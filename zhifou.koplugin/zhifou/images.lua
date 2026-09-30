-- zhifou/images.lua — 图片数据的判型与体积额度（纯逻辑，无 KOReader 依赖，便于单测）
--
-- 存在的理由（都是实测踩过的坑）：
-- 1) CDN 会把图「换格式」返回：七牛 imageView2 加 format/jpg 后，PNG 源返回的是
--    JPEG 字节。若仍按 URL 后缀写进 EPUB 的 media-type，声明与实际不符，
--    严格阅读器会渲染不出来。故一律按**响应字节的魔数**判型。
-- 2) CDN 出错时可能回 200 + HTML 错误页，只看 #data > 0 会把错误页当图片存进 EPUB。
-- 3) 单张图无上限时，一张巨图就能把整期推高数 MB；整期也需要一个字节额度兜底
--    （图片占成品期文件体积的 99%+，实测 22.5MB 期里 22.4MB 是图片）。
-- 4) KOReader 对 GIF 只显示首帧，转静态图不丢可见内容。

local images = {}

-- 单张上限与每期（或每篇收藏）总额度
images.MAX_IMAGE_BYTES = 1500 * 1024
images.MAX_TOTAL_BYTES = 12 * 1024 * 1024
-- 先按 800 宽取；CDN 报 400（超高图）或单张仍超限时降到 480
images.WIDTHS = { 800, 480 }

--- 按魔数判定图片类型；不是图片（HTML 错误页、空响应）返回 nil。
-- @return "jpg" | "png" | "gif" | "webp" | nil
function images.ext_from_data(data)
    if type(data) ~= "string" or #data < 12 then return nil end
    if data:sub(1, 3) == "\255\216\255" then return "jpg" end       -- JPEG SOI
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end   -- PNG 签名
    if data:sub(1, 4) == "GIF8" then return "gif" end               -- GIF87a/89a
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp" end
    return nil
end

-- 额度对象：整期（或单篇收藏）共享一个，负责「还收不收得下」的判定与统计
local Budget = {}
Budget.__index = Budget

--- @param opts 可选 { max_image_bytes = , max_total_bytes = }
function images.new_budget(opts)
    opts = opts or {}
    return setmetatable({
        max_image_bytes = opts.max_image_bytes or images.MAX_IMAGE_BYTES,
        max_total_bytes = opts.max_total_bytes or images.MAX_TOTAL_BYTES,
        bytes = 0,
        count = 0,
        skipped = 0,
        skipped_reasons = {},
    }, Budget)
end

--- 判定一张图能否收下（不改状态）："ok" | "too_large"（换更小宽度再试）| "over_budget"（该停了）
function Budget:check(bytes)
    if bytes > self.max_image_bytes then return "too_large" end
    if self.bytes + bytes > self.max_total_bytes then return "over_budget" end
    return "ok"
end

--- 计入一张已收下的图（仅在 check 返回 "ok" 时调用）
function Budget:add(bytes)
    self.bytes = self.bytes + bytes
    self.count = self.count + 1
end

--- 记一次放弃（统计用；reason 见 check 的返回值或抓取错误串）
function Budget:note_skip(reason)
    self.skipped = self.skipped + 1
    local key = tostring(reason or "unknown")
    self.skipped_reasons[key] = (self.skipped_reasons[key] or 0) + 1
end

function Budget:summary()
    return {
        images = self.count,
        bytes = self.bytes,
        skipped = self.skipped,
        skipped_reasons = self.skipped_reasons,
    }
end

--- 抓一张图：按宽度候选重写 URL → 下载 → 魔数判型 → 额度判定。
-- @param url 原图 URL
-- @param opts {
--   download = function(url) -> data | nil, err   必填
--   rewrite  = function(url, width, o) -> url|nil 可选（imgurl.rewrite）
--   budget   = Budget                             可选
--   gray     = boolean                            可选（让重写选灰度配方）
--   widths   = {800, 480}                         可选
-- }
-- @return { data = , ext = } 或 nil, 原因（"not_image"|"too_large"|"over_budget"|错误串）
function images.fetch(url, opts)
    opts = opts or {}
    local download = opts.download
    if type(download) ~= "function" then return nil, "缺少下载函数" end
    local budget = opts.budget

    -- 候选目标：可重写时按宽度逐个尝试（800 → 480），不可重写时只下原图一次
    local targets, seen = {}, {}
    if opts.rewrite then
        for _, width in ipairs(opts.widths or images.WIDTHS) do
            local target = opts.rewrite(url, width, { gray = opts.gray })
            if target and target ~= url and not seen[target] then
                seen[target] = true
                targets[#targets + 1] = target
            end
        end
    end
    if #targets == 0 then targets = { url } end

    local last_err = "下载失败"
    for index, target in ipairs(targets) do
        local data, err = download(target)
        if data and #data > 0 then
            local ext = images.ext_from_data(data)
            if not ext then
                -- CDN 返回的不是图片（多为 HTML 错误页）：换宽度也没用，直接放弃
                if budget then budget:note_skip("not_image") end
                return nil, "not_image"
            end
            local verdict = budget and budget:check(#data) or "ok"
            if verdict == "ok" then
                if budget then budget:add(#data) end
                return { data = data, ext = ext }
            elseif verdict == "over_budget" then
                -- 整期额度用尽：调用方应停止继续下载后面的图
                if budget then budget:note_skip("over_budget") end
                return nil, "over_budget"
            end
            last_err = "too_large"  -- 单张超限：继续试更小的宽度
        else
            last_err = err or "下载失败"
        end
        if index == #targets and budget then
            budget:note_skip(last_err)
        end
    end
    return nil, last_err
end

return images
