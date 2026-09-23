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
20. **冷启动的剩余时间在站点自己的串行链上**（见 §6.19 (4)）：外壳 HTML 的 TTFB ~1.2s，`app.v2.js`（59KB）在它后面，实测站点 UI 到 +2.9s、首页数据到 +10s 才齐。本轮修掉的是我们自己的两处浪费（资源 URL 每天换一次、设置页一次点错连发 25 个 403 的 `/mobile/lang/<域名>.json`）；要再往下压只有把静态资源搬进应用（`docs/optimization-plan-2026-09-23.md` §3/P2）。**§6.22 已做掉可达的那 8 个文件（906296 字节 源文件随包 + 后台 `If-Modified-Since` 校验）**，解析器自建的那 13 个仍需接管文档加载；**§6.23 用真机日志 + 冷缓存实测（16 个引用合计 1232KB、`max-age=86400` 且无 ETag，一天最多付一次，而首屏在 +1225ms 已释放）把这条路否掉了**。

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
  *（第十九轮：`日志2.txt` 里 `[PATCH]` 仍是 0 行——那份日志从 20:07:31 才开始，启动的几行没被复制
  进来；用户已确认正文里的声明消失，本项按结果关闭，不再挂。）*
- 第 3 项：`pageElements` / `currentPageId` 是**站点自己的字段名**（未压缩的
  `app.v2.chapterdisplay.js`）。真机应出现 `fallback source [pageflip page N of M]`；若仍出现
  `fallback source [document body]`，说明取值链在真机上被站点改过，按新结构再对一次。
  滚动式显示器（没有「页」的概念）仍是「从本章开头读」——真机若是那个模式，日志会显示
  `fallback source [current chapter]`。
  *（第十九轮定案：`[pageflip page N of M]` 出现且页码跟着翻页走，「读的是哪一页」这一层成立。
  滚动式「从本章开头读」也在这一轮改成从可见行开始，见 §6.21。）*
- 第 1 项：站点对书籍**是否真的完全没有取消路径**没有定案（`Không tìm thấy lịch sử` 提示这个
  端点找的是**历史记录 id**，例如书详情里的 `lid`）。用户说「不行就算了」，本轮不再试；
  若哪天想再试一次，最小实验是把 `lid` 传进去试一个请求，代价一行日志。

### 6.21 第十九轮反馈（`日志2.txt`，905 行）：朗读起点改成「屏幕上看得到的那一行」

这一轮用户只报了一件事，另两件是确认：正文里的 `@Bạn đang đọc bản lưu trong hệ thống` **已经没了**；
但正文朗读「读的不是当前页面最开始的内容，而是**上一页最后几行**开始」，滚动模式要求「从屏幕可见的
第一句开始」。

#### 日志（905 行，20:07:31 起）

```
20:07:38 [TTS] fallback source [pageflip page 2 of 9]: 2532 chars -> 204 sentence(s), first=第三章 休伤吾主
20:07:38 [TTS] reader TTS start: sentences=204 first=12 chars page=7594448741977817662#1 provider=ios
20:08:21 [TTS] fallback source [pageflip page 3 of 9]: 2200 chars -> 182 sentence(s), first=第三章 休伤吾主
20:08:21 [TTS] reader TTS start: sentences=182 first=12 chars page=7594448741977817662#2 provider=ios
20:08:48 [TTS] fallback source [pageflip page 2 of 8]: 2360 chars -> 158 sentence(s), first=第四章 永恒传说
20:10:30 [TTS] fallback source [pageflip page 3 of 8]: 1937 chars -> 137 sentence(s), first=第四章 永恒传说
```

- 上一轮的修复本身生效了：来源从 `[document body]` 变成 `[pageflip page N of M]`，页码键 `#1` → `#2`
  跟着翻页变，说明「读的是哪一页」这一层已经对。这一份日志里 `[PATCH]` / `[LIKE]` 都是 **0 行**
  （日志从 20:07:31 才开始，启动那几行没被复制进来）；声明消失是用户直接观察到的结论。
- 根因是第二层：**页面的文本不是页面看得见的文本**。切分器 `splitPage`（`chapterdisplay.js`
  1095-1113）切一段时**克隆两份**——保住上半的页拿一份 `height: clipHeight; overflow: hidden` 的副本，
  下一页拿一个 `div`（同样 `overflow: hidden`）套住**同一段**、给子节点 `marginTop: -clipHeight`
  把已经显示过的行推到盒子上方。两份的 `textContent` 都还是**整段**，所以第二页的文本开头正好是
  上一页末尾那几行——用户的原话「从上一页最后几行开始读」说的就是这个形状，不是「切分不准」，
  而是**读的是节点树，节点树里两半都在**。
- `first=第三章 休伤吾主` 是第二个线索：`createPage()`（1142-1166）在每页盖了一个 `chaptertopinfo`
  固定页眉（章节名 + 时钟，`position: absolute; top: 0; height: 14px`，正好压在正文第一行上），
  它也在 `textContent` 里，于是每页的第一句都是「章节名 + 时间」。
- 修法（`readerTts` 块）——起点不问节点树，直接问 WebKit：
  1. `caretAtTop(doc, box)`：对**屏幕上那个盒子**的顶部做 `caretRangeFromPoint` 命中测试
     （`webkitCaretRangeFromPoint` / `caretPositionFromPoint` 兜底），自上而下每 2px 扫一遍
     （最多 320px）；命中落在 `.chaptertopinfo` 里的继续往下走，所以固定页眉既不会被读、也不会
     把起点挡在它后面。`leftmostCaret()` 再用命中行的 rect 左沿重探一次，避免从一行中间开始念。
  2. 取文改成**按块收集**（`blocksText` / `nodeText`）：跳过页眉块、块与块之间加换行、块内文本节点
     之间不加（站点自己的 `<i>` 标注不能把句子切断），从可见的那个字开始，到本页末尾。
  3. 后面的页只按块收集，并**跳过开头的负边距包壳**（`isSpillBlock`：DIV 且首个子元素
     `marginTop < 0`）——那半段上一页已经交过，既不会念两遍也不会漏。判定用的是「第一个
     **有文字**的块」而不是「第一个子节点」：`createPage()` 先把页眉写进页面的 `innerHTML`，
     所以页眉是 child 0、包壳是 child 1——按 `i === 0` 判会在真机上完全不生效（页眉开着的时候
     每一页都带页眉，等于这个规则永远不触发）。这一条是自查时发现的，测试里把第三页也加上页眉
     就能抓住它（把规则改回 `i === 0` 会红 3 条）。
  4. 滚动式显示器走同一条路：可见顶端就是视口滚到的位置（`.contentcontainer` 的 rect 与视口取交），
     所以「从屏幕可见的第一句开始」在两种模式里是同一份代码。
  5. 来源行写明起点取自哪里：`pageflip page 2 of 9, from the visible line`；WebKit 答不出来时退回
     `, from the top of the page`（与上一轮行为一致，不会因为一次命中失败就静默或读空）。
  6. `coveredTop(win)`：阅读器自己的标题栏在**宿主文档**里（RECT 日志把它量在 0..82），可能盖住
     frame 的顶部——被盖住的行不算「看得见」，所以扫描起点再往下压 `barRect.bottom - frameRect.top`。
     frame 本来就落在标题栏下面时这个值是 0，两种布局都安全。
  - 顺带修的：`isChromeNode` 原来从文本节点起步时 `while (el && el.nodeType === 1)` 直接不进循环，
    文本节点永远不算页眉——测试里就表现为「起点落在页眉上、然后整段被跳过、最后退回旧路径」。

#### 验证（本轮）

- `node scripts/check-ios-shim.js` → 22 块 / 378919 字节 / **50** markers（`pageModelText` 换成
  `visiblePageText`，新增 `caretRangeFromPoint`、`skipSpill`、`isSpillBlock`、`chaptertopinfo`）
