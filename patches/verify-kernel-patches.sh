#!/usr/bin/env bash
#
# verify-kernel-patches.sh -- assert the dozenos-build linux-kernel recipe
# still carries the arm64 syscalltbl fix the linux-perf package build needs.
#
# arch/arm64/kernel/Makefile.syscalls overrides syscalltbl with a path
# relative to the kernel source root, but tools/lib/perf invokes the header
# generator from tools/lib/perf/ -- so on a NATIVE arm64 build host the
# linux-perf package build dies with "No rule to make target
# '.../unistd_64.h'", aborting build-kernel.sh before it generates the
# ephemeral signing key and leaving every OOT module unsigned.
#
# This repo used to ship that fix itself as a 0005- kernel patch. Upstream
# now carries it (vyos-build a0a7452, mirrored as
# patches/kernel/0005-arm64-fix-relative-syscalltbl-path-in-Makefile.sysc.patch),
# so we only verify it is still there rather than installing a duplicate --
# two patches touching the same line would collide on `patch -p1`.
#
# No writes: this script only reads the target tree.
#
# Usage:
#   verify-kernel-patches.sh <dozenos-build-tree>
set -euo pipefail

die() { printf 'verify-kernel-patches: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <dozenos-build-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

LK="$TARGET/scripts/package-build/linux-kernel"
DEST="$LK/patches/kernel"
BK="$LK/build-kernel.sh"
[ -d "$DEST" ] || die "kernel patches dir not found (upstream drift?): $DEST"
[ -f "$BK" ]   || die "build-kernel.sh not found (upstream drift?): $BK"

grep -q 'patches/kernel' "$BK" \
  || die "build-kernel.sh no longer applies patches/kernel (upstream drift) -- the arm64 syscalltbl fix would be dead"

FIX='syscalltbl = $(srctree)/arch/arm64/tools/syscall_%.tbl'
if ! grep -rqF -- "$FIX" "$DEST"; then
  die "no patch under patches/kernel/ carries the absolute arm64 syscalltbl fix -- upstream dropped it; re-add it here (see git history: patches/kernel/0005-arm64-perf-abs-syscalltbl.patch)"
fi

echo "verify-kernel-patches: arm64 syscalltbl fix present"
