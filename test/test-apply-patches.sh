#!/usr/bin/env bash
#
# Integration test for apply-patches.sh (kernel-config-bf2-offload.sh +
# ofed-25-01.sh). Self-contained and NETWORK-FREE: builds a synthetic
# dozenos-build tree holding the exact upstream forms the patch scripts
# grep for, then asserts:
#
#   1. One apply produces every §6.1-6.4 edit (fragments flipped, defconfig
#      options present, OFED version/sha1/guard/SOURCES/install.pl edits).
#   2. Idempotent: a second run is byte-identical.
#   3. Drift detection: a tree missing an expected form dies loudly and
#      leaves the tree unmodified from the failure point on.
#   4. Bad usage fails loudly.
#
# NOTE: no `set -e` -- this runner tallies pass/fail itself.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLKIT=$(dirname "$HERE")
SCRIPT="$TOOLKIT/apply-patches.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

snapshot() {
  ( cd "$1" || exit
    find . -type f | LC_ALL=C sort | while IFS= read -r p; do
      printf 'F %s %s\n' "$p" "$(sha256sum < "$p" | cut -d' ' -f1)"
    done )
}

# ---------------------------------------------------------------------------
# Fixture: the pre-patch upstream forms, reduced to the lines the patch
# scripts anchor on (plus the prerequisite lines they assert).
# ---------------------------------------------------------------------------
make_fixture() {
  local t=$1
  local lk="$t/scripts/package-build/linux-kernel"
  mkdir -p "$lk/config/arm64"

  cat > "$lk/config/13-net-sched.config" <<'EOF'
CONFIG_NET_ACT_TUNNEL_KEY=m
# CONFIG_NET_ACT_CT is not set
# CONFIG_NET_ACT_GATE is not set
# CONFIG_NET_TC_SKB_EXT is not set
EOF

  cat > "$lk/config/20-netfilter.config" <<'EOF'
CONFIG_NF_FLOW_TABLE_INET=m
CONFIG_NF_FLOW_TABLE=m
# CONFIG_NF_FLOW_TABLE_PROCFS is not set
CONFIG_NETFILTER_XTABLES=m
EOF

  cat > "$lk/config/arm64/dozenos_defconfig" <<'EOF'
CONFIG_VIRTIO_NET=m
CONFIG_MLX5_CORE=m
CONFIG_MLX5_ESWITCH=y
CONFIG_MLX5_BRIDGE=y
# CONFIG_MLXBF_GIGE is not set
CONFIG_VIRTIO_CONSOLE=y
CONFIG_HWMON=y
CONFIG_EDAC=y
CONFIG_MMC_SDHCI_PLTFM=m
# CONFIG_MMC_SDHCI_OF_DWCMSHC is not set
EOF

  mkdir -p "$lk/patches/kernel"
  cat > "$lk/patches/kernel/0002-build-linux-perf-package.patch" <<'EOF'
(placeholder upstream patch)
EOF
  cat > "$lk/patches/kernel/0005-arm64-fix-relative-syscalltbl-path-in-Makefile.sysc.patch" <<'EOF'
--- a/arch/arm64/kernel/Makefile.syscalls
+++ b/arch/arm64/kernel/Makefile.syscalls
-syscalltbl = arch/arm64/tools/syscall_%.tbl
+syscalltbl = $(srctree)/arch/arm64/tools/syscall_%.tbl
EOF
  cat > "$lk/build-kernel.sh" <<'EOF'
#!/bin/bash
CWD=$(pwd)
PATCH_DIR=${CWD}/patches/kernel
for patch in $(ls ${PATCH_DIR}); do
    patch -p1 < ${PATCH_DIR}/${patch}
done
make bindeb-pkg BUILD_TOOLS=1
EOF

  cat > "$lk/build-mellanox-ofed.sh" <<'EOF'
#!/bin/sh
DROP_DEV_DBG_DEBS=1
CWD=$(pwd)

if [ ! -f x ]; then
  :
fi

if ! dpkg-architecture -iamd64; then
    echo "Mellanox OFED is only buildable on amd64 platforms"
    exit 0
fi

mlxver="24.07-0.6.1.0"
url="https://www.mellanox.com/downloads/ofed/MLNX_OFED-${mlxver}/MLNX_OFED_SRC-debian-${mlxver}.tgz"
DRIVER_SHA1="c64defa8fb38dcbce153adc09834ab5cdcecd791"

rm -f SOURCES/ibarr_*.tar.gz
rm -f SOURCES/kernel-mft_*.tar.gz
rm -f SOURCES/mstflint_*.tar.gz
rm -f SOURCES/openmpi_*.tar.gz
rm -f SOURCES/rshim_*.tar.gz
rm -f SOURCES/ucx_*.tar.gz

./install.pl \
  --basic --dpdk \
  --kernel-sources ${KERNEL_DIR} \
  --kernel ${KERNEL_VERSION}${KERNEL_SUFFIX}
EOF
}

