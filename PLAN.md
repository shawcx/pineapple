# pineapple — custom OpenWrt firmware for the WiFi Pineapple Enterprise

Custom firmware for several Hak5 **WiFi Pineapple Enterprise** units, built as a
**private fork of upstream OpenWrt** (no Hak5 code). The goal is a DIY wireless
security-testing platform on modern OpenWrt + kernel, with the standard
open-source wireless-audit toolset, managed as a small fleet.

A `Makefile` clones a
pinned OpenWrt, applies our files overlay (device definition, DTS, config),
and builds the image, SDK, and ImageBuilder from one tree.

## Hardware (confirmed)

Hak5 shop spec + docs; the "8devices Pineapple" module is an unrelated Wi-Fi-6E
part (name collision), **not** this board.

| | |
|---|---|
| SoC | Qualcomm **IPQ4019** — 4× ARM Cortex-A7 @ 716 MHz → OpenWrt target **`ipq40xx`** |
| RAM | 1 GB DDR3L (`memory@0`, `0x40000000`) |
| Boot flash | **32 MB SPI-NOR** (`jedec,spi-nor`), standard Qualcomm layout; `firmware` partition is a `denx,fit` (FIT) |
| Data storage | **4 GB eMMC** on a *separate* `sdhci@7824900` controller — persistent/overlay only, **not** in the boot path |
| Radio 0/1 | IPQ4019 built-in 2.4/5 GHz 2×2 ac wave-2 → **`ath10k`** (mainline); cal variant `Hak5-WiFi-Pineapple-Ent-1`, ART in NOR `0:ART` |
| Radio 2/3/4 | 3× MediaTek **MT7612U** (USB, 2.4/5 GHz 2×2) → **`mt76x2u`** (mainline), on the single `dwc3` USB3 host via internal hub |
| Ethernet | `qcom,ess-switch`: **gmac1 = WAN** (port 5, forced 1 Gbps), **gmac0 = LAN** (ports 1–4). Plus USB-C 3.0 **ASIX AX88179** NIC (`ax88179_178a`) |
| Console | UART `serial@78af000`, **GPIO16 TX / GPIO17 RX**, 115200 8N1 |
| LEDs / keys | 4× RGB status LEDs + reset button (GPIO53), all GPIO-mapped in the stock DTS |
| Power / form | 100–240 V AC, 1U rack, 160×244×41 mm |
| Recovery | Bootloader web recovery: hold reset on power, host static **172.16.42.42/24**, browse **http://172.16.42.1**, upload `.bin` |

**Stock firmware analysed:** `upgrade-ent-2.1.3-stable` (Oct 2022), OpenWrt-based,
**Linux 5.4.154**. Its FIT is **unsigned** (crc32 + sha1 integrity only). The
full decompiled stock device tree is at `docs/stock-pineapple-ent.dts` — model
`Hak5 WiFi Pineapple Enterprise 1.0`, compatible
`hak5,wifi-pineapple-enterprise-1`, `qcom,ipq4019`.

**Implication:** every active component has a mainline OpenWrt driver, and the
board is a near-textbook **ipq40xx SPI-NOR + FIT** device. The work is a
straightforward board bring-up (DTS we already have, image recipe producing a
FIT into the `firmware` partition, sysupgrade), **not** driver porting and
**not** a tricky eMMC boot chain.

## Strategy & decisions

- **Upstream OpenWrt, pinned.** Latest stable: the **25.12** series
  (`OPENWRT_VERSION ?= v25.12.5`, overridable; kernel 6.12.x). Security support
  for 24.10 ends Sept 2026, so 25.12 is the right base. Our changes live as a
  **files overlay + patches** applied to the clone; the clone is never committed.
- **Private fork.** Shortcuts allowed, no upstreaming goal. But write the DTS and
  partition map cleanly anyway — it's the difference between a maintainable fork
  and a brittle one, and costs little.
- **Keep the stock bootloader.** Do **not** reflash U-Boot. We make our kernel +
  rootfs load from the partitions the stock bootloader already expects. The Hak5
  web-recovery path (172.16.42.1) stays our un-brickable escape hatch throughout.
- **Never brick.** Before writing anything, take a full eMMC + bootloader-env
  backup over UART/SSH, and keep the stock recovery `.bin` on hand. One unit is
  the designated guinea pig.
- **Fleet model (your answers):** one image for all units; **per-unit
  provisioning** on first boot; each unit **phones home over WireGuard**;
  **central OTA** via signed sysupgrade pulled from our server.

## Phases

### Phase 0 — Recon & backup (do before building anything)
The whole port hinges on facts only the live device has. Open the guinea-pig
unit, attach a 3.3 V USB-UART (115200 8N1), and over serial + root SSH capture:
- U-Boot: version, full `printenv`, `bootcmd`/`bootargs`, how it finds the kernel
  (eMMC partition? FIT image? `mmc`/`bootm` commands), and the recovery trigger.
- Kernel cmdline (`/proc/cmdline`), `/proc/partitions`, eMMC layout
  (`gpt`/`fdisk -l /dev/mmcblk0`, or `/proc/mtd` if any), mount map, A/B slots?
- The live **device tree**: `dtc -I fs /proc/device-tree > stock.dts` (gold — the
  basis for our DTS), plus `/sys/firmware/devicetree`.
- Radio mapping: `iw dev`, `iw phy`, `lsusb`, which phy is ath10k vs each
  mt76x2u, MAC assignments, calibration/ART data location for the ath10k.
