
# SangTacReader — sangtacviet.vip 轻量阅读器（iOS）
目前无法解决获取小说正文绕过cloudflare验证，导致体验非常差，不搞了。
一个极简的 iOS 阅读器：用 WKWebView 打开 sangtacviet.vip，并注入「阅读模式」脚本
（自动加载章节正文、隐藏广告、优化排版、夜间模式、底部导航），免费自签安装。

> 官方目前无 iOS 版（只有安卓 APK）。本项目自行封装官网阅读页，**不逆向正文 API**，
> 尊重官网反爬设计。若官网改版导致脚本失效，改 `reader.js` 即可。

## 功能
- ✅ 打开即进官网（已设为手机 UA）
- ✅ 自动点掉「加载章节」按钮（正文一次加载好）
- ✅ 阅读排版：宽 720 / 字号 19 / 行高 1.9 / 段首缩进 / 图片自适应
- ✅ 隐藏广告、侧栏、页脚、弹窗
- ✅ 夜间模式自动跟随系统
- ✅ 底部「目录 / ↑」导航栏

## 目录结构
```
SangTacReader/
├── SangTacReader.xcodeproj      # Xcode 工程
├── SangTacReader/
│   ├── AppDelegate.swift
│   ├── WebViewController.swift  # WKWebView + 注入 reader.js
│   ├── Info.plist
│   ├── LaunchScreen.storyboard
│   └── Assets.xcassets
└── Resources/InjectScripts/
    └── reader.js                # ★ 阅读模式核心脚本，可自行调试
```

## 如何在 iPhone 上安装（免费，需自签）

iOS 无法像安卓那样直接装，需要先在你的电脑上**签名**一次。任选一种：

### 方式 A：AltStore（推荐，自动续签）
1. Mac 或 Windows 上安装 **AltServer**：https://altstore.io
2. iPhone 连接同一 Wi-Fi，用数据线连电脑
3. 电脑上 `open -a AltServer`（Mac），然后 iPhone 上从
   Tools 触发 AltStore 安装（或直接 `altinstall`）
4. 电脑上用 Xcode 或命令行把本项目构建成 .ipa：
   `xcodebuild -project SangTacReader.xcodeproj -scheme SangTacReader -archivePath build -archive` 然后导出 .ipa
5. 把 .ipa 通过 AltStore 安装到 iPhone
   （AltStore 会要求你的 Apple ID，7 天自动重签）

### 方式 B：Sideloadly（Windows / Mac）
1. 下载 **Sideloadly**：https://sideloadly.io
2. 电脑上装好本项目编译出的 .ipa
3. iPhone 连电脑，用 Sideloadly 把 .ipa + 你的 Apple ID 拖进去安装
   （免费 Apple ID 7 天续签一次；可开启 app 内自动刷新）

### 需要
- 一台电脑（Mac 或 Windows）
- 一个免费 Apple ID（自签用，不收费）
- Xcode（Mac 上构建 .ipa 用）

## 说明 / 免责
- 本项目仅供个人学习使用，数据与版权归 sangtacviet.vip 所有，请勿用于商用。
- 图标为占位，如需自定义替换 `Assets.xcassets/AppIcon.appiconset` 内的 1024x1024 图。
