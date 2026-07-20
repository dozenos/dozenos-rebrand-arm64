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
4. **`zstdcat` in our installer `/init` but busybox has no zstd.** Long since
   moot: the installer no longer decompresses anything itself — the image ships
   as qcow2 and a bundled `qemu-img` writes it out.

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
- **Installer initramfs must bring up the eMMC like udev does.** Settled: the
  initramfs carries the whole module tree with depmod metadata and names what
  it needs via `modprobe`. See the module-loading finding below for why a
  curated `insmod` list cannot work.

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

## 2026-07-20 — the full chain works end to end

A single controlled push (one `bfb-install`, both console readers started
*before* the push, no resets) took the board from a stock-Ubuntu eMMC to a
self-booting DozenOS:

```
I: ===== FLASH COMPLETE =====
I: registering UEFI boot entry for DozenOS...
I: boot entry registered:
BootCurrent: 0019
BootOrder: 001A,0014,0000,0001,0002,...
I: done. Rebooting into installed DozenOS in 5s.
[   38.833965] reboot: Restarting system
… Booting `2026.07.20-0245-rolling'
```

- **Install → boot → auto-boot → boot entry**: all four work, unattended.
- **`BootCurrent: 0019`** is the decisive number: the installer itself booted
  from the rshim entry *while Ubuntu's `Boot0014` sat ahead of it in BootOrder*.
  Pushing a BFB takes precedence over the installed OS, full stop.
- **`BootOrder: 001A,…`** — `efibootmgr -c` prepends, so the new DozenOS entry
  leads the order exactly like Ubuntu's installer does.
- **Install takes ~34 s** (`Run /init` at 4.86 s, `reboot` at 38.83 s), down
  from ~7 minutes, since `qemu-img convert -n` writes only allocated clusters.

### Three earlier conclusions, all now disproven

Recorded because each cost real time and each looked well-evidenced:

1. **"A valid NVRAM boot entry blocks BFB re-flashing."** Wrong — see
   `BootCurrent: 0019` above, and a stock NVIDIA BFB flashed fine on this board
   under the same NVRAM state. The original evidence (v2 installed, v3 did not)
   was a symptom of #2, not of boot ordering.
2. **"The BFB/rshim boot path has no EFI runtime, so efibootmgr can never work
   there."** Wrong — it works. What actually mattered was *when* efivarfs is
   mounted: mounting it once at the top of `/init` returned ENODEV, while
   mounting it at the point of use — NVIDIA's own sequence — succeeds.
3. **"Our BFB packaging is defective."** Wrong — a byte-level `mlx-mkbfb -x`
   comparison had already shown every boot-governing image identical to stock,
   and the hardware now agrees.

The lesson worth keeping: the fix came from reading NVIDIA's installer
(`ubuntu/install.sh:update_efi_bootmgr`, extracted from the stock bf-bundle
initramfs) rather than from reasoning about the firmware. When a reference
implementation exists, diff against it early.

### What the installer now does (mirroring NVIDIA)

1. `modprobe` the filesystems it needs (all `=m`) from the bundled tree;
2. flash with `qemu-img convert -n -p -f qcow2 -O raw` onto `/dev/mmcblk0`;
3. `sgdisk -e`, `parted resizepart 3 100%`, `e2fsck -f -y`, `resize2fs -f` —
   grow into whatever the card actually holds;
4. `blockdev --rereadpt` — the kernel still holds the *previous* OS's partition
   table, so `p2` would otherwise resolve to the old ESP offset;
5. `mount -t efivarfs none /sys/firmware/efi/efivars` **at the point of use**;
6. delete any existing entry with our label, `efibootmgr -c -d /dev/mmcblk0
   -p 2 -L DozenOS -l '\EFI\BOOT\BOOTAA64.EFI'`, verify, retry, and fall back to
   `bfbootmgr --cleanall` before giving up;
7. write the install log to the ESP, unmount efivarfs, reboot.

### Serial login comes from the flavor, not from config.boot

`console=` alone does not obviously give a login prompt, and the path to
understanding why cost two wrong turns worth recording.

What is true: DozenOS takes its serial console from `system console device` in
**config.boot**, and the image's `config.boot.default` ships no `console`
section at all (`getty.target.wants/` holds only `getty@tty1`). What is *also*
true, and is the part that matters: **VyOS derives that setting from the kernel
cmdline itself** — the running config came back carrying
`device ttyAMA0 { kernel; speed "115200" }`, the `kernel` flag marking it as
auto-derived.

So the fix is one line in the flavor:

```toml
[boot_settings]
console_type = "ttyAMA"
```

GRUB then emits `console=ttyAMA0,115200`, VyOS picks it up, and the login
prompt appears. **dozenos-build is untouched and nothing is injected into the
installed system.**

The wrong turns, since both looked well-evidenced at the time:

1. *"The UART dies in early userspace."* It does not. Output flows to
   `Configuration success` at ~82 s and beyond; there was simply nothing
   further to print, and no getty to answer a keypress. Raw reads of the BMC
   UARTs returning 0 bytes looked like a dead link and was not.
2. *"The installer must seed config.boot."* Built and shipped it — generate the
   file on the runner from the image's own `config.boot.default`, drop it into
   `boot/<version>/rw/opt/vyatta/etc/config/config.boot`. It worked, and it was
   redundant: with the flavor fixed, VyOS wrote its own stanza too and
   config.boot came back with **two** `console` blocks. Removed again.

The earlier attempts failed only because the image still said `console_type =
"hvc"` — VyOS was faithfully configuring hvc0, which is not where anyone was
looking.

### Module loading: the whole tree, and modprobe

`insmod` resolves no dependencies. A curated list loaded in alphabetical order
put `ext4` before `jbd2` and died with `Unknown symbol jbd2_journal_wipe`,
which took the root-partition mount with it. A multi-pass retry loop hid the
ordering rather than fixing it, and every new module meant guessing its
dependency chain again.

The initramfs now stages the **entire** module tree (1479 modules, 148 MB)
plus depmod metadata and names what it wants via `modprobe`. Modules are
decompressed on the way in — the kernel sets `CONFIG_MODULE_COMPRESS_XZ` and
busybox's modprobe has no `.ko.xz` support (its binary carries no such string),
so a plain `.ko` tree removes the question. Cost measured: 34 MB compressed vs
~210 MB decompressed, ~35 MB net in the gzip'd cpio.

Relevant because **EXT4, VFAT, SQUASHFS and BLK_DEV_LOOP are all `=m`** in the
DozenOS kernel — anything the installer wants to mount needs its module.

NLS charsets need naming explicitly (`nls_cp437`, `nls_iso8859-1`,
`nls_ascii`): the kernel autoloads a vfat charset by calling `/sbin/modprobe`,
which does not exist in this initramfs, so mounting the ESP fails with
**EINVAL** — not the ENODEV you would expect from a missing filesystem driver.

### Growing the root filesystem, and the 1980 clock

The image is built for the smallest supported eMMC, so on a 38.9 GiB card 23
GiB sat unused and every boot logged `GPT: 33554431 != 81494015`.

```
sgdisk -e /dev/mmcblk0              # backup GPT header to the true end of disk
parted -s /dev/mmcblk0 resizepart 3 100%
e2fsck -f -y /dev/mmcblk0p3
resize2fs -f /dev/mmcblk0p3
```

`parted resizepart` is deliberate: it rewrites only partition 3's end sector,
leaving the start, the partition GUID and every data block untouched.
Delete-and-recreate (what `growpart` does) is equally non-destructive in
principle but stakes the data on reproducing the start sector exactly, and
there is no reason to take that risk when an in-place operation exists.

**`-f` on resize2fs is required, and is not a bypass.** resize2fs refuses when
`s_lastcheck < s_mtime`, and the DPU has no usable clock during install — it
stamps files **1980**, which is visible on the ESP install log's timestamp. So
the check e2fsck just recorded always looks older than the 2026 image, however
many times e2fsck runs. The symptom is thoroughly misleading: resize2fs says
"Please run 'e2fsck -f' first" *after* a successful e2fsck that completed all
five passes. Run e2fsck, inspect its result, then force.

Result on hardware: `df` 15 G → **38 G**, `lsblk` p3 38.6 G, GPT warning gone.

### Diagnostics discipline

Two failures in this session were prolonged by discarded output:
`e2fsck ... >/dev/null 2>&1` hid why resize2fs then refused, and an early
`mount 2>/dev/null` hid EINVAL-vs-ENODEV on the ESP. Both now capture and
report. In an installer that runs unattended on a board with no login, an
error message thrown away is an hour of hardware time.

## Installer-kernel strategy

The installer kernel is throwaway. NVIDIA's `bluefield-64k` kernel
(`casper/vmlinuz`, 6.8.0-1022) EFI-stub-boots via rshim reliably; its eMMC host
drivers ship as modules (`sdhci`, `sdhci-pltfm`, `cqhci`, `sdhci-of-dwcmshc`;
`mmc_core`/`mmc_block`/`virtio_console` are built-in). Wrapping NVIDIA's kernel
+ our dd initramfs is the pragmatic installer; the installed DozenOS boots from
eMMC via its own GRUB (Linux boot protocol, not EFI stub).
