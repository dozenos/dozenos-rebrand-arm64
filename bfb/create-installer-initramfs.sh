#!/usr/bin/env bash
#
# create-installer-initramfs.sh -- build the BF2 eMMC installer initramfs for
# the dd-a-disk-image model (plan §7). HARDWARE-VALIDATED 2026-07-19 on a real
# BlueField-2; see bfb/HARDWARE-FINDINGS.md for the full write-up.
#
# The initramfs boots on the DPU ARM cores from the BFB. Its whole job:
#   1. wait for the eMMC to appear (/dev/mmcblk0),
#   2. flash a pre-installed DozenOS disk image onto it
#      (qemu-img convert -n: allocated clusters only, zeros as BLKZEROOUT),
#   3. register a UEFI boot entry for the freshly-written ESP (efibootmgr),
#   4. reboot into the installed DozenOS.
# The disk image already has GPT + ESP + GRUB + squashfs (raw_image.py did the
# real install), so there is NO distro-aware install logic -- a plain block
# copy, which is what makes this robust for VyOS/DozenOS.
#
# Hardware facts this encodes (all confirmed on a BF2):
#  - eMMC = Synopsys DesignWare (dw_mmc-bluefield, ACPI PRP0001), NOT sdhci. In
#    the DozenOS kernel MMC_DW_BLUEFIELD is built in (=y), so /dev/mmcblk0
#    appears on its own -- no module loading needed. A modules dir may still be
#    passed as a fallback for a modular kernel.
#  - the disk image ships as qcow2; bundled qemu-img writes it out directly.
#  - after dd the old UEFI boot entries are stale (changed partition GUIDs), so
#    UEFI drops to PXE unless we add an entry -> efibootmgr creates one pointing
#    at the DozenOS ESP (partition 2, \EFI\BOOT\BOOTAA64.EFI).
#
# Layout of the produced initramfs (a gzip'd cpio):
#   /init            -- the installer (below)
#   /bin/busybox     -- static arm64 busybox
#   /usr/bin/{efibootmgr,qemu-img} + /lib/*.so* -- dynamic tools + glibc deps
#   /disk.qcow2      -- the DozenOS disk image (qcow2, compressed)
#   /lib/modules/... -- optional eMMC host .ko fallback (only if --modules-dir)
#
# Usage:
#   create-installer-initramfs.sh \
#       --disk <disk.img|disk.qcow2> \
#       --busybox <static-arm64-busybox> \
#       --out <installer-initramfs.cpio.gz> \
#       [--modules-dir <linux-image /lib/modules/<kver>>] [--kver <release>]
#
# Runs on an arm64 host (the arm64 CI runner): it copies the runner's own glibc
# for the bundled tools and apt-fetches efibootmgr/qemu-utils when absent.
set -euo pipefail

die() { printf 'create-installer-initramfs: %s\n' "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

DISK="" BUSYBOX="" OUT="" MODDIR="" KVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --disk)        DISK="${2:?}"; shift 2 ;;
    --busybox)     BUSYBOX="${2:?}"; shift 2 ;;
    --out)         OUT="${2:?}"; shift 2 ;;
    --modules-dir) MODDIR="${2:?}"; shift 2 ;;
    --kver)        KVER="${2:?}"; shift 2 ;;
    -h|--help)     sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done
for v in DISK BUSYBOX OUT; do [ -n "${!v}" ] || die "--$(echo "$v"|tr A-Z_ a-z-) required"; done
[ -n "$KVER" ] && echo "I: target kernel: $KVER"
[ -f "$DISK" ]    || die "disk image not found: $DISK"
[ -x "$BUSYBOX" ] || die "busybox not found/executable: $BUSYBOX"
need cpio; need gzip; need qemu-img; need file; need dpkg-deb

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
root="$WORK/root"
mkdir -p "$root"/{bin,sbin,proc,sys,dev,mnt,lib,usr/bin,lib/modules}

cp "$BUSYBOX" "$root/bin/busybox"; chmod +x "$root/bin/busybox"

# --- dynamic tools: efibootmgr (UEFI boot entry) + pv (dd progress) ----------
# The arm64 CI runner already has glibc; efibootmgr/pv + libefivar come from
# apt. Copy every NEEDED shared object + the dynamic loader so the tools run in
# the bare initramfs.
LIBDIR=/lib/aarch64-linux-gnu
[ -d "$LIBDIR" ] || LIBDIR=/usr/lib/aarch64-linux-gnu
fetch_tool() {
  local pkg="$1" bin="$2"
  command -v "$bin" >/dev/null 2>&1 || sudo apt-get install -y "$pkg" >/dev/null 2>&1 || true
  command -v "$bin" 2>/dev/null || true
}
EFIBM=$(fetch_tool efibootmgr efibootmgr)
QIMG=$(fetch_tool qemu-utils qemu-img)
[ -n "$EFIBM" ] || die "efibootmgr unavailable (apt-get install efibootmgr failed)"
[ -n "$QIMG" ]  || die "qemu-img unavailable (apt-get install qemu-utils failed)"

