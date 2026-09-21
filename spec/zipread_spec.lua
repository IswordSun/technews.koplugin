-- spec/zipread_spec.lua — technews 最小 ZIP 读取器（technews/zipread.lua）测试
--
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/zipread_spec.lua）
-- 不依赖测试框架，也不需要 KOReader 运行时：先用 epub.lua 构建一个真实
-- EPUB（2 条资讯、2 张假图片），再用 zipread 按名字提取并逐字节比对。
--
-- 覆盖：mimetype、章节 XHTML 内容、图片二进制、缺失条目、非 ZIP 文件，
-- 以及 method 8（deflate）条目被拒绝（把中央目录条目的 method 字段改掉模拟）。

local spec_dir = (arg and arg[0] or "spec/zipread_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local Epub = dofile(spec_dir .. "/../technews.koplugin/technews/epub.lua")
local zipread = dofile(spec_dir .. "/../technews.koplugin/technews/zipread.lua")

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
        ("expected=%s actual=%s"):format(tostring(expected), tostring(actual)))
end

local function contains(text, needle, name)
    ok(text ~= nil and text:find(needle, 1, true) ~= nil, name)
end

local function read_file(path)
    local file = assert(io.open(path, "rb"), "无法读取 " .. path)
    local content = file:read("*a")
    file:close()
    return content
end

local function write_file(path, content)
    local file = assert(io.open(path, "wb"), "无法写入 " .. path)
    file:write(content)
    file:close()
end

----------------------------------------------------------------------
-- 临时文件
----------------------------------------------------------------------

local temp_files = {}

local function temp_path(suffix)
    local path = os.tmpname() .. (suffix or "")
    temp_files[#temp_files + 1] = path
    temp_files[#temp_files + 1] = path .. ".part"
    return path
end

local function cleanup()
    for _, path in ipairs(temp_files) do os.remove(path) end
end

----------------------------------------------------------------------
-- 样本：2 条资讯 + 2 张假图片（内容为任意二进制，逐字节比对）
----------------------------------------------------------------------

local IMG_A = "\137PNG\r\n\26\n" .. "fake-png-payload-A" .. "\0\1\2\3\255"
local IMG_B = "\255\216\255\224" .. "fake-jpeg-payload-B" .. "\0\254\255\217"

local sample = {
    title = "科技资讯 · 2026-09-21",
    date = "2026-09-21",
    items = {
        {
            title = "甲一标题",
            source_name = "IT之家",
            blocks = {
                { text = "甲一正文" },
                { img = "https://example.com/a.png" },
            },
        },
        {
            title = "乙一标题",
            source_name = "雷锋网",
            blocks = {
                { text = "乙一正文" },
                { img = "https://example.com/b.jpg" },
            },
        },
    },
    images = {
        ["https://example.com/a.png"] = { data = IMG_A, ext = "png" },
        ["https://example.com/b.jpg"] = { data = IMG_B, ext = "jpg" },
    },
}

local epub_path = temp_path(".epub")
Epub.build(sample, epub_path)

----------------------------------------------------------------------
-- 基础提取
----------------------------------------------------------------------

local reader = zipread.open(epub_path)
ok(reader ~= nil, "zipread.open：自建 EPUB 可打开")

if reader then
    eq(reader:extract("mimetype"), "application/epub+zip",
        "mimetype 条目内容正确")

    local chapter1 = reader:extract("OEBPS/text/article-001.xhtml")
    contains(chapter1, "甲一标题", "章节 1 含文章标题")
    contains(chapter1, "甲一正文", "章节 1 含正文")
    contains(chapter1, "../images/img-001.png", "章节 1 引用 img-001.png")

    local chapter2 = reader:extract("OEBPS/text/article-002.xhtml")
    contains(chapter2, "乙一标题", "章节 2 含文章标题")
    contains(chapter2, "../images/img-002.jpg", "章节 2 引用 img-002.jpg")

    eq(reader:extract("OEBPS/images/img-001.png"), IMG_A,
        "图片 1 提取字节与写入完全一致")
    eq(reader:extract("OEBPS/images/img-002.jpg"), IMG_B,
        "图片 2 提取字节与写入完全一致")

    eq(reader:extract("OEBPS/images/does-not-exist.png"), nil,
        "缺失条目返回 nil")
    eq(reader:extract(""), nil, "空名字返回 nil")

    reader:close()
end

----------------------------------------------------------------------
-- 非 ZIP 文件：open 应返回 nil
----------------------------------------------------------------------

local not_zip = temp_path(".txt")
write_file(not_zip, "这不是一个 ZIP 文件，只是一段普通文本。")
eq(zipread.open(not_zip), nil, "非 ZIP 文件 open 返回 nil")

local empty_file = temp_path(".empty")
write_file(empty_file, "")
eq(zipread.open(empty_file), nil, "空文件 open 返回 nil")

----------------------------------------------------------------------
-- method 8（deflate）条目拒绝：把中央目录里 img-001 的 method 字段
-- 从 0 改成 8（局部头不动）；zipread 应先查中央目录并拒绝提取该条目，
-- 其余 stored 条目不受影响。
----------------------------------------------------------------------

local deflate_path = temp_path(".epub")
do
    local bytes = read_file(epub_path)
    local target = "OEBPS/images/img-001.png"
    local search, patched = 1, false
    while true do
        local n = bytes:find(target, search, true)
        if not n then break end
        if bytes:sub(n - 46, n - 43) == "PK\001\002" then
            -- 中央目录条目：method 在签名后 0-based 偏移 10 处（2 字节小端）
            local method = bytes:byte(n - 36) + bytes:byte(n - 35) * 256
            if method == 0 then
                bytes = bytes:sub(1, n - 37) .. "\008\000" .. bytes:sub(n - 34)
                patched = true
            end
        end
        search = n + 1
    end
    ok(patched, "构造 deflate 样本：已把 img-001 中央目录 method 改为 8")
    write_file(deflate_path, bytes)
end

local deflate_reader = zipread.open(deflate_path)
ok(deflate_reader ~= nil, "deflate 样本：结构仍可解析（open 成功）")
if deflate_reader then
    eq(deflate_reader:extract("OEBPS/images/img-001.png"), nil,
        "method 8 条目被拒绝（返回 nil）")
    eq(deflate_reader:extract("OEBPS/images/img-002.jpg"), IMG_B,
        "同一文件内其余 stored 条目仍可提取")
    eq(deflate_reader:extract("mimetype"), "application/epub+zip",
        "deflate 样本的 mimetype 仍可提取")
    deflate_reader:close()
end

----------------------------------------------------------------------

cleanup()

print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
