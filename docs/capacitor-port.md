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
6. `__stvDiag` 诊断面板是临时设施，现场问题定性完成后应移除（`SitePatch.diag` 整块 + `SangTacHttpPlugin.report`）；`tabProbe` 同批退役，见 §6.11 (4)。
7. 站点 `filterDownloadingChapters`（`read.js:3445`）参数遮蔽导致跨任务去重失效 —— 低危、未改（改动会牵动 `total` 口径，见 §6.11 (2)）。
8. ~~储物袋顶部 tab 的错位成因未定~~ —— **已定性**：不是位移错位，是末页「Đang kích hoạt」本来就没有数据（服务端 `act` 为空数组，见 §6.11/§6.12 (6)）。`tabProbe` 探针已补 `panes`/`activate`，若后续发现该有数据再收口。
9. **系统离线翻译要 iOS 18+ 且语言包已下载**（见 §6.13）。iOS 15-17 上 `App.translationStatus` 如实回 `unsupported`，`commentTranslate` 会自动改用联网引擎（免密钥微软通道，或用户自备 Key），因此该功能在旧系统上不是不可用，只是必须联网。
10. **自备 API Key 存在站点存储里**（`app.storage` → Capacitor Preferences → UserDefaults），并被 `settingsBackup` 一并镜像进 Keychain（`stv.translate.settings`）。日志只记引擎名，不打印 Key；但它不是独立的加密存储，介意的话请用可随时吊销的 Key。

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


### 6.8 第七轮真机反馈（`日志.txt`，800 行）

上一轮的修法全部在日志里得到验证：`[RECT] ... #overlay[0..874 h874] #mainnavbar[789..874 h85] viewport=874 vh100=874px`
（底栏不再穿透）、`[PATCH] chapter name place=top infos=3 were-hidden=3`（单程票被清掉）、
`[TTS] fallback source: ... -> N sentence(s)` 后面跟着真实音频（`audioBuffer.duration: 6.78s`）。

#### (1) 章节名只有「第 N 章」是中文 —— 站点协议里有中文原名，只是没走这条路

`readchapter` 的 `chaptername` 永远是越南语机器翻译，即使正文已经是中文
（`transmode=chinese`）。但章节列表响应里有 **`oridata`**：

```js
// app.v2.js:270
if(x.oridata && app.language != "vi"){
    x.data = x.oridata;
    if(app.language != "zh"){ x.data = await translateWithGoogle(x.data, "zh", app.language); }
}
```

也就是说站点自己就有中文原名，按 `cid` 关联即可。做法是在名字的生产者
（`app.reader.getContent`）上补一次查表：

- 首次打开某本书时后台拉一次 `/index.php?ngmar=chapterlist&...&sajax=getchapterlist`，
  解析 `oridata`（格式与 `data` 相同：`flag-/-cid-/- 标题 -//-`），只保留含 CJK 的项，
  缓存到内存（**不 await**，否则首章要等一个 100KB 响应）；
- 命中时把 `cdata.chaptername` 换成 `第N章 <中文原名>`（原名自带编号则不再重复加）；
- 列表到达后回写已经渲染出来的标题：主文档 `.chaptername`、iframe 里的
  `.chapternamefixed`，同时更新 `cdata`，避免 `updateFixedChapterName()` 的
  `oldName != name` 守卫又开始每帧 recycle；
- 没有 `oridata`（或里面不是中文）时原样保留，并上报 `TITLE no original chapter names ...`。

#### (2) 朗读读的不是当前章节 / 退出正文还在读 / 测试还是越南语

- **读错内容**：阅读器 iframe 里根本没有 `#maincontent`（pageflip 模板只建了
  `.chaptertopinfo`、`#mainscroller`、`#dragbar`），而 `#mainscroller` 里同时挂着
  上一章、当前章、下一章，所以读 `body` 就是读"碰巧挂载着的那几章"。改成读当前章的
  `.contentcontainer`（`chapterdisplay.js:3615` 每章一个），拿不到才退回文档。
  日志同时暴露了另一面：`[TTS] fallback source: 0 chars` —— display 重建的瞬间
  文档是空的，退回分支正是为这个时刻准备的。
- **退出后继续读**：站点没有"关掉朗读"的入口。包装 `app.popPage`，pop 前
  `#chapterview` 在、pop 后不在，就 `player.stop()` + `ttsEngine.clearQueue()`；
  阅读器自己 push 的子页（目录）不会让 `#chapterview` 消失，所以不会误停。
- **测试语句**：`app.tts.test` 里写死越南语样例（`app.v2.read.js:3174`），照抄五行
  改成中文；provider 的 `props` 描述、发音人兜底名、`engineList` 里带越南语品牌名的
  项也一并中文化；再包装 `app.tts.openSetting` 上报设置页实际显示的
  `options=[...] engines=[...]`，免得再靠猜。

#### (3) 下载报「无法读取数据」，没有继续/删除按钮

