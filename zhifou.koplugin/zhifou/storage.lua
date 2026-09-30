-- zhifou/storage.lua — EPUB 缓存与目录管理
--
-- 目录：<koreader 数据目录>/zhifou/
-- 文件：<source_id>-<date>.epub（如 ithome-2026-09-16.epub、merged-2026-09-16.epub）

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local epub = require("zhifou.epub")

local storage = {}

storage.dir = DataStorage:getDataDir() .. "/zhifou/"

function storage:init()
    -- 过渡：旧版本数据目录 <data>/technews/ → <data>/zhifou/
    -- （缓存/收藏/索引整体搬移；新目录已存在时保持现状，只补建）
    local legacy_dir = DataStorage:getDataDir() .. "/technews"
    if lfs.attributes(legacy_dir, "mode") == "directory"
        and lfs.attributes(self.dir, "mode") ~= "directory" then
        local target = self.dir:gsub("/$", "")
        local ok, rename_err = os.rename(legacy_dir, target)
        if not ok then
            logger.warn("zhifou cannot migrate legacy data dir:",
                legacy_dir, "->", target, tostring(rename_err))
        end
    end
    if lfs.attributes(self.dir, "mode") ~= "directory" then
        -- 逐级创建（兼容父目录不存在）
        local cur = self.dir:sub(1, 1) == "/" and "/" or ""
        for part in self.dir:gmatch("[^/]+") do
            cur = cur .. part .. "/"
            if lfs.attributes(cur, "mode") ~= "directory" then
                local ok, err = lfs.mkdir(cur)
                if not ok then
                    logger.warn("zhifou cannot create dir:", cur, tostring(err))
                    return
                end
            end
        end
    end
end

function storage:epub_path(source_id, date)
    return self.dir .. source_id .. "-" .. date .. ".epub"
end

--- 缓存期文件是否存在**且内容完整**（缓存命中的唯一判定）。
-- 只判 mode=="file" 是不够的：写盘中断（磁盘满/断电）会留下截断的 EPUB，
-- 当成命中直接打开会报 unsupported or invalid document，且永远不会重抓。
function storage:epub_exists(source_id, date)
    local path = self:epub_path(source_id, date)
    if lfs.attributes(path, "mode") ~= "file" then return false end
    if not epub.is_complete(path) then
        -- 不删：留给「缓存清理」可见可删；这里只当作未命中，触发重新抓取
        logger.warn("zhifou cache epub incomplete, refetch:", path)
        return false
    end
    return true
end

-- 前置声明（定义见文件末尾，remove_issue/clear_* 也要用）
local remove_recursive

--- 删除一个缓存期刊物（含 .sdr 阅读状态与 .items.lua sidecar）；name = 文件名
function storage:remove_issue(name)
    os.remove(self.dir .. name)
    remove_recursive(self.dir .. name .. ".sdr")
    os.remove(self.dir .. name .. ".items.lua") -- 条目 sidecar（收藏定位用）
end

--- 列出缓存中的期刊物：{ name=文件名, id=源id, date=YYYY-MM-DD, path=完整路径 }
-- 排序：日期倒序；同一天里合并期在前（更完整），其余按 id。
-- 供「往期缓存」（浏览）与「缓存清理」（逐期删除）共用。
function storage:list_issues()
    if lfs.attributes(self.dir, "mode") ~= "directory" then return {} end
    local entries = {}
    for name in lfs.dir(self.dir) do
        local id, date = name:match("^(.-)%-(%d%d%d%d%-%d%d%-%d%d)%.epub$")
        if id and date then
            entries[#entries + 1] = {
                name = name, id = id, date = date, path = self.dir .. name,
            }
        end
    end
    table.sort(entries, function(a, b)
        if a.date ~= b.date then return a.date > b.date end
        if a.id ~= b.id then
            -- 同一天里合并期在前（更完整）
            if a.id == "merged" then return true end
            if b.id == "merged" then return false end
            return a.id < b.id
        end
        -- 兜底：同名不可能（文件名唯一），但必须有确定结果，
        -- 否则「与自己比较返回 true」会破坏严格弱序，排序结果随机错乱
        return a.name < b.name
    end)
    return entries
