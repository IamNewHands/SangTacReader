# SangTacReader iOS —— Capacitor 迁移档案

> 本文记录「为什么把 iOS 端从纯 WKWebView 套壳重做成 Capacitor 应用」的完整证据链与实施状态。
> 所有结论均来自对 `apk_extracted/`（安卓版 `stvmobilereader-1.2.17.apk` 反编译落地）与线上前端 `app.v2.js` 的实证阅读。

## 1. 一句话

安卓版**本身就是 Capacitor 应用**，站点前端因此走「app 模式」；旧的 iOS 端是纯 WKWebView，站点只认成浏览器，走「web 模式」——两条完全不同的代码路径，这才是「体验差」的根因，而不是缺 Capacitor。

## 2. 证据链

| 事实 | 出处 |
|---|---|
| 安卓版是 Capacitor 应用（appId `com.sangtacviet.mobilereader`） | `apk_extracted/assets/capacitor.config.json` |
| 安卓版**远程加载**站点，不是本地打包 UI | 同上：`server.url = https://sangtacviet.com/app.v2.php` |
| 安卓版开启了 `CapacitorHttp` | 同上：`plugins.CapacitorHttp.enabled = true` |
| 安卓版注册了 15 个插件，含自制 `capacitor-webnativeview` | `apk_extracted/assets/capacitor.plugins.json` |
| 站点前端按 `window.Capacitor` 是否存在分两条路 | `app.v2.js` 中 `isCachedFrontend = window.hasOwnProperty("Capacitor")` |
| app 模式下所有数据请求走原生网络栈 | `app.v2.bookdisplay.js`：`if (window.Capacitor && window.Capacitor.Plugins.Http)` → `Http.get({...})`，带 `x-stv-transport: app`、`x-requested-with: com.sangtacviet.mobilereader` |
| 安卓 APK 改写过 CapacitorHttp：原生签名 | `libssign.so` 导出 `Java_com_getcapacitor_plugin_http_Http_signParams` / `signParamsK` |
| 签名算法（上一轮已逆向） | `MD5(排序后的 query + 尾部 &)`，盐 `erogh982^%*%^*`（signParams）、`475yvjt837y9%$^#`（signParamsK） |
| 签名**不是**关键门槛 | v14/v16 实测：假签名 code:1、无签名 code:5；真正门槛是 TLS 指纹 + 页面会话，而 iOS URLSession 指纹被服务器接受（v17 真机 code:0） |
| 安卓的「原生阅读界面」其实是站点自己的网页 UI | `assets/public/` 只是空壳；正文由站点前端渲染 |
| `WebNativeView` 只服务漫画模块 | `app.v2.js:5974` `AndroidView.create("android.webkit.WebView")`、`app.v2.js:6413` `createHandler("android.view.View$OnScrollChangeListener", ...)` |

### 站点前端依赖的原生插件（按调用次数）

| 插件 | 调用点 | iOS 方案 |
|---|---|---|
| `StatusBar` | 21 | 官方 `@capacitor/status-bar` |
| `WebNativeView` | 8 | 自制 Swift 桥（**当前为占位**，仅影响漫画） |
| `App`（含自定义 `SyncCookie`） | 7 | 自制 `plugins/app` |
| `Http` | 6 | 自制 `plugins/http` |
| `Keyboard` / `Browser` / `Share` / `Preferences` / `Haptics` | 3/2/2/2/1 | 官方 iOS 插件 |
| `CapacitorSQLite` | 1（`if` 守卫） | 暂缺，功能降级 |
| `MlKit` / `MainClass` | 2 / 1 | 安卓 ML Kit OCR，iOS 暂缺（漫画翻译降级） |
| `AdMob` | 1 | 暂缺（广告，非阅读路径） |

## 3. 关键实现决策