日志把原因写得很清楚：

```
22:53:41 ... download=true -> 200 ... 8200b     ← 前 18 章正常
22:53:57 ... download=true -> 429 ... 7183b     ← 之后全是 429（HTML 错误页）
```

`downloadChapter`（`app.v2.read.js:3556`）对非 JSON 响应只重试 3 次、间隔 200/300ms，
`JSON.parse` 失败即抛 `Không thể đọc dữ liệu`；而 `start()` 是**一次性并发 3 个、无间隔**
（`:3491`、`:3519`）。所以修法是在请求起点限速：

- 包装 `DownloadManager.prototype.downloadChapter`，用全局闸门保证两次请求起点至少相隔
  900ms（站点自己的内部重试也会经过这个包装，所以重试同样被限速）；
- 一旦有请求失败，把间隔放大到 2500ms 并上报 `[DOWNLOAD] download failed, widening the gap`；
- 行内按钮：站点把「暂停/重试」藏在长按菜单里，且**根本没有删除任务**的入口。包装
  `render()` 后往每行追加「暂停下载/继续下载」和「删除任务」两个按钮
  （`stopPropagation`，删除 = 从 `app.bookDownloaderList` 摘掉 + 移除节点）。

### 6.9 第八轮反馈：设置跨重启丢失、首屏外壳、许可

#### (1) 设置「完整退出应用后重新进入全没了」

`app.v2.config.js` 的时序是关键：

```js
await onDbLoad.waitForLoad();                                   // 立即 resolve
var loadedReaderSetting = JSON.parse((await app.storage.cache.getFile("config.reader")) || "{}");
app.config._reader = $.extend({}, app.config.readerDefault, loadedReaderSetting);
```

它紧跟 `app.v2.js` 求值之后就读 `config.reader` / `config.ux` / `config.comicReader`，
而我们的 Keychain 恢复是一次原生往返（查询 + 每个键 `get`/`set`），很容易跑输。
一旦跑输，运行中的应用已经落在默认值上；更糟的是默认值随后会被任何一次 setter
写回存储，把用户的设置覆盖掉。

修法：恢复完成后除了写存储，还把值**回灌进运行中的 `app.config`**
（每个键的 setter 会同步 `_reader` 并重存，所以 UI 与存储保持一致），并上报
`SETTINGS live config updated: N key(s)`。

恢复摘要行也改成可判读的形式：

```
[SETTINGS] keychain restore: N written, M kept [key:len …], K unusable [key:typeof …], of T backed-up key(s)
```

- `written > 0` ⇒ 启动时存储是空的（容器被换掉 / 写入没落地）；
- `kept` 列表里的 `key:len` ⇒ 存储本来就有值，问题不在恢复。

下一份**启动日志**（重启后立刻复制面板）就能定死是哪一类。

#### (2) 首屏要等很久才出现底部标签

站点 HTML 本身就是完整的 —— `_page_vip.html` 里 `<tab id="mainview">` 已经包含
`<tabbar id="mainnavbar">` 和四个 `tabitem` —— 只是要等站点 CSS 和约 750KB 未压缩
JS（`app.v2.js` 261KB、`chapterdisplay` 158KB、`read` 145KB、`comicprovider` 80KB、
`stv.tts` 47KB…）到齐。设备日志里 `db loaded`（即 `app.v2.js` 求值完）出现在文档开始
后第 8 秒。

新增 `bootShell` 块：文档开始就往 `<head>` 注入一段最小样式，把这段空白画成应用的
样子 —— 主题背景、底部标签栏布局、淡出的「载入中…」提示。样式全部限定在
`html.stv-boot` 下，一旦站点自己的 `app.v2.css` 出现在 `document.styleSheets`
（或 `app.config` 已经建立，作为文件改名的兜底）就摘掉这个 class，因此不会和真实 UI
抢规则。同时按 0/1/3/6/10/20s 采样上报：

```
[BOOT] +Nms stylesheet: app=yes/no config=yes/no navbar=NNpx
[BOOT] shell released at +Nms (app.v2.css)
```

顺带否掉一个看起来更直接、实际没用的方案：把上次可用域名固化进
`app.config.ux.app_domain`。`networkManagerXHR.bestDomain()`（app.v2.js:933）仍然要等
`this.domains` 被探测填好，`app_domain` 只决定存活域名里选哪个，省不掉那几秒探测。

#### (3) 许可证

新增 `LICENSE`：个人非商业同源开源许可 1.0（SPDX
`LicenseRef-SangTacReader-NC-SA-1.0`），四条核心约束 —— 个人自用允许、任何商业用途
禁止、必须保留许可/版权/署名并标注修改、分发修改版必须以同一许可公开完整源代码。
只覆盖本仓库作者编写的代码与文档；站点内容与第三方素材不在授权范围内。
`README.md` 增补许可证一节，四个 `package.json` 加 `license` 字段。

