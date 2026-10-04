#!/usr/bin/env node
/**
 * Guard: every `"""..."""` block in the SangTacAppPlugin Swift target is
 * JavaScript that the web view will actually run.
 *
 * Why this exists: a Swift string-escaping slip inside one of those blocks once
 * shipped a shim that was a JS syntax error, so it never executed and the whole
 * compatibility layer was silently dead on device (see
 * docs/capacitor-port.md §6.1). Nothing else in the build would
 * have caught it — Swift compiles it happily, and the binary-level check only
 * proves the marker string is present, not that it parses.
 *
 * Run: node scripts/check-ios-shim.js
 */
const fs = require('fs');
const path = require('path');

const TARGET_DIR = path.join(
  __dirname,
  '..',
  'plugins',
  'app',
  'ios',
  'Sources',
  'SangTacAppPlugin'
);

/** Markers that must survive somewhere in the injected JavaScript. */
const REQUIRED_MARKERS = [
  'window.__stvIOSCompatInstalled',
  'window.nativeclick',
  'window.TTS',
  'window.__stvDiag',
  // The asset cache-buster stabiliser: the site appends Math.random() to the
  // URLs of its own /asset/ bundles, which defeats the max-age=86400 it sends.
  'window.__stvAssetCache',
  // The logging switch (off by default) and the two things that make it
  // permanent: its keychain-mirrored store key, and the "view downloads" button
  // of the download-started dialog.
  'stv.diag.settings',
  'action=stvqueue',
  // The delete button has to reach the persistent store (store.remove unwraps
  // the book wrapper) and a pause has to reach the retry backoff, or the reader
  // sees a deleted book come back and a paused download keep going.
  'store.remove unwraps OfflineBook records',
  'resumed in place for ',
  'stvPaused',
  // The detail page's like button is one-way in the site's own client; without
  // this wrapper the second tap re-likes the book and looks like a dead button.
  'like toggle installed',
  // The like state has to come from the endpoint that shares the key space with
  // like()/unlike() (`querylikestatus`), and the call has to be verified: the
  // aggregate reply re-lights the button and made "已取消点赞" a lie.
  'querylikestatus',
  "'unlike(' + label",
  // The unlike ladder is gone: both candidate keys are answered by the device
  // logs (the object id is accepted and deletes nothing, a row id comes back as
  // "no history found"), so the button keeps a single attempt and reports the
  // outcome instead of spending two more requests on the same answer.
  '站点不支持取消这个赞',
  // The site's own archive notice is stripped where the chapter text is
  // consumed -- reader and exporter share the one definition of it.
  'stripNotice',
  'bản lưu trong hệ thống',
  // The reader reads the page that is on screen. The page-flip display renders
  // the chapter into an off-screen element and moves the split pages into the
  // frames it shows, so that element and the body are leftovers -- which is
  // what the device was reading aloud.
  'visiblePageText',
  'pageflip page ',
  '__stvPageKey',
  // ...and it reads that page from the line the reader is looking at, not from
  // the top of the node tree: the splitter clones a paragraph for both halves,
  // so the second page's text opens with the lines the first half already read.
  // The caret is asked of WebKit itself; the spill half is recognised by the
  // negative margin the splitter leaves on it.
  'caretRangeFromPoint',
  'skipSpill',
  'isSpillBlock',
  'chaptertopinfo',
  // A frame inside a frame: the page-flip template is one srcdoc frame and the
  // chapter can be another, and querySelectorAll does not cross that boundary.
  'attachFramesIn',
  // The settings page can hand changeLanguage a domain instead of a language,
  // which costs a 403 per call; a value that is not a language is refused.
  'refused a language that is not one',
  // ...and the overlay itself is a Vietnamese -> Chinese layer, so it may only
  // rewrite anything while the reader has actually asked for Chinese. The
  // language is resolved from the site's own "lang" cookie first.
  'function chineseUi(',
  'function currentLanguage(',
  // The 修炼 value is one datum, so a realm the table does not know must not be
  // half translated ("Chân Đế三重", 2026-10-04 report): the row is left whole
  // and the string is logged instead.
  'function isDanhhaoNode(',
  '名号没有对应词条',
  // Switching language has to re-render the page from the new cookie, or the
  // strings the overlay already rewrote stay Chinese and the page is left
  // half-translated -- which is the report this round answers.
  'function reloadForLanguage(',
  'language switched to ',
  // The first launch adopts the device's language, which the web view cannot
  // know (its navigator.language is the app's localisation, and the Capacitor
  // template ships English only), so native hands it down.
  'window.__stvDeviceLang',
  'first launch: language seeded to ',
  // The reader's error alert (the unlock message with its "Tải lại" button) is
  // built inside the chapter frame or inside .contentcontainer, neither of
  // which the general translation pass may enter -- so it gets its own,
  // alert-scoped pass.
  'function sweepAlertsIn(',
  'function walkAlert(',
  // ...and the message is translated at the funnel that produces it, because the
  // display classes that render it are mirrored site assets we may not edit.
  'function installReaderFunnels(',
  'function translateAlertMessage(',
  'reader alert and failed-chapter navigator hooked',
  // A chapter that failed to load would otherwise be unloaded by name only
  // (PageClipChapter.remove keeps cid, goPrevChapter checks cid), so the bar
  // moved and the body did not.
  'function installChapterUnloadGuard(',
  'chapter unload keeps a real chapter while its own chapter is still loading',
  // A chapter that needs unlocking never gets cdata, so the display answers the
  // bottom bar with an empty name -- blanking the only proof that < or > moved.
  'function installDisplayName(',  'the chapter bar keeps a name while the chapter has no content',
  // Bing TTS speaks through MediaSource with a WebM/Opus buffer, which WebKit
  // on iOS cannot play -- the entry is dropped and a stored bing choice is
  // healed to the native provider.
  'tts provider bing -> ios (no MediaSource on iOS)',
  // One DOWNLOADED row per novel: the row is stamped and the finished job drops
  // the row it would otherwise duplicate.
  'data-stvbook',
  // Exporting has to relabel every heading from the chapter list's original
  // names, or the file opens as one blob in another reader.
  'chapterNames',
  // Re-running a finished range must queue only what is not on disk yet.
  'already downloaded',
  // Long-pressing a book cell has to open the menu without selecting text.
  'webkit-touch-callout',
  // Exporting a downloaded book: the in-page builder and the native hand-off.
  'window.__stvExportInstalled',
  'exportFile',
  'window.__stvActivityLogInstalled',
  'window.__stvTabProbeInstalled',
  'window.__stvStorageAccessorInstalled',
  'window.__stvGridLayoutInstalled',
  'window.__stvKeyboardPopupInstalled',
  'window.__stvReaderDefaultsInstalled',
  'window.__stvTtsProviderInstalled',
  'window.__stvI18nInstalled',
  'window.__stvFollowFallbackInstalled',
  'window.__stvSafeAreaInstalled',
  'window.__stvSettingsBackupInstalled',
  'window.__stvDomainFailoverInstalled',
  'window.__stvBookmarkToggleInstalled',
  'window.__stvReaderTtsInstalled',
  'window.__stvPageRepairInstalled',
  'window.__stvCommentTranslateInstalled',
  'window.__stvBootShellInstalled',
  // The reader modules the site only asks for once the reader opens.
  'window.__stvReaderPrefetchInstalled',
  'pageflip',
  // The local asset mirror: the site's own boot bundles are shipped inside the
  // app and handed to the page from document start, because the shell asks for
  // them with a Math.random() cache-buster over a 300-900ms link. The flag is
  // the escape hatch a failed mirror sets before reloading without itself.
  'window.__stvAssetMirror',
  'stv.mirror.off',
  'data-stv-mirror',
  "STV_SERVER",
  'siteAssetRefresh',
  // The resource timeline is the measurement half: it reports what the mirror
  // does *not* cover (the parser-created files) so the remaining cost is known
  // rather than assumed.
  'static request(s) still over the network',
  // The mirror choice has to exist before the site's first request, not shortly
  // after it: `fullUrl()`/`bestDomain()` resolve the host of every app.net call
  // in the same turn the managers are created, so the install is driven by
  // accessors instead of a poll.
  'function watchProperty(',
  'function watchNet(',
  // ...and the way back out: if the declaration is ever refused, the trap is
  // dropped for good and the page reloaded once instead of the site never booting.
  'stv.domain.trap.off',
  // A remembered mirror used to lose only by answering code 7, so a mirror that
  // stalled kept winning: the 2026-09-23 log is four 10s timeouts in a row on the
  // same chapter list and a reader that never got one. Now a request that comes
  // back with no payload bans it, the site's own retries land elsewhere, an
  // explicit 线路 choice wins, and the fresh probe ranking is logged.
  'function patchNet(',
  'function wrappedNet(',
  'function failed(',
  'function reachFailure(',
  'transport failover installed',
  'app_domain=',
  // 关注/书签的结果上报：站点把回调传给了 `app.net.get` 的 `force` 参数（不是回调），
  // 所以站点自己写的 toast 与列表刷新是死代码，成与不成看起来一模一样。
  'function attachFollow(',
  '站点没有取消关注的接口',
  // The Cbox board is a cross-origin frame and Capacitor's bridge is
  // main-frame-only, so this one block is injected into every frame and refuses
  // to exist anywhere but Cbox. Without the marker the whole 社区 → Cbox
  // translation channel is silently absent.
  'window.__stvCboxFrameInstalled',
  'stvCbox',
  // The comic sources now answer the list API with a bot challenge, and the
  // token is minted by a script the plugin's URLSession never runs. Without this
  // wrapper 漫画 renders its tabs and no rows at all.
  'window.__stvComicGateInstalled',
  'the comic source asked for a bot check',
  // The keyless Google channel (newsnook-ios uses the same endpoint), and the
  // two comic repairs: the site's own translator used to mangle every provider's
  // rows (url included) or hang for ever, and getComicProvider threw on a
  // non-string argument.
  'translate_a/single',
  'the comic sources translator can no longer lose the data',
  'getComicProvider no longer throws on a bad argument',
  // The notification line's book name is the server's Vietnamese one; the
  // Chinese name comes from the book the item links to.
  'notification book titles are looked up in Chinese',
  // 势力 translates its list but the window it opens prints the server's own
  // description plus the template's hardcoded labels.
  'popup bodies are translated when auto translate is on',
  '站点没有删除评论的接口',
  // 2026-10-04: the diagnostic buffer died with the page, so the one report that
  // matters most — a crash — arrived with nothing in it. Every line is now
  // mirrored into a file the app process owns, and the panel reads it back.
  'stv-diagnostic.log',
  'function toBase64(',
  // ...and the same report said the faction board took 14 seconds: gtx answers
  // one text per request, so the sweep was split into two sequential chunks of
  // ~60. Now it is pooled, de-duplicated, cached and ramped.
  'function gtxWorthSending(',
  'function gtxCacheLoad(',
  'nothing to send (谷歌通道)',
  'width ended at ',
  // 漫画: a failing source used to leave the preloader spinning and the detail
  // page half built (both callers attach a bare .then()), and the chapter frame
  // was on a different host from the page, so every read across it threw
  // SecurityError.
  'function guardProvider(',
  'function patchTranslatorUrl(',
  'the chapter frame is on ',
  'function patchReaderFrame(',
  'function frameReport(',
  'the chapter frame could not be wired up',
  // The frame's translator never handed the OCR service an image: a plain url
  // was dropped by toRealRawData's missing return, and a LAZY: url waited for a
  // parent answer nobody sends. Both are repaired from the parent now.
  'function patchChapterTranslator(',
  'function onChapterFrameMessage(',
  'the chapter frame translator is patched',
  // When the site's own egress is what is blocked, the reader fetches the page
  // and hands the bytes over; a page neither side can reach names the host.
  'function imageHost(',
  'could not be fetched here either',
  // The comic detail page's own chapter-count row is never filled by the site.
  'function patchComicChapterCount(',
  // The chapter-list tail reads `.url` off a value that IS the url.
  'function patchComicHistory(',
  // The frame hard-codes "paired" mode, so it hands the OCR service a JSON array
  // of two images: joining them was never a url, and the array is what the
  // service parses itself. A paired request also reaches the byte relay, which
  // used to hand the whole array to the downloader.
  'function imageCandidates(',
  'function imageBytesOne(',
  // A url the service cannot fetch makes it answer plain text, which the frame's
  // JSON.parse turned into a silent hang.
  'function patchOcrResponse(',
  '"imageWidth":null,"t_image":null',
  // The last-read marker is applied a line before the site hands the ROW to
  // ui.scrollto, which builds its selector as `$("#" + ele)` and so only takes an
  // id. And paired mode asks for the same image twice, so a dead host used to cost
  // one TLS handshake per image.
  'function patchScrollto(',
  'function patchComicChapterListScroll(',
  'leaving the rest of this chapter to the',
];

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

