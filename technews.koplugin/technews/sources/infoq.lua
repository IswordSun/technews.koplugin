-- technews/sources/infoq.lua — InfoQ 中文适配器
--
-- feed 约 20 条；RSS 描述是短摘要，完整正文需抓文章页。
-- 文章页为 Vue SSR（Nuxt）：页面 HTML 里 <style> 多份，且内联 JSON 中出现过
--   "ProseMirror" 字样，但真正的正文容器 <div class="ProseMirror"> 全页仅一处，
--   故用它作起始标记（纯文本匹配不会误命中 CSS / JSON 中的散词）。
-- 正文段落为 <p data-type="paragraph">，图片为独立的 <img src="...data-type="image">。
-- 结束标记用 </article>（全页唯一，闭合正文外层 <article>）；
--   其后是骨架屏评论区，不属正文。文章页头部另有「AI摘要」<section>，在起始标记之前，自动排除。
-- 图片走 static001.geekbang.org / static001.infoq.cn（无防盗链，直接取图）。
-- 注意：feed 的 pubDate 为 RFC822 +0800。

return {
    id = "infoq",
    name = "InfoQ 中文",
    menu_label = "InfoQ 中文 · 今日资讯", -- 菜单项文案（缺省时用 name 生成）
    feed = "https://www.infoq.cn/feed",
    mode = "fulltext",       -- 抓取每篇正文（RSS 描述仅是摘要）
    max_items = 20,          -- 单独阅读时的条数（feed 全量约 20 条）
    merge_max_items = 6,     -- 合并视图中的条数
    default_enabled = false, -- 默认停用（用户可在「订阅源设置」里开启）
    article_extract = {
        starts = {
            '<div class="ProseMirror">', -- 正文容器（全页唯一）
        },
        ends = {
            '</article>', -- 正文外层闭合（全页唯一）
        },
        max_len = 80000,
    },
}
