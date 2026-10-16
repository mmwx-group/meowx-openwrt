#!/bin/sh

. "$IPKG_INSTROOT/etc/meowx/scripts/include.sh"

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
