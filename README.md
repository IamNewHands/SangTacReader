# SangTacReader — sangtacviet 的非官方 iOS 客户端

与安卓版**同构**的 iOS 客户端：Capacitor 8 应用，`server.url` 远程加载
`sangtacviet.com/app.v2.php`，并补齐站点前端依赖的原生插件，使站点走
「app 模式」——这正是安卓版拿到完整阅读体验的原因。

> 官方只发布安卓 APK。本项目自行封装，仅供个人学习使用。
> 架构、证据链与每一轮真机问题的根因见 [`docs/capacitor-port.md`](docs/capacitor-port.md)。

## 为什么不是「WKWebView + 注入脚本」

早期版本是纯 WKWebView 套壳，效果很差。原因不是「iOS 没有 Capacitor」，而是：

| | 安卓版 | 旧 iOS 版 |
|---|---|---|
| 运行时 | Capacitor 应用 | 纯 WKWebView |
| 站点判定 | `window.Capacitor` 存在 → **app 模式** | 无 → **web 模式** |
| 数据请求 | 原生网络栈（`Capacitor.Plugins.Http`） | 网页 XHR，撞 Cloudflare / 设备判定 |
| 结果 | 正文 `code:0` | 正文 `code:7`，体验差 |

## 目前能做什么

书列表 / 搜索 / 最新更新 / 排行榜、小说详情、关注 / 书签 / 点赞、章节目录、正文阅读
（默认左右翻页）、原生 TTS 朗读、离线下载（断点续传、已下载章节自动跳过、可删除）与
**导出为 TXT / EPUB**（带封面与书名，走系统分享面板）、评论与社区帖子翻译（系统离线优先，
可自备 API Key，语言任选）、界面中文化、设置跨重装保留。

站点自身的问题（例如「关注」tab 服务端 500、章节标题只有越南语机翻、书签没有
取消接口）已在 `docs/capacitor-port.md` 中逐条定位并说明哪些能补、哪些补不了。

## 目录结构

```
SangTacReader/
├── capacitor.config.json        # 照抄安卓 APK 的配置（server.url 远程加载）
├── package.json                 # Capacitor 8 依赖 + 三个本地插件
├── dist/index.html              # 仅占位（server.url 模式下 webDir 不被使用）
├── plugins/
│   ├── http/                    # 原生 URLSession 版 Http（含 WKWebView cookie 桥接）
│   ├── app/                     # App 插件 + 站点补丁注入 + 原生 TTS + 安全区/设置备份 + 评论翻译
│   └── webnativeview/           # 安卓反射桥的 iOS 占位（仅漫画模块，尚未实现）
├── data/site-i18n.json          # 站点文案中译字典（唯一真源）
├── scripts/                     # 四条本地/CI 守护（见下）
├── docs/capacitor-port.md       # ★ 迁移档案：证据链、决策、逐轮真机问题
└── .github/workflows/build-ipa.yml   # macOS 上构建未签名 IPA 并发布滚动 Release
```

`ios/` **不入库**：必须由 macOS 上的 `npx cap add ios` 生成（Windows 会把反斜杠
路径写进 `CapApp-SPM/Package.swift`，macOS 的 SwiftPM 无法解析）。

旧 WKWebView 工程（`SangTacReader.xcodeproj/`、`SangTacReader/` 及其打包的 `www/`
资源）与 `tests/` 下的一次性探测脚本已在 2026-09-22 退役，需要时从 git 历史取回。

## 站点补丁（`plugins/app/.../SitePatch.swift`）

站点是远程页面，我们唯一的注入点是 `WKUserScript`（document start）。共 23 个块，
每块独立守卫、互不依赖：

