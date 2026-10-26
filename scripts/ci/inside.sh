#!/bin/sh
# 在 arm64 镜像里跑（qemu 模拟），把模块需要的运行体拷到挂进来的 /out。
# 只做「原样搬运」：不编译、不改二进制。
set -eu

BIN=/usr/local/bin/agent2api-server
[ -f "$BIN" ] || BIN=$(command -v agent2api-server)
[ -n "$BIN" ] && [ -f "$BIN" ] || { echo "镜像里找不到 agent2api-server"; exit 1; }

mkdir -p /out/usr/local/bin /out/lib /out/etc /out/usr/share/zoneinfo/Asia /out/app
cp -f "$BIN" /out/usr/local/bin/agent2api-server
echo "bin: $(wc -c < "$BIN") 字节"

UI=""
for d in /app/ui /ui /opt/agent2api/ui /srv/ui; do
    [ -d "$d" ] && { UI="$d"; break; }
done
[ -n "$UI" ] || { echo "镜像里找不到 panel ui 目录"; exit 1; }
cp -a "$UI" /out/app/ui
echo "ui: $(find /out/app/ui -type f | wc -l) 个文件（来自 $UI）"

cp -f /etc/ssl/certs/ca-certificates.crt /out/etc/ca-certificates.crt
cp -f /usr/share/zoneinfo/Asia/Shanghai /out/usr/share/zoneinfo/Asia/Shanghai

# 二进制依赖的 so + 解释器：原样按 basename 摊平到 lib/
LD=$(readelf -l "$BIN" 2>/dev/null | sed -n 's/.*interpreter: \(.*\)\]/\1/p')
for l in $LD $(ldd "$BIN" 2>/dev/null | awk '/=>/ {print $3} /ld-linux/ {print $1}'); do
    [ -f "$l" ] || continue
    cp -Lf "$l" "/out/lib/$(basename "$l")"
done
ls -l /out/lib
echo "运行体抽取完成"
