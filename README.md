# MeowX for OpenWrt

MeowX 的 OpenWrt 路由器版：LuCI 界面 + 透明代理，内核是 MeowX 自己的 mihomo fork（与 Android / Windows 客户端同一份，
支持 Miu、AnyTLS + REALITY、Snell v6 等官方 mihomo 没有的协议）。

基于 [OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki)（GPL-3.0）改造，感谢原作者。本项目同样以 GPL-3.0 发布。

## 环境要求

- OpenWrt >= 24.10（或同代的 ImmortalWrt），firewall4
- Linux 内核 >= 5.13

## 安装

```shell
# 添加软件源（只需一次）
wget -O - https://dl.miaomiaowux.com/meowx/openwrt/feed.sh | ash
# opkg（24.10）
opkg install meowx luci-app-meowx luci-i18n-meowx-zh-cn
# apk（25.12 及以后）
apk add meowx luci-app-meowx luci-i18n-meowx-zh-cn
```

卸载并清除配置：`wget -O - https://dl.miaomiaowux.com/meowx/openwrt/uninstall.sh | ash`

## 包

| 包 | 内容 |
|---|---|
| `meowx-core` | 内核，`/usr/bin/meowx-core`，从 [meowC](https://github.com/mmwx-group/meowC) 的 `core/Clash.Meta` 按发版提交编译 |
| `meowx` | 服务：订阅下载、配置混入、nftables / 路由、procd |
| `luci-app-meowx` | LuCI 界面 |

订阅缺省用官方客户端 UA（`mihomo/1.19.0 MeowX/<内核版本> (OpenWrt)`，用户代理选「MeowX（官方客户端）」），
主控据此下发只有 MeowX 内核才支持的节点。

## 编译

```shell
echo "src-git meowx https://github.com/mmwx-group/meowx-openwrt.git;main" >> feeds.conf.default
./scripts/feeds update -a && ./scripts/feeds install -a
make package/luci-app-meowx/compile
```

产物在 `bin/packages/<架构>/meowx`。
