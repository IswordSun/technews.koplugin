-- zhifou/diag.lua — 网络诊断：分阶段探测一台主机，把「卡在哪一步」变成可读结果
--
-- 为什么要它：设备（尤其定制 Android）上「所有源都抓不到」可能卡在完全不同的层
-- （DNS 解析 / TCP 连接 / TLS 握手 / HTTP / 解压），而在设备上又没有 adb、没有日志可看。
-- 这里把每一层单独跑一遍并记下耗时或错误原文，由 UI 直接显示在屏幕上。
--
-- 设计要点：
--   * 每一步都可能阻塞（DNS 尤其——KOReader 的超时管不到它），因此**调用方要把整个
--     probe 放进子进程**（Trapper:dismissableRunInSubprocess），这样卡住时界面仍可取消
--   * 所有网络原语都可注入（opts.resolve/connect/tls/http），便于单测与替换

local diag = {}

--- 简单的单调计时（socket.gettime 不可用时退回 os.time）
local function timer()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then return socket.gettime end
    return os.time
end

--- 探测阶段定义（顺序即执行顺序）
diag.STAGES = { "DNS", "TCP", "TLS", "HTTP", "gzip" }

-- 默认实现（真机路径）
local function default_resolve(host)
    local socket = require("socket")
    local ip, err = socket.dns.toip(host)
    if not ip then return nil, tostring(err or "解析失败") end
    -- toip 可能返回表（多地址）或字符串
    if type(ip) == "table" then ip = ip[1] end
    return ip
end

local function default_connect(ip, port, timeout)
    local socket = require("socket")
    local tcp = socket.tcp()
    if not tcp then return nil, "无法创建 socket" end
    tcp:settimeout(timeout or 5)
    local ok, err = tcp:connect(ip, port)
    if not ok then
        pcall(function() tcp:close() end)
        return nil, tostring(err or "连接失败")
    end
    return tcp
end

--- 直接调 ssl.wrap 时必须补齐的两个参数（实测缺一不可）：
--   protocol → LuaSec 的 https.lua 默认 "any"
--   mode     → https.lua 里那句 "Force client mode"（params.mode = "client"）
-- 插件真实请求走 ssl.https.request，两者由 https.lua 自动补，所以这里缺参数
-- 只影响诊断自身，不影响抓取。
function diag.tls_params(host)
    return { server = host, verify = "none", protocol = "any", mode = "client" }
end

local function default_tls(tcp, host, timeout)
    local ok_ssl, ssl = pcall(require, "ssl")
    if not ok_ssl or not ssl then return nil, "LuaSec 不可用（KOReader 缺少 ssl 模块）" end
    tcp:settimeout(timeout or 5)
    local wrapped, err = ssl.wrap(tcp, diag.tls_params(host))
    if not wrapped then return nil, tostring(err or "TLS 包装失败") end
    local handshook, herr = wrapped:dohandshake()
    if not handshook then
        pcall(function() wrapped:close() end)
        return nil, tostring(herr or "TLS 握手失败")
    end
    return wrapped
end

