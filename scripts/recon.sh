#!/bin/sh
# recon.sh — read-only hardware/firmware recon for the WiFi Pineapple Enterprise.
#
# Runs ON the device, on the STOCK Hak5 firmware (OpenWrt/busybox ash). It only
# READS: it writes a tarball to /tmp and prints to stdout. It never touches eMMC,
# U-Boot env, or config. Safe to run on a production unit.
#
# Usage, over SSH from your workstation (recommended — output comes back to you):
#     ssh root@<pineapple-ip> 'sh -s' < scripts/recon.sh | tee docs/stock-recon.out
# then copy the tarball off:
#     scp root@<pineapple-ip>:/tmp/pineapple-recon-*.tar.gz backups/
#
# Or paste the whole script into a serial (UART) root shell; the tarball path is
# printed at the end, retrieve it over the network or a USB stick.

set -u
OUT="/tmp/pineapple-recon-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)"
mkdir -p "$OUT" 2>/dev/null || { echo "cannot create $OUT"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# run a labeled, read-only capture: cap <slug> <command...>
cap() {
	slug=$1; shift
	f="$OUT/$slug.txt"
	{
		echo "### $slug: $*"
		echo "### $(date 2>/dev/null)"
		echo "----------------------------------------------------------------"
		"$@" 2>&1
		echo "### exit=$?"
	} >"$f" 2>&1
	echo "  [captured] $slug"
}

# copy a file/tree verbatim if it exists: grab <src> <destname>
grab() {
	[ -e "$1" ] || { echo "  [skip]     $2 (no $1)"; return; }
	cp -a "$1" "$OUT/$2" 2>/dev/null && echo "  [grabbed]  $2 ($1)" \
		|| echo "  [fail]     $2 ($1)"
}

echo "== Pineapple Enterprise recon -> $OUT"
echo "== read-only; writes only under /tmp"
echo

# --- identity / release -------------------------------------------------------
cap os-release          cat /etc/os-release
cap banner              cat /etc/banner
cap openwrt-release     cat /etc/openwrt_release
cap uname               uname -a
cap kver                cat /proc/version
cap hostname            cat /proc/sys/kernel/hostname

# --- cpu / memory -------------------------------------------------------------
cap cpuinfo             cat /proc/cpuinfo
cap meminfo             cat /proc/meminfo
cap loadavg             cat /proc/loadavg

# --- boot: cmdline + bootloader env -------------------------------------------
# This is the crux: how U-Boot hands off, and whether boot is verified.
cap cmdline             cat /proc/cmdline
if have fw_printenv; then
	cap uboot-env       fw_printenv            # needs /etc/fw_env.config to be set
	grab /etc/fw_env.config fw_env.config
else
	echo "  [note]     fw_printenv absent — capture U-Boot 'printenv' from the UART console instead (see runbook)"
fi

# --- storage: partitions, filesystems, flash ---------------------------------
cap partitions          cat /proc/partitions
cap mounts              cat /proc/mounts
cap mtd                 cat /proc/mtd
cap mtd-sys             ls -l /sys/class/mtd
cap block-info          sh -c 'block info 2>/dev/null || true'
cap df                  df -h
if have fdisk;   then cap fdisk-emmc  sh -c 'fdisk -l /dev/mmcblk0 2>/dev/null'; fi
if have sgdisk;  then cap gpt-emmc    sh -c 'sgdisk -p /dev/mmcblk0 2>/dev/null'; fi
cap mmc-sys             sh -c 'for d in /sys/block/mmcblk*; do echo "== $d"; cat "$d/size" "$d/ro" 2>/dev/null; cat "$d"/device/{name,type,manfid,oemid,serial} 2>/dev/null; done'
cap mmc-partitions      sh -c 'ls -l /dev/mmcblk* 2>/dev/null'
# A/B slot hints
cap ubootenv-file       sh -c 'cat /proc/device-tree/chosen/* 2>/dev/null | tr -c "[:print:]\n" " "'

# --- device tree (GOLD: basis for our DTS) ------------------------------------
if have dtc; then
	cap dt-decompiled   dtc -I fs -O dts /proc/device-tree
else
	echo "  [note]     dtc absent on device — grabbing raw /proc/device-tree; decompile on host with: dtc -I fs -O dts device-tree"
fi
grab /proc/device-tree device-tree         # raw tree, always
cap dt-model            cat /proc/device-tree/model
cap dt-compatible       sh -c 'cat /proc/device-tree/compatible | tr "\0" "\n"'

# --- radios / wifi ------------------------------------------------------------
cap lsusb               sh -c 'lsusb 2>/dev/null || cat /sys/kernel/debug/usb/devices 2>/dev/null'
cap usb-tree            sh -c 'ls -l /sys/bus/usb/devices 2>/dev/null'
if have iw; then
	cap iw-phy          iw phy
	cap iw-dev          iw dev
	cap iw-reg          iw reg get
fi
cap wifi-phys           sh -c 'for p in /sys/class/ieee80211/*; do echo "== $p"; cat "$p/index" "$p/macaddress" 2>/dev/null; ls "$p/device/driver" 2>/dev/null; readlink -f "$p/device/driver" 2>/dev/null; done'
cap net-wireless-cfg    sh -c 'cat /etc/config/wireless 2>/dev/null'
# ath10k calibration / ART — must be carried into our build
cap ath10k-cal          sh -c 'ls -lR /lib/firmware/ath10k 2>/dev/null; find / -iname "*caldata*" -o -iname "*.art" -o -iname "art" 2>/dev/null | head'
cap caldata-mtd         sh -c 'grep -i -E "art|caldata|cal" /proc/mtd 2>/dev/null'

# --- ethernet / switch --------------------------------------------------------
if have ip; then
	cap ip-link         ip -d link
	cap ip-addr         ip addr
else
	cap ifconfig        ifconfig -a
fi
if have swconfig; then cap swconfig sh -c 'swconfig dev switch0 show 2>/dev/null; swconfig list 2>/dev/null'; fi
cap net-config          sh -c 'cat /etc/config/network 2>/dev/null'
cap dsa-ports           sh -c 'ls -l /sys/class/net/*/dsa 2>/dev/null; for n in /sys/class/net/*; do echo "$n: $(cat $n/operstate 2>/dev/null)"; done'
cap asix-nic            sh -c 'dmesg 2>/dev/null | grep -i -E "asix|ax88|usb.*eth"'

# --- kernel modules / drivers in use -----------------------------------------
cap lsmod               sh -c 'lsmod 2>/dev/null || cat /proc/modules'
cap drivers             sh -c 'for d in ath10k_pci ath10k_core mt76x2u mt76x2_common mt76_usb mt76 asix ax88179_178a; do echo "== $d"; ls /sys/module/$d 2>/dev/null >/dev/null && echo loaded || echo absent; done'

# --- dmesg / logs -------------------------------------------------------------
cap dmesg               sh -c 'dmesg 2>/dev/null'
if have logread; then cap logread logread; fi

# --- packages / opkg (what Hak5 shipped) --------------------------------------
if have opkg; then
	cap opkg-installed  opkg list-installed
	grab /etc/opkg.conf  opkg.conf
	grab /etc/opkg       opkg.d
fi
cap processes           sh -c 'ps w 2>/dev/null || ps'
cap listening           sh -c 'netstat -ltnup 2>/dev/null || ss -ltnup 2>/dev/null'

# --- pack it up ---------------------------------------------------------------
TARBALL="$OUT.tar.gz"
( cd "$(dirname "$OUT")" && tar czf "$TARBALL" "$(basename "$OUT")" ) 2>/dev/null \
	&& echo && echo "== DONE. Tarball: $TARBALL" \
	|| echo "== DONE (tar failed; the files are under $OUT)"
echo "== Copy it off, e.g.:  scp root@<ip>:$TARBALL backups/"
