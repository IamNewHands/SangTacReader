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

### 最终根因（v4，决定性）：User-Agent 判定设备

同一本 `100490360` 同一章 `114882456` 的**完全相同 URL**，Chrome 返回 code:0（59668 字节正文），iOS WKWebView 返回 code:7（24 字节）——二者**唯一差异是 User-Agent**。

**Chrome 覆盖 UA 实测（决定性）**：DevTools Network conditions 把 UA 覆盖为 iOS 的
`Mozilla/5.0 (iPhone...) Mobile/15E148 SangTacVietApp/1.2.17` 后，同一个成功 URL **立即返回 code:7**；换回 Chrome 自带 UA 则 code:0。

**结论**：服务器通过 User-Agent 判定设备，带 `SangTacVietApp` 后缀的自定义 UA 被判为不受支持的设备 → readchapter 返回 code:7（Device not supported）。chapterlist 接口不校验设备所以此前能成功。

### 真相

1. **grantcontext 返回的 JSFuck 代码**（`(()=>{var 藡锔...})()`）**在任何环境 eval 均返回 undefined，且无任何副作用**——已用 node、真实 Chrome file://、真实网站会话三重验证。`readcontextid` cookie 也不是 key。
2. **key 参数根本不需要**。真实成功请求不带 key。
3. iOS 前端 getContent 构造的 URL 格式缺 `ngmar/sty/exts` 且带 `key=undefined` → code:7（已由覆写 getContent 修复为正确格式）。
4. **即使 URL 格式完全正确，iOS 仍因自定义 UA `SangTacVietApp` 被判为不受支持设备 → code:7**（这是 v3 修复后仍失败的真正原因）。
5. `h` 参数必须用**源名**（ciweimao），`app.reader.host` 已是源名。

## 修复方案 v4（已实施，待真机验证）

### v1 失败：注入 window.Capacitor（commit 1f4c279，已废弃）
### v2 失败：覆写 loadKeyFromServer（commit 5f14f71，已废弃）
### v3 部分成功：覆写 getContent（commit d3c4989）

覆写 `app.reader.getContent` 用正确格式 `?bookid&h=源名&c&ngmar=readc&sajax=readchapter&sty=1&exts=`（不带 key），同源请求。真机验证：**URL 已正确（h=ciweimao 源名），但 readchapter 仍返回 code:7** → 定位到 UA 是第二层根因。

### v4 修复：改回标准 iPhone Safari UA（当前）

`customUserAgent` 从 `...Mobile/15E148 SangTacVietApp/1.2.17` 改为 `...Mobile/15E148 Safari/604.1`（标准 iPhone Safari），去掉 app 后缀，服务器视其为 Safari 浏览器放行。

### 待真机验证

1. 章节正文可读取（`[DBG:gc-ok]` 显示长度）。
2. 登录、语言切换、目录仍正常（用 Safari UA 走纯 web 分支）。
