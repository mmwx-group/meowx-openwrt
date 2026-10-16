include $(TOPDIR)/rules.mk

PKG_NAME:=meowx
PKG_VERSION:=2026.10.10
PKG_RELEASE:=1

PKG_LICENSE:=GPL3.0+
PKG_MAINTAINER:=Joseph Mory <morytyann@gmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/meowx
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Transparent Proxy with Mihomo on OpenWrt.
  URL:=https://miaomiaowux.com
  DEPENDS:=+ca-bundle +curl +yq firewall4 +ip-full +kmod-inet-diag +kmod-nft-socket +kmod-nft-tproxy +kmod-tun +kmod-dummy +meowx-core
endef

define Package/meowx/conffiles
/etc/config/meowx
/etc/meowx/mixin.yaml
endef

define Package/meowx/install
	$(INSTALL_DIR) $(1)/etc/meowx
	$(INSTALL_DIR) $(1)/etc/meowx/ucode
	$(INSTALL_DIR) $(1)/etc/meowx/scripts
	$(INSTALL_DIR) $(1)/etc/meowx/nftables
	$(INSTALL_DIR) $(1)/etc/meowx/profiles
	$(INSTALL_DIR) $(1)/etc/meowx/subscriptions
	$(INSTALL_DIR) $(1)/etc/meowx/run
	$(INSTALL_DIR) $(1)/etc/meowx/run/providers
	$(INSTALL_DIR) $(1)/etc/meowx/run/providers/rule
	$(INSTALL_DIR) $(1)/etc/meowx/run/providers/proxy

	$(INSTALL_DATA) $(CURDIR)/files/mixin.yaml $(1)/etc/meowx/mixin.yaml

	$(INSTALL_BIN) $(CURDIR)/files/ucode/include.uc $(1)/etc/meowx/ucode/include.uc
	$(INSTALL_BIN) $(CURDIR)/files/ucode/mixin.uc $(1)/etc/meowx/ucode/mixin.uc
	$(INSTALL_BIN) $(CURDIR)/files/ucode/hijack.ut $(1)/etc/meowx/ucode/hijack.ut

	$(INSTALL_BIN) $(CURDIR)/files/scripts/include.sh $(1)/etc/meowx/scripts/include.sh
	$(INSTALL_BIN) $(CURDIR)/files/scripts/firewall_include.sh $(1)/etc/meowx/scripts/firewall_include.sh
	$(INSTALL_BIN) $(CURDIR)/files/scripts/debug.sh $(1)/etc/meowx/scripts/debug.sh

	$(INSTALL_BIN) $(CURDIR)/files/nftables/geoip_cn.nft $(1)/etc/meowx/nftables/geoip_cn.nft
	$(INSTALL_BIN) $(CURDIR)/files/nftables/geoip6_cn.nft $(1)/etc/meowx/nftables/geoip6_cn.nft

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/meowx.conf $(1)/etc/config/meowx

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/meowx.init $(1)/etc/init.d/meowx

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(CURDIR)/files/uci-defaults/firewall.sh $(1)/etc/uci-defaults/99_firewall_meowx
	$(INSTALL_BIN) $(CURDIR)/files/uci-defaults/init.sh $(1)/etc/uci-defaults/99_init_meowx
	$(INSTALL_BIN) $(CURDIR)/files/uci-defaults/migrate.sh $(1)/etc/uci-defaults/99_migrate_meowx

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) $(CURDIR)/files/meowx.upgrade $(1)/lib/upgrade/keep.d/meowx
endef

define Package/meowx/postrm
#!/bin/sh
if [ -z $${IPKG_INSTROOT} ]; then
	uci -q batch <<-EOF > /dev/null
		del firewall.meowx
		commit firewall
	EOF
fi
endef

define Build/Compile

endef

$(eval $(call BuildPackage,meowx))
