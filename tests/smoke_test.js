/**
 * SangTacReader - 完整冒烟测试套件 (Smoke Test Suite)
 * 
 * 用途：每次代码修改后执行完整回归测试，确保核心功能不被破坏。
 * 执行：node tests/smoke_test.js
 * 
 * 测试分类：
 *   A. 服务端连通性 & 入口页面验证
 *   B. API 接口全链路测试
 *   C. 多源小说兼容性测试
 *   D. iOS 前端 CSS/JS 注入规则验证
 *   E. WebViewController 桥接脚本完整性验证
 */

const https = require('https');
const fs = require('fs');
const path = require('path');

// ============================================
// 工具函数
// ============================================

function fetchUrl(url, postData = null, cookie = '') {
  return new Promise((resolve, reject) => {
    const urlObj = new URL(url);
    const options = {
      hostname: urlObj.hostname,
      port: 443,
      path: urlObj.pathname + urlObj.search,
      method: postData ? 'POST' : 'GET',
      headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 SangTacVietApp/1.2.17',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8,application/json',
        'Referer': 'https://sangtacviet.vip/',
        'Origin': 'https://sangtacviet.vip',
        'Cookie': cookie
      }
    };
    if (postData) {
      options.headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8';
      options.headers['Content-Length'] = Buffer.byteLength(postData);
    }
    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => resolve({
        status: res.statusCode,
        headers: res.headers,
        body: data,
        setCookie: res.headers['set-cookie']
      }));
    });
    req.on('error', reject);
    req.setTimeout(15000, () => { req.destroy(); reject(new Error('Request timeout')); });
    if (postData) req.write(postData);
    req.end();
  });
}

// ============================================
// 测试框架
// ============================================

let totalPassed = 0;
let totalFailed = 0;
let totalSkipped = 0;
const results = [];

function assert(condition, name, details = '') {
  if (condition) {
    console.log(`  [PASS] ${name}`);
    totalPassed++;
    results.push({ status: 'PASS', name });
  } else {
    console.error(`  [FAIL] ${name} -> ${details}`);
    totalFailed++;
    results.push({ status: 'FAIL', name, details });
  }
}

function skip(name, reason) {
  console.log(`  [SKIP] ${name} -> ${reason}`);
  totalSkipped++;
  results.push({ status: 'SKIP', name, reason });
}

function section(title) {
  console.log(`\n${'='.repeat(60)}`);
  console.log(`  ${title}`);
  console.log('='.repeat(60));
}

// ============================================
// A. 服务端连通性 & 入口页面验证
// ============================================

async function testConnectivity() {
  section('A. 服务端连通性 & 入口页面验证');

  // A1: 官网首页
  try {
    const homeRes = await fetchUrl('https://sangtacviet.vip/');
    assert(homeRes.status === 200, 'A1. 官网首页可访问 (HTTP 200)', `Status: ${homeRes.status}`);
    assert(homeRes.body.length > 5000, 'A2. 首页内容完整 (>5KB)', `Body size: ${homeRes.body.length}`);
  } catch (e) {
    assert(false, 'A1. 官网首页可访问', e.message);
    assert(false, 'A2. 首页内容完整', 'Skipped due to A1 failure');
  }

  // A3: 移动端入口
  try {
    const appRes = await fetchUrl('https://sangtacviet.vip/app.v2.php');
    assert(appRes.status === 200, 'A3. 移动端入口 app.v2.php 可访问', `Status: ${appRes.status}`);
    assert(appRes.body.length > 1000, 'A4. app.v2.php 内容完整', `Body size: ${appRes.body.length}`);

    // A5: DOM 结构关键元素
    assert(appRes.body.includes('<tab id="mainview"'), 'A5. 根容器 <tab id="mainview"> 存在', 'HTML missing mainview');
    assert(
      appRes.body.includes('id="tabtusach"') && appRes.body.includes('id="tabtimkiem"'),
      'A6. 四大 Tab 页签定义完整',
      'Missing tab definitions'
    );
    assert(appRes.body.includes('id="mainnavbar"'), 'A7. 底部导航栏 #mainnavbar 存在', 'Missing #mainnavbar');

    // A8: 核心 JS/CSS 资源引用
    assert(
      appRes.body.includes('stv.ui.js') || appRes.body.includes('stv.ui.min.js'),
      'A8. 核心 stv.ui.js 脚本引用存在',
      'Missing stv.ui.js reference'
    );

    return appRes.body;
  } catch (e) {
    assert(false, 'A3. 移动端入口 app.v2.php 可访问', e.message);
    return null;
  }
}

// ============================================
// B. API 接口全链路测试
// ============================================

