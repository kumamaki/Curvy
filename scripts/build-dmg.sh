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
#   CODE_SIGN=no             disable code signing (CI runner without cert)
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v create-dmg >/dev/null; then
  echo "create-dmg not found. Install with: brew install create-dmg" >&2
  exit 1
fi

DERIVED="${DERIVED:-$PWD/build/derived}"
STAGING="${STAGING:-$PWD/build/dmg-staging}"
OUT_DIR="${OUT_DIR:-$PWD/dist}"
OUT_DMG="${OUT_DMG:-$OUT_DIR/Curvy.dmg}"
VOLNAME="${VOLNAME:-Curvy}"
BG="$PWD/assets/dmg/background.png"

if [[ ! -f "$BG" ]]; then
  echo "Background missing at <$BG>. Regenerate with: swift scripts/make-dmg-background.swift assets/dmg" >&2
  exit 1
fi

xcb_args=(
  -project mac/Curvy.xcodeproj
  -scheme Curvy
  -configuration Release
  -derivedDataPath "$DERIVED"
)

[[ -n "${MARKETING_VERSION:-}" ]]       && xcb_args+=( "MARKETING_VERSION=$MARKETING_VERSION" )
[[ -n "${CURRENT_PROJECT_VERSION:-}" ]] && xcb_args+=( "CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION" )

if [[ "${CODE_SIGN:-yes}" == "no" ]]; then
  xcb_args+=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=
  )
fi

echo "==> xcodegen"
( cd mac && xcodegen generate >/dev/null )

echo "==> Building Release"
xcodebuild "${xcb_args[@]}" build

APP="$DERIVED/Build/Products/Release/Curvy.app"
if [[ ! -d "$APP" ]]; then
  echo "Release build missing at <$APP>" >&2
  exit 1
fi

echo "==> Staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"

mkdir -p "$(dirname "$OUT_DMG")"
rm -f "$OUT_DMG"

echo "==> create-dmg ($VOLNAME)"
# White window. Curvy.app (left) + /Applications drop target (right), pair-centered.
# 128pt icons with an 80pt gap → 336pt total → 102pt side margins → centers at
# x=170 / x=370. y=180 biases the icon up to optically center the icon+label
# unit. The background ships @1x + @2x; Finder picks the Retina copy.
create-dmg \
  --volname "$VOLNAME" \
  --background "$BG" \
  --window-pos 200 120 \
  --window-size 540 380 \
  --icon-size 128 \
  --icon "Curvy.app" 170 180 \
  --hide-extension "Curvy.app" \
  --app-drop-link 370 180 \
  --no-internet-enable \
  "$OUT_DMG" \
  "$STAGING"

echo "==> Done"
ls -lh "$OUT_DMG"

