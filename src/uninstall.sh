#!/system/bin/sh
# 卸载：停进程 + 删模块目录 + 删数据目录。
# ⛔ 只碰写死的两个路径，且必须精确匹配白名单；其它一律不删。
#    绝不用通配符、绝不 rm -rf 任何动态拼出来的路径。
#    想重装后保留账号：卸载前 touch /data/adb/ag2a/keep

MODDIR=/data/adb/modules/ag2a
WORK=/data/adb/ag2a

# 白名单删除：只认这三个精确路径，其它一律拒绝（防变量异常时误删）
safe_rm() {
    case "$1" in
        /data/adb/modules/ag2a | /data/adb/modules_update/ag2a | /data/adb/ag2a)
            [ -d "$1" ] || return 0
            rm -rf "$1" 2>/dev/null
            [ -d "$1" ] && return 1
            return 0 ;;
        *)
            echo "[ag2a] 拒绝删除非白名单路径: $1" >&2
            return 1 ;;
    esac
}

# 先停网关再停更新定时器（v1.6.2 起定时器是个 sleep 进程，不是 crond）
_svc="$MODDIR/service.sh"
if [ -f "$_svc" ]; then
    sh "$_svc" stop >/dev/null 2>&1
fi
# 更新定时器：按 pidfile 精确杀掉（不 pkill，避免误伤同名进程）
if [ -f "$WORK/update.timer.pid" ]; then
    _t=$(cat "$WORK/update.timer.pid" 2>/dev/null)
    if [ -n "$_t" ]; then
        kill "$_t" 2>/dev/null
        sleep 0.2 2>/dev/null
        kill -9 "$_t" 2>/dev/null
    fi
    rm -f "$WORK/update.timer.pid" 2>/dev/null
fi
# 老版本（v1.6.0/1）遗留的 crontab 与 crond 一并清掉
rm -f "$WORK/crontab" "$WORK/crontab.tmp" 2>/dev/null

# 兜底：老版本的常驻循环 / 网关进程（v1.5.x 及以前）
# 四条路径都要扫：v1.9.0 起网关从 rt/ 起，模块目录里那份只是回退（见 lib.sh）
pkill -f "$MODDIR/control.sh" 2>/dev/null
pkill -f "$MODDIR/updater.sh" 2>/dev/null
pkill -f "$MODDIR/bin/agent2api-server" 2>/dev/null
pkill -f "$WORK/rt/bin/agent2api-server" 2>/dev/null
pkill -f "/data/adb/modules_update/ag2a/bin/agent2api-server" 2>/dev/null
sleep 1
pkill -9 -f "$MODDIR/control.sh" 2>/dev/null
pkill -9 -f "$MODDIR/updater.sh" 2>/dev/null
pkill -9 -f "$MODDIR/bin/agent2api-server" 2>/dev/null
pkill -9 -f "$WORK/rt/bin/agent2api-server" 2>/dev/null
pkill -9 -f "/data/adb/modules_update/ag2a/bin/agent2api-server" 2>/dev/null

echo "[ag2a] 网关 / 更新排班 / 旧版循环已停止。"
# 运行体自检：rt/ 里还留着二进制就说明进程没停干净（下面删数据目录会连带删掉）
if [ -f "$WORK/rt/bin/agent2api-server" ] && [ -n "$(pgrep -f "$WORK/rt/bin/agent2api-server" 2>/dev/null)" ]; then
    echo "[ag2a] ⚠ 仍有进程在用 $WORK/rt 里的二进制，重启后再手动删一次 $WORK"
fi

touch "$MODDIR/remove" 2>/dev/null
[ -f "$MODDIR/disable" ] || touch "$MODDIR/disable" 2>/dev/null
cd / 2>/dev/null
safe_rm "$MODDIR"
safe_rm /data/adb/modules_update/ag2a

# 历史残留：v1.3.3~1.3.4 的刷入脚本曾在 /data/local/tmp/.ag2a_key.<pid> 里传按键结果
# （正常流程当场删掉，安装被杀才会留下）。v1.3.5 起不再写任何临时文件。
# 只删「前缀 + 纯数字」的文件，其它一概不碰；也不用 .ag2a_* 这种宽通配。
for _k in /data/local/tmp/.ag2a_key.*; do
    [ -f "$_k" ] || continue
    case "${_k##*/.ag2a_key.}" in
        '' | *[!0-9]*) continue ;;
    esac
    rm -f "$_k" 2>/dev/null
done

# 数据目录：账号库、配置、日志 —— 一并清掉
if [ -f "$WORK/keep" ]; then
    echo "[ag2a] 检测到 $WORK/keep，保留数据目录（重装可继续用同一个账号）。"
else
    if safe_rm "$WORK"; then
        echo "[ag2a] 数据目录已删除（$WORK）。"
    else
        echo "[ag2a] 数据目录没删干净（$WORK），重启后再手动删一次。"
    fi
fi

if [ -d "$MODDIR" ]; then
    echo "[ag2a] 模块目录没删掉（$MODDIR），已打 remove 标记：重启后由管理器清除。"
else
    echo "[ag2a] 模块已卸载（目录已删除，管理器列表刷新后即消失）。"
fi