- `node scripts/test-site-patch.js` → **531 条断言**全过（上一轮 522）。新增：
  - 桩里给文本节点加**渲染行表**（`layoutLines`）+ `caretRangeFromPoint`（`attachCaretModel`），
    让「命中测试看不见被裁掉的那些行」这件事可以在测试里成立；元素的 `getBoundingClientRect()`
    改成认 `__rect`（没给的照旧）；
  - 起点：造一个「上一页最后一行」在盒子外的克隆 + 每页页眉 + 下一页重复的包壳，断言首句是
    **可见行**（`第二页第一句。`）、被裁掉的那行不再出现、页眉不念、包壳只念一次；
  - 标题栏遮挡：宿主文档里放一个 `.titlebar`（bottom 40）压住 frame 顶部，断言起点落在它下面的
    那一行，被盖住的字不念；
  - 滚动式：`.contentcontainer` 的 rect 顶部在视口之上，断言只有屏幕上那一句被读；
  - 三条来源行各一条断言（两条 `, from the visible line`、一条退化的 `, from the top of the page`）。
  - 旧的两条 pageflip 断言**没有改**：它们现在正好覆盖「WebKit 答不出来」的退化路径
    （桩里那些页没有渲染行表），仍然从 `currentPageId` 那一页开始读。
- `node scripts/gen-site-i18n.js --check` → 458 labels / 35 fragments

**未证实项**：

- 这一轮的起点精度**只能在真机上验证**：桩里的命中测试是我们自己写的模型，不是 WebKit。真机应出现
  `fallback source [pageflip page N of M, from the visible line]`；若仍是
  `, from the top of the page`，说明这台 WKWebView 没给 `caretRangeFromPoint`（或返回的 caret 不在
  页面元素里），退化行为与上一轮相同、不会更差，但起点问题就还在，需要按新的日志再对一次。
- 页眉（章节名 + 时钟）**故意不念**：它在屏幕上确实看得见，但每页都重复、还带当前时间，按「内容」处理
  更合理。若用户希望连它也念，去掉 `isChromeNode` 的两处判断即可（一行）。
- 滚动式显示器本轮仍只按「视口顶端」取起点；若阅读器在 frame 内还有自己的悬浮工具栏，起点会落在
  它下面一行左右——真机若是这个形状，把日志给我，按工具栏的 rect 再收一次。
- 第 1 项（取消点赞）与上一轮同：已经拆掉阶梯、只试站点契约那一种键，仍未定案，用户说「不行就算了」。

### 6.22 第二十轮（用户要求：把站点资源镜像到本地）：可达的 8 个文件进包 + `[ASSET]` 时间线

#### 证据（`日志2.txt`，905 行，20:07:30–20:11:28）

先说这份日志**不能**回答什么，因为这决定了本轮的做法：

- tag 分布：`TTS` 359 / `LOG` 349 / `ERR` 37 / `TAP` 23 / `Http` 14 / `RECT` 12 / `MSG` 2 /
  `PAGE` 2 / `SAFE` 1 / `BOOT` **1**。这是一份**阅读器会话**日志（20:07:30 起，用户开着日志开关
  在正文里操作），不是启动日志——`[BOOT]` 行只有一条 `+20001ms stylesheet: app=yes config=yes navbar=85px`。
- 那 14 条 `[Http]` 是**唯一**有耗时证据的网络行，全部是 API：
  `searchBooks 74047b in 1013ms`、`readchapter 7828b in 710ms`、`bookinfo 1556b in 710ms`、
  `updateOldLink 39b in 667/711/916/2782ms`、`ngmar=onl2 1b in 818/1116ms`，两条命中章节缓存
  `in 0ms (cache)`（P0-5 的 `ResponseCache` 在工作）。
- **站点自己的静态资源一次都没出现**——它们由 WKWebView 直接抓，不走原生 Http 插件，
  所以这份日志里没有任何一条能说明它们花了多少时间。这正是本轮的第二个产物（`[ASSET]` 时间线）
  存在的原因。

动手前用本机探测把三件事定死（这决定了实现方式，不是猜测）：

| 探测 | 结果 |
|---|---|
| 外壳 HTML 里被 `Math.random()` 破缓存的 URL | 4 处：`app.v2.css`（:3066，`setAttribute('href')`）、`app.v2.js`（:5207）、`bookdisplay`（:5208）、`config`（:5211） |
| 由 HTML 解析器直接建 `<script src>` 的静态文件 | 13 个（`_page_vip.html` :96–:130：`jqr.js?v=10`、`bootstrap.min.css?origin=`、`font/font.css?v=4`、`asset/all.min.css`、`main.css?v=44`、`theme.default.css?v=0`、`bootstrap.min.js`、`stv.ui.js?v=1.360`、`stv.host.js`、`iro.js`、`materialize.icon.css`、`crypto-js.min.js`、`html2canvas.min.js`、`gsap.min.js`、`materialize.min.css`、`materialize.min.js`） |
| 这 8 个可达文件的响应头与体积 | 全部 `Cache-Control: max-age=86400` + **`Last-Modified`**、**没有 ETag**；`app.v2.js` 259387 字节（LM 2026-06-28）、`app.v2.css` 52744（2025-05-09）、`bookdisplay` 27155（2025-07-12）、`config` 4095（2025-11-12）、`read` 145097（2026-02-14）、`chapterdisplay` 157668（2026-02-15）、`stv.tts.js?v=7` 46220（2025-12-19）、`hanviet.js` 176419（2020-11-09） |
| 站点是否发 CSP | **没有** `Content-Security-Policy` 头（node fetch 实测）→ 内联脚本、`eval`、`blob:` 三种做法都合法 |

`Last-Modified` 是关键：它让「每次启动后台校验一次」变成一次 **304、无 body** 的往返，
这也是站点自己给 WebKit 的缓存时长（`max-age=86400`）——所以镜像的陈旧窗口不会比现状更差。

#### 根因与可达性（为什么只做 8 个）

- WKWebView **无法拦截/重定向 `https://`**（`WKURLSchemeHandler` 只吃自定义 scheme，
  `WKContentRuleList` 只有 block / block-cookies / css-display-none / make-https，没有重定向）。
  所以：**JS 钩子能改的只有 `script.src` / `link.href` 的 setter 与 `setAttribute`**，
  也就是那 4 个被随机化的 + 4 个由 `scriptmanager.load` 拉的；解析器自建的那 13 个注入层永远碰不到。
- 要连那 13 个一起拿掉，只有一条路：**原生侧取外壳 HTML、把 `<script src>` 换成内联/`data:` URL、
  再用 `loadHTMLString(html, baseURL: 真实 URL)` 载入**（origin 仍是 `https://sangtacviet.com`，
  所以 Cookie/Referer/Turnstile 都不动）。那条路要接管 `webView.navigationDelegate`（Capacitor
  自己占着），本机无法编译、无法真机验证，**本轮没做**，见下面「未证实项」。

#### 改了什么

1. **`scripts/gen-site-assets.js`**（新）：从站点原样下载那 8 个文件到
   `plugins/app/ios/Sources/SangTacAppPlugin/site-assets/`，写 `manifest.json`（name / path /
   bytes / sha256 / lastModified）。`--check` 只读盘、重算哈希，CI 跑它。**生成时就验**：`.js`
   必须能被 `new Function` 解析、文件开头不能是 HTML（Cloudflare 拦截页存成 `.js` 是这类镜像最
   典型的死法，这里在构建期抓住而不是在真机上）。
