# MeowX for OpenWrt

MeowX 的 OpenWrt 路由器版：在路由器上跑 MeowX 内核，用浏览器（LuCI）管理，给整个局域网做透明代理。

内核是 MeowX 自己的 mihomo 分支（与 Android / Windows 客户端同一份），支持 **Miu**、AnyTLS + REALITY、Snell v6 等官方 mihomo 没有的协议；
订阅、主控账户、po0 加白等操作与 MeowX 客户端一致。

本项目基于 [OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki) 改造，透明代理、配置混入与服务脚本都来自它，衷心感谢 nikki 项目及其作者。
本项目同样以 [GPL-3.0](LICENSE) 开源。

## 环境要求

- OpenWrt 24.10 及以后（或同代的 ImmortalWrt），使用 firewall4（nftables）
- Linux 内核 5.13 及以后
- 存储空间：内核约 40MB（各架构不同），小闪存机型请先确认剩余空间（`df -h /overlay`）

## 安装

SSH 登录路由器后执行下面任一种。

### 方式一：一键安装（推荐）

```shell
wget -O - https://dl.miaomiaowux.com/meowx/openwrt/install.sh | ash
```

自动识别系统版本与架构，安装 `meowx-core`、`meowx`、`luci-app-meowx` 与当前 LuCI 语言的翻译包。

### 方式二：添加软件源后安装

添加一次软件源，之后就能像系统自带的软件一样安装、升级（也可以在 LuCI「系统 → 软件包」里操作）：

```shell
# 添加软件源（只需一次；会导入软件源的签名公钥）
wget -O - https://dl.miaomiaowux.com/meowx/openwrt/feed.sh | ash

# OpenWrt 24.10（opkg）
opkg install meowx luci-app-meowx luci-i18n-meowx-zh-cn

# OpenWrt 25.12 及以后（apk）
apk add meowx luci-app-meowx luci-i18n-meowx-zh-cn
```

繁体中文界面把 `zh-cn` 换成 `zh-tw`。

### 方式三：手动安装

在 [Releases](https://github.com/mmwx-group/meowx-openwrt/releases) 下载对应架构与系统版本的压缩包（`meowx_<架构>-<系统版本>.tar.gz`），
解压后传到路由器上，`opkg install ./*.ipk` 或 `apk add --allow-untrusted ./*.apk`。
架构名看 `/etc/openwrt_release` 里的 `DISTRIB_ARCH`。

## 升级

```shell
# 添加过软件源的
opkg update && opkg upgrade meowx-core meowx luci-app-meowx    # 24.10
apk update && apk upgrade meowx-core meowx luci-app-meowx      # 25.12 及以后
```

用一键安装装的，再执行一遍一键安装命令即可。升级会保留设置、订阅与主控账户。

## 卸载

```shell
wget -O - https://dl.miaomiaowux.com/meowx/openwrt/uninstall.sh | ash
```

会删掉三个包、全部设置（`/etc/config/meowx`、`/etc/meowx`，包括订阅与主控账户）和软件源。

## 使用

装好后打开 LuCI「服务 → MeowX」。

1. **登录主控账户**（可选）：在主控网页打开「扫码登录」，点「复制登录链接」，粘贴到「插件配置」页的「主控账户」卡里登录。
   路由器上没法扫码，所以用链接代替；链接只能用一次、5 分钟内有效。登录后账户下只有一份订阅时会自动导入并切换过去。
2. **添加订阅**：在「插件配置」页的订阅卡或「配置文件」页粘贴订阅链接即可，名称、用量、到期时间从订阅自动读取，缺省 24 小时自动更新。
   订阅缺省用 MeowX 官方客户端的 UA，主控据此下发只有 MeowX 内核才支持的节点。
3. **启用**：「插件配置」里打开「启用」，选好配置文件，「保存并应用」。
   - 缺省是「仅核心」：只运行内核、开放代理端口，不接管路由器的流量，适合先确认订阅可用；
   - 关掉「仅核心」后按「代理配置」里的设置做透明代理（Redirect / TPROXY / TUN，IPv4 / IPv6，按设备或端口的访问控制）。
4. **po0 加白**（「辅助功能」页）：把路由器的出口 IP 上报到 po0 服务器（主控登记的与自己添加的），每 10 分钟及 WAN 重新拨号时自动加白。
5. **面板**：「插件配置」顶部「打开面板」进入 Web 面板，查看节点、连接与日志。

日志在「日志」页；配置文件可以在「编辑器」页直接改。

## 包

| 包 | 内容 |
|---|---|
| `meowx-core` | 内核 `/usr/bin/meowx-core`：[meowC](https://github.com/mmwx-group/meowC) 里的 mihomo 分支（`core/Clash.Meta`），按 meowC 发版提交编译，补丁在 `meowx-core/patches/` |
| `meowx` | 服务：订阅下载、配置混入、nftables 与路由、procd、主控账户与白名单上报 |
| `luci-app-meowx` | LuCI 界面 |

## 编译

用 OpenWrt SDK 或完整源码树：

```shell
echo "src-git meowx https://github.com/mmwx-group/meowx-openwrt.git;main" >> feeds.conf.default
./scripts/feeds update -a && ./scripts/feeds install -a
make package/meowx-core/compile package/meowx/compile package/luci-app-meowx/compile
```

产物在 `bin/packages/<架构>/meowx`。

GitHub Actions：

- `build-packages`：手动触发，编译全部架构并上传为构建产物（不签名、不发布）。
- `release-packages`：推 `v*` 标签（须与 `meowx/Makefile` 的 `PKG_VERSION` 一致）自动编译、签名，发布到 GitHub Releases，
  并推到 CDN：软件源同步到 `dl.miaomiaowux.com/meowx/openwrt`，`dl.miaomiaowux.com/meowx/latest.json` 登记 `openwrt` 条目
  （文档站「客户端下载」页读它）。也可手动触发，在 main 上勾选 publish 才推 CDN；带 `-` 的标签只发 GitHub 预发布。
  需要的仓库 secrets 见工作流文件开头的注释。

## 许可

GPL-3.0，见 [LICENSE](LICENSE)。内核源码见 [meowC](https://github.com/mmwx-group/meowC)。
