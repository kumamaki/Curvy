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

# Open the freshest Debug build.
app:
    open "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Curvy-*/Build/Products/Debug/Curvy.app | head -1)"

# Build, kill any running instance, and launch fresh.
run: build kill app

# Requires `InjectionNext.app` in /Applications — drop the build from
# https://github.com/johnno1962/InjectionNext/releases once, then edits
# to .swift files reload live without rebuilding.
#
# Run with InjectionNext hot-reload (auto-launches the watcher).
develop: ensure-injection run

[private]
ensure-injection:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "/Applications/InjectionNext.app" ]; then
      echo "InjectionNext.app is not in /Applications."
      echo "Download from https://github.com/johnno1962/InjectionNext/releases"
      echo "and drop the .app into /Applications, then run InjectionNext.app."
      exit 1
    fi
    if ! pgrep -f InjectionNext.app >/dev/null; then
      echo "Launching InjectionNext.app (file watcher)…"
      open -g /Applications/InjectionNext.app
      sleep 1
    fi

# Kill any running Curvy instance.
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

# Build a Release Curvy.app and package it into a styled installer at dist/Curvy.dmg.
package:
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
    echo "bumping ${latest} → ${new} ({{kind}})"
    git tag -a "${new}" -m "Release ${new}"
    git push origin "${new}"
    echo "tagged ${new} — workflow:"
    open https://github.com/kumamaki/Curvy/actions
