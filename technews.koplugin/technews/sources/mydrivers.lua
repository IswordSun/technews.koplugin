-- technews/sources/mydrivers.lua — 快科技适配器
--
-- RSS 描述为短摘要（约 100~200 字），完整正文需抓文章页；文章页服务端渲染。
-- 正文容器为 <div class="news_info">，其内以多个 <p> 段落 + 配图组成。
-- 结束标记取页面上最早出现者：
--   class="zhuanzai"        —— 正文末尾的【本文结束】/责编页脚（首选）
--   <div class="navs_newsinfo  —— 「相关资讯」列表
--   <div class="news_zc">     —— 打赏 / 打分区块（兜底）
-- 图片走 //img1.mydrivers.com（协议相对，htmltext 会补 https）。
-- 注意：feed 域名 rss.mydrivers.com，正文域名 news.mydrivers.com；pubDate 为 RFC822 +0800。

return {
    id = "mydrivers",
    name = "快科技",
    menu_label = "快科技 · 今日资讯", -- 菜单项文案（缺省时用 name 生成）
    feed = "http://rss.mydrivers.com/rss.aspx?Tid=1",
    mode = "fulltext",       -- 抓取每篇正文（RSS 描述仅是摘要）
    max_items = 30,          -- 新闻量大，逐篇抓取时控制条数
    merge_max_items = 6,     -- 合并视图中的条数
    default_enabled = false, -- 默认停用（用户可在「订阅源设置」里开启）
    article_extract = {
        starts = { '<div class="news_info">' },
        ends = {
            'class="zhuanzai"',
            '<div class="navs_newsinfo',
            '<div class="news_zc">',
        },
        max_len = 40000,
    },
}