2. **`plugins/app/Package.swift`**：`resources: [.copy("site-assets")]`，随 IPA 发布。
3. **`SiteAssets.swift`**（新）：读快照 + 读 `Library/Application Support/stv-site-assets/` 里
   被刷新过的副本（**后者优先**），用 `JSONSerialization` 拼出 `window.__stvSiteAssets` /
   `window.__stvSiteStamps` 两个表。两个刻意的选择：
   - **不用 `Bundle.module`**：SwiftPM 生成的访问器在资源包不在预期位置时是 `fatalError`，
     等于把一个打包失误变成启动崩溃；这里改成自己找、找不到返回 nil（镜像静默失效，页面照旧全网络）。
   - **不用 Swift 字符串字面量装站点代码**：那 900KB 里全是反斜杠、两种引号和越南文，
     手写转义正是第 6.1 节那次「shim 是语法错误、整层静默死掉」的同类错误。让 Foundation 转义。
     `SiteAssets.swift` 里因此**一个 `\"\"\"` 块都没有**（`check-ios-shim.js` 扫的是那种块）。
4. **`assetMirror` 块**（`SitePatch.swift`，注入顺序第 4，紧跟 `assetCache` 之后——它包住
   `assetCache` 刚装的那两个钩子，所以必须在它后面）：
   - **脚本走 `blob:` URL**，通过站点自己用的那个 `HTMLScriptElement.src` 属性赋进去：
     元素仍然是普通 `<script>`，站点 loader 的 `onload` 与按 URL 去重的 `stack` 原样工作。
     换成「新建一个内联 `<script>`」会把这两样都破坏掉。
   - **样式走 `<style>` 节点**：pageflip 的模板用
     `document.querySelectorAll("link[rel=stylesheet],style")` 重建每个 frame 的 `<head>`，
     `<style>` 取 `css.textContent`（`_dl_app.v2.js` @199996），所以这个形状能**确定**把站点
     样式带进 frame；blob 的 `href` 要在 `about:srcdoc` 文档里解析，不可靠。
     `bootShell.siteCssReady()` 相应增加按 `data-stv-mirror` 认表（`<style>` 没有 `href`）。
   - **两条自愈**（这是「盲改也得能装」的前提）：镜像脚本 `error`（元素上的 `error` 事件，
     或 `window.onerror` 的 filename 是 `blob:`）→ 写 `stv.mirror.off` 并 reload 一次；
     `app.v2.js` 载入 8 秒后 `window.STV_SERVER`（该文件第一行就声明的全局）仍未定义 → 同样处理。
     第二次加载完全走网络，与没有这个功能时**逐字节相同**。刻意**不用**「N 秒后 `window.app`
     还没出现就放弃」：真机 `[BOOT]` 有 20s 的样本，那会把正常但慢的启动误判成镜像坏了，
     然后 `stv.mirror.off` 一写，功能就永久静默失效了。`STV_SERVER` 是「文件到底跑没跑」的
     直接证据，不是时间猜测。
   - **频率**：revalidate 有 6 小时 TTL（`stv.mirror.checked`），不是每次导航一次；
     设置页新增「本地资源镜像」（开关，写/清 `stv.mirror.off`）与「丢弃已刷新的资源副本」，
     后者与既有的「强制刷新站点资源」互相挂钩（那一行现在也会 `forget()`，否则只修了 WebKit
     缓存的那一半）。
5. **`[ASSET]` 资源时间线**（同一块，`load` 后 500ms 打印，**与镜像是否开启无关**）：
   `performance.getEntriesByType('resource')` 里按扩展名筛出静态资源（把 XHR API 排除），
   报一条汇总（还有几条在网络、wire/解码字节、几条 `transferSize===0` 即命中缓存、
   最后一个字节在 +Nms）+ 最慢 5 条（名字、wire 大小、耗时、`cache`/`network`、`@+startTime`）。
   **这是唯一能看见那 13 个解析器自建文件成本的地方**——镜像覆盖不到它们，只能先量。
6. **原生 `siteAssetRefresh` / `siteAssetForget`**（`SangTacAppPlugin`）：按 `If-Modified-Since`
   做条件 GET，304 跳过、200 且通过 `plausible()`（>512 字节、不以 `<` 开头、有花括号配对）
   才写盘，写失败就不写——**宁可保留好快照，也不让一次截断的下载永久毁掉镜像**。
   `origin` 必须是 https 且调用方是站点自己的主 frame：否则被 XSS 的页面可以把镜像指向任意主机、
   把随包资源换成任意 JavaScript，而这份 JavaScript 会在**每次启动**的 document start 执行，
   等于一个持久的、自己给自己装的 XSS。

#### 验证（本轮）

- `node scripts/check-ios-shim.js` → **23 块 / 399339 字节 / 56 markers**（新增
  `window.__stvAssetMirror`、`stv.mirror.off`、`data-stv-mirror`、`STV_SERVER`、
  `siteAssetRefresh`、`static request(s) still over the network`）
- `node scripts/test-site-patch.js` → **569 条断言**全过（上一轮 531，新增 38）。新增覆盖：
  - 桩里给 `HTMLScriptElement` / `HTMLLinkElement` / `Element` 建**同一棵原型链**（真 DOM 的形状），
    `Element.prototype.setAttribute` 才既是 `assetCache` 又是 `assetMirror` 的拦截点；
  - 脚本：`/asset/app.v2.js?0.4242` → 元素 `src` 是 `blob:`、打了 `data-stv-mirror`、日志有
    `[MIRROR] app.v2.js`；`/stv.tts.js?v=7` 也命中（**查询串不是身份**）；`/jqr.js?v=10` 不被接管；
  - 样式：`setAttribute('href')` 之后 head 里出现带 `data-stv-mirror="app.v2.css"` 的 `<style>`，
    `textContent` 是整份 CSS，而 `<link>` 上**没有留下 `href`**（= 不发请求）；
  - `bootShell`：把「`href` 为 null、`ownerNode` 带标记」的 sheet 推进 `document.styleSheets`，
    断言外壳以 `app.v2.css (local)` 释放（在**删掉 `app.config.reader`** 的沙箱里跑，
    否则那条信号会抢先把外壳摘掉、测不到这条路径）；
  - 自愈两条路径各 4 条断言：元素 `error` → 写标记 + reload；`STV_SERVER` 已定义时 `probe()` **不动作**
    （慢启动不误判）；`STV_SERVER` 未定义时 → 写标记 + reload；带标记的下一次加载 `hooks === undefined`、
    文件确实回到网络；
  - 时间线：喂 3 条 resource entry（2 静态 + 1 XHR），断言只数 2 条、`30KB wire / 267KB decoded`、
    `1 from cache`、最慢两条各按 `network`/`cache` 具名；
  - revalidate：断言发的条数、`If-Modified-Since` 就是那份 `Last-Modified`、origin 是页面实际读的那个、
    返回 `updated` 时日志写 `(next launch)`，以及**同一会话内不会重复发**（TTL）；
  - **三份清单必须一致**：从 `SiteAssets.swift`、`assetMirror` 块里的 `PATHS`、`gen-site-assets.js`
    的 `ASSETS` 各解析一遍，断言三个列表是同一份（只在一个地方知道的路径会**静默失效**：
    镜像永远不匹配，文件继续走网络，没有任何报错）。
- `node scripts/gen-site-i18n.js --check` → 458 labels / 35 fragments
- `node scripts/gen-site-assets.js --check` → 8 files / 906296 bytes / host `https://sangtacviet.com`
  （哈希与字节数按 CRLF 归一化后计算，`.gitattributes` 另把 `site-assets/**` 钉成 `-text`，
  免得 `core.autocrlf` 不同的机器让这条断言报假警）
- `.github/workflows/build-ipa.yml` 新增两步：`gen-site-assets.js --check`；
  **产物里必须有资源包**（`*SangTacAppPlugin*.bundle/site-assets/` 下逐个文件存在）。
  资源包缺失时镜像会静默失效（App 仍能启动，只是又变慢），所以这件事必须在构建期红，
  不能等读者发现。二进制 strings 检查加上 `stvAssetMirror`、`siteAssetRefresh`、`data-stv-mirror`。
- `README.md`：块表加 `assetMirror` 一行（22 → 23 块）、本地验证四条命令、`ASSET`/`MIRROR` 两个 tag，
  并在许可一节写明：**`site-assets/` 里是站点自己的前端 bundle（906296 字节），版权归 sangtacviet**，
  不适用本仓库许可，只随个人自用构建进包，删掉该目录并去掉 `Package.swift` 的 `resources` 一行
  即可完全退回全网络加载。

