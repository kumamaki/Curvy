import CryptoKit
import Foundation
import OSLog
import SwiftData

/// Receive-side coordinator for encrypted image blobs. When the polling
/// loop ingests an `.image` envelope, the bytes themselves still live
/// on `kumamaki/curvy-room` — this class downloads, AES-GCM-decrypts,
/// and writes the plaintext to the local cache directory. The UI
/// re-renders when the row's `imageCachedAt` flips from nil → Date.
///
/// `@MainActor` because it writes to SwiftData (`modelContext` is
/// MainActor-isolated) and bumps observable state on `CachedMessage`
/// rows that the UI's `@Query` is watching.
///
/// Concurrency: in-flight asset paths are tracked in a `Set<String>` so
/// repeated `materialize` calls for the same asset (which happen any
/// time the polling loop re-ingests an already-known message) coalesce
/// into one download. `Task` is fire-and-forget — failures log and
/// retry on the next poll cycle, which is the same recovery model as
/// the issue-comment poll loop itself.
@MainActor
final class BlobFetcher {
    private let github: GitHubClient
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "dev.kumamaki.Curvy", category: "BlobFetcher")
    private var inFlight: Set<String> = []

    init(github: GitHubClient, modelContext: ModelContext) {
        self.github = github
        self.modelContext = modelContext
    }

    /// Local cache root: `~/Library/Caches/dev.kumamaki.Curvy/blobs/`.
    /// macOS may evict it under disk pressure, which is fine — missing
    /// cache files trigger a re-fetch the next time the user opens the
    /// chat. Created lazily on first write.
    static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "dev.kumamaki.Curvy/blobs", directoryHint: .isDirectory)
    }

    /// Local cache path for a given asset path. Path basename is the
    /// content-addressable filename (`<uuid>.bin`); we keep the `.bin`
    /// extension because `NSImage(contentsOfFile:)` reads bytes by
    /// magic numbers, not extension, so the suffix is decorative only.
    static func cacheURL(for assetPath: String) -> URL {
        let basename = (assetPath as NSString).lastPathComponent
        return cacheDirectory.appending(path: basename, directoryHint: .notDirectory)
    }

    /// Idempotent: no-op if `message` is already materialized (local
    /// cache hit) or already in flight. Otherwise downloads, decrypts,
    /// writes to disk, and bumps `imageCachedAt` so the UI re-renders.
    func materialize(_ message: CachedMessage, invite: Invite, roomKey: Data) {
        guard message.kind == .image,
              let assetPath = message.assetPath,
              let assetSha = message.assetSha,
              let keyB64 = message.imageKeyB64,
              let nonceB64 = message.imageNonceB64 else {
            return
        }

        let cacheURL = Self.cacheURL(for: assetPath)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            // Cache hit, but `imageCachedAt` may be nil if the file
            // landed in a previous run before we recorded it.
            if message.imageCachedAt == nil {
                message.imageCachedAt = Date()
                try? modelContext.save()
            }
            return
        }

        guard !inFlight.contains(assetPath) else { return }
        inFlight.insert(assetPath)

        let messageID = message.id
        Task { [weak self] in
            await self?.runMaterialize(
                assetPath: assetPath,
                assetSha: assetSha,
                keyB64: keyB64,
                nonceB64: nonceB64,
                messageID: messageID,
                invite: invite,
                roomKey: roomKey,
                cacheURL: cacheURL
            )
        }
    }

    private func runMaterialize(
        assetPath: String,
        assetSha: String,
        keyB64: String,
        nonceB64: String,
        messageID: Int,
        invite: Invite,
        roomKey _: Data,
        cacheURL: URL
    ) async {
        defer { inFlight.remove(assetPath) }

        do {
            let ciphertext = try await github.getContent(
                invite: invite,
                path: assetPath,
                knownSha: assetSha
            )

            // Per-file AES-GCM open. Note: the room key never enters
            // here — only the per-file key wrapped inside the message
            // envelope. This is the load-bearing property that lets us
            // store ciphertext on a host the room key never touches.
            let plaintext = try Self.openBlob(
                ciphertext: ciphertext,
                keyB64: keyB64,
                nonceB64: nonceB64
            )

            try Self.writeCache(plaintext: plaintext, to: cacheURL)

            // Bump the row's cached-at so SwiftData publishes the
            // change and `@Query` re-fires on `MessageRow`.
            let descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == messageID })
            if let row = (try? modelContext.fetch(descriptor))?.first {
                row.imageCachedAt = Date()
                try? modelContext.save()
            }
        } catch {
            logger.warning("materialize failed for <\(assetPath, privacy: .public)>: \(error.localizedDescription, privacy: .public)")
            // No retry here — next poll cycle re-ingests this row,
            // which triggers another `materialize` call. Idempotent
            // by construction.
        }
    }

    private static func openBlob(ciphertext: Data, keyB64: String, nonceB64: String) throws -> Data {
        guard let keyData = Data(base64Encoded: keyB64),
              keyData.count == 32 else {
            throw BlobError.malformedKey
        }
        guard let nonceData = Data(base64Encoded: nonceB64),
              nonceData.count == 12 else {
            throw BlobError.malformedNonce
        }
        guard ciphertext.count >= 16 else {
            throw BlobError.ciphertextTooShort
        }
        let key = SymmetricKey(data: keyData)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let tag = ciphertext.suffix(16)
        let cipherOnly = ciphertext.prefix(ciphertext.count - 16)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherOnly, tag: tag)
        return try AES.GCM.open(box, using: key)
    }

    private static func writeCache(plaintext: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try plaintext.write(to: url, options: .atomic)
    }

    enum BlobError: Error, CustomStringConvertible {
        case malformedKey
        case malformedNonce
        case ciphertextTooShort

        var description: String {
            switch self {
            case .malformedKey: "per-file key isn't valid 32-byte base64"
            case .malformedNonce: "per-file nonce isn't valid 12-byte base64"
            case .ciphertextTooShort: "asset bytes are shorter than the AES-GCM tag (16 bytes)"
            }
        }
    }
}

