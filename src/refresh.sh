#!/system/bin/sh
# 刷新模块列表里显示的 description（运行中 · IP:端口）。
#
# ⛔ 这不是守护进程，不会循环。调用时机只有三个：
#   1) service.sh start 之后（启动完刷一次）
#   2) action.sh 里手动刷（点「操作」按钮 / sh action.sh refresh）
#   3) WiFi 变化后用户想更新显示（同上）
# 老版本的 control.sh 每 30 秒无条件重算一遍 IP 再写 module.prop，
# 那是「为了列表好看」付出整夜掉电的代价 —— 不值。

MODDIR="${AG2A_REFRESH_MODDIR:-$(dirname "$(readlink -f "$0")")}"
case "$MODDIR" in
    '' | / | /data | /data/adb | /sdcard | /storage* | /system* | /data/local/tmp)
        MODDIR=$(dirname "$(readlink -f "$0")") ;;
esac
. "$MODDIR/lib.sh"

WORK=$(ag2a_data_dir)
IP=""

# ---- 状态 ----
if [ -f "$MODDIR/disable" ]; then
    ST="已停用（模块被关闭）"
elif [ ! -f "$(ag2a_bin)" ]; then
    ST="缺少二进制"
elif [ ! -f "$MODDIR/lib/$AG2A_LD_NAME" ]; then
    ST="缺少 loader"
elif ag2a_running; then
    ST="运行中"
    IP=$(wlan_ip)
    [ -n "$IP" ] || IP=127.0.0.1     # 拿不到局域网 IP 也要给个能点的地址
    _run=1
else
    ST="未运行"
fi
PORT=$(ag2a_get_port)
[ -n "$PORT" ] || PORT=${AG2A_DEFAULT_PORT:-3065}
ST="$ST · $IP:$PORT"
# 点「执行」重启后管理器会**自己退回列表**（APatch 的 ExecuteAPMActionScreen 成功即
# popBackStack，脚本控制不了），所以结果只能看这一行：把启动时刻写进来，时间变了就是重启成功。
[ -n "$_run" ] && ST="$ST · $(date '+%H:%M') 启动"
case "$ST" in
    *停用* | *缺少*) : ;;
    *) ST="$ST ｜ 执行=重启进程" ;;
esac

# ---- 写 module.prop（只写这一行，写临时文件再 mv；不用 sed -i，某些挂载点会静默失败） ----
_mp="$MODDIR/module.prop"
_have=0
grep -q '^description=' "$_mp" 2>/dev/null && _have=1
if [ ! -w "$_mp" ] && [ "$(id -u 2>/dev/null)" != "0" ]; then
    echo "module.prop 不可写，跳过" >&2
    exit 1
fi
if [ "$_have" = "1" ]; then
    if { grep -v '^description=' "$_mp"; printf 'description=%s\n' "$ST"; } > "$_mp.tmp" 2>/dev/null &&
       mv -f "$_mp.tmp" "$_mp" 2>/dev/null; then
        chmod 0644 "$_mp" 2>/dev/null
    else
        rm -f "$_mp.tmp" 2>/dev/null
        echo "$(date '+%m-%d %H:%M') 写 module.prop 失败（$ST）" >> "$WORK/desc.log" 2>/dev/null
        exit 1
    fi
fi

[ "$1" = "quiet" ] || printf '%s\n' "$ST"
exit 0
