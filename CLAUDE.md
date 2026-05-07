# CLAUDE.md

Project-level guidance for Claude when working in this repo. Read first.

## What this project is

**Curvy** is a native macOS chat for **four people** — kumamaki and three
personally invited friends. There is no signup, no server, no roadmap
that involves more users. The trust model assumes you know everyone in
the room.

The repo is two cooperating pieces that live in **separate GitHub
repos**:

```
kumamaki/Curvy        ← this repo. App source. Public.
                        Contains zero secrets. Anyone can read the code,
                        nobody can use it without an invite.

kumamaki/curvy-room   ← private data repo. 4 collaborators, no humans
                        ever read it directly. Contents:
                          - Issue #1, with comments = encrypted messages
                          - Releases, with assets   = encrypted blobs
                        Curvy.app talks to it via the GitHub REST API.
                        It is NEVER cloned, just queried.
```

Every message and attachment is AES-GCM ciphertext. GitHub stores opaque
bytes; the four clients share one 256-bit room key, distributed
out-of-band as part of an "invite" bundle (PAT + room key + repo
coordinates, base64-encoded JSON). See `scripts/mint-invite.sh`.

`README.md` is intentionally a one-liner. This file is the real
context.

## Hard rules — do not violate

These are load-bearing for the trust model. If a refactor seems to
require breaking one of these, **stop and ask.**

- **No per-user OAuth.** All four Macs share one fine-grained PAT
  scoped to `kumamaki/curvy-room` only. The PAT travels in the invite
  bundle. We deliberately do *not* sign in each user via GitHub OAuth
  Device Flow because (a) that would force every friend to have a
  GitHub account, (b) it would leak real usernames into
  `comment.user.login` which is exactly the metadata we want to hide.
  GitHub sees one anonymous bot doing all the writes — keep it that
  way.
- **Identity lives inside the encrypted payload, not on GitHub.** When
  v1 lands, the sender's display name is a field inside the ciphertext.
  Never set it from `comment.user.login` or any other GitHub-visible
  attribute, even as a "fallback."
- **The room key never leaves Keychain after the user pastes it.** No
  logging, no debug prints, no analytics. Same for the PAT.
- **Curvy stores everything in one Keychain entry: `invite.bundle`,
  scoped to service `dev.kumamaki.Curvy`.** Single atomic blob means
  onboarding can't half-succeed. Don't split it across multiple entries
  without a strong reason.
- **`mac/project.yml` is the source of truth.** Both `Curvy.xcodeproj/`
  and the generated `Info.plist` / `Curvy.entitlements` are gitignored.
  Run `just build` (which calls `xcodegen generate`) after editing
  `project.yml`.
- **Bundle ID prefix is `dev.kumamaki`** (matching Pigeon, not
  `com.kumamaki`). Don't drift.

## Architecture cheat sheet

### Onboarding (one-time, per friend)

```
kumamaki  ──▶  github.com/settings/tokens
               creates fine-grained PAT scoped to kumamaki/curvy-room

           ──▶  just mint <pat> | pbcopy
                emits base64 invite bundle, prints fresh room key on stderr

           ──▶  shares invite over Signal with friend
           ──▶  for friends 2/3/4: just mint-extra <pat> <key>
                (reuses the same room key so all four clients agree)

friend     ──▶  pastes invite into Curvy.app's InviteView
           ──▶  SessionStore.applyInvite() decodes, validates against
                GitHub via GET /repos/:owner/:repo, persists to Keychain
                as the `invite.bundle` entry, advances phase to .ready
```

### Runtime (every launch)

```
CurvyApp ──▶ SessionStore.bootstrap()
              │
              ├── reads `invite.bundle` from Keychain
              │   └── if absent → phase = .needsInvite (InviteView)
              │
              ├── decodes Invite JSON
              ├── GitHubClient.verifyAccess(invite:)
              │     → GET https://api.github.com/repos/<owner>/<repo>
              │       Authorization: Bearer <pat>
              │
              ├── 200 OK → phase = .ready (ConnectedView for v0;
              │            chat UI for v1+)
              └── any error → phase = .error (ErrorView with "Start over")
```

### Wire format (locked, will guide v1+)

Each comment body on Issue #1 of `curvy-room` is base64 of:

```json
{ "v": 1, "n": "<12-byte nonce b64>", "c": "<ciphertext+tag b64>" }
```

Plaintext (before AES-GCM seal) is JSON, polymorphic by `type`:

- `text`    — `{type, body, reply_to?, sent_at}`
- `image`   — `{type, asset_id, name, mime, key, nonce, size, sent_at}`
- `file`    — same shape as image, different render
- `reaction`        — `{type, target_id, emoji, sent_at}`
- `reaction_remove` — `{type, target_id, emoji}`

Files/images: encrypt with a per-file AES-GCM key, upload ciphertext as
a Release asset on `curvy-room`, wrap the per-file key into the message
envelope. Don't put the room key on the per-file blobs.

## Build & dev

The `justfile` is the canonical dev surface.