### 6.10 第九轮反馈（`日志2.txt`，408 行）：镜像 code 7、下载行按钮、记录与设置

#### (1) 正文打不开，提示「Thiết bị không phù hợp hoặc phiên bản ứng dụng đã lỗi thời」

这句是站点自己的兜底文案，不是真因（`app.v2.read.js:747`：`x.err || x.info || "…"`）。
真因在响应体里：

```
[Http] GET https://dns1.stv-appdomain-00000001.org/?sajax=readchapter&h=qidian&bookid=…&key=…
       -> 200 text/html … 24b in 1271ms {"code": 7,"time": 1000}
```

**每个** `readchapter` 都是 `code 7`，而且换书、换 host（qidian/fanqie）都一样；同一份日志里
下载路径（`sangtacviet.app/index.php?…&key=stvmobilereader&download=true`）20/20 全部
`code 0`，上一轮的日志（`日志.txt`）里阅读路径走的是 `sangtacviet.com`，也全部 `code 0`。

差别只有一个：**域名**。`app.net.networkManager.bestDomain()`（app.v2.js:933）只按
`/warp.php` 的探测延迟排序，而三个镜像并不等价：

| 镜像 | warp.php | readchapter |
| --- | --- | --- |
| `sangtacviet.com` | `yes` | 正常 |
| `dns1.stv-appdomain-00000001.org` | `no` | `code 7` |
| `sangtacviet.app` | `no` | 未测 |

这台设备上 dns1 最快（1408ms vs 3503ms），于是赢下竞速，阅读全挂；`grantcontext`（章节
密钥）在同一个域名上照样 200 —— 所以问题不在密钥、不在 Cookie、不在 `x-stv-transport`。

修法不写死域名黑名单，而是**用服务端自己的回答来判定**（新增 `domainFailover` 块）：

1. `bestDomain()` 被包装：已经回过 `code 7` 的镜像不再被选中（按站点自己的存活/延迟排序
   取下一个，`defaultDomains` 兜底）；
2. `code 7` 在 `app.reader.getContent` 出口被拦下 —— 那是所有章节的唯一入口
   （chapterdisplay.js:788 / :1812 / :3680）。拦下后封禁该镜像、清掉 `app.reader.cachekey`
   （密钥是刚被抛弃的那个镜像签发的，不清掉 `getKey()` 会继续复用）并重新取一次章节。

用户看到的结果：第一次翻章会多一次往返，之后整个会话都走可用镜像；只有所有镜像都拒绝时
才保留站点原本的报错弹窗。面板上报：

```
[DOMAIN] mirror https://dns1.stv-appdomain-00000001.org banned: readchapter answered code 7
[DOMAIN] refetching qidian/1045345742 chapter 847372113 after code 7
```

#### (2) 下载页的「暂停 / 删除」点不到，一点就提示「书籍信息缺失」

上一轮把两个按钮追加到 `DownloadManager.render()` 返回的节点上，但站点模板
（`_page_vip.html` 的 `view-bookdownloadjob`）与 CSS 决定了那个位置点不到：

```css
.bookrowcont { position: relative; height: 77px; }   /* 固定高 */
.bookrow     { position: absolute; }                 /* 行本体脱离文档流 */
```

控制条是 `.bookrowcont` 里的普通流子元素，而 `.bookrow` 是定位元素 —— **定位元素画在普通流
之上**，于是整条控制条被行本体盖住，手指落点始终是行本体，触发的是站点自己的
`node.addEventListener("click", … openBookWithData(0, bi))`。日志逐条印证：

```
[TAP] tap div.status / div.pgbarinner / div.right / div.bookrow
[ERR] openBookWithData called with no book data (bookid=0) -- refusing to push a blank detail page
[LOG] 书籍信息缺失，请返回后重试
```

修法两条：

1. **让控制条真的可点**：`.bookrowcont` 放开（`height:auto; min-height:77px`），控制条本身
   `margin-top:77px` 让出定位行占的 77px，再 `position:relative; z-index:5` 画在定位行之上；
2. **让行本体点了也有用**：`render()` 捕获的 `bi` 在缓存未命中时是 `undefined`
   （`populateBookInfo()` 只读缓存、静默返回 `[]`，app.v2.read.js:3258 → :3609），而那个
   匿名监听器无法解绑。于是在 `document` 捕获阶段接管：行的 `.tname` 为空即说明站点没拿到
   书籍信息，此时自己解析 bookinfo 并打开详情页，而不是让守卫弹「书籍信息缺失」。
   `.tname` 有内容（站点自己拿到了数据）的行一律放行，控制条自身的点击也不拦。

#### (3) 下载记录与设置「关闭应用重进就没了」

启动日志里 7 个键**全部** `(store was empty)`：

```
[SETTINGS] restore config.reader -> 497 chars (store was empty)
…
[SETTINGS] keychain restore: 7 written, 0 kept [], 0 unusable [], of 7 backed-up key(s)
```

