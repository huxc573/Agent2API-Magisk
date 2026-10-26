#!/system/bin/sh
# 自动更新：查 GitHub Releases（Agent2API/agent2api），拉官方 linux-arm64 服务端包，
# 用 GitHub API 的 assets[].digest 校验 sha256 后只替换 rt/bin 与 rt/ui（v1.9.0 起的运行体落点）。
#
# ⛔ 不要写成 `while :; do … sleep 60; done`：v1.5.x 就是这样，每 60 秒 fork 一次
#    date 算钟点，整夜几十万次 wakeup，是仅次于 control.sh 的耗电源。
#    也不要指望 crond —— 本机（APatch）没有 crond，探测必然失败。
# ✅ tick 是一次性的：判断该不该跑，跑完退出。
# ✅ daemon 是给它包一层「睡到目标时刻再醒」：一天最多 1 次真干活，
#    单次睡眠上限 30 分钟（兜住深睡拉长 / 用户改钟点），sleep 本身零 CPU。
#
# 用法：
#   sh updater.sh now      立即检查（不管钟点）
#   sh updater.sh tick     按钟点判断该不该查（跑完退出）
#   sh updater.sh daemon   常驻定时器（service.sh 拉起，睡到点才醒）
#   sh updater.sh status   看开关与上次结果

MODDIR="${AG2A_UPDATE_MODDIR:-$(dirname "$(readlink -f "$0")")}"
# 兜底：测试旁路被误设成空/根目录时不做任何删除 —— 下面有 rm -rf "$RT/ui.old"
case "$MODDIR" in
    '' | / | /data | /data/adb | /sdcard | /storage* | /system* | /data/local/tmp)
        MODDIR=$(dirname "$(readlink -f "$0")") ;;
esac
. "$MODDIR/lib.sh"

WORK="${AG2A_UPDATE_WORK:-$(ag2a_data_dir)}"
# 运行体写在 rt/ 而不是模块目录：模块目录要重启才被 Magisk 替换，写进去等于白写
# （跑着的还是旧二进制），rt/ 写完重启一下网关进程就生效。规则见 rt.sh。
RT="$WORK/rt"
# RT 是 rm -rf 的目标：数据目录被带偏成空/根时立刻停手（与上面 MODDIR 同一套判据）
case "$WORK" in
    '' | / | /data | /data/adb | /sdcard | /storage* | /system* | /data/local/tmp)
        echo "[ag2a] 数据目录异常（$WORK），拒绝执行" >&2; exit 1 ;;
esac
# 上游仓库有两个名字（改过组织/迁移过）：旧的 Agent2API/agent2api 与新的 aimod-cc/agent2api。
# 两个都试，谁先返回可用 release 就用谁；两边都可能被墙/被封 ⇒ 全部失败即视为本次检查失败。
# 可用 AG2A_UPDATE_REPOS 覆盖（空格分隔）。
REPOS="${AG2A_UPDATE_REPOS:-${AG2A_UPDATE_REPO:-Agent2API/agent2api aimod-cc/agent2api}}"
GH="${AG2A_UPDATE_API:-https://api.github.com}"
ASSET=agent2api-server-linux-arm64.tar.gz
STAMP="$WORK/update.stamp"
LOG="$WORK/update.log"
STATUS="$WORK/update.status"
OFF="$WORK/update.off"
VERF="$WORK/upstream.version"
CONF="$WORK/update.conf"

export TZ="$MODDIR/zoneinfo/Asia/Shanghai"

# ---- 基础工具 ----
have() { command -v "$1" >/dev/null 2>&1; }

BUSYBOX=""
for _b in /data/adb/ap/bin/busybox /data/adb/magisk/busybox /data/adb/ksu/bin/busybox "$MODDIR/bin/busybox"; do
    [ -x "$_b" ] && { BUSYBOX="$_b"; break; }
done

if command -v sha256sum >/dev/null 2>&1; then
    SHA="sha256sum"
elif [ -n "$BUSYBOX" ] && "$BUSYBOX" sha256sum </dev/null >/dev/null 2>&1; then
    SHA="$BUSYBOX sha256sum"
