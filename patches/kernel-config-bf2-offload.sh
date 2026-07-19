#!/usr/bin/env bash
#
# kernel-config-bf2-offload.sh -- enable nftables flowtable hardware offload
# (mlx5 TC offload path) and the BlueField-2 SoC drivers in the arm64 kernel
# config. Implements BF2-FLOWTABLE-OFFLOAD-PLAN.md §6.1-6.3.
#
# Root cause being fixed: the stock kernel config cuts the mlx5 TC-offload
# dependency chain --
#   MLX5_CLS_ACT depends on MLX5_ESWITCH && NET_CLS_ACT && NET_TC_SKB_EXT
#   MLX5_TC_CT   depends on MLX5_CLS_ACT && NF_FLOW_TABLE && NET_ACT_CT
# -- because 13-net-sched.config disables NET_ACT_CT and NET_TC_SKB_EXT.
# With MLX5_CLS_ACT=n the representor path stubs ndo_setup_tc(TC_SETUP_FT)
# to -EOPNOTSUPP and a `flags offload` flowtable cannot bind.
#
# The config fragments are merged ON TOP of the defconfig
# (build-kernel.sh: defconfig is the base, config/*.config override it),
# so the fragment lines MUST be patched -- fixing only the defconfig would
# be silently overridden.
#
# Only the arm64 defconfig is patched: this repo feeds the arm64 pipeline
# exclusively and the amd64 stream must stay untouched.
#
# Idempotent; dies loudly when a file has neither the expected upstream
# form nor the patched form (upstream drift -- re-review by hand).
#
# Usage:
#   kernel-config-bf2-offload.sh <dozenos-build-tree>
set -euo pipefail

