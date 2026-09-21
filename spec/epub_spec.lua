-- spec/epub_spec.lua — technews EPUB 目录（nav.xhtml / toc.ncx）结构测试
--
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/epub_spec.lua）
-- 不依赖任何测试框架；所有断言通过时退出码为 0，否则为 1。
--
-- epub.lua 把条目以 stored（未压缩）方式写入 ZIP，因此构建出的 .epub
-- 可直接整体当字符串搜索，逐字节校验 nav/ncx 的标记与嵌套关系。

local spec_dir = (arg and arg[0] or "spec/epub_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local Epub = dofile(spec_dir .. "/../technews.koplugin/technews/epub.lua")

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

-- 纯文本查找（避免模式转义），返回起始字节位置
local function pos(text, needle)
    return text:find(needle, 1, true)
end

local function contains(text, needle, name)
    ok(pos(text, needle) ~= nil, name)
end

-- 取两个标记之间的完整片段（含标记本身），用于整块对比
local function block_of(text, opening, closing)
    local start = pos(text, opening)
    local stop = pos(text, closing)
    if not start or not stop then return nil end
    return text:sub(start, stop + #closing - 1)
end

----------------------------------------------------------------------
-- 临时文件与构建工具
----------------------------------------------------------------------

local temp_files = {}

local function temp_path()
    local base = os.tmpname()
    local path = base .. ".epub"
    temp_files[#temp_files + 1] = base
    temp_files[#temp_files + 1] = path
    temp_files[#temp_files + 1] = path .. ".part"
    return path
end

local function build_and_read(data)
    local path = temp_path()
    Epub.build(data, path)
    local file = assert(io.open(path, "rb"), "无法读取 " .. path)
    local content = file:read("*a")
    file:close()
    return content, path
end

local function cleanup()
    for _, path in ipairs(temp_files) do os.remove(path) end
end

-- os.execute 的返回值在 Lua 5.1 / LuaJIT 下为状态码，兼容返回布尔值的实现
local function run_ok(cmd)
    local status = os.execute(cmd)
    if type(status) == "number" then return status == 0 end
    return status == true
end

----------------------------------------------------------------------
-- 样本一：两源混排（含无 source_name 条目），目录应分两级
-- 条目顺序 → href：1 甲一(IT之家) · 2 乙一(CNBeta) · 3 甲二(IT之家)
--                  4 乙二(CNBeta) · 5 丙一(无来源)
----------------------------------------------------------------------

local merged = {
    title = "科技资讯 · 2026-09-20",
    date = "2026-09-20",
    items = {
        { title = "甲一", source_name = "IT之家", blocks = { { text = "甲一正文" } } },
        { title = "乙一", source_name = "CNBeta", blocks = { { text = "乙一正文" } } },
        { title = "甲二", source_name = "IT之家", blocks = { { text = "甲二正文" } } },
        { title = "乙二", source_name = "CNBeta", blocks = { { text = "乙二正文" } } },
        { title = "丙一", blocks = { { text = "丙一正文" } } },
    },
}

local merged_epub, merged_path = build_and_read(merged)

do
    ok(#merged_epub > 0, "两源样本：构建出的 EPUB 非空")
    eq(merged_epub:sub(-22, -19), "PK\005\006", "两源样本：EPUB 以 ZIP EOCD 签名结尾")

    -- nav.xhtml：封面顶层 + 按来源两级
    contains(merged_epub, '<li><a href="text/cover.xhtml">本期目录</a></li>',
        "nav 顶层保留封面「本期目录」")
    contains(merged_epub, "<li><span>IT之家</span><ol>", "nav 出现 IT之家 分组标签与内嵌 <ol>")
    contains(merged_epub, "<li><span>CNBeta</span><ol>", "nav 出现 CNBeta 分组标签与内嵌 <ol>")
    contains(merged_epub, "<li><span>其他</span><ol>", "nav 无来源条目归入「其他」分组")

    local p_it = pos(merged_epub, "<span>IT之家</span>")
    local p_cn = pos(merged_epub, "<span>CNBeta</span>")
    local p_ot = pos(merged_epub, "<span>其他</span>")
    ok(p_it and p_cn and p_ot and p_it < p_cn and p_cn < p_ot,
        "nav 分组顺序为来源首次出现顺序：IT之家 → CNBeta → 其他")

    if p_it and p_cn and p_ot then
        local group_it = merged_epub:sub(p_it, p_cn - 1)
        local group_cn = merged_epub:sub(p_cn, p_ot - 1)
        local group_ot = merged_epub:sub(p_ot, #merged_epub)
        contains(group_it, "text/article-001.xhtml", "IT之家组包含第 1 条（甲一）")
        contains(group_it, "text/article-003.xhtml", "IT之家组包含第 3 条（甲二）")
        ok(pos(group_it, "text/article-001.xhtml") < pos(group_it, "text/article-003.xhtml"),
            "IT之家组内保持条目原相对顺序（甲一在甲二前）")
        ok(pos(group_it, "text/article-002.xhtml") == nil,
            "IT之家组不含 CNBeta 条目")
        contains(group_cn, "text/article-002.xhtml", "CNBeta 组包含第 2 条（乙一）")
        contains(group_cn, "text/article-004.xhtml", "CNBeta 组包含第 4 条（乙二）")
        contains(group_ot, "text/article-005.xhtml", "其他组包含第 5 条（丙一）")
    end

    -- toc.ncx：封面 navPoint + 每组父 navPoint（content 指向组内首条）+ 子 navPoint 嵌套
    local expected_map = table.concat({
        '<navPoint id="nav-1" playOrder="1"><navLabel><text>本期目录</text></navLabel>'
            .. '<content src="text/cover.xhtml"/></navPoint>',
        '<navPoint id="nav-2" playOrder="2"><navLabel><text>IT之家</text></navLabel>'
            .. '<content src="text/article-001.xhtml"/>',
        '<navPoint id="nav-3" playOrder="3"><navLabel><text>甲一</text></navLabel>'
            .. '<content src="text/article-001.xhtml"/></navPoint>',
        '<navPoint id="nav-4" playOrder="4"><navLabel><text>甲二</text></navLabel>'
            .. '<content src="text/article-003.xhtml"/></navPoint>',
        "</navPoint>",
        '<navPoint id="nav-5" playOrder="5"><navLabel><text>CNBeta</text></navLabel>'
            .. '<content src="text/article-002.xhtml"/>',
        '<navPoint id="nav-6" playOrder="6"><navLabel><text>乙一</text></navLabel>'
            .. '<content src="text/article-002.xhtml"/></navPoint>',
        '<navPoint id="nav-7" playOrder="7"><navLabel><text>乙二</text></navLabel>'
            .. '<content src="text/article-004.xhtml"/></navPoint>',
        "</navPoint>",
        '<navPoint id="nav-8" playOrder="8"><navLabel><text>其他</text></navLabel>'
            .. '<content src="text/article-005.xhtml"/>',
        '<navPoint id="nav-9" playOrder="9"><navLabel><text>丙一</text></navLabel>'
            .. '<content src="text/article-005.xhtml"/></navPoint>',
        "</navPoint>",
    }, "\n")
    eq(block_of(merged_epub, "<navMap>", "</navMap>"),
        "<navMap>" .. expected_map .. "</navMap>",
        "ncx 分组结构（父子嵌套 + 顺序 id/playOrder）与预期一致")
    contains(merged_epub, '<meta name="dtb:depth" content="2"/>', "ncx depth 元数据为 2")
end

----------------------------------------------------------------------
-- 样本二：单源（全部条目同源），nav/ncx 应保持原有平铺结构
----------------------------------------------------------------------

local single = {
    title = "科技资讯 · 2026-09-20",
    date = "2026-09-20",
    items = {
        { title = "甲一", source_name = "IT之家", blocks = { { text = "甲一正文" } } },
        { title = "甲二", source_name = "IT之家", blocks = { { text = "甲二正文" } } },
        { title = "甲三", source_name = "IT之家", blocks = { { text = "甲三正文" } } },
    },
}

local single_epub, single_path = build_and_read(single)

do
    ok(#single_epub > 0, "单源样本：构建出的 EPUB 非空")
    eq(single_epub:sub(-22, -19), "PK\005\006", "单源样本：EPUB 以 ZIP EOCD 签名结尾")

    ok(pos(single_epub, "<span>") == nil, "单源 nav 保持平铺（无分组标签 span）")
    contains(single_epub, '<li><a href="text/cover.xhtml">本期目录</a></li>',
        "单源 nav 仍保留封面「本期目录」")

    local expected_nav = table.concat({
        "<ol>",
        '<li><a href="text/cover.xhtml">本期目录</a></li>',
        '<li><a href="text/article-001.xhtml">甲一</a></li>',
        '<li><a href="text/article-002.xhtml">甲二</a></li>',
        '<li><a href="text/article-003.xhtml">甲三</a></li>',
        "</ol>",
    }, "\n")
    eq(block_of(single_epub, "<ol>", "</ol>"), expected_nav,
        "单源 nav 完整平铺结构与预期一致")

    local expected_map = table.concat({
        '<navPoint id="nav-1" playOrder="1"><navLabel><text>本期目录</text></navLabel>'
            .. '<content src="text/cover.xhtml"/></navPoint>',
        '<navPoint id="nav-2" playOrder="2"><navLabel><text>甲一</text></navLabel>'
            .. '<content src="text/article-001.xhtml"/></navPoint>',
        '<navPoint id="nav-3" playOrder="3"><navLabel><text>甲二</text></navLabel>'
            .. '<content src="text/article-002.xhtml"/></navPoint>',
        '<navPoint id="nav-4" playOrder="4"><navLabel><text>甲三</text></navLabel>'
            .. '<content src="text/article-003.xhtml"/></navPoint>',
    }, "\n")
    eq(block_of(single_epub, "<navMap>", "</navMap>"),
        "<navMap>" .. expected_map .. "</navMap>",
        "单源 ncx 完整平铺结构与预期一致（无父级分组）")
    contains(single_epub, '<meta name="dtb:depth" content="1"/>', "单源 ncx depth 元数据保持 1")
end

----------------------------------------------------------------------
-- 样本三：仅一个非 nil 来源 + 无来源条目，仍不足两个来源，保持平铺
----------------------------------------------------------------------

local mixed_flat = {
    title = "科技资讯 · 2026-09-20",
    date = "2026-09-20",
    items = {
        { title = "甲一", source_name = "IT之家", blocks = { { text = "甲一正文" } } },
        { title = "丙一", blocks = { { text = "丙一正文" } } },
        { title = "丙二", blocks = { { text = "丙二正文" } } },
    },
}

local flat_epub = build_and_read(mixed_flat)

do
    ok(pos(flat_epub, "<span>") == nil,
        "单来源+无来源混排：非 nil 来源仅 1 个，nav 保持平铺")
    contains(flat_epub,
        '<navPoint id="nav-2" playOrder="2"><navLabel><text>甲一</text></navLabel>'
            .. '<content src="text/article-001.xhtml"/></navPoint>',
        "单来源+无来源混排：ncx 条目仍为平铺 navPoint")
    local flat_map = block_of(flat_epub, "<navMap>", "</navMap>")
    ok(flat_map ~= nil and flat_map:find("<text>其他</text>", 1, true) == nil,
        "单来源+无来源混排：不出现「其他」父级分组")
end

----------------------------------------------------------------------
-- 样本四：文本块 kind 渲染（heading → <h3>，bullet/caption → 带 class 的 <p>）
----------------------------------------------------------------------

local kinds = {
    title = "科技资讯 · 2026-09-20",
    date = "2026-09-20",
    items = {
        { title = "排版样本", source_name = "IT之家", blocks = {
            { text = "普通段落文字。" },
            { text = "章节小标题", kind = "heading" },
            { text = "列表项文字", kind = "bullet" },
            { text = "图注文字", kind = "caption" },
        } },
    },
}

local kinds_epub = build_and_read(kinds)

do
    contains(kinds_epub, "<h3>章节小标题</h3>", "heading 块渲染为 <h3>")
    contains(kinds_epub, '<p class="bullet">· 列表项文字</p>',
        "bullet 块渲染为带「· 」前缀的 p.bullet")
    contains(kinds_epub, '<p class="caption">图注文字</p>', "caption 块渲染为 p.caption")
    contains(kinds_epub, "<p>普通段落文字。</p>", "无 kind 文本块仍渲染为普通 <p>")
    contains(kinds_epub, "h3 { font-size: 1.12em;", "样式表包含 h3 规则")
end

----------------------------------------------------------------------
-- 可选：用 unzip -t 校验 ZIP 完整性（环境中无 unzip 时跳过）
----------------------------------------------------------------------

if run_ok("command -v unzip >/dev/null 2>&1") then
    ok(run_ok("unzip -t '" .. merged_path .. "' >/dev/null 2>&1"),
        "unzip -t：两源 EPUB 校验通过")
    ok(run_ok("unzip -t '" .. single_path .. "' >/dev/null 2>&1"),
        "unzip -t：单源 EPUB 校验通过")
else
    print("     # skip - 环境中没有 unzip")
end

cleanup()

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
