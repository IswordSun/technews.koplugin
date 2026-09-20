-- technews/sources/cnbeta.lua — CNBeta 适配器
--
-- RSS 描述约 360 字（含 HTML），完整正文仍逐篇抓文章页提取。
-- 2026-09-20：旧 feed backend.php 已 302 跳转 MSN，改用 rss.cnbeta.com.tw；
-- 部分网络（境外出口 IP）下文章页也会 302，抓取失败时回退到 RSS 描述。

return {
    id = "cnbeta",
    name = "CNBeta",
    feed = "https://rss.cnbeta.com.tw/",
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
