-- 科技资讯订阅 — 多源 RSS 订阅阅读器
--
-- 入口：
--   顶部菜单 → 科技资讯订阅
--   手势/快捷菜单：Dispatcher 动作「科技资讯订阅」
--
-- 数据流：RSS/网页 → 内容块（文字+图片）→ 生成整期 EPUB → KOReader 原生阅读器
--
-- 自测钩子：环境变量 TECHNEWS_SELFTEST=1 时，启动 3 秒后自动打开「合并·今日」

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local extract = require("technews.extract")
local epub = require("technews.epub")
local htmltext = require("technews.htmltext")
local http = require("technews.http")
local rss = require("technews.rss")
local storage = require("technews.storage")
local window = require("technews.window")

local SOURCES = {
    require("technews.sources.ithome"),
    require("technews.sources.cnbeta"),
}

-- 每期图片总量上限（控制抓取时间与 EPUB 体积）
local MAX_IMAGES_PER_ISSUE = 50

local TechNews = WidgetContainer:extend{
    name = "technews",
    is_doc_only = false,
    version = "0.1.0",
}

-- 自测只执行一次：插件用 dofile 加载，模块级变量会随 UI 重建被重置，
-- 必须用全局变量记录（同一进程内有效），否则会反复重开文档。
-- （环境变量 TECHNEWS_SELFTEST）

local function today_str()
    return os.date("%Y-%m-%d")
end

local function source_by_id(id)
    for _, source in ipairs(SOURCES) do
        if source.id == id then return source end
    end
end

-- 从 URL 推断图片扩展名
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

function TechNews:init()
    storage:init()
    storage:cleanup(7)   -- 保留最近 7 期
    self.ui.menu:registerToMainMenu(self)
    logger.info("technews initialized")

    if os.getenv("TECHNEWS_SELFTEST") == "1" and not G_technews_selftest_done then
        G_technews_selftest_done = true
        UIManager:scheduleIn(3.0, function()
            self:openMergedIssue()
        end)
    end
end

--- 是否在 EPUB 中包含图片
function TechNews:withImages()
    return G_reader_settings:readSetting("technews_with_images") ~= false
end

--- 缓存超过 6 小时后是否自动重新抓取
function TechNews:autoRefreshEnabled()
    return G_reader_settings:readSetting("technews_auto_refresh") == true
end

--- 缓存是否已过期（需重抓）
function TechNews:isCacheStale(source_id, date)
    if not self:autoRefreshEnabled() then return false end
    local mtime = storage:epub_mtime(source_id, date)
    if not mtime then return true end
    return (os.time() - mtime) > 6 * 3600
end

function TechNews:addToMainMenu(menu_items)
    menu_items.technews = {
        text = "科技资讯订阅",
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getMenuItems()
        end,
    }
end

function TechNews:getMenuItems()
    return {
        {
            text = "IT之家 · 今日新闻",
            keep_menu_open = false,
            callback = function() self:openIssue("ithome") end,
        },
        {
            text = "CNBeta · 今日资讯",
            keep_menu_open = false,
            callback = function() self:openIssue("cnbeta") end,
        },
        {
            text = "合并 · 今日科技资讯",
            keep_menu_open = false,
            callback = function() self:openMergedIssue() end,
        },
        {
            text = "包含图片",
            keep_menu_open = true,
            check_callback_updates_menu = true,
            checked_func = function() return self:withImages() end,
            callback = function()
                G_reader_settings:saveSetting("technews_with_images",
                    not self:withImages())
                -- 切换后当天缓存作废，下次打开重新生成
                storage:clear_date(today_str())
            end,
        },
        {
            text = "缓存 6 小时后自动更新",
            keep_menu_open = true,
            checked_func = function() return self:autoRefreshEnabled() end,
            callback = function()
                G_reader_settings:saveSetting("technews_auto_refresh",
                    not self:autoRefreshEnabled())
            end,
        },
        {
            text = "重新抓取今日",
            keep_menu_open = false,
            callback = function() self:confirmRefetch() end,
        },
        {
            text = "清理全部缓存",
            keep_menu_open = false,
            callback = function() self:confirmClearCache() end,
        },
        {
            text = "关于",
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = "科技资讯订阅 v0.1\n\n作者：Isword先生\n数据来源：IT之家 · CNBeta\n内容仅供个人阅读学习。",
                })
            end,
        },
    }
