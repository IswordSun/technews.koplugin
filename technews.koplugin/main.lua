-- 科技资讯订阅 — 多源 RSS 订阅阅读器
--
-- 入口：
--   顶部菜单 → 科技资讯订阅 → 全屏首页（打开今日 / 分源阅读 / 设置）
--   手势/快捷菜单：Dispatcher 动作「科技资讯订阅」（直接打开合并今日）
--
-- 数据流：RSS/网页 → 内容块（文字+图片）→ 生成整期 EPUB → KOReader 原生阅读器
--
-- 自测钩子：环境变量 TECHNEWS_SELFTEST=1 时，启动 3 秒后自动打开「合并·今日」

-- 首次引导一次性守卫：插件经 dofile 重载会重置模块级变量，必须用全局记录
-- luacheck: globals G_technews_sources_prompted

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckButton = require("ui/widget/checkbutton")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local dedupe = require("technews.dedupe")
local extract = require("technews.extract")
local epub = require("technews.epub")
local favorites = require("technews.favorites")
local htmltext = require("technews.htmltext")
local http = require("technews.http")
local imgurl = require("technews.imgurl")
local rss = require("technews.rss")
local storage = require("technews.storage")
local subscriptions = require("technews.subscriptions")
local window = require("technews.window")

-- 全部可用订阅源（有序）；新增源只需在 sources/registry.lua 追加一行
local registry = require("technews.sources.registry")

-- 每期图片总量上限（安全阀：控制抓取时间与 EPUB 体积；每条默认取全部图片）
local MAX_IMAGES_PER_ISSUE = 150

local TechNews = WidgetContainer:extend{
    name = "technews",
    is_doc_only = false,
    version = "0.1.1",
}

-- 自测只执行一次：插件用 dofile 加载，模块级变量会随 UI 重建被重置，
-- 必须用全局变量记录（同一进程内有效），否则会反复重开文档。
-- （环境变量 TECHNEWS_SELFTEST）

local function today_str()
    return os.date("%Y-%m-%d")
end

local function source_by_id(id)
    for _, source in ipairs(registry) do
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

-- 下载图片：按图床决定是否附带 Referer
-- （少数派 cdnfile.sspai.com 不带 Referer 会 403；其余图床不带，见 imgurl.referer）
local function download_image(url)
    return http.get(url, nil, nil, nil, { referer = imgurl.referer(url) })
end

-- 「选择订阅源」多选对话框（容器结构参照 KOReader 的 ConfirmBox）：
-- CenterContainer > MovableContainer > FrameContainer > VerticalGroup
--   （标题 + 提示 + 每源一个 CheckButton）+ ButtonTable（取消/确定）
-- 点对话框外或按返回键 = 取消（不保存）
local SourceSelectDialog = InputContainer:extend{
    modal = true,
    dismissable = true,
    sources = nil,    -- 适配器数组（决定行数与顺序）
    checked = nil,    -- { [source.id] = true } 初始勾选状态
    on_confirm = nil, -- 确定回调，参数为勾选集合 { [id] = true }
}

