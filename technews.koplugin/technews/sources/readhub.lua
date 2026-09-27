-- technews/sources/readhub.lua — Readhub 早报适配器（网页源，支持按日期回溯）
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

--- 抓某天的早报内容块；返回 blocks，或 nil 与错误/空（err 为 nil 表示当天没有内容）
local function fetch_day(iso, prefix)
    local http = require("technews.http")
    local htmltext = require("technews.htmltext")
    local Trapper = require("ui/trapper")
    if not Trapper:info(string.format(
            "%s抓取 Readhub 早报 %s…（点击可取消）", prefix, iso)) then
        return nil, "已取消"
    end
    local html, err = http.get(BASE .. iso)
    if not html then
        return nil, err
    end
    -- 只取正文区（首个 <article> 到最后一个 </article>），避开导航与页脚噪音
    local s = html:find("<article", 1, true)
    if not s then
        return nil, "页面结构已变化"
    end
    local body_end, pos = s, s
    while true do
        local a, b = html:find("</article>", pos + 1, true)
        if not a then break end
        body_end = b
        pos = a
    end
    local blocks = htmltext.blocks(html:sub(s, body_end), nil)
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
