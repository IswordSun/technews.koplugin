-- technews/sources/ruanyf.lua — 阮一峰「科技爱好者周刊」适配器
--
-- Atom feed（<entry> / <updated> ISO8601，rss.lua 已支持）；内容在 <content> 内
-- 即完整正文（约 5 千字，含图）。更新频率：周刊每周 1 期（另有零星博客文），
-- 总量小但质量高，合并期取 3 条以内即可。

return {
    id = "ruanyf",
    name = "阮一峰",
    menu_label = "阮一峰 · 科技爱好者周刊",
    feed = "https://www.ruanyifeng.com/blog/atom.xml",
    mode = "summary",        -- <content> 即完整正文
    max_items = 5,
    merge_max_items = 3,
    default_enabled = false,
}
