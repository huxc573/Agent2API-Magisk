#!/system/bin/sh
# 启动器：负责环境准备 + 拉起看门狗；网关本身由看门狗拉起并守着。
#
# 保活模型（v1.6.4）：
#   service.sh start → setsid watchdog.sh（脱离安装器/adb 会话）
#   watchdog.sh      → 起 `service.sh run`（前置后 exec 成网关）→ wait → 死了重拉
#   wait 是阻塞系统调用：网关活着时看门狗零 CPU、不阻休眠；网关一死立即返回。
#   ⛔ 不要改回「sleep N + pgrep 判活」：老版本 control.sh 每 3 秒扫一次 /proc，
#      光一次全表扫描就要 14.5 秒 CPU，永远追不上轮询间隔 ⇒ 单核 100%，
#      整夜掉电 80% 以上。这就是 v1.5.x 耗电的根因。
#
# 用法：
#   sh service.sh          前台 exec（调试用，跟着终端走）
#   sh service.sh start    后台起（开机流程、action.sh、安装收尾）
#   sh service.sh run      由 watchdog 调用：前置完 exec 成网关本体
#   sh service.sh stop     停看门狗 + 网关
#   sh service.sh restart  重启

MODDIR="$(dirname "$(readlink -f "$0")")"
. "$MODDIR/lib.sh"

# 等 /data 解密完成（FBE 机型 services 阶段 /data/adb 可能还没挂好）
_i=0
while [ ! -d /data/adb ] && [ "$_i" -lt 60 ]; do
    sleep 1
    _i=$((_i + 1))
done

WORK=$(ag2a_data_dir)
mkdir -p "$WORK" "$WORK/debug" 2>/dev/null

# ---------- 运行体自愈 ----------
# rt 缺失 / 没有版本戳 / 比模块旧（刷了新 zip 还没重启、或上次同步被打断）⇒ 整份重同步。
# 正常情况下这里只是 2 次 stat + 1 次 cat，不做任何复制，开销可忽略。
if [ -f "$MODDIR/rt.sh" ] && ag2a_rt_need_sync; then
    sh "$MODDIR/rt.sh" sync >/dev/null 2>&1
fi

