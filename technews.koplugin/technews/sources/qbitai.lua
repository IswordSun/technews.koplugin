-- technews/sources/qbitai.lua — 量子位适配器
--
-- feed 只有 10 条（量子位以公众号为主，官网每日同步数篇），故 max_items = 10（全取）。
-- RSS 描述是短摘要，完整正文需抓文章页；文章页为 WordPress（主题 liangziwei）服务端渲染。
-- 正文容器：<div class="article">，内含 <h1> 标题、作者信息、<div class="zhaiyao"> 导语，
--   其后是 <p data-track="N"> 正文段落与 <img>（图片托管在 www.qbitai.com/wp-content/uploads/）。
-- 结束标记取文章末尾的版权声明块 <div class="line_font">（其后还有 tags / 分享区，均不属正文）。
-- 注意：页面侧栏另有一段 <p>扫码关注量子位</p>，起始标记锁定 <div class="article"> 后可避开。
-- feed 的 pubDate 为 RFC822 +0800。

return {
    id = "qbitai",
    name = "量子位",
    menu_label = "量子位 · 今日资讯", -- 菜单项文案（缺省时用 name 生成）
    feed = "https://www.qbitai.com/feed",
    mode = "fulltext",       -- 抓取每篇正文（RSS 描述仅是摘要）
    max_items = 10,          -- feed 全量即 10 条，逐篇抓取
    merge_max_items = 5,     -- 合并视图中的条数
    default_enabled = false, -- 默认停用（用户可在「订阅源设置」里开启）
    article_extract = {
        starts = {
            '<div class="article">', -- 正文容器（页面仅此一处）
        },
        ends = {
            '<div class="line_font">', -- 版权声明块（正文到此为止）
            '<div class="tags">',      -- 标签区（兜底）
        },
        max_len = 60000,
        drop = {
            "imagesnew/head.jpg", -- 作者信息里的主题默认头像，非正文配图
        },
    },
}
