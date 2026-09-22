-- spec/favorites_spec.lua — 收藏模块（favorites.lua）纯逻辑单元测试
--
-- 重点：二级目录的小节定位与切分（section_index / section_article）——
-- 「收藏整篇文章还是子文章」依赖的两个纯函数。
-- KOReader 运行时依赖（datastorage / lfs / logger / http 栈 / dump）在此打桩，
-- 不触碰磁盘、不发网络请求。
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/favorites_spec.lua）
-- 不依赖任何测试框架；所有断言通过时退出码为 0，否则为 1。

local spec_dir = (arg and arg[0] or "spec/favorites_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = spec_dir .. "/../technews.koplugin"

package.preload["datastorage"] = function()
    return { getDataDir = function() return "/tmp/technews-favorites-spec" end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function() return nil end,
        mkdir = function() return false end,
    }
end
package.preload["logger"] = function()
    return {
        info = function() end, warn = function() end,
        dbg = function() end, err = function() end,
    }
end
package.preload["dump"] = function() return function() return "" end end
package.preload["ltn12"] = function() return {} end
package.preload["socket"] = function() return { sleep = function() end } end
package.preload["ssl.https"] = function() return {} end
package.preload["socketutil"] = function() return {} end
package.path = plugin_dir .. "/?.lua;" .. package.path
local favorites = require("technews.favorites")

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

----------------------------------------------------------------------
-- 样本：一条带 3 个小标题的早报式文章（收尾各带正文与图片）
----------------------------------------------------------------------

local item = {
    title = "早报｜示例",
    link = "https://example.com/post/1",
    source_name = "爱范儿",
    blocks = {
        { text = "开场白。" },                       -- 小节之前：属整篇
        { text = "条目一标题", kind = "heading" },   -- 小节 1
        { text = "条目一正文。" },
        { img = "https://example.com/a.jpg" },
        { text = "条目二标题", kind = "heading" },   -- 小节 2
        { text = "条目二正文甲。" },
        { text = "条目二正文乙。" },
        { text = "条目三标题", kind = "heading" },   -- 小节 3
        { text = "条目三正文。" },
    },
}

----------------------------------------------------------------------
-- section_index：小标题序号（1 起）
----------------------------------------------------------------------

do
    eq(favorites.section_index(item, "条目一标题"), 1, "section_index：第 1 个小标题")
    eq(favorites.section_index(item, "条目二标题"), 2, "section_index：第 2 个小标题")
    eq(favorites.section_index(item, "条目三标题"), 3, "section_index：第 3 个小标题")
    eq(favorites.section_index(item, "开场白。"), nil, "section_index：非小标题文本不命中")
    eq(favorites.section_index(item, "不存在的标题"), nil, "section_index：无匹配返回 nil")
    eq(favorites.section_index(nil, "条目一标题"), nil, "section_index：item 缺失返回 nil")
    eq(favorites.section_index({ title = "无块" }, "条目一标题"), nil,
        "section_index：无 blocks 的文章返回 nil")
end

----------------------------------------------------------------------
-- section_article：切出子文章（标题 / 继承字段 / 段落范围）
----------------------------------------------------------------------

do
    local sub2 = favorites.section_article(item, 2)
    ok(sub2 ~= nil, "section_article：第 2 小节可切出")
    eq(sub2.title, "条目二标题", "小节标题 = 小标题文本")
    eq(sub2.link, item.link, "子文章继承整篇的原文链接")
    eq(sub2.source_name, item.source_name, "子文章继承来源名")
    eq(#sub2.blocks, 2, "第 2 小节含 2 个正文块")
    eq(sub2.blocks[1].text, "条目二正文甲。", "第 2 小节首块正确")
    eq(sub2.blocks[2].text, "条目二正文乙。", "第 2 小节次块正确")
end

do
    local sub1 = favorites.section_article(item, 1)
    eq(#sub1.blocks, 2, "第 1 小节含正文与图片 2 块")
    eq(sub1.blocks[2].img, "https://example.com/a.jpg", "第 1 小节的图片块被切出")
end

do
    local sub3 = favorites.section_article(item, 3)
    eq(#sub3.blocks, 1, "最后一个小节切到文章末尾")
    eq(sub3.blocks[1].text, "条目三正文。", "最后一个小节的正文正确")
end

do
    eq(favorites.section_article(item, 0), nil, "section_article：序号 0 返回 nil")
    eq(favorites.section_article(item, 99), nil, "section_article：越界序号返回 nil")
    eq(favorites.section_article(item, nil), nil, "section_article：序号缺失返回 nil")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
