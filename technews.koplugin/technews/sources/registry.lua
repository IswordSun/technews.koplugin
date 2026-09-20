-- technews/sources/registry.lua — 全部可用订阅源的登记处（有序）
--
-- 新增订阅源时只在这里追加一行适配器；是否默认启用由适配器的
-- default_enabled 决定，用户可在「订阅源设置」里覆盖。
-- 说明：cnbeta 适配器保留但未登记（.tw 域名大陆直连不可达，已停用）。

return {
    require("technews.sources.ithome"),
    require("technews.sources.leiphone"),
}
