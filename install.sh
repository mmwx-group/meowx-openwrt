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

if [ -x "/bin/opkg" ]; then
	# update feeds
	echo "update feeds"
	opkg update
	# get languages
	echo "get languages"
	languages=$(opkg list-installed luci-i18n-base-* | cut -d ' ' -f 1 | cut -d '-' -f 4-)
	# get latest version
	echo "get latest version"
	wget -O meowx.version $feed_url/index.json
	# install ipks
	echo "install ipks"
	eval "$(jsonfilter -i meowx.version -e "meowx_core_version=@['packages']['meowx-core']" -e "meowx_version=@['packages']['meowx']" -e "luci_app_meowx_version=@['packages']['luci-app-meowx']")"
	opkg install "$feed_url/meowx-core_${meowx_core_version}_${arch}.ipk"
	opkg install "$feed_url/meowx_${meowx_version}_${arch}.ipk"
	opkg install "$feed_url/luci-app-meowx_${luci_app_meowx_version}_all.ipk"
	for lang in $languages; do
		lang_version=$(jsonfilter -i meowx.version -e "@['packages']['luci-i18n-meowx-${lang}']")
		opkg install "$feed_url/luci-i18n-meowx-${lang}_${lang_version}_all.ipk"
	done
	
	rm -f meowx.version
elif [ -x "/usr/bin/apk" ]; then
	# update feeds
	echo "update feeds"
	apk update
	# get languages
	echo "get languages"
	languages=$(apk list --installed --manifest luci-i18n-base-* | cut -d ' ' -f 1 | cut -d '-' -f 4-)
	# install apks from remote repository
	echo "install apks from remote repository"
	# --upgrade：已经装过的也升到软件源里的新版（apk add 缺省不升级已安装的包，再跑一遍安装脚本等于没升）
	apk add --upgrade --allow-untrusted -X $feed_url/packages.adb meowx-core meowx luci-app-meowx
	for lang in $languages; do
		apk add --upgrade --allow-untrusted -X $feed_url/packages.adb "luci-i18n-meowx-${lang}"
	done
fi

echo "success" 
