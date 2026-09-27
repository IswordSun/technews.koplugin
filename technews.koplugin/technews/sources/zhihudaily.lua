-- technews/sources/zhihudaily.lua — 知乎日报适配器（API 源，支持按日期回溯）
--
-- 数据源：公开的 v4 API（news-at.zhihu.com/api/4；实测可用，结论参考本机的
-- zhihudaily.koplugin）：
--   /news/latest           最新一期（约北京时间 08:00 更新）
--   /news/before/YYYYMMDD  该日期之前的一期（返回的 date 才是刊期）
--   /news/<id>             单篇正文（body 为 HTML 片段）
-- 与 RSS 源不同，该 API 天然支持往期，分源阅读的「昨日 / 自定义日期 / 近一周」
-- 都能真正取到内容。请求走 http.lua 默认浏览器 UA；图片在 pic*.zhimg.com，
-- 需要 Referer（见 imgurl.referer）。

local API = "https://news-at.zhihu.com/api/4"

local adapter = {
    id = "zhihudaily",
    name = "知乎日报",
    mode = "api", -- 非 RSS：走自定义 fetch
    max_items = 20,
    merge_max_items = 6,
    default_enabled = false,
}

-- 北京时间的 YYYYMMDD（知乎按北京时间发布/归档；设备时区可能不准）
local function beijing_ymd(offset_days)
    return os.date("!%Y%m%d", os.time() + 8 * 3600 - (offset_days or 0) * 86400)
end

local function ymd_add(ymd, delta)
    local y, m, d = ymd:match("^(%d%d%d%d)(%d%d)(%d%d)$")
    if not y then return nil end
    local t = os.time{ year = y, month = m, day = d, hour = 12 } + delta * 86400
    return os.date("%Y%m%d", t)
end

local function get_json(path)
    local http = require("technews.http")
    local body, err = http.get(API .. path)
    if not body then
        return nil, err
    end
    local ok, json = pcall(require, "json")
    if not ok or type(json) ~= "table" then
        return nil, "解析失败（缺少 JSON 解码器）"
    end
    local ok2, data = pcall(json.decode, body)
    if not ok2 or type(data) ~= "table" then
        return nil, "解析失败（JSON）"
    end
    return data
end

--- 目标日（北京时间 YYYYMMDD）的故事列表；今天走 /news/latest，其余走 /news/before
local function list_stories(ymd)
    local path
    if ymd == beijing_ymd(0) then
        path = "/news/latest"
    else
        local next_day = ymd_add(ymd, 1)
        if not next_day then return nil, "无效日期" end
        path = "/news/before/" .. next_day
    end
    local data, err = get_json(path)
    if not data then return nil, err end
    return data.stories or {}
end

--- 只取 <div class="content"> 容器内的正文（参考参考插件 zhihudaily.koplugin 的解析思路：
-- 作者条（含 <img class="avatar"> 头像）、空占位、隐藏的"查看知乎原文"等都在容器外，
-- 用容器切片而非逐块过滤更稳）。其注释称实测 content 内无嵌套 div，故首个
-- </div> 即容器结束；可能出现多个 content 段（问答结构），按序拼接。
-- 未找到容器（结构变化）时返回 nil，由调用方兜底整段处理。
local function content_only(body)
    local parts = {}
    local pos = 1
    while true do
        local s, e = body:find('<div class="content">', pos, true)
        if not s then break end
        local _, close = body:find("</div>", e + 1, true)
        if not close then break end
        parts[#parts + 1] = body:sub(e + 1, close - 6)
        pos = close + 1
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, "\n")
end

--- 作者行（作者名+简介）取自作者条；拿不到返回 nil。
local function author_of(body)
    local meta = body:match('<div class="meta">(.-)</div>')
    if not meta then return nil end
    local name = meta:match('<span class="author">(.-)</span>')
    if not name then return nil end
    local bio = meta:match('<span class="bio">(.-)</span>')
    return name .. (bio or "")
end

--- 自定义抓取入口（fetchSource 调用）：按时间范围产出条目（含内容块）。
function adapter.fetch(_, opts)
    local range = opts.range
    local limit = opts.limit or adapter.max_items
    local prefix = opts.prefix or ""
    local htmltext = require("technews.htmltext")
    local Trapper = require("ui/trapper")
    local socket = require("socket")

    -- 目标日期（北京时间 YYYYMMDD，从新到旧）
    local days = {}
    if range and range.suffix == "-week" then
        for i = 0, 6 do days[#days + 1] = beijing_ymd(i) end
    elseif range and range.date then
        days[1] = range.date:gsub("%-", "")
    else
        days[1] = beijing_ymd(0)
    end

    -- 收集故事（跨天去重；单日失败即整体失败，近一周时单日失败跳过）
    local stories, seen = {}, {}
    for _, day in ipairs(days) do
        if #stories >= limit then break end
        local list, err = list_stories(day)
        if not list then
            if #days == 1 then
                return nil, err
            end
        else
            for _, s in ipairs(list) do
                if s.id and not seen[s.id] then
                    seen[s.id] = true
                    s._day = day
                    stories[#stories + 1] = s
                    if #stories >= limit then break end
                end
            end
        end
    end
    if #stories == 0 then
        return {}
    end

    -- 逐篇抓正文（0.2s 间隔限速，参考 zhihudaily 插件的最小请求间隔）
    local items = {}
    for i, s in ipairs(stories) do
        if not Trapper:info(string.format(
                "%s抓取 知乎日报 %d/%d…（点击可取消）", prefix, i, #stories)) then
            return nil, "已取消"
        end
        local data, err = get_json("/news/" .. tostring(s.id))
        if not data then
            return nil, err
        end
        -- 正文只取 content 容器（作者头像等在容器外，天然排除）；
        -- 作者名+简介单独提取，作为一条图注放在开头
        local raw = data.body or ""
        local blocks = htmltext.blocks(content_only(raw) or raw, nil)
        local author = author_of(raw)
        if author then
            table.insert(blocks, 1, { text = author, kind = "caption" })
        end
        if #blocks == 0 then
            blocks = { { text = s.title or "" } }
        end
        local y, m, d = s._day:match("^(%d%d%d%d)(%d%d)(%d%d)$")
        items[#items + 1] = {
            title = s.title,
            link = s.url or ("https://daily.zhihu.com/story/" .. tostring(s.id)),
            time = string.format("%d月%d日", tonumber(m), tonumber(d)),
            -- ts 仅供合并期按时间排序（自定义源不做窗口过滤）
            ts = os.time{ year = tonumber(y), month = tonumber(m),
                day = tonumber(d), hour = 12 },
            blocks = blocks,
        }
        if i < #stories then
            socket.sleep(0.2)
        end
    end
    return items
end

return adapter
