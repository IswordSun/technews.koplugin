-- zhifou/storage.lua — EPUB 缓存与目录管理
--
-- 目录：<koreader 数据目录>/zhifou/
-- 文件：<source_id>-<date>.epub（如 ithome-2026-09-16.epub、merged-2026-09-16.epub）

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

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

function storage:epub_exists(source_id, date)
    return lfs.attributes(self:epub_path(source_id, date), "mode") == "file"
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
        if a.id == "merged" or b.id == "merged" then
            return a.id == "merged" -- 同一天里合并期在前（更完整）
        end
        return a.id < b.id
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
function storage:cleanup(retain_days)
    -- 目录不存在时 lfs.dir 迭代会抛错，直接返回
    if lfs.attributes(self.dir, "mode") ~= "directory" then return 0 end
    retain_days = retain_days or 7
    local cutoff = os.time() - retain_days * 86400
    local names = {}
    for name in lfs.dir(self.dir) do
        local date = name:match("%-(%d%d%d%d%-%d%d%-%d%d)%.epub$")
        if date then
            local y, m, d = date:match("(%d+)-(%d+)-(%d+)")
            local t = os.time{ year = y, month = m, day = d, hour = 12 }
            if t and t < cutoff then
                names[#names + 1] = name
            end
        end
    end
    for _, name in ipairs(names) do
        self:remove_issue(name)
        logger.info("zhifou cleanup removed:", name)
    end
    return #names
end

return storage
