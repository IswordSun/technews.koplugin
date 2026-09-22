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
-- 样本一：两源混排（含无 source_name 条目）：目录按正文顺序平铺
-- （合并期不再按来源分组：分组序与正文序不一致 → 页码非单调 → KOReader 的
--  validateAndFixToc 会把它当坏目录修复、目录跳转全错，见 2026-09-22 实测）
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

    -- nav.xhtml：平铺（按正文顺序），封面在首位；合并期不再按来源分组
    contains(merged_epub, '<li><a href="text/cover.xhtml">本期目录</a></li>',
        "nav 顶层保留封面「本期目录」")
    ok(pos(merged_epub, "<span>") == nil, "nav 全平铺（不再有分组标签 span）")

    local order = {}
    for i = 1, 5 do
        order[i] = pos(merged_epub, string.format('text/article-%03d.xhtml"', i))
    end
    ok(order[1] and order[5] and order[1] < order[2] and order[2] < order[3]
        and order[3] < order[4] and order[4] < order[5],
        "nav 条目按正文顺序平铺（article-001 → article-005）")

    -- toc.ncx：平铺 navPoint（封面 + 5 条，顺序 id/playOrder），无分组嵌套；depth = 1
    local expected_map = table.concat({
        '<navPoint id="nav-1" playOrder="1"><navLabel><text>本期目录</text></navLabel>'
            .. '<content src="text/cover.xhtml"/></navPoint>',
        '<navPoint id="nav-2" playOrder="2"><navLabel><text>甲一</text></navLabel>'
            .. '<content src="text/article-001.xhtml"/></navPoint>',
        '<navPoint id="nav-3" playOrder="3"><navLabel><text>乙一</text></navLabel>'
            .. '<content src="text/article-002.xhtml"/></navPoint>',
        '<navPoint id="nav-4" playOrder="4"><navLabel><text>甲二</text></navLabel>'
            .. '<content src="text/article-003.xhtml"/></navPoint>',
        '<navPoint id="nav-5" playOrder="5"><navLabel><text>乙二</text></navLabel>'
            .. '<content src="text/article-004.xhtml"/></navPoint>',
        '<navPoint id="nav-6" playOrder="6"><navLabel><text>丙一</text></navLabel>'
            .. '<content src="text/article-005.xhtml"/></navPoint>',
    }, "\n")
    eq(block_of(merged_epub, "<navMap>", "</navMap>"),
        "<navMap>" .. expected_map .. "</navMap>",
        "ncx 平铺结构（顺序 id/playOrder）与预期一致")
    contains(merged_epub, '<meta name="dtb:depth" content="1"/>', "ncx depth 元数据为 1")
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
-- 样本五：收藏快照模式（no_cover + no_overview）——无封面页、无目录页，打开即正文
----------------------------------------------------------------------

local snapshot = {
    title = "某篇收藏文章",
    date = "2026-09-22",
    no_cover = true,
    no_overview = true,
    items = {
        { title = "某篇收藏文章", source_name = "Solidot", blocks = {
            { text = "收藏正文" },
            { img = "https://example.com/a.jpg" },
        } },
    },
    images = { ["https://example.com/a.jpg"] = { data = "JPEGDATA", ext = "jpg" } },
}

local snapshot_epub = build_and_read(snapshot)

do
    ok(pos(snapshot_epub, "cover.xhtml") == nil, "快照模式：无封面/目录页（cover.xhtml）")
    ok(pos(snapshot_epub, "coverpage.xhtml") == nil, "快照模式：无独立封面页")
    ok(pos(snapshot_epub, "cover.jpg") == nil, "快照模式：无封面图片文件")
    ok(pos(snapshot_epub, "cover-image") == nil, "快照模式：无 cover-image 清单项与 meta")
    contains(snapshot_epub, '<itemref idref="ch1"/>', "快照模式：spine 首项即正文（ch1）")
    contains(snapshot_epub, "收藏正文", "快照模式：正文内容仍在")
    contains(snapshot_epub, "OEBPS/images/img-001.jpg", "快照模式：正文图片照常注入")
    contains(snapshot_epub, '<li><a href="text/article-001.xhtml">某篇收藏文章</a></li>',
        "快照模式：nav 仅列文章本身")
    ok(pos(snapshot_epub, "本期目录") == nil, "快照模式：无「本期目录」条目")
end

----------------------------------------------------------------------
-- 样本六：文内小标题 → 二级目录（正文锚点 + nav/ncx 嵌套；单条不建子目录）
-- 条目 1（2 个小标题）应产生嵌套子目录；条目 2（1 个）保持平铺、无锚点。
-- 目录一律平铺（不再按来源分组）；ncx 深度应为 2（文章 → 小标题）
----------------------------------------------------------------------

local digest = {
    title = "科技资讯 · 2026-09-22",
    date = "2026-09-22",
    items = {
        { title = "早报｜示例", source_name = "爱范儿", blocks = {
            { text = "开场白。" },
            { text = "曝 A 量产良率仅六成", kind = "heading" },
            { text = "正文一。" },
            { text = "曝 B 筹备新一轮融资", kind = "heading" },
            { text = "正文二。" },
        } },
        { title = "单标题文章", source_name = "IT之家", blocks = {
            { text = "唯一小标题", kind = "heading" },
            { text = "正文。" },
        } },
    },
}

local digest_epub = build_and_read(digest)

do
    contains(digest_epub, '<h3 id="h1">曝 A 量产良率仅六成</h3>', "小标题正文带锚点（h1）")
    contains(digest_epub, '<h3 id="h2">曝 B 筹备新一轮融资</h3>', "小标题正文带锚点（h2）")
    contains(digest_epub,
        '<li><a href="text/article-001.xhtml">早报｜示例</a><ol>',
        "nav：早报条目内嵌子目录 <ol>")
    contains(digest_epub,
        '<li><a href="text/article-001.xhtml#h1">曝 A 量产良率仅六成</a></li>',
        "nav：子目录项指向 h1 锚点")
    contains(digest_epub, '<content src="text/article-001.xhtml#h1"/>',
        "ncx：子 navPoint 指向 h1 锚点")
    contains(digest_epub, '<content src="text/article-001.xhtml#h2"/>',
        "ncx：子 navPoint 指向 h2 锚点")
    contains(digest_epub, '<meta name="dtb:depth" content="2"/>',
        "ncx：深度随子目录加一级（文章→小标题）")
    contains(digest_epub, '<li><a href="text/article-002.xhtml">单标题文章</a></li>',
        "单条小标题不建子目录（条目平铺）")
    contains(digest_epub, "<h3>唯一小标题</h3>", "单条小标题正文无锚点（与从前一致）")
    ok(pos(digest_epub, "article-002.xhtml#") == nil, "单标题文章无任何锚点目录项")
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
