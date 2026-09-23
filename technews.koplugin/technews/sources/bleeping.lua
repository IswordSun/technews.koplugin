-- technews/sources/bleeping.lua — BleepingComputer 适配器
--
-- RSS 描述为短摘要，完整正文在文章页（服务端渲染，Cloudflare 前置）。
-- 正文容器为 <div class="articleBody">，内为标准 <p> 段落 + 配图（首图在 <p> 内）。
-- 正文之后是联盟推广块 <div class="article-callout">（含广告图），
-- 再往后是相关文章 / 作者简介 / 评论区。结束标记取最早出现者：
--   <div class="article-callout">          —— 文末联盟推广（首选）
--   <div class="cz-related-article-wrapp"> —— 相关文章
--   <div class="cz-full-bio-content-wrapp"> —— 作者简介
--   id="comment_form"                     —— 评论区（兜底）
-- 图片走 www.bleepstatic.com，无需 Referer。
-- 注意：feed 的 pubDate 为 RFC822 +0000。

return {
    id = "bleeping",
    name = "BleepingComputer",
    menu_label = "BleepingComputer · 今日资讯", -- 菜单项文案（缺省时用 name 生成）
    feed = "https://www.bleepingcomputer.com/feed/",
    mode = "fulltext",       -- 抓取每篇正文（RSS 描述仅是摘要）
    max_items = 20,          -- 逐篇抓取，控制条数
    merge_max_items = 5,     -- 合并视图中的条数
    default_enabled = false, -- 默认停用（用户可在「订阅源设置」里开启）
    article_extract = {
        starts = { '<div class="articleBody">' },
        ends = {
            '<div class="article-callout">',
            '<div class="cz-related-article-wrapp">',
            '<div class="cz-full-bio-content-wrapp">',
            'id="comment_form"',
        },
        max_len = 40000,
    },
}
