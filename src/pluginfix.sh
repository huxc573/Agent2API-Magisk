#!/system/bin/sh
# 给插件二进制套一层启动壳。
#
# 为什么：插件（提供商增强 / 网页提供商）是上游按 **glibc Linux** 编译的独立进程，
# 面板用 exec 直接拉起它们。它们的 ELF 解释器写死是 /lib/ld-linux-aarch64.so.1，
# 而 Android 根目录根本没有 /lib ⇒ 内核 execve 返回 ENOENT，面板报
# 「启动插件进程失败（…/bin/agent2api-providers）: No such file or directory (os error 2)」
# —— 文件明明在，是解释器找不到。主程序能跑是因为 service.sh 用模块自带 loader 起的，
# 插件不在我们手里，只能事后把入口换成脚本：脚本再 exec 同一个 loader。
#
# 判据很轻：只有 ELF 才套壳，已经是脚本（#! 开头）就跳过，所以可以每次启动都跑一遍。
# 插件升级会把 bin/ 里的入口换回 ELF ⇒ 下次启动自动重新套壳。

MODDIR="${AG2A_MODDIR:-/data/adb/modules/ag2a}"
. "$MODDIR/lib.sh"

# 壳里写死的 loader 路径必须指向**最终**模块目录：customize.sh 执行时 $MODDIR 是
# modules_update/ag2a，安装完就被清掉了，写进壳里会让插件永远起不来。
WRAPDIR="${AG2A_WRAP_MODDIR:-$MODDIR}"

WORK=$(ag2a_data_dir)
P="$WORK/plugins"
QUIET=0
[ "$1" = "quiet" ] && QUIET=1

if [ ! -d "$P" ]; then
    [ "$QUIET" = "1" ] || echo "还没有装插件（$P 不存在）"
    exit 0
fi

LD="$WRAPDIR/lib/$AG2A_LD_NAME"
if [ ! -f "$LD" ]; then
    echo "缺少 loader：$LD" >&2
    exit 1
fi

ELF_MAGIC=$(printf '\177ELF')

for _f in "$P"/*/*/bin/*; do
    [ -f "$_f" ] || continue
    case "$_f" in *.real | *.old | *.new) continue ;; esac
    _hdr=$(head -c 4 "$_f" 2>/dev/null)
    if [ "$_hdr" = "$ELF_MAGIC" ]; then
        if mv -f "$_f" "$_f.real" 2>/dev/null; then
            {
                echo '#!/system/bin/sh'
                echo '# ag2a 生成，别手改：Android 没有 /lib/ld-linux-aarch64.so.1，'
                echo '# glibc 二进制直接 exec 会 ENOENT，这里用模块自带 loader 拉起来。'
                # 库搜索路径给两段：模块 lib（libc/libm/libgcc_s）＋插件自己目录（万一它带私有 .so）
                printf 'exec "%s" --library-path "%s:%s" "${0}.real" "$@"\n' \
                    "$LD" "$WRAPDIR/lib" '${0%/*}'
            } > "$_f" && chmod 0755 "$_f" 2>/dev/null
            if [ "$?" = "0" ]; then
                [ "$QUIET" = "1" ] || echo "  已套壳 ${_f#$P/}"
            else
                echo "  套壳失败 ${_f#$P/}" >&2
            fi
        else
            echo "  挪不动 ${_f#$P/}" >&2
        fi
    fi
done

[ "$QUIET" = "1" ] || echo "插件入口检查完毕（$P）"
exit 0
