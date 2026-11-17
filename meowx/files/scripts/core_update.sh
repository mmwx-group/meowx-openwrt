#!/bin/sh
# 内核更新（「关于」页的「更新内核」）：直接从 meowx-core 的 GitHub Release 下载内核，替换 /usr/bin/meowx-core。
# 不动插件，也不用等 meowx-openwrt 发版。下载按「GitHub 加速」的设置走加速地址，加速地址不通或内容不对再直连一次。
#
#   core_update.sh latest            输出 Release 上的最新版本号（不带 v）
#   core_update.sh asset             输出本机该下载的文件名（meowx-core-linux-<架构>.gz），认不出架构时失败
#   core_update.sh update [版本]     下载 → 校验 sha256 → 解压到内核旁边 → 跑一遍 -v 核对版本 → 原子替换 → 服务在跑就重启
#
# 换上去的内核不经过包管理：apk / opkg 记的还是 meowx-core 包的版本，之后升级插件时软件源里的内核包若更新，照常覆盖。
# 文件名与 meowx-core 仓库 .github/workflows/release.yml 里编出来的一致，改一边要两边一起改。
# 下面几个路径可以用环境变量换掉，只为测试。

REPO_URL="${MEOWX_CORE_REPO_URL:-https://github.com/mmwx-group/meowx-core}"
CORE_PATH="${MEOWX_CORE_PATH:-/usr/bin/meowx-core}"
INIT="${MEOWX_INIT:-/etc/init.d/meowx}"
GHPROXY_CLI="${MEOWX_GHPROXY_CLI:-/etc/meowx/ucode/ghproxy_cli.uc}"
OPENWRT_RELEASE="${MEOWX_OPENWRT_RELEASE:-/etc/openwrt_release}"
WORK_DIR="${MEOWX_CORE_WORK_DIR:-/tmp/meowx-core-update}"
APP_LOG="${MEOWX_APP_LOG:-/var/log/meowx/app.log}"

# 按「GitHub 加速」的设置换算地址；没开加速、或换算不了时原样
mirror() {
	local url
	url=$(ucode -S "$GHPROXY_CLI" url "$1" 2> /dev/null)
	echo "${url:-$1}"
}

# get <地址> <存到哪（- 为标准输出）> <mirror|direct> [超时秒]：先用 curl（插件依赖它，一定装着），不行再试 wget。
# 失败的原因写到 stderr（「关于」页与插件日志显示）。以前只用 wget：ImmortalWrt / OpenWrt 25.12 上它是 uclient-fetch，
# 开着 Fake-IP 与路由器自身代理时连 GitHub 超时、curl 却正常（#1798），而且错误被丢掉，只剩一句「拿不到版本」
get() {
	local url="$1" out="$2" timeout="${4:-60}" err rc
	[ "$3" = "direct" ] || url=$(mirror "$1")
	err=$(mktemp "${TMPDIR:-/tmp}/meowx-core-get.XXXXXX") || err=/dev/null
	if command -v curl > /dev/null 2>&1; then
		curl -fsSL --connect-timeout 10 --max-time "$timeout" -o "$out" "$url" 2> "$err"
		rc=$?
		if [ "$rc" = 0 ]; then
			[ "$err" = /dev/null ] || rm -f "$err"
			return 0
		fi
		# curl 自己的报错就以「curl: (码) …」开头；没输出时补上退出码
		if [ -s "$err" ]; then
			tr '\n' ' ' < "$err" | sed 's/[[:space:]]*$//' >&2
			echo >&2
		else
			echo "curl: exit code $rc" >&2
		fi
	fi
	if command -v wget > /dev/null 2>&1; then
		wget -q -T "$timeout" -O "$out" "$url" 2> "$err"
		rc=$?
		if [ "$rc" = 0 ]; then
			[ "$err" = /dev/null ] || rm -f "$err"
			return 0
		fi
		echo "wget: exit code $rc$( [ -s "$err" ] && printf ', %s' "$(tr '\n' ' ' < "$err" | sed 's/[[:space:]]*$//')")" >&2
	fi
	[ "$err" = /dev/null ] || rm -f "$err"
	return 1
}

# 写一行插件日志（「日志」页的插件日志），格式同 init 脚本的 log
log_app() {
	[ -d "$(dirname "$APP_LOG")" ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Core] $1" >> "$APP_LOG"
}

