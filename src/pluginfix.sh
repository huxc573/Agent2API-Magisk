#!/system/bin/sh
# 插件二进制「解释器」修复。
#
# 为什么：插件（提供商增强 / 网页提供商）是上游按 **glibc Linux** 编的独立进程，
# 面板 exec 直接拉起。它们 ELF 头里的 PT_INTERP 写死 /lib/ld-linux-aarch64.so.1，
# 而 Android 根分区只读、没有 /lib，内核 execve 时找不到解释器直接 ENOENT ——
# 报的是「启动插件进程失败 … No such file or directory (os error 2)」，文件明明在。
#
# 解法：把 PT_INTERP 那个字符串**原地**改成 /data/adb/ag2a/ld.so（软链指向模块自带
# 的 loader）。原槽位 27 字节（"/lib/ld-linux-aarch64.so.1" 26 + 结尾 NUL），新串
# 21 字节，其余补 0；phdr 不动、文件长度不动、偏移不动。只改这一段字符串，
# 失败最多留一个 .interp.tmp，不会把插件改坏。
#
# 为什么不套壳（换成 sh 脚本 + .real）：多一份文件、壳里把路径写死、上游升级后
# 还得再抢时机；改 interp 之后二进制本身就是可执行的，没有这些尾巴。
# 为什么不用 chroot / unshare -m：那要 bind-mount 一堆系统目录，异常退出留脏挂载，
# 而且 APatch 的 su 下 namespace 不一定真隔离。
#
# 幂等：已经是目标值就判 ok 跳过，可以每次启动都跑。

MODDIR="${AG2A_MODDIR:-/data/adb/modules/ag2a}"
# 安装期（customize.sh 调用）时 MODDIR 指向旧模块目录，可能还没有 lib.sh；先给默认值兜住。
AG2A_LD_NAME=ld-linux-aarch64.so.1
[ -f "$MODDIR/lib.sh" ] && . "$MODDIR/lib.sh"

WORK="${AG2A_DATA_DIR:-/data/adb/ag2a}"
P="$WORK/plugins"
LOADER="$MODDIR/lib/$AG2A_LD_NAME"
# 必须短：原槽位只有 27 字节，路径一长就塞不进去。固定放这里，不跟 .datadir 走。
LDSO_LINK="${AG2A_LDSO_LINK:-/data/adb/ag2a/ld.so}"

QUIET=0
[ "$1" = "quiet" ] && QUIET=1
say() { [ "$QUIET" = "1" ] || echo "$@"; }

# ---------- 软链：指向模块自带的 loader ----------
# 用软链不用拷贝：模块升级后 loader 那份会换，软链自动跟到新的。
link_refresh() {
    [ -x "$LOADER" ] || return 1
    [ "$(readlink "$LDSO_LINK" 2>/dev/null)" = "$LOADER" ] && return 0
    _t="$LDSO_LINK.new.$$"
    rm -f "$_t" 2>/dev/null
    ln -s "$LOADER" "$_t" 2>/dev/null || return 1
    mv -f "$_t" "$LDSO_LINK" 2>/dev/null || { rm -f "$_t"; return 1; }
    [ "$(readlink "$LDSO_LINK" 2>/dev/null)" = "$LOADER" ]
}

# ---------- ELF 头解析 ----------
# 输出 "<p_offset> <p_filesz>"；不是 aarch64 动态 ELF 就返回 1。
# ELF64 布局：e_ident@0(16) / e_phoff@32(8) / e_phentsize@54(2) / e_phnum@56(2)
# phdr 布局：p_type@0(4) / p_offset@8(8) / p_filesz@32(8)
interp_of() {
    _f="$1"
    [ -f "$_f" ] || return 1
    # e_ident[4]=2 → ELF64，e_ident[18..19]=0xB7 0x00 → EM_AARCH64(183)
    _cls=$(od -An -tu1 -j4 -N1 "$_f" 2>/dev/null | tr -d ' \t\r\n')
    _m0=$(od -An -tu1 -j18 -N1 "$_f" 2>/dev/null | tr -d ' \t\r\n')
    _m1=$(od -An -tu1 -j19 -N1 "$_f" 2>/dev/null | tr -d ' \t\r\n')
    [ "$_cls" = "2" ] || return 1
    [ "$_m0" = "183" ] && [ "$_m1" = "0" ] || return 1
    _phoff=$(od -An -tu8 -j32 -N8 "$_f" 2>/dev/null | tr -d ' \t\r\n')
    _phes=$(od -An -tu2 -j54 -N2 "$_f" 2>/dev/null | tr -d ' \t\r\n')
    _phnum=$(od -An -tu2 -j56 -N2 "$_f" 2>/dev/null | tr -d ' \t\r\n')
    case "$_phoff$_phes$_phnum" in '' | *[!0-9]*) return 1 ;; esac
    [ "$_phes" -ge 56 ] 2>/dev/null || return 1
    [ "$_phnum" -gt 0 ] 2>/dev/null || return 1
    [ "$_phnum" -lt 4096 ] 2>/dev/null || return 1
    _i=0
    while [ "$_i" -lt "$_phnum" ]; do
        _o=$((_phoff + _i * _phes))
        _type=$(od -An -tu4 -j"$_o" -N4 "$_f" 2>/dev/null | tr -d ' \t\r\n')
        if [ "$_type" = "3" ]; then
            _poff=$(od -An -tu8 -j$((_o + 8)) -N8 "$_f" 2>/dev/null | tr -d ' \t\r\n')
            _pfsz=$(od -An -tu8 -j$((_o + 32)) -N8 "$_f" 2>/dev/null | tr -d ' \t\r\n')
            case "$_poff$_pfsz" in '' | *[!0-9]*) return 1 ;; esac
            [ "$_pfsz" -gt 0 ] 2>/dev/null || return 1
            [ "$_pfsz" -le 512 ] 2>/dev/null || return 1
            printf '%s %s' "$_poff" "$_pfsz"
            return 0
        fi
        _i=$((_i + 1))
    done
    return 1
}

