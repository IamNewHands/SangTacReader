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
6. ~~`__stvDiag` 诊断面板是临时设施，应移除~~ —— **改判为常设功能**（2026-09-23，用户要求）：面板由「设置 → 诊断」的开关控制，默认关闭（关着时不存在任何悬浮窗、不缓冲、不接管 console），开着时徽标常显 + 面板常驻，开关镜像进 Keychain 重装不丢，见 §6.15 (1)。`tabProbe` 仍是临时探针（它的 `TAB` 日志与 `activityLog` 的 `NAV` 并存），储物袋 tab 的成因已定性，见 §6.11 (4) / 本表第 8 条。
7. 站点 `filterDownloadingChapters`（`read.js:3445`）参数遮蔽导致跨任务去重失效 —— 站点代码本身仍未改，但影响已被绕开：下载对话框现在拒绝为同一本**正在下载**的书起第二个任务（§6.14 (1)），所以那个「被过滤成空章节列表、永远停在 0/N」的任务不会再产生。
8. ~~储物袋顶部 tab 的错位成因未定~~ —— **已定性**：不是位移错位，是末页「Đang kích hoạt」本来就没有数据（服务端 `act` 为空数组，见 §6.11/§6.12 (6)）。`tabProbe` 探针已补 `panes`/`activate`，若后续发现该有数据再收口。
9. **系统离线翻译要 iOS 18+ 且语言包已下载**（见 §6.13）。iOS 15-17 上 `App.translationStatus` 如实回 `unsupported`，`commentTranslate` 会自动改用联网引擎（免密钥微软通道，或用户自备 Key），因此该功能在旧系统上不是不可用，只是必须联网。
10. **自备 API Key 存在站点存储里**（`app.storage` → Capacitor Preferences → UserDefaults），并被 `settingsBackup` 一并镜像进 Keychain（`stv.translate.settings`）。日志只记引擎名，不打印 Key；但它不是独立的加密存储，介意的话请用可随时吊销的 Key。
11. **社区里的 Cbox 板块翻译不了**：`page-pagecbox`（`_page_vip.html:982`）是一个跨域 iframe（`www6.cbox.ws`），父页面拿不到里面的 DOM；Facebook 的两个按钮是外部浏览器。其余板块（Kênh truyện / Kênh linh tinh / 势力 / 单帖 / 用户主页评论 / 广播）都已覆盖，见 §6.14 (7)。
12. **标签栏切换的正式 API 未知**：`ui.smtab()` 来自 `/stv.ui.js`，该文件不在仓库里也拉不下来（本机 TLS 取不到），所以「跳转到下载页」是靠**在 tabitem 上派发 click**（和手指一样）+ 事后用 `tab.current()` 校验；校验不过才去探测 `select/go/switchTo/setIndex/activate/to` 这一组 setter 名字。走哪条路、`current()` 是否存在于 `#tabtusach`，都会写进 `[DOWNLOAD]` 日志，下一份真机日志即可定案，见 §6.15 (2)。
13. 站点自身还有两处缺陷，已用包装绕过（站点代码仍未改，见 §6.16）：`store.remove()` 按**引用**找记录而 `OfflineBook.delete()` 递进去的是包装对象（`app.v2.js:661` / `read.js:3314`），所以删除恒不落盘、重启就复活；`OfflineBook.deleteAll()`（`read.js:3368`）边遍历边 `splice`，每隔一章漏删一个章节文件。
14. 站点还有两处「只实现一半」的地方，同样只在我们的包装里补（见 §6.17）：详情页的点赞按钮只发 `ajax=like`（`_page_vip.html:4220` / `app.v2.js:4914`），而取消用的 `app.api.unlike`（`:4917`）没有任何调用方；站点的 `app.v2.css` 只写了无前缀的 `user-select: none`（`body:28` / `.booksquare:89` / `.bookrow:156`），没有 `-webkit-user-select` 也没有 `-webkit-touch-callout`，所以长按弹菜单时 iOS 的选中/放大镜手势仍然生效。范围下载也从不检查磁盘上已有的章节（`clist.slice(start-1, end)` 直接交新任务），重复下一个区间会整段重下并把限速节奏打坏。
15. **「我赞过这本书吗」这个问题，站点自己也问错了接口**（见 §6.18 (1)）：`updateBookPage`（`app.v2.js:4932`）用 `queryBookExtStatus`（`ajax=querybookmarkstatus`，带 `bookname`/`author`，返回的是**书自己的记录**，同一回复还喂书签和关注）的 `like` 字段当「我的状态」，于是 unlike 成功后它仍会重新点亮按钮。真正对口的接口是 `querylikestatus`（`app.v2.js:4865`，键是 `type:id`，与 `like`/`unlike` 同一套）。我们的包装已改用它并在调用后复查，`updateBookPage` 的判定也换成复查值——站点自身没改。
16. **「已下载」列表的重复行是我们自己造成的**（见 §6.18 (2)）：任务完成后 `moveJobToDownloaded` 无条件往列表里 `appendChild`，而站点渲染列表用的是按 `(host,id)` 去重的 `store.data`，所以同一本书下第二次就会多一行。已改成按 `data-stvbook` 键先摘旧行、读列表时再折叠一次。
17. **导出的章节名只有越南语机翻可用，除非去问章节列表**（见 §6.18 (3)）：`readchapter` 不带原名，`oridata` 只在 `getChapterListOnline`（`app.v2.js:270`）出现。导出已改为复用阅读器那套映射；EPUB 的 `dc:language` / `xml:lang` 已在第十七轮改成 `zh`（正文与标题都是中文），见 §6.19 (1)。
18. **「书本的取消点赞」很可能在站点侧根本不存在**（见 §6.19 (3)）：`app.api.unlike` 全站只有一个调用方，而且是社区帖子（`app.v2.js:5239`）；书籍这条路上站点自己只会 `like`。真机日志显示服务端收下 `ajax=unlike`（`code 100`）却一行都没删，而同一本书的 like 记录有两行。我们的包装已改成阶梯（对象 id → 逐行 id，每条复查），若行 id 也删不动，就只能如实提示失败——或者干脆不让赞加上去（按钮只读），这属于产品取舍，需要用户定。
19. **每章正文末尾的存档声明是服务端加的**（见 §6.19 (2)）：`Bạn đang đọc bản lưu trong hệ thống` 不在客户端任何文件里，只能在消费正文处剥掉（阅读器 iframe + 导出，共用 `__stvI18n.stripNotice`）。匹配按用户给出的句子做，别的写法会漏。
20. **冷启动的剩余时间在站点自己的串行链上**（见 §6.19 (4)）：外壳 HTML 的 TTFB ~1.2s，`app.v2.js`（59KB）在它后面，实测站点 UI 到 +2.9s、首页数据到 +10s 才齐。本轮修掉的是我们自己的两处浪费（资源 URL 每天换一次、设置页一次点错连发 25 个 403 的 `/mobile/lang/<域名>.json`）；要再往下压只有把静态资源搬进本地 origin（`docs/optimization-plan-2026-09-23.md` §3/P2），工作量大且回归面广，尚未做。

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

- 挂钩点有两个：`app.pushPage`（所有页面的唯一漏斗）与 `app.comment.loadEmbed`
  （`app.v2.js:3560`，站内每一个评论列表都由它建）。前者覆盖「页面打开时就有容器」的
  情况（书籍评论页、社区频道板 `pageposts`、设置页），后者覆盖「容器是打开之后才
  append 的」情况（单帖的评论区、用户主页的评论）。`installOnPage()` 对没有评论/帖子
  容器的页面直接返回，所以不会到处加按钮。
- 可翻译内容的两种形状：评论 `[view=commentblock] > .cmtbody > .cmtcontent`
  （`_page_vip.html:2333`）与帖子 `.postcontent > .content`（`view-post` :2671、单帖页
  :1105）。`textTargets()` 同时收集两者，所以「译全部」在一页里既能翻评论也能翻帖子。
- 每处 UI：标题栏 `译全部` + `⚙`；每条评论/每个帖子一个 `译／原文` 切换；评论输入框
  一个 `译成X`（书籍评论页是 `.commentinput` contenteditable，帖子是 `.comment-input`
  textarea —— 后者站点读 `.value`，所以写入方式按标签区分）。
- **译全部不弹窗**：原先走 `app.toast()`，而它是 `app.context.info(msg, true)`
  （`app.v2.js:614`），是个模态信息框，于是「点译全部先弹一个窗」。现在进度写在按钮
  文案上（`翻译中…`），结果写进诊断日志，另有自绘的非交互条 `hint()`。
- **等列表加载**：`loadEmbed()` 是异步的，用户可能先点按钮。此时不再回「还没有可翻译的
  评论」，而是把请求挂起（`page.__stvPendingAll`），`MutationObserver` 一旦看到第一条
  评论/帖子落地就自动执行。`auto`（自动翻译）同理，而且标记在页面存续期间一直有效 ——
  之后被评论频道推进来的新评论也会被翻。
- **幂等**：翻过的节点打 `stv-orig`（保留原文）或 `stv-tr-done`（已送过引擎，哪怕译文与
  原文相同），`textTargets()` 跳过它们。否则再点一次「译全部」会把译文再翻一遍，并覆盖掉
  存着的原文。
