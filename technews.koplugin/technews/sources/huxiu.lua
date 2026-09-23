-- technews/sources/huxiu.lua — 虎嗅适配器
--
-- 官方老 feed（www.huxiu.com/rss/0.xml）已停止服务；现用独立域 rss.huxiu.com。
-- 描述即完整正文（约 2-3 千字），无需逐篇抓取。pubDate 为 RFC822 +0800。

return {
    id = "huxiu",
    name = "虎嗅",
    menu_label = "虎嗅 · 今日资讯",
    feed = "https://rss.huxiu.com/",
    mode = "summary",        -- 描述即完整正文
    max_items = 40,
    merge_max_items = 8,
    default_enabled = false,
}
