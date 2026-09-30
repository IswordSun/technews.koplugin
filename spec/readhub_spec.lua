-- spec/readhub_spec.lua — Readhub 早报「条目区段」抽取（readhub.lua 的 daily_region）
--
-- 为什么值得测：旧实现取「首个 <article> 到最后一个 </article>」，
-- 页面改版后文末只要多出任何 <article> 区块（推荐位/评论），整段就会被当成正文吸进来。
-- 新实现按段校验结构（<h2> + /topic/ 链接），宁少勿滥。
-- 适配器顶层无 KOReader 依赖，可直接 dofile 加载。

local spec_dir = (arg and arg[0] or "spec/readhub_spec.lua"):match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = spec_dir .. "/../zhifou.koplugin"
local adapter = dofile(plugin_dir .. "/zhifou/sources/readhub.lua")
local daily_region = adapter.daily_region
assert(daily_region, "readhub.lua 应导出 daily_region 供单测")

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
    ok(actual == expected, name, ("实际=%s 期望=%s"):format(tostring(actual), tostring(expected)))
end

local function item(title, summary)
    return '<article class="mb-4"><h2><a href="/topic/abc">' .. title
        .. '</a></h2><p>' .. summary .. '</p></article>'
end

----------------------------------------------------------------------
-- 1) 正常页面：连续条目全部收进来
----------------------------------------------------------------------

do
    local html = '<html><body><nav>导航</nav>'
        .. item("标题一", "摘要一") .. item("标题二", "摘要二")
        .. '<footer>页脚</footer></body></html>'
    local region = daily_region(html)
    ok(region ~= nil, "有条目时返回区段")
    ok(region:find("标题一", 1, true) ~= nil, "含第一条")
    ok(region:find("标题二", 1, true) ~= nil, "含第二条")
    eq(region:find("导航", 1, true), nil, "不含导航")
    eq(region:find("页脚", 1, true), nil, "不含页脚")
end

----------------------------------------------------------------------
-- 2) 改版后的陷阱：条目后面又出现别的 <article>（推荐位）→ 必须截断
----------------------------------------------------------------------

do
    local html = item("标题一", "摘要一")
        .. '<article class="recommend"><h2>相关推荐</h2><p>别的文章</p></article>'
    local region = daily_region(html)
    ok(region:find("标题一", 1, true) ~= nil, "仍含真实条目")
    eq(region:find("相关推荐", 1, true), nil, "推荐位没被吸进来（旧实现会吸进来）")
    eq(region:find("别的文章", 1, true), nil, "推荐位正文没被吸进来")
end

----------------------------------------------------------------------
-- 3) 条目前面有噪音 article（导航块）→ 跳过，从真正的条目开始
----------------------------------------------------------------------

do
    local html = '<article class="nav"><p>站点导航</p></article>'
        .. item("标题一", "摘要一")
    local region = daily_region(html)
    ok(region ~= nil, "前面有噪音块时仍能取到条目")
    ok(region:find("标题一", 1, true) ~= nil, "含真实条目")
    eq(region:find("站点导航", 1, true), nil, "噪音块不在区段内")
end

----------------------------------------------------------------------
-- 4) 没有条目 → nil（调用方报「页面结构已变化」）
----------------------------------------------------------------------

do
    eq(daily_region('<html><body><p>空页面</p></body></html>'), nil, "无 article → nil")
    eq(daily_region('<article><p>只有文章容器没有标题链接</p></article>'), nil,
        "article 不含 <h2>+/topic/ → 视为无条目")
    eq(daily_region(nil), nil, "nil 输入 → nil")
    eq(daily_region(""), nil, "空串 → nil")
end

----------------------------------------------------------------------
print(("%d checks, %d failed"):format(checks, failed))
if failed > 0 then os.exit(1) end
