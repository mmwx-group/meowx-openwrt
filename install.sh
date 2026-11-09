#!/bin/sh

# MeowX's installer

# check env
if [[ ! -x "/bin/opkg" && ! -x "/usr/bin/apk" || ! -x "/sbin/fw4" ]]; then
	echo "only supports OpenWrt build with firewall4!"
	exit 1
fi

# include openwrt_release
. /etc/openwrt_release
[ -f /etc/os-release ] && . /etc/os-release

# get branch/arch
# 第三方固件常把 DISTRIB_RELEASE 改成自己的名字（如「Buddha Version」），依次看 DISTRIB_RELEASE / DISTRIB_REVISION /
# os-release 的 VERSION_ID、OPENWRT_RELEASE 里有没有版本号；都认不出时按包管理器选：apk 用 25.12 的包，opkg 用 24.10 的包
arch="$DISTRIB_ARCH"
branch=
for release in "$DISTRIB_RELEASE" "$DISTRIB_REVISION" "$VERSION_ID" "$OPENWRT_RELEASE"; do
	case "$release" in
		*"24.10"*) branch="openwrt-24.10" ;;
		*"25.12"*) branch="openwrt-25.12" ;;
		*"SNAPSHOT"*) branch="SNAPSHOT" ;;
	esac
	[ -n "$branch" ] && break
done
if [ -z "$branch" ]; then
	if [ -x "/usr/bin/apk" ]; then
		branch="openwrt-25.12"
	else
		branch="openwrt-24.10"
	fi
	echo "unknown release \"$DISTRIB_RELEASE\", using $branch packages"
fi
# 包格式跟着包管理器走：opkg 只能装 24.10 的 ipk，apk 只能装 25.12 / SNAPSHOT 的 apk（第三方固件的版本号不一定可信）
if [ -x "/usr/bin/apk" ] && [ "$branch" = "openwrt-24.10" ]; then
	branch="openwrt-25.12"
elif [ ! -x "/usr/bin/apk" ] && [ "$branch" != "openwrt-24.10" ]; then
	branch="openwrt-24.10"
fi
if [ -z "$arch" ]; then
	if [ -x "/usr/bin/apk" ]; then
		arch="$(apk --print-arch 2>/dev/null)"
	else
		arch="$(opkg print-architecture 2>/dev/null | awk '$2 != "all" && $2 != "noarch" { a = $2 } END { print a }')"
	fi
fi

# 哪一步失败就停下：以前各步都不看退出码，装没装上最后都打印 success
fail() {
	echo "$1"
	exit 1
}

# feed url
repository_url="https://dl.miaomiaowux.com/meowx/openwrt"
feed_url="$repository_url/$branch/$arch/meowx"

# 这个系统版本 / 架构有没有编出来的包
if [ -x "/usr/bin/apk" ]; then
	feed_index="$feed_url/packages.adb"
else
	feed_index="$feed_url/Packages.gz"
fi
if [ -z "$arch" ] || ! wget -q -O /dev/null "$feed_index"; then
	echo "no packages for $branch / ${arch:-unknown arch}, see https://github.com/mmwx-group/meowx-openwrt"
	exit 1
fi

tmp_dir="$(mktemp -d /tmp/meowx-install.XXXXXX)" || fail "cannot create a temporary directory"
trap 'rm -rf "$tmp_dir"' EXIT

# 先用 wget 下到本地再交给 opkg：老固件的 opkg 只把 http:// / ftp:// 当网址，https:// 的地址会被当成本地文件名去打开，装不上
install_ipk() {
	wget -q -O "$tmp_dir/$1" "$feed_url/$1" || {
		echo "cannot download $feed_url/$1"
		return 1
	}
	opkg install "$tmp_dir/$1"
}

if [ -x "/bin/opkg" ]; then
	# update feeds：某个软件源连不上时 opkg update 也返回失败，只提示、照常往下装（真缺依赖时下面的安装会失败并停下）
	echo "update feeds"
	opkg update || echo "opkg update reported errors, continuing with the package lists it got"
	# get languages
	echo "get languages"
	languages=$(opkg list-installed luci-i18n-base-* | cut -d ' ' -f 1 | cut -d '-' -f 4-)
	# get latest version
	echo "get latest version"
	wget -q -O "$tmp_dir/index.json" "$feed_url/index.json" || fail "cannot download $feed_url/index.json"
	eval "$(jsonfilter -i "$tmp_dir/index.json" -e "meowx_core_version=@['packages']['meowx-core']" -e "meowx_version=@['packages']['meowx']" -e "luci_app_meowx_version=@['packages']['luci-app-meowx']")"
	if [ -z "$meowx_core_version" ] || [ -z "$meowx_version" ] || [ -z "$luci_app_meowx_version" ]; then
		fail "cannot read package versions from $feed_url/index.json"
	fi
	# install ipks
	echo "install ipks"
	install_ipk "meowx-core_${meowx_core_version}_${arch}.ipk" || fail "failed to install meowx-core"
	install_ipk "meowx_${meowx_version}_${arch}.ipk" || fail "failed to install meowx"
	install_ipk "luci-app-meowx_${luci_app_meowx_version}_all.ipk" || fail "failed to install luci-app-meowx"
	# kmod-dummy 可选（只给 IPv6 fake-ip 网段挂路由用）：有些第三方固件的软件源里没有，装不上不影响使用
	opkg install kmod-dummy > /dev/null 2>&1 || echo "kmod-dummy is unavailable, skip (only needed by the IPv6 fake-ip range)"
	# 语言包装不上不影响使用（界面退回英文），只提示
	for lang in $languages; do
		lang_version=$(jsonfilter -i "$tmp_dir/index.json" -e "@['packages']['luci-i18n-meowx-${lang}']")
		if [ -z "$lang_version" ]; then
			echo "no luci-i18n-meowx-${lang} package, skip"
			continue
		fi
		install_ipk "luci-i18n-meowx-${lang}_${lang_version}_all.ipk" || echo "failed to install luci-i18n-meowx-${lang}, skip"
	done
elif [ -x "/usr/bin/apk" ]; then
	# update feeds
	echo "update feeds"
	apk update || echo "apk update reported errors, continuing with the package lists it got"
	# get languages
	echo "get languages"
	languages=$(apk list --installed --manifest luci-i18n-base-* | cut -d ' ' -f 1 | cut -d '-' -f 4-)
	# install apks from remote repository
	echo "install apks from remote repository"
	# --upgrade：已经装过的也升到软件源里的新版（apk add 缺省不升级已安装的包，再跑一遍安装脚本等于没升）
	apk add --upgrade --allow-untrusted -X $feed_url/packages.adb meowx-core meowx luci-app-meowx || fail "failed to install meowx"
	# kmod-dummy 可选（只给 IPv6 fake-ip 网段挂路由用）：有些第三方固件的软件源里没有，装不上不影响使用
	apk add kmod-dummy > /dev/null 2>&1 || echo "kmod-dummy is unavailable, skip (only needed by the IPv6 fake-ip range)"
	for lang in $languages; do
		apk add --upgrade --allow-untrusted -X $feed_url/packages.adb "luci-i18n-meowx-${lang}" || echo "failed to install luci-i18n-meowx-${lang}, skip"
	done
fi

echo "success" 