end

function TechNews:onDispatcherRegisterActions()
    Dispatcher:registerAction("technews_open", {
        category = "none",
        event = "ShowTechNews",
        title = "科技资讯订阅",
        general = true,
    })
end

function TechNews:onShowTechNews()
    self:openMergedIssue()
end

--- 抓取一个源。必须在 Trapper:wrap 协程内调用。
-- @return { items = {...}, images = { [url]= {data=, ext=} } } 或 (nil, 错误)
function TechNews:fetchSource(source, limit, progress)
    -- 合并模式下显示来源进度前缀（单源时为空串）
    local prefix = ""
    if progress and progress.source_count and progress.source_count > 1 then
        prefix = string.format("来源 %d/%d · ",
            progress.source_index, progress.source_count)
    end
    local xml, err = http.get(source.feed)
    if not xml then
        return nil, err
    end
    local items = rss.parse(xml)
    if #items == 0 then
        return nil, "没有解析到条目"
    end
    -- 今日窗口：0 点起 + 不足时向前回补
    local result, n_today = window.filter(
        items, limit or source.max_items, source.min_items)
    if #result == 0 then
        return nil, "没有可用的条目"
    end
    logger.info("technews window:",
        source.id,
        "today=" .. tostring(n_today),
        "selected=" .. tostring(#result),
        "feed=" .. tostring(#items))
    for _, item in ipairs(result) do
        item.source_id = source.id
        item.source_name = source.name
    end

    -- 1) 组装内容块（文字 + 图片，保持顺序）
    if source.mode == "fulltext" then
        for i, item in ipairs(result) do
            local msg = string.format("%s抓取 %s 全文 %d/%d…（点击可取消）",
                prefix, source.name, i, #result)
            if not Trapper:info(msg) then
                return nil, "已取消"
            end
            local html = http.get(item.link)
            if html then
                local blocks = extract.blocks(html, source.article_extract)
                if blocks then
                    item.blocks = blocks
                end
            end
            if not item.blocks then
                local blocks = htmltext.blocks(item.summary_html, nil)
                if #blocks > 0 then
                    item.blocks = blocks
                end
            end
            if not item.blocks then
                item.blocks = { { text = item.summary } }
            end
        end
    else
        for _, item in ipairs(result) do
            local blocks = htmltext.blocks(item.summary_html, nil)
            if #blocks == 0 then
                blocks = { { text = item.summary } }
            end
            item.blocks = blocks
        end
    end

    -- 2) 下载图片（可关闭；总量与单条数量都设上限）
    local images = {}
    if self:withImages() then
        local pending = {}
        local seen = {}
        for _, item in ipairs(result) do
            local per_item = source.max_images_per_item or 1
            local count = 0
            for _, block in ipairs(item.blocks) do
                if block.img and count < per_item then
                    if not seen[block.img] then
                        seen[block.img] = true
                        pending[#pending + 1] = { url = block.img }
                    end
                    count = count + 1
                end
            end
        end
        local total = math.min(#pending, MAX_IMAGES_PER_ISSUE)
        for i = 1, total do
            local url = pending[i].url
            local msg = string.format("%s下载图片 %d/%d…（点击可取消）",
                prefix, i, total)
            if not Trapper:info(msg) then
                break
            end
            local data = http.get(url)
            if data and #data > 0 then
                images[url] = { data = data, ext = image_ext(url) }
            end
        end
        logger.info("technews images:",
            source.id,
            "pending=" .. tostring(#pending),
            "downloaded=" .. tostring(total),
            "cap=" .. tostring(MAX_IMAGES_PER_ISSUE))
    end

    return { items = result, images = images }
end

--- 生成 EPUB 并打开
function TechNews:buildAndOpen(issue_id, title, date, items, images)
    local path = storage:epub_path(issue_id, date)
    logger.info("technews building issue:",
        issue_id, date, tostring(#items) .. " items", path)
    local ok, err = pcall(epub.build, {
        title = title,
        date = date,
        items = items,
        images = images or {},
    }, path)
    if not ok then
        logger.warn("technews epub build failed:", tostring(err))
        UIManager:scheduleIn(0.1, function()
            UIManager:show(InfoMessage:new{
                text = "生成 EPUB 失败\n" .. tostring(err),
            })
        end)
        return
    end
    UIManager:scheduleIn(0.1, function()
        self:openEpub(path)
    end)
end

function TechNews:openEpub(path)
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        self.ui:openFile(path)
    end
end

--- 统一的抓取失败提示（区分网络问题，并附带重试）
function TechNews:showFetchError(err, retry_cb)
    local msg
    local err_str = tostring(err or "未知错误")
    local connected = true
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr then
        connected = NetworkMgr:isConnected()
    end
    if not connected then
        msg = "网络未连接。\n请连接 Wi-Fi 后重试。"
    elseif err_str:find("连接失败") then
        msg = "服务器连接不稳定，请稍后重试。\n（" .. err_str .. "）"
    elseif err_str:find("HTTP") then
        msg = "服务器返回异常。\n（" .. err_str .. "）"
    elseif err_str:find("解析") then
        msg = "页面解析失败，可能网站结构已更新。\n（" .. err_str .. "）"
    else
        msg = "获取失败\n" .. err_str
    end
    UIManager:scheduleIn(0.1, function()
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = msg,
            ok_text = "重试",
            cancel_text = "关闭",
            ok_callback = retry_cb,
        })
    end)
end

--- 打开单个源的今日资讯（缓存优先）
function TechNews:openIssue(source_id)
    local source = source_by_id(source_id)
    if not source then return end
    local date = today_str()
    if storage:epub_exists(source.id, date)
        and not self:isCacheStale(source.id, date) then
        self:openEpub(storage:epub_path(source.id, date))
        return
    end
    Trapper:wrap(function()
        local bundle, err = self:fetchSource(source)
        if not bundle then
            self:showFetchError(err, function() self:openIssue(source_id) end)
            return
        end
        local title = string.format("%s · %s", source.name, date)
        self:buildAndOpen(source.id, title, date, bundle.items, bundle.images)
    end)
end

--- 打开两源合并的今日资讯
function TechNews:openMergedIssue()
    local date = today_str()
    if storage:epub_exists("merged", date)
        and not self:isCacheStale("merged", date) then
        self:openEpub(storage:epub_path("merged", date))
        return
    end
    Trapper:wrap(function()
        local all = {}
        local all_images = {}
        local failed = {}
        for i, source in ipairs(SOURCES) do
            local bundle, err = self:fetchSource(source, source.merge_max_items,
                { source_index = i, source_count = #SOURCES })
            if bundle then
                for _, item in ipairs(bundle.items) do
                    all[#all + 1] = item
                end
                for url, img in pairs(bundle.images) do
                    all_images[url] = img
                end
            else
                logger.warn("technews merge source failed:",
                    source.id, tostring(err))
                failed[#failed + 1] = source.name
            end
        end
        if #all == 0 then
            self:showFetchError(
                table.concat(failed, "、") .. " 均不可用",
                function() self:openMergedIssue() end)
            return
        end
        -- 按时间倒序排列（无时间的排最后）
        table.sort(all, function(a, b)
            return (a.ts or 0) > (b.ts or 0)
        end)
        local title = "今日科技资讯 · " .. date
        self:buildAndOpen("merged", title, date, all, all_images)
    end)
end

function TechNews:confirmRefetch()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = "清除今日缓存并重新抓取？（抓取全文与图片需要一些时间）",
        ok_text = "重新抓取",
        cancel_text = "取消",
        ok_callback = function()
            storage:clear_date(today_str())
            UIManager:show(InfoMessage:new{
                text = "今日缓存已清除，请重新打开资讯",
                timeout = 1,
            })
        end,
    })
end

function TechNews:confirmClearCache()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = "删除全部缓存的资讯 EPUB？",
        ok_text = "删除",
        cancel_text = "取消",
        ok_callback = function()
            storage:clear_all()
            UIManager:show(InfoMessage:new{
                text = "缓存已清空",
                timeout = 1,
            })
        end,
    })
end

return TechNews
