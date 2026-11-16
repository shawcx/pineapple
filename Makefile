# Build custom OpenWrt (+ SDK + ImageBuilder) for the WiFi Pineapple Enterprise.
#
# The Enterprise is not an upstream OpenWrt device, so before building we inject
# our board support into the freshly cloned tree:
#   - files/  : overlay rsync'd into the tree (our DTS, base-files/board.d)
#   - patches/: quilt-style patches applied with `patch -p1` (the device
#               definition appended to target/linux/ipq40xx/image/generic.mk)
#
#   make              checkout + feeds + inject + config + download + build
#   make menuconfig   edit the config, then save the minimal diff to ./diffconfig
#   make example      build ./example out of tree with the SDK into an .apk
#
# RAM-boot (Phase 1, no flash writes) uses the initramfs .itb from BIN_DIR.

OPENWRT_URL     ?= https://git.openwrt.org/openwrt/openwrt.git
OPENWRT_VERSION ?= v25.12.5
OPENWRT_DIR     ?= openwrt
JOBS            ?= $(shell nproc)

TARGET    := ipq40xx
SUBTARGET := generic
DEVICE    := hak5_wifi-pineapple-enterprise-1

BIN_DIR := $(OPENWRT_DIR)/bin/targets/$(TARGET)/$(SUBTARGET)
SDK_TAR  = $(firstword $(wildcard $(BIN_DIR)/openwrt-sdk-*.tar.zst))
SDK_DIR := sdk
SDK_PKGS = $(SDK_DIR)/bin/packages/$(shell sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"/\1/p' $(SDK_DIR)/.config 2>/dev/null)/base

.PHONY: all checkout feeds inject config download build menuconfig savediff sdk example example-clean clean distclean

all: build

checkout:
	@if [ ! -d $(OPENWRT_DIR)/.git ]; then \
		git clone --branch $(OPENWRT_VERSION) $(OPENWRT_URL) $(OPENWRT_DIR); \
	elif [ "$$(git -C $(OPENWRT_DIR) describe --tags --exact-match 2>/dev/null)" != "$(OPENWRT_VERSION)" ]; then \
		git -C $(OPENWRT_DIR) fetch --tags origin && \
		git -C $(OPENWRT_DIR) checkout $(OPENWRT_VERSION); \
	fi

feeds: checkout
	cd $(OPENWRT_DIR) && ./scripts/feeds update -a && ./scripts/feeds install -a

# Inject our board support into the clone. Idempotent: the overlay is a plain
# copy, and each patch is skipped if it already applies in reverse (i.e. is in).
inject: feeds
	rsync -a files/ $(OPENWRT_DIR)/
	@for p in $(sort $(wildcard patches/*.patch)); do \
		if patch -d $(OPENWRT_DIR) -p1 -R --dry-run -s -f <"$$p" >/dev/null 2>&1; then \
			echo "already applied: $$p"; \
		else \
			echo "applying: $$p"; \
			patch -d $(OPENWRT_DIR) -p1 <"$$p"; \
		fi; \
	done

config: inject
	cp diffconfig $(OPENWRT_DIR)/.config
	$(MAKE) -C $(OPENWRT_DIR) defconfig

download: config
	$(MAKE) -C $(OPENWRT_DIR) -j$(JOBS) download

build: download
	$(MAKE) -C $(OPENWRT_DIR) -j$(JOBS) || $(MAKE) -C $(OPENWRT_DIR) -j1 V=s
	@echo
	@ls -1 $(BIN_DIR)/*sysupgrade.bin $(BIN_DIR)/*initramfs* $(BIN_DIR)/openwrt-sdk-* $(BIN_DIR)/openwrt-imagebuilder-* 2>/dev/null

menuconfig: config
	$(MAKE) -C $(OPENWRT_DIR) menuconfig
	$(MAKE) savediff

savediff:
	cd $(OPENWRT_DIR) && ./scripts/diffconfig.sh > $(CURDIR)/diffconfig

sdk: $(SDK_DIR)/.unpacked

$(SDK_DIR)/.unpacked: $(SDK_TAR)
	@test -n "$(SDK_TAR)" || { echo "No SDK in $(BIN_DIR); run 'make' first" >&2; exit 1; }
	rm -rf $(SDK_DIR) && mkdir -p $(SDK_DIR)
	tar --zstd -xf $(SDK_TAR) -C $(SDK_DIR) --strip-components=1
	$(MAKE) -C $(SDK_DIR) defconfig
	touch $@

example: sdk
	ln -sfn $(CURDIR)/example $(SDK_DIR)/package/example
	$(MAKE) -C $(SDK_DIR) package/example/compile V=s
	@echo
	@ls -1 $(SDK_PKGS)/example-*.apk

example-clean:
	-$(MAKE) -C $(SDK_DIR) package/example/clean

clean:
	$(MAKE) -C $(OPENWRT_DIR) clean

distclean:
	rm -rf $(OPENWRT_DIR)
