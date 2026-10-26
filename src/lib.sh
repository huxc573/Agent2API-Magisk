#!/system/bin/sh
# 公共工具：control.sh / action.sh / service.sh / customize.sh 都会 source 它。
# 被 source 不执行，所以不需要可执行位。

# ---------- 路径 ----------
# MODDIR 由调用方设置（customize.sh 里是 $MODPATH，其余由 $0 推导）
DATA_DIR_DEFAULT=/data/adb/ag2a

# busybox 位置：Magisk / KernelSU / APatch 三种根方案各不相同。
# ⛔ 别只写死 /data/adb/magisk/busybox —— 本机是 APatch，只装了 /data/adb/ap/bin/busybox。
# 只在 source 时做几次 stat，不 fork。
AG2A_BUSYBOX=""
for _bb in /data/adb/ap/bin/busybox /data/adb/magisk/busybox /data/adb/ksu/bin/busybox; do
    [ -x "$_bb" ] && { AG2A_BUSYBOX=$_bb; break; }
done

# 数据目录：只认 /data/adb/ag2a（及其子目录）。
# ⛔ 这个值会被 rm -rf 用，绝不能由外部随意指定 —— 一旦变成空/根目录就是灾难。
# 本地测试用环境变量 AG2A_DATA_DIR 旁路（只在测试脚本里设）。
ag2a_data_dir() {
    if [ -n "$AG2A_DATA_DIR" ]; then
        echo "$AG2A_DATA_DIR"
        return
    fi
    _d=$(cat "$MODDIR/.datadir" 2>/dev/null | head -n1 | tr -d '\r')
    case "$_d" in
        /data/adb/ag2a | /data/adb/ag2a/*) : ;;
        *) _d=$DATA_DIR_DEFAULT ;;
    esac
    echo "$_d"
}

# ---------- 二进制 / 库 ----------
AG2A_ID=ag2a
AG2A_BIN_NAME=agent2api-server
AG2A_LD_NAME=ld-linux-aarch64.so.1

# 运行体（bin/ + ui/）的权威位置＝数据目录下的 rt/。
# 为什么不用模块目录：/data/adb/modules/ag2a 是 Magisk 的地盘，只有**下次启动**才会被
#   modules_update 整体替换；运行体放里面，刷完 zip 不重启就还是旧二进制。
#   /data/adb/ag2a 是模块自己的数据，Magisk 从不碰 ⇒ 同步过去立刻生效。
# 同步逻辑在 rt.sh，这里只做路径解析。
ag2a_rt() { echo "$(ag2a_data_dir)/rt"; }

# 二进制：rt 优先，缺失时回退模块目录（保证任何情况下都起得来）
ag2a_bin() {
    _ab="$(ag2a_data_dir)/rt/bin/$AG2A_BIN_NAME"
    if [ -f "$_ab" ]; then echo "$_ab"; else echo "$MODDIR/bin/$AG2A_BIN_NAME"; fi
}

# UI 目录：同规则
ag2a_ui() {
    _au="$(ag2a_data_dir)/rt/ui"
    if [ -d "$_au" ]; then echo "$_au"; else echo "$MODDIR/ui"; fi
}

# rt 的版本戳（= 同步时源 module.prop 的 versionCode）。rt.sh sync 的最后一步才写它，
# 所以它等价于「这次同步完整跑完了」的提交点。读不到一律当 0（= 不可信，需要重同步）。
ag2a_rtver() {
    _rv=$(sed -n '1p' "$(ag2a_rt)/.rtver" 2>/dev/null | tr -dc '0-9')
    case "$_rv" in '' | *[!0-9]*) _rv=0 ;; esac
    echo "$_rv"
}

# 模块自带 module.prop 的 versionCode；读不到当 0
ag2a_modver() {
    _mv=$(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1 | tr -dc '0-9')
    case "$_mv" in '' | *[!0-9]*) _mv=0 ;; esac
    echo "$_mv"
}

# 是否需要把模块目录的 bin/ui 重新同步进 rt（0=需要 1=不需要）。
# 三种情况要同步：rt 里没有二进制 / 没有版本戳（同步被打断过） / rt 比模块旧。
# ⚠ 判据必须是「rt 比模块旧」而不是「不相等」：刷完 zip 但还没重启时，
#   rt 已经是新版、模块目录还是旧版，用「不相等」会把 rt 反而降级回旧版。
ag2a_rt_need_sync() {
    [ -f "$(ag2a_rt)/bin/$AG2A_BIN_NAME" ] || return 0
    _nsv=$(ag2a_rtver)
    [ "$_nsv" -gt 0 ] 2>/dev/null || return 0
    _nmv=$(ag2a_modver)
    [ "$_nmv" -gt "$_nsv" ] 2>/dev/null || return 1
    return 0
}

# 启动器：loader --library-path <模块lib> <二进制>
# 用 loader 直接跑，不 chroot、不建 rootfs：二进制只依赖 libc/libm/libgcc_s。
# ⚠ loader 与 lib/ 始终留在模块目录（上游从没换过它们，没必要跟着版本搬）。
ag2a_cmdline() {
    printf '%s --library-path %s %s' \
        "$MODDIR/lib/$AG2A_LD_NAME" "$MODDIR/lib" "$(ag2a_bin)"
}

# ---------- 配置 ----------
# 自动更新开关：update.off 文件 或 AG2A_UPDATE_INTERVAL=0 都算关闭。
# 放 lib.sh 是因为 service.sh（要不要起定时器）、updater.sh（tick 该不该干活）、
# customize.sh（刷入时显示当前状态）三处都要判，各写一份必然会漂。
ag2a_update_on() {
    [ -f "$WORK/update.off" ] && return 1
    _u=$(sed -n 's/^AG2A_UPDATE_INTERVAL=\([0-9][0-9]*\).*/\1/p' "$WORK/update.conf" 2>/dev/null | head -n1)
    # 没有配置文件＝默认开启
    [ -n "$_u" ] || return 0
    [ "$_u" -gt 0 ] 2>/dev/null
}

