# AGENTS.md：technews.koplugin 工作区

> 本文件是项目现场记录。任何新会话（人或 AI）读完即可恢复开发，无需重新考古。
> 最后更新：2026-09-20（首次创建）

## 0. 当前状态一句话版

- 项目：`technews.koplugin`，个人自用的 KOReader 插件。多源 RSS/网页 → 内容块（文字+图片）→ 整期 EPUB → KOReader 原生阅读器
- 核心链路可用：单源/合并、缓存、图片开关、菜单与手势入口都已就位
- 仓库仅本地：分支 `main`，**无 remote**；2026-09-20 共 9 个提交（基线 `4c962b0`，B 段体验打磨已完成）
- 模拟器插件副本与源码逐字一致（2026-09-20，`diff -rq` 通过）
- 测试与 lint 基建已就位：4 个 spec（123 项断言全绿：window/dedupe/imgurl/epub）、`scripts/run_specs.sh`、`.luacheckrc`（0 warning），命令见 §5
- B 段体验打磨 5/5 完成（进度细分、两源去重、图片瘦身、目录层级化）；摘要模式补全经调研取消（IT之家 RSS 描述即全文）
- 待办与已知问题见 §6

## 1. 目录地图

```
/Users/isword/DEV/Workspace/KOPlugin/technews/      ← git 仓库根（唯一代码源头）
├── AGENTS.md                                       ← 本文件
├── .gitignore                                      ← 忽略 .DS_Store、*.part
├── .omo/                                           ← opencode 运行态，非源码
├── spec/                                           ← Lua 规格测试（window_spec.lua），dev-only 不部署
├── scripts/                                        ← run_specs.sh，dev-only 不部署
└── technews.koplugin/                              ← 运行时插件（逐字镜像到模拟器/真机）
    ├── main.lua                                    ← 入口、菜单、抓取编排、设置
    ├── _meta.lua                                   ← 插件元信息
    ├── TODO.md                                     ← 活清单（状态见 §6）
    └── technews/
        ├── epub.lua                                ← 最小 EPUB3 构建（手写 ZIP + CRC32）
        ├── extract.lua                             ← 网页正文容器抽取
        ├── htmltext.lua                            ← HTML↔文本、图文内容块
        ├── http.lua                                ← HTTPS GET（带超时与重试）
        ├── rss.lua                                 ← RSS 2.0 解析、RFC822 时间
        ├── storage.lua                             ← 缓存目录、EPUB 路径、清理
        ├── window.lua                              ←「今日」时间窗口
        └── sources/{ithome,cnbeta}.lua             ← 各源适配器
```

关键分界：**只有 `technews.koplugin/` 会被部署**；`spec/`、`scripts/`、`AGENTS.md`、`.omo/`、`.git/` 都留在仓库里。

## 2. 数据流与来源

流程：`RSS/网页 → 内容块（{text=} / {img=url} 有序数组）→ 整期 EPUB → KOReader 原生阅读器`。
单源与合并都走同一条 `fetchSource → buildAndOpen` 路径，区别只在源的数量与 `issue_id`。

### 来源

| 源 | id | 模式 | feed | 单源条数 | 合并条数 | 回补阈值 | 每条图片 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| IT之家 | `ithome` | summary（RSS 描述已含完整 HTML） | https://www.ithome.com/rss/ | 60 | 30 | 15 | 1 |
| CNBeta | `cnbeta` | fulltext（逐篇抓文章页，失败回退描述） | https://rss.cnbeta.com.tw/ | 25 | 12 | 10 | 2 |

- 合并模式：两源混排，按时间戳倒序（无时间的排最后），`issue_id = "merged"`
- 合并时某源失败不致命：记录警告，只要还有条目就照常出刊
- CNBeta 逐篇抓正文较慢（25 条约 1~2 分钟）；IT之家单次请求即可

### 菜单（主菜单 → 科技资讯订阅）

| 菜单项 | 行为 |
| --- | --- |
| IT之家 · 今日新闻 | `openIssue("ithome")` |
| CNBeta · 今日资讯 | `openIssue("cnbeta")` |
| 合并 · 今日科技资讯 | `openMergedIssue()` |
| 包含图片（开关） | 默认开；切换后清当天缓存，下次打开重建 |
| 缓存 6 小时后自动更新（开关） | 默认关；开启后当天缓存超 6 小时则重抓 |
| 重新抓取今日 | 确认后清今日缓存 |
| 清理全部缓存 | 确认后删除全部缓存 EPUB |
| 关于 | 版本信息弹窗 |

