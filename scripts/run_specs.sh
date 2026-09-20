#!/usr/bin/env bash
# scripts/run_specs.sh — 运行 technews 的 Lua 单元测试
#
# 用法（在任意工作目录均可）：
#   bash scripts/run_specs.sh
#
# 自动发现 spec/*_spec.lua，逐个用 luajit 执行；
# 每个文件打印 PASS/FAIL，最后输出汇总；全部通过退出码为 0，否则为 1。
# 可用环境变量 LUAJIT_BIN 指定解释器（默认 luajit）。

set -uo pipefail

# 解析脚本自身所在目录，保证与调用方 cwd 无关
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"

lua_bin="${LUAJIT_BIN:-luajit}"
if ! command -v "$lua_bin" >/dev/null 2>&1 && [[ ! -x "$lua_bin" ]]; then
    echo "error: 未找到 LuaJIT；请安装 luajit 或设置 LUAJIT_BIN" >&2
    exit 1
fi

shopt -s nullglob
spec_files=("$repo_dir"/spec/*_spec.lua)
shopt -u nullglob

if (( ${#spec_files[@]} == 0 )); then
    echo "error: $repo_dir/spec 下没有发现 *_spec.lua" >&2
    exit 1
fi

passed=0
failed=0

for spec_file in "${spec_files[@]}"; do
    rel="${spec_file#"$repo_dir"/}"
    echo "==> $rel"

    run_rc=0
    output="$("$lua_bin" "$spec_file" 2>&1)" || run_rc=$?
    printf '%s\n' "$output" | sed 's/^/    /'

    if (( run_rc == 0 )); then
        echo "PASS  $rel"
        passed=$((passed + 1))
    else
        echo "FAIL  $rel (exit $run_rc)"
        failed=$((failed + 1))
    fi
done

echo "----------------------------------------"
echo "specs: ${#spec_files[@]}  passed: $passed  failed: $failed"

if (( failed > 0 )); then
    exit 1
fi
exit 0
