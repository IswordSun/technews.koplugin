-- technews/sources/thn.lua — The Hacker News 适配器
--
-- RSS 描述为短摘要，完整正文在文章页（Blogger，服务端渲染）。
-- 正文容器为 <div class='articlebody clear cf' id='articlebody'>（单引号属性），
-- 内为 <p> 段落 + Blogger 的 <div class="separator"> 配图（图片为独立元素）。
-- 正文之后是分享条 / 标签 / 右侧栏（含广告脚本注入的 <img> 模板字符串）。
-- 结束标记取最早出现者：
--   <div class='sharebelow clear'>  —— 正文末尾的分享条（首选）
--   <div class='tags'>              —— 文章标签
--   <div class='rightbx' id='rightbx'> —— 右侧栏 / 广告（兜底）
-- 注意：正文 marker 用单引号，与页面源码逐字一致；feed 由 Blogger 提供 RSS 2.0，
-- 条目为 <item>，链接是 <link>…</link>（rss.lua 已支持）。

return {
    id = "thn",
    name = "The Hacker News",
    menu_label = "The Hacker News · 今日资讯", -- 菜单项文案（缺省时用 name 生成）
    feed = "https://thehackernews.com/feeds/posts/default",
    mode = "fulltext",       -- 抓取每篇正文（RSS 描述仅是摘要）
    max_items = 20,          -- 逐篇抓取，控制条数
    merge_max_items = 5,     -- 合并视图中的条数
    default_enabled = false, -- 默认停用（用户可在「订阅源设置」里开启）
    article_extract = {
        starts = { "<div class='articlebody clear cf' id='articlebody'>" },
        ends = {
            "<div class='sharebelow clear'>",
            "<div class='tags'>",
            "<div class='rightbx' id='rightbx'>",
        },
        max_len = 60000,
    },
}
