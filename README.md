# SangTacReader — sangtacviet 的非官方 iOS 客户端

与安卓版**同构**的 iOS 客户端：Capacitor 应用，`server.url` 远程加载
`sangtacviet.com/app.v2.php`，并补齐站点前端依赖的原生插件，使站点走
「app 模式」——这正是安卓版拿到完整阅读体验的原因。

> 官方只发布安卓 APK。本项目自行封装，仅供个人学习使用。
> 架构与证据链见 [`docs/capacitor-port.md`](docs/capacitor-port.md)。

## 为什么不是「WKWebView + 注入脚本」

早期版本是纯 WKWebView 套壳，效果很差。原因不是「iOS 没有 Capacitor」，而是：

| | 安卓版 | 旧 iOS 版 |
|---|---|---|
| 运行时 | Capacitor 应用 | 纯 WKWebView |
| 站点判定 | `window.Capacitor` 存在 → **app 模式** | 无 → **web 模式** |
| 数据请求 | 原生网络栈（`Capacitor.Plugins.Http`） | 网页 XHR，撞 Cloudflare / 设备判定 |
| 结果 | 正文 `code:0` | 正文 `code:7`，体验差 |

## 目录结构

```
SangTacReader/
├── capacitor.config.json        # 照抄安卓 APK 的配置（server.url 远程加载）
├── package.json                 # Capacitor 8 依赖 + 三个本地插件
├── dist/index.html              # 仅占位（webDir 在 server.url 模式下不使用）
├── plugins/
│   ├── http/                    # 原生 URLSession 版 Http（含 WKWebView cookie 桥接）
│   ├── app/                     # App 插件 + 安卓版自定义的 SyncCookie
│   └── webnativeview/           # 安卓反射桥的 iOS 占位（仅漫画模块）
├── docs/capacitor-port.md       # ★ 迁移档案：证据链、决策、缺口
├── .github/workflows/build-ipa.yml  # macOS 上构建未签名 IPA
└── SangTacReader.xcodeproj/     # 旧 WKWebView 工程，待新构建验证后退役
```

`ios/` **不入库**：必须由 macOS 上的 `npx cap add ios` 生成（Windows 会把反斜杠
路径写进 `CapApp-SPM/Package.swift`，macOS 的 SwiftPM 无法解析）。

## 构建与安装

1. 推送后由 GitHub Actions（`macos-26`）自动构建**未签名** IPA，产物名
   `SangTacReader-unsigned.ipa`。
2. 下载后由设备端签名安装（SideStore / LiveContainer / SideInstaller，用你自己的
   Apple ID；仓库不需要任何证书或描述文件）。

本机（Windows）无法编译 Swift，任何 Swift 改动都必须等 CI 结果验证。

## 说明 / 免责

- 本项目仅供个人学习使用，数据与版权归 sangtacviet 所有，请勿用于商用。
- 图标为占位，如需自定义替换 AppIcon 资源内的 1024x1024 图。
