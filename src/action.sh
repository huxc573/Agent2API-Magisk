#!/system/bin/sh
# 「执行」按钮：重启网关进程（不动手机）。不带参数点按钮就干这个，并把状态打出来。
# 打开面板归「打开」按钮：webroot/index.html（APatch / KernelSU 原生支持；
#   Magisk 自己没有 WebView，要装 KsuWebUI 或 MMRL 才会显示那个按钮）。
# 命令行可用 auto on|off|status|<HH:MM> 管自动更新，open 开浏览器。

MODDIR="$(dirname "$(readlink -f "$0")")"
. "$MODDIR/lib.sh"

WORK=$(ag2a_data_dir)
mkdir -p "$WORK" 2>/dev/null
CONF="$WORK/update.conf"

# ---- 自动更新开关 ----
# 两处都能关：$WORK/update.off 文件，或 update.conf 里 AG2A_UPDATE_INTERVAL=0。
# 写配置时顺手清掉 update.off，避免「文件留着、配置开了却仍不跑」。
auto_status() {
    if [ -f "$WORK/update.off" ]; then
        echo "关闭（存在 update.off）"
        return
    fi
    _i=$(sed -n 's/^[[:space:]]*AG2A_UPDATE_INTERVAL=\([0-9][0-9]*\).*/\1/p' "$CONF" 2>/dev/null | head -n1)
    [ -n "$_i" ] || _i=86400
    if [ "$_i" = "0" ]; then
        echo "关闭（AG2A_UPDATE_INTERVAL=0）"
        return
    fi
    _at=$(sed -n 's/^[[:space:]]*AG2A_UPDATE_AT=\([0-9:]*\).*/\1/p' "$CONF" 2>/dev/null | head -n1)
    case "$_at" in
        [0-9]:[0-9][0-9] | [01][0-9]:[0-9][0-9] | 2[0-3]:[0-9][0-9]) : ;;
        *) _at=04:00 ;;
    esac
    _ch=$(sed -n 's/^[[:space:]]*AG2A_UPDATE_CHANNEL=\([A-Za-z]*\).*/\1/p' "$CONF" 2>/dev/null | head -n1)
    [ -n "$_ch" ] || _ch=beta
    echo "开启（每天 $_at，通道 $_ch）"
}

set_kv() {
    # 注意变量名带 sk_ 前缀：sh 没有 local，叫 _k/_v 会把调用方的同名变量改掉
    _sk=$1; _sv=$2
    [ -f "$CONF" ] || : > "$CONF"
    if grep -q "^[[:space:]]*$_sk=" "$CONF" 2>/dev/null; then
        sed -i "s|^[[:space:]]*$_sk=.*|$_sk=$_sv|" "$CONF"
    else
        printf '%s=%s\n' "$_sk" "$_sv" >> "$CONF"
    fi
}

