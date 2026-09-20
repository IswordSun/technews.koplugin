-- technews/sources/ithome.lua — IT之家适配器
--
-- 官方 RSS 直接给出带 HTML 的完整描述（平均 ~600 字，短新闻即全文），
-- 因此用摘要模式即可，无需逐篇抓取。

return {
    id = "ithome",
    name = "IT之家",
    menu_label = "IT之家 · 今日新闻", -- 菜单项文案（缺省时用 name 生成）
    feed = "https://www.ithome.com/rss/",
    mode = "summary",       -- 直接用 RSS 描述（含完整 HTML 与图片）
    max_items = 60,         -- 单独阅读时的条数
    merge_max_items = 30,   -- 合并视图中的条数
    default_enabled = true, -- 默认启用（用户可在「订阅源设置」里修改）
}
