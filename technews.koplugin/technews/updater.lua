-- technews/updater.lua — 在线更新（GitHub Releases + 国内镜像）
--
-- 流程：releases/latest → 取 .zip 资产 → 流式下载 → 解压到暂存目录 → 校验版本
-- → 备份并原子替换插件目录（失败回滚）→ 由调用方提示重启 KOReader。
-- 设计参考 weread.koplugin / bookshelf.koplugin 的更新器（见 AGENTS 记录）。
-- 除 http 外，KOReader 依赖一律在函数内 require：模块可在纯 Lua 下加载，便于单测。

local http = require("technews.http")

local updater = {}

updater.REPO = "IswordSun/technews.koplugin"
updater.API_LATEST = "https://api.github.com/repos/" .. updater.REPO .. "/releases/latest"
updater.RELEASE_PREFIX = "https://github.com/" .. updater.REPO .. "/releases/download/"
-- 国内镜像：直连不通时按序尝试（仅公开库可用；API 与资产下载都可前缀代理）
updater.MIRRORS = {
    "https://gh-proxy.com/",
    "https://ghfast.top/",
    "https://ghproxy.net/",
}
-- 发行包顶层目录（与 scripts/make_snapshot.sh 产出的 ZIP 结构一致）
updater.ASSET_PREFIX = "technews.koplugin/"
updater.MAX_PACKAGE_BYTES = 20 * 1024 * 1024

--- 版本号解析："1.2.3" / "v1.2.3" → {1,2,3}；非法（含预发布后缀）返回 nil
function updater.parse_version(value)
    local major, minor, patch = tostring(value or ""):match("^v?(%d+)%.(%d+)%.(%d+)$")
    if not major then return nil end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

--- 版本比较：a 新于 b 返回 1，相同 0，旧于 -1；任一非法返回 nil
function updater.compare_versions(a, b)
    local left, right = updater.parse_version(a), updater.parse_version(b)
    if not left or not right then return nil end
    for i = 1, 3 do
        if left[i] ~= right[i] then
            return left[i] > right[i] and 1 or -1
        end
    end
    return 0
end

--- 远端版本是否新于当前版本
function updater.is_newer(remote, current)
    return updater.compare_versions(remote, current) == 1
end

