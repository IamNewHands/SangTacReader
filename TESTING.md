# SangTacReader 测试流程说明

## 概述

本项目采用 **冒烟测试 (Smoke Test)** 作为核心回归测试手段。每次代码修改后，必须执行完整冒烟测试并全部通过，方可提交代码或触发 CI 构建。

---

## 快速开始

```bash
# 一键执行完整冒烟测试
node tests/smoke_test.js
```

**要求**：Node.js >= 14，需要网络连接（测试会访问 sangtacviet.vip 验证 API）。

---

## 测试分类

### A. 服务端连通性 & 入口页面验证 (A1-A8)

| 编号 | 测试内容 | 说明 |
|------|----------|------|
| A1 | 官网首页可访问 | HTTP 200 |
| A2 | 首页内容完整 | Body > 5KB |
| A3 | 移动端入口 app.v2.php 可访问 | HTTP 200 |
| A4 | app.v2.php 内容完整 | Body > 1KB |
| A5 | 根容器 `<tab id="mainview">` 存在 | DOM 结构关键元素 |
| A6 | 四大 Tab 页签定义完整 | tabtusach, tabtimkiem 等 |
| A7 | 底部导航栏 #mainnavbar 存在 | 布局关键元素 |
| A8 | 核心 stv.ui.js 脚本引用存在 | JS 资源引用 |

### B. API 接口全链路测试 (B1-B8)

| 编号 | 测试内容 | 接口 |
|------|----------|------|
| B1 | 首页书籍列表可提取 | 首页 HTML 解析 |
| B2 | 排行榜 API 响应正常 | `app.v2.php?ajax=get_rank` |
| B3 | 书籍详情 API 响应正常 | `app.v2.php?ajax=book_detail` |
| B4 | 章节内容 API 响应正常 | `app.v2.php?ajax=get_chapter` |
| B5 | 搜索 API 响应正常 | `index.php?sajax=searchbook` |
| B6 | 小说详情页面加载 | `/truyen/{host}/1/{bookid}/` |
| B7 | 章节列表 API 返回数据 | `index.php?ngmar=chapterlist` |
| B8 | 章节正文 API 返回内容 | `index.php?ngmar=readchapter` |

### C. 多源小说兼容性测试

验证不同小说源（69shu、uukanshu 等）的书籍详情页是否可正常访问。

### D. iOS 前端 CSS/JS 注入规则验证 (D1-D14)

验证 `WebViewController.swift` 中 bridgeJS 脚本的完整性：

| 编号 | 验证内容 |
|------|----------|
| D1 | WebViewController.swift 文件可读 |
| D2 | --vh100 CSS 变量设置 |
| D3 | --vh 动态计算变量 |
| D4 | safe-area-inset-bottom 安全区适配 |
| D5 | #mainview flex 布局修复规则 |
| D6 | #mainnavbar 底栏固定规则 |
| D7 | 内容区域 flex 弹性扩展规则 |
| D8 | window.innerHeight 动态计算 |
| D9 | resize 事件监听器 |
| D10 | Capacitor 桥接对象注入 |
| D11 | Cordova 执行桥接注入 |
| D12 | didFinish 中触发 resize 重算 |
| D13 | 原生 TTS 语音合成支持 |
| D14 | 原生触觉反馈支持 |

### E. WebViewController 桥接脚本完整性验证 (E1-E7)

| 编号 | 验证内容 |
|------|----------|
| E1 | WKWebView 组件使用 |
| E2 | WKWebViewConfiguration 配置 |
| E3 | Cookie 持久化 (WKWebsiteDataStore) |
| E4 | JS-Native 消息桥接 |
| E5 | 导航策略拦截器 |
| E6 | 正确的移动端入口 URL |
| E7 | 全屏/状态栏控制 |

---

## 测试结果解读

```
╔══════════════════════════════════════════════════════════╗
║  测试结果: 30 PASSED / 0 FAILED / 0 SKIPPED
║  耗时: 5.2s
╚══════════════════════════════════════════════════════════╝
```

- **PASSED**: 测试通过
- **FAILED**: 测试失败，需要修复后重新测试
- **SKIPPED**: 因前置条件不满足而跳过（通常是网络或数据问题）

退出码：`0` = 全部通过，`1` = 存在失败项。

---

## 回归测试流程

每次代码修改后，按以下流程执行：

```
1. 修改代码
2. 执行: node tests/smoke_test.js
3. 确认全部 PASSED
4. git add & git commit
5. git push -> 触发 GitHub Actions 编译 IPA
```

**规则**：冒烟测试存在 FAIL 项时，禁止提交代码。

---

## 测试文件结构

```
SangTacReader/
├── tests/
│   └── smoke_test.js          # 统一冒烟测试入口（主测试文件）
├── test_suite.js               # 早期集成测试（已合并到 smoke_test.js）
├── run_tests.js                # 早期 API 全链路测试（已合并）
├── test_api.js                 # 早期探索性 API 测试（已合并）
├── test_detail.js              # 书籍详情分析脚本
├── test_contain.js             # 前端初始化序列测试
├── test_jsdom.js               # JSDOM 模拟 DOM 渲染测试
├── test_sources.js             # 多源兼容性测试（已合并）
├── test_read_chap.js           # 章节阅读逻辑分析
├── test_chap_url.js            # 章节 URL 分析
├── test_chap_url2.js           # 章节 URL 分析 v2
└── test_script.js              # 前端脚本分析
```

> 注意：根目录下的 `test_*.js` 和 `run_tests.js` 是开发过程中产生的探索性测试脚本，其核心测试逻辑已全部整合到 `tests/smoke_test.js` 中。日常回归测试只需执行 `tests/smoke_test.js`。

---

## 后续完善计划

- [ ] 添加登录态 API 测试（需要测试账号）
- [ ] 添加 TTS 语音合成端到端测试
- [ ] 添加离线资源完整性校验
- [ ] 接入 GitHub Actions CI 自动执行冒烟测试
- [ ] 添加 WebSocket/实时聊天功能测试
- [ ] 添加更多小说源兼容性测试