end

--- 删除指定日期的全部 EPUB 及其 .sdr 阅读状态（重新抓取用）
function storage:clear_date(date)
    -- 目录不存在时 lfs.dir 迭代会抛错，直接返回
    if lfs.attributes(self.dir, "mode") ~= "directory" then return end
    local suffix = "-" .. date .. ".epub"
    local names = {}
    for name in lfs.dir(self.dir) do
        if name:sub(-#suffix) == suffix then
            names[#names + 1] = name
        end
    end
    for _, name in ipairs(names) do
        self:remove_issue(name)
    end
end

--- 清空全部缓存（EPUB 与对应 .sdr 阅读状态）
function storage:clear_all()
    -- 目录不存在时 lfs.dir 迭代会抛错，直接返回
    if lfs.attributes(self.dir, "mode") ~= "directory" then return end
    local names = {}
    for name in lfs.dir(self.dir) do
        if name:sub(-5) == ".epub" then
            names[#names + 1] = name
        end
    end
    for _, name in ipairs(names) do
        self:remove_issue(name)
    end
end

-- 递归删除文件/目录（用于清理 EPUB 与 .sdr 阅读状态目录）
remove_recursive = function(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove_recursive(path .. "/" .. entry)
            end
        end
        lfs.rmdir(path)
    elseif mode then
        os.remove(path)
    end
end

--- 清理超过 retain_days 天的缓存（EPUB 与对应 .sdr 阅读状态）。
-- 按**文件修改时间**（=抓取时间）判定，而不是文件名里的日期：
-- 「抓取往期」的历史期刊文件名带目标日期（如 merged-2026-09-19.epub），按文件名
-- 判会在落盘瞬间被当成过期删除——实测阅读器打开它时报 unsupported or invalid
-- document（文件已被清掉）。按 mtime 判既修此问题，又保持"保留最近 7 天抓取"语义。
-- @param protect 可选：{ [绝对路径] = true }，命中的文件不删。
--   用途：KOReader 启动时会先打开上次阅读的文档、之后才构造插件并调用本函数，
--   若那一期已过保留期，就会把**正在阅读**的 EPUB 连同 .sdr 进度一起删掉。
function storage:cleanup(retain_days, protect)
    -- 目录不存在时 lfs.dir 迭代会抛错，直接返回
    if lfs.attributes(self.dir, "mode") ~= "directory" then return 0 end
    retain_days = retain_days or 7
    local cutoff = os.time() - retain_days * 86400
    local names = {}
    for name in lfs.dir(self.dir) do
        if name:sub(-5) == ".epub" then
            local path = self.dir .. name
            if not (protect and protect[path]) then
                local attr = lfs.attributes(path)
                local mtime = attr and attr.modification
                if mtime and mtime < cutoff then
                    names[#names + 1] = name
                end
            end
        end
    end
    for _, name in ipairs(names) do
        self:remove_issue(name)
        logger.info("zhifou cleanup removed:", name)
    end
    self:cleanup_partials()
    return #names
end

--- 回收残留的 .part（构建中断/断电留下的半成品）。
-- 它们与整期同尺寸，却不在任何清理路径的扫描范围内（只认 .epub），
-- 不清就会一直占地方。阈值 1 天：避免误删正在进行中的构建。
function storage:cleanup_partials(min_age_seconds)
    if lfs.attributes(self.dir, "mode") ~= "directory" then return 0 end
    local cutoff = os.time() - (min_age_seconds or 86400)
    local removed = 0
    for name in lfs.dir(self.dir) do
        if name:sub(-5) == ".part" then
            local path = self.dir .. name
            local attr = lfs.attributes(path)
            local mtime = attr and attr.modification
            if mtime and mtime < cutoff then
                os.remove(path)
                removed = removed + 1
                logger.info("zhifou cleanup removed partial:", name)
            end
        end
    end
    return removed
end

return storage
