#!/bin/bash
# Build a Fedora-booting initramfs for the A145F and patch the bootargs.
# Run from the uniLoader repo root AFTER make_a145f_blobs.py (that script
# overwrites blob/ramdisk and blob/dtb). Keep init next to this script.
#
#   RD_ALL    unpacked stock ramdisk that contains lib/modules  (default ~/rd_all)
#   BUSYBOX   static aarch64 busybox binary                      (default ~/busybox-1.36.1/busybox)
#   OUT       blob directory                                     (default ./blob)
set -euo pipefail

RD_ALL=${RD_ALL:-$HOME/rd_all}
BUSYBOX=${BUSYBOX:-$HOME/busybox-1.36.1/busybox}
OUT=${OUT:-$PWD/blob}
HERE=$(cd "$(dirname "$0")" && pwd)

die() { echo "error: $*" >&2; exit 1; }

[ -f "$HERE/init" ]                       || die "init not found next to this script"
[ -f "$RD_ALL/lib/modules/modules.load" ] || die "no lib/modules/modules.load under $RD_ALL"
[ -f "$BUSYBOX" ]                         || die "busybox not found at $BUSYBOX"
file "$BUSYBOX" | grep -q 'ARM aarch64'   || die "busybox is not an aarch64 binary"
file "$BUSYBOX" | grep -q 'statically'    || die "busybox is not statically linked"
[ -f "$OUT/dtb" ] && [ -f "$OUT/ramdisk" ] || die "run make_a145f_blobs.py first ($OUT/dtb and $OUT/ramdisk missing)"
command -v lz4 >/dev/null && command -v cpio >/dev/null || die "install lz4 and cpio"
command -v fdtget >/dev/null && command -v fdtput >/dev/null || die "install device-tree-compiler"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T"/{bin,dev,proc,sys,mnt,lib/modules}
cp "$RD_ALL"/lib/modules/* "$T/lib/modules/"
cp "$BUSYBOX" "$T/bin/busybox"
install -m 755 "$HERE/init" "$T/init"

# Same format as the stock ramdisk (legacy lz4), which the kernel already accepts.
( cd "$T" && find . | cpio -o -H newc -R 0:0 --quiet | lz4 -l -9 -c ) > "$OUT/ramdisk.new"
mv "$OUT/ramdisk.new" "$OUT/ramdisk"
echo "ramdisk: $(stat -c %s "$OUT/ramdisk") bytes ($(find "$T/lib/modules" -name '*.ko' | wc -l) modules)"

# Fedora has no use for SELinux on this kernel; systemd logs go to the kernel
# log so they reach the ramoops console too.
ARGS=$(fdtget -t s "$OUT/dtb" /chosen bootargs)
for a in selinux=0 systemd.log_target=kmsg; do
	case " $ARGS " in
		*" $a "*) ;;
		*) ARGS="$ARGS $a" ;;
	esac
done
fdtput -t s "$OUT/dtb" /chosen bootargs "$ARGS"
echo "bootargs now ends with: ...${ARGS: -80}"
