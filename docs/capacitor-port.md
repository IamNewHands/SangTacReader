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

1. **「关注」列表登录后空白**（站点侧疑似 500）——需要真机 `__stvDiag` 面板的 URL + 状态码 + 响应体才能定性，见 §6.3 (4)。
2. **「取消收藏」在站点侧不存在**：客户端只有 `ajax=addbookmark`，`delbookmark`/`removebookmark`/`unbookmark` 全部返回空响应（未知动作）。只能去网页版取消，客户端无法补。
3. `WebNativeView` 目前是占位实现 → 漫画/图片模块退化（小说正文不受影响）。
4. `CapacitorSQLite`、`MlKit`/`MainClass`（OCR）、`AdMob` 未接 → 对应功能降级。
5. ~~旧工程 `SangTacReader.xcodeproj` + `WebViewController.swift`（2410 行）~~ —— **已退役**（2026-09-22，新构建多轮真机验证通过后删除，含它打包的 `www/` 资源与 `tests/` 下的一次性探测脚本）。旧实现仍可从 git 历史取回。
6. `__stvDiag` 诊断面板是临时设施，现场问题定性完成后应移除（`SitePatch.diag` 整块 + `SangTacHttpPlugin.report`）。

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

### 6.3 正文能读之后的五项（2026-09-22 第二轮真机反馈）

用户反馈原文：正文可以看了，但是上下滑动（安卓是左右翻页）；语言切中文后部分设置项仍是越南语；详情页底部书签点不动、书签取消不了；顶部「关注」空白且诊断面板挡住底栏；TTS 要用 iOS 原生实现。

#### (1) 阅读模式默认「上下滑动」——不是 iOS 的锅，是站点默认值

站点自己的默认值就是竖向滚动，**与平台无关**：

```js
// /asset/app.v2.config.js
"display_type": "auto",

// /asset/app.v2.read.js  loadChapterDisplay()
if (displayType == "auto" || !displayType) { displayType = "default"; }

// /asset/app.v2.chapterdisplay.js  (注册表末尾)
const ChapterDisplayTypeRegistry = {
    slide: SlideChapterDisplay,
    pageflip: PageFlipChapterDisplay,
    simulatedpageflip: SimulatedPageFlipChapterDisplay,
    flashpageflip: FlashPageFlipChapterDisplay,
    continuos: ContinuosChapterDisplay,
    default: SlideChapterDisplay,     // <- auto/default 落到「上下滑动」
};
```

全前端**没有任何一处**写过 `display_type`（`grep` 只有 config 的默认值、i18n 标签、read.js 的两处读取），安卓 APK 加载的也是同一个 `/asset/app.v2.config.js`。所以安卓那边的左右翻页是**那台设备自己在「阅读设置」里选过**并存进本机 `config.reader` 的，不是平台差异。

**修复**：`SitePatch.readerDefaults` 在 `app.config._reader` 就绪后轮询，**仅当值仍是未动过的 `auto`/`default`/空**时写入 `pageflip`（走 `app.config.reader` 的 setter，等于一次正常的手动修改）。用户自己在阅读设置里选过的值（含 `simulatedpageflip`/`continuos`）**不会被覆盖**——`scripts/test-site-patch.js` 有对应用例。

#### (2) 语言切中文后仍有越南语——站点自己把文案硬编码在 HTML/JS 里

站点 i18n 机制是：HTML 写 `<text>some_key</text>`，`app.celoader.text(el)` 用 `app.text[key]` 替换；`app.text.changeLanguage()` 把 `/mobile/lang/<lang>.json` **`$.extend` 合并**到越南语基底上。实测 `zh.json` 与 `vi.json` **键数完全相同（各 188 个）**，所以 `<text>` 驱动的标签全部能翻译。

剩下的越南语是**硬编码字面量**，例如：

```html
<div class="settingitemtitle">Thêm name 1 nhấp</div>     <!-- 没有 <text> -->
<div class="settingsection mt-3">Bộ lọc name</div>
<div class="settingitemtitle">Cho phép hoạt động</div>
```

以及 `app.context.menu.*` 的 `text: "Đánh dấu"`、`app.toast(...)` 等。**服务器不归我们管**，所以唯一可动的 owner 是客户端。

**实现**：`data/site-i18n.json`（人工校对，450 条整节点精确匹配 + 35 条拼接片段 + 1 条前后缀模板，覆盖服务端 HTML、`app.v2*.js`、`stv.tts.js`、`app.v2.comicprovider.js`（漫画分类）与 `stv.ui.js`（章节 iframe UI））由 `scripts/gen-site-i18n.js` 生成 `plugins/app/ios/Sources/SangTacAppPlugin/SiteI18nData.swift`，CI 用 `gen-site-i18n.js --check` 保证两者不漂移。运行时 `SitePatch` 注入的覆盖层：

1. **整节点精确匹配**（`text.trim()` 全等）——覆盖设置页全部标签，短词（`Ảnh`/`Khác`/`Không`）也只按整节点替换，不会误伤书名或正文。
2. **片段替换**（仅 ≥5 字符、且按长度降序）——处理站点用字符串拼接出来的消息，如 `"Đã dừng đọc sau " + n + " phút"`。
3. **前后缀模板**——`"Các truyện do " + name + " làm"` 这类中间是变量、且首尾都要改写的句子。
4. `MutationObserver`（`childList` + `characterData`）覆盖站点异步渲染，另有 1.5s / 5s 两次兜底 sweep。
5. **黑名单容器**（`#pageflipper`、`.chapterdcontinuos`、`.chaptercontent`、`.info`、`.comment`、`.post`、`.name`、`.previewcontent` …）整体跳过，正文/评论/简介/书名永不被改写；`placeholder`/`title` 属性同样走精确匹配。

