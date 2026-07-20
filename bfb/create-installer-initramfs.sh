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
#    the DozenOS kernel MMC_DW_BLUEFIELD is built in (=y) so /dev/mmcblk0
#    appears on its own, but EXT4/VFAT/SQUASHFS/LOOP are all =m -- hence the
#    full module tree plus modprobe rather than a hand-picked insmod list.
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
#   /lib/modules/<kver>/ -- the full module tree + depmod metadata, so the
#                           installer can modprobe by name (only if --modules-dir)
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

# --- dynamic tools: efibootmgr (UEFI boot entry) + qemu-img (flashing) -------
# The arm64 CI runner already has glibc; efibootmgr + libefivar come from
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
SGDISK=$(fetch_tool gdisk sgdisk)
PARTED=$(fetch_tool parted parted)
RESIZEFS=$(fetch_tool e2fsprogs resize2fs)
E2FSCK=$(fetch_tool e2fsprogs e2fsck)
[ -n "$EFIBM" ]   || die "efibootmgr unavailable (apt-get install efibootmgr failed)"
[ -n "$QIMG" ]    || die "qemu-img unavailable (apt-get install qemu-utils failed)"
[ -n "$SGDISK" ]  || die "sgdisk unavailable (apt-get install gdisk failed)"
[ -n "$PARTED" ]  || die "parted unavailable (apt-get install parted failed)"
[ -n "$RESIZEFS" ] || die "resize2fs unavailable (apt-get install e2fsprogs failed)"
[ -n "$E2FSCK" ]  || die "e2fsck unavailable (apt-get install e2fsprogs failed)"

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
copy_with_libs "$SGDISK" "$root/usr/bin/sgdisk"
copy_with_libs "$PARTED" "$root/usr/bin/parted"
copy_with_libs "$RESIZEFS" "$root/usr/bin/resize2fs"
copy_with_libs "$E2FSCK" "$root/usr/bin/e2fsck"
# the ELF interpreter path is /lib/ld-linux-aarch64.so.1; make sure it exists there
if [ ! -e "$root/lib/ld-linux-aarch64.so.1" ]; then
  ld=$(find "$LIBDIR" /lib -name 'ld-linux-aarch64.so.1' 2>/dev/null | head -1)
  [ -n "$ld" ] && { mkdir -p "$root/lib"; cp "$ld" "$root/lib/ld-linux-aarch64.so.1"; }
fi
echo "I: bundled efibootmgr + qemu-img + sgdisk/parted/resize2fs with $(find "$root/lib" "$root/usr/lib" -name '*.so*' 2>/dev/null | wc -l) shared libs"

# --- kernel modules ----------------------------------------------------------
# Stage the WHOLE module tree plus depmod metadata, so the installer can
# `modprobe` anything by name and get its dependencies loaded in the right
# order. Curating a list and insmod'ing it does not work: insmod resolves
# nothing, so e.g. ext4 fails with "Unknown symbol jbd2_*" unless jbd2, mbcache
# and crc16 happen to be loaded first -- which an alphabetical loop gets wrong.
#
# Modules are decompressed on the way in: whether busybox's modprobe can read
# compressed modules depends on how that busybox was built, and a plain .ko
# tree removes the question.
if [ -n "$MODDIR" ] && [ -d "$MODDIR" ]; then
  [ -n "$KVER" ] || die "--kver is required together with --modules-dir"
  need depmod
  dstmod="$root/lib/modules/$KVER"
  mkdir -p "$dstmod"
  ( cd "$MODDIR" && find . -type d -print0 | xargs -0 -I{} mkdir -p "$dstmod/{}" )
  ( cd "$MODDIR" && find . -type f | while IFS= read -r f; do
      case "$f" in
        *.ko.xz)  unxz    -c "$f" > "$dstmod/${f%.xz}"  ;;
        *.ko.zst) zstd -dq -c "$f" > "$dstmod/${f%.zst}" ;;
        *.ko.gz)  gzip   -dc "$f" > "$dstmod/${f%.gz}"  ;;
        *)        cp -a "$f" "$dstmod/$f" ;;
      esac
    done )
  depmod -b "$root" "$KVER"
  echo "I: staged $(find "$dstmod" -name '*.ko' | wc -l) kernel modules ($(du -sh "$dstmod" | cut -f1)) + depmod metadata"
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

