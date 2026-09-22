-- technews/favorites.lua — 收藏（单篇快照 EPUB）
--
-- 目录布局：
--   <koreader 数据目录>/technews/favorites.lua      索引（Lua 数组，按收藏时间倒序）
--   <koreader 数据目录>/technews/favorites/*.epub   单篇快照（自包含标题/正文/图片）
--
-- 快照独立于每日缓存：storage 的 cleanup/clear_date/clear_all 只清理
-- <source_id>-<date>.epub 及其 .sdr/.items.lua，不触碰 favorites/ 与索引，
-- 因此缓存过期或「清理全部缓存」后收藏仍可打开。
--
-- 索引条目：{ title, link, source_name, favorited_at = os.time(), file = 快照绝对路径 }

local dump = require("dump")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local epub = require("technews.epub")
local http = require("technews.http")
local imgurl = require("technews.imgurl")
local storage = require("technews.storage")
local zipread = require("technews.zipread")

local favorites = {}

-- 快照目录与索引位置（索引放在上级目录，避免与快照文件混放）
favorites.dir = storage.dir .. "favorites/"
favorites.index_path = storage.dir .. "favorites.lua"

-- 单篇收藏的图片上限（防超长图文拖慢下载与构建）
local MAX_IMAGES = 40

-- 逐级创建目录（与 storage:init 同思路，兼容父目录不存在）
local function ensure_dir(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    local cur = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        cur = cur .. part .. "/"
        if lfs.attributes(cur, "mode") ~= "directory" then
            local ok, err = lfs.mkdir(cur)
            if not ok then
                logger.warn("technews favorites cannot create dir:", cur, tostring(err))
                return false
            end
        end
    end
    return true
end

local function ensure_dirs()
    return ensure_dir(storage.dir) and ensure_dir(favorites.dir)
end

-- 按 UTF-8 字符截断（按字节截断会切断多字节字符，产生非法文件名）
local function truncate_utf8(text, max_chars)
    local count, pos = 0, 1
    while pos <= #text and count < max_chars do
        local byte = text:byte(pos)
        local size = byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4
        if pos + size - 1 > #text then break end -- 尾字符不完整则不收
        pos = pos + size
        count = count + 1
    end
    return text:sub(1, pos - 1)
end

-- 文件名净化：路径不安全字符替换为 "_"，保留中文，最长 60 字符
local function sanitize_title(title)
    local safe = tostring(title or ""):gsub('[/\\:*?"<>|]', "_")
    safe = truncate_utf8(safe, 60)
    if safe == "" then safe = "article" end
    return safe
end

-- 同秒同名防撞：已存在时加 -2/-3… 后缀
local function unique_path(path)
    if lfs.attributes(path, "mode") ~= "file" then return path end
    local base, ext = path:match("^(.*)(%.epub)$")
    for i = 2, 99 do
        local candidate = base .. "-" .. i .. ext
        if lfs.attributes(candidate, "mode") ~= "file" then return candidate end
    end
    return path
end

-- 从 URL 推断图片扩展名（与 main.lua 的 image_ext 同规则）
local function image_ext(url)
    local path = url:match("^[^?]+") or url
    local ext = path:match("%.([%a%d]+)$")
    if ext then
        ext = ext:lower()
        if ext == "jpeg" then ext = "jpg" end
        if ext == "jpg" or ext == "png" or ext == "gif" or ext == "webp" then
            return ext
        end
    end
    return "jpg"
end

--- 读取索引，按收藏时间倒序；文件缺失/损坏时返回空数组
function favorites.load()
    local list = {}
    local chunk = loadfile(favorites.index_path)
    if chunk then
        local ok, data = pcall(chunk)
        if ok and type(data) == "table" then
            for _, entry in ipairs(data) do
                if type(entry) == "table" and entry.title then
                    list[#list + 1] = entry
                end
            end
        else
            logger.warn("technews favorites index unreadable:", tostring(data))
        end
    end
    table.sort(list, function(a, b)
        return (a.favorited_at or 0) > (b.favorited_at or 0)
    end)
    return list
end

--- 精确标题匹配（收藏定位与判重的唯一依据）；未命中返回 nil
function favorites.find(title)
    if not title or title == "" then return nil end
    for _, entry in ipairs(favorites.load()) do
        if entry.title == title then return entry end
    end
    return nil
end

function favorites.is_favorited(title)
    return favorites.find(title) ~= nil
end

--- 小标题（kind=heading）在文章内容块中的序号（1 起）；无匹配返回 nil。
-- 二级目录（nav/NCX 嵌套条目）与「收藏整篇/本小篇」都以此序号为准。
function favorites.section_index(item, title)
    if not item or not title then return nil end
    local index = 0
    for _, block in ipairs(item.blocks or {}) do
        if block.text and block.kind == "heading" then
            index = index + 1
            if block.text == title then return index end
        end
    end
    return nil
end

--- 按小节序号切出子文章：标题 = 小标题文本；blocks = 该小标题之后、下一个小标题之前。
-- 返回值可直接交给 favorites.add（link/source_name 继承整篇）。
function favorites.section_article(item, index)
    if not item or type(index) ~= "number" or index < 1 then return nil end
    local heading, sub = 0, nil
    for _, block in ipairs(item.blocks or {}) do
        if block.text and block.kind == "heading" then
            heading = heading + 1
            if heading == index then
                sub = {
                    title = block.text,
                    link = item.link,
                    source_name = item.source_name,
                    blocks = {},
                }
            elseif heading > index then
                break
            end
        elseif sub then
            sub.blocks[#sub.blocks + 1] = block
        end
    end
    return sub
end

--- 覆盖写入索引（dump 序列化的 Lua 表，可直接 loadfile 读回）
function favorites.save(list)
    if not ensure_dirs() then return nil, "无法创建收藏目录" end
    -- 原子写：先写 .part 再 rename，写一半崩溃不会损坏原索引
    local tmp_path = favorites.index_path .. ".part"
    local file, err = io.open(tmp_path, "wb")
    if not file then return nil, err end
    -- dump 产物是表达式，须前置 return 才是合法 Lua chunk（loadfile 要求语句）
    local ok, write_err = file:write("return ", dump(list))
    file:close()
    if not ok then
        os.remove(tmp_path)
        return nil, write_err
    end
    local renamed, rename_err = os.rename(tmp_path, favorites.index_path)
    if not renamed then
        os.remove(tmp_path)
        return nil, rename_err
    end
    return true
end

--- 写入某期 EPUB 的条目 sidecar（<epub_path>.items.lua）。
-- 只含元数据与内容块（图片二进制不在其中），供阅读器内「收藏当前文章」定位当前条目。
-- 精简：只序列化下游实际消费的字段（title/link/source_name/time/blocks）。
-- summary/summary_html 是抓取阶段的原始 HTML（最大字段），而 sidecar 每次
-- 菜单渲染都被 load_sidecar 重新解析，写入它们纯属拖慢渲染且无人读取。
function favorites.write_sidecar(epub_path, title, date, items)
    local slim = {}
    for i, item in ipairs(items or {}) do
        slim[i] = {
            title = item.title,
            link = item.link,
            source_name = item.source_name,
            time = item.time,
            blocks = item.blocks,
        }
    end
    local ok, err = pcall(function()
        local file, open_err = io.open(epub_path .. ".items.lua", "wb")
        if not file then error(open_err) end
        -- 同索引：dump 是表达式，前置 return 后 loadfile 才能执行
        file:write("return ", dump({ title = title, date = date, items = slim }))
        file:close()
    end)
    if not ok then
        logger.warn("technews sidecar write failed:", tostring(err))
        return nil, tostring(err)
    end
    return true
end

--- 读取 sidecar；不存在/损坏返回 nil
function favorites.load_sidecar(epub_path)
    if not epub_path or epub_path == "" then return nil end
    local chunk = loadfile(epub_path .. ".items.lua")
    if not chunk then return nil end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or type(data.items) ~= "table" then
        logger.warn("technews sidecar unreadable:", epub_path, tostring(data))
        return nil
    end
    return data
end

--- 尝试从本期 EPUB 就地提取文章图片（零网络请求）。
-- 定位链：sidecar 条目序号 N → OEBPS/text/article-NNN.xhtml → 章节内 <img> 出现顺序
-- 即内容块图片入册顺序。返回以内容块 URL 为键的 images 表；任何环节不成立
-- （无 sidecar / 条目定位失败 / ZIP 不可解析 / 章节图数与内容块图数不符 / 某张提取失败）
-- 都返回 nil，由调用方回退到网络下载。
local function extract_images_from_issue(article, issue_path)
    local meta = favorites.load_sidecar(issue_path)
    if not meta then return nil end
    -- 优先按原文链接定位（标题理论上唯一，但链接更稳），退化到精确标题
    local index
    for i, item in ipairs(meta.items) do
        if article.link and item.link == article.link then
            index = i
            break
        end
    end
    if not index then
        for i, item in ipairs(meta.items) do
            if item.title == article.title then
                index = i
                break
            end
        end
    end
    if not index then return nil end

    local reader = zipread.open(issue_path)
    if not reader then return nil end
    local ok, images = pcall(function()
        -- 章节文件名与 sidecar 序号一一对应（epub.lua 用 article-%03d.xhtml）
        local chapter = reader:extract(
            string.format("OEBPS/text/article-%03d.xhtml", index))
        if not chapter then return nil end
        -- epub.lua 渲染图片块时按块顺序写出 <div class="img"><img src="../images/…">
        local names = {}
        for name in chapter:gmatch('<img src="%.%./images/([^"]+)"') do
            names[#names + 1] = name
        end
        local urls = {}
        for _, block in ipairs(article.blocks or {}) do
            if block.img then urls[#urls + 1] = block.img end
        end
        -- 构建期会跳过没有数据的图片块（当次未下载/超出上限），数量不符说明
        -- 本章图片不完整，必须回退下载补齐（正文与其余图片最终仍齐全）
        if #names ~= #urls then return nil end
        local images = {}
        for i, url in ipairs(urls) do
            local data = reader:extract("OEBPS/images/" .. names[i])
            if not data then return nil end
            local ext = names[i]:match("%.([%a%d]+)$") or "jpg"
            images[url] = { data = data, ext = ext:lower() }
        end
        return images
    end)
    reader:close()
    if not ok or not images then
        if not ok then
            logger.warn("technews favorite local extract failed:", tostring(images))
        end
        return nil
    end
    return images
end

--- 收藏一篇文章：提取图片 → 生成自包含单篇快照 EPUB → 追加索引。
-- issue_path 为本期 EPUB 路径：给出时优先就地提取图片（零网络），不可行再回退下载。
-- progress_cb(text) 返回 false 可中止；中止/失败返回 nil, 原因。
function favorites.add(article, issue_path, progress_cb)
    if not article or not article.title then
        return nil, "缺少文章信息"
    end
    if not ensure_dirs() then
        return nil, "无法创建收藏目录"
    end

    -- 1) 图片：首选从本期 EPUB 就地提取（构建期已下载过的原图，零网络）；
    --    本地不可行时回退逐张下载
    local images
    if issue_path then
        if progress_cb and progress_cb("正在从本期提取图片…（点击可取消）") == false then
            return nil, "已取消"
        end
        images = extract_images_from_issue(article, issue_path)
    end
    if not images then
        -- 回退：按 URL 去重、上限 MAX_IMAGES；单张失败静默跳过，正文照常收藏
        local pending, seen = {}, {}
        for _, block in ipairs(article.blocks or {}) do
            if block.img and not seen[block.img] and #pending < MAX_IMAGES then
                seen[block.img] = true
                pending[#pending + 1] = block.img
            end
        end
        images = {}
        for i, url in ipairs(pending) do
            if progress_cb then
                local go_on = progress_cb(string.format("下载图片 %d/%d…（点击可取消）", i, #pending))
                if go_on == false then
                    return nil, "已取消"
                end
            end
            -- 与每日抓取同规则：CDN 缩放 800；HTTP 400（超高图）降级 480 重试
            local target = imgurl.rewrite(url, 800) or url
            local data, err = http.get(target, nil, nil, nil, { referer = imgurl.referer(target) })
            if not data and err and err:find("HTTP 400", 1, true) then
                local fallback = imgurl.rewrite(url, 480)
                if fallback then
                    data = http.get(fallback, nil, nil, nil, { referer = imgurl.referer(fallback) })
                end
            end
            if data and #data > 0 then
                images[url] = { data = data, ext = image_ext(url) }
            end
        end
    end

    -- 2) 生成快照 EPUB（文件名：时间戳-净化标题）
    local now = os.time()
    local filename = os.date("%Y%m%d-%H%M%S", now) .. "-"
        .. sanitize_title(article.title) .. ".epub"
    local path = unique_path(favorites.dir .. filename)
    local ok, build_err = pcall(epub.build, {
        title = article.title,
        date = os.date("%Y-%m-%d", now),
        items = { article },
        images = images,
        no_cover = true,    -- 收藏快照：无封面页
        no_overview = true, -- 无目录页（打开即正文）
    }, path)
    if not ok then
        os.remove(path .. ".part")
        return nil, tostring(build_err)
    end

    -- 3) 追加索引；索引写失败则回滚快照，避免留下孤儿文件
    local entry = {
        title = article.title,
        link = article.link,
        source_name = article.source_name,
        favorited_at = now,
        file = path,
    }
    local list = favorites.load()
    list[#list + 1] = entry
    local saved, save_err = favorites.save(list)
    if not saved then
        os.remove(path)
        return nil, save_err or "索引写入失败"
    end
    return entry
end

-- 两条索引是否指同一条收藏：优先按快照文件路径，退化到标题+时间
local function same_entry(a, b)
    if a.file and b.file then return a.file == b.file end
    return a.title == b.title and a.favorited_at == b.favorited_at
end

--- 移除一条收藏：默认尽力删除快照文件（不存在/删除失败无妨），再从索引剔除并保存。
-- keep_file 为真时只剔除索引条目、保留快照文件。
function favorites.remove(entry, keep_file)
    if not entry then return nil, "缺少条目" end
    if entry.file and not keep_file then os.remove(entry.file) end
    local kept = {}
    for _, e in ipairs(favorites.load()) do
        if not same_entry(e, entry) then kept[#kept + 1] = e end
    end
    return favorites.save(kept)
end

return favorites