#### 未证实项（下一轮的输入）

- **`blob:` 当 `<script src>` 在本机 WKWebView 上没在真机验证过**（同类做法在站点自己那里有：
  `app.images.downloadAndAssign` 用 `URL.createObjectURL(blob)` 给 `<img>`）。这是本轮唯一
  「可能装上就没用」的点，所以才有那两条自愈。真机应看到 `[MIRROR] <文件> (<n>KB) from the local copy`
  与 `[MIRROR] 8 file(s), 907KB bundled, hooks=2`（这里的 KB 是页面内字符数，
  与 manifest 的 906296 字节记账口径不同：manifest 把 CRLF 归一化后算哈希，
  否则 `core.autocrlf` 不同的机器会让 `--check` 报假警）；若看到 `[ERR] ... reloading without the local copy`，
  就是这台 webview 不接受，功能会自己关掉、App 照旧可用，把那一行给我。
- **本轮不解决 20s 启动**。它把可达的 8 个文件（启动关键路径 78KB wire、阅读器 226KB wire）
  从网络拿掉，但**那 13 个解析器自建文件仍在网络**，而日志里的 14 条 API 是 498–2782ms/条。
  所以下一轮的输入是 `[ASSET] N static request(s) still over the network: …KB wire / …KB decoded,
  N from cache, last byte at +Nms` 这一行：如果静态资源本来就是 cache 命中、字节很少，
  那 8 秒闸门就不在资源上，要往 API 与域名探测方向走；如果 `wire` 还是几百 KB，才值得做
  「原生取外壳 + `loadHTMLString(html, baseURL:)`」那条路（1–2 天，风险面是接管导航代理）。
- 镜像的新鲜度：快照与构建同龄，之后每次启动后台校验一次、**下一次启动生效**，所以陈旧窗口
  ≤ 一次启动，与站点自己给的 `max-age=86400` 同阶。若站点在两次启动之间改名/改内容而读者只启动一次，
  那次仍是旧文件——「丢弃已刷新的资源副本」+「强制刷新站点资源」是手动出口。
- 包体：`site-assets/` 906296 字节 源文件（zip 后约 150KB，IPA 现 952372 字节）。


### 6.23 第二十一轮（`日志.txt` 560 行，21:39:18–21:41:02）：镜像生效确认 + 首请求主机 + 章节列表缓存

这一轮的输入是用户在 §6.22 之后交回的真机日志。它同时回答了两个问题：镜像在设备上到底
成不成，以及「要不要做壳接管」。

#### ① 先纠正一个被误读了三轮的读数：`[BOOT] +20000ms` 不是「启动 20 秒」

`bootShell` 的采样点是 0/1/3/6/10/20 秒六个，**无条件全打**（`releaseNow()` 在已释放后
只返回 false，`note()` 照打），所以 `+20000ms` 那一行只是最后一个采样点，不是首屏耗时。
本份日志里：

| 证据 | 值 |
|---|---|
| `[BOOT] shell released` | **+1225ms**（原因 `app.v2.css (local) at +1225ms (stylesheet inserted)`） |
| `[BOOT] +3001ms` | **`app=yes config=yes navbar=85px`** —— 站点自己的 JS 已经跑完 |
| `[BOOT] +6019 / +10002 / +20000ms` | 同样 `app=yes config=yes`，只是继续在打点 |

也就是说本次启动 1.2 秒撤掉假外壳、3 秒站点就绪。之前几轮把采样行当成耗时，方向偏了。

#### ② 镜像在真机确认成立

| 证据 | 值 |
|---|---|
| 装载 | `[MIRROR] 8 file(s), 848KB bundled, hooks=2 (blob scripts, style CSS)` |
| 逐个取用 | 8 个文件全部 `from the local copy`（含 `app.v2.js (253KB)`、`hanviet.js (172KB)`） |
| 首屏释放 | `shell released at +1225ms (app.v2.css (local) …)` —— 走的就是 §6.22 加的 `data-stv-mirror` 分支 |
| 新鲜度 | `[MIRROR] 8 checked, all current (next launch)` + `revalidated 8 file(s): all current` |
| 自愈 | **一次都没触发**，日志里没有 `[ERR] … reloading without the local copy` |
| blob 的 origin | `[LOG] printStackTrace@blob:https://sangtacviet.com/76e71285-…` —— blob 继承的是真 origin，站点的同源判断没被打断 |

TTS 起点（§6.21）同样在真机确认：`pageflip page 1 of 15 / 2 of 15 / 3 of 15` 三条都是
`from the visible line`，起点分别是 `宝、` / `睡，` / `墨拿出布条，`，即屏幕上那一行的第一个字。

#### ③ 结论：壳接管**不做**

`[ASSET]` 那一行是决定性的：

```
[ASSET] 21 static request(s) still over the network: 1KB wire / 0KB decoded,
        17 from cache, last byte at +6318ms; 7 served locally (app.v2.css,app.v2.js,…)
```

剩下 21 个静态请求总共只花了 **1KB 上网**，17 个直接命中 WKWebView 的磁盘缓存，最后 1 字节
落在 +6318ms —— 而首屏在 +1225ms 就释放了，静态资源根本不在关键路径上。为了给「接管文档加载」
定价，本轮实测了那 16 个解析器自建的引用在**冷缓存**下的全量：

| 文件 | 字节 |
|---|---|
| `html2canvas.min.js` | 198689 |
| `materialize.min.js` | 181109 |
| `bootstrap.min.css?origin=` | 155758 |
| `stv.ui.js?v=1.360` | 153833 |
| `materialize.min.css` | 141841 |
| `jqr.js?v=10` | 88207 |
| `asset/all.min.css` | 83405 |
| `gsap.min.js` | 74069 |
| `bootstrap.min.js` | 58078 |
| `crypto-js.min.js` | 48316 |
| `main.css?v=44` | 37026 |
| `iro.js` | 28249 |
| `stv.host.js` | 9612 |
| `font/font.css?v=4` | 1226 |
| `asset/theme.default.css?v=0` | 1541 |
| `asset/materialize.icon.css` | 619 |
| **合计** | **1261578（1232KB）** |

全部带 `max-age=86400` + `Last-Modified`、**无 ETag**，所以这 1232KB 一天最多付一次；
`loadHTMLString` 那条路要 1–2 天、接管导航代理、包里再 +1.2MB，换的却是这个数。
**不做**，理由是量出来的，不是估出来的。

#### ④ 于是把力气放到日志里真正花钱的地方

同一份日志按耗时排序（`[Http]` 行，含原生侧 `in <ms>ms`）：

| 请求 | 耗时 | 备注 |
|---|---|---|
| `POST sangtacviet.com/mobile/booklist.php?method=history` | **4034ms** | 启动后第一个数据请求，历史是默认 tab |
| `GET /index.php?ngmar=chapterlist…&sajax=getchapterlist` | 1484 + 1162 + 828 = **3474ms** | **同一 URL、同一内容取了 3 次**，每次 114771 字节 |
| `POST /io/novel/updateOldLink` ×3 | 836 + 561 + 873 = 2270ms | 响应只有 19 字节 |
| `GET /io/grantcontext/context` | 2011ms | 844297 字节 |
| `GET dns1.stv-appdomain-00000001.org/warp.php` | 2105ms | 回的是 `no`（死镜像） |
| `POST userinfo.php` ×2 | 484 + 711ms | 背靠背同一个请求打了两次 |

而 `.com` 上那三个请求（`warp.php` 1043ms、`lang/zh.json` 1635ms、`history` 4034ms）之后的
15 个请求全部落在 `.app`（473–765ms 那一档）。注意：**`.app` 也不是全都快**（`getinv` 31 字节
花了 1195ms、`searchBooks` 1221ms、`grantcontext` 2011ms），所以「换主机能省 3 秒」这件事
本轮**没有证明**，可证明的是「第一个请求用错了主机，而修正它的代价很小」。

