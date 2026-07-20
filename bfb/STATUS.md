# BF2 BFB / arm64 boot — current status (2026-07-20)

Snapshot of where the BlueField-2 bring-up stands. Companion to
[HARDWARE-FINDINGS.md](HARDWARE-FINDINGS.md) (the deep technical write-up).

## The whole chain works, unattended

One `bfb-install` push takes a BF2 from whatever was on its eMMC to a
self-booting, loginable DozenOS. Every line below is from a real board.

| Step | Evidence |
|---|---|
| Flash | `FLASH COMPLETE`, ~34 s (`Run /init` 4.86 s → `reboot` 38.83 s) |
| Disk grown to fit the eMMC | `df`: 15 G → **38 G**, `lsblk` p3 38.6 G, GPT warning gone |
| UEFI boot entry | `boot entry registered`, `BootOrder: 001A,…` (ours first) |
| Auto-boot | `BootCurrent: 001A` — no operator action |
| Serial login | `dozenos@dozenos:~$` over the BMC console (port 2200) |
| Install log on the ESP | `ESP:/dozenos-install.log`, contents read back from the booted system |

## How each piece works

- **Flash** — `qemu-img convert -n -p -f qcow2 -O raw` straight onto
  `/dev/mmcblk0`: allocated clusters only, zero regions become BLKZEROOUT, so
  an install writes ~1 GB instead of the image's full 16 GB.
- **Grow** — `sgdisk -e` moves the backup GPT to the true end of the disk, then
  `parted resizepart 3 100%` extends the partition **in place** (only the end
  sector is rewritten; start, partition GUID and data blocks are untouched) and
  `resize2fs -f` grows the filesystem.
- **Boot entry** — mirrors NVIDIA's own installer: mount efivarfs at the point
  of use, drop any existing entry with our label, `efibootmgr -c -d
  /dev/mmcblk0 -p 2 -L DozenOS -l '\EFI\BOOT\BOOTAA64.EFI'`, verify, retry,
  and fall back to `bfbootmgr --cleanall`.
- **Serial login** — comes from the flavor alone: `dpu.toml` sets
  `console_type = "ttyAMA"`, GRUB puts `console=ttyAMA0,115200` on the cmdline,
  and DozenOS derives its `system console device` from that. Nothing is
  injected into config.boot and dozenos-build is untouched.
- **Modules** — the initramfs carries the whole tree (1479 modules, 148 MB)
  plus depmod metadata and uses `modprobe`, so dependencies resolve. EXT4,
  VFAT, SQUASHFS and LOOP are all `=m` in the DozenOS kernel.

## Release artefacts

`nightly.yml` → release (iso, dpu qcow2, both minisigned) → `bfb.yml` chains on
success → `dozenos-<ver>-bf2.bfb` **+ `.minisig`** on the same release. The
auto-chain skips when the release already has its `.bfb` (a change-gated
nightly still reports success), so it no longer burns a runner for nothing.

## Open

1. **OFED on arm64** — not started, and the premise needs a decision first.
   The `amd64`-only guard in `build-mellanox-ofed.sh` is currently *deliberate*
   (see `patches/ofed-25-01.sh`): OFED 25.01 is not expected to build against
   kernel 6.18, and MLNX_OFED is EOL as a standalone product — from January
   2025 NVIDIA ships DOCA-OFED instead. In-tree mlx5 is the primary driver and
   OFED OOT modules are not shipped, so what is actually wanted may be the
   userland tools (mstflint / mft / rshim) rather than an OOT module build.
2. **GRUB serial noise** — every boot prints `error: serial port 'com0' isn't
   found` / `error: terminal 'serial' isn't found`. Cosmetic: arm64 PL011 does
   not take the x86 `com0` form. Deliberately deferred.
3. **No CI gate for BFB regressions** — the whole chain is validated by pushing
   to real hardware. Nothing in CI would catch a break.

## Test rig

x86-64 staging VM `bf1` (172.30.0.160) drives the BF2 over rshim
(`/dev/rshim0/{boot,console,misc}`). DPU BMC at 172.30.0.159, console
`ssh -p 2200 root@<bmc>` (root/0penBmc). Install logs kept per attempt under
`~/bf2-test/v*/` on bf1.