elif command -v openssl >/dev/null 2>&1; then
    SHA="openssl dgst -sha256"
elif [ -n "$BUSYBOX" ] && "$BUSYBOX" openssl dgst -sha256 </dev/null >/dev/null 2>&1; then
    SHA="$BUSYBOX openssl dgst -sha256"
else
    SHA=""
fi

say() {
    _t=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s %s\n' "$_t" "$*"
    printf '%s %s\n' "$_t" "$*" >> "$LOG" 2>/dev/null
}
mark() { printf '%s %s\n' "$(date '+%m-%d %H:%M')" "$*" > "$STATUS" 2>/dev/null; }

sha_of() {
    [ -n "$SHA" ] || { printf '\n'; return; }
    case "$SHA" in
        *openssl*) $SHA "$1" 2>/dev/null | awk '{print $NF}' | tr -d '\r' ;;
        *)         $SHA "$1" 2>/dev/null | awk '{print $1}' | tr -d '\r' ;;
    esac
}

# 下载：curl -> busybox wget -> wget。GitHub 会 302 到 objects.githubusercontent.com，必须跟。
# $3 非空时带 Authorization（API 吃更高限流；资产走 302 不需要）
# $4 = 最长秒数（默认 900）；$5 非空时启用慢速放弃（<8KB/s 持续 30 秒就掐掉换源）
fetch() {
    _u=$1; _o=$2; _h=$3; _t=${4:-900}; _sl=$5
    rm -f "$_o"
    if have curl; then
        _cs="--connect-timeout 20 --max-time $_t"
        [ -n "$_sl" ] && _cs="$_cs --speed-limit 8192 --speed-time 30"
        if [ -n "$_h" ]; then
            curl -fsSL $_cs -H "Authorization: Bearer $_h" -o "$_o" "$_u" && return 0
        else
            curl -fsSL $_cs -o "$_o" "$_u" && return 0
        fi
    elif [ -n "$BUSYBOX" ]; then
        if [ -n "$_h" ]; then
            "$BUSYBOX" wget -q -T 120 -O "$_o" --header "Authorization: Bearer $_h" "$_u" && return 0
        else
            "$BUSYBOX" wget -q -T 120 -O "$_o" "$_u" && return 0
        fi
    elif have wget; then
        wget -q --timeout=120 -O "$_o" "$_u" && return 0
    fi
    [ -s "$_o" ] || { rm -f "$_o"; return 1; }
    return 0
}

# ---- 配置读取 ----
conf_get() {
    [ -f "$CONF" ] || return 0
    sed -n "s/^[[:space:]]*$1=\(.*\)/\1/p" "$CONF" | head -n1 | tr -d '\r'
}

# 开关：update.off 文件 或 AG2A_UPDATE_INTERVAL=0
is_on() {
    [ -f "$OFF" ] && return 1
    _i=$(conf_get AG2A_UPDATE_INTERVAL)
    [ -n "$_i" ] || _i="${AG2A_UPDATE_INTERVAL:-86400}"
    [ "$_i" = "0" ] && return 1
    return 0
}

# 每天的执行钟点 AG2A_UPDATE_AT=HH:MM，格式不对退回 04:00
check_at() {
    _t=$(conf_get AG2A_UPDATE_AT)
    case "$_t" in
        [0-9]:[0-9][0-9] | [01][0-9]:[0-9][0-9] | 2[0-3]:[0-9][0-9]) : ;;
        *) _t=04:00 ;;
    esac
    echo "$_t"
}

