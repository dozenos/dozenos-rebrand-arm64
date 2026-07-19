# bfb/ — BFB packaging for BlueField-2 (plan §7)

Wrap a **fully-installed DozenOS disk image** into a `.bfb` boot stream the
host pushes over rshim (`cat dozenos-bf2.bfb > /dev/rshim0/boot`). On boot the
DPU runs a tiny installer that block-copies the image onto the eMMC and
reboots into the installed system — no interactive `install image` step.

Model: **dd a pre-installed disk image** (not bfb-build's Debian
rootfs-tarball-extract). The `dpu` flavor
(`flavors/fresh-install/dpu.toml`) already produces a complete disk
(partitions + squashfs + GRUB via `raw_image.py`), so the installer is a
plain `dd` — simpler and VyOS-correct, since VyOS is already properly
installed inside the image.

## Pieces (all here)

| File | Role |
|---|---|
| `create-installer-initramfs.sh` | Builds the installer initramfs: static busybox + eMMC host modules + the zstd-compressed disk image + an `/init` that loads the mmc stack, `dd`s the image to `/dev/mmcblk0`, and reboots. |
| `make-bfb.sh` | Packs NVIDIA's base `default.bfb` + our kernel `Image` + that installer initramfs into `dozenos-bf2.bfb` via `mlx-mkbfb` (invocation shape verified against bfb-build's `create_bfb`). |

## Inputs you must supply (board-specific — NOT bundled)

1. **`mlxbf-bootimages`** — provides `default.bfb` (NVIDIA ATF/UEFI) at
   `/lib/firmware/mellanox/boot/default.bfb`. From NVIDIA's **public** DOCA
   apt repo `https://linux.mellanox.com/public/repo/doca/` (key
   `GPG-KEY-Mellanox.pub`). **The version MUST match your BF2 board's
   firmware/BSP** — you know it, this repo doesn't. Wrong version can fail to
   boot.
2. **`mlx-mkbfb`** — the packer (Python), from NVIDIA rshim-user-space / DOCA
   tools (not in the plain Debian `rshim` package).
3. **static arm64 busybox** — Debian `busybox-static` (`/bin/busybox`).
4. **kernel `Image` + `/lib/modules/<kver>`** — extracted from the `dpu`
   qcow2 (mount it) or the `linux-image-*-dozenos_*_arm64.deb`.

## End-to-end (once you have the above)

```sh
qemu-img convert -f qcow2 -O raw dozenos-*-dpu-arm64.qcow2 disk.raw   # optional; the script also accepts qcow2
bfb/create-installer-initramfs.sh \
    --disk dozenos-*-dpu-arm64.qcow2 \
    --busybox /bin/busybox \
    --modules-dir <extracted>/lib/modules/6.18.38-dozenos \
    --kver 6.18.38-dozenos \
    --out installer.cpio.gz
bfb/make-bfb.sh \
    --mkbfb "$(which mlx-mkbfb)" \
    --base-bfb /lib/firmware/mellanox/boot/default.bfb \
    --kernel <extracted>/boot/6.18.38-dozenos/vmlinuz \
    --initramfs installer.cpio.gz \
    --out dozenos-bf2.bfb
# host side:
cat dozenos-bf2.bfb > /dev/rshim0/boot
```

## CI wiring (arm64 nightly repo)

Intended as a `workflow_dispatch` job in `dozenos-nightly-build-arm64`
parameterized by `bootimages_version` (your board's) + the release tag whose
`dpu` qcow2 to wrap. Not wired to run on every scheduled nightly: it needs
the board-specific bootimages version and can only be trusted after a
hardware pass. Wire it once the board's BSP version is known.

## !!! Needs hardware validation (plan §9.4) !!!

None of this has booted on a real BF2. `create-installer-initramfs.sh` marks
the likely first-adjust points with `HW-CHECK` (eMMC device name, module load
order, console). Validation order: host rshim → `/dev/rshim0/console` shows
UEFI → push BFB → watch the installer `dd` → first eMMC boot reaches the
DozenOS login on the rshim console (`ttyAMA1@115200`) → tmfifo SSH.
