# OpenWrt for the WiFi Pineapple Enterprise

Board support and a build system for running upstream
[OpenWrt](https://openwrt.org) 25.12 on the Hak5 **WiFi Pineapple Enterprise**
(Qualcomm IPQ4019, OpenWrt target `ipq40xx/generic`).

This is an unofficial project and is not affiliated with or supported by Hak5.
It replaces the stock firmware with plain OpenWrt. It contains no Hak5 software,
so PineAP and the stock web interface are not part of it.

> [!WARNING]
> Installing this needs a serial console and replaces the stock firmware. It has
> been tested on one unit. Back up the flash first (see [Install](#install)),
> and never write to the bootloader or `ART` partitions: `ART` holds the
> radio calibration for that specific unit and cannot be regenerated.

## Status

| | |
|---|---|
| Boot from SPI-NOR, sysupgrade | Works |
| Built-in 2.4/5 GHz radios (ath10k) | Work, calibration read from `ART` |
| 3× MT7612U USB radios (mt76x2u) | Work |
| Ethernet switch, USB-C network port | Work |
| 4 GB eMMC | Works, used as the root overlay |
| LEDs, reset button | Defined from the stock device tree; polarity not verified |

Known issues:

- The WAN port links at 1 Gbps, drops, and comes back at 100 Mbps.
- The radios log `command failed: Not supported (-95)` at startup.
- A sysupgrade that keeps settings is untested. Use `sysupgrade -n`.
- First boot on a unit whose eMMC still holds the stock overlay is untested.

## Hardware

| | |
|---|---|
| SoC | Qualcomm IPQ4019, 4× Cortex-A7 |
| RAM | 1 GB |
| Boot flash | 32 MB SPI-NOR, Qualcomm layout, FIT image in `firmware` at `0x180000` |
| Storage | 4 GB eMMC, not in the boot path |
| Wi-Fi | 2× IPQ4019 built-in (ath10k) and 3× MT7612U on an internal USB 3 hub |
| Ethernet | QCA8075 switch (DSA) and an internal ASIX AX88179 behind the USB-C port |
| Console | UART on GPIO16 (TX) / GPIO17 (RX), 3.3 V, 115200 8N1 |
| Bootloader | U-Boot 2012.07, unsigned FIT, secure boot not enabled |

Port map:

| Interface | Connector |
|---|---|
| `wan` | RJ45 nearest the power inlet |
| `lan4` | RJ45 nearest the USB-C port |
| `lan3` | USB-C port (shows up on your computer as a USB network adapter) |
| `lan1`, `lan2` | not connected to anything |

The USB-C port is a network port only. It cannot act as a USB serial or storage
device.

## What the image contains

- OpenWrt v25.12.5 (Linux 6.12) with LuCI over HTTPS.
- The root overlay on the eMMC (about 3 GB free for packages and data). It is
  cleared automatically when a new image is flashed.
- gpsd and chrony. A USB GPS on `/dev/ttyACM0` is used as a fallback time
  source after NTP. The clock is UTC.
- WireGuard, tcpdump, `iw-full`, `ip-full`, USB storage, USB serial and USB
  tethering drivers, MT7921U support, and common admin tools.

The package list is in [`diffconfig`](diffconfig). Change it with
`make menuconfig`.

## Build

Host packages (Debian/Ubuntu):

```sh
sudo apt install build-essential clang flex bison g++ gawk gettext git \
  libncurses-dev libssl-dev python3-dev python3-setuptools rsync swig unzip \
  zlib1g-dev libelf-dev file wget device-tree-compiler u-boot-tools
```

```sh
make              # clone OpenWrt, add the board support, configure, build
make menuconfig   # change the config; the minimal diff is saved to ./diffconfig
```

The Pineapple Enterprise is not an upstream OpenWrt device, so the `Makefile`
clones a pinned OpenWrt release and adds the board to it before building:

- [`files/`](files) is copied over the tree: the device tree and the files that
  go into the image.
- [`patches/`](patches) are applied to the tree: the device definition and the
  network and MAC address defaults.

Images are written to `openwrt/bin/targets/ipq40xx/generic/`:

| File | Use |
|---|---|
| `…-squashfs-sysupgrade.bin` | the image to flash |
| `…-initramfs-uImage.itb` | runs from RAM over TFTP, for the first install |
| `openwrt-sdk-*.tar.zst` | SDK for building packages out of tree |
| `openwrt-imagebuilder-*.tar.zst` | ImageBuilder |

## Install

The first install goes through U-Boot. It boots OpenWrt from RAM, and you flash
from there. Nothing is written until the last step.

1. Attach a 3.3 V USB-UART adapter to the console at 115200 8N1.
2. Give your computer the address `192.168.1.3/24`, connect it to the RJ45
   nearest the USB-C port, and serve the initramfs image over TFTP as
   `pineapple.itb`.
3. Power-cycle the unit and press a key at `Hit any key to stop booting`.
   [`scripts/uboot-interrupt.sh`](scripts/uboot-interrupt.sh) does this for you.
4. At the `(IPQ40xx) #` prompt:

   ```
   tftpboot 0x84000000 pineapple.itb
   bootm 0x84000000
   ```

5. OpenWrt is now running from RAM at `192.168.1.1`. Back up the flash:

   ```sh
   for i in 0 1 2 3 4 5 6 7 8; do
     ssh root@192.168.1.1 "cat /dev/mtd$i" > mtd$i.bin
   done
   ```

6. Copy the sysupgrade image to `/tmp` on the unit and flash it:

   ```sh
   sysupgrade -n /tmp/openwrt-…-squashfs-sysupgrade.bin
   ```

After the reboot the unit is at `192.168.1.1` on the LAN ports, with LuCI at
`https://192.168.1.1`. The `root` account has no password until you set one.

Later upgrades are a plain `sysupgrade -n` from the running system.

## Recovery

- **U-Boot and TFTP:** the RAM-boot steps above work as long as the bootloader
  is intact, whatever state the firmware is in.
- **Back to stock:** Hak5 documents a bootloader web recovery. Set your
  computer to `172.16.42.42/24`, hold reset while applying power, browse to
  `http://172.16.42.1`, and upload a stock image from
  <https://downloads.hak5.org/pineapple/ent1>. This project has not tested it.

## More detail

- [`docs/stock-recon.md`](docs/stock-recon.md): how the stock unit was
  examined, and the findings from bring-up.
- [`docs/stock-pineapple-ent.dts`](docs/stock-pineapple-ent.dts): the device
  tree decompiled from stock firmware 2.1.3, which ours is derived from.
- [`PLAN.md`](PLAN.md): the original plan, hardware notes and open questions.
