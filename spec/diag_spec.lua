-- spec/diag_spec.lua — 网络诊断（diag.lua）分阶段探测的单元测试
--
-- 覆盖：DNS 失败即止、TCP 失败即止、TLS 失败即止、HTTP 失败给出结论、
-- 全通时结论为「全链路可用」、gzip 自检能发现解压异常、render 输出可读。
-- 所有网络原语都注入假实现，不联网。

local spec_dir = (arg and arg[0] or "spec/diag_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = spec_dir .. "/../zhifou.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path
local diag = require("zhifou.diag")

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
    ok(actual == expected, name, ("实际=%s 期望=%s"):format(tostring(actual), tostring(expected)))
end

local function stage_of(result, name)
    for _, stage in ipairs(result.stages) do
        if stage.name == name then return stage end
    end
end

-- 可控时钟：每次调用 +0.05 秒，便于断言 ms 计算
local function fake_now()
    local t = 0
    return function() t = t + 0.05; return t end
end

local base = {
    now = fake_now(),
    resolve = function() return "1.2.3.4" end,
    connect = function() return { close = function() end } end,
    tls = function() return { close = function() end, dohandshake = function() return true end } end,
    http = function() return "body", nil end,
}



----------------------------------------------------------------------
-- 1) 全链路可用
----------------------------------------------------------------------

do
    local result = diag.probe("https://example.com/feed", base)
    eq(result.host, "example.com", "解析出主机名")
    eq(result.ip, "1.2.3.4", "记下解析出的 IP")
    eq(result.summary, "全链路可用", "全通时结论正确")
    eq(#result.stages, 5, "共 5 个阶段（DNS/TCP/TLS/HTTP/gzip）")
    eq(result.stages[1].name, "DNS", "阶段顺序从 DNS 开始")
    eq(result.stages[5].name, "gzip", "最后是 gzip 自检")
    ok(stage_of(result, "DNS").ok, "DNS 阶段通过")
    ok(stage_of(result, "gzip").ok, "gzip 自检通过（本机 libz 可用）")
    ok(stage_of(result, "DNS").ms >= 0, "记录耗时（ms）")
end

----------------------------------------------------------------------
-- 2) DNS 失败：后面的阶段不该再跑（省时间，也让结论明确）
----------------------------------------------------------------------

do
    local opts = {}
    for k, v in pairs(base) do opts[k] = v end
    opts.now = fake_now()
    opts.resolve = function() return nil, "name resolution failed" end
    local result = diag.probe("https://example.com/feed", opts)
    eq(#result.stages, 1, "DNS 失败后只有 1 个阶段")
    eq(result.stages[1].ok, false, "DNS 阶段标记失败")
    ok(tostring(result.summary):find("DNS", 1, true) ~= nil, "结论指向 DNS", tostring(result.summary))
    ok(tostring(result.stages[1].detail):find("resolution", 1, true) ~= nil,
        "保留原始错误原文", tostring(result.stages[1].detail))
end

----------------------------------------------------------------------
-- 3) TCP 失败 / TLS 失败
----------------------------------------------------------------------

do
    local opts = {}
    for k, v in pairs(base) do opts[k] = v end
    opts.now = fake_now()
    opts.connect = function() return nil, "connection refused" end
    local result = diag.probe("https://example.com/feed", opts)
    eq(#result.stages, 2, "TCP 失败后停在 TCP")
    ok(tostring(result.summary):find("TCP", 1, true) ~= nil, "结论指向 TCP", tostring(result.summary))
end

do
    local opts = {}
    for k, v in pairs(base) do opts[k] = v end
    opts.now = fake_now()
    opts.tls = function() return nil, "handshake failure" end
    local result = diag.probe("https://example.com/feed", opts)
    -- TLS 失败**不再提前返回**：继续跑 HTTP 一步，一次就能同时看到
    -- 「TLS 的报错」与「插件实际请求路径的报错」
    eq(#result.stages, 5, "TLS 失败仍继续跑完 HTTP 与 gzip 阶段")
    eq(stage_of(result, "TLS").ok, false, "TLS 阶段标记失败")
    ok(tostring(stage_of(result, "TLS").detail):find("handshake", 1, true) ~= nil,
        "保留 TLS 的原始报错", tostring(stage_of(result, "TLS").detail))
    eq(stage_of(result, "HTTP").ok, true, "HTTP 阶段仍然执行（走插件自己的请求路径）")
    ok(tostring(result.summary):find("TLS", 1, true) ~= nil, "结论指向 TLS", tostring(result.summary))
end

----------------------------------------------------------------------
-- 7) ssl.wrap 的参数（真机上先后漏过 protocol 与 mode，各挂一次）
----------------------------------------------------------------------

do
    local params = diag.tls_params("example.com")
    eq(params.server, "example.com", "带上 server（SNI）")
    eq(params.protocol, "any", "补了 protocol=any（https.lua 的默认）")
    eq(params.mode, "client", "补了 mode=client（https.lua 的 Force client mode）")
    eq(params.verify, "none", "诊断不校验证书（只测能否握手）")
end

----------------------------------------------------------------------
-- 4) HTTP 失败（DNS/TCP/TLS 都通）→ 结论指向请求或解压
----------------------------------------------------------------------

do
    local opts = {}
    for k, v in pairs(base) do k = k; opts[k] = v end
    opts.now = fake_now()
    opts.http = function() return nil, "解压失败（gzip：zlib 不可用）" end
    local result = diag.probe("https://example.com/feed", opts)
    ok(tostring(result.summary):find("HTTP", 1, true) ~= nil, "结论指向 HTTP 环节", tostring(result.summary))
    ok(tostring(stage_of(result, "HTTP").detail):find("解压失败", 1, true) ~= nil,
        "详情保留插件报的原始错误", tostring(stage_of(result, "HTTP").detail))
end

----------------------------------------------------------------------
-- 5) http 协议（无 TLS 阶段）
----------------------------------------------------------------------

do
    local opts = {}
    for k, v in pairs(base) do opts[k] = v end
    opts.now = fake_now()
    local result = diag.probe("http://www.dgtle.com/rss/dgtle.xml", opts)
    eq(stage_of(result, "TLS"), nil, "http 源不跑 TLS 阶段")
    eq(stage_of(result, "TCP").detail, "1.2.3.4:80 已连接", "http 用 80 端口")
end

----------------------------------------------------------------------
-- 6) render：可读、含结论
----------------------------------------------------------------------

do
    local result = diag.probe("https://example.com/feed", base)
    local text = diag.render(result)
    ok(text:find("DNS", 1, true) ~= nil, "文本含 DNS")
    ok(text:find("结论：", 1, true) ~= nil, "文本含结论")
    ok(text:find("✓", 1, true) ~= nil, "成功的阶段带 ✓")
    eq(diag.render(nil), "（无结果）", "nil 结果有兜底文案")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