已知未覆盖（记录在案）：服务端直接下发的越南语文案（`app.toast(d)` 里 d 就是服务端原文）、站点 `notificationReplace` 只认 4 种格式的通知、以及站点自己用 `innerHTML` 拼出来的 HTML 片段。这些只能等站点自己本地化，客户端无法在不误伤用户内容的前提下改写。

#### (3) 详情页书签点不动 / 取消不了——两个独立原因

**「点不动」**：旧诊断面板是**贴底 60% 高的浮层**，且**任何 ERR 都会自动展开**。详情页的 `app.api.updateBookPage` 里有一处站点自身的空指针：

```js
app.api.queryBookExtStatus = async function(bookinfo){
    if(!app.user.isLogin){ return null; }
    return app.net.post(url,params).then(down => down.code == 100 ? down : null);
};
app.api.updateBookPage = function(p,bookinfo){
    app.api.queryBookExtStatus(bookinfo).then((status)=>{
        if(status.like){ ... }        // status === null -> TypeError
```

这个 TypeError 触发 `window.onerror` → 面板自动弹出 → **盖住详情页底部那条 60px 的 `.bottombar`**（书签/评论/立即阅读/目录四个按钮都在里面）。用户看到的「书签点不动」和「面板挡住底栏」是**同一个现象**。

**「取消不了」**：站点**根本没有取消收藏的接口**。把候选 action 全部匿名实测（`/mobile/jsonify.php?ajax=…`，两个域各一遍）：

| action | 返回 |
| --- | --- |
| `addbookmark` | `{"text":"Permission denied","code":102}`（动作存在，需要登录） |
| `querybookmarkstatus` | `{"text":"Permission denied","code":102}` |
| `followbook` | `{"text":"Permission denied","code":102}` |
| `delbookmark` / `removebookmark` / `unbookmark` / `deletebookmark` / `bookmark` | **空响应**（等于「未知动作」） |

客户端也只有 `app.api.bookmark` 一处写操作（`ajax=addbookmark`）。**所以「取消收藏」在安卓上同样不存在**，只能在网页版操作。这一条是站点功能缺口，客户端无法补（没有 endpoint）。

**修复**：面板重做（见 (4)），自动展开取消；底部栏不再被遮挡。

#### (4) 关注空白 + 面板挡住底栏

- **面板**：改成**贴顶 42% 高**的浮窗，标题栏可纵向拖动，按钮 `COPY` / `CLEAR` / `CLOSE`。折叠态是右侧一个 24px 小圆点，显示日志行数，**出现 ERR 时变红**；不再自动展开（旧行为正是「挡底栏」的成因）。`COPY` 把整个缓冲区写进剪贴板（`navigator.clipboard` + `execCommand` 兜底），比截图更好用。同时新增**点击日志**：每次 tap 记录 `目标元素`，并在 `document.elementFromPoint` 命中的元素与目标不一致时追加 `topmost=…`——这正好区分「回调没绑上」和「被别的东西盖住了」。
- **关注空白**：`view-bookfollowing` 的 `<bookdisplay from="/mobile/booklist.php?method=following&p=0">`。匿名实测 `method=following` 与 `method=bookmarked` 都返回 `{"code":102}`，`method=history` 返回 `{"code":101}`，`method=bookpush` 正常返回列表——**匿名态看不出区别**，登录后的 500 只能在真机取证。为此 `SangTacHttpPlugin` 的上报行升级为：**完整 URL + 状态码 + Content-Type + data 类型 + 字节数 + 响应体前 240 字符**，且 **`status >= 500` 用 `ERR` 标签**（会点亮红色角标）。另外补了 `Http.startForeground` / `Http.stopForeground` 空实现——`app.v2.read.js` 通过 `Capacitor.nativePromise("Http", …)` 调用且**不 catch**，方法缺失会变成 unhandledrejection 噪音。**真机结论见 6.4(1)：站点服务端 500，安卓同样打不开。**

#### (5) TTS 用 iOS 原生

安卓的 `app.tts.engineList()` 第一项就是原生引擎 `{name:"Android TextToSpeech", value:"google"}`；**iOS 分支只给了网络 provider**（Bing / Zalo / FPT / Viettel / Sáng Tác Việt），没有任何本机选项。

`/stv.tts.js` 的 provider 契约（`TtsProvider` / `AndroidTts`）是：

```
props                        -> 设置项描述
async speak(text, options)   -> 音频 Blob（ttsEngine.decodeAudio() 交给 AudioContext.decodeAudioData）
async getVoices()            -> [{name, value, gender}]
```

`AndroidTts.speak()` 正是 `await TTS.speakToFile(param)` → `new Blob([arrayBuffer], {type:'audio/wav'})`。iOS 照抄这条路径：