# 端口优先级：$WORK/port（安装时写入，最高）> config.json 的 listen > 默认 3065
# 上游是「config.json 已有 listen 就原样沿用」，光改 env 里的 PORT 会被无视，所以端口单独落一个文件。
ag2a_get_port() {
    _pf="$(ag2a_data_dir)/port"
    _q=""
    [ -r "$_pf" ] && _q=$(tr -dc '0-9' < "$_pf" 2>/dev/null | head -n1)
    case "$_q" in
        '') : ;;
        *[!0-9]*) : ;;
        [1-9]*) [ "$_q" -ge 1024 ] 2>/dev/null && [ "$_q" -le 65535 ] 2>/dev/null && { echo "$_q"; return; } ;;
    esac
    _cfg="$(ag2a_data_dir)/config.json"
    _p=$(sed -n 's/.*"listen"[^"]*"\([^"]*\)".*/\1/p' "$_cfg" 2>/dev/null | head -n1)
    case "$_p" in
        *:*) _p=${_p##*:} ;;
    esac
    case "$_p" in
        '' | *[!0-9]*) _p=${AG2A_DEFAULT_PORT:-3065} ;;
    esac
    echo "$_p"
}

# 启动时按 $WORK/port 校正 config.json 的 listen：上游「已有 listen 就原样沿用」，
# 所以只有首启前写好 env、或改这里才真正换端口。
ag2a_force_port() {
    _fp=$1
    _cfg="$(ag2a_data_dir)/config.json"
    [ -n "$_fp" ] && [ -f "$_cfg" ] || return 0
    case "$_fp" in '' | *[!0-9]*) return 0 ;; esac
    if grep -q '"listen"' "$_cfg" 2>/dev/null; then
        sed -i "s|\"listen\"\([[:space:]]*:[[:space:]]*\)\"[^\"]*\"|\"listen\"\1\"0.0.0.0:$_fp\"|" "$_cfg" 2>/dev/null
    fi
}

# ---------- 网络 ----------
# 单个接口的 IPv4；先 ip -4，再退 ifconfig（两种 ifconfig 输出都认）
iface_ip() {
    _a=$(ip -4 -o addr show "$1" 2>/dev/null | awk 'NR==1{split($4,x,"/"); print x[1]}')
    [ -n "$_a" ] && { echo "$_a"; return; }
    ifconfig "$1" 2>/dev/null | sed -n \
        -e 's/.*[[:space:]]inet addr:\([0-9][0-9.]*\).*/\1/p' \
        -e 's/.*[[:space:]]inet[[:space:]][[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -n1
}

# 取一个 PC 能访问到的 IPv4：只认 wlan0 / ap*，故意不碰 rmnet/ccmni 蜂窝口
# （蜂窝地址 PC 连不上，显示它比不显示更误导）
wlan_ip() {
    _v=$(iface_ip wlan0)
    [ -n "$_v" ] && { echo "$_v"; return; }
    for _d in $(ip -4 -o addr show 2>/dev/null | awk '{print $2}' | grep -E '^(wlan|ap)') \
              $(ifconfig -a 2>/dev/null | sed -n 's/^\(\(wlan\|ap\)[a-zA-Z0-9_]*\)[[:space:]:].*/\1/p'); do
        [ "$_d" = wlan0 ] && continue
        _v=$(iface_ip "$_d")
        [ -n "$_v" ] && { echo "$_v"; return; }
    done
}

