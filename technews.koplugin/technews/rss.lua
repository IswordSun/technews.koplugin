-- technews/rss.lua — RSS 2.0 解析（够用即可：title / link / description / content:encoded / pubDate）

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

--- RFC822 日期 → epoch（UTC 秒）。处理 GMT/UTC/Z 与 ±HHMM 时区。
local function parse_date(s)
    if not s then return nil end
    local day, mon, year, hour, min, sec, zone =
        s:match("(%d+) (%a+) (%d+) (%d+):(%d+):(%d+)%s+(%S+)")
    if not day then
        -- 部分 feed 省略秒
        day, mon, year, hour, min, zone =
            s:match("(%d+) (%a+) (%d+) (%d+):(%d+)%s+(%S+)")
        sec = "00"
    end
    local m = MONTHS[mon]
    if not (day and m and year) then return nil end
    local zone_offset = 0
    if zone and zone ~= "GMT" and zone ~= "UTC" and zone ~= "Z" then
        local sign, zh, zm = zone:match("([+%-])(%d%d)(%d%d)")
        if sign then
            zone_offset = tonumber(zh) * 3600 + tonumber(zm) * 60
            if sign == "-" then zone_offset = -zone_offset end
        end
    end
    -- os.time 把字段当作本地时间，先获取"把 UTC 当本地"的 epoch，
    -- 再加上本地偏移、减去 feed 自身时区偏移，得到真实 UTC 秒。
    local as_local = os.time{
        year = tonumber(year), month = m, day = tonumber(day),
        hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec),
    }
    if not as_local then return nil end
    return as_local + local_utc_offset() - zone_offset
end

--- 解析 RSS XML，返回条目数组
-- { { title=, link=, summary=, summary_html=, ts=epoch, time="MM-DD HH:MM"(本地), … }, … }
function rss.parse(xml)
    local items = {}
    for block in xml:gmatch("<item>(.-)</item>") do
        local title = tag_value(block, "title")
        local link = tag_value(block, "link")
        local desc = tag_value(block, "description")
        -- content:encoded（如爱范儿）含完整正文，非空时优先于短摘要 description
        local content = tag_value(block, "content:encoded")
        local body = content
        if not body or body == "" then body = desc end
        local pub = tag_value(block, "pubDate")
        if title and link and link ~= "" then
            local ts = parse_date(pub)
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
    return items
end

return rss
