#!/usr/bin/env node
/**
 * Behavioural test for the JavaScript we inject into the site (SitePatch.swift).
 *
 * `scripts/check-ios-shim.js` proves the blocks parse. This proves they do what
 * the site expects, in a stubbed DOM/WKWebView environment:
 *
 *   - window.TTS.speakToFile reaches Capacitor.Plugins.App and turns the base64
 *     WAV into an audio Blob (the ttsEngine provider contract)
 *   - ttsEngine.createProvider("ios") yields a provider whose speak() returns a
 *     Blob and whose getVoices() never returns an empty list
 *   - app.tts.engineList() lists the native engine first
 *   - app.tts.setting.ios exists, because loadProviderOption dereferences
 *     app.tts.setting[provider].voice unguarded
 *   - an untouched reader display_type is seeded to "pageflip", while a value the
 *     user already chose is left alone
 *   - the diagnostics panel builds without throwing and buffers lines
 *   - the safe-area patch fills in `--status-bar-height` / `--screensafebottom`
 *     from the native insets, pads the reader's overlay title bar, and leaves a
 *     value the site already produced alone
 *   - the settings backup writes keychain entries back into localStorage, keeps
 *     an existing localStorage value, and mirrors `app.storage.set` writes
 *   - the bookmark button cancels (probing removal actions) instead of re-adding
 *     when the book is already bookmarked
 *
 * Run: node scripts/test-site-patch.js
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const TARGET_DIR = path.join(__dirname, '..', 'plugins', 'app', 'ios', 'Sources', 'SangTacAppPlugin');

let failures = 0;
function check(name, condition, detail) {
  if (condition) {
    console.log(`  ok   ${name}`);
  } else {
    failures += 1;
    console.log(`  FAIL ${name}${detail ? ' — ' + detail : ''}`);
  }
}

function loadBlocks() {
  const blocks = [];
  for (const name of fs.readdirSync(TARGET_DIR).filter((f) => f.endsWith('.swift')).sort()) {
    const swift = fs.readFileSync(path.join(TARGET_DIR, name), 'utf8');
    for (const match of swift.matchAll(/"""([\s\S]*?)"""/g)) {
      blocks.push(match[1]);
    }
  }
  return blocks;
}

// ---------------------------------------------------------------- DOM stub

function makeStyle() {
  // A plain object that also answers setProperty/getPropertyValue, because the
  // safe-area patch writes and reads CSS custom properties on :root.
  return {
    setProperty(name, value) {
      this[name] = String(value);
    },
    getPropertyValue(name) {
      return this[name] === undefined ? '' : String(this[name]);
    },
    removeProperty(name) {
      delete this[name];
    },
  };
}

function makeElement(tagName) {
  const element = {
    nodeType: 1,
    tagName: String(tagName || 'div').toUpperCase(),
    id: '',
    className: '',
    value: '',
    nodeValue: null,
    parentNode: null,
    children: [],
    style: makeStyle(),
    attributes: {},
    setAttribute(name, value) {
      this.attributes[name] = value;
      if (name === 'class') { this.className = value; }
    },
    getAttribute(name) {
      return this.attributes[name];
    },
    appendChild(child) {
      child.parentNode = this;
      this.children.push(child);
      return child;
    },
    removeChild(child) {
      this.children = this.children.filter((entry) => entry !== child);
      this.childNodes = this.children;
      child.parentNode = null;
      return child;
    },
    listeners: {},
    addEventListener(type, handler) {
      this.listeners[type] = (this.listeners[type] || []).concat([handler]);
    },
    removeEventListener() {},
    // The injected blocks attach click handlers to buttons they create, so the
    // stub has to be able to fire them.
    __fire(type, event) {
      const handlers = this.listeners[type] || [];
      for (const handler of handlers) { handler(event); }
    },
    getBoundingClientRect() {
      return { left: 0, top: 0, width: 26, height: 26, right: 26, bottom: 26 };
    },
    select() {},
    querySelector() {
      return null;
    },
    querySelectorAll(selector) {
      // Supports the shapes the injected blocks actually use: one or more
      // comma-separated class selectors, plus bare tag and #id selectors.
      const matchers = String(selector)
        .split(',')
        .map((part) => part.trim())
        .filter(Boolean)
        .map((part) => {
          if (part.charAt(0) === '.') { return { cls: part.slice(1) }; }
          if (part.charAt(0) === '#') { return { id: part.slice(1) }; }
          return { tag: part.toUpperCase() };
        });
      const found = [];
      const visit = (node) => {
        for (const child of node.children) {
          if (child.nodeType !== 1) { continue; }
          const names = String(child.className || '').split(/\s+/);
          for (const matcher of matchers) {
            const hit = (matcher.cls && names.indexOf(matcher.cls) >= 0)
              || (matcher.id && child.id === matcher.id)
              || (matcher.tag && child.tagName === matcher.tag);
            if (hit) { found.push(child); break; }
          }
          visit(child);
        }
      };
      visit(element);
      return found;
    },
    focus() {},
  };
  element.childNodes = element.children;

  // parentElement mirrors parentNode, like the real DOM (the comment-button
  // capture listener walks up with it).
  Object.defineProperty(element, 'parentElement', {
    get() {
      return element.parentNode;
    },
  });

  // classList mirrors className, like the real DOM.
  Object.defineProperty(element, 'classList', {
    get() {
      const names = () => String(element.className || '').split(/\s+/).filter(Boolean);
      return {
        contains: (name) => names().indexOf(name) >= 0,
        add: (name) => { if (names().indexOf(name) < 0) { element.className = names().concat([name]).join(' '); } },
        remove: (name) => { element.className = names().filter((n) => n !== name).join(' '); },
        toggle: (name) => {
          if (names().indexOf(name) >= 0) { element.className = names().filter((n) => n !== name).join(' '); }
          else { element.className = names().concat([name]).join(' '); }
        },
      };
    },
  });

  // textContent has to reflect the children, because the i18n chapter-title
  // pass reads and rewrites it.
  let detached = '';
  Object.defineProperty(element, 'textContent', {
    get() {
      if (element.children.length === 0) { return detached; }
      let out = '';
      for (const child of element.children) {
        out += child.nodeType === 3 ? (child.nodeValue || '') : (child.textContent || '');
      }
      return out;
    },
    set(value) {
      detached = value === undefined || value === null ? '' : String(value);
      element.children.length = 0;
      element.childNodes = element.children;
      if (detached !== '') { element.appendChild(makeTextNode(detached)); }
    },
  });

  return element;
}

function makeTextNode(value) {
  return {
    nodeType: 3,
    nodeValue: value,
    parentNode: null,
    childNodes: [],
    textContent: value,
  };
}

function makeContainer(tagName, className, text) {
  const element = makeElement(tagName);
  element.className = className;
  if (text !== undefined) {
    element.appendChild(makeTextNode(text));
  }
  return element;
}

function makeSandbox() {
  const body = makeElement('body');
  const head = makeElement('head');
  const documentElement = makeElement('html');
  documentElement.appendChild(head);
  documentElement.appendChild(body);

  const byId = (id) => {
    let found = null;
    const visit = (node) => {
      if (found) { return; }
      if (node.id === id) { found = node; return; }
      for (const child of node.children || []) { visit(child); }
    };
    visit(documentElement);
    return found;
  };

  const store = {};
  const localStorage = {
    getItem: (key) => (Object.prototype.hasOwnProperty.call(store, key) ? store[key] : null),
    setItem: (key, value) => { store[key] = String(value); },
    removeItem: (key) => { delete store[key]; },
    keys: () => Object.keys(store),
  };

  const listeners = {};
  const document = {
    body,
    head,
    documentElement,
    createElement: (tag) => makeElement(tag),
    addEventListener(type, handler) {
      listeners[type] = listeners[type] || [];
      listeners[type].push(handler);
    },
    removeEventListener() {},
    getElementById: byId,
    querySelectorAll: (selector) => documentElement.querySelectorAll(selector),
    elementFromPoint() {
      return null;
    },
    execCommand() {
      return true;
    },
  };
  const window = {
    innerHeight: 800,
    innerWidth: 400,
    addEventListener() {},
    removeEventListener() {},
    getComputedStyle: (element) => ({
      getPropertyValue: (name) => (element.style && element.style.getPropertyValue
        ? element.style.getPropertyValue(name)
        : ''),
    }),
  };
  window.window = window;

  const sandbox = {
    window,
    document,
    localStorage,
    navigator: { userAgent: 'node-test' },
    console: { log() {}, warn() {}, error() {} },
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    atob: (value) => Buffer.from(value, 'base64').toString('binary'),
    Blob: globalThis.Blob,
    Uint8Array,
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  sandbox.__dom = { byId, store, head };
  // The page-repair block installs a capture-phase click listener on document;
  // the tests need to be able to fire it.
  sandbox.__dispatch = (type, event) => {
    for (const handler of listeners[type] || []) { handler(event); }
  };
  sandbox.__listenerCount = (type) => (listeners[type] || []).length;
  return sandbox;
}

/**
 * A same-origin srcdoc iframe, which is where the reader puts the chapter text
 * (and the pinned chapter name) -- `getMainContainer()` builds one in
 * app.v2.chapterdisplay.js and writes baseSrcDoc into it.
 */
