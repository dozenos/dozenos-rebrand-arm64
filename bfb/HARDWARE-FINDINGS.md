# BlueField-2 BFB — Hardware Bring-up Findings

Real-hardware findings from booting DozenOS BFBs on a physical BF2 (rshim +
BMC). Records what the CI-built BFB got wrong and how the boot chain actually
behaves. Kept as the source of truth for `bfb/` and `bfb.yml` fixes.

## Test rig topology

- **VM `bf1` (172.30.0.138)** = x86-64 build/staging host. The BF2 is PCIe
  passed-through; the VM talks to it via **rshim** (`/dev/rshim0/{boot,console,misc}`).
  So `busybox`/kernels *for the DPU are arm64* and cannot be run on the VM.
- **DPU BMC (OpenBMC)** — IP moved 172.30.0.139 → **172.30.0.142** after a BMC
  firmware flash. Default creds **`root` / `0penBmc`** (documented default, not
  changed on this unit).
- **Host serial console via BMC** = `ssh -p 2200 root@<bmc>` (obmc-console).
  Use SSH port 2200, **not** IPMI SoL (IPMI RAKP auth is broken on this unit).

## Console routing (the thing that cost the most time)

| Phase | Where the DPU console goes | How to read it |
|-------|----------------------------|----------------|
| rshim-push boot (installer) | **rshim console = hvc0** (TMFIFO virtio) | `cat /dev/rshim0/console` — but hvc0 only exists once `MLXBF_TMFIFO` is loaded |
| firmware/UEFI + NVIDIA installer progress | **rshim boot-status** (`INFO[BL2]…INFO[MISC]`) — a hardware/firmware channel, NOT hvc0 | `bfb-install` parses it; our initramfs does not emit it |
| normal eMMC boot | **BMC UART → port 2200** | `ssh -p 2200` |

Consequences:
- Only **one** reader may hold `/dev/rshim0/console`. A stray `cat` competes
  with `bfb-install` and eats the bytes it needs → `bfb-install` appears to hang.
- The kernel's EFI-stub line `EFI stub: Booting Linux Kernel…` reaches the rshim
  console (UEFI ConOut). Anything after that is invisible until `MLXBF_TMFIFO`
  brings up hvc0 — which our installer initramfs never loads, so the installer
  runs **blind** on rshim.
- `console=` is additive (printk hits every listed console); `/dev/console`
  (userspace) is the **last** `console=`. To make `/init` output land on the
  BMC console put `console=ttyAMA1` last.

## Root causes found in our CI-built BFB

1. **gzip kernel rejected.** `mlx-mkbfb --image <gzip vmlinuz>` → UEFI prints
   `Failed to boot 'Linux from rshim'` and falls through to eMMC. The kernel
   must be the **uncompressed arm64 Image** (`MZ` @0x0, `ARMd` @0x38). NVIDIA
   `create_bfb` does exactly this (`zcat vmlinuz > image`). **Fixed in `bfb.yml`.**
2. **Stock BFB stores the kernel LZMA-compressed** (`Boot image` chunk = LZMA,
   decompresses to the same raw Image); BF2 firmware decompresses it at boot
   (`Kernel Decompressed Successfully, Compressed … to Decompressed …`). Passing
   a raw Image to `--image` did *not* get LZMA-wrapped by our mlx-mkbfb call —
   under investigation whether that matters.
3. **`EFI stub: Generating empty DTB`** on our BFBs vs `Using DTB from
   configuration table` on stock. Seen with BOTH our kernel and the NVIDIA
   kernel when wrapped by us, and on both 4.11.0 and 4.15.0 firmware — so it is
   **how we generate the BFB**, not the firmware version. `create_bfb` passes no
   `--dtb`/`--acpi` (DTB comes from UEFI). Still isolating which override
   (`--image` / `--boot-args`) suppresses the DTB. `bootimages` note: our old
   base is 4.11.0 and **downgrades** a board the DOCA bundle put at 4.15.0 —
   should pin a newer base regardless.
4. **`zstdcat` in our installer `/init` but busybox has no zstd.** The arm64
   busybox has gzip/gunzip/zcat only. Our `create-installer-initramfs.sh` was
   never hardware-validated. Fix: ship the disk image gzip-compressed and
   `zcat | dd`, or bundle a static `zstd`.

