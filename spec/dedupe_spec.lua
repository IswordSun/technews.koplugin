-- spec/dedupe_spec.lua — technews 跨源去重逻辑的单元测试
--
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/dedupe_spec.lua）
-- 不依赖任何测试框架；所有断言通过时退出码为 0，否则为 1。

-- 以脚本自身路径定位被测模块，保证从任意工作目录运行都成立
local spec_dir = (arg and arg[0] or "spec/dedupe_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local dedupe = dofile(spec_dir .. "/../technews.koplugin/technews/dedupe.lua")

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

-- 条目工厂：texts 为各文字块的字数（求和决定去重时保留谁）；nil 表示无 blocks
local function item(id, title, source, texts)
    local blocks
    if texts then
        blocks = {}
        for i, n in ipairs(texts) do
            blocks[i] = { text = string.rep("字", n) }
        end
    end
    return { id = id, title = title, source_id = source, blocks = blocks }
end

local function ids(items)
    local out = {}
    for i, it in ipairs(items) do out[i] = it.id end
    return "{" .. table.concat(out, ", ") .. "}"
end

local function eq_ids(actual, expected, name)
    local want = "{" .. table.concat(expected, ", ") .. "}"
    ok(ids(actual) == want, name,
        ("expected=%s actual=%s"):format(want, ids(actual)))
end

----------------------------------------------------------------------
-- 精确相同标题跨源：去重，保留正文更全者
----------------------------------------------------------------------
do
    local kept, removed = dedupe.filter{
        item("a", "苹果发布 iPhone 17", "ithome", { 10 }),
        item("b", "苹果发布 iPhone 17", "cnbeta", { 30 }),
    }
    eq(#kept, 1, "完全相同的标题跨源去重后只剩一条")
    eq_ids(kept, { "b" }, "完全相同的标题保留正文更全的一条")
    eq(#removed, 1, "removed 记录一条被丢弃的重复")
    eq(removed[1].kept.id, "b", "removed.kept 指向保留的条目")
    eq(removed[1].dropped.id, "a", "removed.dropped 指向被丢弃的条目")
end

----------------------------------------------------------------------
-- 仅标点/空白不同：归一化后判为重复
----------------------------------------------------------------------
do
    eq(dedupe.normalize("苹果 发布 iPhone 17！"), "苹果发布iphone17",
        "normalize 去掉空白与 ASCII/CJK 标点")
    eq(dedupe.normalize("“苹果”《发布》—iPhone…17、"), "苹果发布iphone17",
        "normalize 去掉引号/书名号/破折号等常见标点")

    local kept = dedupe.filter{
        item("a", "苹果发布 iPhone 17！", "ithome", { 10 }),
        item("b", "苹果 发布 iPhone17。", "cnbeta", { 20 }),
    }
    eq(#kept, 1, "仅标点/空白不同的标题跨源去重")
    eq_ids(kept, { "b" }, "标点差异的重复保留正文更全者")
end

----------------------------------------------------------------------
-- 轻微改写的近似标题：去重
----------------------------------------------------------------------
do
    -- 短标题中插 2 字（如 iPhone 17 → 正式版）Jaccard 约 0.78，与后缀延伸
    -- 场景（17 → 17 Pro）同档，无法区分；长标题的同类改写（插“正式”）为
    -- 0.85，属可判定的近逐字重复。
    local kept, removed = dedupe.filter{
        item("a", "苹果发布新款 MacBook Pro，起售价 12999 元", "ithome", { 10 }),
        item("b", "苹果正式发布新款 MacBook Pro，起售价 12999 元", "cnbeta", { 20 }),
    }
    eq(#kept, 1, "轻微改写的近似标题跨源去重")
    eq_ids(kept, { "b" }, "近似重复保留正文更全者")
    eq(#removed, 1, "近似重复场景记录一条 removed")

    local kept2 = dedupe.filter{
        item("c", "突发：苹果发布 iPhone 17", "ithome", { 10 }),
        item("d", "苹果发布 iPhone 17", "cnbeta", { 10 }),
    }
    eq(#kept2, 1, "加“突发：”前缀的同一标题跨源去重")
end

----------------------------------------------------------------------
-- 后缀延伸（不同新闻）：不去重
----------------------------------------------------------------------
do
    local a, b = "苹果发布 iPhone 17", "苹果发布 iPhone 17 Pro"
    local sim = dedupe.similarity(a, b)
    ok(sim < dedupe.THRESHOLD, "后缀延伸标题的相似度低于阈值",
        ("sim=%.4f threshold=%.2f"):format(sim, dedupe.THRESHOLD))
    ok(not dedupe.is_duplicate(a, b), "后缀延伸标题不判为重复")
    local kept, removed = dedupe.filter{
        item("a", a, "ithome", { 10 }),
        item("b", b, "cnbeta", { 10 }),
    }
    eq(#kept, 2, "iPhone 17 与 iPhone 17 Pro 是两个条目，不去重")
    eq(#removed, 0, "后缀延伸场景没有 removed")
end

----------------------------------------------------------------------
-- 不同新闻共享公共前缀：不去重
----------------------------------------------------------------------
do
    local kept = dedupe.filter{
        item("a", "华为发布 Mate 80 系列，搭载麒麟 9100", "ithome", { 10 }),
        item("b", "华为正式发布盘古大模型 5.0，面向行业客户", "cnbeta", { 10 }),
        item("c", "特斯拉 Model 3 宣布降价", "ithome", { 10 }),
        item("d", "特斯拉 Model Y 宣布降价", "cnbeta", { 10 }),
    }
    eq(#kept, 4, "仅共享前缀的不同新闻不去重（含相近的 Model 3/Y 对比）")
end

----------------------------------------------------------------------
-- 同源或缺失 source_id：不去重
----------------------------------------------------------------------
do
    local kept, removed = dedupe.filter{
        item("a1", "苹果发布 iPhone 17", "ithome", { 10 }),
        item("a2", "苹果发布 iPhone 17", "ithome", { 30 }),
    }
    eq(#kept, 2, "同源相同标题不去重（只跨源比较）")
    eq(#removed, 0, "同源不产生 removed")

    local kept2 = dedupe.filter{
        item("n1", "量子计算新突破", nil, { 10 }),
        item("n2", "量子计算新突破", "cnbeta", { 30 }),
        item("n3", "量子计算新突破", nil, { 40 }),
    }
    eq(#kept2, 3, "缺失 source_id 的条目不参与去重")
end

----------------------------------------------------------------------
-- 保留正文更全者（多块求和）；平局保留先出现者
----------------------------------------------------------------------
do
    local kept, removed = dedupe.filter{
        item("a", "英伟达发布新一代显卡", "ithome", { 10, 5 }),
        item("b", "英伟达发布新一代显卡", "cnbeta", { 20 }),
    }
    eq(#kept, 1, "重复条目只保留一条")
    eq_ids(kept, { "b" }, "多块文字量求和：20 > 10+5，保留后出现者")
    eq(removed[1].dropped.id, "a", "文字量更少的先出现者被丢弃")

    local kept2, removed2 = dedupe.filter{
        item("first", "SpaceX 星舰完成新试飞", "ithome", { 12 }),
        item("second", "SpaceX 星舰完成新试飞", "cnbeta", { 12 }),
    }
    eq(#kept2, 1, "正文量平局时仍去重")
    eq_ids(kept2, { "first" }, "平局保留先出现的条目")
    eq(removed2[1].dropped.id, "second", "平局时后出现者被丢弃")

    local kept3 = dedupe.filter{
        item("no_blocks", "OpenAI 发布新模型", "ithome", nil),
        item("has_blocks", "OpenAI 发布新模型", "cnbeta", { 1 }),
    }
    eq_ids(kept3, { "has_blocks" }, "blocks 缺失的条目文字量按 0 处理")
end

----------------------------------------------------------------------
-- 保持输入相对顺序；空/单条输入原样返回；removed 按丢弃顺序
----------------------------------------------------------------------
do
    local kept, removed = dedupe.filter{
        item("x", "量子计算取得新突破", "ithome", { 10 }),
        item("y", "英伟达发布新显卡", "cnbeta", { 10 }),
        item("x2", "量子计算取得新突破！", "cnbeta", { 30 }),
        item("z", "OpenAI 推出新模型", "ithome", { 10 }),
    }
    eq_ids(kept, { "y", "x2", "z" }, "去重后保留项保持输入相对顺序（x 被更全的 x2 替换）")
    eq(#removed, 1, "顺序场景记录一次去重")
    eq(removed[1].kept.id, "x2", "顺序场景保留正文更全的 x2")
    eq(removed[1].dropped.id, "x", "顺序场景丢弃 x")

    local empty, removed_empty = dedupe.filter({})
    eq(#empty, 0, "空输入返回空列表")
    eq(#removed_empty, 0, "空输入没有 removed")

    local one = item("solo", "单条不受影响", "ithome", { 5 })
    local kept1, removed1 = dedupe.filter{ one }
    eq(#kept1, 1, "单条输入原样返回")
    ok(kept1[1] == one, "单条输入保持同一对象")
    eq(#removed1, 0, "单条输入没有 removed")
end

do
    local _, removed = dedupe.filter{
        item("a", "重复标题一", "ithome", { 10 }),
        item("b", "重复标题二", "ithome", { 10 }),
        item("c", "重复标题一！", "cnbeta", { 5 }),
        item("d", "重复标题二！", "cnbeta", { 5 }),
    }
    eq(#removed, 2, "多组重复分别记录")
    eq(removed[1].dropped.id, "c", "removed 按丢弃顺序记录：先 c")
    eq(removed[2].dropped.id, "d", "removed 按丢弃顺序记录：后 d")
end

----------------------------------------------------------------------
-- near_misses：0.6~阈值之间的跨源标题对
----------------------------------------------------------------------
do
    local near = dedupe.near_misses({
        item("a", "苹果发布 iPhone 17", "ithome", { 10 }),
        item("b", "苹果发布 iPhone 17 Pro", "cnbeta", { 10 }),
    }, 0.6)
    eq(#near, 1, "near_misses 捕获 0.6~阈值之间的跨源标题对")
    ok(near[1].similarity >= 0.6 and near[1].similarity < dedupe.THRESHOLD,
        "near_misses 的相似度落在 [0.6, 阈值)")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