function makeFakeFrame(contentElements) {
  const frame = makeElement('iframe');
  const html = makeElement('html');
  const frameBody = makeElement('body');
  html.appendChild(frameBody);
  for (const element of contentElements || []) { frameBody.appendChild(element); }
  const byId = (id) => {
    let found = null;
    const visit = (node) => {
      if (found) { return; }
      if (node.id === id) { found = node; return; }
      for (const child of node.children || []) { visit(child); }
    };
    visit(html);
    return found;
  };
  const doc = { documentElement: html, body: frameBody, getElementById: byId };
  frame.contentDocument = doc;
  frame.contentWindow = {
    document: doc,
    addEventListener() {},
    removeEventListener() {},
  };
  return frame;
}

// ---------------------------------------------------------------- fake site

function installFakeApp(sandbox, options) {
  const calls = [];
  const stored = {};
  const keychain = Object.assign({}, options.keychain || {});
  const posts = [];

  const setting = {
    provider: options.provider || 'bing',
    set(name, value) {
      if (!this[this.provider]) { this[this.provider] = {}; }
      this[this.provider][name] = value;
      stored.tts = JSON.stringify(this);
    },
  };

  const app = {
    platform: { isIOS: options.isIOS !== false, isAndroid: false, isWeb: false },
    config: {
      _reader: { display_type: options.displayType },
      reader: {},
    },
    storage: {
      // The site reads its config through app.storage, which on iOS is
      // Capacitor Preferences -- NOT localStorage. The stub has to expose the
      // same pair, or the settings backup can pass here while restoring into a
      // store the site never reads (which is what the device showed).
      get(key) {
        return Promise.resolve(sandbox.localStorage.getItem(key) || '');
      },
      set(key, value) {
        sandbox.localStorage.setItem(key, value);
        stored[key] = value;
        return Promise.resolve();
      },
      cache: {
        getFile() {
          return Promise.resolve(options.storedTtsSetting || '');
        },
        setFile(key, value) {
          return app.storage.set(key, value);
        },
      },
    },
    tts: {
      setting,
      engineList() {
        return [
          { name: 'Bing TTS', value: 'bing' },
          { name: 'Zalo AI', value: 'zalo' },
        ];
      },
    },
    api: {
      bookmark(bookdata) {
        stored.bookmarkAdds = (stored.bookmarkAdds || 0) + 1;
        return Promise.resolve({ code: 100, bookdata: bookdata });
      },
    },
    net: {
      post(url, body) {
        posts.push({ url, body });
        const action = String(body).replace('ajax=', '').split('&')[0];
        const ok = options.bookmarkRemoval === action;
        return Promise.resolve(ok ? { code: 100 } : { code: 101 });
      },
    },
    toast(message) {
      stored.toasts = (stored.toasts || []).concat([message]);
    },
  };
  app.config.reader.__defineSetter__('display_type', function (value) {
    app.config._reader.display_type = value;
    stored.reader = value;
  });
  app.config.reader.__defineGetter__('display_type', function () {
    return app.config._reader.display_type;
  });

  // ---- reader / TTS / navigation surface used by the newer blocks ----------
  const display = options.display || null;
  app.reader = {
    bookinfo: options.readerBookInfo === undefined ? null : options.readerBookInfo,
    host: options.readerHost || 'qidian',
    id: options.readerId || '1034915599',
    getDisplay() { return display; },
    loadChapterDisplay() { return display; },
    showMenuOl() { stored.menuOlCalls = (stored.menuOlCalls || 0) + 1; },
  };
  app.fun = {
    openBookWithData(bookid, data) {
      stored.opened = (stored.opened || []).concat([{ bookid, data }]);
      return 'pushed-page';
    },
    showComment(host, id) {
      stored.comments = (stored.comments || []).concat([{ host, id }]);
    },
  };
  app.tts.start = function () {
    stored.startCalls = (stored.startCalls || 0) + 1;
    if (options.ttsStartThrows) { throw new Error('start failed'); }
    this.player = { sentences: options.ttsSentences || [] };
  };
  app.tts.player = {
    sentences: [],
    stop() { stored.ttsStops = (stored.ttsStops || 0) + 1; },
  };
  app.tts.test = function () { stored.testCalls = (stored.testCalls || 0) + 1; };
  app.tts.openSetting = function () { stored.openSettingCalls = (stored.openSettingCalls || 0) + 1; };
  app.tts.applyPlaybackSetting = function () {};
  app.tts.playQueue = function () {};
  const bookInfoResponses = options.bookInfoResponses || {};
  app.net.getCacheLater = (url) => {
    stored.cacheLater = (stored.cacheLater || []).concat([url]);
    if (url.indexOf('sajax=getchapterlist') >= 0) {
      return Promise.resolve(options.oridata
        ? { code: 1, oridata: options.oridata }
        : { code: 1, data: '1-/-1-/- Thứ 1 chương mở đầu -//-' });
    }
    if (!Object.prototype.hasOwnProperty.call(bookInfoResponses, url)) {
      return Promise.resolve(null);
    }
    return Promise.resolve(bookInfoResponses[url]);
  };
  app.net.get = (url) => app.net.getCacheLater(url);
  app.popPage = function () {
    stored.popPageCalls = (stored.popPageCalls || 0) + 1;
    // The real popPage tears the page down; popping a sub-page the reader
    // pushed (the chapter list) leaves the reader mounted.
    if (options.popKeepsReader) { return; }
    const view = sandbox.document.getElementById('chapterview');
    if (view && view.parentElement) { view.parentElement.removeChild(view); }
  };
  // The single funnel every chapter name comes from (app.v2.read.js:602).
  app.reader.getContent = options.getContent || function () {
    return Promise.resolve({
      chaptername: options.chapterName === undefined ? 'Chương 03:. Giao phong'
        : options.chapterName,
    });
  };
  app.offlineBook = {
    store: { data: options.offlineBooks || [] },
    getDownloadBooks(from, to) {
      stored.listReads = (stored.listReads || []).concat([from + ':' + to]);
      // Stands in for populateBookInfo(), which answers from the bookinfo cache
      // and silently returns [] on a miss.
      const cache = stored.cacheLater || [];
      return Promise.resolve(app.offlineBook.store.data.slice(from, to).filter((book) => {
        return cache.indexOf('/mobile/bookinfo.php?hid=' + book.id + '&host=' + book.host) >= 0;
      }));
    },
  };
  // DownloadManager renders its progress row the instant a download starts
  // (app.v2.read.js:3481), and that render is what reads the cache.
  app.bookDownloaderList = [];
  class FakeDownloadManager {
    constructor(host, id) {
      this.host = host;
      this.id = id;
      this.isPaused = false;
      this.chapters = ['c1', 'c2'];
      this.downloaded = 0;
      this.total = 2;
      app.bookDownloaderList.push(this);
    }
    render() {
      stored.renderCache = (stored.cacheLater || []).slice();
      return Promise.resolve(makeContainer('div', 'bookrowcont'));
    }
    downloadChapter(chapter) {
      stored.downloadStarts = (stored.downloadStarts || []).concat([Date.now()]);
      if (options.downloadFails) { return Promise.reject(new Error('Không thể đọc dữ liệu')); }
      return Promise.resolve(chapter);
    }
    pause() { this.isPaused = true; }
    start() { this.isPaused = false; stored.resumes = (stored.resumes || 0) + 1; }
  }
  app.BookDownloadManager = FakeDownloadManager;

  sandbox.app = app;
  sandbox.window.app = app;
  sandbox.__calls = calls;
  sandbox.__stored = stored;
  sandbox.__posts = posts;
  sandbox.__keychain = keychain;

  sandbox.Capacitor = {
    Plugins: {
      App: {
        speakToFile(payload) {
          calls.push(payload);
          // The real plugin resolves an object, not a bare string.
          return Promise.resolve({
            data: Buffer.from('RIFFfakewav').toString('base64'),
            mime: 'audio/wav',
          });
        },
        getVoices() {
          return Promise.resolve({
            voices: [
              { identifier: 'com.apple.voice.compact.vi-VN.Linh', name: 'Linh', language: 'vi-VN', gender: 2 },
            ],
          });
        },
        stopSpeech() {
          return Promise.resolve({ value: true });
        },
        getSafeArea() {
          return Promise.resolve(options.safeArea || { top: 62, bottom: 34, left: 0, right: 0 });
        },
        settingsSave(payload) {
          keychain[payload.key] = payload.value;
          return Promise.resolve({ value: true });
        },
        settingsRestore() {
          return Promise.resolve({ entries: Object.assign({}, keychain) });
        },
      },
    },
  };
  sandbox.window.Capacitor = sandbox.Capacitor;
  return app;
}

