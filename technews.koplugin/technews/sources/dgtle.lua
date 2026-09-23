-- technews/sources/dgtle.lua — 数字尾巴适配器（数码 / 生活方式）
--
-- 描述即完整正文（约 2 千字，含多图），无需逐篇抓取。pubDate 为 RFC822 +0800。
-- 注意：feed 为 http（该域 https 侧异常），http.lua 会按 scheme 分派请求。

return {
    id = "dgtle",
    name = "数字尾巴",
    menu_label = "数字尾巴 · 今日资讯",
    feed = "http://www.dgtle.com/rss/dgtle.xml",
    mode = "summary",        -- 描述即完整正文（含图片）
    max_items = 30,
    merge_max_items = 6,
    default_enabled = false,
}