- `NativeSpeech.swift`：`AVSpeechSynthesizer.write(_:toBufferCallback:)` 取 PCM（float32/int16/int32、交错与非交错都归一化成 16-bit），拼一个标准 44 字节 WAV 头，base64 回传。`speakToFile` 走这条路；`speak` 用 `AVSpeechSynthesizer.speak()` 直接播放（站点实际不调，但 Cordova 插件有这个方法）。
- 语速映射：站点 `rate` 是倍率（安卓直接交给 `setSpeechRate`），iOS 是 `AVSpeechUtterance.rate ∈ [0,1]`、默认 0.5 → `rate_ios = clamp(0.5 × rate, min, max)`；`pitch` 直接 clamp 到 `[0.5, 2]`。
- `SitePatch.ttsProvider`：包装 `ttsEngine.createProvider` 增加 `"ios"` 分支，并把 `app.tts.engineList()` 的 `"ios"` 项插到最前。首次安装（`tts.setting` 为空）自动把 provider 设为 `ios`；用户选过别的 provider 则不动。
- 两个必须照顾的站点细节：`loadProviderOption` 会**无保护地**读 `app.tts.setting[provider].voice`，所以 provider 子对象要预先建好；`getVoices()` 为空时 `voices[0].value` 会抛错，所以**永远至少返回一项**。

**本轮护栏**：`scripts/test-site-patch.js` 在 stub 的 DOM/Capacitor 环境里真跑一遍注入脚本（TTS facade → Blob、provider 注册、engineList 顺序、provider 默认值不被覆盖、display_type 只在未动过时改写、面板构建与缓冲、i18n 覆盖层改写设置标签但**不动**正文/评论、拼接消息与 `placeholder` 也能翻译），CI 增加一步 `node scripts/test-site-patch.js`；`check-ios-shim.js` 改成扫描该 target 下**所有**多行字符串块（现在 5 块、42KB），并新增 `gen-site-i18n.js --check` 与 `strings | grep stvI18nInstalled`。

### 6.4 第三轮真机反馈（2026-09-22）

日志：`D:\GitHub_Clone\日志.txt`（370 行，来自面板 `COPY`）。

#### (1) 关注 = 站点服务端 500，不是客户端问题

同一 cookie jar、同一 host、同一 headers、**同一 endpoint**，只有 `method` 不同：

| 请求 | 结果 |
| --- | --- |
| `/mobile/booklist.php?method=following&p=0` | **500，0 字节** |
| `/mobile/booklist.php?method=bookmarked&p=0` | 200，34 KB JSON |
| `/mobile/booklist.php?method=mybook&p=0` | 200，`{"list":[],"code":100}` |

匿名探测三者**都**返回 `{"code":102}`（`follow`/`myfollowing` 之类不存在的方法返回 `{"code":101}`），说明 handler 存在、鉴权通过，**然后崩了**。站点自己的模板里写死了这个坏 URL（`<bookdisplay from="/mobile/booklist.php?method=following&p=0">`），所以**安卓版同样打不开关注**——这一项已经和安卓「效果一致」了。

客户端修不了服务端崩溃。新增 `SitePatch.followFallback`：包装 `app.net.get`（**不是** `Capacitor.Plugins.Http`——`Capacitor.Plugins` 是 proxy，赋值可能静默失败，而不会触发的诊断比没有更糟；`app.net.get` 是普通对象属性，且所有书单视图都走它），当 `method=following` 的调用**被 reject / 返回的不是书单 / 返回不可用**时，去抓站点自己那个**仍然活着**的旧接口 `/?ajax=getfollowing&user=0`（匿名返回 `Bạn chưa đăng nhập.`；站点模板第 3070 行还留着这个 URL，只是被注释掉了），把状态码 + 长度 + 前 400 字符打进面板。下一轮据此写转换器，而不是猜。

#### (2) 正文顶部章节标题仍是越南语

两个独立事实：

1. **覆盖层没碰它**：`.chaptername` 在 i18n 覆盖层的 `SKIP` 集合里，`walk()` 根本不下沉。这个设计本身是对的（章节标题是每本书的数据，不能拿片段表去替换），所以修法是**加一条专用 pass**，而不是把它从 SKIP 里删掉。
2. **标题正文无法翻译**：服务端从来不暴露中文原标题。`sajax=readchapter` 只回 `bookname` + `chaptername`；`mobile/bookinfo.php` 只回 `{"book":{…}}`，**没有章节列表**；`transmode=original`（cookie `transmode=chinese`）只把**正文**切成中文，标题照旧越南语。日志里 `"chaptername":"Chương 03:. Giao phong"` 与纯中文 `data` 同时出现，就是这个组合。

能修的是**外壳**，而且有两种数字格式（日志里都出现了）：

| 站点 | 原文 | 改写后 |
| --- | --- | --- |
| qidian | `Chương 3:. Giao phong` | `第3章 Giao phong` |
| fanqie | `Thứ 2 chương Ngọc Long linh tuyền không gian` | `第2章 Ngọc Long linh tuyền không gian` |

实现刻意**不用正则**（整块要被嵌进 Swift 多行字符串，反斜杠是硬错误），改成 `TITLE_HEADS = [['Chương',''],['Thứ','chương']]` 表 + `charCodeAt` 逐字符扫描；幂等（`第…` 开头的直接原样返回，也避免了 MutationObserver 自激），且 `Thứ tự chương`（以 `Thứ` 开头但没有数字）原样保留。测试补 5 条断言。

#### (3) TTS 报「no voice / 没有音频」——声音是有的，是合成返回空

日志证明**本机语音读得到**（LiveContainer 里也读得到）：

```
19:35:10 [LOG] [{"name":"Linh","value":"com.apple.voice.super-compact.vi-VN.Linh","gender":1}]
19:35:16 [LOG] processing  Xin chào, đây là chuyển văn bản thành giọng nói
19:35:17 [LOG] iOS TTS returned no audio
19:35:17 [LOG] Không tìm thấy blob
```