function tick(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------- tests

async function testCompatAndTtsProvider() {
  console.log('compat + tts provider');
  const sandbox = makeSandbox();
  const blocks = loadBlocks();
  installFakeApp(sandbox, { displayType: 'auto' });

  // ttsEngine stands in for /stv.tts.js.
  sandbox.ttsEngine = { createProvider() { throw new Error('unknown provider'); } };
  sandbox.window.ttsEngine = sandbox.ttsEngine;

  vm.runInContext(blocks.join('\n'), sandbox);

  check('nativeclick global exists', typeof sandbox.window.nativeclick === 'object');
  check('TTS facade exists', typeof sandbox.window.TTS === 'object');
  check(
    'updateMediaSession deliberately absent',
    sandbox.window.TTS.updateMediaSession === undefined,
    'the site guards this call with if (TTS.updateMediaSession)'
  );

  const raw = await sandbox.window.TTS.speakToFile({ text: 'Xin chào', identifier: 'v', rate: 1, pitch: 1 });
  check(
    'speakToFile reaches Capacitor.Plugins.App',
    !!raw && typeof raw === 'object' && typeof raw.data === 'string' && raw.data.length > 0,
    'SangTacAppPlugin resolves { data, mime }, not a bare base64 string'
  );
  check('speakToFile forwarded the text', sandbox.__calls[0] && sandbox.__calls[0].text === 'Xin chào');

  // The provider registration polls; give it a tick.
  await tick(400);
  check('ttsEngine.createProvider was patched', !!sandbox.ttsEngine.__stvIosProviderInstalled);

  sandbox.ttsEngine.createProvider('ios', {});
  const provider = sandbox.ttsEngine.provider;
  check('ios provider created', !!provider && typeof provider.speak === 'function');
  check('provider exposes props', !!provider.props && !!provider.props.voice);

  const blob = await provider.speak('Xin chào', { voice: 'v', rate: 1.2 });
  check('provider.speak returns a Blob', !!blob && typeof blob.size === 'number' && blob.size > 0,
    'regression: the shim used to reject the plugin object as "no audio"');
  check('provider.speak asks for audio/wav', !!blob && blob.type === 'audio/wav');

  const voices = await provider.getVoices();
  check('getVoices returns the native voice', voices.length === 1 && voices[0].value.includes('vi-VN'));
  check('female voice maps to site gender 1', voices[0].gender === 1);

  // The reader hands every sentence it builds to the site with a leading
  // marker, because the site's own filter only lets an ASCII word character
  // through and Chinese text has none. The marker must never be spoken.
  await provider.speak('stv0第一句', { voice: 'v', rate: 1 });
  const forwarded = sandbox.__calls[sandbox.__calls.length - 1];
  check('the reader sentence marker is stripped before synthesis',
    forwarded && forwarded.text === '第一句', forwarded ? forwarded.text : '(no call)');
  await provider.speak('Xin chào', { voice: 'v', rate: 1 });
  const plain = sandbox.__calls[sandbox.__calls.length - 1];
  check('unmarked text is forwarded untouched', plain && plain.text === 'Xin chào',
    plain ? plain.text : '(no call)');

  const list = sandbox.app.tts.engineList();
  check('engineList lists iOS first', list[0].value === 'ios', JSON.stringify(list));
  check('engineList keeps the network providers', list.length === 3);
  check('setting.ios exists (loadProviderOption dereferences it)', !!sandbox.app.tts.setting.ios);
  check('provider defaulted to ios on a fresh install', sandbox.app.tts.setting.provider === 'ios');
}

async function testTtsProviderRespectsStoredChoice() {
  console.log('tts provider respects an existing choice');
  const sandbox = makeSandbox();
  installFakeApp(sandbox, {
    displayType: 'pageflip',
    provider: 'bing',
    storedTtsSetting: '{"provider":"bing","rate":1.5,"bing":{}}',
  });
  sandbox.ttsEngine = { createProvider() {} };
  sandbox.window.ttsEngine = sandbox.ttsEngine;
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(400);
  check('stored provider untouched', sandbox.app.tts.setting.provider === 'bing');
  check('ios still offered in engineList', sandbox.app.tts.engineList()[0].value === 'ios');
}

async function testReaderDefaults() {
  console.log('reader display type');
  const untouched = makeSandbox();
  installFakeApp(untouched, { displayType: 'auto' });
  vm.runInContext(loadBlocks().join('\n'), untouched);
  await tick(400);
  check('untouched display_type becomes pageflip', untouched.app.config._reader.display_type === 'pageflip');

  const chosen = makeSandbox();
  installFakeApp(chosen, { displayType: 'simulatedpageflip' });
  vm.runInContext(loadBlocks().join('\n'), chosen);
  await tick(400);
  check('an explicit choice is preserved', chosen.app.config._reader.display_type === 'simulatedpageflip');
}

async function testDiagPanel() {
  console.log('diagnostics panel');
  const sandbox = makeSandbox();
  installFakeApp(sandbox, { displayType: 'auto' });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(300);
  const diag = sandbox.window.__stvDiag;
  check('__stvDiag installed', !!diag);
  check('badge appended to body', sandbox.document.body.children.length > 0);
  const badge = sandbox.document.body.children[0];
  check(
    'badge stays hidden while nothing has errored',
    badge.style.display === 'none',
    `display=${badge.style.display} (the reader turns pages by tapping the right third of the screen)`
  );
  diag.log('Http', 'GET /x -> 200');
  diag.log('ERR', 'boom');
  const text = diag.text();
  check('lines are buffered', text.includes('GET /x -> 200') && text.includes('boom'));
  check('badge shows the line count', badge.textContent === String(diag.lines().length));
  check('badge reveals itself on the first error', badge.style.display === 'block');
  check('copy() returns the buffer', diag.copy() === text);
  diag.hide();
  diag.show();
  check('show/hide are safe', true);
}

async function testI18nOverlay() {
  console.log('i18n overlay');
  const sandbox = makeSandbox();
  installFakeApp(sandbox, { displayType: 'auto' });

  const settings = makeContainer('div', 'settingitem');
  const label = makeContainer('div', 'settingitemtitle', 'Thêm name 1 nhấp');
  settings.appendChild(label);
  sandbox.document.body.appendChild(settings);

  // Chapter body and comments hold user data and must survive untouched.
  const chapter = makeContainer('div', 'chaptercontent');
  chapter.appendChild(makeContainer('p', '', 'Hủy'));
  sandbox.document.body.appendChild(chapter);
  const comment = makeContainer('div', 'comment', 'Khác');
  sandbox.document.body.appendChild(comment);

  // An interpolated message the site builds by concatenation.
  const toast = makeContainer('div', 'toast', 'Đã dừng đọc sau 5 phút');
  sandbox.document.body.appendChild(toast);

  const input = makeElement('input');
  input.setAttribute('placeholder', 'Tiêu đề');
  sandbox.document.body.appendChild(input);

  // The reader header chapter title. The site only ever sends a Vietnamese
  // machine translation, so all we can fix is the "Chương <n>:" scaffolding.
  const header = makeContainer('div', 'chaptertopinfo');
  const chapterName = makeContainer('div', 'chaptername', 'Chương 1:. Uống thuốc');
  header.appendChild(chapterName);
  sandbox.document.body.appendChild(header);
  const plainName = makeContainer('div', 'chaptername', 'Chương');
  sandbox.document.body.appendChild(plainName);

  // The pinned name at the top of the chapter page is a different element and
  // lives inside the reader's same-origin srcdoc iframe, which is why the first
  // version of this fix never reached it.
  const pinned = makeContainer('div', 'chapternamefixed', 'Chương 03:. Giao phong');
  const frameLabel = makeContainer('div', 'settingitemtitle', 'Thêm name 1 nhấp');
  const frame = makeFakeFrame([pinned, frameLabel]);
  sandbox.document.body.appendChild(frame);

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(60);

  check('dictionary loaded', sandbox.window.__stvI18n && sandbox.window.__stvI18n.size > 300,
    `size=${sandbox.window.__stvI18n && sandbox.window.__stvI18n.size}`);
  check('settings label translated', label.childNodes[0].nodeValue === '一键添加译名',
    JSON.stringify(label.childNodes[0].nodeValue));
  check('chapter body untouched', chapter.childNodes[0].childNodes[0].nodeValue === 'Hủy',
    JSON.stringify(chapter.childNodes[0].childNodes[0].nodeValue));
  check('comment untouched', comment.childNodes[0].nodeValue === 'Khác',
    JSON.stringify(comment.childNodes[0].nodeValue));
  check('concatenated message translated', toast.childNodes[0].nodeValue.indexOf('分钟') >= 0,
    JSON.stringify(toast.childNodes[0].nodeValue));
  check('placeholder attribute translated', input.getAttribute('placeholder') === '标题',
    JSON.stringify(input.getAttribute('placeholder')));
  check('chapter title numbering translated', chapterName.textContent === '第1章 Uống thuốc',
    JSON.stringify(chapterName.textContent));
  check('title without a number is left alone', plainName.textContent === 'Chương',
    JSON.stringify(plainName.textContent));
  check('chapter title pass is idempotent',
    sandbox.window.__stvI18n.fixChapterTitle('第1章 Uống thuốc') === '第1章 Uống thuốc',
    JSON.stringify(sandbox.window.__stvI18n.fixChapterTitle('第1章 Uống thuốc')));
  // The fanqie host uses a different scaffold: "Thứ 2 chương <title>".
  check('fanqie chapter numbering translated',
    sandbox.window.__stvI18n.fixChapterTitle('Thứ 2 chương Ngọc Long linh tuyền không gian')
      === '第2章 Ngọc Long linh tuyền không gian',
    JSON.stringify(sandbox.window.__stvI18n.fixChapterTitle('Thứ 2 chương Ngọc Long linh tuyền không gian')));
  check('unrelated Vietnamese is left alone',
    sandbox.window.__stvI18n.fixChapterTitle('Thứ tự chương') === 'Thứ tự chương',
    JSON.stringify(sandbox.window.__stvI18n.fixChapterTitle('Thứ tự chương')));
  check('zero-padded chapter numbers are normalised',
    sandbox.window.__stvI18n.fixChapterTitle('Chương 03:. Giao phong') === '第3章 Giao phong',
    JSON.stringify(sandbox.window.__stvI18n.fixChapterTitle('Chương 03:. Giao phong')));
  check('the pinned name inside the reader iframe is translated',
    pinned.textContent === '第3章 Giao phong', JSON.stringify(pinned.textContent));
  check('only the title pass runs inside the iframe',
    frameLabel.textContent === 'Thêm name 1 nhấp', JSON.stringify(frameLabel.textContent));

  // Assigning srcdoc navigates the iframe and swaps its document out, so the
  // observer has to be re-armed on the new one or the pinned name stops being
  // translated after the first chapter change.
  const repinned = makeContainer('div', 'chapternamefixed', 'Chương 12: Nhập môn');
  const replacement = makeFakeFrame([repinned]);
  frame.contentDocument = replacement.contentDocument;
  frame.contentWindow = replacement.contentWindow;
  sandbox.window.__stvI18n.sweepFrames();
  check('a re-navigated iframe document is picked up again',
    repinned.textContent === '第12章 Nhập môn', JSON.stringify(repinned.textContent));

  // Translating the title element alone makes the site's own
  // `oldName != name` guard in updateFixedChapterName() true forever, which
  // re-runs its recycle + updateHistory2 branch on every scroll tick. The name
  // is translated where it is produced instead, so the comparison stays equal.
  const source = await sandbox.app.reader.getContent('qidian', '1', '2');
  check('the chapter name is translated at its source',
    source.chaptername === '第3章 Giao phong', JSON.stringify(source.chaptername));
  const again = await sandbox.app.reader.getContent('qidian', '1', '2');
  check('the source translation is idempotent so the recycle guard stays quiet',
    again.chaptername === source.chaptername, JSON.stringify(again.chaptername));

  // The chapter NAME the reader receives is Vietnamese even when the body is
  // Chinese; the chapter LIST carries the original under `oridata`
  // (app.v2.js:270). Join them by cid.
  const titled = makeSandbox();
  installFakeApp(titled, {
    displayType: 'auto',
    oridata: '1-/-865875696-/- 交锋-//-1-/-855899892-/- 弱点',
  });
  vm.runInContext(loadBlocks().join('\n'), titled);
  await tick(250);
  const first = await titled.app.reader.getContent('qidian', '1', '865875696');
  check('the chapter number is translated even before the list arrives',
    first.chaptername === '第3章 Giao phong', JSON.stringify(first.chaptername));
  await tick(300);
  const second = await titled.app.reader.getContent('qidian', '1', '865875696');
  check('the original Chinese chapter name is joined in from the chapter list',
    second.chaptername === '第3章 交锋', JSON.stringify(second.chaptername));
  const diagText = titled.window.__stvDiag.text ? titled.window.__stvDiag.text() : '';
  check('the original-name lookup is reported',
    String(diagText).indexOf('original chapter names') >= 0, String(diagText).slice(-200));

  const noOriginal = makeSandbox();
  installFakeApp(noOriginal, { displayType: 'auto' });
  vm.runInContext(loadBlocks().join('\n'), noOriginal);
  await tick(250);
  const plain = await noOriginal.app.reader.getContent('qidian', '1', '9');
  check('without oridata the Vietnamese title is left alone',
    plain.chaptername === '第3章 Giao phong', JSON.stringify(plain.chaptername));
  const noOriginalDiag = noOriginal.window.__stvDiag.text
    ? noOriginal.window.__stvDiag.text() : '';
  check('a list without original names is reported as such',
    String(noOriginalDiag).indexOf('no original chapter names') >= 0,
    String(noOriginalDiag).slice(-200));
}

async function testReaderTts() {
  console.log('reader TTS sentence source');
  const maincontent = makeContainer('div', 'maincontent', '第一句。第二句！第三句？');
  maincontent.id = 'maincontent';
  const frame = makeFakeFrame([maincontent]);
  const display = {
    innerWindow: frame.contentWindow,
    getCurrentWindow() { return frame.contentWindow; },
    tokenizeSentence() { throw new Error('speaker is undefined'); },
  };
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, { displayType: 'pageflip', display, ttsSentences: [] });
  sandbox.document.body.appendChild(frame);

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(250);

  let threw = null;
  try { app.tts.start(); } catch (error) { threw = error; }
  await tick(20);
  check('a speaker is installed so getSentences() stops bailing out',
    !!frame.contentWindow.speaker, 'without it the site returns null and shows a toast');
  check('tapping play no longer throws out of the click handler', threw === null,
    threw ? String(threw.message) : 'ok');
  check('the site\'s own tokenizer is used when it works',
    display.tokenizeSentence() .length === 3,
    JSON.stringify(display.tokenizeSentence().map((s) => s.toText())));

  const diag = sandbox.window.__stvDiag.text ? sandbox.window.__stvDiag.text() : '';
  check('the TTS outcome is reported instead of failing silently',
    String(diag).indexOf('reader TTS start') >= 0, String(diag).slice(-200));
  check('the sentence source is reported when it had to be replaced',
    String(diag).indexOf('chapter-text fallback') >= 0, String(diag).slice(-200));

  // A display whose tokenizer returns nothing must still produce sentences.
  const emptyDisplay = {
    innerWindow: frame.contentWindow,
    getCurrentWindow() { return frame.contentWindow; },
    tokenizeSentence() { return []; },
  };
  const emptySandbox = makeSandbox();
  installFakeApp(emptySandbox, { displayType: 'pageflip', display: emptyDisplay });
  emptySandbox.document.body.appendChild(frame);
  vm.runInContext(loadBlocks().join('\n'), emptySandbox);
  await tick(250);
  const produced = emptyDisplay.tokenizeSentence();
  check('an empty sentence list falls back to the chapter text',
    produced.length === 3, JSON.stringify(produced.map((s) => s.toText())));
  check('fallback sentences expose toText so Sentence() never needs the speaker',
    typeof produced[0].toText === 'function');
  // The site's own filter is `text.match(ASCII_WORD)` (app.v2.read.js:2357), so
  // a Chinese sentence is dropped unless it carries a word character. Without
  // the marker the device reported "fallback -> 23 sentence(s)" and then
  // "reader TTS start: sentences=0" on the very next line.
  check('fallback sentences carry the marker the site\'s ASCII filter needs',
    produced[0].toText().indexOf('stv0') === 0, JSON.stringify(produced[0].toText()));
  check('the marker is not part of the sentence text the site would speak',
    produced[0].toText().slice(4) === '第一句。', JSON.stringify(produced[0].toText()));

  // The reader iframe has no #maincontent -- the pageflip template builds only
  // .chaptertopinfo, #mainscroller and #dragbar -- and the scroller holds the
  // previous, current and next chapter side by side. Reading the document reads
  // whichever chapters happen to be mounted, which is how the device ended up
  // playing text that was not the chapter on screen.
  const current = makeContainer('div', 'contentcontainer', '当前章节第一句。当前章节第二句。');
  const view = {
    cdata: { chaptername: 'Chương 1: 开局' },
    q: (selector) => (selector === '.contentcontainer' ? current : null),
  };
  const scoped = {
    innerWindow: frame.contentWindow,
    getCurrentChapter: () => view,
    tokenizeSentence() { return []; },
  };
  const scopedSandbox = makeSandbox();
  installFakeApp(scopedSandbox, { displayType: 'pageflip', display: scoped });
  scopedSandbox.document.body.appendChild(frame);
  vm.runInContext(loadBlocks().join('\n'), scopedSandbox);
  await tick(250);
  const scopedOut = scoped.tokenizeSentence();
  check('the sentence source is the current chapter, not the whole iframe',
    scopedOut.length === 2 && scopedOut[0].toText().slice(4) === '当前章节第一句。',
    JSON.stringify(scopedOut.map((s) => s.toText())));

  // app.tts.test() hardcodes "Xin chào, đây là chuyển văn bản thành giọng nói"
  // (app.v2.read.js:3174).
  const testSandbox = makeSandbox();
  const testApp = installFakeApp(testSandbox, { displayType: 'pageflip' });
  let spoken = '';
  testSandbox.ttsEngine = {
    clearQueue() {},
    requestAudio(text) { spoken = text; },
    onFirstLoad(callback) { callback(); },
  };
  testSandbox.window.ttsEngine = testSandbox.ttsEngine;
  vm.runInContext(loadBlocks().join('\n'), testSandbox);
  await tick(250);
  testApp.tts.test();
  check('the TTS test sentence is Chinese',
    /[\u4e00-\u9fff]/.test(spoken), JSON.stringify(spoken));

  // Nothing in the site stops playback when the reader page goes away.
  const closeSandbox = makeSandbox();
  const closeApp = installFakeApp(closeSandbox, { displayType: 'pageflip' });
  const chapterView = makeContainer('div', '');
  chapterView.id = 'chapterview';
  closeSandbox.document.body.appendChild(chapterView);
  vm.runInContext(loadBlocks().join('\n'), closeSandbox);
  await tick(250);
  closeApp.popPage();
  await tick(600);
  check('the reader-close hook is installed', closeApp.__stvTtsCloseWrapped === true,
    'wrapped=' + String(closeApp.__stvTtsCloseWrapped)
      + ' popPageCalls=' + String(closeSandbox.__stored.popPageCalls));
  check('leaving the reader stops playback',
    (closeSandbox.__stored.ttsStops || 0) === 1,
    'ttsStops=' + String(closeSandbox.__stored.ttsStops)
      + ' popPageCalls=' + String(closeSandbox.__stored.popPageCalls));

  // Popping a page the reader itself pushed (the chapter list) keeps
  // #chapterview mounted and must not stop playback.
  const stillSandbox = makeSandbox();
  const stillApp = installFakeApp(stillSandbox, { displayType: 'pageflip', popKeepsReader: true });
  const stillView = makeContainer('div', '');
  stillView.id = 'chapterview';
  stillSandbox.document.body.appendChild(stillView);
  vm.runInContext(loadBlocks().join('\n'), stillSandbox);
  await tick(250);
  stillApp.popPage();
  await tick(600);
  check('a sub-page pushed from inside the reader does not stop playback',
    (stillSandbox.__stored.ttsStops || 0) === 0,
    'ttsStops=' + String(stillSandbox.__stored.ttsStops));
}

