#!/usr/bin/env bash
#
# kernel-perf-nonfatal.sh -- make the linux-kernel build tolerate the known
# arm64 linux-perf sub-package failure.
#
# Root cause (observed on the first arm64 nightly): build-kernel.sh runs
# `make bindeb-pkg BUILD_TOOLS=1 ... -j N` under `set -e`. On arm64 the
# linux-perf package (added unconditionally by the kernel recipe's
# patches/kernel/0002-build-linux-perf-package.patch) fails to build --
# `make -C tools/perf install` hits a libperf generated-syscall-header race:
#   No rule to make target '.../tools/perf/libperf/arch/arm64/include/
#   generated/uapi/asm/unistd_64.h'.
# That non-zero exit aborts build-kernel.sh BEFORE it generates the
# ephemeral module-signing key (/tmp/ephemeral.key, from the freshly
# built certs/signing_key.pem). Every out-of-tree module built afterward
# (ipt-netflow, jool, nat-rtsp, ...) then cannot be signed or xz-compressed
# by sign-modules.sh, so fpm fails on the missing .ko.xz and those debs
# never build -- the ISO then fails with "Unable to locate package
# dozenos-ipt-netflow".
#
# linux-perf is NOT installed by any DozenOS package list, so its failure
# is cosmetic. This patch tolerates a linux-perf-only failure while still
# REQUIRING the essential linux-image deb, so a genuine kernel build failure
# still aborts loudly. amd64 is unaffected (this repo patches only the arm64
# pipeline; amd64's perf builds fine).
#
# Idempotent; dies loudly on upstream drift.
#
# Usage:
#   kernel-perf-nonfatal.sh <dozenos-build-tree>
set -euo pipefail

die() { printf 'kernel-perf-nonfatal: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <dozenos-build-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

BK="$TARGET/scripts/package-build/linux-kernel/build-kernel.sh"
[ -f "$BK" ] || die "expected file not found (upstream drift?): $BK"

SENTINEL='__kbuild_rc'
ANCHOR='make bindeb-pkg BUILD_TOOLS=1 LOCALVERSION=${KERNEL_SUFFIX} KDEB_PKGVERSION=${KERNEL_VERSION}-1 -j $(getconf _NPROCESSORS_ONLN)'

if grep -qF "$SENTINEL" "$BK"; then
  echo "already patched (idempotent no-op): build-kernel.sh perf-nonfatal"
  exit 0
fi
grep -qF "$ANCHOR" "$BK" \
  || die "the 'make bindeb-pkg' anchor line was not found verbatim (upstream drift) -- re-review by hand"

# Replace the single anchored make line with a guarded block. python3 does
# the literal, once-only substitution (no regex metachar hazards).
python3 - "$BK" "$ANCHOR" <<'PYEOF'
import sys
path, anchor = sys.argv[1], sys.argv[2]
src = open(path).read()
if src.count(anchor) != 1:
    sys.exit(f"kernel-perf-nonfatal: expected exactly one anchor, found {src.count(anchor)}")
block = (
    "# arm64 (dozenos-rebrand-arm64): tolerate the known linux-perf build\n"
    "# failure (libperf arm64 generated-header race) so build-kernel.sh still\n"
    "# reaches the ephemeral-key generation below; linux-perf is not shipped.\n"
    "# A genuine kernel build failure (no linux-image deb) still aborts.\n"
    "set +e\n"
    f"{anchor}\n"
    "__kbuild_rc=$?\n"
    "set -e\n"
    "if [ ${__kbuild_rc} -ne 0 ]; then\n"
    '    if ls ../linux-image-${KERNEL_VERSION}${KERNEL_SUFFIX}_*.deb >/dev/null 2>&1; then\n'
    '        echo "W: make bindeb-pkg exited ${__kbuild_rc}; essential kernel debs present -- tolerating the known arm64 linux-perf failure"\n'
    "    else\n"
    '        echo "E: make bindeb-pkg exited ${__kbuild_rc} and no linux-image deb was produced -- real kernel build failure" >&2\n'
    "        exit ${__kbuild_rc}\n"
    "    fi\n"
    "fi"
)
open(path, 'w').write(src.replace(anchor, block, 1))
PYEOF

grep -qF "$SENTINEL" "$BK" || die "patch did not apply (post-check failed)"
bash -n "$BK" || die "patched build-kernel.sh no longer parses -- aborting"
echo "patched: build-kernel.sh tolerates the arm64 linux-perf failure"
echo "kernel-perf-nonfatal: done"