asset() {
	local arch name
	[ -f "$OPENWRT_RELEASE" ] && arch=$(. "$OPENWRT_RELEASE"; echo "$DISTRIB_ARCH")
	case "$arch" in
		x86_64) name=amd64 ;;
		i386_*) name=386 ;;
		aarch64_*) name=arm64 ;;
		# ARMv5 / v6 的核（arm1176 带 VFP 也不能跑 GOARM=7）与没有 FPU 的核用软浮点版
		arm_arm1176*|arm_arm926*|arm_fa526*|arm_xscale*|arm_mpcore*) name=armv5 ;;
		arm_*vfp*|arm_*neon*) name=armv7 ;;
		arm_*) name=armv5 ;;
		mipsel_*) name=mipsle-softfloat ;;
		mips_*) name=mips-softfloat ;;
		mips64_*) name=mips64-softfloat ;;
		riscv64_*) name=riscv64 ;;
		loongarch64_*) name=loong64 ;;
		*)
			echo "no core build for this architecture: ${arch:-unknown}" >&2
			return 1
			;;
	esac
	echo "meowx-core-linux-$name.gz"
}

valid_version() {
	case "$1" in
		[0-9]*) case "$1" in *[!0-9A-Za-z.-]*) return 1 ;; esac ;;
		*) return 1 ;;
	esac
}

# 依次尝试的方式：开了加速是「加速、直连」，没开（或换算不了）只有直连
routes() {
	if [ "$(mirror "$1")" = "$1" ]; then echo direct; else echo mirror direct; fi
}

latest() {
	local via version reason reasons err
	err=$(mktemp "${TMPDIR:-/tmp}/meowx-core-latest.XXXXXX") || err=/dev/null
	for via in $(routes "$REPO_URL"); do
		version=$(get "$REPO_URL/releases/latest/download/version.txt" - "$via" 10 2> "$err" | head -n 1 | tr -d ' \r\n')
		if valid_version "$version"; then
			[ "$err" = /dev/null ] || rm -f "$err"
			echo "$version"
			return 0
		fi
		reason=$(tr '\n' ' ' < "$err" 2> /dev/null | sed 's/[[:space:]]*$//')
		[ -n "$version" ] && [ -z "$reason" ] && reason="unexpected content"
		reasons="$reasons${reasons:+; }$via: ${reason:-no response}"
	done
	[ "$err" = /dev/null ] || rm -f "$err"
	echo "cannot get the latest core version ($reasons)" >&2
	log_app "Check core update failed: $reasons"
	return 1
}

# download <release 地址> <文件名>：下到 WORK_DIR 并校验 sha256，加速地址下不对就直连再来一次
download() {
	local via want got
	for via in $(routes "$1"); do
		if get "$1/sha256sums.txt" "$WORK_DIR/sha256sums.txt" "$via" 2>&1 && get "$1/$2" "$WORK_DIR/$2" "$via" 2>&1; then
			want=$(awk -v f="$2" '$2 == f { print $1 }' "$WORK_DIR/sha256sums.txt")
			got=$(sha256sum "$WORK_DIR/$2" | cut -d ' ' -f 1)
			[ -n "$want" ] && [ "$want" = "$got" ] && return 0
			echo "checksum mismatch ($via)"
		else
			echo "download failed ($via)"
		fi
	done
	return 1
}

update() {
	local version name got
	version="$1"
	if [ -z "$version" ]; then
		version=$(latest) || exit 1
	fi
	valid_version "$version" || { echo "invalid version: $version"; exit 1; }
	name=$(asset) || exit 1

	rm -rf "$WORK_DIR"
	mkdir -p "$WORK_DIR" || exit 1
	trap 'rm -rf "$WORK_DIR" "$CORE_PATH.new"' EXIT

	echo "download $name ($version)"
	download "$REPO_URL/releases/download/v$version" "$name" || exit 1

	# 解压到内核旁边（闪存）而不是内存盘：解压后约 40MB。先跑一遍 -v：架构不对的跑不起来，到这里就停
	echo "install"
	if ! gunzip -c "$WORK_DIR/$name" > "$CORE_PATH.new"; then
		echo "decompress failed (not enough space in $(dirname "$CORE_PATH")?)"
		exit 1
	fi
	chmod 0755 "$CORE_PATH.new"
	got=$("$CORE_PATH.new" -v 2> /dev/null | grep Mihomo | cut -d ' ' -f 3)
	if [ "$got" != "meowx-$version" ]; then
		echo "the new core does not run on this router (got: ${got:-nothing})"
		exit 1
	fi
	mv -f "$CORE_PATH.new" "$CORE_PATH" || exit 1
	echo "core updated to $version"
	if "$INIT" running; then
		echo "restart service"
		"$INIT" restart
	fi
	echo "success"
}

case "$1" in
	latest) latest ;;
	asset) asset ;;
	update) update "$2" ;;
	*)
		echo "usage: $0 latest | asset | update [version]" >&2
		exit 1
		;;
esac
