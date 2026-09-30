-- scripts/export_fixtures.lua — 抓真实页面/feed，导出「黄金样例」供安卓端移植验收
--
-- 思路：把当前 Lua 实现的输出（条目数、内容块种类与数量、关键字段）固化成 JSON，
-- 安卓端（Kotlin）用同一份 HTML/XML 跑自己的实现，输出必须对得上——
-- 这样「移植有没有走样」不靠肉眼，靠数据。
--
-- 运行（模拟器自带的 luajit 即可）：
--   cd <koreader-dev>/koreader-emulator-*/koreader
--   ZHIFOU_PLUGIN_DIR=<插件目录> ./luajit scripts/export_fixtures.lua <输出目录>
--
-- 产物（默认写到 spec/fixtures/，**不入库**——含第三方文章正文，避免版权与体积问题）：
--   <out>/<name>.html          原始 HTML
--   <out>/<name>.expected.json 期望结果（块的 kind 计数、文本总量、首尾片段）
--   <out>/<name>.feed.xml      feed 原文（RSS 解析用）
--   <out>/<name>.items.json    feed 解析期望（条数、前几条的标题/链接/时间）

require("setupkoenv")
package.preload["socketutil"] = function()
    local http, https = require("socket.http"), require("ssl.https")
    return {
        LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
        set_timeout = function(_, b) http.TIMEOUT = b or 10; https.TIMEOUT = b or 10 end,
        reset_timeout = function() end,
    }
end

local plugin_dir = os.getenv("ZHIFOU_PLUGIN_DIR") or "plugins/zhifou.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

local http = require("zhifou.http")
local htmltext = require("zhifou.htmltext")
local extract = require("zhifou.extract")
local rss = require("zhifou.rss")

local out_dir = arg and arg[1]
if not out_dir then
    io.stderr:write("用法: luajit export_fixtures.lua <输出目录>\n")
    os.exit(1)
end

local function esc(text)
    return (tostring(text):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
        :gsub("\r", "\\r"):gsub("\t", "\\t"))
end