# ---------- 进程 ----------
# 判活 = 找 argv 里带 <运行体>/bin/agent2api-server 的进程。
#
# ⛔ 绝不要写成「遍历 /proc + 每个进程 fork 一次 tr/cat」：
#    本机约 1000 个进程时，那个写法单次实测 14.5 秒 CPU（2000 次 fork × 20–30ms）。
#    v1.5.x 把它放进每 3 秒一轮的 control.sh，永远追不上轮询间隔 ⇒ 单核 100% 跑满，
#    这是那一版整夜掉电的主因（CPU 2668mAh / 55%、UID 0 排第一）。
#    同一台机器对照：pgrep -f 单次 72ms、ps 单次 75ms，结果完全一致，快 200 倍以上。
#
# 匹配命令行里带 <模块目录> 的 agent2api-server（用完整路径，避免误杀别的同名进程）
#
# ⚠ 安装期路径错乱：customize.sh 是在临时目录（/data/adb/modules_update/ag2a 或
#   /dev/tmp/...）里执行的，从那里拉起的进程 cmdline 记的就是临时路径。安装完成把
#   目录搬到 /data/adb/modules/ag2a 之后，只按 $MODDIR 匹配就认不出这个进程，
#   于是 start 判定「没在跑」再起一个 ⇒ 端口被占、新进程起不来、旧进程变孤儿。
#   之前设备上那个指向 modules_update 的 5982 就是这么来的。所以两路都要匹配。
_ag2a_pids_one() {
    # $1 = cmdline 里要匹配的完整路径
    if command -v pgrep >/dev/null 2>&1; then
        for _p in $(pgrep -f "$1" 2>/dev/null); do
            # 排掉自己：调用方命令行里也可能带这个路径，不能把自己当网关（会误杀）
            case "$_p" in
                "$$" | "$PPID") continue ;;
            esac
            echo "$_p"
        done
        return 0
    fi
    # 没有 pgrep 的老 ROM：用 ps 一次读全表（1 次 fork）。
    # ⛔ 别退回「遍历 /proc + 每进程 fork 一次 tr」—— 那正是下面警告里 14.5 秒的写法。
    ps -A -o PID,ARGS 2>/dev/null | while read -r _pid _rest; do
        case "$_pid" in
            '' | *[!0-9]* | "$$" | "$PPID") continue ;;
        esac
        case " $_rest" in
            *"$1"*) echo "$_pid" ;;
        esac
    done
}

ag2a_pids() {
    # 四条路都要匹配：
    #   rt/                          运行体权威位置（v1.9.0 起）
    #   $MODDIR/bin/                 旧装法、或 rt 还没同步时的回退
    #   /data/adb/modules/ag2a/bin/  ⛔ 和 $MODDIR 不是一回事：customize.sh 里
    #                                $MODDIR=$MODPATH=…/modules_update/ag2a，
    #                                从那儿调 stop 必须能认出正跑着的旧网关
    #   modules_update/              安装期从临时目录拉起的进程（见上面那段警告）
    # 四者输出可能有重复，统一用 awk 去重。
    for _q in "$(ag2a_data_dir)/rt/bin/$AG2A_BIN_NAME" \
              "$MODDIR/bin/$AG2A_BIN_NAME" \
              "/data/adb/modules/$AG2A_ID/bin/$AG2A_BIN_NAME" \
              "/data/adb/modules_update/$AG2A_ID/bin/$AG2A_BIN_NAME"; do
        [ -n "$_q" ] || continue
        _ag2a_pids_one "$_q"
    done | awk 'NF && !_s[$0]++'
}

ag2a_running() {
    [ -n "$(ag2a_pids)" ]
}

# 端口是否真的在 LISTEN。
# 「进程还在」≠「服务可用」：网关可能起来了但端口没绑上（配置错、端口被占）。
# 只读 /proc/net/tcp{,6}，一次 awk 判完，不连网络、不依赖 curl。
#   /proc/net/tcp 的 $4 是状态，0A = LISTEN；$2 是 local_address，形如 00000000:0BF9
ag2a_port_listen() {
    _pt=$1
    case "$_pt" in '' | *[!0-9]*) return 1 ;; esac
    _hx=$(printf '%04X' "$_pt" 2>/dev/null)
    [ -n "$_hx" ] || return 1
    awk -v h="$_hx" '
        FNR == 1 { next }
        $4 == "0A" { n = split($2, a, ":"); if (a[n] == h) { f = 1; exit } }
        END { exit(f ? 0 : 1) }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# 看门狗的 pid；没在跑则返回非 0。
