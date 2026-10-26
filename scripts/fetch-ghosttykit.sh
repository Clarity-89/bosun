#!/bin/sh
# Fetches GhosttyKit.xcframework (libghostty built from Ghostty 1.3.1) from
# the Calyx repository at a pinned commit into Vendor/, which is gitignored.
# Headers and plists come from the source tarball; the 141 MB static library
# is a git-lfs object, fetched from GitHub's media endpoint and checked
# against the sha256 its pointer file declares.
set -eu

REPO="yuuichieguchi/Calyx"
COMMIT="2dfb7a400d450f1554ae6277452ae4772fdd0dae"
LIB_PATH="GhosttyKit.xcframework/macos-arm64/libghostty-fat.a"
DEST="${1:-Vendor}"

if [ -f "$DEST/$LIB_PATH" ] && [ ! -f "$DEST/.incomplete" ]; then
  echo "GhosttyKit.xcframework already present in $DEST"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "fetching source tree at $COMMIT"
curl -fsSL "https://github.com/$REPO/archive/$COMMIT.tar.gz" \
  | tar -xzf - -C "$work" --strip-components=1 "Calyx-$COMMIT/GhosttyKit.xcframework"

pointer="$work/$LIB_PATH"
expected="$(sed -n 's/^oid sha256:\([0-9a-f]*\)$/\1/p' "$pointer")"
[ -n "$expected" ] || { echo "pointer file has no sha256 oid: $pointer" >&2; exit 1; }

echo "fetching libghostty-fat.a (141 MB)"
curl -fSL --progress-bar -o "$pointer" \
  "https://media.githubusercontent.com/media/$REPO/$COMMIT/$LIB_PATH"

actual="$(shasum -a 256 "$pointer" | cut -d' ' -f1)"
[ "$actual" = "$expected" ] || { echo "sha256 mismatch: $actual != $expected" >&2; exit 1; }

mkdir -p "$DEST"
touch "$DEST/.incomplete"
rm -rf "$DEST/GhosttyKit.xcframework"
mv "$work/GhosttyKit.xcframework" "$DEST/"
rm -f "$DEST/.incomplete"
echo "GhosttyKit.xcframework ready in $DEST (sha256 $actual)"
