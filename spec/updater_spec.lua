-- spec/updater_spec.lua — 在线更新（updater.lua）纯逻辑单元测试
--
-- 覆盖：版本号解析/比较、候选 URL（直连在前+镜像在后，且仅放行本站地址）、
-- release 解析（草稿/预发布/非法 tag/缺 ZIP/体积超限）。
-- updater.lua 顶部的 technews.http 会 require LuaSocket/LuaSec/KOReader 模块，
-- 这里统一打桩，测试不触网、不落盘。
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/updater_spec.lua）

local spec_dir = (arg and arg[0] or "spec/updater_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = spec_dir .. "/../technews.koplugin"

package.preload["ltn12"] = function()
    return { sink = { file = function() end, table = function() end } }
end
package.preload["socket"] = function()
    return { skip = function() end, sleep = function() end }
end
package.preload["ssl.https"] = function() return { request = function() end } end
package.preload["socketutil"] = function() return {} end
package.preload["logger"] = function()
    return {
        info = function() end, warn = function() end,
        dbg = function() end, err = function() end,
    }
end
package.preload["json"] = function() return { decode = function() return nil end } end
package.path = plugin_dir .. "/?.lua;" .. package.path
local updater = require("technews.updater")

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

    local asset = updater.RELEASE_PREFIX .. "v0.1.4/technews.koplugin-v0.1.4.zip"
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
        html_url = "https://github.com/IswordSun/technews.koplugin/releases/tag/v0.1.4",
        body = "更新说明",
        assets = {
            {
                name = "technews.koplugin-v0.1.4.zip",
                browser_download_url = updater.RELEASE_PREFIX .. "v0.1.4/technews.koplugin-v0.1.4.zip",
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
    eq(release.zip_url, updater.RELEASE_PREFIX .. "v0.1.4/technews.koplugin-v0.1.4.zip",
        "parse_release：取到 ZIP 资产地址")

    eq(updater.parse_release(release_fixture({ draft = true })), nil, "parse_release：草稿拒绝")
    eq(updater.parse_release(release_fixture({ prerelease = true })), nil, "parse_release：预发布拒绝")
    eq(updater.parse_release(release_fixture({ tag_name = "nightly" })), nil,
        "parse_release：非法 tag 拒绝")
    eq(updater.parse_release(release_fixture({ assets = {} })), nil, "parse_release：缺 ZIP 资产拒绝")

    local evil = release_fixture({
        assets = { {
            name = "technews.koplugin-v0.1.4.zip",
            browser_download_url = "https://evil.example.com/x.zip",
            size = 60000,
        } },
    })
    eq(updater.parse_release(evil), nil, "parse_release：站外资产地址拒绝")

    local huge = release_fixture({
        assets = { {
            name = "technews.koplugin-v0.1.4.zip",
            browser_download_url = updater.RELEASE_PREFIX .. "v0.1.4/big.zip",
            size = updater.MAX_PACKAGE_BYTES + 1,
        } },
    })
    eq(updater.parse_release(huge), nil, "parse_release：体积超限拒绝")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
