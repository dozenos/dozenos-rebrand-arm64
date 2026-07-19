# dozenos-rebrand-arm64

arm64/DPU patch layer for DozenOS. Applied by `dozenos-nightly-build-arm64`
CI on top of an already-rebranded `dozenos/dozenos-build` checkout
(`rolling`). Implements `BF2-FLOWTABLE-OFFLOAD-PLAN.md` §6 (kernel config +
OFED script) and carries the arm64 build flavors and BFB packaging tooling.

This repo is deliberately thin: the full VyOS→DozenOS rebrand already
happened in `dozenos-rebrand` (mode-B mirrors). Everything here is
arm64/BlueField-specific delta only, and none of it is ever pushed back to
the `dozenos-build` mirror — the amd64 pipeline (`dozenos-rebrand`,
`dozenos-nightly-build`, `dozenos-deb-cache`) is untouched by design.

## Pipeline position

```
dozenos/dozenos-build @ rolling   (checkout, already rebranded)
        |
        v
apply-patches.sh <tree>           (this repo; idempotent, drift-fatal)
        |
        v  local throwaway commit  (so deb-cache keys see patched content)
        |
arm64 package + image build       (dozenos-nightly-build-arm64, native
                                   arm64 runners, ghcr arm64 container)
        |
        v
BFB wrap (bfb/)                   (image -> .bfb for rshim push to BF2)
```

## Contents

| Path | Purpose |
|---|---|
| `apply-patches.sh` | Entry point; runs every `patches/` script in order |
| `patches/kernel-config-bf2-offload.sh` | Plan §6.1–6.3: un-cut the mlx5 TC-offload dependency chain (`NET_ACT_CT`, `NET_TC_SKB_EXT`, `NF_FLOW_TABLE_PROCFS`) and enable `MLX5_CLS_ACT`/`MLX5_TC_CT`/`MLX5_TC_SAMPLE` + the BlueField SoC drivers (mlxbf-gige, tmfifo, bootctl, pmc, gpio, i2c, pwr, EDAC, eMMC DWCMSHC) in the arm64 defconfig |
| `patches/ofed-25-01.sh` | Plan §6.4: MLNX_OFED 25.01 port of the old-environment changes. Fallback-only — the arm64 nightly does not build the mlnx unit; in-tree mlx5 (kernel 6.18) is the main driver per plan §5 |
| `flavors/` | arm64 build flavors (`DOZENOS_BUILD_FLAVORS_DIR` contract, same as `dozenos-rebrand/flavors/`) |
| `bfb/` | Plan §7: wrap a built image into a `.bfb` boot stream for rshim delivery |
| `test/` | Network-free test suite (`test/test-apply-patches.sh`) |

## Verifying the kernel config (plan §9.1)

The merge test needs only a kernel source tree (pure kconfig processing, no
build, any host arch):

```sh
cd <linux-6.18.x>
ARCH=arm64 scripts/kconfig/merge_config.sh -m \
    <patched-tree>/scripts/package-build/linux-kernel/config/arm64/dozenos_defconfig \
    <patched-tree>/scripts/package-build/linux-kernel/config/*.config
ARCH=arm64 make alldefconfig KCONFIG_ALLCONFIG=.config
grep -E "MLX5_CLS_ACT|MLX5_TC_CT|MLXBF|DWCMSHC" .config
```

CI runs the equivalent gate against the built kernel `.deb` (plan §9.0) so a
config regression fails the run minutes in, not after a BF2 flash cycle.
