#!/bin/bash
# uboot-interrupt.sh — catch the U-Boot prompt over serial.
#
# Logs the console and sends a space every 100 ms until autoboot is
# interrupted, then stops sending. Start it, then power-cycle the unit.
#
#   scripts/uboot-interrupt.sh [tty] [logfile] [timeout-seconds]

TTY=${1:-/dev/ttyUSB0}
LOG=${2:-docs/uboot.log}
TIMEOUT=${3:-180}

stty -F "$TTY" 115200 cs8 -cstopb -parenb -icrnl -ixon raw -echo || exit 1
: >"$LOG"
cat "$TTY" >>"$LOG" &
CAT=$!
trap 'kill $CAT 2>/dev/null' EXIT

end=$((SECONDS + TIMEOUT))
seen_boot=0
while [ $SECONDS -lt $end ]; do
	# A fresh boot shows the U-Boot banner; only then is a prompt meaningful.
	if [ $seen_boot = 0 ] && grep -aqE 'U-Boot [0-9]{4}\.' "$LOG"; then
		seen_boot=1
		echo "U-Boot banner seen"
	fi
	if [ $seen_boot = 1 ]; then
		if grep -aqE 'Starting kernel|Booting kernel' "$LOG"; then
			echo "MISSED: kernel started before autoboot was interrupted"
			tail -n 30 "$LOG"
			exit 2
		fi
		# Autoboot message gone by and no kernel start within 3 s => prompt.
		if grep -aqiE 'autoboot|stop booting' "$LOG"; then
			sleep 3
			if ! grep -aqE 'Starting kernel|Booting kernel' "$LOG"; then
				printf '\r' >"$TTY"
				sleep 1
				echo "INTERRUPTED: at the U-Boot prompt"
				tail -n 40 "$LOG"
				exit 0
			fi
		fi
	fi
	printf ' ' >"$TTY"
	sleep 0.1
done
echo "TIMEOUT: no U-Boot banner in ${TIMEOUT}s (was the unit power-cycled?)"
tail -n 20 "$LOG"
exit 1
