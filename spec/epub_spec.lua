-- spec/epub_spec.lua — zhifou EPUB 目录（nav.xhtml / toc.ncx）结构测试
--
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/epub_spec.lua）
-- 不依赖任何测试框架；所有断言通过时退出码为 0，否则为 1。
--
-- epub.lua 把条目以 stored（未压缩）方式写入 ZIP，因此构建出的 .epub
-- 可直接整体当字符串搜索，逐字节校验 nav/ncx 的标记与嵌套关系。

local spec_dir = (arg and arg[0] or "spec/epub_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local Epub = dofile(spec_dir .. "/../zhifou.koplugin/zhifou/epub.lua")

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
        '<navPoint id="nav-2" playOrder="2"><navLabel><text>【IT之家】甲一</text></navLabel>'
            .. '<content src="text/article-001.xhtml"/></navPoint>',
        '<navPoint id="nav-3" playOrder="3"><navLabel><text>【CNBeta】乙一</text></navLabel>'
            .. '<content src="text/article-002.xhtml"/></navPoint>',
        '<navPoint id="nav-4" playOrder="4"><navLabel><text>【IT之家】甲二</text></navLabel>'
            .. '<content src="text/article-003.xhtml"/></navPoint>',
        '<navPoint id="nav-5" playOrder="5"><navLabel><text>【CNBeta】乙二</text></navLabel>'
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
        '<li><a href="text/article-001.xhtml">【IT之家】甲一</a></li>',
        '<li><a href="text/article-002.xhtml">【IT之家】甲二</a></li>',
        '<li><a href="text/article-003.xhtml">【IT之家】甲三</a></li>',
        "</ol>",
    }, "\n")
    eq(block_of(single_epub, "<ol>", "</ol>"), expected_nav,
        "单源 nav 完整平铺结构与预期一致")

    local expected_map = table.concat({
        '<navPoint id="nav-1" playOrder="1"><navLabel><text>本期目录</text></navLabel>'
            .. '<content src="text/cover.xhtml"/></navPoint>',
        '<navPoint id="nav-2" playOrder="2"><navLabel><text>【IT之家】甲一</text></navLabel>'
            .. '<content src="text/article-001.xhtml"/></navPoint>',
        '<navPoint id="nav-3" playOrder="3"><navLabel><text>【IT之家】甲二</text></navLabel>'
            .. '<content src="text/article-002.xhtml"/></navPoint>',
        '<navPoint id="nav-4" playOrder="4"><navLabel><text>【IT之家】甲三</text></navLabel>'
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
        '<navPoint id="nav-2" playOrder="2"><navLabel><text>【IT之家】甲一</text></navLabel>'
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
    contains(snapshot_epub,
        '<item id="img-1" href="images/img-001.jpg" media-type="image/jpeg"/>',
        "快照模式：正文图片进 manifest")
    contains(snapshot_epub, '<img src="../images/img-001.jpg" alt=""/>',
        "快照模式：正文确实引用该图")
    contains(snapshot_epub, '<li><a href="text/article-001.xhtml">【Solidot】某篇收藏文章</a></li>',
        "快照模式：nav 仅列文章本身（带来源标记）")
    ok(pos(snapshot_epub, "本期目录") == nil, "快照模式：无「本期目录」条目")
end

----------------------------------------------------------------------
-- 样本六：文内小标题 → 二级目录（正文锚点 + nav/ncx 嵌套）
-- 仅"新闻聚合"类标题（含 早报/日报/周刊… 关键词）且小标题 ≥2 时建子目录：
-- 条目 1（早报，2 个小标题）→ 嵌套子目录；条目 2（1 个）与条目 3（普通长文，2 个小标题）
-- 均保持平铺、无锚点。目录一律平铺（不再按来源分组）；ncx 深度应为 2
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
        { title = "普通长文（两小节）", source_name = "少数派", blocks = {
            { text = "小节甲", kind = "heading" },
            { text = "普通正文甲。" },
            { text = "小节乙", kind = "heading" },
            { text = "普通正文乙。" },
        } },
    },
}

local digest_epub, digest_epub_path = build_and_read(digest)

