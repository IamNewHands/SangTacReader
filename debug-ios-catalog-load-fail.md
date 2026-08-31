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

## v8（真机验证结果）：章节页触发 Cloudflare Turnstile 挑战，readchapter 返回 code:7 -> 无限 reload

**2026-08-31 真机日志 log.txt 分析**：
1. grantcontext eval 返回 undefined（`[DBG:gkey] key=undefined`）→ App 格式 readchapter `key=` 空 → **code:7**。证实 App key 机制不可复现。
2. 自动导航到章节页 `/truyen/qidian/1/1034915599/850838603/`。
3. 章节页 web readchapter（POST `/index.php?...ngmar=readc&sajax=readchapter&sty=1&exts=`）返回 **size=22/24 = `{"code":7,"time":1000}`** → 触发页面 `if(x.code=="7"){ ... location.reload() }`（章节页源码 line 761-778）→ **无限 1 秒 reload 循环**（用户所见"一直加载不停刷新"）。
4. 期间加载 **Cloudflare Turnstile**（`challenges.cloudflare.com`）并 POST `verifyca`（size=7，OK），但 readchapter 仍 code:7。

### 决定性根因
- **章节正文受 Cloudflare Turnstile 反爬保护**。readchapter 需在 Turnstile 完成并签发 `cf_clearance`/`_gac` 证明后才放行，否则返回 code:7（设备不支持/未认证）。
- **node 实测**（仅获取 `_gac` cookie 而无页面 JS 生成的证明）：返回 `code:"5"` err `4002`（"Lỗi không xác định, mã 4002"），与真机 code:7 不同 → 两者都是"缺少 Turnstile 证明"的不同拒绝码。
- **UA 无关**：iOS Safari / 桌面 Chrome / 安卓 Chrome 三 UA 结果相同。
- **readcontextid cookie 不是 key**：直接当 key 用返回 code:7。

### 修复 v8（已实施）：forMainFrameOnly=true
- **嫌疑**：bridgeJS/debugJS 以 `forMainFrameOnly:false` 注入到**所有 iframe，包括 Cloudflare Turnstile 挑战 iframe**（日志可见大量 `origin=https://challenges.cloudflare.com` 的 `[DBG:ready] instrumentation installed`）。若我们覆写挑战 iframe 内的 XHR，会破坏 Turnstile 挑战计算 → 永不完成 → cf_clearance 不签发 → readchapter code:7 → reload 循环。
- **修改**：`bridgeScript` 与 `debugScript` 均改为 `forMainFrameOnly: true`，只在主框架注入，避免污染第三方/Cloudflare iframe。
- bridgeJS/debugJS 语法已用 node vm.Script 验证通过；Swift 无诊断错误。

### 待真机验证（v8）
1. 章节页不再无限 reload，正文能渲染（Turnstile 在主框架正常运行）。
2. 目录、登录、语言切换仍正常。
3. 若仍 code:7，则说明 WKWebView/LiveContainer 环境本身被 Cloudflare 判定为异常（非 iframe 污染），需另行评估（如替换为可过 CF 的浏览器内核）。

## v8.1（v8 验证结果 + 进一步修复）：主框架 XHR 插桩也破坏章节页反爬

**2026-08-31 log2.txt 分析**：
- `forMainFrameOnly:true` 生效：日志不再出现 `origin=https://challenges.cloudflare.com` 帧，**Cloudflare Turnstile 挑战不再触发**。
- 但章节页 **仍无限 reload**：web readchapter 每个 POST 都返回 size=22/24 = `{"code":7,"time":1000}`，触发 `location.reload()`。`_ac`/`_gac` cookie 正常写入，页面 JS 正常执行。
- 结论：**iframe 污染非 code:7 根因**。剩余差异是主框架内我们 debugJS 对 `XMLHttpRequest.prototype.send` 的包裹——章节页自身混淆脚本也包裹 send 注入 `_gac`/`state` 反爬证明，可能检测到外部 send 覆写而拒绝注入 → readchapter 缺证明 → code:7。