#### ⑤ 改动 A：记住的镜像在 document start 就生效（`domainFailover`）

**机制**（全部有行号）：

1. `fullUrl(url)`（`app.v2.js:110-129`）对每个 `app.net` 请求决定主机：先取
   `window.location.origin`，若 `networkManagerXHR.isDomainAlive(origin)` 为假才问
   `bestDomain()`，最后 `baseDomain + url`。
2. `bestDomain()` 在 `this.domains.length == 0` 时直接返回 `defaultDomains[0]`
   （`networkManager` 是 `https://sangtacviet.com`，`app.v2.js:932/934-936`；
   `networkManagerXHR` 是 `https://dns1…`，`:1035/1037-1039`）。
3. `checkDomains()` 在 `:990` / `:1124` 被调用，`networkManagerXHR` 那一个还会先
   `this.domains = []`（`:1063`），于是**探测期间 `bestDomain()` 只能给 `defaultDomains[0]`**。
4. manager 在本文件里被建立后**同一轮**就可能被用掉（`:990-991`、`:1124-1125`），
   而原来的实现是 50ms 轮询 —— 这场竞争是结构性输掉的。
5. 而且 `app.v2.js` 并不是 `_page_vip.html` 里的头脚本，它由外壳在第 **5207** 行
   `ui.scriptmanager.load("/asset/app.v2.js?" + Math.random(), …)` **动态注入**；`app` 本身
   由外壳自己一个内联 `<script>`（抓下来的 `app.v2.php` 第 3054 行起）用 **`var app = {`**
   （第 3073 行，顶层、前后括号平衡）建立 —— 两处都是**普通赋值**。

**实现**：在 `window.app`、`app.net`、`net.networkManager`、`net.networkManagerXHR` 四处各装
一个访问器（`watchProperty`），对象一出现就在**同一轮**交给原来那套幂等包装
（`patchBestDomain` 的 `__stvFailoverInstalled` 守卫不变），50ms 轮询降级为 250ms×40 次的兜底
（`patchContent` 没有可挂的属性，仍靠它）。`Object.defineProperty` 包在 try/catch 里，
装不上就退回旧行为，不会让整块失效。同时把 `readGood()` 从「第一次 `bestDomain()` 时惰性读」
改成「document start 就读」，请求路径上不再有 `JSON.parse`。

**安全属性保持不变**：记住的镜像仍然必须出现在站点自己的 `domains`/`defaultDomains` 里，
所以伪造 localStorage 仍然指不到别的 origin（`test-site-patch` 里那条用例照旧通过）。

**自愈（这条改动是拿站点换来的，所以必须留退路）**：给全局 `app` 装访问器是唯一能让
「站点建立对象」和「我们包装它」之间不留时间窗的做法，但它有一个**只能推断、无法本地验证**的
前提 —— 引擎允许在已存在（且 `configurable`）的属性上执行 `var app = {`。按规范这是安全的
（`CanDeclareGlobalVar` 只看 `HasOwnProperty`，为真就不声明，随后赋值走 `[[Set]]` 命中访问器），
但若某个引擎不这么做，外壳那段内联脚本会**停在这一行**，后面的 `app.v2.js` 都不会被请求，
站点直接起不来，而且日志里没有任何线索。所以加了一条看门狗：文档 `readyState === 'complete'`
且 `app` 仍不存在时，写 `stv.domain.trap.off` 并 `location.reload()` 一次；下一次启动读到该标记
就完全不装访问器，退回 250ms 轮询（即本轮之前的行为）。写标记失败时不 reload（否则会无限循环）。
「页面只是慢」不会误触：`readyState` 到 `complete` 时外壳那段内联脚本早就执行完了。

**顺带核对过的风险点**：外壳/stv.ui.js/app.v2.js 里没有 `hasOwnProperty("app")`、
`"app" in window`、`delete window.app`、`Object.keys(window)`、`typeof app` 这些会被访问器
影响的写法；唯一的 `Object.defineProperty(window.localStorage, 'length', …)` 是站点自己的。
外壳第 77 行的 `if (app && app.debug && app.debug.report)` 在外壳建立 `app` 之前就引用了它 ——
装了访问器之后 `app` 是「已定义但 undefined」，那里从可能抛 ReferenceError 变成安静跳过，
方向是安全的。

#### ⑥ 改动 B：原生会话缓存加 TTL，并把 `sajax=getchapterlist` 收进去

原来的 `ResponseCache`（进程内 LRU，300 条 / 64MB）只认 `url.contains("sajax=readchapter")`，
键是 `方法|URL|Cookie 变体`，**没有过期概念**（正文是不可变文本，可以这么干）。本轮：

- `Entry` 加 `expiresAt: Date?`（`nil` = 整个会话有效），`get()` 命中过期项时**当场删掉并退还
  字节预算**。
- 判定集中成一个 `cachePolicy(method:url:)`，查表（lookup）与写入（store）用的是同一个策略
  对象，不可能互相不一致。
- 新增 `isChapterListRequest`：**必须 `GET`**（键里没有请求体，POST 永远不进缓存），且
  URL 含 `sajax=getchapterlist`。
- 新增 `isCacheableChapterList`：必须 `code == 1` **且** `data` 是含站点自己 `-/-` 分隔符的
  字符串 —— 错误页、Cloudflare 拦截页、站点自己的 `{"code":400}` 都进不来。失败方向是安全的
  那一侧（不认识就重新取），因为一次错误的缓存会钉住整个 TTL。
- TTL 取 **300 秒**：比日志里同一份列表首末两次相隔的 60 秒长，又短到「读者在读期间作者
  更新了章节」不会一直被挡。
- 存入时多写一行原生调用日志（`… cached-for 300s (114771b)`），面板不加新行（每个缓存响应
  都刷一行会把面板淹掉）；命中仍然沿用现成的 `[Http] … (cache)`。

**故意没做**：`userinfo.php`（背靠背两次）与 `booklist.php?method=*`（未读数/关注状态）不进缓存
—— 它们的过期是「显示错」而不是「省一次往返」。

#### ⑦ 守卫与产物

| 守卫 | 结果 |
|---|---|
| `scripts/check-ios-shim.js` | 23 块 / **405254 字节** / **59 个标记**（新增 `function watchProperty(`、`function watchNet(`、`stv.domain.trap.off`） |
| `scripts/test-site-patch.js` | **577 条断言**（上一轮 569，新增 8 条：manager 在建后同一轮被包上、同一轮就用记住的镜像、`app` 在块之后建立也被接住、探测未回来的 manager 仍给记住的镜像、退路标记下同一轮不包、退路标记下兜底轮询仍包、`app` 始终不出现时写标记、写标记后 reload 一次） |
| `scripts/gen-site-i18n.js --check` | 458 标签 / 35 片段 |
| `scripts/gen-site-assets.js --check` | 8 文件 / 906296 字节 / host `https://sangtacviet.com` |

CI 的二进制 strings 标记新增 `stv.domain.trap.off`（在注入块里，必然进产物）。

**改动 B 不能用二进制 strings 检查 —— 这是第一次 CI 红出来的教训，记在这里**：最初把
`sajax=getchapterlist` 与 `cached-for ` 加进了 `strings` 检查，结果 `cached-for ` 找不到。
两个原因都值得记：(1) 那个字面量只作为参数传给 `callLog` → `CAPLog.print`，release 产物里
这条路径没有可观察效果，字符串被优化掉了；(2) `sajax=getchapterlist` 其实**也不是** http 插件
贡献的 —— `SiteI18nData.swift` 的注入块里就有同样的文本，所以这条断言是「别的地方碰巧也有这个
字符串」而通过的，属于会假装通过的检查。现在 B 改成**查源码**（`cachePolicy(method:`、
`sajax=getchapterlist`、`chapterListTTL`、`isCacheableChapterList` 四个串必须在
`plugins/http/.../SangTacHttpPlugin.swift` 里），它证明的是「规则还在源码里」，能不能链进产物
由编译步骤（16）与插件注册校验（14）负责 —— 与其留一条会误报通过的带标记检查，不如把它的
证明力说清楚。

