-- technews/extract.lua — 网页正文抽取（容器定位 + <p> 段落过滤）

local htmltext = require("technews.htmltext")

local extract = {}

--- 从文章页 HTML 抽取内容块（文字 + 图片，保持顺序）。
-- @param html 页面 HTML
-- @param opts {
--     start = '<div class="post_content " id="paragraph">',  -- 正文起始标记（纯文本匹配）
--     ends  = { '<div class="related', ... },                 -- 结束标记（取最早出现）
--     max_len = 30000,                                        -- 兜底最大窗口
--     drop  = { 'adsbygoogle', ... },                         -- 命中即丢弃的广告关键词
-- }
-- @return 块数组 | nil
function extract.blocks(html, opts)
    if not html or type(opts) ~= "table" then return nil end
    local start = html:find(opts.start, 1, true)
    if not start then return nil end
    start = start + #opts.start
    local stop = start + (opts.max_len or 30000)
    for _, marker in ipairs(opts.ends or {}) do
        local p = html:find(marker, start, true)
        if p and p < stop then stop = p end
    end
    local region = html:sub(start, stop)
    local blocks = htmltext.blocks(region, opts.drop)
    if #blocks == 0 then return nil end
    return blocks
end

--- 从文章页 HTML 抽取正文段落（纯文字）。
function extract.paragraphs(html, opts)
    if not html or type(opts) ~= "table" then return nil end
    local start = html:find(opts.start, 1, true)
    if not start then return nil end
    start = start + #opts.start
    local stop = start + (opts.max_len or 30000)
    for _, marker in ipairs(opts.ends or {}) do
        local p = html:find(marker, start, true)
        if p and p < stop then stop = p end
    end
    local region = html:sub(start, stop)
    local paras = htmltext.paragraphs(region, opts.drop)
    if #paras == 0 then return nil end
    return paras
end

return extract
