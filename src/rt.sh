#!/system/bin/sh
# 运行体同步：把模块目录里的 bin/ + ui/ 复制到数据目录的 rt/，让新版**立刻**生效。
#
# 为什么需要这一步：
#   /data/adb/modules/ag2a 是 Magisk 的地盘 —— 刷 zip 只是把文件解到
#   /data/adb/modules_update/ag2a，要**重启**才会整体替换到 modules/。
#   运行体放在那儿，刷完不重启就还是旧二进制，表现就是「模块列表显示新版本、
#   实际服务还是老的」。
#   /data/adb/ag2a 是模块自己的数据目录，Magisk 从不碰 ⇒ 同步过去、重启网关即生效。
#
# lib/ etc/ zoneinfo/ 故意不搬：它们跟着模块版本走但从不变（libc 那套上游没换过），
#   留在模块目录少一份拷贝，loader 也在那儿。
#
# 提交点：所有文件都 mv 到位之后才写 .rtver。
#   中途断电/失败时它还是旧值（或不存在），下次启动 service.sh 发现 rt 比模块旧
#   （或根本没有戳）就整份重同步 —— 自愈，不需要人工介入。
#
# 用法：
#   sh rt.sh sync [源目录]   同步（源默认 $MODDIR；customize.sh 传 $MODPATH）
#   sh rt.sh check           只判断：需要同步返回 0，不需要返回 1
#   sh rt.sh status          打印两边版本与落点

MODDIR="$(dirname "$(readlink -f "$0")")"
. "$MODDIR/lib.sh"

WORK=$(ag2a_data_dir)
RT="$WORK/rt"
# RT 下会做 rm -rf：数据目录被带偏成空/根时立刻停手
case "$WORK" in
    '' | / | /data | /data/adb | /sdcard | /storage* | /system* | /data/local/tmp)
        echo "[rt] 数据目录异常（$WORK），拒绝执行" >&2; exit 1 ;;
esac

# 源目录里 module.prop 的 versionCode（= 同步完要写进 .rtver 的值）
_src_ver() {
    _sv=$(sed -n 's/^versionCode=//p' "$1/module.prop" 2>/dev/null | head -n1 | tr -dc '0-9')
    case "$_sv" in '' | *[!0-9]*) _sv=0 ;; esac
    echo "$_sv"
}

do_sync() {
    _src=$1
    [ -f "$_src/bin/$AG2A_BIN_NAME" ] || { echo "[rt] 源目录没有二进制：$_src" >&2; return 1; }
    [ -d "$_src/ui" ] || { echo "[rt] 源目录没有 ui：$_src" >&2; return 1; }
    mkdir -p "$RT/bin" 2>/dev/null || { echo "[rt] 建不了 $RT" >&2; return 1; }

    # 1) 二进制：cp → 补权限 → mv。同一个文件系统上 mv 是原子的，
    #    不会出现「文件半截被网关 exec」的窗口。
    if cp -f "$_src/bin/$AG2A_BIN_NAME" "$RT/bin/.bin.new" 2>/dev/null; then
        chmod 0755 "$RT/bin/.bin.new" 2>/dev/null
        mv -f "$RT/bin/.bin.new" "$RT/bin/$AG2A_BIN_NAME" 2>/dev/null || {
            echo "[rt] 替换二进制失败" >&2; return 1; }
    else
        rm -f "$RT/bin/.bin.new" 2>/dev/null
        echo "[rt] 复制二进制失败（空间不足？）" >&2
        return 1
    fi

    # 2) ui 整目录替换：先复制成 ui.new，再换名；换名失败就把旧的换回来
    rm -rf "$RT/ui.new" 2>/dev/null
    if ! cp -R "$_src/ui" "$RT/ui.new" 2>/dev/null; then
        rm -rf "$RT/ui.new" 2>/dev/null
        echo "[rt] 复制 ui 失败（空间不足？）" >&2
        return 1
    fi
    rm -rf "$RT/ui.old" 2>/dev/null
    mv "$RT/ui" "$RT/ui.old" 2>/dev/null
    if mv "$RT/ui.new" "$RT/ui" 2>/dev/null; then
        rm -rf "$RT/ui.old" 2>/dev/null
    else
        [ -d "$RT/ui.old" ] && mv "$RT/ui.old" "$RT/ui" 2>/dev/null
        rm -rf "$RT/ui.new" 2>/dev/null
        echo "[rt] 替换 ui 失败，已回滚" >&2
        return 1
    fi

    # 3) 提交点：最后才写版本戳
    _ver=$(_src_ver "$_src")
    if printf '%s\n' "$_ver" > "$RT/.rtver.new" 2>/dev/null; then
        mv -f "$RT/.rtver.new" "$RT/.rtver" 2>/dev/null || {
            echo "[rt] 写版本戳失败" >&2; return 1; }
    else
        echo "[rt] 写版本戳失败" >&2
        return 1
    fi

    echo "[rt] 已同步 $(find "$RT/ui" -type f 2>/dev/null | wc -l | tr -d ' ') 个 ui 文件，版本戳 $_ver"
    return 0
}

case "$1" in
    sync | '') do_sync "${2:-$MODDIR}"; exit $? ;;
    check)    ag2a_rt_need_sync; exit $? ;;
    status)
        echo "数据目录 $WORK"
        echo "运行体   $RT"
        echo "二进制   $(ag2a_bin)"
        echo "ui       $(ag2a_ui)"
        echo "版本戳   rt=$(ag2a_rtver) 模块=$(ag2a_modver)"
        if ag2a_rt_need_sync; then
            echo "状态     需要同步（sh $(dirname "$(readlink -f "$0")")/rt.sh sync）"
        else
            echo "状态     已是最新"
        fi
        exit 0 ;;
    *)
        echo "用法: sh rt.sh sync [源目录] | check | status"
        exit 1 ;;
esac