1. **`plugins/http` 不用 `@capacitor-community/http`**，也不直接复用核心 `HttpRequestHandler`，原因：站点调用 `Capacitor.Plugins.Http` 时自带 `Cookie: document.cookie`，而 httpOnly 的会话 cookie（`access`/`useri2`/`hstamp`）**不在 `document.cookie` 里**。自写插件从 `WKWebsiteDataStore.httpCookieStore` 重建 Cookie 头，并把响应的 `Set-Cookie` 写回 webview cookie store。这正是安卓 `SyncCookie` 存在的原因。
2. **`plugins/app` 必须自写**：同一个 jsName 不能注册两个插件，要支持 `App.SyncCookie()` 就不能再装官方 `@capacitor/app`。
3. **`addListener` / `removeAllListeners` 不能自己声明**（`CAPPlugin.h` 已声明，重写会编译报错），只在 `load()` 里注册观察者并 `notifyListeners`。
4. **`ios/` 目录不入库**：必须由 macOS 上的 `npx cap add ios` 生成，否则 Windows 会把反斜杠路径写进 `CapApp-SPM/Package.swift`，macOS 的 SwiftPM 解析失败（newsnook-ios 已踩过）。
5. **`CapacitorHttp.enabled` 先设 `false`**：站点显式调用的 `Plugins.Http` 已经覆盖数据请求；开启核心的 fetch/XHR 全局改写有干扰 Cloudflare Turnstile 的风险。若实测需要原生路由，再改为 `true`。

## 4. 验证闭环

- 本机（Windows）**无法编译 Swift**，每轮改动靠 GitHub Actions（`.github/workflows/build-ipa.yml`，`macos-26`）产出未签名 IPA。
- 装机：SideStore / LiveContainer / SideInstaller 本地签名。
- 判断「app 模式是否生效」的现场证据：站点不再弹 Cloudflare 挑战、`readchapter` 返回 `code:0`、以及原生日志里 `[SangTacHttp:ok]` 出现请求记录。

## 5. 已知缺口（按优先级）

1. `WebNativeView` 目前是占位实现 → 漫画/图片模块退化（小说正文不受影响）。
2. `CapacitorSQLite`、`MlKit`/`MainClass`（OCR）、`AdMob` 未接 → 对应功能降级。
3. 旧工程 `SangTacReader.xcodeproj` + `WebViewController.swift`（2410 行）仍留在树里，待新构建真机验证通过后再决定退役（**删除需用户确认**）。

## 6. 真机问题档案

### 6.1 列表能看、点小说没反应（2026-09-22 定位并修复）

**现象**：小说列表正常，点任意一本没反应（详情页不出现）。

**根因**：站点前端在点击回调里**先**调 `app.platform.nativeClick()`，**后**才打开详情。线上生产代码（`/asset/app.v2.bookdisplay.js`，4 处）：

```js
ele.addEventListener("click", function () {
    app.platform.nativeClick();                    // -> nativeclick.trigger()
    app.fun.openBookWithData(data.lid, data);      // 上一行抛错则永不执行
});
```

`nativeclick` 这个全局在安卓 APK 里由 Cordova 插件 `cordova-plugin-nativeclicksound` 提供（`cordova_plugins.js` 的 `"clobbers": ["nativeclick"]`）。iOS 侧没有 Cordova 插件 → `nativeclick` 未定义 → 第一行抛 `ReferenceError` → 整个点击回调中断 → 详情打不开。列表渲染不涉及点击，所以看起来「只有详情坏了」。

**已排除的错误假设**：以为是站点「web 通道 vs app 通道」被 Cloudflare 区别对待。用真实请求实测（`/mobile/bookinfo.php?id=<lid>`、`/io/searchtp/searchBooks`）四个域、两条通道返回**完全一致**（详情 1168 字节同一份 JSON），该假设被证伪。注意列表项用的是 `lid`（内部 id），不是 `id`。

**修复**：在 `SangTacAppPlugin.load()` 里用 `WKUserScript`（`.atDocumentStart`，主框架）注入 Cordova 兼容层：`nativeclick`（空实现，iOS 无系统点击音）与 `TTS`（空对象；站点以 `if (TTS.updateMediaSession)` 形式探测，空对象即可安全跳过安卓媒体会话逻辑）。CI 增加 `strings | grep stvIOSCompatInstalled` 校验，确保兼容层真的编进产物。

**同类风险（尚未触发）**：`AndroidFullScreen.*` 只在 `isAndroid` 分支使用，iOS 不可达；`TTS` 的真实朗读功能仍未实现（需要 `AVSpeechSynthesizer`）。

### 6.2 正文打不开 + 长时间卡死（2026-09-22 定位并修复）

**现象**：详情页、目录都正常；点章节正文弹 `Kết nối tới máy chủ thất bại, hãy thử kiểm tra kết nối mạng.`（带「Tải lại」）并退回首页；有时页面卡住很久点不动。登录后：历史为空、关注报 HTTP 500、书签正常。

**根因（决定性）：`Http` 插件的 `data` 类型与安卓不一致。**

安卓参考实现 `HttpRequestHandler.readData`（`ionic-team/capacitor` 主分支，`android/.../plugin/util/HttpRequestHandler.java`）的规则是：

