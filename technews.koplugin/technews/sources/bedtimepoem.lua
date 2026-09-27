-- technews/sources/bedtimepoem.lua — 「读首诗再睡觉」适配器
--
-- RSS（WordPress）：全文在 <content:encoded>（description 仅 65 字摘要），
-- 因此用摘要模式，无需逐篇抓取。https://bedtimepoem.com/feed
-- 每天约 1 首（诗歌 + 赏析，常配 1~3 张图）；feed 保留约 45 期（近一两个月），
-- 更早的往期受 feed 限制，与其它 RSS 源一致。
-- 注意：站点在 Cloudflare 之后（大陆当前可达）；真机长期可达性请留意。

return {
    id = "bedtimepoem",
    name = "读首诗再睡觉",
    feed = "https://bedtimepoem.com/feed",
    mode = "summary",        -- 全文在 content:encoded
    max_items = 10,          -- 单独阅读时的条数
    merge_max_items = 3,     -- 合并视图中的条数
    default_enabled = false,
}
