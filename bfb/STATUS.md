# BF2 BFB / arm64 boot — current status (2026-07-20)

Snapshot of where the BlueField-2 bring-up stands. Companion to
[HARDWARE-FINDINGS.md](HARDWARE-FINDINGS.md) (the deep technical write-up).

## Verified on real BF2 hardware (2026-07-19)

- BFB packaging, rshim push, `bfb-install` — work.
- Installer initramfs loads the eMMC driver, `dd`s the DozenOS disk onto
  `/dev/mmcblk0`, prints **FLASH COMPLETE**, reboots. ✅
- After reboot, via UEFI **EFI shell**, our DozenOS **GRUB** loads and hands off
  to our DozenOS kernel (`HW watchdog disabled`). ✅
- What still failed on hardware: the installed kernel then hung mounting root,
  because that (old) kernel lacked `CONFIG_MMC_DW` — the eMMC driver. Root cause
  fixed in the kernel config (below); needs the rebuilt kernel to re-verify.

## Root causes found + fixed

| Problem | Fix | Where |
|---|---|---|
| eMMC not found (wrong driver) | BF2 eMMC = `dw_mmc-bluefield` (ACPI PRP0001), **not** sdhci. Build `MMC/MMC_BLOCK/MMC_DW/MMC_DW_PLTFM/MMC_DW_BLUEFIELD =y` | `patches/kernel-config-bf2-offload.sh` (new `force_opt` helper) |
| gzip vmlinuz rejected by UEFI | embed uncompressed arm64 Image | `bfb.yml` extract step |
| busybox has no zstd | ship disk gzip'd, `zcat\|pv\|dd` | `bfb/create-installer-initramfs.sh` |
| UEFI drops to PXE after dd (stale boot entries) | `efibootmgr -c -d mmcblk0 -p 2 -l \EFI\BOOT\BOOTAA64.EFI` | installer initramfs |
| our-BFB firmware downgrade | pin default.bfb to DOCA 4.15.0 (debian13/arm64-dpu) | `bfb.yml` |
| CI gate failed on MLXBF_PTM/IPMB | dropped (unresolved in 6.18, non-boot-critical) | kernel patch |

## CI pipeline (now self-contained, "正宗")

```
nightly.yml  ── builds MMC_DW kernel + dpu qcow2, publishes release
     │ workflow_run (on success)
bfb.yml      ── wraps the qcow2: OUR DozenOS kernel + dd installer
                (efibootmgr + pv), 4.15.0 default.bfb base
     ▼
release asset: dozenos-<ver>-bf2.bfb   (bootable BFB)
```

## In flight

- **nightly run 29712072349** (re-triggered after dropping PTM/IPMB) — building
  `linux-kernel` with `MMC_DW_BLUEFIELD=y`. ~1h15m. On success bfb.yml auto-runs.
- Being watched by a background monitor (relaunched each 10-min window).

## Commits (all pushed)

- rebrand-arm64: `force_opt` + MMC=y stack; drop PTM/IPMB; hardware-validated
  `create-installer-initramfs.sh` (dw_mmc/gzip/pv/efibootmgr); HARDWARE-FINDINGS.md.
- nightly-build-arm64: `bfb.yml` workflow_run auto-chain, 4.15 base, efibootmgr/pv,
  DozenOS kernel; kernel-config gate includes `force_opt`.

## Pending / next (not yet done)

1. **Confirm the rebuilt kernel boots to login** on eMMC (MMC_DW + efibootmgr +
   auto-boot end-to-end — the pieces are proven separately, not yet together).
2. Untested-together risks: our kernel as the *installer* kernel (proven only to
   kernel-handoff), the efibootmgr auto-entry, full boot-to-login.
3. **Installed-system console visibility**: DozenOS cmdline is `console=hvc0`
   with no earlycon → early boot is silent until hvc0. Add earlycon for debug.
4. **OFED on arm64** — deferred next phase. OFED *does* support arm64 (user
   confirmed); the current amd64-only guard just needs removing + build deps
   wired. Needed for VPP/DPDK/RDMA/DOCA, not for basic boot.
5. Sign/publish the .bfb (currently uploaded unsigned; iso/qcow2 are signed).

## Test rig (bf1 powered off)

x86-64 staging VM `bf1` (172.30.0.138) talked to the BF2 via rshim; BMC host
console `ssh -p 2200 root@<bmc>` (root/0penBmc). Rig is off now — all further
work is in CI until hardware is available again.
