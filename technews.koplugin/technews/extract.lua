-- technews/extract.lua — 网页正文抽取（容器定位 + <p> 段落过滤）

local htmltext = require("technews.htmltext")

local extract = {}

--- 从文章页 HTML 抽取内容块（文字 + 图片，保持顺序）。
-- @param html 页面 HTML
-- @param opts {
--     starts = { '<div class="a">', '<article class="b">' },  -- 候选正文起始标记（纯文本匹配，按序取首个命中）
--     start = '<div class="post_content " id="paragraph">',   -- 单一正文起始标记（旧接口，starts 缺席时使用）
--     ends  = { '<div class="related', ... },                 -- 结束标记（取最早出现）
--     max_len = 30000,                                        -- 兜底最大窗口
--     drop  = { 'adsbygoogle', ... },                         -- 命中即丢弃的广告关键词
--     strip = { { from = '<div class="comment__list"',        -- 剥离规则（纯文本匹配）：
--                 to = { '<div class="next-item' } } },       --   删除 [from .. 其后最早的 to)
-- }
-- @return 块数组 | nil
-- 多起始标记（starts）用于同一站点存在多套模板的情况（如少数派：普通文章
-- 与派早报的正文容器不同），逐个试到命中为止；均未命中返回 nil。

-- 按 strip 规则剥离区域内的内嵌区块（全部纯文本匹配）：
-- 反复定位 from，删除 [from .. 其后最早的 to)；若 to 一个都没命中，删到区域末尾。
-- 这样处理是因为有些站点会把评论区内嵌在正文中段（如少数派派早报的条目之间），
-- 不剥离的话，评论头像 / 表情图会被当作正文图片一并抽出。
local function apply_strip(region, rules)
    for _, rule in ipairs(rules) do
        local from, tos = rule.from, rule.to or {}
        if type(from) == "string" and from ~= "" then
            local p = region:find(from, 1, true)
            while p do
                local cut
                for _, marker in ipairs(tos) do
                    local q = region:find(marker, p + #from, true)
                    if q and (not cut or q < cut) then cut = q end
                end
                region = region:sub(1, p - 1) .. (cut and region:sub(cut) or "")
                p = region:find(from, 1, true)
            end
        end
    end
    return region
end

function extract.blocks(html, opts)
    if not html or type(opts) ~= "table" then return nil end
    local marker = opts.start
    if type(opts.starts) == "table" and #opts.starts > 0 then
        for _, s in ipairs(opts.starts) do
            if html:find(s, 1, true) then
                marker = s
                break
            end
        end
    end
    if not marker then return nil end
    local start = html:find(marker, 1, true)
    if not start then return nil end
    start = start + #marker
    local stop = start + (opts.max_len or 30000)
    for _, end_marker in ipairs(opts.ends or {}) do
        local p = html:find(end_marker, start, true)
        if p and p < stop then stop = p end
    end
    local region = html:sub(start, stop)
    if type(opts.strip) == "table" then
        region = apply_strip(region, opts.strip)
    end
    local blocks = htmltext.blocks(region, opts.drop)
    if #blocks == 0 then return nil end
    return blocks
end

return extract