| 块 | 作用 |
|---|---|
| `compat` | `nativeclick` 空实现 + `window.TTS` 门面（站点不调则整条点击链抛错） |
| `assetCache` | 站点给 `/asset/*.js|css` 发 `max-age=86400`，却在 URL 上拼 `Math.random()`，于是每次冷启动都是全新 URL、磁盘缓存永不命中。这里把随机串换成稳定 token（`stv<代>`，**不含日期**：带日期等于每天第一次启动强制重下启动关键路径上的 74KB），拦截 `script.src` / `link.href` / `img.src` 的 setter 与 `setAttribute`；`?v=1.360` 这类真版本号一律不动。设置页「强制刷新站点资源」换一代并 reload |
| `assetMirror` | **站点自己的启动包放进 IPA**：`app.v2.js`/`app.v2.css`/`bookdisplay`/`config`/`read`/`chapterdisplay`/`stv.tts.js`/`hanviet.js` 共 906296 字节 随包发布（`plugins/app/.../site-assets/`，`scripts/gen-site-assets.js` 生成、CI `--check`），document start 由原生侧用 `JSONSerialization` 拼成一张表交给页面，取用时**脚本走 `blob:` URL、样式走 `<style>` 节点**——前者保住站点 loader 的 `onload` 与按 URL 去重的 `stack`，后者保住 pageflip 把样式带进 frame 的 `css.textContent` 路径（`_dl_app.v2.js` @199996），`bootShell` 靠 `data-stv-mirror` 认这张无 `href` 的样式表。每次启动后用 `If-Modified-Since` 后台校验一次（6 小时 TTL、304 无 body），有变化就写进 Application Support，**下次启动生效**；设置页有开关与「丢弃已刷新的资源副本」。两条自愈：镜像脚本报错（blob 的 `error` / `window.onerror` 带 blob 文件名）或 `app.v2.js` 载入 8 秒后 `STV_SERVER` 仍未定义，就写 `stv.mirror.off` 并 reload 一次，下一次完全走网络。同一块还打印 `[ASSET]` 资源时间线：还剩多少静态请求在网络、wire/解码字节、几条命中缓存、最慢的 5 个（传 `transferSize===0` 判缓存），**这是唯一能看见 HTML 解析器自建的那 13 个文件成本的地方**——注入层永远碰不到它们，只能先量 |
| `diag` | 页面内诊断面板 `window.__stvDiag`（侧载包没有可读控制台）。**默认关闭**：关着时不存在任何悬浮窗、不缓冲、不接管 console；在「设置 → 诊断」打开后徽标常显、面板立即弹出，开关镜像进 Keychain，重装后仍然有效 |
| `activityLog` | 常见流程的日志：`PAGE` 每个 `pushPage`/`popPage`、`NAV` 每次标签栏点击（含序号与文案）、`MSG` 每次 `app.toast` / `app.context.info`、`BOOT` app 对象就绪时刻 |
| `tabProbe` | 临时：点 tab 时上报 tabbar 项宽、指针 transform/width、`tabdiv` transform、末页子节点数 |
| `storageAccessor` | 替换站点坏掉的 `app.storage.get`（`await prefs.get({key}).value` 恒为 `undefined`），设置/下载记录/历史才读得回来 |
| `readerDefaults` | iOS 上把阅读器 `display_type` 默认成左右翻页；修「静态章节名称」选过不显示后再也回不来的单程 bug |
| `ttsProvider` | 注册 `ttsEngine` 的 `ios` provider，走原生 `AVSpeechSynthesizer`；按文本语种挑发音人 |
| `followFallback` | 「关注」接口服务端 500 时探测站点自己的旧接口 |
| `safeArea` | 灵动岛 / Home Indicator：安全区补齐、`#overlay` 高度兜底 + 阅读器菜单几何量上报 |
| `keyboardPopup` | 键盘弹起时接管带输入框弹窗的纵向定位（顶在键盘上方、压到可视区内），收起后交还站点 CSS |
| `gridLayout` | 书架网格：格子不再被强制成第一格的高度、标题两行截断；历史网格换成与书签 tab 同款的 auto-fill 列（1 行 4 个）+ 行不再被拉伸；列表单元与长按菜单补 `-webkit-user-select` / `-webkit-touch-callout`（站点只写了无前缀的 `user-select`，长按弹选项时会顺带选中文字） |
| `settingsBackup` | 设置与下载记录镜像进 Keychain；等 `storageAccessor` 修好后才恢复，并把值回灌运行中的 `app.config` / `offlineBook.store.data` |
| `domainFailover` | 正文镜像故障转移：回过 `code 7` 的域名不再被选中，`getContent` 出口拦截并换镜像重取；**记住的镜像必须在站点发第一个请求之前就生效**——`fullUrl()`/`bestDomain()`（`app.v2.js:110-129`、`:1136-1191`）在**建立 manager 的同一轮**就决定了每个 `app.net` 请求的主机，而 `checkDomains()` 还没回来时 `bestDomain()` 只能回 `defaultDomains[0]`（`app.v2.js:934-936`），所以 50ms 轮询必然输掉这场竞争（2026-09-23 真机日志：一次启动的头三个数据请求落在规范域名上，`booklist.php?method=history` 花了 4034ms，而两秒后第一个看见记住镜像的调用就用了快的那台）。现在改成 **document start 给 `window.app` / `app.net` / 两个 manager 各装一个访问器**（外壳用内联 `var app = {` 建立、`app.net` 由 `app.v2.js:695` 建立，都是普通赋值，所以对象一出现就被接住，随后交给原来那套幂等包装），轮询只留作兜底。**自愈**：访问器是拿站点换来的——万一某个引擎拒绝「已有属性上再 `var app`」，外壳那段内联脚本会停在那一行、站点再也起不来，所以文档到 `complete` 时若 `app` 仍不存在，就写 `stv.domain.trap.off` 并 reload 一次，下一次启动退回纯轮询（等于本轮之前的行为），不会反复重载 |
| `bookmarkToggle` | 已收藏时探测取消接口，把书签按钮变成真开关；点赞按钮同理——站点有 `ajax=unlike` 却从不调用，这里**改用 `querylikestatus`（与 like/unlike 同一套 `type:id` 键）读状态、调用后再复查一次才敢提示成功**，并把 `updateBookPage` 的 `active` 判定换成复查过的值（它问的 `queryBookExtStatus` 是这本书自己的记录，取消成功后仍是 `like=true`，会把按钮重新点亮——这正是「提示取消但实际没取消」的来源），同时同步 `.liked` 计数。取消只发**一次** `unlike(host, bookId)`（站点自己的契约形式）并复查一次：日志已经把两个候选键都问完了——对象 id 被接受（`code 100`）却一行都不删，行 id 直接被服务端拒（`{"text":"Không tìm thấy lịch sử.","code":101}`，这个端点找的是阅读历史里的 id），而站点自己只在社区帖子上调 `unlike`，书籍这条路上没有契约。所以阶梯已拆掉（少 2 个请求、少 2 秒等待，结论一样），失败就如实提示 `站点不支持取消这个赞`，按钮维持站点当前的点亮状态。**同一排的第三个动作（关注）与书签的「加入」路径也有同一个病**：`app.api.follow` / `app.api.bookmark` 把自己的结果回调当成 `app.net.get` 的**第二个参数**传进去，而那一位是 `force`（`app.v2.js:696`，不是回调），所以站点写的 toast 与列表刷新是**死代码**——成功与失败都毫无反馈。这里把两个调用原样留下，只加上报与复查（`ajax=querybookmarkstatus` 的回答里带 `follow`）：调用前后各读一次状态，才决定说「已关注」「已经在关注列表里（站点没有取消关注的接口）」还是「关注没生效（code X）」；站点不肯回答时（未登录/请求失败）什么都不声称，只把原文写进面板 |
| `readerTts` | 正文朗读：句子来源取**屏幕上看得见的那一行**到本章结尾、失败原因上报、测试语句改中文、退出正文自动停止。pageflip 显示器的正文其实在两层里——站点先把整章渲染进**离屏**的 `#maincontent`，再把切好的页搬进真正显示的 frame，所以拿离屏渲染器或 `body` 会读到「不属于这一页的残留」（真机日志：两次都是同一段 111 字符）；改读 `currentChapter.pageElements[currentPageId..]` 之后又暴露第二层：**页面的文本不是页面看得见的文本**。切分器是靠**克隆**把一段切两半的——保住上半的页拿一份按高度裁切的副本，下一页拿一个把子节点用负 `marginTop` 拉上去的包壳（`chapterdisplay.js splitPage` 1095-1113），两份都还带着**整段**文字，所以第二页的 `textContent` 开头就是读者已经念完的那几行（用户第二次反馈的原话），而 `chaptertopinfo` 又给每页盖了个「章节名 + 时钟」的固定页眉。现在起点直接问 WebKit：对屏幕上那个盒子顶部做 `caretRangeFromPoint` 命中测试（带向下逐 2px 扫描，跳过固定页眉，再按宿主文档 `.titlebar` 的遮挡高度往下压），拿到可见行的第一个字，再按块收集到本页末尾；后续页只按块收集并**跳过开头的负边距包壳**（那半段上一页已经交过）。滚动式显示器同一条路——可见顶端就是视口滚到的地方。日志的来源行会写明是 `from the visible line` 还是退回 `from the top of the page`。`app.tts.start` 的包装里加了「章节 + 页码」键与「列表已读完」判定：站点只在章节变化时重建队列，翻页后或读完后按播放原本会重播旧页（读完时更糟：站点自己的 `play()` 会直接跳下一章）。日志行带 `page=<cid>#<页码>` |
| `pageRepair` | 评论按钮按需补 `bookinfo`；下载书籍详情页不再空白；下载对话框「起始章→结束章 + 来源选择」；**重复区间只下缺的**（先读 `getChapterDownloaded()`，已下的跳过、全都有就不建任务）；点下载后弹「已开始下载」确认窗（带「查看下载」按钮，直接回到书架→下载页；重复点则提示已在下载）；下载循环自持（无 3s 批间睡眠、失败退避重试、完成后归入已下载并给已下载行加删除/导出按钮）；同一本书不会并发起两个任务，行渲染去重（同一任务只出现一行），未下完的书不再提前出现在「已下载」；**「已下载」按小说维度去重——每行带 `data-stvbook` 键，完成后端进来的行会先摘掉同一本书的旧行，读列表时也按 host/id 折叠记录，所以同一本书永远只有一行、只有一个导出入口**；删除真落盘（站点 `store.remove` 拿的是书对象包装、而 `data` 里存的是记录本体，恒删不掉，这里拆包后再删，并清掉书的单例缓存；章节文件按副本遍历删，避开 `deleteAll` 边遍历边 splice 只删一半的坑；同一本书的残留记录一并清掉）；暂停/继续可用（暂停在重试退避里就生效并保留未下章节，继续会就地解暂停而不是被去重守卫吞掉，重放不会重复插入已下载行） |
| `downloadExport` | 已下载行的「导出」：TXT（书名/作者/来源 + **中文章节名与序号**）或 EPUB（同样的文字转 XHTML，带封面图、`nav.xhtml` 与 `toc.ncx`，只存不压的 ZIP 写入器），字节交给原生 `App.exportFile` 写进临时目录并弹出系统分享面板；标题来自章节列表的 `oridata`（`readchapter` 只给越南语机翻），无编号时按书内章节位次补 `第N章`，绝不用导出序号（下 15-30 章不会被编成 1-16）；正文里站点自己加的存档声明（`bản lưu trong hệ thống`）逐行剥掉，规则与阅读器共用 `__stvI18n.stripNotice`；EPUB 的 `dc:language` / `xml:lang` 是 `zh`（正文与标题都是中文，声明 `vi` 会让阅读器按越南语排版断词） |
| `commentTranslate` | 评论 + 社区帖子翻译：标题栏「译全部」（无弹窗，按钮内联进度，评论没加载完就先记下、到了自动翻）、每条评论/每个帖子单独「译／原文」、发帖输入框「译成X」；覆盖书籍评论页与社区各板块（Kênh truyện / Kênh linh tinh / 势力 / 单帖 / 用户主页评论）；引擎按「系统离线 → 免密钥微软通道 → 自备 Key」降级；设置面板用自绘选择器（原生 `select` 在本 webview 里点不开），语言表 49 种可选可搜 |
| `bootShell` | 首屏外壳：站点 CSS 到位前先把底部标签栏画出来（主题背景 + 载入提示），并记录启动时间线 |
| `SiteI18nData.script` | 生成物：站点文案中译 + 章节名在 `app.reader.getContent` 源头改写（中文原名来自 `oridata`，含阅读器 iframe 兜底）；另导出 `chapterNames(host,id)` / `chineseChapterName` / `stripNotice` 供导出复用（`readchapter` 不带原名，只有章节列表有）。正文里站点自己加的存档声明在主文档与阅读器 frame 里剥掉（只删这一句，段落其余部分不动，空掉的段落才连元素一起删）。**frame 是递归找的**：注入块一律 `forMainFrameOnly`，正文所在的 frame 只能由主文档伸手进去，而 `querySelectorAll` 不跨文档、`srcdoc` 换文档又不产生 mutation——所以新增的 iframe 会在子树里被找出来（不再要求新增节点本身就是 iframe）、每层 frame 自己再找里面的 frame，另有 1 秒周期的兜底扫描（上限 1 小时）。另给 `app.text.changeLanguage` 加一道闸：不是语言代码（字母/数字/`-`/`_`，站点只有 vi/en/zh）的值直接拒掉并不发请求——设置页的语言行带着 `onchange="app.text.changeLanguage('value')"`，而那个 onchange 是 eval 出来的（`page-vip:3646`），域名行的值会从这条路进来，一次 `/mobile/lang/https://sangtacviet.app.json` 就是一次 403 |

