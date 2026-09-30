-- zhifou/favorites.lua — 收藏（单篇快照 EPUB）
--
-- 目录布局：
--   <koreader 数据目录>/zhifou/favorites.lua      索引（Lua 数组，按收藏时间倒序）
--   <koreader 数据目录>/zhifou/favorites/*.epub   单篇快照（自包含标题/正文/图片）
--
-- 快照独立于每日缓存：storage 的 cleanup/clear_date/clear_all 只清理
-- <source_id>-<date>.epub 及其 .sdr/.items.lua，不触碰 favorites/ 与索引，
-- 因此缓存过期或「清理全部缓存」后收藏仍可打开。
--
-- 索引条目：{ title, link, source_name, favorited_at = os.time(), file = 快照绝对路径 }

local dump = require("dump")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local epub = require("zhifou.epub")
local http = require("zhifou.http")
local images = require("zhifou.images")
local imgurl = require("zhifou.imgurl")
local storage = require("zhifou.storage")
local zipread = require("zhifou.zipread")

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
                logger.warn("zhifou favorites cannot create dir:", cur, tostring(err))
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

-- 图片扩展名不再从 URL 推断：CDN 会换格式（PNG 源返回 JPEG），
-- 一律以响应字节的魔数为准（zhifou/images.lua 的 ext_from_data）

-- 索引解析缓存：一次菜单渲染会多次调用 load()（首页/收藏菜单/定位都各来一次），
-- 每次都 loadfile + 执行 + 排序纯属浪费。按「路径 + mtime + 大小」判定新鲜度，
-- 写入路径（save / preserve_broken_index）显式失效——同一秒内改写时 mtime 不变，
-- 只靠 stat 会读到陈旧缓存。
local index_cache = { mtime = nil, size = nil, list = nil }

--- 让索引缓存失效（save 与损坏备份后调用）
function favorites.invalidate_index_cache()
    index_cache.mtime, index_cache.size, index_cache.list = nil, nil, nil
end

local function index_stat()
    local attr = lfs.attributes(favorites.index_path)
    if type(attr) ~= "table" then return nil, nil end
    return attr.modification, attr.size
end

--- 读取索引，按收藏时间倒序；文件缺失/损坏时返回空数组。
-- 损坏（文件在但解析失败）**不会**静默清空：先把原索引改名备份为
-- favorites.lua.broken-<时间戳>，再返回空表；否则下一次收藏/删除会以空表为基准
-- 全量覆盖写回，历史收藏就此从索引里永久消失（快照文件还在，界面再也看不到）。
-- 命中缓存时返回浅拷贝：调用方（菜单/排序）拿到独立数组，不会互相串改。
function favorites.load()
    local mtime, size = index_stat()
    -- 拿不到 mtime 与 size（异常文件系统/桩实现）时不缓存：宁可多解析一次，
    -- 也不能把陈旧索引当成最新（那会导致下一次 save 全量覆盖、收藏丢失）
    local cacheable = mtime ~= nil and size ~= nil
    if cacheable and index_cache.list
        and mtime == index_cache.mtime and size == index_cache.size then
        local copy = {}
        for i, entry in ipairs(index_cache.list) do copy[i] = entry end
        return copy
    end

    local list = {}
    local chunk, load_err = loadfile(favorites.index_path)
    if chunk then
        local ok, data = pcall(chunk)
        if ok and type(data) == "table" then
            local dropped = 0
            for _, entry in ipairs(data) do
                if type(entry) == "table" and entry.title then
                    list[#list + 1] = entry
                else
                    dropped = dropped + 1
                end
            end
            if dropped > 0 then
                logger.warn("zhifou favorites index dropped entries without title:", dropped)
            end
        else
            favorites.preserve_broken_index(tostring(data))
        end
    elseif lfs.attributes(favorites.index_path, "mode") == "file" then
        -- 文件在但 loadfile 失败（截断/语法损坏）与「文件不存在」必须区分开
        favorites.preserve_broken_index(tostring(load_err))
    end
    table.sort(list, function(a, b)
        return (tonumber(a.favorited_at) or 0) > (tonumber(b.favorited_at) or 0)
    end)
    if cacheable then
        index_cache.mtime, index_cache.size, index_cache.list = mtime, size, list
    else
        favorites.invalidate_index_cache()
    end
    local copy = {}
    for i, entry in ipairs(list) do copy[i] = entry end
    return copy
end

--- 备份损坏的索引文件，并记下给用户看的一次性提示。
-- @return 备份后的路径，失败返回 nil（此时 save 会拒绝写入，避免覆盖唯一的副本）
function favorites.preserve_broken_index(reason)
    if favorites._broken_handled then return favorites._broken_backup end
    favorites._broken_handled = true
    if lfs.attributes(favorites.index_path, "mode") ~= "file" then return nil end
    local backup = favorites.index_path .. ".broken-"
        .. os.date("%Y%m%d-%H%M%S")
    local renamed = os.rename(favorites.index_path, backup)
    favorites.invalidate_index_cache()
    if renamed then
        favorites._broken_backup = backup
        logger.warn("zhifou favorites index corrupt, backed up to:", backup, reason)
        favorites._notice = "收藏索引损坏，已备份为 " .. backup
            .. "\n快照文件仍在 favorites/ 目录，收藏列表已重新开始记录。"
    else
        -- 连备份都失败：拒绝后续写入，宁可这次收藏不落索引，也不覆盖唯一副本
        logger.warn("zhifou favorites index corrupt and backup failed:", reason)
        favorites._notice = "收藏索引损坏且无法备份，已暂停写入以免覆盖原索引（详见日志）。"
    end
    return favorites._broken_backup
end

--- 取出一次性提示（读过即清），供首页在打开时告知用户
function favorites.consume_notice()
    local notice = favorites._notice
    favorites._notice = nil
    return notice
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

--- 在条目表里按目录标题定位（快捷菜单/收藏用）。
-- 目录条目标题可能带「【来源】」前缀（epub.lua 的 toc_label），而 sidecar 里存的是
-- 纯标题；两种形式都参与比对（先原始、后去前缀，避免误伤本身以【开头的标题）。
-- 命中文内小标题（二级目录条目）时附带小节序号。
-- @return item[, section_index]；无匹配或无法消歧时返回 nil
function favorites.locate(items, title)
    if not title or title == "" then return nil end
    local list = items or {}
    local plain = title:gsub("^【.-】", "")
    -- 第一遍：整篇标题精确命中优先（否则「某篇的标题恰是另一篇的小标题」会被抢先）
    for _, item in ipairs(list) do
        if item.title == title or item.title == plain then
            return item
        end
    end
    -- 第二遍：小标题命中；若多篇共用同一小标题名则不猜（宁可隐藏收藏，
    -- 也不要把别的小节存成收藏）
    local found, found_index, matches
    for _, item in ipairs(list) do
        local index = favorites.section_index(item, title)
            or favorites.section_index(item, plain)
        if index then
            matches = (matches or 0) + 1
            if not found then
                found, found_index = item, index
            end
        end
    end
    if matches == 1 then
        return found, found_index
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
    -- 索引曾损坏且备份失败：拒绝写入，否则会把唯一可抢救的副本覆盖成新表
    -- （此判定必须先于建目录：数据安全优先于「把目录建好」）
    if favorites._broken_handled and not favorites._broken_backup then
        return nil, "收藏索引损坏且未能备份，已暂停写入以免覆盖原索引"
    end
    if not ensure_dirs() then return nil, "无法创建收藏目录" end
    -- 原子写：先写 .part 再 rename，写一半崩溃不会损坏原索引
    local tmp_path = favorites.index_path .. ".part"
    local file, err = io.open(tmp_path, "wb")
    if not file then return nil, err end
    -- dump 产物是表达式，须前置 return 才是合法 Lua chunk（loadfile 要求语句）
    local ok, write_err = file:write("return ", dump(list))
    -- 收尾同样要检查：stdio 有缓冲，磁盘满只在 flush/close 暴露，
    -- 否则截断的索引会被改名成正式索引，等于把历史收藏写没了
    local flushed, flush_err = file:flush()
    local closed, close_err = file:close()
    if not ok or not flushed or not closed then
        os.remove(tmp_path)
        return nil, write_err or flush_err or close_err
    end
    local renamed, rename_err = os.rename(tmp_path, favorites.index_path)
    if not renamed then
        os.remove(tmp_path)
        return nil, rename_err
    end
    favorites.invalidate_index_cache()
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
        local wrote, write_err = file:write("return ",
            dump({ title = title, date = date, items = slim }))
        if not wrote then
            file:close()
            error(write_err)
        end
        -- sidecar 截断会让「收藏当前文章」定位不到条目，同样要检查落盘
        local flushed, flush_err = file:flush()
        local closed, close_err = file:close()
        if not flushed or not closed then
            error(flush_err or close_err)
        end
    end)
    if not ok then
        logger.warn("zhifou sidecar write failed:", tostring(err))
        return nil, tostring(err)
    end
    favorites.invalidate_sidecar_cache(epub_path)
    return true
end

--- 读取 sidecar；不存在/损坏返回 nil
-- sidecar 解析缓存（同样按路径 + mtime + 大小判定；构建期写入后显式失效）。
-- 阅读器里打开「⋯」菜单、收藏定位都会读它，而 sidecar 含整期条目与内容块，
-- 每次重新 loadfile 一遍在低配设备上是可感知的卡顿。
local sidecar_cache = {}

function favorites.invalidate_sidecar_cache(epub_path)
    if epub_path then
        sidecar_cache[epub_path] = nil
    else
        sidecar_cache = {}
    end
end

function favorites.load_sidecar(epub_path)
    if not epub_path or epub_path == "" then return nil end
    local path = epub_path .. ".items.lua"
    local attr = lfs.attributes(path)
    local mtime = type(attr) == "table" and attr.modification or nil
    local size = type(attr) == "table" and attr.size or nil
    local cached = sidecar_cache[epub_path]
    -- 同索引：mtime 与 size 都拿得到才用缓存
    if cached and mtime and size and cached.mtime == mtime and cached.size == size then
        return cached.data
    end
    local chunk = loadfile(path)
    if not chunk then
        sidecar_cache[epub_path] = nil
        return nil
    end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or type(data.items) ~= "table" then
        logger.warn("zhifou sidecar unreadable:", epub_path, tostring(data))
        sidecar_cache[epub_path] = nil
        return nil
    end
    if mtime and size then
        sidecar_cache[epub_path] = { mtime = mtime, size = size, data = data }
    else
        sidecar_cache[epub_path] = nil
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
    local ok, image_map = pcall(function()
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
        local image_map = {}
        for i, url in ipairs(urls) do
            local data = reader:extract("OEBPS/images/" .. names[i])
            if not data then return nil end
            local ext = names[i]:match("%.([%a%d]+)$") or "jpg"
            image_map[url] = { data = data, ext = ext:lower() }
        end
        return image_map
    end)
    reader:close()
    if not ok or not image_map then
        if not ok then
            logger.warn("zhifou favorite local extract failed:", tostring(image_map))
        end
        return nil
    end
    return image_map
end

--- 收藏一篇文章：提取图片 → 生成自包含单篇快照 EPUB → 追加索引。
-- issue_path 为本期 EPUB 路径：给出时优先就地提取图片（零网络），不可行再回退下载。
-- progress_cb(text) 返回 false 可中止；中止/失败返回 nil, 原因。
--- 收藏一篇文章为单篇快照 EPUB。
-- @param progress_cb 可选：进度回调，返回 false 表示用户取消
-- @param with_gray 可选：图片转灰度（与设置里的开关一致；仅下载回退路径用得上）
-- @param widths 可选：候选宽度表（images.widths_for；与设置里的图片分辨率一致）
function favorites.add(article, issue_path, progress_cb, with_gray, widths)
    if not article or not article.title then
        return nil, "缺少文章信息"
    end
    if not ensure_dirs() then
        return nil, "无法创建收藏目录"
    end

    -- 1) 图片：首选从本期 EPUB 就地提取（构建期已下载过的原图，零网络）；
    --    本地不可行时回退逐张下载
    local image_map
    if issue_path then
        if progress_cb and progress_cb("正在从本期提取图片…（点击可取消）") == false then
            return nil, "已取消"
        end
        image_map = extract_images_from_issue(article, issue_path)
    end
    if not image_map then
        -- 回退：按 URL 去重、上限 MAX_IMAGES；单张失败静默跳过，正文照常收藏
        local pending, seen = {}, {}
        for _, block in ipairs(article.blocks or {}) do
            if block.img and not seen[block.img] and #pending < MAX_IMAGES then
                seen[block.img] = true
                pending[#pending + 1] = block.img
            end
        end
        image_map = {}
        -- 与每日抓取同一套闸门：单张上限 + 本篇总额度（下载回退路径才有网络开销）
        -- 额度随分辨率设置放大（与每日抓取同一套规则）
        local budget = images.new_budget({
            width = widths and widths[1] or nil,
        })
        for i, url in ipairs(pending) do
            if progress_cb then
                local go_on = progress_cb(string.format("下载图片 %d/%d…（点击可取消）", i, #pending))
                if go_on == false then
                    return nil, "已取消"
                end
            end
            -- 与每日抓取同规则：CDN 缩放/转 JPEG/灰度 → 魔数判型 → 体积额度
            local image, img_err = images.fetch(url, {
                download = function(target)
                    return http.get(target, nil, nil, nil, {
                        referer = imgurl.referer(target),
                        max_bytes = images.MAX_DOWNLOAD_BYTES,
                    })
                end,
                rewrite = imgurl.rewrite,
                budget = budget,
                gray = with_gray,
                widths = widths,
            })
            if image then
                image_map[url] = image
            elseif img_err == "over_budget" then
                -- 整篇额度已满：再下也是丢（每张最多 3MB），直接停
                logger.info("zhifou favorites image budget exhausted:", url)
                break
            else
                logger.info("zhifou favorites image skipped:", url)
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
        -- 每篇快照各自唯一：同一天收藏多篇时 identifier 不能相同
        identifier = "zhifou-fav-" .. os.date("%Y%m%d-%H%M%S", now),
        items = { article },
        images = image_map,
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
