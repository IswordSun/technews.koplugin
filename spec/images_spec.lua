-- spec/images_spec.lua — 图片数据判型与体积额度（zhifou/images.lua）的单元测试
--
-- 覆盖三件实测踩过的坑：
--   1) CDN 会换格式（PNG 源返回 JPEG）→ 必须按响应字节的魔数判型，不能信 URL 后缀
--   2) CDN 出错时会回 200 + HTML 错误页 → 不能被当成图片存进 EPUB
--   3) 单张无上限 / 整期无字节闸门时，一张巨图就能把整期推高数 MB
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/images_spec.lua）

local spec_dir = (arg and arg[0] or "spec/images_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local images = dofile(spec_dir .. "/../zhifou.koplugin/zhifou/images.lua")

----------------------------------------------------------------------
-- 极简断言工具（与其它 spec 保持一致）
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

-- 造样本：只用前几个字节的魔数，其余填充（判型只看魔数）
local function sample(kind, size)
    size = size or 64
    local heads = {
        jpg = "\255\216\255\224",
        png = "\137PNG\r\n\26\n",
        gif = "GIF89a",
        webp = "RIFF\0\0\0\0WEBP",
        html = "<!DOCTYPE ",
    }
    local head = heads[kind]
    return head .. string.rep("x", math.max(size - #head, 0))
end

----------------------------------------------------------------------
-- 1) 魔数判型
----------------------------------------------------------------------

do
    eq(images.ext_from_data(sample("jpg")), "jpg", "ext_from_data：JPEG（FF D8 FF）")
    eq(images.ext_from_data(sample("png")), "png", "ext_from_data：PNG")
    eq(images.ext_from_data(sample("gif")), "gif", "ext_from_data：GIF87a/89a")
    eq(images.ext_from_data(sample("webp")), "webp", "ext_from_data：WEBP（RIFF+WEBP）")
    eq(images.ext_from_data(sample("html")), nil, "ext_from_data：HTML 错误页不是图片")
    eq(images.ext_from_data(""), nil, "ext_from_data：空响应返回 nil")
    eq(images.ext_from_data(nil), nil, "ext_from_data：nil 返回 nil")
    eq(images.ext_from_data("PK\003\004" .. string.rep("\0", 40)), nil,
        "ext_from_data：ZIP 等其它二进制返回 nil")
end

----------------------------------------------------------------------
-- 2) 额度：单张上限 / 总额度 / 统计
----------------------------------------------------------------------

do
    local budget = images.new_budget({ max_image_bytes = 2000, max_total_bytes = 2500 })
    eq(budget:check(1999), "ok", "check：未超单张上限 → ok")
    eq(budget:check(2001), "too_large", "check：超单张上限 → too_large")
    eq(budget:check(2000), "ok", "check：正好等于单张上限 → ok")

    budget:add(1000)
    eq(budget:check(1400), "ok", "check：单张与总额都还够 → ok")
    eq(budget:check(1600), "over_budget", "check：超出整期额度 → over_budget（调用方应停止）")
    budget:add(1400)
    eq(budget.bytes, 2400, "add：累计字节正确")
    eq(budget:check(200), "over_budget", "check：剩余额度不足 → over_budget")

    budget:note_skip("too_large")
    budget:note_skip("too_large")
    budget:note_skip("not_image")
    local summary = budget:summary()
    eq(summary.images, 2, "summary：收下的张数")
    eq(summary.bytes, 2400, "summary：收下的字节")
    eq(summary.skipped, 3, "summary：放弃张数")
    eq(summary.skipped_reasons.too_large, 2, "summary：按原因计数（too_large）")
    eq(summary.skipped_reasons.not_image, 1, "summary：按原因计数（not_image）")
end

do
    -- 缺省额度来自模块常量
    local budget = images.new_budget()
    eq(budget.max_image_bytes, images.MAX_IMAGE_BYTES, "缺省单张上限取模块常量")
    eq(budget.max_total_bytes, images.MAX_TOTAL_BYTES, "缺省总额度取模块常量")
end

----------------------------------------------------------------------
-- 3) fetch：宽度降级、换格式后的判型、错误页拒绝、额度停止
----------------------------------------------------------------------