function SourceSelectDialog:init()
    local screen = Device.screen
    local width = math.floor(math.min(screen:getWidth(), screen:getHeight()) * 2/3)

    -- 每个登记源一个勾选项，初始状态即当前启用状态
    self.check_buttons = {}
    local source_list = VerticalGroup:new{ align = "left" }
    for _, source in ipairs(self.sources) do
        local button = CheckButton:new{
            text = source.name,
            checked = self.checked[source.id] == true,
            parent = self,
            width = width,
        }
        self.check_buttons[source.id] = button
        table.insert(source_list, button)
    end

    local buttons = {{ -- 单行：取消 / 确定
        {
            text = "取消",
            callback = function()
                UIManager:close(self)
            end,
        },
        {
            text = "确定",
            callback = function()
                local set = {}
                for id, button in pairs(self.check_buttons) do
                    if button.checked then set[id] = true end
                end
                self.on_confirm(set)
                UIManager:close(self)
            end,
        },
    }}

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        padding = Size.padding.default,
        padding_bottom = 0, -- 底部不留白，由按钮行接管
        VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text = "选择订阅源",
                face = Font:getFace("infofont"),
                bold = true,
            },
            VerticalSpan:new{ width = Size.span.vertical_default },
            TextBoxWidget:new{
                text = "之后可在「订阅源设置」里修改，点「确定」保存",
                face = Font:getFace("smallinfofont"),
                width = width,
            },
            VerticalSpan:new{ width = Size.padding.large },
            source_list,
            VerticalSpan:new{ width = Size.padding.large },
            ButtonTable:new{
                width = width,
                buttons = buttons,
                zero_sep = true,
                show_parent = self,
            },
        },
    }
    self.movable = MovableContainer:new{ frame }
    self[1] = CenterContainer:new{
        dimen = screen:getSize(),
        self.movable,
    }

    if self.dismissable then
        if Device:isTouchDevice() then
            self.ges_events.TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = screen:getWidth(), h = screen:getHeight(),
                    },
                },
            }
        end
        if Device:hasKeys() then
            self.key_events.Close = { { Device.input.group.Back } }
        end
    end
end

function SourceSelectDialog:onTapClose(_, ges)
    if ges.pos:notIntersectWith(self.movable.dimen) then
        UIManager:close(self)
    end
    -- 不把点击传播给下层控件
    return true
end

function SourceSelectDialog:onClose()
    UIManager:close(self)
    return true
end

function SourceSelectDialog:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.movable.dimen
    end)
end

function SourceSelectDialog:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self.movable.dimen
    end)
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

--- 订阅源设置（nil = 用户尚未选择，按各源 default_enabled 默认启用）
function TechNews:sourceSetting()
    return G_reader_settings:readSetting("technews_sources")
end

--- 保存订阅源设置；启用集合变化后当天缓存作废，下次打开重建
function TechNews:setSourceSetting(set)
    G_reader_settings:saveSetting("technews_sources", set)
    storage:clear_date(today_str())
end

function TechNews:addToMainMenu(menu_items)
    menu_items.technews = {
        text = "科技资讯订阅",
        sorting_hint = "tools",
        -- 主菜单只保留一个入口：直接打开全屏首页（不再展开下拉子菜单）
        callback = function()
            self:openHome()
        end,
    }
    -- 阅读器菜单条目只在阅读文档时注册（文件管理器无 self.ui.document）。
    -- 已核实：ReaderMenu 的 tab_item_table 一旦构建即缓存，addToMainMenu 每次阅读会话
    -- 只被调用一次，故文案不能按注册时状态固定，需用 text_func 在每次菜单展开时求值。
    if self.ui.document then
        menu_items.technews_favorite = {
            text_func = function()
                local article = self:currentIssueArticle()
                if article and favorites.is_favorited(article.title) then
                    return "取消收藏当前文章"
                end
                return "收藏当前文章"
            end,
            sorting_hint = "tools",
            callback = function()
                local article, issue_path = self:currentIssueArticle()
                if not article then
                    UIManager:show(InfoMessage:new{
                        text = "当前文章不支持收藏\n（未找到该期资讯的元数据）",
                        timeout = 3,
                    })
                    return
                end
                self:toggleFavorite(article, issue_path)
            end,
        }
    end
end

