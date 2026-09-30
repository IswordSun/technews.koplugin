-- spec/storage_spec.lua — 缓存管理（storage.lua）的删除/命中判定测试
--
-- 覆盖三件容易出事、又都在「有删除权限」这条路径上的事：
--   1) epub_exists：文件存在 ≠ 内容完整（写盘中断的截断 EPUB 不能当缓存命中）
--   2) cleanup：按 mtime 判过期，且必须豁免**正在阅读**的那一期
--   3) clear_date / clear_all / cleanup_partials：命中哪些文件、连带删掉什么
--
-- 做法：文件真实写在 /tmp 下（epub.is_complete 要读结尾字节），
-- 用受控的 lfs 替身提供 attributes/dir/rmdir（文件名与 mtime 由本 spec 登记），
-- 并给 os.remove / lfs.rmdir 加一层记录，用来断言「删了谁 / 没删谁」。
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/storage_spec.lua）

local spec_dir = (arg and arg[0] or "spec/storage_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = spec_dir .. "/../zhifou.koplugin"
local TMP = "/tmp/"

----------------------------------------------------------------------
-- 受控文件系统替身
----------------------------------------------------------------------

local files = {}    -- 文件名（不含目录）→ mtime
local dirs = {}     -- 目录绝对路径 → 子项集合
local removed = {}  -- os.remove 的调用记录
local rmdirs = {}   -- lfs.rmdir 的调用记录

local mock_lfs = {}

local function is_root(path)
    return path == TMP or path == TMP:sub(1, -2)
end

function mock_lfs.attributes(path, what)
    if is_root(path) or dirs[path] ~= nil then
        if what == "mode" then return "directory" end
        return { mode = "directory", modification = 0 }
    end
    local name = path:sub(#TMP + 1)
    local mtime = files[name]
    if not mtime then return nil end
    if what == "mode" then return "file" end
    if what == "modification" then return mtime end
    return { mode = "file", modification = mtime }
end

-- 真实 lfs.dir 会给出 "." 与 ".."，这里照做（storage 靠后缀过滤，不该被它们影响）
function mock_lfs.dir(path)
    local names, index = { ".", ".." }, 0
    local children = is_root(path) and files or dirs[path]
    for name in pairs(children or {}) do names[#names + 1] = name end
    return function()
        index = index + 1
        return names[index]
    end
end

function mock_lfs.mkdir() return false end

function mock_lfs.rmdir(path)
    rmdirs[path] = true
    dirs[path] = nil
    return true
end

local real_remove = os.remove

package.preload["datastorage"] = function()
    return { getDataDir = function() return TMP:sub(1, -2) end }
end
package.preload["libs/libkoreader-lfs"] = function() return mock_lfs end
package.preload["logger"] = function()
    return {
        info = function() end, warn = function() end,
        dbg = function() end, err = function() end,
    }
end
package.path = plugin_dir .. "/?.lua;" .. package.path

-- 记录 os.remove 的调用：storage 会删不存在的东西（.sdr/.items.lua），
-- 只看「删完还在不在」无法覆盖这些分支，所以这里记录调用本身
-- luacheck: push ignore 122
os.remove = function(path)
    removed[path] = true
    return real_remove(path)
end
-- luacheck: pop

local storage = require("zhifou.storage")
storage.dir = TMP   -- 数据目录直接落 /tmp（避免依赖不存在的子目录）

----------------------------------------------------------------------
-- 极简断言工具
----------------------------------------------------------------------

local checks, failed = 0, 0

local function ok(cond, name, detail)
    checks = checks + 1
    if cond then
        print(("%d ok - %s"):format(checks, name))
    else
        failed = failed + 1
        print(("%d not ok - %s"):format(checks, name))
        if detail then print("    # " .. detail) end
    end
end

local function eq(actual, expected, name)
    ok(actual == expected, name,
        ("实际=%s 期望=%s"):format(tostring(actual), tostring(expected)))
end

----------------------------------------------------------------------
-- 工具：写入真实文件 / 登记目录
----------------------------------------------------------------------

local function write_file(name, content, mtime)
    local file = assert(io.open(TMP .. name, "wb"))
    file:write(content)
    file:close()
    files[name] = mtime or os.time()
    removed[TMP .. name] = nil
    return TMP .. name
end

-- 结构完整的最小 ZIP：结尾 22 字节是 EOCD（签名 + 18 字节零填充）
local function write_complete_epub(name, mtime)
    return write_file(name, "PK\005\006" .. string.rep("\0", 18), mtime)
end

-- 登记一个目录（.sdr 阅读状态在真实设备上就是目录）
local function make_dir(path)
    dirs[path] = {}
    rmdirs[path] = nil
    return path
end

local function reset_fs()
    for name in pairs(files) do
        real_remove(TMP .. name)
    end
    files, dirs, removed, rmdirs = {}, {}, {}, {}
end

local DAY = 86400

----------------------------------------------------------------------
-- 1) epub_exists：存在且完整才算命中
----------------------------------------------------------------------

do
    reset_fs()
    eq(storage:epub_exists("merged", "2026-09-28"), false,
        "epub_exists：文件不存在 → false")

    write_complete_epub("merged-2026-09-28.epub")
    eq(storage:epub_exists("merged", "2026-09-28"), true,
        "epub_exists：结构完整的 EPUB → true")

    write_file("ithome-2026-09-28.epub", string.rep("x", 4096))
    eq(storage:epub_exists("ithome", "2026-09-28"), false,
        "epub_exists：被截断的 EPUB（结尾无 EOCD）→ false")

    write_file("tiny-2026-09-28.epub", "PK\005\006")
    eq(storage:epub_exists("tiny", "2026-09-28"), false,
        "epub_exists：小于 22 字节的残片 → false")
end

----------------------------------------------------------------------
-- 2) list_issues：文件名解析、排序、忽略非期文件
----------------------------------------------------------------------

do
    reset_fs()
    write_complete_epub("ithome-2026-09-27.epub")
    write_complete_epub("merged-2026-09-27.epub")
    write_complete_epub("merged-2026-09-28.epub")
    write_complete_epub("merged-week-2026-09-28.epub")
    write_complete_epub("nodate.epub")
    write_file("notes.txt", "not an issue")

    local list = storage:list_issues()
    eq(#list, 4, "list_issues：只收录 <id>-<日期>.epub")
    eq(list[1].name, "merged-2026-09-28.epub", "list_issues：最新日期在前")
    eq(list[1].id, "merged", "list_issues：合并期 id 解析正确")
    eq(list[2].id, "merged-week", "list_issues：近一周期的 id 解析正确")
    eq(list[3].name, "merged-2026-09-27.epub",
        "list_issues：同一天里合并期排在其它源之前")
    eq(list[4].id, "ithome", "list_issues：单源 id 解析正确")
end

----------------------------------------------------------------------
-- 3) clear_date：删当天全部期（含近一周）+ .sdr + .items.lua
----------------------------------------------------------------------

do
    reset_fs()
    local target = write_complete_epub("merged-2026-09-27.epub")
    local week = write_complete_epub("merged-week-2026-09-27.epub")
    local keep = write_complete_epub("merged-2026-09-28.epub")
    make_dir(target .. ".sdr")
    make_dir(week .. ".sdr")

    storage:clear_date("2026-09-27")

    ok(removed[target], "clear_date：删除当天期的 EPUB")
    ok(removed[week], "clear_date：同一天的近一周期一并删除（后缀匹配）")
    ok(rmdirs[target .. ".sdr"], "clear_date：连带删除 .sdr 阅读状态目录")
    ok(removed[target .. ".items.lua"], "clear_date：连带删除 .items.lua sidecar")
    ok(not removed[keep], "clear_date：不动其它日期")
end

----------------------------------------------------------------------
-- 4) cleanup：mtime 过期判定 + 豁免正在阅读的那一期
----------------------------------------------------------------------

