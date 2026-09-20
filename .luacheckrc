-- Luacheck 配置 — technews.koplugin
-- 用法：在项目根目录执行 `luacheck technews.koplugin`
--
-- 参考：koreader-dev/.luacheckrc（KOReader 主仓库，本工作区权威样板）

-- 设备运行时是 LuaJIT 2.1（KOReader 自带 LuaJIT）；std "luajit"
-- 提供 bit/utf8 等，并与 KOReader 自身 .luacheckrc 保持一致。
std = "luajit"

-- 部分菜单方法用冒号语法定义但未使用实例状态（如 TechNews:autoRefreshEnabled、
-- TechNews:confirmRefetch），其隐式 self 参数并非真正的未使用变量。
-- 与 koreader-dev/.luacheckrc 的 `self = false` 同理，仅忽略隐式 self，
-- 显式传入的参数仍会被检查。
self = false

-- KOReader 宿主进程提供 / 插件自身使用的全局变量（仅列真正用到者）。
globals = {
    -- KOReader 全局设置存储（main.lua 中 readSetting/saveSetting）
    "G_reader_settings",
    -- 自测一次性守卫，在 main.lua:75 赋值（插件经 dofile 重载，模块态
    -- 会被重置，必须用全局记录，属有意为之）
    "G_technews_selftest_done",
}

-- technews/epub.lua 内嵌单行 EPUB XML/XHTML 模板与 string.format 标记串，
-- 超长行是有意为之（换行反而难读）。仅行宽问题，故按文件收窄忽略。
files["technews.koplugin/technews/epub.lua"] = {
    ignore = {
        "631", -- line is too long
    },
}
