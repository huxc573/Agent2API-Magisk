#!/system/bin/sh
# 兼容壳。v1.5.x 的 control.sh 是「每 3 秒扫 /proc 判活 + 每 30 秒刷 description」的
# 常驻循环 —— 那是耗电元凶（CPU 永远进不了深度休眠）。
# v1.6.0 起：启停全部由 service.sh 一次性完成，description 由 refresh.sh 按需刷。
# 本文件只做转发，保证旧的调用（action.sh / uninstall.sh / 手打）不报错。

MODDIR="$(dirname "$(readlink -f "$0")")"
exec /system/bin/sh "$MODDIR/service.sh" "${1:-start}"