## 中文字典流水线

```
data/site-i18n.json            ← 手工维护（唯一真源，可编辑）
  → scripts/gen-site-i18n.js   → SiteI18nData.swift（生成物，勿手改）
  → SitePatch.all              → 注入页面
```

改了 JSON 要重新生成，否则 CI 的 `--check` 会失败。

## 原生会话响应缓存（`plugins/http/.../SangTacHttpPlugin.swift`）

所有 `app.net` 请求最后都走原生 `Http` 插件，插件里有一个**进程内、内存、无磁盘**的
LRU（300 条 / 64MB 上限，重启即清空），命中时按网络路径同一套 `responsePayload` 重建
响应，所以类型与网络路径完全一致。缓存的判定集中在一个 `cachePolicy` 里：

| 请求 | 保留多久 | 什么才算「真答案」 |
|---|---|---|
| `sajax=readchapter` | 整个会话（正文是不可变的已发布文本） | 2xx、≥4KB、`code` 不是 `7`/`10002`（站点的失败 JSON 与超时码不能被缓存） |
| `sajax=getchapterlist`（仅 `GET`） | **300 秒** | 2xx、`code == 1` 且 `data` 是含站点 `-/-` 分隔符的字符串 |

章节列表是唯一被加进来的非正文响应：真机日志里同一本书的列表在一次启动里取了**三次**
（进列表、开阅读器、退回列表：1484 + 1162 + 828 ms，每次 114771 字节），而作者不更新就
不会变。**用户状态类接口故意不缓存**（`userinfo.php`、`booklist.php?method=*`）：它们的
回答带着未读数和关注状态，过期了是「显示错」而不是「省一次往返」。缓存键是
`方法|URL|Cookie 变体`（翻译模式下 `readchapter` 的正文不同），键里没有请求体，所以
POST 永远不进这个缓存。

