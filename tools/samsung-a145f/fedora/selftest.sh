#!/bin/sh
# Hardware self-test for the Galaxy A14 4G (SM-A145F), run from the initramfs
# (busybox ash). Prints machine-readable lines:
#   TEST <name> PASS|FAIL|SKIP <detail>
#   SUMMARY pass=N fail=N skip=N
# WRITE=1 additionally does a destructive-free write test (a file on tmpfs and,
# if mounted, a file on the SD root). Never writes to the internal eMMC.
P=0; F=0; S=0
t() { # name status detail
	case "$2" in PASS) P=$((P+1));; FAIL) F=$((F+1));; *) S=$((S+1));; esac
	echo "TEST $1 $2 $3"
}
echo "SELFTEST begin $(date 2>/dev/null) kernel=$(uname -r)"

# --- CPU ---------------------------------------------------------------
n=$(grep -c '^processor' /proc/cpuinfo)
[ "$n" -eq 8 ] && t cpu.cores PASS "$n cores" || t cpu.cores FAIL "$n cores (expected 8)"
parts=$(grep -i 'CPU part' /proc/cpuinfo | sort | uniq -c | tr -s ' ' | tr '\n' ';')
case "$parts" in *0xd05*) t cpu.core_type PASS "Cortex-A55 $parts";; *) t cpu.core_type FAIL "$parts";; esac
online=$(cat /sys/devices/system/cpu/online 2>/dev/null)
[ "$online" = "0-7" ] && t cpu.online PASS "$online" || t cpu.online FAIL "online=$online"
fmax=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
[ -n "$fmax" ] && t cpu.max_freq PASS "cpu0 max ${fmax} kHz" || t cpu.max_freq SKIP "no cpufreq"
# integer workload: must finish, checksum must be stable
a=$(i=0; s=0; while [ $i -lt 20000 ]; do s=$(( (s*31 + i) % 1000003 )); i=$((i+1)); done; echo $s)
b=$(i=0; s=0; while [ $i -lt 20000 ]; do s=$(( (s*31 + i) % 1000003 )); i=$((i+1)); done; echo $s)
[ "$a" = "$b" ] && t cpu.compute PASS "checksum $a" || t cpu.compute FAIL "$a != $b"

# --- RAM ---------------------------------------------------------------
kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
[ "$kb" -ge 3300000 ] && t ram.total PASS "${kb} kB" || t ram.total FAIL "${kb} kB (expected >= 3300000)"
mkdir -p /ramt; mount -t tmpfs -o size=256m tmpfs /ramt 2>/dev/null
if dd if=/dev/urandom of=/ramt/a bs=1M count=128 2>/dev/null; then
	cp /ramt/a /ramt/b
	if cmp -s /ramt/a /ramt/b; then
		t ram.pattern PASS "128 MiB random copy compare ok"
	else
		t ram.pattern FAIL "128 MiB copy mismatch"
	fi
else
	t ram.pattern SKIP "tmpfs unavailable"
fi
rm -f /ramt/a /ramt/b; umount /ramt 2>/dev/null

# --- storage -----------------------------------------------------------
sz() { awk -v d="$1" '$4==d {print int($3/1024)}' /proc/partitions; }
e=$(sz mmcblk0)
if [ -z "$e" ]; then t emmc.present FAIL "mmcblk0 missing"
elif [ "$e" -ge 55000 ]; then t emmc.present PASS "${e} MiB"
else t emmc.present FAIL "${e} MiB (expected ~58000+)"; fi
if [ -b /dev/mmcblk0 ]; then
	r=$(dd if=/dev/mmcblk0 of=/dev/null bs=1M count=64 2>&1 | tail -1)
	case "$r" in *copied*) t emmc.read PASS "$r";; *) t emmc.read FAIL "$r";; esac
fi
s=$(sz mmcblk1)
if [ -z "$s" ]; then t sd.present SKIP "no SD card in slot"
else
	t sd.present PASS "${s} MiB"
	r=$(dd if=/dev/mmcblk1 of=/dev/null bs=1M count=64 2>&1 | tail -1)
	case "$r" in *copied*) t sd.read PASS "$r";; *) t sd.read FAIL "$r";; esac
	if [ "$WRITE" = 1 ] && grep -q ' /mnt ' /proc/mounts; then
		dd if=/dev/urandom of=/mnt/.selftest bs=1M count=32 2>/dev/null
		sync
		c1=$(cksum < /mnt/.selftest)
		echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
		c2=$(cksum < /mnt/.selftest)
		rm -f /mnt/.selftest
		[ "$c1" = "$c2" ] && t sd.write PASS "32 MiB write/readback ok" || t sd.write FAIL "cksum $c1 vs $c2"
	elif [ "$WRITE" = 1 ]; then t sd.write SKIP "SD root not mounted"; fi
fi

# --- USB ---------------------------------------------------------------
u=$(ls /sys/class/udc 2>/dev/null | head -1)
[ -n "$u" ] && t usb.udc PASS "$u state=$(cat /sys/class/udc/$u/state)" || t usb.udc FAIL "no UDC"
[ -c /dev/ttyGS0 ] && t usb.serial PASS "/dev/ttyGS0" || t usb.serial FAIL "no ttyGS0"
spd=$(cat /sys/class/udc/$u/current_speed 2>/dev/null)
case "$spd" in high-speed|super-speed*) t usb.speed PASS "$spd";; "") t usb.speed SKIP "n/a";; *) t usb.speed FAIL "$spd";; esac
nh=$(ls /sys/bus/usb/devices 2>/dev/null | grep -c '^[0-9]-[0-9.]*$')
t usb.host_devices SKIP "$nh attached (host mode needs OTG; informational)"

# --- GPU / misc --------------------------------------------------------
if ls /sys/class/misc 2>/dev/null | grep -qi mali || ls /dev/mali* >/dev/null 2>&1 || ls /sys/devices/platform 2>/dev/null | grep -qi mali; then
	t gpu.mali PASS "Mali device node present"
else t gpu.mali SKIP "no Mali node in initramfs (module not loaded)"; fi
th=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
[ -n "$th" ] && t thermal PASS "zone0 $th" || t thermal SKIP "none"
bc=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
[ -n "$bc" ] && t battery PASS "${bc}%" || t battery SKIP "none"

echo "SUMMARY pass=$P fail=$F skip=$S"
echo "SELFTEST end"
