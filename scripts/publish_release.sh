#!/usr/bin/env bash
# scripts/publish_release.sh — 打包当前版本并发 GitHub Release（供插件「设置 → 检查更新」使用）
#
# 用法:  bash scripts/publish_release.sh [--notes-file <文件>]
# 前置:  工作区干净；版本号单一来源 = technews.koplugin/main.lua 的 version
# 产物:  GitHub Release v<版本>，资产 = technews.koplugin-v<版本>.zip
#        （ZIP 顶层目录 technews.koplugin/，与 updater.lua 的校验一致）
# 备注:  直连 GitHub 超时时走代理：HTTPS_PROXY=http://127.0.0.1:1087 bash scripts/publish_release.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

VERSION=$(grep -m1 'version = "' technews.koplugin/main.lua \
    | sed -E 's/.*version = "([^"]+)".*/\1/')
TAG="v$VERSION"

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: 工作区有未提交改动，请先提交再发布" >&2
    exit 1
fi

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT
ZIP="$OUT_DIR/technews.koplugin-$TAG.zip"
git archive --format=zip --prefix="technews.koplugin/" -o "$ZIP" "HEAD:technews.koplugin"
echo "打包完成: $ZIP（版本 $TAG）"

if [ "${1:-}" = "--notes-file" ] && [ -n "${2:-}" ]; then
    NOTES_ARGS=(--notes-file "$2")
else
    NOTES_ARGS=(--notes "发布 $TAG。设备端可在插件「设置 → 检查更新」中直接升级。")
fi

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG 已存在，覆盖上传资产…"
    gh release upload "$TAG" "$ZIP" --clobber
else
    gh release create "$TAG" "$ZIP" --title "technews.koplugin $TAG" "${NOTES_ARGS[@]}"
fi

echo "发布完成: $(gh release view "$TAG" --json url --jq .url)"
