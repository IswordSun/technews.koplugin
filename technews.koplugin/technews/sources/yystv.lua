-- technews/sources/yystv.lua — 游研社适配器（游戏文化）
--
-- 描述即完整正文（约 3 千字，含图），无需逐篇抓取。
-- feed 更新频率较低（每天几条）。pubDate 为 RFC822 +0800。

return {
    id = "yystv",
    name = "游研社",
    menu_label = "游研社 · 今日资讯",
    feed = "https://www.yystv.cn/rss/feed",
    mode = "summary",        -- 描述即完整正文（含图片）
    max_items = 12,
    merge_max_items = 5,
    default_enabled = false,
}
