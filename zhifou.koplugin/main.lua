-- 知否 — 多源 RSS 订阅阅读器（包名仍为 zhifou.koplugin）
--
-- 入口：
--   顶部菜单 → 知否 → 全屏首页（打开今日 / 分源阅读 / 设置）
--   手势/快捷菜单：Dispatcher 动作「知否」（直接打开合并今日）
--
-- 数据流：RSS/网页 → 内容块（文字+图片）→ 生成整期 EPUB → KOReader 原生阅读器
--
-- 自测钩子：环境变量 ZHIFOU_SELFTEST=1 时，启动 3 秒后自动打开「合并·今日」

-- 一次性守卫：插件经 dofile 重载会重置模块级变量，必须用全局记录
-- luacheck: globals G_zhifou_sources_prompted G_zhifou_end_patch G_zhifou_toc_patch G_zhifou_log_ring

local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local diag = require("zhifou.diag")

local TextWidget = require("ui/widget/textwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

-- 最近错误环形记录：设备上没法看日志（无 adb/文件传输）时，
-- 直接用「设置 → 最近错误（诊断）」把插件记录的失败原因显示在屏幕上。
-- 只挂一次（插件会被 dofile 重载，模块级变量会重置，故用全局表）。
local LOG_RING_SIZE = 40

local function install_log_ring()
    if G_zhifou_log_ring then return G_zhifou_log_ring end
    local ring = { entries = {}, hooked = true }
    G_zhifou_log_ring = ring
    local originals = { warn = logger.warn, err = logger.err }
    local function record(prefix, ...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring((select(i, ...)))
        end
        local text = table.concat(parts, " ")
        if text:find("zhifou", 1, true) then
            ring.entries[#ring.entries + 1] = string.format("[%s] %s %s",
                os.date("%H:%M:%S"), prefix, text)
            while #ring.entries > LOG_RING_SIZE do table.remove(ring.entries, 1) end
        end
    end
    for name, prefix in pairs({ warn = "WARN", err = "ERR" }) do
        local original = originals[name]
        if type(original) == "function" then
            logger[name] = function(...)
                pcall(record, prefix, ...)   -- 记录失败绝不能影响日志本身
                return original(...)
            end
        end
    end
    return ring
end

local dedupe = require("zhifou.dedupe")
local extract = require("zhifou.extract")
local epub = require("zhifou.epub")
local favorites = require("zhifou.favorites")
local htmltext = require("zhifou.htmltext")
local http = require("zhifou.http")
local images = require("zhifou.images")
local imgurl = require("zhifou.imgurl")
local rss = require("zhifou.rss")
local storage = require("zhifou.storage")
local subscriptions = require("zhifou.subscriptions")
local updater = require("zhifou.updater")
local window = require("zhifou.window")

-- 全部可用订阅源（有序）；新增源只需在 sources/registry.lua 追加一行
local registry = require("zhifou.sources.registry")

-- 每期图片张数上限（安全阀：控制抓取时间；字节上限在 zhifou/images.lua）
local MAX_IMAGES_PER_ISSUE = 150
-- 整期抓取时间预算（秒）：正常一期约 1 分钟，这里留足余量，
-- 只用来兜住「某个源被墙/服务器装死」把整期拖到十几分钟的情况
local FETCH_BUDGET_SECONDS = 300

local TechNews = WidgetContainer:extend{
    name = "zhifou",
    is_doc_only = false,
    version = "0.1.22",
}

-- 自测只执行一次：插件用 dofile 加载，模块级变量会随 UI 重建被重置，
-- 必须用全局变量记录（同一进程内有效），否则会反复重开文档。
-- （环境变量 ZHIFOU_SELFTEST）

local function today_str()
    return os.date("%Y-%m-%d")
end

local function source_by_id(id)
    for _, source in ipairs(registry) do
        if source.id == id then return source end
    end
end

-- 相对今天偏移若干天的日期串（0=今天，1=昨天）
local function date_str_of(offset_days)
    return os.date("%Y-%m-%d", os.time() - (offset_days or 0) * 86400)
end

--- 分源阅读的时间范围描述（kind = today / yesterday / week / date）。
-- 返回 range = { date=缓存日期, suffix=缓存 id 后缀, start_ts/end_ts=半开区间,
-- include_no_ts=无时间戳条目是否命中, title=期标题后缀, empty=空结果提示 }；
-- 非法或未来日期返回 nil, 原因。
local function issue_range(kind, date)
    if kind == "today" then
        return {
            date = date_str_of(0), suffix = "",
            start_ts = window.day_start_ts(0), end_ts = math.huge,
            include_no_ts = true, title = date_str_of(0),
            empty = "今日暂无新条目",
        }
    elseif kind == "yesterday" then
        return {
            date = date_str_of(1), suffix = "",
            start_ts = window.day_start_ts(1), end_ts = window.day_start_ts(0),
            include_no_ts = false,
            title = "昨日（" .. os.date("%m月%d日", os.time() - 86400) .. "）",
            empty = "昨日没有抓到条目（RSS 源只提供最近几天的内容）",
        }
    elseif kind == "week" then
        return {
            date = date_str_of(0), suffix = "-week",
            start_ts = window.day_start_ts(6), end_ts = math.huge,
            include_no_ts = true, title = "近一周",
            empty = "近一周没有可用条目",
        }
    elseif kind == "date" and type(date) == "string" then
        local y, m, d = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
        if not y then return nil, "无效的日期" end
        local start_ts = os.time{ year = y, month = m, day = d, hour = 0 }
        if not start_ts then return nil, "无效的日期" end
        if start_ts >= window.day_start_ts(0) + 86400 then
            return nil, "这个日期还没到"
        end
        return {
            date = date, suffix = "",
            start_ts = start_ts, end_ts = start_ts + 86400, include_no_ts = false,
            title = string.format("%d月%d日", tonumber(m), tonumber(d)),
            empty = "这一天没有抓到条目（RSS 源只提供最近几天的内容）",
        }
    end
end

-- 字节数 → 人类可读（缓存列表用；与 weread 的展示习惯一致）
local function human_size(bytes)
    if bytes < 1024 * 1024 then
        return string.format("%.0f KB", bytes / 1024)
    end
    return string.format("%.1f MB", bytes / 1024 / 1024)
end

-- 缓存期条目的显示名（往期缓存 / 缓存清理共用）：「源名 · 9月27日」（近一周加后缀）
local function issue_label(entry)
    local base_id = entry.id:gsub("%-week$", "")
    local label
    if base_id == "merged" then
        label = "合并期"
    else
        local src = source_by_id(base_id)
        label = (src and src.name) or base_id
    end
    if entry.id:sub(-5) == "-week" then
        label = label .. " · 近一周"
    end
    local _, m, d = entry.date:match("(%d+)-(%d+)-(%d+)")
    return string.format("%s · %s月%s日", label, tonumber(m), tonumber(d))
end

-- 图片扩展名不再从 URL 推断：CDN 会换格式（PNG 源返回 JPEG），
-- 一律以响应字节的魔数为准，见 zhifou/images.lua 的 ext_from_data

-- 下载图片：按图床决定是否附带 Referer
-- （少数派 cdnfile.sspai.com 不带 Referer 会 403；其余图床不带，见 imgurl.referer）
local function download_image(url)
    -- 图片是可有可无的：重试 1 次、超时 10/25 秒（比 LARGE 的 3 次重试/30 秒更早止损），
    -- 否则一个不可达的图床会让「单张」耗掉几分钟
    return http.get(url,
        images.DOWNLOAD_TIMEOUTS.block, images.DOWNLOAD_TIMEOUTS.total,
        images.DOWNLOAD_RETRIES, {
            referer = imgurl.referer(url),
            max_bytes = images.MAX_DOWNLOAD_BYTES,
        })
end

function TechNews:init()
    -- 过渡：旧设置键 technews_* → zhifou_*（首次运行搬一次；旧键保留，便于回滚旧版）
    do
        local legacy_sources = G_reader_settings:readSetting("technews_sources")
        if legacy_sources ~= nil and G_reader_settings:readSetting("zhifou_sources") == nil then
            G_reader_settings:saveSetting("zhifou_sources", legacy_sources)
        end
        local legacy_images = G_reader_settings:readSetting("technews_with_images")
        if legacy_images ~= nil and G_reader_settings:readSetting("zhifou_with_images") == nil then
            G_reader_settings:saveSetting("zhifou_with_images", legacy_images)
        end
    end
    storage:init()
    -- 保留最近 7 期；正在阅读的那一期必须豁免
    -- （KOReader 先打开上次的文档、后构造插件 → 过期的那期会连 .sdr 进度一起被删）
    local opened = self.ui and self.ui.document and self.ui.document.file
    local protect = opened and { [opened] = true } or nil
    storage:cleanup(7, protect)
    -- 上次在线更新若留下回滚副本，能走到这里说明新版本可用，清掉备份
    pcall(updater.cleanup_backup)
    self.ui.menu:registerToMainMenu(self)
    logger.info("zhifou initialized")

    -- 文档结束弹窗：本插件文档统一改用快捷菜单（其它文档保持 KOReader 原行为）。
    -- 插件经 dofile 重载，用全局标记保证补丁只安装一次。
    if not G_zhifou_end_patch then
        G_zhifou_end_patch = true
        local ConfirmBox = require("ui/widget/confirmbox")
        local ReaderStatus = require("apps/reader/modules/readerstatus")
        local orig_onEndOfBook = ReaderStatus.onEndOfBook
        ReaderStatus.onEndOfBook = function(rs, ...)
            local plugin = rs.ui and rs.ui.zhifou
            if plugin and plugin:isTechNewsDocument() then
                if G_reader_settings:isTrue("end_document_auto_mark") then
                    rs:markBook(true)
                end
                local top_widget = UIManager:getTopmostVisibleWidget() or {}
                if top_widget.name ~= "zhifou_end_prompt" then
                    UIManager:show(ConfirmBox:new{
                        name = "zhifou_end_prompt",
                        text = "已经是最后一页了\n是否需要返回？",
                        ok_text = "返回",
                        cancel_text = "忽略",
                        ok_callback = function()
                            plugin:closeDocumentAndReturn()
                        end,
                    })
                end
                return true
            end
            return orig_onEndOfBook(rs, ...)
        end
    end

    -- 目录菜单去掉键盘快捷键字母列（与首页一致；模拟器有键盘才会显示）。
    -- 构建期间临时改类默认（首次 updateItems 发生在构建内），构建后钉在实例上。
    if not G_zhifou_toc_patch then
        G_zhifou_toc_patch = true
        local ReaderToc = require("apps/reader/modules/readertoc")
        local Menu = require("ui/widget/menu")
        local orig_onShowToc = ReaderToc.onShowToc
        ReaderToc.onShowToc = function(toc, ...)
            local plugin = toc.ui and toc.ui.zhifou
            if not (plugin and plugin:isTechNewsDocument()) then
                return orig_onShowToc(toc, ...)
            end
            local saved = Menu.is_enable_shortcut
            Menu.is_enable_shortcut = false
            local ret = orig_onShowToc(toc, ...)
            Menu.is_enable_shortcut = saved
            if toc.toc_menu then
                toc.toc_menu.is_enable_shortcut = false
            end
            return ret
        end
    end

    install_log_ring()

    if os.getenv("ZHIFOU_SELFTEST") == "1" and not G_zhifou_selftest_done then
        G_zhifou_selftest_done = true
        UIManager:scheduleIn(3.0, function()
            self:openMergedIssue()
        end)
    end
end

--- 是否在 EPUB 中包含图片
function TechNews:withImages()
    return G_reader_settings:readSetting("zhifou_with_images") ~= false
end

--- 图片是否转灰度（默认开：墨水屏上彩色没有意义，灰度 JPEG 更小；
-- 支持的图床见 imgurl 的 gray_recipe，不支持的自动作罢）
--- 图片分辨率设置：读回用户选的宽度；返回 nil 表示「自动（按屏幕宽度）」
function TechNews:imageWidthSetting()
    local value = G_reader_settings:readSetting("zhifou_image_width")
    if value == nil or value == "auto" then return nil end
    return tonumber(value)
end

--- 「自动」档：按设备屏幕宽度取（不同设备屏宽不同，这是默认行为）
function TechNews:autoImageWidth()
    local ok, width = pcall(function()
        return require("device").screen:getWidth()
    end)
    if ok and type(width) == "number" and width > 0 then return width end
    return images.DEFAULT_WIDTH
end

--- 当前生效的图片目标宽度（设置 → 图片分辨率）
function TechNews:imageTargetWidth()
    return self:imageWidthSetting() or self:autoImageWidth()
end

--- 当前生效的候选宽度表（目标宽 → 降档宽）
function TechNews:imageWidths()
    return images.widths_for(self:imageTargetWidth())
end

--- 保存图片分辨率；改完当天缓存作废（与图片开关同样的语义）
-- @param value 数字（像素宽）或 nil（自动）
function TechNews:setImageWidth(value)
    if value == nil then
        G_reader_settings:delSetting("zhifou_image_width")
    else
        G_reader_settings:saveSetting("zhifou_image_width", tonumber(value))
    end
    storage:clear_date(today_str())
end

function TechNews:withGrayImages()
    return G_reader_settings:readSetting("zhifou_gray_images") ~= false
end

--- 订阅源设置（nil = 用户尚未选择，按各源 default_enabled 默认启用）
function TechNews:sourceSetting()
    return G_reader_settings:readSetting("zhifou_sources")
end

--- 保存订阅源设置；启用集合变化后当天缓存作废，下次打开重建
function TechNews:setSourceSetting(set)
    G_reader_settings:saveSetting("zhifou_sources", set)
    storage:clear_date(today_str())
end

--- 当前文档是否由本插件生成（路径判定：数据目录下的 zhifou/，覆盖缓存期与收藏快照；
-- 兼容旧数据目录 technews/——迁移若失败也不至于把自家文档判成外部书）
function TechNews:isTechNewsDocument()
    local doc_file = self.ui and self.ui.document and self.ui.document.file
    if not doc_file then return false end
    return doc_file:find("/zhifou/", 1, true) ~= nil
        or doc_file:find("/technews/", 1, true) ~= nil
end

function TechNews:addToMainMenu(menu_items)
    menu_items.zhifou = {
        text = "知否",
        sorting_hint = "tools",
        -- 主菜单只保留一个入口：直接打开全屏首页（不再展开下拉子菜单）
        callback = function()
            self:openHome()
        end,
    }
end

--- 打开「知否」全屏首页（用 Menu 部件铺满全屏；条目见 getHomeItems）
function TechNews:openHome()
    -- 首次使用：不再弹多选（26 个源弹一大串体验差），改为提示去设置里选择（每会话一次）
    if self:sourceSetting() == nil and not G_zhifou_sources_prompted then
        G_zhifou_sources_prompted = true
        UIManager:scheduleIn(0.2, function()
            UIManager:show(InfoMessage:new{
                text = "首次使用：请到「设置 → 订阅源设置」中选择要订阅的源。\n\n"
                    .. "默认启用：IT之家、雷锋网、知乎日报、「一个」。",
                timeout = 6,
            })
        end)
    end

    -- 收藏索引曾损坏：一次性告知（快照没丢，但用户必须知道列表为什么空了）
    local index_notice = favorites.consume_notice()
    if index_notice then
        UIManager:scheduleIn(0.2, function()
            UIManager:show(InfoMessage:new{
                text = index_notice,
                timeout = 10,
            })
        end)
    end

    -- 首页已打开时不叠加：旧菜单的 close_callback 会把新引用置 nil
    if self._home_menu then return end

    -- 全屏页用 Menu 部件（文件列表/目录同款；TouchMenu 是系统菜单那种「顶部部分高度面板」）
    local Menu = require("ui/widget/menu")
    local home_menu = Menu:new{
        title = "知否",
        item_table = self:getHomeItems(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        -- 不显示键盘快捷键字母列（模拟器有键盘会显示 Q/W/E…，真机无键盘不显示）
        is_enable_shortcut = false,
    }
    -- Menu 不识别 TouchMenu 的 keep_menu_open / sub_item_table_func，在此适配：
    -- 1) sub_item_table_func 点击时解析，保持「展开时按当前启用集合生成」语义
    -- 2) keep_menu_open 条目（开关/勾选类）执行后原地刷新，不关闭首页
    -- 3) 其余条目沿用 Menu 默认：先 callback、后 close_callback 关闭首页
    home_menu.onMenuSelect = function(menu_self, item)
        if item.sub_item_table_func then
            item.sub_item_table = item.sub_item_table_func()
        end
        if item.keep_menu_open and item.sub_item_table == nil then
            if item.callback then item.callback() end
            -- 抓取类条目可能在回调里已打开阅读器（ShowingReader 已收起首页），此时不再刷新
            if not menu_self._closed_by_reader then
                menu_self:updateItems()
            end
            return true
        end
        return Menu.onMenuSelect(menu_self, item)
    end
    home_menu.close_callback = function()
        self._home_menu = nil
        UIManager:close(home_menu)
    end
    -- 打开阅读器时收起首页：否则首页残留在窗口栈里，之后「关闭并返回」重建
    -- 首页会被 _home_menu 守卫挡掉，首页就再也打不开（实测隐患）
    home_menu.onShowingReader = function(menu_self)
        menu_self.dithered = nil
        menu_self._closed_by_reader = true
        if menu_self.close_callback then
            menu_self.close_callback()
        end
    end
    self._home_menu = home_menu
    UIManager:show(home_menu)
