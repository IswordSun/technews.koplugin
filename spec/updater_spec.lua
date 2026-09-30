-- spec/updater_spec.lua — 在线更新（updater.lua）纯逻辑单元测试
--
-- 覆盖：版本号解析/比较、候选 URL（直连在前+镜像在后，且仅放行本站地址）、
-- release 解析（草稿/预发布/非法 tag/缺 ZIP/体积超限）。
-- updater.lua 顶部的 zhifou.http 会 require LuaSocket/LuaSec/KOReader 模块，
-- 这里统一打桩，测试不触网、不落盘。
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/updater_spec.lua）

local spec_dir = (arg and arg[0] or "spec/updater_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = spec_dir .. "/../zhifou.koplugin"

package.preload["ltn12"] = function()
    return { sink = { file = function() end, table = function() end } }
end
package.preload["socket"] = function()
    return { skip = function() end, sleep = function() end }
end
package.preload["ssl.https"] = function() return { request = function() end } end
package.preload["socket.http"] = function() return { request = function() end } end
package.preload["socketutil"] = function() return {} end
package.preload["logger"] = function()
    return {
        info = function() end, warn = function() end,
        dbg = function() end, err = function() end,
    }
end
package.preload["json"] = function() return { decode = function() return nil end } end
package.path = plugin_dir .. "/?.lua;" .. package.path
local updater = require("zhifou.updater")

----------------------------------------------------------------------
-- 极简断言工具（与其它 spec 保持一致）
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
        ("expected=%s actual=%s"):format(tostring(expected), tostring(actual)))
end

----------------------------------------------------------------------
-- 版本号解析与比较
----------------------------------------------------------------------

do
    eq(table.concat(updater.parse_version("1.2.3"), "."), "1.2.3", "parse_version：标准三段")
    eq(table.concat(updater.parse_version("v0.1.4"), "."), "0.1.4", "parse_version：v 前缀")
    eq(updater.parse_version("1.2"), nil, "parse_version：两段非法")
    eq(updater.parse_version("1.2.3-beta"), nil, "parse_version：预发布后缀非法")
    eq(updater.parse_version(""), nil, "parse_version：空串非法")
    eq(updater.parse_version(nil), nil, "parse_version：nil 非法")
end

do
    eq(updater.compare_versions("0.1.4", "0.1.3"), 1, "compare：补丁位新")
    eq(updater.compare_versions("0.1.3", "0.1.4"), -1, "compare：补丁位旧")
    eq(updater.compare_versions("0.1.3", "0.1.3"), 0, "compare：相同")
    eq(updater.compare_versions("v1.0.0", "0.9.9"), 1, "compare：跨主版本（带 v）")
    eq(updater.compare_versions("nightly", "0.1.3"), nil, "compare：非法版本返回 nil")
    ok(updater.is_newer("0.1.4", "0.1.3"), "is_newer：更高为真")
    ok(not updater.is_newer("0.1.3", "0.1.3"), "is_newer：相同为假")
end

----------------------------------------------------------------------
-- 候选 URL：直连在前、镜像在后；仅放行本站 API / Release 前缀
----------------------------------------------------------------------