copy_with_libs() {
  local bin="$1" dst="$2"
  cp "$bin" "$dst"
  # resolve + copy each NEEDED .so and the interpreter (recurse one level via ldd)
  ldd "$bin" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | sort -u | while read -r so; do
    [ -f "$so" ] || continue
    mkdir -p "$root$(dirname "$so")"
    cp -n "$so" "$root$so" 2>/dev/null || true
  done
}
copy_with_libs "$EFIBM" "$root/usr/bin/efibootmgr"
copy_with_libs "$QIMG" "$root/usr/bin/qemu-img"
# the ELF interpreter path is /lib/ld-linux-aarch64.so.1; make sure it exists there
if [ ! -e "$root/lib/ld-linux-aarch64.so.1" ]; then
  ld=$(find "$LIBDIR" /lib -name 'ld-linux-aarch64.so.1' 2>/dev/null | head -1)
  [ -n "$ld" ] && { mkdir -p "$root/lib"; cp "$ld" "$root/lib/ld-linux-aarch64.so.1"; }
fi
echo "I: bundled efibootmgr + qemu-img with $(find "$root/lib" "$root/usr/lib" -name '*.so*' 2>/dev/null | wc -l) shared libs"

# --- optional modular-eMMC fallback -----------------------------------------
# MMC_DW_BLUEFIELD is =y in the DozenOS kernel so this is normally unused, but
# if a modules dir is given, stage the dw_mmc host stack for a modular kernel.
if [ -n "$MODDIR" ] && [ -d "$MODDIR" ]; then
  # efivarfs + vfat (+ nls deps): the DozenOS kernel builds these =m, and the
  # installer needs them for efibootmgr (efivars) and the on-ESP install log.
  for name in dw_mmc dw_mmc-pltfm dw_mmc-bluefield mmc_core mmc_block \
              efivarfs fat vfat nls_cp437 nls_iso8859-1 nls_ascii; do
    while IFS= read -r ko; do
      [ -n "$ko" ] || continue; base=$(basename "$ko")
      case "$base" in
        *.ko.xz)  unxz  -c "$ko" > "$root/lib/modules/${base%.xz}" ;;
        *.ko.zst) zstd -dq -c "$ko" > "$root/lib/modules/${base%.zst}" 2>/dev/null ;;
        *.ko.gz)  gzip -dc "$ko" > "$root/lib/modules/${base%.gz}" ;;
        *.ko)     cp "$ko" "$root/lib/modules/$base" ;;
      esac
    done < <(find "$MODDIR" -type f \( -name "${name}.ko" -o -name "${name}.ko.*" \) 2>/dev/null)
  done
  echo "I: staged fallback modules: $(ls "$root/lib/modules" 2>/dev/null | tr '\n' ' ')"
fi

# --- the disk image: ship as qcow2 ------------------------------------------
# The installer flashes with `qemu-img convert -n` straight onto the eMMC:
# only allocated clusters are written and zero regions become BLKZEROOUT
# requests, so a mostly-empty 16 GB image no longer costs 16 GB of eMMC
# writes (and minutes of dd time) per install.
if qemu-img info "$DISK" 2>/dev/null | grep -qi 'file format: qcow2'; then
  cp "$DISK" "$root/disk.qcow2"
else
  echo "I: converting raw -> compressed qcow2"
  qemu-img convert -f raw -O qcow2 -c "$DISK" "$root/disk.qcow2"
fi

cat > "$root/init" <<'INIT'
#!/bin/busybox sh
# DozenOS BlueField-2 eMMC installer (dd model, hardware-validated).
/bin/busybox --install -s /bin
mkdir -p /proc /sys /dev
mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs dev      /dev 2>/dev/null || mdev -s
export PATH=/usr/bin:/bin:/sbin
export LD_LIBRARY_PATH=/lib:/usr/lib:/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu
# /dev/console follows the last console= in the BFB boot-args (ttyAMA0, which
# may be unattached) -- broadcast every message to all consoles instead, and
# accumulate a copy for the on-ESP install log.
LOG=/install.log
say() {
  echo "$@" >> $LOG
  for c in /dev/console /dev/hvc0 /dev/ttyAMA0 /dev/ttyAMA1; do
    echo "$@" > $c 2>/dev/null
  done
}
say ""
say "=== DozenOS BlueField-2 installer ==="

