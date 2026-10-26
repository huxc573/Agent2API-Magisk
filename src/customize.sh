#!/system/bin/sh
# 安装脚本：补权限 + 建持久数据目录 + 音量键配置。
# 刻意不在这里写 config.json：交给二进制首次启动自己生成（随机 api_key、绝不覆盖已有配置）。
#
# ⚠ 1.6.1/1.6.2 曾把这个文件整个删掉，结果刷入时一个选项都没有。
#   音量键选项是这模块的使用习惯，不能丢。

VER=$(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null | tr -d '\r')
[ -n "$VER" ] || VER="unknown"

# 本地测试兜底：正常刷入时这几个函数由管理器注入
command -v ui_print >/dev/null 2>&1 || ui_print() { echo "$@"; }
command -v abort >/dev/null 2>&1 || abort() { echo "! $*" >&2; exit 1; }
command -v set_perm >/dev/null 2>&1 || set_perm() {
    chown "$2:$3" "$1" 2>/dev/null; chmod "$4" "$1" 2>/dev/null
}
command -v set_perm_recursive >/dev/null 2>&1 || set_perm_recursive() {
    chown -R "$2:$3" "$1" 2>/dev/null
    find "$1" -type d -exec chmod "$4" {} \; 2>/dev/null
    find "$1" -type f -exec chmod "$5" {} \; 2>/dev/null
}

ui_print " "
ui_print " Agent2API Gateway · $VER (linux/arm64)"
ui_print " "

# 架构校验：只发 arm64 包
ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
ABIS=$(getprop ro.product.cpu.abilist 2>/dev/null)
case "$ABIS" in
    *arm64-v8a*) : ;;
    *) ui_print "! 本机 ABI 不是 arm64-v8a（$ABI / $ABIS），这个包跑不了"
       abort "! 需要 arm64 设备" ;;
esac

# ---------- 权限 ----------
# 1.5.x 靠这里补可执行位；1.6.x 起 zip 里已带模式位，这里再兜一次（Windows 打包会丢）。
for _f in action.sh check.sh control.sh pluginfix.sh refresh.sh rt.sh service.sh uninstall.sh updater.sh watchdog.sh; do
    [ -f "$MODPATH/$_f" ] && set_perm "$MODPATH/$_f" 0 0 0755
done
[ -f "$MODPATH/bin/agent2api-server" ] && set_perm "$MODPATH/bin/agent2api-server" 0 0 0755
# loader 必须可执行，否则网关根本起不来
[ -f "$MODPATH/lib/ld-linux-aarch64.so.1" ] && set_perm "$MODPATH/lib/ld-linux-aarch64.so.1" 0 0 0755
for _f in lib/libc.so.6 lib/libm.so.6 lib/libgcc_s.so.1; do
    [ -f "$MODPATH/$_f" ] && set_perm "$MODPATH/$_f" 0 0 0644
done
[ -f "$MODPATH/module.prop" ] && set_perm "$MODPATH/module.prop" 0 0 0644
[ -f "$MODPATH/lib.sh" ] && set_perm "$MODPATH/lib.sh" 0 0 0644
for _d in ui etc zoneinfo; do
    [ -d "$MODPATH/$_d" ] && set_perm_recursive "$MODPATH/$_d" 0 0 0755 0644
done

# 持久数据目录：模块更新会把模块目录整体替换，凭证与状态必须放这里
# 测试可用 AG2A_DATA_DIR 旁路（与 lib.sh 的 ag2a_data_dir 同一套约定）；刷入时不会设
DATA_DIR=${AG2A_DATA_DIR:-/data/adb/ag2a}
mkdir -p "$DATA_DIR" "$DATA_DIR/debug"
set_perm_recursive "$DATA_DIR" 0 0 0700 0600

# ---------- 刷入时选择：只能读音量键 ----------
# Magisk / APatch / KernelSU 的安装界面没有输入框，也不把 stdin 交给 customize.sh：
#   用 read 会永久阻塞（现象＝进度条卡住、提示也不显示），用 echo 也不显示。
# 业界可行做法（OpenList-Magisk / box_for_magisk 等）是读 /dev/input 的音量键：
#   音量下 = 切下一项，音量上 = 确认。**一直等，没有超时**——只有按了音量上才往下走。
# 唯一的自动退出：本机没有 getevent / timeout（极少见），那就只能用默认值。

