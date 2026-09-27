-- technews/sources/one.lua — 「ONE · 一个」适配器（API 源，支持按日期回溯）
--
-- 数据源：官方 App 的 v3 API（http://v3.wufazhuce.com:8000，每个请求须带
-- version/platform 参数；实现参考本机 one.koplugin 的实测结论）：
--   /api/reading/index/<page>  时间线（每页约 5 天；给出当天的文章/问答 id）
--   /api/essay/<id>            文章（hp_title / hp_author / hp_content）
--   /api/question/<id>         问答（question_title / answer_content）
--   /api/hp/idlist/<offset>    最近发布的图文 id（每页 10 天、按日期连续）
--   /api/hp/detail/<id>        图文（VOL.N / 每日一句 / 配图 image.wufazhuce.com）
-- 每日一期 = 图文 + 文章 + 问答，合并为一条（多日范围时每日一条）。

local V3 = "http://v3.wufazhuce.com:8000"
local V3_QS = "?version=3.5.0&platform=android"

local adapter = {
    id = "one",
    name = "「一个」",
    mode = "api",
    max_items = 10,
    merge_max_items = 3,
    default_enabled = false,
}

local function get_json(path)
    local http = require("technews.http")
    local body, err = http.get(V3 .. path .. V3_QS)
    if not body then
        return nil, err
    end
    local ok, json = pcall(require, "json")
    if not ok or type(json) ~= "table" then
        return nil, "解析失败（缺少 JSON 解码器）"
    end
    local ok2, decoded = pcall(json.decode, body)
    if not ok2 or type(decoded) ~= "table" then
        return nil, "解析失败（JSON）"
    end
    if decoded.res ~= 0 then
        return nil, "接口返回异常（res=" .. tostring(decoded.res) .. "）"
    end
    if decoded.data == nil then
        return nil, "该日期没有内容"
    end
    return decoded.data
end

local function days_between(y1, m1, d1, y2, m2, d2)
    local a = os.time{ year = y1, month = m1, day = d1, hour = 12 }
    local b = os.time{ year = y2, month = m2, day = d2, hour = 12 }
    return math.floor((b - a) / 86400 + 0.5)
end