# eMMC host driver is built in (dw_mmc-bluefield); load any fallback modules
# then wait for /dev/mmcblk0.
for pass in 1 2 3; do
  prog=0
  for ko in /lib/modules/*.ko; do
    [ -f "$ko" ] || continue
    insmod "$ko" 2>/dev/null && { prog=1; mv "$ko" "$ko.done" 2>/dev/null || rm -f "$ko"; }
  done
  [ "$prog" = 0 ] && break
done
TGT=/dev/mmcblk0
for i in $(seq 1 30); do [ -b "$TGT" ] && break; sleep 1; mdev -s 2>/dev/null || true; done
if [ ! -b "$TGT" ]; then
  say "E: eMMC $TGT not found. dmesg:"; say "$(dmesg | grep -iE 'mmc|dwmmc|PRP0001' | tail -20)"
  say "E: dropping to a shell."; exec /bin/busybox sh
fi

say "I: flashing DozenOS onto $TGT (this wipes it)..."
# -n: write into the existing device; allocated clusters are written, zero
# clusters are pushed down as zero-out requests instead of 16 GB of data.
qemu-img convert -n -p -f qcow2 -O raw /disk.qcow2 "$TGT" \
  || { say "E: qemu-img convert failed -- shell."; exec /bin/busybox sh; }
say "I: ===== FLASH COMPLETE ====="
# fix the backup GPT to the real (larger) eMMC end -- best effort
command -v sgdisk >/dev/null 2>&1 && sgdisk -e "$TGT" 2>/dev/null || true
sync

# Register a UEFI boot entry for the DozenOS ESP so the DPU boots it without a
# manual EFI-shell step. The DozenOS image ESP is partition 2 with the
# removable-media bootloader at \EFI\BOOT\BOOTAA64.EFI (confirmed on hardware).
# A mounted efivarfs is a hard prerequisite: the mountpoint directory exists in
# sysfs whenever EFI runtime services are up, so test /proc/mounts, not -d.
# Mirrors NVIDIA's own installer (`ubuntu/install.sh:update_efi_bootmgr` in the
# stock BFB): mount efivarfs at the point of use, drop any existing entry with
# our label so repeat installs do not pile up duplicates, create the entry, and
# verify it landed -- retrying, then falling back to wiping the boot entries,
# exactly as they do.
efivars_mount=0
if ! grep -q efivarfs /proc/mounts; then
  mount -t efivarfs none /sys/firmware/efi/efivars 2>/dev/null && efivars_mount=1
fi

if command -v efibootmgr >/dev/null 2>&1 && grep -q efivarfs /proc/mounts; then
  say "I: registering UEFI boot entry for DozenOS..."
  if efibootmgr | grep -q DozenOS; then
    efibootmgr -b "$(efibootmgr | grep DozenOS | head -1 | cut -c 5-8)" -B >/dev/null 2>&1
  fi
  add_entry() {
    efibootmgr -c -d "$TGT" -p 2 -L DozenOS -l '\EFI\BOOT\BOOTAA64.EFI' >/dev/null 2>&1
  }
  add_entry
  if ! efibootmgr | grep -q DozenOS; then
    say "W: boot entry did not stick; retrying"
    add_entry
    if ! efibootmgr | grep -q DozenOS; then
      say "W: still missing; clearing boot entries (bfbootmgr --cleanall) and retrying"
      command -v bfbootmgr >/dev/null 2>&1 && bfbootmgr --cleanall >/dev/null 2>&1
      add_entry
    fi
  fi
  if efibootmgr | grep -q DozenOS; then
    say "I: boot entry registered:"
  else
    say "E: failed to register the DozenOS boot entry:"
  fi
  say "$(efibootmgr 2>&1 | head -6)"
else
  # efivarfs registers its filesystem type only when the firmware handed the
  # kernel working EFI runtime services, so an ENODEV mount means they are
  # absent rather than that the driver is missing. NVIDIA's installer mounts it
  # successfully on this same boot path, so if we land here the difference is
  # ours -- dump what the kernel actually saw.
  say "E: efivarfs unavailable; cannot register a boot entry"
  say "D: /proc/filesystems efi: $(grep -c efi /proc/filesystems)"
  say "D: /sys/firmware/efi: $(ls /sys/firmware/efi 2>&1 | tr '\n' ' ')"
  say "D: cmdline: $(cat /proc/cmdline)"
  say "D: dmesg efi:"
  say "$(dmesg | grep -iE 'efi|uefi' | head -20)"
fi
[ "$efivars_mount" = 1 ] && umount /sys/firmware/efi/efivars 2>/dev/null

# Drop the install log onto the freshly-written ESP so it is readable from the
# installed system / EFI shell even when no console was attached.
mdev -s 2>/dev/null || true
if mount -t vfat "${TGT}p2" /mnt 2>/dev/null; then
  dmesg | tail -40 >> $LOG 2>/dev/null || true
  cp $LOG /mnt/dozenos-install.log 2>/dev/null || true
  umount /mnt
  say "I: install log written to ESP:/dozenos-install.log"
else
  say "W: could not mount ${TGT}p2; install log not persisted"
fi

sync
say "I: done. Rebooting into installed DozenOS in 5s."
sleep 5
reboot -f
INIT
chmod +x "$root/init"

( cd "$root" && find . | cpio -o -H newc --quiet | gzip -1 ) > "$OUT"
echo "I: wrote installer initramfs: $OUT ($(du -h "$OUT" | cut -f1))"
