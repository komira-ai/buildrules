#!/usr/bin/env bash
# HELD: uploads the pinned busybox to a release of this repository. Run by the repository owner (or on their go); never by CI.
#
# Why: busybox.net is the only origin of the busybox 1.35.0 that every action of buildrules runs under, and it times out for hours at a time. rules/pins/pins.bzl and
# rules/rust/pins.bzl pin the copy this script uploads (an asset of the release `mirror-busybox-1.35.0`), with the sha256 and size of the official file.
#
#   tools/held/mirror-busybox.sh            dry run: downloads the official file, checks it, says what --apply would do. Changes nothing on GitHub.
#   tools/held/mirror-busybox.sh --apply    downloads and checks, creates the release, uploads the asset, downloads the asset again and checks it.
#
# Needs: curl, sha256sum, wc, awk, and (for --apply) `gh` logged in with write access to this repository. Run it from anywhere; it finds pins.bzl beside itself.
# Safe to run again: a release that already holds the asset is only re-verified. It never replaces an asset and never deletes a release.
# The origin may be down: each download is tried ATTEMPTS times with a growing wait; if all fail the script says busybox.net is not answering and stops without changing anything.
set -euo pipefail

BASE="https://github.com/komira-ai/buildrules"
REPO="${BASE#https://github.com/}"
TAG="mirror-busybox-1.35.0"
ASSET="busybox"
UPSTREAM="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
MIRROR="$BASE/releases/download/$TAG/$ASSET"
ATTEMPTS="${ATTEMPTS:-6}"
FIRST_WAIT="${FIRST_WAIT:-10}"

apply=0
for arg in "$@"; do
  case "$arg" in
    --apply) apply=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg (only --apply)" >&2; exit 2 ;;
  esac
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pins="$here/../../rules/pins/pins.bzl"
[ -f "$pins" ] || { echo "no $pins" >&2; exit 2; }

# The busybox row of pins.bzl: sha256, size, and the url it must have.
row="$(awk '/^    "busybox": \{/{on=1} on{print} on&&/^    \},/{exit}' "$pins")"
want_sha="$(printf '%s\n' "$row" | sed -n 's/^ *"sha256": "\([0-9a-f]\{64\}\)",$/\1/p')"
want_size="$(printf '%s\n' "$row" | sed -n 's/^ *"size": \([0-9][0-9]*\),$/\1/p')"
row_url="$(printf '%s\n' "$row" | sed -n 's/^ *"url": "\(.*\)",$/\1/p')"
[ -n "$want_sha" ] && [ -n "$want_size" ] || { echo "cannot read the busybox sha256 and size from $pins" >&2; exit 2; }
if [ "$row_url" != "$MIRROR" ]; then
  echo "pins.bzl's busybox url is $row_url, not $MIRROR: this script and the pin disagree" >&2
  exit 2
fi

work_root="${HOLD_WORK:-$HOME/workplace}"
work="$(mktemp -d "$work_root/mirror-busybox.XXXXXX")"
cleanup() { rm -f "$work/official" "$work/mirror"; rmdir "$work" 2>/dev/null || true; }
trap cleanup EXIT

# fetch <url> <file> <what>: curl with retries and a wait that doubles. Returns 1 when every attempt failed.
fetch() {
  local url="$1" out="$2" what="$3" i wait="$FIRST_WAIT"
  for ((i = 1; i <= ATTEMPTS; i++)); do
    if curl --fail --silent --show-error --location --connect-timeout 20 --max-time 180 --output "$out" "$url"; then
      return 0
    fi
    echo "  $what: attempt $i of $ATTEMPTS failed" >&2
    if ((i < ATTEMPTS)); then
      echo "  waiting ${wait}s" >&2
      sleep "$wait"
      wait=$((wait * 2))
    fi
  done
  return 1
}

# verify <file> <what>: the pinned sha256 and size, or stop.
verify() {
  local file="$1" what="$2" got_sha got_size
  got_size="$(wc -c <"$file" | tr -d ' ')"
  got_sha="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$got_size" != "$want_size" ] || [ "$got_sha" != "$want_sha" ]; then
    echo "$what does not match the pin: size $got_size (want $want_size), sha256 $got_sha (want $want_sha)" >&2
    exit 1
  fi
  echo "$what matches the pin: $got_size bytes, sha256 $got_sha"
}

echo "1. download the official file: $UPSTREAM"
if ! fetch "$UPSTREAM" "$work/official" "busybox.net"; then
  echo "busybox.net is not answering ($ATTEMPTS attempts). Nothing was changed. Try again later; this script takes the file from no other host." >&2
  exit 3
fi
echo "2. verify it against rules/pins/pins.bzl"
verify "$work/official" "the official file"

if [ "$apply" -eq 0 ]; then
  echo "dry run: with --apply this would create the release $TAG on $REPO (if absent), upload the asset '$ASSET' ($want_size bytes),"
  echo "then download $MIRROR and verify it again. Nothing was changed."
  exit 0
fi

command -v gh >/dev/null || { echo "--apply needs gh" >&2; exit 2; }
echo "3. the release $TAG on $REPO"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "  the release exists"
else
  gh release create "$TAG" --repo "$REPO" --target main --latest=false \
    --title "busybox 1.35.0 mirror" \
    --notes "A copy of $UPSTREAM, pinned by rules/pins/pins.bzl (sha256 $want_sha, $want_size bytes). Do not replace the asset."
fi
echo "4. the asset"
if gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name' | grep -qx "$ASSET"; then
  echo "  the asset is already there; it is not replaced, only verified below"
else
  gh release upload "$TAG" "$work/official#$ASSET" --repo "$REPO"
fi
echo "5. download the asset again: $MIRROR"
if ! fetch "$MIRROR" "$work/mirror" "github.com"; then
  echo "the uploaded asset cannot be downloaded from $MIRROR ($ATTEMPTS attempts)" >&2
  exit 1
fi
verify "$work/mirror" "the mirrored asset"
echo "done: pins.bzl's busybox url now resolves."
