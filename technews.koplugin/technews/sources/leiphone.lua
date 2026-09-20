-- technews/sources/leiphone.lua — 雷锋网适配器
--
-- RSS 描述即完整正文（含图片）：实测单条约 1 万字、36 个 <p>、3 张 <img>，
-- 因此用摘要模式即可，无需逐篇抓取。
-- 图片走七牛 CDN（static.leiphone.com），由 imgurl.lua 注入缩放参数缩图。

return {
    id = "leiphone",
    name = "雷锋网",
    feed = "https://www.leiphone.com/feed",
    mode = "summary",       -- 直接用 RSS 描述（含完整 HTML 与图片）
    max_items = 20,         -- 单独阅读时的条数
    merge_max_items = 10,   -- 合并视图中的条数
    default_enabled = true, -- 默认启用（用户可在「订阅源设置」里修改）
}
