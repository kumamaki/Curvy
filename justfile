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
    #!/usr/bin/env bash
    set -euo pipefail
    app="$(ls -dt ~/Library/Developer/Xcode/DerivedData/Curvy-*/Build/Products/Debug/Curvy.app | head -1)"
    # Re-register with LaunchServices so lsd's view of the bundle matches the
    # freshly-built one. Avoids -600 procNotFound when lsd's prior registration
    # is still mid-tear-down (kernel reaped the PID, but lsd's bookkeeping is async).
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
    # -n forces a brand-new instance, sidestepping LS dedup against any stale entry.
    open -n "$app"

[private]
kill:
    #!/usr/bin/env bash
    pkill -f Curvy.app 2>/dev/null || true
    while pgrep -f Curvy.app > /dev/null 2>&1; do sleep 0.1; done
    # pgrep tracks the kernel; launchservicesd's view is async. Wait for lsd to
    # forget the bundle too, otherwise `open` can race and return -600.
    while lsappinfo list 2>/dev/null | grep -q 'dev\.kumamaki\.Curvy'; do sleep 0.1; done

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
    git fetch origin main --quiet 2>/dev/null || true
    latest=$(git tag --list 'v*' --sort=-version:refname | head -1)
    latest=${latest:-v0.0.0}
    if ! [[ "${latest#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "latest tag <${latest}> is not vX.Y.Z — fix manually"
      exit 1
    fi
    version="${latest#v}"
    OUT_DMG="dist/Curvy-${version}.dmg" \
    VOLNAME="Curvy ${version}" \
    MARKETING_VERSION="${version}" \
    CURRENT_PROJECT_VERSION="${version}" \
      ./scripts/build-dmg.sh

# === Logs ===================================================================

# Subsystem used by AppLog. Single source of truth for the log predicates below.
log_subsystem := "dev.kumamaki.Curvy"

# Tail Curvy logs live. Ctrl-C to stop.
#   just logs                 # all categories
#   just logs net             # GitHub API only
# Categories: net, store, session, crypto, blobs, images, notif, ql, ui, all (default).
logs category="all":
    #!/usr/bin/env bash
    set -euo pipefail
    cat=$(echo "{{category}}" | tr '[:upper:]' '[:lower:]')
    if [[ "$cat" == "all" ]]; then
      pred='subsystem == "{{log_subsystem}}"'
    else
      capped="$(tr '[:lower:]' '[:upper:]' <<< ${cat:0:1})${cat:1}"
      pred='subsystem == "{{log_subsystem}}" AND category == "'"$capped"'"'
    fi
    echo "==> tailing $cat — Ctrl-C to stop"
    exec log stream --style compact --level info --predicate "$pred"

# Dump last <duration> of Curvy logs and exit.
#   just logs-since             # all categories, last 5m
#   just logs-since net 30s     # Net only, last 30s
# Duration syntax: 30s, 5m, 1h.
logs-since category="all" duration="5m":
    #!/usr/bin/env bash
    set -euo pipefail
    cat=$(echo "{{category}}" | tr '[:upper:]' '[:lower:]')
    if [[ "$cat" == "all" ]]; then
      pred='subsystem == "{{log_subsystem}}"'
    else
      capped="$(tr '[:lower:]' '[:upper:]' <<< ${cat:0:1})${cat:1}"
      pred='subsystem == "{{log_subsystem}}" AND category == "'"$capped"'"'
    fi
    echo "==> dumping $cat (last {{duration}})"
    log show --style compact --info --debug --last {{duration}} --predicate "$pred"

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
    git fetch origin main --quiet
    target=$(git rev-parse origin/main)
    # --merged origin/main filters tags not reachable from our main
    # (defensive against stale upstream tags). Falls back to v0.0.0 for
    # the first-ever release.
    latest="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --merged origin/main --sort=-version:refname | head -1)"
    latest="${latest:-v0.0.0}"
    # No-op release guard: if origin/main is already at the latest tag AND
    # there are no local commits to push, bumping would tag the same commit twice.
    # If local HEAD is ahead of origin/main, release.sh --confirm will push
    # those commits first, so we skip the guard and let it proceed.
    ahead="$(git rev-list --count origin/main..HEAD)"
    if git rev-parse -q --verify "refs/tags/${latest}" >/dev/null \
       && [ "$(git rev-parse "${latest}^{commit}")" = "${target}" ] \
       && [ "${ahead}" -eq 0 ]; then
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