面板里命中显示为 `[Http] … (cache)`；存入只写原生调用日志（`… cached-for 300s (114771b)`），
不进面板——每个缓存响应都刷一行会把面板淹掉。

## 构建与安装

1. 推送到 `main` 后 GitHub Actions（`macos-26`）自动构建**未签名** IPA
   （`.md` 改动不触发构建）。产物名 `SangTacReader-unsigned.ipa`。
2. 推送到 `main` 的每次构建都会刷新同一个滚动 Release（tag `latest`）：

   ```
   https://github.com/IamNewHands/SangTacReader/releases/latest/download/SangTacReader-unsigned.ipa
   ```

3. 下载后由设备端签名安装（SideStore / LiveContainer / SideInstaller，用你自己的
   Apple ID；仓库不需要任何证书或描述文件）。

## 本地能验证什么

本机（Windows）无法编译 Swift，**Swift 改动只能等 CI 结果**。注入的 JavaScript
可以本地全量验证，CI 每次构建也会跑这四条：

```bash
node scripts/check-ios-shim.js      # 注入块能解析、无转义陷阱、必需标记齐全
node scripts/test-site-patch.js     # 在 stub DOM 里验证每个补丁的行为
node scripts/gen-site-i18n.js --check   # 生成的中译块与 JSON 同步
node scripts/gen-site-assets.js --check # 随包的站点资源镜像与 manifest 同步
```