# The full module tree with depmod metadata is in the initramfs, so name what
# the installer needs and let modprobe pull in the dependencies. The eMMC host
# driver is =y in the DozenOS kernel; the rest (ext4 for the root partition,
# vfat for the ESP, efivarfs for efibootmgr) are =m and each drag in several
# others -- jbd2/mbcache/crc16 for ext4, the nls charsets for vfat.
# nls_* are needed explicitly: the kernel autoloads a vfat charset through
# /sbin/modprobe, which does not exist in this initramfs, so mounting the ESP
# fails with EINVAL unless the charsets are already resident.
for m in dw_mmc-bluefield mmc_block ext4 vfat nls_cp437 nls_iso8859-1 nls_ascii efivarfs; do
  modprobe "$m" 2>/dev/null || say "W: modprobe $m failed"
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
# The image is sized for the smallest eMMC we support, so on a bigger card its
# GPT describes only the first 16 GB -- the kernel says so directly
# ("GPT: 33554431 != 81494015"). Move the backup header to the true end of the
# disk so the tail becomes addressable.
sgdisk -e "$TGT" >/dev/null 2>&1 || true
sync
# The kernel enumerated the partitions of whatever OS was on the eMMC before
# this install, so ${TGT}p* still describe the OLD layout and would mount the
# wrong offsets. Force a re-read of the table we just wrote.
blockdev --rereadpt "$TGT" 2>/dev/null || true
mdev -s 2>/dev/null || true
for i in $(seq 1 10); do [ -b "${TGT}p2" ] && break; sleep 1; mdev -s 2>/dev/null || true; done

# --- grow the root filesystem into the rest of the eMMC ----------------------
# Extended IN PLACE: `parted resizepart` only rewrites partition 3's end
# sector, so its start, its partition GUID and every data block stay exactly
# where they are. Deleting and recreating the partition would also work (that
# is what growpart does) but stakes the data on reproducing the start sector
# byte-for-byte, and there is no reason to take that risk.
grow_root() {
  local out
  out=$(parted -s "$TGT" resizepart 3 100% 2>&1) \
    || { say "W: parted resizepart failed ($out); root stays at its image size"; return 1; }
  blockdev --rereadpt "$TGT" 2>/dev/null || true
  mdev -s 2>/dev/null || true
  for i in $(seq 1 10); do [ -b "${TGT}p3" ] && break; sleep 1; mdev -s 2>/dev/null || true; done
  # resize2fs refuses a filesystem that has not been checked since its last
  # mount. Use -f -y, not -p: preen mode gives up on anything it considers
  # unexpected, and its exit status is easy to mistake for success. Report what
  # it said -- swallowing this output once already hid why resize2fs then
  # refused to run.
  fsck_out=$(e2fsck -f -y "${TGT}p3" 2>&1); fsck_rc=$?
  # 0 = clean, 1 = errors corrected; anything else means it could not do its job
  if [ "$fsck_rc" -gt 1 ]; then
    say "W: e2fsck rc=$fsck_rc: $(echo "$fsck_out" | tail -2)"
  fi
  # -f is required here, and it is not skipping the safety check. resize2fs
  # refuses when s_lastcheck < s_mtime, and the DPU has no usable clock during
  # install -- it dates files to 1980, so the check e2fsck just recorded looks
  # older than the image's own mtime no matter how many times it runs. We ran
  # e2fsck immediately above and inspected its result, so force the resize.
  out=$(resize2fs -f "${TGT}p3" 2>&1) \
    || { say "W: resize2fs failed ($out); e2fsck said: $(echo "$fsck_out" | tail -2)"; return 1; }
  say "I: root grown -- $(echo "$out" | tail -1)"
}
grow_root || true

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
esp_err=$(mount -t vfat "${TGT}p2" /mnt 2>&1)
if [ -z "$esp_err" ] && mountpoint -q /mnt 2>/dev/null || mount | grep -q "${TGT}p2"; then
  dmesg | tail -40 >> $LOG 2>/dev/null || true
  cp $LOG /mnt/dozenos-install.log 2>/dev/null || true
  umount /mnt
  say "I: install log written to ESP:/dozenos-install.log"
else
  say "W: could not mount ${TGT}p2 ($esp_err); install log not persisted"
fi

sync
say "I: done. Rebooting into installed DozenOS in 5s."
sleep 5
reboot -f
INIT
chmod +x "$root/init"

( cd "$root" && find . | cpio -o -H newc --quiet | gzip -1 ) > "$OUT"
echo "I: wrote installer initramfs: $OUT ($(du -h "$OUT" | cut -f1))"