`app.storage` 在 iOS 上是 `@capacitor/preferences`（UserDefaults，`package.json` 里有这个
依赖），正常情况下重启不会清空 —— 所以要么容器被换掉（每次侧载新构建都会），要么写入没
落地。两种情况都指向同一个结论：**Keychain 是这台设备上唯一真正持久的地方**，而上一轮只把
设置镜像进去，没管下载记录。

于是把镜像面扩大到 `offlineBook`（`app.objectStore("offlineBook")` 的列表，也就是下载记录
本体，app.v2.read.js:3189；章节正文键 `offlineBook_<host>_<id>_<cid>` 体积大且可由站点在
线补读，故意不镜像）。同时补上三处可判读性：

- `read()` 区分「存储回空值」和「存储读失败」，摘要行给出
  `unreadable [key:err …]`；
- 写回后**回读校验**，后端「接受写入然后忘记」会被记为
  `not-persisted [key:len …]`（这类后端正是整个块要防的东西）；
- 实时配置回灌改成等 `app.config.reader` 出现后再做（设备上 `app.v2.config.js` 约 +10s
  才建好读写器，上一轮把它挂在恢复链尾，日志里因此没有 `live config updated` 行），
  并且**只回灌本次真正写入的键** —— 存储里本来就有的值比备份新，回灌会把用户后来的修改
  顶掉。

新的摘要行形态：

```
[SETTINGS] keychain restore: N written, M kept [key:len …], U unreadable [key:err …],
           P not-persisted [key:len …], K unusable [key:typeof …], of T backed-up key(s)
```

#### 验证

`check-ios-shim`（13 块 / 138075 字节 / 16 markers）、`test-site-patch`（142 条断言，新增
`readchapter mirror failover` 10 条、`download row controls and missing book info` 10 条、
设置镜像与可判读性 4 条）、`gen-site-i18n --check`（456 labels / 35 fragments）全绿。

### 6.11 第十轮反馈（`日志.txt`，261 行）：存储读取口、下载范围与计数、历史网格热区、储物袋 tab

上一轮的三条按预期收口：`readchapter` 全部 `code 0`（`[DOMAIN]` 故障转移在位），下载行控制条
可点，设置靠 Keychain 镜像 + 实时回灌活着。这一轮的四件事，第一件是**真根因**。

#### (1) 站点自己的 `app.storage.get` 永远返回 `undefined`

```
09:36:25 [SETTINGS] restore config.reader -> 517 chars (store was empty)
09:36:25 [ERR] restore readback mismatch for config.reader (wrote 517 chars, read back 0)
…
[SETTINGS] keychain restore: 7 written, 0 kept [], 0 unreadable [], 7 not-persisted […]
```

`app.v2.js:536`：

```js
app.storage.get = async function(key){
    return await prefs.get({ key: key }).value;
}
```

成员访问先于 `await` 求值，所以这是 `await ((prefs.get({key})).value)` —— **Promise 的
`.value` 是 `undefined`**，函数对任何键都返回 `undefined`，包括它自己刚写进去的键。

为什么安卓版没这个问题：APK 没有 `@capacitor/preferences` 依赖，站点走 `else` 分支用
localStorage，读写都正常。我们这个包 `package.json` 里装了这个依赖（CI 的
`packageClassList` 里确实有 `PreferencesPlugin`），于是**跑的是坏的那条分支**。

影响面就是"站点自己写的东西自己读不回来"：`config.reader` / `config.ux`（全部设置）、
`offlineBook`（下载记录）、`readhistory`、bookinfo 缓存。所以上一轮"设置/下载记录跨重启丢失"
的真根因不是容器被换掉 —— 写入一直是成功的，读取一直是空的。

修法（新增 `storageAccessor` 块）：**替换**访问器（不能包装，原函数在自己体内就把值丢了），
按 `@capacitor/preferences` 的契约解包 `{value}`；没有 Preferences 时（localStorage 分支）
直接放行。同时立一条顺序约束：

- 访问器修好后置 `window.__stvStorageAccessorPatched`；
- `settingsBackup` 的恢复**必须等这个标志**。否则"读失败"和"存储为空"无法区分，会把
  Keychain 里的旧备份写到用户后来改过的设置上面。等标志之后，存储里有值就是 `kept`，
  备份只在真的空时才写。

`offlineBook` 再补一道实时回灌（与 `applyToLiveConfig` 同套路）：站点
`app.offlineBook.store.load()`（`app.v2.js:624`）通常在恢复之前就跑完了，而且修复前它读到的
永远是空，所以把恢复出来的记录直接推进 `app.offlineBook.store.data`。

#### (2) 下载：默认 4-20、实际下到 4-23

`_page_vip.html:4939-4953`：

