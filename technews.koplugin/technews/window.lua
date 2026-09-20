-- technews/window.lua — 时间窗口过滤（"今日"的定义）
--
-- 规则：优先取"本地今日 0 点起"发布的条目；若不足 min_items，
-- 向前回补较旧的条目（保证早晨打开也有完整的信息量）。
-- 回补条目会在各自的时间标签上体现（日期与今日不同）。

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

--- 过滤并排序条目。
-- @param items 条目数组（需带 ts 字段，epoch 秒；无 ts 视为最新）
-- @param max_items 最多返回条数
-- @param min_items 今日不足该数量时向前回补（默认 12）
-- @return selected（ts 倒序）、今日实际条数
function window.filter(items, max_items, min_items)
    local midnight = window.local_midnight_ts()
    local today_items, earlier_items = {}, {}
    for _, item in ipairs(items) do
        if not item.ts or item.ts >= midnight then
            today_items[#today_items + 1] = item
        else
            earlier_items[#earlier_items + 1] = item
        end
    end
    local n_today = #today_items
    local selected = today_items
    min_items = min_items or 12
    if #selected < min_items then
        for _, item in ipairs(earlier_items) do
            if #selected >= min_items then break end
            selected[#selected + 1] = item
        end
    end
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
