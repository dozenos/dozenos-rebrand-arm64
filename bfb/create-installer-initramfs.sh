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

# The eMMC host driver stack is modular in our kernel. Copy the SDHCI /
# DWCMSHC / mmc-block modules (found by basename anywhere under the tree --
# they live under kernel/drivers/mmc/...) into a flat initramfs dir. Our
# build compresses modules to .ko.xz and busybox insmod cannot read xz, so
# DECOMPRESS to plain .ko here; the module signature is inside the .ko and
# our kernel (CONFIG_MODULE_SIG_KEY) trusts it, so the signed .ko still
# loads under MODULE_SIG_FORCE. HW-CHECK: if /dev/mmcblk0 never appears,
# widen this basename list.
mod_names=(mmc_core mmc_block sdhci sdhci-pltfm sdhci-of-dwcmshc
           sdhci_pltfm sdhci_of_dwcmshc cqhci)
mkdir -p "$root/lib/modules"
for name in "${mod_names[@]}"; do
  while IFS= read -r ko; do
    [ -n "$ko" ] || continue
    base=$(basename "$ko")
    case "$base" in
      *.ko.xz)  unxz  -c "$ko" > "$root/lib/modules/${base%.xz}" ;;
      *.ko.zst) zstd -dq -c "$ko" > "$root/lib/modules/${base%.zst}" ;;
      *.ko.gz)  gzip -dc "$ko" > "$root/lib/modules/${base%.gz}" ;;
      *.ko)     cp "$ko" "$root/lib/modules/$base" ;;
    esac
  done < <(find "$MODDIR" -type f \( -name "${name}.ko" -o -name "${name}.ko.*" \) 2>/dev/null)
done
echo "I: bundled modules for $KVER: $(ls "$root/lib/modules" 2>/dev/null | tr '\n' ' ')"

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

# Load the eMMC host stack. Multi-pass insmod so dependency order resolves
# itself regardless of filename order (mmc_core before sdhci before
# sdhci-of-dwcmshc, etc.). Stop when a full pass loads nothing new.
for pass in 1 2 3 4 5; do
  progress=0
  for ko in /lib/modules/*.ko; do
    [ -f "$ko" ] || continue
    if insmod "$ko" 2>/dev/null; then progress=1; mv "$ko" "$ko.done" 2>/dev/null || rm -f "$ko"; fi
  done
  [ "$progress" = 0 ] && break
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
