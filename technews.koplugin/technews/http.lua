-- technews/http.lua — HTTPS GET（LuaSocket + LuaSec，带超时与重试）
--
-- 备注：部分站点偶发直接断开连接，表现为返回 "closed" 错误码，因此这里内置
-- 3 次重试（仅连接层错误与 5xx 重试，4xx 立即返回）；错误信息会区分
-- "连接失败 / HTTP 状态码 / 网络错误"。

local ltn12 = require("ltn12")
local socket = require("socket")
local https = require("ssl.https")
local socketutil = require("socketutil")
local logger = require("logger")

local http = {}

local UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

local function request_once(url, block_timeout, total_timeout, referer)
    local body = {}
    socketutil:set_timeout(
        block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
        total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
    local req_headers = {
        ["User-Agent"] = UA,
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8",
    }
    -- 部分图床 CDN（如少数派 cdnfile.sspai.com）不带 Referer 会返回 403；
    -- 而微信图床 mmbiz.qpic.cn 正相反：带第三方 Referer 会被换成 140x140 占位图。
    -- 因此是否附带 Referer 由调用方通过 opts.referer 显式决定，默认不附带。
    if referer then
        req_headers["Referer"] = referer
    end
    -- LuaSocket：成功时返回 (1, 状态码, headers, status)；失败时返回错误码
    local code, headers, status = socket.skip(1, https.request{
        url = url,
        headers = req_headers,
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
-- @param opts 可选：{ referer = "..." }，给出时随请求发送 Referer 头（图床防盗链用）
-- 备注：重试之间加短暂延迟，部分站点对高频请求会直接断连（closed），
-- 小幅退避能显著提高成功率。
-- 重试策略：仅连接层失败（错误信息无 "HTTP <状态码>"）与 HTTP 5xx 重试；
-- HTTP 4xx（失效订阅源的 404、图床 403 等）重试无意义，立即返回。
function http.get(url, block_timeout, total_timeout, retries, opts)
    retries = retries or 3
    local referer = opts and opts.referer
    local last_err
    for attempt = 1, retries + 1 do
        local body, err = request_once(url, block_timeout, total_timeout, referer)
        if body then
            return body
        end
        last_err = err
        -- 仅连接层错误（无 "HTTP <code>" 前缀）或 5xx 可重试；4xx 等立即返回，
        -- 避免每次失败都白等数轮超时与退避（如失效 feed 的 404）
        local http_code = tostring(err):match("^HTTP (%d+)")
        if attempt > retries or (http_code and http_code:sub(1, 1) ~= "5") then
            break
        end
        logger.warn("technews http retry:", url,
            "attempt=" .. attempt, tostring(err))
        socket.sleep(0.6)
    end
    logger.warn("technews http failed:", url, tostring(last_err))
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
