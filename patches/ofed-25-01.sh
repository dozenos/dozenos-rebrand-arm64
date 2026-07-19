#!/usr/bin/env bash
#
# ofed-25-01.sh -- port the proven old-environment changes to
# build-mellanox-ofed.sh (BF2-FLOWTABLE-OFFLOAD-PLAN.md §6.4):
#
#   - MLNX_OFED 24.07-0.6.1.0 -> 25.01-0.6.0.0 (+ matching source SHA1)
#   - keep the kernel-mft / mstflint / rshim SOURCES tarballs (BlueField
#     tools) instead of deleting them before install.pl runs
#   - pass --kernel-extra-args '--with-sf-cfg-drv' (SF configuration driver)
#
# The amd64-only guard is deliberately KEPT (not removed as the plan's §6.4
# draft suggested): build.py builds every package.toml recipe including mlnx
# with no --packages filter, and on the arm64 nightly we want mlnx to SKIP
# cleanly (the guard exits 0 on non-amd64) rather than download the OFED
# tarball and fail-build against kernel 6.18 -- in-tree mlx5 is the primary
# driver (plan §5), OFED OOT modules are NOT shipped, and OFED 25.01 is not
# expected to compile against 6.18 anyway. The version/sources/sf-cfg-drv
# edits below are FALLBACK-PREP only: they live in the recipe for the day
# someone does a MANUAL out-of-tree OFED build (userland mstflint/rshim/mft,
# or pinning to an OFED-supported LTS kernel per plan §5), where the guard
# is removed by hand for that one-off build. Removing it here would only add
# a noisy, time-wasting fail-build to every arm64 nightly.
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

# The amd64-only guard is intentionally KEPT (see header). Assert it is still
# there so a future upstream removal of the guard is caught here rather than
# silently letting mlnx fail-build on every arm64 nightly.
grep -q '^if ! dpkg-architecture -iamd64; then$' "$OFED" \
  || die "the amd64-only guard is gone from build-mellanox-ofed.sh (upstream drift) -- re-review by hand: mlnx would now fail-build on arm64"
echo "kept the amd64-only guard (mlnx skips cleanly on the arm64 nightly)"

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
