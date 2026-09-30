-- zhifou/custom_sources.lua — 用户自定义订阅源的纯逻辑（零 KOReader 依赖，有单测）
--
-- 存在 G_reader_settings 的 zhifou_custom_sources 里，形如：
--   { { id = "custom-1a2b3c4d", url = "https://example.com/feed",
--       name = "某某博客", mode = "summary" | "fulltext",
--       max_items = 20, merge_max_items = 5 }, ... }
--
-- 设计要点：
--   * id 由 URL 归一化后哈希得到 —— 稳定且唯一，用户的启用状态（zhifou_sources[id]）
--     在改名/改条数后依然有效；同一条 URL 不会重复添加。
--   * 只做纯逻辑（解析/校验/增删改/转适配器），设置读写与 UI 都在 main.lua。

local custom_sources = {}

custom_sources.DEFAULT_MAX_ITEMS = 20
custom_sources.DEFAULT_MERGE_ITEMS = 5
custom_sources.MAX_SOURCES = 30          -- 上限，防止设置文件被塞爆
custom_sources.MAX_NAME_LENGTH = 24
custom_sources.ITEM_CHOICES = { 10, 20, 30, 50 }

--- 主机名是否像个真实域名（用于挡住「随便敲几个字」被补成 https:// 的情况）
local function host_looks_valid(host)
    if not host or host == "" then return false end
    host = host:gsub(":%d+$", "")             -- 去端口
    if not host:match("^[%w%.%-]+$") then return false end   -- 只允许 ASCII 主机名字符
    -- 注意 plain=true 时 % 不再是转义符，这里必须直接找字面量 "."
    if not host:find(".", 1, true) then return false end     -- 必须带点（排除「不是地址」）
    if host:match("^%.") or host:match("%.$") or host:find("..", 1, true) then
        return false
    end
    return true
end

--- 归一化 URL：去空白、补协议、去掉末尾斜杠与常见跟踪参数
-- @return 归一化后的字符串；输入明显不是 http(s) 时返回 nil
function custom_sources.normalize_url(url)
    if type(url) ~= "string" then return nil end
    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" then return nil end
    -- 允许用户只贴 example.com/feed —— 默认按 https 处理
    if not url:match("^%a[%w+.-]*://") then
        url = "https://" .. url
    end
    if not url:match("^https?://") then return nil end
    local scheme, rest = url:match("^(https?)://(.*)$")
    if not rest or rest == "" then return nil end
    -- 主机名必须有内容（至少一个点或 localhost），排除 "https://" 这类残片
    local host = rest:match("^([^/?#]+)")
    if not host_looks_valid(host) then return nil end
    -- 去掉末尾斜杠（保留路径语义；带查询串的不动）
    rest = rest:gsub("/+$", "")
    -- 去掉常见跟踪参数
    rest = rest:gsub("[?&](utm_[%w_]+=[^&]*)", "")
    rest = rest:gsub("^%?$", "")
    return scheme .. "://" .. rest
end

--- URL → 稳定 id（djb2 哈希取 8 位十六进制）
function custom_sources.id_for(url)
    local normalized = custom_sources.normalize_url(url) or tostring(url)
    local hash = 5381
    for i = 1, #normalized do
        hash = (hash * 33 + normalized:byte(i)) % 4294967296
    end
    return string.format("custom-%08x", hash)
end

--- 从 URL 推一个可读的默认名称（主机名去掉 www.）
function custom_sources.name_from_url(url)
    local normalized = custom_sources.normalize_url(url) or ""
    local host = normalized:match("^https?://([^/?#]+)") or normalized
    host = host:gsub("^www%.", "")
    if host == "" then return "自定义源" end
    return host
end

--- 校验一条源记录
-- @return true 或 nil, 原因
function custom_sources.validate(entry)
    if type(entry) ~= "table" then return nil, "记录不是表" end
    local url = custom_sources.normalize_url(entry.url)
    if not url then return nil, "地址无效（需要 http/https）" end
    if entry.mode ~= nil and entry.mode ~= "summary" and entry.mode ~= "fulltext" then
        return nil, "类型只能是 summary 或 fulltext"
    end
    if entry.max_items ~= nil and (type(entry.max_items) ~= "number"
        or entry.max_items < 1 or entry.max_items > 200) then
        return nil, "条数越界"
    end
    return true
end