- 评论是分两批到的：`loadEmbed()` 的首屏渲染，以及之后评论频道推来的新评论。只挂一次
  `MutationObserver` 才能覆盖第二批。
- 发帖方向不能只写 `innerHTML` 就完事：站点在 `_page_vip.html:4586` 把
  `p.q('.commentinput').innerHTML` 交给 `replyContext.set()`，所以写入的是转义后的文本
  （换行用 `<br>`），否则用户输入里的尖括号会被当成标签。
- 设置存 `app.storage` 的 `stv.translate.settings`，并加进 `settingsBackup` 的 `KEYS`，
  于是和阅读设置一样能跨重装恢复（走 Keychain）。
- 长列表按 3000 字符切块串行发送；单块失败只让那一块保留原文，不会把整页翻译丢掉。

#### (5) 设置面板为什么不用原生 `<select>`

站点在 `body` 上设了 `user-select: none`（`app.v2.css:28`），而面板是 `position:fixed`
的可滚动浮层；真机日志里这一片区域**没有任何一次点击的目标是 `select`**，只有它周围的
`div` —— 也就是引擎和语言根本点不开。现在引擎与三个语言项都是自绘选择器：一个按钮显示
当前值，点开是一个普通 `div` 列表（带搜索框），完全由我们的事件处理驱动。语言表从 16 种
扩到 49 种，`readSource` 也可以选具体语言而不只是「自动识别」。

#### 验证

`check-ios-shim`（18 块 / 240958 字节 / 21 markers）、`test-site-patch`（301 条断言，
其中 `comment translation (system offline engine)`、`comment translation without the system
engine`、`comment translation provider request shapes`、`译全部 waits for the list and opens
no popup`、`auto-translate waits for the comments to load`、`community boards are translatable`）、
`gen-site-i18n --check`（458 labels / 35 fragments）全绿。CI 另加：二进制里必须有
`translationStatus`/`translationPrepare`/`translationTranslate` 与 `stvCommentTranslateInstalled`，
且 `Translation.framework` 必须是弱链接。

**未证实项**：`TranslationSession` 跨调用复用是主要运行时假设（与 newsnook-ios 相同）；
真机若失败，provider 的 `discardSession()` + 重建路径会在下次调用自愈。首次翻译新语对会弹
系统语言包下载确认，CI 无法覆盖。Cbox 板块（`page-pagecbox`，`_page_vip.html:982`）是跨域
iframe，父页面够不到里面的文字，翻译不了；Facebook 的两个按钮是外部浏览器，同理。

### 6.14 第十二轮真机反馈（`日志.txt`，389 行）：下载重复/归类/删除、翻译弹窗与选择器、社区板块

六条反馈，前三条在下载，后三条在翻译。逐条给出根因（都能在日志或站点源码里指到具体行）。

#### (1) 「下载页面有时会出现两次相同的下载」

`DownloadManager.render()`（`app.v2.read.js:3605`）是 async，而它唯一的幂等守卫是
`if (this.node) return this.node;` —— 在第一个 `await` **之前**读的。`onUpdate()`
（:3428）被并发调用两次（构造函数的、完成归类的、我们按钮的），两次都能穿过这个守卫，
各自建一个节点，于是同一个任务在列表里出现两行。修复：把**进行中的 promise** 也记住
（`__stvRenderPending`），第二个调用者等第一个的结果，`onUpdate` 的父节点判断随后
自然去重。

另外在下载对话框的动作里加了一道闸：同一本书已经有**正在跑**的任务时，第二次「确定」
直接忽略。站点自己的 `filterDownloadingChapters()`（:3445）会把重复任务的章节列表过滤
成空，于是那一行永远停在 0/N，既下不完也离不开列表 —— 这正是「没完成就出现在别处」的
另一半来源。暂停或完成的任务不算「正在跑」，不影响重新下载。

#### (2) 「正在下载中的任务还没完成就已经在已下载中显示了」

`getNewBook()`（:3218）在下载**开始**时就调 `book.save()`，而 `OfflineBook.save()`
（:3304）会 `store.prepend(baseObject)` —— 书在第一个章节还没下下来时就已经进了
`offlineBook.store.data`，而「已下载」列表正是读这个数组（`getDownloadBooks` → :3202）。

修复：包装 `getDownloadBooks`，读列表时把「有正在跑的任务」的书临时从视图里去掉。
`store.data` 用「换入过滤后的数组、调用完换回」的方式处理，这样站点按 index 分页的
`20 条/页` 计数不会被带偏（直接过滤结果会让页数错位）；也不是把记录删掉 —— 阅读器
靠 `isBookExist()` 找离线章节，删了记录就没法离线读半本。列表读取本身用 promise 链
串行化，避免换入换出重入。

#### (3) 「已下载的小说没有删除按钮」

删除按钮的代码一直在，但装不上：`patchDownloadedRow()` 判的是
`app.celldisplay.bookdownloadedrow`，而站点里这个渲染器叫 **`app.celoader`**
（`_page_vip.html:3610`，`bookdownloadedrow` 在 :4014，已下载列表在 :4074 调它）。
`app.celldisplay` 在整个站点包里根本不存在，于是补丁永远返回 false，计时器白跑 600 次，
按钮从未出现。同一处拼写错误也出现在完成归类的 `moveJobToDownloaded()` 里 —— 这就是
日志里每次都是「finished ...; the DOWNLOADED list is not open」的原因。两处都改成
`app.celoader`。

测试里原本写的是 `app.celldisplay`，等于**把 bug 写进了断言**：现在改成 `app.celoader`，
并加一条断言确保不再依赖那个不存在的名字。

#### (4) 「点击译全部会弹提示窗口」

`app.toast()` = `app.context.info(msg, true)`（`app.v2.js:614`），是模态信息框。翻译
流程里三处都在用它（「正在翻译 N 条」「已翻译 N 条」「还没有可翻译的评论」），所以点一下
就弹一个窗。现在：进度写在按钮文案上，结果只进诊断日志，另加自绘的非交互提示条
（`pointer-events:none`，2.6 秒自消失）。新增断言直接检查 `app.toast` 一次都没被调用。

#### (5) 「还没加载出评论，翻译就已经开始，提示没有评论」

`loadEmbed()` 是异步的，而自动翻译在 `pushPage('comment')` 的同一轮就发起，于是必然撞上
空列表。现在自动翻译只置一个 `__stvAutoPending` 标记，由 `MutationObserver` 在第一条评论
落地时才真正发请求；手动点「译全部」时若列表还空，同样挂起（按钮显示「等加载…」），
内容到了自动继续。

#### (6) 「配置页无法切换通道/语言，语言不要只限越南语和中文」

见 §6.13 (5)：原生 `<select>` 在这个 webview 里点不开（日志证据：该区域没有一次点击目标
是 `select`），已全部换成自绘选择器；语言表扩到 49 种，可搜索，源语言也可指定。

#### (7) 「翻译功能扩展到社区分类下各个板块」

社区 tab（`_page_vip.html:196-263`）里能在本 webview 内渲染的板块，入口都收敛到两处：
`app.pushPage('pageposts')`（`showCommChannel` → Kênh truyện / Kênh linh tinh / 势力，
`showUserPosts` → 用户动态）与 `app.comment.loadEmbed`（单帖 `:5230`、用户主页 `:4843`、
广播与 fromuser 评论板）。所以挂钩 `pushPage` + `loadEmbed` 就覆盖了全部：频道板翻帖子
正文，单帖翻正文 + 评论 + 输入框，用户主页翻评论。`page-pagecbox`（Cbox web）是跨域
iframe，父页面取不到内部文字，**不支持**；两个 Facebook 按钮是外部浏览器，同理。

#### 验证（本轮）

- `node scripts/check-ios-shim.js` → 18 块 / 240958 字节 / 21 markers
- `node scripts/test-site-patch.js` → 301 条断言全过（本轮新增 4 组：并发渲染去重、已下载
  列表过滤、重复启动忽略、译全部等待 + 无弹窗 + 幂等 + 自动翻译等待与续翻 + 社区板块）
- `node scripts/gen-site-i18n.js --check` → 458 labels / 35 fragments

**未证实项**：`user-select: none` 与原生 `select` 的关系是从日志反推的（真机上点不到），
自绘选择器绕开了这个不确定性；社区板块的真机布局（标题栏空间是否够放两个按钮）需要下一
轮日志确认。

### 6.15 第十三轮反馈（2026-09-23）：日志开关、下载开始提示与跳转

两条新需求（原消息的第 3 条是误触的空行，已确认无内容）。

#### (1) 「把日志打印的功能做到设置里，用开关控制……禁用后就不再有悬浮日志窗口，启用后就一直显示」

改动在 `diag` 块 + `commentTranslate` 的设置页：

- **默认关闭**。`enabled` 在 document start 从 `localStorage['stv.diag']` 同步读出——这是
  唯一能在那一刻读到的地方，`app.storage`（Capacitor Preferences）要晚一拍才 resolve，等
  它就来不及决定「悬浮窗到底要不要存在」。
- 关着时：不建徽标、不建面板、不缓冲任何行（`log()` 第一行就 return，所以 800 行上限不会
  被撑满），console 的 `tee` 直接透传原函数，click/touchstart 两个监听器第一行就 return。
  整个功能在关闭状态下的成本是每次用户操作一个布尔判断。