- Dispatcher 动作：`technews_open`（event `ShowTechNews`，`general = true`）→ 打开合并版

### 设置键（`G_reader_settings`）

| 键 | 默认 | 判定方式 |
| --- | --- | --- |
| `technews_with_images` | `true` | `~= false` 即为开 |
| `technews_auto_refresh` | `false` | `== true` 才算开 |

### 自测钩子

- 环境变量 `TECHNEWS_SELFTEST=1`：启动 3 秒后自动打开「合并·今日」
- 用全局 `G_technews_selftest_done` 保证只触发一次。**必须用全局变量**：插件模块用 `dofile` 重载，模块级变量会随 UI 重建被重置

###「今日」语义

- 本地 0 点起（`window.local_midnight_ts`）的条目优先；不足 `min_items` 时向前回补
- 结果按时间戳倒序；无时间戳的条目视为最新

### 缓存

- 路径：`<KOReader 数据目录>/technews/<source_id>-<date>.epub`（`source_id` ∈ `ithome`/`cnbeta`/`merged`）
- `init()` 时调用 `cleanup(7)`：保留最近 7 天，并连带删除对应的 `.sdr` 阅读状态
- `clear_date(date)`：只删当天的 `.epub`；`clear_all()`：删除全部 `.epub`（两者均不处理 `.sdr`，见 §6-5）

## 3. 环境与模拟器

模拟器根目录：`/Users/isword/DEV/Workspace/KOPlugin/koreader-dev`

### 启动

- 双击 `启动KOReader模拟器.command`（内部执行 `./kodev run -W 900 -H 1200 -D 300`，即 900×1200 @300DPI，窗口置于外接显示器左侧）
- **再次双击 = 重启**：启动器会先结束已有实例；内部用 `/tmp/koreader-launch.lock` 防并发双击互踩
- 日志：`/tmp/koreader-launch.log`
- 首次或重新编译约需 10~30 秒

### 快捷键与产物

- **F8 = 截图**
- 截图落盘：`koreader-dev/koreader-emulator-arm64-apple-darwin24.6.0-debug/koreader/screenshots/`
- 运行数据：`koreader-dev/koreader-emulator-arm64-apple-darwin24.6.0-debug/koreader/`

### 给模拟器换插件版本（标准步骤）

```bash
cd /Users/isword/DEV/Workspace/KOPlugin/koreader-dev

# 1) 先备份现有副本（惯例命名 .before-<描述>-<短SHA>，当前短SHA 4c962b0）
cp -R plugins/technews.koplugin "plugins/technews.koplugin.before-<描述>-4c962b0"

# 2) 从源头镜像（--delete 清掉残留旧文件，避免幽灵 bug）
rsync -a --delete \
  /Users/isword/DEV/Workspace/KOPlugin/technews/technews.koplugin/ \
  plugins/technews.koplugin/

# 3) 重启模拟器实测
```

- 模拟器副本：`koreader-dev/plugins/technews.koplugin`（2026-09-20 与源码逐字一致）
- 在模拟器里临时改代码可以，但**记得回填源码**，仓库才是源头
- 同步**前**务必先做 `.before-` 备份，否则回滚无据

### 本机工具链

`luajit`（2.1）、`luacheck`（1.2）、`python3`，均在 `/opt/homebrew/bin`。

## 4. 标准开发流程

1. 在 `technews.koplugin/` 下改代码
2. 跑检查（见 §5），确认 `luacheck` 无告警
3. 按 §3 步骤同步到模拟器（先备份，再 `rsync --delete`）
4. 重启模拟器实测，用 F8 截图留证
5. 里程碑完成后更新 §6 与 `technews.koplugin/TODO.md`
6. 大操作（推送、删除、真机部署、清缓存）先与用户确认

## 5. 测试与检查

```bash
cd /Users/isword/DEV/Workspace/KOPlugin/technews

bash scripts/run_specs.sh        # Lua 规格测试（4 个 spec 文件，123 项断言）
luacheck technews.koplugin spec  # 静态检查（应为 0 warning / 0 error）
```

> `spec/`、`scripts/` 是 dev-only，**不会**随插件部署到模拟器或真机。