```js
var ccount = data.chaptercount;                  // 取到了，下面从没用过
var index = readed ? ((readed.chapterIndex||readed.index)+1) : 1;
popupTemplate.data.numstart = index;             // 读到第 3 章 → 默认 4
popupTemplate.data.total = 20;                   // 固定「20 章」
```

`app.v2.js:2768-2783` 把第二个框当**章数**用：

```js
var lists = clist.slice(startnum, startnum + total);   // 4..23，不是 4..20
```

所以"选定的范围"和"实际下载的范围"本来就差一个语义：第二个框是章数、不是结束章，而且写死 20。
修法（`pageRepair` 内新增 `patchDownloadRange`）：第二个框改成 `numend`（结束章），占位符与
引导语进词典（`Nhập khoảng chương để tải:`→输入要下载的章节范围：、`Đến chương`→结束章节），
动作改成 `clist.slice(start-1, end)`，超界收敛到 `clist.length`；默认值在
`app.context.showPopup` 这个"值落到输入框"的接缝上改成 **1 → chaptercount**（站点在
`showDownloadBook` 里先塞了"阅读进度+1 / 20"，那里无法从外部改）。

日志里的 `1/20 … 20/20 … 21/20 … 32/20`（同一个 cid 抓 3 次）还有第二个成因，是**我们自己的
锅**：09:37:34 与 09:37:36 两次 `tap button`（暂停/继续）让 `manager.start()` 在上一轮循环还在
`await` 时被再进一次，两条循环跑同一份 `this.chapters`。现在 `start()` 加了重入闩：循环在跑时
再进来的 `start()` 直接忽略；**只有暂停中的那次（真·继续）会被记下来，等旧循环退出后重放一次**。
暂停标志在重放前一直保持置位，否则旧循环不会 `break`，会直接跑成第二条循环。

删任务后 `DOWNLOADING (n)` 不刷新：计数器由 `app.bookDownloaderList.onUpdate()` 从列表长度
重画（`_page_vip.html:2294`、`:4044`），我们的删除按钮 splice 完没调用它。现在调用。

站点侧还有一个低危 bug 记录在案、**未改**：`filterDownloadingChapters`（`read.js:3445`）用
`var i` 遮蔽了 bookid 参数，`bookDownloaderList[j].id != i` 比的是数组下标，跨任务的去重永远
不成立。改它要连 `total` 的口径一起动（进度条按 `downloaded/total` 算），收益不抵风险，而观测
到的重复下载已由重入闩消掉。

#### (3) 首页-历史：点空白命中第一行

`app.celoader.infbookgrid`（`_page_vip.html:3873`）渲染完每个格子后：

```js
var h = addedElements[0].scrollHeight;
for (...) { addedElements[i].style.height = h + "px"; }
```

**所有格子被强制成第一个书格的高度**，而 flexbox 本来就已经把一行的格子拉到最高的那个。格子
同时就是点击热区（`:3897` 的 `openBookWithData`），于是矮卡片下面那条空白仍然属于那张卡片 ——
第一本书标题换行最多、它撑高了 `h`，每行都继承这段可点的空白。

修法（新增 `gridLayout` 块，纯 CSS）：`.f-3-col/.f-sm-4-col/.f-md-6-col{align-items:flex-start}` +
`.booksquarecont{height:auto !important}`（压掉内联行高）+ `.booksquare .tname` 两行截断
（站点本来写了 `-max-height`，被注释掉了）。

#### (4) 储物袋顶部 tab：先测，再修

六个 `tabitem` 对六个 `tabview`（`_page_vip.html:1914-1938`）结构是齐的，切换由 `/stv.ui.js`
的 `ui.smtab` 负责 —— **这个文件不在仓库里**（`_dl_*` 只有 app.v2.\*/stv.tts.js），指针与
`tabdiv` 的位移算式看不到。两个候选成因需要不同的修法：

- 几何：指针与位移按过期或写死的宽度算（模板里 `tabpointermark{width:85px}`），末页落到空白；
- 数据：末页「Đang kích hoạt」由 `inv.activate` 填（`app.v2.js:7760`、`:7828`），服务端不给
  `act` 时它本来就是空的。

新增 `tabProbe` 块（临时设施，和 `diag` 一起退役）：点任意 `tabitem` 时上报 tabbar 项数与各项
`offsetLeft+offsetWidth`、指针的 width/transform、`tabdiv` 的 transform、以及末页子节点数，
点击前与 400ms 后各一行：

```
[TAB] before index=1/2 items=[0+60 60+90] mark=85px translateX(0px) div=translateX(0px) views=2 lastview=0 child(ren)
[TAB] after  …
```

一份日志即可定死是几何还是空面板。

#### 验证

`check-ios-shim`（16 块 / 154877 字节 / 19 markers）、`test-site-patch`（175 条断言，新增
`site storage accessor` 9 条、`download range dialog` 8 条、`download task lifecycle` 7 条、
`grid tap targets` 4 条、`inventory tab probe` 5 条）、`gen-site-i18n --check`
（458 labels / 35 fragments）全绿。