_key_once() {
    # 最多阻塞 1 秒；只认 KEY_VOLUMEUP / KEY_VOLUMEDOWN 的按下事件。
    # 外面套 { } 是必须的：timeout 杀掉 getevent 时 shell 会往自己的 stderr 打
    # 一行 "Terminated"，光重定向 getevent 的 stderr 盖不住它。
    _ke=$( { timeout 1 getevent -qlc 1; } 2>/dev/null )
    case "$_ke" in
        *KEY_VOLUMEUP*DOWN*) printf 'up' ;;
        *KEY_VOLUMEDOWN*DOWN*) printf 'down' ;;
    esac
}

_nth() {
    _nw=$1; shift; _nj=0
    for _nx in "$@"; do
        _nj=$((_nj + 1))
        [ "$_nj" = "$_nw" ] && { printf '%s' "$_nx"; return; }
    done
}

# choose "标题" 默认序号 选项1 选项2 ...  ⇒ 结果在 $CHOICE，采用值在 $PICKED
choose() {
    _ct=$1; _cd=$2; shift 2
    _cn=$#
    _cur=$_cd
    if ! command -v getevent >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        CHOICE=$_cd
        PICKED=$(_nth "$_cd" "$@")
        ui_print "- $_ct: $PICKED（本机没有 getevent，取默认）"
        return
    fi
    ui_print " "
    ui_print "- $_ct: 音量下=切换  音量上=确认"
    ui_print "  → $(_nth "$_cur" "$@")"
    while :; do
        case "$(_key_once)" in
            down)
                _cur=$((_cur % _cn + 1))
                ui_print "  → $(_nth "$_cur" "$@")"
                sleep 0.25 ;;
            up)
                break ;;
        esac
        # 屏幕静止时 getevent 自己就阻塞满 1 秒，这里只防事件流很密时空转烧 CPU
        sleep 0.15 2>/dev/null || sleep 1
    done
    CHOICE=$_cur
    PICKED=$(_nth "$_cur" "$@")
    # 确认后停一下：音量上键松开得慢的话，残留事件会把下一个问题也秒确认掉
    sleep 0.4 2>/dev/null || sleep 1
}

# ---------- 读现有配置 ----------
MODDIR="$MODPATH"
. "$MODDIR/lib.sh" 2>/dev/null
WORK="$DATA_DIR"

_cur_port=""
[ -s "$DATA_DIR/port" ] && _cur_port=$(tr -dc '0-9' < "$DATA_DIR/port" 2>/dev/null | head -n1)
case "$_cur_port" in '' | *[!0-9]*) _cur_port="" ;; esac

_installed=0
if [ -s "$DATA_DIR/port" ] || [ -s "$DATA_DIR/env" ]; then _installed=1; fi

# ---------- 已安装：第一个问题就问要不要动配置 ----------
# 升级安装最怕的就是「刷一下配置全被重置」，所以默认项是「保持默认」，
# 音量上直接确认＝什么都不改。只有明确选「重新设置」才往下问。
RECONF=1
AUTO_ON=""
if [ "$_installed" = "1" ]; then
    _sp=${_cur_port:-3065}
    if ag2a_update_on; then _sa="开启"; else _sa="关闭"; fi
    ui_print " "
    ui_print "- 检测到已安装：端口 $_sp，自动更新 $_sa"
    choose "是否重新设置" 1 "保持默认（沿用现有配置，不修改）" "重新设置"
    if [ "$PICKED" = "重新设置" ]; then
        RECONF=1
    else
        RECONF=0
        PORT=$_sp
        ui_print "- 沿用现有配置：端口 $PORT，自动更新 $_sa"
    fi
fi

# ---------- 配置值 ----------
if [ "$RECONF" = "1" ]; then
    # 端口：把当前值放第一项，音量上直接确认＝不改
    case "$_cur_port" in
        52018) _o1=52018; _o2=3065 ;;
        3065 | '') _o1=3065; _o2=52018 ;;
        *) _o1=$_cur_port; _o2=3065 ;;      # 用户自定义过的端口，原样保留
    esac
    choose "网关端口" 1 "$_o1" "$_o2"
    PORT=$PICKED

    # 自动更新：默认项＝当前状态；首次安装默认「关闭」
    # 理由：GitHub 的两个上游仓库目前都不可达，面板里另有「软件更新」入口，
    # 在确定最终更新手段之前不该让模块每天 04:00 空跑一次失败。
    if [ ! -f "$DATA_DIR/update.conf" ]; then
        _adef=2                                      # 首次安装：关闭
    elif ag2a_update_on; then
        _adef=1
    else
        _adef=2
    fi
    choose "自动更新（每天 04:00 查 GitHub Releases，两个仓库都试）" "$_adef" "开启" "关闭"
    AUTO_ON=$PICKED
fi

