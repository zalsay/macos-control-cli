#!/usr/bin/env bash
# 交叉编译 Safarier 自带的精简版 mihomo（Clash.Meta 内核）：darwin/arm64（Apple 芯片）和 darwin/amd64（Intel）两个切片，
# 由 build-app.sh 合并成 Universal 后打进 Safarier.app/Contents/Helpers。
# Clash 格式的订阅（链式代理、证书指纹、XUDP 等）由它运行；URI 节点仍然用 sing-box。
# 在编译机上跑（不在 Mac 上编译），产物取回到 .build/mihomo/（mihomo-arm64、mihomo-amd64、LICENSE、COPYING、SOURCE；
# 有 lipo 时另有合并好的 Universal mihomo）：
#   remote-build --fetch out/mihomo:.build -- scripts/build-mihomo.sh
# 环境变量：MIHOMO_VERSION（默认 1.19.33，和 SafarierNetwork 里 MihomoProxyFields 提取字段表时用的源码版本一致；
#           升级时两者要一起改），MIHOMO_ARCHS（默认 "arm64 amd64"）。
# 只编 SOCKS 入站和出站协议，不带 with_gvisor（那是 TUN 才用的）。
set -euo pipefail

VERSION="${MIHOMO_VERSION:-1.19.33}"
ARCHS="${MIHOMO_ARCHS:-arm64 amd64}"
cd "$(dirname "$0")/.."
OUT="$PWD/out/mihomo"
SRC="$PWD/out/mihomo-src/$VERSION"
LDFLAGS="-s -w -buildid= -X github.com/metacubex/mihomo/constant.Version=$VERSION"

if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC"
  git clone --quiet --depth 1 --branch "v$VERSION" https://github.com/MetaCubeX/mihomo.git "$SRC"
fi

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

rm -rf "$OUT"
mkdir -p "$OUT"
for arch in $ARCHS; do
  echo "==> darwin/${arch}"
  (
    cd "$SRC"
    CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build -trimpath -ldflags "$LDFLAGS" -o "$OUT/mihomo-$arch" .
  )
done

# 编译机通常是 Linux，没有 lipo：留两个切片，由 Mac 上的 build-app.sh 合并。
if command -v lipo >/dev/null 2>&1 && [ -f "$OUT/mihomo-arm64" ] && [ -f "$OUT/mihomo-amd64" ]; then
  lipo -create -output "$OUT/mihomo" "$OUT/mihomo-arm64" "$OUT/mihomo-amd64"
  echo "==> 已合并 Universal：$(lipo -archs "$OUT/mihomo")"
fi

cp "$SRC/LICENSE" "$OUT/LICENSE"
# 上游 LICENSE 只是版权声明；GPL 要求随程序附上许可证全文。
curl -fsSL https://www.gnu.org/licenses/gpl-3.0.txt -o "$OUT/COPYING"
grep -q 'GNU GENERAL PUBLIC LICENSE' "$OUT/COPYING"
{
  echo "mihomo ${VERSION}，GPL-3.0，未修改源码。"
  echo "源码：https://github.com/MetaCubeX/mihomo/tree/v${VERSION}（commit $(git -C "$SRC" rev-parse HEAD)）"
  echo "工具链：$(go version)；CGO_ENABLED=0"
  echo "Safarier.app 里的 mihomo 是下面各切片用 lipo -create 合并的 Universal 文件："
  for arch in $ARCHS; do
    echo "  darwin/${arch}：CGO_ENABLED=0 GOOS=darwin GOARCH=$arch go build -trimpath -ldflags \"$LDFLAGS\" ."
    echo "    sha256 $(sha256 "$OUT/mihomo-$arch")"
  done
} > "$OUT/SOURCE"
ls -la "$OUT"
