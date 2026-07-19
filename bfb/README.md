# bfb/ — BFB packaging for BlueField-2 (plan §7)

Wrap a built DozenOS arm64 image into a `.bfb` boot stream the host pushes
over rshim (`cat dozenos-bf2.bfb > /dev/rshim0/boot`). Reference flow:
[Mellanox/bfb-build](https://github.com/Mellanox/bfb-build) — its
`create_bfb` script packs a distro rootfs + installer initramfs with the
`mlx-mkbfb` tool on top of NVIDIA's `mlxbf-bootimages` (ATF/UEFI).

## Status: scaffold — not yet wired into the nightly

`make-bfb.sh` assembles a `.bfb` from parts you already have. It becomes a
`dozenos-nightly-build-arm64` job only after the open points below are
resolved against real hardware (first CI image + a BF2 flash cycle,
plan §9.4).

## Inputs `make-bfb.sh` expects

Invocation shape verified against bfb-build's `debian/12/create_bfb`: the
base `default.bfb` is re-packed with `--image`/`--initramfs`/`--capsule`/
`--boot-args-v0`/`--boot-args-v2`.

| Part | Where it comes from |
|---|---|
| `mlx-mkbfb` | script from the bfb-build repo (or the `mlxbf-bootimages` deb) |
| base `default.bfb` (NVIDIA ATF/UEFI) | `mlxbf-bootimages` package, `/lib/firmware/mellanox/boot/default.bfb` — version must match the BF2 board firmware |
| capsule (optional) | same package, `boot/capsule/boot_update2.cap` |
| kernel image (`vmlinuz`) | our built kernel deb |
| installer initramfs | to-be-authored: embeds the OS payload (the nightly's image artifact), finds the eMMC (`CONFIG_MMC_SDHCI_OF_DWCMSHC`) and writes it — create_bfb's model, where the payload rides inside the initramfs, not as a separate mkbfb argument |

## Open points (from plan §7 — resolve before wiring the CI job)

- Which `mlxbf-bootimages` version matches our BF2 board firmware.
- Whether `create_bfb`/`mlx-mkbfb` from bfb-build are reused directly
  (licence allows it) or via the deb.
- Installer initramfs authoring: eMMC discovery, `dd` the raw image (or
  extract the ISO squashfs like the old flow), GRUB/UEFI boot entries on
  the eMMC matching the DozenOS layout.
- tmfifo console settings for the installer so the install is watchable
  from the host (`screen /dev/rshim0/console 115200`).

## Test procedure

Plan §9.4, in order: host rshim install → `/dev/rshim0/` nodes → console
smoke test → push BFB → first eMMC boot → tmfifo network
(`192.168.100.1/30` host, `.2` DPU) → OOB fallback (mlxbf_gige). Only then
the §9.2 offload decision tree.
