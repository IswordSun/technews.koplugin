-- technews/subscriptions.lua — 订阅源启用集合的纯逻辑（零 KOReader 依赖）
--
-- setting 语义（对应 G_reader_settings 里的 technews_sources）：
--   nil  → 用户尚未选择，用各适配器自带的 default_enabled 作默认；
--   表   → 显式选择：只有 setting[adapter.id] == true 才算启用（空表 = 全部停用）。

local subscriptions = {}

--- 单个源在给定设置下是否启用
function subscriptions.is_enabled(adapter, setting)
    if setting == nil then
        return adapter.default_enabled == true
    end
    return setting[adapter.id] == true
end

--- 按 registry 顺序返回启用源的数组
function subscriptions.enabled(registry, setting)
    local result = {}
    for _, adapter in ipairs(registry) do
        if subscriptions.is_enabled(adapter, setting) then
            result[#result + 1] = adapter
        end
    end
    return result
end

--- 是否至少启用了一个源
function subscriptions.any_enabled(registry, setting)
    for _, adapter in ipairs(registry) do
        if subscriptions.is_enabled(adapter, setting) then
            return true
        end
    end
    return false
end

--- 由启用 id 数组构造集合表（供菜单/对话框翻转与判断）
function subscriptions.to_set(ids)
    local set = {}
    for _, id in ipairs(ids) do
        set[id] = true
    end
    return set
end

return subscriptions