新加的断言里，前四条**全部发生在不 `await` 的同步段**：装完块并 `tick(300)` 之后才做赋值，
赋值与检查之间没有任何 yield，所以只有访问器可能完成接线 —— 这正是本轮修的那个竞争；
后四条分别验证退路（标记生效后同一轮不接线、兜底轮询仍接线）与看门狗（始终不出现 `app`
→ 写标记 + reload 一次）。

#### 未证实项（下一轮的输入）

- **访问器在 Safari 里与 `var app` 的相互作用没有真机验证过**。规范的读法是：
  `GlobalDeclarationInstantiation` 对已存在的属性只做 `HasOwnProperty` 检查（为真就跳过），
  随后的赋值走 `[[Set]]`，命中访问器；属性是 `configurable: true`，所以即便站点改用
  `let app` 也不会抛。**但这依赖 Safari 的实现**。真机上的判据有三条：
  `[DOMAIN] networkManager mirror failover installed` 应出现得比原来更早（理想情况下在
  第一条 `[Http]` 之前）、`[BOOT]` 三个采样点应照常 `app=yes`、以及**不应**出现
  `[DOMAIN] app never appeared: dropping the document-start trap and reloading`。
  若看到最后那条（面板开着才会有，且开关持久化），说明看门狗生效、下一次启动已经退回轮询，
  功能只是没优化而不是坏了，把那一行给我即可。
- **「第一个请求改用记住的镜像」能省多少，这份日志证明不了**（`.com` 与 `.app` 都有 1–4 秒的
  调用）。要看的下一份日志是：`history` 与 `lang/zh.json` 这两条是否落在 `.app`、耗时是否降到
  500ms 一档；以及 `[DOMAIN] networkManagerXHR using remembered mirror` 是否出现在
  **第一条 `[Http]` 之前**。
- **章节列表缓存的收益要看命中**：期望在第二次/第三次 `getchapterlist` 上看到
  `[Http] GET … (cache)`，且 `[ASSET]`-式的重复消失；`cached-for 300s (114771b)` 只写在原生调用
  日志里，面板看不到。若 5 分钟内作者更新了章节而读者正好退回列表，那一次会看到旧列表 ——
  这是选定的取舍，不是缺陷。
- **`userinfo.php` 背靠背两次**、**`updateOldLink` 三次共 2270ms**、**`dns1` 探测 2105ms 回 `no`
  而 `.com`/`.app` 都已回 `yes`** 都还没动：前两个是下一轮的低风险目标，第三个要改站点自己的
  `verifyDomain()` 排名，风险更高。
- 日志里还有个**独立**的观察待确认：`jsonify.php?ajax=followbook` 回 `{"status":"success","code":400}`
  （本站 `code 100` 才算成功），我当时写的「随后的状态查询是 `"follow":false`，所以这条动作没生效」
  是**错的** —— 那条 `querybookmarkstatus` 是当时打开的**另一本书**的（见 §6.24 (1)）；
  同一份日志里 `[SAFE] safe area top=0` 出现过两次、`viewport` 从 874 变成过 768，我据此猜的
  「顶栏会有一次视觉跳动」也**不成立**（见 §6.24 (2)：两处都不写坏变量，且 `--vh100` 的两个
  使用点都已被钳住）。两条都已在下一轮查清。


### 6.24 第二十二轮（用户要求「查」这两条）：关注为什么没反应 + 安全区 top=0

用户点名要查 §6.23 末尾挂着的两条观察。结论：**「关注」是真缺陷（已修）；安全区那两条不是
缺陷，而且我上一轮的描述是错的，撤回。**

#### (1) 「关注」：站点自己的客户端把结果吞掉了（与 `code 400` 是什么无关）

**调用链只有一条**：`app.api.follow(bookdata)` → `GET /mobile/jsonify.php?ajax=followbook&
name=<名>&author=<作者>`（`app.v2.js:4848-4864`）。两个入口都走它：详情页的 `.followbook`
按钮（外壳 `:4215-4219`，`app.api.follow(d)`）与长按菜单（`app.v2.js:2386-2390`、`:2700-2701`、
`:2711`）。全站没有第二个「加关注」接口。

**死回调**：`app.api.follow` 把结果处理函数当作**第二个实参**交给 `app.net.get`
（`app.v2.js:4856`），而 `app.net.get = async function(url, force, retry)`（`app.v2.js:696`，
全文件只定义这一次）的第二位是 **`force`**，不是回调。所以那段 `if(down.code == 100){ …toast…
}` **永远不会执行**。后果：从长按菜单关注任何书，成功不提示、关注列表不刷新；被服务端拒绝
也一样安静——**「点了没反应」不需要 `code 400` 就能解释**。同一处缺陷也在
`app.api.bookmark`（`app.v2.js:4839`），而且它成功时弹的是 `app.text.followed`（「关注成功」）
——收藏弹关注的文案，同样因为回调是死的而从未暴露。

**日志里那条 `code 400` 现在有解释了**：`日志.txt` 里

- `:28` `GET /mobile/booklist.php?method=following&p=0 -> 200 1564b`，返回的列表**只有一本书**
  ——`fanqie/7594444988159642686` 大唐：开局青帝，吓退突厥二十万 / 百花齐舞；
- `:36` `[NAV] tab 1 关注`（用户当时就在关注页）；`:39` `[TAP] tap div.contextmenuitem`
  长按菜单；`:40` `ajax=followbook&name=大唐…&author=百花齐舞 -> {"status":"success","code":400}`。

也就是说：**这本书 11 秒前就已经在关注列表里**，而关注列表长按菜单的第一项（文案是
`app.text.w.delete`，即「删除」）被站点自己接到了 **`follow`** 上（`app.v2.js:2685-2686`）
——**站点没有任何「取消关注」接口**（全站 grep 只有 `followbook` 一个写接口）。所以：
用户想做的是取消关注，发出去的却是「再关注一次」，服务端回 `code 400`（「重复/已经在列表里」
是对这条日志最合理的解释，但**服务端语义仍是推断**，不是证明）。「什么都没变」其实是**正确的
服务端行为**；缺陷在于没有任何一处告诉用户这件事。

**改动**（在 `bookmarkToggle` 块里——它已经拥有「站点自己的写动作必须说实话」这件事）：

1. `attachFollow()`：把 `app.api.follow` 包一层，**请求本身原样交给站点**，只加
   「调用前读一次 → 调用 → 调用后读一次」（`app.api.queryBookExtStatus`，也就是
   `ajax=querybookmarkstatus`，它的回答里带 `follow`），再把两端写进 `[FOLLOW]` 面板行：
   `followbook <host>/<id> -> code <code> raw=…` 与 `<host>/<id> before=<bool> after=<bool> raw=…`。
2. 提示按**复查过的**结果说：`after=true && before=true` → 「已经在关注列表里（站点没有取消
   关注的接口）」；`after=true && before=false` → 「已关注」并重排关注列表（这正是站点那段死
   回调本来要做的事）；`after=false && code=100` → 「站点说成功，但复查仍显示未关注」；
   `after=false && code≠100` → 「关注没生效（code X）」；**读不到状态（未登录/请求失败）时
   什么都不声称**，只把原文写进面板（与 like 块同一条规矩：`null` 不许变成猜测）。
3. 未登录（`app.user.isLogin === false`）直接原样交给站点——它自己会弹登录页，多一次状态查询
   是噪音。判断写成「**明确等于 false** 才跳过」，所以页面还没建好 `app.user` 时仍然会上报。
4. 顺带把 `app.api.bookmark` 的**加入**路径也接上：成功时重排书签列表并提示
   「已加入书签」（站点原意如此，只是文案写错且回调是死的）。
