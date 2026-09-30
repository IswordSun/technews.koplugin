-- zhifou/epub.lua — 将一期资讯构造成 EPUB（KOReader 原生阅读器打开）
--
-- 最小 EPUB 3 实现：目录/概览页 + 每条资讯一个章节（无封面图片页；仅保留元数据封面供书架缩略图）。
-- ZIP 写入 + CRC32 参考 readhubdaily（已通过 unzip -t / xmllint 验证）。

local bit = require("bit")

local Epub = {}

local crc_table
local function crc32(data)
    if not crc_table then
        crc_table = {}
        for index = 0, 255 do
            local value = index
            for _ = 1, 8 do
                if bit.band(value, 1) == 1 then
                    value = bit.bxor(bit.rshift(value, 1), 0xEDB88320)
                else
                    value = bit.rshift(value, 1)
                end
            end
            crc_table[index] = value
        end
    end
    local value = 0xFFFFFFFF
    for index = 1, #data do
        value = bit.bxor(bit.rshift(value, 8),
            crc_table[bit.band(bit.bxor(value, data:byte(index)), 0xFF)])
    end
    return bit.bxor(value, 0xFFFFFFFF)
end

local function le16(number)
    return string.char(bit.band(number, 0xFF), bit.band(bit.rshift(number, 8), 0xFF))
end

local function le32(number)
    return string.char(
        bit.band(number, 0xFF), bit.band(bit.rshift(number, 8), 0xFF),
        bit.band(bit.rshift(number, 16), 0xFF), bit.band(bit.rshift(number, 24), 0xFF))
end

-- 写入失败时统一收尾：关闭句柄、删除临时文件，抛出含路径的错误
local function fail_write(file, temporary_path, err)
    file:close()
    os.remove(temporary_path)
    error(string.format("写入 EPUB 失败：%s（%s）", temporary_path, tostring(err)))
end

