-- technews/dedupe.lua — 合并视图的跨源去重
--
-- 同一条新闻被 IT之家与 CNBeta 同时报道时只保留一条：
-- 标题归一化（小写、去空白与标点）后取字符二元组（bigram）的 Jaccard 相似度，
-- 相似度与长度比同时达标判为重复；重复时保留正文文字更多的一条（平局保留先出现的）。
-- 仅比较不同来源（source_id）的条目；缺失 source_id 的条目不参与去重。

local dedupe = {}

-- 判定阈值（按真实 feed 标题调校，见 TODO「两源去重」）
dedupe.THRESHOLD = 0.8      -- bigram Jaccard 下限
dedupe.LENGTH_RATIO = 0.8   -- 归一化标题长度比 min/max 下限

-- 需剔除的多字节标点（ASCII 标点含引号/反引号，交给 %p；空白交给 %s）
local CJK_PUNCT = {
    "，", "。", "！", "？", "：", "；", "、", "（", "）", "【", "】",
    "《", "》", "〈", "〉", "“", "”", "‘", "’", "「", "」", "『", "』",
    "·", "—", "…", "　",
}

--- 标题归一化：小写 + 去除全部空白与标点
function dedupe.normalize(title)
    local s = (title or ""):lower():gsub("%s+", ""):gsub("%p+", "")
    for _, p in ipairs(CJK_PUNCT) do
        s = s:gsub(p, "")
    end
    return s
end

-- UTF-8 逐码点切分（Lua 无内建 UTF-8 支持）
local function codepoints(s)
    local cps = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        cps[#cps + 1] = ch
    end
    return cps
end

-- 相邻码点的二元组集合
local function bigrams(cps)
    local set = {}
    for i = 1, #cps - 1 do
        set[cps[i] .. cps[i + 1]] = true
    end
    return set
end

-- 集合的 Jaccard 相似度；空集合返回 0
local function jaccard(a, b)
    local inter, union = 0, 0
    for g in pairs(a) do
        if b[g] then inter = inter + 1 end
        union = union + 1
    end
    for g in pairs(b) do
        if not a[g] then union = union + 1 end
    end
    if union == 0 then return 0 end
    return inter / union
end

-- 条目特征：归一化标题、bigram 集合、码点数、正文文字量（各 text 块长度之和）
local function profile(item)
    local norm = dedupe.normalize(item.title)
    local cps = codepoints(norm)
    local text = 0
    for _, block in ipairs(item.blocks or {}) do
        if block.text then text = text + #block.text end
    end
    return { norm = norm, grams = bigrams(cps), len = #cps, text = text }
end

-- 两特征的相似度；任一方归一化后为空返回 0
local function profile_similarity(a, b)
    if a.norm == "" or b.norm == "" then return 0 end
    if a.norm == b.norm then return 1 end
    return jaccard(a.grams, b.grams)
end

-- 是否判为重复：归一化标题完全相同，或相似度与长度比同时达标
local function match(a, b)
    if a.norm == "" or b.norm == "" then return false end
    if a.norm == b.norm then return true end
    local ratio = math.min(a.len, b.len) / math.max(a.len, b.len)
    return ratio >= dedupe.LENGTH_RATIO
        and profile_similarity(a, b) >= dedupe.THRESHOLD
end

--- 标题相似度（0~1）：字符 bigram 的 Jaccard
function dedupe.similarity(title_a, title_b)
    return profile_similarity(profile{ title = title_a }, profile{ title = title_b })
end

--- 标题是否判为重复（相似度 + 长度比同时达标）
function dedupe.is_duplicate(title_a, title_b)
    return match(profile{ title = title_a }, profile{ title = title_b })
end

--- 跨源去重。
-- @param items 条目数组（每条可带 title/source_id/blocks）
-- @return kept 过滤后的数组（保持输入相对顺序）、
--         removed { kept = <保留条目>, dropped = <被丢弃条目> }（按丢弃顺序）
function dedupe.filter(items)
    local kept, removed, profs = {}, {}, {}
    for _, item in ipairs(items) do
        local p = profile(item)
        local dup_idx
        if item.source_id and p.norm ~= "" then
            for i, k in ipairs(kept) do
                if k.source_id and k.source_id ~= item.source_id
                    and match(p, profs[i]) then
                    dup_idx = i
                    break
                end
            end
        end
        if not dup_idx then
            kept[#kept + 1] = item
            profs[#profs + 1] = p
        elseif p.text > profs[dup_idx].text then
            -- 新条目正文更全：丢弃旧条目，新条目按输入顺序追加到末尾
            removed[#removed + 1] = { kept = item, dropped = kept[dup_idx] }
            table.remove(kept, dup_idx)
            table.remove(profs, dup_idx)
            kept[#kept + 1] = item
            profs[#profs + 1] = p
        else
            removed[#removed + 1] = { kept = kept[dup_idx], dropped = item }
        end
    end
    return kept, removed
end

--- 收集跨源且相似度在 [floor, THRESHOLD) 的标题对（近似未命中，供调参与日志）
-- @param items 条目数组
-- @param floor 相似度下限（默认 0.6）
-- @return { { a = item, b = item, similarity = n }, … }
function dedupe.near_misses(items, floor)
    floor = floor or 0.6
    local profs = {}
    for i, item in ipairs(items) do
        profs[i] = profile(item)
    end
    local out = {}
    for i = 1, #items do
        local a = items[i]
        if a.source_id and profs[i].norm ~= "" then
            for j = i + 1, #items do
                local b = items[j]
                if b.source_id and b.source_id ~= a.source_id
                    and profs[j].norm ~= "" and not match(profs[i], profs[j]) then
                    local sim = profile_similarity(profs[i], profs[j])
                    if sim >= floor and sim < dedupe.THRESHOLD then
                        out[#out + 1] = { a = a, b = b, similarity = sim }
                    end
                end
            end
        end
    end
    return out
end

return dedupe
