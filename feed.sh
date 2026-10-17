#!/bin/sh

# MeowX's feed

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
	# add key
	echo "add key"
	key_build_pub_file="key-build.pub"
	wget -O "$key_build_pub_file" "$repository_url/key-build.pub"
	opkg-key add "$key_build_pub_file"
	rm -f "$key_build_pub_file"
	# add feed
	echo "add feed"
	if grep -q meowx /etc/opkg/customfeeds.conf; then
		sed -i '/meowx/d' /etc/opkg/customfeeds.conf
	fi
	echo "src/gz meowx $feed_url" >> /etc/opkg/customfeeds.conf
	# update feeds
	echo "update feeds"
	opkg update
elif [ -x "/usr/bin/apk" ]; then
	# add key
	echo "add key"
	wget -O "/etc/apk/keys/meowx.pem" "$repository_url/public-key.pem"
	# add feed
	echo "add feed"
	if grep -q meowx /etc/apk/repositories.d/customfeeds.list; then
		sed -i '/meowx/d' /etc/apk/repositories.d/customfeeds.list
	fi
	echo "$feed_url/packages.adb" >> /etc/apk/repositories.d/customfeeds.list
	# update feeds
	echo "update feeds"
	apk update
fi

echo "success"
