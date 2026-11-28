#!/bin/sh
# 用官方源码（BSD-3）编路由器用的 tailscale 合体程序（tailscale.combined：一个文件同时当 tailscale 与 tailscaled，
# 靠程序名区分），给喵窝设备中继用（规格 miaomiaowuC/Design/mesh-peer-relay.md §5.4）。
#
#   scripts/build-tailscale-static.sh <版本> <输出目录> [架构…]
#
# 架构（manifest 里的键，mesh_cli.uc 的 static_arch 按 DISTRIB_ARCH 对应）：
#   aarch64  x86_64  armv7（GOARM=7，arm_cortex-a5/a7/a8/a9/a15…共用）  mipsel / mips（GOMIPS=softfloat，*_24kc / *_74kc / *_mips32）  riscv64
# 不写架构 = 全部。产出 <输出目录>/<版本>/<架构>/tailscale.combined + <输出目录>/<版本>/manifest.json（每个架构的大小与 sha256）。
#
# 功能裁剪：cmd/featuretags --min 只留 KEEP 里的（及其依赖），其余全部 ts_omit_*（Taildrop、SSH、web 客户端、云元数据、
# systray、drive、serve / funnel、出口节点、netlog / logtail 上传等都砍掉）。必须保留 relayserver（设备中继），
# cli（合体程序），以及路由器入网要用的：子网路由、NAT 穿透、端口映射、debug（mesh_cli 用 tailscale debug prefs / derp-map）。
set -eu

VERSION="${1:?usage: $0 <版本> <输出目录> [架构…]}"
OUT="${2:?usage: $0 <版本> <输出目录> [架构…]}"
shift 2
ARCHS="${*:-aarch64 x86_64 armv7 mipsel mips riscv64}"

KEEP="${TS_KEEP:-relayserver,cli,osrouter,nattraversal,udptransport,portmapper,listenrawdisco,advertiseroutes,useroutes,iptables,dns,debug,health,ipnbus,unixsocketidentity,bakedroots}"

SRC="${TS_SRC:-}"
if [ -z "$SRC" ]; then
	SRC="$(mktemp -d)/tailscale"
	git clone --depth 1 --branch "v$VERSION" https://github.com/tailscale/tailscale.git "$SRC"
fi
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
DEST="$OUT/$VERSION"
mkdir -p "$DEST"

cd "$SRC"
TAGS="$(go run ./cmd/featuretags --min --add="$KEEP")"
echo "build tags: $TAGS"
# 版本号写法同官方 build_dist.sh（tailscale version / tailscaled --version 第一行是 <版本>）
LDFLAGS="-s -w -X tailscale.com/version.longStamp=$VERSION-meowx -X tailscale.com/version.shortStamp=$VERSION"

files=""
for arch in $ARCHS; do
	case "$arch" in
	aarch64) set -- GOARCH=arm64 ;;
	x86_64) set -- GOARCH=amd64 ;;
	armv7) set -- GOARCH=arm GOARM=7 ;;
	mipsel) set -- GOARCH=mipsle GOMIPS=softfloat ;;
	mips) set -- GOARCH=mips GOMIPS=softfloat ;;
	riscv64) set -- GOARCH=riscv64 ;;
	*) echo "unknown arch $arch" >&2; exit 2 ;;
	esac
	mkdir -p "$DEST/$arch"
	echo "== $arch ($*)"
	env CGO_ENABLED=0 GOOS=linux "$@" go build -trimpath -tags "$TAGS" -ldflags "$LDFLAGS" \
		-o "$DEST/$arch/tailscale.combined" ./cmd/tailscaled
	size=$(wc -c < "$DEST/$arch/tailscale.combined" | tr -d ' ')
	sum=$( (sha256sum "$DEST/$arch/tailscale.combined" 2>/dev/null || shasum -a 256 "$DEST/$arch/tailscale.combined") | cut -d' ' -f1)
	echo "   $size bytes  $sum"
	files="$files${files:+,}\"$arch\":{\"path\":\"$arch/tailscale.combined\",\"size\":$size,\"sha256\":\"$sum\"}"
done

# 只编了部分架构时把已有 manifest 里别的架构并进来
python3 - "$DEST/manifest.json" "$VERSION" "{$files}" <<'PY'
import json, os, sys, time
path, version, new = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
files = {}
if os.path.exists(path):
    try:
        files = json.load(open(path)).get('files', {})
    except Exception:
        files = {}
files.update(new)
json.dump({'version': version, 'built_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'files': dict(sorted(files.items()))},
          open(path, 'w'), indent=2)
print(open(path).read())
PY