--- 打开「科技资讯」全屏首页（TouchMenu 单 tab；条目见 getHomeItems）
function TechNews:openHome()
    -- 首次使用：打开首页即引导选择订阅源（全局标记防 dofile 重载后重复弹出）
    if self:sourceSetting() == nil and not G_technews_sources_prompted then
        G_technews_sources_prompted = true
        UIManager:scheduleIn(0.2, function()
            self:promptSourceSelection()
        end)
    end

    -- 惰性加载：只有首页需要 TouchMenu（与 KOReader readermenu 同构）
    local TouchMenu = require("ui/widget/touchmenu")
    -- 全屏承载容器：CenterContainer 包一层，关闭时整层移除（参照 ReaderMenu:onShowMenu）
    local menu_container = CenterContainer:new{
        covers_header = true,
        ignore = "height",
        dimen = Device.screen:getSize(),
    }
    local home_menu = TouchMenu:new{
        width = Device.screen:getWidth(),
        -- TouchMenu 没有 title 字段（title 属于 Menu 部件）；tab 元信息（icon 等）
        -- 与条目同表：唯一 tab 的本体即首页 item_table，icon 是左上角唯一的 tab 按钮
        tab_item_table = { self:getHomeItems() },
        show_parent = menu_container,
    }
    home_menu.close_callback = function()
        UIManager:close(menu_container)
    end
    menu_container[1] = home_menu
    UIManager:show(menu_container)
end

--- 首页条目表（作为 TouchMenu 唯一 tab，同时充当 item_table）
-- 关闭时机（已核对 touchmenu.lua 的 TouchMenu:onMenuSelect）：普通 callback 条目是
-- 「先执行 callback、返回后才 closeMenu」（只有 tap_input 才是先关后跑）；抓取经
-- Trapper:wrap 在首个进度 yield 时立即返回、随即由 TouchMenu 关闭，故无需手动先关菜单，
-- 进度框与 ConfirmBox 都会显示在随后关闭的首页之上，不受影响。
function TechNews:getHomeItems()
    local items = {
        {
            text = "打开今日资讯",
            callback = function() self:openMergedIssue() end,
        },
        {
            text = "分源阅读",
            sub_item_table_func = function()
                -- 每次展开按当前启用集合生成（订阅源设置改动后立即生效）
                local source_items = {}
                for _, source in ipairs(subscriptions.enabled(registry, self:sourceSetting())) do
                    source_items[#source_items + 1] = {
                        text = source.menu_label or (source.name .. " · 今日资讯"),
                        callback = function() self:openIssue(source.id) end,
                    }
                end
                return source_items
            end,
        },
        {
            text = "订阅源设置",
            keep_menu_open = true,
            sub_item_table_func = function()
                return self:getSourceSettingItems()
            end,
        },
        {
            text = "包含图片",
            keep_menu_open = true,
            check_callback_updates_menu = true,
            checked_func = function() return self:withImages() end,
            callback = function(touchmenu_instance)
                G_reader_settings:saveSetting("technews_with_images",
                    not self:withImages())
                -- 切换后当天缓存作废，下次打开重新生成
                storage:clear_date(today_str())
                -- 带 check_callback_updates_menu 的条目由 callback 负责刷新勾选
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text = "重新抓取今日",
            callback = function() self:confirmRefetch() end,
        },
        {
            text = "清理全部缓存",
            callback = function() self:confirmClearCache() end,
        },
        {
            text = "关于",
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = "科技资讯订阅 v" .. self.version
                        .. "\n\n作者：Isword先生\n数据来源：IT之家 等 6 个订阅源\n内容仅供个人阅读学习。",
                })
            end,
        },
    }
    -- 「我的收藏」紧跟「打开今日资讯」；「管理收藏」仅在确有收藏时出现
    table.insert(items, 2, {
        text = "我的收藏",
        sub_item_table_func = function()
            return self:getFavoriteItems()
        end,
    })
    if #favorites.load() > 0 then
        table.insert(items, 3, {
            text = "管理收藏",
            keep_menu_open = true,
            sub_item_table_func = function()
                return self:getFavoriteManageItems()
            end,
        })
    end
    -- 单 tab 元信息：icon 为左上角 tab 按钮；text 供菜单搜索展示
    items.icon = "home"
    items.text = "科技资讯订阅"
    return items
end