5. **`install()` 不再短路**：原来是 `attachBookmark() && attachLike()`，`attachLike()` 一返回
   false 就永远轮不到后面（`app.api.bookmark` 在 `app.v2.js` 跑完就有，而 `likeBook`/`unlike`、
   `follow` 是各自独立赋值），新增的 `attachFollow()` 会因此永远装不上——写测试时先撞上了这个
   坑（三个 wrap 都带 `__stv*Wrapped` 守卫，重复尝试是免费的），改成 `a = …; b = …; c = …;
   return a && b && c;`。

#### (2) 安全区 `top=0` / `viewport=768`：不是缺陷，先撤回我上一轮的说法

我上一轮说「`[SAFE] top=0` 出现过两次…顶栏会有一次视觉跳动」——**这句是错的**，`日志.txt`
里两个来源都不写坏任何东西：

| 采样 | 来源 | 值 | 后果 |
|---|---|---|---|
| `[SAFE] safe area top=0`（`:24`、`:41:02`） | 原生 `App.getSafeArea` 的 `safeAreaInsets` | `{top:0,bottom:34}` | 无：`apply()` 只在站点自己的值 **≤0** 时才写 CSS 变量（`SitePatch.swift:1999-2006`），报告行里 `status-bar-height` 一直是 62px |
| `[RECT] env={"top":0,…}`（`:28`，+10s 采样） | **站点自己**的 `window.getSafeHeight()`（`app.v2.js:4433-4452`：往 body 塞一个 `height:env(safe-area-inset-top)` 的探针量出来） | `{top:0,bottom:34}` | 无：同一行的 `status-bar=62/62`，站点那次量到 0 并没有写回变量（站点自己的 `statusBarHeight` 只在 `isCheckingStatusBarHeight` 那一次里更新，日志 `:19` 已记 `detect status bar height: 62`） |

而 `viewport=768`（`window.innerHeight`，站点据此写 `--vh100: 768px`）是**已知**的站点行为，
`--vh100` 来自 `visualViewport.height`、任何一次 resize 都会写进一个偏小的值；它的可见后果
（导航栏从推入页面底下露出来）**上一轮就已经修掉了**：我们的样式表把 `#overlay` 钳到
`max(var(--vh100,100vh),100vh)`（`SitePatch.swift:1959`），站点自己在 `onresize` 里又把
`#mainview` 内联成 `100vh`（`app.v2.js:4507`），所以这两个面都不跟着过期的 768 走。`:28`
那次采样里 navbar 在 `683..768`——对 768 的视口是自洽的，不是错位。

**顺带记一个站点侧的隐患**（本轮不改）：站点的键盘保护是
`if(vh100 < winHeight - 150){ vh100 = Math.max(maxWinHeight, winHeight); }`（`app.v2.js:4489-4491`），
阈值 150px 是「键盘至少这么高」的假设；874−768 = **106 < 150**，所以这种幅度的视口收缩
会被站点当成真实高度接受并写进 `--vh100`。当前两处使用它的地方都被钳住了，所以没有可见后果。

#### (3) 守卫与产物

| 守卫 | 结果 |
|---|---|
| `scripts/check-ios-shim.js` | 23 块 / **413210 字节** / **61 个标记**（新增 `function attachFollow(`、`站点没有取消关注的接口`） |
| `scripts/test-site-patch.js` | **587 条断言**（上一轮 577，新增 10 条：已关注时说「已经在关注列表里」、面板里有 `followbook … code 400`、调用前后各读一次状态、不声称成功、「已关注」+ 重排关注列表、被拒时报 code、读不到状态时什么都不说、未登录不查状态、书签加入提示文案正确） |

新增的 `testFollowOutcome` 用四组脚本化的「调用前/调用后」状态把上面每一条提示都钉住，
并显式断言「面板里没有成功提示」这种**否定**条件——「什么都不说」正是这条缺陷原来的样子。

#### 未证实项

- **`code 400` = 「已经关注过」是推断**，依据是那本书 11 秒前就在关注列表里；下一次真机日志
  里 `[FOLLOW] <host>/<id> before=… after=…` 会直接给出状态，不再需要推断。
- **站点没有取消关注接口**：全站（外壳、`stv.ui.js`、`app.v2.js`、`app.v2.read.js`）只有
  `followbook` 一个写接口，匿名探测也只能看到 `followbook`；「取消关注」与「取消收藏」
  「取消点赞」同类——**站点的功能缺口，客户端补不了**，只能如实说。
- `reportRects` 只把 `window.innerHeight` 打进面板；把 `visualViewport.height` 与
  `documentElement.clientHeight` 一起打出来，下一次就能直接看出 768 是什么
  （目前**没有必要**：两处使用 `--vh100` 的地方都已被钳住，没有可见后果）。

### 6.25 第二十三轮（用户报「加载目录、加载正文时间非常长」）：记住的镜像只会被 `code 7` 拔掉

`日志.txt` 389 行，23:12:12–23:15:52。用户的现象是「目录和正文加载非常长」，日志里
**目录一次都没出来**。

#### (1) 真机上到底慢在哪

| 请求 | 次数与耗时 | 字节 |
|---|---|---|
| `index.php?ngmar=chapterlist&…&sajax=getchapterlist` | **4 次全部 `FAILED in 10005/10002/10002/10001ms`** | 0 |
| `mobile/bookmanage.php?act=getallhost` | 4 次 `FAILED in 10002/10005/10002/10002ms`，第 5 次 3862ms 成功 | 179 |
| `mobile/booklist.php?method=bookmarked&p=1` | **57991ms** | 22 |
| `/io/grantcontext/context?hostid=qidian&bookid=1034915599` | **63050ms / 37063ms**（同一 URL 两次） | 802554 / 780900 |
| 同 URL，`hostid=trxs` | 27088ms | 722417 |
| `?sajax=readchapter&h=qidian&…&c=866969379` | **35382ms** | 7430 |
| `?sajax=readchapter&h=trxs&…`（5 次） | 2106 / 2066 / 2526 / 4293 / 4295ms | 约 10KB |

10 秒不是我们的超时：**站点自己传的** `timeout: 10000`（`app.v2.js:1155`），插件照做
（`SangTacHttpPlugin.swift:714`，而 `timeoutIntervalForRequest` 收到数据就重置，所以
22 字节花 58 秒和 10 秒硬超时是同一件事的两面）。本轮之前加的 300 秒 `getchapterlist`
缓存**一次都没命中**——它只缓存成功响应，而这些请求一次都没成功。

同一分钟里的三路探测（`networkManager.verifyDomain`，原生，`[Http]` 行）：
`.com/warp.php` **750ms**（`yes`）、`.app/warp.php` **3449ms**（`yes`）、
`dns1…org/warp.php` 4322ms（`no`）。**全部数据请求都在 `.app` 上。**

`.app` 是哪儿来的：`app.v2.read.js:564` 写死了
`fullUrl(app.net.networkManager.bestDomain() + '/?sajax=readchapter…')`，而
`fullUrl()` 对已经是 `http` 开头的 URL 原样返回（`app.v2.js:111-112`）——日志里那行
`[LOG] https://sangtacviet.app/?sajax=readchapter…` 就是它 `console.log(url)` 出来的。
`bestDomain()` 是本块包装过的，而日志 `:18` 明确写着
`[DOMAIN] networkManagerXHR using remembered mirror https://sangtacviet.app`。**正文的主机
确凿来自「记住的镜像」。** 目录走的是相对 URL（`app.v2.js:263-265` `app.net.get(url)`），
主机由 `fullUrl()` 的三个来源之一决定，其中两个是 manager、第三个是 `window.STV_SERVER`
（`app.v2.js:1` **硬编码** `"https://sangtacviet.app"`，只在站点认为页面是「本地」时使用）
——这一条**这份日志分不出来**，所以本轮加了 `route` 诊断行（见 (4)）。

