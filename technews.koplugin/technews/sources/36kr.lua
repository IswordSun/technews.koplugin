-- technews/sources/36kr.lua — 36氪适配器
--
-- 注意：feed 必须带 www（无 www 的 36kr.com/feed 会返回反爬 HTML 页面）。
-- 描述即完整正文（约 4-5 千字，含图片），无需逐篇抓取。
-- 时间格式为 "YYYY-MM-DD HH:MM:SS +0800"（非 RFC822，rss.lua 已支持）。
-- 另有深度文章流 https://www.36kr.com/feed-article（50 条）可按需换用。

return {
    id = "36kr",
    name = "36氪",
    menu_label = "36氪 · 今日资讯",
    feed = "https://www.36kr.com/feed",
    mode = "summary",        -- 描述即完整正文（含图片）
    max_items = 30,
    merge_max_items = 8,
    default_enabled = false, -- 默认停用（用户可在「订阅源设置」里开启）
}
