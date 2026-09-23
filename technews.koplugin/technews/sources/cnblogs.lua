-- technews/sources/cnblogs.lua — 博客园适配器
--
-- feed 为「园子首页」精华帖，约 20 条；RSS 描述是短摘要，完整正文需抓文章页。
-- 文章页为服务端渲染（老式 ASP.NET，非 SPA）：正文容器
--   <div id="cnblogs_post_body" class="blogpost-body cnblogs-markdown">（全页唯一），
--   内含 <h1>/<h2>/<h3> 小标题、<p> 段落、<ol><li> 列表，以及 <pre><code> 代码块。
-- 结束标记取正文之后的元信息块 id="blog_post_info_block"（其后 id="post_next_prev"
--   为上/下一篇导航，一并作兜底）。
-- 注意：htmltext.blocks 只解析 <p>/<li>/<h2..h4>，<pre><code> 内的代码不产出文本块；
--   博客园技术长文的段落量通常仍足够，代码会以相邻段落形式丢失（可接受）。
-- 图片多托管在 img*.cnblogs.com（无防盗链）。feed 的 pubDate 为 RFC822 +0800。

return {
    id = "cnblogs",
    name = "博客园",
    menu_label = "博客园 · 今日精选", -- 菜单项文案（缺省时用 name 生成）
    feed = "https://feed.cnblogs.com/blog/sitehome/rss",
    mode = "fulltext",       -- 抓取每篇正文（RSS 描述仅是摘要）
    max_items = 20,          -- 单独阅读时的条数（feed 全量约 20 条）
    merge_max_items = 5,     -- 合并视图中的条数
    default_enabled = false, -- 默认停用（用户可在「订阅源设置」里开启）
    article_extract = {
        starts = {
            '<div id="cnblogs_post_body"', -- 正文容器（全页唯一）
        },
        ends = {
            'id="blog_post_info_block"', -- 正文后的元信息块
            'id="post_next_prev"',       -- 上/下一篇导航（兜底）
        },
        max_len = 80000,
        drop = {
            "adsbygoogle",
        },
    },
}