end

--- 首页条目表（Menu 全屏页的 item_table）
-- 关闭时机（已核对 menu.lua 的 Menu:onMenuSelect）：普通 callback 条目是「先执行
-- callback、返回后才 close_callback 关闭首页」；抓取经 Trapper:wrap 在首个进度 yield
-- 时立即返回、随即关闭首页，故无需手动先关菜单，进度框与 ConfirmBox 均显示在首页之上。
function TechNews:getHomeItems()
    return {
        {
            text = "今日一期",
            -- keep_menu_open：抓取期间进度显示在首页之上，失败也能留在首页重试；
            -- 打开阅读器时由首页的 onShowingReader 正常收起（见 openHome）
            -- 已有今日一期时先弹「打开 / 重新抓取」询问（prompt_if_cached）
            keep_menu_open = true,
            callback = function() self:openMergedIssue(true) end,
        },
        {
            text = "抓取往期",
            keep_menu_open = true, -- 抓取期间保持首页（与「今日一期」一致）
            callback = function() self:askMergedIssueRange() end,
        },
        {
            text = "分源阅读",
            sub_item_table_func = function()
                return self:getSourceReadItems()
            end,
        },
        {
            text = "我的收藏",
            sub_item_table_func = function()
                return self:getFavoriteItems()
            end,
        },
        {
            text = "往期缓存",
            sub_item_table_func = function()
                return self:getHistoryItems()
            end,
        },
        {
            text = "设置",
            sub_item_table_func = function()
                return self:getSettingItems()
            end,
        },
        {
            text = "关于",
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = "知否 v" .. self.version
                        .. "\n\n作者：Isword先生（开源许可：AGPL-3.0）"
                        .. "\n数据来源：IT之家、36氪 等 32 个订阅源"
                        .. "\n内容版权归原作者与各站点所有，仅供个人阅读学习。",
                })
            end,
        },
    }
end

--- 「分源阅读」子菜单：只列已订阅的源（与「订阅源设置」一致，不再带 ☑/☐）；
-- 点开某个源后询问要读哪段时间（今日 / 昨日 / 近一周 / 自定义日期）
function TechNews:getSourceReadItems()
    local items = {}
    for _, source in ipairs(subscriptions.enabled(registry, self:sourceSetting())) do
        items[#items + 1] = {
            text = source.menu_label or source.name,
            keep_menu_open = true, -- 抓取期间保持首页（同「今日一期」）
            callback = function()
                self:askIssueRange(source)
            end,
        }
    end
    if #items == 0 then
        items[1] = { text = "尚未订阅任何源（去「设置 → 订阅源设置」选择）", select_enabled = false }
    end
    return items
