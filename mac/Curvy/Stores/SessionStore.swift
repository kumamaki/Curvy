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

    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let github: GitHubClient

    init(keychain: KeychainStore = KeychainStore(),
         github: GitHubClient = GitHubClient()) {
        self.keychain = keychain
        self.github = github
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
    func signOut() {
        try? keychain.delete(account: KeychainStore.Account.invite)
        currentInvite = nil
        phase = .needsInvite
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