失败点是 `AVSpeechSynthesizer.write(_:toBufferCallback:)` **立刻回调一个 `frameLength == 0` 的 buffer**，一个采样都没给。旧代码的三个问题：只 `setCategory` 没 `setActive(true)`；用 `mode: .spokenAudio`；没有兜底。

现在：先 `setCategory(.playback, mode: .default, options:[.mixWithOthers])` + `setActive(true)`，然后按顺序试三种配置，取第一个真正出采样的：

1. `usesApplicationAudioSession = false` + 用户选的 voice
2. `usesApplicationAudioSession = false` + `AVSpeechSynthesisVoice(language:"vi-VN")`
3. `usesApplicationAudioSession = true` + 用户选的 voice

每次尝试、解析到的 voice identifier、buffer 回调次数、最终字节数都通过 `SangTacAppPlugin.report()` 同步进**页面面板**（`window.__stvDiag`）——侧载包没有可读的控制台，而站点自己的报错（`Không tìm thấy blob`）完全不说明原因。

### 6.5 第四轮真机反馈（2026-09-22 晚）

日志 `日志2.txt`（278 行）。五项。

#### (1) 覆盖安装后设置全恢复默认 —— 容器被换掉了，不是补丁写坏的

站点的配置存在 **localStorage** 里，链路是：

```
app.config.saveReaderSetting()  ->  app.storage.cache.setFile('config.reader', …)
app.storage.cache.setFile       ->  app.storage.set
app.storage.set                 ->  localStorage.setItem
```

（`app.v2.config.js:100-111`、`app.v2.js:551-586`。`CapacitorSQLite` 不在 iOS 依赖里，所以走的就是 localStorage 那条分支。）

侧载包每次重装都会拿到**全新的数据容器**，localStorage 是空的，于是 `$.extend({}, readerDefault, loadedReaderSetting)` 里的 `loadedReaderSetting` 就是 `{}`。日志也印证了：本次启动 `[PATCH] reader display_type auto -> pageflip` —— `auto` 就是默认值，说明读回来的配置是空的。

修法：**iOS Keychain 不随 App 删除而清除**，把配置镜像进去。新增 `settingsBackup` 站点补丁 + `SangTacAppPlugin.settingsSave/settingsRestore`：

- 包装 `app.storage.set`（**唯一漏斗**，`cache.set` / `cache.setFile` / `save*Setting` 全部经过它），对 `config.reader`、`config.ux`、`config.comicReader`、`tts.setting`、`readthemeset` 以及动态前缀 `reader.style.*` 做镜像；
- document start 时调 `settingsRestore({})`，把 Keychain 里的值写回 localStorage（**只在 localStorage 缺该键时写**，绝不覆盖本次已存在的值）；
- 时机是安全的：站点要等 `onDbLoad.waitForLoad()` 才读配置（本次日志里我们 20:04:20 注入、`db loaded` 在 20:04:24），异步的 Keychain 读取毫秒级返回，一定先落地；
- Keychain 写失败（侧载包可能缺 entitlement，`errSecMissingEntitlement`）只是记一条日志，不影响设置本身。

注意：**这一次重装仍然是默认值**（备份是空的），需要用户重新设一次；从下一个版本开始才会自动恢复。

#### (2) TTS 仍报 no voice —— 原生已经成功，是 shim 把返回值认错了

这一轮的日志把根因钉死了：

```
20:07:10 [TTS] speakToFile 47 chars voice=com.apple.voice.compact.vi-VN.Linh
20:07:11 [TTS] audio session active (playback/default/mixWithOthers)
20:07:11 [TTS] attempt 1/3 [own-session+voice] voice=com.apple.voice.compact.vi-VN.Linh
20:07:11 [TTS] attempt 1 ok: 152238 bytes
20:07:11 [TTS] synthesised 152238 bytes
20:07:11 [LOG] iOS TTS returned no audio        <- 站点侧，来自我们的 shim
20:07:11 [LOG] Không tìm thấy blob
```

**原生合成一次成功，152238 字节**，上一轮的三种配置重试根本没用到。失败在 shim：`SangTacAppPlugin.speakToFile` resolve 的是 `{data: <base64>, mime: 'audio/wav'}`（对象），而 `IosTts.prototype.speak` 写的是 `typeof encoded !== 'string'` → 直接抛 `iOS TTS returned no audio`。

契约对不上是因为两边各取一半：`cordova-plugin-tts-advanced` 的 `speakToFile` 把原生返回值原样 resolve，而站点 `_dl_stv.tts.js:743-744` 做的是 `new Blob([await TTS.speakToFile(param)])`。**shim 就是这两者的适配层**，所以修在 shim：接受 `{data}` 与裸字符串两种形状，统一转成 Blob。`speak()` 的契约（返回 Blob）不变。

#### (3) 搜索/最新更新/排行/目录/正文都慢 —— 先测出时间花在哪，再改

日志里的耗时是**跳变**的：同一个 `searchBooks` 端点，`20:07:43 → 20:07:50` 用了 7 秒（79 KB），紧接着 `20:07:50 → 20:07:51` 只用 1 秒（70 KB）；`grantcontext/context` 864 KB 用了 6 秒。没有一条 `[ERR]`、没有超时重试痕迹。

本机无法复现测量（`sangtacviet.com` 从这台机器直接 TLS 被重置），所以**不猜**：给 `SangTacHttpPlugin` 的每条上报加了墙钟耗时，并给失败路径补了上报行：

```
[Http] GET <url> -> 200 application/json json 78926b in 120ms {…}
[ERR]  GET <url> FAILED in 10021ms: The request timed out.
```