- 开着时：徽标**常显**（旧行为是「出现第一条 ERR 才冒出来」，也正是这次要去掉的那种「莫名
  其妙多出来的窗」），面板随开关一起弹出；`HIDE` 仍然只收徽标，`CLOSE` 只收面板，连点左上
  角三次照旧。
- `setEnabled()` 是唯一入口：写 localStorage、写 `app.storage['stv.diag.settings']`（于是被
  `settingsBackup` 自动镜像进 Keychain），关掉时还会清空缓冲区并**删除**两个 DOM 节点。
  `show()` 里也判一次 `enabled`，否则「查看/复制日志」那一行会在开关关着时把面板重建出来。
- 设置页加在 `commentTranslate` 块里（它本来就负责设置页）：`设置 → 诊断` 下两行——「日志
  （悬浮日志窗口）」点一下开关，右侧实时显示 `已关闭 · 点这里开启` / `已开启 · 点这里关闭`；
  「查看/复制日志」会先把开关打开再弹面板。
- 重装后不丢：`settingsBackup` 的 `KEYS` 加了 `stv.diag.settings`，恢复链末尾用
  `applyDiagSetting()` 把这个值直接交给 `__stvDiag.setEnabled()`（它是我们自己的设置，不是
  站点的 config，所以不走 `CONFIG_TARGETS`）。规则与既有一致：只有**这次真的写进去了**才
  应用，站点存储里已有的值更新，不覆盖。

「常见的功能都加点日志」落在新的第 19 个块 `activityLog`：它只做站点自己不会记的那一层——
`[PAGE]` 每次 `pushPage`/`popPage`、`[NAV]` 每次标签栏点击（序号 + 文案）、`[MSG]` 每次
`app.toast` / `app.context.info`（两个都是模态弹窗，「站点到底弹了什么」通常就是整个问题）、
`[BOOT]` app 对象就绪时刻。其余主题（下载、翻译、TTS、书签、存储、镜像失败转移、阅读器
默认值）各自已经有 tag，不重复。包装函数一律 `apply(this, arguments)` 并原样返回，异常不
吞。`app.pushPage` 被两个块先后包装，两层都保 `this`/返回值，互不影响。

#### (2) 「点击下载后要有提示窗口说明开始下载了，然后有按钮直接跳转到下载界面」

站点自己什么都不弹：`startdownload` 关掉范围对话框就结束了，任务行只出现在**书架 → 下载**
里，而读者还停在详情页上。

- 提示窗用站点自己的弹窗模板（`app.context.popup`，`app.v2.js:2195`）：`button` 里放带
  `action` 属性的 `<button>`，站点在 `:2218-2243` 分派到 `action[name](pop)`。两个按钮：
  「关闭」和「查看下载」。正文写清楚 `host / bookid` 和「第 a - b 章，共 n 章」。
- 重复点同一本书时**也弹这个窗**，但标题是「已在下载」、正文说明没有重复添加——比静默忽略
  好，用户至少知道为什么没反应。
- 「查看下载」= `openDownloadList()`：先把 `#overlay` 里的页面全部 `popPage()` 掉（上限 20
  次，避免任何情况下死循环），等 300ms（`popPage` 的 gsap 动画 250ms，动画结束时还会调
  `mainview.ontabchange()`，抢在它前面切 tab 会被它抹掉），再 `selectDownloadTab()`。
- 书架是**主标签栏的第 0 项**（`#mainnavbar` 的 home，`_page_vip.html:135-166`），下载列表是
  书架的**第 5 个子 tab**（history / follow / bookmark / novel_owner / download，列表本身是
  `:162` 的 `<tabview id="downloadedlist">`）。所以先点 `#mainnavbar` 的第 0 个 tabitem，再点
  `#tabtusach` 的最后一个 tabitem。
- tabitem 藏在 `<tab>` 里的 `<tabbar>` 中（`:140-146`），不是 `<tab>` 的直接子节点——第一版
  就是直接找子节点所以一个都没找到，测试当场抓到了。
- 切换方式：**在 tabitem 上派发 `MouseEvent('click')`**（`createEvent` 兜底），因为
  `/stv.ui.js` 不在仓库里、本机也拉不下来，`ui.smtab()` 的 setter 名字无法查证。点完 300ms
  后用 `tab.current()` 校验；对不上再按 `select/go/switchTo/setIndex/activate/to` 顺序探测
  setter。**走了哪条路会写进日志**，所以下一份真机日志就能把 §5 第 12 条定案。

#### 验证（本轮）

- `node scripts/check-ios-shim.js` → 19 块 / 260412 字节 / **24** markers（新增
  `stv.diag.settings`、`action=stvqueue`、`window.__stvActivityLogInstalled` 三个必需
  标记，被删掉就红）
- `node scripts/test-site-patch.js` → **350 条断言**全过。本轮新增/重写 4 组：诊断面板的
  开/关两种状态（关着时无窗、无缓冲、console 不接管、`show()` 也建不出窗；开着时徽标常显、
  面板在屏、`setEnabled(false)` 删窗清缓冲、`setEnabled(true)` 重建）、设置页两行与
  Keychain 恢复（`logging switch restored: on`）、`activityLog` 的 `PAGE`/`NAV`/`MSG`/`BOOT`
  四类行且包装后原调用仍到达站点、下载开始提示窗（标题/正文范围/两个按钮、重复启动改成
  「已在下载」、点「查看下载」→ 关窗 → 关掉 3 个已推页面 → 主标签点 home、子标签点第 4 项 →
  日志确认 `download tab selected by click`）
- `node scripts/gen-site-i18n.js --check` → 458 labels / 35 fragments

**未证实项**：`ui.smtab()` 的 setter 名字、`#tabtusach.current()` 在真机上是否存在、以及
真机点 tabitem 是否真的能触发框架切换（三者都由本轮日志自证）；「关闭日志后 tap 日志也停」
这一点只在测试里断言了（真机上表现为「面板里不再出现新行」）。

### 6.16 第十四轮反馈（`日志.txt`，225 行）：删除不落盘、暂停无效

上一轮的两件事都成了（日志第 146 行 `download tab selected by click`、第 138-148 行
`[NAV]`/`[TAB]` 记录、悬浮窗正常开关），本轮是两个新问题。

#### 1. 已删除的已下载内容，重进应用又回来了

日志第 38-52 行：5 本书 `deleting downloaded book ...` → `removed downloaded book ...`，
全程没有 `[ERR]`，看上去删成功了；重启后 5 本全回来。

根因是站点的 `store.remove()` 用**引用相等**找记录（`app.v2.js:661`
`this.data.indexOf(item)`），而 `OfflineBook.delete()`（`app.v2.read.js:3314`）递进去的是
**OfflineBook 包装对象**，`store.data` 里存的却是它包着的那条记录（`store.prepend(this.baseObject)`，
`:3309`）。`indexOf` 恒为 -1 → 什么都没 splice → 我们的按钮只是把 DOM 行删了，
`store.save()` 又把没变的数组原样写回文件。站点自己的 `save()` 递的是 `baseObject`
（`:3309`），`delete()` 递的是 `this`，两处不一致，所以这个坑只在删除路径上。

修法（两层）：

- `patchReaders()` 里包一层 `app.offlineBook.store.remove`：参数带 `baseObject` 就先拆包，
  再走站点原本的 `indexOf`。这样站点自己的 `delete()` 也一起修好了。
- 删除链里顺手清掉 `app.offlineBook.offlineBookSingletons[host_id]`。这个单例缓存
  （`:3248-3255`）从不失效，而 `OfflineBook.save()` 在 `isWithBaseObject` 时只 `store.save()`
  不 `prepend`（`:3304-3312`）——不清单例的话，**同一次会话里删掉再重下这本书会永远回不来**。

顺带修掉 `deleteAll()`（`:3368`）的边遍历边 splice：它 `for` 走 `chapters` 的同时
`deleteChapter()` 又在 splice 同一个数组，**每隔一章漏一个**章节文件。改成先 `.slice()`
快照再逐个删（站点自己从不调用 `deleteAll()`，这个坑只被我们的按钮踩到）。

#### 2. 点暂停还在下，点继续报错，过一会儿又自己继续

日志第 162-205 行是完整的现场：

- `14:00:49` 暂停 → `isPaused = true`；
- `14:00:50-56` 第 13/14/15 章的批还在飞，14/15 撞上 429，退避重试
  （`retry 1/3` / `retry 2/3`，1500/3000/6000ms）**一路重试不看 `isPaused`**，所以「暂停了还在下」；
  站点自己的 `downloadChapter` 失败时已经把行状态写成 `Lỗi: Không thể đọc dữ liệu`（`:3566`），
  这就是用户看到的「报错」；
- `14:00:57/59` 点「继续下载」→ `start()` 被去重守卫吞掉（`start() ignored while a loop is running`，
  只置 `__stvStartAgain` 等循环退出后重放）；
- 批终于落定 → 重放的 `runJob()` 开头 `self.isPaused = false` → **又自己接着下到 20/20**。

三个修法：

- 退避重试里加暂停检查（`downloadChapter` 包装）：进请求前 `isPaused` 就直接 reject，失败后
  若 `isPaused` 则把行状态写回 `Đã dừng` 再 reject，不再重试。暂停从「等整批结束」变成
  「立刻生效」。