### 6.12 第十一轮反馈（`日志2.txt`，321 行）：下载来源/归类/节奏、历史网格、键盘遮挡

上一轮的四项按预期收口，日志直接给出证据：

```
[STORAGE] app.storage.get reads the Preferences result properly
[SETTINGS] keychain restore: 0 written, 8 kept [… offlineBook:260 …]
[DOWNLOAD] range dialog defaulted to 1-310
[DOWNLOAD] range 1-10 of 310 -> 10 chapter(s)
```

存储读取口修好之后，"存储为空"变成"8 个键全部 kept" —— 设置与下载记录现在是站点自己读回来的，
Keychain 只是兜底。

#### (0) 先修我上一轮引入的回归

```
[ERR] onerror TypeError: null is not an object (evaluating 'pop.q(`.${template.focus}`).focus') @app.v2.js:2254
```

`app.context.popup()` 会无保护地对 `template.focus` 取元素并 `.focus()`
（app.v2.js:2252-2257）。上一轮把第二个输入框改名成 `numend`，但
`app.context.menu.downloadchapter.focus` 还是旧章数字段的 `"total"`，于是每次打开下载框都抛一次。
现在 `focus = 'numend'`。

#### (1) 下载来源：站点早就支持，只是下载框没有

日志里打开小说详情时那两行就是来源表：

```
{"data":[{"host":"qidian","id":"1034915599","chaptercount":"310"},
         {"host":"trxs","id":"11728","chaptercount":"253"},
         {"host":"trxs2","id":"11728","chaptercount":"253"}],"code":400}
```

它来自 `app.fun.openChapterList`（page-vip:4429-4472）：`/mobile/bookmanage.php?act=getallhost
&name=<书名>&author=<作者>` → `d.data` → 每个来源建一个 `tabitem`（`${host}(${chaptercount})`）。
**章节目录页早就能切来源，只有下载对话框没有。**

修法：对话框加 `<select class="dlsource">`，在 `app.context.showPopup` 那个"值落到输入框"的接缝上
用同一个接口填充（`attach` 就是 book，取 `name`/`author`），当前来源置顶选中；`startdownload`
优先读选择框的 `host|id`，切换来源时把结束章默认值换成该来源的 `chaptercount`（不同镜像章节数不同）。

#### (2) 下载完成不归到「已下载」+ 已下载没有删除按钮

站点的完成分支只做两件事（app.v2.read.js:3521-3524）：

```js
if(this.total == this.downloaded){ this.setStatus("Hoàn thành"); this.book.save(); }
```

不把任务从 `app.bookDownloaderList` 摘掉、不通知页面；而「已下载」列表是 `bookdownloaded`
视图加载时**一次性**拉的（page-vip:4038-4076，`loader()` 只跑一次，下拉刷新被注释掉）。删除入口
也不存在：`bookdownloadedrow`（page-vip:4014-4037）只渲染封面/书名/`Đã tải N/M`，而站点有
`OfflineBook.deleteAll()`（app.v2.read.js:3368，逐章删正文）与 `delete()`（:3314，摘记录）却
没有任何 UI 调它们。

修法：完成时摘出列表 + `onUpdate()` 刷新 `(n)` + 移除该行 + 往「已下载」区追加一行（复用
`app.celldisplay.bookdownloadedrow(null, data)`，与 loader 同一路径，落在 DOWNLOADED 标题之后）；
包装 `app.celldisplay.bookdownloadedrow` 给每行加「删除」按钮 → `deleteAll()` → `delete()` →
`store.save()` → 移除行。注意两个都要调：`deleteAll()` 只删章节正文，不删记录。

#### (3) 下载慢与限流：站点循环的两处问题

- **慢**：站点 `start()`（app.v2.read.js:3504-3520）每 3 章一批、批间 `await sleepFor(3000)`。
  上一轮日志 10:24:33→10:24:49 下 10 章用了 16s，其中 3 次 3s 睡眠占 9s。`sleepFor` 是
  app.v2.js:8725 的 **`const`**（不在 `window` 上、也不能重新赋值），所以只能替换循环本身。
- **限流**：`downloadChapter`（:3533-3582）对 429（HTML 体、JSON.parse 失败）只重试 3 次、
  间隔 200ms；一旦最终抛错，`start()` 的 catch 会 `isBreak = true` **中断整个任务** ——
  剩下的章节永远不下。这才是"先保证能完整下载"的真正缺口。

修法：`start()` 换成我们自己的循环（保留 3 并发与 `total/downloaded` 口径）：去掉批间睡眠
（900ms 起步闸门已经在按请求间隔限速）、单个章节失败只记入 `failed` 并继续、完成后走 (2) 的
归类；`downloadChapter` 包装改成退避重试（1.5s/3s/6s，共 3 轮），失败时把闸门从 900ms 放大到
2500ms、连续 10 次成功后逐步回落到 900ms。这样站点那个 `isBreak` 中断分支永远不会被触发。

