# BlueField-2 BFB — Hardware Bring-up Findings

Real-hardware findings from booting DozenOS BFBs on a physical BF2 (rshim +
BMC). Records what the CI-built BFB got wrong and how the boot chain actually
behaves. Kept as the source of truth for `bfb/` and `bfb.yml` fixes.

## Test rig topology

- **VM `bf1`** = x86-64 build/staging host (172.30.0.138, **172.30.0.160** as of
  2026-07-20). The BF2 is PCIe passed-through; the VM talks to it via **rshim**
  (`/dev/rshim0/{boot,console,misc}`). So `busybox`/kernels *for the DPU are
  arm64* and cannot be run on the VM.
- **DPU BMC (OpenBMC)** — IP moved 172.30.0.139 → 172.30.0.142 →
  **172.30.0.159** (2026-07-20). Default creds **`root` / `0penBmc`**
  (documented default, not changed on this unit). BMC-side console server is
  `obmc-console@ttyS0`; port 2200 is the only listener (2201 has a client
  config but no socket).
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
- The old "hangs after `HW watchdog disab…`" symptom is **resolved** — with the
  MMC stack built in, that line is simply the last one before GRUB hands off and
  the kernel boots to a full multi-user system (verified 2026-07-20).
- `MLXBF_TMFIFO` and `EFIVAR_FS` are now forced `=y` (2026-07-20) so the rshim
  console exists from early boot and efivarfs needs no module. Note that `=y`
  did **not** make efivarfs usable in the BFB boot path — see the EFI-runtime
  finding below; the driver was never the constraint.

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

## 2026-07-20 session — install and boot work; three new blockers

### What is proven working

- **Install**: BFB push → eMMC flash → reboot, three times over.
- **Boot**: the installed DozenOS boots to `Reached target DozenOS target` and
  `Configuration success` — root mounted off `mmcblk0`, the whole systemd stack
  up. The MMC fix is confirmed end-to-end.
- **Auto-boot**: with a UEFI boot entry present, UEFI goes straight to GRUB and
  into DozenOS with no operator action.
- **NVRAM writes work** — an entry added by hand from the EFI shell
  (`bcfg boot add 0 FS0:\EFI\BOOT\BOOTAA64.EFI "DozenOS"`) survived reboots and
  even a reinstall. So nothing about this board rejects boot entries; only the
  installer cannot create them (next finding).

### Blocker 1 — no EFI runtime in the BFB/rshim boot path

`mount -t efivarfs` in the installer fails with **`No such device` (ENODEV)**
even though `CONFIG_EFIVAR_FS=y` is verified present in the built kernel (the
CI kernel-config gate checks all 24 options). `efivarfs_init()` registers its
filesystem type **only when the firmware handed over working EFI runtime
services**; ENODEV therefore means EFI runtime is absent in that boot, not that
the driver is missing.

Consequence: **`efibootmgr` can never work from the installer as currently
booted** — it is not an installer bug and no amount of fixing the efibootmgr
call will help. Either the BFB boot path must be made to deliver EFI runtime,
or the boot entry must be registered from the installed system (which boots via
GRUB and does have full EFI). Diagnostics that dump `/sys/firmware/efi`,
`/proc/filesystems` and the EFI dmesg lines are now in the installer but have
not yet produced output (see blocker 2 — the installer stopped being reachable).

Ruled out: 64K-page runtime-region misalignment (the kernel is `ARM64_4K_PAGES`),
missing driver (`=y`), and `CONFIG_EFI` (=y).

### Blocker 2 — our BFB loses to the eMMC OS; the stock BFB does not

**RETRACTED — no cause established (2026-07-20).** Two independent checks
knocked the NVRAM theory down, and the packaging theory that replaced it did
not survive either.

1. A stock NVIDIA Ubuntu BFB pushed with `bfb-install` on this board, with
   `Boot0022 DozenOS` present and bootable, **did** reach its rshim installer.
2. Our own timeline says the same thing: `Boot0022` was created at 06:38 and
   the **v2 install at 06:49 ran fine**. Only the later v3 pushes did not.

So a valid NVRAM boot entry does not block BFB flashing.

A byte-level `mlx-mkbfb -x` comparison then cleared our packaging too — every
field that governs the rshim boot entry is **identical to the stock BFB**:

| image | stock | ours |
|-------|-------|------|
| `boot-desc-v0` | `Linux from rshim` | same |
| `boot-path-v0` | `VenHw(F019E406-8C9C-11E5-8797-001ACA00BFC4)/Image` | same |
| `boot-args-v0` | `console=ttyAMA1 console=hvc0 console=ttyAMA0 earlycon=pl011,0x01000000 earlycon=pl011,0x01800000 initrd=initramfs` | same |
| `boot-args-v2` | `console=hvc0 console=ttyAMA0 earlycon=pl011,0x13010000 initrd=initramfs` | same |
| `boot-acpi-v0` | `default` | same |

