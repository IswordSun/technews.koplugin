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
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
