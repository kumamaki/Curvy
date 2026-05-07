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
    pkill -f Curvy.app 2>/dev/null || true

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

# Bump the latest v* tag (major | minor | patch) and push it. The GitHub Action
# builds the DMG and attaches it to the release. Requires a clean working tree.
# First-ever release uses v0.0.0 as the base, so `just ship patch` → v0.0.1.
#
# Bump the latest v-tag, push, and trigger the release workflow.
ship kind:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{kind}}" in
      major|minor|patch) ;;
      *) echo "usage: just ship <major|minor|patch>"; exit 1 ;;
    esac
    if [ -n "$(git status --porcelain)" ]; then
      echo "working tree is dirty — commit or stash first"
      exit 1
    fi
    git fetch --tags --quiet
    latest=$(git tag --list 'v*' --sort=-version:refname | head -1)
    latest=${latest:-v0.0.0}
    if ! [[ "${latest#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "latest tag <${latest}> is not vX.Y.Z — fix manually"
      exit 1
    fi
    IFS=. read -r major minor patch <<< "${latest#v}"
    case "{{kind}}" in
      major) major=$((major+1)); minor=0; patch=0 ;;
      minor) minor=$((minor+1)); patch=0 ;;
      patch) patch=$((patch+1)) ;;
    esac
    new="v${major}.${minor}.${patch}"
    echo "==> bumping {{kind}}: ${latest} → ${new}"
    echo
    read -r -p "Push ${new} now? [y/N] " reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) echo "ship: aborted." >&2; exit 1 ;;
    esac
    git tag -a "${new}" -m "Release ${new}"
    git push origin "${new}"
    echo "tagged ${new} — workflow:"
    open https://github.com/kumamaki/Curvy/actions
