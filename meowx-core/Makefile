include $(TOPDIR)/rules.mk

# MeowX 内核：MeowX 各端共用的 mihomo fork（meowx-core 仓库，meowC 的 Android / Windows / Linux 客户端也用它），
# 比官方 mihomo 多 Miu、AnyTLS + REALITY、Snell v6 等。按 meowx-core 的 tag 固定（PKG_VERSION = tag 去掉 v）。
# 以前从 meowC 的 core/Clash.Meta 编、自带 001 / 002 / 003 三个补丁；独立程序自己起监听端口与 TUN、`meowx-core panel …`
# 子命令（主控账户、账户订阅、白名单上报、喵窝入网）现在都在 meowx-core 里，这里不再打补丁。
PKG_NAME:=meowx-core
PKG_VERSION:=0.5.1
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/mmwx-group/meowx-core.git
PKG_SOURCE_VERSION:=29aa32d68c0868b058f087461cf52fbb5a92cf76
PKG_MIRROR_HASH:=7de2c7b8f3b7b98345fdd3fd520dd70b3bc50848f2cfb4be21081970b82645ca

PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=MeowX

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_BUILD_TIME:=$(shell date -u -Iseconds)

GO_PKG:=github.com/metacubex/mihomo
GO_PKG_BUILD_PKG:=github.com/metacubex/mihomo
GO_PKG_LDFLAGS_X:=$(GO_PKG)/constant.Version=meowx-$(PKG_VERSION) $(GO_PKG)/constant.BuildTime=$(PKG_BUILD_TIME)
# 路由器上用不到 Bettbox 带的三种组网出站（EasyTier 光内嵌的 WASM 就有 6.5MB）：去掉后 mipsle 59M → 41M
GO_PKG_TAGS:=with_gvisor,no_easytier,no_tailscale,no_zerotier

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/meowx-core
  SECTION:=net
  CATEGORY:=Network
  TITLE:=MeowX core (mihomo fork)
  URL:=https://github.com/mmwx-group/meowx-core
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle +ip-full +kmod-inet-diag +kmod-tun
endef

define Package/meowx-core/description
  MeowX proxy core, a fork of mihomo with Miu, AnyTLS + REALITY and Snell v6.
endef

define Build/Prepare
	$(Build/Prepare/Default)
	$(RM) -r $(PKG_BUILD_DIR)/rules/logic_test
endef

define Package/meowx-core/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/mihomo $(1)/usr/bin/meowx-core
endef

$(eval $(call GoBinPackage,meowx-core))
$(eval $(call BuildPackage,meowx-core))