```sh
just                  # list recipes
just build            # xcodegen + xcodebuild Debug
just run              # build, kill any running instance, launch fresh
just develop          # run with InjectionNext hot-reload (auto-launches the watcher)
just app              # launch the freshest existing build (no rebuild)
just kill             # pkill Curvy.app
just test             # run the test bundle
just clean            # kill + trash all DerivedData/Curvy-*
just mint <pat>       # generate first invite — prints new room key to stderr
just mint-extra <pat> <key>  # generate invites 2/3/4 — reuses given key
just nuke-keychain    # wipe local Curvy state (re-onboarding tests)
just package          # build Release + package into dist/Curvy.dmg
just ship <bump>      # bump v-tag (major|minor|patch), push, trigger Actions
```

Requires Xcode 26 + macOS 26 + xcodegen + just.

```sh
brew install xcodegen just
```

If a build fails with "Entitlements file was modified during the build,"
do `just clean` once and rebuild — xcodegen + xcodebuild can race on a
fresh generate.

## Conventions

### Swift (`mac/`)

- Swift 6, **strict concurrency complete.** Don't downgrade.
- macOS 26 deployment target. Use new APIs freely. **Skip `#available`
  gating for macOS 26+ APIs** — there's no older floor to fall back to,
  so the gates are noise.
- `@Observable` + `@State` over `ObservableObject` + `@StateObject`.
- `@MainActor` on stores; mark `@ObservationIgnored` on any property
  wrapper inside an `@Observable` class.
- **Use `actor` only for shared mutable state.** Stateless network
  layers like `GitHubClient` are `Sendable` structs, not actors. Actor
  isolation is overhead with no benefit when there's nothing to
  serialize.
- All `@State` properties are `private`.

### Liquid Glass

- We adopt Liquid Glass deliberately. The window background is glass,
  cards are glass, buttons use `.buttonStyle(.glass)` /
  `.buttonStyle(.glassProminent)`. **Message bubbles will stay solid
  in v1** — text legibility on glass is fragile, and chat is
  read-heavy.
- Apply `.glassEffect(...)` AFTER layout modifiers (padding/frame), not
  before.
- Group co-located glass surfaces in a `GlassEffectContainer` so they
  sample consistently. Glass cannot sample other glass.

### Git

- Branch naming: `type/description` (e.g. `feat/encrypted-text`,
  `fix/keychain-race`).
- Conventional commits: `feat:`, `fix:`, `chore:`, `refactor:`. No
  `(scope)` since this repo is one app.
- Co-author trailer: `Co-Authored-By: Claude Opus 4.7 (1M context)`.
- Never push to `main` without explicit user confirmation.

### Tooling

