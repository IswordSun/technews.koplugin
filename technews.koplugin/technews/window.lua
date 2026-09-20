-- technews/window.lua — 时间窗口过滤（"今日"的定义）
--
-- 严格语义：只取"本地今日 0 点起"发布的条目；今日不足时也不回补更旧条目
-- （2026-09-20 用户决定：宁可量少，也不要混入昨日的旧闻）。
-- 无时间戳的条目视为今日。

local window = {}

--- 本地今日 0 点的 epoch（秒）
function window.local_midnight_ts()
    return os.time{
        year = tonumber(os.date("%Y")),
        month = tonumber(os.date("%m")),
        day = tonumber(os.date("%d")),
        hour = 0, min = 0, sec = 0,
    }
end

--- 过滤并排序条目（严格今日，不回补）。
-- @param items 条目数组（需带 ts 字段，epoch 秒；无 ts 视为今日）
-- @param max_items 最多返回条数
-- @return selected（今日条目按 ts 倒序）、今日实际条数（截断前）
function window.filter(items, max_items)
    local midnight = window.local_midnight_ts()
    local selected = {}
    for _, item in ipairs(items) do
        if not item.ts or item.ts >= midnight then
            selected[#selected + 1] = item
        end
    end
    local n_today = #selected
    table.sort(selected, function(a, b)
        return (a.ts or 0) > (b.ts or 0)
    end)
    local result = {}
    for i = 1, math.min(#selected, max_items) do
        result[i] = selected[i]
    end
    return result, n_today
end

return window
