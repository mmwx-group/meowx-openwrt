#!/bin/sh

. "$IPKG_INSTROOT/etc/meowx/scripts/include.sh"

# 绕过节点服务器地址（代理配置 → 绕过）缺省开：老配置里没有这一项的，升级时补上并打开（每次装 / 升级都会跑这个脚本，
# 所以放在下面「只在新装时」的判断之前；已经有这一项的，不论开关都不动）
if uci -q get meowx.proxy > /dev/null && [ -z "$(uci -q get meowx.proxy.bypass_proxy_server)" ]; then
	uci set meowx.proxy.bypass_proxy_server='1'
	uci commit meowx
fi

# 喵窝设备中继的定时任务只在入网时加：已入网的老版本升级上来补上（装进固件时 IPKG_INSTROOT 非空，跳过）
if [ -z "$IPKG_INSTROOT" ] && [ "$(uci -q get meowx.mesh.enabled)" = "1" ] && [ -f /etc/meowx/ucode/mesh_cli.uc ]; then
	ucode -S /etc/meowx/ucode/mesh_cli.uc cron >/dev/null 2>&1
fi

# check meowx.config.init
init=$(uci -q get meowx.config.init); [ -z "$init" ] && return

# generate random string for api secret and authentication password
random=$(awk 'BEGIN{srand(); printf "%06d", int(rand() * 1000000)}')

# set meowx.mixin.api_secret
uci set meowx.mixin.api_secret="$random"

# set meowx.@authentication[0].password
uci set meowx.@authentication[0].password="$random"

# remove meowx.config.init
uci del meowx.config.init

# commit
uci commit meowx

# exit with 0
exit 0
