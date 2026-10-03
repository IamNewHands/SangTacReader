# SangTacReader — sangtacviet 的非官方 iOS 客户端

把 sangtacviet 的网页版装进一个 iOS 原生外壳：Capacitor 8 应用，远程加载
`sangtacviet.com/app.v2.php`，并补齐站点前端依赖的原生能力，让站点走「app 模式」——
这正是官方安卓版拿到完整阅读体验的原因。

官方只发布安卓 APK，本项目自行封装，仅供个人学习使用。

## 功能

- 书列表 / 搜索 / 最新更新 / 排行榜、小说详情、关注 / 书签 / 点赞
- 章节目录与正文阅读（默认左右翻页，可切滚动式）
- 原生 TTS 朗读，从屏幕上看得到的那一行开始念
- 离线下载：断点续传、已下载章节自动跳过、可暂停 / 继续 / 删除
- 导出为 TXT / EPUB（带封面与书名），走系统分享面板
- 评论与社区帖子翻译，系统离线优先，也可自备 API Key
- 界面中文化（越南语 → 简体中文）；首次启动跟随 iOS 系统语言，之后可在设置里改
- 设置、下载记录、日志开关跨重装保留
- 阅读器安全区适配（灵动岛 / Home Indicator）、长按菜单、键盘弹窗定位

## 安装

推送到 `main` 后 GitHub Actions 自动构建**未签名** IPA，并刷新同一个滚动 Release：

```
https://github.com/IamNewHands/SangTacReader/releases/latest/download/SangTacReader-unsigned.ipa
```

下载后用 SideStore / LiveContainer / SideInstaller 以你自己的 Apple ID 本地签名安装；
仓库不含任何证书或描述文件。

## 它是怎么工作的

站点前端按 `window.Capacitor` 是否存在，决定走「app 模式」（原生网络栈）还是
「web 模式」（网页 XHR，容易撞 Cloudflare）。本外壳补齐站点依赖的原生插件，
并在 document start 注入一组站点补丁：站点资源本地镜像与缓存稳定化、镜像故障转移、
设置备份、下载与导出、评论翻译、正文朗读、界面中文化等。

补丁逐条的作用、证据链与每一轮真机问题的根因记录在
[`docs/capacitor-port.md`](docs/capacitor-port.md)。

## 目录结构

```
SangTacReader/
├── capacitor.config.json        # server.url 远程加载站点
├── package.json                 # Capacitor 8 依赖 + 三个本地插件
├── plugins/
│   ├── http/                    # 原生 URLSession 版 Http（含 WKWebView cookie 桥接）
│   ├── app/                     # App 插件 + 站点补丁注入 + 原生 TTS + 中译字典 + 评论翻译
│   └── webnativeview/           # 安卓反射桥的 iOS 占位（漫画模块，尚未实现）
├── data/site-i18n.json          # 站点文案中译字典（唯一真源，生成 SiteI18nData.swift）
├── scripts/                     # 四条本地 / CI 守护
├── docs/capacitor-port.md       # ★ 迁移档案：证据链、决策、逐轮问题根因
└── .github/workflows/build-ipa.yml
```

`ios/` **不入库**：必须由 macOS 上的 `npx cap add ios` 生成（Windows 会把反斜杠路径
写进 `CapApp-SPM/Package.swift`，macOS 的 SwiftPM 无法解析）。

## 本地验证

本机（Windows）无法编译 Swift，Swift 改动只能等 CI；注入的 JavaScript 可以本地全量验证，
CI 每次构建也会跑这四条：

```bash
node scripts/check-ios-shim.js          # 注入块能解析、无转义陷阱、必需标记齐全
node scripts/test-site-patch.js         # 在 stub DOM 里验证每个补丁的行为
node scripts/gen-site-i18n.js --check   # 生成的中译块与 JSON 同步
node scripts/gen-site-assets.js --check # 随包的站点资源镜像与 manifest 同步
```

## 诊断

侧载包看不到控制台，所以内置一个页面内诊断面板：**设置 → 诊断 → 日志**打开。
默认关闭，此时页面上没有任何悬浮窗、不缓冲日志；打开后徽标常显、面板随开关弹出，
可一键复制日志。

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
站点自己发布的 8 个前端 bundle（共 906296 字节），由 `scripts/gen-site-assets.js` 从站点
原样下载，仅为让 App 不必每次启动重下它们。这些文件**不是**本项目作者的作品，不适用上面的
许可，版权归 sangtacviet；它们只随个人自用构建进入 IPA，运行期还会与站点核对并在有变化时
用站点的新版本覆盖。不需要的人删掉该目录并去掉 `Package.swift` 里的 `resources` 一行即可
（App 会自动退回全网络加载）。

## 说明 / 免责

- 本项目仅供个人学习使用，数据与版权归 sangtacviet 所有，请勿用于商用。
- 图标为占位，如需自定义替换 AppIcon 资源内的 1024x1024 图。
