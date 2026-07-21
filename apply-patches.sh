#!/usr/bin/env bash
#
# apply-patches.sh -- arm64/DPU patch layer for a dozenos-build tree.
#
# Pipeline position (dozenos-nightly-build-arm64 CI):
#
#   checkout dozenos/dozenos-build @ rolling -> apply-patches.sh <tree>
#
# This repo patches an ALREADY-REBRANDED dozenos-build checkout at CI time.
# It is not a mirror overlay: nothing here is ever pushed back to the
# dozenos-build mirror, and the amd64 pipeline (dozenos-rebrand +
# dozenos-nightly-build) never sees these patches. After applying, CI makes
# a throwaway local commit so deb-cache.sh's HEAD:-based key material sees
# the patched recipe content (see dozenos-rebrand/DEB-CACHE.md).
#
# Idempotent: every patch script is a no-op when already applied and dies
# loudly on upstream drift (neither the expected nor the patched form
# found). Running twice against the same tree produces byte-identical
# output on the second run.
#
# No network, no git, no build -- pure file operations.
#
# Usage:
#   apply-patches.sh <dozenos-build-tree>
set -euo pipefail

die() { printf 'apply-patches: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <dozenos-build-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"
TARGET=$(cd "$TARGET" && pwd)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

echo "== apply-patches: dozenos-rebrand-arm64 =="
"$SCRIPT_DIR/patches/kernel-config-bf2-offload.sh" "$TARGET"
"$SCRIPT_DIR/patches/verify-kernel-patches.sh" "$TARGET"
"$SCRIPT_DIR/patches/ofed-25-01.sh" "$TARGET"
echo "apply-patches: done"