--- 候选 URL 列表：直连在前、镜像在后；仅放行本站 API 与 Release 前缀地址
-- （防止被伪造成任意地址下载）
function updater.candidate_urls(url)
    if type(url) ~= "string" then return {} end
    local allowed = url == updater.API_LATEST
        or url:sub(1, #updater.RELEASE_PREFIX) == updater.RELEASE_PREFIX
    if not allowed then return {} end
    local urls = { url }
    for _, prefix in ipairs(updater.MIRRORS) do
        urls[#urls + 1] = prefix .. url
    end
    return urls
end

--- 从 GitHub release 数据解析可用更新（纯函数）。
-- 约束：非 draft/prerelease、tag 形如 v1.2.3、含 .zip 资产、体积不超上限
function updater.parse_release(release)
    if type(release) ~= "table" or release.draft or release.prerelease then
        return nil, "发布包不可用（草稿或预发布）"
    end
    local version = tostring(release.tag_name or ""):gsub("^v", "")
    if not updater.parse_version(version) then
        return nil, "版本号格式不支持"
    end
    local zip_url, zip_size
    for _, asset in ipairs(release.assets or {}) do
        local name = tostring(asset.name or "")
        if name:sub(-4) == ".zip" then
            zip_url = asset.browser_download_url
            zip_size = tonumber(asset.size)
            break
        end
    end
    if not zip_url or #updater.candidate_urls(zip_url) == 0 then
        return nil, "发行包缺少可用的 ZIP 资产"
    end
    if zip_size and zip_size > updater.MAX_PACKAGE_BYTES then
        return nil, "发行包体积超出上限"
    end
    return {
        version = version,
        zip_url = zip_url,
        zip_size = zip_size,
        notes = release.body,
        page_url = release.html_url,
    }
end

--- 拉取最新 release（直连失败按镜像重试）；返回 release 表或 (nil, 错误信息)
function updater.fetch_latest_release()
    local JSON = require("json")
    local last_err
    for _, url in ipairs(updater.candidate_urls(updater.API_LATEST)) do
        local body, err = http.get(url, 15, 30, 1)
        if body then
            local ok, decoded = pcall(JSON.decode, body)
            if ok and type(decoded) == "table" then
                local release, parse_err = updater.parse_release(decoded)
                if release then return release end
                last_err = parse_err
            else
                last_err = "返回内容无法解析"
            end
        else
            last_err = err
        end
    end
    return nil, last_err or "网络不可用"
end

--- 下载发行包（按候选列表依次尝试）；on_progress 返回 false 可中止
function updater.download(zip_url, dest_path, on_progress)
    local last_err
    for _, url in ipairs(updater.candidate_urls(zip_url)) do
        local ok, err = http.download(url, dest_path, {
            on_progress = on_progress,
            max_bytes = updater.MAX_PACKAGE_BYTES,
        })
        if ok then return true end
        if err == "已取消" then return nil, err end
        last_err = err
    end
    return nil, last_err or "下载失败"
end

--- 插件目录（由本模块所在路径推导：…/plugins/technews.koplugin/technews/updater.lua）
function updater.plugin_dir()
    local source = debug.getinfo(1, "S").source or ""
    return source:match("^@?(.+)/technews/updater%.lua$")
end

local remove_tree
remove_tree = function(path)
    local ok_util, util = pcall(require, "ffi/util")
    if ok_util and util and util.purgeDir then
        if pcall(util.purgeDir, path) then return true end
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok_lfs and lfs) then return false end
    local mode = lfs.attributes(path, "mode")
    if not mode then return true end
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove_tree(path .. "/" .. entry)
            end
        end
        lfs.rmdir(path)
    else
        os.remove(path)
    end
    return true
end

--- 安装发行包：解压到暂存 → 校验版本 → 备份并原子替换（失败回滚）
function updater.install(zip_path, expected_version)
    local Archiver = require("ffi/archiver")
    local DataStorage = require("datastorage")
    local plugin_dir = updater.plugin_dir()
    if not plugin_dir then return nil, "无法定位插件目录" end

    local stage = DataStorage:getDataDir() .. "/technews/update-stage"
    remove_tree(stage)
    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then
        local open_err = reader.err
        reader:close()
        return nil, open_err or "无法打开发行包"
    end
    local prefix_len = #updater.ASSET_PREFIX
    local unpack_err
    for entry in reader:iterate() do
        local path = entry.path
        if type(path) == "string" and path:sub(1, prefix_len) == updater.ASSET_PREFIX then
            local rel = path:sub(prefix_len + 1)
            if rel ~= "" and not rel:find("%.%.") then
                if not reader:extractToPath(path, stage .. "/" .. rel) then
                    unpack_err = reader.err or "解压失败"
                    break
                end
            end
        end
    end
    reader:close()
    if unpack_err then
        remove_tree(stage)
        return nil, unpack_err
    end

    -- 校验暂存内容：main.lua 存在且版本号与发布版本一致
    local staged = stage .. "/technews.koplugin"
    local main_file = io.open(staged .. "/main.lua", "rb")
    if not main_file then
        remove_tree(stage)
        return nil, "发行包缺少 main.lua"
    end
    local content = main_file:read("*a")
    main_file:close()
    if content:match('version%s*=%s*"([^"]+)"') ~= expected_version then
        remove_tree(stage)
        return nil, "发行包版本校验失败"
    end

    -- 原子替换：旧目录改名备份 → 新目录改名就位；失败回滚
    local backup = plugin_dir .. ".backup"
    remove_tree(backup)
    if not os.rename(plugin_dir, backup) then
        remove_tree(stage)
        return nil, "无法备份现有插件目录"
    end
    if not os.rename(staged, plugin_dir) then
        os.rename(backup, plugin_dir)
        remove_tree(stage)
        return nil, "无法写入新版本（已回滚）"
    end
    remove_tree(stage)
    return true
end

--- 清理上次更新的回滚副本（插件能加载即说明新版本可用；init 时调用）
function updater.cleanup_backup()
    local plugin_dir = updater.plugin_dir()
    if not plugin_dir then return end
    local backup = plugin_dir .. ".backup"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.attributes(backup, "mode") then
        remove_tree(backup)
        require("logger").info("technews updater: removed rollback backup", backup)
    end
end

return updater