# 管理员：不在刷入时设。面板登录页会自己探测「有没有账号」，没有就切到
# 「创建账号并进入面板」，密码由用户当场定（≥8 位）——比给个默认 adminadmin 安全。
ui_print " "
ui_print "- 管理员账号: 首次打开面板自己创建（密码自己定，至少 8 位）"

# 回读旧账号（升级安装时保留）
ADM_USER=root
PW=""
if [ -s "$DATA_DIR/admin_user" ]; then
    _u=$(head -n1 "$DATA_DIR/admin_user" | tr -d '\r')
    [ -n "$_u" ] && ADM_USER=$_u
elif [ -f "$DATA_DIR/env" ]; then
    _u=$(sed -n 's/^AGENT2API_ADMIN_USER=//p' "$DATA_DIR/env" | head -n1 | tr -d '\r')
    [ -n "$_u" ] && ADM_USER=$_u
fi
if [ -s "$DATA_DIR/admin_pw" ]; then
    _w=$(head -n1 "$DATA_DIR/admin_pw" | tr -d '\r')
    [ -n "$_w" ] && PW=$_w
elif [ -f "$DATA_DIR/env" ]; then
    _w=$(sed -n 's/^AGENT2API_ADMIN_PASSWORD=//p' "$DATA_DIR/env" | head -n1 | tr -d '\r')
    [ -n "$_w" ] && PW=$_w
fi

# ---------- 落配置 ----------
# 配置文件：只在没有时写，升级安装不覆盖用户改过的值
if [ ! -f "$DATA_DIR/env" ]; then
    printf '%s\n' \
        '# Agent2API 启动环境（service.sh 每次启动 source 本文件）' \
        '# 端口以 port 文件为准；这里保留同值只是给二进制首启生成 config.json 用' \
        'AGENT2API_HOST=0.0.0.0' \
        "AGENT2API_PROXY_PORT=$PORT" \
        'AGENT2API_CAPTCHA_ENABLED=0' \
        '# 面板自带的「软件更新」默认关（=0）。模块自己有更新通道，两条一起动会打架；' \
        '# 想改用面板内一键更新就改成 1（它会在容器/进程内自替换，模块目录可能被写坏）' \
        'AGENT2API_SELF_UPDATE=0' \
        '# 管理员账号不预设：首次打开面板（http://手机IP:端口/）会切到「创建账号」，' \
        '# 密码当场自己定。想预设就 sh action.sh config（会走 /api/panel/setup 建号）。' \
        > "$DATA_DIR/env"
fi
chmod 0600 "$DATA_DIR/env" 2>/dev/null

# 端口单独落文件：上游「config.json 已有 listen 就沿用」，改端口必须同时钉住 listen
# 选「保持默认」时不重写，避免把用户手改的值覆盖掉
if [ "$RECONF" = "1" ] && [ -n "$PORT" ]; then
    printf '%s\n' "$PORT" > "$DATA_DIR/port"
    chmod 0600 "$DATA_DIR/port" 2>/dev/null
fi
[ -n "$PORT" ] || PORT=$(tr -dc '0-9' < "$DATA_DIR/port" 2>/dev/null | head -n1)
[ -n "$PORT" ] || PORT=3065

# 管理员密码落独立文件，仅供 service.sh 首次播种读取，安装日志里不回显。
# 只有明确设过密码（PW 非空）才写；默认走「网页里自己创建」，这里什么都不留。
if [ -n "$PW" ] && [ ! -f "$DATA_DIR/admin.json" ]; then
    printf '%s\n' "$PW" > "$DATA_DIR/admin_pw"
    chmod 0600 "$DATA_DIR/admin_pw" 2>/dev/null
    printf '%s\n' "$ADM_USER" > "$DATA_DIR/admin_user"
    chmod 0600 "$DATA_DIR/admin_user" 2>/dev/null
fi
unset PW

if [ ! -f "$DATA_DIR/update.conf" ]; then
    printf '%s\n' \
        '# 自动更新：每天一次，按下面的钟点触发（updater.sh daemon 睡到点才醒，零 CPU 空转）' \
        '# 关掉：把下面改成 0（或 sh action.sh auto off）；改钟点：sh action.sh auto 03:30' \
        '# 首次安装默认 0=关闭：两个上游仓库当前都不可达，等更新手段定下来再开' \
        'AG2A_UPDATE_INTERVAL=0' \
        'AG2A_UPDATE_AT=04:00' \
        '# 更新后是否重启网关：1=是' \
        'AG2A_UPDATE_RESTART=1' \
        '# 更新通道：beta=连 pre-release 一起取（上游新版目前全是 beta，正式版停在 3.0.8）' \
        '# stable=只要正式版。改：sh action.sh auto channel stable' \
        'AG2A_UPDATE_CHANNEL=beta' \
        '# 下载源（逗号分隔，末项留空=GitHub 直连兜底）。默认已内置两个公共加速；' \
        '# 有自建反代就写自己的，例如 AG2A_UPDATE_SOURCES=https://gh.你的域名/' \
        '#AG2A_UPDATE_SOURCES=https://gh-proxy.com/,https://ghproxy.net/,https://ghfast.top/,' \
        '# 上游仓库（空格分隔，按顺序探测，第一个取到 release 的生效）。' \
        '# 默认已含改名前后的两个：Agent2API/agent2api 与 aimod-cc/agent2api' \
        '#AG2A_UPDATE_REPOS=Agent2API/agent2api aimod-cc/agent2api' \
        > "$DATA_DIR/update.conf"
