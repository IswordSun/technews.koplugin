-- technews/sources/meituan.lua — 美团技术团队适配器（技术深度长文）
--
-- 正文在 content:encoded（完整 HTML，单篇可上万字，含图），rss.lua 已优先取用。
-- 更新频率低（每周 1-2 篇）。pubDate 为 RFC822 GMT。

return {
    id = "meituan",
    name = "美团技术",
    menu_label = "美团技术 · 今日文章",
    feed = "https://tech.meituan.com/feed/",
    mode = "summary",        -- content:encoded 即完整正文
    max_items = 10,
    merge_max_items = 4,
    default_enabled = false,
}