async function testCommentButton() {
  console.log('reader comment button');
  const url = '/mobile/bookinfo.php?hid=1034915599&host=qidian';
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, {
    displayType: 'pageflip',
    readerBookInfo: null,
    bookInfoResponses: { [url]: { book: { id: '1034915599', host: 'qidian', tname: '这些仙子全都不正常！' } } },
  });
  const button = makeContainer('button', 'btncomment');
  const icon = makeContainer('i', 'fas fa-comment');
  button.appendChild(icon);
  sandbox.document.body.appendChild(button);

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(250);

  let stopped = false;
  sandbox.__dispatch('click', {
    target: icon,
    preventDefault() {},
    stopImmediatePropagation() { stopped = true; },
  });
  await tick(50);

  check('the click is intercepted when app.reader.bookinfo is empty', stopped,
    'the site handler would throw on bookinfo.host');
  check('bookinfo is fetched for the open book',
    (sandbox.__stored.cacheLater || []).indexOf(url) >= 0,
    JSON.stringify(sandbox.__stored.cacheLater || []));
  check('comments open with the resolved book',
    JSON.stringify(sandbox.__stored.comments) === JSON.stringify([{ host: 'qidian', id: '1034915599' }]),
    JSON.stringify(sandbox.__stored.comments));

  // When bookinfo is already loaded the site's own handler must stay in charge.
  const ready = makeSandbox();
  installFakeApp(ready, {
    displayType: 'pageflip',
    readerBookInfo: { id: '7', host: 'fanqie' },
  });
  const readyButton = makeContainer('button', 'btncomment');
  ready.document.body.appendChild(readyButton);
  vm.runInContext(loadBlocks().join('\n'), ready);
  await tick(250);
  let readyStopped = false;
  ready.__dispatch('click', {
    target: readyButton,
    preventDefault() {},
    stopImmediatePropagation() { readyStopped = true; },
  });
  check('a loaded bookinfo is left to the site handler', !readyStopped);
}

