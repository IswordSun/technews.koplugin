-- technews/sources/tmtpost.lua — 钛媒体适配器
--
-- 正文在 content:encoded（完整 HTML，含图片），RSS 描述仅摘要；
-- rss.lua 已优先取 content:encoded，无需逐篇抓取。pubDate 为 RFC822 +0800。

return {
    id = "tmtpost",
    name = "钛媒体",
    menu_label = "钛媒体 · 今日资讯",
    feed = "https://www.tmtpost.com/rss.xml",
    mode = "summary",        -- content:encoded 即完整正文
    max_items = 20,
    merge_max_items = 8,
    default_enabled = false,
}
