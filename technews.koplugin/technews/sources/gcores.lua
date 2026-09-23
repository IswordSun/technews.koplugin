-- technews/sources/gcores.lua — 机核适配器（游戏 / 科技文化）
--
-- 描述即完整正文（约 2-3 千字，含多图），无需逐篇抓取。pubDate 为 RFC822 +0800。

return {
    id = "gcores",
    name = "机核",
    menu_label = "机核 · 今日资讯",
    feed = "https://www.gcores.com/rss",
    mode = "summary",        -- 描述即完整正文（含图片）
    max_items = 20,
    merge_max_items = 6,
    default_enabled = false,
}