end

--- 时间范围询问框（分源阅读与合并期共用；on_pick(kind[, date]) 收到选择）。
-- opts.include_today = true 时显示「今日」（分源阅读）；「抓取往期」入口不显示
-- ——今日已由「今日一期」承担。
function TechNews:showRangeDialog(title_text, on_pick, opts)
    opts = opts or {}
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function pick(kind)
        return function()
            UIManager:close(dialog)
            on_pick(kind)
        end
    end
    local function custom_date()
        return function()
            UIManager:close(dialog)
            self:pickRangeDate(on_pick)
        end
    end
    local buttons = {}
    if opts.include_today then
        buttons[#buttons + 1] = {
            { text = "今日", callback = pick("today") },
            { text = "昨日", callback = pick("yesterday") },
        }
        buttons[#buttons + 1] = {
            { text = "近一周", callback = pick("week") },
            { text = "自定义日期…", callback = custom_date() },
        }
    else
        buttons[#buttons + 1] = {
            { text = "昨日", callback = pick("yesterday") },
            { text = "近一周", callback = pick("week") },
        }
        buttons[#buttons + 1] = {
            { text = "自定义日期…", callback = custom_date() },
        }
    end
    buttons[#buttons + 1] = {
        { text = "取消", callback = function() UIManager:close(dialog) end },
    }
    dialog = ButtonDialog:new{
        title = title_text,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- 自定义日期选择（DateTimeWidget；显式 year_min，默认 2021 会挡住更早的日期）
function TechNews:pickRangeDate(on_pick)
    local DateTimeWidget = require("ui/widget/datetimewidget")
    local today = os.date("*t")
    UIManager:show(DateTimeWidget:new{
        year = today.year, month = today.month, day = today.day,
        year_min = 2015,
        ok_text = "确定", cancel_text = "取消",
        title_text = "读哪一天的文章？",
        callback = function(time)
            on_pick("date",
                string.format("%04d-%02d-%02d", time.year, time.month, time.day))
        end,
    })
end

--- 分源阅读：询问要抓取的时间范围（含「今日」）
function TechNews:askIssueRange(source)
    self:showRangeDialog(source.name, function(kind, date)
        self:openIssueRange(source, kind, date)
    end, { include_today = true })
end

--- 合并期：询问时间范围（「抓取往期」入口；不含「今日」）
function TechNews:askMergedIssueRange()
    self:showRangeDialog("合并期刊", function(kind, date)
        self:openMergedIssueRange(kind, date)
    end)
end

--- 「订阅源设置」子菜单：每个登记源一个勾选项（勾选即生效并清今日缓存）
--- 复选/单选条目点击后原地刷新。
-- KOReader 只在条目带 checked/checked_func 时才会自动 updateItems（touchmenu.lua
-- 的 onMenuSelect），而插件用 ☑/☐ 写进 text_func，所以要在回调里自己刷新，
-- 否则点了之后标记不变、要退出菜单再进才更新。回调的第一个参数就是菜单本体。
local function refresh_menu(menu)
    if menu and menu.updateItems then menu:updateItems() end
end

function TechNews:getSourceSettingItems()
    local items = {}
    for _, source in ipairs(registry) do
        items[#items + 1] = {
            text_func = function()
                local mark = subscriptions.is_enabled(source, self:sourceSetting())
                    and "☑ " or "☐ "
                return mark .. source.name
            end,
            keep_menu_open = true,
            callback = function(menu)
                -- 以当前启用集合为基准翻转本项，另存为新集合
                local ids = {}
                for _, adapter in ipairs(subscriptions.enabled(registry, self:sourceSetting())) do
                    ids[#ids + 1] = adapter.id
                end
                local set = subscriptions.to_set(ids)
                if set[source.id] then
                    set[source.id] = nil
                else
                    set[source.id] = true
                end
                self:setSourceSetting(set)
                refresh_menu(menu)
            end,
        }
    end
    return items
end

--- 源连通性自检：逐个源发一个小请求（截断到 64KB，只判「通不通」），
-- 结果一次性列出——省去「改设置 → 抓一次 → 看哪个源失败」的来回试。
-- 注意只看 feed 可达性，不解析、不抓正文、不生成期文件。
function TechNews:checkSourceConnectivity()
    local sources = subscriptions.enabled(registry, self:sourceSetting())
    if #sources == 0 then
        UIManager:show(InfoMessage:new{ text = "尚未订阅任何源（去「订阅源设置」勾选）" })
        return
    end
    Trapper:wrap(function()
        local ProgressbarDialog = require("ui/widget/progressbardialog")
        local socket = require("socket")
        local now = socket.gettime or os.time
        local started_all = now()
        local lines, slowest = {}, nil
        local reachable, probed = 0, 0

        -- 与「设置 → 检查更新」同款的进度条对话框：真实进度条 + 点击即取消
        -- （ProgressbarDialog 的 redrawProgressbar 内部会 forceRePaint，
        --   所以在同步的网络探测循环里也能立即刷新，不用让出协程）
        local cancelled = false
        local dialog = ProgressbarDialog:new{
            title = string.format("正在自检订阅源…（共 %d 个）", #sources),
            progress_max = #sources,
            -- main.lua 顶部已 require 过 Device，直接用（墨水屏刷新慢，降频）
            refresh_time_seconds = Device:hasEinkScreen() and 0.5 or 0.1,
        }
        dialog.dismiss_callback = function() cancelled = true end
        dialog:show()
        UIManager:forceRePaint()

        for i, source in ipairs(sources) do
            if cancelled then break end
            dialog:reportProgress(i - 1) -- 已完成的个数
            if not source.feed then
                lines[#lines + 1] = string.format("· %s：自定义源，跳过（%s）",
                    source.name, source.mode or "?")
            else
                probed = probed + 1
                local started = now()
                local ok, body, err = pcall(http.get, source.feed, 10, 20, 0, {
                    max_bytes = 64 * 1024, allow_truncated = true,
                })
                if not ok then
                    body, err = nil, "探测异常：" .. tostring(body)
                end
                local elapsed = now() - started
                if body then
                    reachable = reachable + 1
                    lines[#lines + 1] = string.format("✓ %s：%.1f 秒", source.name, elapsed)
                    if not slowest or elapsed > slowest.elapsed then
                        slowest = { name = source.name, elapsed = elapsed }
                    end
                else
                    lines[#lines + 1] = string.format("✗ %s：%s", source.name, tostring(err))
                end
            end
        end

        dialog.dismiss_callback = nil -- 收尾关闭不再当作取消
        if cancelled then
            dialog:close()
            UIManager:show(InfoMessage:new{ text = "已取消自检", timeout = 2 })
            return
        end
        dialog:reportProgress(#sources)
        dialog:close()

        local head = string.format("可达 %d/%d", reachable, probed)
        if probed < #sources then
            head = head .. string.format("（另 %d 个自定义源未探测）", #sources - probed)
        end
        if slowest then
            head = head .. string.format("；最慢 %s（%.1f 秒）", slowest.name, slowest.elapsed)
        end
        head = head .. string.format("；共耗时 %d 秒", math.floor(now() - started_all))
        local msg = head .. "\n\n" .. table.concat(lines, "\n")
            .. "\n\n（仅探测订阅源入口是否可达，不代表正文抽取正常）"
        logger.info("zhifou connectivity:", head)
        UIManager:show(TextViewer:new{
            title = "源连通性自检",
            text = msg,
        })
    end)
end

--- 生成诊断报告文本（纯探测，不碰 UI）。
-- 注意：这段代码可能运行在**子进程**里，因此：
--   * 绝不调用 Trapper:info —— 它会 coroutine.yield()，而子进程没有调度器来恢复协程，
--     任务会卡在那里、父进程只能拿到空结果（KOReader 自己的子进程任务也只返回字符串）
--   * 全程 pcall，保证任何异常都以文本形式回到父进程，而不是静默丢失
local function build_diag_report(targets, on_progress)
    local lines = {
        "分阶段探测（每步的耗时与错误原文）：",
        "若长时间停在 DNS 一步，点取消即可——那说明解析卡住，本身就是结论。",
        "",
    }
    for _, target in ipairs(targets) do
        if on_progress then on_progress(target) end
        lines[#lines + 1] = string.format("【%s】%s", target.name, target.url)
        local ok, result = pcall(diag.probe, target.url, { timeout = 5 })
        if ok then
            lines[#lines + 1] = diag.render(result)
        else
            lines[#lines + 1] = "探测异常：" .. tostring(result)
        end
        lines[#lines + 1] = ""
    end
    local http_mod = require("zhifou.http")
    lines[#lines + 1] = string.format("本机 gzip 开关：%s（true = 允许声明压缩）",
        tostring(http_mod.gzip_usable()))
    return table.concat(lines, "\n")
end

--- 网络诊断：优先在**子进程**里跑（卡在 DNS 时界面仍可点、取消即杀掉），
-- 若该平台子进程拿不回结果，则退回主进程直接探测（宁可短暂卡住也要有结果）。
function TechNews:runNetworkDiagnosis()
    local sources = subscriptions.enabled(registry, self:sourceSetting())
    local targets = {}
    for _, source in ipairs(sources) do
        if source.feed and #targets < 3 then
            targets[#targets + 1] = { name = source.name, url = source.feed }
        end
    end
    if #targets == 0 then
        targets[1] = { name = "IT之家", url = "https://www.ithome.com/rss/" }
    end
    -- 纯 http 对照：用来区分「HTTPS/TLS 有问题」还是「整机没网」
    targets[#targets + 1] = { name = "纯 HTTP 对照", url = "http://www.dgtle.com/rss/dgtle.xml" }

    local function show(text)
        UIManager:show(TextViewer:new{
            title = "知否 · 网络诊断",
            text = tostring(text),
        })
    end

    Trapper:wrap(function()
        local completed, text = Trapper:dismissableRunInSubprocess(function()
            local ok, report = pcall(build_diag_report, targets)
            if not ok then return "诊断异常（子进程）：" .. tostring(report) end
            return report
        end, "网络诊断中…（逐个目标探测，约十几秒；点击可取消）", true)
        if not completed then
            UIManager:show(InfoMessage:new{ text = "诊断已取消", timeout = 2 })
            return
        end
        if type(text) ~= "string" or text == "" then
            -- 子进程没带回结果（该平台 fork/管道受限）：退回主进程直接探测，
            -- 只测前两个目标以免长时间无响应
            local fallback_targets = { targets[1], targets[#targets] }
            local ok, report = pcall(build_diag_report, fallback_targets, function(target)
                Trapper:info(string.format("诊断 %s…（点击可取消）", target.name))
            end)
            if ok then
                show("（子进程未返回结果，已改为主进程直接探测）\n\n" .. report)
            else
                show("诊断失败：" .. tostring(report))
            end
            return
        end
        show(text)
    end)
end

--- 「设置」子菜单：管理收藏（仅有收藏时）、订阅源设置、包含图片、清理全部缓存
--- 设置菜单：按主题分组，避免平铺一堆复选框与诊断工具
--   图片与显示 ▶ / 订阅源 ▶ / 缓存清理 / 检查更新 / 收藏 ▶（有收藏时）/ 诊断 ▶
function TechNews:getSettingItems()
    local items = {}

    -- 1) 图片显示：开关 + 分辨率（设备屏宽不同，分辨率需要可调）
    items[#items + 1] = {
        text = "图片显示",
        sub_item_table_func = function()
            return {
            {
                text = "包含图片",
                keep_menu_open = true,
                text_func = function()
                    return (self:withImages() and "☑ " or "☐ ") .. "包含图片"
                end,
                callback = function(menu)
                    G_reader_settings:saveSetting("zhifou_with_images",
                        not self:withImages())
                    -- 切换后当天缓存作废，下次打开重新生成
                    storage:clear_date(today_str())
                    refresh_menu(menu)
                end,
            },
            {
                text = "图片转灰度（省体积）",
                keep_menu_open = true,
                text_func = function()
                    return (self:withGrayImages() and "☑ " or "☐ ")
                        .. "图片转灰度（省体积）"
                end,
                callback = function(menu)
                    G_reader_settings:saveSetting("zhifou_gray_images",
                        not self:withGrayImages())
                    storage:clear_date(today_str())
                    refresh_menu(menu)
                end,
            },
            {
                text = "图片分辨率",
                sub_item_table_func = function()
                    local auto_width = self:autoImageWidth()
                    -- 选中标记用 ☑/☐ 写进文字里：KOReader 的 RadioMark 用 ◉/◯
                    -- 两个 Unicode 符号，这套字体里没有（实测渲染成空白），
                    -- 与菜单里其它复选框保持一致反而更可靠
                    local function mark(selected)
                        return selected and "☑ " or "☐ "
                    end
                    local entries = {
                        {
                            text_func = function()
                                return mark(self:imageWidthSetting() == nil)
                                    .. string.format("自动（按屏幕宽度 · %d px）",
                                        auto_width)
                            end,
                            keep_menu_open = true,
                            callback = function(menu)
                                self:setImageWidth(nil)
                                refresh_menu(menu)
                            end,
                        },
                    }
                    for _, width in ipairs(images.PRESET_WIDTHS) do
                        entries[#entries + 1] = {
                            text_func = function()
                                return mark(self:imageWidthSetting() == width)
                                    .. string.format("%d px%s", width,
                                        width == images.DEFAULT_WIDTH
                                            and "（默认）" or "")
                            end,
                            keep_menu_open = true,
                            callback = function(menu)
                                self:setImageWidth(width)
                                refresh_menu(menu)
                            end,
                        }
                    end
                    entries[#entries + 1] = {
                        text = "越宽越清晰、流量越大",
                        enabled = false,
                    }
                    entries[#entries + 1] = {
                        text = "换档后当天缓存清空",
                        enabled = false,
                    }
                    return entries
                end,
            },
            }
        end,
    }

    -- 2) 订阅源相关
    items[#items + 1] = {
        text = "订阅源",
        sub_item_table_func = function()
            return {
                {
                    text = "订阅源设置",
                    sub_item_table_func = function()
                        return self:getSourceSettingItems()
                    end,
                },
                {
                    text = "源连通性自检",
                    keep_menu_open = true,
                    callback = function()
                        self:checkSourceConnectivity()
                    end,
                },
            }
        end,
    }

    -- 3) 缓存
    items[#items + 1] = {
        text = "缓存清理",
        sub_item_table_func = function()
            return self:getCacheCleanupItems()
        end,
    }

    -- 4) 在线更新（有新版时文案变「更新到 vX」）
    items[#items + 1] = {
        text_func = function()
            if self._pending_release then
                return "更新到 v" .. self._pending_release.version
            end
            return "检查更新"
        end,
        keep_menu_open = true, -- 确认框 / 下载进度显示在首页之上
        callback = function()
            local release = self._pending_release
            if release then
                self:installUpdate(release)
            else
                self:checkForUpdates()
            end
        end,
    }

    -- 5) 收藏（仅在有收藏时出现）
    if #favorites.load() > 0 then
        items[#items + 1] = {
            text = "收藏",
            sub_item_table_func = function()
                return self:getFavoriteManageItems()
            end,
        }
    end

    -- 6) 诊断：平时不占位置，需要时才展开
    items[#items + 1] = {
        text = "诊断",
        sub_item_table_func = function()
            return {
                {
                    text = "网络诊断（分阶段）",
                    keep_menu_open = true,
                    callback = function()
                        self:runNetworkDiagnosis()
                    end,
                },
                {
                    text = "最近错误",
                    keep_menu_open = true,
                    callback = function()
                        local ring = install_log_ring()
                        local text
                        if #ring.entries == 0 then
                            text = "本次启动以来没有记录到插件错误。\n\n"
                                .. "若刚抓取失败，请先抓一次再回来看。"
                        else
                            text = table.concat(ring.entries, "\n")
                        end
                        UIManager:show(TextViewer:new{
                            title = "知否 · 最近错误", text = text,
                        })
                    end,
                },
            }
        end,
    }

    return items
end

--- 「我的收藏」子菜单：每条收藏一个单篇快照 EPUB 打开入口
function TechNews:getFavoriteItems()
    local list = favorites.load()
    local items = {}
    for _, entry in ipairs(list) do
        if entry.file then
            items[#items + 1] = {
                text = string.format("%s · %s", entry.title,
                    os.date("%m-%d", tonumber(entry.favorited_at) or 0)),
                callback = function()
                    self:openEpub(entry.file)
                end,
            }
        end
    end
    if #items == 0 then
        items[1] = { text = "暂无收藏", select_enabled = false }
    end
    return items
end

--- 「往期缓存」子菜单：列出本机缓存过的各期刊物（近 7 天，随缓存清理自然过期）
function TechNews:getHistoryItems()
    local items = {}
    for _, entry in ipairs(storage:list_issues()) do
        items[#items + 1] = {
            text = issue_label(entry),
            callback = function() self:openEpub(entry.path) end,
        }
        if #items >= 40 then break end
    end
    if #items == 0 then
        items[1] = { text = "暂无缓存", select_enabled = false }
    end
    return items
end

--- 「缓存清理」子菜单：逐期列出缓存（含体积），可只删某一期；末尾才是清除全部。
-- （交互参照 weread：条目带体积、删除后就地重建列表；收藏不受影响）
function TechNews:getCacheCleanupItems()
    local lfs = require("libs/libkoreader-lfs")
    local ConfirmBox = require("ui/widget/confirmbox")
    local entries = storage:list_issues()
    local items = {}
    local total_size = 0
    for _, entry in ipairs(entries) do
        local label = issue_label(entry)
        local attr = lfs.attributes(entry.path)
        local size = (attr and attr.size) or 0
        total_size = total_size + size
        items[#items + 1] = {
            text = string.format("%s（%s）", label, human_size(size)),
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = string.format(
                        "清除「%s」的缓存？\n（该期 EPUB 与阅读进度将被删除，收藏不受影响）",
                        label),
                    ok_text = "清除",
                    cancel_text = "取消",
                    ok_callback = function()
                        storage:remove_issue(entry.name)
                        UIManager:show(InfoMessage:new{
                            text = "已清除：" .. label,
                            timeout = 2,
                        })
                        -- 成员已变化：整体重建缓存清理列表
                        if self._home_menu then
                            self._home_menu:switchItemTable("缓存清理",
                                self:getCacheCleanupItems())
                        end
                    end,
                })
            end,
        }
    end
    if #entries == 0 then
        items[1] = { text = "暂无缓存", select_enabled = false }
    else
        items[#items + 1] = {
            text = string.format("【清理】清除所有缓存（%d 期 · %s）",
                #entries, human_size(total_size)),
            separator = true,
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = string.format(
                        "清除所有缓存？\n（共 %d 期 EPUB 与阅读进度，收藏不受影响）",
                        #entries),
                    ok_text = "清除",
                    cancel_text = "取消",
                    ok_callback = function()
                        storage:clear_all()
                        UIManager:show(InfoMessage:new{
                            text = "缓存已清空",
                            timeout = 2,
                        })
                        if self._home_menu then
                            self._home_menu:switchItemTable("缓存清理",
                                self:getCacheCleanupItems())
                        end
                    end,
                })
            end,
        }
    end
    return items
end

--- 「管理收藏」子菜单：逐条确认删除；删除完成后整体重建条目表以反映成员变化
function TechNews:getFavoriteManageItems()
    local ConfirmBox = require("ui/widget/confirmbox")
    local items = {}
    for _, entry in ipairs(favorites.load()) do
        items[#items + 1] = {
            text = string.format("%s · %s", entry.title,
                os.date("%m-%d", tonumber(entry.favorited_at) or 0)),
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = "删除这条收藏？\n" .. entry.title,
                    ok_text = "删除",
                    cancel_text = "取消",
                    ok_callback = function()
                        favorites.remove(entry)
                        UIManager:show(InfoMessage:new{
                            text = "已删除收藏",
                            timeout = 2,
                        })
                        -- updateItems 只重绘旧条目表：成员已变化，须整体替换后再刷新
                        if self._home_menu then
                            self._home_menu:switchItemTable("管理收藏",
                                self:getFavoriteManageItems())
                        end
                    end,
                })
            end,
        }
    end
    if #items == 0 then
        items[1] = { text = "暂无收藏", select_enabled = false }
    end
    return items
end

-- 过渡别名：旧动作名（technews_*）继续注册，让既有手势绑定不断；
-- 待用户重新绑定后可考虑在后续版本移除
function TechNews:onDispatcherRegisterActions()
    Dispatcher:registerAction("zhifou_open", {
        category = "none",
        event = "ShowTechNews",
        title = "知否",
        general = true,
    })
    Dispatcher:registerAction("zhifou_quickmenu", {
        category = "none",
        event = "ShowTechNewsQuickMenu",
        title = "知否快捷菜单",
        general = true,
    })
    Dispatcher:registerAction("technews_open", {
        category = "none",
        event = "ShowTechNews",
        title = "知否（旧动作名 technews_open）",
        general = true,
    })
    Dispatcher:registerAction("technews_quickmenu", {
        category = "none",
        event = "ShowTechNewsQuickMenu",
        title = "知否快捷菜单（旧动作名 technews_quickmenu）",
        general = true,
    })
end

function TechNews:onShowTechNews()
    self:openMergedIssue()
end

--- 快捷菜单（Dispatcher 动作 zhifou_quickmenu；可绑定到双击等手势）
function TechNews:onShowTechNewsQuickMenu()
    local ButtonDialog = require("ui/widget/buttondialog")
    if not (self.ui and self.ui.document) then
        UIManager:show(InfoMessage:new{
            text = "在阅读知否资讯时可用快捷菜单",
            timeout = 2,
        })
        return true
    end
    -- Dispatcher 手势可在任意文档触发：非本插件文档必须拦下，避免「删除并返回」误删用户书籍
    if not self:isTechNewsDocument() then
        UIManager:show(InfoMessage:new{
            text = "该功能仅用于知否内容",
            timeout = 2,
        })
        return true
    end
    -- 已经弹出时不叠加（⋯ 按钮在菜单显示期间仍可被点到）
    local top_widget = UIManager:getTopmostVisibleWidget() or {}
    if top_widget.name == "zhifou_quickmenu" then
        return true
    end
    local article, issue_path, section_index = self:currentActionableArticle()
    local dialog
    local buttons = {}
    local first_row = { {
        text = "目录",
        callback = function()
            UIManager:close(dialog)
            if self.ui.toc and self.ui.toc.onShowToc then
                self.ui.toc:onShowToc()
            end
        end,
    } }
    if article then
        local ctx = self:favoriteContext(article, section_index)
        local favorited = ctx and (ctx.sub_favorited or ctx.whole_favorited)
        first_row[#first_row + 1] = {
            text = favorited and "取消收藏" or "收藏文章",
            callback = function()
                UIManager:close(dialog)
                self:toggleFavorite(article, issue_path, section_index)
            end,
        }
    end
    buttons[#buttons + 1] = first_row
    buttons[#buttons + 1] = {
        {
            text = "删除并返回",
            callback = function()
                UIManager:close(dialog)
                self:deleteCurrentDocument()
            end,
        },
        {
            text = "关闭并返回",
            callback = function()
                UIManager:close(dialog)
                self:closeDocumentAndReturn()
            end,
        },
    }
    dialog = ButtonDialog:new{
        name = "zhifou_quickmenu",
        title = "快捷菜单",
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
    return true
end

--- 关闭当前文档并回到插件首页（阅读器实例随后失效，改由文件管理器一侧的实例打开首页）
function TechNews:closeDocumentAndReturn()
    if not (self.ui and self.ui.document) then return end
    self.ui:onClose()
    -- 文件管理器通常还在下层：直接复用，保持它自己原来的位置（约等于 KOReader 启动时的视图）。
    -- 不传文档路径——传了会把文件管理器/书架导航进技术资讯的数据目录。
    local FileManager = require("apps/filemanager/filemanager")
    if not FileManager.instance then
        FileManager:showFiles()
    end
    UIManager:scheduleIn(0.2, function()
        local fm = FileManager.instance
        local fm_plugin = fm and fm.zhifou
        if fm_plugin then
            fm_plugin:openHome()
        else
            self:openHome()
        end
    end)
end

--- 删除当前文档：收藏快照同时移除收藏条目；完成后回到插件首页
function TechNews:deleteCurrentDocument()
    -- 防御：只删本插件生成的文档；Dispatcher 手势可能从其它书籍触发，绝不动用户自己的书
    if not self:isTechNewsDocument() then return end
    local doc_path = self.ui and self.ui.document and self.ui.document.file
    if not doc_path then return end
    local FileManager = require("apps/filemanager/filemanager")
    local function pre_delete_callback()
        local entry = self:favoriteEntryForDocument(doc_path)
        if entry then
            -- 收藏：keep_file=true 只移除索引条目，快照文件留给 FileManager 删除。
            -- 若在此处先删文件，随后的 deleteFile 会因文件已不存在而失败，
            -- 使 post_delete_callback 被跳过，无法回到插件首页。
            favorites.remove(entry, true)
        else
            os.remove(doc_path .. ".items.lua") -- 缓存期：清理条目 sidecar
        end
        self.ui:onClose()
    end
    local function post_delete_callback()
        -- 必须与阅读器关闭处于同一事件内：若延迟，窗口栈会短暂无应用而直接退出。
        -- 文件管理器还在下层就复用（不导航到数据目录）；不在才补一个（它自己的默认位置）。
        if not FileManager.instance then
            FileManager:showFiles()
        end
        local fm = FileManager.instance
        local fm_plugin = fm and fm.zhifou
        if fm_plugin then
            fm_plugin:openHome()
        else
            self:openHome()
        end
    end
    FileManager:showDeleteFileDialog(doc_path, post_delete_callback, pre_delete_callback)
end

-- 快捷按钮触摸区的覆盖列表：与 bookshelf 插件同款 + 左上角区
local QUICK_ZONE_OVERRIDES = {
    "tap_forward", "tap_backward",
    "readerhighlight_tap", "readerhighlight_tap_select_mode",
    "readerfooter_tap", "readermenu_tap", "readermenu_ext_tap",
    "tap_top_left_corner",
}

--- 阅读界面左上角的快捷菜单按钮（三个点）；仅本插件文档显示。
-- 参考 bookshelf 插件做法：显示挂到阅读视图模块（随页面绘制，不是浮层、不碰事件派发）；
-- 点击另注册为阅读器触摸区（overrides 盖过同位置的翻页/高亮/菜单/书签角等区域）。
-- 视图模块必须在首帧绘制前注册（ReaderReady 同步调用）：注册晚了按钮要等下一次
-- 重绘（翻页）才出现；且 setDirty 只认窗口栈上的部件——view 不在栈上，催不动重绘。
function TechNews:showQuickMenuButton()
    if self._quick_button or not self:isTechNewsDocument() then return end
    if not (self.ui.view and self.ui.view.registerViewModule) then return end
    local Screen = Device.screen
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin = Screen:scaleBySize(6)
    -- 顶部状态栏之下（读 footer 高度；无 footer 时贴着顶缘）
    local top_offset = 0
    if self.ui.footer and self.ui.footer.getHeight then
        local ok, h = pcall(self.ui.footer.getHeight, self.ui.footer)
        if ok and h then top_offset = h end
    end
    local dots = TextWidget:new{
        text = "…",
        face = Font:getFace("cfont", 34),
    }
    local dots_size = dots:getSize()
    -- 左上角（右上角被书签手势占用）；点击区放大，便于点按
    local x, y = margin, top_offset + margin
    local area = math.max(dots_size.w, dots_size.h) + Screen:scaleBySize(20) -- 点击区比点大一圈
    self._quick_button = {
        paintTo = function(_, bb)
            dots:paintTo(bb, x, y)
        end,
    }
    self.ui.view:registerViewModule("zhifou_quickmenu_dots", self._quick_button)
    -- 触摸区只预建对象，稍后再注册（见 registerQuickMenuTouchZone）
    self._quick_zone = {
        id = "zhifou_quickmenu_tap",
        ges = "tap",
        screen_zone = {
            ratio_x = margin / sw, ratio_y = (top_offset + margin) / sh,
            ratio_w = area / sw, ratio_h = area / sh,
        },
        overrides = QUICK_ZONE_OVERRIDES,
        handler = function()
            self:onShowTechNewsQuickMenu()
            return true
        end,
    }
end

--- 注册快捷按钮点击区；ReaderReady 后晚一拍调用。
-- 晚一拍是为了让注册顺序排在 ReaderUI 自身触摸区之后，overrides 才能盖过
-- 翻页/高亮/菜单/书签角等区域。
function TechNews:registerQuickMenuTouchZone()
    if self._quick_zone_registered or not self._quick_zone then return end
    self.ui:registerTouchZones({ self._quick_zone })
    self._quick_zone_registered = true
end

function TechNews:hideQuickMenuButton()
    if self._quick_button then
        if self.ui.view and self.ui.view.view_modules then
            self.ui.view.view_modules.zhifou_quickmenu_dots = nil
        end
        self._quick_button = nil
    end
    if self._quick_zone and self._quick_zone_registered
        and self.ui and self.ui.unRegisterTouchZones then
        self.ui:unRegisterTouchZones({ self._quick_zone })
    end
    self._quick_zone = nil
    self._quick_zone_registered = nil
end

function TechNews:onReaderReady()
    -- 显示：同步注册视图模块，赶在首帧绘制前（ReaderReady 早于 ReaderUI 入栈与首绘）
    self:showQuickMenuButton()
    -- 点击：晚一拍注册触摸区（顺序排在 ReaderUI 自身各区之后）；随后兜底催一次重绘
    UIManager:scheduleIn(0.3, function()
        self:registerQuickMenuTouchZone()
        if self._quick_button then UIManager:setDirty(self.ui, "ui") end
    end)
end

function TechNews:onCloseDocument()
    self:hideQuickMenuButton()
end

--- 抓取一个源。必须在 Trapper:wrap 协程内调用。
-- @return { items = {...}, images = { [url]= {data=, ext=} } } 或 (nil, 错误)
--- RSS 源的抓取与内容块组装；返回条目数组，或 nil 与错误原因。
-- range 为空时按严格今日窗口；否则按给定半开区间过滤（分源阅读的昨日/近一周/指定日）。
--- 重试时更新进度并接受取消（返回 false 会让 http.get 停止重试）
local function retry_progress(prefix, source_name)
    return function(attempt)
        return Trapper:info(string.format(
            "%s正在连接 %s…失败，第 %d 次重试（点击可取消）",
            prefix, source_name, attempt))
    end
end

local function fetch_rss_items(source, max_items, prefix, range)
    local xml, err = http.get(source.feed, nil, nil, nil, {
        on_retry = retry_progress(prefix, source.name),
    })
    if not xml then
        return nil, err
    end
    local items = rss.parse(xml)
    if #items == 0 then
        return nil, "没有解析到条目"
    end
    local result, n_range
    if range then
        result, n_range = window.filter_range(items, max_items,
            range.start_ts, range.end_ts, range.include_no_ts)
    else
        result, n_range = window.filter(items, max_items)
    end
    logger.info("zhifou window:",
        source.id,
        "in_range=" .. tostring(n_range),
        "selected=" .. tostring(#result),
        "feed=" .. tostring(#items))
    if #result == 0 then
        return {}
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
    return result
end

function TechNews:fetchSource(source, limit, progress, range)
    -- 合并模式下显示来源进度前缀（单源时为空串）
    local prefix = ""
    if progress and progress.source_count and progress.source_count > 1 then
        prefix = string.format("来源 %d/%d · ",
            progress.source_index, progress.source_count)
    end
    local max_items = limit or source.max_items
    -- 首个网络请求之前先出进度：feed/API 请求带重试（单源最坏 4×30s），
    -- 此前这一整段没有任何提示与取消点，用户看到的是「点了没反应」。
    if not Trapper:info(string.format("%s正在连接 %s…（点击可取消）", prefix, source.name)) then
        return nil, "已取消"
    end
    local result, err
    if source.fetch then
        -- 自定义抓取源（如知乎日报 API）：适配器按时间范围直接产出条目（含内容块）
        result, err = source.fetch(self, {
            range = range, limit = max_items, prefix = prefix,
        })
    else
        result, err = fetch_rss_items(source, max_items, prefix, range)
    end
    if not result then
        return nil, err
    end
    if #result == 0 then
        return nil, (range and range.empty) or "今日暂无新条目"
    end
    for _, item in ipairs(result) do
        item.source_id = source.id
        item.source_name = source.name
    end

    -- 2) 下载图片（可关闭；张数上限 + 字节额度，见 zhifou/images.lua）
    local downloaded = {}
    local image_skips = 0
    local hit_deadline = false   -- 图片阶段是否因整期时间预算提前收手
    if self:withImages() then
        local pending = {}
        local seen = {}
        for _, item in ipairs(result) do
            for _, block in ipairs(item.blocks) do
                if block.img and not seen[block.img] then
                    seen[block.img] = true
                    pending[#pending + 1] = { url = block.img }
                end
            end
        end
        -- 合并模式下由调用方传入剩余张数额度，单源时用整期上限
        local cap = (progress and progress.image_budget) or MAX_IMAGES_PER_ISSUE
        if cap < 0 then cap = 0 end
        local total = math.min(#pending, cap)
        local gray = self:withGrayImages()
        -- 图片分辨率（设置 → 图片显示 → 图片分辨率）：目标宽 → 降档宽
        local target_width = self:imageTargetWidth()
        local target_widths = self:imageWidths()
        -- 字节额度：合并期跨源共享（调用方传入同一个 budget 才生效）；
        -- 额度随分辨率放大——选了更高分辨率不该变成「更多图被略过」
        local budget = (progress and progress.image_bytes_budget)
            or images.new_budget({ width = target_width })
        local deadline = progress and progress.deadline
        local started_at = os.time()
        -- 按图床记账：同一 host 连续失败到阈值就跳过它剩下的图
        -- （个别图床在设备网络上不可达时，否则会一张一张地耗光整期时间）
        local host_failures, host_circuit = {}, {}
        for i = 1, total do
            -- 每张都查时钟：单张最坏也要几十秒，隔 10 张才查等于预算形同虚设
            if deadline and os.time() > deadline then
                hit_deadline = true
                logger.warn("zhifou image deadline reached:", source.id,
                    "at", tostring(i), "of", tostring(total))
                break
            end
            local url = pending[i].url
            local host = images.host_of(url)
            local elapsed = os.time() - started_at
            local msg = string.format("%s下载图片 %d/%d（已 %d 分 %d 秒）…（点击可取消）",
                prefix, i, total, math.floor(elapsed / 60), elapsed % 60)
            if not Trapper:info(msg) then
                return nil, "已取消"
            end
            if host and host_circuit[host] then
                -- 该图床已熔断：不再尝试，直接跳过（计入略过数）
                budget:note_skip("host_down")
            else
                -- 重写（含灰度/转 JPEG）→ 下载 → 魔数判型 → 额度判定，全在 images.fetch 里
                local image, img_err = images.fetch(url, {
                    download = download_image,
                    rewrite = imgurl.rewrite,
                    budget = budget,
                    gray = gray,
                    widths = target_widths,
                })
                if image then
                    if host then host_failures[host] = 0 end
                    downloaded[url] = image
                elseif img_err == "over_budget" then
                    -- 整期字节额度用尽：后面的图不再下载（张数与体积都要有闸门）
                    logger.info("zhifou image budget exhausted:", source.id,
                        "at", tostring(i), "of", tostring(total))
                    break
                elseif host and images.is_host_failure(img_err) then
                    host_failures[host] = (host_failures[host] or 0) + 1
                    if host_failures[host] >= images.MAX_HOST_FAILURES then
                        host_circuit[host] = true
                        logger.warn("zhifou image host circuit open:", host,
                            "after", tostring(host_failures[host]), "failures;",
                            "skipping the rest from this host")
                    end
                end
            end
        end
        local summary = budget:summary()
        image_skips = summary.skipped
        logger.info("zhifou images:",
            source.id,
            "pending=" .. tostring(#pending),
            "downloaded=" .. tostring(summary.images),
            "cap=" .. tostring(cap),
            "bytes=" .. tostring(summary.bytes),
            "skipped=" .. tostring(summary.skipped))
    end

    -- 字节额度对象要跨源复用：合并期由调用方持有并传回下一源
    return {
        items = result, images = downloaded,
        image_skips = image_skips, budget_hit = hit_deadline,
    }
end

--- 生成 EPUB 并打开
-- @param warnings 可选：本期缺漏提示（合并期里有源抓取失败时的源名列表）
function TechNews:buildAndOpen(issue_id, title, date, items, image_map, warnings)
    local path = storage:epub_path(issue_id, date)
    logger.info("zhifou building issue:",
        issue_id, date, tostring(#items) .. " items", path)
    local ok, err = pcall(epub.build, {
        title = title,
        date = date,
        -- 唯一标识带上 issue_id：同一天的合并期与各单源期不能共用同一个 identifier
        identifier = "zhifou-" .. issue_id .. "-" .. date,
        items = items,
        images = image_map or {},
    }, path)
    if not ok then
        logger.warn("zhifou epub build failed:", tostring(err))
        os.remove(path .. ".part") -- 清理构建中断残留（与 favorites.add 一致）
        Trapper:clear()
        UIManager:scheduleIn(0.1, function()
            UIManager:show(InfoMessage:new{
                text = "生成 EPUB 失败\n" .. tostring(err),
            })
        end)
        return
    end
    -- 成功出刊后写入条目 sidecar（阅读器内「收藏当前文章」据此定位当前条目）
    favorites.write_sidecar(path, title, date, items)
    -- 抓取与构建全部完成：弹一条含条数/图片数的完成提示（2 秒自动消失）
    local image_count = 0
    for _ in pairs(image_map or {}) do
        image_count = image_count + 1
    end
    local text = string.format("下载完成 · %d 条资讯 · %d 张图片", #items, image_count)
    -- 有源抓取失败时必须说明：否则用户会以为「今天这些源没更新」
    -- （此前只写 logger，界面上完全看不出来）
    if warnings and #warnings > 0 then
        text = text .. "\n本期未取到：" .. table.concat(warnings, "、")
    end
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = warnings and #warnings > 0 and 5 or 2,
    })
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

--- 当前阅读的文章条目及其所在期路径；任一条件不满足返回 nil。
--- 判定链：有文档 → 文档旁有可读 sidecar → 定位当前章节标题 → 与 sidecar 条目精确匹配。
--- 标题若是文内小标题（二级目录条目），额外返回第三值 section_index（1 起）：
--- 位于小标题分区内时，收藏可选择「整篇 / 本小篇」。
function TechNews:currentIssueArticle()
    local ui = self.ui
    local document = ui and ui.document
    local issue_path = document and document.file
    if not issue_path then return nil end
    local meta = favorites.load_sidecar(issue_path)
    if not meta then return nil end

    -- 当前章节标题用 xpointer 比较定位，而不是 KOReader 的
    -- getTocTitleOfCurrentPage()。原因（合并期实测）：目录按来源分组，
    -- NCX 父节点按来源、子节点按组内顺序，与正文 spine 的时间顺序不一致，
    -- 于是 TOC 顺序 != 文档顺序（非单调）。ReaderToc:getTocIndexByPage 却按
    -- TOC 顺序线性扫描、遇到首个 page 超界即 early break，非单调目录会提前
    -- 中断并返回错误条目——实测会返回「IT之家」这类分组标签或别家的章节。
    -- 而 xpointer 比较与 TOC 排列无关：在所有条目中取「不晚于当前位置」的
    -- 最大 xpointer；相同 xpointer（分组父节点 content 指向组内首条）时取
    -- TOC 中靠后者，让子条目胜过父标签。
    local toc_reader = ui and ui.toc
    if toc_reader and not toc_reader.toc and toc_reader.fillToc then
        pcall(toc_reader.fillToc, toc_reader)
    end
    local entries = toc_reader and toc_reader.toc
    local title
    local cur_xp = document.getXPointer and document:getXPointer()
    -- cur_xp 为空串说明当前没有有效书签位置（crengine getBookmark 为空）：
    -- 此时 createXPointer 全部为 null、比较恒返回 0，扫描会退化成「取最后一条」，
    -- 必须改走兜底而不参与比较
    if entries and cur_xp and cur_xp ~= "" and document.compareXPointers then
        local best
        for _, entry in ipairs(entries) do
            if entry.xpointer and entry.title then
                local cmp = document:compareXPointers(entry.xpointer, cur_xp)
                if cmp == 0 or cmp == 1 then -- 条目位置不晚于当前页
                    if not best then
                        best = entry
                    else
                        -- rel == -1：entry 比 best 更靠后（xpointer 更大）→ 取 entry
                        -- rel == 0：同一位置 → 取 TOC 中靠后者（子条目胜过组标签）
                        local rel = document:compareXPointers(entry.xpointer, best.xpointer)
                        if rel == -1 or rel == 0 then best = entry end
                    end
                end
            end
        end
        if best then title = best.title end
    end
    -- 兜底：没有 xpointer 信息（引擎不支持/无目录）时退回 KOReader 原生查找，
    -- 保证单源、平铺目录等旧场景行为不变
    if not title or title == "" then
        title = toc_reader and toc_reader.getTocTitleOfCurrentPage
            and toc_reader:getTocTitleOfCurrentPage()
    end
    if not title or title == "" then return nil end
    -- 目录标题可能带来源前缀（【来源】标题，见 epub.lua 的 toc_label）；
    -- 由 favorites.locate 以「原始/去前缀」两种形式定位
    local item, section_index = favorites.locate(meta.items, title)
    if item then
        return item, issue_path, section_index
    end
    return nil
end

--- 按文档路径反查收藏条目（索引里存的是相对路径，以文件名为准比对）
function TechNews:favoriteEntryForDocument(path)
    if not path then return nil end
    local base = path:match("([^/]+)$")
    for _, entry in ipairs(favorites.load()) do
        if entry.file and entry.file:match("([^/]+)$") == base then
            return entry
        end
    end
    return nil
end

--- 可操作的当前文章：优先本期 sidecar（每日缓存期），其次按收藏快照反查索引（阅读收藏时）。
--- 跟随 currentIssueArticle 返回 (article, issue_path, section_index)。
function TechNews:currentActionableArticle()
    local article, issue_path, section_index = self:currentIssueArticle()
    if article then return article, issue_path, section_index end
    local doc_path = self.ui and self.ui.document and self.ui.document.file
    local entry = self:favoriteEntryForDocument(doc_path)
    if entry then
        return {
            title = entry.title,
            link = entry.link,
            source_name = entry.source_name,
        }
    end
    return nil
end

--- 收藏上下文：站在带二级目录文章的小标题分区内时解析出子文章与两级收藏状态。
-- 返回 { sub = 子文章或 nil, whole_favorited = bool, sub_favorited = bool }；article 缺失时 nil。
function TechNews:favoriteContext(article, section_index)
    if not article then return nil end
    local sub = section_index and favorites.section_article(article, section_index) or nil
    return {
        sub = sub,
        whole_favorited = favorites.is_favorited(article.title) and true or false,
        sub_favorited = sub ~= nil and favorites.is_favorited(sub.title) and true or false,
    }
end

--- 取消收藏（按标题精确匹配）；整篇与小篇两条路径共用。
function TechNews:removeFavorite(title)
    local entry = favorites.find(title)
    if not entry then return end
    favorites.remove(entry)
    UIManager:show(InfoMessage:new{
        text = "已取消收藏",
        timeout = 2,
    })
end

--- 执行收藏（Trapper 协程内构建快照）；article 为整篇或某小节的子文章。
function TechNews:doFavorite(article, issue_path)
    logger.info("zhifou favorite:", article.title, issue_path)
    Trapper:wrap(function()
        Trapper:info("收藏中…（点击可取消）")
        local added, err = favorites.add(article, issue_path, function(text)
            return Trapper:info(text)
        end, self:withGrayImages(), self:imageWidths())
        Trapper:clear()
        if added then
            UIManager:show(InfoMessage:new{
                text = "已收藏：" .. article.title,
                timeout = 2,
            })
        else
            local msg = err == "已取消" and "已取消收藏"
                or ("收藏失败：" .. tostring(err or "未知错误"))
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 3,
            })
        end
    end)
end

--- 收藏/取消收藏当前文章（阅读器菜单与快捷菜单入口）。
-- 带二级目录的文章里位于某小标题分区内时：本小篇已收藏 → 直接取消；
-- 否则弹出「整篇 / 本小篇」选择框（按钮文案随两级已收藏状态变化）。
function TechNews:toggleFavorite(article, issue_path, section_index)
    local ctx = self:favoriteContext(article, section_index)
    if not ctx then return end
    if ctx.sub_favorited then
        self:removeFavorite(ctx.sub.title)
        return
    end
    if not ctx.sub and ctx.whole_favorited then
        self:removeFavorite(article.title)
        return
    end
    if ctx.sub then
        self:showFavoriteChoice(article, issue_path, ctx)
        return
    end
    self:doFavorite(article, issue_path)
end

--- 收藏范围选择框：收藏整篇 / 收藏本小篇（点击框外取消）
function TechNews:showFavoriteChoice(article, issue_path, ctx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        name = "zhifou_favorite_choice",
        title = "收藏",
        title_align = "center",
        buttons = { {
            {
                text = ctx.whole_favorited and "取消收藏整篇" or "收藏整篇文章",
                callback = function()
                    UIManager:close(dialog)
                    if ctx.whole_favorited then
                        self:removeFavorite(article.title)
                    else
                        self:doFavorite(article, issue_path)
                    end
                end,
            },
            {
                text = ctx.sub_favorited and "取消收藏本小篇" or "收藏本小篇",
                callback = function()
                    UIManager:close(dialog)
                    if ctx.sub_favorited then
                        self:removeFavorite(ctx.sub.title)
                    else
                        self:doFavorite(ctx.sub, issue_path)
                    end
                end,
            },
        } },
    }
    UIManager:show(dialog)
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

--- 用户主动取消：中性提示，不提供重试
function TechNews:showCancelled()
    UIManager:scheduleIn(0.1, function()
        UIManager:show(InfoMessage:new{
            text = "已取消抓取",
            timeout = 2,
        })
    end)
end

--- 打开单个源在指定时间范围的资讯（分源阅读：今日 / 昨日 / 近一周 / 指定日期）。
-- 缓存键：今日与昨日/指定日期为 <id>-<刊期日>.epub，近一周为 <id>-week-<今日>.epub；
-- 命中缓存直接打开，不再抓取。
function TechNews:openIssueRange(source, kind, date)
    local range, why = issue_range(kind, date)
    if not range then
        UIManager:scheduleIn(0.1, function()
            UIManager:show(InfoMessage:new{ text = why or "无效的日期", timeout = 2 })
        end)
        return
    end
    local issue_id = source.id .. range.suffix
    if storage:epub_exists(issue_id, range.date) then
        self:openEpub(storage:epub_path(issue_id, range.date))
        return
    end
    Trapper:wrap(function()
        local bundle, err = self:fetchSource(source, source.max_items, nil, range)
        if not bundle then
            Trapper:clear()
            if err == "已取消" then
                self:showCancelled()
                return
            end
            self:showFetchError(err, function() self:openIssueRange(source, kind, date) end)
            return
        end
        local title = string.format("%s · %s", source.name, range.title)
        local warnings = {}
        if (bundle.image_skips or 0) > 0 then
            warnings[#warnings + 1] = string.format("%d 张图过大已略过", bundle.image_skips)
        end
        self:buildAndOpen(issue_id, title, range.date, bundle.items, bundle.images, warnings)
        -- 结束立即收起进度消息（Trapper 不会自动关闭，需显式 clear；KOReader 惯例）
        Trapper:clear()
    end)
end

--- 打开已启用源的合并今日资讯
function TechNews:openMergedIssue(prompt_if_cached)
    local date = today_str()
    if storage:epub_exists("merged", date) then
        -- 首页入口：已有今日一期时先问「打开 / 重新抓取」；手势等快捷路径直接打开
        if prompt_if_cached then
            self:showTodayIssueDialog(date)
        else
            self:openEpub(storage:epub_path("merged", date))
        end
        return
    end
    self:fetchAndOpenMerged("merged", date, nil)
end

--- 打开合并期的指定时间范围（「抓取往期」：今日 / 昨日 / 近一周 / 指定日期）。
-- 缓存键：今日为 merged-<今日>，近一周为 merged-week-<今日>，其余以目标日为刊期。
function TechNews:openMergedIssueRange(kind, date)
    local range, why = issue_range(kind, date)
    if not range then
        UIManager:scheduleIn(0.1, function()
            UIManager:show(InfoMessage:new{ text = why or "无效的日期", timeout = 2 })
        end)
        return
    end
    local issue_id = "merged" .. range.suffix
    if storage:epub_exists(issue_id, range.date) then
        self:openEpub(storage:epub_path(issue_id, range.date))
        return
    end
    self:fetchAndOpenMerged(issue_id, range.date, range)
end

--- 抓取并打开合并期（共享管线；range 为空 = 严格今日）：
-- 逐源抓取（跨源共享图片额度）→ 按时间倒序 → 跨源去重 → 构建打开
function TechNews:fetchAndOpenMerged(issue_id, date, range)
    local sources = subscriptions.enabled(registry, self:sourceSetting())
    if #sources == 0 then
        UIManager:scheduleIn(0.1, function()
            UIManager:show(InfoMessage:new{
                text = "请先在「订阅源设置」中选择至少一个新闻源",
                timeout = 4,
            })
        end)
        return
    end
    Trapper:wrap(function()
        local all = {}
        local all_images = {}
        local failed = {}
        local image_budget = MAX_IMAGES_PER_ISSUE
        -- 字节额度跨源共享：否则每个源各留 12MB，整期仍可能到几十 MB；
        -- 额度随「图片分辨率」设置放大（高分辨率下同一批图本就更大）
        local bytes_budget = images.new_budget({ width = self:imageTargetWidth() })
        local image_skips = 0
        -- 整期时间预算：超了就停止后续源，并在完成提示里说明
        local deadline = os.time() + FETCH_BUDGET_SECONDS
        local skipped_by_budget = {}
        for i, source in ipairs(sources) do
            if os.time() > deadline then
                skipped_by_budget[#skipped_by_budget + 1] = source.name
                logger.warn("zhifou fetch deadline reached, skip source:", source.id)
            else
            local bundle, err = self:fetchSource(source, source.merge_max_items,
                { source_index = i, source_count = #sources,
                  image_budget = image_budget,
                  image_bytes_budget = bytes_budget,
                  deadline = deadline }, range)
            if bundle then
                -- 合并期图片上限跨源共享：按实际下载数扣减剩余额度
                local used = 0
                for _ in pairs(bundle.images) do used = used + 1 end
                image_budget = math.max(image_budget - used, 0)
                image_skips = image_skips + (bundle.image_skips or 0)
                for _, item in ipairs(bundle.items) do
                    all[#all + 1] = item
                end
                for url, img in pairs(bundle.images) do
                    all_images[url] = img
                end
            else
                if err == "已取消" then
                    -- 取消是整期语义：立刻中止，不当作单源失败继续凑刊
                    Trapper:clear()
                    self:showCancelled()
                    return
                end
                logger.warn("zhifou merge source failed:",
                    source.id, tostring(err))
                failed[#failed + 1] = { name = source.name, err = tostring(err) }
            end
            end
        end
        if #all == 0 then
            Trapper:clear()
            -- 全军覆没时把每个源的原因一并说清（断网 / 被墙 / 改版 是三种不同的处置）
            local reason = range and range.empty
            if not reason then
                local parts = {}
                for _, fail in ipairs(failed) do
                    parts[#parts + 1] = fail.name .. "（" .. fail.err .. "）"
                end
                reason = table.concat(parts, "、") .. " 均不可用"
            end
            self:showFetchError(reason,
                function() self:fetchAndOpenMerged(issue_id, date, range) end)
            return
        end
        -- 按时间倒序排列（无时间的排最后）
        table.sort(all, function(a, b)
            return (a.ts or 0) > (b.ts or 0)
        end)
        -- 跨源去重：同一条新闻两源都报时只保留正文更全的一条
        local kept, removed = dedupe.filter(all)
        -- 去重保留更全条目时会把它移到列表末尾，这里恢复按时间倒序
        table.sort(kept, function(a, b)
            return (a.ts or 0) > (b.ts or 0)
        end)
        for _, pair in ipairs(removed) do
            logger.info("zhifou dedupe:",
                pair.kept.title, "|", pair.dropped.title, "|",
                ("%.2f"):format(dedupe.similarity(pair.kept.title, pair.dropped.title)))
        end
        logger.info("zhifou dedupe removed:",
            tostring(#removed), "of", tostring(#all))
        for _, pair in ipairs(dedupe.near_misses(kept, 0.6)) do
            logger.info("zhifou dedupe near-miss:",
                pair.a.title, "|", pair.b.title, "|",
                ("%.2f"):format(pair.similarity))
        end
        local title = "知否 · " .. (range and range.title or date)
        local warnings = {}
        for _, fail in ipairs(failed) do
            warnings[#warnings + 1] = fail.name
        end
        -- 有图被略过也要说一声（否则用户只看到图片数变少，不知道是体积闸门）
        if image_skips > 0 then
            warnings[#warnings + 1] = string.format("%d 张图过大已略过", image_skips)
        end
        if #skipped_by_budget > 0 then
            warnings[#warnings + 1] = string.format("抓取超时已跳过 %d 个源（%s）",
                #skipped_by_budget, table.concat(skipped_by_budget, "、"))
        end
        self:buildAndOpen(issue_id, title, date, kept, all_images, warnings)
        Trapper:clear()
    end)
end

--- 今日一期已存在：询问直接打开还是重新抓取（原「重新抓取今日」菜单项并入此处）
function TechNews:showTodayIssueDialog(date)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = "今日一期已生成",
        buttons = {
            {
                { text = "打开", callback = function()
                    UIManager:close(dialog)
                    self:openEpub(storage:epub_path("merged", date))
                end },
                { text = "重新抓取", callback = function()
                    UIManager:close(dialog)
                    self:refetchToday()
                end },
            },
            {
                { text = "取消", callback = function() UIManager:close(dialog) end },
            },
        },
    }
    UIManager:show(dialog)
end

--- 清掉今日缓存并立即重新抓取合并期（带进度显示）
function TechNews:refetchToday()
    storage:clear_date(today_str())
    self:openMergedIssue()
end

--- 检查在线更新（设置菜单入口）：GitHub Releases 取最新版，比较版本号
function TechNews:checkForUpdates()
    Trapper:wrap(function()
        Trapper:info("正在检查更新…（点击可取消）")
        local release, err = updater.fetch_latest_release()
        Trapper:clear()
        if not release then
            UIManager:show(InfoMessage:new{
                text = "检查更新失败：" .. tostring(err or "未知错误"),
                timeout = 4,
            })
            return
        end
        if not updater.is_newer(release.version, self.version) then
            self._pending_release = nil
            UIManager:show(InfoMessage:new{
                text = "已是最新版本 v" .. tostring(self.version),
                timeout = 3,
            })
            return
        end
        -- 记下待装版本：菜单文案变为「更新到 vX」，再次点击可直接安装
        self._pending_release = release
        if self._home_menu then self._home_menu:updateItems() end
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = string.format("发现新版本 v%s（当前 v%s）\n\n是否下载并安装？",
                release.version, tostring(self.version)),
            ok_text = "下载并安装",
            cancel_text = "取消",
            ok_callback = function()
                self:installUpdate(release)
            end,
        })
    end)
end

--- 下载并安装更新：整个任务在子进程中执行，进度经进度文件回传。
-- 说明：http.download 的进度回调运行在 socket 回调（C 调用栈）中，不能 yield
-- （Trapper:info 会崩）；子进程里只做纯文件写入，UI 线程按 0.5s 轮询刷新进度条。
-- 进度条可点击取消（Trapper 的 dismiss 信号）。
function TechNews:installUpdate(release)
    local ProgressbarDialog = require("ui/widget/progressbardialog")
    local progress_path = storage.dir .. "update-progress"
    local zip_path = storage.dir .. "zhifou-update.zip"

    local function write_progress(stage, percent, current, total)
        local file = io.open(progress_path .. ".tmp", "wb")
        if not file then return end
        file:write(table.concat({
            tostring(stage), tostring(math.floor(percent or 0)),
            tostring(math.floor(current or 0)), tostring(math.floor(total or 0)),
        }, "\t"))
        file:close()
        os.rename(progress_path .. ".tmp", progress_path)
    end

    local function read_progress()
        local file = io.open(progress_path, "rb")
        if not file then return nil end
        local content = file:read("*a")
        file:close()
        local stage, percent = content:match("^([^\t]*)\t(%d+)\t%d+\t%d+$")
        if not stage then return nil end
        return stage, tonumber(percent)
    end

    local function remove_progress()
        os.remove(progress_path)
        os.remove(progress_path .. ".tmp")
    end

    remove_progress()
    local dialog = ProgressbarDialog:new{
        title = "正在更新 v" .. release.version .. "…",
        progress_max = 100,
        refresh_time_seconds = 0.5,
    }
    dialog:show()

    local active = true
    local function poll()
        if not active then return end
        local stage, percent = read_progress()
        if stage == "downloading" then
            dialog:reportProgress(percent)
        elseif stage == "install" or stage == "complete" then
            dialog:reportProgress(100)
        end
        UIManager:scheduleIn(0.5, poll)
    end

    Trapper:wrap(function()
        poll()
        local zip_size = tonumber(release.zip_size) or 0
        local completed, result = Trapper:dismissableRunInSubprocess(function()
            -- 子进程：下载 + 安装；进度只写文件，不触碰 UI（可安全用于 socket 回调）
            write_progress("downloading", 0, 0, zip_size)
            -- 传入 release 提供的 sha256：镜像即使被投毒，内容对不上也会被拒
            local ok, err = updater.download(release.zip_url, zip_path, function(received)
                write_progress("downloading",
                    zip_size > 0 and math.floor(received * 100 / zip_size) or 0,
                    received, zip_size)
                return true
            end, release.zip_digest)
            if not ok then
                return { success = false, phase = "download", error = err }
            end
            write_progress("install", 100, 0, zip_size)
            local installed, install_err = updater.install(zip_path, release.version)
            os.remove(zip_path) -- 成败都清理下载文件
            if not installed then
                return { success = false, phase = "install", error = install_err }
            end
            write_progress("complete", 100, 0, zip_size)
            return { success = true }
        end, dialog)

        active = false
        UIManager:unschedule(poll)
        remove_progress()
        dialog.dismiss_callback = nil -- 收尾关闭时不再触发取消信号
        dialog:close()

        if not result or not result.success then
            local msg
            if not completed then
                msg = "已取消更新"
            else
                local prefix = result.phase == "download" and "下载失败：" or "安装失败："
                msg = prefix .. tostring(result.error or "未知错误")
            end
            UIManager:show(InfoMessage:new{ text = msg, timeout = 5 })
            return
        end
        self._pending_release = nil
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = string.format("已更新到 v%s\n\n是否立即重启 KOReader 以生效？",
                release.version),
            ok_text = "重启",
            cancel_text = "稍后",
            ok_callback = function()
                UIManager:restartKOReader()
            end,
        })
    end)
end

return TechNews