if (!fs.existsSync(TARGET_DIR)) {
  fail(`missing ${TARGET_DIR}`);
}

const swiftFiles = fs
  .readdirSync(TARGET_DIR)
  .filter((name) => name.endsWith('.swift'))
  .sort();

if (swiftFiles.length === 0) {
  fail(`${TARGET_DIR} contains no Swift sources`);
}

const blocks = [];
for (const name of swiftFiles) {
  const file = path.join(TARGET_DIR, name);
  const swift = fs.readFileSync(file, 'utf8');
  const declared = (swift.match(/=\s*"""/g) || []).length;
  const found = [...swift.matchAll(/"""([\s\S]*?)"""/g)].map((m) => m[1]);
  if (declared !== found.length) {
    fail(
      `${name}: found ${declared} multiline-string openers but paired ${found.length} blocks — ` +
        'a stray `"""` inside a string or comment has unbalanced the file'
    );
  }
  found.forEach((js, index) => blocks.push({ file: name, index, js }));
}

if (blocks.length === 0) {
  fail('no `"""..."""` JavaScript block found in the SangTacAppPlugin target');
}

let total = 0;
for (const block of blocks) {
  const label = `${block.file} block #${block.index + 1}`;

  // Swift processes escapes inside multiline string literals, so a stray `\n`
  // reaches JS as a real newline and breaks the string it sits in. These blocks
  // are written without any backslash on purpose.
  const backslashes = (block.js.match(/\\/g) || []).length;
  if (backslashes > 0) {
    fail(`${label} contains ${backslashes} literal backslash(es); write it escape-free`);
  }

  try {
    // eslint-disable-next-line no-new-func
    new Function(block.js);
  } catch (error) {
    fail(`${label} is not valid JavaScript: ${error.message}`);
  }

  total += block.js.length;
}

const combined = blocks.map((block) => block.js).join('\n');
for (const marker of REQUIRED_MARKERS) {
  if (!combined.includes(marker)) {
    fail(`injected JavaScript is missing required marker: ${marker}`);
  }
}

/**
 * Blocks are separate WKUserScripts, so each is its own script AND its own
 * IIFE: a helper defined in one block is not in scope in another. A block that
 * calls a neighbour's helper therefore throws `ReferenceError` — and only on
 * the path that helper was written for, which is why it reads as "the failure
 * handler failed". `comicGate` called `messageOf` (defined in
 * `commentTranslate`) exactly that way, and every comic failure report it was
 * supposed to write became a second, silent failure instead.
 *
 * The harness runs the blocks concatenated, so it cannot see this; only a
 * per-block scope check can. Helpers listed here are duplicated per block on
 * purpose, so every block that names one has to define it.
 */
const SHARED_HELPERS = ['note', 'messageOf', 'settle', 'appPlugin', 'q', 'qq',
  'textOf', 'bodyOf', 'httpRequest', 'loadSettings', 'trimSlashes'];

// Matched against the block with its comments removed, never a
// string-stripped copy: these blocks are full of Vietnamese text and of regexes
// that quote attribute names, and a quote-pairing pass over that desynchronises
// and eats most of the block. Comments are the only thing that has to go — a
// doc comment naming `q("...")` is not a call.
function codeOnly(source) {
  let out = '';
  let i = 0;
  let quote = null;
  while (i < source.length) {
    const ch = source[i];
    const next = source[i + 1];
    if (quote) {
      if (ch === quote) { quote = null; }
      out += ch;
      i += 1;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') {
      quote = ch;
      out += ch;
      i += 1;
      continue;
    }
    if (ch === '/' && next === '/') {
      while (i < source.length && source[i] !== '\n') { i += 1; }
      continue;
    }
    if (ch === '/' && next === '*') {
      i += 2;
      while (i < source.length && !(source[i] === '*' && source[i + 1] === '/')) { i += 1; }
      i += 2;
      continue;
    }
    out += ch;
    i += 1;
  }
  return out;
}

for (const block of blocks) {
  const code = codeOnly(block.js);
  for (const helper of SHARED_HELPERS) {
    const call = new RegExp('(^|[^.\\w$\'"`])' + helper + '\\s*\\(', 'm');
    if (!call.test(code)) { continue; }
    const declares = new RegExp(
      '(?:function\\s+' + helper + '\\s*\\()'
      + '|(?:(?:var|let|const)\\s+' + helper + '\\b)', 'm');
    if (!declares.test(code)) {
      const at = code.search(call);
      const snippet = code.slice(Math.max(0, at - 60), at + 40).replace(/\s+/g, ' ');
      fail(`${block.file} block #${block.index + 1} calls ${helper}() without defining it; `
        + 'blocks are separate scripts and separate IIFEs, so that is a ReferenceError'
        + ` — near: ${snippet}`);
    }
  }
}

/**
 * The workflow's shell steps are run by a bash whose locale makes it fold the
 * high bytes of a multi-byte character into a variable name. `echo "…（$marker）…"`
 * therefore asks for the variable `marker\xEF\xBC\x89`, `set -u` aborts, and the
 * step dies with no output at all — which is what happened to run 37177806505,
 * after a three-minute build. `${marker}` is always safe; this catches the bare
 * form next to any non-ASCII character before the build starts.
 */
const WORKFLOW_DIR = path.join(__dirname, '..', '.github', 'workflows');
for (const name of fs.readdirSync(WORKFLOW_DIR).filter((file) => /\.ya?ml$/.test(file))) {
  const lines = fs.readFileSync(path.join(WORKFLOW_DIR, name), 'utf8').split(/\r?\n/);
  lines.forEach((line, index) => {
    if (/^\s*#/.test(line)) { return; }
    const risky = /\$([A-Za-z_][A-Za-z0-9_]*)([^\x00-\x7F])/.exec(line);
    if (risky) {
      fail(`${name}:${index + 1} uses $${risky[1]} directly before `
        + `${JSON.stringify(risky[2])}; write \${${risky[1]}} — bash folds the `
        + 'high bytes into the name and set -u aborts the step');
    }
  });
}

console.log(
  `✓ injected document-start JavaScript is valid (${blocks.length} blocks, ${total} bytes, ` +
    `${REQUIRED_MARKERS.length} markers)`
);
