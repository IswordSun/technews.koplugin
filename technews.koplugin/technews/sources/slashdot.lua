-- technews/sources/slashdot.lua — Slashdot 适配器（英文）
--
-- RDF（RSS 1.0）格式：<item rdf:about=...>，时间为 <dc:date> ISO8601
-- （rss.lua 已支持）；description 即完整正文（纯文本，聚合讨论风格）。

return {
    id = "slashdot",
    name = "Slashdot",
    menu_label = "Slashdot · 今日资讯",
    feed = "https://rss.slashdot.org/Slashdot/slashdotMain",
    mode = "summary",        -- description 即完整正文
    max_items = 30,
    merge_max_items = 6,
    default_enabled = false,
}
