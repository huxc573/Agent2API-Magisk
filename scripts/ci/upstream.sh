#!/usr/bin/env bash
# 解析上游最新 tag。输出到 $GITHUB_OUTPUT：tag=<tag>  skip=<0|1>
#   skip=1 表示和仓库里 UPSTREAM 记录的一致（没有新版），除非 FORCE=1。
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

CUR="$(cat UPSTREAM 2>/dev/null | tr -d ' \r\n' || true)"
echo "上游 tag: $TAG（仓库记录: ${CUR:-空}）"

{
    echo "tag=$TAG"
    if [ "$TAG" = "$CUR" ] && [ "${FORCE:-0}" != "1" ]; then
        echo "skip=1"
    else
        echo "skip=0"
    fi
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT 未设置}"
