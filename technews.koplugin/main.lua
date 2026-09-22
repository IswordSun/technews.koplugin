-- 科技资讯订阅 — 多源 RSS 订阅阅读器
--
-- 入口：
--   顶部菜单 → 科技资讯订阅 → 全屏首页（打开今日 / 分源阅读 / 设置）
--   手势/快捷菜单：Dispatcher 动作「科技资讯订阅」（直接打开合并今日）
--
-- 数据流：RSS/网页 → 内容块（文字+图片）→ 生成整期 EPUB → KOReader 原生阅读器
--
-- 自测钩子：环境变量 TECHNEWS_SELFTEST=1 时，启动 3 秒后自动打开「合并·今日」

-- 一次性守卫：插件经 dofile 重载会重置模块级变量，必须用全局记录
-- luacheck: globals G_technews_sources_prompted G_technews_end_patch G_technews_toc_patch

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
local updater = require("technews.updater")
local window = require("technews.window")

-- 全部可用订阅源（有序）；新增源只需在 sources/registry.lua 追加一行
local registry = require("technews.sources.registry")

-- 每期图片总量上限（安全阀：控制抓取时间与 EPUB 体积；每条默认取全部图片）
local MAX_IMAGES_PER_ISSUE = 150

local TechNews = WidgetContainer:extend{
    name = "technews",
    is_doc_only = false,
    version = "0.1.4",
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
    -- 上次在线更新若留下回滚副本，能走到这里说明新版本可用，清掉备份
    pcall(updater.cleanup_backup)
    self.ui.menu:registerToMainMenu(self)
    logger.info("technews initialized")

    -- 文档结束弹窗：本插件文档统一改用快捷菜单（其它文档保持 KOReader 原行为）。
    -- 插件经 dofile 重载，用全局标记保证补丁只安装一次。
    if not G_technews_end_patch then
        G_technews_end_patch = true
        local ConfirmBox = require("ui/widget/confirmbox")
        local ReaderStatus = require("apps/reader/modules/readerstatus")
        local orig_onEndOfBook = ReaderStatus.onEndOfBook
        ReaderStatus.onEndOfBook = function(rs, ...)
            local plugin = rs.ui and rs.ui.technews
            if plugin and plugin:isTechNewsDocument() then
                if G_reader_settings:isTrue("end_document_auto_mark") then
                    rs:markBook(true)
                end
                local top_widget = UIManager:getTopmostVisibleWidget() or {}
                if top_widget.name ~= "technews_end_prompt" then
                    UIManager:show(ConfirmBox:new{
                        name = "technews_end_prompt",
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
    if not G_technews_toc_patch then
        G_technews_toc_patch = true
        local ReaderToc = require("apps/reader/modules/readertoc")
        local Menu = require("ui/widget/menu")
        local orig_onShowToc = ReaderToc.onShowToc
        ReaderToc.onShowToc = function(toc, ...)
            local plugin = toc.ui and toc.ui.technews
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

--- 当前文档是否由本插件生成（路径判定：数据目录下的 technews/，覆盖缓存期与收藏快照）
function TechNews:isTechNewsDocument()
    local doc_file = self.ui and self.ui.document and self.ui.document.file
    return doc_file ~= nil and doc_file:find("/technews/", 1, true) ~= nil
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
    -- 阅读器菜单条目只在阅读「本插件生成」的文档时注册（见 isTechNewsDocument；
    -- 其它书籍不受打扰）。已核实：ReaderMenu 的 tab_item_table 一旦构建即缓存，
    -- addToMainMenu 每次阅读会话只被调用一次，故收藏文案需用 text_func 每次求值。
    if self:isTechNewsDocument() then
        menu_items.technews_favorite = {
            text_func = function()
                local ctx = self:currentFavoriteContext()
                if ctx and ctx.sub_favorited then
                    return "取消收藏当前小篇"
                end
                if ctx and ctx.whole_favorited then
                    return "取消收藏当前文章"
                end
                return "收藏当前文章"
            end,
            sorting_hint = "tools",
            callback = function()
                local ctx = self:currentFavoriteContext()
                if not ctx then
                    UIManager:show(InfoMessage:new{
                        text = "当前文章不支持收藏\n（未找到该期资讯的元数据）",
                        timeout = 3,
                    })
                    return
                end
                self:toggleFavorite(ctx.article, ctx.issue_path, ctx.section_index)
            end,
        }
        menu_items.technews_close = {
            text = "关闭并返回",
            sorting_hint = "tools",
            callback = function()
                self:closeDocumentAndReturn()
            end,
        }
    end
end

--- 打开「科技资讯」全屏首页（用 Menu 部件铺满全屏；条目见 getHomeItems）
function TechNews:openHome()
    -- 首次使用：打开首页即引导选择订阅源（全局标记防 dofile 重载后重复弹出）
    if self:sourceSetting() == nil and not G_technews_sources_prompted then
        G_technews_sources_prompted = true
        UIManager:scheduleIn(0.2, function()
            self:promptSourceSelection()
        end)
    end

    -- 首页已打开时不叠加：旧菜单的 close_callback 会把新引用置 nil
    if self._home_menu then return end

    -- 全屏页用 Menu 部件（文件列表/目录同款；TouchMenu 是系统菜单那种「顶部部分高度面板」）
    local Menu = require("ui/widget/menu")
    local home_menu = Menu:new{
        title = "科技资讯订阅",
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
            text = "打开今日资讯",
            -- keep_menu_open：抓取期间进度显示在首页之上，失败也能留在首页重试；
            -- 打开阅读器时由首页的 onShowingReader 正常收起（见 openHome）
            keep_menu_open = true,
            callback = function() self:openMergedIssue() end,
        },
        {
            text = "重新抓取今日",
            keep_menu_open = true, -- 取消「清除缓存」确认框后首页保持不丢
            callback = function() self:confirmRefetch() end,
        },
        {
            text = "我的收藏",
            sub_item_table_func = function()
                return self:getFavoriteItems()
            end,
        },
        {
            text = "分源阅读",
            sub_item_table_func = function()
                return self:getSourceReadItems()
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
                    text = "科技资讯订阅 v" .. self.version
                        .. "\n\n作者：Isword先生\n数据来源：IT之家 等 6 个订阅源\n内容仅供个人阅读学习。",
                })
            end,
        },
    }
