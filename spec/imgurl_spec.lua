-- spec/imgurl_spec.lua — technews 图片 URL 重写逻辑的单元测试
--
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/imgurl_spec.lua）
-- 不依赖任何测试框架；所有断言通过时退出码为 0，否则为 1。

-- 以脚本自身路径定位被测模块，保证从任意工作目录运行都成立
local spec_dir = (arg and arg[0] or "spec/imgurl_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local imgurl = dofile(spec_dir .. "/../technews.koplugin/technews/imgurl.lua")

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
        ("expected=%s actual=%s"):format(tostring(expected), tostring(actual)))
end

-- 统计子串出现次数（plain 查找），用于校验参数没有被重复追加
local function count(haystack, needle)
    local n = 0
    local pos = 1
    while true do
        local from, to = haystack:find(needle, pos, true)
        if not from then break end
        n = n + 1
        pos = to + 1
    end
    return n
end

local function recipe(width)
    return "?x-bce-process=image/resize,m_lfit,w_" .. width .. ",limit_1/quality,q_75"
end

----------------------------------------------------------------------
-- IT之家：已有 x-bce-process 查询串 → 整段替换（追加会被 CDN 忽略）
----------------------------------------------------------------------
do
    local input = "https://img.ithome.com/newsuploadfiles/2026/9/abc123.jpg"
        .. "?x-bce-process=image/format,f_auto"
    local out = imgurl.rewrite(input, 800)
    eq(out,
        "https://img.ithome.com/newsuploadfiles/2026/9/abc123.jpg" .. recipe(800),
        "带 x-bce-process 的 IT之家图片：替换查询串得到精确网址")
    ok(not out:find("format,f_auto", 1, true), "重写结果不含原有的 format,f_auto")
    eq(count(out, "x-bce-process"), 1, "重写结果只有一个 x-bce-process 参数")
    eq(count(out, "?"), 1, "重写结果只有一个 ? 分隔符")
end

----------------------------------------------------------------------
-- IT之家：无查询串 / http 协议 / 其他子域名
----------------------------------------------------------------------
do
    eq(imgurl.rewrite("https://img.ithome.com/a/b.png", 800),
        "https://img.ithome.com/a/b.png" .. recipe(800),
        "无查询串的 IT之家图片：直接追加配方")
    eq(imgurl.rewrite("http://img.ithome.com/a/b.jpg", 800),
        "http://img.ithome.com/a/b.jpg" .. recipe(800),
        "http:// 协议同样可重写且保留协议")
    eq(imgurl.rewrite("https://www.ithome.com/rss/cover.jpg", 800),
        "https://www.ithome.com/rss/cover.jpg" .. recipe(800),
        "www.ithome.com 域名也可重写")
end

----------------------------------------------------------------------
-- 宽度参数：800 与降级 480 只差 w 值
----------------------------------------------------------------------
do
    local input = "https://img.ithome.com/a.jpg?x-bce-process=image/format,f_auto"
    eq(imgurl.rewrite(input, 480),
        "https://img.ithome.com/a.jpg" .. recipe(480),
        "w_480 降级配方：仅宽度不同")
    eq(imgurl.rewrite(input, 800), "https://img.ithome.com/a.jpg" .. recipe(800),
        "w_800 与 w_480 结果互不相同")
end

----------------------------------------------------------------------
-- fragment 被剥离（查询串 + fragment 同时存在时一并处理）
----------------------------------------------------------------------
do
    eq(imgurl.rewrite("https://img.ithome.com/a.jpg#frag", 800),
        "https://img.ithome.com/a.jpg" .. recipe(800),
        "fragment 被剥离")
    eq(imgurl.rewrite("https://img.ithome.com/a.jpg?x-bce-process=image/format,f_auto#frag", 800),
        "https://img.ithome.com/a.jpg" .. recipe(800),
        "查询串与 fragment 同时存在时都被丢弃")
end

----------------------------------------------------------------------
-- 不可重写的输入：CNBeta / 其他域名 / nil / 空串
----------------------------------------------------------------------
do
    eq(imgurl.rewrite("https://static.cnbetacdn.com/article/2026/0919/abc.jpg", 800), nil,
        "CNBeta CDN 图片不重写（不支持缩放参数）")
    eq(imgurl.rewrite("https://static.cnbetacdn.com/article/2026/0919/abc.jpg"
        .. "?x-bce-process=image/format,f_auto", 800), nil,
        "CNBeta 图片即使带 x-bce-process 也不重写")
    eq(imgurl.rewrite("https://example.com/a.jpg", 800), nil,
        "无关域名不重写")
    eq(imgurl.rewrite(nil, 800), nil, "nil 输入返回 nil")
    eq(imgurl.rewrite("", 800), nil, "空串输入返回 nil")
    eq(imgurl.rewrite("https://img.ithome.com/a.jpg"), nil, "缺少 width 返回 nil")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