-- 记录每次下载的 URL，返回预先排好的响应
local function fake_downloader(responses)
    local calls = {}
    local fn = function(url)
        calls[#calls + 1] = url
        local response = table.remove(responses, 1)
        if not response then return nil, "没有更多响应" end
        return response.data, response.err
    end
    return fn, calls
end

-- 与 imgurl 行为一致的假重写：800 → w/800，480 → w/480
local function fake_rewrite(url, width)
    return url .. "?w/" .. width
end

do
    -- 首次下载返回 HTML 错误页 → 不换宽度重试（换也没用），直接放弃
    local download, calls = fake_downloader({
        { data = sample("html") },
        { data = sample("jpg") },
    })
    local image, err = images.fetch("https://a.com/x.jpg", {
        download = download, rewrite = fake_rewrite,
    })
    eq(image, nil, "fetch：CDN 返回 HTML 错误页 → 拒绝（不写进 EPUB）")
    eq(err, "not_image", "fetch：错误原因为 not_image")
    eq(#calls, 1, "fetch：错误页不做宽度降级重试")
end

do
    -- 800 返回 400（超高图），480 成功：沿用旧的降级语义
    local download, calls = fake_downloader({
        { err = "HTTP 400" },
        { data = sample("png") },
    })
    local image = images.fetch("https://a.com/x.png", {
        download = download, rewrite = fake_rewrite,
    })
    ok(image ~= nil, "fetch：800 失败后 480 成功")
    eq(image.ext, "png", "fetch：扩展名按字节魔数判定")
    eq(#calls, 2, "fetch：正好尝试了两个宽度")
    ok(calls[2]:find("w/480", 1, true) ~= nil, "fetch：第二次用的是 480 配方")
end

do
    -- 单张超限：800 超大 → 480 仍超大 → 放弃并计数
    local big = string.rep("y", 5000)
    local download = fake_downloader({
        { data = sample("jpg", 0) .. big },
        { data = sample("jpg", 0) .. big },
    })
    local budget = images.new_budget({ max_image_bytes = 4000, max_total_bytes = 100000 })
    local image, err = images.fetch("https://a.com/big.jpg", {
        download = download, rewrite = fake_rewrite, budget = budget,
    })
    eq(image, nil, "fetch：两个宽度都超单张上限 → 放弃")
    eq(err, "too_large", "fetch：放弃原因为 too_large")
    eq(budget:summary().skipped_reasons.too_large, 1, "fetch：超限计入统计")
end

do
    -- 800 超大、480 可用 → 收下小的那张
    local download = fake_downloader({
        { data = sample("jpg", 0) .. string.rep("y", 5000) },
        { data = sample("jpg", 0) .. string.rep("y", 100) },
    })
    local budget = images.new_budget({ max_image_bytes = 4000, max_total_bytes = 100000 })
    local image = images.fetch("https://a.com/x.jpg", {
        download = download, rewrite = fake_rewrite, budget = budget,
    })
    ok(image ~= nil, "fetch：800 超限但 480 可用 → 收下")
    eq(budget:summary().images, 1, "fetch：收下的图计入额度")
    ok(budget.bytes <= 4000, "fetch：计入的字节数不超过单张上限")
end

do
    -- 整期额度用尽：返回 over_budget，调用方据此停止后续下载
    local download = fake_downloader({
        { data = sample("jpg", 0) .. string.rep("y", 500) },
        { data = sample("jpg", 0) .. string.rep("y", 500) },
    })
    local budget = images.new_budget({ max_image_bytes = 10000, max_total_bytes = 800 })
    budget:add(600)   -- 先占掉大半额度：下一张 500 字节虽然不大，但放不下了
    local image, err = images.fetch("https://a.com/x.jpg", {
        download = download, rewrite = fake_rewrite, budget = budget,
    })
    eq(image, nil, "fetch：超出整期额度 → 放弃")
    eq(err, "over_budget", "fetch：放弃原因为 over_budget")
    eq(budget:summary().skipped_reasons.over_budget, 1, "fetch：额度耗尽计入统计")
end

do
    -- 不可重写的图床：只下一次原图，不因宽度重复下载同一张
    local download, calls = fake_downloader({ { data = sample("jpg") } })
    local image = images.fetch("https://unknown.com/x.jpg", { download = download })
    ok(image ~= nil, "fetch：无重写规则时直接下原图")
    eq(#calls, 1, "fetch：无重写规则时只请求一次")
    eq(calls[1], "https://unknown.com/x.jpg", "fetch：请求的就是原 URL")
end

do
    -- gray 透传给重写函数
    local seen_gray
    local download = fake_downloader({ { data = sample("jpg") } })
    images.fetch("https://a.com/x.jpg", {
        download = download,
        rewrite = function(url, width, opts)
            seen_gray = opts and opts.gray
            return url .. "?w/" .. width
        end,
        gray = true,
    })
    eq(seen_gray, true, "fetch：gray 选项透传给重写函数")
end

do
    -- 缺下载函数时报错而不是崩
    local image, err = images.fetch("https://a.com/x.jpg", {})
    eq(image, nil, "fetch：缺 download 返回 nil")
    ok(err ~= nil, "fetch：缺 download 给出原因")
end

----------------------------------------------------------------------
-- 失败分类（熔断用）：只有「这张图本身的问题」才不算图床故障
----------------------------------------------------------------------

do
    eq(images.is_host_failure("连接失败（timeout）"), true, "连接超时 → 算图床故障")
    eq(images.is_host_failure("HTTP 403"), true, "HTTP 403 → 算图床故障（如缺 Referer）")
    eq(images.is_host_failure("响应过大（超过 3145728 字节已中止）"), false,
        "响应过大（被中断）→ 不算图床故障（降宽度可解）")
    eq(images.classify_failure("响应过大（超过 3145728 字节已中止）"), "size",
        "响应过大 → 归类为 size（值得降档）")
    eq(images.classify_failure("HTTP 400"), "size",
        "HTTP 400 → 归类为 size（CDN 不接受该图缩放参数）")
    eq(images.classify_failure("HTTP 404"), "host", "HTTP 404 → 归类为 host")
    eq(images.classify_failure("too_large"), "size", "单张超限 → size（换宽度可解）")
    eq(images.classify_failure("not_image"), "image", "非图片 → image")
    eq(images.classify_failure("over_budget"), "budget", "额度耗尽 → budget")
    eq(images.is_host_failure("not_image"), false, "返回的不是图片 → 不算（换宽度也没用）")
    eq(images.is_host_failure("over_budget"), false, "整期额度耗尽 → 不算")
    eq(images.is_host_failure(nil), false, "nil → 不算（unknown 不触发熔断）")
    eq(images.MAX_HOST_FAILURES, 3, "熔断阈值 3 次")
    eq(images.DOWNLOAD_RETRIES, 1, "图片下载只重试 1 次")
    eq(images.DOWNLOAD_TIMEOUTS.total, 25, "图片下载总超时 25 秒")
end

----------------------------------------------------------------------
-- 主机名解析（熔断按主机记账）
----------------------------------------------------------------------

do
    eq(images.host_of("https://s3.ifanr.com/a/b.png?x=1"), "s3.ifanr.com", "取 https 主机名")
    eq(images.host_of("http://img.example.com/a.jpg"), "img.example.com", "取 http 主机名")
    eq(images.host_of("not a url"), nil, "非 URL → nil")
    eq(images.host_of(nil), nil, "nil → nil")
end

----------------------------------------------------------------------
-- 网络层失败不再降档重试（这是「一张图耗几分钟」的放大器）
----------------------------------------------------------------------

do
    -- 两个宽度都可用，但下载直接连接失败：只应尝试一次（不再试 480）
    local attempts = {}
    local result, err = images.fetch("https://img.example.com/a.jpg", {
        rewrite = function(url, width) return url .. "?w=" .. width end,
        download = function(target)
            attempts[#attempts + 1] = target
            return nil, "连接失败（timeout）"
        end,
    })
    eq(result, nil, "连接失败 → 无图")
    eq(err, "连接失败（timeout）", "错误原因原样返回（供熔断计数）")
    eq(#attempts, 1, "连接失败只尝试一次（不再退到 480 宽）")
    ok(attempts[1]:find("w=800", 1, true) ~= nil, "尝试的是 800 宽")

    -- 对照：单张太大 → 仍应降档到 480
    local attempts2 = {}
    local big = sample("jpg", 2100)   -- 合法 JPEG 魔数 + 超限体积
    local result2, err2 = images.fetch("https://img.example.com/big.jpg", {
        rewrite = function(url, width) return url .. "?w=" .. width end,
        budget = images.new_budget({ max_image_bytes = 1024, max_total_bytes = 10 * 1024 }),
        download = function(target)
            attempts2[#attempts2 + 1] = target
            return big, nil
        end,
    })
    eq(result2, nil, "单张超限 → 最终无图")
    eq(err2, "too_large", "原因是 too_large")
    eq(#attempts2, 2, "单张超限会降到 480 宽再试（与网络失败区分开）")
    ok(attempts2[2]:find("w=480", 1, true) ~= nil, "第二次尝试 480 宽")
end

----------------------------------------------------------------------
-- 图片分辨率：目标宽 → 候选宽度表（设置里可配；设备屏宽不同，需求不同）
----------------------------------------------------------------------

do
    -- 默认行为必须与之前一致（800 → 480），否则老设备上的观感与流量会突变
    local t = images.widths_for(nil)
    eq(t[1], 800, "未配置时目标宽 800")
    eq(t[2], 480, "未配置时降档 480（与旧行为一致）")
    eq(#images.WIDTHS, 2, "默认候选表两项")
    eq(images.WIDTHS[1], 800, "images.WIDTHS 目标宽 800")
    eq(images.WIDTHS[2], 480, "images.WIDTHS 降档 480")

    local big = images.widths_for(1404)          -- Boox Nova3 屏宽
    eq(big[1], 1404, "自动档：按屏宽取值")
    eq(big[2], 842, "降档 = 目标宽 × 0.6")
    ok(big[2] < big[1], "降档一定更小")

    eq(images.widths_for(480)[2], 288, "480 → 288")
    eq(images.widths_for(1200)[2], 720, "1200 → 720")

    -- 边界：过小抬到下限、过大压到上限、非法值回默认、降档可低于目标下限
    eq(images.widths_for(100)[1], images.MIN_WIDTH, "过小的目标宽抬到下限")
    eq(images.widths_for(9999)[1], images.MAX_WIDTH, "过大的目标宽压到上限")
    eq(images.widths_for("abc")[1], images.DEFAULT_WIDTH, "非法值回默认 800")
    local tiny = images.widths_for(images.MIN_WIDTH)
    ok(tiny[2] < tiny[1], "极小目标宽的降档仍更小")
    ok(tiny[2] >= images.MIN_DEGRADE_WIDTH, "降档不低于降档下限")
end

----------------------------------------------------------------------
-- 分辨率真的会进入 CDN 配方（换档必须改变实际请求的 URL）
----------------------------------------------------------------------

do
    local imgurl = dofile(spec_dir .. "/../zhifou.koplugin/zhifou/imgurl.lua")
    local src = "https://s3.ifanr.com/wp-content/uploads/2026/09/pic.jpg"
    local w1000 = imgurl.rewrite(src, images.widths_for(1000)[1])
    local w480 = imgurl.rewrite(src, images.widths_for(480)[1])
    ok(w1000:find("w/1000", 1, true) ~= nil, "1000 档写进七牛配方", tostring(w1000))
    ok(w480:find("w/480", 1, true) ~= nil, "480 档写进七牛配方", tostring(w480))
    ok(w1000 ~= w480, "不同档位产生不同 URL")
end

----------------------------------------------------------------------
-- 额度随分辨率缩放：选了更高分辨率不该变成「更多图被略过」
----------------------------------------------------------------------

do
    local MB = 1024 * 1024
    eq(images.scale_budget(12 * MB, 800), 12 * MB, "800（基准）额度不变")
    eq(images.scale_budget(12 * MB, 480), 12 * MB, "低于基准也不缩小")
    eq(images.scale_budget(12 * MB, nil), 12 * MB, "未配置按基准")
    eq(images.scale_budget(12 * MB, "abc"), 12 * MB, "非法值按基准")

    local w1072 = images.scale_budget(12 * MB, 1072)   -- Kindle PW
    local w1404 = images.scale_budget(12 * MB, 1404)   -- Boox Nova3
    local w1800 = images.scale_budget(12 * MB, 1800)
    ok(w1072 > 12 * MB and w1072 < 15 * MB, "1072 档略放大", tostring(w1072))
    ok(w1404 > w1072 and w1404 < 18 * MB, "1404 档再大些", tostring(w1404))
    ok(w1800 > w1404 and w1800 < 21 * MB, "1800 档最大", tostring(w1800))

    -- 实测依据：1800px 那期约 96KB/张（800px 约 39KB/张）→ 12.5MB 会撞上 12MB 上限，
    -- 缩放后的 19.5MB 能装下整期 130 张（约 12.5MB）
    ok(w1800 > 12.5 * MB, "缩放后能容纳实测的 12.5MB 整期")

    local b = images.new_budget({ width = 1404 })
    eq(b.max_total_bytes, w1404, "new_budget 用缩放后的整期额度")
    eq(b.max_image_bytes, images.scale_budget(images.MAX_IMAGE_BYTES, 1404),
        "单张额度同样缩放")
    local d = images.new_budget()
    eq(d.max_total_bytes, images.MAX_TOTAL_BYTES, "不传宽度时保持默认额度")
    local e = images.new_budget({ width = 1404, max_total_bytes = 999 })
    eq(e.max_total_bytes, 999, "显式额度优先于缩放")
end

----------------------------------------------------------------------
-- 宽度表真的进了 CDN 配方（设置 → 图片分辨率 → 实际请求 URL）
----------------------------------------------------------------------

do
    local imgurl = dofile(spec_dir .. "/../zhifou.koplugin/zhifou/imgurl.lua")
    local asked = {}
    local function fetch_with(widths)
        asked = {}
        return images.fetch("https://s3.ifanr.com/a/b.jpg", {
            rewrite = imgurl.rewrite,
            widths = widths,
            download = function(url)
                asked[#asked + 1] = url
                -- 第一次成功（只为看清请求了哪些 URL）
                return "\255\216\255\224" .. string.rep("x", 64)
            end,
        })
    end

    fetch_with({ 1000, 600 })
    eq(#asked, 1, "首张成功即停（不无谓地试更小宽度）")
    ok(asked[1]:find("w/1000", 1, true) ~= nil, "请求的是设置里的 1000 档", tostring(asked[1]))

    -- 空表要当成「没给」：不能退化成直接下原图（无缩放、无灰度）
    fetch_with({})
    ok(asked[1] ~= "https://s3.ifanr.com/a/b.jpg", "空宽度表不退化成原图")
    ok(asked[1]:find("w/800", 1, true) ~= nil, "空表回落默认 800 档", tostring(asked[1]))

    -- 高度超限的图：目标宽与按比例降档都失败时，要用绝对小档兜底
    local tries = {}
    local img = images.fetch("https://img.ithome.com/tall.jpg", {
        rewrite = imgurl.rewrite,
        widths = images.widths_for(1404),   -- 1404 / 842 / 480
        download = function(url)
            tries[#tries + 1] = url
            if url:find("w_1404", 1, true) or url:find("w_842", 1, true) then
                return nil, "HTTP 400"           -- 超高图：CDN 只认极窄宽度
            end
            return "\255\216\255\224" .. string.rep("y", 64)
        end,
    })
    ok(img ~= nil, "兜底档把超高图救了回来")
    eq(#tries, 3, "依次试 1404 / 842 / 480")
    ok(tries[3]:find("w_480", 1, true) ~= nil, "最后用的是绝对小档 480", tostring(tries[3]))
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
