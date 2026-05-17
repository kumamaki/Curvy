import CryptoKit
import Foundation
import Observation
import os

/// App-wide auth + room state.
///
/// Curvy is a 4-person group chat. There is no per-user OAuth, no
/// signup, no user accounts. All four Macs share one fine-grained
/// GitHub Personal Access Token scoped to `kumamaki/curvy-room`. The
/// token, the AES-256 room key, and the repo coordinates travel
/// together as a single base64-encoded JSON "invite" that kumamaki
/// generates with `scripts/mint-invite.sh` and shares over Signal.
///
/// User-visible identity (who sent which message) lives inside the
/// encrypted payload — set by each user locally in v1, ignored in v0.
@MainActor
@Observable
final class SessionStore {
    enum Phase: Equatable {
        case bootstrapping
        case needsInvite
        case validating
        case ready(repoSlug: String)
        case error(String)
    }

    private(set) var phase: Phase = .bootstrapping

    /// The invite that's currently active. Non-nil iff `phase == .ready`.
    /// Held in memory so `MessageStore` can pull the room key out for
    /// AES-GCM seal/open without re-reading Keychain on every send.
    /// Per CLAUDE.md, the key never leaves Keychain in a *persisted*
    /// form — keeping it in process memory is necessary for the app to
    /// function and is not what that rule prohibits.
    private(set) var currentInvite: Invite?

    /// This device's stable user ID. Generated on first launch of a
    /// build with DMs and persisted alongside the private key in a
    /// single atomic Keychain blob (`identity.bundle`). Loaded once
    /// per process when `.ready` is first reached; subsequently held
    /// for the process lifetime and survives `signOut()` so re-
    /// onboarding with the same friends preserves identity.
    /// Nil only before the first successful bootstrap; never reset.
    private(set) var myUserID: UUID?

    /// This device's Curve25519 key-agreement private key. Same
    /// lifecycle as `myUserID` — paired with it in the atomic Keychain
    /// blob so the two can never be out of sync. Observation-ignored
    /// because the typed key isn't `Hashable` and the observation
    /// graph has no business firing on it.
    @ObservationIgnored private(set) var myPrivateKey: Curve25519.KeyAgreement.PrivateKey?

    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let github: GitHubClient

    init(keychain: KeychainStore = KeychainStore(),
         github: GitHubClient = GitHubClient()) {
        self.keychain = keychain
        self.github = github
    }

    /// Convenience projection for callers that need the public-facing
    /// identity to broadcast or compare against the registry. Nil
    /// before bootstrap completes — once `.ready`, this is non-nil
    /// for the lifetime of the session.
    func identity(displayName: String) -> UserIdentity? {
        guard let myUserID, let pubKey = myPrivateKey?.publicKey.rawRepresentation else {
            return nil
        }
        return UserIdentity(
            userID: myUserID,
            displayName: displayName,
            pubKey: pubKey,
            announcedAt: Date()
        )
    }

    /// Called from the App's `.task` modifier. If we already have a
    /// valid invite in Keychain, verify it still works against GitHub
    /// and advance to `.ready`. Otherwise `.needsInvite`.
    func bootstrap() async {
        AppLog.session.pub("bootstrap start")
        do {
            guard let invite = try loadInvite() else {
                AppLog.session.pub("phase → needsInvite (no stored invite)")
                phase = .needsInvite
                return
            }
            AppLog.session.pub("phase → validating")
            phase = .validating
            try await github.verifyAccess(invite: invite)
            currentInvite = invite
            try loadOrCreateIdentity()
            AppLog.session.pub("phase → ready (\(invite.owner)/\(invite.repo))")
            phase = .ready(repoSlug: "\(invite.owner)/\(invite.repo)")
        } catch {
            AppLog.session.error("bootstrap failed: \(error.localizedDescription, privacy: .public)")
            phase = .error("Stored invite is no longer valid: \(error). Paste a fresh one.")
        }
    }

    /// User pasted an invite into `InviteView`. Decode, validate
    /// against GitHub, persist on success.
    func applyInvite(_ raw: String) async {
        AppLog.session.pub("applyInvite start")
        phase = .validating
        do {
            let invite = try Invite.decode(raw)
            AppLog.session.pub("invite decoded — verifying access")
            try await github.verifyAccess(invite: invite)
            try saveInvite(invite)
            currentInvite = invite
            try loadOrCreateIdentity()
            AppLog.session.pub("phase → ready (\(invite.owner)/\(invite.repo))")
            phase = .ready(repoSlug: "\(invite.owner)/\(invite.repo)")
        } catch let error as Invite.DecodeError {
            AppLog.session.error("invite decode failed: \(error.userFacing, privacy: .public)")
            phase = .error(error.userFacing)
        } catch let error as GitHubClient.GitHubError {
            AppLog.session.error("GitHub rejected invite: \(error.description, privacy: .public)")
            phase = .error("GitHub rejected the invite: \(error)")
        } catch {
            AppLog.session.error("applyInvite failed: \(error.localizedDescription, privacy: .public)")
            phase = .error("\(error)")
        }
    }

    /// Wipes the invite. Used by the "Sign out" action.
    ///
    /// Deliberately does *not* wipe the DM identity (private key +
    /// user ID). Re-onboarding with the same friends should preserve
    /// the user's stable identity so existing DM channels and the
    /// roster they appear in on peers' sidebars stay intact. A
    /// destructive identity reset requires `just nuke-keychain`.
    func signOut() {
        try? keychain.delete(account: KeychainStore.Account.invite)
        currentInvite = nil
        phase = .needsInvite
    }

    // MARK: - DM identity (v1.5)

    /// Load this device's DM identity from Keychain, or generate +
    /// persist a fresh one in a single atomic write. The userID and
    /// the private key share one blob (`identity.bundle`) so a crash
    /// between writes can never leave them out of sync — same
    /// atomicity discipline as `invite.bundle`. Idempotent: skipped
    /// when the in-memory fields are already populated for this
    /// process.
    private func loadOrCreateIdentity() throws {
        if myUserID != nil, myPrivateKey != nil { return }

        if let data = try keychain.read(account: KeychainStore.Account.identityBundle) {
            let bundle = try JSONDecoder().decode(IdentityBundle.self, from: data)
            guard let rawKey = Data(base64Encoded: bundle.privKeyB64) else {
                throw KeychainStore.KeychainError.decodingFailed
            }
            self.myPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawKey)
            self.myUserID = bundle.userID
            return
        }

        let userID = UUID()
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let bundle = IdentityBundle(
            userID: userID,
            privKeyB64: privateKey.rawRepresentation.base64EncodedString()
        )
        let encoded = try JSONEncoder().encode(bundle)
        try keychain.write(account: KeychainStore.Account.identityBundle, value: encoded)
        AppLog.session.pub("generated new DM identity bundle")
        self.myUserID = userID
        self.myPrivateKey = privateKey
    }

    // MARK: - Persistence

    private func loadInvite() throws -> Invite? {
        guard let data = try keychain.read(account: KeychainStore.Account.invite) else {
            return nil
        }
        return try JSONDecoder().decode(Invite.self, from: data)
    }

    private func saveInvite(_ invite: Invite) throws {
        let data = try JSONEncoder().encode(invite)
        try keychain.write(account: KeychainStore.Account.invite, value: data)
    }
}