do
    reset_fs()
    local now = os.time()
    local stale = write_complete_epub("merged-2026-09-20.epub", now - 10 * DAY)
    local reading = write_complete_epub("ithome-2026-09-19.epub", now - 9 * DAY)
    local fresh = write_complete_epub("merged-2026-09-28.epub", now - 1 * DAY)
    make_dir(stale .. ".sdr")
    make_dir(reading .. ".sdr")

    local removed_count = storage:cleanup(7, { [reading] = true })

    eq(removed_count, 1, "cleanup：只删过期且未豁免的一期")
    ok(removed[stale], "cleanup：过期期文件被删")
    ok(rmdirs[stale .. ".sdr"], "cleanup：过期期的 .sdr 一并删")
    ok(not removed[reading],
        "cleanup：正在阅读的那一期被豁免（否则连阅读进度一起删）")
    ok(rmdirs[reading .. ".sdr"] == nil, "cleanup：被豁免期的 .sdr 保留")
    ok(not removed[fresh], "cleanup：保留期内的不动")
end

----------------------------------------------------------------------
-- 5) cleanup_partials：回收构建中断残留，但不碰进行中的构建
----------------------------------------------------------------------

do
    reset_fs()
    local now = os.time()
    local stale = write_file("merged-2026-09-20.epub.part", "half", now - 2 * DAY)
    local active = write_file("merged-2026-09-28.epub.part", "half", now - 60)

    local removed_count = storage:cleanup_partials()

    eq(removed_count, 1, "cleanup_partials：只回收陈旧的 .part")
    ok(removed[stale], "cleanup_partials：陈旧的 .part 被删")
    ok(not removed[active], "cleanup_partials：刚写入的 .part 不动（可能是进行中的构建）")
end

----------------------------------------------------------------------
-- 6) clear_all：清空全部 EPUB，但不动 favorites 目录
----------------------------------------------------------------------

do
    reset_fs()
    local a = write_complete_epub("merged-2026-09-27.epub")
    local b = write_complete_epub("ithome-2026-09-28.epub")
    make_dir(a .. ".sdr")

    storage:clear_all()

    ok(removed[a] and removed[b], "clear_all：删除全部期文件")
    ok(rmdirs[a .. ".sdr"], "clear_all：连带 .sdr")
end

reset_fs()

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