interp_string() {
    _r=$(interp_of "$1" 2>/dev/null) || return 1
    dd if="$1" bs=1 skip="${_r%% *}" count="${_r##* }" 2>/dev/null | tr -d '\000'
}

# 改一个文件。输出 ok / fixed / static / other / toolong / write-fail / verify-fail
# 返回 0 = 可用（ok/fixed/static），1 = 有问题
interp_fix() {
    _f="$1"
    _r=$(interp_of "$_f" 2>/dev/null) || { printf 'static'; return 0; }
    _poff="${_r%% *}"
    _pfsz="${_r##* }"
    _cur=$(interp_string "$_f" 2>/dev/null)
    _want="$LDSO_LINK"
    [ "$_cur" = "$_want" ] && { printf 'ok'; return 0; }
    # 只碰「看起来是系统动态链接器」的，别的一律不动（宁可不动，也别改坏别人的程序）
    case "$_cur" in
        /lib/* | /usr/lib/* | /system/lib* | /apex/*) : ;;
        *) printf 'other:%s' "$_cur"; return 1 ;;
    esac
    # 新串必须塞得进原槽位（含结尾 NUL）
    [ $((${#_want} + 1)) -le "$_pfsz" ] || { printf 'toolong'; return 1; }

    _tmp="${_f}.interp.tmp"
    cp -f "$_f" "$_tmp" 2>/dev/null || { printf 'write-fail'; return 1; }
    dd if=/dev/zero of="$_tmp" bs=1 seek="$_poff" count="$_pfsz" conv=notrunc 2>/dev/null \
        || { rm -f "$_tmp"; printf 'write-fail'; return 1; }
    printf '%s' "$_want" | dd of="$_tmp" bs=1 seek="$_poff" conv=notrunc 2>/dev/null \
        || { rm -f "$_tmp"; printf 'write-fail'; return 1; }
    [ "$(interp_string "$_tmp" 2>/dev/null)" = "$_want" ] \
        || { rm -f "$_tmp"; printf 'verify-fail'; return 1; }
    chmod 755 "$_tmp" 2>/dev/null || { rm -f "$_tmp"; printf 'write-fail'; return 1; }
    mv -f "$_tmp" "$_f" 2>/dev/null || { rm -f "$_tmp"; printf 'write-fail'; return 1; }
    # mv 之后再从最终路径回读一遍：临时文件对了不代表落盘对了
    [ "$(interp_string "$_f" 2>/dev/null)" = "$_want" ] || { printf 'verify-fail'; return 1; }
    printf 'fixed'
    return 0
}

# 扫目录树里的可执行 ELF（跳过 .so，共享库没有 interp）
fix_tree() {
    _root="$1"
    [ -d "$_root" ] || return 0
    for _e in "$_root"/*; do
        [ -e "$_e" ] || continue
        if [ -d "$_e" ]; then fix_tree "$_e"; continue; fi
        case "$_e" in *.so | *.so.* | *.tmp) continue ;; esac
        case "$(interp_fix "$_e" 2>/dev/null)" in
            fixed) say "  已修复解释器：${_e#$P/}" ;;
            verify-fail | toolong | write-fail) echo "  解释器改写失败：${_e#$P/}" >&2 ;;
        esac
    done
    return 0
}

# ---------- 主流程 ----------
[ -d "$P" ] || { say "还没有装插件（$P 不存在）"; exit 0; }

# 软链不在，后面改出来的 interp 就是死路径 —— 宁可不动
if ! link_refresh; then
    echo "缺少 loader 或软链建立失败：$LOADER → $LDSO_LINK" >&2
    exit 1
fi

# 布局随上游版本变过，整棵扫：<id>/<ver>/bin/* 与 <id>/bin/* 都能覆盖到
for _d in "$P"/*; do
    [ -d "$_d" ] || continue
    case "$_d" in *.staging) continue ;; esac
    fix_tree "$_d"
done

say "插件解释器检查完毕（$P）"
exit 0
