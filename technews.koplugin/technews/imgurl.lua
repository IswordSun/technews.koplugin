-- technews/imgurl.lua — 图片 URL 瘦身（按图床套用 CDN 缩放参数）
--
-- 外部服务事实（2026-09-20 实测，非显而易见，勿随意改动）：
-- 1) IT之家图片由百度 BCE CDN 提供，可用 x-bce-process 指令让 CDN 直接返回
--    缩放后的 JPEG，实测平均体积降约 80%。feed 里的原图 URL 已带
--    ?x-bce-process=image/format,f_auto，若再追加一个同名参数会被 CDN 忽略
--    （返回原始大图），因此必须整段替换原查询串（只留一个 ?）。
-- 2) 超高图（如 706x22389）缩到宽 800 后高度超过 CDN 边长上限 16384，
--    返回 HTTP 400；此时改用较小宽度（480）可正常返回，由调用方降级重试。
-- 3) 雷锋网图片由七牛 CDN 提供（static.leiphone.com），原 URL 自带
--    ?imageMogr2/quality/90；重写配方为丢弃原查询串后追加
--    ?imageView2/2/w/<width>。实测 1062x588/87319B → w/800 后 800x443/48886B。
-- 4) 雷锋网为何用 imageView2 而非 imageMogr2：imageView2 模式 2 等比缩到
--    不超过目标宽且不放大（实测 w/2000 对 1062 宽的图仍是 1062x588）；
--    而 imageMogr2/thumbnail/800x 会放大小图（1062→2000，体积反增到 166KB），
--    追加 quality 参数同样净增体积，故配方只留 w。
-- 5) CNBeta 的 static.cnbetacdn.com 实测不支持缩放参数，不做重写
--    （该源已停用，见 sources/cnbeta.lua）。
-- 6) 爱范儿 s3.ifanr.com、极客公园 imgslim.geekpark.net、少数派 cdnfile.sspai.com
--    三家图床均支持 ?imageView2/2/w/<width>（模式 2 等比缩到不超过目标宽且不放大），
--    配方与雷锋网相同。实测：ifanr 1200x675/87370B → 800x450/53KB；
--    geekpark 1080x607/311KB → 800x450/258KB；sspai 4440x2960/590KB → 800x533/34KB。
-- 7) 3 家中仅少数派图床需要防盗链 Referer：不带 Referer 直接 403，
--    补 Referer: https://sspai.com/ 才能取图（见 imgurl.referer）。
-- 8) 微信图床 mmbiz.qpic.cn（会出现在极客公园 feed 中）是反例：imageView2 参数被忽略、
--    路径式缩放也无效；且发送第三方 Referer（非微信域名）会返回 140x140 占位图。
--    故既不重写（下载原图）、由 imgurl.referer 返回 nil（不带 Referer）。

local imgurl = {}

-- 各图床的重写规则：按顺序匹配，先匹配先赢。
-- host   = 匹配 URL 前缀的 Lua 模式
-- recipe = string.format 模板（参数：去掉查询串与 fragment 的基础 URL、宽度）
local RULES = {
    {
        host = "^https?://[^/]*ithome%.com/",
        recipe = "%s?x-bce-process=image/resize,m_lfit,w_%d,limit_1/quality,q_75",
    },
    {
        host = "^https?://static%.leiphone%.com/",
        recipe = "%s?imageView2/2/w/%d",
    },
    {
        host = "^https?://s3%.ifanr%.com/",
        recipe = "%s?imageView2/2/w/%d",
    },
    {
        host = "^https?://imgslim%.geekpark%.net/",
        recipe = "%s?imageView2/2/w/%d",
    },
    {
        host = "^https?://cdnfile%.sspai%.com/",
        recipe = "%s?imageView2/2/w/%d",
    },
}

-- 抓图时需要携带 Referer 的图床（未列出的域名一律不带）。
-- 少数派：不带 Referer 返回 403；其余图床（尤其微信 mmbiz.qpic.cn，
-- 带第三方 Referer 会返回 140x140 占位图）必须保持不带 Referer。
local REFERER_RULES = {
    { host = "^https?://cdnfile%.sspai%.com/", referer = "https://sspai.com/" },
}

--- 生成 CDN 缩放 URL。
-- @param url 原图 URL
-- @param width 目标最大宽度（像素）
-- @return 重写后的 URL；域名不可重写或参数缺失时返回 nil
function imgurl.rewrite(url, width)
    if not url or url == "" or not width then return nil end
    for _, rule in ipairs(RULES) do
        if url:match(rule.host) then
            -- 丢掉原查询串与 fragment：两家图床的原参数都会被新配方整段替换，
            -- 追加第二个同名参数会被 CDN 忽略（返回原图）
            local base = url:match("^[^?#]+")
            return string.format(rule.recipe, base, width)
        end
    end
    return nil
end

--- 返回抓取该图片时应携带的 Referer；不需要或未知域名返回 nil。
-- 注：微信图床 mmbiz.qpic.cn 明确返回 nil——带第三方 Referer 会得到 140x140 占位图。
function imgurl.referer(url)
    if not url or url == "" then return nil end
    for _, rule in ipairs(REFERER_RULES) do
        if url:match(rule.host) then
            return rule.referer
        end
    end
    return nil
end

return imgurl
