#!/bin/bash
# Laptop side: capture the phone's USB serial console and report self-test results.
# Usage: a145f-test-host.sh [/dev/ttyACM0] [timeout_seconds] [--rerun]
#   Needs read access to the tty (sudo or dialout group). Exit 0 = no FAIL, 1 = FAIL, 2 = no result.
DEV=${1:-}; TMO=${2:-240}; RERUN=${3:-}
if [ -z "$DEV" ]; then
	echo "waiting for /dev/ttyACM* (boot the phone, cable in) ..."
	for _ in $(seq "$TMO"); do DEV=$(ls /dev/ttyACM* 2>/dev/null | head -1); [ -n "$DEV" ] && break; sleep 1; done
fi
[ -c "$DEV" ] || { echo "no serial device found"; exit 2; }
LOG=a145f-selftest-$(date +%Y%m%d-%H%M%S).log
stty -F "$DEV" 115200 raw -echo
echo "reading $DEV -> $LOG"
[ "$RERUN" = --rerun ] && { sleep 1; echo run > "$DEV"; }
timeout "$TMO" bash -c 'while IFS= read -r l; do echo "$l"; case "$l" in "SELFTEST end"*) break;; esac; done < "$0"' "$DEV" | tr -d '\r' | tee "$LOG"
echo; echo "===== results ====="
grep '^TEST' "$LOG" | awk '{c=($3=="PASS")?"\033[32m":($3=="FAIL")?"\033[31m":"\033[33m"; printf "%s%-5s\033[0m %-18s", c,$3,$2; $1=$2=$3=""; print $0}'
grep -q '^SUMMARY' "$LOG" || { echo "no SUMMARY line: selftest did not finish"; exit 2; }
grep '^SUMMARY' "$LOG"
grep -q '^TEST .* FAIL' "$LOG" && exit 1 || exit 0
