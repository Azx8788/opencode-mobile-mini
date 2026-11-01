#!/usr/bin/env bash
# Fetches the pinned proot, its loader and the two libraries it needs from the
# Termux package archive, checks every download against its SHA-256, and
# installs them as the app's native libraries.
#
# Why native libraries: an app targeting Android 10+ may not run programs from
# its own storage, but it may run what the APK ships under jniLibs, which the
# system unpacks into a read-only, executable folder. proot then runs Ubuntu's
# programs itself through its loader, so nothing is executed from app storage.
#
# Android only unpacks files named lib*.so, so the files are renamed, and the
# one dependency declared under another name (libtalloc.so.2) is rewritten
# with patchelf. The Termux RUNPATH is dropped: the app sets LD_LIBRARY_PATH.
#
# Usage: tool/builtin_linux/fetch_proot.sh [patchelf]
set -euo pipefail

PATCHELF=${1:-patchelf}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/android/app/src/main/jniLibs"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

MIRROR=https://packages-cf.termux.dev/apt/termux-main/pool/main

# name|path in the archive|sha256, per architecture.
declare -A PACKAGES=(
  [aarch64]="
p/proot/proot_5.1.107.94_aarch64.deb|b6fa26884d162f5234b0aba9f8a98971aad793706099464f7bd7eb1e21d63935
libt/libtalloc/libtalloc_2.4.3_aarch64.deb|ac81ad623d74c209718b9f3acb2dd702cc8a88c431e820d212229910b4db29da
liba/libandroid-shmem/libandroid-shmem_0.7_aarch64.deb|0da3a24d558b93c92bcf8d611e0826a99ff96e396b148e6cdf33b47c47c57ff6"
  [x86_64]="
p/proot/proot_5.1.107.94_x86_64.deb|826cdf66f9eb04bb9faf7f1eb36078abc75b086c074e937b53d1abbf08ccfb85
libt/libtalloc/libtalloc_2.4.3_x86_64.deb|7ca2eaae2e53b28228a01301bc410b62845403d6317c25b8e0a7f40681de0628
liba/libandroid-shmem/libandroid-shmem_0.7_x86_64.deb|ffa9e4c87467b158b148d0ff92dda796aa038276c2075af3269cdcdb06f25797"
)
declare -A ABI=([aarch64]=arm64-v8a [x86_64]=x86_64)

for arch in aarch64 x86_64; do
  unpacked="$WORK/$arch"
  mkdir -p "$unpacked"
  while IFS='|' read -r path sha; do
    [ -n "$path" ] || continue
    deb="$WORK/$(basename "$path")"
    curl -fsSL --retry 3 -o "$deb" "$MIRROR/$path"
    echo "$sha  $deb" | sha256sum -c --quiet -
    (cd "$unpacked" && ar p "$deb" data.tar.xz | tar xJ)
  done <<<"${PACKAGES[$arch]}"

  usr="$unpacked/data/data/com.termux/files/usr"
  dest="$OUT/${ABI[$arch]}"
  mkdir -p "$dest"
  install -m 0755 "$usr/bin/proot" "$dest/libproot.so"
  install -m 0755 "$usr/libexec/proot/loader" "$dest/libproot-loader.so"
  install -m 0755 "$usr/lib/libtalloc.so.2.4.3" "$dest/libtalloc.so"
  install -m 0755 "$usr/lib/libandroid-shmem.so" "$dest/libandroid-shmem.so"

  "$PATCHELF" --replace-needed libtalloc.so.2 libtalloc.so "$dest/libproot.so"
  "$PATCHELF" --remove-rpath "$dest/libproot.so"
  "$PATCHELF" --set-soname libtalloc.so "$dest/libtalloc.so"
  "$PATCHELF" --remove-rpath "$dest/libtalloc.so"
  "$PATCHELF" --remove-rpath "$dest/libandroid-shmem.so" 2>/dev/null || true
done

echo "Installed into $OUT:"
find "$OUT" -name '*.so' -printf '  %P %s bytes\n' | sort
