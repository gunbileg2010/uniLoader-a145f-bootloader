#!/bin/bash
# DEBUG image: splash picture plus the previous-boot kernel log and bootloader
# log screens (about 50 s extra per boot when a log exists).
# Run from anywhere; it cd's to the uniLoader repo root.
#
#   B=...        a145f backup dir with partitions/ and info/
#                (default ~/Downloads/uniLoader-a145f-bootloader/a145f-backup)
#   FEDORA=1     also build the Fedora initramfs (needs RD_ALL and BUSYBOX,
#                see Documentation/samsung-a145f-fedora.md)
#   SKIP_BLOBS=1 reuse blob/ from the last run instead of rebuilding it
#   FLASH=1      flash with heimdall when done (phone in Download mode)
#   JOBS=N       parallel make jobs (default: all cores)
set -euo pipefail
cd "$(dirname "$0")/../.."

MODE=debug
CFG=a145f_${MODE}_defconfig
OUT=boot_a145f_${MODE}.img
B=${B:-$HOME/Downloads/uniLoader-a145f-bootloader/a145f-backup}
die() { echo "error: $*" >&2; exit 1; }

for t in aarch64-linux-gnu-gcc python3 fdtput fdtoverlay; do
	command -v "$t" >/dev/null || die "missing $t (sudo apt install gcc-aarch64-linux-gnu device-tree-compiler python3)"
done
[ -f "$B/partitions/boot.img" ] || die "backup not found at $B (set B=...)"

# blobs first: they are linked into uniLoader
if [ "${SKIP_BLOBS:-0}" != 1 ]; then
	echo ">> stock blobs"
	python3 tools/samsung-a145f/make_a145f_blobs.py \
		--boot "$B/partitions/boot.img" --vendor-boot "$B/partitions/vendor_boot.img" \
		--init-boot "$B/partitions/init_boot.img" --dtbo "$B/partitions/dtbo.img" \
		--getprop "$B/info/getprop.txt" \
		--live-dtb tools/samsung-a145f/live-dtb/stock_live.dtb --out blob
	if [ "${FEDORA:-0}" = 1 ]; then
		echo ">> Fedora initramfs"
		RD_ALL=${RD_ALL:-$HOME/rd_all} BUSYBOX=${BUSYBOX:-$HOME/busybox-1.36.1/busybox} \
			bash tools/samsung-a145f/fedora/build_fedora_ramdisk.sh
	fi
fi

echo ">> building uniLoader ($MODE)"
make clean >/dev/null 2>&1 || true     # stale objects have shipped old screens before
make "$CFG"
make -j"${JOBS:-$(nproc)}" CROSS_COMPILE=aarch64-linux-gnu-
n=$(grep -c -a "KERNEL LOG (ramoops" uniLoader || true)
[ "$n" = 1 ] || die "log screens missing from the binary (stale build, do not flash)"
echo "   check ok (log screens present)"

echo ">> packing $OUT"
python3 tools/samsung-a145f/pack_boot_v4.py uniLoader --stock "$B/partitions/boot.img" -o "$OUT"
ls -l "$OUT"
if [ "${FLASH:-0}" = 1 ]; then
	heimdall flash --BOOT "$OUT" --no-reboot
else
	echo "flash with:  heimdall flash --BOOT $OUT --no-reboot"
fi