下一份日志就能一眼分开「服务端慢」和「WebView 里 JS/渲染慢」。如果 `in` 很小但用户仍觉得久等，问题在站点自己的 `checkDomains()`（启动时并行探测 3 个域名，每个 5s 超时）或渲染，而不是网络层。

#### (4) 灵动岛没适配，顶部按钮点不到、底部多一行空白

站点自己**有**安全区模型，但只覆盖它自己画的那几条栏：

- `.titlebar` / `body[ovlwv] .titlebar` 有 `padding-top: var(--status-bar-height)`；
- `.bottombar` 有 `padding-bottom: var(--screensafebottom)`（`box-sizing: content-box`，背景会一起长下去）。

漏掉的是阅读器那两个浮层（`app.v2.css:959-1005`）：

```css
#chapterview .titlebar { position: fixed; top: var(--ntitlebarovl); height: 40px; }  /* 无 status-bar padding */
#chapterview.showmenu .titlebar { top: 0; }                                          /* 展开后就在 y=0 */
#chapterview .coption { position: fixed; bottom: 0; padding: 12px; }                 /* 无 screensafebottom */
```

`contentInset: "never"` + `viewport-fit=cover` 让 WebView 全屏出血，没有别的东西补偿，于是**阅读器顶栏展开后正好压在灵动岛下面（顶栏左右按钮点不到）**，底部选项面板则顶到 Home Indicator。

新增 `safeArea` 站点补丁 + `SangTacAppPlugin.getSafeArea()`：

- 注入 `#chapterview .titlebar{padding-top:var(--status-bar-height) !important;height:auto !important}`（隐藏态的 `top: var(--ntitlebarovl)` = `-(62+45)` = −107px 仍大于展开后的 102px，不影响滑入滑出动画）和 `#chapterview .coption{padding-bottom:calc(12px + var(--screensafebottom))}`；
- 值来自**原生 `window.safeAreaInsets`**，不依赖 `env(safe-area-inset-*)`：站点那两个变量只在 `window.onresize` 里写，而 `onresize` 只由 `overlayStatusBar(true)` 调度，任何一环断了就是 0；
- 只在**站点没给出值（≤0）时**才补，站点自己算出来的值（本次日志 `detect status bar height: 62`）一律不覆盖；
- 顺带幂等补上 `viewport-fit=cover`（站点只在 `setOverlaysWebView` 成功后才加）。

#### (5) 书签点不掉 —— 站点客户端根本没有「取消书签」这条路

`app.api.bookmark`（`app.v2.js:4831-4847`）**只**调 `ajax=addbookmark`；把 `app.v2.js` 里所有 `ajax=` 动作列一遍，没有 un-bookmark（点赞反倒有配对的 `ajax=unlike`）。所以已收藏的书再点一次就是**重新添加**，安卓同样如此。

新增 `bookmarkToggle` 补丁，把按钮做成真正的开关：

- 站点用 `querybookmarkstatus` 的结果给按钮加 `.active`（`app.v2.js:4946-4954`），所以「是否已收藏」直接读 `.btnbookmark.active`，不用额外请求；
- 已收藏时按顺序试 `unbookmark` / `removebookmark` / `delbookmark` / `deletebookmark`（`POST /mobile/jsonify.php`，和 `unlike` 同一形状），**第一个回 `code 100` 的生效**，并清掉 `.active`；
- 每个候选的返回都写进面板（`[BOOKMARK] unbookmark -> {"code":…}`），所以真机上点一次就能知道服务端到底有没有这个接口，而不是继续猜。


### 6.6 第五轮真机反馈（`日志.txt`，685 行）

七项。五项已在站点源码里钉死根因，两项（灵动岛顶栏、储物袋顶栏错位）只拿到"用户描述"，
所以这一轮对它们是**加量测 + 给最保守的修正**，不做猜测式重写。

#### (1) 正文顶部仍是越南语章节名 —— 我们改的是另一个元素，而且在另一个文档里

上一轮的 `fixChapterTitles` 只查 `.chaptername`，但阅读器顶部钉住的静态章节名是
**`.chapternamefixed`**：

```
app.v2.chapterdisplay.js:3294   <div class="chaptertopinfo"><div class="chapternamefixed"></div>…
app.v2.chapterdisplay.js:3579   updateFixedChapterName(c) { … fixed.textContent = c.cdata.chaptername; }
```

更关键的是它**不在主文档里**：阅读器正文和这个顶栏都在一个 `srcdoc` iframe 内
（`getMainContainer()`，`app.v2.chapterdisplay.js:1545-1551`），而注入脚本是
`forMainFrameOnly: true`，`document.querySelectorAll` 永远查不到它。

修法（`scripts/gen-site-i18n.js`，两处）：

- 标题选择器扩成 `.chaptername, .chapternamefixed`，并且 `fixChapterTitles` 认这两个 class 自身；
- 新增 iframe 桥：扫 `document.querySelectorAll('iframe')`，对**同源**的 iframe
  挂 `MutationObserver` + `load` 监听，只跑**标题那一趟**。帧内**不跑** `walk()`——
  片段表是给站点自己的 UI 文案用的，不该盖到小说正文上；
- 帧是懒建且切显示模式会重建，所以按 `[0,300,1000,2000,4000,8000]ms` 重扫，并在主
  MutationObserver 里对新增的 `<iframe>` 立刻 `attachFrame`；
- 顺带把前导零归一（qidian 的 `Chương 03:. Giao phong` → `第3章 Giao phong`，
  原来是 `第03章`）。

