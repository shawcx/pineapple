#!/bin/bash
# uboot-cmd.sh — send one command to the serial console and print the reply.
#
#   scripts/uboot-cmd.sh "printenv" [wait-seconds] [tty]
#
# Appends everything to docs/uboot.log as well. Works for the U-Boot prompt
# and for a Linux shell on the same console.

CMD=$1
WAIT=${2:-3}
TTY=${3:-/dev/ttyUSB0}
LOG=${UBOOT_LOG:-docs/uboot.log}

stty -F "$TTY" 115200 cs8 -cstopb -parenb -icrnl -ixon raw -echo || exit 1
TMP=$(mktemp)
cat "$TTY" >"$TMP" &
CAT=$!
trap 'kill $CAT 2>/dev/null; rm -f "$TMP"' EXIT

# U-Boot 2012.07 has no input FIFO to speak of: send slowly, char by char.
for ((i = 0; i < ${#CMD}; i++)); do
	printf '%s' "${CMD:i:1}" >"$TTY"
	sleep 0.01
done
printf '\r' >"$TTY"
sleep "$WAIT"
kill $CAT 2>/dev/null
tr -d '\r' <"$TMP" | tee -a "$LOG"
echo
