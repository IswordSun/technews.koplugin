-- technews/sources/ifanr.lua — 爱范儿适配器
--
-- RSS 描述是短摘要，完整正文 HTML 在 <content:encoded> 中
-- （rss.lua 优先取 content:encoded），因此用摘要模式即可，无需逐篇抓取。
-- 注意：feed 的 pubDate 为 RFC822 +0000（真 GMT），解析器按 ±HHMM 处理。
-- 图片走 s3.ifanr.com CDN（均在 <p> 内）；其中混有 WordPress 小表情
-- （s.w.org），由 htmltext 的图片升级逻辑过滤。单条约 8~23 张图。

return {
    id = "ifanr",
    name = "爱范儿",
    menu_label = "爱范儿 · 今日资讯", -- 菜单项文案（缺省时用 name 生成）
    feed = "https://www.ifanr.com/feed",
    mode = "summary",        -- 直接用 RSS 描述（完整 HTML 在 content:encoded）
    max_items = 20,          -- 单独阅读时的条数（feed 全量约 20 条）
    merge_max_items = 10,    -- 合并视图中的条数
    default_enabled = false, -- 默认停用（用户可在「订阅源设置」里开启）
}