async function testOfflineBookDetailPage() {
  console.log('downloaded book detail page');
  const url = '/mobile/bookinfo.php?hid=1034915599&host=qidian';
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, {
    displayType: 'pageflip',
    offlineBooks: [{ host: 'qidian', id: '1034915599', key: 'offlineBook_qidian_1034915599' }],
    bookInfoResponses: { [url]: { book: { id: '1034915599', host: 'qidian' } } },
  });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(400);

  // A row rendered for a download that has just started must already have the
  // bookinfo cache filled: populateBookInfo() answers from it and returns []
  // otherwise, and the row's click handler captures that undefined.
  const manager = new app.BookDownloadManager('qidian', '1034915599');
  await manager.render();
  check('the download manager warms the bookinfo cache before rendering its row',
    (sandbox.__stored.renderCache || []).indexOf(url) >= 0,
    JSON.stringify(sandbox.__stored.renderCache || []));

  const rows = await app.offlineBook.getDownloadBooks(0, 20);
  check('the downloaded list warms the cache before building its rows',
    (sandbox.__stored.cacheLater || []).indexOf(url) >= 0,
    JSON.stringify(sandbox.__stored.cacheLater || []));
  check('the warmed cache makes populateBookInfo() find the book',
    rows.length === 1, JSON.stringify(rows));

  // A book downloaded after boot only appears in store.data later.
  const lateUrl = '/mobile/bookinfo.php?hid=999&host=fanqie';
  sandbox.app.offlineBook.store.data.push({ host: 'fanqie', id: '999' });
  await tick(3200);
  check('a book downloaded after boot is warmed by the periodic sweep',
    (sandbox.__stored.cacheLater || []).indexOf(lateUrl) >= 0,
    JSON.stringify(sandbox.__stored.cacheLater || []));

  const before = (sandbox.__stored.cacheLater || []).length;
  await tick(3200);
  check('an already warmed book is not refetched',
    (sandbox.__stored.cacheLater || []).length === before,
    JSON.stringify((sandbox.__stored.cacheLater || []).slice(before)));

  const blank = app.fun.openBookWithData(0, undefined);
  check('a detail page is never pushed without book data', blank === null,
    String(blank));
  check('the user is told why nothing happened',
    (sandbox.__stored.toasts || []).some((t) => t.indexOf('书籍信息缺失') >= 0),
    JSON.stringify(sandbox.__stored.toasts || []));
  check('the site implementation is not reached with undefined data',
    (sandbox.__stored.opened || []).length === 0);

  const book = { id: '1034915599', host: 'qidian' };
  app.fun.openBookWithData(0, book);
  check('a real book still opens the detail page',
    (sandbox.__stored.opened || []).length === 1, JSON.stringify(sandbox.__stored.opened || []));

  // DownloadManager.start() fires three requests at once with no spacing, and
  // the endpoint rate limits: the device log shows 200s for the first eighteen
  // chapters and then nothing but 429s, which JSON.parse turns into
  // "Lỗi: Không thể đọc dữ liệu".
  const throttled = new app.BookDownloadManager('qidian', '999');
  await Promise.all([throttled.downloadChapter('a'), throttled.downloadChapter('b')]);
  const starts = sandbox.__stored.downloadStarts || [];
  check('download requests are spaced out instead of fired in a burst',
    starts.length === 2 && starts[1] - starts[0] >= 800,
    JSON.stringify(starts));

  const row = await throttled.render();
  const bar = row.children[0];
  const buttons = bar ? bar.children.filter((child) => child.tagName === 'BUTTON') : [];
  check('the download row gets its own pause and delete buttons',
    buttons.length === 2 && buttons[0].textContent === '暂停下载'
      && buttons[1].textContent === '删除任务',
    JSON.stringify(buttons.map((b) => b.textContent)));
  const clickEvent = { stopPropagation() {}, preventDefault() {} };
  buttons[0].__fire('click', clickEvent);
  check('the pause button pauses the task', throttled.isPaused === true);
  buttons[0].__fire('click', clickEvent);
  check('the same button resumes it',
    throttled.isPaused === false && (sandbox.__stored.resumes || 0) === 1,
    'resumes=' + String(sandbox.__stored.resumes));
  buttons[1].__fire('click', clickEvent);
  check('the delete button drops the task',
    app.bookDownloaderList.indexOf(throttled) < 0,
    'still in the list: ' + String(app.bookDownloaderList.length));
  check('the deleted row is removed from the page', !row.parentElement);
}