do
    contains(digest_epub, '<h3 id="h1">曝 A 量产良率仅六成</h3>', "小标题正文带锚点（h1）")
    contains(digest_epub, '<h3 id="h2">曝 B 筹备新一轮融资</h3>', "小标题正文带锚点（h2）")
    contains(digest_epub,
        '<li><a href="text/article-001.xhtml">【爱范儿】早报｜示例</a><ol>',
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
    contains(digest_epub, '<li><a href="text/article-002.xhtml">【IT之家】单标题文章</a></li>',
        "单条小标题不建子目录（条目平铺）")
    contains(digest_epub, "<h3>唯一小标题</h3>", "单条小标题正文无锚点（与从前一致）")
    ok(pos(digest_epub, "article-002.xhtml#") == nil, "单标题文章无任何锚点目录项")
    contains(digest_epub, "<h3>小节甲</h3>", "非聚合长文：小标题不带锚点（与从前一致）")
    ok(pos(digest_epub, "article-003.xhtml#") == nil, "非聚合长文：目录无子条目")
end

----------------------------------------------------------------------
-- EPUB3 合规：正文图片必须进 manifest、dcterms:modified、唯一 identifier、
-- NCX playOrder 在文档流中递增（父节点先编号）
----------------------------------------------------------------------

do
    -- 两张图（no_cover 避免封面复用干扰编号）：逐张登记且 media-type 按后缀给
    local two_images = build_and_read({
        title = "两图期", date = "2026-09-28", identifier = "zhifou-test-two",
        no_cover = true,
        items = { { title = "两图", blocks = {
            { img = "https://example.com/a.jpg" },
            { text = "中间文字。" },
            { img = "https://example.com/b.png" },
        } } },
        images = {
            ["https://example.com/a.jpg"] = { data = "JPEGDATA!!", ext = "jpg" },
            ["https://example.com/b.png"] = { data = "PNGDATA!!!", ext = "png" },
        },
    })
    local declared = 0
    for _ in two_images:gmatch('<item id="img%-%d+"') do declared = declared + 1 end
    eq(declared, 2, "manifest：正文图片逐张登记（两张图两个清单项）")
    contains(two_images, '<item id="img-1" href="images/img-001.jpg" media-type="image/jpeg"/>',
        "manifest：JPEG 项带正确 href 与 media-type")
    contains(two_images, '<item id="img-2" href="images/img-002.png" media-type="image/png"/>',
        "manifest：PNG 项带正确 media-type")
    contains(two_images, '<img src="../images/img-002.png" alt=""/>',
        "manifest：正文引用与清单项一致")

    -- dcterms:modified 是 EPUB 3.0 必填项，且必须是 UTC 的 ISO8601
    local modified = merged_epub:match('<meta property="dcterms:modified">([^<]+)</meta>')
    ok(modified ~= nil, "metadata：含 dcterms:modified（EPUB 3 必填）")
    ok(modified and modified:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil,
        "metadata：dcterms:modified 为 UTC ISO8601 格式", tostring(modified))
    contains(merged_epub, 'prefix="dcterms: http://purl.org/dc/terms/"',
        "package：声明 dcterms 前缀")

    -- unique-identifier 必须逐期不同：同一天的不同期不能共用
    local first = build_and_read({
        title = "甲期", date = "2026-09-28", identifier = "zhifou-merged-2026-09-28",
        items = { { title = "一篇", blocks = { { text = "正文。" } } } },
    })
    local second = build_and_read({
        title = "乙期", date = "2026-09-28", identifier = "zhifou-ithome-2026-09-28",
        items = { { title = "一篇", blocks = { { text = "正文。" } } } },
    })
    contains(first, '<dc:identifier id="bookid">zhifou-merged-2026-09-28</dc:identifier>',
        "identifier：采用调用方传入的值")
    ok(pos(first, 'id="bookid">zhifou-ithome') == nil and pos(second, 'id="bookid">zhifou-ithome') ~= nil,
        "identifier：同一天的两期互不相同")
    -- 未传 identifier 时回退为「日期 + 构建时刻」，不再是同日共用一个
    local fallback = build_and_read({
        title = "丙期", date = "2026-09-28",
        items = { { title = "一篇", blocks = { { text = "正文。" } } } },
    })
    ok(fallback:match('<dc:identifier id="bookid">zhifou%-2026%-09%-28%-%d+</dc:identifier>') ~= nil,
        "identifier：缺省时回退为日期 + 时间戳")

    -- XML 非法控制字符：源站偶发带进正文，不剥离会让整篇成为非法 XML
    local dirty, dirty_path = build_and_read({
        title = "控制字符期", date = "2026-09-28", identifier = "zhifou-test-ctrl",
        items = { { title = "标题\1带控制字符", blocks = {
            { text = "正文\2里有\1控制字符。\11\12" },
        } } },
    })
    contains(dirty, "正文里有控制字符。",
        "escape：控制字符被剥掉且正文其余内容不变（原串为 正文\\2里有\\1控制字符。）")
    if run_ok("command -v unzip >/dev/null 2>&1") then
        -- 整包是 ZIP（含二进制头），只能按字节搜会误命中；解出章节再查
        local pipe = io.popen("unzip -p '" .. dirty_path .. "' OEBPS/text/article-001.xhtml")
        local chapter = pipe and pipe:read("*a") or ""
        if pipe then pipe:close() end
        ok(chapter:find("\1", 1, true) == nil and chapter:find("\2", 1, true) == nil
            and chapter:find("\11", 1, true) == nil,
            "escape：解出的章节里不含 XML 非法控制字符")
    end

    if run_ok("command -v xmllint >/dev/null 2>&1") then
        ok(run_ok("unzip -p '" .. dirty_path
            .. "' OEBPS/text/article-001.xhtml | xmllint --noout - >/dev/null 2>&1"),
            "xmllint：剥掉控制字符后的章节是合法 XML")
        ok(run_ok("unzip -p '" .. merged_path
            .. "' OEBPS/content.opf | xmllint --noout - >/dev/null 2>&1"),
            "xmllint：content.opf 合法")
        ok(run_ok("unzip -p '" .. digest_epub_path
            .. "' OEBPS/toc.ncx | xmllint --noout - >/dev/null 2>&1"),
            "xmllint：toc.ncx 合法")
    else
        print("     # skip - 环境中没有 xmllint")
    end

    -- NCX playOrder：父节点先编号 → 文档流中严格递增（此前父 nav-4 内含 nav-2/nav-3）
    local orders = {}
    for value in digest_epub:gmatch('playOrder="(%d+)"') do
        orders[#orders + 1] = tonumber(value)
    end
    local monotonic = #orders > 0
    for i = 2, #orders do
        if orders[i] <= orders[i - 1] then monotonic = false end
    end
    ok(monotonic, "ncx：playOrder 在文档流中严格递增（父节点先于子节点）",
        table.concat(orders, ","))
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

----------------------------------------------------------------------
-- 样本七：普通期带图 —— 无封面图片页（打开即目录页），保留元数据封面
----------------------------------------------------------------------

local no_coverpage = {
    title = "知否 · 2026-09-27",
    date = "2026-09-27",
    items = {
        { title = "带图文章", source_name = "IT之家", time = "9月27日", blocks = {
            { text = "正文。" },
            { img = "https://example.com/a.jpg" },
        } },
    },
    images = { ["https://example.com/a.jpg"] = { data = "JPEGDATA", ext = "jpg" } },
}

local no_coverpage_epub = build_and_read(no_coverpage)

do
    ok(pos(no_coverpage_epub, "coverpage.xhtml") == nil, "普通期：无封面图片页")
    ok(pos(no_coverpage_epub, '<itemref idref="coverpage"/>') == nil, "普通期：spine 无封面页引用")
    -- 封面取自正文首图：字节相同就不再存第二份文件，只在 manifest 里标记为封面
    contains(no_coverpage_epub,
        '<item id="cover-image" href="images/img-001.jpg" media-type="image/jpeg" properties="cover-image"/>',
        "普通期：封面复用正文首图（manifest 标记 properties=cover-image）")
    ok(pos(no_coverpage_epub, "images/cover.jpg") == nil,
        "普通期：封面与正文首图同字节 → 不写第二份文件（每期省一张最大图）")
    contains(no_coverpage_epub, '<meta name="cover" content="cover-image"/>', "普通期：保留 meta cover")
    contains(no_coverpage_epub, '<spine toc="ncx"><itemref idref="ch1"/>',
        "普通期：spine 首项即目录页（ch1）")
end

----------------------------------------------------------------------
-- is_complete：写盘完整性判定（缓存命中前用；截断的 EPUB 不能算命中）
----------------------------------------------------------------------

do
    local _, built = build_and_read({
        title = "完整期",
        date = "2026-09-28",
        items = { { title = "一篇", blocks = { { text = "正文。" } } } },
    })
    ok(Epub.is_complete(built), "is_complete：正常构建的 EPUB 判定为完整")
    ok(not Epub.is_complete(built .. ".not-exist"), "is_complete：文件不存在 → false")

    -- 模拟写盘中断：保留开头，砍掉结尾的 EOCD
    local file = assert(io.open(built, "rb"))
    local content = file:read("*a")
    file:close()
    local truncated = built .. ".truncated"
    temp_files[#temp_files + 1] = truncated
    local out = assert(io.open(truncated, "wb"))
    out:write(content:sub(1, #content - 30))
    out:close()
    ok(not Epub.is_complete(truncated), "is_complete：截断的 EPUB → false")

    local tiny = built .. ".tiny"
    temp_files[#temp_files + 1] = tiny
    out = assert(io.open(tiny, "wb"))
    out:write("PK")
    out:close()
    ok(not Epub.is_complete(tiny), "is_complete：过短的残片 → false")
end

cleanup()

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
