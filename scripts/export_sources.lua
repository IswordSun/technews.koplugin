-- scripts/export_sources.lua — 把内置源登记信息导出成 sources.json（Lua 插件与安卓 App 共用）
--
-- 为什么要有这个：源清单是两端唯一的「事实来源」。插件侧继续用
-- zhifou/sources/*.lua 维护，导出后安卓端读同一份 JSON，避免两边各写一套
-- 然后慢慢分叉（feed 改了、条数调了、抽取标记变了，一处改、两处生效）。
--
-- 运行（需要 KOReader 的 luajit 环境；用模拟器自带的即可）：
--   cd <koreader-dev>/koreader-emulator-*/koreader
--   ZHIFOU_PLUGIN_DIR=<插件目录> ./luajit /path/to/scripts/export_sources.lua <输出路径>
-- 说明：必须由脚本自己写文件——KOReader 的 setupkoenv 会往 stdout 打一堆库搜索日志，
-- 用 `> sources.json` 重定向会把那些噪音一起写进去（实测踩过）。
--
-- 说明：API/网页类源（知乎日报 / 「一个」/ Readhub / 60秒）没有 feed，
-- 导出时标记 kind = "api"/"web" 并给出 module 名——安卓端第一版先只支持
-- feed 类（rss/atom/rdf），这几类后续各自写适配器。

require("setupkoenv")
package.preload["socketutil"] = function()
    local http, https = require("socket.http"), require("ssl.https")
    return {
        LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
        set_timeout = function(_, b) http.TIMEOUT = b or 10; https.TIMEOUT = b or 10 end,
        reset_timeout = function() end,
    }
end

local plugin_dir = os.getenv("ZHIFOU_PLUGIN_DIR") or "plugins/zhifou.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

local registry = require("zhifou.sources.registry")

-- 极简 JSON 编码（只需处理本脚本用到的类型：nil/boolean/number/string/table）
local function esc(text)
    return (tostring(text):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
        :gsub("\r", "\\r"):gsub("\t", "\\t"))
end

local function is_array(value)
    if type(value) ~= "table" then return false end
    local n = 0
    for k in pairs(value) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #value and n > 0
end

local function encode(value, indent)
    indent = indent or ""
    local t = type(value)
    if t == "nil" then return "null" end
    if t == "boolean" or t == "number" then return tostring(value) end
    if t == "string" then return '"' .. esc(value) .. '"' end
    if t == "table" then
        local inner = indent .. "  "
        if is_array(value) then
            local parts = {}
            for _, item in ipairs(value) do
                parts[#parts + 1] = inner .. encode(item, inner)
            end
            if #parts == 0 then return "[]" end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
        end
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            local v = value[k] ~= nil and value[k] or value[tonumber(k)]
            if v == nil then v = value[k] end
            parts[#parts + 1] = inner .. '"' .. esc(k) .. '": ' .. encode(v, inner)
        end
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    return "null"
end

-- 源里有函数（自定义 fetch）与运行时字段，导出时只取「数据」部分
local SCALAR_KEYS = {
    "id", "name", "menu_label", "feed", "mode", "max_items", "merge_max_items",
    "default_enabled", "referer", "needs_referer",
}

local function export_source(source)
    local out = {}
    for _, key in ipairs(SCALAR_KEYS) do
        local value = source[key]
        if value ~= nil then out[key] = value end
    end
    -- 抽取配置（fulltext 源）：starts/start/ends/strip 都是纯数据，可直接带走
    if type(source.article_extract) == "table" then
        out.article_extract = source.article_extract
    end
    -- 类型判定：有 feed 的一律走 RSS 解析；其余是 API/网页专用适配器
    if not out.feed then
        out.kind = source.fetch and "api" or "web"
        out.adapter = source.id
    else
        out.kind = "feed"
    end
    return out
end

local sources = {}
for _, source in ipairs(registry) do
    sources[#sources + 1] = export_source(source)
end

local payload = {
    schema = 1,
    generated_by = "scripts/export_sources.lua",
    note = "源清单单一事实来源：改 zhifou.koplugin/zhifou/sources/*.lua 后重新导出，安卓端读同一份",
    count = #sources,
    sources = sources,
}

local out_path = arg and arg[1]
if not out_path then
    io.stderr:write("用法: luajit export_sources.lua <输出路径>\n")
    os.exit(1)
end
local file = assert(io.open(out_path, "w"), "无法写入 " .. out_path)
file:write(encode(payload))
file:write("\n")
file:close()
io.stderr:write(string.format("已导出 %d 个源 → %s\n", #sources, out_path))