面板新增 `[DOWNLOAD] retry N/3 …` / `throttled (…) gap widened to 2500ms` / `gap relaxed to
Nms` / `chapter … gave up`，下一份日志能直接看出限流阈值。

#### (4) 历史网格：一行 3 个 + 行间大空白

两个 tab 是两套布局：

| | 容器 | 列数 |
|---|---|---|
| 历史 | `infbookgrid`（page-vip:3873/3877）→ flex + `f-3-col`（`flex:0 0 33.33%`） | 恒 3 |
| 书签 | `BookGrid`（bookdisplay.js:101/110）→ `<div class="book-grid-parent grid g-100px">`（page-vip:2109） | CSS grid `repeat(auto-fill,minmax(100px,1fr))`，按宽度自动塞 |

空白来自**行拉伸**：`infbookgrid` 在 refresh 模式给容器设了 `height:100%`（page-vip:3936），
flex 多行容器的 `align-content` 默认 `stretch`，内容不足一屏时剩余高度被摊到行与行之间。书签那边
没这问题，因为 `celldisplay.bookgrid` 给容器写死 `grid.style.height = scrollHeight + "px"`
（page-vip:3857）。

修法：`gridLayout` 块新增 `.stv-bookgrid4`（`display:grid` + `repeat(auto-fill,minmax(100px,1fr))`
+ `align-content:start`，并清掉 `.f-3-col > *` 的 `max-width:33.33%`），通过包装
`app.history.setContainer`（infbookgrid 的唯一调用方）把该类打在历史网格容器上，因此只影响历史 tab；
全局另加 `align-content:flex-start` 兜住其它 flex 书格。

#### (5) 键盘遮挡下载输入框

站点的机制是 `keyboardWillShow` 时把 `--nkbheight: -<kbHeight>px` / `--popwithkb: 5%` 写到
`:root`（app.v2.js:4509-4531），css:1605-1608 的 `.popupedit[hasedit]` 靠这两个变量抬起来。
`KeyboardPlugin` 确实在 `packageClassList` 里，但日志里没有任何键盘行，无法判断变量是否落地、
或 `position:absolute` 是否被视觉视口吃掉。

修法：新增 `keyboardPopup` 块，不再赌站点变量 —— `visualViewport` 与 Capacitor 事件双通道检测
键盘高度，键盘弹起时直接接管 `.popupedit[hasedit]` 的纵向定位（`transform: translate(-50%,0)`
抵消站点的位移，`bottom: kb+10px` 顶在键盘上方，并把弹窗与 `.popupedit_body` 的 `max-height`
压到可视区内），收起时把内联样式清空、交还站点 CSS。上报
`[KEYBOARD] kb=…px visible=…px, popup anchored above the keyboard (focused=…)`。

#### (6) 储物袋顶部 tab：不是错位，是末页没有数据

探针（10:25:19-10:25:30，6 项那组就是储物袋）：

```
items=[0+40 40+40 80+40 120+40 160+40 200+54] views=6 lastview=0 child(ren) div=translateZ(0px)
```

`div=translateZ(0px)` 说明切换不靠 transform（所以不是位移错位），而末页在点击前后都是 0 个子节点。
末页「Đang kích hoạt」由 `app.items.inv.activate` 填（app.v2.js:7745/7760/7826-7829）；若是
`undefined`，`loadListIntoView` 会在 `list.length` 抛错并出现在面板里 —— 日志里没有这条 `[ERR]`，
所以服务端给的 `act` 是空数组，也就是"这个账号没有激活中的道具"。

这一版把探针补成 `panes=[i:子节点数 …] activate=<长度>`：一次点击就能同时看到"被点的面板有没有
子节点"和"activate 列表有多长"，把"无数据"与"切换未触发"彻底分开。用户已确认网页版也找不到对应
设置，倾向就是无数据。

#### 验证

`check-ios-shim`（17 块 / 175812 字节 / 20 markers）、`test-site-patch`（213 条断言，新增
`download source picker` 6 条、`a finished download moves to DOWNLOADED` 10 条、
`a failing chapter is retried instead of abandoning the job` 5 条、`keyboard vs popup inputs` 8 条、
`grid tap targets` +4 条、`inventory tab probe` +2 条）、`gen-site-i18n --check`
（458 labels / 35 fragments）全绿。

### 6.13 评论翻译（2026-09-23 新增功能）

**需求**：正文的评论页要能翻译别人的评论，也要能把「我输入的评论」译成任意语言再发出去；
优先用 iOS 自带的离线翻译，同时也允许自己填 API Key；实现方式参考 `newsnook-ios` 的
`AppleTranslationPlugin.swift` 与 `features/translation/freeProviders.ts`。

#### (1) 为什么是两个目标语言，不是一个