async function testChapterNamePlace() {
  console.log('static chapter name place');
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, { displayType: 'pageflip' });
  // The pinned name lives in the reader iframe's own document.
  const info = makeContainer('div', 'chaptertopinfo');
  info.style.display = 'none'; // what the 不显示 option left behind
  app.reader.getDisplay = () => ({ innerWindow: { q: () => [info] } });
  app.config.reader.chapter_name_fixed_place = 'top';
  app.reader.behaviour = {
    chapter_name_fixed_place: {
      apply() {
        // The site only ever rewrites top/bottom here -- never display.
        info.style.top = 'unset';
        info.style.bottom = 'unset';
      },
    },
  };

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(400);
  check('the display:none left by the 不显示 option is cleared',
    info.style.display !== 'none', String(info.style.display));
  check('the chosen side is applied to the pinned name',
    info.style.top === '0', String(info.style.top));

  app.config.reader.chapter_name_fixed_place = 'none';
  app.reader.behaviour.chapter_name_fixed_place.apply();
  check('choosing 不显示 still hides it', info.style.display === 'none',
    String(info.style.display));

  app.config.reader.chapter_name_fixed_place = 'bottom';
  app.reader.behaviour.chapter_name_fixed_place.apply();
  check('switching back to 底部 brings it back',
    info.style.display !== 'none' && info.style.bottom === '0',
    'display=' + String(info.style.display) + ' bottom=' + String(info.style.bottom));
}

