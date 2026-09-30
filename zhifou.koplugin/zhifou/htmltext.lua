-- zhifou/htmltext.lua — HTML 文本转换（RSS 描述、网页正文共用）
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

--- 收集指定标签的成对区间 { s, e, inner }。
-- 为什么不用 `<p[^>]*>(.-)</p>` 这种写法：Lua 模式没有“标签名边界”，
-- `<p[^>]*>` 会把 <pre>/<param>/<picture> 一起匹配（p + re…），而一旦误匹配，
-- 区间会一路吞到后面某个 </p> —— 实测表现为「代码块导致其后整段正文丢失」。
-- <li[^>]*> 误吃 <link>、<tr[^>]*> 误吃 <track>、<t[dh][^>]*> 误吃 <thead> 同理。
local function spans_of(html, name)
    local spans, pos = {}, 1
    local open_pattern = "<" .. name .. "[%s>]"
    local close_tag = "</" .. name .. ">"
    while true do
        local s = html:find(open_pattern, pos)
        if not s then break end
        local tag_end = html:find(">", s, true)
        if not tag_end then break end
        local close_s, close_e = html:find(close_tag, tag_end + 1, true)
        if not close_s then break end
        spans[#spans + 1] = {
            s = s, e = close_e, inner = html:sub(tag_end + 1, close_s - 1),
        }
        pos = close_e + 1
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

-- 单行文本的显示宽度（中日韩全角按 2 列算，用于表格列对齐）。
-- 注意：KOReader 的 LuaJIT **没有** utf8 库（`utf8` 是 nil），只能用 util 的助手，
-- 它们内部走 ffi/utf8proc。
local function display_width(text)
    if text == "" then return 0 end
    local width = 0
    for _, char in ipairs(util.splitToChars(text)) do
        if util.isCJKChar(char) then
            width = width + 2
        else
            width = width + 1
        end
    end
    return width
end

-- 按显示宽度补空格（表格列对齐）
local function pad_right(text, width)
    local gap = width - display_width(text)
    if gap <= 0 then return text end
    return text .. string.rep(" ", gap)
end

--- 代码块内容 → 文本：保留换行与缩进，只去标签与首尾空行
local function code_text(inner)
    local text = inner
        :gsub("<br%s*/?>", "\n")
        :gsub("<[^>]*>", "")            -- <code>/<span class="hljs-..."> 等着色标签
    text = util.htmlEntitiesToUtf8(text)
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[ \t]+\n", "\n")          -- 行尾空白
    text = text:gsub("^\n+", ""):gsub("\n+$", "") -- 首尾空行
    return text
end

