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

书列表 / 搜索 / 最新更新 / 排行榜、小说详情、关注与书签、章节目录、正文阅读
（默认左右翻页）、原生 TTS 朗读、评论翻译（系统离线优先，可自备 API Key）、
界面中文化、设置跨重装保留。

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
├── scripts/                     # 三条本地/CI 守护（见下）
├── docs/capacitor-port.md       # ★ 迁移档案：证据链、决策、逐轮真机问题
└── .github/workflows/build-ipa.yml   # macOS 上构建未签名 IPA 并发布滚动 Release
```

`ios/` **不入库**：必须由 macOS 上的 `npx cap add ios` 生成（Windows 会把反斜杠
路径写进 `CapApp-SPM/Package.swift`，macOS 的 SwiftPM 无法解析）。

旧 WKWebView 工程（`SangTacReader.xcodeproj/`、`SangTacReader/` 及其打包的 `www/`
资源）与 `tests/` 下的一次性探测脚本已在 2026-09-22 退役，需要时从 git 历史取回。

## 站点补丁（`plugins/app/.../SitePatch.swift`）

站点是远程页面，我们唯一的注入点是 `WKUserScript`（document start）。共 17 个块，
每块独立守卫、互不依赖：

| 块 | 作用 |
|---|---|
| `compat` | `nativeclick` 空实现 + `window.TTS` 门面（站点不调则整条点击链抛错） |
| `diag` | 页面内诊断面板 `window.__stvDiag`（侧载包没有可读控制台） |
| `tabProbe` | 临时：点 tab 时上报 tabbar 项宽、指针 transform/width、`tabdiv` transform、末页子节点数 |
| `storageAccessor` | 替换站点坏掉的 `app.storage.get`（`await prefs.get({key}).value` 恒为 `undefined`），设置/下载记录/历史才读得回来 |
| `readerDefaults` | iOS 上把阅读器 `display_type` 默认成左右翻页；修「静态章节名称」选过不显示后再也回不来的单程 bug |
| `ttsProvider` | 注册 `ttsEngine` 的 `ios` provider，走原生 `AVSpeechSynthesizer`；按文本语种挑发音人 |
| `followFallback` | 「关注」接口服务端 500 时探测站点自己的旧接口 |
| `safeArea` | 灵动岛 / Home Indicator：安全区补齐、`#overlay` 高度兜底 + 阅读器菜单几何量上报 |
| `keyboardPopup` | 键盘弹起时接管带输入框弹窗的纵向定位（顶在键盘上方、压到可视区内），收起后交还站点 CSS |
| `gridLayout` | 书架网格：格子不再被强制成第一格的高度、标题两行截断；历史网格换成与书签 tab 同款的 auto-fill 列（1 行 4 个）+ 行不再被拉伸 |
| `settingsBackup` | 设置与下载记录镜像进 Keychain；等 `storageAccessor` 修好后才恢复，并把值回灌运行中的 `app.config` / `offlineBook.store.data` |
| `domainFailover` | 正文镜像故障转移：回过 `code 7` 的域名不再被选中，`getContent` 出口拦截并换镜像重取 |
| `bookmarkToggle` | 已收藏时探测取消接口，把书签按钮变成真开关 |
| `readerTts` | 正文朗读：句子来源取当前章、失败原因上报、测试语句改中文、退出正文自动停止 |
| `pageRepair` | 评论按钮按需补 `bookinfo`；下载书籍详情页不再空白；下载对话框「起始章→结束章 + 来源选择」；下载循环自持（无 3s 批间睡眠、失败退避重试、完成后归入已下载并给已下载行加删除按钮） |
| `commentTranslate` | 评论翻译：标题栏「译全部」、每条评论单独「译／原文」、发帖输入框「译成X」；引擎按「系统离线 → 免密钥微软通道 → 自备 Key」降级，设置面板在 设置 → 翻译 |
| `bootShell` | 首屏外壳：站点 CSS 到位前先把底部标签栏画出来（主题背景 + 载入提示），并记录启动时间线 |
| `SiteI18nData.script` | 生成物：站点文案中译 + 章节名在 `app.reader.getContent` 源头改写（中文原名来自 `oridata`，含阅读器 iframe 兜底） |

## 中文字典流水线

```
data/site-i18n.json            ← 手工维护（唯一真源，可编辑）
  → scripts/gen-site-i18n.js   → SiteI18nData.swift（生成物，勿手改）
  → SitePatch.all              → 注入页面
```

改了 JSON 要重新生成，否则 CI 的 `--check` 会失败。

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
可以本地全量验证，CI 每次构建也会跑这三条：

```bash
node scripts/check-ios-shim.js      # 注入块能解析、无转义陷阱、必需标记齐全
node scripts/test-site-patch.js     # 在 stub DOM 里验证每个补丁的行为
node scripts/gen-site-i18n.js --check   # 生成的中译块与 JSON 同步
```

## 诊断面板

侧载包看不到 console，所以出错都进页面面板：**连点左上角三次**打开，`COPY`
把整个缓冲区放进剪贴板。徽标平时隐藏，出现第一条 `ERR` 才显示。

面板里的 tag 含义：`Http` 每条原生请求（含 `in <ms>ms` 耗时）、`TTS` 语音合成每次尝试
与正文朗读的句子数/兜底来源、`FOLLOW` 关注接口探测、`SAFE` 安全区取值、`RECT` 阅读器
菜单与页面顶栏的实际几何量 + `#overlay` / `#mainnavbar` 高度 + `--vh100`（定位灵动岛
遮挡、底栏穿透用）、`SETTINGS` 设置备份/恢复（逐键写出、保留、不可用的数量）、
`BOOKMARK` 取消书签探测、`BOOKINFO` 评论/详情页缺数据时的补取与缓存预热、
`COMMENT` 评论按钮拦截、`TITLE` 章节中文原名的获取结果、`DOWNLOAD` 下载限速与任务
按钮、`TRANSLATE` 评论翻译（引擎探测、逐条/整页结果、设置保存）、`BOOT` 启动时间线
（外壳释放时刻 + app/config/标签栏就绪时刻）、`ERR` 错误。

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

## 说明 / 免责

- 本项目仅供个人学习使用，数据与版权归 sangtacviet 所有，请勿用于商用。
- 图标为占位，如需自定义替换 AppIcon 资源内的 1024x1024 图。
