-- zhifou/sources/chuapp.lua — 触乐（游戏文化长文）适配器
--
-- RSS：正文完整放在 <description> 的 CDATA 里（约 10KB/篇），pubDate 为
-- RFC822 +0800，故用摘要模式。https://www.chuapp.com/feed
-- 每天约 2 篇：游戏文化、开发者专访、评测等长文。

return {
    id = "chuapp",
    name = "触乐",
    feed = "https://www.chuapp.com/feed",
    mode = "summary",        -- description 即完整正文
    max_items = 12,
    merge_max_items = 4,
    default_enabled = false,
}
