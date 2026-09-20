-- technews/sources/ithome.lua — IT之家适配器
--
-- 官方 RSS 直接给出带 HTML 的完整描述（平均 ~600 字，短新闻即全文），
-- 因此用摘要模式即可，无需逐篇抓取。

return {
    id = "ithome",
    name = "IT之家",
    feed = "https://www.ithome.com/rss/",
    mode = "summary",       -- 直接用 RSS 描述（含完整 HTML 与图片）
    max_items = 60,         -- 单独阅读时的条数
    merge_max_items = 30,   -- 合并视图中的条数
    min_items = 15,         -- 今日不足此数时向前回补（保证早晨的信息量）
    max_images_per_item = 1, -- 每条取第 1 张图（新闻头图）
}
