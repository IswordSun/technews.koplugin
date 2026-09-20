-- spec/rss_spec.lua — technews RSS 解析（rss.lua）的单元测试
--
-- 重点：content:encoded 非空时优先于 description（爱范儿全文正文），
-- 以及 CDATA 剥离、pubDate（时区等价、省略秒）、缺 link 跳过等语义。
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/rss_spec.lua）
-- 不依赖任何测试框架；所有断言通过时退出码为 0，否则为 1。
--
-- rss.lua → technews.htmltext → require("util")（KOReader 运行时模块），
-- 这里用 package.preload 给 util 打桩；桩不做实体解码，故样例一律不含实体。

local spec_dir = (arg and arg[0] or "spec/rss_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = spec_dir .. "/../technews.koplugin"
package.preload["util"] = function() return { htmlEntitiesToUtf8 = function(s) return s end } end
package.path = plugin_dir .. "/?.lua;" .. package.path
local rss = require("technews.rss")

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

-- 纯文本查找（避免把标记里的特殊字符当模式）
local function contains(text, needle, name)
    ok(text ~= nil and text:find(needle, 1, true) ~= nil, name,
        ("needle=%s text=%s"):format(needle, tostring(text)))
end

local function not_contains(text, needle, name)
    ok(text ~= nil and text:find(needle, 1, true) == nil, name,
        ("unexpected needle=%s text=%s"):format(needle, tostring(text)))
end

----------------------------------------------------------------------
-- 同时含 description 与 content:encoded：优先完整正文
----------------------------------------------------------------------
do
    local xml = [=[<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
<channel>
  <title>测试源</title>
  <item>
    <title>爱范儿文章</title>
    <link>https://www.ifanr.com/1234567</link>
    <description><![CDATA[<p>TEASER_ONLY 短摘要。</p>]]></description>
    <content:encoded><![CDATA[<p>FULL_ARTICLE_MARKER 完整正文第一段。</p><p>完整正文第二段。</p>]]></content:encoded>
    <pubDate>Sun, 20 Sep 2026 13:10:39 +0000</pubDate>
  </item>
</channel>
</rss>]=]
    local items = rss.parse(xml)
    eq(#items, 1, "同时含 description 与 content:encoded 时解析出 1 条")
    local it = items[1]
    eq(it.title, "爱范儿文章", "title 正确提取")
    eq(it.link, "https://www.ifanr.com/1234567", "link 正确提取")
    contains(it.summary_html, "FULL_ARTICLE_MARKER", "summary_html 使用 content:encoded 完整正文")
    not_contains(it.summary_html, "TEASER_ONLY", "summary_html 不含 description 摘要")
    ok(it.summary ~= "", "summary 非空")
    contains(it.summary, "FULL_ARTICLE_MARKER", "summary 为 content:encoded 的纯文本")
    not_contains(it.summary, "TEASER_ONLY", "summary 不含摘要文本")
end

----------------------------------------------------------------------
-- 只有 description：保持既有行为
----------------------------------------------------------------------
do
    local xml = [=[<rss version="2.0"><channel>
  <item>
    <title>仅描述</title>
    <link>https://example.com/desc-only</link>
    <description><![CDATA[<p>DESC_ONLY_MARKER 描述正文。</p>]]></description>
    <pubDate>Sun, 20 Sep 2026 13:10:39 +0000</pubDate>
  </item>
</channel></rss>]=]
    local items = rss.parse(xml)
    eq(#items, 1, "只有 description 时解析出 1 条")
    contains(items[1].summary_html, "DESC_ONLY_MARKER", "无 content:encoded 时回退 description（summary_html）")
    contains(items[1].summary, "DESC_ONLY_MARKER", "无 content:encoded 时回退 description（summary）")
end

----------------------------------------------------------------------
-- CDATA 剥离：summary_html 得到裸 HTML
----------------------------------------------------------------------
do
    local xml = [=[<rss version="2.0"><channel>
  <item>
    <title>CDATA</title>
    <link>https://example.com/cdata</link>
    <description>旧描述</description>
    <content:encoded><![CDATA[<p>CDATA_BODY_MARKER</p>]]></content:encoded>
  </item>
</channel></rss>]=]
    local items = rss.parse(xml)
    eq(items[1].summary_html, "<p>CDATA_BODY_MARKER</p>", "content:encoded 外层 CDATA 包装被剥离")
    not_contains(items[1].summary_html, "<![CDATA[", "summary_html 无 CDATA 开始标记")
    not_contains(items[1].summary_html, "]]>", "summary_html 无 CDATA 结束标记")
end

----------------------------------------------------------------------
-- pubDate：+0000 与等价的 +0800 解析为同一时刻
----------------------------------------------------------------------
do
    local xml = [=[<rss version="2.0"><channel>
  <item>
    <title>UTC 写法</title>
    <link>https://example.com/tz-utc</link>
    <pubDate>Sun, 20 Sep 2026 13:10:39 +0000</pubDate>
  </item>
  <item>
    <title>东八区写法</title>
    <link>https://example.com/tz-cn</link>
    <pubDate>Sun, 20 Sep 2026 21:10:39 +0800</pubDate>
  </item>
</channel></rss>]=]
    local items = rss.parse(xml)
    eq(#items, 2, "两条带时区的条目都解析出来")
    ok(items[1].ts ~= nil and items[2].ts ~= nil, "两种时区写法的 pubDate 都能解析")
    eq(items[1].ts, items[2].ts, "+0000 与等价的 +0800 时间戳相同")
end

----------------------------------------------------------------------
-- pubDate：省略秒的写法按 0 秒处理
----------------------------------------------------------------------
do
    local xml = [=[<rss version="2.0"><channel>
  <item>
    <title>省略秒</title>
    <link>https://example.com/no-sec</link>
    <pubDate>Sun, 20 Sep 2026 13:10 +0000</pubDate>
  </item>
  <item>
    <title>带秒</title>
    <link>https://example.com/with-sec</link>
    <pubDate>Sun, 20 Sep 2026 13:10:00 +0000</pubDate>
  </item>
</channel></rss>]=]
    local items = rss.parse(xml)
    eq(#items, 2, "省略秒与带秒的条目都解析出来")
    ok(items[1].ts ~= nil, "省略秒的 pubDate 能解析")
    eq(items[1].ts, items[2].ts, "省略秒与显式 :00 的时间戳相同")
end

----------------------------------------------------------------------
-- 缺 link / 空 link 的条目被跳过
----------------------------------------------------------------------
do
    local xml = [=[<rss version="2.0"><channel>
  <item>
    <title>没有链接</title>
    <description>应被跳过</description>
  </item>
  <item>
    <title>空链接</title>
    <link></link>
  </item>
  <item>
    <title>正常条目</title>
    <link>https://example.com/kept</link>
    <description><![CDATA[<p>KEPT_MARKER</p>]]></description>
  </item>
</channel></rss>]=]
    local items = rss.parse(xml)
    eq(#items, 1, "缺 link 与空 link 的条目被跳过")
    eq(items[1].title, "正常条目", "保留条目的 title 正确")
    eq(items[1].link, "https://example.com/kept", "保留条目的 link 正确")
    contains(items[1].summary_html, "KEPT_MARKER", "保留条目的 summary_html 正确")
    eq(items[1].ts, nil, "无 pubDate 时 ts 为 nil")
end

----------------------------------------------------------------------
-- 空 content:encoded 回退 description
----------------------------------------------------------------------
do
    local xml = [=[<rss version="2.0"><channel>
  <item>
    <title>CDATA 空内容</title>
    <link>https://example.com/empty-1</link>
    <description><![CDATA[<p>FALLBACK_ONE</p>]]></description>
    <content:encoded><![CDATA[]]></content:encoded>
  </item>
  <item>
    <title>空标签</title>
    <link>https://example.com/empty-2</link>
    <description><![CDATA[<p>FALLBACK_TWO</p>]]></description>
    <content:encoded></content:encoded>
  </item>
  <item>
    <title>自闭合</title>
    <link>https://example.com/empty-3</link>
    <description><![CDATA[<p>FALLBACK_THREE</p>]]></description>
    <content:encoded/>
  </item>
</channel></rss>]=]
    local items = rss.parse(xml)
    eq(#items, 3, "空 content:encoded 的条目仍被解析")
    eq(items[1].summary_html, "<p>FALLBACK_ONE</p>", "CDATA 空 content:encoded 回退 description 原文")
    contains(items[1].summary, "FALLBACK_ONE", "回退后 summary 来自 description")
    contains(items[2].summary_html, "FALLBACK_TWO", "空标签 content:encoded 回退 description")
    contains(items[3].summary_html, "FALLBACK_THREE", "自闭合 content:encoded 回退 description")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
