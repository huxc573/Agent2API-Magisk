#!/usr/bin/env bash
# 生成 Release 说明（notes.md）。
#
# 为什么不只放一个上游链接：上游常常「只有 tag、没发 Release」（3.3.0-beta.5.1 就是这样），
# 甚至事后删 tag，链接一点就 404 —— 那样谁也不知道这次到底更新了啥。
# 所以这里把「本模块这次改了什么」和「上游这版改了什么」**正文抄进来**，链接只作补充。
#
# 用法: notes.sh <本地版本> <上游tag> <zip路径> <运行体来源 asset|image> <镜像引用> [二进制sha256]
set -euo pipefail

V="${1:?本地版本}"
UP="${2:?上游 tag}"
ZIP="${3:?zip 路径}"
SRC="${4:-image}"
IMGREF="${5:-aimodcc/agent2api}"
BSHA="${6:-}"
UPREPO="${UPSTREAM_REPO:-aimod-cc/agent2api}"
UPV="${UP#v}"

[ -f "$ZIP" ] || { echo "找不到 $ZIP"; exit 1; }
SHA="$(sha256sum "$ZIP" | cut -d' ' -f1)"
SIZE="$(du -h "$ZIP" | cut -f1)"

# ---- 本模块本次变更：CHANGELOG 最上面那一节正文 ----
# ⚠ 这里不加 head：pipefail 下 head 提前关管道会让上游拿到 SIGPIPE(141)，整步失败
LOCAL="$(awk 'BEGIN{n=0} /^## /{n++; if(n==2) exit} n==1' CHANGELOG.md | sed '1d' | sed '/^[[:space:]]*$/d')"
[ -n "$LOCAL" ] || LOCAL="- （CHANGELOG 里没找到对应小节）"

# ---- 上游这版改了什么 ----
UP_BODY=""
UP_LINK=""
if gh release view "v$UPV" -R "$UPREPO" >/dev/null 2>&1; then
    UP_BODY="$(gh release view "v$UPV" -R "$UPREPO" --json body -q .body 2>/dev/null || true)"
    UP_LINK="https://github.com/$UPREPO/releases/tag/v$UPV"
else
    # 没有 Release：退一步读该 tag 的 commit message；tag 也没了再退到 commits 列表
    UP_BODY="$(gh api "repos/$UPREPO/commits/v$UPV" --jq '.commit.message' 2>/dev/null || true)"
    if [ -n "$UP_BODY" ]; then
        UP_LINK="https://github.com/$UPREPO/commits/v$UPV"
    else
        UP_LINK="https://github.com/$UPREPO/commits"
    fi
fi
UP_BODY="$(printf '%s' "$UP_BODY" | head -c 1500 || true)"
[ -n "$UP_BODY" ] || UP_BODY="（上游没有可读的 release 说明或提交信息）"

# ---- 运行体来源 ----
case "$SRC" in
    asset) SRC_TXT="上游 Release 资产 \`agent2api-server-linux-arm64.tar.gz\`（已校验 sha256）" ;;
    *)     SRC_TXT="官方镜像 \`$IMGREF\` 里的二进制（该 tag 没有可用 Release 资产）" ;;
esac

cat > notes.md <<EOF
模块版本 **$V**，上游运行体 **$UP**。

## 本模块这次改了什么

$LOCAL

## 上游 $UP 的说明

$UP_BODY

## 运行体来源

- $SRC_TXT
- 二进制 sha256：\`${BSHA:-（未记录）}\`
- 包大小 $SIZE，sha256 \`$SHA\`
- 上游链接：$UP_LINK

## 安装

在管理器里刷入 zip（APatch / Magisk / KernelSU）。**首次安装要重启一次**，升级安装刷完即生效。
升级时运行体在 \`/data/adb/ag2a/rt/\` 立即换新；两个按钮（打开/执行）的面板入口需重启一次才换成新版。
EOF

echo "notes.md 已生成（$(wc -l < notes.md) 行）"
