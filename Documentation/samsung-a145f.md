# Samsung Galaxy A14 4G (SM-A145F) bring-up guide

Status: **builds, not yet confirmed booting on hardware.** Everything below was
derived from a stock A145F backup (Android 15, board revision 4) and checked
by building; nothing has been flashed by the author of this guide yet.

The phone: Exynos 850 (s5e3830), 4 GB RAM, eMMC, Android 15, non-A/B with
dynamic partitions, GKI-style layout: `boot` (header v4, kernel only),
`init_boot` (generic ramdisk), `vendor_boot` (device tree, modules, bootconfig).

Helper scripts live in `tools/samsung-a145f/`.

## 0. Before you start

* Bootloader unlocked, USB debugging on, a root shell on the phone (Magisk or a
  custom recovery with adb root).
* The boot chain must accept a custom `boot.img`: AVB verification has to be
  disabled (e.g. a `vbmeta` flashed with verification off). If your phone already
  runs a custom kernel it probably is.
* Host (Ubuntu): `sudo apt install adb gcc-aarch64-linux-gnu device-tree-compiler make python3`

## 1. Back up the phone (do not skip)

```
./tools/samsung-a145f/a145f-backup.sh -o a145f-backup
```

Dumps every partition straight to the PC with a live progress bar and a
timestamped `backup.log`. Defaults: skips `userdata` and the whole-disk
`mmcblk0` entry, copies `/sdcard`. Useful flags: `--skip a,b`, `--skip-super`,
`--no-sdcard`, `--checksums`, `--verify`. Press **s** to skip the partition
that is currently copying.

Keep `efs`, `sec_efs`, `cpefs` somewhere safe: they hold your IMEI.

## 2. Build the boot inputs from your own backup

uniLoader embeds a kernel, a device tree and a ramdisk. Build them from the
stock images (never commit them, they are device specific):

```
B=path/to/your/a145f-backup-folder      # contains partitions/ and info/
python3 tools/samsung-a145f/make_a145f_blobs.py \
  --boot $B/partitions/boot.img --vendor-boot $B/partitions/vendor_boot.img \
  --init-boot $B/partitions/init_boot.img --dtbo $B/partitions/dtbo.img \
  --getprop $B/info/getprop.txt --out blob
```

* `blob/Image`   - the kernel from `boot.img`
* `blob/ramdisk` - vendor ramdisk + `init_boot` ramdisk + a bootconfig block
  (with `androidboot.*` values taken from your `ro.boot.*` properties)
* `blob/dtb`     - `vendor_boot`'s base tree + the `dtbo` overlay chosen by
  `ro.boot.dtbo_idx`, plus `bootconfig`, `root=/dev/ram0` and the panel
  parameters (`lcdtype`, `s3cfb.bootloaderfb`, ...) in `/chosen/bootargs`

Serial numbers and similar identifiers are not copied.

## 3. Build uniLoader and pack the boot image

```
make a145f_defconfig CROSS_COMPILE=aarch64-linux-gnu-
make CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)"
python3 tools/samsung-a145f/pack_boot_v4.py uniLoader --stock $B/partitions/boot.img -o boot_uniloader.img
```

The result is a header-v4 `boot.img` (no ramdisk) whose "kernel" is uniLoader.
It must fit the 64 MiB boot partition; the packer checks this.

## 4. Flash and recover

**Odin chooses the partition from the file name inside the tar, so it must be
called `boot.img`.** Prepare both the new image and a restore tar first:

```
mkdir -p odin/new odin/stock
cp boot_uniloader.img odin/new/boot.img
head -c 67108864 $B/partitions/boot.img > odin/stock/boot.img   # stock, junk bytes trimmed
(cd odin/new   && tar -H ustar -cf ../AP_uniloader.tar boot.img)
(cd odin/stock && tar -H ustar -cf ../AP_stock.tar boot.img)
```

Check that verification is already off (flags `3` means disabled):

```
python3 -c "import struct,sys;d=open(sys.argv[1],'rb').read(256);print('vbmeta flags =',struct.unpack('>I',d[120:124])[0])" $B/partitions/vbmeta.img
```

Then reboot to Download mode (hold Vol Up + Vol Down while plugging in USB) and
flash `odin/AP_uniloader.tar` in Odin's **AP** slot (Windows Odin3, or Samsung's
Linux `odin4`; Heimdall often fails on recent Samsung phones). If anything goes
wrong, flash `odin/AP_stock.tar` the same way. Download mode does not depend on
the OS, so a bad boot image is recoverable.

## 5. Why the addresses are what they are

`configs/a145f_defconfig`:

