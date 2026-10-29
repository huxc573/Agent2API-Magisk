#!/usr/bin/env bash
# 抽取模块运行体。来源按优先级：
#   1) 上游 Release 资产 agent2api-server-linux-arm64.tar.gz
#      —— 里面有 agent2api-server + ui/ 整份静态资源，还带 .sha256 可供校验；
#         与上游发布的 tag 一一对应，不依赖 Docker Hub。
#   2) 官方 arm64 镜像 aimodcc/agent2api:<tag> 里的 /usr/local/bin/agent2api-server + ui。
# so / 根证书 / 时区只有镜像里有，所以镜像无论如何都要拉一次（该 tag 没有就退 latest，
# 只影响这三样，二进制与 ui 的正确性由第 1 步保证）。
#
# 用法: scripts/ci/rootfs.sh <上游 tag>
set -euo pipefail

TAG="${1:?需要上游 tag}"
IMG="${AG2A_IMAGE:-aimodcc/agent2api}"
UPREPO="${UPSTREAM_REPO:-aimod-cc/agent2api}"
TAGV="${TAG#v}"

rm -rf rootfs publish
mkdir -p rootfs/usr/local/bin rootfs/lib rootfs/etc rootfs/usr/share/zoneinfo/Asia rootfs/app

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------- 1) 二进制 + ui：优先 Release 资产 ----------
SRC="image"
BIN_SHA=""
echo "== 1) 先看上游 Release 资产"
if gh release view "v$TAGV" -R "$UPREPO" >/dev/null 2>&1; then
    gh release download "v$TAGV" -R "$UPREPO" \
        -p 'agent2api-server-linux-arm64.tar.gz*' -D "$TMP" >/dev/null 2>&1 || true
    if [ -f "$TMP/agent2api-server-linux-arm64.tar.gz" ]; then
        if [ -f "$TMP/agent2api-server-linux-arm64.tar.gz.sha256" ]; then
            ( cd "$TMP" && sha256sum -c --quiet agent2api-server-linux-arm64.tar.gz.sha256 ) \
                || { echo "::error::资产 sha256 校验失败（下载不完整或被替换）"; exit 1; }
            echo "   sha256 校验通过"
        else
            echo "::warning::该 release 没提供 .sha256，跳过完整性校验"
        fi
        mkdir -p "$TMP/x"
        tar -xzf "$TMP/agent2api-server-linux-arm64.tar.gz" -C "$TMP/x"
        _bin="$(find "$TMP/x" -maxdepth 2 -type f -name 'agent2api-server' | head -n1)"
        [ -n "$_bin" ] || { echo "::error::资产里没有 agent2api-server"; exit 1; }
        cp -f "$_bin" rootfs/usr/local/bin/agent2api-server
        chmod 0755 rootfs/usr/local/bin/agent2api-server
        if [ -d "$TMP/x/ui" ]; then
            cp -a "$TMP/x/ui" rootfs/app/ui
            echo "   ui 也取自资产：$(find rootfs/app/ui -type f | wc -l) 个文件"
        else
            echo "::warning::资产里没有 ui/，ui 改从镜像取"
        fi
        SRC="asset"
        BIN_SHA="$(sha256sum rootfs/usr/local/bin/agent2api-server | cut -d' ' -f1)"
        echo "   二进制取自 v$TAGV 的 Release 资产（sha256 $BIN_SHA）"
    else
        echo "::warning::v$TAGV 有 Release 但没有 arm64 资产，退回镜像"
    fi
else
    echo "::warning::上游没有 v$TAGV 的 Release（只有 tag 或 tag 已删），退回镜像"
fi

# ---------- 2) 镜像：补 so / 根证书 / 时区（缺资产时也补二进制与 ui） ----------
USED=""
for t in "$TAG" latest; do
    echo "== 2) 试镜像 $IMG:$t"
    if docker pull --platform linux/arm64 "$IMG:$t" >/dev/null 2>&1; then USED="$t"; break; fi
done
[ -n "$USED" ] || { echo "::error::镜像 $IMG 拉不下来（so/证书/时区拿不到）"; exit 1; }
if [ "$USED" != "$TAG" ]; then
    echo "::warning::没有 $IMG:$TAG，退回 $USED —— so/证书/时区可能与该 tag 不完全一致"
    [ "$SRC" = "asset" ] || echo "::warning::本包的二进制与 ui 也来自镜像 $USED，可能与上游 release 版本不符"
fi

docker run --rm --platform linux/arm64 \
    -v "$PWD/rootfs:/out" -v "$PWD/scripts/ci:/ci:ro" \
    --entrypoint /bin/sh "$IMG:$USED" /ci/inside.sh

# ---------- 3) 防呆 ----------
python3 - <<'PY'
import sys, os
p = "rootfs/usr/local/bin/agent2api-server"
d = open(p, "rb").read(20)
if d[:4] != b"\x7fELF" or int.from_bytes(d[18:20], "little") != 0xB7:
    sys.exit("运行体不是 aarch64 ELF")
print("ELF aarch64 ok, %d 字节" % os.path.getsize(p))
PY

VER="${TAGV}"
if [ "$VER" != "latest" ] && ! grep -qa "$VER" rootfs/usr/local/bin/agent2api-server; then
    echo "::warning::二进制里没找到版本串 $VER，确认来源是否与 tag 对齐"
fi

# 记账：来源写进 step 输出，notes 里要写明（可追溯）
{
    echo "src=$SRC"
    echo "image=$IMG:$USED"
    if [ -n "$BIN_SHA" ]; then echo "bin_sha256=$BIN_SHA"; fi
} >> "${GITHUB_OUTPUT:-/dev/null}"

ls -R rootfs | head -20
du -sh rootfs