--- 表格 → 行/单元格（单元格文本保留人工换行）
-- 设计取舍：博客园等站点用「单列大表格」当正文容器，此时按行输出反而更易读；
-- 真正的多列表格才按列对齐成等宽表格。判据 = 单行最多几个非空单元格。
local function table_rows(inner)
    local rows = {}
    for _, row in ipairs(spans_of(inner, "tr")) do
        local row_html = row.inner
        -- 单元格：<td> 与 <th> 按出现顺序合并
        local cell_spans = {}
        for _, kind in ipairs({ "td", "th" }) do
            for _, cell in ipairs(spans_of(row_html, kind)) do
                cell_spans[#cell_spans + 1] = cell
            end
        end
        table.sort(cell_spans, function(a, b) return a.s < b.s end)
        local cells = {}
        for _, cell in ipairs(cell_spans) do
            local cell_html = cell.inner
            local text = cell_html
                :gsub("<br%s*/?>", "\n")
                :gsub("<[^>]*>", " ")
            text = util.htmlEntitiesToUtf8(text)
            text = text:gsub("[ \t]+", " "):gsub(" *\n *", "\n")
            text = text:gsub("^[ \n]+", ""):gsub("[ \n]+$", "")
            cells[#cells + 1] = text
        end
        local nonempty = 0
        for _, c in ipairs(cells) do
            if c ~= "" then nonempty = nonempty + 1 end
        end
        if nonempty > 0 then
            rows[#rows + 1] = { cells = cells, nonempty = nonempty }
        end
    end
    return rows
end

--- 把表格渲染成等宽文本（多列时列对齐；单列时就是普通的逐行文本）
local function table_to_lines(rows)
    local max_cols = 0
    for _, row in ipairs(rows) do
        if #row.cells > max_cols then max_cols = #row.cells end
    end
    local widths = {}
    for col = 1, max_cols do
        local w = 0
        for _, row in ipairs(rows) do
            local cell = row.cells[col]
            if cell and not cell:find("\n", 1, true) then
                local cw = display_width(cell)
                if cw > w then w = cw end
            end
        end
        widths[col] = math.min(w, 40)
    end
    local lines = {}
    for _, row in ipairs(rows) do
        if max_cols <= 1 then
            -- 单列：当作普通段落（博客园的正文容器就是这个形态）
            local text = row.cells[1] or ""
            if text ~= "" then lines[#lines + 1] = text end
        else
            local parts = {}
            for col = 1, #row.cells do
                local cell = row.cells[col]
                if cell and cell ~= "" then
                    parts[#parts + 1] = pad_right(cell, widths[col])
                end
            end
            local line = table.concat(parts, "  ")
            line = line:gsub("[ ]+$", "")
            if line ~= "" then lines[#lines + 1] = line end
        end
    end
    return lines, max_cols
end

--- 去掉整块噪音容器（脚本/样式/导航/页眉页脚/侧栏/表单/评论区）
-- 自定义源没有站点特调，只能靠这些通用规则先把明显的非正文摘掉。
local NOISE_TAGS = { "script", "style", "nav", "header", "footer", "aside", "form", "noscript" }

function htmltext.strip_noise(html)
    if not html or html == "" then return "" end
    local out = html
    for _, tag in ipairs(NOISE_TAGS) do
        local spans = spans_of(out, tag)
        -- 从后往前删，避免前面的删除影响后面的偏移
        for i = #spans, 1, -1 do
            local span = spans[i]
            out = out:sub(1, span.s - 1) .. out:sub(span.e + 1)
        end
    end
    return out
end

--- 猜正文容器：在 <article> 与 class/id 带正文关键词的 <div>/<section> 里，
-- 选「段落文字总量」最大的那个。找不到像样的容器时返回 nil，由调用方决定兜底。
-- @return 区间文本，或 nil
function htmltext.main_region(html, min_chars)
    if not html or html == "" then return nil end
    min_chars = min_chars or 300
    local candidates = {}
    local function consider(spans, tag)
        for _, span in ipairs(spans) do
            candidates[#candidates + 1] = { span = span, tag = tag }
        end
    end
    consider(spans_of(html, "article"), "article")
    consider(spans_of(html, "main"), "main")
    -- div/section：只认 class/id 里带关键词的（否则整页 wrapper 总是最大）
    for _, tag in ipairs({ "div", "section" }) do
        for _, span in ipairs(spans_of(html, tag)) do
            local head = html:sub(span.s, math.min(span.s + 200, span.e))
            local open_tag = head:match("^<[^>]*>") or ""
            local marker = open_tag:lower()
            if marker:find("content", 1, true) or marker:find("article", 1, true)
                or marker:find("post", 1, true) or marker:find("entry", 1, true)
                or marker:find("main", 1, true) or marker:find("body", 1, true)
                or marker:find("正文", 1, true) then
                candidates[#candidates + 1] = { span = span, tag = tag }
            end
        end
    end

    local best, best_score = nil, 0
    for _, candidate in ipairs(candidates) do
        local inner = htmltext.strip_noise(candidate.span.inner)
        local chars = 0
        local paragraphs = 0
        for _, p in ipairs(spans_of(inner, "p")) do
            local text = htmltext.to_text(p.inner)
            chars = chars + #text
            if #text >= 20 then paragraphs = paragraphs + 1 end
        end
        -- 至少要有两段、总字数达标，否则不算「像正文」
        local score = chars + paragraphs * 50
        if paragraphs >= 2 and chars >= min_chars and score > best_score then
            best, best_score = candidate.span.inner, score
        end
    end
    return best
end

--- 通用样板文关键词：整块命中即丢弃。
-- 只放「几乎不可能出现在正文里」的固定短语，避免误伤（例如「广告」这种词不放，
-- 因为文章本身可能就在讲广告；这里用的是完整短语）。
htmltext.DEFAULT_BOILERPLATE = {
    "扫码关注", "关注公众号", "下载客户端", "客户端下载", "下载 App", "下载APP",
    "转载请注明", "版权声明", "版权所有", "相关阅读", "责任编辑", "投稿邮箱",
    "广告合作", "点击查看更多", "点击查看全文", "解锁全新阅读体验",
    "更多精彩内容", "本文由", "原文链接：", "本文地址：",
}

--- 自适应内容块：先猜正文容器，猜不到就用整页（去掉噪音容器）
-- 供没有站点特调的源（自定义源）使用；样板文关键词与调用方给的关键词合并。
function htmltext.auto_blocks(html, drop_keywords)
    if not html or html == "" then return {} end
    local region = htmltext.main_region(html) or htmltext.strip_noise(html)
    local merged = {}
    for _, kw in ipairs(htmltext.DEFAULT_BOILERPLATE) do merged[#merged + 1] = kw end
    for _, kw in ipairs(drop_keywords or {}) do merged[#merged + 1] = kw end
    return htmltext.blocks(region, merged)
end

--- 提取有序内容块：{ text= } / { text=, kind= } 与 { img=url }
-- 用于把正文按“文字-图片”顺序渲染到 EPUB。
-- 文本块 kind：heading（h2/h3/h4 小标题）、bullet（<li> 列表项）、caption（<figcaption> 图注）；
-- 普通段落不带 kind（保持 v2 语义）。
-- 图片来源：<p> 内（原有逻辑）、<figure> 内（少数派风格）、以及不在任何
-- <p>/<figure> 内的独立 <img>；全部按源码位置排序、同一张图只收录一次。
-- @param html HTML 片段（可含转义或 CDATA）
-- @param drop_keywords 命中即丢弃的关键词（作用于文本块，段落命中时连带丢弃段内图片；
--        图片 URL 命中时同样丢弃，用于兜底评论头像 / 表情类社区图）
-- @return 块数组
function htmltext.blocks(html, drop_keywords)
    if not html or html == "" then return {} end
    html = html:gsub("<!%[CDATA%[", ""):gsub("%]%]>", "")
    html = util.htmlEntitiesToUtf8(html)

    local p_spans = spans_of(html, "p")
    local f_spans = spans_of(html, "figure")
    local h2_spans = spans_of(html, "h2")
    local h3_spans = spans_of(html, "h3")
    local h4_spans = spans_of(html, "h4")
    local li_spans = spans_of(html, "li")
    local cap_spans = spans_of(html, "figcaption")
    -- 2026-09-30 补：代码块 / 表格 / 引用块此前**整块丢失**（它们不在 <p> 里）。
    -- 实测博客园某篇文章正文 8.4KB 全在 <table> 中 → 产出 0 字（正文基本没抓到）。
    local pre_spans = spans_of(html, "pre")
    local table_spans = spans_of(html, "table")
    local quote_spans = spans_of(html, "blockquote")
    local imgs = find_spans(html, "(<img[^>]*>)")
    for _, img in ipairs(imgs) do img.tag = img.inner end

    -- 没有任何可解析的 <p>…</p> 段落、也没有代码/表格时，沿用旧版兜底：整体转文本 + 收集全部图片
    if #p_spans == 0 and #pre_spans == 0 and #table_spans == 0 then
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
    local push_seq = 0
    local function push(pos, kind, value)
        push_seq = push_seq + 1
        items[#items + 1] = { pos = pos, kind = kind, value = value, seq = push_seq }
    end

    -- <pre> 内部的段落/图片一律不重复产出（代码块整体由 pre 块承载）
    local function in_pre(span)
        for _, pre in ipairs(pre_spans) do
            if contained(pre, span.s, span.e) then return true end
        end
        return false
    end

    local p_text_set = {}
    for _, span in ipairs(p_spans) do
        local inner = span.inner:gsub("<script[^>]*>.-</script>", "")
        local text = htmltext.to_text(inner)
        p_text_set[text] = true
        -- 代码块内的 <p> 不单独产出（避免与 code 块重复）
        if not in_pre(span) and not dropped(text, drop_keywords) then
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

    -- 代码块：整体一个块，保留换行与缩进（epub 侧用等宽样式渲染）
    for _, span in ipairs(pre_spans) do
        local text = code_text(span.inner)
        if #text >= 10 and not dropped(text, drop_keywords) then
            push(span.s, "code", text)
        end
    end

    -- 表格：多列按显示宽度对齐成等宽表格；单列（博客园式正文容器）按行输出普通段落。
    -- 单元格文本若已被某个 <p> 收走就不再重复产出。
    for _, span in ipairs(table_spans) do
        local rows = table_rows(span.inner)
        local lines, cols = table_to_lines(rows)
        if cols > 1 then
            -- 多列表格：整表一个块（和多行代码块同理），保住行列对齐
            local kept = {}
            for _, line in ipairs(lines) do
                if #line >= 10 and not dropped(line, drop_keywords)
                    and not p_text_set[line] then
                    kept[#kept + 1] = line
                end
            end
            if #kept > 0 then
                push(span.s, "table", table.concat(kept, "\n"))
            end
        else
            -- 单列表格：按段落逐个产出（博客园等把正文装在单列大表格里）
            local seq = 0
            for _, line in ipairs(lines) do
                if #line >= 10 and not dropped(line, drop_keywords)
                    and not p_text_set[line] then
                    seq = seq + 1
                    push(span.s + seq * 0.01, "text", line)
                end
            end
        end
    end

    -- 引用块：内部有 <p> 时交给段落路径（那才是正文），否则整块作为引用产出
    for _, span in ipairs(quote_spans) do
        if not span.inner:find("<p[%s>]") then
            local text = inner_text(span.inner)
            if #text >= 10 and not dropped(text, drop_keywords) then
                push(span.s, "quote", text)
            end
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
        for _, span in ipairs(pre_spans) do
            if contained(span, img.s, img.e) then covered = true break end
        end
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

    table.sort(items, function(a, b)
        if a.pos ~= b.pos then return a.pos < b.pos end
        -- 同一位置可能有多块（表格逐行）：按插入顺序排，避免不稳定排序打乱行列
        return (a.seq or 0) < (b.seq or 0)
    end)

    -- 依次产出；嵌套容器（如 <figure> 内嵌 <p>）可能让同一张图入列两次，按位置去重
    local blocks, seen_img = {}, {}
    for _, it in ipairs(items) do
        if it.kind == "img" then
            -- 图片 URL 命中 drop 关键词同样丢弃（如少数派评论区残留的 community/ 头像与表情）
            if not seen_img[it.pos] and not dropped(it.value, drop_keywords) then
                seen_img[it.pos] = true
                blocks[#blocks + 1] = { img = it.value }
            end
        elseif it.kind == "text" or it.kind == nil then
            blocks[#blocks + 1] = { text = it.value }
        else
            -- heading / bullet / caption / code / table / quote
            blocks[#blocks + 1] = { text = it.value, kind = it.kind }
        end
    end
    return blocks
end

return htmltext
