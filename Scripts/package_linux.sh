#!/usr/bin/env bash
# Linux x86_64 build of the `sessionhopper` CLI (no menu-bar app), from macOS through Docker.
# Out: dist/sessionhopper-linux-x86_64.tar.gz (+ .sha256). Needs glibc 2.35+ on the target (Swift runtime linked in).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Ubuntu 22.04 base: the binary needs the build image's glibc or newer (plain swift:6.4 needs 2.43).
SWIFT_IMAGE="${SWIFT_IMAGE:-swift:6.4-jammy}"
OUT="$ROOT_DIR/dist/sessionhopper-linux-x86_64"

mkdir -p "$ROOT_DIR/dist"
# .build-linux keeps the macOS .build untouched.
docker run --rm --platform linux/amd64 -v "$ROOT_DIR":/src -w /src "$SWIFT_IMAGE" bash -c \
  "swift build -c release --static-swift-stdlib --product sessionhopper --scratch-path /src/.build-linux \
   && strip -o /src/dist/sessionhopper.linux /src/.build-linux/release/sessionhopper"

rm -rf "$OUT" && mkdir -p "$OUT"
mv "$ROOT_DIR/dist/sessionhopper.linux" "$OUT/sessionhopper"
cp "$ROOT_DIR/LICENSE" "$OUT/"
# No macOS metadata: GNU tar warns about every LIBARCHIVE.xattr header it does not know.
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -C "$ROOT_DIR/dist" -czf "$OUT.tar.gz" "$(basename "$OUT")"
(cd "$ROOT_DIR/dist" && shasum -a 256 "$(basename "$OUT").tar.gz" | tee "$(basename "$OUT").tar.gz.sha256")