case "$1" in
reset)
    # 清掉面板账号库：让登录页回到「创建账号」状态。
    # ⛔ 只删 $WORK 下我们自己的文件，且路径必须落在 /data/adb/ag2a 之内 ——
    #    路径异常时宁可不动，也不能变成 `rm -f /*.db` 这种。
    case "$WORK" in
        /data/adb/ag2a | /data/adb/ag2a/) : ;;
        *) echo "路径异常（$WORK），拒绝删除"; exit 1 ;;
    esac
    n=0
    for _f in "$WORK"/*.db "$WORK/admin.json" "$WORK/admin_pw" "$WORK/.admin.pending"; do
        [ -e "$_f" ] || continue
        rm -f "$_f" && { echo "  删除 $(basename "$_f")"; n=$((n + 1)); }
    done
    [ "$n" = "0" ] && echo "  没有找到账号库文件（$WORK）" || echo "  共删 $n 个"
    sh "$MODDIR/service.sh" restart >/dev/null 2>&1
    sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1
    echo "网关已重启；之后打开 http://127.0.0.1:$(ag2a_get_port)/ 就是「创建账号」页"
    exit 0 ;;
config)
    # 刷入时没法交互（安装器不给 stdin），配置只能装完后在终端改。
    # 非终端（Magisk 点「操作」按钮、被管道喂）直接打现状，不阻塞。
    # 确实要从管道喂答案时: AG2A_ASSUME_TTY=1 sh action.sh config < answers.txt
    if [ ! -t 0 ] && [ -z "$AG2A_ASSUME_TTY" ]; then
        echo "当前配置（要改请在终端跑 su -c 'sh $0 config'）"
        echo "  端口        $(ag2a_get_port)"
        echo "  管理员      $(head -n1 "$WORK/admin_user" 2>/dev/null || echo root) / $( [ -f "$WORK/admin.json" ] && echo '已建号' || echo '待播种' )"
        echo "  自动更新    $(auto_status)"
        exit 0
    fi

    echo "== Agent2API 配置（直接回车＝保持现值）=="

    # 1) 端口
    _cp=$(ag2a_get_port)
    printf '端口 [%s]: ' "$_cp"
    read -r _v
    [ -n "$_v" ] || _v=$_cp
    case "$_v" in
        '' | *[!0-9]*) echo "  跳过：不是数字" ;;
        *) if [ "$_v" -ge 1024 ] 2>/dev/null && [ "$_v" -le 65535 ] 2>/dev/null; then
               printf '%s\n' "$_v" > "$WORK/port"; chmod 0600 "$WORK/port"
               echo "  端口 → $_v"
           else
               echo "  跳过：要 1024~65535"
           fi ;;
    esac

    # 2) 管理员（面板没有改密入口，只能重置账号库）
    _cu=$(head -n1 "$WORK/admin_user" 2>/dev/null | tr -d '\r')
    [ -n "$_cu" ] || _cu=root
    printf '管理员用户名 [%s]: ' "$_cu"
    read -r _v
    [ -n "$_v" ] || _v=$_cu
    case "$_v" in '' | *[!A-Za-z0-9_.@-]*) echo "  跳过：只允许字母数字 _ . @ -"; _v=$_cu ;; esac
    printf '管理员密码（≥8 位，回车不改）: '
    read -r _p
    if [ -n "$_p" ] || [ "$_v" != "$_cu" ]; then
        [ "${#_p}" -ge 8 ] || _p=""
        if [ -f "$WORK/admin.json" ]; then
            echo "  账号已建好，上游没有改密/改名接口，只能清掉账号库重建。"
            echo "  这会丢面板里的配置项，需要重新登录；客户端 api_key 在 config.json 里，不受影响。"
            printf '  确认重建? [y/N]: '
            read -r _yn
            case "$_yn" in
                y* | Y*) rm -f "$WORK/proxy.db" "$WORK/admin.json" "$WORK/.admin.pending"
                         echo "  已清账号库" ;;
                *) echo "  跳过管理员修改"; _p=""; _v=""; ;;
            esac
        fi
        if [ -n "$_v" ]; then
            printf '%s\n' "$_v" > "$WORK/admin_user"; chmod 0600 "$WORK/admin_user"
            if [ -n "$_p" ]; then
                printf '%s\n' "$_p" > "$WORK/admin_pw"; chmod 0600 "$WORK/admin_pw"
            fi
            : > "$WORK/.admin.pending"
            echo "  管理员 → $_v（重启后自动建号）"
        fi
        unset _p
    else
        echo "  跳过管理员修改"
    fi

    # 3) 自动更新
    echo "自动更新现在是 $(auto_status)"
    printf '自动更新钟点（HH:MM，输 off 关闭，回车不改）: '
    read -r _v
    case "$_v" in
        off | OFF) rm -f "$WORK/update.off"; set_kv AG2A_UPDATE_INTERVAL 0; echo "  已关闭" ;;
        [0-9]:[0-9][0-9] | [01][0-9]:[0-9][0-9] | 2[0-3]:[0-9][0-9])
            rm -f "$WORK/update.off"; set_kv AG2A_UPDATE_INTERVAL 86400; set_kv AG2A_UPDATE_AT "$_v"
            echo "  已设为每天 $_v" ;;
        '') echo "  保持 $(auto_status)" ;;
        *) echo "  跳过：格式要 HH:MM" ;;
    esac

    echo "→ 已重启网关，端口/账号改动生效"
    sh "$MODDIR/service.sh" restart >/dev/null 2>&1
    sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1
    exit 0 ;;
auto)
    case "$2" in
    off)
        rm -f "$WORK/update.off"
        set_kv AG2A_UPDATE_INTERVAL 0
        # 定时器不用停：tick 内部判 is_on，关着直接退出
        echo "自动更新已关闭（改回: sh $MODDIR/action.sh auto on）"
        exit 0 ;;
    on)
        rm -f "$WORK/update.off"
        set_kv AG2A_UPDATE_INTERVAL 86400
        echo "自动更新已开启 → $(auto_status)"
        exit 0 ;;
    status)
        echo "$(auto_status)"
        exit 0 ;;
    channel)
        case "$3" in
        beta | stable)
            set_kv AG2A_UPDATE_CHANNEL "$3"
            # 不用重排定时器：daemon 每次到点都重新读配置
            echo "更新通道已改为 $3 → $(auto_status)"
            exit 0 ;;
        *)
            echo "用法: sh $MODDIR/action.sh auto channel beta|stable"
            echo "  beta   = 连 pre-release 一起取（上游 3.3.0 目前全是 beta）"
            echo "  stable = 只要正式版（当前最高 v3.0.8）"
            exit 1 ;;
        esac ;;
    [0-9]:[0-9][0-9] | [01][0-9]:[0-9][0-9] | 2[0-3]:[0-9][0-9])
        rm -f "$WORK/update.off"
        set_kv AG2A_UPDATE_AT "$2"
        # 改钟点要让定时器按新时刻重排：crontab 子命令 = 停旧定时器 + 起新的
        sh "$MODDIR/service.sh" crontab >/dev/null 2>&1
        echo "检查钟点已改为每天 $2 → $(auto_status)"
        exit 0 ;;
    esac
    echo "用法: sh $MODDIR/action.sh auto on | off | status | channel beta|stable | HH:MM"
    exit 1
    ;;
refresh)
    sh "$MODDIR/refresh.sh" "$2"
    exit 0 ;;
log)
    # 网关日志（面板「打开」页下面那块显示的就是这个文件的尾部）。
    # 行数可调：sh action.sh log 120
    tail -n "${2:-40}" "$WORK/run.log" 2>/dev/null || echo "没有 $WORK/run.log"
    exit 0 ;;
start)
    sh "$MODDIR/service.sh" start
    sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1
    exit 0 ;;
stop)
    sh "$MODDIR/service.sh" stop
    sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1
    echo "网关已停止"
    exit 0 ;;
fixplugins)
    # 面板装完/升级插件后入口又变回 ELF，跑一次这个重新套壳（不重启网关也行，插件再启一次即可）
    sh "$MODDIR/pluginfix.sh"
    exit 0 ;;
open)
    PORT=$(ag2a_get_port)
    IP=$(wlan_ip)
    echo "局域网   http://${IP:-127.0.0.1}:$PORT/"
    echo "设备本机 http://127.0.0.1:$PORT/"
    am start -a android.intent.action.VIEW -d "http://127.0.0.1:$PORT/" >/dev/null 2>&1 &&
        echo "→ 已打开浏览器" || echo "→ 打开浏览器失败，手动访问上面的地址"
    exit 0 ;;
restart)
    if sh "$MODDIR/service.sh" restart >/dev/null 2>&1; then
        echo "网关已重启（pid $(ag2a_pids | tr '\n' ' ' | sed 's/ *$//')）"
    else
        echo "重启失败：端口 $(ag2a_get_port) 没有监听，详见 $(ag2a_data_dir)/run.log"
    fi
    sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1
    exit 0 ;;
esac

# ---- 默认（点「执行」按钮）：重启网关进程 ----
# ⛔ 不再顺带开浏览器：那个动作归「打开」按钮（webroot/index.html）。
PORT=$(ag2a_get_port)
WL=$(wlan_ip)

# 管理模式（APatch）在脚本成功返回后**自己 popBackStack 退回列表**，输出页留不住，
# 所以结果必须额外推一条系统通知 —— 否则点完执行完全看不出来到底重启没重启。
notify() {
    command -v cmd >/dev/null 2>&1 || return 0
    cmd notification post -S bigtext -t 'Agent2API' ag2a_restart "$1" >/dev/null 2>&1 ||
        cmd notification post -t 'Agent2API' ag2a_restart "$1" >/dev/null 2>&1
}

echo "== Agent2API 网关 =="
if ag2a_running; then
    echo "重启前   运行中 pid=$(ag2a_pids | tr '\n' ' ' | sed 's/ *$//')"
else
    echo "重启前   未运行"
fi

# service.sh restart 自己会等到端口真的 LISTEN 才返回 0，这里直接用它的退出码，
# 不再另写一遍轮询（重复判活最容易和真实现状漂）。
if sh "$MODDIR/service.sh" restart >/dev/null 2>&1; then
    echo "重启后   运行中 pid=$(ag2a_pids | tr '\n' ' ' | sed 's/ *$//')（端口 $PORT 已监听）"
    notify "网关已重启 · pid $(ag2a_pids | tr '\n' ' ' | sed 's/ *$//') · 端口 $PORT"
else
    echo "重启后   ! 失败：端口 $PORT 没有监听"
    echo "         详见 $(ag2a_data_dir)/run.log"
    notify "网关重启失败 · 端口 $PORT 没监听，详见 run.log"
fi
# 说明行必须在这里再刷一次：service.sh restart 内部那次刷在等待端口之后，
# APatch 执行 action 有超时，来不及跑到那里就把整个进程带走了 ⇒ 列表里时间不变。
sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1
echo "面板     http://${WL:-127.0.0.1}:$PORT/"
echo "运行体   $(ag2a_bin)"
echo "自动更新 $(auto_status)"
echo ""
echo "打开面板 sh $MODDIR/action.sh open"
echo "改配置   sh $MODDIR/action.sh config"