# 今天该查的时刻（epoch）
today_at() {
    _h=$((10#${1%%:*}))
    _m=$((10#${1##*:}))
    _today=$(date +%Y-%m-%d 2>/dev/null)
    _s=""
    if [ -n "$_today" ]; then
        _s=$(date -d "$_today $_h:$_m:00" +%s 2>/dev/null)
        if [ -z "$_s" ] && [ -n "$BUSYBOX" ]; then
            _s=$("$BUSYBOX" date -d "$_today $_h:$_m:00" +%s 2>/dev/null)
        fi
    fi
    case "$_s" in '' | *[!0-9]*) _s="" ;; esac
    [ -n "$_s" ] || _s=$(($(date +%s 2>/dev/null || echo 0) + 60))
    echo "$_s"
}

gh_token() { echo "${GITHUB_TOKEN:-${WORKBUDDY_GITHUB_TOKEN:-}}"; }

# 版本大小比较：$1 严格大于 $2 才返回 0。
# 支持 v 前缀、3 段/4 段数字、-beta.N 预发布后缀；同主版本时正式版 > 预发布，预发布之间比末位数字。
# ⚠必须有这一步：封库后 GitHub API 可能仍返回**陈旧** release（如 v3.0.9-beta.1），
#   只判「tag 相等」会把旧版本当成新版下载，直接造成降级覆盖。
vercmp_gt() {
    [ "$1" = "$2" ] && return 1
    _ga=$(printf '%s' "$1" | sed 's/^[vV]//')
    _gb=$(printf '%s' "$2" | sed 's/^[vV]//')
    _ca=${_ga%%-*}
    _cb=${_gb%%-*}
    _gk=1
    while [ "$_gk" -le 4 ]; do
        _gx=$(printf '%s' "$_ca" | cut -d. -f"$_gk" 2>/dev/null)
        _gy=$(printf '%s' "$_cb" | cut -d. -f"$_gk" 2>/dev/null)
        case "$_gx" in '' | *[!0-9]*) _gx=0 ;; esac
        case "$_gy" in '' | *[!0-9]*) _gy=0 ;; esac
        [ "$_gx" -gt "$_gy" ] && return 0
        [ "$_gx" -lt "$_gy" ] && return 1
        _gk=$((_gk + 1))
    done
    # 主版本相同 → 比较预发布后缀
    _sa=${_ga#"$_ca"}
    _sb=${_gb#"$_cb"}
    [ -z "$_sa" ] && [ -n "$_sb" ] && return 0    # 正式版 > 预发布
    [ -n "$_sa" ] && [ -z "$_sb" ] && return 1
    [ -z "$_sa" ] && return 1                     # 完全相等
    _ta=$(printf '%s' "$_sa" | tr -dc '0-9.')
    _tb=$(printf '%s' "$_sb" | tr -dc '0-9.')
    _pa=${_ta##*.}
    _pb=${_tb##*.}
    case "$_pa" in '' | *[!0-9]*) _pa=0 ;; esac
    case "$_pb" in '' | *[!0-9]*) _pb=0 ;; esac
    [ "$_pa" -gt "$_pb" ] && return 0
    return 1
}

# 从 releases 列表里挑最高版本。$1=json 文件 $2=通道(stable|beta)
# 输出选中的 tag；没有符合条件的就输出空。
# ⚠ 不能只靠 /releases/latest：它只返回「正式版」，上游把新版全标成 pre-release 时
#   会永远停在旧正式版（现在 latest=v3.0.8，而实际最新是 v3.3.0-beta.3）。
pick_tag() {
    _pc="$WORK/.cand"
    tr -d ' \n\r\t' < "$1" | sed 's/},{/}\n{/g' \
        | sed -n 's/.*"tag_name":"\([^"]*\)".*"prerelease":\(true\|false\).*/\1 \2/p' > "$_pc" 2>/dev/null
    _best=""
    while read -r _t _pre; do
        [ -n "$_t" ] || continue
        [ "$2" = "beta" ] || [ "$_pre" = "false" ] || continue
        if [ -z "$_best" ] || vercmp_gt "$_t" "$_best"; then _best=$_t; fi
    done < "$_pc"
    rm -f "$_pc"
    printf '%s' "$_best"
}

# 最新版本：按 REPOS 顺序探测，输出 "仓库<TAB>tag<TAB>sha256"
# 通道由 AG2A_UPDATE_CHANNEL 决定：beta=连 pre-release 一起（默认），stable=只要正式版
# 全部仓库都取不到就返回 1（仓库被封/不可达是常态，不算异常）
release_info() {
    _tf="$WORK/.rel.json"
    _ch=$(conf_get AG2A_UPDATE_CHANNEL)
    [ -n "$_ch" ] || _ch="${AG2A_UPDATE_CHANNEL:-beta}"
    for _r in $REPOS; do
        [ -n "$_r" ] || continue
        if ! fetch "$GH/repos/$_r/releases?per_page=12" "$_tf" "$(gh_token)"; then
            say "  仓库 $_r 取不到（不通/被封/限流）"
            continue
        fi
        _tag=$(pick_tag "$_tf" "$_ch")
        if [ -z "$_tag" ]; then
            say "  仓库 $_r 没有符合通道（$_ch）的版本"
            rm -f "$_tf"
            continue
        fi
        # 再单独取这个 tag 的详情，拿 arm64 资产的官方 digest（单对象，解析可靠）
        _sha=""
        _tf2="$WORK/.rel1.json"
        if fetch "$GH/repos/$_r/releases/tags/$_tag" "$_tf2" "$(gh_token)"; then
            _sha=$(tr -d ' \n\r\t' < "$_tf2" | sed 's/},{/}\n{/g' \
                   | grep -F "\"name\":\"$ASSET\"" \
                   | sed -n 's/.*"digest":"sha256:\([0-9a-f]\{64\}\)".*/\1/p' | head -n1)
            rm -f "$_tf2"
        fi
        rm -f "$_tf"
        printf '%s\t%s\t%s\n' "$_r" "$_tag" "$_sha"
        return 0
    done
    rm -f "$_tf"
    return 1
}

sources() {
    _s=$(conf_get AG2A_UPDATE_SOURCES)
    [ -n "$_s" ] || _s="${AG2A_UPDATE_SOURCES:-}"
    [ -n "$_s" ] || _s="https://gh-proxy.com/,https://ghproxy.net/,https://ghfast.top/,"
    printf '%s\n' "$_s" | tr ',' ' '
}

fetch_asset() {
    _url=$1; _out=$2; _want=$3
    for _p in $(sources); do
        if [ -n "$_p" ]; then
            _u="${_p%/}/$_url"
            _label=$_p
        else
            _u=$_url
            _label="github 直连"
        fi
        say "  试源 $_label"
        if [ -n "$_p" ]; then
            _ok=$(fetch "$_u" "$_out" "" 480 slow && echo 1)
        else
            _ok=$(fetch "$_u" "$_out" "" 1200 && echo 1)
        fi
        if [ -n "$_ok" ]; then
            if [ -z "$_want" ]; then
                say "  没有官方摘要可比，接受该源（无法校验）"
                return 0
            fi
            _got=$(sha_of "$_out")
            if [ "$_got" = "$_want" ]; then
                say "  sha256 校验通过"
                return 0
            fi
            say "  校验不符（得 $_got），换下一个源"
            rm -f "$_out"
        else
            say "  连不上/超时，换下一个源"
        fi
    done
    return 1
}

# ELF 必须是 aarch64（防上游误传 amd64 把模块跑废）
is_arm64() {
    _magic=$(dd if="$1" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ "$_magic" = "7f454c46" ] || return 1
    _m=$(dd if="$1" bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ "$_m" = "b700" ]
}

check_once() {
    if ! is_on; then
        say "自动更新已关闭"
        mark "自动更新已关闭"
        return 2
    fi
    [ -n "$SHA" ] || { say "没有 sha256 工具，无法校验，跳过"; mark "失败：无 sha256 工具"; return 1; }

    ag2a_rotate "$LOG" 262144

    _chan=$(conf_get AG2A_UPDATE_CHANNEL)
    [ -n "$_chan" ] || _chan="${AG2A_UPDATE_CHANNEL:-beta}"
    say "检查更新（$REPOS，通道 $_chan）"
    _info=$(release_info) || { say "所有仓库都取不到 release（被封/网络不通）"; mark "失败：取 release 失败"; return 1; }
    _hit=$(printf '%s' "$_info" | cut -f1)
    _tag=$(printf '%s' "$_info" | cut -f2)
    _want=$(printf '%s' "$_info" | cut -f3)
    [ -n "$_tag" ] || { say "release 里没有 tag"; mark "失败：无 tag"; return 1; }
    say "命中仓库 $_hit → $_tag"

    _old=$(cat "$VERF" 2>/dev/null | tr -d ' \r\n')
    if [ "$_tag" = "$_old" ]; then
        say "已是最新（$_tag）"
        mark "已是最新 $_tag"
        return 0
    fi
    # 只有严格更新才动文件。封库后 API 可能残留旧 release，不设这道闸会直接降级覆盖。
    if [ -n "$_old" ] && ! vercmp_gt "$_tag" "$_old"; then
        say "远端 $_tag 不比本地 $_old 新，忽略（大概率是封库后的陈旧 release）"
        mark "已是最新 $_old（远端陈旧 $_tag）"
        return 0
    fi

    say "发现新版 $_tag（当前 ${_old:-未知}）→ 下载 $ASSET"
    _tgz="$WORK/.dl.tgz"
    _url="https://github.com/$_hit/releases/download/$_tag/$ASSET"
    fetch_asset "$_url" "$_tgz" "$_want" || {
        say "所有源都失败（或校验都没过）"; mark "失败：下载/校验"; rm -f "$_tgz"; return 1
    }
    [ -s "$_tgz" ] || { say "下载结果为空"; mark "失败：下载为空"; return 1; }

    _st="$WORK/.staged"
    rm -rf "$_st"; mkdir -p "$_st"
    if ! ( cd "$_st" && tar -xzf "$_tgz" 2>/dev/null ); then
        say "解压失败（包不完整？）"; mark "失败：解压"; rm -f "$_tgz"; rm -rf "$_st"; return 1
    fi
    rm -f "$_tgz"

    _newbin="$_st/agent2api-server"
    if [ ! -s "$_newbin" ]; then
        say "包里找不到 agent2api-server"; mark "失败：包结构异常"; rm -rf "$_st"; return 1
    fi
    if ! is_arm64 "$_newbin"; then
        say "新二进制不是 aarch64，拒绝替换"; mark "失败：架构不符"; rm -rf "$_st"; return 1
    fi

    chmod 0755 "$_newbin"
    mkdir -p "$RT/bin" 2>/dev/null
    if ! cp -f "$_newbin" "$RT/bin/agent2api-server.new" 2>/dev/null; then
        say "写二进制失败（$RT 不可写/空间不足？）"; rm -rf "$_st"; mark "失败：替换失败"; return 1
    fi
    mv -f "$RT/bin/agent2api-server.new" "$RT/bin/agent2api-server" || {
        say "替换二进制失败"; rm -rf "$_st"; mark "失败：替换失败"; return 1
    }
    say "二进制已替换（$(wc -c < "$RT/bin/agent2api-server" | tr -d ' ') 字节）"

    # 换 UI：先挪旧目录，失败就回滚
    if [ -d "$_st/ui" ]; then
        rm -rf "$RT/ui.old"
        mv "$RT/ui" "$RT/ui.old" 2>/dev/null
        mv "$_st/ui" "$RT/ui" && rm -rf "$RT/ui.old" || {
            [ -d "$RT/ui.old" ] && mv "$RT/ui.old" "$RT/ui"
            say "替换 ui 失败，已回滚"
        }
        say "ui 已替换（$(find "$RT/ui" -type f 2>/dev/null | wc -l) 个文件）"
    fi

    rm -rf "$_st"
    echo "$_tag" > "$VERF"

    _rs=$(conf_get AG2A_UPDATE_RESTART)
    [ -n "$_rs" ] || _rs=1
    if [ "$_rs" = "0" ]; then
        say "文件已更新；AG2A_UPDATE_RESTART=0，未重启（下次启动生效）"
        mark "已更新 $_tag（待下次启动生效）"
        return 0
    fi

    # 重启网关：直接调 service.sh restart，不再留 reload 标记等别人轮询
    sh "$MODDIR/service.sh" restart >/dev/null 2>&1
    sh "$MODDIR/refresh.sh" quiet >/dev/null 2>&1
    say "已重启网关"
    mark "已更新 $_tag，已重启"
    return 10
}

# tick：按钟点判断今天该不该查。给 crond / 开机流程调用，跑完就退出。
tick() {
    is_on || exit 2
    _now=$(date +%s 2>/dev/null)
    case "$_now" in '' | *[!0-9]*) exit 1 ;; esac
    _slot=$(today_at "$(check_at)")
    _last=$(tr -dc '0-9' < "$STAMP" 2>/dev/null)
    [ -n "$_last" ] || _last=0
    # 还没到点、或今天已经查过 → 什么都不做
    [ "$_now" -ge "$_slot" ] || exit 0
    [ "$_last" -lt "$_slot" ] || exit 0

    check_once
    _rc=$?
    # 成功失败都记「今天这个钟点查过了」。
    # ⛔ 别写成 slot-21600（「6 小时后重试」）：daemon 每 30 分钟醒一次都会重跑 tick，
    #    那个值让 _last < _slot 恒成立 ⇒ 实际变成每 30 分钟联网重试，整夜反复唤醒。
    echo "$_slot" > "$STAMP" 2>/dev/null
    exit "$_rc"
}

mkdir -p "$WORK" 2>/dev/null

# daemon：睡到下一个目标时刻再醒，醒了跑一次 tick。
# 与「每 60 秒醒一次」的本质区别：那版一天 1440 次唤醒且每次 fork date；
# 这版一天 1 次真干活 + 几十次空唤醒。sleep 期间进程不占 CPU，也不阻止系统休眠。
# 单次睡眠封顶 1800 秒：手机深睡会把 sleep 拉长、用户也可能改钟点，
# 每 30 分钟重新校准一次，代价可忽略。
daemon() {
    # 关掉自动更新就别常驻：否则整夜挂着一个只会睡的进程，纯浪费。
    if ! ag2a_update_on; then
        rm -f "$WORK/update.timer.pid" 2>/dev/null
        exit 0
    fi
    echo $$ > "$WORK/update.timer.pid"
    _sp=""
    trap 'rm -f "$WORK/update.timer.pid" 2>/dev/null
          [ -n "$_sp" ] && kill "$_sp" 2>/dev/null
          exit 0' TERM INT HUP
    while :; do
        sh "$MODDIR/updater.sh" tick >/dev/null 2>&1
        _now=$(date +%s 2>/dev/null)
        case "$_now" in
            '' | *[!0-9]*) _wait=300 ;;
            *)
                _slot=$(today_at "$(check_at)")
                _last=$(tr -dc '0-9' < "$STAMP" 2>/dev/null)
                [ -n "$_last" ] || _last=0
                if [ "$_last" -ge "$_slot" ]; then
                    _next=$((_slot + 86400))     # 今天查过了，等明天
                else
                    _next=$_slot
                fi
                _wait=$((_next - _now))
                [ "$_wait" -lt 60 ] && _wait=60
                [ "$_wait" -gt 1800 ] && _wait=1800
                ;;
        esac
        # 后台 sleep + wait：这样 TERM 到达时能把 sleep 一起收掉。
        # ⛔ 直接 sleep 前台阻塞的话，只杀 daemon 会留一个跑满 1800 秒的孤儿 sleep。
        sleep "$_wait" &
        _sp=$!
        wait "$_sp" 2>/dev/null
        _sp=""
    done
}

case "$1" in
    now|check)   check_once; exit $? ;;
    daemon)      daemon ;;                    # 常驻定时器（service.sh 拉起）
    tick)        tick ;;                      # tick 自带 exit
    status)
        if is_on; then echo "开启（每天 $(check_at)）"; else echo "关闭"; fi
        [ -f "$STATUS" ] && echo "上次 $(cat "$STATUS")"
        exit 0 ;;
    '')
        tick ;;                               # 无参 = 一次性 tick（老调用不会挂）
    *)
        echo "用法: sh updater.sh now | tick | status"
        exit 1 ;;
esac
