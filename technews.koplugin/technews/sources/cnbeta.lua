-- technews/sources/cnbeta.lua — CNBeta 适配器
--
-- RSS 描述只有 ~140 字摘要，因此逐篇抓文章页提取正文。
-- 正文位于 <div class="cnbeta-article-body"> 容器，含广告段落需过滤。

return {
    id = "cnbeta",
    name = "CNBeta",
    feed = "https://www.cnbeta.com.tw/backend.php",
    mode = "fulltext",      -- 抓取每篇正文
    max_items = 25,         -- 逐篇抓取，控制数量（每篇 1 次请求）
    merge_max_items = 12,
    min_items = 10,         -- 今日不足此数时向前回补
    max_images_per_item = 2, -- 每条最多 2 张正文图
    article_extract = {
        start = '<div class="cnbeta-article-body">',
        ends = {
            '<div class="clear"></div>',
            'id="comments"',
            'class="comments',
        },
        max_len = 30000,
        drop = {
            "adsbygoogle",
            "slotbydup",
            "window.adsbygoogle",
            "googlesyndication",
        },
    },
}
