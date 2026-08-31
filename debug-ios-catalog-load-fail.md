# Debug Session: ios-catalog-load-fail

**状态**: [OPEN]
**Session ID**: `ios-catalog-load-fail`
**开始时间**: 2026-08-30

## 症状

- 应用打开正常（不再崩溃）。
- 小说目录/内容加载提示 "Thiết bị không phù hợp hoặc phiên bản ứng dụng đã lỗi thời
Tải lại"（设备不兼容或应用版本已过时
重新下载）。
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

### v5 根因（决定性）：bridgeJS 整段因 Swift 字符串转义而 JS 语法错误，从未执行

**2026-08-31 新日志（error.txt）分析**：
- 应用不崩、登录/目录正常（chapterlist 200 size=122338）。
- readchapter 仍返回 size=24（code:7），且请求 URL 仍是
  `/?sajax=readchapter&...&key=undefined`——**未**被注入的
  XHR.readchapter 规范化补丁修正。
- `[DBG:patch] nm-exists; isDomainAlivePatched=false`：bridgeJS 的 patchNet 未生效。
- getContent 覆写未生效（日志无任何 `gc-` 输出）。

**根因**：`WebViewController.swift` 的 `bridgeJS` 是 Swift 普通 `"""` 多行字符串，
其中第 525 行写了 `'\n'`。Swift 会把 `\n` 编译成**真实换行符**，导致注入 WKWebView 的
JS 变成：

```js
dl('pop', 'hash=' + location.hash + '
' + (new Error().stack||'').split('
').slice(1,5).join('
'));
```

单引号字符串跨行 → **整个 bridgeJS 脚本 JS 语法错误，一行都不执行**（node 验证
`SYNTAX ERROR: Invalid or unexpected token`）。只有独立注入的 debugJS 正常打印日志。

**因此此前所有基于 bridgeJS 的修复（getContent 覆写 / XHR.readchapter 规范化 /
强制同源 patchNet / CSS 视口修复）从未真正执行过**——这就是反复失败、每次看起来
"没生效"的真正原因。readchapter 一直发 `key=undefined` 坏 URL → code:7。

**v5 修复（当前）**：把第 525 行改为 `'\\n'`（Swift 生成字面 `\n`），
node 验证修复后注入 JS 语法 OK。

修复后 bridgeJS 首次真正执行，以下机制将同时生效（双保险）：
1. `app.reader.getContent` 覆写：用正确格式 `?bookid&h&c&ngmar=readc&sajax=readchapter&sty=1&exts=`。
2. **XHR.open 兜底**：任何含 `readchapter` 的 URL 删 `key=undefined`、补 `ngmar/sty/exts`。
   （即使 getContent 覆写被前端动态加载的 app.v2.read.js 覆盖，兜底仍生效。）

### 待真机验证（重新编译含 v5 修复的包）

1. 章节正文可读取（readchapter 应返回 `code:0`，URL 不再带 `key=undefined`）。
2. 登录、语言切换、目录仍正常。

## v6 根因（决定性）：readchapter 带 `x-stv-transport: web` 头 → 服务器返回 code:7

**2026-08-31 v5 修复后真机新日志（error.txt）分析**：
- bridgeJS 首次真正执行：`[DBG:gc]` / `[DBG:gc-url]` / `[DBG:gc-code]` 全部出现。
- getContent 覆写生效，URL 已正确：`?bookid=1045345742&h=qidian&c=847372113&ngmar=readc&sajax=readchapter&sty=1&exts=`。
- 但 readchapter 仍返回 **code:7**，且 `REQ-HDRS={"x-stv-transport":"web"}`。
- 关键：**chapterlist（同走 app.net，同带 web 头）却成功**（200 size=122338）→ 说明 code:7 不是 UA 或网络层问题，而是 readchapter 独有的传输判定。

**根因（分析 app.v2.js 源码确认）**：
```js
// app.net.get() 内部强制给所有 GET 加 web 传输头
http.setRequestHeader("x-stv-transport", "web");
// 而安卓真实 App 走 Capacitor，用的是：
headers = {
    "x-stv-transport": "app",
    "x-requested-with": "com.sangtacviet.mobilereader",
    ...
}
```
readchapter 服务器按 `x-stv-transport` 区分传输方式：`app` → 正常返回正文；`web` → 判定"网页版已过时/设备不兼容"返回 code:7。UA 已改标准 Safari（v4），URL 已正确（v3+v5），剩余唯一差异就是**传输头**。

**v6 修复（当前）**：覆写 getContent 时不再用 `app.net.get()`（会强制 web 头），改用**原生 XHR 手动设置 App 客户端头**：
- `x-stv-transport: app`
- `x-requested-with: com.sangtacviet.mobilereader`
- `Referer: document.referrer || window.location.href`（显式补非空 Referer）