## eMMC on BF2 — the real blocker (root-caused on hardware)

- **BF2 eMMC is a Synopsys DesignWare MMC controller** driven by
  **`dw_mmc-bluefield`** (`CONFIG_MMC_DW_BLUEFIELD`), exposed as ACPI node
  **`PRP0001:00`**. Observed live: `dwmmc_bluefield PRP0001:00 … mmc0 …
  mmcblk0 38.9 GiB (p1 p2)`. **It is NOT the SDHCI `sdhci-of-dwcmshc`
  controller** — that driver has an `acpi:MLNXBF30` alias and loads, but binds
  *nothing* here (wrong device). Our first installer hand-picked the 4 sdhci
  modules → eMMC never appeared. Loading `dw_mmc-bluefield` is the fix.
- **`EFI stub: Generating empty DTB` is normal**, not a fault. The stock NVIDIA
  installer shows it too and still erases/writes `/dev/mmcblk0` — the DPU boots
  via **ACPI**, eMMC included. So DTB/ATF is a dead end; don't chase it.
- **Installer initramfs must bring up the eMMC like udev does.** A busybox
  `insmod` of a fixed module list is fragile: the eMMC needs the *right* driver
  loaded (`dw_mmc-bluefield`) and its ACPI/clock deps. Two working shapes:
  (a) reuse the NVIDIA casper initrd (real `udevadm trigger` coldplug), or
  (b) `modprobe dw_mmc-bluefield` **directly** now that the driver is known.
  A blind "modprobe every `/sys` modalias" coldplug DID bring the eMMC up, but
  then hung the init on some later device's module — so target the driver.
- Disk image must be **gzip** (`zcat|dd`) not zstd — the busybox in our
  installer initramfs has gzip/zcat but no zstd.

## DozenOS kernel MMC config (fixed 2026-07-19)

Our arm64 kernel had `# CONFIG_MMC_DW is not set` → an installed DozenOS could
never mount root off the DPU eMMC. `kernel-config-bf2-offload.sh` now sets
`MMC=y MMC_BLOCK=y MMC_DW=y MMC_DW_PLTFM=y MMC_DW_BLUEFIELD=y` (built-in, since
the eMMC holds root). `MMC_SDHCI_OF_DWCMSHC=m` is kept but is not the BF2 driver.

## Our own DozenOS kernel

- `CONFIG_EFI_STUB=y`, `CONFIG_EFI=y`, `CONFIG_RELOCATABLE=y`; PE header is a
  valid arm64 EFI app (same structure as NVIDIA's). Page size (4K) is **not**
  the problem (4K BF images exist).
- Symptom: with our BFB it never prints the EFI-stub line and hangs after
  `HW watchdog disab…`. Because that hang coincides with `empty DTB`, the DTB
  gap (finding #3) is the prime suspect, not the kernel itself.
- `CONFIG_MLXBF_TMFIFO=m` — hvc0 (rshim console) is **not built-in**. Make it
  `=y` so the rshim console works from early boot and installers are visible.

## NVIDIA install mechanism (reference, from `bfb-install` on the stock bundle)

```
Pushing bfb
INFO[UEFI]: exit Boot Service
INFO[MISC]: Erasing eMMC drive: /dev/mmcblk0
INFO[MISC]: Ubuntu installation started
INFO[MISC]: Installing OS image
INFO[MISC]: Ubuntu installation completed
```

Same "write an OS image to eMMC then reboot" model as our dd installer.
`bfb-install --bfb <f> [--config bf.cfg] [--rootfs rootfs.tar.xz] --rshim rshim0`.

## Installer-kernel strategy

The installer kernel is throwaway. NVIDIA's `bluefield-64k` kernel
(`casper/vmlinuz`, 6.8.0-1022) EFI-stub-boots via rshim reliably; its eMMC host
drivers ship as modules (`sdhci`, `sdhci-pltfm`, `cqhci`, `sdhci-of-dwcmshc`;
`mmc_core`/`mmc_block`/`virtio_console` are built-in). Wrapping NVIDIA's kernel
+ our dd initramfs is the pragmatic installer; the installed DozenOS boots from
eMMC via its own GRUB (Linux boot protocol, not EFI stub).