do
    local urls = updater.candidate_urls(updater.API_LATEST)
    eq(#urls, 1 + #updater.MIRRORS, "候选：API 地址 = 直连 + 全部镜像")
    eq(urls[1], updater.API_LATEST, "候选：直连排在第一位")
    for i = 2, #urls do
        ok(urls[i]:sub(-#updater.API_LATEST) == updater.API_LATEST,
            ("候选：第 %d 项为镜像前缀 + 原地址"):format(i))
    end

    local asset = updater.RELEASE_PREFIX .. "v0.1.4/zhifou.koplugin-v0.1.4.zip"
    eq(#updater.candidate_urls(asset), 1 + #updater.MIRRORS, "候选：Release 资产地址可用")
    eq(#updater.candidate_urls("https://evil.example.com/x.zip"), 0,
        "候选：站外地址被拒绝（防任意下载）")
    eq(#updater.candidate_urls(nil), 0, "候选：非字符串返回空表")
end

----------------------------------------------------------------------
-- release 解析
----------------------------------------------------------------------

local function release_fixture(overrides)
    local base = {
        tag_name = "v0.1.4",
        html_url = "https://github.com/IswordSun/zhifou.koplugin/releases/tag/v0.1.4",
        body = "更新说明",
        assets = {
            {
                name = "zhifou.koplugin-v0.1.4.zip",
                browser_download_url = updater.RELEASE_PREFIX .. "v0.1.4/zhifou.koplugin-v0.1.4.zip",
                size = 60000,
            },
        },
    }
    for key, value in pairs(overrides or {}) do base[key] = value end
    return base
end

do
    local release = updater.parse_release(release_fixture())
    ok(release ~= nil, "parse_release：正常发布可解析")
    eq(release.version, "0.1.4", "parse_release：版本号去掉 v 前缀")
    eq(release.zip_url, updater.RELEASE_PREFIX .. "v0.1.4/zhifou.koplugin-v0.1.4.zip",
        "parse_release：取到 ZIP 资产地址")

    eq(updater.parse_release(release_fixture({ draft = true })), nil, "parse_release：草稿拒绝")
    eq(updater.parse_release(release_fixture({ prerelease = true })), nil, "parse_release：预发布拒绝")
    eq(updater.parse_release(release_fixture({ tag_name = "nightly" })), nil,
        "parse_release：非法 tag 拒绝")
    eq(updater.parse_release(release_fixture({ assets = {} })), nil, "parse_release：缺 ZIP 资产拒绝")

    local evil = release_fixture({
        assets = { {
            name = "zhifou.koplugin-v0.1.4.zip",
            browser_download_url = "https://evil.example.com/x.zip",
            size = 60000,
        } },
    })
    eq(updater.parse_release(evil), nil, "parse_release：站外资产地址拒绝")

    local huge = release_fixture({
        assets = { {
            name = "zhifou.koplugin-v0.1.4.zip",
            browser_download_url = updater.RELEASE_PREFIX .. "v0.1.4/big.zip",
            size = updater.MAX_PACKAGE_BYTES + 1,
        } },
    })
    eq(updater.parse_release(huge), nil, "parse_release：体积超限拒绝")
end

----------------------------------------------------------------------
-- entry_rel_path：发行包条目的解压准入（安全边界）
-- 背景：KOReader 的 extractToPath 只设 ARCHIVE_EXTRACT_SECURE_NODOTDOT，
-- 不阻止创建符号链接 → 包内一个链接条目就能让后续条目写到插件目录之外。
----------------------------------------------------------------------

do
    local prefixes = { updater.ASSET_PREFIX, updater.LEGACY_ASSET_PREFIX }

    eq(updater.entry_rel_path("zhifou.koplugin/main.lua", "file", prefixes),
        "main.lua", "entry_rel_path：普通文件剥掉顶层目录")
    eq(updater.entry_rel_path("zhifou.koplugin/zhifou/epub.lua", "file", prefixes),
        "zhifou/epub.lua", "entry_rel_path：子目录文件保留相对路径")
    eq(updater.entry_rel_path("technews.koplugin/main.lua", "file", prefixes),
        "main.lua", "entry_rel_path：过渡期的旧顶层目录同样接受")
    -- 目录条目：不带尾斜杠的能落到暂存目录；带尾斜杠的相对路径为空 → 跳过
    -- （libarchive 解压文件时会自动建父目录，所以跳过目录条目不影响结果）
    eq(updater.entry_rel_path("zhifou.koplugin/zhifou", "directory", prefixes),
        "zhifou", "entry_rel_path：目录条目剥掉前缀后可用")
    local dir_rel, dir_reason = updater.entry_rel_path("zhifou.koplugin/", "directory", prefixes)
    eq(dir_rel, nil, "entry_rel_path：带尾斜杠的目录条目被跳过")
    eq(dir_reason, "empty-rel", "entry_rel_path：跳过原因标注为 empty-rel")

    local rel, reason = updater.entry_rel_path("zhifou.koplugin/zhifou", "link", prefixes)
    eq(rel, nil, "entry_rel_path：符号链接条目被拒（写穿防线）")
    eq(reason, "non-regular", "entry_rel_path：拒绝原因标注为 non-regular")
    eq(updater.entry_rel_path("zhifou.koplugin/dev", "other", prefixes), nil,
        "entry_rel_path：设备节点/未知类型被拒")

    eq(updater.entry_rel_path("zhifou.koplugin/../evil.lua", "file", prefixes), nil,
        "entry_rel_path：路径穿越被拒")
    eq(updater.entry_rel_path("other.koplugin/main.lua", "file", prefixes), nil,
        "entry_rel_path：不在已知顶层目录内被拒")
    eq(updater.entry_rel_path(nil, "file", prefixes), nil,
        "entry_rel_path：路径缺失被拒")
    -- 更老的 KOReader 不提供 mode 字段：按普通文件处理，保持向后兼容
    eq(updater.entry_rel_path("zhifou.koplugin/main.lua", nil, prefixes),
        "main.lua", "entry_rel_path：mode 缺失时按文件处理")
end

----------------------------------------------------------------------
-- 发布包摘要：解析 + 校验（防「下载走了镜像」被投毒）
----------------------------------------------------------------------

do
    local with_digest = updater.parse_release({
        tag_name = "v9.9.9", draft = false, prerelease = false,
        assets = { {
            name = "zhifou.koplugin-v9.9.9.zip", size = 1000,
            browser_download_url = "https://github.com/IswordSun/zhifou.koplugin/releases/download/v9.9.9/x.zip",
            digest = "sha256:ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        } },
    })
    ok(with_digest ~= nil, "带 digest 的 release 可解析")
    eq(with_digest and with_digest.zip_digest,
        "sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        "digest 被保留并转小写（带 sha256: 前缀）")

    local bad_digest = updater.parse_release({
        tag_name = "v9.9.9", draft = false, prerelease = false,
        assets = { {
            name = "x.zip", size = 1000,
            browser_download_url = "https://github.com/IswordSun/zhifou.koplugin/releases/download/v9.9.9/x.zip",
            digest = "md5:abcdef",
        } },
    })
    eq(bad_digest and bad_digest.zip_digest, nil, "非 sha256 的 digest 被忽略")

    local no_digest = updater.parse_release({
        tag_name = "v9.9.9", draft = false, prerelease = false,
        assets = { {
            name = "x.zip", size = 1000,
            browser_download_url = "https://github.com/IswordSun/zhifou.koplugin/releases/download/v9.9.9/x.zip",
        } },
    })
    ok(no_digest ~= nil, "老 API（无 digest 字段）仍可解析")
    eq(no_digest and no_digest.zip_digest, nil, "无 digest → nil（下载时仅校验魔数）")
end

do
    -- 注入一个假的 sha256（避免依赖 KOReader 的 ffi/sha2）
    updater._sha256 = function(data)
        -- 不是真摘要，只用来验证「读取文件 → 比对 → 报错」这条链路
        local sum = 0
        for i = 1, #data do sum = (sum + data:byte(i)) % 65536 end
        return string.format("%064x", sum)
    end
    local path = "/tmp/zhifou_digest_spec.bin"
    local f = assert(io.open(path, "wb"))
    f:write("hello")
    f:close()

    eq(updater.verify_digest(path, updater.sha256_hex("hello")), true,
        "摘要一致 → 通过")
    eq(updater.verify_digest(path, "sha256:" .. updater.sha256_hex("hello")), true,
        "带 sha256: 前缀也通过")
    local ok2, err2 = updater.verify_digest(path, updater.sha256_hex("other"))
    eq(ok2, nil, "摘要不符 → 失败")
    ok(tostring(err2):find("摘要不符", 1, true) ~= nil, "失败原因点明摘要不符", tostring(err2))
    local ok3, err3 = updater.verify_digest(path, "")
    eq(ok3, nil, "空摘要 → 失败（拒绝「无摘要」被当成通过）")
    ok(tostring(err3):find("未提供摘要", 1, true) ~= nil, "空摘要的原因明确", tostring(err3))
    local ok4 = updater.verify_digest("/tmp/zhifou_不存在.bin", "abc")
    eq(ok4, nil, "文件不存在 → 失败")
    os.remove(path)
    updater._sha256 = nil
end

----------------------------------------------------------------------
-- CA 包与 TLS 选项
----------------------------------------------------------------------

do
    local ca = updater.ca_bundle_path()
    ok(ca == nil or type(ca) == "string", "ca_bundle_path 返回路径或 nil")
    local tls = updater.tls_opts()
    ok(type(tls) == "table", "tls_opts 总返回表")
    if ca then
        eq(tls.verify_tls, true, "有 CA 包 → 开启证书校验")
        eq(tls.cafile, ca, "cafile 指向 CA 包")
    else
        eq(tls.verify_tls, nil, "无 CA 包 → 不开启校验（fail-open，保证仍能更新）")
    end
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
