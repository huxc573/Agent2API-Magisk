#!/usr/bin/env bash
# 从官方 arm64 镜像抽运行体，拼出 build_module.py 需要的 rootfs/ 目录结构。
# 用法: scripts/ci/rootfs.sh <上游 tag>   （tag 不存在时退回 latest）
set -euo pipefail

TAG="${1:?需要上游 tag}"
IMG="${AG2A_IMAGE:-aimodcc/agent2api}"

USED=""
for t in "$TAG" latest; do
    echo "== 试 $IMG:$t"
    if docker pull --platform linux/arm64 "$IMG:$t"; then USED="$t"; break; fi
done
[ -n "$USED" ] || { echo "::error::镜像 $IMG 拉不下来"; exit 1; }
[ "$USED" = "$TAG" ] || echo "::warning::没有 $TAG 的镜像 tag，退回 $USED —— 本次包里的运行体版本可能与上游 release 不一致"

rm -rf rootfs publish
docker run --rm --platform linux/arm64 \
    -v "$PWD/rootfs:/out" -v "$PWD/scripts/ci:/ci:ro" \
    --entrypoint /bin/sh "$IMG:$USED" /ci/inside.sh

# 防呆：必须是 aarch64 ELF，且版本串对得上（上游二进制里带 tag 字符串）
python3 - <<'PY'
import sys, os
p = "rootfs/usr/local/bin/agent2api-server"
d = open(p, "rb").read(20)
if d[:4] != b"\x7fELF" or int.from_bytes(d[18:20], "little") != 0xB7:
    sys.exit("运行体不是 aarch64 ELF")
print("ELF aarch64 ok, %d 字节" % os.path.getsize(p))
PY

VER="${USED#v}"
if [ "$VER" != "latest" ] && ! grep -qa "$VER" rootfs/usr/local/bin/agent2api-server; then
    echo "::warning::二进制里没找到版本串 $VER，确认镜像 tag 是否与 release 对齐"
fi

ls -R rootfs | head -30
du -sh rootfs
