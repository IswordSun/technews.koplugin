-- zhifou/window.lua — 时间窗口过滤（"今日"的定义）
--
-- 严格语义：只取"本地今日 0 点起"发布的条目；今日不足时也不回补更旧条目
-- （2026-09-20 用户决定：宁可量少，也不要混入昨日的旧闻）。
-- 无时间戳的条目视为今日。

local window = {}

--- 本地某日 0 点的 epoch（秒）；offset_days：0=今天，1=昨天…
function window.day_start_ts(offset_days)
    local t = os.time() - (offset_days or 0) * 86400
    return os.time{
        year = tonumber(os.date("%Y", t)),
        month = tonumber(os.date("%m", t)),
        day = tonumber(os.date("%d", t)),
        hour = 0, min = 0, sec = 0,
    }
end

--- 本地今日 0 点的 epoch（秒）
function window.local_midnight_ts()
    return window.day_start_ts(0)
end

--- 过滤给定半开时间区间 [start_ts, end_ts) 的条目，按 ts 倒序并截断。
-- @param include_no_ts 无时间戳条目是否视为命中（今日/近一周为 true，指定历史某日为 false）
-- @return selected、区间内实际条数（截断前）
function window.filter_range(items, max_items, start_ts, end_ts, include_no_ts)
    local selected = {}
    for _, item in ipairs(items) do
        local ts = item.ts
        if not ts then
            if include_no_ts then selected[#selected + 1] = item end
        elseif ts >= start_ts and ts < end_ts then
            selected[#selected + 1] = item
        end
    end
    local n_selected = #selected
    table.sort(selected, function(a, b)
        return (a.ts or 0) > (b.ts or 0)
    end)
    local result = {}
    for i = 1, math.min(#selected, max_items) do
        result[i] = selected[i]
    end
    return result, n_selected
end

--- 严格今日（本地 0 点起，不回补）。
-- @param items 条目数组（需带 ts 字段，epoch 秒；无 ts 视为今日）
-- @param max_items 最多返回条数
-- @return selected（今日条目按 ts 倒序）、今日实际条数（截断前）
function window.filter(items, max_items)
    return window.filter_range(items, max_items,
        window.local_midnight_ts(), math.huge, true)
end

return window