## 诊断面板（日志开关）

**默认关闭**，此时页面上没有任何悬浮窗、不缓冲日志、也不接管 console。

打开方式：**设置 → 诊断 → 日志（悬浮日志窗口）**，点一下那一行即可开关（右侧实时显示
`已关闭 · 点这里开启` / `已开启 · 点这里关闭`）；下面那行「查看/复制日志」会顺带把开关
打开并弹出面板。开着时：右侧 24px 徽标**常显**（不再只在出错时冒出来），面板随开关一起
弹出，`COPY` 把整个缓冲区放进剪贴板，`HIDE` 只收徽标、`CLOSE` 只收面板；**连点左上角三次**
仍然可以随时开关面板。开关存在 localStorage 并镜像进 Keychain，重装后保持。

面板里的 tag 含义：`Http` 每条原生请求（含 `in <ms>ms` 耗时）、`TTS` 语音合成每次尝试
与正文朗读的句子数/兜底来源/读的是哪一页以及起点取自可见行还是页面顶端（`page=<cid>#<页码>`、`pageflip page N of M, from the visible line`）、`SAFE` 安全区取值、`RECT` 阅读器
菜单与页面顶栏的实际几何量 + `#overlay` / `#mainnavbar` 高度 + `--vh100`（定位灵动岛
遮挡、底栏穿透用）、`SETTINGS` 设置备份/恢复（逐键写出、保留、不可用的数量）、
`BOOKMARK` 取消书签探测、`LIKE` 点赞状态来源与 like/unlike 结果及复查结论（取消只试站点契约那一种键）、
`FOLLOW` 关注动作的真实结果（`followbook` 的 code + 调用前后两次 `querybookmarkstatus` 的 `follow` 值）、
`BOOKINFO` 评论/详情页缺数据时的补取与缓存预热、
`COMMENT` 评论按钮拦截、`TITLE` 章节中文原名的获取结果（阅读器与导出各一条）、
`ASSET` 站点资源 URL 稳定化（token 与拦截到的钩子数）与**资源时间线**（还剩多少静态
请求在网络、wire/解码字节、命中缓存条数、最慢 5 个的耗时与是否命中缓存）、
`MIRROR` 本地资源镜像（装了几个文件、取了哪几个、revalidate 结果、被自愈关掉的时刻）、
`PATCH` 站点文案中译层自己的动作（存档声明剥掉、非语言值被拒），
`DOWNLOAD` 下载限速与任务
按钮（并发去重、已下载章节跳过、已下载列表过滤、同一本书的重复行/记录清理、开始提示窗与跳转下载页、删除落盘、
暂停/继续）、`EXPORT` 导出（读了多少章、跳过了多少、中文章节名的命中数、产物字节数与文件名、交给系统）、
`TRANSLATE` 评论/帖子翻译
（引擎探测、逐条/整页结果、设置保存、等待列表加载）、`PAGE` 页面打开/返回、`NAV` 标签栏
点击、`MSG` 站点弹窗（`app.toast` / `app.context.info`）、`DIAG` 日志开关本身、
`BOOT` 启动时间线（外壳释放时刻 + app/config/标签栏就绪时刻）、`ERR` 错误。