Only two real differences remain, neither of which governs boot selection:
stock carries an extra `info-v0` (a Redfish *Software Inventory* JSON listing
BSP/ATF versions — reporting metadata for the BMC), and stock stores its kernel
LZMA-compressed (12.8 MB) where ours is a raw Image (35.3 MB) — and our raw
Image has demonstrably booted.

v2 (worked) and v3 (did not) are themselves structurally identical: same
kernel bytes, same boot metadata, initramfs 529.0 MB vs 534.0 MB.

**Therefore the v3 "installer never ran" observation is unexplained, and the
conditions it was taken under were poor**: a leftover v2 `bfb-install` process
was still running, the rshim console bridge was torn down and rebuilt several
times around the push, and the board was `SW_RESET` more than once mid-flight.
The missing `BlueField-2 installer` banner may well be lost console output
rather than a boot that never happened. **Next step: one controlled push — a
single `bfb-install`, one long-lived console reader started before the push,
no resets — before theorising further.**

Things that do **not** solve it:

- **`BOOT_MODE 0` (rshim)** — this only selects where **ATF/UEFI** are loaded
  from. UEFI still consults NVRAM BootOrder afterwards and still picks the eMMC
  OS. It also does not persist: it reads back as `1` after the next boot.
- **`bfb-install`** — it has no boot-mode or boot-order override at all; it
  `cat`s the BFB to `/dev/rshim0/boot` and then polls `/dev/rshim0/misc`.
- **Redfish/BMC boot options** — deliberately out of scope: stock BFBs do not
  depend on a DPU BMC, so neither can we.

Our BFB's structure matches NVIDIA's (`mlx-mkbfb -d`): boot-desc v0, boot-path
v0, boot-args v0+v2, kernel v0, initramfs v0 — no missing image explains it, so
the open question is how the firmware *orders* the rshim entry, not whether it
exists.

### Blocker 3 — no usable login on the installed system

| Path | Behaviour |
|------|-----------|
| rshim console (hvc0) | alive the whole boot, but **no getty** — DozenOS puts its getty on ttyAMA0 |
| BMC SoL / ttyAMA0 (port 2200) | carries firmware, GRUB and early kernel output, then **goes silent in early userspace**; raw reads of both BMC UARTs return 0 bytes afterwards |
| GRUB | renders on ttyAMA0 but **ignores serial input** (no `terminal_input serial`), so the menu cannot be interrupted to edit the cmdline |
| UEFI setup menu | reachable by spamming ESC during UEFI, but **password-protected**; `bluefield` is rejected (see below) |

**UEFI password.** The documented default is `bluefield`, but BlueField forces a
change on first use and the policy requires **12–64 characters**, so a board
that has ever been entered has a non-guessable password. Official reset, run
**on the DPU**:

```bash
sudo bfrec --capsule /usr/lib/firmware/mellanox/boot/capsule/EnrollKeysCap
sudo reboot
```

The capsule is processed on the next boot and puts the password back to
`bluefield` (which UEFI then makes you change again). Keep `EnrollKeysCap` a
manual rescue step: it also enrols Secure Boot keys, so it must never be baked
into a product BFB where every install would silently alter the board's
security state. Our BFB bundles only `boot_update2.cap` (the ATF/UEFI firmware
update, pinned to 4.15.0 to stop firmware downgrades) — not `EnrollKeysCap`.

Net effect: the system boots and runs correctly yet cannot be logged into, and
because of blocker 2 it also cannot be re-flashed. Recommended fix regardless of
the rest: **give the DPU image a getty on hvc0 as well as ttyAMA0**, so the rshim
console is always a way in.

### Installer speed

The installer now flashes with `qemu-img convert -n -p -f qcow2 -O raw` straight
onto `/dev/mmcblk0` instead of `zcat | dd` of a full-size raw image: only
allocated clusters are written and zero regions become BLKZEROOUT requests, so
an install writes roughly 1 GB rather than the full 16 GB. `qemu-img` is bundled
into the initramfs with its shared libraries (visible as 22 bundled libs, versus
4 for the old efibootmgr+pv set).

## Installer-kernel strategy

The installer kernel is throwaway. NVIDIA's `bluefield-64k` kernel
(`casper/vmlinuz`, 6.8.0-1022) EFI-stub-boots via rshim reliably; its eMMC host
drivers ship as modules (`sdhci`, `sdhci-pltfm`, `cqhci`, `sdhci-of-dwcmshc`;
`mmc_core`/`mmc_block`/`virtio_console` are built-in). Wrapping NVIDIA's kernel
+ our dd initramfs is the pragmatic installer; the installed DozenOS boots from
eMMC via its own GRUB (Linux boot protocol, not EFI stub).
