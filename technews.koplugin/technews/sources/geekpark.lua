-- technews/sources/geekpark.lua — 极客公园适配器
--
-- RSS 描述即完整正文（含图片），因此用摘要模式即可，无需逐篇抓取。
-- 注意：feed 的 pubDate 为 RFC822 +0800；部分文章中图片是独立段落。
-- 图片主要走 imgslim.geekpark.net CDN；少数为微信图床 mmbiz.qpic.cn
-- （不可缩放、需无反盗链），另有极少量 geek.feishu.cn。

return {
    id = "geekpark",
    name = "极客公园",
    menu_label = "极客公园 · 今日资讯", -- 菜单项文案（缺省时用 name 生成）
    feed = "https://www.geekpark.net/rss",
    mode = "summary",        -- 直接用 RSS 描述（含完整 HTML 与图片）
    max_items = 30,          -- 单独阅读时的条数（feed 全量约 30 条）
    merge_max_items = 12,    -- 合并视图中的条数
    default_enabled = false, -- 默认停用（用户可在「订阅源设置」里开启）
}