die() { printf 'kernel-config-bf2-offload: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <dozenos-build-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

KCFG="$TARGET/scripts/package-build/linux-kernel/config"
[ -d "$KCFG" ] || die "kernel config dir not found (upstream drift?): $KCFG"

NET_SCHED="$KCFG/13-net-sched.config"
NETFILTER="$KCFG/20-netfilter.config"
DEFCONFIG="$KCFG/arm64/dozenos_defconfig"
for f in "$NET_SCHED" "$NETFILTER" "$DEFCONFIG"; do
  [ -f "$f" ] || die "expected file not found (upstream drift?): $f"
done

# enable_opt <file> <OPTION> <y|m>: flip an existing "# CONFIG_X is not set"
# line. The option MUST already be present in one form or the other -- a
# completely absent option means upstream restructured the file.
enable_opt() {
  local f="$1" opt="$2" val="$3" base
  base=${f##*/}
  if grep -q "^CONFIG_${opt}=${val}\$" "$f"; then
    echo "already enabled (idempotent no-op): ${opt}=${val} [$base]"
  elif grep -q "^CONFIG_${opt}=" "$f"; then
    die "CONFIG_${opt} has an unexpected value in $base -- re-review by hand"
  elif grep -q "^# CONFIG_${opt} is not set\$" "$f"; then
    sed -i "s|^# CONFIG_${opt} is not set\$|CONFIG_${opt}=${val}|" "$f"
    echo "enabled: ${opt}=${val} [$base]"
  else
    die "CONFIG_${opt} not found in any form in $base (upstream drift) -- re-review by hand"
  fi
}

# add_opt <file> <OPTION> <y|m>: set an option that is expected to be ABSENT
# today (hidden while its dependencies are unmet, e.g. MLX5_CLS_ACT before
# NET_TC_SKB_EXT=y). Appends when absent; also accepts a later-appearing
# "is not set" line. Position in the file is irrelevant: the defconfig is
# kconfig input, resolved by merge_config.sh + alldefconfig.
add_opt() {
  local f="$1" opt="$2" val="$3" base
  base=${f##*/}
  if grep -q "^CONFIG_${opt}=${val}\$" "$f"; then
    echo "already set (idempotent no-op): ${opt}=${val} [$base]"
  elif grep -q "^CONFIG_${opt}=" "$f"; then
    die "CONFIG_${opt} has an unexpected value in $base -- re-review by hand"
  elif grep -q "^# CONFIG_${opt} is not set\$" "$f"; then
    sed -i "s|^# CONFIG_${opt} is not set\$|CONFIG_${opt}=${val}|" "$f"
    echo "enabled: ${opt}=${val} [$base]"
  else
    printf 'CONFIG_%s=%s\n' "$opt" "$val" >> "$f"
    echo "appended: ${opt}=${val} [$base]"
  fi
}

# require_opt <file> <regex>: dependency sanity -- these must already be on
# in the defconfig for the options below to resolve (plan §6.3 dependency
# table). A miss means upstream changed the base config; re-review.
require_opt() {
  grep -q "^$2\$" "$1" || die "prerequisite '$2' missing in ${1##*/} (upstream drift) -- re-review by hand"
}

require_opt "$DEFCONFIG" 'CONFIG_MLX5_ESWITCH=y'
require_opt "$DEFCONFIG" 'CONFIG_MLX5_BRIDGE=y'
require_opt "$DEFCONFIG" 'CONFIG_MMC_SDHCI_PLTFM=m'
require_opt "$DEFCONFIG" 'CONFIG_VIRTIO_CONSOLE=y'
require_opt "$DEFCONFIG" 'CONFIG_VIRTIO_NET=m'
require_opt "$DEFCONFIG" 'CONFIG_HWMON=y'
require_opt "$DEFCONFIG" 'CONFIG_EDAC=y'
require_opt "$NETFILTER" 'CONFIG_NF_FLOW_TABLE=m'

# §6.1 -- un-cut the TC offload dependency chain (shared fragments, but only
# the arm64 pipeline ever consumes this patched tree).
enable_opt "$NET_SCHED" NET_ACT_CT m
enable_opt "$NET_SCHED" NET_TC_SKB_EXT y
enable_opt "$NETFILTER" NF_FLOW_TABLE_PROCFS y

# §6.2 -- write the mlx5 offload options explicitly (default y once the
# chain above is un-cut; explicit so a regression is grep-visible).
add_opt "$DEFCONFIG" MLX5_CLS_ACT y
add_opt "$DEFCONFIG" MLX5_TC_CT y
add_opt "$DEFCONFIG" MLX5_TC_SAMPLE y

# §6.3 -- BlueField SoC drivers (all upstream in 6.18; replaces the old
# hand-built module debs). MELLANOX_PLATFORM is the menuconfig gate hiding
# the whole drivers/platform/mellanox submenu plus the GPIO/pinctrl/I2C/
# EDAC BlueField entries; without it every option below stays invisible
# (verified against linux-6.18.38 Kconfig). POWER_MLXBF is 6.18's name for
# the plan's PWR_MLXBF (drivers/power/reset/Kconfig).
# GPIO_MLXBF3/PINCTRL_MLXBF3 are BF3 prep, added in the same pass per the
# plan.
add_opt "$DEFCONFIG" MELLANOX_PLATFORM y
enable_opt "$DEFCONFIG" MLXBF_GIGE m
enable_opt "$DEFCONFIG" MMC_SDHCI_OF_DWCMSHC m
add_opt "$DEFCONFIG" MLXBF_TMFIFO m
add_opt "$DEFCONFIG" MLXBF_BOOTCTL m
add_opt "$DEFCONFIG" MLXBF_PMC m
add_opt "$DEFCONFIG" GPIO_MLXBF2 m
add_opt "$DEFCONFIG" GPIO_MLXBF3 m
add_opt "$DEFCONFIG" PINCTRL_MLXBF3 m
add_opt "$DEFCONFIG" I2C_MLXBF m
add_opt "$DEFCONFIG" POWER_MLXBF m
add_opt "$DEFCONFIG" EDAC_BLUEFIELD m

echo "kernel-config-bf2-offload: done"
