-- technews/storage.lua — EPUB 缓存与目录管理
--
-- 目录：<koreader 数据目录>/technews/
-- 文件：<source_id>-<date>.epub（如 ithome-2026-09-16.epub、merged-2026-09-16.epub）

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local storage = {}

storage.dir = DataStorage:getDataDir() .. "/technews/"

function storage:init()
    if lfs.attributes(self.dir, "mode") ~= "directory" then
        -- 逐级创建（兼容父目录不存在）
        local cur = self.dir:sub(1, 1) == "/" and "/" or ""
        for part in self.dir:gmatch("[^/]+") do
            cur = cur .. part .. "/"
            if lfs.attributes(cur, "mode") ~= "directory" then
                local ok, err = lfs.mkdir(cur)
                if not ok then
                    logger.warn("technews cannot create dir:", cur, tostring(err))
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

--- 缓存文件的修改时间（秒），不存在返回 nil
function storage:epub_mtime(source_id, date)
    return lfs.attributes(self:epub_path(source_id, date), "modification")
end

--- 删除指定日期的全部 EPUB（重新抓取用）
function storage:clear_date(date)
    local suffix = "-" .. date .. ".epub"
    local names = {}
    for name in lfs.dir(self.dir) do
        if name:sub(-#suffix) == suffix then
            names[#names + 1] = name
        end
    end
    for _, name in ipairs(names) do
        os.remove(self.dir .. name)
    end
end

--- 清空全部缓存
function storage:clear_all()
    local names = {}
    for name in lfs.dir(self.dir) do
        if name:sub(-5) == ".epub" then
            names[#names + 1] = name
        end
    end
    for _, name in ipairs(names) do
        os.remove(self.dir .. name)
    end
end

--- 已缓存的文件列表（调试用）
function storage:list()
    local names = {}
    for name in lfs.dir(self.dir) do
        if name:sub(-5) == ".epub" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

-- 递归删除文件/目录（用于清理 EPUB 与 .sdr 阅读状态目录）
local function remove_recursive(path)
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
        os.remove(self.dir .. name)
        remove_recursive(self.dir .. name .. ".sdr")
        logger.info("technews cleanup removed:", name)
    end
    return #names
end

return storage