### 修复 v8.1（已实施）：章节页(/truyen/)完全不加插桩
- bridgeJS 与 debugJS 的 IIFE 顶部加守卫：`if (String(location.pathname).indexOf('/truyen/') === 0) return;`
- 主框架为章节页时两个脚本空转，让章节页与真实浏览器运行环境一致，页面自身反爬正常注入证明。
- SPA（app.v2.php）行为不变。
- JS 语法 node vm.Script 验证通过；Swift 无诊断错误。

### 待真机验证（v8.1）
1. 章节页不再无限 reload，正文能渲染（页面自身反爬证明正常工作）。
2. 若仍 code:7，则证明 WKWebView/LiveContainer 环境本身被服务器判定为异常（非我们插桩导致），需评估是否替换浏览器内核。

## v8.2（v8.1 验证结果 + 重新诊断）

**2026-08-31 log3.txt 分析**：
- v8.1 守卫生效：`/truyen/` 章节页无 `[DBG:init]/[DBG:ready]` 日志（bridgeJS/debugJS 空转）。
- 但用户反馈 **仍无限刷新** → 章节页在**完全无插桩**下仍返回 code:7 循环。
- **关键结论**：问题不在我们的插桩（插桩开/关都是 code:7），而是 **WKWebView/LiveContainer 环境下 web readchapter 的 `_gac`/`state` 反爬证明无法通过**。

### node 决定性测试
1. **grantcontext 混淆 JS 新增全局函数**（`_0x54a6`、`_0x498f`）：`_0x498f()` 返回字符串解码表，`_0x54a6()` 返回 undefined —— **key 在 IIFE 闭包内，全局不可达**，eval 返回 undefined，App key 机制为硬死路。
2. **章节页脚本运行**：设置 `_gac` cookie，但**不包裹 XHR.send**（mock 中 send 源未变）→ 反爬证明纯靠 `_gac` cookie，无 XHR 覆写依赖。
3. **全新会话**：GET 章节页返回 `state:0`（无有效 state），POST readchapter 返回**空 body**——与有会话的 code:"5"/code:7 不同。

### 修复 v8.2（诊断构建，已提交）
- **bridgeJS**：保留 `/truyen/` 守卫（空转），避免 open 覆写干扰章节页。
- **debugJS**：重新在章节页注入（行为保持，仅日志），并新增 `[DBG:xhr-body]` 打印 readchapter **响应体前 300 字符**，确认章节页实际收到的 code/err。
- 目标：拿到章节页 readchapter 的精确响应与 `_gac`/`state` 状态，判断是 stale session 还是 env 检测。

### 待真机验证（v8.2）
1. 日志应重新出现章节页的 `[DBG:xhr-load]` + `[DBG:xhr-body] resp={...}`，确认响应 code。
2. 若 `state` 相关/`_gac` 过期 → 尝试登出重登、清 cookie 重开会话。
3. 若环境被检测 → 评估更换浏览器内核/换源站直连。

## v9（用户洞察）：换到 sangtacviet.vip 域以通过 Cloudflare 挑战

**2026-08-31 用户反馈 + 验证**：
- 用户实测：`sangtacviet.com` 在 PC/Safari 会一直刷新，稍后弹出 **Cloudflare 认证**，认证后正文才显示。
- 手机 Safari 用 `sangtacviet.vip` 能**自动弹出并完成 Cloudflare 认证**，正文正常显示。
- App 里只配置了 `sangtacviet.com` 和 `sangtacviet.app`，**没有 `sangtacviet.vip`**。