--- 读设置值 → 数组（容忍 nil / 脏数据：坏记录直接丢弃，不炸）
function custom_sources.parse(raw)
    local list = {}
    if type(raw) ~= "table" then return list end
    for _, entry in ipairs(raw) do
        if type(entry) == "table" and custom_sources.validate(entry) then
            local url = custom_sources.normalize_url(entry.url)
            list[#list + 1] = {
                id = (type(entry.id) == "string" and entry.id ~= "" and entry.id)
                    or custom_sources.id_for(url),
                url = url,
                name = (type(entry.name) == "string" and entry.name ~= "")
                    and entry.name or custom_sources.name_from_url(url),
                mode = entry.mode or "summary",
                max_items = entry.max_items or custom_sources.DEFAULT_MAX_ITEMS,
                merge_max_items = entry.merge_max_items or custom_sources.DEFAULT_MERGE_ITEMS,
            }
        end
    end
    return list
end

--- 转成 fetchSource 认得的适配器（与内置源同形）
function custom_sources.to_adapter(entry)
    return {
        id = entry.id,
        name = entry.name,
        menu_label = entry.name .. " · 今日文章",
        feed = entry.url,
        mode = entry.mode or "summary",
        max_items = entry.max_items or custom_sources.DEFAULT_MAX_ITEMS,
        merge_max_items = entry.merge_max_items or custom_sources.DEFAULT_MERGE_ITEMS,
        default_enabled = true,   -- 自定义源加上就该能看（用户随时可停用）
        custom = true,            -- 标记：菜单里可管理、自检里单列一节
    }
end

--- 解析设置 → 适配器数组
function custom_sources.adapters(raw)
    local result = {}
    for _, entry in ipairs(custom_sources.parse(raw)) do
        result[#result + 1] = custom_sources.to_adapter(entry)
    end
    return result
end

--- 按 id 找记录（返回记录与下标）
function custom_sources.find(list, id)
    for i, entry in ipairs(list) do
        if entry.id == id then return entry, i end
    end
end

--- 按 URL 找记录（用于判重）
function custom_sources.find_by_url(list, url)
    local normalized = custom_sources.normalize_url(url)
    if not normalized then return nil end
    for _, entry in ipairs(list) do
        if entry.url == normalized then return entry end
    end
end

--- 追加一条源（返回新数组、新记录）；重复或非法返回 nil, 原因
function custom_sources.add(list, fields)
    local existing = custom_sources.parse(list)
    if #existing >= custom_sources.MAX_SOURCES then
        return nil, string.format("最多 %d 个自定义源", custom_sources.MAX_SOURCES)
    end
    local url = custom_sources.normalize_url(fields and fields.url)
    if not url then return nil, "地址无效（需要 http/https）" end
    if custom_sources.find_by_url(existing, url) then
        return nil, "这个地址已经添加过了"
    end
    local entry = {
        id = custom_sources.id_for(url),
        url = url,
        name = (fields.name and fields.name ~= "" and fields.name)
            or custom_sources.name_from_url(url),
        mode = fields.mode or "summary",
        max_items = fields.max_items or custom_sources.DEFAULT_MAX_ITEMS,
        merge_max_items = fields.merge_max_items or custom_sources.DEFAULT_MERGE_ITEMS,
    }
    local ok, err = custom_sources.validate(entry)
    if not ok then return nil, err end
    entry.name = custom_sources.trim_name(entry.name)
    existing[#existing + 1] = entry
    return existing, entry
end

--- 名称整理：去空白、限长（菜单一行放得下）
function custom_sources.trim_name(name)
    local trimmed = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    trimmed = trimmed:gsub("%s+", " ")
    if trimmed == "" then return "自定义源" end
    if #trimmed > custom_sources.MAX_NAME_LENGTH * 3 then
        -- 24 个汉字 ≈ 72 字节；按字节截断可能切碎多字节字符，这里保守按字符数判断
        local count, out = 0, {}
        for char in trimmed:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            count = count + 1
            if count > custom_sources.MAX_NAME_LENGTH then break end
            out[#out + 1] = char
        end
        trimmed = table.concat(out)
    end
    return trimmed
end

--- 删除一条源（返回新数组、是否删掉了）
function custom_sources.remove(list, id)
    local entries = custom_sources.parse(list)
    for i, entry in ipairs(entries) do
        if entry.id == id then
            table.remove(entries, i)
            return entries, true
        end
    end
    return entries, false
end

--- 改一条源的字段（返回新数组、是否改到了）
function custom_sources.update(list, id, fields)
    local entries = custom_sources.parse(list)
    local entry = custom_sources.find(entries, id)
    if not entry then return entries, false end
    for _, key in ipairs({ "name", "mode", "max_items", "merge_max_items" }) do
        local value = fields and fields[key]
        if value ~= nil then
            if key == "name" then
                entry.name = custom_sources.trim_name(value)
            else
                entry[key] = value
            end
        end
    end
    if not custom_sources.validate(entry) then
        return custom_sources.parse(list), false
    end
    return entries, true
end

return custom_sources