- 这个 reject 带 `stvPaused` 标记，`runJob()` 据此把章节**退回队列**而不是记成
  `gave up`（记成放弃的话，章节已被 `queue.splice` 拿走，续传就永久少章）。
- `start()` 在「循环还在跑 + 已暂停」时**就地解暂停**（`isPaused = false` + 状态回
  `Đang tải...` + 仍然置 `__stvStartAgain` 兜住「循环刚好已经过了最后一次检查、正要退出」的窗口），
  日志写 `resumed in place for ...`，不再有「点了没反应」。
- `moveJobToDownloaded()` 加 `__stvMoved` 幂等：重放的循环会再走一次完成分支，
  否则「已下载」列表会出现两行同一本书。

#### 验证（本轮）

- `node scripts/check-ios-shim.js` → 19 块 / 266966 字节 / **27** markers（新增
  `store.remove unwraps OfflineBook records`、`resumed in place for `、`stvPaused`）
- `node scripts/test-site-patch.js` → **367 条断言**全过。新增/改写：
  - 删除：桩里的 `existedBook.delete()` 逐字照抄站点（`store.remove(this)`），`store.remove()`
    也照抄站点的 `indexOf`；断言 4 个章节文件**全删**（不是隔一个）、记录真的不在 `store.data` 里、
    落盘内容里已无该书、单例缓存被清、`wiped 4 chapter file(s)` 上报；
  - 暂停/继续：批在飞时暂停 → 该批失败后**不记 gave up、章节退回队列、状态是 `Đã dừng`**、
    循环不再开新批；继续 → 整段补齐到 6/6；另一路断言「批还在飞时点继续」走就地解暂停
    （`resumed in place for qidian/8`，且**没有** `start() ignored`）；
  - 重放一个已完成的 job 不会在「已下载」里插第二行。
- `node scripts/gen-site-i18n.js --check` → 458 labels / 35 fragments

**未证实项**：真机上「删完重启不再出现」要看下一份日志（`[DOWNLOAD] wiped N chapter file(s)`
+ 重启后列表）；暂停的即时性在真机上的表现是「点暂停后不再有新请求」，`[DOWNLOAD] paused ... at
d/ t` 与 `resumed in place for ...` 会写在日志里；「删除任务」按钮走的也是 `pause()`，
现在同样会真的停下。

### 6.17 第十五轮反馈（`日志.txt`，512 行）：点赞取消、下载去重、导出、长按选中

四件事：两件是站点客户端的单向按钮/重复任务，一件是新功能（导出），一件是 iOS 手势与站点 CSS 的错配。

#### 1. 小说详情页点赞后无法取消

站点源码就是单向的：详情页把 `.likebook` 绑到 `app.api.likeBook`
（`_page_vip.html:4220`），而它只发 `ajax=like`（`app.v2.js:4914-4916`）。
**取消用的端点其实是有的**——`app.api.unlike`（`:4917-4931`，`ajax=unlike`）——只是详情页
从来没有人调它。所以第二次点只是再 like 一次，状态与计数都不动。

修法（`bookmarkToggle` 块，与「取消书签」同一个所有者：站点只单向实现的书本动作）：

- `app.api.likeBook` 包一层，用 `app.api.queryBookExtStatus(book)` 读**权威状态**——这正是
  站点自己 `updateBookPage`（`:4936`）用来决定 `.active` 的那个调用，所以不是猜；
- `status.like` 为真 → `app.api.unlike(host, id)`；为假 → 走原本的 like；
- 计数（`_page_vip.html:334` 的 `.liked`）由这次点击加减 1：`updateBookPage` 只改 `.active`
  类，不管数字。作用域限定在 `.likebook` 内，因为社区帖子的点赞按钮里也有一个裸 `.liked`
  （`:1132`），一起加会写错别人的数字。下次打开详情页 `bookinfo.php` 会送回真值，漂移不会累积。

两条路径都写 `[LIKE] ... status like=...` / `liked ... -> code ...`：**本轮日志里根本没有点赞的
TAP/POST 记录**（14:45:41 打开详情页到 14:45:48 点 `button.w-100` 之间没有任何 `[TAP]`，
`jsonify.php` 一次都没出现），所以这个根因来自站点源码而不是日志。下一份日志能直接判定：
有点赞的 `[LIKE]` 行 = 处理器在跑；没有 = 点击根本没到处理器，那是另一个问题。

#### 2. 重复下载同一个区间会新建任务

日志第 216-217 行与 410-411 行是同一个区间的两次执行：

```
14:46:22 [DOWNLOAD] range 1-20 of 310 -> 20 chapter(s)
14:46:22 [DOWNLOAD] started dialog shown: 第 1 - 20 章，共 20 章
...
14:46:43 [DOWNLOAD] moved qidian/1034915599 into the DOWNLOADED list
...
14:47:27 [DOWNLOAD] range 1-20 of 310 -> 20 chapter(s)
```

第二次是在「已下载」之后发起的，20 章一个不落地重新下，还顺带把节奏打坏
（第 452-465 行的 `throttled (chapter failed: Không thể đọc dữ liệu)`、
`retry 1/3`/`retry 2/3`）。

根因：范围对话框把 `clist.slice(start-1, end)` 的每一个 `cid` 直接交给新的
`BookDownloadManager`，从不问磁盘上已经有什么。而 `OfflineBook` 一直知道答案：
`getChapterDownloaded()`（`app.v2.read.js:3317`）读的就是按 book 存的章节 id 列表。

修法：`menu.action.startdownload` 里先取 `book.getChapterDownloaded()` 建集合，
过滤掉已有的 id，只把缺的交给新 job：

- `[DOWNLOAD] range 1-20 of 310 -> 15 new chapter(s), 5 already downloaded`；
- 全都有 → **不建 job**，弹「无需重复下载」（标题就是这个），不再产生一个 0/N 的僵尸行；
- 弹窗文案区分三种情况：全新 / 部分新增（`新增 N 章（第 a - b 章里已有 M 章，直接跳过）`）/ 全部已有。
- 记录按 (host, id) 分开：同一本书换个源就是另一本书、另一套章节 id，该下还得下——
  这正是「检查已下载的章节和来源」里的「来源」那一半。

#### 3. 已下载列表加「导出」（TXT / EPUB，带封面与书名）

新增 `downloadExport` 块 + 原生 `SangTacAppPlugin.exportFile`。行内的按钮由 `pageRepair`
的 `decorateDownloadedRow` 通过 `window.__stvExport.button(book)` 取——行布局归 `pageRepair`，
导出归 `downloadExport`，`app.celoader.bookdownloadedrow` 只包一层（两个独立包装器是行被
装饰两次的老路）。

- TXT：书名 / 作者 / 来源 / 章节数 + 每章「站点原标题 + 正文」，`\r\n` 换行；
- EPUB：把同样的文字转成 XHTML 塞进 ZIP，封面图（`Http.get({responseType:'arraybuffer'})`
  拿回的 base64，`SangTacHttpPlugin.swift:749`）、`nav.xhtml` 与 `toc.ncx` 都给上，
  EPUB 3 和只认 NCX 的老阅读器都能出目录；
- ZIP 是**只存不压**的：格式要求 `mimetype` 必须是第一个且未压缩的条目，而剩下的内容马上就
  交给别的 App，引 pako 或 `CompressionStream` 只会多一个依赖和一个出错点；
- 文件交给原生 → 写进临时目录 → 弹系统分享面板（存到「文件」/ AirDrop / 直接进其他阅读器）。
  WKWebView 里 `<a download>` 是空操作，这个构建又没有 Filesystem 插件，分享面板是唯一出路；
- 没有封面、没有 `chapterTitle`、某一章读不出来都不致命：封面缺失就不放封面，读不出的章节
  跳过并记 `[EXPORT] read N of M chapter(s), K unreadable`，一章都没有才报错。

**测试第一次跑就抓出 zip 写入的真 bug**：`localSize` 与 `centralSize` 用了同一个累加变量，
于是每个本地头的 offset 写成了「中央目录的位置」，`mimetype` 的 CRC 全对但数据段错位。
测试用**独立的** ZIP 读取器（自己解析 EOCD / 中央目录 / 本地头）加 `zlib.crc32` 复核，
不是把写入逻辑重抄一遍；修好后另外用 .NET `System.IO.Compression.ZipFile` 打开产物复核过
（`mimetype` 是第 0 个条目、`CompressedLength == Length`、`content.opf` 正常）。

原生侧：

- `CAPPluginMethod(name: "exportFile")`，写 `FileManager.default.temporaryDirectory`，
  `UIActivityViewController` 在主线程 present，popover 锚点也给了（iPad/分屏用法下 UIKit 会
  直接抛异常而不是降级）；
- 文件名走 `NSString.lastPathComponent` + 替换 `/` 与 `:`，长度截到 120；
- **故意不加 `isTrustedCaller`**：它不读任何已存状态、不向调用方返回数据，只写调用方给的字节并
  抬 UI（与 `speakToFile`、翻译桥同理）；加了的话，主框架落在 `trustedHosts` 之外的镜像域名时
  导出会静默失败，换来的安全性并不存在；
