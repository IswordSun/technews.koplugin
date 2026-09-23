-- technews/rss.lua — RSS 2.0 / RDF / Atom 解析（够用即可：title / link / 正文 / 时间）
--
-- 支持：
--   * RSS 2.0：<item>，description / content:encoded（有 cenc 时优先），pubDate / dc:date
--   * RDF（Slashdot 类）：带属性的 <item rdf:about=...>
--   * Atom：<entry>，<link href>（优先 rel="alternate"）、content / summary、updated / published
--   * 时间：RFC822、ISO8601、"YYYY-MM-DD HH:MM:SS ±ZZZZ"；无时区按 +0800（中文源惯例）

local htmltext = require("technews.htmltext")

local rss = {}

local MONTHS = {
    Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
    Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

local function strip_cdata(s)
    if not s then return nil end
    s = s:gsub("^%s*<!%[CDATA%[", ""):gsub("%]%]>%s*$", "")
    return s
end

-- Lua 模式魔法字符转义：tag 名可能含 `-` 等特殊字符（如 content:encoded 之外
-- 的命名空间标签），不转义会被当作量词导致匹配异常。
local function pattern_escape(s)
    return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function tag_value(block, tag)
    local pat = pattern_escape(tag)
    local v = block:match("<" .. pat .. "[^>]*>(.-)</" .. pat .. ">")
    return strip_cdata(v)
end

-- 本地时区相对 UTC 的偏移（秒），如北京时间 +28800
local function local_utc_offset()
    local now = os.time()
    return os.difftime(now, os.time(os.date("!*t", now)))
end

-- 时区串 → 偏移秒："+0800" / "+08:00" / "-04:00"；Z/GMT/UTC/空 另行处理
local function zone_offset_of(zone)
    if not zone or zone == "" then return nil end
    if zone == "Z" or zone == "GMT" or zone == "UTC" then return 0 end
    local sign, zh, zm = zone:match("([+%-])(%d%d):?(%d%d)")
    if not sign then return nil end
    local offset = tonumber(zh) * 3600 + (tonumber(zm) or 0) * 60
    return sign == "-" and -offset or offset
end

--- 时间解析：RFC822 / ISO8601 / "YYYY-MM-DD HH:MM:SS ±ZZZZ" → epoch（UTC 秒）。
-- 无时区的中国式时间按 +0800 处理（源站惯例）；均返回 nil 表示无法解析。
local function parse_date(s)
    if not s then return nil end
    s = s:match("^%s*(.-)%s*$")
    local year, month, day, hour, min, sec, zone_offset

    local date_part, clock_part, zone_part =
        s:match("^(%d%d%d%d%-%d%d%-%d%d)[T ](%d%d:%d%d:?%d*)%s*(.-)$")
    if date_part then
        -- ISO8601 / 中国式：2026-09-23T04:17:20Z / 2026-09-23 12:17:14 +0800 / 无时区
        local y, mo, d = date_part:match("(%d+)-(%d+)-(%d+)")
        local hh, mi, ss = clock_part:match("(%d+):(%d+):?(%d*)")
        year, month, day = tonumber(y), tonumber(mo), tonumber(d)
        hour, min = tonumber(hh), tonumber(mi)
        sec = tonumber(ss ~= "" and ss or "00")
        zone_offset = zone_offset_of(zone_part)
        if not zone_offset then zone_offset = 28800 end -- 缺省按北京时间
    else
        -- RFC822：Wed, 23 Sep 2026 15:36:47 +0800（部分源省略秒）
        local d, mon, y, hh, mi, ss2, zone =
            s:match("(%d+) (%a+) (%d+) (%d+):(%d+):(%d+)%s+(%S+)")
        if not d then
            d, mon, y, hh, mi, zone = s:match("(%d+) (%a+) (%d+) (%d+):(%d+)%s+(%S+)")
            ss2 = "00"
        end
        local m = MONTHS[mon]
        if not (d and m and y) then return nil end
        year, month, day = tonumber(y), m, tonumber(d)
        hour, min, sec = tonumber(hh), tonumber(mi), tonumber(ss2)
        zone_offset = zone_offset_of(zone) or 0
    end

    -- os.time 把字段当作本地时间，先获取"把 UTC 当本地"的 epoch，
    -- 再加上本地偏移、减去 feed 自身时区偏移，得到真实 UTC 秒。
    local as_local = os.time{
        year = year, month = month, day = day,
        hour = hour, min = min, sec = sec,
    }
    if not as_local then return nil end
    return as_local + local_utc_offset() - zone_offset
end

--- 无 pubDate 时尝试从链接路径推断日期（/YYYY/MM/DD/ 为博客类永久链接惯例）。
-- 返回当日 00:00（按 +0800 计）的 epoch；无法推断返回 nil。
local function date_from_link(link)
    if not link then return nil end
    local y, mo, d = link:match("/(%d%d%d%d)/(%d%d)/(%d%d)/")
    if not y then return nil end
    local as_local = os.time{
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = 0, min = 0, sec = 0,
    }
    if not as_local then return nil end
    return as_local + local_utc_offset() - 28800
end

--- 解析 feed XML（RSS 2.0 / RDF / Atom），返回条目数组
-- { { title=, link=, summary=, summary_html=, ts=epoch, time="MM-DD HH:MM"(本地), … }, … }
function rss.parse(xml)
    local items = {}

    local function add(block, is_atom)
        local title = tag_value(block, "title")
        local link, body, pub
        if is_atom then
            -- 优先 rel="alternate"（文章链接），退而取第一个 href；
            -- 属性引号单双皆可（Blogger 等用单引号）
            link = block:match('<link[^>]-rel=["\']alternate["\'][^>]-href=["\']([^"\']+)["\']')
                or block:match('<link[^>]-href=["\']([^"\']+)["\']')
            local content = tag_value(block, "content")
            local summary = tag_value(block, "summary")
            body = (content and content ~= "" and content) or summary
            pub = tag_value(block, "updated") or tag_value(block, "published")
        else
            link = tag_value(block, "link")
            -- content:encoded（如爱范儿/钛媒体）含完整正文，非空时优先于短摘要 description
            local content = tag_value(block, "content:encoded")
            local desc = tag_value(block, "description")
            body = (content and content ~= "" and content) or desc
            pub = tag_value(block, "pubDate") or tag_value(block, "dc:date")
        end
        if title and link and link ~= "" then
            local ts = parse_date(pub) or date_from_link(link)
            items[#items + 1] = {
                title = htmltext.to_text(title),
                link = link,
                summary = body and htmltext.to_text(body) or "",
                summary_html = body or "",  -- 原始 HTML（含图片）
                ts = ts,
                time = ts and os.date("%m-%d %H:%M", ts) or nil,
            }
        end
    end

    -- <item>（RSS 2.0 / RDF 带属性）与 <entry>（Atom）
    for block in xml:gmatch("<item[^>]*>(.-)</item>") do
        add(block, false)
    end
    for block in xml:gmatch("<entry[^>]*>(.-)</entry>") do
        add(block, true)
    end
    return items
end

return rss
