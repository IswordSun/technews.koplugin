-- zhifou/http.lua — HTTP(S) GET（LuaSocket + LuaSec，带超时与重试）
--
-- 按 URL 前缀选择传输层：https:// 走 ssl.https，http:// 走 socket.http
-- （「一个」的 v3 API 与其图片 CDN 只提供 http，需要纯 HTTP 通道）。
--
-- 备注：部分站点偶发直接断开连接，表现为返回 "closed" 错误码，因此这里内置
-- 3 次重试（仅连接层错误与 5xx 重试，4xx 立即返回）；错误信息会区分
-- "连接失败 / HTTP 状态码 / 网络错误"。

local ltn12 = require("ltn12")
local socket = require("socket")
local https = require("ssl.https")
local socket_http = require("socket.http")
local socketutil = require("socketutil")
local logger = require("logger")

local http = {}

-- 单次响应的默认字节上限：feed/HTML/JSON 都远小于它，纯粹是防「异常大响应把内存打爆」
-- （调用方可用 opts.max_bytes 覆盖，例如图片按 2MB 卡）
http.MAX_RESPONSE_BYTES = 8 * 1024 * 1024
-- 退避上限与抖动上限（秒）
http.MAX_BACKOFF = 3
local MAX_RETRY_AFTER = 10
-- 这些错误是确定性的，重试只会白白再下一次整个响应体
local FATAL_ERRORS = { "解压失败", "响应过大" }

local UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

--- 解析 Retry-After（秒数或 HTTP-date），钳制在 [0, MAX_RETRY_AFTER]
local function retry_after_seconds(headers)
    local value = headers and headers["retry-after"]
    if not value then return nil end
    value = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    local seconds = tonumber(value)
    if seconds then
        return math.max(0, math.min(seconds, MAX_RETRY_AFTER))
    end
    -- HTTP-date："Wed, 21 Oct 2026 07:28:00 GMT"
    local day, month_name, year, hour, minute, sec =
        value:match("^%a+, (%d+) (%a+) (%d+) (%d+):(%d+):(%d+) GMT$")
    if not day then return nil end
    local months = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
                     Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }
    local month = months[month_name]
    if not month then return nil end
    local target = os.time{ year = tonumber(year), month = month, day = tonumber(day),
        hour = tonumber(hour), min = tonumber(minute), sec = tonumber(sec) }
    -- os.time{} 按本地时区解释；用「当前 UTC 时刻按本地解释」相减抵消时区差
    local delta = target - os.time(os.date("!*t"))
    return math.max(0, math.min(delta, MAX_RETRY_AFTER))
end

--- 是否是确定性错误（不该重试）
local function is_fatal(err)
    local text = tostring(err)
    for _, marker in ipairs(FATAL_ERRORS) do
        if text:find(marker, 1, true) then return true end
    end
    return false
end