- 上限 64 MB，且**解码前**先按 base64 长度判断（64 MB 的 base64 是 ~85 MB 字符串，
  `Data(base64Encoded:)` 会再分配一次）。

#### 4. 历史列表长按会顺带选中文字

站点给每个书本单元挂 `ui.hold(e, ...)` 弹菜单（`_page_vip.html:3901/3977/4000/4027`），
并且只对里面的 `img` 挡了 `contextmenu`——文字上没有。`app.v2.css` 只在 `body:28`、
`.booksquare:89`、`.bookrow:156` 写了**无前缀**的 `user-select: none`，从来没有
`-webkit-user-select`，更没有 `-webkit-touch-callout`。菜单在手指下面冒出来的那一刻，
iOS 的选中/放大镜手势正好落在新节点上，于是「弹选项的同时默认选中了文字」。

修法：`gridLayout` 注入的那张样式表里补上 `.booksquare/.booksquarecont/.bookrow/
.bookrowcont/.bookrowext` 与 `.contextmenu/.mixedcontextmenu` 系列的
`-webkit-user-select: none` + `-webkit-touch-callout: none`。只圈列表单元和菜单本身——
评论与正文的选择能力必须留着。

#### 验证（本轮）

- `node scripts/check-ios-shim.js` → 22 块 / 334172 字节 / **34** markers（新增
  `like toggle installed`、`already downloaded`、`webkit-touch-callout`、
  `window.__stvExportInstalled`、`exportFile`）
- `node scripts/test-site-patch.js` → **486 条断言**全过（上一轮 367 条）。新增四组：
  - 点赞：已 like 时走 `unlike`、两个按钮的 `.active` 都掉、计数 25→24、再点回 25；
    未登录（状态查询返回 null）时仍然走站点自己的 like 路径，不会对不存在的会话发 unlike；
  - 去重：`alreadyDownloaded: ['c1'..'c5']` 时 1-20 只排队 `c6..c20`（15 章）、
    弹窗写「已有 5 章」；整段都下过时**一个 job 都不建**，标题是「无需重复下载」；
  - 导出：点行内按钮 → 格式弹窗 → TXT 命名/表头/章节顺序/去标签，EPUB 的
    `mimetype` 是第 0 个且未压缩、**每个条目的 CRC32 用 `zlib.crc32` 复核**、
    container/opf/nav/ncx/封面齐备、spine 含 cover + 两章、章节 XHTML 转义正确、
    封面字节就是取回的那份；空书报「导出失败」而不是产出空文件；
    `textBytes` 与 `Buffer.from(...,'utf8')` 逐字节比对（含 emoji 这种代理对），
    `safeName` 挡掉 `/ : * ? " < > |`；
  - 长按：注入的样式表里有 `-webkit-touch-callout: none` / `-webkit-user-select: none`，
    覆盖列表单元与菜单，且**没有**任何 `user-select: text`。
- `node scripts/gen-site-i18n.js --check` → 458 labels / 35 fragments
- 产物复核：`STV_EXPORT_DUMP=1 node scripts/test-site-patch.js` 会往
  `_export-check/`（gitignore）写一份 TXT + EPUB，本轮用 .NET `ZipFile` 独立打开验证过。

**未证实项**：真机上四件事都要看下一份日志——点赞要 `[LIKE] ... status like=...`；
去重要 `[DOWNLOAD] ... 15 new chapter(s), 5 already downloaded`；导出要有
`[EXPORT] read N of M chapter(s)` 与系统分享面板弹出；长按是否还选中文字只能眼看（手势事件
不进日志）。Swift 侧本机无法编译验证：开发机是 Windows，`exportFile`
只有 CI 的 `macos-26` 会编（workflow 里加了 `exportFile` 的符号校验）。

### 6.18 第十六轮反馈（`日志.txt`，302 行）：点赞取消仍是假的、已下载重复行、导出章节名

第十五轮的四项里，长按不选中文字的真机反馈是「已修复」，其余三项都还有问题。

#### 1. 取消点赞「提示取消，但实际没取消」——状态读错了接口

日志里四次点击全都走同一条路：

```
17:07:40 [LIKE] qidian/1034915599 status like=true
17:07:40 [LIKE] qidian/1034915599 is liked; unliking
17:07:41 [LIKE] unliked qidian/1034915599          <- 服务端答 code 100
17:07:41 [MSG] toast: 已取消点赞
...
17:07:47 [LIKE] qidian/1034915599 status like=true  <- 6 秒后又是 true
```

而 17:07:19 已经对同一本书 unlike 过一次（同样 code 100），17:07:37 重新打开详情页、17:07:40
再点仍然读到 `like=true`。`app.net.post` 不缓存（`app.v2.js:756`），所以这不是读到了旧响应。
整份日志里**没有一条 `liked ... -> code 100`**：四次点击全部进了删除分支。

根因在第十五轮选的状态接口。`queryBookExtStatus` 打的是 `ajax=querybookmarkstatus`，带
`bookid` + `host` + `bookname` + `author`（`app.v2.js:4879`），返回的是**这本书自己的记录**，
同一个回复还喂着书签和关注按钮——所以 `status.like` 不等于「我赞过没有」，unlike 成功后它
依然是 `true`。判断「我赞过没有」的接口是 `querylikestatus`：

```js
app.api.queryLike = async function(list){          // app.v2.js:4865
    var params = `ajax=querylikestatus&list=${list.join(",")}`;
```

它的键是 `type:id`（`app.v2.js:5258` 用 `topic:<id>` 构造），**与 `like(type,id)` /
`unlike(type,id)`（`app.v2.js:4905/4923`）同一套**——读和写第一次说的是同一个对象。

修法（`bookmarkToggle` 块的 `attachLike`）：

1. 新增 `readLiked(book)`：先问 `queryLike([host + ':' + id])`，返回 `{liked, source, raw}`；
   接口不存在时（老镜像构建）才退回 `queryBookExtStatus`，并把这个来源记进日志；未登录
   （`queryLike` 返回 `[]`）时 `liked=false`，仍走站点自己的 like 路径弹登录提示；
2. 删/增都要**复查**：`unlike` 返回 code 100 之后再问一次 `readLiked`，只有服务端改口才
   `applyLiked(false)` + 计数 -1 + `已取消点赞`；仍然 `liked=true` 就提示「取消失败，详见日志」，
   把两个字面量（`unlike` 原始响应、复查结果）都写进面板。**这是上一轮最大的错**：无条件弹
   「已取消点赞」正是「提示取消但实际没取消」的来源；
3. `updateBookPage` 的 `active` 判定换成复查过的值。它只按 `queryBookExtStatus` 的答案改
   `.likebook` 的 class（`app.v2.js:4936-4945`，全站唯一的写入方），unlike 一成功它就把按钮
   重新点亮。做法是包一层 `updateBookPage`：调用期间把 `queryBookExtStatus` 临时换成
   「原样返回、只把 `like` 覆盖成已复查值」的版本，`updateBookPage` 取完回复后
   （`setTimeout(...,0)`）恢复。不猜时间、不和 class 列表抢。

#### 2. 多次下载同一本书 →「已下载」出现多行

站点侧「已下载」是按 `store.data` 渲染的，而 `getNewBook`（`app.v2.read.js:3218`）按
`(host,id)` 找已存在的记录、有就不 `prepend`——**一个 book 只有一条记录**。多出来的行是我们
自己造的：`moveJobToDownloaded` 在任务完成后无条件 `area.appendChild(row)`
（`app.celoader.bookdownloadedrow`，`_page_vip.html:4014`），守卫只有 `manager.__stvMoved`，
那是**每个 job 实例**的标记；再下一次同一本书是一个新 job，于是又插一行。因为记录只有一条、
章节文件键也只有一份（`offlineBook_<host>_<id>_chapters`），每行导出出来的都是同一份内容——
正是「导出时好像又是导出的同一份数据」。

修法都在 `pageRepair`，三处：

1. `decorateDownloadedRow` 给行盖 `data-stvbook="host/id"`（两个渲染入口——站点列表与我们的
   追加——都经过 `bookdownloadedrow`，所以每行都有键）；
2. `moveJobToDownloaded` 追加前先摘掉同键的旧行（倒序遍历 `area.children`，按
   `getAttribute('data-stvbook')` 比对；测试桩不支持属性选择器，也不用后代选择器）；
3. 读列表时（`getDownloadBooks` 包装里）再按 `host/id` 折叠一次记录，保留 `lastDownload`
   最新的那条 —— 视口层面兜底，不改持久化数据。删除时把同一本书的**所有**记录一起清掉
   （先照旧 `target.delete()`，再扫残留），否则留下的兄弟记录下次启动又会长出一行。

#### 3. 导出里的章节序号与名称还是越南语

`readchapter` 的 `chaptername` 是站点的越南语机翻（`app.v2.js:210` 一带的正文接口），**只有
章节列表带中文原名**：`getChapterListOnline` 在 `app.language != "vi"` 时用 `x.oridata`
（`app.v2.js:270`）。这个源 `SiteI18nData.script` 早就用了（阅读器的章节名就是这么改的），但
导出块是另一份代码，直接拿 `json.chaptername` 当标题，于是 TXT 的
`---------- Chương 15: ...` 在别的阅读器里连目录都切不出来。

修法：

