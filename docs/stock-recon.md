# Phase 0 — stock recon & backup runbook

Everything the port depends on (eMMC layout, how U-Boot boots, whether boot is
verified, the device tree, radio→phy mapping, ath10k calibration) lives only on
the running unit. Capture it all **before** building or flashing anything. Do
this on the designated guinea-pig unit.

Three captures: **(A)** U-Boot console, **(B)** Linux recon script, **(C)** full
image backup. A, B, C are all read-only except C reads the raw eMMC.

---

## Prereqs
- A 3.3 V USB-UART adapter (CP2102/FT232 etc.). **Not 5 V** — 5 V can kill the SoC.
- `picocom`/`screen`/`minicom` on your workstation. Serial: **115200 8N1, no flow control**.
- Root SSH to the unit on stock firmware (you have this).
- A free USB stick ≥ 8 GB (for the eMMC backup, option C2), or enough disk on the
  workstation to pull a 4 GB image over the network (C1).

Install on Debian/Ubuntu if missing:
`! sudo apt install picocom device-tree-compiler`

---

## A. U-Boot console capture (serial only)

The bootloader env is **not** reliably reachable from Linux, so grab it from the
console. This answers risk #1 (eMMC boot chain) and #2 (verified boot).

1. Open the unit, locate the UART header (TX/RX/GND — likely near the SoC; GND
   first, leave VCC unconnected). Confirm pinout with a multimeter: GND to
   chassis ground, TX idles at 3.3 V.
2. `picocom -b 115200 /dev/ttyUSB0`  (start a log: add `--logfile docs/uboot.log`).
3. Power on and **mash a key** to interrupt autoboot and drop to the U-Boot prompt.
4. At the prompt, run and save the output of:
   ```
   printenv
   bdinfo
   version
   mmc list
   mmc part            # or: part list mmc 0
   help bootm ; help booti ; help bootz
   ```
   The key things to read off `printenv`:
   - `bootcmd` / `bootargs` — how it finds and launches the kernel.
   - whether it loads a **FIT image** (`bootm`) vs raw kernel, and from which
     **mmc partition / offset**.
   - any `verify`, signature, or `fdt` handling → tells us if boot is **signed**.
   - the **recovery** trigger (the 172.16.42.1 httpd stager).
5. **Do not** `saveenv` or write anything. Boot normally: `boot` (or power-cycle).

Save the whole session to `docs/uboot.log` and note `bootcmd`/`bootargs` verbatim
at the top of this file when you have them.

---

## B. Linux recon script (read-only)

`scripts/recon.sh` captures release, CPU/mem, `/proc/cmdline`, partitions, mounts,
`/proc/mtd`, eMMC geometry, the **device tree** (raw + decompiled), radios
(`iw phy`/`iw dev`, lsusb, driver bindings), ath10k calibration location,
ethernet/switch topology, loaded modules, dmesg, and the stock opkg package list.
It only writes a tarball under `/tmp`.

From the workstation (output comes back to you + a tarball on the device):
```sh
ssh root@<pineapple-ip> 'sh -s' < scripts/recon.sh | tee docs/stock-recon.out
scp root@<pineapple-ip>:/tmp/pineapple-recon-*.tar.gz backups/
```
Or paste the script into the serial root shell; it prints the tarball path at the
end — pull it over the network or a USB stick.

What to extract from the tarball afterwards:
- `dt-decompiled.txt` / `device-tree/` → **the seed for our DTS**. If `dtc` was
  absent on the device, decompile the raw tree on the host:
  `dtc -I fs -O dts backups/<recon>/device-tree > docs/stock.dts`
- `partitions.txt` + `mtd.txt` + `fdisk-emmc.txt`/`gpt-emmc.txt` → the eMMC
  **partition map** our image must match.
- `cmdline.txt` + `uboot-env.txt` → confirm the boot chain from the Linux side.
- `wifi-phys.txt` + `iw-phy.txt` + `lsusb.txt` → the 5-radio → phy/driver map.
- `ath10k-cal.txt` + `caldata-mtd.txt` → where the built-in radios' **calibration
  / ART** lives (must be carried into our build).
- `net-config.txt` + `swconfig.txt`/`dsa-ports.txt` → WAN/LAN port mapping.
- `opkg-installed.txt` → what Hak5 shipped (reference for our package set).

---

## C. Full image backup (your rollback)

Back up the whole eMMC **and** the bootloader + env so any mistake is recoverable
even if web-recovery ever fails. Pick one:

**C1 — pull the raw eMMC over the network (nothing to plug in):**
```sh
# ~4 GB; needs 'dd' on the device (busybox has it). Streams to the workstation.
ssh root@<pineapple-ip> 'dd if=/dev/mmcblk0 bs=4M 2>/dev/null' > backups/emmc-full.img
# per-partition, from the names in B's partitions.txt (bootloader/env are the
# ones to be sure of), e.g.:
ssh root@<pineapple-ip> 'dd if=/dev/mmcblk0boot0 2>/dev/null' > backups/mmcblk0boot0.img
ssh root@<pineapple-ip> 'dd if=/dev/mmcblk0boot1 2>/dev/null' > backups/mmcblk0boot1.img
```

**C2 — dump to a USB stick on the device** (if pulling 4 GB over the net is slow):
```sh
# on the unit, with a stick mounted at /mnt/usb:
dd if=/dev/mmcblk0 bs=4M of=/mnt/usb/emmc-full.img
```

**Also download Hak5's recovery + stable images** (the un-brickable escape hatch)
to `backups/`:
- recovery / stable `.bin` from `https://downloads.hak5.org/pineapple/ent1`
- the bootloader web-recovery procedure: host static **172.16.42.42/24**, hold
  reset on power, browse **http://172.16.42.1**, upload the `.bin`.

Verify the backups are non-empty and note their `sha256sum` here before moving on.

---

## Gate to Phase 1
Phase 0 is complete when `backups/` has: the full eMMC image + boot partitions,
the Hak5 recovery `.bin`, the recon tarball, and `docs/stock.dts` +
`docs/uboot.log` with `bootcmd`/`bootargs` recorded. Only then start flashing
experiments (and even then, Phase 1 boots from RAM first).

---

## Findings: U-Boot console (captured 2026-11-15, unit 1)

Full session in `docs/uboot.log` (gitignored). Scripts: `scripts/uboot-interrupt.sh`
(catch the prompt on power-up), `scripts/uboot-cmd.sh` (send one command).

- **U-Boot 2012.07** (`Hak5 WiFi Pineapple Enterprise v1.0`, build 2021-11-26),
  prompt `(IPQ40xx) #`, autoboot message `Hit any key to stop booting`, 2 s delay.
- **Secure boot fuse is not enabled** (`is_sec_boot_enabled`).
- Flash: Macronix **MX25L25635E**, 32 MiB SPI-NOR. eMMC present (`qca_mmc: 0`).
- Environment (complete):
  ```
  bootcmd=bootipq; ping 192.168.1.3; run lfq; bootipq; run httpd; reset
  bootdelay=2
  ethact=eth0
  ipaddr=192.168.1.1
  serverip=192.168.1.3
  machid=8010001
  flash_type=0
  ```
- SMEM partition table (`smeminfo`): same offsets as the stock device tree up
  to ART, then `0:HLOS` at **0x180000** (size 0xa00000). `bootipq` loads the FIT
  from `0:HLOS`, which is where our `firmware` partition starts. Later entries
  (`QSDK_KERNEL` 0x1000000, `rootfs` 0x1400000) overlap the Linux `firmware`
  partition and are not used by the stock OpenWrt-style image.
- Commands available: `tftpboot`, `bootm`, `sf`, `mmc`, `usb`, `dhcp`, `ping`,
  `saveenv`. No `bdinfo`.
- Ethernet MAC reported by U-Boot: `00:13:37:xx:xx:xx`.

## Incident: interrupted stager flash

Refreshing the stager page during the first firmware install left the squashfs
rootfs corrupt (`SQUASHFS error: xz decompression failed`, looping; LEDs solid
blue + green, fast red). Kernel and bootloader were intact. Recovery is via
U-Boot (this section) or Hak5's bootloader web recovery.

## Findings: first RAM boot of our image (2026-11-15, unit 1)

`tftpboot 0x84000000 pineapple.itb` then `bootm 0x84000000` from the U-Boot
prompt (host at 192.168.1.3 running dnsmasq TFTP, cable in an RJ45 port). Boot
log in `docs/boot-ramboot.log` (gitignored).

- Linux 6.12.94 boots; board name `hak5,wifi-pineapple-enterprise-1`.
- All five radios come up: phy0-2 `mt76x2u` (USB 2-1.1, 2-1.2, 2-1.3),
  phy3-4 `ath10k_ahb` with pre-calibration read from ART over NVMEM.