| Setting | Value | Reason |
|---|---|---|
| `TEXT_BASE` | `0xa0000000` | With `POSITION_INDEPENDENT` uniLoader copies itself here and runs from here. The old `0x90000000` overlapped the bootloader's `ect_binary` (`0x90000000`) and `sec_debug_next` (`0x91200000`) reserved regions. |
| `PAYLOAD_ENTRY` | `0x80200000` | The kernel's `Image` header has `text_offset 0`, so it must be 2 MiB aligned. Image size is `0x2720000`. |
| `RAMDISK_ENTRY` | `0x84000000` | Clear of the kernel and below `0x90000000`. |

Other facts used: DRAM starts at `0x80000000` (4 GB total); the bootloader
framebuffer is `0xfa000000`, 13 MiB (1080x2408, ARGB8888); the panel ID
(`lcdtype=5993024`, `0x5B7240`, Tianma) selects the Novatek NT36523 touch
firmware (`nt36672_a14_tianma.bin`), which the vendor ramdisk carries.

## 6. Things that are not verified

* Where Samsung's bootloader first loads the image (uniLoader is
  position independent, so this should not matter).
* The stock bootloader normally patches the device tree (and passes
  bootloader-computed values). uniLoader does not; anything missing there is
  unknown.
* The `androidboot.verifiedbootstate/vbmeta.device_state/flash.locked` values in
  the generated bootconfig are set to "orange/unlocked/0" on purpose; change
  them in `make_a145f_blobs.py` if your setup needs different ones.
* `bootimg_info.py <img>` prints boot/vendor_boot headers (load addresses, size,
  cmdline) and extracts the vendor_boot device tree; useful for reports.

## 7. If it does not boot

Report: what the screen shows (black, logo, uniLoader text), whether Download
mode still works, and the output of `bootimg_info.py` on your stock images.
After a successful boot, `dmesg | grep -i -E "nvt|lcdtype|lcd is not attached"`
shows whether touch found its panel.

## Reading the kernel log after a failed boot

If the screen goes black and the phone reboots, uniLoader shows what the
previous boot left in RAM the next time it starts (DRAM survives the reset):

1. Re-run `make_a145f_blobs.py` (it adds a 1 MiB `ramoops` reserved region at
   `0x8fe00000` and `ignore_loglevel pstore.compress=none` to the command
   line), rebuild, repack, flash.
2. Let the boot fail once. When uniLoader appears again it shows, in order:
   the CPU state, the **kernel log** from ramoops (held 40 s), then the tail
   of the stock bootloader's own log plus a raw hex view, then continues.
3. Photograph the kernel-log screen.

"ramoops: no kernel log" means the kernel died before pstore started (very
early crash) or the RAM was cleared; the sig value printed helps tell which.
The `log_kernel` area at `0xf0010000` holds the *bootloader's* log (it ends at
"Starting kernel..."), not Linux's.

## 9. Using the bootloader-patched device tree (`--live-dtb`)

Samsung's bootloader patches the device tree before the kernel sees it
(reserved-memory addresses, memory size, board fields). uniLoader does not, and
a static tree can make the kernel use memory that TrustZone protects, which
shows up as a TZASC interrupt followed by a panic a few seconds into boot.

With the **stock** boot.img restored and a root shell, capture the real tree:

```
tools/samsung-a145f/a145f-capture-live-dtb.sh live-dtb
python3 tools/samsung-a145f/make_a145f_blobs.py ... --live-dtb live-dtb/stock_live.dtb --out blob
```

The script keeps the live tree as is, adds the bring-up bootargs that are not
already there, adds the ramoops node (and warns if it overlaps a reserved
region), and leaves `/chosen/linux,initrd-*` for uniLoader to rewrite.
Untested on hardware.

The on-screen crash view now searches for `Kernel panic - not syncing` first,
then oops/BUG markers, and only then TZASC lines.

### Why the static tree panics (found by diffing against the live tree)

The device tree the stock bootloader hands to the kernel differs from the
static vendor_boot + dtbo one in a few places only:

* **memory**: live tree has RAM at `0x80000000-0xbb9fffff`, `0xc0000000-0xdfffffff`,
  `0xe0d00000-0xffffffff` and 2 GiB at `0x880000000`. The static tree claims all of
  `0x80000000-0xffffffff`, including `0xbba00000-0xbfffffff` (about 100 MiB) and
  `0xe0000000-0xe0cfffff`, which TrustZone protects. If the kernel allocates or
  maps pages there, TZASC fires and Samsung's handler panics.
* a `kaslr` node at `0x8ffff000` (4 KiB) for the KASLR seed
* board-revision pin-control phandles in two nodes, and a `ddi_id` property
* the full stock `bootargs` (`oops=panic`, `sec_debug_next=...`, `ess_setup=...`)

Use `--live-dtb`; it carries all of these. ramoops moved to `0x8fe00000`
because `0x8ffff000` is the kaslr node.