同源请求无 preflight，自定义头可正常发送。

### 待真机验证（v6）
1. readchapter 应返回 `code:0`（正文），REQ-HDRS 应显示 `x-stv-transport: app`。
2. 目录、登录、语言切换仍正常。

## v7 根因（决定性）：readchapter 必须带有效 `key`，且 key 由 grantcontext 下发混淆 JS 生成（无法在 Web 环境复现）

**2026-08-31 v6 修复后仍失败（error.txt）**：
- `x-stv-transport: app` 头已正确发送，URL 已正确，但仍返回 code:7。

**通过抓取 app.v2.read.js 源码 + 服务器多重实测，推翻 v5 的"key 不需要"结论**：

### 源码真相（app.v2.read.js 决定性）
```js
// 真实 App 流程（App 端才有 Capacitor.Plugins.Http）：
app.reader.loadKeyFromServer = async function(h,i){
    if(window.Capacitor && window.Capacitor.Plugins.Http){   // ← 仅 App 存在 Capacitor 才运行
        var toEvaluate = await context.get({
            url: fullUrl(bestDomain() + "/io/grantcontext/context?hostid="+h+"&bookid="+i),
            headers: { Cookie: document.cookie + "; mac_tt=true;", "x-stv-transport":"app", ... }
        });
        app.net.evalCookie(toEvaluate.headers);
        this.chapterkey = eval(toEvaluate.data);   // ← key = eval 服务器下发混淆 JS 的结果
    }
}
app.reader.getContent2 = async function(h,i,c,rl){
    if(window.Capacitor && window.Capacitor.Plugins.Http){
        var url = `/?sajax=readchapter&h=${h}&bookid=${i}&c=${c}&key=${this.chapterkey}`;  // ← 必须带 key
        ...
    }
}
```
- **纯 Web WKWebView 无 Capacitor → loadKeyFromServer 永不运行 → chapterkey 永远 undefined → key=undefined → code:7**。
- **服务器实测**：App 格式 `/?sajax=readchapter&h&bookid&c&key=`（key 空/缺）均返回 `{"code":7}`；`key` 确实必须。

### 服务器 grantcontext 混淆 JS 分析（node 三重验证）
- grantcontext 返回**超大混淆 JS**（因 session/cookie 变化：plain 321KB、带 `_ac`/`_gac` 297KB、两者都带 274KB）。
- 脚本为 **javascript-obfuscator 风格 IIFE**：`(()=>{var ...})()`，**无 `return` 关键字、无 window/Capacitor/document 引用**。
- node 精确复现（btoa/atob/RegExp/Date 全补）eval **返回 undefined**，仅设置两个全局 `_0x4d38`/`_0x8c0e`（字符串解码缓存）。
- 结论：**eval 返回 undefined** → 要么真实 App 设备/登录会话拿到的脚本不同（设备指纹绑定），要么该机制本身就不可在纯 Web 复现。**从抓包环境无法确定 key 是否能在真机 WKWebView 里生成**。

### 网页章节页（Crawler 参考项目，可工作）
Crawler（phantom-sea-limited/Crawler#sangtacviet）用 **导航到章节页** `/truyen/{ori}/1/{bookid}/{c}/` 抓 `contentbox` DOM，完全绕开 readchapter API 的 key。章节页内部用 `POST /index.php?bookid&h&c&ngmar=readc&sajax=readchapter&sty=1&exts=`（无 key），但其授权依赖**执行页面内联 JS 设置的 `_gac` cookie**（node 无法执行 JS，故 node 测试返回 code:"5"/7，真机浏览器可行）。

### 修复方案 v7（当前，已实施）
1. **保留自定义 loadKeyFromServer**：XHR 拉 grantcontext + eval，真机验证 `[DBG:gkey]` 能否拿到 key（若能则走原生 key 流程）。
2. **getContent 覆写改造**：先尝试 App 格式 `/?sajax=readchapter&...&key=`；若 `key` 无效 / code:7 / code:"5" → **导航到章节页** `/truyen/{h}/1/{bookid}/{c}/`（网页版可读，Crawler 同法）。
3. **移除全局 XHR.readchapter 的 ngmar/sty/exts 强制补全**（那是网页章节页格式，与 App 格式 key 冲突），仅清理字面 `key=undefined`。

### 待真机验证（v7）
1. `[DBG:gkey] key=...` 看 eval 是否真能返回有效 key（大概率 undefined）。
2. 若 key 无效 → 应自动导航到章节页并渲染正文。
3. 目录、登录、语言切换仍正常。