async function testAPIs() {
  section('B. API 接口全链路测试');

  // B1: 首页书籍列表提取
  let testHost = '69shu', testBookId = '48443';
  try {
    const homeRes = await fetchUrl('https://sangtacviet.vip/');
    const bookMatches = [...homeRes.body.matchAll(/\/truyen\/([a-zA-Z0-9_\-]+)\/1\/([0-9]+)\//g)];
    assert(bookMatches.length > 0, 'B1. 首页书籍列表可提取', `Found ${bookMatches.length} books`);

    // 优先选择支持 ngmar 接口的标准小说源 (如 69shu, uukanshu, biquge)
    const supportedSources = ['69shu', 'uukanshu', 'biquge', 'hetushu'];
    const matched = bookMatches.find(m => supportedSources.includes(m[1]));
    if (matched) {
      testHost = matched[1];
      testBookId = matched[2];
    }
    console.log(`     -> 选取测试书籍: Host=${testHost}, BookID=${testBookId}`);
  } catch (e) {
    assert(false, 'B1. 首页书籍列表可提取', e.message);
    console.log(`     -> 回退到默认测试书籍: Host=${testHost}, BookID=${testBookId}`);
  }

  // B2: 排行榜 API (app.v2 接口)
  try {
    const rankData = await fetchUrl('https://sangtacviet.vip/app.v2.php?ajax=get_rank&type=all&page=1');
    assert(
      rankData.body && (rankData.body.includes('{') || rankData.body.includes('[') || rankData.body.length > 20),
      'B2. 排行榜 API (get_rank) 响应正常',
      'Empty response'
    );
  } catch (e) {
    assert(false, 'B2. 排行榜 API (get_rank) 响应正常', e.message);
  }

  // B3: 书籍详情 API (app.v2 接口)
  try {
    const bookDetail = await fetchUrl('https://sangtacviet.vip/app.v2.php?ajax=book_detail&bookid=37758');
    assert(bookDetail.body && bookDetail.body.length > 10, 'B3. 书籍详情 API (book_detail) 响应正常', 'Detail response empty');
  } catch (e) {
    assert(false, 'B3. 书籍详情 API (book_detail) 响应正常', e.message);
  }

  // B4: 章节内容 API (app.v2 接口)
  try {
    const chapData = await fetchUrl('https://sangtacviet.vip/app.v2.php?ajax=get_chapter&bookid=37758&chap=1');
    assert(chapData.body && chapData.body.length > 10, 'B4. 章节内容 API (get_chapter) 响应正常', 'Chapter response empty');
  } catch (e) {
    assert(false, 'B4. 章节内容 API (get_chapter) 响应正常', e.message);
  }

  // B5: 搜索 API
  try {
    const searchRes = await fetchUrl('https://sangtacviet.vip/index.php?sajax=searchbook', 'key=kiem+hiep');
    assert(searchRes.status === 200, 'B5. 搜索 API (sajax=searchbook) 响应正常', `Status: ${searchRes.status}`);
  } catch (e) {
    assert(false, 'B5. 搜索 API (sajax=searchbook) 响应正常', e.message);
  }

  // B6: 小说详情页面加载
  try {
    const bookRes = await fetchUrl(`https://sangtacviet.vip/truyen/${testHost}/1/${testBookId}/`);
    assert(bookRes.status === 200, 'B6. 小说详情页面加载 (HTML)', `Status: ${bookRes.status}`);
  } catch (e) {
    assert(false, 'B6. 小说详情页面加载 (HTML)', e.message);
  }

  // B7: 章节列表 API (ngmar 接口)
  try {
    const chapListRes = await fetchUrl(
      `https://sangtacviet.vip/index.php?ngmar=chapterlist&h=69shu&bookid=48443&sajax=getchapterlist`,
      null,
      { 'Referer': `https://sangtacviet.vip/truyen/69shu/1/48443/` }
    );
    let chapListJson = null;
    try { chapListJson = JSON.parse(chapListRes.body); } catch (e) {}
    const hasChapterData = chapListJson && chapListJson.data && chapListJson.data.length > 0;
    assert(hasChapterData, 'B7. 章节列表 API (ngmar=chapterlist) 返回数据', `Response: ${chapListRes.body.slice(0, 100)}`);

    // B8: 章节正文 API
    if (hasChapterData) {
      const chapters = chapListJson.data.split('-//-');
      const firstChap = chapters[0].split('-/-');
      const group = firstChap[0];
      const chapid = firstChap[1];
      console.log(`     -> 章节列表共 ${chapters.length} 章, 测试第1章: Group=${group}, ChapID=${chapid}`);

      const readAjax = await fetchUrl(
        `https://sangtacviet.vip/index.php?ngmar=readchapter&h=69shu&b=48443&c=${chapid}`,
        null,
        { 'Referer': `https://sangtacviet.vip/truyen/69shu/${group}/48443/${chapid}/` }
      );
      assert(
        readAjax.status === 200 && readAjax.body.length > 0,
        'B8. 章节正文 API (ngmar=readchapter) 返回内容',
        `Status: ${readAjax.status}, Body: ${readAjax.body.slice(0, 80)}`
      );
    } else {
      skip('B8. 章节正文 API (ngmar=readchapter) 返回内容', 'No chapter list');
    }
  } catch (e) {
    assert(false, 'B7. 章节列表 API (ngmar=chapterlist) 返回数据', e.message);
  }
}

// ============================================
// C. 多源小说兼容性测试
// ============================================

async function testMultipleSources() {
  section('C. 多源小说兼容性测试');

  const sources = [
    { name: '69shu', bookid: '48443' },
    { name: 'uukanshu', bookid: '65842' },
  ];

  for (const src of sources) {
    try {
      const bookRes = await fetchUrl(`https://sangtacviet.vip/truyen/${src.name}/1/${src.bookid}/`);
      assert(
        bookRes.status === 200,
        `C. [${src.name}] 书籍详情页可访问`,
        `Status: ${bookRes.status}`
      );
    } catch (e) {
      assert(false, `C. [${src.name}] 书籍详情页可访问`, e.message);
    }
  }
}

// ============================================
// D. iOS 前端 CSS/JS 注入规则验证
// ============================================

async function testCSSRules() {
  section('D. iOS 前端 CSS/JS 注入规则验证');

  // 读取 WebViewController.swift 中的 bridgeJS 内容
  const swiftPath = path.join(__dirname, '..', 'SangTacReader', 'WebViewController.swift');
  let swiftContent = '';
  try {
    swiftContent = fs.readFileSync(swiftPath, 'utf8');
    assert(swiftContent.length > 0, 'D1. WebViewController.swift 文件存在且可读');
  } catch (e) {
    assert(false, 'D1. WebViewController.swift 文件存在且可读', e.message);
    return;
  }

  // D2: CSS 视口修复规则
  assert(swiftContent.includes('--vh100'), 'D2. bridgeJS 包含 --vh100 CSS 变量设置');
  assert(swiftContent.includes('--vh'), 'D3. bridgeJS 包含 --vh 动态计算变量');
  assert(swiftContent.includes('safe-area-inset-bottom'), 'D4. bridgeJS 包含安全区底部适配');

  // D5: 主视图布局规则
  assert(swiftContent.includes('tab#mainview'), 'D5. bridgeJS 包含 #mainview 高度视口适配');
  assert(swiftContent.includes('#mainnavbar'), 'D6. bridgeJS 包含 #mainnavbar 底栏安全区规则');

  // D7-D11: 关键 —— 纯 Web 模式，不得注入任何 Capacitor/Cordova 桥接。
  // 前端 app.v2.js 用 window.hasOwnProperty("Capacitor") 判断原生模式，
  // 一旦存在 window.Capacitor 就会等待原生 SQLite，导致 app.init() 永不执行。
  assert(!swiftContent.includes('window.Capacitor'), 'D7. 不注入 window.Capacitor（避免触发原生分支）');
  assert(!/window\.Capacitor\s*=/.test(swiftContent), 'D7.1. 不赋值 window.Capacitor 对象');
  assert(!swiftContent.includes('cordovaExec'), 'D7.2. 不注册 cordovaExec 消息桥');
  assert(!swiftContent.includes('window.cordova'), 'D10. 不注入 window.cordova');
  assert(!swiftContent.includes('WKScriptMessageHandler'), 'D11. 不注册 JS-Native 消息桥');

  // D8: 动态视口更新
  assert(swiftContent.includes('window.innerHeight'), 'D8. 动态 vh 计算使用 window.innerHeight');
  assert(
    swiftContent.includes("addEventListener('resize'") || swiftContent.includes('addEventListener("resize"'),
    'D9. resize 事件监听器注册',
    'Missing resize listener'
  );

  // D12: didFinish 中的修复
  assert(
    swiftContent.includes('dispatchEvent') && swiftContent.includes('resize'),
    'D12. didFinish 中触发 resize 事件重新计算视口'
  );

  // D13: Web 模式强制同域 —— 注入 XHR 拦截，把前端 fullUrl()/bestDomain() 切到镜像
  // 域名的请求改回当前页面域。原因：GET 请求带自定义头 x-stv-transport: web，
  // 服务器 CORS 白名单不含该头，跨域 preflight 被拦截 -> onerror -> 目录加载失败。
  // 改回同域后无 preflight，x-stv-transport 头正常发送（去掉会返回 502）。
  assert(
    swiftContent.includes('XMLHttpRequest.prototype.open') &&
      swiftContent.includes('x-stv-transport') &&
      swiftContent.includes('stvHosts'),
    'D13. 注入 XHR 同域拦截，保持同域绕开 CORS preflight 拦截',
    'Missing XHR same-origin rewrite patch for x-stv-transport header'
  );
}

// ============================================
// E. WebViewController 桥接脚本完整性验证
// ============================================

async function testBridgeIntegrity() {
  section('E. WebViewController 桥接脚本完整性验证');

  const swiftPath = path.join(__dirname, '..', 'SangTacReader', 'WebViewController.swift');
  let swiftContent = '';
  try {
    swiftContent = fs.readFileSync(swiftPath, 'utf8');
  } catch (e) {
    assert(false, 'E0. WebViewController.swift 可读取', e.message);
    return;
  }

  // E1: WKWebView 配置
  assert(swiftContent.includes('WKWebView'), 'E1. 使用 WKWebView 组件');
  assert(swiftContent.includes('WKWebViewConfiguration'), 'E2. WKWebView 正确配置');

  // E3: Cookie 持久化
  assert(
    swiftContent.includes('WKWebsiteDataStore.default()') || swiftContent.includes('dataStore'),
    'E3. Cookie 持久化 (WKWebsiteDataStore.default)',
    'Missing cookie persistence'
  );

  // E4: 纯 Web 模式 —— 不注册 JS-Native 消息桥（避免前端误判原生环境）
  assert(
    !swiftContent.includes('WKScriptMessageHandler'),
    'E4. 纯 Web 模式，不注册 JS-Native 消息桥',
    'Found native message bridge that would break Web mode'
  );

  // E5: 导航策略
  assert(
    swiftContent.includes('decidePolicyFor') || swiftContent.includes('navigationAction'),
    'E5. 导航策略拦截器 (decidePolicyFor)'
  );

  // E6: 入口 URL —— 必须落在前端 defaultDomains 内 (sangtacviet.com)，与安卓一致
  assert(
    swiftContent.includes('sangtacviet.com/app.v2.php'),
    'E6. 加载正确的移动端入口 URL (sangtacviet.com)',
    'Entry URL must be sangtacviet.com to keep cookies same-origin'
  );

  // E7-E8: 解决服务器对 GET 强制要求 Referer 的问题。
  // 服务器要求 GET 必须带 Referer 头，否则返回空体(Content-Length: 0)，前端会误判为
  // "Kết nối tới máy chủ thất bại"。安卓用 CapacitorHttp 原生层显式附加 Referer。
  // iOS 不能再用 WKURLSchemeHandler 接管 https（https 是 WKWebView 原生 scheme，
  // setURLSchemeHandler 会抛异常崩溃），而是注入脚本强制所有 STV 请求保持同源：
  // WKWebView 对【同源】XHR 会自动携带完整 Referer，等价于安卓显式附加 Referer。
  assert(
    !swiftContent.includes('setURLSchemeHandler'),
    'E7. 不使用 WKURLSchemeHandler 接管 https（避免崩溃）',
    'setURLSchemeHandler on https throws an exception in WKWebView'
  );
  assert(
    swiftContent.includes('isDomainAlive = function') &&
      swiftContent.includes('bestDomain = function') &&
      swiftContent.includes('XMLHttpRequest.prototype.open'),
    'E8. 注入同域强制脚本 (覆盖 isDomainAlive/bestDomain + XHR 同域) 让浏览器自动带 Referer',
    'Missing same-origin enforcement so WKWebView sends Referer automatically'
  );
}

// ============================================
// 主执行入口
// ============================================

async function main() {
  const startTime = Date.now();

  console.log('');
  console.log('╔══════════════════════════════════════════════════════════╗');
  console.log('║     SangTacReader 完整冒烟测试 (Smoke Test Suite)       ║');
  console.log('║     Version: 1.0                                       ║');
  console.log(`║     Date: ${new Date().toISOString().slice(0, 19)}                    ║`);
  console.log('╚══════════════════════════════════════════════════════════╝');

  try {
    await testConnectivity();
    await testAPIs();
    await testMultipleSources();
    await testCSSRules();
    await testBridgeIntegrity();
  } catch (e) {
    console.error(`\n[FATAL] 测试执行异常: ${e.message}`);
    console.error(e.stack);
  }

  const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);

  console.log('');
  console.log('╔══════════════════════════════════════════════════════════╗');
  console.log(`║  测试结果: ${totalPassed} PASSED / ${totalFailed} FAILED / ${totalSkipped} SKIPPED`);
  console.log(`║  耗时: ${elapsed}s`);
  console.log('╚══════════════════════════════════════════════════════════╝');

  if (totalFailed > 0) {
    console.log('\n失败测试项：');
    results.filter(r => r.status === 'FAIL').forEach(r => {
      console.log(`  - ${r.name}: ${r.details}`);
    });
    process.exit(1);
  } else {
    console.log('\n所有测试通过！可以安全提交代码。');
    process.exit(0);
  }
}

main();
