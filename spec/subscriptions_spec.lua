-- spec/subscriptions_spec.lua — technews 订阅源启用集合逻辑的单元测试
--
-- 语义：setting == nil → 用适配器的 default_enabled；
--       setting 为表   → 只有 setting[id] == true 才算启用（空表 = 全部停用）。
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/subscriptions_spec.lua）
-- 不依赖任何测试框架；所有断言通过时退出码为 0，否则为 1。

-- 以脚本自身路径定位被测模块，保证从任意工作目录运行都成立
local spec_dir = (arg and arg[0] or "spec/subscriptions_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local subscriptions = dofile(spec_dir .. "/../technews.koplugin/technews/subscriptions.lua")

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

-- 比较启用源 id 序列，用于校验集合内容及其顺序
local function eq_ids(actual, expected, name)
    local same = #actual == #expected
    if same then
        for i = 1, #expected do
            if actual[i].id ~= expected[i] then same = false break end
        end
    end
    local function join(ids) return "{" .. table.concat(ids, ", ") .. "}" end
    local actual_ids, expected_ids = {}, {}
    for i, adapter in ipairs(actual) do actual_ids[i] = adapter.id end
    for i, id in ipairs(expected) do expected_ids[i] = id end
    ok(same, name, ("expected=%s actual=%s"):format(join(expected_ids), join(actual_ids)))
end

-- 构造测试用适配器；default_enabled 省略即"默认不启用"
local function adapter(id, default_enabled)
    return { id = id, name = id, default_enabled = default_enabled }
end

-- 顺序故意打乱（test_b 在 test_a 前），用于校验结果顺序取自 registry 而非设置表
local registry = {
    adapter("test_b", true),
    adapter("test_a", true),
    adapter("test_off", nil),
}

----------------------------------------------------------------------
-- setting == nil：使用 default_enabled
----------------------------------------------------------------------
do
    eq_ids(subscriptions.enabled(registry, nil), { "test_b", "test_a" },
        "nil 设置只返回 default_enabled 的源，且保持 registry 顺序")
    eq(subscriptions.is_enabled(registry[1], nil), true,
        "default_enabled = true 的源在 nil 设置下启用")
    eq(subscriptions.is_enabled(registry[3], nil), false,
        "default_enabled 为 nil 的源在 nil 设置下停用")
    eq(subscriptions.any_enabled(registry, nil), true,
        "默认有启用源时 any_enabled 为 true")
end

----------------------------------------------------------------------
-- 显式设置：只认 setting[id] == true（默认启用也会被显式排除）
----------------------------------------------------------------------
do
    eq_ids(subscriptions.enabled(registry, { test_a = true }), { "test_a" },
        "显式设置只返回被勾选的源（default_enabled 不再生效）")
    eq(subscriptions.is_enabled(registry[1], { test_a = true }), false,
        "不在设置表中的默认启用源被停用")
    eq(subscriptions.any_enabled(registry, { test_a = true }), true,
        "显式设置选中一项时 any_enabled 为 true")
end

----------------------------------------------------------------------
-- 显式设置：结果顺序取自 registry，而不是设置表的键序
----------------------------------------------------------------------
do
    local setting = { test_off = true, test_b = true } -- 键序 b 在 off 之后
    eq_ids(subscriptions.enabled(registry, setting), { "test_b", "test_off" },
        "启用源按 registry 顺序返回（test_b 在 test_off 之前）")
end

----------------------------------------------------------------------
-- 空表 = 全部停用
----------------------------------------------------------------------
do
    eq(#subscriptions.enabled(registry, {}), 0, "空设置表返回空列表")
    eq(subscriptions.is_enabled(registry[1], {}), false,
        "空设置表下默认启用源也不启用")
    eq(subscriptions.any_enabled(registry, {}), false,
        "空设置表下 any_enabled 为 false")
end

----------------------------------------------------------------------
-- 显式 false / 非 true 值不算启用
----------------------------------------------------------------------
do
    eq(#subscriptions.enabled(registry, { test_a = false }), 0,
        "setting[id] = false 不算启用")
    eq(#subscriptions.enabled(registry, { test_a = 1 }), 0,
        "setting[id] 非 true（如 1）不算启用")
end

----------------------------------------------------------------------
-- is_enabled：显式选中一个默认停用的源
----------------------------------------------------------------------
do
    eq(subscriptions.is_enabled(registry[3], { test_off = true }), true,
        "显式选中时默认停用的源变为启用")
    eq(subscriptions.is_enabled(registry[2], { test_off = true }), false,
        "未选中的源在显式设置下停用")
end

----------------------------------------------------------------------
-- any_enabled：空 registry 与全部默认停用
----------------------------------------------------------------------
do
    eq(subscriptions.any_enabled({}, nil), false, "空 registry 时 any_enabled 为 false")
    local off_registry = { adapter("only_off", nil), adapter("also_off", false) }
    eq(subscriptions.any_enabled(off_registry, nil), false,
        "全部默认停用（nil / false）时 any_enabled 为 false")
    eq(subscriptions.any_enabled(off_registry, { also_off = true }), true,
        "显式选中任一源后 any_enabled 为 true")
end

----------------------------------------------------------------------
-- to_set：由 id 数组构造集合表
----------------------------------------------------------------------
do
    local set = subscriptions.to_set({ "x", "y" })
    eq(set.x, true, "to_set 生成的集合含 x")
    eq(set.y, true, "to_set 生成的集合含 y")
    eq(set.z, nil, "to_set 生成的集合不含未列出的 z")
    local count = 0
    for _ in pairs(set) do count = count + 1 end
    eq(count, 2, "to_set 生成的集合键数与输入数组长度一致")

    local empty = subscriptions.to_set({})
    local empty_count = 0
    for _ in pairs(empty) do empty_count = empty_count + 1 end
    eq(empty_count, 0, "to_set({}) 为空集合")

    -- 与 enabled 配合：显式选择只含 test_a
    local round_trip = subscriptions.to_set({ "test_a" })
    eq_ids(subscriptions.enabled(registry, round_trip), { "test_a" },
        "to_set 结果可直接作为 setting 传给 enabled")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
