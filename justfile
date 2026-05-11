# Curvy task runner. Run `just` with no args to see all recipes.

set shell := ["bash", "-uc", "-o", "pipefail"]

xcb := `command -v xcbeautify >/dev/null && echo xcbeautify || echo cat`

# Show the recipe list.
default:
    @just --list

# === Build / run ============================================================

# Regenerate Xcode project + build Debug.
build:
    cd mac && xcodegen generate
    cd mac && xcodebuild -project Curvy.xcodeproj -scheme Curvy -configuration Debug build 2>&1 | {{xcb}}

# Run the test bundle.
test:
    cd mac && xcodebuild -project Curvy.xcodeproj -scheme Curvy -configuration Debug test 2>&1 | {{xcb}}

# Build, kill any running instance, and launch fresh.
run: build kill
    open "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Curvy-*/Build/Products/Debug/Curvy.app | head -1)"

[private]
kill:
    #!/usr/bin/env bash
    pkill -f Curvy.app 2>/dev/null || true
    while pgrep -f Curvy.app > /dev/null 2>&1; do sleep 0.1; done

# Trash all DerivedData copies (per CLAUDE.md: trash, never rm).
clean: kill
    trash ~/Library/Developer/Xcode/DerivedData/Curvy-* 2>/dev/null || true

# === Invites ================================================================

# Mint a fresh invite (new room key). Pipe to pbcopy: `just mint <pat> | pbcopy`.
mint pat:
    CURVY_PAT={{pat}} ./scripts/mint-invite.sh

# Mint an extra invite reusing an existing room key (for friends 2/3/4).
mint-extra pat key:
    CURVY_PAT={{pat}} CURVY_ROOM_KEY={{key}} ./scripts/mint-invite.sh

# === Local state ============================================================

# Wipe Curvy's Keychain entries — same as "Sign out" in app, useful for re-onboarding tests.
nuke-keychain:
    security delete-generic-password -s dev.kumamaki.Curvy 2>/dev/null || echo "nothing to delete"

# === Distribution ===========================================================

# Mirrors the contract used by the release workflow so a locally-built DMG
# matches what CI would produce. No tags yet → falls back to 0.0.0.
#
# Build Release Curvy.app and package it into dist/Curvy-<version>.dmg using the latest v* tag.
package:
    #!/usr/bin/env bash
    set -euo pipefail
    git fetch --tags --quiet 2>/dev/null || true
    latest=$(git tag --list 'v*' --sort=-version:refname | head -1)
    latest=${latest:-v0.0.0}
    if ! [[ "${latest#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "latest tag <${latest}> is not vX.Y.Z — fix manually"
      exit 1
    fi
    version="${latest#v}"
    echo "==> packaging Curvy ${version}"
    OUT_DMG="dist/Curvy-${version}.dmg" \
    VOLNAME="Curvy ${version}" \
    MARKETING_VERSION="${version}" \
    CURRENT_PROJECT_VERSION="${version}" \
      ./scripts/build-dmg.sh

# === Release ================================================================

# Delegates to scripts/release.sh, which validates preconditions (clean tree,
# GitButler awareness, tag uniqueness on local + remote, strict monotonic
# version), tags origin/main, and pushes the tag — which triggers
# .github/workflows/release.yml.
#
# Safe to run from any branch including gitbutler/workspace; release.sh
# always tags origin/main in GitButler mode. First-ever release uses v0.0.0
# as the base, so `just ship patch` → v0.0.1.
#
# For a dry-run preview without prompting, invoke the script directly:
#   ./scripts/release.sh --version 1.2.3                    # prints plan, no mutation
#   ./scripts/release.sh --version 1.2.3 --confirm --watch  # prompt, tag, push, watch CI
#   ./scripts/release.sh --version 1.2.3 --push --watch     # silent tag + push + watch CI
#
# Bump v* tag (major|minor|patch), confirm, then push to trigger the release.
ship kind:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{kind}}" in
      major|minor|patch) ;;
      *) echo "usage: just ship <major|minor|patch>" >&2; exit 2 ;;
    esac
    git fetch origin main --tags --quiet
    target=$(git rev-parse origin/main)
    # --merged origin/main filters tags not reachable from our main
    # (defensive against stale upstream tags). Falls back to v0.0.0 for
    # the first-ever release.
    latest="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --merged origin/main --sort=-version:refname | head -1)"
    latest="${latest:-v0.0.0}"
    # No-op release guard: if origin/main is already at the latest tag,
    # bumping would create a new tag pointing at the same commit.
    if git rev-parse -q --verify "refs/tags/${latest}" >/dev/null \
       && [ "$(git rev-parse "${latest}^{commit}")" = "${target}" ]; then
      echo "origin/main is already tagged ${latest} — land new commits before shipping" >&2
      exit 1
    fi
    IFS=. read -r major minor patch <<< "${latest#v}"
    case "{{kind}}" in
      major) major=$((major+1)); minor=0; patch=0 ;;
      minor) minor=$((minor+1)); patch=0 ;;
      patch) patch=$((patch+1)) ;;
    esac
    next="${major}.${minor}.${patch}"
    echo "==> bumping {{kind}}: ${latest} → v${next}"
    echo
    # --confirm validates preconditions, prints the plan (including the
    # annotated tag message), prompts on /dev/tty, and only then tags + pushes.
    # One invocation closes the double-fetch window where the tree could
    # have shifted between the just-recipe's check and the script's push.
    ./scripts/release.sh --version "${next}" --confirm
    open https://github.com/kumamaki/Curvy/actions