评论是越南语、用户要读中文；用户打中文、评论者要看越南语。一个目标语言不可能同时服务
两个方向，所以设置里是 `readTarget`（评论翻译成）与 `writeTarget`（发评论时译成）两项，
`readTarget` 的默认值跟随站点界面语言（`app.language === 'zh'` → `zh-Hans`）。

#### (2) 引擎与降级顺序

| 引擎 | 说明 |
|---|---|
| `apple` | iOS 18+ Translation 框架：离线、免密钥、复用系统已下语言包。默认首选 |
| `free` | 微软 Edge 无鉴权端点 `edge.microsoft.com/translate/translatetext`（与 newsnook-ios 同一条通道），按 IP 限速 |
| `azure` / `google` / `deepl` / `openai` | 用户自备 Key，走原生 Http 插件 —— 页面级 `fetch` 到这些域会被 CORS 拦掉 |

`apple` 不是靠 UA 猜的：`SangTacAppPlugin.translationStatus` 在**所有 iOS 版本上都存在**，
iOS 15-17 上如实回 `{status:'unsupported'}`，JS 的 `probeApple()` 据此把引擎换成 `free`。
若把这三个方法写成 `@available(iOS 18.0, *)` 的 extension，旧系统上选择子直接不存在，
JS 只会拿到一个不透明的桥接错误，没法判断该不该降级。

#### (3) 原生侧：`TranslationBridge.swift`

- 框架只在 SwiftUI `.translationTask` 的闭包里交出 `TranslationSession`，也只有这个 session
  能申请语言包下载，所以插件挂了一个常驻 1×1 的 `AppleTranslationHostView`（Capacitor
  视图控制器的子 VC）当宿主，语对不变就复用同一个 session。
- 换配置前必须先丢掉旧 session（框架里复用会 `fatalError`），并且要「先置 nil、下一轮
  runloop 再设新值」，否则同一语对的第二次请求拿不到 session。这两点与 newsnook-ios 一致。
- `translate` 会先跑一次 `prepareTranslation()`：这正是弹出系统语言包下载确认的调用，
  于是「第一次翻译某个新语对」是自愈的，而不是先报一个错误让用户去猜。
- **弱链接**：部署目标是 15.0，`Translation` 是 iOS 18 框架，所有使用都在
  `@available(iOS 18.0, *)` 内，Swift 因此发出 `LC_LOAD_WEAK_DYLIB`。强链接会让 iOS 15-17
  的 dyld 在任何代码执行前中止启动，而编译期与本机（Windows）都看不出来 —— CI 新增
  `Verify Translation.framework is weak linked` 步骤查产物的加载命令兜底。
- 不解析 `TranslationError` 的具体错误码：那套静态成员是 iOS 26 才公开的（newsnook-ios 为此
  耗过一轮 CI），这里只用 `localizedDescription` 加自有的超时错误文案。

#### (4) 站点侧：`commentTranslate` 块

- 挂钩点是 `app.pushPage`（所有页面的唯一漏斗）：`comment` → 装按钮，`pagesetting` → 加
  「设置 → 翻译」入口。
- 评论页（`_page_vip.html:914-941`）加三处 UI：标题栏 `译全部` + `⚙`、每条 `[view=commentblock]`
  的 `.cmtbody` 里一个 `译／原文` 切换、`.commentinput` 上方一个 `译成X`。
- 评论是分两批到的：`loadEmbed()` 的首屏渲染，以及之后评论频道推来的新评论。只挂一次
  `MutationObserver` 才能覆盖第二批。
- 发帖方向不能只写 `innerHTML` 就完事：站点在 `_page_vip.html:4586` 把
  `p.q('.commentinput').innerHTML` 交给 `replyContext.set()`，所以写入的是转义后的文本
  （换行用 `<br>`），否则用户输入里的尖括号会被当成标签。
- 设置存 `app.storage` 的 `stv.translate.settings`，并加进 `settingsBackup` 的 `KEYS`，
  于是和阅读设置一样能跨重装恢复（走 Keychain）。
- 长列表按 3000 字符切块串行发送；单块失败只让那一块保留原文，不会把整页翻译丢掉。

#### 验证

`check-ios-shim`（18 块 / 219102 字节 / 21 markers）、`test-site-patch`（257 条断言，新增
`comment translation (system offline engine)` 22 条、`comment translation without the system engine`
3 条、`comment translation provider request shapes` 16 条）、`gen-site-i18n --check`
（458 labels / 35 fragments）全绿。CI 另加：二进制里必须有
`translationStatus`/`translationPrepare`/`translationTranslate` 与 `stvCommentTranslateInstalled`，
且 `Translation.framework` 必须是弱链接。

**未证实项**：`TranslationSession` 跨调用复用是主要运行时假设（与 newsnook-ios 相同）；
真机若失败，provider 的 `discardSession()` + 重建路径会在下次调用自愈。首次翻译新语对会弹
系统语言包下载确认，CI 无法覆盖。
