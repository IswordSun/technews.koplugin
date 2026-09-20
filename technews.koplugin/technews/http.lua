-- technews/http.lua — HTTPS GET（LuaSocket + LuaSec，带超时与重试）
--
-- 备注：部分站点（如 CNBeta）偶发直接断开连接，表现为返回 "closed" 错误码，
-- 因此这里内置 2 次重试；错误信息会区分"连接失败 / HTTP 状态码 / 网络错误"。

local ltn12 = require("ltn12")
local socket = require("socket")
local https = require("ssl.https")
local socketutil = require("socketutil")
local logger = require("logger")

local http = {}

local UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

local function request_once(url, block_timeout, total_timeout)
    local body = {}
    socketutil:set_timeout(
        block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
        total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
    -- LuaSocket：成功时返回 (1, 状态码, headers, status)；失败时返回错误码
    local code, headers, status = socket.skip(1, https.request{
        url = url,
        headers = {
            ["User-Agent"] = UA,
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8",
        },
        sink = ltn12.sink.table(body),
    })
    if not code then
        return nil, tostring(headers) or "request failed"
    end
    if type(code) ~= "number" then
        -- "closed" / "timeout" 等连接层错误码
        return nil, "连接失败（" .. tostring(code) .. "）"
    end
    local ok_status = code == 200
        or (status and tostring(status):find("200"))
    if not ok_status then
        return nil, "HTTP " .. tostring(code)
    end
    return table.concat(body)
end

--- GET 请求（自动重试），返回响应体或 (nil, 错误信息)
-- @param url
-- @param block_timeout 单次阻塞超时（秒）
-- @param total_timeout 总超时（秒）
-- @param retries 重试次数（默认 3，即最多尝试 4 次）
-- 备注：重试之间加短暂延迟，部分站点对高频请求会直接断连（closed），
-- 小幅退避能显著提高成功率。
function http.get(url, block_timeout, total_timeout, retries)
    retries = retries or 3
    local last_err
    for attempt = 1, retries + 1 do
        local body, err = request_once(url, block_timeout, total_timeout)
        if body then
            return body
        end
        last_err = err
        if attempt <= retries then
            logger.warn("technews http retry:", url,
                "attempt=" .. attempt, tostring(err))
            socket.sleep(0.6)
        end
    end
    logger.warn("technews http failed:", url, tostring(last_err))
    return nil, last_err
end

return http