**根因确认（log5 + node 实测）**：
- 章节页确实发送反爬证明 body（`[DBG:xhr-body-req] body=75dbb6c1...`），但服务器仍返回 code:7 → 因 **cf_clearance 未签发**（Cloudflare 挑战未完成）。
- 证明 token 跨书恒定（fanqie/trxs 相同 `75dbb6c1...`），说明是会话级证明而非内容相关。
- grantcontext 混淆 JS 无 `return`、不设 cookie、只定义 2 个解码全局函数，eval 恒 undefined → App key 机制为硬死路。
- node 从三个域名（.com/.vip/.app）都能直接拿到正常 HTML（无 CF 挑战）→ CF 挑战是**浏览器指纹级**，非 IP 级。
- 前端 `defaultDomains = ["https://sangtacviet.com", "https://dns1.stv-appdomain-00000001.org", "https://sangtacviet.app"]`，**不含 .vip**；`app.config.ux.app_domain` 可钉住首选域。

**修复 v9（已提交）**：
1. Swift 入口 URL 改为 `https://sangtacviet.vip/app.v2.php`，Referer 同步改 .vip。
2. `didFailProvisionalNavigation` 回退逻辑改为 .vip → .com。
3. bridgeJS STV 主机白名单加入 `sangtacviet.vip`。
4. bridgeJS `patchNet` 已强制 `bestDomain()` 返回 `curOrigin`，故所有请求保持 .vip 同源；章节页导航也在 .vip 上执行，若 .vip 的托管型 CF 挑战自动完成则 readchapter 应返回 code:0。
- JS 语法 node vm 验证通过，Swift 无诊断错误。

### 待真机验证（v9）
1. 应用入口是否成功加载 sangtacviet.vip（`[DBG:init] origin=https://sangtacviet.vip`）。
2. Cloudflare 挑战是否自动完成并签发 cf_clearance。
3. 章节正文是否正常显示（不再无限 reload）。

## v10（突破）：网页版 readchapter + 内置 verifyca 成功加载正文

**2026-08-31 log6 分析（决定性）**：
- `[DBG:init] origin=https://sangtacviet.vip`：v9 域名切换生效，CF 挑战自动完成进入首页。
- App 格式 readchapter（`/?sajax=readchapter&...&key=`）仍 code:7；grantcontext eval 仍 undefined。
- 但**网页版 readchapter**（`POST /index.php?...&ngmar=readc&sajax=readchapter&sty=1&exts=`）完整走通：
  1. 首次 code:7 `time:30`/`time:1000`（等待证明就绪/重试）
  2. 随后 code:21 `err:"Vui lòng xác nhận để tiếp tục."`（需人机验证）
  3. 用户完成 `POST /index.php?ngmar=verifyca` 后
  4. 再次请求 → `{"code":"0","bookname":...,"chaptername":...,"data":"<p>正文...</p>"}` **正文加载成功**

**关键源码确认（app.v2.read.js + app.v2.js）**：
- `app.reader.getContent2`（line 555）被 `if(window.Capacitor && window.Capacitor.Plugins.Http)` 守卫，无 Capacitor 返回 undefined。
- `app.reader.handlingException`（line 729）对 `code:"21"` 调 `runCaptcha("read", cb)`——app 内置 Cloudflare Turnstile（sitekey `0x4AAAAAABbXTEjsj3isHkfm`），验证成功后 `reloadCurrentChapter(true)` 重新加载。
- 即 app **原生就有验证流**，只是 getContent2 用的 App 格式（需 key）先命中 code:7，到不了 code:21。

**修复 v10（已提交）**：覆写 `app.reader.getContent` 改用**网页版 readchapter**（POST，无需 key）：
1. code:7 → 按 `time` 延时重试（最多 6 次）。
2. code:21 → 直接返回给 app，触发内置 runCaptcha（Turnstile）→ 用户验证 → reloadCurrentChapter。
3. code:0 → 返回正文，**在 app 原生阅读器渲染**（不再跳浏览器页）。
- 移除章节页导航回退（不再需要）。
- JS 语法 node vm 验证通过，Swift 无诊断错误。

### 待真机验证（v10）
1. 进章节 → 应弹出 app 内置的 Turnstile 人机验证框（若会话已通过 CF，可能直接 code:0）。
2. 验证后正文在原生阅读器显示（`[DBG:gc-ok]`）。
3. 登录仍失败（ajax=login size=7）单独处理。
