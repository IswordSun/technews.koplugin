-- zhifou/sources/readhub.lua — Readhub 早报适配器（网页源，支持按日期回溯）
--
-- 数据源：readhub.cn/daily/<YYYY-MM-DD>（服务端渲染，实测可翻往期；API
-- api.readhub.cn/daily 忽略 date 参数，因此必须解析网页）。页面结构：
--   <article> × N，每条 = <h2><a href="/topic/…">标题</a></h2> + <p>摘要</p>
-- 每日一期作为一条资讯（标题含"早报"，目录里会因此展开二级小标题）。
-- 无图片；请求走 http.lua 默认浏览器 UA（该站需要）。

local BASE = "https://readhub.cn/daily/"

local adapter = {
    id = "readhub",
    name = "Readhub 早报",
    mode = "api", -- 非 RSS：走自定义 fetch
    max_items = 10,
    merge_max_items = 3,
    default_enabled = false,
}

local function date_str_of(offset_days)
    return os.date("%Y-%m-%d", os.time() - (offset_days or 0) * 86400)
end

--- 从页面 HTML 里取出「早报条目」区段（导出仅供单测）。
-- 旧实现取「首个 <article> 到最后一个 </article>」：页面改版后，
-- 只要文末多出任何 <article> 区块（推荐位/评论），整段推荐区就会被当成正文吸进来。
-- 现在按段校验结构：每段必须是 <article …>…</article> 且含 <h2> 与 /topic/ 链接，
-- 从第一段匹配开始收集，遇到第一段不匹配即停（宁少勿滥）。
local function daily_region(html)
    if not html then return nil end
    local segments, pos, started = {}, 1, false
    while true do
        local a = html:find("<article", pos, true)
        if not a then break end
        local b = html:find("</article>", a, true)
        if not b then break end
        local segment = html:sub(a, b + 8)   -- 含 "</article>"
        local looks_like_item = segment:find("<h2", 1, true)
            and segment:find("/topic/", 1, true)
        if looks_like_item then
            started = true
            segments[#segments + 1] = segment
        elseif started then
            break   -- 条目区结束（后面的 article 不是早报条目）
        end
        pos = b + 9
    end
    if #segments == 0 then return nil end
    return table.concat(segments)
end

adapter.daily_region = daily_region   -- 供 spec/readhub_spec.lua 直接测（运行时不用）

--- 抓某天的早报内容块；返回 blocks，或 nil 与错误/空（err 为 nil 表示当天没有内容）
local function fetch_day(iso, prefix)
    local http = require("zhifou.http")
    local htmltext = require("zhifou.htmltext")
    local Trapper = require("ui/trapper")
    if not Trapper:info(string.format(
            "%s抓取 Readhub 早报 %s…（点击可取消）", prefix, iso)) then
        return nil, "已取消"
    end
    local html, err = http.get(BASE .. iso)
    if not html then
        return nil, err
    end
    -- 只取「早报条目」区段（结构校验，见 daily_region），避开导航/页脚/文末推荐
    local region = daily_region(html)
    if not region then
        return nil, "页面结构已变化"
    end
    local blocks = htmltext.blocks(region, nil)
    if #blocks == 0 then
        return nil
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
                title = string.format("Readhub 早报 · %d月%d日", tonumber(m), tonumber(d)),
                link = BASE .. iso,
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