- `SiteI18nData.script`（生成物，源在 `scripts/gen-site-i18n.js`）里把
  `parseChapterList` 改成同时返回 `{names, order}`（`order` 是书本身的章节顺序），并新导出
  `chapterNames(host, id)`（可等待，成功才缓存，失败不缓存以便重试）与 `chineseChapterName`；
- 导出块给每章带上 `cid`，`labelChapters()` 用 `chapterNames` 的结果算标题：
  `chineseChapterName(越南语标题, 中文原名)` 得到「第15章 交锋」；
- **补号一律用书内位次**（`order.indexOf(cid) + 1`），绝不用导出下标——日志里这本是下 15-30 章，
  用下标会编成 1-16；
- `chapterLabel` 优先用算出来的 `label`，兜底从 `'第 N 章'` 改成 `'第N章'`（带空格的形式阅读器
  的目录正则匹配不到）。

#### 验证（本轮）

- `node scripts/check-ios-shim.js` → 22 块 / 350862 字节 / **38** markers（新增
  `querylikestatus`、`after unlike:`、`data-stvbook`、`chapterNames`）
- `node scripts/test-site-patch.js` → **496 条断言**全过（上一轮 486）。新增/改写：
  - 点赞：状态必须来自 `querylikestatus`（桩里 `queryBookExtStatus` 恒返回 `like:true`，用它就
    会重演旧 bug）；unlike 后复查 `liked=false` 才提示；**站点自己的 `updateBookPage` 不能再把
    按钮点亮**；服务端收下却改不动时不许弹「已取消点赞」；没有 `queryLike` 的构建退回
    `queryBookExtStatus`；未登录仍走站点 like 路径；
  - 重复下载：同一本书起第二个 job 后 `[data-stvbook]` 行数仍是 1，并记
    `dropped 1 earlier row(s) for qidian/1034915599`；
  - 导出：三章标题必须是 `第1章 交锋` / `第2章 入门` / **`第3章 决战`**（第三章的站点标题没有
    编号，只能靠章节列表的顺序补），正文里不许再出现 `Chương`，EPUB 的 `<h2>`、`nav.xhtml`、
    `toc.ncx` 都是中文标题，面板记 `chapter headings: 3 of 3 carry a Chinese name`。
- `node scripts/gen-site-i18n.js --check` → 458 labels / 35 fragments（本轮改了生成器模板，
  已重新生成）
- 产物复核：`STV_EXPORT_DUMP=1` 后用 .NET `ZipFile` 独立打开 `book.epub` —— 11 个条目、
  `mimetype` 第 0 个且 `CompressedLength == Length`、`chapter-0001.xhtml` 的 `<h2>` 是
  `第1章 交锋`、`toc.ncx` 的 navLabel 依次是「这些仙子全都不正常！/ 第1章 交锋 / 第2章 入门 /
  第3章 决战」；TXT 里同样是 `第1章 交锋`。

**未证实项**：

- 第 1 项的**根因归属**仍有两种可能，日志只能证明「客户端发了 unlike、服务端答 code 100、
  复查时仍是 liked」，不能证明是服务端没删还是 `status.like` 本身不代表「我」。本轮的改法对
  两种都成立（状态改由 `querylikestatus` 读、且调用后复查），真机日志会给结论：
  正常应是 `[LIKE] qidian/X status querylikestatus liked=true` → `unlike ... -> code 100`
  → `after unlike: querylikestatus liked=false`；若出现 `liked=true` 就是服务端没删，
  下一轮再按日志里的原始响应处理；
- 第 2 项：`store.data` 本身在真机上是否真有重复记录**未经证实**（按源码推不出来），上面的
  折叠与「删除清全部」对两种情形都成立，代价是列表被折叠过；
- 第 3 项：`oridata` 在真机上确实是中文原名这一点，靠「阅读器里的章节名早就是中文」间接成立，
  本机无法直连站点验证（`sangtacviet.com` 在这台机器上解析到非公网地址）。导出会记
  `[TITLE] export: N of M chapter names for host/id`，下一份日志直接给出命中率；
- 导出的 EPUB 仍写 `xml:lang="vi"` / `<dc:language>vi`（正文与标题其实都是中文），本轮没动：
  超出本轮反馈范围，且改了会影响越南语读者的排版。
  → **第十七轮已改**，见 §6.19 (1)。

### 6.19 第十七轮反馈（`日志.txt`，141 行）：导出语言、站点存档声明、取消点赞、首屏慢

本轮日志只有 141 行（18:22:43–18:23:19），但正好压着两件事：一次冷启动的完整时间线，和一次
被点坏的设置页。

#### 1. 导出的 EPUB 声明成越南语

- 上下文：`buildEpub()` 里 `var lang = 'vi';`，于是 `<dc:language>vi</dc:language>` 与每个
  XHTML 的 `xml:lang="vi"` 都是越南语，而正文与标题（第十六轮起）都是中文。
- 影响：iOS 图书这类阅读器会按声明语言排版、断词、选词典和朗读发音。
- 修法：`lang` 改成 `zh`（站点自己的语言代码就是 `zh`，`/mobile/lang/zh.json`）。
- 证据：产物复核见下（用 .NET 的 `ZipFile` 打开导出的 EPUB 逐条读）。

#### 2. 正文里站点自己加的存档声明

- 现象：每章正文都带一句 `@Bạn đang đọc bản lưu trong hệ thống`（「你正在阅读系统里的存档副本」），
  导出的 TXT/EPUB 里也有。
- 定性：这句话**不在客户端的任何文件里**（`grep` 过仓库里全部 js/html/json 与站点下载下来的
  `_dl_*`），是服务端塞进 `readchapter` 正文的，所以只能在「消费正文」的两处去掉：阅读器
  （正文在阅读器的同源 srcdoc iframe 里，主文档的替换扫描进不去）与导出。
- 修法：**一份定义两处用**。`SiteI18nData.script`（生成物）里加 `stripNotice(text)` +
  `stripNotices(root)`，主文档 `sweep()`、iframe 的 `sweepFrame()`、以及 iframe 的
  MutationObserver 回调都调它；导出块调 `window.__stvI18n.stripNotice`，自己不再抄一份规则。
  只删这一句：句子本身、可选的 `Bạn đang đọc ` 引导语、前面的装饰性 `@`、后面的句读；
  段落其余部分原样不动，删空了的段落才连元素一起删（否则留一个空行）。
  这个 pass **不受 SKIP 限制**（站点正文本来就在 SKIP 里、翻译表必须绕开它），但它只认那一句，
  所以不会把中文原文换成别的字。
- 验证：桩里三个位置各放一句（iframe 里整段、主文档带 `@` 前缀、`结尾一句。Bạn đang đọc ...`
  粘在真实句子上），断言前两句清空、第三句只剩 `结尾一句。`、计数 `removed() === 3`；
  导出的 TXT 与 EPUB 里都不再出现 `bản lưu`，而 `第三段` 仍在。

#### 3. 取消点赞还是失败（这次是「站点没删」）

- 本轮的日志把上一轮的两种可能收窄成了一种。时间线（同一本书 `qidian/1034915599`）：
  ```
  18:23:12  querylikestatus → {"list":[{...id:2541666},{...id:2541667}],"code":100}   ← 两行
  18:23:12  [LIKE] qidian/1034915599 status querylikestatus liked=true raw=[...]
  18:23:12  unlike → {"status":"success","code":100}
  18:23:13  querylikestatus → 与上面**逐字节相同**的两行
  18:23:13  [LIKE] ... after unlike: querylikestatus liked=true raw=[...]
  18:23:13  取消失败，详见日志
  ```
- 两个结论：
  1. 上一轮改的**状态来源是对的**：`querylikestatus` 返回的是「我赞过的对象」，键是
     `type:id`——站点自己的社区代码就是这么用的（`app.socialpost.queryLikeStatus`，
     `app.v2.js:5252-5270`：把 `down.list` 里每个 `objectid` 对应的按钮点亮）。
  2. 服务端**收下了删除请求却一行都没删**：前后两次查询的行数、行 id 完全一样。
     注意 `unlike` 自己返回的是 `{"status":"success","code":100}`，也就是说「成功」不等于「删掉了」。
- 另一个事实：这本书有**两行** like 记录（`id` 2541666 / 2541667）。站点的点赞按钮没有防重复，
  历史上多轮反复点击就会留下多行。
- 站点的契约：`app.api.unlike(type,id)` 只有社区在用（`app.v2.js:5239`，
  `unlike(type, topic.id)`），**书籍这条路上站点自己从不取消**，所以「书本 unlike 该用哪个键」
  没有任何站点内证据。
- 修法（阶梯，全部是「有证据才试」的键）：
  1. 先用站点契约里的**对象 id**（`unlike(host, bookId)`）——这是唯一确定只作用于这本书的形式；
  2. 复查仍是 liked 时，拿 `querylikestatus` 刚返回的每一行 `id`（上限 3 个）逐条 `unlike`，
     **每条之后都复查**；
  3. 只有当行的 `objectid` 确实是这本书（或 `type:id` 键相等）时，那一行的 `id` 才会被当作
     删除键——行 id 是删除键，不能拿别的对象的行来猜；不是自己的行最多是个 no-op；
  4. 全都不生效就如实提示 `取消失败：站点没有删除这个赞（见日志）`，绝不谎报。
  每一次尝试都写一行 `[LIKE] unlike(<object|row NNN>) host/id -> code N raw=...` 与
  `[LIKE] host/id after unlike(<...>): <来源> liked=<bool> raw=...`，下一份日志能直接看出
  哪个键真的删得动、还是要认账「站点对书籍没有取消路径」。

