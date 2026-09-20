-- spec/htmltext_spec.lua — technews HTML → 内容块提取逻辑的单元测试
--
-- 覆盖 htmltext.blocks 的 v2 语义：
--   1) <p> 内图片照旧收集（IT之家/雷锋网 回归）
--   2) <figure> 内图片收集（少数派风格）
--   3) 不在任何 <p>/<figure> 内的独立 <img> 收集
--   4) 全部块按源码文档顺序排列，且同一张图不重复收集
--   5) 懒加载取址优先级、data: 与占位图/表情图跳过、drop 关键词、>=10 字符规则
--   6) 无 <p> 段落时沿用整体兜底（全文 + 全部图片）
-- 运行方式：bash scripts/run_specs.sh（或直接 luajit spec/htmltext_spec.lua）
-- 不依赖任何测试框架；所有断言通过时退出码为 0，否则为 1。

-- htmltext.lua 依赖 KOReader 的 util，这里注入恒等替身；样例均为无实体文本
local spec_dir = (arg and arg[0] or "spec/htmltext_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
package.preload["util"] = function() return { htmlEntitiesToUtf8 = function(s) return s end } end
local htmltext = dofile(spec_dir .. "/../technews.koplugin/technews/htmltext.lua")

----------------------------------------------------------------------
-- 极简断言工具
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

local function join(parts) return "{" .. table.concat(parts, ", ") .. "}" end

-- 把块序列序列化为 "T:文本" / "I:地址" 列表，便于精确断言顺序与内容
local function sig(blocks)
    local parts = {}
    for i, b in ipairs(blocks) do
        if b.img then
            parts[i] = "I:" .. b.img
        else
            parts[i] = "T:" .. b.text
        end
    end
    return join(parts)
end

-- 块序列中的图片地址列表
local function img_urls(blocks)
    local urls = {}
    for _, b in ipairs(blocks) do
        if b.img then urls[#urls + 1] = b.img end
    end
    return join(urls)
end

----------------------------------------------------------------------
-- 空输入
----------------------------------------------------------------------
do
    eq(#htmltext.blocks(nil), 0, "nil 输入返回空块表")
    eq(#htmltext.blocks(""), 0, "空字符串输入返回空块表")
end

----------------------------------------------------------------------
-- 回归：<p> 内图片收集（IT之家 / 雷锋网 风格）
----------------------------------------------------------------------
do
    local html = '<p>段落一：正文文字。</p>'
        .. '<p>段落二：正文<img src="https://ex.com/a.jpg">与图一，'
        .. '<img src="https://ex.com/b.jpg">与图二。</p>'
        .. '<p>段落三：正文文字。</p>'
    local blocks = htmltext.blocks(html, nil)
    eq(#blocks, 5, "段内图片：共 5 个块")
    eq(sig(blocks), join({
        "T:段落一：正文文字。",
        "T:段落二：正文与图一，与图二。",
        "I:https://ex.com/a.jpg",
        "I:https://ex.com/b.jpg",
        "T:段落三：正文文字。",
    }), "段内图片：文本与图片按段内顺序输出（旧行为回归）")
end

----------------------------------------------------------------------
-- <figure> 内图片收集（少数派风格）；figure 不产出文本块
----------------------------------------------------------------------
do
    local html = '<p>导语：正文文字。</p>'
        .. '<figure><img src="https://ex.com/fig.jpg"><figcaption>图注文字说明</figcaption></figure>'
    local blocks = htmltext.blocks(html, nil)
    eq(sig(blocks), join({
        "T:导语：正文文字。",
        "I:https://ex.com/fig.jpg",
    }), "figure 内图片被收集，figcaption 文本不产出块")
end

----------------------------------------------------------------------
-- 独立 <img>（不在 <p>/<figure> 内）收集，且按文档顺序排在段落之前
----------------------------------------------------------------------
do
    local html = '<div>前言文字，长度足够。</div>'
        .. '<img src="https://ex.com/loose.jpg">'
        .. '<p>正文段落，长度足够。</p>'
    local blocks = htmltext.blocks(html, nil)
    eq(sig(blocks), join({
        "I:https://ex.com/loose.jpg",
        "T:正文段落，长度足够。",
    }), "独立图片被收集；无 <p> 的 div 文本不产出块")
end

----------------------------------------------------------------------
-- 混合文档顺序：p 文本 → figure 图 → p 文本 → 独立图
----------------------------------------------------------------------
do
    local html = '<p>第一段文字，长度足够。</p>'
        .. '<figure><img src="https://ex.com/f1.jpg"></figure>'
        .. '<p>第二段文字，长度足够。</p>'
        .. '<img src="https://ex.com/loose2.jpg">'
    local blocks = htmltext.blocks(html, nil)
    eq(sig(blocks), join({
        "T:第一段文字，长度足够。",
        "I:https://ex.com/f1.jpg",
        "T:第二段文字，长度足够。",
        "I:https://ex.com/loose2.jpg",
    }), "混合文档：块序列严格按源码位置排列")
end

----------------------------------------------------------------------
-- 同一张图只收集一次
----------------------------------------------------------------------
do
    local html = '<p>段内唯一图片，正文足够长。<img src="https://ex.com/dup.jpg"></p>'
    local blocks = htmltext.blocks(html, nil)
    eq(sig(blocks), join({
        "T:段内唯一图片，正文足够长。",
        "I:https://ex.com/dup.jpg",
    }), "段内图片只收集一次（无重复）")

    -- 嵌套容器：<figure> 内嵌 <p>，图片同时落在两个 span 内
    local nested = '<figure><p>图内段落，正文足够长。<img src="https://ex.com/once.jpg"></p></figure>'
    local nested_blocks = htmltext.blocks(nested, nil)
    eq(sig(nested_blocks), join({
        "T:图内段落，正文足够长。",
        "I:https://ex.com/once.jpg",
    }), "嵌套 figure>p 时图片仍只收集一次")
end

----------------------------------------------------------------------
-- 取址优先级：data-original > data-src > src；data: 与占位图跳过
----------------------------------------------------------------------
do
    local html = '<p>懒加载优先<img data-original="https://ex.com/orig.jpg"'
        .. ' data-src="https://ex.com/dsrc.jpg" src="https://ex.com/src.jpg">，正文足够长。</p>'
        .. '<p>次选<img data-src="https://ex.com/dsrc2.jpg" src="https://ex.com/src2.jpg">，正文足够长。</p>'
        .. '<p>兜底<img src="https://ex.com/src3.jpg">，正文足够长。</p>'
        .. '<p>内联<img src="data:image/gif;base64,AAAA">，正文足够长。</p>'
        .. '<p>占位<img src="https://ex.com/v2/t.png">，正文足够长。</p>'
    local blocks = htmltext.blocks(html, nil)
    eq(img_urls(blocks), join({
        "https://ex.com/orig.jpg",
        "https://ex.com/dsrc2.jpg",
        "https://ex.com/src3.jpg",
    }), "取址优先级 data-original > data-src > src，data: 与 /v2/t.png 被跳过")
end

----------------------------------------------------------------------
-- WordPress 表情图片跳过（s.w.org …/images/core/emoji/…）
----------------------------------------------------------------------
do
    local html = '<p>表情<img src="https://s.w.org/images/core/emoji/15.0.1/svg/1f602.svg">'
        .. '与真图<img src="https://ex.com/real.jpg">，正文足够长。</p>'
    local blocks = htmltext.blocks(html, nil)
    eq(img_urls(blocks), join({ "https://ex.com/real.jpg" }),
        "表情图片被跳过，真实图片保留")
    eq(sig(blocks), join({
        "T:表情与真图，正文足够长。",
        "I:https://ex.com/real.jpg",
    }), "表情图所在段落文本仍正常产出")
end

----------------------------------------------------------------------
-- drop 关键词：命中段落文本被丢弃，段内图片连带丢弃
----------------------------------------------------------------------
do
    local html = '<p>正常段落，文字足够长。</p>'
        .. '<p>广告内容<img src="https://ex.com/ad.jpg">推荐，长度足够。</p>'
    local blocks = htmltext.blocks(html, { "广告" })
    eq(sig(blocks), join({ "T:正常段落，文字足够长。" }),
        "drop 关键词命中段落（含段内图片）整段丢弃")
end

----------------------------------------------------------------------
-- 段落 <10 字符（字节）不产出文本块
----------------------------------------------------------------------
do
    local html = '<p>123456789</p><p>1234567890</p>'
    local blocks = htmltext.blocks(html, nil)
    eq(sig(blocks), join({ "T:1234567890" }),
        "9 字节段落被过滤，满足 10 字节的段落保留")
end

----------------------------------------------------------------------
-- 无 <p> 段落时的整体兜底：全文 + 全部图片（含 figure 内与独立图）
----------------------------------------------------------------------
do
    local html = '<div>无段落结构，整体文字足够长。</div>'
        .. '<figure><img src="https://ex.com/fb1.jpg"></figure>'
        .. '<img src="https://ex.com/fb2.jpg">'
    local blocks = htmltext.blocks(html, nil)
    eq(sig(blocks), join({
        "T:无段落结构，整体文字足够长。",
        "I:https://ex.com/fb1.jpg",
        "I:https://ex.com/fb2.jpg",
    }), "无 <p> 时整体文本 + 全部图片按顺序兜底")
end

----------------------------------------------------------------------
-- <p> 内 <script> 被剥离，脚本内容不混入文本
----------------------------------------------------------------------
do
    local html = '<p>可见正文文字足够长<script>var tracker = "x";</script>，收尾。</p>'
    local blocks = htmltext.blocks(html, nil)
    eq(sig(blocks), join({ "T:可见正文文字足够长，收尾。" }),
        "段内 <script> 整段剥离")
    ok(not blocks[1].text:find("tracker", 1, true),
        "剥离后的文本不含脚本内容")
end

----------------------------------------------------------------------
-- 公共 API 冒烟：to_text 仍然可用
----------------------------------------------------------------------
do
    eq(htmltext.to_text("<p>甲<br>乙</p>"), "甲\n乙",
        "to_text 公共 API 行为不变（块级转换行）")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
