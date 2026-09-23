-- technews/sources/nine2five.lua — 9to5Mac 适配器
--
-- RSS 描述为短摘要，完整正文在文章页（WordPress，服务端渲染）。
-- 正文容器为 <div class="container med post-content">，内为首图 <figure> + <p> 段落。
-- 文末由主题追加一段「亚马逊好物」联盟推广（标题随文章变化，如
-- 「Worth checking out on Amazon」/「Best iPad … accessories」/
-- 「My favorite Apple deals right now」），其后依次是谷歌来源徽章、
-- FTC 联盟声明与文末推广段。结束标记取最早出现者，先把联盟推广的标题也列入，
-- 命中时整段推广即被切掉；若标题变体未命中，则退到来源徽章 / 声明 / 侧栏 <aside>。
-- 注意：feed 的 pubDate 为 RFC822 +0000。

return {
    id = "nine2five",
    name = "9to5Mac",
    menu_label = "9to5Mac · 今日资讯", -- 菜单项文案（缺省时用 name 生成）
    feed = "https://9to5mac.com/feed/",
    mode = "fulltext",       -- 抓取每篇正文（RSS 描述仅是摘要）
    max_items = 20,          -- 逐篇抓取，控制条数
    merge_max_items = 5,     -- 合并视图中的条数
    default_enabled = false, -- 默认停用（用户可在「订阅源设置」里开启）
    article_extract = {
        starts = { '<div class="container med post-content">' },
        ends = {
            'Worth checking out on Amazon',
            'Best iPad, Apple Watch, Apple TV accessories',
            'My favorite Apple deals right now',
            '<div class="google-preferred-source-badge">',
            '<div class="ad-disclaimer-container">',
            '<aside',
        },
        max_len = 60000,
    },
}
