-- spec/gzip_spec.lua — gzip / zlib 解压（zhifou/gzip.lua）的单元测试
--
-- 为什么值得测：HTTP 打开 Accept-Encoding 后，服务端压缩过的响应必须能正确解开，
-- 否则上层拿到的是二进制乱码（解析失败得莫名其妙）。样本是 Python 生成的真实
-- gzip / zlib 流（hex 内嵌，避免源码里出现二进制字节）。
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/gzip_spec.lua）

local spec_dir = (arg and arg[0] or "spec/gzip_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = spec_dir .. "/../zhifou.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

local gzip = require("zhifou.gzip")

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
        ("实际=%s 期望=%s"):format(tostring(actual), tostring(expected)))
end

local function unhex(text)
    return (text:gsub("%x%x", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

----------------------------------------------------------------------
-- 样本（Python gzip.compress / zlib.compress 生成）
----------------------------------------------------------------------

local RAW = [[<?xml version="1.0"?><rss><channel><title>读首诗再睡觉</title>]]
    .. [[<item><title>测试条目</title><description>正文内容若干</description></item>]]
    .. [[</channel></rss>]]
local GZ_HEX = "1f8b08000000000002ffb3b1afc8cd51284b2d2acecccfb35532d43350b2b7b3292a2eb6b349ce48"
    .. "cccb4bcdb1b329c92cc949b57bb17ef7cb65d35eac9ffeb4adf7f9dc852f9677dae843646c324b527361ca9e"
    .. "6ded7eb17eeab3b90b9fcf5e075790925a9c5c94595002b4c3eed9dac5cfa6b53f6d6b7dba6ee78beea54f"
    .. "776eb2d14796b7d18718a70fb75f1fe41c000ca79487a9000000"
local ZLIB_HEX = "78dab3b1afc8cd51284b2d2acecccfb35532d43350b2b7b3292a2eb6b349ce48cccb4bcdb1b329c9"
    .. "2cc949b52b492d2eb1d187b06df4e192fa20b500506c184f"
local ZLIB_RAW = [[<?xml version="1.0"?><rss><channel><title>test</title></channel></rss>]]

local gz_data = unhex(GZ_HEX)
local zlib_data = unhex(ZLIB_HEX)
eq(#RAW, 169, "样本原文 169 字节（与生成时一致）")
eq(#gz_data, 153, "gzip 样本 153 字节")
ok(#gz_data < #RAW, "gzip 样本确实被压缩过")

----------------------------------------------------------------------
-- 1) 魔数判定
----------------------------------------------------------------------

do
    eq(gzip.window_bits(gz_data), 31, "window_bits：gzip 魔数 1f 8b → 31")
    eq(gzip.window_bits(zlib_data), 15, "window_bits：zlib 头 → 15")
    eq(gzip.window_bits("plain text"), -15, "window_bits：认不出 → 裸 deflate(-15)")
    eq(gzip.window_bits(""), -15, "window_bits：空串 → 裸 deflate")
end

----------------------------------------------------------------------
-- 2) 解压（真实样本，逐字节比对）
----------------------------------------------------------------------

do
    eq(gzip.available(), true, "zlib 可用（本机可加载 libz）")

    local plain, err = gzip.inflate(gz_data)
    eq(plain, RAW, "gzip 流解压结果与原文逐字节一致")
    eq(err, nil, "gzip 解压成功时无错误")

    local plain2, err2 = gzip.inflate(zlib_data)
    eq(plain2, ZLIB_RAW, "zlib 流解压结果与原文逐字节一致")
    eq(err2, nil, "zlib 解压成功时无错误")
end

----------------------------------------------------------------------
-- 3) 分块输出：小 chunk 也要拼回完整结果（覆盖多轮 inflate 循环）
----------------------------------------------------------------------

do
    local plain = gzip.inflate(gz_data, { chunk = 16 })
    eq(plain, RAW, "chunk=16 时仍拼出完整原文（多轮循环）")
    local plain2 = gzip.inflate(gz_data, { chunk = 1 })
    eq(plain2, RAW, "chunk=1 时仍拼出完整原文（极端分块）")
end

----------------------------------------------------------------------
-- 4) 异常输入：返回 nil + 原因，不抛错
----------------------------------------------------------------------

do
    local plain, err = gzip.inflate("")
    eq(plain, nil, "空数据 → nil")
    ok(err ~= nil, "空数据给出原因")

    -- gzip 头正确但数据体是垃圾
    local bad = unhex("1f8b08000000000002ff") .. "this is not deflate data"
    local plain2, err2 = gzip.inflate(bad)
    eq(plain2, nil, "损坏数据 → nil（不抛错）")
    ok(tostring(err2):find("解压失败", 1, true) ~= nil,
        "损坏数据的原因里含「解压失败」", tostring(err2))

    -- 截断：把 gzip 流砍掉后半段
    local truncated = gz_data:sub(1, math.floor(#gz_data * 0.6))
    local plain3, err3 = gzip.inflate(truncated)
    eq(plain3, nil, "截断数据 → nil（不返回半截结果）")
    ok(err3 ~= nil, "截断数据给出原因", tostring(err3))
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
