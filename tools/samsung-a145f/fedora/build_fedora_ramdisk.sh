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
# modules.min: the SD-card subset of modules.load (dependency closure, same
# order). FULL_MODULES=1 skips it and loads all of modules.load.
if [ "${FULL_MODULES:-0}" != 1 ]; then
	python3 - "$RD_ALL/lib/modules" "$T/lib/modules/modules.min" <<'PY'
import sys, os
d, out = sys.argv[1:3]
dep = {}
for l in open(os.path.join(d, "modules.dep")):
    k, _, v = l.partition(":")
    dep[os.path.basename(k.strip())] = [os.path.basename(x) for x in v.split()]
order = [os.path.basename(l.strip()) for l in open(os.path.join(d, "modules.load")) if l.strip()]
need = set()
def add(m):
    if m in need: return
    need.add(m)
    for x in dep.get(m, []): add(x)
for m in ("dw_mmc-exynos-sec.ko", "dw_mmc-exynos-fmp.ko", "dw_mmc-srpmb.ko", "dw_mmc-pltfm.ko",
          "dw_mmc.ko", "s2mpu12-regulator.ko", "s2mpu12_mfd.ko", "pinctrl-samsung-core.ko",
          "clk_exynos.ko", "i2c-exynos5.ko", "exynos-pmu.ko", "exynos-pd.ko", "exynos-chipid_v2.ko",
          # USB device mode: Samsung's OTG state machine only starts the gadget when
          # the cable-detect chain (MUIC / USB-PD / notifier) reports VBUS.
          "dwc3-exynos-usb.ko", "phy-exynos-usbdrd-super.ko", "usb_notifier.ko", "usb_notify_layer.ko",
          "vbus_notifier.ko", "usb_typec_manager.ko", "if_cb_manager.ko", "mfd_s2mu106.ko",
          "muic_platform.ko", "common_muic.ko", "muic_s2mu106.ko", "s2mu106-usbpd.ko",
          "pdic_notifier_module.ko", "s2m_pdic_notifier_module.ko", "switch_class.ko"):
    add(m)
open(out, "w").write("\n".join(m for m in order if m in need) + "\n")
print("modules.min:", len([m for m in order if m in need]), "modules")
PY
fi
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
