-- technews/sources/hackaday.lua — Hackaday 适配器（英文，硬件 / DIY）
--
-- 正文在 content:encoded（完整 HTML，含图）。条目量小（每次 7 条左右）。

return {
    id = "hackaday",
    name = "Hackaday",
    menu_label = "Hackaday · 今日资讯",
    feed = "https://hackaday.com/blog/feed/",
    mode = "summary",        -- content:encoded 即完整正文
    max_items = 10,
    merge_max_items = 4,
    default_enabled = false,
}
