#!/usr/bin/env bash
#
# make-bfb.sh -- assemble a BlueField-2 .bfb boot stream from prebuilt
# parts (plan §7). Thin, explicit wrapper over mlx-mkbfb, matching the
# invocation shape of bfb-build's create_bfb (debian/12): a base
# default.bfb (NVIDIA ATF/UEFI, from the mlxbf-bootimages package) is
# re-packed with our kernel and an installer initramfs. The OS payload is
# NOT a separate argument -- create_bfb embeds the rootfs archive inside
# the installer initramfs, whose init writes it onto the eMMC; authoring
# that initramfs is the open point tracked in README.md.
#
# Usage:
#   make-bfb.sh --mkbfb <mlx-mkbfb> --base-bfb <default.bfb> \
#               --kernel <vmlinuz> --initramfs <installer-initramfs> \
#               --out <dozenos-bf2.bfb> \
#               [--capsule <boot_update2.cap>] [--boot-args <file>]
set -euo pipefail

die() { printf 'make-bfb: %s\n' "$*" >&2; exit 2; }

MKBFB="" BASE_BFB="" KERNEL="" INITRAMFS="" OUT="" CAPSULE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mkbfb)     MKBFB="${2:-}"; shift 2 ;;
    --base-bfb)  BASE_BFB="${2:-}"; shift 2 ;;
    --kernel)    KERNEL="${2:-}"; shift 2 ;;
    --initramfs) INITRAMFS="${2:-}"; shift 2 ;;
    --out)       OUT="${2:-}"; shift 2 ;;
    --capsule)   CAPSULE="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

for req in MKBFB BASE_BFB KERNEL INITRAMFS OUT; do
  [ -n "${!req}" ] || die "--$(echo "$req" | tr '[:upper:]_' '[:lower:]-') is required"
done
[ -x "$MKBFB" ] || die "mlx-mkbfb not executable: $MKBFB"
[ -f "$BASE_BFB" ] || die "base default.bfb not found: $BASE_BFB (from the mlxbf-bootimages package -- version must match the board firmware, see README.md)"
[ -f "$KERNEL" ] || die "kernel image not found: $KERNEL"
[ -f "$INITRAMFS" ] || die "installer initramfs not found: $INITRAMFS"
[ -z "$CAPSULE" ] || [ -f "$CAPSULE" ] || die "capsule not found: $CAPSULE"

# The boot-path is load-bearing: it is the UEFI boot entry ("Linux from
# rshim") that points at the BFB-embedded kernel Image. WITHOUT it, BF2 UEFI
# has no entry for our kernel and falls through to whatever is on the eMMC
# (observed on real hardware: our first BFB, lacking these, only updated
# ATF/UEFI and then booted the stock eMMC OS). The GUID + boot-args below are
# the standard BF2 rshim-boot values from bfb-build's create_bfb.
BA0=$(mktemp) BA2=$(mktemp) BP=$(mktemp) BD=$(mktemp)
trap 'rm -f "$BA0" "$BA2" "$BP" "$BD"' EXIT
# Exactly the boot-args NVIDIA bfb-build's create_bfb writes (debian/12), so we
# inherit its proven console setup rather than diverging. Kernel `console=` is
# additive -- printk goes to EVERY listed console -- so hvc0 (the BF2 rshim
# TMFIFO virtio console = `screen /dev/rshim0/console`, confirmed on this board)
# receives all boot output even though ttyAMA0 is last; ttyAMA1 is the BMC-SoL
# UART. v0 targets the pre-boot UART bases, v2 the post-boot one (0x13010000).
# initrd=initramfs names the packed initramfs.
printf 'console=ttyAMA1 console=hvc0 console=ttyAMA0 earlycon=pl011,0x01000000 earlycon=pl011,0x01800000 initrd=initramfs' > "$BA0"
printf 'console=hvc0 console=ttyAMA0 earlycon=pl011,0x13010000 initrd=initramfs' > "$BA2"
printf 'VenHw(F019E406-8C9C-11E5-8797-001ACA00BFC4)/Image' > "$BP"
printf 'Linux from rshim' > "$BD"

args=(--image "$KERNEL" --initramfs "$INITRAMFS")
[ -n "$CAPSULE" ] && args+=(--capsule "$CAPSULE")
args+=(--boot-args-v0 "$BA0" --boot-args-v2 "$BA2" --boot-path "$BP" --boot-desc "$BD")

"$MKBFB" "${args[@]}" "$BASE_BFB" "$OUT"

[ -s "$OUT" ] || die "mlx-mkbfb produced no output: $OUT"
echo "make-bfb: wrote $OUT ($(du -h "$OUT" | cut -f1))"
