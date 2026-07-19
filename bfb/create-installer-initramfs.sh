#!/usr/bin/env bash
#
# create-installer-initramfs.sh -- build the BF2 eMMC installer initramfs for
# the dd-a-disk-image model (plan §7).
#
# The initramfs is what boots on the DPU ARM cores from the BFB. Its whole
# job: find the eMMC, block-copy a pre-installed DozenOS disk image onto it,
# then reboot into the installed system. Because the disk image already has
# partitions + squashfs + GRUB (raw_image.py did the real install), there is
# NO VyOS-aware install logic here -- it is a plain `dd`, which is why this
# model is simpler and more robust for VyOS than bfb-build's Debian
# rootfs-tarball-extract installer.
#
# Layout of the produced initramfs (a gzip'd cpio):
#   /init                 -- the installer (below)
#   /bin/busybox          -- static arm64 busybox (all shell utils via applets)
#   /disk.img.zst         -- the DozenOS disk image, zstd-compressed
#   /lib/modules/...       -- the eMMC host driver .ko's (MMC_SDHCI_OF_DWCMSHC
#                            and deps are =m in our kernel, so the installer
#                            must load them before /dev/mmcblk0 appears)
#
# !!! UNVALIDATED ON HARDWARE !!! Every step here is derived from the BF2
# BSP docs + bfb-build, not from a real BF2 boot. The most likely things to
# adjust on first hardware run (plan §9.4): the eMMC device name
# (/dev/mmcblk0 vs mmcblk1), the exact module load order, and the console
# device. Search for HW-CHECK markers.
#
# Usage:
#   create-installer-initramfs.sh \
#       --disk <disk.img|disk.qcow2> \
#       --busybox <static-arm64-busybox> \
#       --modules-dir <extracted linux-image /lib/modules/<kver>> \
#       --kver <kernel release, e.g. 6.18.38-dozenos> \
#       --out <installer-initramfs.cpio.gz>
set -euo pipefail

die() { printf 'create-installer-initramfs: %s\n' "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

DISK="" BUSYBOX="" MODDIR="" KVER="" OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --disk)        DISK="${2:?}"; shift 2 ;;
    --busybox)     BUSYBOX="${2:?}"; shift 2 ;;
    --modules-dir) MODDIR="${2:?}"; shift 2 ;;
    --kver)        KVER="${2:?}"; shift 2 ;;
    --out)         OUT="${2:?}"; shift 2 ;;
    -h|--help)     sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done
for v in DISK BUSYBOX MODDIR KVER OUT; do [ -n "${!v}" ] || die "--$(echo "$v"|tr A-Z_ a-z-) required"; done
[ -f "$DISK" ]    || die "disk image not found: $DISK"
[ -x "$BUSYBOX" ] || die "busybox not found/executable: $BUSYBOX"
[ -d "$MODDIR" ]  || die "modules dir not found: $MODDIR"
need zstd; need cpio; need gzip; need qemu-img; need file

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
root="$WORK/root"
mkdir -p "$root"/{bin,sbin,proc,sys,dev,mnt,lib/modules}

cp "$BUSYBOX" "$root/bin/busybox"
chmod +x "$root/bin/busybox"

# The eMMC host driver stack is modular in our kernel -- copy the SDHCI /
# DWCMSHC / mmc-block modules (and their explicit deps) into the initramfs.
# HW-CHECK: if /dev/mmcblk0 never appears, widen this list or check depmod.
mods=(
  drivers/mmc/host/sdhci.ko drivers/mmc/host/sdhci-pltfm.ko
  drivers/mmc/host/sdhci-of-dwcmshc.ko
  drivers/mmc/core/mmc_block.ko drivers/mmc/core/mmc_core.ko
)
mkdir -p "$root/lib/modules/$KVER"
for m in "${mods[@]}"; do
  # modules may be .ko or .ko.xz (our build compresses); copy whatever exists
  for cand in "$MODDIR/$m" "$MODDIR/$m.xz" "$MODDIR/$m.zst" "$MODDIR/$m.gz"; do
    if [ -f "$cand" ]; then
      mkdir -p "$root/lib/modules/$KVER/$(dirname "$m")"
      cp "$cand" "$root/lib/modules/$KVER/$(dirname "$m")/"
    fi
  done
done
# modules.dep so modprobe resolves deps (best-effort; init also insmods directly)
[ -f "$MODDIR/modules.dep" ] && cp "$MODDIR/modules.dep" "$root/lib/modules/$KVER/" || true

# Normalize the disk to a raw stream, then zstd-compress it into the initramfs.
if file --brief --mime-type "$DISK" | grep -q 'qemu\|octet' && qemu-img info "$DISK" 2>/dev/null | grep -qi 'file format: qcow2'; then
  echo "I: converting qcow2 -> raw"
  qemu-img convert -f qcow2 -O raw "$DISK" "$WORK/disk.raw"
  SRC="$WORK/disk.raw"
else
  SRC="$DISK"
fi
echo "I: zstd-compressing the disk image into the initramfs"
zstd -q -19 --long=27 -T0 -o "$root/disk.img.zst" "$SRC"

cat > "$root/init" <<'INIT'
#!/bin/busybox sh
# DozenOS BF2 eMMC installer (dd model). UNVALIDATED ON HARDWARE.
/bin/busybox --install -s /bin
mkdir -p /proc /sys /dev
mount -t proc  proc  /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs dev /dev 2>/dev/null || mdev -s

echo
echo "=== DozenOS BlueField-2 installer ==="

# Load the eMMC host stack (modular in our kernel).
for ko in $(find /lib/modules -name '*.ko*' 2>/dev/null); do
  insmod "$ko" 2>/dev/null || true
done

# HW-CHECK: eMMC device. BF2 eMMC is normally /dev/mmcblk0. Wait for it.
TGT=/dev/mmcblk0
for i in $(seq 1 30); do [ -b "$TGT" ] && break; sleep 1; mdev -s 2>/dev/null || true; done
if [ ! -b "$TGT" ]; then
  echo "E: eMMC $TGT not found -- dropping to a shell for diagnosis."
  exec /bin/busybox sh
fi

echo "I: flashing DozenOS onto $TGT (this wipes it)..."
if zstdcat /disk.img.zst | dd of="$TGT" bs=4M conv=fsync 2>/dev/null; then
  echo "I: flash complete."
else
  echo "E: dd failed -- shell." ; exec /bin/busybox sh
fi

# GPT was written for the image's own disk size; fix the backup GPT header to
# the real eMMC end so firmware/UEFI is happy on a larger eMMC. Best-effort.
command -v sgdisk >/dev/null 2>&1 && sgdisk -e "$TGT" 2>/dev/null || true

sync
echo "I: done. Rebooting into the installed system in 5s."
sleep 5
reboot -f
INIT
chmod +x "$root/init"

( cd "$root" && find . | cpio -o -H newc --quiet | gzip -9 ) > "$OUT"
echo "I: wrote installer initramfs: $OUT ($(du -h "$OUT" | cut -f1))"
