#!/usr/bin/env bash
# Mints a Curvy invite bundle.
#
# Reads a fine-grained GitHub PAT from $CURVY_PAT (or argv[1]),
# generates a fresh 32-byte AES-256 room key, and prints a single
# base64 string to stdout. Hand that string to a friend over Signal —
# they paste it into Curvy and they're in.
#
# Usage:
#   CURVY_PAT=github_pat_xxx ./scripts/mint-invite.sh
#   ./scripts/mint-invite.sh github_pat_xxx
#
# Optional env vars:
#   CURVY_OWNER     default: kumamaki
#   CURVY_REPO      default: curvy-room
#   CURVY_ROOM_KEY  reuse an existing key (base64). Pass this on the
#                   2nd, 3rd, 4th invites so all four clients share
#                   the same key. Omit it on the FIRST invite — the
#                   script will print a fresh key to stderr so you can
#                   capture and reuse it.

set -euo pipefail

PAT="${CURVY_PAT:-${1:-}}"
if [[ -z "$PAT" ]]; then
  echo "error: pass PAT as \$CURVY_PAT or argv[1]" >&2
  exit 1
fi

OWNER="${CURVY_OWNER:-kumamaki}"
REPO="${CURVY_REPO:-curvy-room}"

if [[ -n "${CURVY_ROOM_KEY:-}" ]]; then
  ROOM_KEY="$CURVY_ROOM_KEY"
else
  ROOM_KEY="$(openssl rand -base64 32 | tr -d '\n')"
  echo "fresh room key (save this; reuse via CURVY_ROOM_KEY for the next 3 invites):" >&2
  echo "$ROOM_KEY" >&2
  echo >&2
fi

JSON=$(printf '{"v":1,"token":"%s","roomKey":"%s","owner":"%s","repo":"%s"}' \
  "$PAT" "$ROOM_KEY" "$OWNER" "$REPO")

# base64 of the JSON, single line, no wrapping
printf '%s' "$JSON" | base64 | tr -d '\n'
echo
