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

--- 提取 <p> 段落数组（用于网页正文抽取）
-- @param region HTML 片段
-- @param drop_keywords 命中的段落会被丢弃（广告等）
function htmltext.paragraphs(region, drop_keywords)
    local paras = {}
    for block in region:gmatch("<p[^>]*>(.-)</p>") do
        -- 干掉脚本/样式
        block = block:gsub("<script[^>]*>.-</script>", "")
        block = block:gsub("<style[^>]*>.-</style>", "")
        local text = htmltext.to_text(block)
        local drop = false
        for _, kw in ipairs(drop_keywords or {}) do
            if text:find(kw, 1, true) then
                drop = true
                break
            end
        end
        if not drop and #text >= 10 then
            paras[#paras + 1] = text
        end
    end
    return paras
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
    -- 协议相对地址补全
    if url:sub(1, 2) == "//" then
        url = "https:" .. url
    end
    -- 去掉查询参数里的缩放指令会丢尺寸，保留原样（KOReader 自行缩放）
    return url
end

--- 提取有序内容块：{ text= } 与 { img=url }
-- 用于把正文按“文字-图片”顺序渲染到 EPUB。
-- @param html HTML 片段（可含转义或 CDATA）
-- @param drop_keywords 命中即丢弃的关键词
-- @return 块数组
function htmltext.blocks(html, drop_keywords)
    if not html or html == "" then return {} end
    html = html:gsub("<!%[CDATA%[", ""):gsub("%]%]>", "")
    html = util.htmlEntitiesToUtf8(html)
    local blocks = {}
    local any_p = false
    for block in html:gmatch("<p[^>]*>(.-)</p>") do
        any_p = true
        block = block:gsub("<script[^>]*>.-</script>", "")
        local text = htmltext.to_text(block)
        local drop = false
        for _, kw in ipairs(drop_keywords or {}) do
            if text:find(kw, 1, true) then
                drop = true
                break
            end
        end
        if not drop then
            if #text >= 10 then
                blocks[#blocks + 1] = { text = text }
            end
            for tag in block:gmatch("<img[^>]*>") do
                local url = img_src(tag)
                if url then
                    blocks[#blocks + 1] = { img = url }
                end
            end
        end
    end
    if not any_p then
        -- 无 <p> 结构：整体转文本 + 收集图片
        local text = htmltext.to_text(html)
        if #text >= 10 then
            blocks[#blocks + 1] = { text = text }
        end
        for tag in html:gmatch("<img[^>]*>") do
            local url = img_src(tag)
            if url then
                blocks[#blocks + 1] = { img = url }
            end
        end
    end
    return blocks
end

return htmltext