local function json(value, indent)
    indent = indent or ""
    local t = type(value)
    if t == "nil" then return "null" end
    if t == "boolean" or t == "number" then return tostring(value) end
    if t == "string" then return '"' .. esc(value) .. '"' end
    if t == "table" then
        local inner = indent .. "  "
        local is_array = #value > 0
        if is_array then
            local parts = {}
            for _, item in ipairs(value) do parts[#parts + 1] = inner .. json(item, inner) end
            if #parts == 0 then return "[]" end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
        end
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = inner .. '"' .. esc(k) .. '": ' .. json(value[k], inner)
        end
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    return "null"
end

--- 只保留合法 UTF-8 序列，坏字节替换为 ?（源页面/实体解码后可能带残字节）
local function sanitize_utf8(text)
    local out, i, len = {}, 1, #text
    while i <= len do
        local byte = text:byte(i)
        local size
        if byte < 0x80 then size = 1
        elseif byte >= 0xF0 and byte <= 0xF4 then size = 4
        elseif byte >= 0xE0 and byte <= 0xEF then size = 3
        elseif byte >= 0xC0 and byte <= 0xDF then size = 2
        else size = 0 end           -- 0x80–0xBF（游离续字节）或 0xF5+：非法
        local chunk = size > 0 and text:sub(i, i + size - 1) or ""
        local ok = size > 0 and #chunk == size
        if ok and size > 1 then
            for j = 2, size do
                local cont = chunk:byte(j)
                if not cont or cont < 0x80 or cont > 0xBF then ok = false break end
            end
        end
        if ok then
            out[#out + 1] = chunk
            i = i + size
        else
            out[#out + 1] = "?"
            i = i + 1
        end
    end
    return table.concat(out)
end

--- 按字节截断但**不切断多字节字符**（from_end = true 时取末尾）
local function safe_slice(text, max_bytes, from_end)
    if #text <= max_bytes then return text end
    local cut = from_end and text:sub(-max_bytes) or text:sub(1, max_bytes)
    cut = sanitize_utf8(cut)
    -- 头部截断可能留下半个字符：去掉结尾的不完整多字节序列
    if not from_end then
        cut = cut:gsub("[\194-\244][\128-\191]*$", "")
    else
        -- 尾部截断可能从字符中间开始：去掉开头的不完整续字节
        cut = cut:gsub("^[\128-\191]+", "")
    end
    return cut
end

local function write(path, content)
    local file = assert(io.open(path, "wb"), "无法写入 " .. path)
    file:write(content)
    file:close()
end

--- 汇总一组内容块：种类计数 + 文本总量 + 首尾片段 + 图片数
local function summarize(blocks)
    local kinds, text_bytes, images = {}, 0, 0
    local first_text, last_text
    for _, block in ipairs(blocks) do
        if block.img then
            images = images + 1
        elseif block.text then
            local kind = block.kind or "text"
            kinds[kind] = (kinds[kind] or 0) + 1
            text_bytes = text_bytes + #block.text
            if not first_text then first_text = safe_slice(block.text, 60, false) end
            last_text = safe_slice(block.text, 60, true)
        end
    end
    return {
        block_count = #blocks,
        kinds = kinds,
        text_bytes = text_bytes,
        images = images,
        first_text = first_text,
        last_text = last_text,
    }
end

-- 页面样例：覆盖「段落源」「含代码/表格的技术文」「自适应抽取」
local pages = {
    { name = "cnblogs-tech", url = "https://www.cnblogs.com/xiexj/p/23172454" },
    { name = "cnblogs-table", url = "https://www.cnblogs.com/ywbmaster/p/23172720" },
    { name = "ruanyf-weekly", url = "https://www.ruanyifeng.com/blog/2024/04/weekly-issue-296.html" },
}

-- feed 样例：覆盖 RSS 2.0 / Atom / RDF 三种格式
local feeds = {
    { name = "ithome", url = "https://www.ithome.com/rss/" },
    { name = "ruanyf", url = "https://www.ruanyifeng.com/blog/atom.xml" },
    { name = "slashdot", url = "https://rss.slashdot.org/Slashdot/slashdotMain" },
    { name = "cnblogs", url = "https://feed.cnblogs.com/blog/sitehome/rss" },
}

local manifest = { pages = {}, feeds = {} }

for _, page in ipairs(pages) do
    local html = http.get(page.url, 20, 40, 0, { max_bytes = 3 * 1024 * 1024 })
    if html then
        write(out_dir .. "/" .. page.name .. ".html", html)
        local whole = summarize(htmltext.blocks(html, {}))
        local adaptive = summarize(htmltext.auto_blocks(html, {}))
        manifest.pages[#manifest.pages + 1] = {
            name = page.name,
            url = page.url,
            bytes = #html,
            whole_page = whole,
            adaptive = adaptive,
            has_code = (whole.kinds.code or 0) > 0,
            has_table = (whole.kinds.table or 0) > 0,
        }
        io.stderr:write(string.format("页面 %s: %d 字节, 全页 %d 块, 自适应 %d 块\n",
            page.name, #html, whole.block_count, adaptive.block_count))
    else
        io.stderr:write("页面抓取失败: " .. page.url .. "\n")
    end
end

for _, feed in ipairs(feeds) do
    local xml = http.get(feed.url, 20, 40, 0, { max_bytes = 3 * 1024 * 1024 })
    if xml then
        write(out_dir .. "/" .. feed.name .. ".feed.xml", xml)
        local items = rss.parse(xml)
        local head = {}
        for i = 1, math.min(#items, 5) do
            head[#head + 1] = {
                title = sanitize_utf8(items[i].title or ""),
                link = sanitize_utf8(items[i].link or ""),
                ts = items[i].ts,
                summary_bytes = items[i].summary_html and #items[i].summary_html or 0,
            }
        end
        manifest.feeds[#manifest.feeds + 1] = {
            name = feed.name,
            url = feed.url,
            bytes = #xml,
            item_count = #items,
            head = head,
        }
        io.stderr:write(string.format("feed %s: %d 字节, %d 条\n",
            feed.name, #xml, #items))
    else
        io.stderr:write("feed 抓取失败: " .. feed.url .. "\n")
    end
end

write(out_dir .. "/manifest.json", sanitize_utf8(json(manifest)) .. "\n")
io.stderr:write("黄金样例已写入 " .. out_dir .. "\n")