#### (2) 结构缺陷：记忆镜像没有「慢」这个失败模式

`patchBestDomain` 原来是「`good` 在候选里就返回它」，而 `candidates()` 无条件把
`defaultDomains` 并进来，所以记忆镜像**永远**是候选；唯一的清除路径是 `patchContent` 里
的 `code 7`。**慢、超时、无载荷都不算失败**，于是 `.app` 一旦卡住就被钉到 6 小时 TTL
到期为止。同一份日志还有两处佐证：

- 站点自己刚测出 `.com` 比 `.app` 快 4.6 倍，而 `bestDomain()` 的原实现是「`app_domain` 指定的
  镜像活着就返回它，否则返回 ping 最低的活镜像」（`app.v2.js:933-956`）——所以在**未打补丁**
  且 `app.config.ux.app_domain` 不是 `.app` 的前提下它会选 `.com`。这一句是推论，不是本份日志
  能证的事：日志里没有 `app_domain` 的取值（只能看到 23:14:14 那次点选给了
  `https://sangtacviet.com`），所以「原实现会选 `.com`」**留待新的 `route` 行确认**。
  能确定的是**这个分支只有一条出口**：只要记忆分支被走到，`bestDomain()` 回的就是 `.app`，
  与 `original` 说了什么无关——`app.v2.read.js:564` 的主机正是它的返回值。
- 23:14:14 / 23:14:16 两次点「线路」菜单（`[LOG] app.config.ux.app_domain`），此后每个
  请求仍在 `.app`——站点自己在 `app.v2.js:937-943`／`:1040-1046` 是**认**这个偏好的
  （镜像 `alive` 时直接返回它），也被吃掉了。

#### (3) 我本机测出来什么，以及要撤回的那句话

**第一版探测（单次）**：`.com` 983ms 对 `.app` 6294ms，看起来像 6 倍差距。
**连测 4 轮后不成立**：中位数 `.com` 3327 / `.app` 2389 / `dns1` 1367 ms，逐次区间
478–9252ms，三个镜像**在本机噪声内等价**。所以「`.app` 全局更慢」**不成立**，本机测不出
设备上那一段劣化（设备的 750 vs 3449 只有一组、各一次，且 `.com` 是页面同源、连接是热的）。
能站住的只有第 (2) 条：**不管哪台快，这个钉子都逃不掉坏的那台。**

#### (4) 改了什么（都在 `domainFailover` 块里）

1. **没有载荷就是失败。** `app.net.get`/`app.net.post`（目录走这条）与 `getContent`
   （正文走 `app.v2.read.js:556-599`，它自己吞掉两次失败后 `return null`——这正是原来注释里
   那句「transport failure arrives here as a missing payload」的来源）出口新增
   `failed()`：拉黑该镜像（`banned`）并从记忆里删掉（`forgetGood`）。站点自己的重试
   （`app.net.get` 重试 3 次、`getContent2` 重试 1 次）因此落到下一台。
   - **失败的那个请求不重放**：有副作用的 POST 绝不能跑第二遍，重试是站点自己的事。
   - **只有指向站点自己镜像的请求才有资格拉黑**（`stvRequest()`：相对 URL 算，绝对 URL 问
     `isStvDomain()`），否则翻译/封面这类外站请求失败会误伤镜像。
   - 拉黑不再和 `code 7` 共用重试预算：新增 `code7Seen`，`banCount` 删掉。
2. **站点刚探测过、记忆镜像没应答**（`domains` 里有它且 `status !== 'alive'`）就丢掉。
   探测还没回来（`checkDomains()` 会先清空再逐条 push，`app.v2.js:1060-1091`）算「暂无消息」，
   不是「死」——这条区分很重要，否则每次启动的头几秒会把记忆镜像误判掉。
3. **手选线路优先**：`app.config.ux.app_domain`（非 `auto`、在候选里、未被拉黑、且没被探测
   判死）直接返回，并把不同的记忆值清掉。**故意不要求 `original.bestDomain()` 也同意**——
   它要等自己那次 `/warp.php` 探测回来才认这个偏好，而那段窗口恰好是记忆镜像会赢的窗口。
4. **诊断**：每次启动一行
   `[DOMAIN] <manager> route: page=… alive=… STV_SERVER=… app_domain=…`（`fullUrl()` 三个
   主机来源一次全打出来）与 `[DOMAIN] <manager> ranked <name>=<status>/<ping>ms …`
   （每次排名变化一行）。

**刻意没做的事：按 ping 比快慢。** 赢得站点竞速的那台恰好经常是回 `code 7` 的那台
（`scripts/test-site-patch.js` 里就是这个组合：100ms 的 `dns1` 回 code 7、400ms 的 `.com`
出正文），所以「别人 ping 更快」**不构成**记忆镜像有问题的证据；照 ping 让记忆值输，
等于把 round 20 修掉的 bug 装回去。

**也刻意没做：给 `window.STV_SERVER` 装访问器。** 如果目录那台主机来自 `app.v2.js:1`
的硬编码，一个 document-start 访问器能让它跟着实际排名走（和 `window.app` 同一手法）。
但现在**没有证据**指向它——先让 `route` 行说话；在证据之前多做一层全局陷阱，正是我这次
要避免的那种改动。

#### (5) 顺手否掉的一个想法

`grantcontext` 不能缓存：同一 session、同一 URL 两次返回 **802554 与 780900 字节**，
内容会变。（它与 `getallhost` 都不在 round 21 的缓存名单里，现在确认应该继续不在。）

#### (6) 守卫与产物

| 守卫 | 结果 |
|---|---|
| `scripts/check-ios-shim.js` | 23 块 / **423826 字节** / **66 个标记**（新增 `function patchNet(`、`function wrappedNet(`、`function failed(`、`transport failover installed`、`app_domain=`） |
| `scripts/test-site-patch.js` | **598 条断言**（上一轮 587，新增 11 条） |
| `scripts/gen-site-i18n.js --check` | 458 labels / 35 fragments |
| `scripts/gen-site-assets.js --check` | 8 files / 906296 bytes |

新增断言覆盖：`app.net.get` 确实被包上（函数级标记，不是对象级——站点是
`app.net = app.net \|\| {}` 之后**下一句**才加 `get`，对象级标记会把一个什么都没包的包装
锁死）、卡住的镜像被拉黑且从记忆里删掉、面板写出 `banned: get failed:`、站点重试落到另一台、
探测判死的记忆镜像被丢、手选线路赢过记忆镜像、`route`/`ranked` 两行出现、
**外站请求失败不拉黑镜像**。

#### 未证实项

- **目录那台主机到底是谁决定的**：`route` 行给出答案之前，`window.STV_SERVER`
  （`app.v2.js:1` 硬编码 `.app`）这条来源无法排除。正文那条**已经确定**是本块的记忆镜像。
- **`.app` 是否全局劣化**：本机 4 轮测不出差异（见 (3)），设备上只有一组样本。
- **本轮的修复在设备上的实际效果**：可测的预期是——下一次日志里 `sajax=getchapterlist`
  最多失败 **1 次**（第一次超时拉黑 `.app`）而不是 4 次，且失败后紧跟着的那次会落在另一台；
  `[DOMAIN]` 里会出现 `banned: get failed: …` 与 `ranked`。
- **`.com` 与页面同源会换走 XHR 通道**：`app.net.get` 里
  `isDomainMatchOrigin(url)` 为真时走 `XMLHttpRequest`（`x-stv-transport: web`），不再经
  原生插件、也就没有 `[Http]` 行、没有 10 秒超时。这是**站点自己的设计**（未打补丁时
  `fullUrl()` 第三行就是页面 origin），不是本轮引入的；但「下一次日志里 `[Http]` 行变少」
  是它的可观察后果，需要确认内容没变。
- 日志里 2 次 `[ERR] unhandledrejection setContent@…chapterdisplay:1643:46 /
  preload@…:1816:28`（正文落地瞬间）不是本轮的慢，**留作单独一轮排查**。




