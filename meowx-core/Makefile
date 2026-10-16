include $(TOPDIR)/rules.mk

# MeowX 内核：meowC（Android / Windows 客户端）里的 mihomo fork，比官方 mihomo 多 Miu、AnyTLS + REALITY、Snell v6 等。
# 源码在 meowC 仓库的 core/Clash.Meta，按 meowC 的发版提交固定。
# patches/：001 让内核作为独立程序运行时自己起监听端口与 TUN（Bettbox 把这一步交给了 Flutter 外壳，单跑内核不开任何端口）。
#           002 加 `meowx-core panel …` 子命令：主控账户（登录链接）、账户订阅、客户端 IP 白名单上报，加密信道同 iOS / Android 客户端。
PKG_NAME:=meowx-core
PKG_VERSION:=0.3.1
PKG_RELEASE:=2

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/mmwx-group/meowC.git
PKG_SOURCE_VERSION:=0db577753dff3999d5105d7a2cbc2f456b1b7352
PKG_MIRROR_HASH:=85831f24438270e0f46e39939367c4d680014395062ba59f85f0155506839eea

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
  URL:=https://github.com/mmwx-group/meowC
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle +ip-full +kmod-inet-diag +kmod-tun
endef

define Package/meowx-core/description
  MeowX proxy core, a fork of mihomo with Miu, AnyTLS + REALITY and Snell v6.
endef

# 仓库根是 Flutter 客户端，内核在 core/Clash.Meta：解包后换成那个子目录
define Build/Prepare
	$(Build/Prepare/Default)
	mv $(PKG_BUILD_DIR) $(PKG_BUILD_DIR).repo
	mv $(PKG_BUILD_DIR).repo/core/Clash.Meta $(PKG_BUILD_DIR)
	rm -rf $(PKG_BUILD_DIR).repo
	$(RM) -r $(PKG_BUILD_DIR)/rules/logic_test
endef

define Package/meowx-core/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/mihomo $(1)/usr/bin/meowx-core
endef

$(eval $(call GoBinPackage,meowx-core))
$(eval $(call BuildPackage,meowx-core))
