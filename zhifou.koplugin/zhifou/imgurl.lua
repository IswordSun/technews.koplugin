-- zhifou/imgurl.lua — 图片 URL 瘦身（按图床套用 CDN 缩放参数）
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
-- 9) 转 JPG（lossy_recipe）是**最大的体积杠杆**：实测虎嗅 PNG 1.14MB → JPEG 141KB（8×）、
--    少数派 PNG 100KB → JPEG 22KB（4.6×）、IT之家 PNG 163KB → JPEG 127KB。这些源的图
--    多为截图，转 JPEG 视觉损失很小；GIF 转静态图不丢内容（KOReader 只显示首帧）。
-- 10) 灰度（gray_recipe）实测收益远小于转格式：虎嗅 141KB → 135KB（4%）、
--    爱范儿 17.8KB → 15.5KB（13%）。七牛用 imageMogr2 的 colorspace/Gray（返回 1 分量
--    真灰度 JPEG）；**百度 BCE 不支持灰度**（colorspace 返回 400 InvalidArgument），
--    故 IT之家只配 lossy_recipe。七牛 thumbnail/800x> 实测只缩不放（1600x> 对 1080 宽
--    的图原样返回），不会把小图放大。

local imgurl = {}

-- 七牛系（虎嗅/雷锋网/爱范儿/极客公园/少数派）共用配方：
-- imageView2 模式 2 = 等比缩到不超过目标宽且不放大（见上文 4）；
-- imageMogr2/thumbnail/<w>x> 用于需要 colorspace 的灰度场景（imageView2 不支持）。
local QINIU = "%s?imageView2/2/w/%d"
local QINIU_JPG = "%s?imageView2/2/w/%d/format/jpg/quality/75"
local QINIU_GRAY = "%s?imageMogr2/thumbnail/%dx>/format/jpg/quality/75/colorspace/Gray"

-- 各图床的重写规则：按顺序匹配，先匹配先赢。
-- host         = 匹配 URL 前缀的 Lua 模式，或模式数组（任一命中即算匹配；
--                Lua 模式没有 | 与分组量词，根域 + 子域这类“或”只能写成多模式）
-- recipe       = string.format 模板（参数：去掉查询串与 fragment 的基础 URL、宽度），
--                或函数 (base, width) -> url|nil（返回 nil 表示这张图不重写）
-- lossy_recipe = 可选：PNG/GIF 源改用它，让 CDN 直接输出 JPEG（体积大头）
-- lossy_ext    = 配合 lossy_recipe：哪些源后缀算「该转」（png/gif）
-- gray_recipe  = 可选：开启灰度时用它（未配置则回退 recipe/lossy_recipe）
local RULES = {
    {
        -- 主机须锚定：只匹配 ithome.com 根域或其子域（如 img.ithome.com）。
        -- 不能写成 [^/]*ithome%.com——"notithome.com" 这类前缀伪域会误命中
        host = {
            "^https?://ithome%.com/",
            "^https?://[%w%-%.]*%.ithome%.com/",
        },
        recipe = "%s?x-bce-process=image/resize,m_lfit,w_%d,limit_1/quality,q_75",
        lossy_recipe = "%s?x-bce-process=image/resize,m_lfit,w_%d,limit_1/quality,q_75"
            .. "/format,f_jpg",
        lossy_ext = { png = true, gif = true },
        -- 无 gray_recipe：BCE 不支持 colorspace（实测 400 InvalidArgument）
    },
    {
        -- 虎嗅：URL 自带 ?imageView2/2/w/1000/format/png/interlace,1，必须整段替换查询串
        host = "^https?://img%.huxiucdn%.com/",
        recipe = QINIU,
        lossy_recipe = QINIU_JPG,
        lossy_ext = { png = true, gif = true },
        gray_recipe = QINIU_GRAY,
    },
    {
        host = "^https?://static%.leiphone%.com/",
        recipe = QINIU,
        lossy_recipe = QINIU_JPG,
        lossy_ext = { png = true, gif = true },
        gray_recipe = QINIU_GRAY,
    },
    {
        host = "^https?://s3%.ifanr%.com/",
        recipe = QINIU,
        lossy_recipe = QINIU_JPG,
        lossy_ext = { png = true, gif = true },
        gray_recipe = QINIU_GRAY,
    },
    {
        host = "^https?://imgslim%.geekpark%.net/",
        recipe = QINIU,
        lossy_recipe = QINIU_JPG,
        lossy_ext = { png = true, gif = true },
        gray_recipe = QINIU_GRAY,
    },
    {
        host = "^https?://cdnfile%.sspai%.com/",
        recipe = QINIU,
        lossy_recipe = QINIU_JPG,
        lossy_ext = { png = true, gif = true },
        gray_recipe = QINIU_GRAY,
    },
    {
        -- 「一个」的配图（URL 无后缀，原图可达 3001x2000/792KB）：
        -- 实测 ?imageView2/2/w/800 → 800x533/37KB（21×），是七牛系 CDN
        host = "^https?://image%.wufazhuce%.com/",
        recipe = QINIU,
        lossy_recipe = QINIU_JPG,
        lossy_ext = { png = true, gif = true },
        gray_recipe = QINIU_GRAY,
    },
    {
        -- 知乎（zhimg）：JPEG 已是 _720w 缩略图，参数式缩放被 CDN 忽略（imageView2/
        -- imageMogr2 都无效），所以 JPEG 不重写；但 **GIF 换后缀 .gif→.jpg 会让 CDN
        -- 返回首帧静态 JPEG**（实测 8.6MB → 19.7KB、4.6MB → 59KB）。KOReader 对 GIF
        -- 本来就只渲染首帧，转静态无可见损失。
        host = "^https?://[%w%-%.]*%.zhimg%.com/",
        recipe = function(base)
            local still = base:gsub("%.gif$", ".jpg")
            if still == base then return nil end
            return still
        end,
    },
}