#### (2)(6) 灵动岛顶栏 / 储物袋顶栏错位 —— 先量，再改，且不覆盖站点自己的值

站点有安全区模型，但两个地方有洞：

- `#chapterview .titlebar` 自己没有 padding，展开后 `top: 0`，撑起来全靠
  `--status-bar-height` 在那个瞬间是对的；
- `body[ovlwv] .titlebar { height: var(--titlebarovl); padding-top: var(--status-bar-height) }`
  是 **content-box**，实际渲染 `102 + 62 = 164px`，底下多出 62px 空白，
  所有紧跟 `.titlebar` 的内容（例如储物袋页的 tabbar）就被整体推下去 62px。

所以 CSS 换成不依赖站点探测的形式，并让 `--titlebarovl` 恢复它字面上的含义：

```css
--inset-top:    max(var(--status-bar-height), env(safe-area-inset-top))
--inset-bottom: max(var(--screensafebottom),    env(safe-area-inset-bottom))
#chapterview .titlebar        { padding-top: <inset-top> !important; height:auto !important; box-sizing:content-box !important }
#chapterview.showmenu .titlebar { top: 0 !important }
#chapterview .coption         { padding-bottom: calc(12px + <inset-bottom>) !important }
body[ovlwv] .titlebar         { height:auto !important; box-sizing:content-box !important; padding-top: <inset-top> !important }
body[ovlwv] .bottombar        { padding-bottom: <inset-bottom> !important }
```

`max(var, env)` 是关键：站点那两个变量来自 `window.getSafeHeight()`，而它本身读
`env()`，任何一环断了就是 0；`max` 让原生值和站点值谁大听谁的。

同时**加量测**，因为这两条只有用户描述、没有可判定证据。包装
`app.reader.showMenuOl`（`toggleMenu` / `showEditName` / `showTtsSetting` 三条路都会走它），
菜单滑入稳定后打一行：

```
[RECT] #chapterview .titlebar[0..102 h102] #chapterview .coption=… #overlay .titlebar[62..164 h102] .usertop=… status-bar=62/62 env={"top":62,"bottom":34}
```

下一份日志就能直接判：顶栏是 `top: 0`（那就是 padding 没生效）还是负值（`showmenu` 没加上），
储物袋那条栏是 102 还是 164。

#### (3) 正文朗读没声音 —— 站点的句子来源没起来，而它一声不响

设置页的 test 走 `app.tts.test()` → `ttsEngine.requestAudio` + `playQueue`，这条路是通的。
阅读器走的是另一条：

```
app.tts.start() -> player.generateSentences() -> getSentences()          (app.v2.read.js:2486)
                                 -> getCurrentWindow().speaker            (:2488 没有就 toast + return null)
                                 -> display.tokenizeSentence()            (:2494)
                                        -> this.getCurrentWindow().speaker.viRgx   (:2275 直接抛)
player.play() -> sen.prefetch() -> ttsEngine.requestAudioInstant() -> provider.speak()   ← 这条已验证可用
```

`speaker` 由 iframe 里的 `qtOnline.js` 安装，而那个 script 的地址是
`app.net.networkManagerXHR.bestDomain()`（**和页面不同源**，日志里最快的是
`https://sangtacviet.app`）。它没到位时，`getSentences()` 静默返回 null，
`tokenizeSentence()` 在 `speaker.viRgx` 上抛 TypeError —— 两者都不会写任何日志，
表现就是"点朗读什么都没发生"。日志也印证了：20:45:37 点耳机、20:45:38/39 点播放，
**零条 TTS 相关输出**。

新增 `readerTts` 补丁：

- 包装 `app.tts.start`，try/catch 后固定上报 `[TTS] reader TTS start: sentences=<n> provider=<x>`；
  `n == -1` 就说明 `getSentences()` 返回了 null，`n == 0` 说明句子来源是空的 —— 下次一眼分辨；
- 缺 `speaker` 时补一个最小桩（`senToText` / `parseSen` / `highlightOn` / `highlightOff`），
  只为过掉 `if(!wd.speaker)` 那道闸；
- 包装每个 display 实例的 `tokenizeSentence`：站点那版抛错或返回空时，用**章节正文自己切句**
  （`#maincontent` 的 `innerText`，按 `. ! ? , ; 。！？，、；` 和换行切），
  生成的节点带 `toText()`，所以 `Sentence()` 与 `highlight()` 都不会再去碰 `speaker`；
- 同时包装 `app.reader.loadChapterDisplay`，切显示模式后的新实例也自动打上；
- `IosTts.prototype.speak` 加一行 `[TTS] speak result kind=… payload=…`，
  万一 `Không tìm thấy blob` 再出现，能立刻区分是 `!blob` 还是 `typeof blob == 'string'`。

#### (4) 正文底部评论点了没反应 —— `app.reader.bookinfo` 是空的

```js
// app.v2.read.js:298-300
p.q(".btncomment").addEventListener("click", function(){
    app.fun.showComment(app.reader.bookinfo.host, app.reader.bookinfo.id);   // 无保护
});
```

`bookinfo` 只在 `updateHistory()` 的 `bookinfo.php` 异步回调里赋值（`app.v2.read.js:840-850`），
而且那句判断写成了 `this.bookinfo.id != i && this.bookinfo.host != h`（应为 `||`）。
任何绕过它的打开路径都会让这个按钮抛 TypeError。