## 6. 已知问题与取舍

每条都注明文件位置，方便定位。以下为仍待处理的问题。

1. **构建内存风险**（`technews/epub.lua:44-68`）：整期内容常驻内存；`make_zip` 用 `table.concat` 把所有条目（含图片二进制）拼成一整块 zip 字符串，峰值约为图片字节数的 2 倍。低内存 Kindle 上有隐患。（2026-09-20 图片瘦身后载荷显著下降，峰值随之缓解；流式构建仍未做。）
2. **CRC32 纯 Lua 逐字节循环**（`technews/epub.lua:11-32`）：对整期图片载荷逐字节运算（IT之家图片缩放宽 800 后显著变小），真机上可能造成构建卡顿；需要基准测试。
3. **版本号漂移**（`main.lua:37` 对比 `163`）：`version` 字段是 `"0.1.0"`，「关于」弹窗却写 `v0.1`。
4. **CNBeta 域名重定向**（2026-09-20 发现，`technews/sources/cnbeta.lua`）：`www.cnbeta.com.tw` 全站（含旧 feed `backend.php` 与文章页）在境外出口 IP 下 302 跳转 MSN。旧 feed 已不可用，现改用 `https://rss.cnbeta.com.tw/`（内容同源、描述更全约 360 字 HTML）。境外网络（含本机模拟器）下文章页抓取会快速失败并回退到 RSS 描述；国内直连真机预期正常，**待真机确认**。

2026-09-20 已修复并验证（详见 git log）：取消语义统一（取消 = 整期中止 + 中性提示）、合并期图片上限跨源共享 50、`clear_date`/`clear_all` 同步清理 `.sdr`、删除无调用方的 `paragraphs` 链。

### TODO.md 状态摘要

以 `technews.koplugin/TODO.md` 为活清单，这里只做概览，不逐条重抄：

- **A 先做**（封面、缓存自动清理、图片开关即时生效、错误提示友好化、缓存过期自动更新）：5/5 完成
- **B 体验打磨**（今日时间窗口、抓取进度细分、两源去重、图片瘦身、目录层级化）：5/5 完成；摘要模式补全经调研取消（IT之家 RSS 描述即全文，见 §6 取舍记录）
- **C 成品化**（设置集中、真机验证、失败降级策略、版本化打包、i18n）：0/5 待办
- 末尾「已知取舍记录」记有：今日定义、时区（两家 RSS 的 pubDate 是真 GMT）、图片策略、CNBeta 逐篇抓取、合并条数、自测钩子

## 7. 代码约定与红线

- 注释用中文，标识符用英文；模块命名空间 `require("technews.x")`
- 与用户沟通用简体中文
- 本仓库仅本地 `main` 分支且**无 remote**，默认不推送
- 大操作（推送、删除、真机部署、清缓存）先征得用户确认
- 运行数据（模拟器/真机上的缓存与 `.sdr`）属现场生成物，不进仓库

## 8. 常用地址速查

| 用途 | 路径 |
| --- | --- |
| 仓库根（源头） | `/Users/isword/DEV/Workspace/KOPlugin/technews` |
| 运行时插件源码 | `.../technews/technews.koplugin` |
| TODO 活清单 | `.../technews/technews.koplugin/TODO.md` |
| 模拟器根 | `/Users/isword/DEV/Workspace/KOPlugin/koreader-dev` |
| 模拟器启动器 | `.../koreader-dev/启动KOReader模拟器.command` |
| 模拟器插件副本 | `.../koreader-dev/plugins/technews.koplugin` |
| 截图目录 | `.../koreader-dev/koreader-emulator-arm64-apple-darwin24.6.0-debug/koreader/screenshots/` |
| 启动日志 | `/tmp/koreader-launch.log` |

## 9. 维护本文件

- **何时更新**：来源或条数/图片策略变化；菜单项或设置键增删；缓存路径或保留期变化；已知问题增删或修复；目录结构变化（`spec/`、`scripts/` 落地或新模块出现）；版本号变更
- **更新哪些位置**：顶部日期、§0 状态、§2 来源与设置表、§3 模拟器副本状态、§6 已知问题与 TODO 摘要
- **分工**：本文件 = 环境与工作流现场；`technews.koplugin/TODO.md` = 逐条待办活清单；代码注释 = 实现细节
