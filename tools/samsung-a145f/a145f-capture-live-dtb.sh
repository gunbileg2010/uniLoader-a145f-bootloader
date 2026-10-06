#!/bin/sh
# Dump the device tree Samsung's bootloader handed to the running STOCK kernel.
# Boot stock Android first (restore the stock boot.img), root shell needed.
#   ./a145f-capture-live-dtb.sh [outdir]
set -e
out="${1:-live-dtb}"; mkdir -p "$out"
adb get-state >/dev/null
adb exec-out su -c "cat /sys/firmware/fdt" > "$out/stock_live.dtb"
adb exec-out su -c "cat /proc/iomem"       > "$out/iomem.txt"
adb exec-out su -c "cat /proc/cmdline"     > "$out/cmdline.txt"
sz=$(stat -c %s "$out/stock_live.dtb")
magic=$(head -c4 "$out/stock_live.dtb" | od -An -tx1 | tr -d ' \n')
[ "$magic" = "d00dfeed" ] || { echo "not a device tree (magic $magic): is su allowed?"; exit 1; }
echo "stock_live.dtb: $sz bytes"
echo "next: make_a145f_blobs.py ... --live-dtb $out/stock_live.dtb --out blob"
