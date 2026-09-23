-- technews/sources/registry.lua — 全部可用订阅源的登记处（有序）
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
    require("technews.sources.ithome"),
    require("technews.sources.leiphone"),
    require("technews.sources.ifanr"),
    require("technews.sources.geekpark"),
    require("technews.sources.solidot"),
    require("technews.sources.sspai"),

    -- 国内新增（2026-09-23）
    require("technews.sources.36kr"),
    require("technews.sources.huxiu"),
    require("technews.sources.tmtpost"),
    require("technews.sources.qbitai"),
    require("technews.sources.infoq"),
    require("technews.sources.juejin"),
    require("technews.sources.cnblogs"),
    require("technews.sources.dgtle"),
    require("technews.sources.mydrivers"),
    require("technews.sources.gcores"),
    require("technews.sources.yystv"),
    require("technews.sources.ruanyf"),
    require("technews.sources.meituan"),

    -- 境外新增（英文，实测无需代理）
    require("technews.sources.androidauthority"),
    require("technews.sources.slashdot"),
    require("technews.sources.hackaday"),
    require("technews.sources.macrumors"),
    require("technews.sources.nine2five"),
    require("technews.sources.bleeping"),
    require("technews.sources.thn"),
}
