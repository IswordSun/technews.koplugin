-- spec/window_spec.lua — technews「今日窗口」过滤逻辑的单元测试
--
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

-- 用 ts 构造条目；ts 为 nil 时表示"无时间戳（视为最新）"
local function item(ts, id)
    return { ts = ts, id = id or tostring(ts) }
end

-- 统计结果中位于本地 0 点之前的条目数（即回补条数）
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
        item(midnight - 60, "old"), -- 旧条目，今日已达 min_items，不应被回补
    }
    local selected, n_today = window.filter(items, 10, 3)
    eq(n_today, 3, "全部为今日条目时 n_today 等于今日条数")
    eq(#selected, 3, "今日条数达到 min_items 时只返回今日条目")
    eq_ids(selected, { "b", "a", "c" }, "今日条目按 ts 倒序返回")
end

----------------------------------------------------------------------
-- 今日不足 min_items：向前回补旧条目
----------------------------------------------------------------------
do
    local mixed = {
        item(midnight - 10800, "o3"),
        item(midnight + 120, "t1"),
        item(midnight - 3600, "o1"),
        item(midnight + 60, "t2"),
        item(midnight - 7200, "o2"),
        item(midnight - 14400, "o4"),
        item(midnight - 18000, "o5"),
    }
    local selected, n_today = window.filter(mixed, 100, 5)
    eq(n_today, 2, "回补场景中 n_today 只统计今日条目")
    eq(#selected, 5, "今日不足 min_items 且旧条目充足时回补到 min_items")
    eq_ids(selected, { "t1", "t2", "o1", "o2", "o3" }, "回补后整体仍按 ts 倒序")
end

----------------------------------------------------------------------
-- 回补恰好停在 min_items，不会多补
----------------------------------------------------------------------
do
    local items = {
        item(midnight + 30, "t1"),
        item(midnight + 20, "t2"),
        item(midnight + 10, "t3"),
    }
    for i = 1, 10 do items[#items + 1] = item(midnight - i * 600, "o" .. i) end
    local selected, n_today = window.filter(items, 100, 5)
    eq(#selected, 5, "回补恰好停在 min_items（3 今日 + 2 回补）")
    eq(n_today, 3, "回补后 n_today 仍为 3")
    eq(count_older(selected, midnight), 2, "只回补 min_items - n_today 条旧条目")

    -- 完全没有今日条目时同样精确回补
    local only_older = {}
    for i = 1, 10 do only_older[#only_older + 1] = item(midnight - i * 600, "x" .. i) end
    selected, n_today = window.filter(only_older, 100, 4)
    eq(#selected, 4, "无今日条目时回补恰好 min_items 条")
    eq(n_today, 0, "无今日条目时 n_today = 0")
    eq_ids(selected, { "x1", "x2", "x3", "x4" }, "回补的旧条目仍按 ts 倒序")
end

----------------------------------------------------------------------
-- max_items 截断
----------------------------------------------------------------------
do
    local items = {}
    for i = 1, 5 do items[i] = item(midnight + i * 60, "t" .. i) end
    local selected, n_today = window.filter(items, 3, 5)
    eq(#selected, 3, "可用条目多于 max_items 时按 max_items 截断")
    eq(n_today, 5, "截断后 n_today 仍为未截断的今日条数")
    eq_ids(selected, { "t5", "t4", "t3" }, "截断保留最新的 max_items 条")

    -- 截断发生在回补之后
    local mixed = {
        item(midnight + 60, "t1"),
        item(midnight - 60, "o1"),
        item(midnight - 120, "o2"),
        item(midnight - 180, "o3"),
    }
    selected, n_today = window.filter(mixed, 2, 4)
    eq(#selected, 2, "先回补到 min_items，再按 max_items 截断")
    eq(n_today, 1, "回补-截断场景 n_today 不受影响")
    eq_ids(selected, { "t1", "o1" }, "截断后保留最新条目")
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
    local selected, n_today = window.filter(items, 10, 2)
    eq(n_today, 2, "无 ts 的条目计入今日条数")
    eq(#selected, 2, "无 ts 条目计入今日后可满足 min_items，不再回补旧条目")
    -- 排序键 (ts or 0) 使无 ts 条目排在有 ts 的今日条目之后
    eq_ids(selected, { "t1", "no_ts" }, "无 ts 条目进入今日集合（排序值视作 0，位于最后）")
end

----------------------------------------------------------------------
-- ts 恰好等于本地 0 点：算作今日（边界含等号）
----------------------------------------------------------------------
do
    local m = window.local_midnight_ts() -- 紧邻调用前取值，避免跨午夜时用到过期值
    local items = { item(m, "exact"), item(m - 1, "just_before") }
    local selected, n_today = window.filter(items, 10, 1)
    eq(n_today, 1, "ts 恰好等于本地 0 点算作今日")
    eq_ids(selected, { "exact" }, "恰好 0 点的条目被选中，且不额外回补更旧条目")

    m = window.local_midnight_ts()
    items = { item(m, "exact"), item(m - 1, "just_before") }
    selected, n_today = window.filter(items, 10, 2)
    eq(n_today, 1, "边界条目仍只计 1 条今日")
    eq_ids(selected, { "exact", "just_before" }, "min_items=2 时前一天的条目被回补")
end

----------------------------------------------------------------------
-- 空输入
----------------------------------------------------------------------
do
    local selected, n_today = window.filter({}, 10, 12)
    eq(#selected, 0, "空输入返回空列表")
    eq(n_today, 0, "空输入 n_today = 0")

    selected, n_today = window.filter({}, 10)
    eq(#selected, 0, "空输入且省略 min_items 时仍返回空列表")
    eq(n_today, 0, "空输入且省略 min_items 时 n_today = 0")
end

----------------------------------------------------------------------
-- 省略 min_items 时默认值为 12
----------------------------------------------------------------------
do
    local items = { item(midnight + 60, "t1"), item(midnight + 30, "t2") }
    for i = 1, 20 do items[#items + 1] = item(midnight - i * 600, "o" .. i) end
    local selected, n_today = window.filter(items, 100)
    eq(#selected, 12, "省略 min_items 时默认回补到 12 条")
    eq(n_today, 2, "默认回补场景 n_today = 2")

    -- 今日条目已超过默认值时既不回补也不被默认值截断
    local many = {}
    for i = 1, 15 do many[i] = item(midnight + i * 60, "m" .. i) end
    selected, n_today = window.filter(many, 100)
    eq(#selected, 15, "今日条数超过默认 min_items 时不回补、不截断")
    eq(n_today, 15, "今日条数超过默认 min_items 时 n_today = 15")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