## 许可证

本项目采用自定义的 **个人非商业同源开源许可 1.0**（`LICENSE`，SPDX
`LicenseRef-SangTacReader-NC-SA-1.0`）：

| 条款 | 内容 |
|---|---|
| 个人自用 | 允许为个人学习、研究、自用目的使用、修改 |
| 禁止商用 | 任何形式的商业用途（出售、订阅、广告、企业内部生产、付费托管等）一律禁止 |
| 保留署名 | 必须完整保留 `LICENSE`、版权声明与署名 `IamNewHands` 及仓库地址，并标注你的修改 |
| 同源开源 | 一旦向他人分发（含 IPA/APK、应用商店、侧载包、镜像、二次封装），修改版必须以同一许可公开完整源代码 |

本许可只覆盖本仓库中由本项目作者编写的代码与文档。站点自身的内容、接口、
素材与商标不在授权范围内，其权利归 sangtacviet 所有。

**关于随包的站点资源**：`plugins/app/ios/Sources/SangTacAppPlugin/site-assets/` 里是
站点自己发布的 8 个前端 bundle（`app.v2.js`、`app.v2.css`、`app.v2.read.js` 等，共
906296 字节），由 `scripts/gen-site-assets.js` 从站点原样下载，仅为让 App 不必每次启动重下
它们（见上表 `assetMirror`）。这些文件**不是**本项目作者的作品，不适用上面的许可，
版权归 sangtacviet；它们只随个人自用构建进入 IPA，运行期还会用 `Last-Modified` 与站点
核对并在有变化时用站点的新版本覆盖，不需要的人删掉该目录并去掉 `Package.swift` 里的
`resources` 一行即可（App 会自动退回全网络加载）。

## 说明 / 免责

- 本项目仅供个人学习使用，数据与版权归 sangtacviet 所有，请勿用于商用。
- 图标为占位，如需自定义替换 AppIcon 资源内的 1024x1024 图。