--- 目标日期的时间线分组 {date, items}；找不到（空档日/超范围）返回 nil。
-- 从估算页（每页约 5 天）开始加/减页逼近，最多 30 次。
local function find_group(target_iso, diff_from_today)
    local page = math.max(0, math.floor(diff_from_today / 5) - 1)
    for _ = 1, 30 do
        local data = get_json("/api/reading/index/" .. tostring(page))
        if type(data) ~= "table" or #data == 0 then
            return nil
        end
        local first, last = data[1].date, data[#data].date
        if last <= target_iso and target_iso <= first then
            for _, group in ipairs(data) do
                if group.date == target_iso then
                    return group
                end
            end
            return nil -- 落在该页区间内但没有这天（空档日）
        elseif target_iso < last then
            page = page + 1 -- 目标更旧，往后翻
        elseif page > 0 then
            page = page - 1 -- 目标更新，往前翻
        else
            return nil
        end
    end
    return nil
end

--- 某天的图文 id（近 60 天用 idlist 按天步进查找；更早不取图文）
local function image_id_of(diff_from_today)
    if diff_from_today < 0 or diff_from_today > 60 then
        return nil
    end
    local page = math.floor(diff_from_today / 10)
    local offset, ids = "0", nil
    for p = 0, page do
        ids = get_json("/api/hp/idlist/" .. offset)
        if type(ids) ~= "table" or #ids == 0 then
            return nil
        end
        if p < page then
            if #ids < 10 then
                return nil
            end
            offset = tostring(ids[#ids])
        end
    end
    return ids[(diff_from_today % 10) + 1]
end

--- 抓取某天的全部内容；返回 blocks, 标题, 每日一句, 错误
local function fetch_day(target_iso, diff, prefix)
    local htmltext = require("technews.htmltext")
    local Trapper = require("ui/trapper")
    if not Trapper:info(string.format(
            "%s抓取「一个」%s…（点击可取消）", prefix, target_iso)) then
        return nil, nil, nil, "已取消"
    end

    local blocks, title, quote = {}, nil, nil

    -- 图文：每日一句 + 配图
    local image_id = image_id_of(diff)
    if image_id then
        local hp = get_json("/api/hp/detail/" .. tostring(image_id))
        if type(hp) == "table" then
            quote = hp.hp_content
            if hp.hp_img_url then
                blocks[#blocks + 1] = { img = hp.hp_img_url }
            end
            if quote and quote ~= "" then
                blocks[#blocks + 1] = { text = quote }
            end
        end
    end

    -- 文章 + 问答
    local group = find_group(target_iso, diff)
    if type(group) == "table" then
        local essay_ids, question_id = {}, nil
        for _, it in ipairs(group.items or {}) do
            local c = it.content or {}
            if it.type == 1 and c.content_id then
                essay_ids[#essay_ids + 1] = tostring(c.content_id)
            elseif it.type == 3 and not question_id and c.question_id then
                question_id = tostring(c.question_id)
            end
        end
        for _, id in ipairs(essay_ids) do
            local essay = get_json("/api/essay/" .. id)
            if type(essay) == "table" then
                title = title or essay.hp_title
                if essay.hp_title then
                    blocks[#blocks + 1] = { text = essay.hp_title, kind = "heading" }
                end
                if essay.hp_author then
                    blocks[#blocks + 1] = { text = essay.hp_author, kind = "caption" }
                end
                for _, b in ipairs(htmltext.blocks(essay.hp_content or "", nil)) do
                    blocks[#blocks + 1] = b
                end
            end
        end
        if question_id then
            local q = get_json("/api/question/" .. question_id)
            if type(q) == "table" then
                blocks[#blocks + 1] = { text = "问答", kind = "heading" }
                if q.question_title then
                    blocks[#blocks + 1] = { text = q.question_title }
                end
                for _, b in ipairs(htmltext.blocks(q.answer_content or "", nil)) do
                    blocks[#blocks + 1] = b
                end
            end
        end
    end
    return blocks, title, quote
end

--- 自定义抓取入口（fetchSource 调用）
function adapter.fetch(_, opts)
    local range = opts.range
    local limit = opts.limit or adapter.max_items
    local prefix = opts.prefix or ""
    local socket = require("socket")

    local today = os.date("*t")
    local targets = {}
    if range and range.suffix == "-week" then
        for i = 0, 6 do
            local t = os.date("*t", os.time() - i * 86400)
            targets[#targets + 1] = {
                iso = string.format("%04d-%02d-%02d", t.year, t.month, t.day),
                diff = i,
            }
        end
    else
        local iso = (range and range.date) or os.date("%Y-%m-%d")
        local y, m, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
        if not y then
            return nil, "无效的日期"
        end
        targets[1] = {
            iso = iso,
            diff = days_between(tonumber(y), tonumber(m), tonumber(d),
                today.year, today.month, today.day),
        }
    end

    local items = {}
    for idx, target in ipairs(targets) do
        if #items >= limit then break end
        local blocks, title, quote, err = fetch_day(target.iso, target.diff, prefix)
        if blocks == nil then
            if err == "已取消" or #targets == 1 then
                return nil, err or "抓取失败"
            end
        elseif #blocks > 0 then
            local _, m, d = target.iso:match("^(%d+)%-(%d+)%-(%d+)$")
            items[#items + 1] = {
                title = title or ("「一个」 · " .. tonumber(m) .. "月" .. tonumber(d) .. "日"),
                link = "https://wufazhuce.com/",
                time = string.format("%d月%d日", tonumber(m), tonumber(d)),
                summary = quote,
                blocks = blocks,
            }
        end
        if idx < #targets then
            socket.sleep(0.2)
        end
    end
    return items
end

return adapter
