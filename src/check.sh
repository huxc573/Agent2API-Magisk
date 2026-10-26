#!/system/bin/sh
# 安装后自检：在手机上跑一遍，把结果贴回来（不依赖 magisk 的 ui_print）。
# 用法: sh /data/adb/modules/ag2a/check.sh

MODDIR="$(dirname "$(readlink -f "$0")")"
. "$MODDIR/lib.sh"
WORK=$(ag2a_data_dir)

echo "== 环境 =="
echo "abi: $(getprop ro.product.cpu.abi) / $(getprop ro.product.cpu.abilist)"
echo "android: $(getprop ro.build.version.release) (sdk $(getprop ro.build.version.sdk))"
echo "selinux: $(getenforce 2>/dev/null)"
echo "magisk: $(magisk -V 2>/dev/null || echo '非 magisk?')"
echo "uname: $(uname -m)"

echo "== 文件 =="
for f in lib/ld-linux-aarch64.so.1 lib/libc.so.6 lib/libm.so.6 lib/libgcc_s.so.1 \
         etc/ca-certificates.crt zoneinfo/Asia/Shanghai; do
    [ -e "$MODDIR/$f" ] && echo "  ok   $f ($(wc -c < "$MODDIR/$f" | tr -d ' ') B)" || echo "  MISS $f"
done
echo "  bin  $(ag2a_bin) ($([ -f "$(ag2a_bin)" ] && wc -c < "$(ag2a_bin)" | tr -d ' ' || echo 0) B)"
echo "  ui   $(ag2a_ui)（$(find "$(ag2a_ui)" -type f 2>/dev/null | wc -l) 个文件）"
echo "  运行体版本: rt=$(ag2a_rtver) 模块=$(ag2a_modver)$(ag2a_rt_need_sync && echo '  ⚠ 需要同步')"
echo "  数据目录: $WORK"

echo "== 直跑二进制（-h / --help，预期打印用法或报 flag 错误，不 segfault）=="
export AGENT2API_PROXY_HOME="$WORK" HOME="$WORK" AGENT2API_UI_DIR="$(ag2a_ui)"
eval "$(ag2a_cert_env)"
eval "$(ag2a_tz_env)"
"$MODDIR/lib/ld-linux-aarch64.so.1" --library-path "$MODDIR/lib" --list "$(ag2a_bin)" 2>&1 | head -n 8

echo "== 端口监听（网关起来后才会有）=="
PORT=$(ag2a_get_port)
echo "  port=$PORT"
(netstat -ltnp 2>/dev/null || ss -ltnp 2>/dev/null) | grep ":$PORT" || echo "  未监听（进程没起来）"

echo "== 进程 =="
ag2a_running && { echo "  pid: $(ag2a_pids | tr '\n' ' ')"; } || echo "  未运行"

# 耗电自检：v1.6.0 起不应存在任何常驻 shell 循环。这里列出所有可疑进程，
# 有输出就说明还有旧版残留（control.sh / updater.sh 的 while 循环）。
# ⛔ 不能写成「遍历 /proc + 每个进程 fork 一次 tr」：1000 个进程就是 14.5 秒。
#   先 pgrep 拿到候选 pid，再只对这几个读 cmdline。
_lp=""
if command -v pgrep >/dev/null 2>&1; then
    _lp=$(pgrep -f 'modules/ag2a/control\.sh' 2>/dev/null; pgrep -f 'modules/ag2a/updater\.sh' 2>/dev/null)
else
    _lp=$(ps -A -o PID,ARGS 2>/dev/null | grep -E 'modules/ag2a/(control|updater)\.sh' | awk '{print $1}')
fi
_loop=""
for _p in $_lp; do
    case "$_p" in
        '' | *[!0-9]*) continue ;;
        "$$" | "$PPID") continue ;;
    esac
    _c=$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)
    case "$_c" in
        *"updater.sh daemon"*) _loop="$_loop $_p(更新定时器·正常)" ;;   # 这个是该有的
        *"updater.sh tick" | *"updater.sh now") continue ;;             # 一次性任务
        *control.sh* | *updater.sh*)
            _loop="$_loop $_p($(echo "$_c" | tr -s ' ' | cut -c1-60))" ;;
    esac
done
if [ -n "$_loop" ]; then
    echo "  ⚠ 可疑进程:$_loop"
    echo "    处理: sh $MODDIR/service.sh stop; sh $MODDIR/service.sh start"
else
    echo "  常驻循环: 无（正常，v1.6.0 已移除轮询）"
fi

# 自动更新定时器（v1.6.2 起是 sleep 进程；顺带干掉原来那段 14.5 秒的全表扫描）
if [ -f "$WORK/update.timer.pid" ]; then
    _t=$(cat "$WORK/update.timer.pid" 2>/dev/null)
    if [ -n "$_t" ] && kill -0 "$_t" 2>/dev/null; then
        echo "  更新定时器: 在跑（pid $_t）"
    else
        echo "  更新定时器: pidfile 过期（下次 start 会重建）"
    fi
else
    echo "  更新定时器: 未启动"
fi
[ -f "$WORK/crontab" ] && echo "  ⚠ 还留着旧版 crontab: $WORK/crontab"

echo "== 模块列表显示的描述 =="
echo "  $(sed -n 's/^description=//p' "$MODDIR/module.prop" 2>/dev/null | tail -n1)"
echo "  写失败日志: $(tail -n1 "$WORK/desc.log" 2>/dev/null || echo '无')"

echo "== 最近日志 =="
tail -n 25 "$WORK/run.log" 2>/dev/null || echo "  无 run.log"

echo "== 配置 =="
echo "  env:"
sed 's/^/    /' "$WORK/env" 2>/dev/null | grep -v '^    #' || echo "    无 env"
echo "  update.conf:"
sed 's/^/    /' "$WORK/update.conf" 2>/dev/null | grep -v '^    #' || echo "    无 update.conf"
echo "  update.status: $(cat "$WORK/update.status" 2>/dev/null || echo '未检查过')"

echo "== 面板管理员 =="
_found_db=0
for _db in "$WORK"/*.db; do
    [ -f "$_db" ] || continue
    _found_db=1
    echo "  $(basename "$_db")（$(wc -c < "$_db" | tr -d ' ') B）"
    grep -a -o 'panelAdmin' "$_db" >/dev/null 2>&1 \
        && echo "    已注册管理员（面板可用密码登录）" \
        || echo "    尚未注册管理员"
done
[ "$_found_db" = "1" ] || echo "  db 还没生成：网关尚未成功启动过"
echo "  admin.json: $([ -f "$WORK/admin.json" ] && echo 有 || echo 无)"
echo "  admin_user: $(cat "$WORK/admin_user" 2>/dev/null || echo 无)"
echo "  admin_pw:   $([ -f "$WORK/admin_pw" ] && echo '有（还没播种成功）' || echo '无（已播种或未设）')"

echo "== 面板探活 =="
if command -v curl >/dev/null 2>&1; then
    curl -s --noproxy '*' --max-time 5 -o /dev/null -w "  http %{http_code} (%{time_total}s)\n" "http://127.0.0.1:$PORT/" 2>/dev/null
elif command -v wget >/dev/null 2>&1; then
    wget -q -T 5 -O /dev/null "http://127.0.0.1:$PORT/" && echo "  http OK" || echo "  探活失败"
else
    echo "  无 curl/wget，跳过"
fi