async function testSafeArea() {
  console.log('iOS safe area');
  const sandbox = makeSandbox();
  installFakeApp(sandbox, { displayType: 'auto' });
  const meta = makeElement('meta');
  meta.id = 'metaviewport';
  meta.setAttribute('content', 'width=device-width, initial-scale=1, user-scalable=no');
  sandbox.document.head.appendChild(meta);

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(250);

  const root = sandbox.document.documentElement;
  check('status bar height filled in from the native safe area',
    root.style.getPropertyValue('--status-bar-height') === '62px',
    root.style.getPropertyValue('--status-bar-height'));
  check('bottom safe area filled in',
    root.style.getPropertyValue('--screensafebottom') === '34px',
    root.style.getPropertyValue('--screensafebottom'));
  check('viewport-fit added to the site viewport meta',
    String(meta.getAttribute('content')).includes('viewport-fit=cover'),
    String(meta.getAttribute('content')));
  const style = sandbox.__dom.byId('stv-safe-area');
  check('reader overlay title bar gets status-bar padding',
    !!style && style.textContent.includes('#chapterview .titlebar'),
    'without it the bar renders under the Dynamic Island');
  check('reader option sheet gets bottom padding',
    !!style && style.textContent.includes('#chapterview .coption'));
  // #overlay is `height: var(--vh100)` while #mainview (which owns the main
  // navbar) gets an inline 100vh from the site's own onresize, so a --vh100
  // sample below the real viewport leaves the navbar showing under every page.
  check('the pushed-page overlay is never shorter than the viewport',
    !!style && style.textContent.includes('#overlay{height:max(var(--vh100, 100vh), 100vh) !important;}'),
    'a short --vh100 leaves 首页/搜索/社区/用户 visible under every pushed page');
  check('the overlay rule is skipped while the keyboard is open',
    !!style && style.textContent.includes('body:not([keyboardopen]) #overlay'),
    'the site shrinks the overlay on purpose for the keyboard');
}

