-- spec/extract_spec.lua — technews 网页正文抽取（extract.lua）的单元测试
--
-- 重点：多起始标记（starts）按序取首个命中并支持回退、旧接口 start 仍可用、
-- ends 取最早出现者、max_len 兜底窗口、drop 关键词过滤、空区域返回 nil。
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/extract_spec.lua）
-- 不依赖任何测试框架；所有断言通过时退出码为 0，否则为 1。
--
-- extract.lua → technews.htmltext → require("util")（KOReader 运行时模块），
-- 这里用 package.preload 给 util 打桩；桩不做实体解码，故样例一律不含实体。

local spec_dir = (arg and arg[0] or "spec/extract_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = spec_dir .. "/../technews.koplugin"
package.preload["util"] = function() return { htmlEntitiesToUtf8 = function(s) return s end } end
package.path = plugin_dir .. "/?.lua;" .. package.path
local extract = require("technews.extract")

----------------------------------------------------------------------
-- 极简断言工具（与其它 spec 保持一致）
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

local function contains(text, needle, name)
    ok(type(text) == "string" and text:find(needle, 1, true) ~= nil, name,
        ("needle=%s text=%s"):format(needle, tostring(text)))
end

local function not_contains(text, needle, name)
    ok(type(text) == "string" and text:find(needle, 1, true) == nil, name,
        ("unexpected needle=%s text=%s"):format(needle, tostring(text)))
end

-- 第 i 个文本块的文字；越界或 blocks 为 nil 时返回 nil
local function text_at(blocks, i)
    local b = blocks and blocks[i]
    return b and b.text or nil
end

-- blocks 为 nil 时按 0 计，避免断言自身报错
local function n_blocks(blocks)
    return blocks and #blocks or 0
end

----------------------------------------------------------------------
-- starts：按序取首个命中的候选；其前内容排除、其后内容包含
----------------------------------------------------------------------
do
    local html = table.concat({
        '<p>BEFORE_ALL 起始标记之前的段落。</p>',
        '<div class="start-a">',
        '<p>AFTER_A 标记 A 之后的段落。</p>',
        '<div class="start-b">',
        '<p>AFTER_B 标记 B 之后的段落。</p>',
        '</div>',
    })
    local blocks = extract.blocks(html, {
        starts = { '<div class="start-a">', '<div class="start-b">' },
        ends = { '</section>' },
    })
    eq(n_blocks(blocks), 2, "starts 命中首个候选：切出 2 个文本块")
    contains(text_at(blocks, 1), "AFTER_A", "首块来自标记 A 之后")
    contains(text_at(blocks, 2), "AFTER_B", "标记 B 之后的内容仍被包含")
    not_contains(text_at(blocks, 1), "BEFORE_ALL", "标记 A 之前的内容被排除")
end

----------------------------------------------------------------------
-- starts：首个候选缺席时回退到第二个
----------------------------------------------------------------------
do
    local html = '<p>BEFORE 应被排除。</p><div class="start-b"><p>SECOND_USED 第二个候选生效。</p></div>'
    local blocks = extract.blocks(html, {
        starts = { '<div class="start-a">', '<div class="start-b">' },
    })
    eq(n_blocks(blocks), 1, "首个候选缺席时回退第二个：1 个文本块")
    contains(text_at(blocks, 1), "SECOND_USED", "内容来自第二个候选之后")
    not_contains(text_at(blocks, 1), "BEFORE", "候选之前的内容不进入结果")
end

----------------------------------------------------------------------
-- starts：全部候选未命中（及 starts 为空表）时返回 nil
----------------------------------------------------------------------
do
    local html = '<p>ONLY_CONTENT 没有任何起始标记的页面。</p>'
    eq(extract.blocks(html, { starts = { '<div class="start-a">' } }), nil,
        "候选均未命中且无 start：返回 nil")
    eq(extract.blocks(html, { starts = {} }), nil,
        "starts 为空表且无 start：返回 nil")
end

----------------------------------------------------------------------
-- 旧接口 start：单独使用时行为不变
----------------------------------------------------------------------
do
    local html = '<p>BEFORE 旧接口之前的段落。</p><div class="legacy"><p>LEGACY_OK 旧接口 start 仍生效。</p></div>'
    local blocks = extract.blocks(html, {
        start = '<div class="legacy">',
        ends = { '</div>' },
    })
    eq(n_blocks(blocks), 1, "旧接口 start：1 个文本块")
    contains(text_at(blocks, 1), "LEGACY_OK", "旧接口 start 正常定位正文")
end

----------------------------------------------------------------------
-- ends：多个候选时取最早出现者（与列表顺序无关）
----------------------------------------------------------------------
do
    local html = table.concat({
        '<div class="start-a">',
        '<p>KEEP_BEFORE_END 结束标记之前的段落。</p>',
        '<div class="end-early">',
        '<p>CUT_BY_EARLY 更早结束标记之后应被截断。</p>',
        '<div class="end-late">',
        '<p>CUT_BY_LATE 更晚结束标记之后也应被截断。</p>',
    })
    local blocks = extract.blocks(html, {
        starts = { '<div class="start-a">' },
        ends = { '<div class="end-late">', '<div class="end-early">' },
    })
    eq(n_blocks(blocks), 1, "ends 命中最早出现者：只切出 1 个文本块")
    contains(text_at(blocks, 1), "KEEP_BEFORE_END", "最早结束标记之前的内容保留")
    not_contains(text_at(blocks, 1), "CUT_BY_EARLY", "更早结束标记之后的内容被截断")
end

----------------------------------------------------------------------
-- max_len：无结束标记命中时窗口截断
----------------------------------------------------------------------
do
    local html = table.concat({
        '<div class="start-a">',
        '<p>INSIDE_WINDOW 窗口内的段落。</p>',
        string.rep('<span>填充填充填充填充填充填充填充填充</span>', 20),
        '<p>OUTSIDE_WINDOW 超出 max_len 的段落。</p>',
    })
    local blocks = extract.blocks(html, {
        starts = { '<div class="start-a">' },
        ends = { '<div class="never-matches">' },
        max_len = 120,
    })
    eq(n_blocks(blocks), 1, "max_len 截断：窗口内只切出 1 个文本块")
    contains(text_at(blocks, 1), "INSIDE_WINDOW", "窗口内段落保留")
    not_contains(text_at(blocks, 1), "OUTSIDE_WINDOW", "窗口外段落被截断")
end

----------------------------------------------------------------------
-- drop：命中关键词的段落被过滤
----------------------------------------------------------------------
do
    local html = table.concat({
        '<div class="start-a">',
        '<p>DROP_ME_KEYWORD 这是应被过滤的推广段落。</p>',
        '<p>KEEP_ME 这是应保留的正文段落。</p>',
    })
    local blocks = extract.blocks(html, {
        starts = { '<div class="start-a">' },
        drop = { "DROP_ME_KEYWORD" },
    })
    eq(n_blocks(blocks), 1, "drop 命中：推广段被丢弃，只剩 1 块")
    contains(text_at(blocks, 1), "KEEP_ME", "未被 drop 命中的段落保留")
    not_contains(text_at(blocks, 1), "DROP_ME_KEYWORD", "drop 段落不出现在结果中")
end

----------------------------------------------------------------------
-- strip：剥离 [from .. 其后最早的 to) 区块；多处命中时重复剥离
----------------------------------------------------------------------
do
    local html = table.concat({
        '<div class="start-a">',
        '<p>KEEP_HEAD 剥离点之前的内容保留。</p>',
        '<div class="comment__list">',
        '<p>DROP_ONE 第一段评论区内容应被剥离。</p>',
        '</div>',
        '<div class="item-next">',
        '<p>KEEP_MID 首段正文保留。</p>',
        '<div class="comment__list">',
        '<p>DROP_TWO 第二段评论区内容也应被剥离。</p>',
        '</div>',
        '<div class="item-next">',
        '<p>KEEP_TAIL 尾部正文保留。</p>',
        '</div>',
    })
    local blocks = extract.blocks(html, {
        starts = { '<div class="start-a">' },
        strip = { { from = '<div class="comment__list"', to = { '<div class="item-next">' } } },
    })
    eq(n_blocks(blocks), 3, "strip 剥离两处中段：保留 3 个文本块")
    contains(text_at(blocks, 1), "KEEP_HEAD", "from 之前的内容保留")
    contains(text_at(blocks, 2), "KEEP_MID", "两处剥离点之间的正文保留")
    contains(text_at(blocks, 3), "KEEP_TAIL", "末尾正文保留")
    not_contains(text_at(blocks, 1) .. text_at(blocks, 2) .. text_at(blocks, 3),
        "DROP_ONE", "第一段评论区内容被剥离")
    not_contains(text_at(blocks, 1) .. text_at(blocks, 2) .. text_at(blocks, 3),
        "DROP_TWO", "第二段评论区内容被剥离")
end

----------------------------------------------------------------------
-- strip：to 全部未命中时删到区域末尾
----------------------------------------------------------------------
do
    local html = table.concat({
        '<div class="start-a">',
        '<p>KEEP_HEAD 剥离点之前的内容保留。</p>',
        '<div class="comment__list">',
        '<p>DROP_REST 无 to 命中时应删到区域末尾。</p>',
    })
    local blocks = extract.blocks(html, {
        starts = { '<div class="start-a">' },
        strip = { { from = '<div class="comment__list"', to = { '<div class="never-matches">' } } },
    })
    eq(n_blocks(blocks), 1, "strip 无 to：只保留剥离点之前的 1 个文本块")
    contains(text_at(blocks, 1), "KEEP_HEAD", "剥离点之前的内容保留")
    not_contains(text_at(blocks, 1), "DROP_REST", "剥离点之后的内容全被删除")
end

----------------------------------------------------------------------
-- strip：规则未命中时内容原样保留
----------------------------------------------------------------------
do
    local html = table.concat({
        '<div class="start-a">',
        '<p>KEEP_ONE 规则未命中时内容原样保留。</p>',
        '<p>KEEP_TWO 第二段同样保留。</p>',
    })
    local blocks = extract.blocks(html, {
        starts = { '<div class="start-a">' },
        strip = { { from = '<div class="not-present"', to = { '</div>' } } },
    })
    eq(n_blocks(blocks), 2, "strip 未命中：2 个文本块原样保留")
    contains(text_at(blocks, 1), "KEEP_ONE", "首段未被误删")
    contains(text_at(blocks, 2), "KEEP_TWO", "次段未被误删")
end

----------------------------------------------------------------------
-- 区域切出但没有有效内容块时返回 nil
----------------------------------------------------------------------
do
    local html = '<div class="start-a"><span>短</span></div>'
    eq(extract.blocks(html, {
        starts = { '<div class="start-a">' },
        ends = { '</div>' },
    }), nil, "区域内无有效内容块：返回 nil")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
