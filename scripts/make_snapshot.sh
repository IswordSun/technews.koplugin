#!/usr/bin/env bash
# scripts/make_snapshot.sh — 生成里程碑快照（可安装 ZIP + 完整历史 bundle）
#
# 用法:   bash scripts/make_snapshot.sh "<描述>"
# 前置:   工作区干净（所有改动已提交）；版本号自动读自 technews.koplugin/main.lua
# 产物:   snapshots/NN-<描述>-v<版本>-<短SHA>/
#            ├── technews.koplugin-v<版本>.zip   可安装（根目录=technews.koplugin/，注释内嵌提交 SHA）
#            └── technews-repo-<短SHA>.bundle    完整 git 历史（含 tags，可 clone 恢复）
#         快照自包含于本仓库的 snapshots/ 目录（gitignore），不写任何外部位置
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

DESC="${1:-}"
if [ -z "$DESC" ]; then
    echo "用法: bash scripts/make_snapshot.sh \"<描述>\"" >&2
    exit 1
fi

# 快照必须对应一个干净提交
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: 工作区有未提交改动，请先提交再打快照" >&2
    exit 1
fi

# 版本号单一来源：main.lua 的 version 字段
VERSION=$(grep -m1 'version = "' technews.koplugin/main.lua \
    | sed -E 's/.*version = "([^"]+)".*/\1/')
SHORT_SHA=$(git rev-parse --short HEAD)
FULL_SHA=$(git rev-parse HEAD)

# 快照编号：snapshots/ 下 NN- 递增
SNAP_ROOT="$REPO_DIR/snapshots"
mkdir -p "$SNAP_ROOT"
LAST=$(ls "$SNAP_ROOT" 2>/dev/null | grep -E '^[0-9]{2}-' | sort | tail -1 || true)
if [ -z "$LAST" ]; then
    NEXT=1
else
    NEXT=$(( 10#${LAST:0:2} + 1 ))
fi
NUM=$(printf '%02d' "$NEXT")

DIR_NAME="${NUM}-${DESC}-v${VERSION}-${SHORT_SHA}"
OUT_DIR="$SNAP_ROOT/$DIR_NAME"
mkdir -p "$OUT_DIR"

ZIP_NAME="technews.koplugin-v${VERSION}.zip"
BUNDLE_NAME="technews-repo-${SHORT_SHA}.bundle"

# 1) 可安装 ZIP（git archive 子树 + 前缀；ZIP 注释内嵌提交 SHA，沿用备份惯例）
git archive --format=zip --prefix="technews.koplugin/" \
    -o "$OUT_DIR/$ZIP_NAME" "HEAD:technews.koplugin"
if command -v zip >/dev/null 2>&1; then
    printf '%s %s\n' "$FULL_SHA" "$DESC" | zip -z "$OUT_DIR/$ZIP_NAME" >/dev/null
fi

# 2) 完整 git 历史（--all 含全部分支/标签，可离线 clone 恢复）
git bundle create "$OUT_DIR/$BUNDLE_NAME" --all >/dev/null

# 3) 登记到 snapshots/README.md
README="$SNAP_ROOT/README.md"
if [ ! -f "$README" ]; then
    printf '# technews 里程碑快照\n\n| 目录 | 描述 | 版本 | 提交 |\n| --- | --- | --- | --- |\n' > "$README"
fi
printf '| %s | %s | v%s | `%s` |\n' "$DIR_NAME" "$DESC" "$VERSION" "$SHORT_SHA" >> "$README"

echo
echo "快照完成: $OUT_DIR"
echo "  版本 v$VERSION | 提交 $SHORT_SHA"
echo "  （快照自包含于 snapshots/；如需仓库外备份，请整体备份本仓库目录）"
if [ -z "$(git tag -l "v$VERSION")" ]; then
    echo "提示: 建议为该里程碑打 tag → git tag -a v$VERSION -m \"$DESC\""
fi
