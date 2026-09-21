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
-- }
-- @return 块数组 | nil
-- 多起始标记（starts）用于同一站点存在多套模板的情况（如少数派：普通文章
-- 与派早报的正文容器不同），逐个试到命中为止；均未命中返回 nil。
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
    local blocks = htmltext.blocks(region, opts.drop)
    if #blocks == 0 then return nil end
    return blocks
end

return extract
