#!/bin/sh

. "$IPKG_INSTROOT/etc/meowx/scripts/include.sh"

uci -q batch <<-EOF > /dev/null
	del firewall.meowx
	set firewall.meowx=include
	set firewall.meowx.type=script
	set firewall.meowx.path=$FIREWALL_INCLUDE_SH
	set firewall.meowx.fw4_compatible=1
	commit firewall
EOF
