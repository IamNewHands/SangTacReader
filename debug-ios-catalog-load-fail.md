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

## 最终根因（已通过真实登录会话 + Chrome 抓包精确定位）

### 决定性证据（真实登录会话，Chrome 抓包）

成功读取章节的请求格式（**不需要 key、不需要 grantcontext/eval**）：

```
/index.php?bookid={bookid}&h={源名}&c={章节}&ngmar=readc&sajax=readchapter&sty=1&exts=
```

返回 `{"code":"0","bookname":...,"chaptername":...,"data":"<p>..."}`。

**参数矩阵（真实会话实测）**：

| URL 变体 | 结果 |
|---|---|
| `?bookid&h=源名&c&ngmar=readc&sajax=readchapter&sty=1&exts=` | **code:0 正文** |
| 同上但 `h=数字`(hostid) | code:5 (4003) |
| 缺 `ngmar/sty/exts` | **code:7** |
| 带 `key=undefined` | **code:7** |

### 真相

1. **grantcontext 返回的 JSFuck 代码**（`(()=>{var 藡锔...})()`）**在任何环境 eval 均返回 undefined，且无任何副作用**（无全局变量、无 cookie、无网络请求）——已用 node、真实 Chrome file://、真实网站会话三重验证。`readcontextid` cookie 也不是 key。
2. **key 参数根本不需要**。真实成功请求不带 key。
3. **iOS 前端 `getContent`（online_app.v2.read.js 615行）构造的 `/?sajax=readchapter&h=&bookid=&c=&key=undefined` 缺 `ngmar=readc&sty=1&exts=` 且多带 `key=undefined` → 服务器返回 `{"code":7}` → 前端 throw "Device not supported" → 返回 "Kết nối tới máy chủ thất bại"**。
4. `h` 参数必须用**源名**（ciweimao），`app.reader.host` 已是源名（download 代码 3534 行 `h=${this.host}` 佐证）。
5. 安卓能工作是因为其 Capacitor.Http 走的 `x-stv-transport: app` 分支会**触发 key 相关循环**，而 web 分支的 code:7 处理（622行 `throw`）直接失败。**但真相是：即使没有 key，用正确的参数格式（ngmar/sty/exts/源名）也能成功读取。**

## 修复方案 v3（已实施，待真机验证）

### v1 失败：注入 window.Capacitor（commit 1f4c279，已废弃）

v1 注入最小 `window.Capacitor` 桥接，让 `loadKeyFromServer` 执行。**实测失败（用户反馈"点击点不动"）**：注入后 `app.v2.js` 4412行 `if(window.Capacitor)` 让前端走原生布局分支（跳过 isWeb 分支的 CSS 变量设置）→ 布局塌陷、点击无响应。

### v2 失败：覆写 loadKeyFromServer（commit 5f14f71，已废弃）

假设 `eval(grantcontext JSFuck)` 能拿到 key。**已证伪**：eval 在任何环境返回 undefined，且 key 根本不需要。

### v3 方案：覆写 `app.reader.getContent`（当前）

**不注入 Capacitor，保持纯 Web 布局**，只覆写 `app.reader.getContent`，用验证过的成功格式请求：

```js
/index.php?bookid={i}&h={h}&c={c}&ngmar=readc&sajax=readchapter&sty=1&exts=
```

- 强制用 `window.location.origin` 构造同源绝对 URL（避免 fullUrl 切镜像域触发跨域 preflight）
- 复用 `app.net.get`（同源 XHR + `x-stv-transport: web` 头，已验证可成功返回正文）
- 跳过 `getKey`（不需要 key）、跳过 `getContent2`（无 Capacitor 自动返回 undefined）
- 保留 `offlineBook` 逻辑和 `setTransMode()`
- 失败时回退原始逻辑
- 调试日志：`[DBG:gc] h=... i=... c=...`、`[DBG:gc-url]`、`[DBG:gc-code]`（确认 h 是否为源名、请求是否成功）

### 待真机验证

1. 章节正文可读取（`[DBG:gc-ok]` 显示长度）。
2. `[DBG:gc]` 中 `h=` 是否为源名（若为数字，需额外转换，返回会是 code:5）。

## 结论

根因不是"缺 Capacitor 拿不到 key"，而是**前端 readchapter 请求 URL 格式错误**（缺 `ngmar/sty/exts`、多带 `key=undefined`、路径/参数不符），服务器因此返回 code:7。v3 覆写 `getContent` 用真实会话验证过的成功格式请求，无需 key、无需 Capacitor。待真机确认。
