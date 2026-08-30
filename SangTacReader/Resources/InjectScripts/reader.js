// SangTac 阅读模式注入脚本
// 功能：
//  1) 自动加载正文（点掉"Nhấp vào để tải chương / 点击加载章节"）
//  2) 自动触发隐藏的正文加载
//  3) 隐藏干扰元素（广告、侧栏、页脚、留言框等）
//  4) 改造阅读排版（宽、字体、行高、夜间模式）
//  5) 拨叉 上一章/下一章 按钮
//  6) 顶栏注入"目录"按钮（回到书籍目录）
(function () {
  'use strict';
  // ---- 配置 ----
  var HIDE_SELECTORS = [
    '#tm-credit-section', '#tm-credit-text',   // 页脚版权块
    '#btnshowns',              // 右侧工具栏按钮
    '.toolbar',                // 工具栏
    '#fb-root', '.fb-like',    // fb
    'iframe.ad', 'ins',        // 广告
    '#cbox', '#tm-home-online-box',
    '#navtop', '#navbot',
    '.comment', '#comment',
    '.navbar', '#mainbar',     // 顶栏导航(保留简单返回/目录)
    '#tm-top-nav',
    '#addnamebox', '#loginmodal', 'form',
    '#chatbox'
  ];

  function $(sel, ctx) { return (ctx || document).querySelector(sel); }
  function $$(sel, ctx) { return Array.prototype.slice.call((ctx || document).querySelectorAll(sel)); }

  // ---- 自动加载正文 ----
  function tryLoadContent() {
    // 方式1：点正文容器 / 加载提示
    var c = $('#content-container') || $('#maincontent') || $('#vcontent') || $('#reader');
    var loadEl = $$('#content-container *').concat(c ? [c] : [])
      .find(function (e) { return /(tải chương|tai chuong|点击加载|加载章节|load chương)/i.test(e.textContent || ''); });
    if (loadEl) {
      // 逐级向上冒泡点击, 覆盖事件委托
      var n = loadEl;
      while (n && n !== document.body) {
        try { n.click(); } catch (e) {}
        n = n.parentElement;
      }
    }
    // 方式2：直接调用全局可能存在的加载函数
    try { if (window.excute) window.excute(); } catch (e) {}
  }

  // ---- 隐藏干扰 ----
  function hideJunk() {
    HIDE_SELECTORS.forEach(function (s) {
      try { $$(s).forEach(function (el) { el.style.display = 'none'; }); } catch (e) {}
    });
    // 隐藏任何悬浮广告/弹层
    $$('[id*="ad"], [class*="advert"], [class*="banner"], [class*="popup"]').forEach(function (el) {
      el.style.display = 'none';
    });
  }

  // ---- 阅读美化 ----
  var readerCSS = ['#content-container, .contentbox, #maincontent, .chapter-content, #reader-content {'
    , '  max-width: 720px !important;'
    , '  margin: 0 auto !important;'
    , '  padding: 16px 20px 60px !important;'
    , '  font-size: 19px !important;'
    , '  line-height: 1.9 !important;'
    , '  letter-spacing: 0.2px !important;'
    , '}'
    , '#content-container p, .contentbox p {margin: 0.6em 0 !important; text-indent: 2em !important;}'
    , '#content-container img {max-width:100%;height:auto;}'
    , 'body {background: #f5f0e6 !important; color:#2b2b2b !important;}'
    , '@media(prefers-color-scheme: dark) { body{background:#1a1a1a!important;color:#c8c8c8!important;} }'
  ].join('\n');

  function injectCSS(css) {
    var s = document.createElement('style');
    s.id = 'str-reader-mode';
    s.textContent = css;
    document.head.appendChild(s);
  }

  // ---- 底部上一章/下一章 + 目录 导航 ----
  function buildNav() {
    if ($('#str-reader-nav')) return;
    var navBtn = $$('#navprev, #navnext, a[href*="prev"], a[href*="next"]');
    // 栈: 保留官网自带的导航, 我们只加"目录"与回到顶
    var bar = document.createElement('div');
    bar.id = 'str-reader-nav';
    bar.style.cssText = 'position:fixed;bottom:0;left:0;right:0;z-index:99999;display:flex;background:rgba(30,30,30,.92);color:#fff;padding:10px 12px;justify-content:space-between;font-size:14px;';
    var toc = document.createElement('a');
    toc.textContent = '目录';
    toc.href = '#';
    toc.style.cssText = 'color:#fff;text-decoration:none;padding:6px 12px;background:#444;border-radius:6px;';
    toc.onclick = function (e) { e.preventDefault(); history.length>1 ? history.back() : (document.querySelector('.listchapitem') && document.querySelector('.listchapitem').scrollIntoView()); };
    var top = document.createElement('a');
    top.textContent = '↑';
    top.href = '#';
    top.style.cssText = 'color:#fff;text-decoration:none;padding:6px 12px;background:#444;border-radius:6px;';
    top.onclick = function (e) { e.preventDefault(); window.scrollTo(0,0); };
    bar.appendChild(toc);
    bar.appendChild(top);
    document.body.appendChild(bar);
    // 底部留白,不要被栏挡住
    var spacer = document.createElement('div');
    spacer.id = 'str-spacer';
    spacer.style.cssText = 'height:64px;';
    document.body.appendChild(spacer);
  }

  function init() {
    injectCSS(readerCSS);
    hideJunk();
    buildNav();
    // 延时+重试自动加载正文(内容异步,可能需多次尝试)
    [0, 400, 1200, 2500, 4000].forEach(function (t) {
      setTimeout(function () {
        try { tryLoadContent(); hideJunk(); } catch (e) {}
      }, t);
    });
    // DOM 变化时持续清理
    if (window.MutationObserver) {
      var obs = new MutationObserver(function () { try { hideJunk(); } catch (e) {} });
      setTimeout(function () { obs.observe(document.body, { childList: true, subtree: true }); }, 3000);
    }
  }
  init();
})();