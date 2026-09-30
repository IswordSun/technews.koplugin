-- spec/custom_sources_spec.lua — 自定义订阅源纯逻辑的单元测试
--
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/custom_sources_spec.lua）
-- 不依赖任何测试框架；所有断言通过时退出码为 0，否则为 1。

local spec_dir = (arg and arg[0] or "spec/custom_sources_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local custom = dofile(spec_dir .. "/../zhifou.koplugin/zhifou/custom_sources.lua")

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

----------------------------------------------------------------------
-- URL 归一化
----------------------------------------------------------------------

do
    eq(custom.normalize_url("https://example.com/feed"),
        "https://example.com/feed", "标准地址原样保留")
    eq(custom.normalize_url("  https://example.com/feed/  "),
        "https://example.com/feed", "去空白与末尾斜杠")
    eq(custom.normalize_url("example.com/feed"),
        "https://example.com/feed", "缺协议时补 https")
    eq(custom.normalize_url("http://example.com/rss"),
        "http://example.com/rss", "http 保留（部分源只有 http）")
    eq(custom.normalize_url("https://example.com/feed?utm_source=x&utm_medium=y"),
        "https://example.com/feed", "去掉 utm 跟踪参数")
    eq(custom.normalize_url("https://example.com/feed?id=7"),
        "https://example.com/feed?id=7", "普通查询参数保留")
    eq(custom.normalize_url("https://example.com/a/b/"),
        "https://example.com/a/b", "多级路径只去末尾斜杠")

    eq(custom.normalize_url(""), nil, "空串无效")
    eq(custom.normalize_url(nil), nil, "nil 无效")
    eq(custom.normalize_url("ftp://example.com/feed"), nil, "非 http(s) 无效")
    eq(custom.normalize_url("https://"), nil, "只有协议头无效")
end

----------------------------------------------------------------------
-- id 与名称
----------------------------------------------------------------------

do
    local a = custom.id_for("https://example.com/feed")
    local b = custom.id_for("  https://example.com/feed/  ")
    eq(a, b, "同一地址（不同写法）得到同一个 id")
    ok(a:match("^custom%-%x%x%x%x%x%x%x%x$") ~= nil, "id 形如 custom-xxxxxxxx", a)
    ok(custom.id_for("https://example.com/feed") ~= custom.id_for("https://example.com/other"),
        "不同地址 id 不同")

    eq(custom.name_from_url("https://www.example.com/feed"), "example.com", "默认名取主机名去 www")
    eq(custom.name_from_url("example.com"), "example.com", "缺协议也能取名")
end

----------------------------------------------------------------------
-- 解析（容忍脏数据）
----------------------------------------------------------------------

do
    eq(#custom.parse(nil), 0, "nil → 空表")
    eq(#custom.parse("垃圾"), 0, "非表 → 空表")
    eq(#custom.parse({ "字符串" }), 0, "数组里混入非表元素被丢弃")

    local list = custom.parse({
        { url = "https://a.com/feed", name = "甲" },
        { url = "ftp://bad", name = "乙" },          -- 非法地址
        { url = "https://c.com/feed" },              -- 缺 name
    })
    eq(#list, 2, "坏记录被丢弃，好记录保留")
    eq(list[1].name, "甲", "显式名称保留")
    eq(list[1].mode, "summary", "mode 默认 summary")
    eq(list[1].max_items, custom.DEFAULT_MAX_ITEMS, "条数默认值")
    eq(list[2].name, "c.com", "缺 name 时按主机名补")
    eq(list[2].id, custom.id_for("https://c.com/feed"), "缺 id 时按 URL 补")
end

----------------------------------------------------------------------
-- 添加 / 判重 / 删除 / 修改
----------------------------------------------------------------------

do
    local list = {}
    list = custom.add(list, { url = "https://a.com/feed", name = "甲源" })
    eq(#list, 1, "添加成功")
    eq(list[1].id, custom.id_for("https://a.com/feed"), "id 由 URL 生成")

    local dup, dup_err = custom.add(list, { url = "https://a.com/feed/" })
    eq(dup, nil, "重复地址拒绝")
    eq(dup_err, "这个地址已经添加过了", "重复地址给出原因")

    local bad, bad_err = custom.add(list, { url = "不是地址" })
    eq(bad, nil, "非法地址拒绝")
    eq(bad_err, "地址无效（需要 http/https）", "非法地址给出原因")

    -- 名称过长会被截断（菜单一行放得下）
    local long_name = string.rep("长", 40)
    local list2 = custom.add({}, { url = "https://b.com/feed", name = long_name })
    local chars = 0
    for _ in list2[1].name:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars = chars + 1 end
    eq(chars, custom.MAX_NAME_LENGTH, "超长名称按字符截断")
    eq(custom.add({}, { url = "https://b.com/feed", name = "  多   空格  " })[1].name,
        "多 空格", "名称空白压缩")

    -- 上限
    local many = {}
    for i = 1, custom.MAX_SOURCES do
        many[#many + 1] = { url = "https://s" .. i .. ".com/feed", name = "源" .. i }
    end
    local over, over_err = custom.add(many, { url = "https://overflow.com/feed" })
    eq(over, nil, "超过上限拒绝")
    ok(over_err:find("最多", 1, true) ~= nil, "上限提示", tostring(over_err))

    -- 删除
    local removed, ok_removed = custom.remove(list, list[1].id)
    eq(ok_removed, true, "删除命中")
    eq(#removed, 0, "删除后为空")
    local _, miss = custom.remove(removed, "custom-ffffffff")
    eq(miss, false, "删除不存在的 id 返回 false")

    -- 修改
    local before = custom.add({}, { url = "https://d.com/feed", name = "旧名" })
    local after, changed = custom.update(before, before[1].id,
        { name = "新名", mode = "fulltext", max_items = 30 })
    eq(changed, true, "修改命中")
    eq(after[1].name, "新名", "改名生效")
    eq(after[1].mode, "fulltext", "改类型生效")
    eq(after[1].max_items, 30, "改条数生效")
    eq(after[1].id, before[1].id, "改完 id 不变（启用状态不丢）")

    local unchanged, changed2 = custom.update(after, "custom-00000000", { name = "x" })
    eq(changed2, false, "改不存在的 id 返回 false")
    eq(#unchanged, 1, "原列表不受影响")

    -- 非法字段不写入
    local kept, changed3 = custom.update(after, after[1].id, { mode = "乱写" })
    eq(changed3, false, "非法 mode 拒绝写入")
    eq(kept[1].mode, "fulltext", "被拒后原值不变")
end

----------------------------------------------------------------------
-- 转适配器（fetchSource 认得的形状）
----------------------------------------------------------------------

do
    local adapters = custom.adapters({
        { url = "https://a.com/feed", name = "甲源" },
        { url = "https://b.com/feed", name = "乙源", mode = "fulltext",
          max_items = 30, merge_max_items = 8 },
    })
    eq(#adapters, 2, "两条都转出")

    local a = adapters[1]
    eq(a.id, custom.id_for("https://a.com/feed"), "适配器 id 一致")
    eq(a.feed, "https://a.com/feed", "适配器 feed = url")
    eq(a.mode, "summary", "适配器 mode")
    eq(a.max_items, custom.DEFAULT_MAX_ITEMS, "适配器条数")
    eq(a.merge_max_items, custom.DEFAULT_MERGE_ITEMS, "适配器合并条数")
    eq(a.default_enabled, true, "自定义源默认启用")
    eq(a.custom, true, "带 custom 标记（菜单/自检据此分组）")
    eq(a.menu_label, "甲源 · 今日文章", "菜单文案")

    eq(adapters[2].mode, "fulltext", "全文模式透传")
    eq(adapters[2].max_items, 30, "自定义条数透传")
    eq(adapters[2].merge_max_items, 8, "自定义合并条数透传")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
os.exit(failed == 0 and 0 or 1)