async function testSafeAreaRespectsSiteValues() {
  console.log('iOS safe area keeps values the site already set');
  const sandbox = makeSandbox();
  installFakeApp(sandbox, { displayType: 'auto' });
  const root = sandbox.document.documentElement;
  root.style.setProperty('--status-bar-height', '59px');
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(250);
  check('an existing status bar height is not overwritten',
    root.style.getPropertyValue('--status-bar-height') === '59px',
    root.style.getPropertyValue('--status-bar-height'));
  check('a missing bottom inset is still filled in',
    root.style.getPropertyValue('--screensafebottom') === '34px',
    root.style.getPropertyValue('--screensafebottom'));
}

async function testSettingsBackup() {
  console.log('settings backup across reinstalls');

  // The reinstall case: the app data container is gone, so the site's store has
  // nothing and the keychain is the only surviving copy.
  const restore = makeSandbox();
  installFakeApp(restore, {
    displayType: 'auto',
    keychain: {
      'config.reader': '{"display_type":"pageflip","show_title":false}',
      'reader.style.fontsize': '22px',
      'some.other.key': 'not-a-setting',
    },
  });
  vm.runInContext(loadBlocks().join('\n'), restore);
  await tick(250);
  check('keychain value is restored into the site\'s own store',
    restore.localStorage.getItem('config.reader') === '{"display_type":"pageflip","show_title":false}',
    String(restore.localStorage.getItem('config.reader')));
  check('the restore goes through app.storage.set, not localStorage directly',
    restore.__stored['config.reader'] === '{"display_type":"pageflip","show_title":false}',
    String(restore.__stored['config.reader']));
  check('dynamic reader.style.* keys are restored too',
    restore.localStorage.getItem('reader.style.fontsize') === '22px',
    String(restore.localStorage.getItem('reader.style.fontsize')));
  check('an unrelated keychain key is ignored',
    restore.localStorage.getItem('some.other.key') === null);

  const existing = makeSandbox();
  installFakeApp(existing, { displayType: 'auto', keychain: { 'config.reader': '{"a":1}' } });
  existing.localStorage.setItem('config.reader', '{"b":2}');
  vm.runInContext(loadBlocks().join('\n'), existing);
  await tick(250);
  check('an existing stored value wins over the backup',
    existing.localStorage.getItem('config.reader') === '{"b":2}',
    String(existing.localStorage.getItem('config.reader')));

  const write = makeSandbox();
  const app = installFakeApp(write, { displayType: 'auto' });
  vm.runInContext(loadBlocks().join('\n'), write);
  await tick(250);
  await app.storage.set('config.reader', '{"display_type":"pageflip"}');
  await tick(50);
  check('writes are mirrored to the keychain',
    write.__keychain['config.reader'] === '{"display_type":"pageflip"}',
    String(write.__keychain['config.reader']));
  await app.storage.set('chaptercache.1', 'x');
  await tick(50);
  check('a cached chapter is not mirrored', write.__keychain['chaptercache.1'] === undefined);
}

async function testBookmarkToggle() {
  console.log('bookmark cancel');
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, { displayType: 'auto', bookmarkRemoval: 'removebookmark' });
  const button = makeContainer('button', 'btnbookmark active');
  sandbox.document.body.appendChild(button);
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(250);

  await app.api.bookmark({ id: '42', host: 'fanqie' });
  await tick(50);
  const actions = sandbox.__posts.map((p) => String(p.body).split('&')[0].replace('ajax=', ''));
  check('probing stops at the first action answering code 100',
    actions.join(',') === 'unbookmark,removebookmark',
    actions.join(',') || '(no probe was sent)');
  check('the button stops showing as bookmarked', !button.classList.contains('active'));
  check('the add path is not used while cancelling', !sandbox.__stored.bookmarkAdds);

  const add = makeSandbox();
  const addApp = installFakeApp(add, { displayType: 'auto' });
  vm.runInContext(loadBlocks().join('\n'), add);
  await tick(250);
  await addApp.api.bookmark({ id: '42', host: 'fanqie' });
  await tick(50);
  check('a book that is not bookmarked still goes through addbookmark',
    add.__stored.bookmarkAdds === 1);
  check('no removal probe without an active bookmark', add.__posts.length === 0);
}

(async () => {
  await testCompatAndTtsProvider();
  await testTtsProviderRespectsStoredChoice();
  await testReaderDefaults();
await testChapterNamePlace();
  await testDiagPanel();
  await testI18nOverlay();
  await testSafeArea();
  await testSafeAreaRespectsSiteValues();
  await testSettingsBackup();
  await testBookmarkToggle();
  await testReaderTts();
  await testCommentButton();
  await testOfflineBookDetailPage();
  console.log('');
  if (failures > 0) {
    console.error(`::error::${failures} site-patch assertion(s) failed`);
    process.exit(1);
  }
  console.log('✓ site-patch behaviour verified');
  // The injected blocks arm long safety timers (180s) that would otherwise keep
  // the event loop alive.
  process.exit(0);
})();
