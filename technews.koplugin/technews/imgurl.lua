-- technews/imgurl.lua — 图片 URL 瘦身（CDN 缩放参数）
--
-- 外部服务事实（2026-09-20 实测，非显而易见，勿随意改动）：
-- 1) IT之家图片由百度 BCE CDN 提供，可用 x-bce-process 指令让 CDN 直接返回
--    缩放后的 JPEG，实测平均体积降约 80%。feed 里的原图 URL 已带
--    ?x-bce-process=image/format,f_auto，若再追加一个同名参数会被 CDN 忽略
--    （返回原始大图），因此必须整段替换原查询串（只留一个 ?）。
-- 2) 超高图（如 706x22389）缩到宽 800 后高度超过 CDN 边长上限 16384，
--    返回 HTTP 400；此时改用较小宽度（480）可正常返回，由调用方降级重试。
-- 3) CNBeta 的 static.cnbetacdn.com 实测不支持缩放参数，不做重写。

local imgurl = {}

-- 仅替换查询串的固定配方（宽 800 与降级 480 只差 w 值）
local RECIPE = "%s?x-bce-process=image/resize,m_lfit,w_%d,limit_1/quality,q_75"

--- 生成 CDN 缩放 URL。
-- @param url 原图 URL
-- @param width 目标最大宽度（像素）
-- @return 重写后的 URL；域名不可重写或参数缺失时返回 nil
function imgurl.rewrite(url, width)
    if not url or url == "" or not width then return nil end
    -- 只处理 http(s) 协议的 ithome.com 域名
    if not url:match("^https?://[^/]*ithome%.com/") then return nil end
    -- 丢掉原查询串与 fragment，避免第二个 x-bce-process 被 CDN 忽略
    local base = url:match("^[^?#]+")
    return string.format(RECIPE, base, width)
end

return imgurl
