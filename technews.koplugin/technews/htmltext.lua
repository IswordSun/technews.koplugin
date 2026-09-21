-- technews/htmltext.lua — HTML 文本转换（RSS 描述、网页正文共用）
--
-- 处理两种常见输入：
--   1. RSS 里被 XML 转义的 HTML（&lt;p&gt;…）→ 先解实体再去标签
--   2. 网页里原生的 HTML（<p>…）→ 直接去标签
-- 统一用 util.htmlEntitiesToUtf8 解码（支持命名实体与数字实体）。

local util = require("util")

local htmltext = {}

-- HTML 片段 → 纯文本（段落转换为换行）
function htmltext.to_text(raw)
    if not raw or raw == "" then return "" end
    -- 去 CDATA 包装
    raw = raw:gsub("<!%[CDATA%[", ""):gsub("%]%]>", "")
    -- 先解一层实体：把被转义的 HTML 还原成真实标签
    local text = util.htmlEntitiesToUtf8(raw)
    -- 块级元素转换行
    text = text:gsub("<br%s*/?>", "\n")
    text = text:gsub("<%s*/%s*p%s*>", "\n")
    text = text:gsub("<%s*p[^>]*>", "\n")
    text = text:gsub("<%s*/%s*div%s*>", "\n")
    text = text:gsub("<%s*div[^>]*>", "\n")
    -- 去残留标签
    text = text:gsub("<[^>]*>", "")
    -- 再解一层：正文内的实体
    text = util.htmlEntitiesToUtf8(text)
    -- 空白整理：行内多空格压成一个，行首行尾去空
    text = text:gsub("[ \t]+", " ")
    text = text:gsub("\n%s+", "\n")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

-- 从 <img> 标签里取真实图片地址（兼容懒加载的 data-original / data-src）
local function img_src(tag)
    local url = tag:match('data%-original="([^"]+)"')
        or tag:match('data%-src="([^"]+)"')
        or tag:match('src="([^"]+)"')
    if not url or url == "" then return nil end
    if url:sub(1, 5) == "data:" then return nil end
    -- 跳过占位图
    if url:find("/v2/t.png", 1, true) then return nil end
    -- 跳过 WordPress 表情图片（s.w.org …/images/core/emoji/…，ifanr 内联表情噪音）
    if url:find("/images/core/emoji/", 1, true) then return nil end
    -- 跳过 sspai 评论头像缩略图（thumbnail/!32x32r 与 /avatar/ 是评论噪音，非正文配图）
    if url:find("thumbnail/!32x32r", 1, true) then return nil end
    if url:find("/avatar/", 1, true) then return nil end
    -- 协议相对地址补全
    if url:sub(1, 2) == "//" then
        url = "https:" .. url
    end
    -- 去掉查询参数里的缩放指令会丢尺寸，保留原样（KOReader 自行缩放）
    return url
end