fi
chmod 0600 "$DATA_DIR/update.conf" 2>/dev/null

# 老配置补键（升级安装）：缺 AG2A_UPDATE_CHANNEL 就补上，省得用户以为没这功能
if [ -f "$DATA_DIR/update.conf" ] && ! grep -q '^AG2A_UPDATE_CHANNEL=' "$DATA_DIR/update.conf" 2>/dev/null; then
    printf '# 更新通道：beta=连 pre-release 一起取 / stable=只要正式版\nAG2A_UPDATE_CHANNEL=beta\n' >> "$DATA_DIR/update.conf"
fi

# 刷入时选的开关落进配置（没选＝保持默认，什么都不动）
_aui=$(sed -n 's/^AG2A_UPDATE_INTERVAL=\([0-9][0-9]*\).*/\1/p' "$DATA_DIR/update.conf" 2>/dev/null | head -n1)
if [ "$AUTO_ON" = "关闭" ]; then
    sed -i 's|^AG2A_UPDATE_INTERVAL=.*|AG2A_UPDATE_INTERVAL=0|' "$DATA_DIR/update.conf"
    rm -f "$DATA_DIR/update.off" 2>/dev/null
elif [ "$AUTO_ON" = "开启" ] && [ "$_aui" = "0" ]; then
    sed -i 's|^AG2A_UPDATE_INTERVAL=.*|AG2A_UPDATE_INTERVAL=86400|' "$DATA_DIR/update.conf"
    rm -f "$DATA_DIR/update.off" 2>/dev/null
fi

# 自动更新状态（给人看的）
_ai=$(sed -n 's/^AG2A_UPDATE_INTERVAL=\([0-9][0-9]*\).*/\1/p' "$DATA_DIR/update.conf" 2>/dev/null | head -n1)
_at=$(sed -n 's/^AG2A_UPDATE_AT=\([0-9:]*\).*/\1/p' "$DATA_DIR/update.conf" 2>/dev/null | head -n1)
[ -n "$_at" ] || _at=04:00
if ag2a_update_on; then
    AUTO_ST="每天 $_at"
else
    AUTO_ST="已关闭（sh $MODPATH/action.sh auto on 打开）"
fi

# 记下当前上游版本，updater 拿它跟最新 release 比。
# ⚠升级安装时也必须重写：刷进去的就是这个版本，若沿用旧记录会被判定成「有新版本」，
#   进而去下载被封后残留的旧 release，造成降级覆盖（离线导入新版后尤其明显）。
UPV=$(sed -n 's/.*(ag2a \([^)]*\)).*/\1/p' "$MODPATH/module.prop" 2>/dev/null | head -n1)
if [ -n "$UPV" ]; then
    printf '%s\n' "v$UPV" > "$DATA_DIR/upstream.version"
    chmod 0600 "$DATA_DIR/upstream.version" 2>/dev/null
fi

ui_print " "
ui_print "- 数据目录: $DATA_DIR（账号 / 状态 / 配置都在这里）"
ui_print "- 网关端口: $PORT"
ui_print "  面板地址: http://127.0.0.1:$PORT/ ，手机同 WiFi 用 http://<手机IP>:$PORT/"
if [ -f "$DATA_DIR/admin.json" ]; then
    ui_print "- 管理员账号: 已有（$ADM_USER），面板里直接登录"
else
    ui_print "- 管理员账号: 打开 http://127.0.0.1:$PORT/ 自己创建（首次进入会切到注册）"
fi
ui_print "- 自动更新: $AUTO_ST（源: GitHub Releases 的 linux-arm64 包，带 sha256 校验）"
ui_print " "
ui_print "  随时可改：su -c 'sh /data/adb/modules/ag2a/action.sh config'"
ui_print "- 面板自带的「软件更新」已关（AGENT2API_SELF_UPDATE=0），改用模块的更新通道"
ui_print "- 重启设备即自动运行；手动启停: sh /data/adb/modules/ag2a/service.sh start|stop"
ui_print "- 卸载: 管理器点卸载（会连 $DATA_DIR 一起删干净；想留数据先 touch $DATA_DIR/keep）"
ui_print " "

