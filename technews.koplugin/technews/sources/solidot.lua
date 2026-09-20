-- technews/sources/solidot.lua — Solidot 适配器
--
-- RSS 描述即完整正文（已对照文章页核实），无图片、以短帖为主，
-- 因此用摘要模式即可，无需逐篇抓取。
-- 注意：feed 的 pubDate 为 RFC822 +0800。

return {
    id = "solidot",
    name = "Solidot",
    menu_label = "Solidot · 今日情报", -- 菜单项文案（缺省时用 name 生成）
    feed = "https://www.solidot.org/index.rss",
    mode = "summary",        -- 直接用 RSS 描述（即完整正文，无图）
    max_items = 20,          -- 单独阅读时的条数（feed 全量约 20 条）
    merge_max_items = 10,    -- 合并视图中的条数
    default_enabled = false, -- 默认停用（用户可在「订阅源设置」里开启）
}
