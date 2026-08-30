# Debug Session: ios-catalog-load-fail

**状态**: [OPEN]
**Session ID**: `ios-catalog-load-fail`
**开始时间**: 2026-08-30

## 症状

- 应用打开正常（不再崩溃）。
- 小说目录/内容加载提示 "Kết nối tới máy chủ thất bại"（连接服务器失败）。
- 登录正常（POST 不需要 Referer）。

## 环境

- iOS 真机 (LiveContainer)，WKWebView 加载 `https://sangtacviet.com/app.v2.php`。
- 注入脚本 (documentStart) 强制 STV 请求同源。
- 服务器行为（已实测）：GET 需要**存在非空 Referer**，否则返回空体 (size=0)；任何非空 Referer 均成功。

## 已确认事实（静态+curl）

1. 服务器行为（curl 实测）：GET 需**存在非空 Referer**，任何非空 Referer（同源/镜像域均可）→ 200 49786 字节；无 Referer → 200 size=0。POST 不需要。
2. **跨域 CORS（关键）**：页面 sangtacviet.com 发请求到镜像域 sangtacviet.app：
   - 带 Origin + x-stv-transport + Referer 的实际 GET → 200 49786，且返回 `Access-Control-Allow-Origin: https://sangtacviet.com`（**跨域被允许**）。
   - 但 **PREFLIGHT OPTIONS** 返回 `Access-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With` —— **`x-stv-transport` 不在白名单** → 若请求仍跨域，浏览器会拦截 preflight → onerror。
   - 结论：**跨域请求必须保持同源或去掉 x-stv-transport，否则被 preflight 拦**；同源请求则需 Referer。
3. `String.prototype.contain` 定义在 `stv.ui.js`。
4. `origin` 全局变量任何脚本无定义 → 依赖浏览器内建 `window.origin`。用户登录正常（POST 走 fullUrl），故 iOS 上 `window.origin` 可用，fullUrl 不抛错。
5. `checkDomains()` 异步填充 domains，时序上 fullUrl 可能切到镜像域 → D13 改回同源。

## 待验证假设（需 iOS 运行时证据）

- **H1**：iOS 同源 XHR **不带 Referer**（或空）→ 服务器返回空体 → 目录解析失败。
- **H2**：注入脚本未真正让请求同源，请求仍发到镜像域 → 跨域 preflight（x-stv-transport 不在 CORS 白名单）被拦 → onerror。
- **H3**：请求 URL 被改写错误（pathname/search 丢失）→ 请求 404/失败。
- **H4**：`applyPatch` 覆盖未生效（时序/引用）。
- **H5**：问题在响应处理（低优先级，curl 已证带 Referer 即成功）。

## 插桩状态

已推送 `8ded821`：注入 debugJS + `WKScriptMessageHandler("dbg")`，原生 print `[DBG:tag]` 到 Xcode 控制台。观测：init(window.origin)、xhr-open(原始URL)、xhr-send(responseURL=最终请求URL)、xhr-load(状态+大小)/xhr-error、patch(isDomainAlive 是否被覆盖)。

## 日志（运行时证据，用户从应用内日志面板复制）

- 所有 XHR 均同源（`https://sangtacviet.com`）→ 排除 CORS preflight 拦截（H2 排除）。
- 目录加载成功：`chapterlist` 返回 `status=200 size=120949`。
- **章节内容 readchapter 请求 `key=undefined` → 返回 `size=24`（即 `{"code":7}`）**。
- 登录成功、语言切换成功。

## 最终根因（已定位）

iOS 纯 Web 版 **没有 `window.Capacitor`**。线上 `app.v2.read.js` 的 `loadKeyFromServer`(535行) / `getContent2`(555行) 只在 `window.Capacitor.Plugins.Http` 存在时执行：

- 安卓有原生 Capacitor，会先调 `/io/grantcontext/context` 接口 `eval` 出章节 `chapterkey`，再带 key 请求 readchapter。
- iOS 无 Capacitor → `chapterkey` 保持 `undefined` → readchapter 返回 `{"code":7}` → 前端 throw "Device not supported" → 返回 "Kết nối tới máy chủ thất bại"。
- 服务器 `/io/grantcontext/context` 强制要求 `x-stv-transport: app` + `x-requested-with: com.sangtacviet.mobilereader` 头才返回 key 数据（node 实测：仅 app 头即可，298KB）。

## 修复方案 v2（已实施，待真机验证）

### v1 失败：注入 window.Capacitor（commit 1f4c279，已废弃）

v1 注入最小 `window.Capacitor` 桥接（Plugins.Http + getPlatform + App/StatusBar 等 stub），让 `loadKeyFromServer` 执行。

**实测失败（用户反馈"点击小说页面点不动，点不进小说详情"）**：注入 Capacitor 后，`app.v2.js` 第4412行 `if(window.Capacitor)` 让 `app.platform.isIOS=true`，走原生布局分支（4559行设 mainview 高度、**跳过 4566-4605 行 isWeb 分支的 CSS 变量设置**）→ 布局塌陷、首页点击无响应。日志证实：首页 searchBooks 加载成功（43309/39459 字节）、登录/语言正常，但点击书卡后无任何 detail/readchapter 请求。

### v2 方案：不注入 Capacitor + 覆写 loadKeyFromServer（当前）

**核心：不注入 window.Capacitor**，保持纯 Web 布局（恢复点击），只覆写 `app.reader.loadKeyFromServer`，用 XHR + app 头从 `/io/grantcontext/context` 获取并 eval 章节 key：

1. `capHttpXhr`：同源 XHR 请求 grantcontext，设置非 forbidden 头 `x-stv-transport: app` + `x-requested-with: com.sangtacviet.mobilereader`（服务器强制要求）。同源 XHR 自动携带完整 Referer/Cookie（满足服务器要求）。
2. 覆写 `app.reader.loadKeyFromServer(h,i)`：`ctx.chapterkey = eval(toEvaluate.data)`，与安卓原生第549行**逐字一致**。
3. 完整闭环：`getContent`（602-631行）→ `getKey`（610）→ 我的 `loadKeyFromServer` 设好 chapterkey → `getContent2`（555，无 Capacitor 故不执行返回 undefined）→ fallback 到第615行 `/?sajax=readchapter&...&key=${this.chapterkey}` 普通 XHR（同源带 Referer）→ **key 正确则章节可读**。
4. 时序：`setInterval` 轮询 `window.app.reader` 出现后覆写（app.v2.read.js 由 ui.scriptmanager 动态加载）。
5. 调试：`tryDbg` 通过 `dbg` handler 上报 `[DBG:key] type=... len=... head=...`，用户应用内日志面板可直接看到 key 获取结果。

**key 获取的验证依据**：混淆代码是 JSFuck/Unicode 风格 IIFE（`(()=>{var 藡锔...`，无字面 return，依赖浏览器 btoa/atob 等 API）。node vm 沙箱无法完美模拟浏览器环境检测，返回 undefined，**不构成真实环境反证**。WKWebView 是完整浏览器环境，与安卓 V8 行为一致，`eval` 应返回 key。待真机 `[DBG:key]` 日志确认。

## 结论

根因是 iOS 缺 Capacitor 原生网络层导致 key 无法获取。v2 方案移除 Capacitor 注入（恢复点击）并覆写 loadKeyFromServer（与安卓一致获取 key）。需真机验证：① 点击恢复正常；② 章节可读（`[DBG:key]` 显示有效 key）。
