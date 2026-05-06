# Curvy task runner. Run `just` with no args to see all recipes.

set shell := ["bash", "-uc", "-o", "pipefail"]

xcb := `command -v xcbeautify >/dev/null && echo xcbeautify || echo cat`

# Show the recipe list
default:
    @just --list

# === Build / run ============================================================

# Regenerate Xcode project + build Debug, then reveal the .app in Finder
build:
    cd mac && xcodegen generate
    cd mac && xcodebuild -project Curvy.xcodeproj -scheme Curvy -configuration Debug build 2>&1 | {{xcb}}
    just reveal

# Run the test bundle
test:
    cd mac && xcodebuild -project Curvy.xcodeproj -scheme Curvy -configuration Debug test 2>&1 | {{xcb}}

# Open the freshest Debug build
app:
    open "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Curvy-*/Build/Products/Debug/Curvy.app | head -1)"

# Build then immediately launch the freshest Debug build
run: build app

# Reveal the freshest Debug build in Finder
reveal:
    open -R "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Curvy-*/Build/Products/Debug/Curvy.app | head -1)"

# Kill any running Curvy instance
kill:
    pkill -f Curvy.app 2>/dev/null || true

# Trash all DerivedData copies (per CLAUDE.md: trash, never rm)
clean:
    trash ~/Library/Developer/Xcode/DerivedData/Curvy-* 2>/dev/null || true

# === Invites ================================================================

# Mint a fresh invite (new room key). Pipe to pbcopy: `just mint <pat> | pbcopy`
mint pat:
    CURVY_PAT={{pat}} ./scripts/mint-invite.sh

# Mint an extra invite reusing an existing room key (for friends 2/3/4)
mint-extra pat key:
    CURVY_PAT={{pat}} CURVY_ROOM_KEY={{key}} ./scripts/mint-invite.sh

# === Local state ============================================================

# Wipe Curvy's Keychain entries — same as "Sign out" in app, useful for re-onboarding tests
nuke-keychain:
    security delete-generic-password -s dev.kumamaki.Curvy 2>/dev/null || echo "nothing to delete"

# === Repos ==================================================================

# Open the source repo on github.com
src:
    open https://github.com/kumamaki/Curvy

# Open the room (data) repo on github.com
room:
    open https://github.com/kumamaki/curvy-room
