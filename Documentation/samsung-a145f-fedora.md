# Booting Fedora from an SD card on the Galaxy A14 (SM-A145F)

Status: the build, packing and logging steps are tested. Starting systemd on
the Samsung vendor kernel is **not yet confirmed on hardware**.

Idea: uniLoader starts the Samsung kernel with a small initramfs instead of
Android's. The initramfs loads the vendor modules (the SD controller is a
module), finds an ext4 partition on the SD card that holds a Fedora root, and
`switch_root`s into its systemd. Internal storage (mmcblk0) is never touched.

The kernel has no text console on the screen. Everything the initramfs prints
goes to the kernel log, which survives a warm reboot in RAM (ramoops) and is
shown by uniLoader on the next boot. That is your only debug channel.

## 0. Requirements

* Phone bootloader unlocked, stock backup made (see samsung-a145f.md).
* The blobs from samsung-a145f.md, built with `--live-dtb`.
* `RD_ALL`: the unpacked stock ramdisk that contains `lib/modules`.
* `BUSYBOX`: a static aarch64 busybox binary.
* Packages: `lz4 cpio device-tree-compiler gcc-aarch64-linux-gnu`.
* An SD card with an ext4 partition holding a Fedora aarch64 root (section 2).

## 1. Build (always from the repo root)

```bash
git pull
make clean                       # a stale object file gave old screens once
make a145f_defconfig
make CROSS_COMPILE=aarch64-linux-gnu-
grep -c -a "KERNEL LOG (ramoops" uniLoader     # must print 1
```

If that prints 0 the build is stale. Do not flash it.

```bash
B=~/Downloads/uniLoader-a145f-bootloader/a145f-backup
python3 tools/samsung-a145f/make_a145f_blobs.py \
  --boot "$B/partitions/boot.img" --vendor-boot "$B/partitions/vendor_boot.img" \
  --init-boot "$B/partitions/init_boot.img" --dtbo "$B/partitions/dtbo.img" \
  --getprop "$B/info/getprop.txt" \
  --live-dtb tools/samsung-a145f/live-dtb/stock_live.dtb --out blob

# must run AFTER make_a145f_blobs.py (it overwrites blob/ramdisk and blob/dtb)
RD_ALL=~/rd_all BUSYBOX=~/busybox-1.36.1/busybox \
  bash tools/samsung-a145f/fedora/build_fedora_ramdisk.sh

python3 tools/samsung-a145f/pack_boot_v4.py uniLoader \
  --stock "$B/partitions/boot.img" -o boot_fedora.img
heimdall flash --BOOT boot_fedora.img --no-reboot
```

## 2. Prepare the SD card

The root must be ext4 (not exFAT) and contain `/usr/lib/systemd/systemd`.
**Formatting erases the card: copy anything you need off it first.**
Untested recipe, from an Ubuntu PC:

```bash
sudo apt install qemu-user-binfmt podman parted e2fsprogs   # older Ubuntu: qemu-user-static
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS     # find the SD card, e.g. /dev/sdX
sudo umount /dev/sdX* 2>/dev/null
sudo parted -s /dev/sdX mklabel msdos mkpart primary ext4 1MiB 100%
sudo mkfs.ext4 -L fedora /dev/sdX1             # double-check sdX is the SD card
sudo mkdir -p /mnt/sd && sudo mount /dev/sdX1 /mnt/sd

sudo podman run --rm --privileged --platform linux/arm64 \
  -v /mnt/sd:/sysroot docker.io/library/fedora:latest sh -c '
  dnf -y --installroot=/sysroot --releasever=$(rpm -E %fedora) --forcearch=aarch64 \
      --use-host-config install systemd passwd bash coreutils util-linux iproute \
      NetworkManager openssh-server &&
  echo "root:changeme" | chroot /sysroot chpasswd &&
  mkdir -p /sysroot/var/log/journal'
sync && sudo umount /mnt/sd
```

If dnf says `--use-host-config` is an unknown option (older dnf4), delete that
flag and run again. Change the root password after the first successful boot.
Any other way of producing a bootable Fedora aarch64 root works too.

## 3. First run is a dry run

With no `/.fedora-go` file on the SD root, the init finds the root, saves
`/root/initramfs-dmesg.txt` on it, and reboots. It does not start Fedora.

1. Insert the SD card, boot the flashed phone.
2. Hands off: no buttons, no cable. Wait 20 to 80 s for it to reboot itself.
3. Photograph the screen "KERNEL LOG (ramoops ...)". Look for lines starting
   `fedora-initramfs:`:
   * `modules: N loaded, M failed` and any `insmod X failed`
   * `partitions:` lines. You need `mmcblk1p1` (the SD card).
   * `root is /dev/mmcblk1p1` means the card was found.
   * `no Fedora root found` plus the partition list means it was not.

Manual power cycles decay RAM and garble the log. Only an automatic warm
reboot keeps it readable.

## 4. Really boot Fedora

```bash
sudo touch /mnt/sd/.fedora-go
```

Boot again. The init then moves /dev, /proc, /sys and runs systemd. Fedora
messages are visible only after a reboot, in the kernel log, plus
`/root/initramfs-dmesg.txt` on the card.

## 5. Known risks and ideas

* The vendor kernel may lack options systemd needs. The log will tell.
* `exynos-tzasc.ko` once caused a BUG() panic; the live DTB fixes the cause.
  If the panic returns, remove that line from `modules.load` in the ramdisk.
* No on-screen console and no USB gadget networking yet. Persistent journald
  on the SD root (`mkdir -p /var/log/journal`) is the next debugging aid.
* The SD card must power up from the vendor kernel. If `mmcblk1` never shows
  up, check the failed-module list for dw_mmc / PMIC drivers.
