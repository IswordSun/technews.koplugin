-- technews/sources/sspai.lua — 少数派适配器
--
-- 量小：feed 总共只有 10 条（约 2 条/天），故 max_items = 10（全取）。
-- RSS 描述是 ~83-190 字摘要，需抓文章页正文；文章页为服务端渲染。
-- 正文容器有两套模板（双模板，见 extract.lua 的 starts）：
--   普通文章：<div class="article__main__content wangEditor-txt"...>
--   派早报：  <article class="morning__paper__article"...>（无前者的每日汇总）
-- 结束标记取页面上最早出现者（页脚 / 评论区 / </article>），两套模板一致。
-- 图片走 cdnfile.sspai.com（均在 <figure> 内），该图床要求带 Referer
-- （https://sspai.com/）才能取图，否则可能被拒。
-- 正文内推广段落以 "> " 文本前缀开头，用 drop 关键词过滤。
-- 注意：feed 的 pubDate 为 RFC822 +0800。

return {
    id = "sspai",
    name = "少数派",
    menu_label = "少数派 · 今日文章", -- 菜单项文案（缺省时用 name 生成）
    feed = "https://sspai.com/feed",
    mode = "fulltext",       -- 抓取每篇正文（RSS 描述仅是摘要）
    max_items = 10,          -- feed 全量即 10 条，逐篇抓取
    merge_max_items = 5,     -- 合并视图中的条数
    default_enabled = false, -- 默认停用（用户可在「订阅源设置」里开启）
    article_extract = {
        starts = {
            '<div class="article__main__content wangEditor-txt"', -- 普通文章
            '<article class="morning__paper__article"',           -- 派早报（每日汇总）
        },
        ends = {
            '<div class="article__footer article__section__wrapper',
            'id="article-comment-box"',
            '</article>',
        },
        max_len = 60000,
        drop = {
            "少数派为你呈现",
            "少数派 sspai 官方店铺",
            "少数派小红书",
            "sspai.com/mall",
            "shop549593764.taobao.com",
            "xiaohongshu.com/user/profile",
        },
    },
}
