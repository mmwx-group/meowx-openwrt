#!/bin/sh

# MeowX's uninstaller

# uninstall
if [ -x "/bin/opkg" ]; then
	opkg list-installed luci-i18n-meowx-* | cut -d ' ' -f 1 | xargs opkg remove
	opkg remove luci-app-meowx
	opkg remove meowx
	opkg remove meowx-core
elif [ -x "/usr/bin/apk" ]; then
	apk list --installed --manifest luci-i18n-meowx-* | cut -d ' ' -f 1 | xargs apk del
	apk del luci-app-meowx
	apk del meowx
	apk del meowx-core
fi
# remove config
rm -f /etc/config/meowx
# remove files
rm -rf /etc/meowx
# remove log
rm -rf /var/log/meowx
# remove temp
rm -rf /var/run/meowx
# remove feed
if [ -x "/bin/opkg" ]; then
	if grep -q meowx /etc/opkg/customfeeds.conf; then
		sed -i '/meowx/d' /etc/opkg/customfeeds.conf
	fi
	wget -O "meowx.pub" "https://dl.miaomiaowux.com/meowx/openwrt/key-build.pub"
	opkg-key remove meowx.pub
	rm -f meowx.pub
elif [ -x "/usr/bin/apk" ]; then
	if grep -q meowx /etc/apk/repositories.d/customfeeds.list; then
		sed -i '/meowx/d' /etc/apk/repositories.d/customfeeds.list
	fi
	rm -f /etc/apk/keys/meowx.pem
fi