--- 「订阅源设置」子菜单：每个登记源一个勾选项（勾选即生效并清今日缓存）
function TechNews:getSourceSettingItems()
    local items = {}
    for _, source in ipairs(registry) do
        items[#items + 1] = {
            text = source.name,
            keep_menu_open = true,
            check_callback_updates_menu = true,
            checked_func = function()
                return subscriptions.is_enabled(source, self:sourceSetting())
            end,
            callback = function(touchmenu_instance)
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
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        }
    end
    items[#items + 1] = {
        text = "勾选即生效；改动会清除今日缓存",
        enabled = false,
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
                    os.date("%m-%d", entry.favorited_at or 0)),
                callback = function()
                    self:openEpub(entry.file)
                end,
            }
        end
    end
    if #items == 0 then
        items[1] = { text = "暂无收藏", enabled = false }
    end
    return items
end

--- 「管理收藏」子菜单：逐条确认删除；删除后重建条目表以反映成员变化
function TechNews:getFavoriteManageItems()
    local ConfirmBox = require("ui/widget/confirmbox")
    local items = {}
    for _, entry in ipairs(favorites.load()) do
        items[#items + 1] = {
            text = string.format("%s · %s", entry.title,
                os.date("%m-%d", entry.favorited_at or 0)),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
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
                        if touchmenu_instance then
                            touchmenu_instance.item_table = self:getFavoriteManageItems()
                            touchmenu_instance:updateItems(1)
                        end
                    end,
                })
            end,
        }
    end
    if #items == 0 then
        items[1] = { text = "暂无收藏", enabled = false }
    end
    return items
end