-- 用 find 循环收集同一模式的标签片段，记录字节区间 [s, e]（可含捕获）
local function find_spans(html, pattern)
    local spans, pos = {}, 1
    while true do
        local s, e, inner = html:find(pattern, pos)
        if not s then break end
        spans[#spans + 1] = { s = s, e = e, inner = inner }
        pos = e + 1
    end
    return spans
end

-- 标签 [s, e] 是否完全落在 span 内部（用于判断图片属于哪个容器）
local function contained(span, s, e)
    return s > span.s and e < span.e
end

-- 命中任一 drop 关键词即整块丢弃（段落 / 标题 / 列表项 / 图注共用）
local function dropped(text, drop_keywords)
    for _, kw in ipairs(drop_keywords or {}) do
        if text:find(kw, 1, true) then return true end
    end
    return false
end

-- 容器内容 → 纯文本：先剥离 <script>/<style> 噪音，再走公共转换
local function inner_text(inner)
    return htmltext.to_text(
        (inner:gsub("<script[^>]*>.-</script>", ""):gsub("<style[^>]*>.-</style>", "")))
end

--- 提取有序内容块：{ text= } / { text=, kind= } 与 { img=url }
-- 用于把正文按“文字-图片”顺序渲染到 EPUB。
-- 文本块 kind：heading（h2/h3/h4 小标题）、bullet（<li> 列表项）、caption（<figcaption> 图注）；
-- 普通段落不带 kind（保持 v2 语义）。
-- 图片来源：<p> 内（原有逻辑）、<figure> 内（少数派风格）、以及不在任何
-- <p>/<figure> 内的独立 <img>；全部按源码位置排序、同一张图只收录一次。
-- @param html HTML 片段（可含转义或 CDATA）
-- @param drop_keywords 命中即丢弃的关键词（作用于文本块，段落命中时连带丢弃段内图片）
-- @return 块数组
function htmltext.blocks(html, drop_keywords)
    if not html or html == "" then return {} end
    html = html:gsub("<!%[CDATA%[", ""):gsub("%]%]>", "")
    html = util.htmlEntitiesToUtf8(html)

    local p_spans = find_spans(html, "<p[^>]*>(.-)</p>")
    local f_spans = find_spans(html, "<figure[^>]*>(.-)</figure>")
    local h2_spans = find_spans(html, "<h2[^>]*>(.-)</h2>")
    local h3_spans = find_spans(html, "<h3[^>]*>(.-)</h3>")
    local h4_spans = find_spans(html, "<h4[^>]*>(.-)</h4>")
    local li_spans = find_spans(html, "<li[^>]*>(.-)</li>")
    local cap_spans = find_spans(html, "<figcaption[^>]*>(.-)</figcaption>")
    local imgs = find_spans(html, "(<img[^>]*>)")
    for _, img in ipairs(imgs) do img.tag = img.inner end

    -- 没有任何可解析的 <p>…</p> 段落时，沿用旧版兜底：整体转文本 + 收集全部图片
    if #p_spans == 0 then
        local blocks = {}
        local text = htmltext.to_text(html)
        if #text >= 10 then
            blocks[#blocks + 1] = { text = text }
        end
        for _, img in ipairs(imgs) do
            local url = img_src(img.tag)
            if url then
                blocks[#blocks + 1] = { img = url }
            end
        end
        return blocks
    end

    -- 候选块：文本取容器标签起点位置，图片取自身位置，最后统一按位置排序即可还原文档顺序
    local items = {}
    local function push(pos, kind, value)
        items[#items + 1] = { pos = pos, kind = kind, value = value }
    end

    for _, span in ipairs(p_spans) do
        local inner = span.inner:gsub("<script[^>]*>.-</script>", "")
        local text = htmltext.to_text(inner)
        if not dropped(text, drop_keywords) then
            if #text >= 10 then
                push(span.s, "text", text)
            end
            for _, img in ipairs(imgs) do
                if contained(span, img.s, img.e) then
                    local url = img_src(img.tag)
                    if url then push(img.s, "img", url) end
                end
            end
        end
    end

    -- 小标题：不适用 <10 字节的段落规则，只要有文本就收录（drop 关键词照常生效）
    for _, spans in ipairs({ h2_spans, h3_spans, h4_spans }) do
        for _, span in ipairs(spans) do
            local text = inner_text(span.inner)
            if text ~= "" and not dropped(text, drop_keywords) then
                push(span.s, "heading", text)
            end
        end
    end

    -- 列表项：内含 <p> 的整项跳过（其段落已由 <p> 路径收集，避免正文重复）
    for _, span in ipairs(li_spans) do
        if not span.inner:find("<p[%s>]") then
            local text = inner_text(span.inner)
            if #text >= 10 and not dropped(text, drop_keywords) then
                push(span.s, "bullet", text)
            end
        end
    end

    -- 图注：与段落同规则（>=10 字节 + drop 关键词）
    for _, span in ipairs(cap_spans) do
        local text = inner_text(span.inner)
        if #text >= 10 and not dropped(text, drop_keywords) then
            push(span.s, "caption", text)
        end
    end

    for _, span in ipairs(f_spans) do
        for _, img in ipairs(imgs) do
            if contained(span, img.s, img.e) then
                local url = img_src(img.tag)
                if url then push(img.s, "img", url) end
            end
        end
    end

    -- 独立图片：不属于任何 <p>/<figure>
    for _, img in ipairs(imgs) do
        local covered = false
        for _, span in ipairs(p_spans) do
            if contained(span, img.s, img.e) then covered = true break end
        end
        if not covered then
            for _, span in ipairs(f_spans) do
                if contained(span, img.s, img.e) then covered = true break end
            end
        end
        if not covered then
            local url = img_src(img.tag)
            if url then push(img.s, "img", url) end
        end
    end

    table.sort(items, function(a, b) return a.pos < b.pos end)

    -- 依次产出；嵌套容器（如 <figure> 内嵌 <p>）可能让同一张图入列两次，按位置去重
    local blocks, seen_img = {}, {}
    for _, it in ipairs(items) do
        if it.kind == "img" then
            if not seen_img[it.pos] then
                seen_img[it.pos] = true
                blocks[#blocks + 1] = { img = it.value }
            end
        elseif it.kind == "text" then
            blocks[#blocks + 1] = { text = it.value }
        else
            blocks[#blocks + 1] = { text = it.value, kind = it.kind }
        end
    end
    return blocks
end

return htmltext