`pageRepair` 用 document 捕获阶段拦下 `.btncomment`：`bookinfo` 已就绪就完全不管，
为空时先 `getCacheLater('/mobile/bookinfo.php?hid=<id>&host=<host>')` 再调 `showComment`。

#### (5) 下载完点进去连详情页都空白 —— 传进详情页的数据是 undefined

```
app.v2.read.js:3609   var bi = (await populateBookInfo([{id: this.id, host: this.host}]))[0];
app.v2.read.js:3621   this.node.addEventListener("click", function(){ app.fun.openBookWithData(0, bi); });
_page_vip.html:4425   openBookWithData: function(bookid, data) { var page = app.pushPage("bookinfo", data); … }
_page_vip.html:317    <if if="['sangtac','dich'].indexOf(root.data.host) < 0">
```

`populateBookInfo`（`app.v2.read.js:3258-3278`）读的是
`app.storage.cache.get('/mobile/bookinfo.php?...')`；**缓存未命中就返回 `[]`**，
于是 `bi === undefined`，`pushPage("bookinfo", undefined)` 之后模板的第一句表达式就是
`root.data.host` —— 日志里正是它：

```
20:48:19 [TAP] tap div.right
20:48:19 [ERR] onerror TypeError: undefined is not an object (evaluating 'root.data.host') @undefined:1
```

修法两条：

- **预热**：`app.offlineBook.store.data` 里每本书都先 `getCacheLater('/mobile/bookinfo.php?hid=…&host=…')`
  一遍（顺序、有日志），缓存有了 `populateBookInfo` 自然返回真数据；
- **兜底**：包装 `app.fun.openBookWithData`，`data` 缺 `host`/`id` 时**拒绝 push** 并 toast
  提示，而不是推一个必崩的空白页。

#### (7) 冷启动首页慢 —— 我们自己的 HTTP 插件把缓存关了

```swift
config.requestCachePolicy = .reloadIgnoringLocalCacheData   // SangTacHttpPlugin.swift:67
```

站点所有 `app.net` 请求都走这个 session，于是每次冷启动都要重新拉 `lang/zh.json`、
封面图、`page-flip.mp3`、`qtOnline.js` 等本来可以让 WebView 复用的东西。

改成 `.useProtocolCachePolicy` + 显式给 `URLCache.shared` 32MB 内存 / 256MB 磁盘；
需要永远新鲜的端点（`sajax=readchapter`、`jsonify.php`、`bookmanage.php`）在 `perform` 里
按请求覆盖回 `.reloadIgnoringLocalCacheData`。

注意：这只解决"可缓存的东西被我们主动禁掉了"这一半。日志里 `booklist.php` 这类
动态接口本身也要 0.7–2.1s，那部分是服务端和链路，客户端改不掉。

### 6.7 第六轮真机反馈（`日志2.txt`，445 行）

上一轮上报的 `[RECT]` / `[TTS]` 都按预期出现了，这一轮六个问题里五个由它们或站点源码
直接定死。上一轮的 (2)(6)（灵动岛顶栏、储物袋顶栏）本轮没有再被提及。

#### (5) 顶部章节名「都不显示了」—— 站点自己把「不显示」做成了单程票

`app.reader.behaviour.chapter_name_fixed_place.apply()`（`app.v2.chapterdisplay.js:3350`）：

```js
var cs = app.reader.getDisplay().innerWindow.q(".chaptertopinfo")[0];
switch (app.config.reader.chapter_name_fixed_place) {
    case "top":    { cs.style.top = "0";      cs.style.bottom = "unset"; break; }
    case "bottom": { cs.style.top = "unset";  cs.style.bottom = "0";     break; }
    case "none":   { cs.style.display = "none"; break; }   // ← 没有任何地方清掉它
}
```

`display:none` 一旦被写上就再也没人清。改回 顶部 / 底部 只改 `top`/`bottom`，元素仍然
`display:none`，所以"无论设顶部还是底部都不显示"。日志里 21:32:06 / 21:32:17 /
21:32:26 / 21:33:07 四次 `app.config.reader.chapter_name_fixed_place` 就是用户在反复试。

修法（`readerDefaults` 块）：包装 `apply`，调用站点原逻辑后按当前设置把
`.chaptertopinfo` 的 `display` 重新算一遍并补上 `top`/`bottom`，顺带上报
`PATCH chapter name place=… infos=… were-hidden=…`。

**同一轮还修掉了标题翻译的副作用。** 上一轮是直接在 DOM 里把 `.chapternamefixed` 改成
中文，但站点靠"值有没有变"来决定要不要做重活（`chapterdisplay.js:3584`）：

```js
var oldName = fixed.textContent;
if (oldName != name) { fixed.textContent = name; this.recycle(c); app.reader.updateHistory2(); }
```

DOM 里永远是中文、`name` 永远是越南语 ⇒ 每次滚动都判定"变了" ⇒ 每帧 `recycle()` +
`updateHistory2()`。这一轮改成在**名字的生产者**上翻译：包装 `app.reader.getContent`
（`app.v2.read.js:602`，离线章节、`getContent2`、网络三条路都从这里出去），只改
`cdata.chaptername`。`createPage` / `resetPageHtml` / `getPrependChapterNameHTML` /
`updateFixedChapterName` / 底栏全部读这一个字段，于是比较恒等、重活不再触发，DOM 那一趟
保留成兜底。

#### (2) TTS 还是没声音 —— 站点的句子过滤器只认 ASCII

日志把因果写成了两行：

```
21:26:43 [TTS] tokenizeSentence fallback -> 23 sentence(s)
21:26:43 [TTS] reader TTS start: sentences=0 provider=ios
```

