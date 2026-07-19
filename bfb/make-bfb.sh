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

MKBFB="" BASE_BFB="" KERNEL="" INITRAMFS="" OUT="" CAPSULE="" BOOT_ARGS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mkbfb)     MKBFB="${2:-}"; shift 2 ;;
    --base-bfb)  BASE_BFB="${2:-}"; shift 2 ;;
    --kernel)    KERNEL="${2:-}"; shift 2 ;;
    --initramfs) INITRAMFS="${2:-}"; shift 2 ;;
    --out)       OUT="${2:-}"; shift 2 ;;
    --capsule)   CAPSULE="${2:-}"; shift 2 ;;
    --boot-args) BOOT_ARGS="${2:-}"; shift 2 ;;
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
[ -z "$BOOT_ARGS" ] || [ -f "$BOOT_ARGS" ] || die "boot-args file not found: $BOOT_ARGS"

args=(--image "$KERNEL" --initramfs "$INITRAMFS")
[ -n "$CAPSULE" ] && args+=(--capsule "$CAPSULE")
if [ -n "$BOOT_ARGS" ]; then
  # v0 and v2 mirror create_bfb: old and new boot-stream versions carry
  # their own boot-args blob.
  args+=(--boot-args-v0 "$BOOT_ARGS" --boot-args-v2 "$BOOT_ARGS")
fi

"$MKBFB" "${args[@]}" "$BASE_BFB" "$OUT"

[ -s "$OUT" ] || die "mlx-mkbfb produced no output: $OUT"
echo "make-bfb: wrote $OUT ($(du -h "$OUT" | cut -f1))"
