-- technews/sources/juejin.lua — 掘金适配器
--
-- feed 约 20 条；RSS 描述是短摘要，完整正文需抓文章页。
-- 文章页为 Vue SSR（Nuxt）服务端渲染，正文容器 <div id="article-root" itemprop="articleBody">
--   全页唯一；容器内先有一大段内联 <style>（Markdown 主题 CSS，无 <p>/<img>，可安全略过），
--   其后才是真正的 <p> 正文段落与 mark-v1 水印图（p*-xtjj-sign.byteimg.com）。
-- 结束标记取 </article>（正文外层 <article> 的闭合，全页唯一）；
--   其后的 <div class="article-end">、标签区与推荐位均不属正文。
-- 图片走 byteimg.com 图床（无防盗链，直接取图）。
-- 注意：feed 的 pubDate 为 RFC822 +0800。

return {
    id = "juejin",
    name = "掘金",
    menu_label = "掘金 · 今日文章", -- 菜单项文案（缺省时用 name 生成）
    feed = "https://juejin.cn/rss",
    mode = "fulltext",       -- 抓取每篇正文（RSS 描述仅是摘要）
    max_items = 20,          -- 单独阅读时的条数（feed 全量约 20 条）
    merge_max_items = 5,     -- 合并视图中的条数
    default_enabled = false, -- 默认停用（用户可在「订阅源设置」里开启）
    article_extract = {
        starts = {
            '<div id="article-root" itemprop="articleBody"', -- 正文容器（全页唯一）
        },
        ends = {
            '</article>',              -- 正文外层闭合（全页唯一）
            '<div class="article-end', -- 文末标签区（兜底）
        },
        max_len = 80000,
    },
}
