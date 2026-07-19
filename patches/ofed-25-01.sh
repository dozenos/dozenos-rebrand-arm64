#!/usr/bin/env bash
#
# ofed-25-01.sh -- port the proven old-environment changes to
# build-mellanox-ofed.sh (BF2-FLOWTABLE-OFFLOAD-PLAN.md §6.4):
#
#   - MLNX_OFED 24.07-0.6.1.0 -> 25.01-0.6.0.0 (+ matching source SHA1)
#   - drop the amd64-only guard (confirmed false alert -- the arm64 build
#     works; the guard would silently skip the whole build on the DPU arch)
#   - keep the kernel-mft / mstflint / rshim SOURCES tarballs (BlueField
#     tools) instead of deleting them before install.pl runs
#   - pass --kernel-extra-args '--with-sf-cfg-drv' (SF configuration driver)
#
# FALLBACK-ONLY: the in-tree mlx5 of kernel 6.18 is the main driver (plan
# §5) and the arm64 nightly does NOT build the mlnx unit. This script keeps
# the OFED recipe buildable for userland tools (mstflint/rshim/mft) and as
# the escape hatch if in-tree FT offload shows a real bug on BF2. OFED
# 25.01 kernel modules are not expected to compile against 6.18.
#
# Idempotent; dies loudly on upstream drift.
#
# Usage:
#   ofed-25-01.sh <dozenos-build-tree>
set -euo pipefail

die() { printf 'ofed-25-01: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <dozenos-build-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

OFED="$TARGET/scripts/package-build/linux-kernel/build-mellanox-ofed.sh"
[ -f "$OFED" ] || die "expected file not found (upstream drift?): $OFED"

OLD_VER='mlxver="24.07-0.6.1.0"'
NEW_VER='mlxver="25.01-0.6.0.0"'
OLD_SHA='DRIVER_SHA1="c64defa8fb38dcbce153adc09834ab5cdcecd791"'
NEW_SHA='DRIVER_SHA1="b1aca864f457c0ef860d048e0bb862b3d7f53763"'

if grep -qxF "$NEW_VER" "$OFED"; then
  echo "already at 25.01-0.6.0.0 (idempotent no-op): mlxver"
elif grep -qxF "$OLD_VER" "$OFED"; then
  sed -i "s|^${OLD_VER}\$|${NEW_VER}|" "$OFED"
  echo "mlxver: 24.07-0.6.1.0 -> 25.01-0.6.0.0"
else
  die "mlxver line has neither the expected nor the patched value (upstream drift) -- re-review by hand"
fi

if grep -qxF "$NEW_SHA" "$OFED"; then
  echo "already patched (idempotent no-op): DRIVER_SHA1"
elif grep -qxF "$OLD_SHA" "$OFED"; then
  sed -i "s|^${OLD_SHA}\$|${NEW_SHA}|" "$OFED"
  echo "DRIVER_SHA1: updated for the 25.01-0.6.0.0 source tarball"
else
  die "DRIVER_SHA1 line has neither the expected nor the patched value (upstream drift) -- re-review by hand"
fi

if grep -q '^if ! dpkg-architecture -iamd64; then$' "$OFED"; then
  perl -0pi -e 's/if ! dpkg-architecture -iamd64; then\n[^\n]*\n[^\n]*\nfi\n\n//' "$OFED"
  grep -q 'dpkg-architecture -iamd64' "$OFED" && die "amd64 guard removal left a residue -- re-review by hand"
  echo "removed the amd64-only guard"
elif grep -q 'dpkg-architecture' "$OFED"; then
  die "unexpected dpkg-architecture usage remains (upstream drift) -- re-review by hand"
else
  echo "already removed (idempotent no-op): amd64 guard"
fi

for keep in kernel-mft mstflint rshim; do
  if grep -qxF "rm -f SOURCES/${keep}_*.tar.gz" "$OFED"; then
    sed -i "\|^rm -f SOURCES/${keep}_\*\.tar\.gz\$|d" "$OFED"
    echo "kept SOURCES tarball (removed the rm line): ${keep}"
  else
    echo "already kept (idempotent no-op): ${keep}"
  fi
done
# The other SOURCES rm lines are upstream-authored trim and must survive --
# their wholesale disappearance would mean upstream restructured the script.
grep -q '^rm -f SOURCES/openmpi_\*\.tar\.gz$' "$OFED" \
  || die "SOURCES trim block missing entirely (upstream drift) -- re-review by hand"

KERNEL_LINE='  --kernel ${KERNEL_VERSION}${KERNEL_SUFFIX}'
EXTRA_LINE="  --kernel-extra-args '--with-sf-cfg-drv'"
if grep -qxF "$EXTRA_LINE" "$OFED"; then
  echo "already present (idempotent no-op): --kernel-extra-args"
elif grep -qxF "$KERNEL_LINE" "$OFED"; then
  sed -i 's|^  --kernel ${KERNEL_VERSION}${KERNEL_SUFFIX}$|  --kernel ${KERNEL_VERSION}${KERNEL_SUFFIX} \\\n  --kernel-extra-args '\''--with-sf-cfg-drv'\''|' "$OFED"
  echo "install.pl: added --kernel-extra-args '--with-sf-cfg-drv'"
else
  die "install.pl --kernel line not found (upstream drift) -- re-review by hand"
fi

echo "ofed-25-01: done"
