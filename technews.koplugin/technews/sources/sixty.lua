-- technews/sources/sixty.lua — 「每天 60 秒读懂世界」适配器（JSON API，支持按日期回溯）
--
-- 数据源：60s.viki.moe/v2/60s?date=YYYY-MM-DD（实测可翻往期，返回当日约 15 条
-- 一句话新闻；开源地址 https://github.com/vikiboss/60s）。
-- 注意：该域名为 Cloudflare 线路（大陆一般可达但非 .cn 直连）；真机若不可达，
-- 抓取时会给出明确错误，可在「订阅源设置」里关闭本源。

local API = "https://60s.viki.moe/v2/60s"

local adapter = {
    id = "sixty",
    name = "60秒读懂世界",
    mode = "api",
    max_items = 10,
    merge_max_items = 3,
    default_enabled = false,
}

local function date_str_of(offset_days)
    return os.date("%Y-%m-%d", os.time() - (offset_days or 0) * 86400)
end

--- 抓某天的 60 秒新闻 → bullet 内容块；返回 blocks，或 nil 与错误/空
local function fetch_day(iso, prefix)
    local http = require("technews.http")
    local Trapper = require("ui/trapper")
    if not Trapper:info(string.format(
            "%s抓取 60秒读懂世界 %s…（点击可取消）", prefix, iso)) then
        return nil, "已取消"
    end
    local body, err = http.get(API .. "?date=" .. iso)
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
    if tonumber(data.code or 200) ~= 200 then
        return nil, "接口返回异常（code=" .. tostring(data.code) .. "）"
    end
    local payload = data.data
    local news = (type(payload) == "table" and payload.news) or {}
    if #news == 0 then
        return nil
    end
    local blocks = {}
    for _, line in ipairs(news) do
        blocks[#blocks + 1] = { text = line, kind = "bullet" }
    end
    return blocks
end

--- 自定义抓取入口（fetchSource 调用）
function adapter.fetch(_, opts)
    local range = opts.range
    local limit = opts.limit or adapter.max_items
    local prefix = opts.prefix or ""
    local socket = require("socket")

    local days = {}
    if range and range.suffix == "-week" then
        for i = 0, 6 do days[#days + 1] = date_str_of(i) end
    else
        days[1] = (range and range.date) or date_str_of(0)
    end

    local items = {}
    for idx, iso in ipairs(days) do
        if #items >= limit then break end
        local blocks, err = fetch_day(iso, prefix)
        if not blocks then
            if err == "已取消" then
                return nil, err
            end
            if #days == 1 then
                if err then
                    return nil, err -- 真错误（网络/解析）：上报并允许重试
                end
                return {} -- 当天确实没有内容 → 走"空结果"提示
            end
        elseif #blocks > 0 then
            local y, m, d = iso:match("^(%d+)%-(%d+)%-(%d+)$")
            items[#items + 1] = {
                title = string.format("每天60秒读懂世界 · %d月%d日", tonumber(m), tonumber(d)),
                link = "https://60s.viki.moe/",
                time = string.format("%d月%d日", tonumber(m), tonumber(d)),
                -- ts 仅供合并期按时间排序（自定义源不做窗口过滤）
                ts = os.time{ year = tonumber(y), month = tonumber(m),
                    day = tonumber(d), hour = 12 },
                blocks = blocks,
            }
        end
        if idx < #days then
            socket.sleep(0.2)
        end
    end
    return items
end

return adapter