# 兜底：1.6.x 删掉了 customize.sh，权限全靠 zip 里的模式位。
# 万一某些安装方式把文件解成 644，网关就起不来（lib/ 下的 loader 要能被 exec）。
# 这里每次启动顺手纠正一遍，幂等、开销可忽略。
# ⚠ rt/bin 也要补：customize.sh 里的 set_perm_recursive 会把数据目录下的文件统一改成
#   0600，rt 里那份二进制会被顺手收掉可执行位。
chmod 755 "$MODDIR"/*.sh "$MODDIR/bin/"* "$MODDIR/lib/ld-linux-aarch64.so.1" "$WORK/rt/bin/"* 2>/dev/null

stop_gw() {
    [ -n "$(ag2a_pids)" ] || return 0
    for _p in $(ag2a_pids); do kill "$_p" 2>/dev/null; done
    # 给 3 秒优雅退出，之后强杀（开机/重装时不该在这里耗时间）
    _i=0
    while [ -n "$(ag2a_pids)" ] && [ "$_i" -lt 15 ]; do
        sleep 0.2 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    for _p in $(ag2a_pids); do kill -9 "$_p" 2>/dev/null; done
}

# ---------- 看门狗 ----------
# 顺序很关键：停的时候必须先停看门狗，否则它会在网关被杀后立刻重拉，
# 表现就是「stop 了但进程马上又回来」。
stop_watchdog() {
    _w=$(ag2a_watchdog_pid) || { rm -f "$WORK/watchdog.pid" 2>/dev/null; return 0; }
    kill "$_w" 2>/dev/null
    # 它 trap 里要收网关，给足时间（最多 5 秒）
    _i=0
    while [ "$_i" -lt 25 ] && kill -0 "$_w" 2>/dev/null; do
        sleep 0.2 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    kill -9 "$_w" 2>/dev/null
    rm -f "$WORK/watchdog.pid" 2>/dev/null
    return 0
}

start_watchdog() {
    # 已经在跑就是幂等
    if [ -n "$(ag2a_watchdog_pid)" ]; then
        return 0
    fi
    # 有网关但没看门狗（从 1.6.3 升上来、或看门狗被系统杀过）：
    # 那个网关不是看门狗的子进程，wait 管不到它，只能重启一次纳管。
    if [ -n "$(ag2a_pids)" ]; then
        stop_gw
    fi
    # setsid：脱离安装器 / adb 会话的进程组，装完/断开后不被一起带走
    setsid sh "$MODDIR/watchdog.sh" >/dev/null 2>&1 < /dev/null &
    # 等它把 pidfile 写出来（正常 1 秒内），最多 5 秒
    _i=0
    while [ "$_i" -lt 25 ] && [ -z "$(ag2a_watchdog_pid)" ]; do
        sleep 0.2 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    [ -n "$(ag2a_watchdog_pid)" ]
}

# ---------- 自动更新：一个睡眠进程，到点才醒，不轮询 ----------
# ⛔ 别指望 crond：本机（APatch）既没有 /system/bin/crond，magisk / ksu 的 busybox 也不在，
#    探测必然失败；失败后那个「开机跑一次 tick」只跑一次 —— 自动更新会静默失效而没人发现。
#    ⛔ 探测本身也别遍历 /proc 数 crond，那又是一次 14.5 秒的全表 fork。
# ⛔ 也别每 60 秒醒一次算钟点（v1.5.x），那是纯白耗电。
# 做法：交给 updater.sh daemon —— 睡到下一个目标时刻再醒；单次最多睡 30 分钟，
#    兜住「深睡把 sleep 拉长」和「用户中途改钟点」。sleep 期间零 CPU、不阻休眠。
start_update_timer() {
    # 自动更新既然关着，就别起这个常驻进程：它只会一直睡，白占一个进程槽，
    # 而且在 ps 里挂着容易让人误以为「自动更新还在跑」。
    if ! ag2a_update_on; then
        stop_update_timer
        return 0
    fi
    if [ -f "$WORK/update.timer.pid" ]; then
        _t=$(cat "$WORK/update.timer.pid" 2>/dev/null)
        # 必须校验 cmdline：pid 会被复用，只看 kill -0 会把无关进程当成自己的定时器
        if [ -n "$_t" ] && kill -0 "$_t" 2>/dev/null &&
           grep -q 'updater.sh' "/proc/$_t/cmdline" 2>/dev/null; then
            return 0
        fi
    fi
    setsid sh "$MODDIR/updater.sh" daemon >/dev/null 2>&1 < /dev/null &
    return 0
}

stop_update_timer() {
    [ -f "$WORK/update.timer.pid" ] || return 0
    _t=$(cat "$WORK/update.timer.pid" 2>/dev/null)
    if [ -n "$_t" ] && kill -0 "$_t" 2>/dev/null; then
        kill "$_t" 2>/dev/null
        # 等它自己走完 trap（会顺手收掉子 sleep），最多 2 秒
        _i=0
        while [ "$_i" -lt 10 ] && kill -0 "$_t" 2>/dev/null; do
            sleep 0.2 2>/dev/null
            _i=$((_i + 1))
        done
        # 兜底：万一它被 KILL 掉、来不及收子进程，按 PPID 把残留子进程一起清掉
        for _c in $(ps -A -o PID,PPID 2>/dev/null | awk -v t="$_t" '$2 == t {print $1}'); do
            kill -9 "$_c" 2>/dev/null
        done
        kill -9 "$_t" 2>/dev/null
    fi
    rm -f "$WORK/update.timer.pid" 2>/dev/null
    return 0
}

# ---------- 起不来时留证据 ----------
# 网关自己崩掉时日志有报错；但如果它连一行都没打出来（loader 找不到、ELF 不兼容、
# 配置写坏直接退出），run.log 里就什么都没有，只剩看门狗在「重拉」。
# 这里在「确认没进程、端口也没监听」时手动跑一次二进制，把真实报错留在 run.log 里，
# 面板「打开」页的日志块和 check.sh 都能直接看到。
# ⚠ 只在没进程时跑：有实例在跑时再起一个只会撞端口，日志全是假的。
diag_dump() {
    [ -n "$(ag2a_pids)" ] && return 0
    _db=$(ag2a_bin)
    {
        echo "$(date '+%m-%d %H:%M') [diag] 端口 ${1:-?} 未监听，自检开始"
        echo "[diag] bin=$_db rtver=$(ag2a_rtver) modver=$(ag2a_modver) rt需要同步=$(ag2a_rt_need_sync && echo 是 || echo 否)"
        echo "[diag] 依赖:"
        "$MODDIR/lib/$AG2A_LD_NAME" --library-path "$MODDIR/lib" --list "$_db" 2>&1 | head -n 8
        echo "[diag] 前台直跑 6 秒（真正的报错应该在这几行）:"
        ( cd "$WORK" && exec "$MODDIR/lib/$AG2A_LD_NAME" --library-path "$MODDIR/lib" "$_db" ) 2>&1 &
        _dp=$!
        sleep 6
        kill -9 "$_dp" 2>/dev/null
        echo "[diag] 自检结束"
    } >> "$WORK/run.log" 2>&1
}

case "$1" in
    stop)    stop_watchdog; stop_gw; stop_update_timer; exit 0 ;;
    # ⛔ restart 必须落到 start 分支：只写「停三件套」的话，后面
    #    `[ -z "$1" ] || [ "$1" = "start" ]` 不成立，会一路掉到文件末尾的
    #    前台 exec ⇒ restart 永不返回（调用方例如 Shizuku/面板会超时），
    #    而且看门狗不会被拉起。用 set -- start 复写参数，走同一套后台流程。
    restart) stop_watchdog; stop_gw; stop_update_timer; set -- start ;;
    crontab) stop_update_timer; start_update_timer; exit 0 ;;
esac

# 已在跑就不重复起（restart 除外）；但看门狗和定时器要按最新配置兜一次。
# run 是 watchdog 专用的前台模式，必须绕开这个早退判断，否则会立刻退出→无限重启。
if [ "$1" != "restart" ] && [ "$1" != "run" ] && [ -n "$(ag2a_pids)" ]; then
    case "$1" in
        # 空参数 = 开机流程调用（APatch/Magisk 都是无参执行 service.sh），
        # 必须和 start 同等对待，否则看门狗在本分支下不会被拉起。
        start | "") start_watchdog; start_update_timer ;;
        crontab)    stop_update_timer; start_update_timer ;;
    esac
    exit 0
fi

[ -f "$(ag2a_bin)" ] || { echo "[ag2a] 缺少二进制 $(ag2a_bin)" >&2; exit 1; }
[ -f "$MODDIR/lib/$AG2A_LD_NAME" ] || { echo "[ag2a] 缺少 loader" >&2; exit 1; }

# ---------- 运行环境（glibc 二进制在 Android 上能跑的全部前提） ----------
[ -f "$WORK/env" ] && . "$WORK/env"
export AGENT2API_PROXY_HOME="$WORK"
export HOME="$WORK"
export AGENT2API_HOST="${AGENT2API_HOST:-0.0.0.0}"
export AGENT2API_UI_DIR="$(ag2a_ui)"
# 面板自带的一键更新默认关：模块有独立更新通道，两条一起跑会互相覆盖
export AGENT2API_SELF_UPDATE="${AGENT2API_SELF_UPDATE:-0}"

# 端口以 $WORK/port 为准：上游「config.json 已有 listen 就沿用」，所以要钉住 listen
PORT_FORCED=$(ag2a_get_port)
[ -f "$WORK/port" ] && ag2a_force_port "$PORT_FORCED"
export AGENT2API_PROXY_PORT="$PORT_FORCED"

eval "$(ag2a_cert_env)"     # rustls 不内嵌根证书
eval "$(ag2a_tz_env)"       # 二进制读 /usr/share/zoneinfo

# ---------- 管理员：只在明确设过密码时播种 ----------
# 上游 env 不参与认证（只认 db 里的 bcrypt 哈希），唯一可用入口是 POST /api/panel/setup。
# 默认不预设账号：没有 admin_pw 就完全不管，面板登录页会自己切到「创建账号」。
AG2A_ADMIN_USER="${AG2A_ADMIN_USER:-root}"
[ -s "$WORK/admin_user" ] && AG2A_ADMIN_USER=$(head -n1 "$WORK/admin_user" | tr -d '\r')
AG2A_ADMIN_PASSWORD=""
if [ -s "$WORK/admin_pw" ]; then
    AG2A_ADMIN_PASSWORD=$(head -n1 "$WORK/admin_pw" | tr -d '\r')
fi

# 日志归档：只在冷启动做一次（此刻没有写入者，mv 安全）
[ -f "$WORK/boot.marker" ] || ag2a_rotate "$WORK/run.log" 5242880

cd "$WORK" || exit 1

# ---------- 后台模式 ----------
# ⚠ 空参数也要走这里：APatch / Magisk 开机执行的是无参的 `sh service.sh`，
#   历史上它走的是「前台 exec 网关」，于是看门狗永远不会被拉起（1.6.4 的真实 bug）。
if [ -z "$1" ] || [ "$1" = "start" ]; then
    # 插件入口套壳：插件是 glibc 独立进程，Android 没有 /lib/ld-linux-aarch64.so.1，
    # 面板直接 exec 会 ENOENT（日志里那句 No such file or directory）。必须在网关起来前修好，
    # 否则面板加载插件还是失败。幂等、只碰 plugins/*/*/bin 下的 ELF，开销可忽略。
    sh "$MODDIR/pluginfix.sh" quiet >/dev/null 2>&1
    # 网关不再由这里直接起，而是交给看门狗（它负责崩溃重拉）
    if ! start_watchdog; then
        echo "[ag2a] 看门狗没能启动（$WORK/watchdog.pid 未出现）" >&2
        exit 1
    fi
    # 等端口真的在 LISTEN，而不是「进程存在就算好」。
    # 端口被占、配置写坏时进程活着但绑不上，这时报「已启动」是假消息。
    _i=0
    while [ "$_i" -lt 30 ] && ! ag2a_port_listen "$PORT_FORCED"; do
        sleep 0.5 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done
    if [ -n "$AG2A_ADMIN_PASSWORD" ] && [ ! -f "$WORK/admin.json" ]; then
        sleep 1
        ag2a_seed_admin "$PORT_FORCED"
        case "$?" in
            0) rm -f "$WORK/admin_pw"
               echo "$(date '+%m-%d %H:%M') 管理员已建: $AG2A_ADMIN_USER" >> "$WORK/seed.log" 2>/dev/null ;;
            3) rm -f "$WORK/admin_pw" ;;
        esac
    fi
    # 列表里刷一次状态（运行中 · IP:端口）；之后只在点「操作」时刷
    sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1
    # 自动更新：起睡眠定时器（开机先 tick 一次，漏掉今天钟点也能补上）
    start_update_timer
    echo "$(date '+%m-%d %H:%M') 网关已启动（看门狗 pid $(ag2a_watchdog_pid)）" >> "$WORK/run.log"
    # 记一行运行体来源：排查「升级了但服务还是老的」时，先看这里
    echo "$(date '+%m-%d %H:%M') 运行体 $(ag2a_bin)（rt $(ag2a_rtver) / 模块 $(ag2a_modver)）" >> "$WORK/run.log"
    if ag2a_port_listen "$PORT_FORCED"; then
        exit 0
    fi
    # 后台自检（约 6 秒）写进 run.log，写完再刷一次说明行；不让点按钮的人多等
    ( diag_dump "$PORT_FORCED"; sh "$MODDIR/refresh.sh" quiet ) >/dev/null 2>&1 &
    echo "[ag2a] 网关 15 秒内没有监听端口 $PORT_FORCED，详见 $WORK/run.log" >&2
    exit 1
fi

# ---------- 前台模式：exec，把本进程直接变成网关 ----------
if [ -n "$AG2A_ADMIN_PASSWORD" ] && [ ! -f "$WORK/admin.json" ]; then
    ( sleep 3
      ag2a_seed_admin "$PORT_FORCED" >/dev/null 2>&1 && rm -f "$WORK/admin_pw" ) &
fi
# shellcheck disable=SC2086
exec $(ag2a_cmdline)