#### 4. 首次进入应用仍然慢

日志里的冷启动时间线（这台设备）：
```
18:22:43  [BOOT] +10ms document start: app=no config=no navbar=absent
18:22:44  [BOOT] +1001ms stylesheet: app=no config=no navbar=49px
18:22:46  [BOOT] shell released at +2889ms (app.v2.css at +2889ms (link load))
18:22:47  warp.php ×3（721 / 862 / 1217ms）+ bookinfo.php 676ms + lang/zh.json 1265ms
18:22:47  booklist.php?method=history 1295ms
18:22:53  searchBooks 1959ms → 首页书单落地
```
也就是说：**站点 UI 在 +2.9s 才可用，首页数据在 +10s 才齐**。这一轮能确定并修掉的是两处
「我们自己的浪费」，剩下的属于站点自身的串行链（外壳 HTML 的 TTFB ~1.2s，`app.v2.js` 59KB
在它后面；当前能做的结构性解法只有把静态资源搬进本地 origin，工作量大、风险高，见
`docs/optimization-plan-2026-09-23.md` §3/P2）。

**(a) 资源 token 里的日期**：`assetCache` 的 token 原本是
`'stv' + generation() + '-' + Math.floor(Date.now() / DAY)`，也就是**每天换一次 URL**。
后果：每天第一次启动，启动关键路径上的三个文件（`app.v2.js` 59KB + `app.v2.css` 10KB +
`app.v2.bookdisplay.js` 5KB）必然是全新 URL、必然整包重下；而服务器自己发的是
`max-age=86400`，本来可以让 WebKit 当天直接读盘、隔天只花一个 304 的代价去校验。
**日期这一项不但没有收益，还正好把「每天第一次启动」变成最慢的那次。**
修法：token 只留 `generation`（`stv1`），过期/更新由服务器自己的 `max-age=86400` 兜底，
站点改版而文件名不变时用设置页「强制刷新站点资源」立刻换代。
- 测试：桩里把上下文的 `Date.now` 往后推 3 天，token 必须与今天**完全一致**；
  换 generation 必须变。

**(b) 一次点错设置换来 25 个 403**：
```
18:22:58  [TAP] contextmenu → [TAP] div.contextmenuitem → [LOG] app.config.ux.app_domain
18:23:04  [TAP] contextmenu → [TAP] div.contextmenuitem → [LOG] app.config.ux.app_domain
18:23:07→19  GET https://sangtacviet.app/mobile/lang/https://sangtacviet.app.json → 403 ×25
```
- 链路：站点设置页的语言行是
  `<contextmenu value="app.config.ux.app_language" onchange="app.text.changeLanguage('value')">`
  （`_page_vip.html:1464`），而这个 `onchange` 是被 **eval** 出来的：
  `eval(data.onchange.replace("value", d.value))`（`_page_vip.html:3646-3649`）。日志里
  `console.log(menu.selection)` 打出的是 `app.config.ux.app_domain`（同一个函数 `:2051`），
  紧接着 `changeLanguage` 收到的却是域名的值——即被点的那个 `<contextmenu>` 上，
  `value` 来自域名行、`onchange` 来自语言行。
- `changeLanguage` 的失败路径是**一次网络请求**（`/mobile/lang/<值>.json`，
  `app.v2.js:1876/1944`），值不是语言就必然 403：日志里 25 次、每次 ~500ms、串着发。
- 修法：给 `app.text.changeLanguage` 加一道闸——**不是语言代码就直接拒，不发请求**，
  并记一行 `[PATCH] refused a language that is not one: <值>`。语言代码的定义按站点自己的三个
  代码（vi/en/zh）收：字母开头，只允许字母/数字/`-`/`_`，最长 12。
  这是**不改站点代码**的前提下唯一能落在「坏值进入网络之前」的位置。
- 测试：模拟站点自己的 `changeLanguage`（`app.v2.js:1942-1953`），连调 3 次域名值 →
  `loadOnline` 调用次数必须是 0、站点语言不变；再调 `en` → 必须照常发一次请求。

#### 验证（本轮）

- `node scripts/check-ios-shim.js` → 22 块 / 362208 字节 / **42** markers（新增 `rowIds`、
  `stripNotice`、`bản lưu trong hệ thống`、`refused a language that is not one`；
  上一轮的 `after unlike:` 标记随日志文案改成 `'unlike(' + label`）
- `node scripts/test-site-patch.js` → **516 条断言**全过（上一轮 496）。新增/改写：
  - 存档声明：iframe 内整段被删且元素被摘掉、旁边的正文不动、主文档带 `@` 前缀的也删、
    粘在真实句子后的只删自己那句、计数 3；
  - 导出：TXT 与 EPUB 都不含 `bản lưu` 且 `第三段` 仍在；`<dc:language>zh</dc:language>`、
    `xml:lang="zh"`，且不再出现 `<dc:language>vi</dc:language>`；
  - 取消点赞阶梯：先对象 id、再逐行 id、**别的对象的行 id 不许当删除键**、每一次都有带键名的
    日志、行删除生效即提示成功；
  - 资源 token：`/^stv[0-9]+$/`、把 `Date.now` 推后 3 天 token 不变、换 generation 会变；
  - 语言闸：域名值三次调用 0 次请求 + 拒绝日志 + 站点语言不变，`en` 仍然照发。
- `node scripts/gen-site-i18n.js --check` → 458 labels / 35 fragments（生成器模板已同步，
  `SiteI18nData.swift` 重新生成）
- 产物复核：`STV_EXPORT_DUMP=1` 后用 .NET `ZipFile` 独立打开 `book.epub` —— 11 个条目、
  `mimetype` 第 0 个且 `CompressedLength == Length`、`content.opf` 里
  `<dc:language>zh</dc:language>`、`chapter-0001.xhtml` 的 `xml:lang="zh"` 且正文是
  `<h2>第1章 交锋</h2><p>第一段 &amp; 第二段</p><p>第三段</p>`（存档声明不在），
  整个压缩包里搜不到 `bản lưu`；TXT 头部仍是书名/作者/来源，也没有那句话。

**未证实项**：

- 第 3 项：`unlike` 用**行 id** 是否真能删掉，只有真机能回答（本机 `sangtacviet.com` 解析到
  非公网地址，连不上）。阶梯已经把所有「有依据的键」都试过并逐条复查，下一份日志会给出结论：
  若出现某一行 `unlike(row NNNN) ... code 100` 之后 `liked=false`，就是行 id 生效；若三次之后
  仍是 `liked=true`，则站点对「书籍」这一类对象根本没有取消路径（按源码看，站点自己也只在
  社区帖子上调 `unlike`），届时要么接受「如实提示失败」，要么把点赞按钮改成只读。
  → **第十八轮已定案**：行 id 被服务端直接拒（`code 101`，见 §6.20 (1)），阶梯已按用户要求拆掉。
- 第 4 项：**(a)** 的收益需要跨天的两次冷启动对比才能量化（本机看不到 WebKit 的网络层日志，
  只能看 `[BOOT] shell released at +Nms` 前移多少）；**(b)** 只是把这一次 403 风暴的成因修掉，
  风暴本身由站点设置页的 onchange 串行引发，若真机日志里出现别的 `refused a language` 行，
  说明还有别的入口，但代价已被限成一行日志。
  → **(b) 第十八轮已被真机证实**：489 行日志里一次 403 风暴都没有（§6.20 (3) 的时间线）。
- 「正文里的存档声明」只按用户给的句子做匹配（`bản lưu trong hệ thống`，前缀引导语与 `@`
  一并吃掉）。若那句话还有别的写法（例如后面跟域名），会留在正文里——`[PATCH] dropped the
  site archive notice from the chapter body` 这行只代表**至少删掉一条**，看到日志却还残留就
  把原文发我，按实际写法补。
  → **第十八轮查明不是写法问题，是那段代码根本扫不到正文所在的 frame**（§6.20 (2)）：整场
  会话一条 `[PATCH] dropped` 都没有，用户却仍然看到那句话。

### 6.20 第十八轮反馈（`日志.txt`，489 行）：取消点赞收尾、存档声明还在、TTS 读错页

本轮日志 489 行（19:21:54–19:31:21），把上一轮留下的三个尾巴一次性钉住了。

#### 1. 取消点赞：站点确实没有这条路（用户「不行就算了」）

时间线（同一本书 `qidian/1034915599`，19:22:06–19:22:11）：

```
19:22:06  querylikestatus → {"list":[{"objectid":"1034915599","id":"2541666"},
                                    {"objectid":"1034915599","id":"2541667"}],"code":100}
19:22:07  unlike(对象 id) → {"status":"success","code":100}       [LIKE] unlike(object) -> code 100
19:22:08  querylikestatus → 与上面**逐字节相同**的两行            [LIKE] ... after unlike(object): liked=true
19:22:09  unlike(行 id 2541666) → {"text":"Không tìm thấy lịch sử.","code":101}
                                                                  [LIKE] unlike(row 2541666) -> code 0
19:22:11  unlike(行 id 2541667) → 同上                            [LIKE] ... after unlike(row 2541667): liked=true
19:22:11  取消失败：站点没有删除这个赞（见日志）
```

