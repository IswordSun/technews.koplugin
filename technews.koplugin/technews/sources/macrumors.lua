-- technews/sources/macrumors.lua — MacRumors 适配器（英文，苹果生态）
--
-- description 即完整正文（约 2-3 千字，含图）。pubDate 为 RFC822 GMT。

return {
    id = "macrumors",
    name = "MacRumors",
    menu_label = "MacRumors · 今日资讯",
    feed = "https://www.macrumors.com/macrumors.xml",
    mode = "summary",        -- description 即完整正文（含图片）
    max_items = 20,
    merge_max_items = 6,
    default_enabled = false,
}
