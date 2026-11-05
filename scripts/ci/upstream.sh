#!/usr/bin/env bash
# 解析上游最新 tag。输出到 $GITHUB_OUTPUT：tag=<tag>  prerelease=<0|1>  skip=<0|1>
#   skip=1 表示和仓库里 UPSTREAM 记录的一致（没有新版），除非 FORCE=1。
#   prerelease 跟随上游那个 release 的 pre 标记：上游发正式版，我们的包也是正式版。
set -euo pipefail

IN="${1:-}"
REPOS=("aimod-cc/agent2api" "Agent2API/agent2api")

# 钉版：仓库根有 UPSTREAM_PIN（非空）就只认它，手动传的 tag 也不生效 ——
# 上游发过「headless 起不来」的版本（3.3.0-beta.5：update/mod.rs 在非运行时
# 里 tokio::spawn，启动即 panic rc=134），钉住能保证每小时轮询不会把坏版本
# 又推上来。要恢复跟随最新，删掉这个文件即可。
PIN="$(cat UPSTREAM_PIN 2>/dev/null | tr -d ' \r\n' || true)"
PIN="${PIN#v}"

TAG="$IN"
if [ -n "$PIN" ]; then
    [ "$TAG" = "$PIN" ] || echo "::notice::已钉版到 $PIN，忽略输入/最新 tag（${TAG:-空}）"
    TAG="$PIN"
fi
if [ -z "$TAG" ]; then
    for r in "${REPOS[@]}"; do
        t=$(gh api "repos/$r/releases?per_page=20" \
              --jq '[.[] | select(.draft == false) | .tag_name][0] // empty' 2>/dev/null || true)
        if [ -n "$t" ]; then TAG="$t"; break; fi
        echo "::warning::$r 取不到 release，换下一个仓库"
    done
fi
[ -n "$TAG" ] || { echo "::error::两个仓库都拿不到上游 release"; exit 1; }
TAG="${TAG#v}"

# 上游该 release 是不是预览版。查不到（只有 tag 没 release、或没网络）就**当预览版**：
# 宁可少一次「转正」，也别把没验证过的包标成正式版。
PRE="1"
for r in "${REPOS[@]}"; do
    p=$(gh api "repos/$r/releases/tags/v$TAG" --jq '.prerelease' 2>/dev/null || true)
    if [ "$p" = "true" ] || [ "$p" = "false" ]; then
        PRE="$([ "$p" = "true" ] && echo 1 || echo 0)"
        echo "上游 v$TAG 的 prerelease=$p（$r）"
        break
    fi
done

CUR="$(cat UPSTREAM 2>/dev/null | tr -d ' \r\n' || true)"

# 上次发出的版本号（写 update.json 时一并记到 LAST_VERSION）。上游没变、但
# CHANGELOG 或打包脚本改了，也该重出一个包 —— 否则「只改了说明/脚本」的修复
# 永远到不了用户手上。FORCE=1 时忽略一切判断强出。
LASTV="$(cat LAST_VERSION 2>/dev/null | tr -d ' \r\n' || true)"
FINGER="$(cat CHANGELOG.md src/*.sh src/module.prop src/webroot/index.html build_module.py scripts/ci/*.sh 2>/dev/null | sha256sum | cut -c1-16)"
LASTF="$(cat LAST_FINGER 2>/dev/null | tr -d ' \r\n' || true)"

echo "上游 tag: $TAG（仓库记录: ${CUR:-空}），本包 prerelease=$PRE"
echo "上次版本: ${LASTV:-空}，内容指纹: $FINGER（上次 ${LASTF:-空}）"

SKIP=0
if [ "$TAG" = "$CUR" ] && [ "$FINGER" = "$LASTF" ] && [ "${FORCE:-0}" != "1" ]; then
    SKIP=1
fi

{
    echo "tag=$TAG"
    echo "prerelease=$PRE"
    echo "finger=$FINGER"
    echo "skip=$SKIP"
    # notes.sh 打包时会计入 scripts/ci/*.sh 的指纹，所以它必须在这里先落盘再取，
    # 否则「只改 notes.sh」会重出包却仍沿用旧的 changelog.txt。
    echo "lastv=$LASTV"
    echo "lastf=$LASTF"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT 未设置}"
