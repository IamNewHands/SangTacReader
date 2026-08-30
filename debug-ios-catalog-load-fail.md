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

## 修复方案（已实施，待真机验证）

注入最小 `window.Capacitor` 桥接（仅 `Plugins.Http`，用 XHR 模拟并带 app 头），并补齐 `getPlatform()` + App/StatusBar/Share/Browser/Keyboard/MainClass 的安全 stub，避免 `app.v2.js` 初始化裸调用崩溃（第4413-4417行 `Capacitor.platform.toLowerCase()`、第4401行 `Capacitor.Plugins.App.getLaunchUrl()` 等）。同时保留 applyPatch 强制 networkManager/networkManagerXHR 同源。

效果：`loadKeyFromServer` 会执行 → `eval` grantcontext 得到 key → `getContent2` 带 key 请求 readchapter → 章节内容可读。

## 结论

根因是 iOS 缺 Capacitor 原生网络层导致 key 无法获取。方案是注入最小 Capacitor.Http 桥接（参考安卓原生行为），需真机验证章节阅读。
