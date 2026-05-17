#!/usr/bin/env bash
# Build a Release Curvy.app and package it into a styled installer DMG.
#
# Defaults are tuned for local use:
#   ./scripts/build-dmg.sh              -> dist/Curvy.dmg
#
# CI overrides via env:
#   OUT_DMG                  output path (e.g. dist/Curvy-1.2.3.dmg)
#   VOLNAME                  mounted volume name (e.g. "Curvy 1.2.3")
#   MARKETING_VERSION        forwarded to xcodebuild
#   CURRENT_PROJECT_VERSION  forwarded to xcodebuild
#   CODE_SIGN=no             disable code signing entirely (rare: CI runner without cert)
#   VERBOSE=1                show full xcodebuild output (skip xcbeautify)
#   NO_COLOR=1               disable ANSI color (also auto-disabled when stdout isn't a tty)
#
# Notarization (optional — skipped if vars are absent):
#   NOTARIZATION_APPLE_ID    Apple ID used for notarization (e.g. you@example.com)
#   NOTARIZATION_TEAM_ID     10-char team ID (e.g. 4QB74VU5X3)
#   NOTARIZATION_PASSWORD    App-specific password from appleid.apple.com
set -euo pipefail

cd "$(dirname "$0")/.."

# --- Pretty-print helpers ----------------------------------------------------
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'
  CYAN=$'\033[36m'; GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'
  RESET=$'\033[0m'
else
  BOLD=; DIM=; CYAN=; GREEN=; RED=; YELLOW=; RESET=
fi

step()   { printf '\n%s==>%s %s%s%s\n' "$CYAN" "$RESET" "$BOLD" "$1" "$RESET"; }
ok()     { printf '%s ok%s %s\n' "$GREEN" "$RESET" "$1"; }
skip()   { printf '%s -- %s%s\n' "$YELLOW" "$1" "$RESET"; }
die()    { printf '%s !! %s%s\n' "$RED" "$1" "$RESET" >&2; exit 1; }

# Wrap a step with timing. Usage: timed "label" cmd args...
timed() {
  local label="$1"; shift
  local t0=$SECONDS
  "$@"
  ok "${label} in $((SECONDS - t0))s"
}

# --- Preflight ---------------------------------------------------------------
command -v create-dmg >/dev/null \
  || die "create-dmg not found. Install with: brew install create-dmg"

DERIVED="${DERIVED:-$PWD/build/derived}"
STAGING="${STAGING:-$PWD/build/dmg-staging}"
OUT_DIR="${OUT_DIR:-$PWD/dist}"
OUT_DMG="${OUT_DMG:-$OUT_DIR/Curvy.dmg}"
VOLNAME="${VOLNAME:-Curvy}"

# xcbeautify is optional; falls back to raw output. VERBOSE=1 forces raw.
if [[ -z "${VERBOSE:-}" ]] && command -v xcbeautify >/dev/null; then
  XCB=(xcbeautify --quiet)
else
  XCB=(cat)
fi

TOTAL_START=$SECONDS

step "Packaging ${VOLNAME}"

# --- Generate Xcode project --------------------------------------------------
step "Generating Xcode project"
timed "generated" bash -c '( cd mac && xcodegen generate >/dev/null )'

# --- Build Release -----------------------------------------------------------
xcb_args=(
  -project mac/Curvy.xcodeproj
  -scheme Curvy
  -configuration Release
  -derivedDataPath "$DERIVED"
)
[[ -n "${MARKETING_VERSION:-}" ]]       && xcb_args+=( "MARKETING_VERSION=$MARKETING_VERSION" )
[[ -n "${CURRENT_PROJECT_VERSION:-}" ]] && xcb_args+=( "CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION" )
if [[ "${CODE_SIGN:-yes}" == "no" ]]; then
  xcb_args+=( CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= )
fi

step "Building Release"
build_start=$SECONDS
xcodebuild "${xcb_args[@]}" build 2>&1 | "${XCB[@]}"
ok "built in $((SECONDS - build_start))s"

APP="$DERIVED/Build/Products/Release/Curvy.app"
[[ -d "$APP" ]] || die "Release build missing at <$APP>"

# --- Stage -------------------------------------------------------------------
step "Staging app bundle"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ok "staged at ${STAGING#$PWD/}"

mkdir -p "$(dirname "$OUT_DMG")"
rm -f "$OUT_DMG"

# --- Create DMG --------------------------------------------------------------
# Curvy.app (left) + /Applications drop target (right), pair-centered.
# 128pt icons with an 80pt gap → 336pt total → 102pt side margins → centers at
# x=170 / x=370. y=180 biases the icon up to optically center the icon+label
# unit.
step "Creating installer DMG"
dmg_start=$SECONDS
create-dmg \
  --volname "$VOLNAME" \
  --window-pos 200 120 \
  --window-size 540 380 \
  --icon-size 128 \
  --icon "Curvy.app" 170 180 \
  --hide-extension "Curvy.app" \
  --app-drop-link 370 180 \
  --no-internet-enable \
  "$OUT_DMG" \
  "$STAGING" \
  | sed "s|^|${DIM}    |;s|$|${RESET}|"
ok "built ${OUT_DMG#$PWD/} in $((SECONDS - dmg_start))s"

# --- Sign + notarize ---------------------------------------------------------
if [[ "${CODE_SIGN:-yes}" != "no" ]]; then
  SIGN_ID="${CODE_SIGN_IDENTITY:-Developer ID Application}"

  step "Signing DMG"
  codesign --sign "$SIGN_ID" --timestamp "$OUT_DMG"
  ok "signed with <$SIGN_ID>"

  if [[ -n "${NOTARIZATION_APPLE_ID:-}" && -n "${NOTARIZATION_TEAM_ID:-}" && -n "${NOTARIZATION_PASSWORD:-}" ]]; then
    step "Notarizing (this takes a minute)"
    notary_start=$SECONDS
    xcrun notarytool submit "$OUT_DMG" \
      --apple-id  "${NOTARIZATION_APPLE_ID}" \
      --team-id   "${NOTARIZATION_TEAM_ID}" \
      --password  "${NOTARIZATION_PASSWORD}" \
      --wait
    ok "notarized in $((SECONDS - notary_start))s"

    step "Stapling"
    xcrun stapler staple "$OUT_DMG"
    ok "stapled"
  else
    step "Notarization"
    skip "skipped — set NOTARIZATION_APPLE_ID / TEAM_ID / PASSWORD to enable"
  fi
else
  step "Code signing"
  skip "skipped — CODE_SIGN=no"
fi

# --- Summary -----------------------------------------------------------------
size=$(du -h "$OUT_DMG" | awk '{print $1}')
step "Done in $((SECONDS - TOTAL_START))s"
printf '%s    %s%s  %s(%s)%s\n' "$BOLD" "${OUT_DMG#$PWD/}" "$RESET" "$DIM" "$size" "$RESET"