# ---------- 运行体同步 + 立即启动 ----------
# v1.9.0 起运行体（bin/ + ui/）的权威位置是 /data/adb/ag2a/rt，不是模块目录。
# 原因：模块目录由 Magisk 管，刷 zip 只解到 /data/adb/modules_update/ag2a，
#   要**重启**才整体替换到 modules/ —— 运行体放那儿，刷完不重启就还是旧二进制，
#   这就是以前「模块列表显示新版本、服务还是老的」的根因。
# 数据目录 Magisk 从不碰 ⇒ 现在刷完只要重启网关进程，不用重启手机。
FINAL_DIR=/data/adb/modules/ag2a

# 先把刚解压到 $MODPATH（= modules_update/ag2a）的 bin/ui 同步进 rt。
# 放在 stop 之前做：mv 是原子替换，旧进程握着的旧 inode 要等它退出才回收，不影响它继续跑。
if AG2A_DATA_DIR="$DATA_DIR" sh "$MODPATH/rt.sh" sync >/dev/null 2>&1; then
    _rt_ok=1
else
    _rt_ok=0
fi

# 插件入口套壳：插件是上一版就装好的（在 /data/adb/ag2a/plugins），刷完这一刻就能修，
# 不用等重启。壳里写的 loader 路径必须是 FINAL_DIR —— 这里 $MODPATH 是临时目录。
AG2A_DATA_DIR="$DATA_DIR" AG2A_MODDIR="$MODPATH" AG2A_WRAP_MODDIR="$FINAL_DIR" \
    sh "$MODPATH/pluginfix.sh" quiet >/dev/null 2>&1

# 自动更新当前状态：update.off 或 AG2A_UPDATE_INTERVAL=0 都算关闭（与 lib.sh 的 ag2a_update_on 同规则）
_upd=开启
if [ -f "$DATA_DIR/update.off" ]; then
    _upd=关闭
else
    _iv=$(sed -n 's/^AG2A_UPDATE_INTERVAL=\([0-9][0-9]*\).*/\1/p' "$DATA_DIR/update.conf" 2>/dev/null | head -n1)
    [ -n "$_iv" ] && [ "$_iv" -eq 0 ] 2>/dev/null && _upd=关闭
fi

if [ "${AG2A_INSTALL_NO_START:-0}" = "1" ]; then
    ui_print "- 已跳过立即启动（AG2A_INSTALL_NO_START=1），重启后自动运行"
    ui_print " "
elif [ ! -d "$FINAL_DIR" ]; then
    # 全新安装：模块目录要重启后才出现，这会儿没有能常驻的脚本可跑
    ui_print "- 首次安装，重启设备后自动运行"
    ui_print " "
elif [ -f "$FINAL_DIR/disable" ]; then
    ui_print "- 模块当前处于停用状态，未启动（启用后重启生效）"
    ui_print " "
else
    ui_print "- 正在切到本次刷入的版本（重启网关进程，不用重启手机）…"
    # ⚠ 必须用 $MODPATH 里的新脚本：$FINAL_DIR 里的还是上一版，
    #   从那儿 start 会 exec 旧二进制（旧 lib.sh 只认 $MODDIR/bin）。
    sh "$MODPATH/service.sh" stop >/dev/null 2>&1
    _st=0
    AG2A_DATA_DIR="$DATA_DIR" sh "$MODPATH/service.sh" start >/dev/null 2>&1 || _st=1
    _port=$(cat "$DATA_DIR/port" 2>/dev/null)
    case "$_port" in '' | *[!0-9]*) _port=3065 ;; esac

    if [ "$_st" = "0" ]; then
        ui_print "- 网关已启动，端口 $_port 可以访问（已是本次刷入的版本）"
    else
        # 不复述「已启动」：这是实测没起来
        ui_print "! 网关没能启动（端口 $_port 无响应）"
        ui_print "  重启设备后会自动重试；若重启后仍不行，请把下面日志发我："
        ui_print "  $DATA_DIR/run.log"
    fi
    if [ "$_rt_ok" = "0" ]; then
        ui_print "! 运行体同步失败（$DATA_DIR/rt），当前仍是旧版本在跑"
        ui_print "  重启设备后自动重试；仍失败请检查 /data 剩余空间"
    fi
    ui_print "- 自动更新：$_upd"
    ui_print " "
fi