```java
if (contentType != null && contentType.contains("application/json")) {
    return parseJSON(readStreamAsString(...));   // 只有 JSON MIME 才解析
} else {
    switch (responseType) {
        case BLOB: case ARRAY_BUFFER: return readStreamAsBase64(stream);
        case JSON: return parseJSON(...);
        default: return readStreamAsString(stream);   // 其余一律字符串
    }
}
```

我们的插件却用「body 以 `{` 或 `[` 开头就解析」的启发式。而 `readchapter` 的响应是 **`Content-Type: text/html` + JSON body**（实测 63 字节的 `{"code":...}`，正常章节同理）→ 被我们解析成**对象**。

站点 `app.reader.getContent2`（线上 `/asset/app.v2.read.js:577`）第一行就是：

```js
var j = r.data.replace(/^\uFEFF/, '');   // r.data 是对象 -> TypeError
```

抛错 → 重试 → 返回 `null` → 回落 `app.net.get` → 失败 → `getContent` 的 catch 返回
`{code:"1", info:"Kết nối tới máy chủ thất bại…"}`。**用户看到的正是这句兜底文案。**
这也解释了「为什么只有正文坏」：详情/目录/书签走的是 `app.net.get`（`JSON.parse(response.data)` 在 try/catch 里，对象也能歪打正着），只有 `getContent2` 直接对 `r.data` 调字符串方法。

**卡死根因：忽略调用方传入的 `timeout`。** 站点 `verifyDomain` 传 `timeout: 5000`、`getCapacitor` 传 `timeout: 10000`，我们一律用 60s。而 `readchapter` 返回 `10002` 时站点会 `await app.net.networkManager.checkDomains()`（3 个域 × 最长 60s）并重新拉取 **300KB** 的 `grantcontext` 混淆 JS 循环重试 → 分钟级卡死。

**修复（`plugins/http`）**：

1. `data` 类型严格照抄安卓：只有 `Content-Type` 含 `application/json` / `application/vnd.api+json` 才解析；`responseType` 为 `blob`/`arraybuffer` 返回 base64，为 `json` 才解析，其余返回字符串；`status >= 400` 时附加 `error: true`。
2. 接受 `timeout` / `readTimeout` / `connectTimeout`（毫秒），缺省仍为 60s。
3. 站点调用点不带 `Referer`，改用 **webview 当前 URL** 兜底（读接口需要同站 Referer），而不是裸 origin。
4. 新增 `window.__stvDiag` 诊断面板（`plugins/app` 注入 + `plugins/http` 上报）：捕获 `window.onerror`、`unhandledrejection`、全部 `console` 输出与每一次 Http 请求（方法/路径/状态/data 类型/字节数）。出错自动弹出，左上角连点三下可切换，CLOSE 关闭。sideload 的 iOS 包读不到 console，这是唯一可用的现场证据通道。

**为什么本地无法复现 readchapter**：从 Windows/Node 发起的**任何** readchapter 形态——app 模式 GET 带 `key`、不带 `key`、web 表单 `POST ngmar=readc&sty=1&exts=`、四个域（`.com`/`.app`/`.vip`/`dns1…`）、带与不带 `Origin`——**一律返回 `{"code":"10002","err":"Khởi động lại ứng dụng để tự cập nhật."}`**。`grantcontext` 在 Node 里 `eval` 后返回 `undefined`（该混淆 IIFE 在所有环境探测下都无副作用），说明 `chapterkey=undefined` 是**各平台一致**的正常行为；服务器是按**客户端连接身份**（TLS/连接指纹，见 v16 结论）判定是否为真机 app，Node 不在白名单内。因此 readchapter 的成功/失败只能在真机取证。

**待取证（下一轮真机日志）**：历史为空、关注 500。这两条都走 `app.net.get/post`，与正文不是同一条路径；需要 `__stvDiag` 面板里对应请求的状态码与 URL（判断是否落到了 `bestDomain()` 选出的跨域 `.app` 而丢掉 httpOnly 会话 cookie）。

**顺手补的护栏**：`scripts/check-ios-shim.js` + workflow 步骤，校验 `SangTacAppPlugin.swift` 里 `"""…"""` 的注入脚本是**合法 JS 且不含反斜杠**——这正是历史 v5 事故（Swift 转义导致整段 shim 语法错误、静默失效）的同类风险；另有 `strings | grep stvDiagInstalled` 确保诊断面板真的编进产物。