-- 流式写入 ZIP：逐条写本地头与数据，仅累积小的中央目录记录（含正确字节偏移），
-- 最后写中央目录与 EOCD。字节布局与旧版 make_zip 完全一致，只是不再整块驻留内存。
local function write_zip(entries, file, temporary_path)
    local central = {}
    local offset = 0
    for _, entry in ipairs(entries) do
        local name, data = entry.name, entry.data or ""
        local crc = crc32(data)
        local header = table.concat({
            le32(0x04034b50), le16(20), le16(0), le16(0), le16(0), le16(0),
            le32(crc), le32(#data), le32(#data), le16(#name), le16(0), name,
        })
        local wrote, werr = file:write(header)
        if not wrote then fail_write(file, temporary_path, werr) end
        wrote, werr = file:write(data)
        if not wrote then fail_write(file, temporary_path, werr) end
        central[#central + 1] = table.concat({
            le32(0x02014b50), le16(20), le16(20), le16(0), le16(0), le16(0),
            le16(0), le32(crc), le32(#data), le32(#data), le16(#name),
            le16(0), le16(0), le16(0), le16(0), le32(0), le32(offset), name,
        })
        offset = offset + #header + #data
    end
    local central_data = table.concat(central)
    local eocd = table.concat({
        le32(0x06054b50), le16(0), le16(0), le16(#entries), le16(#entries),
        le32(#central_data), le32(offset), le16(0),
    })
    local wrote, werr = file:write(central_data)
    if not wrote then fail_write(file, temporary_path, werr) end
    wrote, werr = file:write(eocd)
    if not wrote then fail_write(file, temporary_path, werr) end
end

local function escape(value)
    value = tostring(value or "")
    -- XML 1.0 不允许的控制字符（保留 \t \n \r）：源站偶发带进正文，
    -- 直接写进 xhtml 会让整篇成为非法 XML（xmllint 报 PCDATA invalid Char value）
    value = value:gsub("[%z\1-\8\11\12\14-\31]", "")
    value = value:gsub("&", "&amp;")
    value = value:gsub("<", "&lt;")
    value = value:gsub(">", "&gt;")
    return value:gsub('"', "&quot;")
end

-- 文本 → 段落 HTML（把正文按行拆成 <p>）
local function paragraphs_html(text)
    local output = {}
    for paragraph in tostring(text or ""):gmatch("[^\r\n]+") do
        if paragraph:match("%S") then
            output[#output + 1] = "<p>" .. escape(paragraph) .. "</p>"
        end
    end
    return table.concat(output, "\n")
end

-- 排版档位：段落密度（用户可在「设置 → 阅读排版」切换）
--   compact  紧凑：首行缩进、段间不空行（中文书常见）
--   standard 标准：缩进 + 段间 0.6em（默认）
--   loose    宽松：缩进 + 段间 1em、行距更大
local LAYOUTS = {
    compact = { para_margin = "0", line_height = "1.6", heading_top = "1em" },
    standard = { para_margin = "0.6em", line_height = "1.75", heading_top = "1.2em" },
    loose = { para_margin = "1em", line_height = "1.95", heading_top = "1.5em" },
}
-- 左右留白刻意压到 2%：KOReader 自身还有「页边距」设置，两边叠加会把正文挤窄
local PAGE_MARGIN = "2%"

--- 生成样式表（按排版档位）
local function build_css(layout)
    local L = LAYOUTS[layout] or LAYOUTS.standard
    return string.format([[
body { margin: 0 %s; line-height: %s; }
h1 { font-size: 1.55em; line-height: 1.35; margin: 0 0 0.45em; }
h2 { font-size: 1.25em; line-height: 1.4; margin: 0 0 0.65em; padding-bottom: 0.45em; border-bottom: 1px solid #777; }
h3 { font-size: 1.12em; line-height: 1.4; margin: %s 0 0.5em; }
p { margin: 0 0 %s; text-indent: 2em; }
p.meta { color: #666; font-size: 0.82em; text-indent: 0; margin: 0 0 2em; }
p.kicker { color: #666; font-size: 0.8em; text-indent: 0; margin: 0 0 0.4em; letter-spacing: 0.06em; }
p.link { color: #666; font-size: 0.8em; text-indent: 0; margin-top: 1.6em; word-break: break-all; }
p.bullet { text-indent: 0; margin-left: 1.2em; }
p.caption { color: #666; font-size: 0.85em; text-align: center; text-indent: 0; margin: 0.2em 0 1em; }
ol { margin: 0; padding-left: 1.5em; }
li { margin: 0 0 0.8em; line-height: 1.45; }
a { color: #1a4f8a; text-decoration: underline; }
span.src { color: #666; font-size: 0.85em; }
div.img { text-align: center; margin: 0.6em 0 0.8em; }
div.img img { max-width: 100%%; height: auto; }
/* 代码块：等宽 + 浅底 + 不缩进（保留原始换行与缩进，故用 pre 语义块） */
pre.code { font-family: monospace; font-size: 0.82em; line-height: 1.4;
    text-indent: 0; margin: 0.6em 0 1em; padding: 0.5em 0.6em;
    background-color: #f2f2f2; border-left: 2px solid #999; white-space: pre-wrap; }
/* 表格：列已按显示宽度对齐，等宽字体保证不散架 */
pre.table { font-family: monospace; font-size: 0.82em; line-height: 1.5;
    text-indent: 0; margin: 0.6em 0 1em; white-space: pre-wrap; }
/* 引用块：左侧竖线 + 灰字 */
blockquote.quote { margin: 0.6em 0 1em; padding: 0 0 0 0.8em;
    border-left: 3px solid #bbb; color: #444; text-indent: 0; }
]], PAGE_MARGIN, L.line_height, L.heading_top, L.para_margin)
end



local EXT_MEDIA = {
    jpg = "image/jpeg", jpeg = "image/jpeg",
    png = "image/png", gif = "image/gif", webp = "image/webp",
}

local function media_type(ext)
    return EXT_MEDIA[ext] or "image/jpeg"
end

local function xhtml(title, body)
    return [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head><title>]] .. escape(title) .. [[</title><link rel="stylesheet" type="text/css" href="../style.css"/></head>
<body>
]] .. body .. [[
</body></html>]]
end

-- 目录顺序 = 正文顺序（items 数组序）。此前合并期曾按来源分组，但分组顺序与
-- 正文顺序不一致（同源条目在时间轴上不连续）→ 页码非单调 → KOReader 的
-- validateAndFixToc 会把它当作坏目录"修复"，把正确页码改坏、目录跳转全错
-- （2026-09-22 实测：「(原页) 86」，子条目全跳到文章开头）。故一律平铺。

-- 二级目录只对"新闻聚合"类文章生成（早报/日报/周刊等，按标题关键词识别）；
-- 普通文章即便有多个小标题也不建（2026-09-24 按用户要求收窄）。
-- 注意 Lua 模式不支持 | 或分组量词，这里用关键词逐个 find 匹配。
local DIGEST_KEYWORDS = { "早报", "日报", "晚报", "午报", "周报", "周刊", "简讯", "盘点", "汇总" }
local function is_digest_title(title)
    for _, word in ipairs(DIGEST_KEYWORDS) do
        if title:find(word, 1, true) then return true end
    end
    return false
end

-- 目录条目标题：带来源标记（【来源】标题），便于在跳转目录里区分来源；
-- 无来源的条目（如「本期目录」）原样返回
local function toc_label(entry)
    if entry.source and entry.source ~= "" then
        return "【" .. entry.source .. "】" .. entry.title
    end
    return entry.title
end

-- 目录项 → nav 的 <li>；带 subs（文内小标题）时内嵌一层锚点 <ol>
local function nav_li(entry)
    local link = '<a href="text/' .. entry.href .. '">' .. escape(toc_label(entry)) .. "</a>"
    if not entry.subs then
        return "<li>" .. link .. "</li>"
    end
    local nested = { "<ol>" }
    for _, sub in ipairs(entry.subs) do
        nested[#nested + 1] = '<li><a href="text/' .. entry.href .. "#" .. sub.anchor .. '">'
            .. escape(sub.title) .. "</a></li>"
    end
    nested[#nested + 1] = "</ol>"
    return "<li>" .. link .. table.concat(nested, "\n") .. "</li>"
end

local function build_nav(toc)
    local items = { "<ol>" }
    for _, entry in ipairs(toc) do
        items[#items + 1] = nav_li(entry)
    end
    items[#items + 1] = "</ol>"
    return [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head><body><nav epub:type="toc">]]
        .. table.concat(items, "\n") .. "</nav></body></html>"
end

local function build_ncx(toc, identifier, title)
    local points = {}
    local sequence = 0
    -- 生成 navPoint 头（id/playOrder 按文档顺序递增），尾部由调用方补齐
    local function point_head(entry_title, entry_href, fragment)
        sequence = sequence + 1
        return string.format('<navPoint id="nav-%d" playOrder="%d">', sequence, sequence)
            .. "<navLabel><text>" .. escape(entry_title) .. "</text></navLabel>"
            .. '<content src="text/' .. entry_href
            .. (fragment and ("#" .. fragment) or "") .. '"/>'
    end
    -- 目录项 → navPoint；带 subs（文内小标题）时内嵌一层锚点子节点。
    -- 父节点的 id/playOrder 必须先分配：NCX 要求 playOrder 在文档流中递增，
    -- 先给子节点编号会出现「父 nav-4 内含 nav-2/nav-3」这种倒挂。
    local function entry_point(entry)
        local head = point_head(toc_label(entry), entry.href)
        if not entry.subs then
            return head .. "</navPoint>"
        end
        local children = {}
        for _, sub in ipairs(entry.subs) do
            children[#children + 1] = point_head(sub.title, entry.href, sub.anchor) .. "</navPoint>"
        end
        return head .. "\n" .. table.concat(children, "\n") .. "\n</navPoint>"
    end
    local depth = 1
    for _, entry in ipairs(toc) do
        points[#points + 1] = entry_point(entry)
        if entry.subs then
            depth = 2
        end
    end
    return [[<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head>
<meta name="dtb:uid" content="]] .. escape(identifier) .. [["/><meta name="dtb:depth" content="]] .. depth .. [["/>
</head><docTitle><text>]] .. escape(title) .. "</text></docTitle><navMap>"
        .. table.concat(points, "\n") .. "</navMap></ncx>"
end

--- 文件是否是一个写完整的 ZIP/EPUB：长度下限 + 结尾必须是 EOCD 记录。
-- 用途：写盘收尾自检，以及缓存命中前的判定——写盘中断（磁盘满/断电）会留下
-- 「文件存在但内容截断」的 EPUB，若当成有效缓存，阅读器会报 invalid document
-- 且永远不会自动重抓。本函数只读结尾 4 字节，开销可忽略。
function Epub.is_complete(path)
    local file = io.open(path, "rb")
    if not file then return false end
    local size = file:seek("end")
    -- 空 ZIP 也有 22 字节 EOCD；小于此值必定不完整
    if not size or size < 22 then
        file:close()
        return false
    end
    file:seek("set", size - 22)
    local tail = file:read(4)
    file:close()
    -- EOCD 签名 "PK\005\006"（本插件写出的包不带注释，EOCD 恒在末尾）
    return tail == "PK\005\006"
end

--- 构建一期 EPUB（含图片块）。
-- data = {
--   title = "知否 · 2026-09-16",
--   date  = "2026-09-16",
--   items = { { title=, source_name=, time=, summary=, blocks=, images=, link= }, ... },
-- }
--   layout = "compact"|"standard"|"loose"（排版档位，缺省 standard）
-- blocks = { { text= } | { text=, kind="heading"|"bullet"|"caption"|"code"|"table"|"quote" }
--            | { img=url }, ... }；
-- images = { [url] = { data=, ext= } }
function Epub.build(data, output_path)
    local date = assert(data and data.date, "missing issue date")
    local items = assert(data.items, "missing items")
    assert(#items > 0, "empty items")
    local title = data.title or ("知否 · " .. date)
    -- unique-identifier：同一天的合并期与各单源期、以及每篇收藏快照都必须互不相同，
    -- 否则阅读器书库会把它们当成同一本书（此前固定 "zhifou-<日期>"）。
    -- 调用方可传 data.identifier（如 issue_id）；缺省退化为「日期 + 构建时刻」。
    local identifier = data.identifier
        or string.format("zhifou-%s-%d", date, os.time())
    local toc = {}
    local chapters = {}
    local image_entries = {}
    local written_images = {}   -- url → 已写出的文件名（同一张图只存一份）
    local image_counter = 0

    -- 封面：取第一条有图的资讯的首张可用图片（收藏快照传 no_cover 跳过）
    local cover = nil
    if not data.no_cover then
        for _, item in ipairs(items) do
            if type(item.blocks) == "table" then
                for _, block in ipairs(item.blocks) do
                    if block.img and data.images and data.images[block.img] then
                        cover = data.images[block.img]
                        break
                    end
                end
            end
            if cover then break end
        end
    end

    -- 渲染一个内容块（文字或图片）；文字块按 kind 选择标签：
    -- heading → <h3>（文章标题已是 h2，章节内小标题降一级；anchor 供二级目录跳转）、
    -- bullet → p.bullet、caption → p.caption，无 kind（普通段落）保持原有 <p>。
    local function render_block(item, block, anchor)
        if block.text then
            if block.kind == "heading" then
                return "<h3" .. (anchor and (' id="' .. anchor .. '"') or "") .. ">"
                    .. escape(block.text) .. "</h3>"
            elseif block.kind == "bullet" then
                return '<p class="bullet">· ' .. escape(block.text) .. "</p>"
            elseif block.kind == "caption" then
                return '<p class="caption">' .. escape(block.text) .. "</p>"
            elseif block.kind == "code" then
                -- 保留原始换行/缩进：用 pre（crengine 支持 basic pre）
                return '<pre class="code">' .. escape(block.text) .. "</pre>"
            elseif block.kind == "table" then
                return '<pre class="table">' .. escape(block.text) .. "</pre>"
            elseif block.kind == "quote" then
                return '<blockquote class="quote">' .. escape(block.text) .. "</blockquote>"
            end
            return "<p>" .. escape(block.text) .. "</p>"
        elseif block.img then
            -- 图片优先从整期图片表取（跨条目去重），兼容条目内存储
            local image = (data.images and data.images[block.img])
                or (item.images and item.images[block.img])
            if image and image.data then
                -- 同一张图可能被多篇/多块引用：按 URL 复用已写出的文件，
                -- 否则下载只算一次、EPUB 里却存好几份（实测两篇引用同一图 = 两份同样字节）
                local name = written_images[block.img]
                if not name then
                    image_counter = image_counter + 1
                    name = string.format("img-%03d.%s",
                        image_counter, image.ext or "jpg")
                    written_images[block.img] = name
                    image_entries[#image_entries + 1] = {
                        name = "OEBPS/images/" .. name,
                        data = image.data,
                    }
                end
                return '<div class="img"><img src="../images/'
                    .. name .. '" alt=""/></div>'
            end
        end
        return nil
    end

    local overview = {
        "<p class=\"kicker\">知否 · 每日</p>",
        "<h1>" .. escape(title) .. "</h1>",
        "<p class=\"meta\">" .. #items .. " 条资讯 · 可从 KOReader 目录跳转</p>",
        "<ol>",
    }
    for index, item in ipairs(items) do
        local href = string.format("article-%03d.xhtml", index)
        local item_title = item.title or "（无标题）"
        overview[#overview + 1] = '<li>'
            .. (item.source_name and ('<span class="src">【' .. escape(item.source_name) .. '】</span> ') or "")
            .. '<a href="' .. href .. '">' .. escape(item_title) .. "</a></li>"

        local body_parts = {
            '<p class="kicker">'
                .. escape((item.source_name or "") .. " · " .. (item.time or date)
                    .. " · " .. index .. "/" .. #items)
            .. "</p>",
            "<h2>" .. escape(item_title) .. "</h2>",
        }
        -- 文内小标题（kind=heading）收作二级目录：≥2 条才挂进目录（单条只多一行
        -- 噪音），正文相应加锚点；无子目录的条目输出与从前完全一致
        local subs, heading_total = {}, 0
        if type(item.blocks) == "table" then
            for _, block in ipairs(item.blocks) do
                if block.text and block.kind == "heading" then
                    heading_total = heading_total + 1
                end
            end
        end
        -- 二级目录：仅"新闻聚合"类文章（早报/日报/周刊…）且小标题 ≥2 条时生成；
        -- 普通文章不加锚点、不建子目录
        local with_subs = heading_total >= 2 and is_digest_title(item_title)
        if type(item.blocks) == "table" and #item.blocks > 0 then
            for _, block in ipairs(item.blocks) do
                local anchor
                if with_subs and block.text and block.kind == "heading" then
                    anchor = "h" .. (#subs + 1)
                    subs[#subs + 1] = { title = block.text, anchor = anchor }
                end
                local html = render_block(item, block, anchor)
                if html then
                    body_parts[#body_parts + 1] = html
                end
            end
        elseif type(item.body) == "table" and #item.body > 0 then
            for _, p in ipairs(item.body) do
                body_parts[#body_parts + 1] = "<p>" .. escape(p) .. "</p>"
            end
        else
            body_parts[#body_parts + 1] = paragraphs_html(item.summary)
        end
        if item.link then
            body_parts[#body_parts + 1] = '<p class="link">原文：' .. escape(item.link) .. "</p>"
        end
        toc[#toc + 1] = {
            title = item_title, href = href,
            source = item.source_name,
            subs = with_subs and subs or nil,
        }
        chapters[#chapters + 1] = {
            href = href,
            title = item_title,
            body = xhtml(item_title, table.concat(body_parts, "\n")),
        }
    end
    overview[#overview + 1] = "</ol>"
    -- 目录/概览页（cover.xhtml）：收藏快照传 no_overview 跳过（打开即正文）
    if not data.no_overview then
        table.insert(toc, 1, { title = "本期目录", href = "cover.xhtml" })
        table.insert(chapters, 1, {
            href = "cover.xhtml",
            title = "本期目录",
            body = xhtml(title, table.concat(overview, "\n")),
        })
    end

    local manifest, spine, entries = {}, {}, {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = [[<?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]] },
        { name = "OEBPS/style.css", data = build_css(data.layout) },
        { name = "OEBPS/nav.xhtml", data = build_nav(toc) },
        { name = "OEBPS/toc.ncx", data = build_ncx(toc, identifier, title) },
    }
    for index, chapter in ipairs(chapters) do
        manifest[#manifest + 1] = string.format('<item id="ch%d" href="text/%s" media-type="application/xhtml+xml"/>', index, chapter.href)
        spine[#spine + 1] = string.format('<itemref idref="ch%d"/>', index)
        entries[#entries + 1] = { name = "OEBPS/text/" .. chapter.href, data = chapter.body }
    end
    -- 图片：写进 ZIP 的同时登记进 manifest（EPUB3 要求所有资源都在 manifest 声明；
    -- 此前只写文件不登记——epubcheck 报错，其它阅读器/转换链可能直接丢图）
    local cover_manifest_id
    for index, image in ipairs(image_entries) do
        local href = image.name:gsub("^OEBPS/", "")
        local ext = href:match("%.([%w]+)$") or "jpg"
        if not cover_manifest_id and cover and cover.data and image.data == cover.data then
            -- 封面就是从正文里挑的第一张图：内容相同就不再存第二份（省一张最大图），
            -- 直接把这一个 manifest 项标记为封面
            cover_manifest_id = "cover-image"
            manifest[#manifest + 1] = string.format(
                '<item id="cover-image" href="%s" media-type="%s" properties="cover-image"/>',
                href, media_type(ext))
        else
            manifest[#manifest + 1] = string.format(
                '<item id="img-%d" href="%s" media-type="%s"/>', index, href, media_type(ext))
        end
        entries[#entries + 1] = image
    end

    -- 封面：只留元数据封面（书架缩略图用），不生成封面页——打开即目录/概览页
    -- （2026-09-27 按用户要求去掉目录页前的封面图页）
    if cover and cover.data and not cover_manifest_id then
        local ext = cover.ext or "jpg"
        local cover_name = "cover." .. ext
        entries[#entries + 1] = {
            name = "OEBPS/images/" .. cover_name,
            data = cover.data,
        }
        manifest[#manifest + 1] = '<item id="cover-image" href="images/'
            .. cover_name .. '" media-type="' .. media_type(ext)
            .. '" properties="cover-image"/>'
        cover_manifest_id = "cover-image"
    end
    entries[#entries + 1] = { name = "OEBPS/content.opf", data = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">]] .. escape(identifier) .. "</dc:identifier><dc:title>" .. escape(title) .. [[</dc:title>
<dc:creator>Isword</dc:creator><dc:language>zh-CN</dc:language><dc:date>]] .. escape(date) .. [[</dc:date>
<meta property="dcterms:modified">]] .. os.date("!%Y-%m-%dT%H:%M:%SZ") .. [[</meta>
]] .. (cover_manifest_id and '<meta name="cover" content="cover-image"/>' or "") .. [[
</metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="style" href="style.css" media-type="text/css"/>
]] .. table.concat(manifest, "\n") .. "</manifest><spine toc=\"ncx\">" .. table.concat(spine, "\n") .. "</spine></package>" }

    local temporary_path = output_path .. ".part"
    local file, err = io.open(temporary_path, "wb")
    if not file then error(err) end
    write_zip(entries, file, temporary_path)
    -- 收尾必须检查返回值：stdio 有缓冲，磁盘满/配额不足只会在 flush/close 时暴露。
    -- 旧实现忽略 close 的返回值，于是被截断的 .part 照样改名成正式 EPUB，
    -- 之后被当成有效缓存打开（阅读器报 unsupported or invalid document）。
    local flushed, flush_err = file:flush()
    local closed, close_err = file:close()
    if not flushed or not closed then
        os.remove(temporary_path)
        error(string.format("写入 EPUB 失败：%s（%s）",
            temporary_path, tostring(flush_err or close_err)))
    end
    -- 结构自检：确认产物以 EOCD 结尾，挡住「没报错但写了一半」的截断文件
    if not Epub.is_complete(temporary_path) then
        os.remove(temporary_path)
        error(string.format("写入 EPUB 失败：%s（文件不完整）", temporary_path))
    end
    local renamed, rename_err = os.rename(temporary_path, output_path)
    if not renamed then
        os.remove(temporary_path)
        error(string.format("重命名 EPUB 失败：%s → %s（%s）",
            temporary_path, output_path, tostring(rename_err)))
    end
    return output_path
end

return Epub
