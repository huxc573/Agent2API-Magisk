#!/usr/bin/env bash
# 生成管理器更新弹窗用的 changelog.txt。
#
# 管理器会把 update.json 里 changelog 指向的文件**原样**展示给用户，所以这里只写
# 「这一版」的内容，不带历史版本、不带开发过程：
#
#   **本模块 26.11.10_2**　发布于 10:39 UTC+8     ← 版本号 + 发布时刻（版本号自带日期，不重复写日期）
#
#   - 本模块这版改了什么                          ← CHANGELOG.md 里 ## <版本> 那一段
#
#   **上游 3.5.0-beta.1 的改动**                  ← 上游这一版 release 说明里的条目
#
#   **核心更新**
#   - 新增：…
#   **其他更新**
#   - 修复：…
#
# 用法: scripts/ci/changelog.sh <版本号> [上游 tag] [输出文件] [上一版 changelog]
#   scripts/ci/changelog.sh 26.11.10_2 3.5.0-beta.1
# 环境:
#   AG2A_UPSTREAM_REPO  上游源码仓，默认 aimod-cc/Agent2API（读 release 说明用）
#   CHANGELOG_NOW       覆盖发布时刻（HH:MM），只在本地预览时用
set -euo pipefail

V="${1:?需要模块版本号，如 26.11.10_2}"
UP="${2:-}"
OUT="${3:-changelog.txt}"
PREV="${4:-}"
SRC="${CHANGELOG_SRC:-CHANGELOG.md}"
UPREPO="${AG2A_UPSTREAM_REPO:-aimod-cc/Agent2API}"
UPV="${UP#v}"
UP_CAP=20          # 上游条目上限，超过就截断并注明去 Releases 看全

# ---------- 本模块这版 ----------
# 优先用上一版 changelog 里的模块段：上游没变、force 重出包时，CHANGELOG.md 的首节
# 可能已经写成下一个版本了，照抄会张冠李戴。剥离规则与下面写出的格式一一对应。
self_from_prev() {
    [ -s "$PREV" ] || return 0
    awk '
        NR == 1 && /^\*\*本模块 /        { next }   # 版本头
        /^\*\*上游 .*的改动\*\*$/        { exit }   # 到这里开始是上游段
        /^（上游运行体 .*）$/            { next }   # 旧格式尾注
        { print }
    ' "$PREV"
}

self_body=""
[ -n "$PREV" ] && self_body="$(self_from_prev)"
if [ -z "$(printf '%s' "$self_body" | tr -d '[:space:]')" ]; then
    # CHANGELOG.md 第一小节正文（标题行去掉）
    self_body="$(awk 'BEGIN{n=0} /^## /{n++; if(n==2) exit} n==1' "$SRC" 2>/dev/null | sed '1d' || true)"
fi
# 条目里的粗体/行内代码标记在弹窗里没意义，删掉；空行去掉（弹窗里只看条目）
self_body="$(printf '%s\n' "$self_body" \
    | sed 's/\*\*//g' | sed 's/`//g' | sed 's/^[[:space:]]*//' | sed '/^$/d' || true)"

# ---------- 上游这版 ----------
# 上游的说明是中文分节的编号列表（核心更新 / 其他更新），条目形如 "1. 新增：…"；
# GitHub 自动生成的英文仓则是 "* fix(x): … by @user in https://…"。
# 两种都归一成 "- 条目"，丢掉 "by @user in 链接" 尾巴；章节标题留成粗体小标题。
up_body=""
up_total=0
if [ -n "$UP" ] && command -v gh >/dev/null 2>&1; then
    # 上游 tag 带不带 v 都有（v3.5.0-beta.1 / web-v3.4.3），两种都试一次
    up_raw=""
    for _t in "v$UPV" "$UPV"; do
        up_raw="$(gh release view "$_t" -R "$UPREPO" --json body --jq .body 2>/dev/null || true)"
        [ -n "$up_raw" ] && break
    done
    if [ -n "$up_raw" ]; then
        up_body="$(printf '%s\n' "$up_raw" | awk '
            /^## New Contributors/ { stop = 1 }
            /^\*\*Full Changelog\*\*/ { stop = 1 }
            stop { next }
            /^## / {
                s = $0
                sub(/^##[[:space:]]*/, "", s)
                if (s != "") print "**" s "**"
                next
            }
            /^[[:space:]]*([*+-]|[0-9]+[.)、])[[:space:]]+/ { print }
        ' | sed -e 's/^[[:space:]]*\([*+-]\|[0-9]\+[.)、]\)[[:space:]]\+/- /' \
              -e 's/[[:space:]]\+by[[:space:]]\+@[^ ]*[[:space:]]\+in[[:space:]]\+https\{0,1\}:[^ ]*$//' \
              -e 's/[[:space:]]*$//' || true)"
        # 空行统一在输出时补，这里先清掉
        up_body="$(printf '%s\n' "$up_body" | awk 'NF == 0 { next } { print }' || true)"
        up_total="$(printf '%s\n' "$up_body" | grep -c '^- ' || true)"
        if [ "$up_total" -gt "$UP_CAP" ]; then
            up_body="$(printf '%s\n' "$up_body" \
                | awk -v n="$UP_CAP" 'BEGIN{c=0; stop=0} /^- /{c++; if(c>n) stop=1} !stop{print}' || true)"
        fi
    fi
fi

# 发布时刻：版本号里已经有日期（26.11.10_2），这里只补时间，避免同一版看不出先后
NOW="${CHANGELOG_NOW:-$(TZ=Asia/Shanghai date '+%H:%M' 2>/dev/null || date -u '+%H:%M')}"

{
    printf '**本模块 %s**　发布于 %s UTC+8\n' "$V" "$NOW"

    if [ -n "$self_body" ]; then
        printf '\n%s\n' "$self_body"
    fi

    if [ -n "$up_body" ]; then
        printf '\n**上游 %s 的改动**\n\n' "${UPV:-新版本}"
        # 小标题（核心更新 / 其他更新）前面留一个空行，读起来分段清楚
        printf '%s\n' "$up_body" | awk 'NR > 1 && /^\*\*/ { print "" } { print }'
        if [ "$up_total" -gt "$UP_CAP" ]; then
            printf -- '- …（共 %s 条，完整说明见 Releases 页）\n' "$up_total"
        fi
    elif [ -z "$self_body" ]; then
        printf '\n- 本版仅更新运行体到上游 `%s`，无其它改动。\n' "${UPV:-新版本}"
    else
        # 上游没发 Release、只有 tag 时，至少让用户知道运行体是哪个
        printf '\n（上游运行体 %s）\n' "$UP"
    fi
} > "$OUT"

echo "== 写入 $OUT（模块段 ${#self_body} 字节，上游 ${#up_body} 字节）"
cat "$OUT"
