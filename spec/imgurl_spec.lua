-- spec/imgurl_spec.lua — zhifou 图片 URL 重写逻辑的单元测试
--
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/imgurl_spec.lua）
-- 不依赖任何测试框架；所有断言通过时退出码为 0，否则为 1。

-- 以脚本自身路径定位被测模块，保证从任意工作目录运行都成立
local spec_dir = (arg and arg[0] or "spec/imgurl_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local imgurl = dofile(spec_dir .. "/../zhifou.koplugin/zhifou/imgurl.lua")

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
    -- PNG/GIF 源改用「CDN 直接输出 JPEG」的配方（实测 PNG 163KB → JPEG 127KB）
    eq(imgurl.rewrite("https://img.ithome.com/a/b.png", 800),
        "https://img.ithome.com/a/b.png" .. recipe(800) .. "/format,f_jpg",
        "IT之家 PNG：改用转 JPEG 配方")
    eq(imgurl.rewrite("https://img.ithome.com/a/b.JPEG", 800),
        "https://img.ithome.com/a/b.JPEG" .. recipe(800),
        "IT之家 JPEG：后缀大小写不敏感，仍用原配方（不重复转码）")
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
-- 雷锋网：七牛 CDN，丢弃原 imageMogr2 查询串 → 改用 imageView2 配方
-- （模式 2 = 等比缩到不超过目标宽，实测不会放大小图）
----------------------------------------------------------------------
do
    local base = "https://static.leiphone.com/uploads/new/images/20260920/abc.jpg"
    local http_base = base:gsub("^https", "http")
    local out = imgurl.rewrite(base .. "?imageMogr2/quality/90", 800)

    eq(out, base .. "?imageView2/2/w/800",
        "带 imageMogr2/quality/90 的雷锋网图片：替换查询串得到精确网址")
    ok(not out:find("imageMogr2", 1, true), "重写结果不含原有的 imageMogr2")
    eq(count(out, "?"), 1, "重写结果只有一个 ? 分隔符")
    eq(imgurl.rewrite(base, 800), base .. "?imageView2/2/w/800",
        "无查询串的雷锋网图片：直接追加 imageView2 配方")
    eq(imgurl.rewrite(base, 480), base .. "?imageView2/2/w/480",
        "w_480 降级配方：仅宽度不同")
    eq(imgurl.rewrite(http_base, 800), http_base .. "?imageView2/2/w/800",
        "http:// 协议同样可重写且保留协议")
    eq(imgurl.rewrite(base .. "?imageMogr2/quality/90#frag", 800),
        base .. "?imageView2/2/w/800",
        "查询串与 fragment 同时存在时都被丢弃")
end

----------------------------------------------------------------------
-- 爱范儿 / 极客公园 / 少数派：同款七牛 imageView2 配方
----------------------------------------------------------------------
do
    local new_hosts = {
        { name = "爱范儿 s3.ifanr.com", base = "https://s3.ifanr.com/abc/20260920.jpg" },
        { name = "极客公园 imgslim.geekpark.net", base = "https://imgslim.geekpark.net/photo/a.png" },
        { name = "少数派 cdnfile.sspai.com", base = "https://cdnfile.sspai.com/2026/09/20/a.jpg" },
    }
    for _, h in ipairs(new_hosts) do
        local jpg_base = h.base:gsub("%.png$", ".jpg")
        eq(imgurl.rewrite(jpg_base, 800), jpg_base .. "?imageView2/2/w/800",
            h.name .. "：JPEG 无查询串 → w_800 精确网址")
        eq(imgurl.rewrite(jpg_base, 480), jpg_base .. "?imageView2/2/w/480",
            h.name .. "：JPEG 无查询串 → w_480 精确网址")
        local replaced = imgurl.rewrite(jpg_base .. "?imageView2/2/w/1200", 800)
        eq(replaced, jpg_base .. "?imageView2/2/w/800",
            h.name .. "：已有 imageView2 查询串被整段替换")
        eq(count(replaced, "?"), 1, h.name .. "：重写结果只有一个 ? 分隔符")
        eq(replaced:find("w/1200", 1, true), nil, h.name .. "：重写结果不含原宽度 1200")
        -- 同一路径换成 PNG 后缀即走转 JPEG 配方（七牛实测 100KB → 22KB，4.6×）
        local png_base = h.base:gsub("%.jpg$", ".png")
        eq(imgurl.rewrite(png_base, 800),
            png_base .. "?imageView2/2/w/800/format/jpg/quality/75",
            h.name .. "：PNG 源 → 转 JPEG 配方")
    end

    eq(imgurl.rewrite("https://cdnfile.sspai.com/2026/09/20/a.jpg?x=1#frag", 800),
        "https://cdnfile.sspai.com/2026/09/20/a.jpg?imageView2/2/w/800",
        "少数派图片：查询串与 fragment 同时存在时都被丢弃")
    eq(imgurl.rewrite("http://s3.ifanr.com/a.jpg", 800),
        "http://s3.ifanr.com/a.jpg?imageView2/2/w/800",
        "爱范儿 http:// 协议同样可重写且保留协议")
end

----------------------------------------------------------------------
-- 不可重写的输入：CNBeta / 雷锋网非图床子域 / 其他域名 / nil / 空串
----------------------------------------------------------------------
do
    eq(imgurl.rewrite("https://static.cnbetacdn.com/article/2026/0919/abc.jpg", 800), nil,
        "CNBeta CDN 图片不重写（不支持缩放参数）")
    eq(imgurl.rewrite("https://static.cnbetacdn.com/article/2026/0919/abc.jpg"
        .. "?x-bce-process=image/format,f_auto", 800), nil,
        "CNBeta 图片即使带 x-bce-process 也不重写")
    eq(imgurl.rewrite("https://www.leiphone.com/cover.jpg", 800), nil,
        "雷锋网非图床子域（www）不重写")
    eq(imgurl.rewrite("https://mmbiz.qpic.cn/sz_mmbiz_jpg/abc/640", 800), nil,
        "微信图床 mmbiz.qpic.cn 不重写（imageView2 被忽略，路径式缩放无效）")
    eq(imgurl.rewrite("https://mmbiz.qpic.cn/sz_mmbiz_jpg/abc/0?wx_fmt=jpeg", 800), nil,
        "微信图床带查询串同样不重写")
    eq(imgurl.rewrite("https://example.com/a.jpg", 800), nil,
        "无关域名不重写")
    eq(imgurl.rewrite(nil, 800), nil, "nil 输入返回 nil")
    eq(imgurl.rewrite("", 800), nil, "空串输入返回 nil")
    eq(imgurl.rewrite("https://img.ithome.com/a.jpg"), nil, "缺少 width 返回 nil")
end

----------------------------------------------------------------------
-- Referer 查询：仅少数派图床需要；mmbiz 明确不能带，未知域名返回 nil
----------------------------------------------------------------------
do
    eq(imgurl.referer("https://cdnfile.sspai.com/2026/09/20/a.jpg"), "https://sspai.com/",
        "少数派图床返回 https://sspai.com/")
    eq(imgurl.referer("http://cdnfile.sspai.com/a.jpg?imageView2/2/w/800"), "https://sspai.com/",
        "带查询串与 http:// 的少数派图片同样返回 Referer")
    eq(imgurl.referer("https://cdnfile.sspai.com.evil.com/a.jpg"), nil,
        "相似域名 cdnfile.sspai.com.evil.com 不匹配")
    eq(imgurl.referer("https://mmbiz.qpic.cn/sz_mmbiz_jpg/abc/0?wx_fmt=jpeg"), nil,
        "微信图床 mmbiz.qpic.cn 返回 nil（带第三方 Referer 会得到 140x140 占位图）")
    eq(imgurl.referer("https://s3.ifanr.com/a.jpg"), nil, "爱范儿返回 nil（无需 Referer）")
    eq(imgurl.referer("https://imgslim.geekpark.net/a.jpg"), nil, "极客公园返回 nil（无需 Referer）")
    eq(imgurl.referer("https://img.ithome.com/a.jpg"), nil, "IT之家返回 nil（无需 Referer）")
    eq(imgurl.referer("https://example.com/a.jpg"), nil, "未知域名返回 nil")
    eq(imgurl.referer(nil), nil, "referer(nil) 返回 nil")
    eq(imgurl.referer(""), nil, "referer 空串返回 nil")
end

----------------------------------------------------------------------
-- 「一个」image.wufazhuce.com（URL 无后缀，七牛系）：原图 3001x2000/792KB
-- 实测 w/800 → 800x533/37KB（21×）；无后缀时不带 lossy（判不出源格式）
----------------------------------------------------------------------
do
    local base = "http://image.wufazhuce.com/FvbZIwVIXDCd8VYPldoC90YJz3iH"
    eq(imgurl.rewrite(base, 800), base .. "?imageView2/2/w/800",
        "「一个」图片：无后缀也重写（走通用七牛配方）")
    eq(imgurl.rewrite(base, 480), base .. "?imageView2/2/w/480", "「一个」图片：宽度可降级")
    eq(imgurl.referer(base), "https://wufazhuce.com/",
        "「一个」图片需要站点 Referer（未变）")
    eq(imgurl.rewrite("https://image.wufazhuce.com.evil.com/a.jpg", 800), nil,
        "相似域名 image.wufazhuce.com.evil.com 不匹配")
end

----------------------------------------------------------------------
-- 知乎（zhimg）：JPEG 不重写（_720w 已是缩略图，参数被 CDN 忽略）；
-- GIF 换后缀 .gif→.jpg 让 CDN 返回首帧静态图（实测 8.6MB → 19.7KB）
----------------------------------------------------------------------
do
    local jpeg = "https://picx.zhimg.com/v2-abc123_720w.jpg?source=8673f162"
    eq(imgurl.rewrite(jpeg, 800), nil,
        "知乎 JPEG：不重写（返回 nil，调用方下原图）")
    eq(imgurl.rewrite("https://pica.zhimg.com/v2-def_720w.gif", 800),
        "https://pica.zhimg.com/v2-def_720w.jpg",
        "知乎 GIF：后缀改 .jpg → 首帧静态图（且丢掉 ?source= 追踪参数）")
    eq(imgurl.rewrite("https://pic1.zhimg.com/v2-ghi.gif?source=x#f", 800),
        "https://pic1.zhimg.com/v2-ghi.jpg",
        "知乎 GIF：无 _720w 后缀、带查询串与 fragment 也能改写")
    eq(imgurl.rewrite("https://picx.zhimg.com/v2-abc.png", 800), nil,
        "知乎 PNG：不重写（后缀替换只针对 GIF）")
    eq(imgurl.referer("https://picx.zhimg.com/v2-abc_720w.jpg"), "https://news-at.zhihu.com/",
        "知乎图片仍需 Referer（未变）")
end

----------------------------------------------------------------------
-- 灰度：七牛系走 imageMogr2 colorspace/Gray（返回 1 分量真灰度 JPEG）；
-- IT之家无灰度配方（BCE 实测 400 InvalidArgument）→ 回退彩色/转 JPEG 配方
----------------------------------------------------------------------
do
    local huxiu = "https://img.huxiucdn.com/article/content/26-09-28/a.png"
    eq(imgurl.rewrite(huxiu, 800, { gray = true }),
        huxiu .. "?imageMogr2/thumbnail/800x>/format/jpg/quality/75/colorspace/Gray",
        "虎嗅 PNG + 灰度：改用 imageMogr2 灰度配方（thumbnail/<w>x> 只缩不放）")
    eq(imgurl.rewrite("https://s3.ifanr.com/a/b.jpg", 480, { gray = true }),
        "https://s3.ifanr.com/a/b.jpg"
            .. "?imageMogr2/thumbnail/480x>/format/jpg/quality/75/colorspace/Gray",
        "爱范儿 JPEG + 灰度：宽度随参数变化")
    eq(imgurl.rewrite("https://img.ithome.com/a/b.jpg", 800, { gray = true }),
        "https://img.ithome.com/a/b.jpg" .. recipe(800),
        "IT之家无灰度配方：回退彩色配方而不是返回 nil")
    eq(imgurl.rewrite("https://img.ithome.com/a/b.png", 800, { gray = true }),
        "https://img.ithome.com/a/b.png" .. recipe(800) .. "/format,f_jpg",
        "IT之家 PNG + 灰度：回退转 JPEG 配方（仍是体积最省的可用组合）")
    eq(imgurl.rewrite("https://mmbiz.qpic.cn/a/b/0", 800, { gray = true }), nil,
        "不可重写的图床开灰度同样返回 nil（调用方回退原图）")
    eq(imgurl.rewrite(huxiu, 800), huxiu .. "?imageView2/2/w/800/format/jpg/quality/75",
        "未开灰度时虎嗅 PNG 仍走彩色转 JPEG 配方")
end

----------------------------------------------------------------------
-- source_ext：源后缀判定（决定是否转 JPEG）
----------------------------------------------------------------------
do
    eq(imgurl.source_ext("https://a.com/x.PNG"), "png", "大写后缀归一为小写")
    eq(imgurl.source_ext("https://a.com/x.jpeg?q=1#f"), "jpg", "jpeg 归一为 jpg，且忽略查询串与 fragment")
    eq(imgurl.source_ext("https://a.com/x.gif"), "gif", "gif 识别正确")
    eq(imgurl.source_ext("https://a.com/noext"), nil, "无后缀返回 nil")
    eq(imgurl.source_ext(nil), nil, "nil 返回 nil")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