- **对象 id**：被接受（`code 100`）却一行都没删。
- **行 id**：服务端直接拒，`{"text":"Không tìm thấy lịch sử.","code":101}`——「找不到历史」，
  说明这个端点是在**阅读历史**里找这个 id，而不是在点赞表里。`app.api.unlike` 会把
  `code != 100` 统一成 `{code:0}`（`app.v2.js:4924-4930`），所以日志里看到的是 `code 0`。
- 站点自己 `unlike` 的**唯一**调用者是社区帖子（`app.v2.js:5239`，`unlike(type, topic.id)`），
  书籍这条路上站点内没有契约。

修法（按用户「不行就算了」——不再花力气找键）：**拆掉阶梯**。只发一次
`unlike(host, bookId)`（站点自己的契约形式），复查一次，失败就照实提示
`站点不支持取消这个赞`，按钮维持站点当前的点亮状态、`.liked` 计数不动。相比上一轮少 2 个
请求、少约 2 秒等待，结论一样。`[LIKE]` 日志保留（`unlike(object) ... -> code N raw=` 与
`after unlike(object): <来源> liked=<bool> raw=`），下一份日志若出现 `liked=false` 就是站点改了口。

#### 2. 正文里的存档声明还在——不是匹配问题，是根本扫不到

- 事实：整份 489 行日志里**一条 `[PATCH] dropped the site archive notice from the chapter body`
  都没有**，而用户在正文里仍然看到 `@ Bạn đang đọc bản lưu trong hệ thống`。
- 先排除匹配问题：日志里的原文与生成物里的字面值**逐码点相同**（都取出来比对过：
  `0062 1EA3 006E 0020 006C 01B0 0075 ...`，同一套 NFC）。所以是那段代码没有跑到那个节点。
- 根因（四条叠加，缺一条都不足以全解释）：
  1. 所有注入块都是 `forMainFrameOnly: true`（`SangTacAppPlugin.swift:95`），**frame 里不注入**，
     正文只能靠主文档里的代码伸手进去；
  2. 主文档的 MutationObserver 只在「新增节点本身就是 `<iframe>`」时才 `attachFrame`，
     而阅读器是把整页（含 iframe）当**一个子树**插进来的；
  3. 更关键的是 **`srcdoc` 赋值不产生 mutation**：iframe 元素没变，变的是它内部的 document，
     所以即便 frame 早就被 attach 过，换文档后也再没人管；
  4. `attachFrames()` 只在 `FRAME_DELAYS = [0,300,1000,2000,4000,8000] ms` 跑 6 次，而这份日志里
     用户 19:23 与 19:30 才打开阅读器——**8 秒后建立的 frame 再也没人看**。
     另有 `querySelectorAll` **不跨文档**：pageflip 模板是一层 srcdoc frame，章节正文可能又是
     里面的一层，只扫主文档找不到最里面那层。
- 修法（`scripts/gen-site-i18n.js` 模板 + 重新生成的 `SiteI18nData.swift`）：
  1. `attachFrame()` 里递归扫**这一层自己的** iframe（新函数 `attachFramesIn(root)`，
     document 与 element 都能传），frame 套 frame 也能到最里面；
  2. 主文档 observer 对每个新增节点做 `stripNotices(node)`，并在**子树**里找 iframe
     （不再要求新增节点本身是 iframe）；`characterData` 变化也直接剥；
  3. 新增 **1 秒周期的 frame + 存档声明扫描**（上限 1 小时自动停），兜住「iframe 已存在、
     srcdoc 换了文档」这条没有 mutation 的路。
- 验证：桩里在**文档启动之后**才追加一个含存档声明的 frame，等 1.2 s 断言声明被删掉、
  同一 frame 的正文留下；再加一个 frame 套 frame 的用例，断言最里层的声明也被删。

#### 3. TTS 读的不是在看的那一页

日志给出的指纹（19:30:35 与 19:31:01 两次**完全一样**，中间用户还翻过页）：

```
19:30:35  [TTS] fallback source [document body]: 111 chars -> 7 sentence(s), first=就在此时，
19:30:35  [TTS] site tokenizeSentence empty, using the chapter-text fallback -> 7 sentence(s)
19:30:35  [TTS] reader TTS start: sentences=7 first=9 chars provider=ios
19:31:01  [TTS] fallback source [document body]: 111 chars -> 7 sentence(s), first=就在此时，
```

- `source` 落在 **document body** 这条最后的兜底分支，字符数与首句两次一致。
- 根因：pageflip 显示器的结构是「先把整章渲染进一个**离屏**的 `#maincontent`，再把切好的页
  搬进真正显示的 frame」（`chapterdisplay.js` `setContent` 1641-1646、`pushPageToScreen`
  1706-1719；`currentPageId` 就是当前页在 `currentChapter.pageElements` 里的下标）。而 shim 的
  取文顺序是「`getCurrentChapter().q('.contentcontainer')` → 空就 `#maincontent`/`body`」：
  pageflip 的 `getCurrentChapter()` 返回的是**章节对象**（`PageClipChapter`，没有 `q`），
  于是 `chapterHolder()` 永远返回 null，句子就从**离屏渲染器的残留**里切——111 个字符正是
  分页把节点搬走之后留在那里的一小段，所以「不在看的这一页、翻页也不变、不知道是哪里的内容」。
- 修法（`readerTts` 块）：
  1. 新增 `pageModelText(display)`：用 `currentChapter.pageElements[currentPageId..]` 拼出
     「当前页 → 本章结尾」，这就是「从我在看的这页开始读」；读完本章后站点自己的 `player.play()`
     会 `app.reader.nextChapter(true)` 自动接下一章（`app.v2.read.js:2585-2594`），连续性不动。
  2. `chapterHolder()` 兼容两种形状（只有元素才有 `q`），继续服务滚动式显示器的
     `.contentcontainer`。
  3. 拼好的文本再过一次 `window.__stvI18n.stripNotice`——存档声明一份定义两处用。
  4. `app.tts.start` 的包装里加**页键**（`cid + '#' + currentPageId`）与「列表已读完」判定：
     站点只在**章节**变化时重建队列（`app.v2.read.js app.tts.start` 的 `isViewChanged()`），
     所以翻页后或读完后按播放原本会重播旧页的句子（读完时更糟：站点自己的 `play()` 会直接跳章）。
  5. 日志行加 `page=<cid>#<页码>`，下一份日志能直接看出读的是哪一页。
- 验证：桩里造一个 pageflip 形状的显示器（`currentPageId: 1` + 三页 `pageElements` + 一个离屏残留
  `#maincontent`），断言句子从第 2 页开始且出现 `pageflip page 2 of 3`；把 `currentPageId` 改成 2
  再按播放 → 队列重建为第 3 页；把 `currentId` 推到最后再按播放 → 重建而不是交给站点跳章。

#### 验证（本轮）

- `node scripts/check-ios-shim.js` → 22 块 / 367873 字节 / **46** markers（`rowIds` 换成
  `站点不支持取消这个赞`，新增 `pageModelText`、`pageflip page `、`__stvPageKey`、`attachFramesIn`）
- `node scripts/test-site-patch.js` → **522 条断言**全过（上一轮 516）。新增/改写：
  - 取消点赞：只发一次、用的是对象 id、**任何行 id 都不再作为删除键**、提示是
    `站点不支持取消这个赞` 且绝不出现 `已取消点赞`、按钮保持点亮（诊断里有
    `the button stays as the site has it`）；
  - 存档声明：**文档启动之后**才出现的 frame 里的声明照样被删、该 frame 的正文留下、
    frame 套 frame 的最里层也被删；
  - 朗读来源：句子从 `currentPageId` 那一页开始、日志出现 `pageflip page 2 of 3`、
    翻页后队列重建、读完后再按播放是重建而不是跳章。
- `node scripts/gen-site-i18n.js --check` → 458 labels / 35 fragments（模板与生成物同步）

**未证实项**：

- 第 2 项：真机这一份日志里应出现 `[PATCH] dropped the site archive notice from the chapter body`
  至少一行。匹配仍只认用户给的那句原文（`bản lưu trong hệ thống`）；若还有别的写法（例如后面
  跟域名）会留在正文里，把原文发我按实际写法补。
- 第 3 项：`pageElements` / `currentPageId` 是**站点自己的字段名**（未压缩的
  `app.v2.chapterdisplay.js`）。真机应出现 `fallback source [pageflip page N of M]`；若仍出现
  `fallback source [document body]`，说明取值链在真机上被站点改过，按新结构再对一次。
  滚动式显示器（没有「页」的概念）仍是「从本章开头读」——真机若是那个模式，日志会显示
  `fallback source [current chapter]`。
- 第 1 项：站点对书籍**是否真的完全没有取消路径**没有定案（`Không tìm thấy lịch sử` 提示这个
  端点找的是**历史记录 id**，例如书详情里的 `lid`）。用户说「不行就算了」，本轮不再试；
  若哪天想再试一次，最小实验是把 `lid` 传进去试一个请求，代价一行日志。


