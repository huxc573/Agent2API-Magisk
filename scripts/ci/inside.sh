#!/bin/sh
# 在 arm64 镜像里跑（qemu 模拟），把模块需要的运行体拷到挂进来的 /out。
# 只做「原样搬运」：不编译、不改二进制。
#
# /out/usr/local/bin/agent2api-server 与 /out/app/ui 可能已由 rootfs.sh 从
# 上游 Release 资产放好（那是与 tag 一一对应、且过了 sha256 校验的版本），
# 此时镜像只负责补 so / 根证书 / 时区，不能覆盖它们。
set -eu

if [ -f /out/usr/local/bin/agent2api-server ]; then
    BIN=/out/usr/local/bin/agent2api-server
    echo "bin: 已由上游 Release 资产提供（$(wc -c < "$BIN") 字节），镜像不覆盖"
else
    BIN=/usr/local/bin/agent2api-server
    [ -f "$BIN" ] || BIN=$(command -v agent2api-server)
    [ -n "$BIN" ] && [ -f "$BIN" ] || { echo "镜像里找不到 agent2api-server"; exit 1; }
    mkdir -p /out/usr/local/bin
    cp -f "$BIN" /out/usr/local/bin/agent2api-server
    echo "bin: $(wc -c < "$BIN") 字节（来自镜像）"
fi

mkdir -p /out/lib /out/etc /out/usr/share/zoneinfo/Asia /out/app

if [ -d /out/app/ui ]; then
    echo "ui: 已由上游 Release 资产提供（$(find /out/app/ui -type f | wc -l) 个文件）"
else
    UI=""
    for d in /app/ui /ui /opt/agent2api/ui /srv/ui; do
        [ -d "$d" ] && { UI="$d"; break; }
    done
    [ -n "$UI" ] || { echo "镜像里找不到 panel ui 目录"; exit 1; }
    cp -a "$UI" /out/app/ui
    echo "ui: $(find /out/app/ui -type f | wc -l) 个文件（来自 $UI）"
fi

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