end

--- 「分源阅读」子菜单：每次展开按当前启用集合生成（订阅源设置改动后立即生效）
function TechNews:getSourceReadItems()
    local items = {}
    for _, source in ipairs(subscriptions.enabled(registry, self:sourceSetting())) do
        items[#items + 1] = {
            text = source.menu_label or (source.name .. " · 今日资讯"),
            keep_menu_open = true, -- 抓取期间保持首页（同「打开今日资讯」）
            callback = function() self:openIssue(source.id) end,
        }
    end
    return items
end

--- 「订阅源设置」子菜单：每个登记源一个勾选项（勾选即生效并清今日缓存）
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
            callback = function()
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
            end,
        }
    end
    items[#items + 1] = {
        text = "勾选即生效；改动会清除今日缓存",
        select_enabled = false,
    }
    return items
end

--- 「设置」子菜单：管理收藏（仅有收藏时）、订阅源设置、包含图片、清理全部缓存
function TechNews:getSettingItems()
    local items = {}
    if #favorites.load() > 0 then
        items[#items + 1] = {
            text = "管理收藏",
            sub_item_table_func = function()
                return self:getFavoriteManageItems()
            end,
        }
    end
    items[#items + 1] = {
        text = "订阅源设置",
        sub_item_table_func = function()
            return self:getSourceSettingItems()
        end,
    }
    items[#items + 1] = {
        text = "包含图片",
        keep_menu_open = true,
        text_func = function()
            return (self:withImages() and "☑ " or "☐ ") .. "包含图片"
        end,
        callback = function()
            G_reader_settings:saveSetting("technews_with_images",
                not self:withImages())
            -- 切换后当天缓存作废，下次打开重新生成
            storage:clear_date(today_str())
        end,
    }
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
    items[#items + 1] = {
        text = "清理全部缓存",
        keep_menu_open = true,
        callback = function() self:confirmClearCache() end,
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
        items[1] = { text = "暂无收藏", select_enabled = false }
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
                os.date("%m-%d", entry.favorited_at or 0)),
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
    Dispatcher:registerAction("technews_quickmenu", {
        category = "none",
        event = "ShowTechNewsQuickMenu",
        title = "科技资讯快捷菜单",
        general = true,
    })
end

function TechNews:onShowTechNews()
    self:openMergedIssue()
end