-- @return body, err, meta（meta = { headers =, truncated =, status = }）
local function request_once(url, block_timeout, total_timeout, referer, opts)
    opts = opts or {}
    local max_bytes = opts.max_bytes or http.MAX_RESPONSE_BYTES
    local body = {}
    local received = 0
    local truncated = false
    socketutil:set_timeout(
        block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
        total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
    local req_headers = {
        ["User-Agent"] = UA,
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8",
        -- 声明支持压缩：feed/HTML/JSON 压完能小一个数量级。
        -- 实测「读首诗再睡觉」feed 2.01MB → 209KB——它原本每次抓取都要下满 2MB，
        -- 在设备端超过 30s 总超时 → 重试 4 次 ≈ 卡两分钟。图片不受影响
        -- （本身已压缩，服务端不会再压）。
        ["Accept-Encoding"] = "gzip, deflate",
    }
    -- 部分图床 CDN（如少数派 cdnfile.sspai.com）不带 Referer 会返回 403；
    -- 而微信图床 mmbiz.qpic.cn 正相反：带第三方 Referer 会被换成 140x140 占位图。
    -- 因此是否附带 Referer 由调用方通过 opts.referer 显式决定，默认不附带。
    if referer then
        req_headers["Referer"] = referer
    end
    local transport = url:match("^http://") and socket_http or https
    -- LuaSocket：成功时返回 (1, 状态码, headers, status)；失败时返回错误码
    -- （status 状态行只在排错时有用，判定一律用数字状态码）
    -- 手写 sink：统计字节数，超过上限直接让 LuaSocket 中断传输
    -- （LuaSocket 的 sink 返回 nil 即中止，避免把异常大响应整份读进内存）
    local sink = function(chunk)
        if not chunk then return 1 end
        if received + #chunk > max_bytes then
            -- 超出上限：只留到上限为止的那一段（allow_truncated 的调用方拿它当「通了」的证据），
            -- 然后返回 nil 让 LuaSocket 立刻中断传输
            local room = max_bytes - received
            if room > 0 then body[#body + 1] = chunk:sub(1, room) end
            received = max_bytes
            truncated = true
            return nil
        end
        received = received + #chunk
        body[#body + 1] = chunk
        return 1
    end
    local code, headers = socket.skip(1, transport.request{
        url = url,
        headers = req_headers,
        sink = sink,
    })
    if truncated and opts.allow_truncated then
        -- 只关心「通不通」的调用方（如连通性自检）：拿到够用的数据就算成功
        return table.concat(body), nil, { headers = headers, truncated = true }
    end
    if truncated then
        return nil, string.format("响应过大（超过 %d 字节已中止）", max_bytes)
    end
    if not code then
        return nil, tostring(headers) or "request failed"
    end
    if type(code) ~= "number" then
        -- "closed" / "timeout" 等连接层错误码
        return nil, "连接失败（" .. tostring(code) .. "）"
    end
    local meta = { headers = headers, status = code }
    -- 只认数字状态码 200：LuaSocket 成功时 code 就是数字状态，
    -- 旧的 `status:find("200")` 兜底会把任何含 "200" 的状态行当成成功
    -- （status 只在日志里有意义，这里不再用它判定）
    if code ~= 200 then
        return nil, "HTTP " .. tostring(code), meta
    end
    local body_text = table.concat(body)
    -- 服务端压缩过就必须解压，否则上层拿到的是二进制乱码（解析会失败得莫名其妙）；
    -- 少数 CDN 即使没被请求也会回 gzip，所以这里只看响应头，不看我们请求了什么
    local encoding = headers and headers["content-encoding"]
    if encoding and encoding ~= "" and encoding ~= "identity" then
        local gzip = require("zhifou.gzip")
        local plain, unzip_err = gzip.inflate(body_text)
        if not plain then
            return nil, string.format("解压失败（%s：%s）", tostring(encoding), tostring(unzip_err)), meta
        end
        return plain, nil, meta
    end
    return body_text, nil, meta
end

-- 可重试的状态码：5xx（服务端抽风）、408/425（超时/过早）、429（限流）
local function retryable_status(code)
    local text = tostring(code)
    return text:sub(1, 1) == "5" or text == "408" or text == "425" or text == "429"
end

--- GET 请求（自动重试），返回响应体或 (nil, 错误信息)
-- @param url
-- @param block_timeout 单次阻塞超时（秒）
-- @param total_timeout 总超时（秒）
-- @param retries 重试次数（默认 3，即最多尝试 4 次）
-- @param opts 可选：
--   referer        随请求发送 Referer 头（图床防盗链用）
--   max_bytes      响应体字节上限（默认 http.MAX_RESPONSE_BYTES）
--   allow_truncated 超限时把已收到的部分当成功返回（只关心「通不通」的自检用）
-- 重试策略：连接层失败与 5xx/408/425/429 重试；其余 4xx 立即返回
-- （失效 feed 的 404、图床 403 重试无意义）。退避为指数 + 抖动，
-- 429 若带 Retry-After 则优先听服务端的（钳制到 10 秒内）。
function http.get(url, block_timeout, total_timeout, retries, opts)
    retries = retries or 3
    opts = opts or {}
    local referer = opts.referer
    local last_err
    for attempt = 1, retries + 1 do
        local body, err, meta = request_once(url, block_timeout, total_timeout, referer, opts)
        if body then
            return body
        end
        last_err = err
        local http_code = tostring(err):match("^HTTP (%d+)")
        local fatal = is_fatal(err) or (http_code and not retryable_status(http_code))
        if attempt > retries or fatal then
            break
        end
        -- 退避：0.5 / 1 / 2 秒（上限 MAX_BACKOFF）+ 0~250ms 抖动，
        -- 避免多个源同时失败后同步重试（惊群）
        local delay = math.min(0.5 * 2 ^ (attempt - 1), http.MAX_BACKOFF)
        local wait = retry_after_seconds(meta and meta.headers)
        if wait == nil then
            wait = delay + math.random() * 0.25
        end
        logger.warn("zhifou http retry:", url,
            string.format("attempt=%d wait=%.2fs", attempt, wait), tostring(err))
        socket.sleep(wait)
    end
    logger.warn("zhifou http failed:", url, tostring(last_err))
    return nil, last_err
end

--- 流式下载到文件（进度回调、字节上限、手动跟随重定向；不重试——多源重试由调用方负责）。
-- @param url
-- @param dest_path 目标路径（目录须已存在）；先写 .part 再改名，失败清理
-- @param opts { on_progress = function(received)（返回 false 中止）, max_bytes =,
--               referer =, block_timeout =, total_timeout = }
-- 注意：on_progress 在 LuaSocket 的 socket 回调（C 调用栈）中执行，
-- 禁止在其中调用会 yield 的函数（如 Trapper:info），否则报
-- "attempt to yield across C-call boundary" 并中断下载；只可做纯 Lua 处理。
-- @return true | nil, 错误信息
function http.download(url, dest_path, opts)
    opts = opts or {}
    local tmp_path = dest_path .. ".part"
    local target = url

    -- GitHub Release 资产会 302 到 objects.githubusercontent.com；LuaSec 自带的
    -- 跨主机 https 重定向不可靠，这里手动跟随（最多 4 跳）
    for _ = 1, 4 do
        os.remove(tmp_path)
        local file, open_err = io.open(tmp_path, "wb")
        if not file then
            return nil, "无法写入文件（" .. tostring(open_err) .. "）"
        end

        local headers = { ["User-Agent"] = UA }
        if opts.referer then
            headers["Referer"] = opts.referer
        end
        local received, abort_err = 0, nil
        local file_sink = ltn12.sink.file(file)
        local sink = function(chunk, err)
            if chunk then
                received = received + #chunk
                if opts.max_bytes and received > opts.max_bytes then
                    abort_err = "文件超过大小上限"
                    file_sink(nil, abort_err)
                    return nil, abort_err
                end
                if opts.on_progress and opts.on_progress(received) == false then
                    abort_err = "已取消"
                    file_sink(nil, abort_err)
                    return nil, abort_err
                end
            end
            return file_sink(chunk, err)
        end

        socketutil:set_timeout(
            opts.block_timeout or socketutil.FILE_BLOCK_TIMEOUT,
            opts.total_timeout or 300)
        local code, resp_headers = socket.skip(1, https.request{
            url = target,
            headers = headers,
            sink = sink,
            redirect = false,
        })
        socketutil:reset_timeout()
        pcall(function() file:close() end)

        if abort_err then
            os.remove(tmp_path)
            return nil, abort_err
        end
        if not code then
            os.remove(tmp_path)
            return nil, tostring(resp_headers) or "request failed"
        end
        if type(code) ~= "number" then
            os.remove(tmp_path)
            return nil, "连接失败（" .. tostring(code) .. "）"
        end
        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            local location = resp_headers and resp_headers.location
            os.remove(tmp_path)
            if not location or location == "" then
                return nil, "重定向缺少地址"
            end
            target = location
        elseif code == 200 then
            os.remove(dest_path)
            if os.rename(tmp_path, dest_path) then
                return true
            end
            -- 跨文件系统兜底：复制
            local src = io.open(tmp_path, "rb")
            local dst = src and io.open(dest_path, "wb")
            if not (src and dst) then
                if src then src:close() end
                os.remove(tmp_path)
                return nil, "无法保存下载文件"
            end
            dst:write(src:read("*all"))
            src:close()
            dst:close()
            os.remove(tmp_path)
            return true
        else
            os.remove(tmp_path)
            return nil, "HTTP " .. tostring(code)
        end
    end
    return nil, "重定向次数过多"
end

return http
