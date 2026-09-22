-- spec/htmltext_spec.lua — technews HTML → 内容块提取逻辑的单元测试
--
-- 覆盖 htmltext.blocks 的 v2 语义：
--   1) <p> 内图片照旧收集（IT之家/雷锋网 回归）
--   2) <figure> 内图片收集（少数派风格）
--   3) 不在任何 <p>/<figure> 内的独立 <img> 收集
--   4) 全部块按源码文档顺序排列，且同一张图不重复收集
--   5) 懒加载取址优先级、data: 与占位图/表情图/评论头像跳过、drop 关键词、>=10 字符规则
--   6) h2/h3/h4 小标题、<li> 列表项、<figcaption> 图注产出带 kind 的文本块
--   7) 无 <p> 段落时沿用整体兜底（全文 + 全部图片）
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

-- kind 感知的块序列序列化："H:" 标题 / "B:" 列表项 / "C:" 图注 / "T:" 普通段落 / "I:" 图片
local function sigk(blocks)
    local tags = { heading = "H", bullet = "B", caption = "C" }
    local parts = {}
    for i, b in ipairs(blocks) do
        if b.img then
            parts[i] = "I:" .. b.img
        else
            parts[i] = (tags[b.kind] or "T") .. ":" .. b.text
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
-- <figure> 内图片与 <figcaption> 图注（少数派风格）
----------------------------------------------------------------------
do
    local html = '<p>导语：正文文字。</p>'
        .. '<figure><img src="https://ex.com/fig.jpg"><figcaption>图注文字说明</figcaption></figure>'
    local blocks = htmltext.blocks(html, nil)
    eq(sigk(blocks), join({
        "T:导语：正文文字。",
        "I:https://ex.com/fig.jpg",
        "C:图注文字说明",
    }), "figure 内图片与 figcaption 图注按文档顺序收集")

    local short = htmltext.blocks('<p>导语：正文文字。</p>'
        .. '<figure><img src="https://ex.com/fig2.jpg"><figcaption>短注</figcaption></figure>', nil)
    eq(sigk(short), join({
        "T:导语：正文文字。",
        "I:https://ex.com/fig2.jpg",
    }), "短图注（<10 字节）被过滤，图片仍保留")
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
-- 小标题：h2/h3/h4 按文档顺序产出 heading 块（不适用 >=10 字节规则）
----------------------------------------------------------------------
do
    local html = '<p>第一段正文文字，长度足够。</p>'
        .. '<h2>章节标题甲</h2>'
        .. '<p>第二段正文文字，长度足够。</p>'
        .. '<h3>短题</h3>'
        .. '<h4>四级小标题乙</h4>'
        .. '<p>第三段正文文字，长度足够。</p>'
    local blocks = htmltext.blocks(html, nil)
    eq(sigk(blocks), join({
        "T:第一段正文文字，长度足够。",
        "H:章节标题甲",
        "T:第二段正文文字，长度足够。",
        "H:短题",
        "H:四级小标题乙",
        "T:第三段正文文字，长度足够。",
    }), "h2/h3/h4 与段落按文档顺序混排，短标题（<10 字节）也保留")
    eq(blocks[2].kind, "heading", "标题块 kind 为 heading")

    local empty = htmltext.blocks('<p>正文文字足够长。</p><h2></h2><h3>   </h3>', nil)
    eq(sig(empty), join({ "T:正文文字足够长。" }), "空标题（无有效文本）不产出块")
end

----------------------------------------------------------------------
-- 列表项：<li> 产出 bullet 块；<10 字节与内含 <p> 的列表项跳过
----------------------------------------------------------------------
do
    local html = '<p>导语段落文字，长度足够。</p>'
        .. '<ul><li>列表项一，文字足够长。</li><li>短</li>'
        .. '<li>列表项二，文字足够长。</li></ul>'
    local blocks = htmltext.blocks(html, nil)
    eq(sigk(blocks), join({
        "T:导语段落文字，长度足够。",
        "B:列表项一，文字足够长。",
        "B:列表项二，文字足够长。",
    }), "li 产出 bullet 块，<10 字节列表项被过滤")

    local nested = '<p>正文导语文字，长度足够。</p>'
        .. '<ul><li><p>列表内段落文字，足够长。</p></li></ul>'
    local nested_blocks = htmltext.blocks(nested, nil)
    eq(sigk(nested_blocks), join({
        "T:正文导语文字，长度足够。",
        "T:列表内段落文字，足够长。",
    }), "内含 <p> 的 li 整项跳过（其段落由 p 路径收集，无重复）")
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
-- sspai 评论头像缩略图跳过（thumbnail/!32x32r 与 /avatar/）
----------------------------------------------------------------------
do
    local html = '<p>正文文字足够长。<img src="https://cdn.sspai.com/thumbnail/!32x32r/abc.png">'
        .. '<img src="https://cdn.sspai.com/avatar/u123.jpg">'
        .. '<img src="https://cdn.sspai.com/realshot.jpg">收尾。</p>'
    local blocks = htmltext.blocks(html, nil)
    eq(img_urls(blocks), join({ "https://cdn.sspai.com/realshot.jpg" }),
        "评论头像缩略图被跳过，正文配图保留")
    eq(sig(blocks), join({
        "T:正文文字足够长。收尾。",
        "I:https://cdn.sspai.com/realshot.jpg",
    }), "头像所在段落的文本仍正常产出")
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
-- drop 关键词同样作用于标题 / 列表项 / 图注
----------------------------------------------------------------------
do
    local html = '<p>正常段落，文字足够长。</p>'
        .. '<h2>推广专区标题</h2>'
        .. '<ul><li>广告位列表项文字</li></ul>'
        .. '<h3>正常小节标题</h3>'
        .. '<figure><img src="https://ex.com/shot.jpg">'
        .. '<figcaption>广告图注说明文字</figcaption></figure>'
    local blocks = htmltext.blocks(html, { "推广", "广告" })
    eq(sigk(blocks), join({
        "T:正常段落，文字足够长。",
        "H:正常小节标题",
        "I:https://ex.com/shot.jpg",
    }), "命中 drop 关键词的标题/列表项/图注整块丢弃；figure 图片按 v2 规则独立收集")
end

----------------------------------------------------------------------
-- drop 关键词同样作用于图片 URL（评论头像 / 表情类社区图兜底）
----------------------------------------------------------------------
do
    local html = '<p>正常段落，文字足够长。</p>'
        .. '<p><img src="https://ex.com/community/avatar-1.png"/></p>'
        .. '<p><img src="https://ex.com/article/real-1.jpg"/></p>'
    local blocks = htmltext.blocks(html, { "community/" })
    eq(sig(blocks), join({
        "T:正常段落，文字足够长。",
        "I:https://ex.com/article/real-1.jpg",
    }), "drop：URL 命中关键词的图片被丢弃（评论头像/表情兜底），正文图保留")
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
