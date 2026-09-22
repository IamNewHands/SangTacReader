// 验证 1：线上 JS 是否仍是 nativeClick() 在 openBook* 之前（点击链首行抛错）
// 验证 2：注入 shim 后，同样的 handler 是否不再抛错
const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';

const SHIM = `(function () {
    if (window.__stvIOSCompatInstalled) { return; }
    window.__stvIOSCompatInstalled = true;
    if (typeof window.nativeclick === 'undefined') {
        window.nativeclick = { trigger: function () {}, watch: function () {} };
    }
    if (typeof window.TTS === 'undefined') { window.TTS = {}; }
})();`;

(async () => {
  const html = await (await fetch('https://sangtacviet.com/app.v2.php', { headers: { 'User-Agent': UA } })).text();
  const urls = [...new Set([...html.matchAll(/["'](\/app\.v2[a-z0-9._-]*\.js[^"']*)["']/gi)].map(m => m[1]))];
  console.log('线上 app.v2*.js:', urls.join(', ') || '(HTML 里没直接引用)');

  for (const u of urls) {
    const js = await (await fetch('https://sangtacviet.com' + u, { headers: { 'User-Agent': UA } })).text();
    const idx = [...js.matchAll(/nativeClick\(\);?\s*\n?\s*app\.fun\.openBook/g)].length;
    const anyNative = (js.match(/nativeClick\(\)/g) || []).length;
    console.log(`  ${u}: len=${js.length} nativeClick()=${anyNative} 紧邻 openBook=${idx}`);
    if (anyNative) {
      const i = js.indexOf('nativeClick()');
      console.log('    片段:', js.slice(Math.max(0, i - 120), i + 120).replace(/\s+/g, ' '));
    }
  }

  console.log('\n--- shim 行为验证 ---');
  // 复刻站点点击回调：第一行 nativeclick.trigger()，第二行才是打开详情
  const handler = (scope) => {
    let opened = false;
    const app = { platform: { nativeClick() { scope.nativeclick.trigger(); } }, fun: { openBookWithData() { opened = true; } } };
    try { app.platform.nativeClick(); app.fun.openBookWithData(); } catch (e) { return { opened, err: e.constructor.name + ': ' + e.message }; }
    return { opened, err: null };
  };

  const before = handler({});                       // iOS 现状：没有 nativeclick
  console.log('注入前:', JSON.stringify(before));
  const scope = {};
  new Function('window', SHIM)(scope);              // 注入 shim（window 即全局作用域替身）
  const after = handler(scope);
  console.log('注入后:', JSON.stringify(after));

  const ok = before.opened === false && before.err !== null && after.opened === true && after.err === null;
  console.log(ok ? '\n结论: 假设成立 —— 缺失 nativeclick 会中断点击链，shim 可修复' : '\n结论: 假设不成立，需重新定位');
})();
