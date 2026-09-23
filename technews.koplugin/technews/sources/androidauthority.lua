-- technews/sources/androidauthority.lua — Android Authority 适配器（英文）
--
-- 正文在 content:encoded（完整 HTML）。条目量大（feed 单次可达 80 条），
-- 合并期默认少取。pubDate 为 RFC822 GMT。

return {
    id = "androidauthority",
    name = "Android Authority",
    menu_label = "Android Authority · 今日资讯",
    feed = "https://www.androidauthority.com/feed/",
    mode = "summary",        -- content:encoded 即完整正文
    max_items = 30,
    merge_max_items = 6,
    default_enabled = false,
}
