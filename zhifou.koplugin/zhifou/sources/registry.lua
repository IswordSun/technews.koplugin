-- zhifou/sources/registry.lua — 全部可用订阅源的登记处（有序）
--
-- 新增订阅源时只在这里追加一行适配器；是否默认启用由适配器的
-- default_enabled 决定，用户可在「订阅源设置」里覆盖。
-- 说明：cnbeta 适配器保留但未登记（.tw 域名大陆直连不可达，已停用）。
--
-- 2026-09-23 扩充 20 个源（全部 default_enabled = false，按需在「订阅源设置」勾选）：
--   国内 13：36氪 / 虎嗅 / 钛媒体 / 量子位 / InfoQ / 掘金 / 博客园 / 数字尾巴 /
--             快科技 / 机核 / 游研社 / 阮一峰 / 美团技术
--   境外 7：Android Authority / Slashdot / Hackaday / MacRumors /
--           9to5Mac / BleepingComputer / The Hacker News
--   均为实测“直连可达”（无需代理）；未接入的候选见 AGENTS §2 备注：
--   oschina（文章页客户端渲染）、Phoronix（正文为 <br> 松散文本，现抽取器按 <p> 解析会丢正文）、
--   创业邦（GBK 编码，KOReader 无字符集转换）。

return {
    require("zhifou.sources.ithome"),
    require("zhifou.sources.leiphone"),
    require("zhifou.sources.ifanr"),
    require("zhifou.sources.geekpark"),
    require("zhifou.sources.solidot"),
    require("zhifou.sources.sspai"),

    -- 国内新增（2026-09-23）
    require("zhifou.sources.36kr"),
    require("zhifou.sources.huxiu"),
    require("zhifou.sources.tmtpost"),
    require("zhifou.sources.qbitai"),
    require("zhifou.sources.infoq"),
    require("zhifou.sources.juejin"),
    require("zhifou.sources.cnblogs"),
    require("zhifou.sources.dgtle"),
    require("zhifou.sources.mydrivers"),
    require("zhifou.sources.gcores"),
    require("zhifou.sources.yystv"),
    require("zhifou.sources.ruanyf"),
    require("zhifou.sources.meituan"),

    -- 日报类（2026-09-27）：API 驱动、支持按日期回溯
    -- （分源阅读的「昨日 / 自定义日期 / 近一周」能取到真正的往期）
    require("zhifou.sources.zhihudaily"),
    require("zhifou.sources.one"),
    require("zhifou.sources.readhub"),
    require("zhifou.sources.sixty"),

    -- 小而美（2026-09-27 二轮调研）：体量小、内容精选
    -- （读诗 ≈1 篇/天全文 RSS；触乐 ≈2 篇/天游戏文化长文）
    require("zhifou.sources.bedtimepoem"),
    require("zhifou.sources.chuapp"),

    -- 境外（英文，实测无需代理）——中文源之后，排在最后
    require("zhifou.sources.androidauthority"),
    require("zhifou.sources.slashdot"),
    require("zhifou.sources.hackaday"),
    require("zhifou.sources.macrumors"),
    require("zhifou.sources.nine2five"),
    require("zhifou.sources.bleeping"),
    require("zhifou.sources.thn"),
}