--- 首次使用引导：多选订阅源（确定后保存，取消不保存）
function TechNews:promptSourceSelection()
    local setting = self:sourceSetting()
    local checked = {}
    for _, source in ipairs(registry) do
        if subscriptions.is_enabled(source, setting) then
            checked[source.id] = true
        end
    end
    UIManager:show(SourceSelectDialog:new{
        sources = registry,
        checked = checked,
        on_confirm = function(set)
            self:setSourceSetting(set)
            UIManager:show(InfoMessage:new{
                text = "订阅源已保存",
                timeout = 2,
            })
        end,
    })
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
    -- 今日窗口：严格本地 0 点起（不回补旧条目）
    local result, n_today = window.filter(items, limit or source.max_items)
    if #result == 0 then
        return nil, "今日暂无新条目"
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
            local per_item = source.max_images_per_item -- nil = 不限（取全部图片）
            local count = 0
            for _, block in ipairs(item.blocks) do
                if block.img and (not per_item or count < per_item) then
                    if not seen[block.img] then
                        seen[block.img] = true
                        pending[#pending + 1] = { url = block.img }
                    end
                    count = count + 1
                end
            end
        end
        -- 合并模式下由调用方传入剩余额度，单源时用整期上限
        local cap = (progress and progress.image_budget) or MAX_IMAGES_PER_ISSUE
        if cap < 0 then cap = 0 end
        local total = math.min(#pending, cap)
        for i = 1, total do
            local url = pending[i].url
            local msg = string.format("%s下载图片 %d/%d…（点击可取消）",
                prefix, i, total)
            if not Trapper:info(msg) then
                return nil, "已取消"
            end
            -- IT之家图片让 BCE CDN 缩放（宽 800）；原 URL 自带的
            -- x-bce-process 必须被替换而非追加，否则 CDN 忽略新参数返回原图
            local target = imgurl.rewrite(url, 800) or url
            local data, img_err = download_image(target)
            -- 超高图缩到 800 宽会超出 CDN 边长上限（HTTP 400），降级 480 重试
            if not data and img_err and img_err:find("HTTP 400", 1, true) then
                local fallback = imgurl.rewrite(url, 480)
                if fallback then data = download_image(fallback) end
            end
            if data and #data > 0 then
                images[url] = { data = data, ext = image_ext(url) }
            end
        end
        logger.info("technews images:",
            source.id,
            "pending=" .. tostring(#pending),
            "downloaded=" .. tostring(total),
            "cap=" .. tostring(cap))
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
    for _ in pairs(images or {}) do
        image_count = image_count + 1
    end
    UIManager:show(InfoMessage:new{
        text = string.format("下载完成 · %d 条资讯 · %d 张图片", #items, image_count),
        timeout = 2,
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
-- 判定链：有文档 → 文档旁有可读 sidecar → 定位当前章节标题 → 与 sidecar 条目精确匹配。
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
    for _, item in ipairs(meta.items) do
        if item.title == title then
            return item, issue_path
        end
    end
    return nil
end

--- 收藏/取消收藏当前文章（阅读器菜单入口）；收藏过程在 Trapper 协程内进行。
function TechNews:toggleFavorite(article, issue_path)
    local entry = favorites.find(article.title)
    if entry then
        favorites.remove(entry)
        UIManager:show(InfoMessage:new{
            text = "已取消收藏",
            timeout = 2,
        })
        return
    end
    logger.info("technews favorite:", article.title, issue_path)
    Trapper:wrap(function()
        Trapper:info("收藏中…（点击可取消）")
        local added, err = favorites.add(article, issue_path, function(text)
            return Trapper:info(text)
        end)
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

--- 打开单个源的今日资讯（缓存优先）
function TechNews:openIssue(source_id)
    local source = source_by_id(source_id)
    if not source then return end
    local date = today_str()
    if storage:epub_exists(source.id, date) then
        self:openEpub(storage:epub_path(source.id, date))
        return
    end
    Trapper:wrap(function()
        local bundle, err = self:fetchSource(source)
        if not bundle then
            Trapper:clear()
            if err == "已取消" then
                self:showCancelled()
                return
            end
            self:showFetchError(err, function() self:openIssue(source_id) end)
            return
        end
        local title = string.format("%s · %s", source.name, date)
        self:buildAndOpen(source.id, title, date, bundle.items, bundle.images)
        -- 结束立即收起进度消息（Trapper 不会自动关闭，需显式 clear；KOReader 惯例）
        Trapper:clear()
    end)
end

--- 打开已启用源的合并今日资讯
function TechNews:openMergedIssue()
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
    local date = today_str()
    if storage:epub_exists("merged", date) then
        self:openEpub(storage:epub_path("merged", date))
        return
    end
    Trapper:wrap(function()
        local all = {}
        local all_images = {}
        local failed = {}
        local image_budget = MAX_IMAGES_PER_ISSUE
        for i, source in ipairs(sources) do
            local bundle, err = self:fetchSource(source, source.merge_max_items,
                { source_index = i, source_count = #sources,
                  image_budget = image_budget })
            if bundle then
                -- 合并期图片上限跨源共享：按实际下载数扣减剩余额度
                local used = 0
                for _ in pairs(bundle.images) do used = used + 1 end
                image_budget = math.max(image_budget - used, 0)
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
                logger.warn("technews merge source failed:",
                    source.id, tostring(err))
                failed[#failed + 1] = source.name
            end
        end
        if #all == 0 then
            Trapper:clear()
            self:showFetchError(
                table.concat(failed, "、") .. " 均不可用",
                function() self:openMergedIssue() end)
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
            logger.info("technews dedupe:",
                pair.kept.title, "|", pair.dropped.title, "|",
                ("%.2f"):format(dedupe.similarity(pair.kept.title, pair.dropped.title)))
        end
        logger.info("technews dedupe removed:",
            tostring(#removed), "of", tostring(#all))
        for _, pair in ipairs(dedupe.near_misses(kept, 0.6)) do
            logger.info("technews dedupe near-miss:",
                pair.a.title, "|", pair.b.title, "|",
                ("%.2f"):format(pair.similarity))
        end
        local title = "今日科技资讯 · " .. date
        self:buildAndOpen("merged", title, date, kept, all_images)
        Trapper:clear()
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
            -- 清缓存后立即重新抓取合并期（带进度显示），无需用户再手动打开
            self:openMergedIssue()
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