--- 探测一台主机（或一个 URL）。
-- @param url 形如 "https://www.ithome.com/rss/"（只要有 scheme+host 即可）
-- @param opts { resolve=, connect=, tls=, http=, tcp_port=, timeout=, notes= }
-- @return { host=, ip=, stages = { { name=, ok=, ms=, detail= }, ... }, summary= }
function diag.probe(url, opts)
    opts = opts or {}
    local now = opts.now or timer()
    local resolve = opts.resolve or default_resolve
    local connect = opts.connect or default_connect
    local tls_wrap = opts.tls or default_tls
    local http_get = opts.http
    local timeout = opts.timeout or 5

    local scheme, host = tostring(url):match("^(https?)://([^/]+)")
    if not host then
        scheme, host = tostring(url):match("^(https?)://([^/]+)$")
    end
    local result = { url = url, host = host, scheme = scheme, stages = {} }

    local function stage(name, fn)
        local started = now()
        local ok, detail = fn()
        result.stages[#result.stages + 1] = {
            name = name, ok = ok and true or false,
            ms = math.floor((now() - started) * 1000 + 0.5),
            detail = detail,
        }
        return ok
    end

    -- 1) DNS
    local ip
    local dns_ok = stage("DNS", function()
        local resolved, err = resolve(host)
        if not resolved then return false, tostring(err) end
        ip = resolved
        result.ip = resolved
        return true, tostring(resolved)
    end)
    if not dns_ok then
        result.summary = "DNS 解析失败（问题在这一层：设备解析不了域名）"
        return result
    end

    -- 2) TCP
    local port = opts.tcp_port or (scheme == "https" and 443 or 80)
    local tcp
    local tcp_ok = stage("TCP", function()
        local conn, err = connect(ip, port, timeout)
        if not conn then return false, string.format("%s:%d %s", ip, port, tostring(err)) end
        tcp = conn
        return true, string.format("%s:%d 已连接", ip, port)
    end)
    if not tcp_ok then
        result.summary = "TCP 连接失败（域名能解析，但连不上该主机/端口）"
        return result
    end

    -- 3) TLS（仅 https）
    local conn = tcp
    local tls_failed = false
    if scheme == "https" then
        local tls_ok = stage("TLS", function()
            local wrapped, err = tls_wrap(tcp, host, timeout)
            if not wrapped then return false, tostring(err) end
            conn = wrapped
            return true, "握手完成"
        end)
        if not tls_ok then
            -- 不提前返回：继续走 HTTP 一步（走的是插件自己的请求路径），
            -- 这样一次就能同时看到「TLS 报错」与「插件实际请求的报错」
            tls_failed = true
        end
    end
    pcall(function() conn:close() end)

    -- 4) HTTP（走插件自己的 http.lua，带同样的请求头/超时/解压逻辑）
    local http_ok = stage("HTTP", function()
        if not http_get then
            local http = require("zhifou.http")
            http_get = function(target, o)
                return http.get(target, o and o.block, o and o.total, 0, o)
            end
        end
        local body, err = http_get(url, {
            block = timeout, total = timeout * 3, max_bytes = 256 * 1024,
            allow_truncated = true,
        })
        if not body then return false, tostring(err) end
        return true, string.format("取到 %d 字节", #body)
    end)

    -- 5) gzip 自检（本平台能否解压——v0.1.15 那次事故的根因就是这里）
    stage("gzip", function()
        local ok, gz = pcall(require, "zhifou.gzip")
        if not ok or type(gz) ~= "table" then return false, "解压模块加载失败" end
        if not gz.available() then
            local _, why = gz.available_detail()
            return false, tostring(why or "zlib 不可用")
        end
        -- 用一段已知 gzip 数据自测（"test" 的 gzip 流）
        local sample = "\31\139\8\0\0\0\0\0\2\255\43\73\45\46\1\0\12\126\127\216\4\0\0\0"
        local plain, err = gz.inflate(sample)
        if plain ~= "test" then
            return false, "解压自检失败：" .. tostring(err or plain)
        end
        return true, "解压正常"
    end)

    -- 结论优先级：TLS 阶段失败最值得说（但要区分「诊断直连 TLS 失败」与
    -- 「插件实际请求也失败」——两者不总是一致，前者的失败可能只是探测方式不同）
    if tls_failed then
        result.summary = http_ok
            and "直连 TLS 握手失败，但插件请求路径（HTTP 一步）成功——以 HTTP 一步为准"
            or "TLS 握手失败，且插件请求路径也失败（见 HTTP 一步的报错原文）"
    elseif http_ok then
        result.summary = "全链路可用"
    else
        result.summary = "HTTP 请求失败（DNS/TCP/TLS 都通，问题在请求或解压环节）"
    end
    return result
end

--- 把结果格式化成可直接显示的文本
function diag.render(result)
    if not result then return "（无结果）" end
    local lines = {}
    for _, stage in ipairs(result.stages or {}) do
        lines[#lines + 1] = string.format("%s %s：%d ms%s",
            stage.ok and "✓" or "✗", stage.name, stage.ms,
            stage.detail and ("　" .. stage.detail) or "")
    end
    if result.summary then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "结论：" .. result.summary
    end
    return table.concat(lines, "\n")
end

return diag