- `pnpm`, never npm/yarn (mirror toolchain shared with Pigeon).
- Fish shell — Fish-compatible syntax in shell snippets (`just`
  recipes already wrap bash internally so they're safe).
- `trash` for deletes, never `rm`.
- `gh` CLI for GitHub API operations, not WebFetch.

## Common tasks

### Adding a new friend (5th person, hypothetically)

We deliberately don't support this — the trust model is "4 people".
But if you ever do:

1. Add their GitHub username as a collaborator on `kumamaki/curvy-room`.
   *(Even though they don't use OAuth, collaborator status is what
   would let them rotate the PAT in an emergency.)*
2. Run `just mint-extra <pat> <existing-room-key> | pbcopy`.
3. Send the invite over Signal.

### Removing a friend (kicking)

1. Generate a new PAT at github.com/settings/tokens. Revoke the old
   one.
2. Generate a new room key: `openssl rand -base64 32`.
3. `just mint <new-pat>` (gives you a new invite with the new key).
4. `just mint-extra <new-pat> <new-key>` for the remaining friends.
5. Distribute via Signal. Old messages are unreadable to anyone with
   only the old key, but they're also unreadable to the remaining
   friends — past chat history is lost. (We accept this. Forward
   secrecy is out of scope.)

### Updating the wire format (when v1+ ships)

1. Bump `Invite.currentVersion` and the `v` field in the message
   envelope simultaneously.
2. Update `Invite.decode` to either accept multiple versions during a
   transition, or reject the old version (forcing re-onboarding).
3. **Order matters:** decide whether old clients should be able to
   decrypt new messages. If not, ship the schema change to all four
   Macs before the first new-format message lands in `curvy-room`.

### Debugging onboarding

```sh
# 1. Wipe local state and re-onboard from a clean slate:
just nuke-keychain
just app

# 2. Mint an invite with a known-bad PAT to test the error path:
just mint github_pat_definitely_invalid | pbcopy
# (paste, expect "the token isn't valid (HTTP 401)")

# 3. Verify the PAT directly against GitHub:
gh api repos/kumamaki/curvy-room  # uses your gh-CLI auth, not the curvy PAT
curl -s -H "Authorization: Bearer $YOUR_PAT" \
  https://api.github.com/repos/kumamaki/curvy-room | jq .full_name
```

## Lessons learned (don't repeat)

- **`Glass.prominent` does not exist in shipping macOS 26.2.** The
  shipping `SwiftUICore.Glass` only exposes `.regular`, `.clear`,
  `.identity` plus `.tint(_:)` and `.interactive(_:)` instance
  methods. The `swiftui-expert-skill` plugin's `liquid-glass.md`
  reference is wrong on this — it documents `.glassEffect(.prominent)`
  and `.prominent.tint(...)` which compile-fail. The `.buttonStyle(.glass)`
  / `.buttonStyle(.glassProminent)` *button* styles are real and shipping;
  the confusion is that the WWDC25 beta apparently had a `.prominent`
  Glass *material* that was cut before release. Verify against the
  actual `.swiftinterface` when in doubt:
  ```sh
  grep -A20 "^public struct Glass : Swift.Equatable" \
    /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/\
SDKs/MacOSX.sdk/System/Library/Frameworks/SwiftUICore.framework/\
Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface
  ```
- **`#available` gating is noise when macOS 26 is the deployment
  target.** Every macOS 26+ API is available unconditionally — adding
  `if #available(macOS 26, *)` produces a guard that always passes plus
  a fallback branch that's dead code. Skip it. The skill's reference
  text suggests gating; ignore that for *this* project specifically.
- **OAuth Device Flow was wrong for a 4-person closed group.** I
  initially built it because it's the "professional" pattern. The user
  pushed back: "why would we need a sign-in with github?" — correctly.
  Personal Access Token + invite bundle is strictly simpler AND more
  private (no real GitHub usernames leak). Don't reach for OAuth on
  closed-group apps just because it's the default for "real" software.
- **`actor` is for shared mutable state, not "this code is async."**
  The first cut of `GitHubClient` was an actor. It had zero mutable
  state and no need for serialized access. Refactored to `struct:
  Sendable` — clearer, callable from any context, no `await` overhead
  on the call boundary itself. Same lesson: don't reach for the heavy
  primitive when the lightweight one fits.
- **`xcodegen` regenerates `Info.plist` and `Curvy.entitlements`** on
  every run. Both are gitignored — `project.yml` is canonical.
- **Fine-grained PAT permissions are per-API-resource, not per-feature.**
  v1 minted PATs with `Issues: write` for the chat comments, which is
  why text works. v3 needed `Contents: write` for image storage via
  the Contents API — adding it surfaces as a 403 on `PUT /contents/...`
  even though `/issues/.../comments` keeps working. Future feature
  expansions (v2 reactions hit issues, v4 generic files hit contents,
  but v5+ might need `Metadata: read` upgrades or new resources)
  must check what resource each endpoint gates against and update
  `scripts/mint-invite.sh`'s required-permissions header. PAT
  permissions can be widened in place without rotating the token —
  edit at github.com/settings/personal-access-tokens, save, done.
- **The Contents API doesn't auto-create branches.** Originally I had
  v3 store ciphertext on a separate `blobs` branch for "cleanliness",
  with a one-time `ensureBlobsBranch` bootstrap. Two failure modes
  killed it: (1) `PUT /contents/...?branch=blobs` returns 404
  "Branch not found" if the branch doesn't exist, (2) the bootstrap
  itself (`GET /git/ref/heads/main` to find a SHA to branch from)
  returns 409 "Git Repository is empty" on a fresh repo with zero
  commits. The fix was to drop the separate branch entirely and PUT
  directly to the default branch — on an empty repo, the Contents
  API creates the initial commit + the file in one operation. The
  "main pollution" concern was always cosmetic; nobody opens
  `curvy-room` in the GitHub web UI.

## What's deferred / not yet built

In rough priority order if the user asks "what's next?":

1. **v1 — encrypted text chat.** AES-GCM seal/open, message envelope,
   single Issue as the room, polling actor with adaptive intervals,
   send/receive UI, unread badges, local SwiftData cache of decrypted
   messages.
2. **v2 — reactions.** Encrypted reaction comments, full Unicode via
   the macOS emoji picker (⌃⌘Space), grouped under target message in
   the UI.
3. **v3 — encrypted images.** Per-file AES-GCM key wrapped in the
   message envelope, ciphertext uploaded as a Release asset, custom
   Nuke `DataLoading` to decrypt on fetch.
4. **v4 — encrypted files.** Same plumbing as v3, generic file types,
   download to ~/Downloads + reveal in Finder.
5. **v5 — polish.** Local notifications via `UNUserNotificationCenter`,
   replies/threads, member display names, settings panel (room key
   rotation, per-friend mute), local-only search.

When in doubt about what to work on, **ask** — don't assume from this
list.

## Pigeon connection

This project shares a developer (`kumamaki`) and conventions with
[Pigeon](https://github.com/kumamaki/Pigeon), but is otherwise
independent. Both target macOS 26, Swift 6, use xcodegen + just, and
follow the same `@Observable` + `@MainActor` store style. **Do not**
share code via a Swift package or symlinks — they're separate apps with
separate bundle IDs and different threat models. Copy-paste with
attribution if you need a helper from Pigeon.