# 同样必须校验 cmdline：pid 复用会把无关进程当成看门狗（然后被 kill 掉）。
ag2a_watchdog_pid() {
    _wp=$(cat "$(ag2a_data_dir)/watchdog.pid" 2>/dev/null)
    case "$_wp" in '' | *[!0-9]*) return 1 ;; esac
    kill -0 "$_wp" 2>/dev/null || return 1
    grep -q 'watchdog\.sh' "/proc/$_wp/cmdline" 2>/dev/null || return 1
    echo "$_wp"
}

# ---------- 证书 ----------
# rustls 不内嵌根证书（实测 BEGIN CERTIFICATE 计数 0），必须给 SSL_CERT_DIR/SSL_CERT_FILE。
# 候选顺序：模块自带 → Android 13- 的 cacerts → Android 14+ 的 conscrypt APEX
ag2a_cert_env() {
    if [ -f "$MODDIR/etc/ca-certificates.crt" ]; then
        echo "SSL_CERT_FILE=$MODDIR/etc/ca-certificates.crt"
        echo "SSL_CERT_DIR=$MODDIR/etc/certs"
        return
    fi
    for _d in /system/etc/security/cacerts \
              /apex/com.android.conscrypt/cacerts; do
        if [ -d "$_d" ]; then
            echo "SSL_CERT_DIR=$_d"
            return
        fi
    done
}

# ---------- 时区 ----------
# 二进制读 /usr/share/zoneinfo（实测命中 TZif 与路径字符串）。
# TZ 直接给文件绝对路径时 glibc 不再拼 zoneinfo 目录，所以可以指模块内的单个 tzfile。
ag2a_tz_env() {
    if [ -f "$MODDIR/zoneinfo/Asia/Shanghai" ]; then
        echo "TZ=$MODDIR/zoneinfo/Asia/Shanghai"
    fi
}

# ---------- 日志 ----------
# 超限只留尾部；调用前必须保证没有写入者（只在启动时调用）
ag2a_rotate() {
    _f=$1
    _max=$2
    [ -f "$_f" ] || return 0
    [ "$(wc -c < "$_f" 2>/dev/null | tr -d ' ')" -gt "$_max" ] 2>/dev/null || return 0
    tail -c $((_max / 4)) "$_f" > "$_f.tmp" 2>/dev/null && mv -f "$_f.tmp" "$_f"
}

# ---------- 管理员播种 ----------
# 用 POST /api/panel/setup 建管理员（CAPTCHA_ENABLED=0 时免人机验证）。
# 返回 0=建好 1=还没建好（未监听/被拒）3=库里已有管理员。
# 面板只对本机开放，所以打 127.0.0.1；不依赖 curl（Android 12 起系统没带）。
ag2a_seed_admin() {
    _port=$1
    [ -n "$_port" ] || return 1
    [ -f "$WORK/admin.json" ] && return 3
    _body="{\"username\":\"$AG2A_ADMIN_USER\",\"password\":\"$AG2A_ADMIN_PASSWORD\"}"
    _out=""
    if command -v curl >/dev/null 2>&1; then
        _out=$(curl -s --noproxy '*' --max-time 8 -X POST -H 'Content-Type: application/json' \
               -d "$_body" "http://127.0.0.1:$_port/api/panel/setup" 2>/dev/null)
    elif [ -n "$AG2A_BUSYBOX" ]; then
        # 用 busybox nc 发 POST（busybox wget 只有 GET，dash 没 /dev/tcp）
        _out=$(printf 'POST /api/panel/setup HTTP/1.0\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' \
                   "${#_body}" "$_body" \
               | "$AG2A_BUSYBOX" nc 127.0.0.1 "$_port" 2>/dev/null | sed '1,/^$/d')
    else
        return 1
    fi
    case "$_out" in
        *'"success":true'*)
            printf '%s\n' "$_out" > "$WORK/admin.json"
            chmod 0600 "$WORK/admin.json" 2>/dev/null
            : > "$WORK/admin.created"
            return 0 ;;
        '') return 1 ;;
        *)  printf '%s\n' "$_out" >> "$WORK/seed.log" 2>/dev/null
            return 1 ;;
    esac
}