- Switch/ethernet topology (`swconfig`/DSA, which port is WAN/LAN), ASIX NIC.
- **Backups:** `dd` the whole eMMC and the U-Boot env off the device; download
  the stock + RECOVERY `.bin` from downloads.hak5.org. Store under `backups/`.

Deliverable: `docs/stock-recon.md` + `backups/`. Gate for Phase 1.

### Phase 1 — Boot upstream OpenWrt without touching flash
Build vanilla OpenWrt `ipq40xx` and prove our kernel runs on the board **from
RAM**, so a mistake can't brick it:
- `make` clones/configures/builds. Start from the generic
  ipq40xx config + our DTS derived from `stock.dts`.
- Boot an **initramfs** image via U-Boot over TFTP/`bootm` from the UART prompt
  (no flash write). Confirm: console, both ath10k radios, all 3 MT7612U,
  ethernet + switch, ASIX NIC, eMMC visible.
Deliverable: a RAM-booting initramfs that lights up every radio and NIC.

### Phase 2 — DTS, partitions, sysupgrade (first flash)
- Finalise `qcom-ipq4019-pineapple-ent.dts` and the OpenWrt **device definition**
  (image Makefile entry, eMMC partition map matching what the stock bootloader
  loads, FIT/image format it expects).
- Implement **sysupgrade** for eMMC (platform `platform.sh`), ideally writing to
  a non-active slot so a bad flash falls back.
- First real flash to the guinea pig; verify upgrade + factory-reset + recovery
  all still work.
Deliverable: flashable + sysupgradeable image; recovery still proven.

### Phase 3 — Image contents (the platform)
- Package set: wireless-audit toolset from OpenWrt feeds (hostapd with the
  relevant features, aircrack-ng, kismet, tcpdump/hcxdumptool, bettercap, etc.),
  sized against 4 GB eMMC / 1 GB RAM.
- **Radio role config**: a clean uci/config scheme assigning the 5 radios to
  roles (AP / monitor / client) — our replacement for PineAP orchestration.
- Management UI: LuCI by default; decide later whether a thin custom control
  page is worth it. (Open question below.)
Deliverable: a daily-driver image.

### Phase 4 — Fleet (provisioning, phone-home, OTA)
- **Per-unit provisioning:** one image; a first-boot service reads a per-unit
  config (hostname, SSH keys, WireGuard keys, radio roles) from a committed
  per-unit file baked in at build (uci-defaults) or fetched once on first boot.
- **Phone-home:** WireGuard client to a central hub; each unit reachable over
  the tunnel. Keys per unit, generated at provision time.
- **Central OTA:** units pull signed sysupgrade images from our server; sign with
  usign/the OpenWrt key, verify on-device before applying.
Deliverable: flash → unit appears on the WireGuard net → OTA-updatable.

### Phase 5 — Harden & document
Fleet rollout to all units, recovery runbook, README,
reproducible pinned build in CI if wanted.

## Repo layout (proposed)
```
pineapple/
  Makefile                      # clone OpenWrt $OPENWRT_VERSION, apply overlay, build image+SDK+IB
  diffconfig                    # minimal config diff
  files/                        # overlay applied into the OpenWrt tree
    target/linux/ipq40xx/...    # DTS, device definition, base-files (board.d)
    package/ ...                # our own packages (provisioning, phone-home, radio-roles)
  patches/                      # patches against the pinned OpenWrt
  provisioning/<hostname>.conf  # per-unit config (committed)
  docs/stock-recon.md
  backups/                      # eMMC + env dumps, stock/recovery .bin  (gitignored, large)
  README.md  PLAN.md
```

## Top risks / open questions
Offline analysis of stock firmware 2.1.3 retired the two biggest risks:

1. ~~**eMMC boot chain**~~ — **resolved.** Boot is SPI-NOR + `denx,fit`, the
   standard ipq40xx scheme; eMMC is only data storage. Still confirm on the live
   device via `fw_printenv`/U-Boot `printenv` that `bootcmd` just does
   `bootm`/`bootubi` on the `firmware` partition (expected).
2. ~~**Signed/verified boot**~~ — **resolved.** Stock FIT is unsigned (crc32 +
   sha1). We can build our own FIT with `mkimage` and keep stock U-Boot, as long
   as U-Boot itself doesn't enforce a signature (stock image being unsigned says
   it doesn't). One live sanity check when we first boot our FIT.
3. **ath10k ART/calibration** — lives in NOR `0:ART` + cal variant
   `Hak5-WiFi-Pineapple-Ent-1`. Our build must read ART from that MTD partition
   (`mtd-mac-address`/`qcom,ath10k-calibration-variant`) or the internal radios
   come up wrong. Straightforward — it's how ipq40xx already works.
4. **MT7612U power / USB topology** — 3 USB radios + ASIX NIC all hang off the
   single `dwc3` USB3 host through an internal hub. Confirm all 4 enumerate under
   our kernel (power is wall-fed, so draw shouldn't be the issue).
5. **eMMC usage** — confirm live how stock mounts the 4 GB eMMC (overlay? data
   partition?) so we mirror it for persistent storage.
6. **Management UI** — LuCI only, or a thin custom control surface for radio
   roles? (Decide in Phase 3.)

## Prerequisites (host)
OpenWrt build deps (Ubuntu/Debian): `build-essential clang flex bison g++ gawk
gettext git libncurses-dev libssl-dev python3-dev python3-setuptools rsync swig
unzip zlib1g-dev file wget`. Plus `device-tree-compiler` (dtc) and a 3.3 V
USB-UART adapter for bring-up.