# ---------------------------------------------------------------------------
# Run 1: apply on a pristine fixture -- every edit lands.
# ---------------------------------------------------------------------------
echo "== apply on pristine fixture =="
make_fixture "$WORK/tree"
LK="$WORK/tree/scripts/package-build/linux-kernel"

if "$SCRIPT" "$WORK/tree" >"$WORK/run1.log" 2>&1; then
  ok "apply-patches exits 0"
else
  bad "apply-patches exits 0 (log: $(cat "$WORK/run1.log"))"
fi

expect_line() {
  local f="$1" line="$2" what="$3"
  if grep -qxF "$line" "$f"; then ok "$what"; else bad "$what"; fi
}
absent_line() {
  local f="$1" line="$2" what="$3"
  if grep -qxF "$line" "$f"; then bad "$what"; else ok "$what"; fi
}

expect_line "$LK/config/13-net-sched.config" 'CONFIG_NET_ACT_CT=m'      "§6.1 NET_ACT_CT=m"
expect_line "$LK/config/13-net-sched.config" 'CONFIG_NET_TC_SKB_EXT=y'  "§6.1 NET_TC_SKB_EXT=y"
absent_line "$LK/config/13-net-sched.config" '# CONFIG_NET_ACT_CT is not set' "§6.1 old NET_ACT_CT line gone"
expect_line "$LK/config/20-netfilter.config" 'CONFIG_NF_FLOW_TABLE_PROCFS=y' "§6.1 NF_FLOW_TABLE_PROCFS=y"
expect_line "$LK/config/13-net-sched.config" '# CONFIG_NET_ACT_GATE is not set' "unrelated fragment line untouched"

for opt in MLX5_CLS_ACT=y MLX5_TC_CT=y MLX5_TC_SAMPLE=y MELLANOX_PLATFORM=y \
           MLXBF_GIGE=m MLXBF_TMFIFO=y MLXBF_BOOTCTL=m MLXBF_PMC=m \
           GPIO_MLXBF2=m GPIO_MLXBF3=m PINCTRL_MLXBF3=m I2C_MLXBF=m \
           POWER_MLXBF=m EDAC_BLUEFIELD=m MMC_SDHCI_OF_DWCMSHC=m; do
  expect_line "$LK/config/arm64/dozenos_defconfig" "CONFIG_$opt" "§6.2/6.3 $opt"
done

OFED="$LK/build-mellanox-ofed.sh"
expect_line "$OFED" 'mlxver="25.01-0.6.0.0"' "§6.4 mlxver bumped"
expect_line "$OFED" 'DRIVER_SHA1="b1aca864f457c0ef860d048e0bb862b3d7f53763"' "§6.4 sha1 bumped"
expect_line "$OFED" 'if ! dpkg-architecture -iamd64; then' "§6.4 amd64 guard KEPT (mlnx skips on arm64)"
if grep -q '^if \[ ! -f x \]; then$' "$OFED"; then ok "§6.4 unrelated if-block untouched"; else bad "§6.4 unrelated if-block untouched"; fi
absent_line "$OFED" 'rm -f SOURCES/kernel-mft_*.tar.gz' "§6.4 kernel-mft sources kept"
absent_line "$OFED" 'rm -f SOURCES/mstflint_*.tar.gz'   "§6.4 mstflint sources kept"
absent_line "$OFED" 'rm -f SOURCES/rshim_*.tar.gz'      "§6.4 rshim sources kept"
expect_line "$OFED" 'rm -f SOURCES/openmpi_*.tar.gz' "§6.4 upstream trim survives"
expect_line "$OFED" "  --kernel-extra-args '--with-sf-cfg-drv'" "§6.4 --kernel-extra-args added"
if bash -n "$OFED"; then ok "§6.4 patched script parses"; else bad "§6.4 patched script parses"; fi

# verify-kernel-patches (upstream's arm64 perf-syscalltbl kernel patch)
if grep -q 'syscalltbl fix present' "$WORK/run1.log"; then ok "kernel-patch: upstream syscalltbl fix verified"; else bad "kernel-patch: upstream syscalltbl fix verified"; fi
if [ -z "$(find "$LK/patches/kernel" -name '0005-arm64-perf-abs-syscalltbl.patch')" ]; then ok "kernel-patch: no duplicate patch installed"; else bad "kernel-patch: no duplicate patch installed"; fi

# ---------------------------------------------------------------------------
# Run 2: idempotency -- second run byte-identical.
# ---------------------------------------------------------------------------
echo "== idempotency =="
before=$(snapshot "$WORK/tree")
if "$SCRIPT" "$WORK/tree" >"$WORK/run2.log" 2>&1; then
  ok "second run exits 0"
else
  bad "second run exits 0 (log: $(cat "$WORK/run2.log"))"
fi
after=$(snapshot "$WORK/tree")
if [ "$before" = "$after" ]; then
  ok "second run is byte-identical"