--- 快捷菜单（Dispatcher 动作 technews_quickmenu；可绑定到双击等手势）
function TechNews:onShowTechNewsQuickMenu()
    local ButtonDialog = require("ui/widget/buttondialog")
    if not (self.ui and self.ui.document) then
        UIManager:show(InfoMessage:new{
            text = "在阅读科技资讯时可用快捷菜单",
            timeout = 2,
        })
        return true
    end
    -- Dispatcher 手势可在任意文档触发：非本插件文档必须拦下，避免「删除并返回」误删用户书籍
    if not self:isTechNewsDocument() then
        UIManager:show(InfoMessage:new{
            text = "该功能仅用于科技资讯内容",
            timeout = 2,
        })
        return true
    end
    -- 已经弹出时不叠加（⋯ 按钮在菜单显示期间仍可被点到）
    local top_widget = UIManager:getTopmostVisibleWidget() or {}
    if top_widget.name == "technews_quickmenu" then
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
        name = "technews_quickmenu",
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
        local fm_plugin = fm and fm.technews
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
        local fm_plugin = fm and fm.technews
        if fm_plugin then
            fm_plugin:openHome()
        else
            self:openHome()
        end
    end
    FileManager:showDeleteFileDialog(doc_path, post_delete_callback, pre_delete_callback)
end

-- 快捷按钮触摸区的覆盖列表：与 bookshelf 插件同款 + 右上角书签角
local QUICK_ZONE_OVERRIDES = {
    "tap_forward", "tap_backward",
    "readerhighlight_tap", "readerhighlight_tap_select_mode",
    "readerfooter_tap", "readermenu_tap", "readermenu_ext_tap",
    "tap_top_right_corner",
}

--- 阅读界面右上角的快捷菜单按钮（三个点）；仅本插件文档显示。
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
        face = Font:getFace("cfont", 22),
    }
    local dots_size = dots:getSize()
    local x, y = sw - dots_size.w - margin, top_offset + margin
    local area = math.max(dots_size.w, dots_size.h) + Screen:scaleBySize(16) -- 点击区比点大一圈
    self._quick_button = {
        paintTo = function(_, bb)
            dots:paintTo(bb, x, y)
        end,
    }
    self.ui.view:registerViewModule("technews_quickmenu_dots", self._quick_button)
    -- 触摸区只预建对象，稍后再注册（见 registerQuickMenuTouchZone）
    self._quick_zone = {
        id = "technews_quickmenu_tap",
        ges = "tap",
        screen_zone = {
            ratio_x = (sw - area - margin) / sw, ratio_y = (top_offset + margin) / sh,
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
            self.ui.view.view_modules.technews_quickmenu_dots = nil
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

    -- 2) 下载图片（可关闭；按整期总量设上限，单条不限）
    local images = {}
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
    for _, item in ipairs(meta.items) do
        if item.title == title then
            return item, issue_path
        end
        -- 标题命中某条目的文内小标题（二级目录条目）→ 返回该条目与小节序号
        local section_index = favorites.section_index(item, title)
        if section_index then
            return item, issue_path, section_index
        end
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

--- 当前收藏上下文：解析文章/小节与两级收藏状态（菜单文案与动作共用入口）。
-- 返回 { article, issue_path, section_index, sub, whole_favorited, sub_favorited }；无文章时 nil。
function TechNews:currentFavoriteContext()
    local article, issue_path, section_index = self:currentActionableArticle()
    if not article then return nil end
    local ctx = self:favoriteContext(article, section_index) or {}
    ctx.article = article
    ctx.issue_path = issue_path
    ctx.section_index = section_index
    return ctx
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
        name = "technews_favorite_choice",
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

--- 下载并安装更新（Trapper 协程内进行，带下载进度与取消）
function TechNews:installUpdate(release)
    local zip_path = storage.dir .. "technews-update.zip"
    Trapper:wrap(function()
        Trapper:info("正在下载 v" .. release.version .. "…（点击可取消）")
        local ok, err = updater.download(release.zip_url, zip_path, function(received)
            return Trapper:info(string.format("正在下载 v%s… %.1f MB（点击可取消）",
                release.version, received / 1048576))
        end)
        if not ok then
            Trapper:clear()
            UIManager:show(InfoMessage:new{
                text = "下载失败：" .. tostring(err),
                timeout = 4,
            })
            return
        end
        Trapper:info("正在安装 v" .. release.version .. "…")
        local installed, install_err = updater.install(zip_path, release.version)
        os.remove(zip_path) -- 安装成功与否都清掉下载文件（失败时也避免占空间）
        Trapper:clear()
        if not installed then
            UIManager:show(InfoMessage:new{
                text = "安装失败：" .. tostring(install_err),
                timeout = 5,
            })
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
