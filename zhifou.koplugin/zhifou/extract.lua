-- zhifou/extract.lua — 网页正文抽取（容器定位 + <p> 段落过滤）

local htmltext = require("zhifou.htmltext")
local logger = require("logger")

local extract = {}

-- 退化守卫阈值：区域内可见文字 ≥ MIN_REGION_TEXT 字节，而抽出的正文文本
-- 不足其 MIN_KEEP_RATIO 时，判定「容器还在但正文没认出来」（站点改版常见），
-- 返回 nil 让调用方回退到 RSS 摘要——总比产出一篇只有标题的空壳文章强。
-- 阈值取 5%：实测各正文源的正常保留率在 15%~85%（少数派 85%、infoq 24%、
-- 快科技/9to5Mac 15~16%），真退化时接近 0，两边都留足余量
local MIN_REGION_TEXT = 500
local MIN_KEEP_RATIO = 0.05

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
-- 与派早报的正文容器不同），取页面中最靠前的命中；均未命中返回 nil。

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
    -- 候选起始标记取页面中「最靠前」的命中：多模板站点可能出现同类容器在后段
    -- 复现的情况（如少数派派早报：正文在前，文末推荐区又用了普通文章的容器），
    -- 按列表顺序取首个命中会抽到文末区块，把正文整段丢掉。
    local marker, marker_pos
    if type(opts.starts) == "table" and #opts.starts > 0 then
        for _, candidate in ipairs(opts.starts) do
            local p = html:find(candidate, 1, true)
            if p and (not marker_pos or p < marker_pos) then
                marker, marker_pos = candidate, p
            end
        end
    else
        marker = opts.start
        marker_pos = marker and html:find(marker, 1, true)
    end
    if not marker or not marker_pos then return nil end
    local start = marker_pos + #marker
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

    -- 退化守卫（见文件头注释）
    local kept_text = 0
    for _, block in ipairs(blocks) do
        if block.text then kept_text = kept_text + #block.text end
    end
    local region_text = #htmltext.to_text(region)
    if region_text >= MIN_REGION_TEXT and kept_text < region_text * MIN_KEEP_RATIO then
        logger.warn("zhifou extract degraded:",
            "kept=" .. kept_text, "of region_text=" .. region_text)
        return nil
    end
    return blocks
end

return extract