- eMMC: `mmcblk0` 3.64 GiB, HS200, two ext partitions (p1 250 MB, p2 3.4 GB).
- NOR partitions match the stock layout; `firmware` splits into kernel/rootfs.
- DSA ports `lan1-4` and `wan` exist. With the host cable and the USB-C NIC
  attached, **lan3 and lan4** show carrier and `wan` does not, so the USB-C
  (ASIX) NIC is wired internally to a switch port and needs no driver on the
  device.
- Gaps found:
  - No `board.d` network entry, so only `eth0` was bridged and nothing passed
    traffic until the DSA ports were added to `br-lan` by hand.
  - ART offset 0 is blank (0xff). The only MACs in ART are inside the
    pre-calibration blocks: 0x1006 (`00:13:37:xx:xx:xx`, also what U-Boot uses
    for Ethernet) and 0x5006.
- Flash backup of mtd0-mtd8 taken over SSH into `backups/unit1-flash/` with
  SHA256SUMS (mtd8 holds the corrupt stock image).

## Findings: switch port map and eMMC (2026-11-15, unit 1, our firmware)

### Switch ports

Read from the bridge MAC table with the host on both links:

| DSA port | Physical | Evidence |
|---|---|---|
| `lan3` | USB-C (internal ASIX AX88179 NIC) | host USB NIC MAC `00:0e:c6:xx:xx:xx` learned here, 1 Gbps |
| `lan4` | RJ45 **nearest the USB-C port** (the bring-up cable) | host wired MAC learned here, 1 Gbps |
| `wan` | RJ45 **nearest the power inlet** | confirmed: plugged into the LAN it linked on `wan` and got a DHCP lease and internet. It linked at 1 Gbps, dropped after 2 s, and came back at **100 Mbps**; a direct cable to the laptop gave no link at all. Gigabit on this port needs investigating (stock forced 1000/full on gmac1). |
| `lan1`, `lan2` | not seen on any connector | no carrier |

### eMMC (`mmcblk0`, "4FTE4R", 3.64 GiB, HS200)

- MBR table: `p1` 250 MB (sector 16), `p2` 3.4 GB (sector 512016), both type 83.
- `boot0` / `boot1` (4 MiB each): all zeros. The eMMC plays no part in booting.
- `p1`: ext4, created by the factory image, **empty**.
- `p2`: ext4, last mounted on `/tmp/extroot/overlay`. Stock used it as the
  **root overlay (extroot)**: `upper/` and `work/` hold the factory first-boot
  state from 2021-10-24 (`etc/pineapple`, `root/recon.db`, `root/handshakes`).
- Our firmware has no ext4 or block-mount support yet, so it ignores the eMMC
  and keeps its overlay on NOR jffs2 (21 MB).
- Images of `boot0`, `boot1`, `p1`, `p2` and the first 1 MiB are in
  `backups/unit1-emmc/` with SHA256SUMS.

## Findings: eMMC overlay, GPS and time (2026-11-15, unit 1)

- Root overlay now lives on `mmcblk0p2` (ext4, label `pine-overlay`, 3.1 GB
  free), set up by `/etc/uci-defaults/10-pineapple-emmc-overlay` and mounted
  by label from `/etc/config/fstab`. First attempt failed because the label
  `pineapple-overlay` is 17 characters and ext4 truncates at 16.
- Free USB port: a u-blox 7 puck (`1546:01a7`) enumerates on the USB 2 hub as
  `/dev/ttyACM0` (`kmod-usb-acm`). gpsd reports a fix with 11 satellites used.
- chrony runs with four NTP pool sources plus `refclock SHM 0` (GPS); it
  selected an NTP server and showed GPS about 78 ms off, as expected for a
  puck without PPS. busybox ntpd is disabled; timezone is UTC.
- Upgrade behaviour, found by flashing: block's extroot mounts an existing
  `pine-overlay` on the very first boot of a new image, so the old overlay
  (package database, configs, hand-installed files) shadowed the new firmware
  and the uci-defaults script never ran its clean-up. Fixed with
  `/lib/preinit/79_pineapple_overlay`, which compares the overlay's `.rom-id`
  with the running squashfs UUID before `mount_root` and clears `upper/`,
  `work/` and `etc/` on a mismatch. Verified by a second flash: partition UUID
  unchanged, other top-level files kept, 250 packages listed, all kmods present.
- Not yet tested: a settings-preserving sysupgrade (without `-n`) with this
  scheme, and the factory path on a unit that still has the Hak5 stock overlay.
