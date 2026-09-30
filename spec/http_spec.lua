-- spec/http_spec.lua — HTTP 传输层（zhifou/http.lua）的压缩与错误语义测试
--
-- 覆盖这次的改动：声明 Accept-Encoding、按响应头解压、解压失败不重试。
-- 传输层全部打桩（socket / ssl.https / socket.http / ltn12 / socketutil / logger），
-- 不联网、不依赖 KOReader。
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/http_spec.lua）

local spec_dir = (arg and arg[0] or "spec/http_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = spec_dir .. "/../zhifou.koplugin"

----------------------------------------------------------------------
-- 打桩：传输层与依赖
----------------------------------------------------------------------

local response = nil      -- { body =, headers =, code = }
local calls = {}          -- 每次 request 的记录

local function fake_request(req)
    calls[#calls + 1] = { url = req.url, headers = req.headers }
    if req.sink and response and response.body then
        req.sink(response.body)
    end
    local code = (response and response.code) or 200
    return 1, code, (response and response.headers) or {},
        string.format("HTTP/1.1 %d Status", code)
end

-- 传输层对象保持同一份引用：个别用例换掉 request 即可（避免 require 缓存导致换不掉）
local transport = { request = fake_request }

package.preload["ltn12"] = function()
    return {
        sink = {
            table = function(target)
                return function(chunk)
                    if chunk then target[#target + 1] = chunk end
                    return 1
                end
            end,
        },
    }
end
local sleeps = {}
package.preload["socket"] = function()
    return {
        -- 与 LuaSocket 同语义：丢掉前 n 个返回值
        skip = function(n, ...) return select(n + 1, ...) end,
        sleep = function(seconds) sleeps[#sleeps + 1] = seconds end,
    }
end
package.preload["ssl.https"] = function() return transport end
package.preload["socket.http"] = function() return transport end
package.preload["socketutil"] = function()
    return {
        set_timeout = function() end,
        LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
    }
end
package.preload["logger"] = function()
    return {
        info = function() end, warn = function() end,
        dbg = function() end, err = function() end,
    }
end
package.path = plugin_dir .. "/?.lua;" .. package.path

local http = require("zhifou.http")

----------------------------------------------------------------------
-- 极简断言工具
----------------------------------------------------------------------

local checks, failed = 0, 0

local function ok(cond, name, detail)
    checks = checks + 1
    if cond then
        print(("%d ok - %s"):format(checks, name))
    else
        failed = failed + 1
        print(("%d not ok - %s"):format(checks, name))
        if detail then print("    # " .. detail) end
    end
end

local function eq(actual, expected, name)
    ok(actual == expected, name,
        ("实际=%s 期望=%s"):format(tostring(actual), tostring(expected)))
end

local function unhex(text)
    return (text:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end

-- 与 gzip_spec 同一份样本（Python 生成）
local RAW = [[<?xml version="1.0"?><rss><channel><title>读首诗再睡觉</title>]]
    .. [[<item><title>测试条目</title><description>正文内容若干</description></item>]]
    .. [[</channel></rss>]]
local GZ = unhex("1f8b08000000000002ffb3b1afc8cd51284b2d2acecccfb35532d43350b2b7b3292a2eb6b349ce48"
    .. "cccb4bcdb1b329c92cc949b57bb17ef7cb65d35eac9ffeb4adf7f9dc852f9677dae843646c324b527361ca9e"
    .. "6ded7eb17eeab3b90b9fcf5e075790925a9c5c94595002b4c3eed9dac5cfa6b53f6d6b7dba6ee78beea54f"
    .. "776eb2d14796b7d18718a70fb75f1fe41c000ca79487a9000000")

local function reset()
    calls = {}
    sleeps = {}
    response = nil
end

local function total_sleep()
    local sum = 0
    for _, value in ipairs(sleeps) do sum = sum + value end
    return sum
end

----------------------------------------------------------------------
-- 1) 请求头：必须声明支持压缩（这是这次卡顿的根因修复）
----------------------------------------------------------------------

do
    reset()
    response = { body = "plain", headers = { ["content-type"] = "text/plain" } }
    local body = http.get("https://example.com/feed")
    eq(body, "plain", "未压缩响应原样返回")
    eq(#calls, 1, "成功时只请求一次")
    eq(calls[1].headers["Accept-Encoding"], "gzip, deflate",
        "请求头声明 Accept-Encoding: gzip, deflate")
    ok(calls[1].headers["User-Agent"] ~= nil, "仍带 User-Agent")
end

----------------------------------------------------------------------
-- 2) 服务端压缩过 → 必须解开再交给上层
----------------------------------------------------------------------

do
    reset()
    response = {
        body = GZ,
        headers = { ["content-encoding"] = "gzip", ["content-type"] = "application/rss+xml" },
    }
    local body, err = http.get("https://example.com/feed")
    eq(err, nil, "gzip 响应不报错")
    eq(body, RAW, "gzip 响应解压后与原文一致（不是二进制乱码）")
    eq(#calls, 1, "解压成功只请求一次")
end

do
    -- 少数 CDN 不请求也会压：只要响应头写了就按它办
    reset()
    response = { body = GZ, headers = { ["content-encoding"] = "GZIP" } }
    local body = http.get("http://example.com/feed")   -- 顺带覆盖 http:// 通道
    eq(body, RAW, "content-encoding 大小写不敏感（GZIP）")
end

do
    reset()
    response = { body = "plain", headers = { ["content-encoding"] = "identity" } }
    eq(http.get("https://example.com/feed"), "plain",
        "identity 视为未压缩（不做解压）")
end

----------------------------------------------------------------------
-- 3) 解压失败：报明确错误，且不重试（重试只会把整个响应体再下一次）
----------------------------------------------------------------------

do
    reset()
    response = {
        body = unhex("1f8b08000000000002ff") .. "broken data",
        headers = { ["content-encoding"] = "gzip" },
    }
    local body, err = http.get("https://example.com/feed")
    eq(body, nil, "解压失败 → 返回 nil")
    ok(tostring(err):find("解压失败", 1, true) ~= nil, "错误里点明「解压失败」", tostring(err))
    ok(tostring(err):find("gzip", 1, true) ~= nil, "错误里带上编码名", tostring(err))
    eq(#calls, 1, "解压失败不重试（只请求一次）")
end

----------------------------------------------------------------------
-- 4) 状态码与重试语义（回归：别被这次改动带坏）
----------------------------------------------------------------------

do
    reset()
    response = { body = "gone", headers = {}, code = 404 }
    local body, err = http.get("https://example.com/missing")
    eq(body, nil, "404 → nil")
    eq(err, "HTTP 404", "404 错误信息保持原格式")
    eq(#calls, 1, "404 不重试")
end

do
    -- 第一次 500、第二次 200：5xx 应重试并最终成功
    reset()
    local attempt = 0
    transport.request = function(req)
        attempt = attempt + 1
        calls[#calls + 1] = { url = req.url, headers = req.headers }
        if attempt == 1 then
            return 1, 500, {}, "HTTP/1.1 500 Server Error"
        end
        if req.sink then req.sink("recovered") end
        return 1, 200, {}, "HTTP/1.1 200 OK"
    end
    local body = http.get("https://example.com/flaky")
    eq(body, "recovered", "5xx 后重试成功")
    eq(attempt, 2, "5xx 重试了一次")
    transport.request = fake_request
end

----------------------------------------------------------------------
-- 5) 限流与退避：429 听 Retry-After，408 重试，退避指数增长且有上限
----------------------------------------------------------------------

local function flaky_responder(code, headers, body_text)
    local n = 0
    return function(req)
        n = n + 1
        calls[#calls + 1] = { url = req.url, headers = req.headers }
        if n == 1 then
            return 1, code, headers or {}, string.format("HTTP/1.1 %d Status", code)
        end
        if req.sink and body_text then req.sink(body_text) end
        return 1, 200, {}, "HTTP/1.1 200 OK"
    end
end

do
    reset()
    transport.request = flaky_responder(429, { ["retry-after"] = "2" }, "ok")
    local body = http.get("https://example.com/limited")
    eq(body, "ok", "429 后重试成功")
    eq(#calls, 2, "429 重试了一次")
    eq(math.floor(total_sleep() + 0.5), 2, "Retry-After: 2 被遵守（睡约 2 秒）")
    transport.request = fake_request
end

do
    reset()
    transport.request = flaky_responder(429, { ["retry-after"] = "9999" }, "ok")
    http.get("https://example.com/limited-huge")
    ok(total_sleep() <= 10.01, "Retry-After 被钳制到 10 秒内", tostring(total_sleep()))
    transport.request = fake_request
end

do
    reset()
    transport.request = flaky_responder(408, {}, "ok")
    eq(http.get("https://example.com/timeout"), "ok", "408 也会重试")
    eq(#calls, 2, "408 重试了一次")
    transport.request = fake_request
end

do
    reset()
    transport.request = flaky_responder(403, {}, "ok")
    local body, err = http.get("https://example.com/forbidden")
    eq(body, nil, "403 不重试（图床防盗链等）")
    eq(err, "HTTP 403", "403 错误信息保持原格式")
    eq(#calls, 1, "403 只请求一次")
    eq(#sleeps, 0, "403 不退避")
    transport.request = fake_request
end

do
    -- 连接层连续失败：退避应为指数增长（0.5 → 1.0），且带抖动（<= +0.25）
    reset()
    local n = 0
    transport.request = function(req)
        n = n + 1
        calls[#calls + 1] = { url = req.url, headers = req.headers }
        return nil, "closed"
    end
    local body = http.get("https://example.com/dead", nil, nil, 2)
    eq(body, nil, "持续失败最终返回 nil")
    eq(n, 3, "retries=2 → 共 3 次尝试")
    eq(#sleeps, 2, "两次重试各退避一次")
    ok(sleeps[1] >= 0.5 and sleeps[1] <= 0.75, "第一次退避 0.5s + 抖动", tostring(sleeps[1]))
    ok(sleeps[2] >= 1.0 and sleeps[2] <= 1.25, "第二次退避 1.0s + 抖动（指数增长）", tostring(sleeps[2]))
    transport.request = fake_request
end

----------------------------------------------------------------------
-- 6) 响应体字节上限：超限中断传输，且不重试
----------------------------------------------------------------------

do
    reset()
    response = { body = string.rep("x", 5000), headers = {} }
    local body, err = http.get("https://example.com/huge", nil, nil, 3, { max_bytes = 1000 })
    eq(body, nil, "超过 max_bytes → 返回 nil")
    ok(tostring(err):find("响应过大", 1, true) ~= nil, "错误里点明「响应过大」", tostring(err))
    eq(#calls, 1, "响应过大不重试（确定性错误）")
end

do
    reset()
    response = { body = string.rep("x", 5000), headers = {} }
    local body = http.get("https://example.com/probe", nil, nil, 3,
        { max_bytes = 1000, allow_truncated = true })
    eq(#body, 1000, "allow_truncated：拿到截断数据即算成功（连通性自检用）")
    eq(#calls, 1, "自检只请求一次")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
