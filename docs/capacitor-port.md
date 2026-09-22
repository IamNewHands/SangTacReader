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