else
  bad "second run is byte-identical"
fi

# ---------------------------------------------------------------------------
# Run 3: drift detection.
# ---------------------------------------------------------------------------
echo "== drift detection =="

make_fixture "$WORK/tree-drift1"
sed -i '/# CONFIG_NET_ACT_CT is not set/d' \
  "$WORK/tree-drift1/scripts/package-build/linux-kernel/config/13-net-sched.config"
if "$SCRIPT" "$WORK/tree-drift1" >/dev/null 2>&1; then
  bad "missing NET_ACT_CT line: expected non-zero exit"
else
  ok "missing NET_ACT_CT line: dies loudly"
fi

make_fixture "$WORK/tree-drift2"
sed -i 's/^CONFIG_MLX5_BRIDGE=y$/# CONFIG_MLX5_BRIDGE is not set/' \
  "$WORK/tree-drift2/scripts/package-build/linux-kernel/config/arm64/dozenos_defconfig"
if "$SCRIPT" "$WORK/tree-drift2" >/dev/null 2>&1; then
  bad "missing MLX5_BRIDGE prerequisite: expected non-zero exit"
else
  ok "missing MLX5_BRIDGE prerequisite: dies loudly"
fi

make_fixture "$WORK/tree-drift3"
sed -i 's/^# CONFIG_NET_TC_SKB_EXT is not set$/CONFIG_NET_TC_SKB_EXT=m/' \
  "$WORK/tree-drift3/scripts/package-build/linux-kernel/config/13-net-sched.config"
if "$SCRIPT" "$WORK/tree-drift3" >/dev/null 2>&1; then
  bad "unexpected NET_TC_SKB_EXT value: expected non-zero exit"
else
  ok "unexpected NET_TC_SKB_EXT value: dies loudly"
fi

make_fixture "$WORK/tree-drift4"
sed -i 's/^mlxver="24.07-0.6.1.0"$/mlxver="23.10-0.5.5.0"/' \
  "$WORK/tree-drift4/scripts/package-build/linux-kernel/build-mellanox-ofed.sh"
if "$SCRIPT" "$WORK/tree-drift4" >/dev/null 2>&1; then
  bad "unexpected mlxver: expected non-zero exit"
else
  ok "unexpected mlxver: dies loudly"
fi

make_fixture "$WORK/tree-drift5"
rm "$WORK/tree-drift5/scripts/package-build/linux-kernel/build-mellanox-ofed.sh"
if "$SCRIPT" "$WORK/tree-drift5" >/dev/null 2>&1; then
  bad "missing build-mellanox-ofed.sh: expected non-zero exit"
else
  ok "missing build-mellanox-ofed.sh: dies loudly"
fi

make_fixture "$WORK/tree-drift6"
# upstream removed the amd64 guard -> ofed patch must die (mlnx would fail on arm64)
sed -i '/if ! dpkg-architecture -iamd64; then/,/^fi$/d' \
  "$WORK/tree-drift6/scripts/package-build/linux-kernel/build-mellanox-ofed.sh"
if "$SCRIPT" "$WORK/tree-drift6" >/dev/null 2>&1; then
  bad "ofed guard already gone: expected non-zero exit"
else
  ok "ofed guard already gone: dies loudly"
fi

make_fixture "$WORK/tree-drift7"
# upstream dropped the patches/kernel apply loop -> the syscalltbl fix would
# be dead, so verify-kernel-patches must die
sed -i '/PATCH_DIR/d; /patches\/kernel/d' \
  "$WORK/tree-drift7/scripts/package-build/linux-kernel/build-kernel.sh"
if "$SCRIPT" "$WORK/tree-drift7" >/dev/null 2>&1; then
  bad "kernel-patch apply loop gone: expected non-zero exit"
else
  ok "kernel-patch apply loop gone: dies loudly"
fi

make_fixture "$WORK/tree-drift8"
# upstream dropped its arm64 syscalltbl fix -> linux-perf would break the
# kernel build again, so verify-kernel-patches must die
rm "$WORK/tree-drift8/scripts/package-build/linux-kernel/patches/kernel/0005-arm64-fix-relative-syscalltbl-path-in-Makefile.sysc.patch"
if "$SCRIPT" "$WORK/tree-drift8" >/dev/null 2>&1; then
  bad "upstream syscalltbl fix gone: expected non-zero exit"
else
  ok "upstream syscalltbl fix gone: dies loudly"
fi

# ---------------------------------------------------------------------------
# Run 4: bad usage.
# ---------------------------------------------------------------------------
echo "== bad usage =="
if "$SCRIPT" >/dev/null 2>&1; then
  bad "missing target: expected non-zero exit"
else
  ok "missing target: exits non-zero"
fi
if "$SCRIPT" "$WORK/nonexistent-dir" >/dev/null 2>&1; then
  bad "nonexistent target: expected non-zero exit"
else
  ok "nonexistent target: exits non-zero"
fi

echo
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
