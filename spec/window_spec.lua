-- spec/window_spec.lua — technews「今日窗口」过滤逻辑的单元测试
--
-- 严格语义：只取本地今日 0 点起的条目，不回补旧条目（2026-09-20 起）。
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/window_spec.lua）
-- 不依赖任何测试框架；所有断言通过时退出码为 0，否则为 1。

-- 以脚本自身路径定位被测模块，保证从任意工作目录运行都成立
local spec_dir = (arg and arg[0] or "spec/window_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local window = dofile(spec_dir .. "/../technews.koplugin/technews/window.lua")

----------------------------------------------------------------------
-- 极简断言工具
----------------------------------------------------------------------

local checks, failed = 0, 0

local function ok(cond, name, detail)
    checks = checks + 1
    if cond then
        print(("%d ok - %s"):format(checks, name))
    else
        failed = failed + 1
        print(("%d not ok - %s"):format(checks, name))
        if detail then print("    # " .. detail) end
    end
end

local function eq(actual, expected, name)
    ok(actual == expected, name,
        ("expected=%s actual=%s"):format(tostring(expected), tostring(actual)))
end

-- 比较条目 id 序列，用于校验过滤结果及其排序
local function eq_ids(actual, expected, name)
    local same = #actual == #expected
    if same then
        for i = 1, #expected do
            if actual[i].id ~= expected[i] then same = false break end
        end
    end
    local function join(ids) return "{" .. table.concat(ids, ", ") .. "}" end
    local actual_ids, expected_ids = {}, {}
    for i, it in ipairs(actual) do actual_ids[i] = it.id end
    for i, id in ipairs(expected) do expected_ids[i] = id end
    ok(same, name, ("expected=%s actual=%s"):format(join(expected_ids), join(actual_ids)))
end

-- 用 ts 构造条目；ts 为 nil 时表示"无时间戳（视为今日）"
local function item(ts, id)
    return { ts = ts, id = id or tostring(ts) }
end

-- 统计结果中位于本地 0 点之前的条目数（严格模式下应恒为 0）
local function count_older(items, midnight)
    local n = 0
    for _, it in ipairs(items) do
        if it.ts and it.ts < midnight then n = n + 1 end
    end
    return n
end

-- 相对本地 0 点的偏移量，构造与当前时刻无关的确定性测试数据
local midnight = window.local_midnight_ts()

----------------------------------------------------------------------
-- local_midnight_ts()
----------------------------------------------------------------------
do
    local expected = os.time{
        year = tonumber(os.date("%Y")),
        month = tonumber(os.date("%m")),
        day = tonumber(os.date("%d")),
        hour = 0, min = 0, sec = 0,
    }
    eq(window.local_midnight_ts(), expected, "local_midnight_ts 等于本地今日 00:00:00")
    ok(window.local_midnight_ts() <= os.time(), "local_midnight_ts <= os.time()")
    local parts = os.date("*t", window.local_midnight_ts())
    ok(parts.hour == 0 and parts.min == 0 and parts.sec == 0,
        "local_midnight_ts 的时分秒均为 0")
end

----------------------------------------------------------------------
-- 全部为今日条目：只返回今日条目，按 ts 倒序
----------------------------------------------------------------------
do
    local items = {
        item(midnight + 3600, "a"),
        item(midnight + 7200, "b"),
        item(midnight + 1800, "c"),
    }
    local selected, n_today = window.filter(items, 10)
    eq(n_today, 3, "全部为今日条目时 n_today 等于今日条数")
    eq(#selected, 3, "全部为今日条目时全部返回")
    eq_ids(selected, { "b", "a", "c" }, "今日条目按 ts 倒序返回")
end

----------------------------------------------------------------------
-- 严格模式：今日只有 2 条时也不回补旧条目
----------------------------------------------------------------------
do
    local items = {
        item(midnight + 120, "t1"),
        item(midnight + 60, "t2"),
    }
    for i = 1, 10 do items[#items + 1] = item(midnight - i * 600, "o" .. i) end
    local selected, n_today = window.filter(items, 100)
    eq(n_today, 2, "严格模式 n_today 只统计今日条目")
    eq(#selected, 2, "今日只有 2 条、旧条目有 10 条时结果仍为 2 条（不回补）")
    eq_ids(selected, { "t1", "t2" }, "结果只含今日条目且按 ts 倒序")
    eq(count_older(selected, midnight), 0, "结果中不含任何 0 点之前的旧条目")
end

----------------------------------------------------------------------
-- 严格模式：完全没有今日条目时不回补，返回空
----------------------------------------------------------------------
do
    local items = {}
    for i = 1, 10 do items[i] = item(midnight - i * 600, "o" .. i) end
    local selected, n_today = window.filter(items, 100)
    eq(#selected, 0, "只有旧条目时返回空列表（不回补）")
    eq(n_today, 0, "只有旧条目时 n_today = 0")
end

----------------------------------------------------------------------
-- 边界：ts 恰好等于本地 0 点算今日；0 点前 1 秒被排除
----------------------------------------------------------------------
do
    local m = window.local_midnight_ts() -- 紧邻调用前取值，避免跨午夜时用到过期值
    local items = { item(m, "exact"), item(m - 1, "just_before"), item(m + 1, "just_after") }
    local selected, n_today = window.filter(items, 10)
    eq(n_today, 2, "恰好 0 点算今日，0 点前 1 秒不算")
    eq_ids(selected, { "just_after", "exact" }, "恰好 0 点的条目被选中，前 1 秒被排除")
end

----------------------------------------------------------------------
-- 无 ts 的条目视为今日
----------------------------------------------------------------------
do
    local items = {
        item(midnight + 60, "t1"),
        item(nil, "no_ts"), -- 无 ts：视为最新（今日）
        item(midnight - 60, "old"),
    }
    local selected, n_today = window.filter(items, 10)
    eq(n_today, 2, "无 ts 的条目计入今日条数")
    eq_ids(selected, { "t1", "no_ts" }, "无 ts 条目进入今日集合（排序值视作 0，位于最后）")
    eq(count_older(selected, midnight), 0, "旧条目被排除")
end

----------------------------------------------------------------------
-- 混合排序：有 ts 的今日条目在前，无 ts 的条目在后
----------------------------------------------------------------------
do
    local items = {
        item(nil, "n1"),
        item(midnight + 60, "t1"),
        item(nil, "n2"),
        item(midnight + 120, "t2"),
    }
    local selected, n_today = window.filter(items, 10)
    eq(n_today, 4, "有 ts 与无 ts 的今日条目都计入 n_today")
    eq_ids({ selected[1], selected[2] }, { "t2", "t1" }, "有 ts 条目按 ts 倒序排在最前")
    ok(selected[3].ts == nil and selected[4].ts == nil,
        "无 ts 条目排在有 ts 条目之后",
        ("ids=%s,%s"):format(selected[3].id, selected[4].id))
end

----------------------------------------------------------------------
-- max_items 截断（截断只发生在今日集合内）
----------------------------------------------------------------------
do
    local items = {}
    for i = 1, 5 do items[i] = item(midnight + i * 60, "t" .. i) end
    local selected, n_today = window.filter(items, 3)
    eq(#selected, 3, "可用条目多于 max_items 时按 max_items 截断")
    eq(n_today, 5, "截断后 n_today 仍为未截断的今日条数")
    eq_ids(selected, { "t5", "t4", "t3" }, "截断保留最新的 max_items 条")

    -- 混入旧条目时也只截断今日条目，旧条目不会顶上
    local mixed = { item(midnight + 60, "t1"), item(midnight + 30, "t2") }
    for i = 1, 10 do mixed[#mixed + 1] = item(midnight - i * 600, "o" .. i) end
    selected, n_today = window.filter(mixed, 1)
    eq(#selected, 1, "有旧条目时截断仍只作用于今日集合")
    eq(n_today, 2, "截断后 n_today 不受影响")
    eq_ids(selected, { "t1" }, "截断保留最新的今日条目")
end

----------------------------------------------------------------------
-- 空输入
----------------------------------------------------------------------
do
    local selected, n_today = window.filter({}, 10)
    eq(#selected, 0, "空输入返回空列表")
    eq(n_today, 0, "空输入 n_today = 0")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