句子造出来了 23 条，进队列后变成 0 条。中间只有一道过滤器
（`app.v2.read.js:2357`）：

```js
this.hasText = function () { return this.text.match(/\w/); }
```

`\w` 只匹配 ASCII 词字符，中文句子一条都过不去。而站点自己的句子源
（`PageFlipChapterDisplay.tokenizeSentence`，`chapterdisplay.js:2235`）要求
`<i>` 是 `<p>` 的子节点，实际返回的章节 HTML 里 `<i>` 是 `</p>` 的**兄弟**，所以它返回空
数组——两边都不通，于是"点播放没声音、也不报错"。

修法：站点那一趟仍然先试；为空时用章节正文兜底，并且**给每条句子加一个 ASCII 前缀
`stv0`**，让它通过 `hasText()`；我们自己的 provider（`ttsProvider` 块）在调用
`AVSpeechSynthesizer` 之前把前缀剥掉，所以不会念出多余内容。同时上报
`fallback source: N chars -> M sentence(s)`、`site tokenizeSentence -> N`、
`reader TTS start: sentences=N first=M chars`。

语种也一起修了：`NativeSpeech.availableVoices()` 原来硬过滤 `vi*`，`voice(for:)` 也永远
回落到 `vi-VN`。中文正文配越南语发音人基本等于没声音，所以现在语音列表覆盖 `vi` + `zh`，
并且**只在所选发音人的语种和文本语种一致时才用它**，否则按文本语种（CJK → `zh-CN`）挑。

#### (1) 底部首页/搜索/社区/用户一直显示 —— `#overlay` 比 `#mainview` 矮

```css
#overlay { position: fixed; top: 0; width: 100vw; height: var(--vh100); z-index: 100 }  /* app.v2.css:262 */
```

`#mainview`（`#mainnavbar` 就在里面）的高度则由站点自己的 `window.onresize` 写成
内联 `mainview.style.height = "100vh"`（`app.v2.js:4507`），而 `--vh100` 来自
`visualViewport.height`（`:4484`）。两者只要有一次不一致、`--vh100` 偏小，`#overlay`
就盖不满，`#mainview` 底部那条（就是主导航）露出来，翻页进详情页也照样露。重启后
`onresize` 重新采样一次，所以"退出重进又恢复正常"。

修法（`safeArea` 块，键盘弹出时除外——站点是故意缩小的，用 `body[keyboardopen]` 标记）：

```css
body:not([keyboardopen]) #overlay     { height: max(var(--vh100, 100vh), 100vh) !important }
body:not([keyboardopen]) #overlay > div { height: max(var(--vh100, 100vh), 100vh) !important }
```

`[RECT]` 同时加上 `#overlay`、`#mainnavbar` 的实测框、`viewport=` 和 `--vh100` 的解析值，
下一份日志可以直接判定（`#overlay` 底边 < viewport 就是没盖住）。

#### (4) 下载的书点进去「书籍信息缺失」—— 上一轮的兜底拦住了，但缓存还是空的

上一轮加的 `openBookWithData` 守卫确实生效了（日志
`[ERR] openBookWithData called with no book data (bookid=0)`），可它只是把"空白页"换成
"提示"。真正的因是 `populateBookInfo()`（`app.v2.read.js:3258`）只读缓存、未命中直接返回
`[]`，而 `DownloadManager` 的构造**在下载刚开始时**就调 `onUpdate()` → `render()`
（`:3481` → `:3609`）读这个缓存，那时候谁都还没写进去；`render` 里
`app.fun.openBookWithData(0, bi)` 的 `bi` 就被永久固化成了 `undefined`。

修法（`pageRepair` 块）：按生产者顺序预热，而不是事后拦截——

- 包装 `app.BookDownloadManager.prototype.render`，先 `getCacheLater(bookinfo url)` 再渲染
  （`render()` 本来就是被 `await` 的，`app.v2.read.js:3432`）；
- 包装 `app.offlineBook.getDownloadBooks`（储物袋下载列表走这里 → `populateBookInfo`），
  先把 `store.data` 里每本书都预热一遍；
- 保留 3 秒一轮的 `warmStore()` 扫描，覆盖"启动之后才下载"的书；
- 上一轮的 `openBookWithData` 守卫保留成最后一道防线。

#### (6) 覆盖安装后设置还是丢了 —— 恢复写进了站点根本不读的库

站点 `app.v2.js:531`：

```js
if (Capacitor && Capacitor.Plugins.Preferences) { app.storage.get/set = prefs.get/set }  // iOS 走这条
else                                            { app.storage.get/set = localStorage }
```

Capacitor 自带 Preferences，所以 iOS 上 `config.reader` / `config.ux` / `tts.setting` 这些
键全在 **UserDefaults**，而上一轮的恢复是 `localStorage.setItem` —— 备份写对了，回程扔了。
日志证据：

```
21:24:23 [SETTINGS] keychain restore: 0 of 3 backed-up key(s) written back
```

（旧消息把"值不可用"和"本地已有值"两种跳过混在一个数字里，看不出是哪种，这一轮也一并
拆开了。）

修法：恢复改走 `app.storage.get` / `app.storage.set`（`siteStorage()` 等 `app.storage`
就绪再动手），并逐键上报结果：

```
[SETTINGS] keychain restore: N written, M kept [key:len …], K unusable [key:typeof …], of T backed-up key(s)
```

策略仍是"站点库里已有值就不动它"——重装后容器是空的，那才是这个块存在的场景。

