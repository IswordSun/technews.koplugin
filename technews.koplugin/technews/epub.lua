-- technews/epub.lua — 将一期资讯构造成 EPUB（KOReader 原生阅读器打开）
--
-- 最小 EPUB 3 实现：封面目录页 + 每条资讯一个章节。
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

local function make_zip(entries)
    local local_headers, central = {}, {}
    local offset = 0
    for _, entry in ipairs(entries) do
        local name, data = entry.name, entry.data or ""
        local crc = crc32(data)
        local header = table.concat({
            le32(0x04034b50), le16(20), le16(0), le16(0), le16(0), le16(0),
            le32(crc), le32(#data), le32(#data), le16(#name), le16(0), name,
        })
        local_headers[#local_headers + 1] = header
        local_headers[#local_headers + 1] = data
        central[#central + 1] = table.concat({
            le32(0x02014b50), le16(20), le16(20), le16(0), le16(0), le16(0),
            le16(0), le32(crc), le32(#data), le32(#data), le16(#name),
            le16(0), le16(0), le16(0), le16(0), le32(0), le32(offset), name,
        })
        offset = offset + #header + #data
    end
    local central_data = table.concat(central)
    return table.concat(local_headers) .. central_data .. table.concat({
        le32(0x06054b50), le16(0), le16(0), le16(#entries), le16(#entries),
        le32(#central_data), le32(offset), le16(0),
    })
end

local function escape(value)
    value = tostring(value or "")
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

local CSS = [[
body { margin: 0 5%; line-height: 1.75; }
h1 { font-size: 1.55em; line-height: 1.35; margin: 0 0 0.45em; }
h2 { font-size: 1.25em; line-height: 1.4; margin: 0 0 0.65em; padding-bottom: 0.45em; border-bottom: 1px solid #777; }
p { margin: 0 0 1em; text-indent: 2em; }
p.meta { color: #666; font-size: 0.82em; text-indent: 0; margin: 0 0 2em; }
p.kicker { color: #666; font-size: 0.8em; text-indent: 0; margin: 0 0 0.4em; letter-spacing: 0.06em; }
p.link { color: #666; font-size: 0.8em; text-indent: 0; margin-top: 1.6em; word-break: break-all; }
ol { margin: 0; padding-left: 1.5em; }
li { margin: 0 0 0.8em; line-height: 1.45; }
a { color: #222; text-decoration: none; }
span.src { color: #666; font-size: 0.85em; }
div.img { text-align: center; margin: 0.6em 0 1em; }
div.img img { max-width: 100%; }
div.cover { text-align: center; margin: 0; padding: 0; }
div.cover img { max-width: 100%; max-height: 100%; }
]]

local EXT_MEDIA = {
    jpg = "image/jpeg", jpeg = "image/jpeg",
    png = "image/png", gif = "image/gif", webp = "image/webp",
}

local function media_type(ext)
    return EXT_MEDIA[ext] or "image/jpeg"
end

local function coverpage_xhtml(image_href)
    return [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head><title>封面</title><link rel="stylesheet" type="text/css" href="../style.css"/></head>
<body><div class="cover"><img src="../images/]] .. image_href .. [[" alt="封面"/></div></body></html>]]
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

local function build_nav(toc)
    local items = { "<ol>" }
    for _, entry in ipairs(toc) do
        items[#items + 1] = '<li><a href="text/' .. entry.href .. '">'
            .. escape(entry.title) .. "</a></li>"
    end
    items[#items + 1] = "</ol>"
    return [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head><body><nav epub:type="toc">]]
        .. table.concat(items, "\n") .. "</nav></body></html>"
end

local function build_ncx(toc, identifier, title)
    local points = {}
    for index, entry in ipairs(toc) do
        points[#points + 1] = string.format('<navPoint id="nav-%d" playOrder="%d">', index, index)
            .. "<navLabel><text>" .. escape(entry.title) .. "</text></navLabel>"
            .. '<content src="text/' .. entry.href .. '"/></navPoint>'
    end
    return [[<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head>
<meta name="dtb:uid" content="]] .. escape(identifier) .. [["/><meta name="dtb:depth" content="1"/>
</head><docTitle><text>]] .. escape(title) .. "</text></docTitle><navMap>"
        .. table.concat(points, "\n") .. "</navMap></ncx>"
end

--- 构建一期 EPUB（含图片块）。
-- data = {
--   title = "科技资讯 · 2026-09-16",
--   date  = "2026-09-16",
--   items = { { title=, source_name=, time=, summary=, blocks=, images=, link= }, ... },
-- }
-- blocks = { { text= } | { img=url }, ... }；images = { [url] = { data=, ext= } }
function Epub.build(data, output_path)
    local date = assert(data and data.date, "missing issue date")
    local items = assert(data.items, "missing items")
    assert(#items > 0, "empty items")
    local title = data.title or ("科技资讯 · " .. date)
    local identifier = "technews-" .. date
    local toc = { { title = "本期目录", href = "cover.xhtml" } }
    local chapters = {}
    local image_entries = {}
    local image_counter = 0

    -- 封面：取第一条有图的资讯的首张可用图片
    local cover = nil
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

    -- 渲染一个内容块（文字或图片）
    local function render_block(item, block)
        if block.text then
            return "<p>" .. escape(block.text) .. "</p>"
        elseif block.img then
            -- 图片优先从整期图片表取（跨条目去重），兼容条目内存储
            local image = (data.images and data.images[block.img])
                or (item.images and item.images[block.img])
            if image and image.data then
                image_counter = image_counter + 1
                local name = string.format("img-%03d.%s",
                    image_counter, image.ext or "jpg")
                image_entries[#image_entries + 1] = {
                    name = "OEBPS/images/" .. name,
                    data = image.data,
                }
                return '<div class="img"><img src="../images/'
                    .. name .. '" alt=""/></div>'
            end
        end
        return nil
    end

    local overview = {
        "<p class=\"kicker\">TECH NEWS · DAILY</p>",
        "<h1>" .. escape(title) .. "</h1>",
        "<p class=\"meta\">" .. #items .. " 条资讯 · 可从 KOReader 目录跳转</p>",
        "<ol>",
    }
    for index, item in ipairs(items) do
        local href = string.format("article-%03d.xhtml", index)
        local item_title = item.title or "（无标题）"
        toc[#toc + 1] = { title = item_title, href = href }
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
        if type(item.blocks) == "table" and #item.blocks > 0 then
            for _, block in ipairs(item.blocks) do
                local html = render_block(item, block)
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
        chapters[#chapters + 1] = {
            href = href,
            title = item_title,
            body = xhtml(item_title, table.concat(body_parts, "\n")),
        }
    end
    overview[#overview + 1] = "</ol>"
    table.insert(chapters, 1, {
        href = "cover.xhtml",
        title = "本期目录",
        body = xhtml(title, table.concat(overview, "\n")),
    })

    local manifest, spine, entries = {}, {}, {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = [[<?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]] },
        { name = "OEBPS/style.css", data = CSS },
        { name = "OEBPS/nav.xhtml", data = build_nav(toc) },
        { name = "OEBPS/toc.ncx", data = build_ncx(toc, identifier, title) },
    }
    for index, chapter in ipairs(chapters) do
        manifest[#manifest + 1] = string.format('<item id="ch%d" href="text/%s" media-type="application/xhtml+xml"/>', index, chapter.href)
        spine[#spine + 1] = string.format('<itemref idref="ch%d"/>', index)
        entries[#entries + 1] = { name = "OEBPS/text/" .. chapter.href, data = chapter.body }
    end
    -- 附录图片文件
    for _, image in ipairs(image_entries) do
        entries[#entries + 1] = image
    end

    -- 封面：图片 + 封面页（spine 第一位），并声明 EPUB 封面属性
    if cover and cover.data then
        local ext = cover.ext or "jpg"
        local cover_name = "cover." .. ext
        entries[#entries + 1] = {
            name = "OEBPS/images/" .. cover_name,
            data = cover.data,
        }
        entries[#entries + 1] = {
            name = "OEBPS/text/coverpage.xhtml",
            data = coverpage_xhtml(cover_name),
        }
        manifest[#manifest + 1] = '<item id="cover-image" href="images/'
            .. cover_name .. '" media-type="' .. media_type(ext)
            .. '" properties="cover-image"/>'
        manifest[#manifest + 1] = '<item id="coverpage" href="text/coverpage.xhtml" media-type="application/xhtml+xml"/>'
        table.insert(spine, 1, '<itemref idref="coverpage"/>')
    end
    entries[#entries + 1] = { name = "OEBPS/content.opf", data = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">]] .. escape(identifier) .. "</dc:identifier><dc:title>" .. escape(title) .. [[</dc:title>
<dc:creator>Isword</dc:creator><dc:language>zh-CN</dc:language><dc:date>]] .. escape(date) .. [[</dc:date>
]] .. (cover and '<meta name="cover" content="cover-image"/>' or "") .. [[
</metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="style" href="style.css" media-type="text/css"/>
]] .. table.concat(manifest, "\n") .. "</manifest><spine toc=\"ncx\">" .. table.concat(spine, "\n") .. "</spine></package>" }

    local temporary_path = output_path .. ".part"
    local file, err = io.open(temporary_path, "wb")
    if not file then error(err) end
    file:write(make_zip(entries))
    file:close()
    assert(os.rename(temporary_path, output_path))
    return output_path
end

return Epub