-- 抓图时需要携带 Referer 的图床（未列出的域名一律不带）。
-- 少数派：不带 Referer 返回 403；知乎 pic*.zhimg.com 同样需要（zhihudaily
-- 插件实测）；「一个」 image.wufazhuce.com 参考 one.koplugin 携带站点 Referer。
-- 其余图床（尤其微信 mmbiz.qpic.cn，带第三方 Referer 会返回 140x140 占位图）
-- 必须保持不带 Referer。
local REFERER_RULES = {
    { host = "^https?://cdnfile%.sspai%.com/", referer = "https://sspai.com/" },
    { host = "^https?://[%w%-%.]*%.zhimg%.com/", referer = "https://news-at.zhihu.com/" },
    { host = "^https?://[%w%-%.]*%.wufazhuce%.com/", referer = "https://wufazhuce.com/" },
}

--- 规则的主机模式是否命中 URL（host 为字符串或模式数组）。
local function host_matches(url, host)
    if type(host) == "table" then
        for _, pattern in ipairs(host) do
            if url:match(pattern) then return true end
        end
        return false
    end
    return url:match(host) ~= nil
end

--- 从 URL 路径取源图后缀（小写，jpeg→jpg）；取不到返回 nil
function imgurl.source_ext(url)
    if type(url) ~= "string" then return nil end
    local path = url:match("^[^?#]+") or url
    local ext = path:match("%.([%a%d]+)$")
    if not ext then return nil end
    ext = ext:lower()
    if ext == "jpeg" then ext = "jpg" end
    return ext
end

--- 生成 CDN 缩放 URL。
-- @param url 原图 URL
-- @param width 目标最大宽度（像素）
-- @param opts 可选 { gray = true } —— 优先选灰度配方（未配置的图床自动回退）
-- @return 重写后的 URL；域名不可重写或参数缺失时返回 nil
function imgurl.rewrite(url, width, opts)
    if not url or url == "" or not width then return nil end
    local gray = opts and opts.gray
    for _, rule in ipairs(RULES) do
        if host_matches(url, rule.host) then
            -- 丢掉原查询串与 fragment：两家图床的原参数都会被新配方整段替换，
            -- 追加第二个同名参数会被 CDN 忽略（返回原图）
            local base = url:match("^[^?#]+") or url
            -- 函数式配方：自行决定重写结果（返回 nil 表示这张图不重写）
            if type(rule.recipe) == "function" then
                return rule.recipe(base, width)
            end
            if gray and rule.gray_recipe then
                return string.format(rule.gray_recipe, base, width)
            end
            local ext = imgurl.source_ext(url)
            if rule.lossy_recipe and ext and rule.lossy_ext and rule.lossy_ext[ext] then
                return string.format(rule.lossy_recipe, base, width)
            end
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
        if host_matches(url, rule.host) then
            return rule.referer
        end
    end
    return nil
end

return imgurl
