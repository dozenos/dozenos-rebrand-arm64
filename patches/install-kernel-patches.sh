#!/usr/bin/env bash
#
# install-kernel-patches.sh -- drop this repo's arm64 kernel source patches
# into the dozenos-build linux-kernel recipe so build-kernel.sh applies them.
#
# build-kernel.sh applies every file under
# scripts/package-build/linux-kernel/patches/kernel/ with `patch -p1` (in
# `ls` order) against the kernel source BEFORE generating the config. Our
# patches use a 0005+ numeric prefix so they sort after the four upstream
# 0001-0004 patches.
#
# Patches installed (this repo's patches/kernel/*.patch):
#   0005-arm64-perf-abs-syscalltbl.patch -- fix the arm64 linux-perf build
#     (absolute syscalltbl path) so the kernel package builds cleanly and
#     build-kernel.sh reaches its ephemeral-key generation, letting every
#     OOT module sign/compress. Replaces the earlier non-fatal workaround.
#
# Idempotent (byte-identical copy = no-op); dies loudly on drift.
#
# Usage:
#   install-kernel-patches.sh <dozenos-build-tree>
set -euo pipefail

die() { printf 'install-kernel-patches: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <dozenos-build-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC="$SCRIPT_DIR/kernel"
[ -d "$SRC" ] || die "patch source dir not found: $SRC"

LK="$TARGET/scripts/package-build/linux-kernel"
DEST="$LK/patches/kernel"
BK="$LK/build-kernel.sh"
[ -d "$DEST" ] || die "kernel patches dir not found (upstream drift?): $DEST"
[ -f "$BK" ]   || die "build-kernel.sh not found (upstream drift?): $BK"

# Confirm the patches actually get applied -- guard against an upstream
# refactor that drops the patch-application loop (which would silently make
# our patch dead).
grep -q 'patches/kernel' "$BK" \
  || die "build-kernel.sh no longer references patches/kernel (upstream drift) -- re-review by hand: our kernel patch would be dead"

shopt -s nullglob
patches=("$SRC"/*.patch)
[ "${#patches[@]}" -gt 0 ] || die "no *.patch files under $SRC"

for p in "${patches[@]}"; do
  base=${p##*/}
  d="$DEST/$base"
  if [ -e "$d" ]; then
    if cmp -s "$p" "$d"; then
      echo "already installed (idempotent no-op): $base"
      continue
    fi
    die "refusing to overwrite an existing, different kernel patch: $d -- re-review by hand"
  fi
  # A duplicate numeric prefix already present upstream would apply twice --
  # fail rather than collide. nullglob is on, so an empty match yields an
  # empty array (do NOT use `ls`, which would list cwd on an empty glob).
  case "$base" in
    [0-9][0-9][0-9][0-9]-*)
      prefix=${base%%-*}
      existing=("$DEST/${prefix}-"*.patch)
      if [ "${#existing[@]}" -gt 0 ]; then
        die "an upstream patch already uses the ${prefix}- prefix -- renumber $base"
      fi ;;
  esac
  cp -p "$p" "$d"
  echo "installed kernel patch: $base"
done

echo "install-kernel-patches: done"
