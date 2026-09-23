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
    // The comment-translation block builds its own controls and inserts them
    // ahead of the site's, so the stub has to support both.
    insertBefore(child, reference) {
      const index = reference ? this.children.indexOf(reference) : -1;
      child.parentNode = this;
      if (index < 0) { this.children.push(child); } else { this.children.splice(index, 0, child); }
      this.childNodes = this.children;
      return child;
    },
    remove() {
      if (this.parentNode) { this.parentNode.removeChild(this); }
    },
    removeAttribute(name) {
      delete this.attributes[name];
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
    querySelector(selector) {
      const found = this.querySelectorAll(selector);
      return found.length ? found[0] : null;
    },
    querySelectorAll(selector) {
      // Supports the shapes the injected blocks actually use: comma-separated
      // selectors, compound class selectors (`.flex2.f-3-col`), bare tag and #id
      // selectors, each optionally carrying a `[attr]` presence test.
      const matchers = String(selector)
        .split(',')
        .map((part) => part.trim())
        .filter(Boolean)
        .map((part) => {
          const attrMatch = /\[([^\]]+)\]/.exec(part);
          let attr = null;
          if (attrMatch) {
            // Presence (`[hasedit]`) and equality (`[view=commentblock]`) both
            // appear in the injected blocks.
            const raw = attrMatch[1];
            const eq = raw.indexOf('=');
            attr = eq < 0
              ? { name: raw, value: null }
              : { name: raw.slice(0, eq), value: raw.slice(eq + 1).replace(/^["']|["']$/g, '') };
            part = part.replace(/\[[^\]]*\]/, '');
          }
          const matcher = { attr: attr, cls: [], id: null, tag: null };
          if (part.charAt(0) === '.') {
            matcher.cls = part.split('.').filter(Boolean);
          } else if (part.charAt(0) === '#') {
            matcher.id = part.slice(1);
          } else {
            matcher.tag = part.toUpperCase();
          }
          return matcher;
        });
      const found = [];
      const visit = (node) => {
        for (const child of node.children) {
          if (child.nodeType !== 1) { continue; }
          const names = String(child.className || '').split(/\s+/);
          for (const matcher of matchers) {
            let hit = matcher.cls.length
              ? matcher.cls.every((name) => names.indexOf(name) >= 0)
              : true;
            if (hit && matcher.id) { hit = child.id === matcher.id; }
            if (hit && matcher.tag) { hit = child.tagName === matcher.tag; }
            if (hit && matcher.attr) {
              const attrs = child.attributes || {};
              if (!Object.prototype.hasOwnProperty.call(attrs, matcher.attr.name)) {
                hit = false;
              } else if (matcher.attr.value !== null
                && String(attrs[matcher.attr.name]) !== matcher.attr.value) {
                hit = false;
              }
            }
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

  Object.defineProperty(element, 'firstChild', {
    get() {
      return element.children.length ? element.children[0] : null;
    },
  });

  // innerText mirrors textContent: the comment-translation block reads a
  // comment through it first and falls back to textContent.
  Object.defineProperty(element, 'innerText', {
    get() {
      return element.textContent;
    },
  });

  // A deliberately shallow innerHTML: setting it replaces the children with a
  // raw string (which is all the translation block needs for its restore path),
  // and reading it returns that string, or the serialized children.
  let rawHtml = null;
  Object.defineProperty(element, 'innerHTML', {
    get() {
      if (rawHtml !== null) { return rawHtml; }
      let out = '';
      for (const child of element.children) {
        out += child.nodeType === 3 ? (child.nodeValue || '') : (child.outerHTML || child.textContent || '');
      }
      return out;
    },
    set(value) {
      rawHtml = value === undefined || value === null ? '' : String(value);
      detached = '';
      element.children.length = 0;
      element.childNodes = element.children;
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
      rawHtml = null;
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
    querySelector: (selector) => documentElement.querySelectorAll(selector)[0] || null,
    querySelectorAll: (selector) => documentElement.querySelectorAll(selector),
    styleSheets: [],
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
    // The mirror-failover block reads the origin of the URL bestDomain()
    // returned.
    URL: globalThis.URL,
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
  // Minimal MutationObserver: it records the observed node and the callback so a
  // test can flush it by hand. Only the comment-translation block uses one, and
  // it is how a comment that arrives after the first render gets decorated.
  const observers = [];
  sandbox.MutationObserver = class {
    constructor(callback) {
      this.callback = callback;
      this.nodes = [];
      observers.push(this);
    }
    observe(node) { this.nodes.push(node); }
    disconnect() {}
  };
  sandbox.__flushObservers = () => {
    for (const observer of observers) { observer.callback(); }
  };
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
  // Chapter requests the fake holds open, so a test can keep the download loop in
  // flight and then release it. `releaseChapters(true)` also lets every later
  // request through, because the gate spaces the next batch ~900ms out.
  const pendingChapters = [];
  let autoRelease = false;

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
    // The comment-translation block reads app.language to pick the default
    // reading target, and wraps pushPage to decorate the pages it opens.
    language: options.appLanguage || 'vi',
    pushPage(name) {
      stored.pushed = (stored.pushed || []).concat([name]);
      const page = (options.pages || {})[name];
      if (!page) { return null; }
      // The real app.pushPage() returns the page ELEMENT, with q()/qq() mixed
      // into Element.prototype by /stv.ui.js -- not a wrapper object. The
      // translation block walks up from a comment embed to that element, so the
      // stub has to be an element too.
      page.q = (selector) => page.querySelector(selector);
      page.qq = (selector) => page.querySelectorAll(selector);
      return page;
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
    store: {
      data: options.offlineBooks || [],
      save() {
        stored.storeSaves = (stored.storeSaves || 0) + 1;
        return Promise.resolve();
      },
    },
    getNewBook(bookInfo) {
      stored.newBooks = (stored.newBooks || []).concat([bookInfo]);
      return Promise.resolve({ host: bookInfo.host, id: bookInfo.id });
    },
    getExistedBook(obj) {
      stored.existedLookups = (stored.existedLookups || []).concat([obj.host + '/' + obj.id]);
      return options.existedBook || null;
    },
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
    constructor(host, id, chapters) {
      this.host = host;
      this.id = id;
      this.isPaused = false;
      // The range the caller asked for, so a test can see what was sliced.
      this.chapters = chapters || ['c1', 'c2'];
      this.chaptersOrginal = this.chapters.slice();
      this.downloaded = 0;
      this.total = this.chapters.length;
      app.bookDownloaderList.push(this);
    }
    render() {
      stored.renderCache = (stored.cacheLater || []).slice();
      stored.renderCalls = (stored.renderCalls || 0) + 1;
      const build = () => {
        // The real row is `<div class="bookrowcont"><div class="bookrow">` with
        // the title in `.tname` (view-bookdownloadjob); the failover/guard code
        // reads `.tname` to tell a row that got book data from one that did not.
        const node = makeContainer('div', 'bookrowcont');
        const row = makeContainer('div', 'bookrow');
        const right = makeContainer('div', 'right');
        const title = makeContainer('div', 'tname', options.rowTitle || '');
        right.appendChild(title);
        right.appendChild(makeContainer('div', 'status'));
        const pbar = makeContainer('div', 'pgbar');
        pbar.appendChild(makeContainer('div', 'pgbarinner'));
        right.appendChild(pbar);
        row.appendChild(right);
        node.appendChild(row);
        this.node = node;
        this.status = right.children[1];
        this.progress = pbar.children[0];
        return node;
      };
      // render() is async in the site and sets this.node after an await, so two
      // callers can both clear its `if (this.node)` guard. slowRender makes the
      // stub yield the same way instead of resolving in one microtask.
      if (options.slowRender) {
        return new Promise((resolve) => {
          sandbox.setTimeout(() => { resolve(build()); }, options.slowRender);
        });
      }
      return Promise.resolve(build());
    }
    downloadChapter(chapter) {
      stored.downloadStarts = (stored.downloadStarts || []).concat([Date.now()]);
      stored.chapterCalls = (stored.chapterCalls || 0) + 1;
      stored.chapters = (stored.chapters || []).concat([chapter]);
      if (options.downloadFails) { return Promise.reject(new Error('Không thể đọc dữ liệu')); }
      // Fail the first N attempts at a chapter, so the shim's retry/backoff is
      // observable (the site's own downloadChapter would give up and start() would
      // then abandon every remaining chapter).
      if (options.failFirst) {
        const seen = stored.failCounts || (stored.failCounts = {});
        seen[chapter] = (seen[chapter] || 0) + 1;
        if (seen[chapter] <= options.failFirst) {
          return Promise.reject(new Error('Không thể đọc dữ liệu'));
        }
      }
      // The download loop lives in the shim now, so a test that needs the loop to
      // stay in flight holds the chapter requests open instead of the old start().
      if (options.slowChapter && !autoRelease) {
        return new Promise((resolve) => { pendingChapters.push(resolve); });
      }
      return Promise.resolve(chapter);
    }
    pause() { this.isPaused = true; }
    start() {
      this.isPaused = false;
      stored.resumes = (stored.resumes || 0) + 1;
      return undefined;
    }
  }
  app.BookDownloadManager = FakeDownloadManager;
  stored.releaseChapters = (all) => {
    if (all) { autoRelease = true; }
    while (pendingChapters.length) { pendingChapters.shift()(); }
  };

  // The site's mirror picker (app.v2.js:890). Only installed when a test asks
  // for it, because the failover block wraps bestDomain()/getContent().
  if (options.networkManager) {
    const mirrors = options.networkManager;
    app.net.networkManager = {
      domains: mirrors.domains.map((entry) => Object.assign({}, entry)),
      defaultDomains: mirrors.defaultDomains,
      bestDomain() {
        stored.bestDomainCalls = (stored.bestDomainCalls || 0) + 1;
        const alive = this.domains.filter((entry) => entry.status === 'alive');
        if (!alive.length) { return this.defaultDomains[0]; }
        return alive.slice().sort((a, b) => (a.ping || 0) - (b.ping || 0))[0].name;
      },
    };
  }

  // The history view (app.v2.js:3178-3217): setContainer() builds the grid through
  // infbookgrid and appends the flex container the shim tags.
  app.history = {
    container: null,
    setContainer() {
      const wrapper = makeContainer('div', 'historywrapper');
      wrapper.appendChild(
        makeContainer('div', 'flex2 g0 fleft f-3-col f-sm-4-col f-md-6-col'));
      this.container.appendChild(wrapper);
      return wrapper;
    },
  };
  // The inventory's last pane is filled from app.items.inv.activate (app.v2.js:7760).
  app.items = { inv: { activate: options.activate || [] } };

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
        // Apple's Translation framework, reached through the always-present
        // selectors. Defaults model an iOS 18+ device with the pack installed.
        translationStatus(payload) {
          (stored.translationStatus || (stored.translationStatus = [])).push(payload);
          return Promise.resolve(options.appleStatus || { status: 'installed', ready: true });
        },
        translationPrepare(payload) {
          (stored.translationPrepare || (stored.translationPrepare = [])).push(payload);
          return Promise.resolve(options.appleStatus || { status: 'installed', ready: true });
        },
        translationTranslate(payload) {
          (stored.translationTranslate || (stored.translationTranslate = [])).push(payload);
          if (options.appleTranslate) { return options.appleTranslate(payload); }
          return Promise.resolve({
            translations: payload.texts.map((text) => '【系统】' + text),
          });
        },
      },
      // Every network engine goes through the native Http plugin, because a
      // page-level fetch to those hosts is blocked by CORS.
      Http: {
        request(payload) {
          (stored.http || (stored.http = [])).push(payload);
          if (options.httpResponse) {
            return Promise.resolve(options.httpResponse(String(payload.url), payload));
          }
          return Promise.reject(new Error('no Http stub for ' + payload.url));
        },
      },
    },
  };
  // The site's Preferences branch (app.v2.js:534-546). Installed only when a test
  // asks for it: modelling it replaces app.storage.get with the site's own
  // (broken) expression, which changes what every other block reads.
  if (options.preferences) {
    const prefStore = Object.assign({}, options.preferences.store || {});
    sandbox.Capacitor.Plugins.Preferences = {
      get(args) {
        if (options.preferences.rejectGet) {
          return Promise.reject(new Error('Preferences unavailable'));
        }
        const has = Object.prototype.hasOwnProperty.call(prefStore, args.key);
        return Promise.resolve({ value: has ? prefStore[args.key] : null });
      },
      set(args) {
        prefStore[args.key] = args.value;
        return Promise.resolve();
      },
      keys() {
        return Promise.resolve({ keys: Object.keys(prefStore) });
      },
    };
    stored.prefStore = prefStore;
    // Verbatim from app.v2.js:536-546, including `.value` applied to the Promise
    // instead of to its result.
    app.storage.get = async function (key) {
      return await sandbox.Capacitor.Plugins.Preferences.get({ key: key }).value;
    };
    app.storage.set = async function (key, value) {
      return await sandbox.Capacitor.Plugins.Preferences.set({ key: key, value: value });
    };
  }
  sandbox.window.Capacitor = sandbox.Capacitor;
  return app;
}

function tick(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Wait for a condition, because the download gate spaces request starts out. */
async function waitFor(predicate, timeout = 8000) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    if (predicate()) { return true; }
    await tick(50);
  }
  return predicate();
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

async function testBootShell() {
  console.log('first-paint shell');
  const sandbox = makeSandbox();
  installFakeApp(sandbox, { displayType: 'auto' });
  vm.runInContext(loadBlocks().join('\n'), sandbox);

  const root = sandbox.document.documentElement;
  check('the boot shell class is applied at document start',
    String(root.className).indexOf('stv-boot') >= 0, String(root.className));
  const style = sandbox.__dom.byId('stv-boot-css');
  check('the boot stylesheet is injected',
    !!style && style.textContent.indexOf('#mainnavbar') >= 0,
    'without it the tabs are unstyled text for the whole boot');
  check('a loading hint is shown', !!sandbox.__dom.byId('stv-boot-hint'));

  // The site's own stylesheet is the signal that boot is over.
  sandbox.document.styleSheets.push({ href: 'https://sangtacviet.app/asset/app.v2.css?v=4' });
  await tick(1200);
  check('the shell is released once the site stylesheet is in play',
    String(root.className).indexOf('stv-boot') < 0, String(root.className));
  check('the loading hint is removed', !sandbox.__dom.byId('stv-boot-hint'));
  const diag = sandbox.window.__stvDiag.text ? sandbox.window.__stvDiag.text() : '';
  check('the boot timeline is reported',
    String(diag).indexOf('[BOOT]') >= 0 && String(diag).indexOf('shell released') >= 0,
    String(diag).slice(-200));
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
  check('a book with a live download job is not in the downloaded list yet',
    rows.length === 0, JSON.stringify(rows));

  // Drop the job, as a finished download does, and the same read finds the book.
  app.bookDownloaderList.length = 0;
  const settled = await app.offlineBook.getDownloadBooks(0, 20);
  check('the warmed cache makes populateBookInfo() find the book',
    settled.length === 1, JSON.stringify(settled));

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
  const buttons = row.querySelectorAll('button');
  const bar = buttons.length ? buttons[0].parentNode : null;
  check('the download row gets its own pause and delete buttons',
    buttons.length === 2 && buttons[0].textContent === '暂停下载'
      && buttons[1].textContent === '删除任务',
    JSON.stringify(buttons.map((b) => b.textContent)));
  const clickEvent = { stopPropagation() {}, preventDefault() {} };
  buttons[0].__fire('click', clickEvent);
  check('the pause button pauses the task', throttled.isPaused === true);
  const callsBeforeResume = sandbox.__stored.chapterCalls || 0;
  buttons[0].__fire('click', clickEvent);
  await waitFor(() => (sandbox.__stored.chapterCalls || 0) > callsBeforeResume, 4000);
  check('the same button resumes it',
    throttled.isPaused === false
      && (sandbox.__stored.chapterCalls || 0) > callsBeforeResume,
    'paused=' + String(throttled.isPaused) + ' calls=' + String(sandbox.__stored.chapterCalls));
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

async function testDomainFailover() {
  console.log('readchapter mirror failover');
  const bad = 'https://dns1.stv-appdomain-00000001.org';
  const good = 'https://sangtacviet.com';
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, {
    displayType: 'pageflip',
    networkManager: {
      domains: [
        { name: bad, status: 'alive', ping: 100 },
        { name: good, status: 'alive', ping: 400 },
      ],
      defaultDomains: [good, bad, 'https://sangtacviet.app'],
    },
  });
  // The device log: the mirror that wins the ping race answers every chapter
  // with {"code":7,"time":1000} while the slower one serves it fine.
  const served = [];
  app.reader.cachekey = 'qidian-1';
  app.reader.getContent = function () {
    const domain = app.net.networkManager.bestDomain();
    served.push(domain);
    return Promise.resolve(domain === bad
      ? { code: 7, time: 1000 }
      : { code: 0, data: 'chapter' });
  };

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(300);

  check('the site mirror picker is wrapped',
    app.net.networkManager.__stvFailoverInstalled === true);
  check('the fastest mirror is the one the site would use',
    app.net.networkManager.domains.slice().sort((a, b) => a.ping - b.ping)[0].name === bad);

  const data = await app.reader.getContent('qidian', '1', 'c1');
  check('the chapter is returned instead of the code-7 alert',
    !!data && String(data.code) === '0', JSON.stringify(data));
  check('the rejected mirror was retried on the next one',
    served.length === 2 && served[0] === bad && served[1] === good, JSON.stringify(served));
  check('the rejected mirror is never picked again',
    app.net.networkManager.bestDomain() === good, app.net.networkManager.bestDomain());
  check('the chapter key issued by the rejected mirror is dropped',
    app.reader.cachekey === null, String(app.reader.cachekey));
  const diag = sandbox.window.__stvDiag.text();
  check('the failover is reported in the panel',
    diag.indexOf('mirror ' + bad + ' banned') >= 0, diag.slice(-300));

  served.length = 0;
  const second = await app.reader.getContent('qidian', '1', 'c2');
  check('later chapters go straight to the working mirror',
    String(second.code) === '0' && served.length === 1 && served[0] === good,
    JSON.stringify(served));

  // Two bad mirrors in front of a good one: the retry walks past both in a
  // single read instead of handing the first code 7 back to the site.
  const third = 'https://sangtacviet.app';
  const chain = makeSandbox();
  const chainApp = installFakeApp(chain, {
    displayType: 'pageflip',
    networkManager: {
      domains: [
        { name: bad, status: 'alive', ping: 10 },
        { name: third, status: 'alive', ping: 20 },
        { name: good, status: 'alive', ping: 30 },
      ],
      defaultDomains: [good, bad, third],
    },
  });
  const chainServed = [];
  chainApp.reader.getContent = function () {
    const domain = chainApp.net.networkManager.bestDomain();
    chainServed.push(domain);
    return Promise.resolve(domain === good ? { code: 0, data: 'chapter' } : { code: 7 });
  };
  vm.runInContext(loadBlocks().join('\n'), chain);
  await tick(300);
  const walked = await chainApp.reader.getContent('qidian', '1', 'c1');
  check('every rejecting mirror is walked past in one read',
    String(walked.code) === '0' && chainServed.length === 3
      && chainServed[2] === good, JSON.stringify(chainServed));

  // Nothing left to fail over to: the site's own alert has to stay possible.
  const dead = makeSandbox();
  const deadApp = installFakeApp(dead, {
    displayType: 'pageflip',
    networkManager: {
      domains: [{ name: bad, status: 'alive', ping: 10 }],
      defaultDomains: [bad],
    },
  });
  deadApp.reader.getContent = () => Promise.resolve({ code: 7 });
  vm.runInContext(loadBlocks().join('\n'), dead);
  await tick(300);
  const stuck = await deadApp.reader.getContent('qidian', '1', 'c1');
  check('a code 7 with no alternative mirror is passed through untouched',
    !!stuck && String(stuck.code) === '7', JSON.stringify(stuck));
}

async function testDownloadRowControls() {
  console.log('download row controls and missing book info');
  const url = '/mobile/bookinfo.php?hid=1034915599&host=qidian';
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, {
    displayType: 'pageflip',
    bookInfoResponses: {
      [url]: { book: { id: '1034915599', host: 'qidian', name: '这些仙子全都不正常！' } },
    },
  });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(300);

  const manager = new app.BookDownloadManager('qidian', '1034915599');
  const row = await manager.render();
  const title = row.querySelector('.tname');
  const bar = row.__stvBar;

  check('the control bar clears the 77px the absolute row occupies',
    !!bar && String(bar.getAttribute('style')).indexOf('margin-top:77px') >= 0,
    bar ? String(bar.getAttribute('style')) : 'no bar');
  check('the control bar is lifted above the absolutely positioned .bookrow',
    !!bar && String(bar.getAttribute('style')).indexOf('position:relative') >= 0
      && String(bar.getAttribute('style')).indexOf('z-index:5') >= 0,
    bar ? String(bar.getAttribute('style')) : 'no bar');
  check('the fixed-height row container grows to fit the controls',
    row.style.height === 'auto' && row.style.minHeight === '77px',
    JSON.stringify({ h: row.style.height, min: row.style.minHeight }));
  check('the row carries the book it belongs to',
    row.getAttribute('data-stv-host') === 'qidian'
      && row.getAttribute('data-stv-id') === '1034915599',
    String(row.getAttribute('data-stv-host')) + '/' + String(row.getAttribute('data-stv-id')));
  check('an empty .tname marks a row the site rendered without book data',
    title.textContent === '', JSON.stringify(title.textContent));

  const buttons = row.querySelectorAll('button');
  const event = () => ({ stopPropagation() {}, preventDefault() {} });

  // Tapping the row body used to reach openBookWithData(0, undefined) and be
  // refused with 书籍信息缺失.
  sandbox.__dispatch('click', Object.assign({ target: title }, event()));
  await tick(50);
  const opened = sandbox.__stored.opened || [];
  check('tapping a row with no book data still opens the book',
    opened.length === 1 && !!opened[0].data && opened[0].data.id === '1034915599',
    JSON.stringify(opened));
  check('the tap is not turned into the 书籍信息缺失 toast',
    !(sandbox.__stored.toasts || []).some((t) => t.indexOf('书籍信息缺失') >= 0),
    JSON.stringify(sandbox.__stored.toasts || []));

  const beforeButtons = (sandbox.__stored.opened || []).length;
  sandbox.__dispatch('click', Object.assign({ target: buttons[0] }, event()));
  await tick(20);
  check('the capture listener leaves the control bar alone',
    (sandbox.__stored.opened || []).length === beforeButtons,
    JSON.stringify(sandbox.__stored.opened || []));
  buttons[0].__fire('click', event());
  check('the pause button still pauses the task', manager.isPaused === true);

  // A row the site did fill in keeps the site's own behaviour.
  const filled = makeSandbox();
  const filledApp = installFakeApp(filled, {
    displayType: 'pageflip',
    rowTitle: '这些仙子全都不正常！',
    bookInfoResponses: { [url]: { book: { id: '1034915599', host: 'qidian' } } },
  });
  vm.runInContext(loadBlocks().join('\n'), filled);
  await tick(300);
  const filledManager = new filledApp.BookDownloadManager('qidian', '1034915599');
  const filledRow = await filledManager.render();
  filled.__dispatch('click', Object.assign({ target: filledRow.querySelector('.tname') }, event()));
  await tick(30);
  check('a row the site filled in is left to the site',
    (filled.__stored.opened || []).length === 0,
    JSON.stringify(filled.__stored.opened || []));
}

async function testStorageAccessor() {
  console.log('site storage accessor');
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, {
    displayType: 'auto',
    preferences: { store: { 'config.reader': '{"display_type":"pageflip"}' } },
  });
  // Before the shim: the site's own accessor, verbatim from app.v2.js:536.
  const before = await app.storage.get('config.reader');
  check('the site accessor loses the value (the bug being repaired)',
    before === undefined, String(before));

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(250);

  check('the accessor is replaced', app.storage.__stvGetFixed === true);
  check('the repair is reported',
    String(sandbox.window.__stvDiag.text() || '').indexOf('app.storage.get reads') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-200));
  const after = await app.storage.get('config.reader');
  check('the repaired accessor returns the stored value',
    after === '{"display_type":"pageflip"}', String(after));
  const missing = await app.storage.get('never-written');
  check('an unset key reads as null, not a crash', missing === null, String(missing));
  await app.storage.set('written', 'yes');
  check('set keeps working', (await app.storage.get('written')) === 'yes');

  // A backend that rejects must read as "nothing stored", not break the caller.
  const broken = makeSandbox();
  const brokenApp = installFakeApp(broken, {
    displayType: 'auto',
    preferences: { rejectGet: true },
  });
  vm.runInContext(loadBlocks().join('\n'), broken);
  await tick(250);
  const rejected = await brokenApp.storage.get('config.reader');
  check('a rejecting Preferences read resolves to undefined', rejected === undefined,
    String(rejected));

  // The point of the repair: a store the site can read means the keychain backup
  // no longer has to overwrite anything.
  const survivor = makeSandbox();
  installFakeApp(survivor, {
    displayType: 'auto',
    preferences: { store: { 'config.reader': '{"display_type":"pageflip"}' } },
    keychain: { 'config.reader': '{"display_type":"auto","show_title":true}' },
  });
  vm.runInContext(loadBlocks().join('\n'), survivor);
  await tick(250);
  const survivorDiag = String(survivor.window.__stvDiag.text() || '');
  check('a readable store wins over the keychain backup',
    survivor.__stored.prefStore['config.reader'] === '{"display_type":"pageflip"}',
    String(survivor.__stored.prefStore['config.reader']));
  check('the restore reports the value as kept, not written',
    survivorDiag.indexOf('0 written, 1 kept') >= 0, survivorDiag.slice(-260));
}

async function testDownloadRange() {
  console.log('download range dialog');
  const chapters = [];
  for (let i = 1; i <= 30; i += 1) { chapters.push({ cid: 'c' + i }); }
  const sandbox = makeSandbox();
  sandbox.getChapterList = async () => chapters;
  // Hold the chapter requests open so the job stays in the list: a completed job
  // is moved to the DOWNLOADED list and dropped from bookDownloaderList.
  const app = installFakeApp(sandbox, { displayType: 'auto', slowChapter: true });
  // The site's dialog: 起始章 + 章数 (count), the count hard-coded to 20 upstream.
  app.context = {
    menu: {
      downloadchapter: {
        body: 'Nhập số chương để tải:<br>'
          + '<input class="bookid" type="hidden"/>'
          + '<input class="bookhost" type="hidden"/>'
          + '<input class="numstart" type="text" placeholder="Bắt đầu từ" />'
          + '<input class="total" type="text" placeholder="Số chương" />',
        action: {
          startdownload: async function () { sandbox.__stored.siteStart = true; },
          cancel: function () {},
        },
      },
    },
    showPopup(template) {
      sandbox.__stored.popup = template;
      return makeContainer('div', 'popupedit');
    },
  };
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(400);

  const menu = app.context.menu.downloadchapter;
  check('the dialog is patched', menu.__stvRangePatched === true);
  check('the second field is an end chapter, not a count',
    menu.body.indexOf('numend') >= 0 && menu.body.indexOf('class="total"') < 0,
    menu.body);

  // The action must slice on the end chapter: 1..10 of 30, not 1..(1+10).
  const inputs = {
    '.bookhost': { value: 'qidian' },
    '.bookid': { value: '1034915599' },
    '.numstart': { value: '1' },
    '.numend': { value: '10' },
  };
  const popup = { q: (sel) => inputs[sel] || null };
  await menu.action.startdownload.call({ cancel() {} }, popup);
  await tick(30);
  const job = app.bookDownloaderList[app.bookDownloaderList.length - 1];
  check('the job covers exactly the requested range',
    job && job.chaptersOrginal.length === 10
      && job.chaptersOrginal[0] === 'c1' && job.chaptersOrginal[9] === 'c10',
    JSON.stringify(job && job.chaptersOrginal));
  check('the site action is not used', sandbox.__stored.siteStart === undefined);
  check('the range is reported',
    String(sandbox.window.__stvDiag.text() || '').indexOf('range 1-10 of 30') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-200));

  // An end past the last chapter clamps to the book's length. The first job is
  // dropped first: a second start for a book that is still downloading is now
  // ignored on purpose, and this assertion is about the slice, not that guard.
  app.bookDownloaderList.length = 0;
  inputs['.numstart'].value = '25';
  inputs['.numend'].value = '999';
  await menu.action.startdownload.call({ cancel() {} }, popup);
  await tick(30);
  const tail = app.bookDownloaderList[app.bookDownloaderList.length - 1];
  check('an end past the last chapter clamps',
    tail && tail.chaptersOrginal.length === 6 && tail.chaptersOrginal[5] === 'c30',
    JSON.stringify(tail && tail.chaptersOrginal));

  // The dialog defaults to the whole book, not to "where I stopped + 20".
  // showPopup() is the seam: it returns the popup element, and the site's
  // showDownloadBook() sets numstart = reading position + 1 and total = 20 before
  // calling it. A fresh sandbox keeps this independent of the run above.
  const popupNode = makeContainer('div', 'popupedit');
  const startInput = makeElement('input');
  const endInput = makeElement('input');
  startInput.className = 'numstart';
  endInput.className = 'numend';
  startInput.value = '4';
  popupNode.appendChild(startInput);
  popupNode.appendChild(endInput);

  const fresh = makeSandbox();
  fresh.getChapterList = async () => chapters;
  const freshApp = installFakeApp(fresh, { displayType: 'auto' });
  freshApp.context = {
    menu: {
      downloadchapter: {
        body: '<input class="numstart" /><input class="numend" />',
        action: { startdownload: async function () {}, cancel: function () {} },
      },
    },
    showPopup: (template) => popupNode,
  };
  vm.runInContext(loadBlocks().join('\n'), fresh);
  await tick(400);
  freshApp.context.showPopup(freshApp.context.menu.downloadchapter, { chaptercount: 30 });
  check('the dialog defaults to 1 .. the latest chapter',
    startInput.value === '1' && endInput.value === '30',
    startInput.value + '..' + endInput.value);
  check('the defaulting is reported',
    String(fresh.window.__stvDiag.text() || '').indexOf('defaulted to 1-30') >= 0,
    String(fresh.window.__stvDiag.text() || '').slice(-200));
}

async function testDownloadLifecycle() {
  console.log('download task lifecycle');
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, { displayType: 'auto', slowChapter: true });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(300);

  // The download loop belongs to the shim now, so the loop is held in flight by
  // holding its chapter requests open. The gate spaces request starts 900ms apart,
  // so every step is waited for rather than assumed.
  const manager = new app.BookDownloadManager('qidian', '1034915599',
    ['c1', 'c2', 'c3', 'c4', 'c5']);
  const first = manager.start();
  await waitFor(() => (sandbox.__stored.chapterCalls || 0) === 3);
  check('the loop runs three chapters at a time',
    (sandbox.__stored.chapterCalls || 0) === 3, String(sandbox.__stored.chapterCalls));
  const again = manager.start();
  check('a second start() while one is running is ignored',
    (sandbox.__stored.chapterCalls || 0) === 3, String(sandbox.__stored.chapterCalls));
  check('the ignored start is reported',
    String(sandbox.window.__stvDiag.text() || '').indexOf('start() ignored') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-200));
  sandbox.__stored.releaseChapters(true);
  await waitFor(() => (sandbox.__stored.chapterCalls || 0) === 5);
  await Promise.all([first, again]);
  check('a repeat start() is not replayed after the loop exits',
    (sandbox.__stored.chapterCalls || 0) === 5, String(sandbox.__stored.chapterCalls));
  check('every chapter of the range is fetched exactly once',
    (sandbox.__stored.chapters || []).length === 5
      && (sandbox.__stored.chapters || []).join(',') === 'c1,c2,c3,c4,c5',
    JSON.stringify(sandbox.__stored.chapters));

  // A resume that arrives while the paused loop is still winding down is replayed
  // once the loop exits, so the chapters the pause left behind are still fetched.
  const resumed = new app.BookDownloadManager('qidian', '2', ['d1', 'd2', 'd3', 'd4', 'd5']);
  const running = resumed.start();
  await waitFor(() => (sandbox.__stored.chapterCalls || 0) === 8);
  const afterFirstBatch = sandbox.__stored.chapterCalls || 0;
  resumed.pause();
  const deferred = resumed.start();
  check('a resume during the running loop is deferred, not doubled',
    (sandbox.__stored.chapterCalls || 0) === afterFirstBatch,
    String(sandbox.__stored.chapterCalls));
  sandbox.__stored.releaseChapters();
  await waitFor(() => (sandbox.__stored.chapterCalls || 0) === afterFirstBatch + 2);
  await Promise.all([running, deferred]);
  check('the deferred resume replays and fetches the rest',
    (sandbox.__stored.chapterCalls || 0) === afterFirstBatch + 2,
    String(sandbox.__stored.chapterCalls));
  sandbox.__stored.releaseChapters(true);
  await tick(60);

  // Deleting a task has to redraw the DOWNLOADING (n) counter.
  const deleting = new app.BookDownloadManager('qidian', '3');
  const row = await deleting.render();
  let updates = 0;
  app.bookDownloaderList.onUpdate = function () { updates += 1; };
  const buttons = row.querySelectorAll('button');
  buttons[1].__fire('click', { stopPropagation() {}, preventDefault() {} });
  check('deleting a task drops it from the list',
    app.bookDownloaderList.indexOf(deleting) < 0);
  check('deleting a task refreshes the list counter', updates === 1, String(updates));
}

async function testGridLayout() {
  console.log('grid tap targets');
  const sandbox = makeSandbox();
  installFakeApp(sandbox, { displayType: 'auto' });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(120);
  const style = sandbox.document.getElementById('stv-grid-layout');
  check('the grid stylesheet is injected', !!style);
  const css = style ? String(style.textContent || '') : '';
  check('cells stop stretching to the tallest card',
    css.indexOf('align-items: flex-start') >= 0, css);
  check('the forced cell height is overridden',
    css.indexOf('.booksquarecont { height: auto !important; }') >= 0, css);
  check('titles are clamped so rows stay even',
    css.indexOf('-webkit-line-clamp: 2') >= 0, css);
  check('rows no longer stretch to fill the container',
    css.indexOf('align-content: flex-start') >= 0, css);
  check('the history grid uses auto-fill columns like the bookmark tab',
    css.indexOf('grid-template-columns: repeat(auto-fill, minmax(100px, 1fr))') >= 0, css);
  check('the fixed 33.33% column cap is lifted for grid items',
    css.indexOf('.stv-bookgrid4 > * { max-width: none !important; }') >= 0, css);

  // app.history.setContainer builds the history grid, so wrapping it is how the
  // CSS above is scoped to the history tab alone.
  const app = sandbox.app;
  app.history.container = makeContainer('div', 'bookhistory');
  sandbox.document.body.appendChild(app.history.container);
  app.history.setContainer();
  const grid = app.history.container.children[0].children[0];
  check('the history grid is tagged for the auto-fill rule',
    grid.classList.contains('stv-bookgrid4'), String(grid.className));
  check('the tagging is reported',
    String(sandbox.window.__stvDiag.text() || '').indexOf('history grid switched') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-200));
}

async function testTabProbe() {
  console.log('inventory tab probe');
  const sandbox = makeSandbox();
  installFakeApp(sandbox, { displayType: 'auto' });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(120);

  // <tab><tabbar><tabitem/>…<tabpointermark/><tabdiv><tabview/>…</tabdiv></tab>
  const tab = makeContainer('tab');
  const tabbar = makeContainer('tabbar');
  const first = makeContainer('tabitem', '', 'Đan dược');
  const last = makeContainer('tabitem', '', 'Đang kích hoạt');
  first.offsetLeft = 0; first.offsetWidth = 60;
  last.offsetLeft = 60; last.offsetWidth = 90;
  tabbar.appendChild(first);
  tabbar.appendChild(last);
  const mark = makeContainer('tabpointermark');
  mark.style.width = '85px';
  mark.style.transform = 'translateX(0px)';
  const div = makeContainer('tabdiv');
  div.style.transform = 'translateX(0px)';
  const view1 = makeContainer('tabview');
  view1.appendChild(makeContainer('div'));
  const view2 = makeContainer('tabview'); // the empty last pane
  div.appendChild(view1);
  div.appendChild(view2);
  tab.appendChild(tabbar);
  tab.appendChild(mark);
  tab.appendChild(div);
  sandbox.document.body.appendChild(tab);

  sandbox.app.items.inv.activate = [{ i: 1 }, { i: 2 }];
  sandbox.__dispatch('click', { target: last });
  await tick(500);
  const lines = String(sandbox.window.__stvDiag.text() || '')
    .split('\n').filter((line) => line.indexOf('TAB') >= 0);
  const before = lines.find((line) => line.indexOf('before') >= 0) || '';
  const after = lines.find((line) => line.indexOf('after') >= 0) || '';
  check('the tapped tab index and item geometry are reported',
    before.indexOf('index=1/2') >= 0 && before.indexOf('0+60 60+90') >= 0, before);
  check('the pointer mark is reported',
    before.indexOf('mark=85px translateX(0px)') >= 0, before);
  check('the pane transform is reported', before.indexOf('div=translateX(0px)') >= 0, before);
  check('the last pane child count is reported (blank-pane check)',
    before.indexOf('views=2 lastview=0 child(ren)') >= 0, before);
  check('every pane child count is reported, so the tapped one is covered',
    before.indexOf('panes=[0:1 1:0]') >= 0, before);
  check('the inventory activate list length is reported',
    before.indexOf('activate=2') >= 0, before);
  check('the state after the framework reacts is reported too',
    after.indexOf('after') >= 0 && after.indexOf('index=1/2') >= 0, after);
}

async function testDownloadSources() {
  console.log('download source picker');
  const sandbox = makeSandbox();
  sandbox.getChapterList = async () => [{ cid: 't1' }, { cid: 't2' }];
  const app = installFakeApp(sandbox, { displayType: 'auto', slowChapter: true });
  const mirrors = {
    code: 400,
    data: [
      { host: 'qidian', id: '1034915599', chaptercount: '310' },
      { host: 'trxs', id: '11728', chaptercount: '253' },
    ],
  };
  app.net.get = (url) => {
    sandbox.__stored.netGets = (sandbox.__stored.netGets || []).concat([url]);
    return Promise.resolve(url.indexOf('getallhost') >= 0 ? mirrors : null);
  };

  const popupNode = makeContainer('div', 'popupedit');
  popupNode.setAttribute('hasedit', 'true');
  popupNode.q = (selector) => popupNode.querySelector(selector);
  const hostInput = makeElement('input');
  const idInput = makeElement('input');
  const startInput = makeElement('input');
  const endInput = makeElement('input');
  const select = makeElement('select');
  hostInput.className = 'bookhost';
  hostInput.value = 'qidian';
  idInput.className = 'bookid';
  idInput.value = '1034915599';
  startInput.className = 'numstart';
  endInput.className = 'numend';
  select.className = 'dlsource';
  [hostInput, idInput, startInput, endInput, select]
    .forEach((node) => popupNode.appendChild(node));

  app.context = {
    menu: {
      downloadchapter: {
        body: '<input class="numstart"/><input class="numend"/>'
          + '<select class="dlsource"></select>',
        action: {
          startdownload: async function () { sandbox.__stored.siteStart = true; },
          cancel() {},
        },
      },
    },
    showPopup: () => popupNode,
  };

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(400);
  app.context.showPopup(app.context.menu.downloadchapter, {
    host: 'qidian', id: '1034915599', name: '这些仙子全都不正常！', author: '作者', chaptercount: 310,
  });
  await tick(80);

  const options = select.children.filter((child) => child.tagName === 'OPTION');
  check('every mirror of the book is offered',
    options.length === 2 && options[0].value === 'qidian|1034915599'
      && options[1].value === 'trxs|11728',
    JSON.stringify(options.map((option) => option.value)));
  check('the mirror the detail page opened is preselected', select.selectedIndex === 0,
    String(select.selectedIndex));
  check('the source list is reported',
    String(sandbox.window.__stvDiag.text() || '').indexOf('sources: 2 [qidian trxs]') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-260));

  select.value = 'trxs|11728';
  select.__fire('change', {});
  check('choosing a mirror retargets the end chapter', endInput.value === '253',
    String(endInput.value));

  await app.context.menu.downloadchapter.action.startdownload.call({ cancel() {} }, popupNode);
  await tick(60);
  const job = app.bookDownloaderList[app.bookDownloaderList.length - 1];
  check('the chosen mirror is what gets downloaded',
    !!job && job.host === 'trxs' && job.id === '11728',
    job ? job.host + '/' + job.id : 'no job');
  check('the site action is not used', sandbox.__stored.siteStart === undefined);
}

async function testDownloadCompletion() {
  console.log('a finished download moves to DOWNLOADED');
  const url = '/mobile/bookinfo.php?hid=1034915599&host=qidian';
  const sandbox = makeSandbox();
  const deleted = [];
  const app = installFakeApp(sandbox, {
    displayType: 'auto',
    bookInfoResponses: {
      [url]: { book: { host: 'qidian', id: '1034915599', lid: '3972206', chaptercount: '310' } },
    },
    existedBook: {
      deleteAll() { deleted.push('deleteAll'); return Promise.resolve(); },
      delete() { deleted.push('delete'); return Promise.resolve(); },
    },
  });
  // The DOWNLOADED area is #download-manager's parent (page-vip:4041-4075).
  const page = makeContainer('div', 'bookdownloaded');
  const manager = makeContainer('div', 'bookdownloadmanager');
  const area = makeContainer('div', 'download-manager');
  area.id = 'download-manager';
  manager.appendChild(area);
  page.appendChild(manager);
  sandbox.document.body.appendChild(page);
  const rendered = [];
  // The site's row loader is app.celoader (page-vip:3610), not app.celldisplay.
  // The stub used to expose the misspelled name, so the test agreed with a patch
  // that never installed on the device.
  app.celoader = {
    bookdownloadedrow(ele, data) {
      rendered.push(data);
      return makeContainer('div', 'bookdownloadedrow');
    },
  };

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(400);
  check('the downloaded-row renderer is wrapped', app.celoader.__stvRowPatched === true);
  check('a row renderer under the misspelled name is not required',
    app.celldisplay === undefined);

  const job = new app.BookDownloadManager('qidian', '1034915599', ['c1', 'c2']);
  let updates = 0;
  app.bookDownloaderList.onUpdate = function () { updates += 1; };
  await job.start();
  await waitFor(() => rendered.length === 1, 5000);

  check('a finished job leaves the DOWNLOADING list',
    app.bookDownloaderList.indexOf(job) < 0);
  check('the DOWNLOADING counter is refreshed', updates >= 1, String(updates));
  check('the finished book is appended to the DOWNLOADED list',
    rendered.length === 1 && rendered[0].id === '1034915599'
      && rendered[0].totalDownloaded === 2,
    JSON.stringify(rendered));
  check('the move is reported',
    String(sandbox.window.__stvDiag.text() || '').indexOf('moved qidian/1034915599') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-260));

  // The row is appended to #download-manager's parent, i.e. after the
  // "DOWNLOADED" header inside the manager wrapper (page-vip:2292-2298).
  const row = manager.children[manager.children.length - 1];
  const buttons = row.querySelectorAll('button');
  check('the downloaded row gets a delete button',
    buttons.length === 1 && buttons[0].textContent === '删除',
    JSON.stringify(buttons.map((button) => button.textContent)));
  buttons[0].__fire('click', { stopPropagation() {}, preventDefault() {} });
  await waitFor(() => deleted.indexOf('delete') >= 0, 3000);
  check('deleting removes the chapter bodies and then the record',
    deleted.join(',') === 'deleteAll,delete', deleted.join(','));
  check('the record list is saved', (sandbox.__stored.storeSaves || 0) >= 1,
    String(sandbox.__stored.storeSaves));
  check('the row is removed from the page', row.parentElement === null);
  check('the delete is reported',
    String(sandbox.window.__stvDiag.text() || '')
      .indexOf('removed downloaded book qidian/1034915599') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-260));
}

async function testDownloadRenderRace() {
  console.log('one job renders one row even when two updates overlap');
  const url = '/mobile/bookinfo.php?hid=1034915599&host=qidian';
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, {
    displayType: 'pageflip',
    // The site's render() yields before it sets this.node, so two callers can
    // both clear its `if (this.node)` guard.
    slowRender: 25,
    bookInfoResponses: {
      [url]: { book: { id: '1034915599', host: 'qidian', name: '这些仙子全都不正常！' } },
    },
  });
  const container = makeContainer('div', 'download-manager');
  container.id = 'download-manager';
  sandbox.document.body.appendChild(container);

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(300);

  new app.BookDownloadManager('qidian', '1034915599', ['c1']);
  // The site's own onUpdate (app.v2.read.js:3428-3444), verbatim.
  app.bookDownloaderList.onUpdate = async function (n) {
    const target = n || container;
    for (let i = 0; i < this.length; i++) {
      const node = await this[i].render();
      if (node.parentElement === target || node.parentNode === target) { continue; }
      target.appendChild(node);
    }
  };

  await Promise.all([
    app.bookDownloaderList.onUpdate(),
    app.bookDownloaderList.onUpdate(),
  ]);
  await tick(60);

  const rows = container.children.filter((child) => child.className === 'bookrowcont');
  check('two overlapping updates leave exactly one row',
    rows.length === 1, String(rows.length));
  check('the overlapping callers share one render',
    (sandbox.__stored.renderCalls || 0) === 1,
    String(sandbox.__stored.renderCalls));
}

async function testDownloadedListHidesRunningJobs() {
  console.log('a running download is not listed as DOWNLOADED');
  const running = { host: 'qidian', id: '1034915599' };
  const idle = { host: 'qidian', id: '999' };
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, {
    displayType: 'pageflip',
    offlineBooks: [running, idle],
    bookInfoResponses: {
      '/mobile/bookinfo.php?hid=1034915599&host=qidian':
        { book: { id: '1034915599', host: 'qidian', name: 'running' } },
      '/mobile/bookinfo.php?hid=999&host=qidian':
        { book: { id: '999', host: 'qidian', name: 'idle' } },
    },
  });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(300);

  const job = new app.BookDownloadManager('qidian', '1034915599', ['c1', 'c2']);
  const listed = await app.offlineBook.getDownloadBooks(0, 20);
  check('the book whose job is still running is filtered out of the list',
    listed.length === 1 && listed[0].id === '999',
    JSON.stringify(listed.map((book) => book.id)));
  check('the store record itself is kept, so offline reading still resolves',
    app.offlineBook.store.data.length === 2,
    String(app.offlineBook.store.data.length));

  job.pause();
  const paused = await app.offlineBook.getDownloadBooks(0, 20);
  check('a paused job no longer hides its partially downloaded book',
    paused.length === 2, JSON.stringify(paused.map((book) => book.id)));

  job.isPaused = false;
  job.downloaded = 2;
  const finished = await app.offlineBook.getDownloadBooks(0, 20);
  check('a completed job no longer hides its book either',
    finished.length === 2, JSON.stringify(finished.map((book) => book.id)));
  check('the store is put back after every read',
    app.offlineBook.store.data.length === 2,
    String(app.offlineBook.store.data.length));
}

async function testDuplicateDownloadStart() {
  console.log('a second start for a running book is ignored');
  const sandbox = makeSandbox();
  sandbox.getChapterList = async () => [{ cid: 't1' }, { cid: 't2' }];
  const app = installFakeApp(sandbox, { displayType: 'auto', slowChapter: true });

  const popupNode = makeContainer('div', 'popupedit');
  popupNode.q = (selector) => popupNode.querySelector(selector);
  const hostInput = makeElement('input');
  const idInput = makeElement('input');
  const startInput = makeElement('input');
  const endInput = makeElement('input');
  hostInput.className = 'bookhost';
  hostInput.value = 'qidian';
  idInput.className = 'bookid';
  idInput.value = '1034915599';
  startInput.className = 'numstart';
  startInput.value = '1';
  endInput.className = 'numend';
  endInput.value = '2';
  [hostInput, idInput, startInput, endInput].forEach((node) => popupNode.appendChild(node));

  app.context = {
    menu: {
      downloadchapter: {
        body: '<input class="numstart"/><input class="numend"/>',
        action: {
          startdownload: async function () { sandbox.__stored.siteStart = true; },
          cancel() {},
        },
      },
    },
    showPopup: () => popupNode,
  };

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(400);

  const action = app.context.menu.downloadchapter.action.startdownload;
  await action.call({ cancel() {} }, popupNode);
  await tick(60);
  check('the first start creates one job', app.bookDownloaderList.length === 1,
    String(app.bookDownloaderList.length));

  await action.call({ cancel() {} }, popupNode);
  await tick(60);
  check('a second start while that job is live adds no second job',
    app.bookDownloaderList.length === 1, String(app.bookDownloaderList.length));
  check('the ignored start is reported',
    String(sandbox.window.__stvDiag.text() || '').indexOf('already running') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-260));

  app.bookDownloaderList[0].pause();
  await action.call({ cancel() {} }, popupNode);
  await tick(60);
  check('a paused job does not block a fresh start',
    app.bookDownloaderList.length === 2, String(app.bookDownloaderList.length));
}

async function testChapterRetry() {
  console.log('a failing chapter is retried instead of abandoning the job');
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, {
    displayType: 'auto',
    failFirst: 1,
    bookInfoResponses: {
      '/mobile/bookinfo.php?hid=1&host=qidian': {
        book: { host: 'qidian', id: '1', chaptercount: '1' },
      },
    },
  });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(300);
  const job = new app.BookDownloadManager('qidian', '1', ['c1']);
  await job.start();
  check('the chapter is fetched again after a failure',
    (sandbox.__stored.chapterCalls || 0) === 2, String(sandbox.__stored.chapterCalls));
  check('the retry is reported',
    String(sandbox.window.__stvDiag.text() || '').indexOf('retry 1/3') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-260));
  check('the failure widens the pacing gap',
    String(sandbox.window.__stvDiag.text() || '').indexOf('gap widened to 2500ms') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-320));
  check('the job still completes', job.downloaded === 1 && job.total === 1,
    job.downloaded + '/' + job.total);
  check('the failing chapter did not abandon the job',
    String(sandbox.window.__stvDiag.text() || '').indexOf('gave up') < 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-260));
}

async function testKeyboardPopup() {
  console.log('keyboard vs popup inputs');
  const sandbox = makeSandbox();
  installFakeApp(sandbox, { displayType: 'auto' });
  const viewport = { height: 800, offsetTop: 0, addEventListener() {} };
  sandbox.window.visualViewport = viewport;
  sandbox.window.innerHeight = 800;
  const popup = makeContainer('div', 'popupedit');
  popup.setAttribute('hasedit', 'true');
  const body = makeContainer('div', 'popupedit_body');
  const input = makeElement('input');
  input.className = 'numend';
  body.appendChild(input);
  popup.appendChild(body);
  sandbox.document.body.appendChild(popup);

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(150);
  check('the keyboard shim is installed',
    sandbox.window.__stvKeyboardPopupInstalled === true);
  check('a closed keyboard leaves the site placement alone',
    !popup.style.bottom && !popup.style.transform, String(popup.style.bottom));

  // The keyboard opens: the visual viewport shrinks by 300px.
  viewport.height = 500;
  sandbox.document.activeElement = input;
  sandbox.__dispatch('focusin', { target: input });
  await tick(150);
  check('the popup is anchored just above the keyboard',
    popup.style.bottom === '310px', String(popup.style.bottom));
  check('the site transform is neutralised so it cannot double up',
    popup.style.transform === 'translate(-50%, 0px)', String(popup.style.transform));
  check('the popup is capped to the visible area',
    popup.style.maxHeight === '480px', String(popup.style.maxHeight));
  check('the popup body is capped too',
    body.style.maxHeight === '360px', String(body.style.maxHeight));
  check('the numbers are reported',
    String(sandbox.window.__stvDiag.text() || '').indexOf('kb=300px visible=500px') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-260));

  viewport.height = 800;
  sandbox.__dispatch('focusout', { target: input });
  await tick(150);
  check('hiding the keyboard hands the placement back',
    popup.style.bottom === '' && popup.style.transform === ''
      && popup.style.maxHeight === '',
    JSON.stringify({ bottom: popup.style.bottom, transform: popup.style.transform }));
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
  // app.v2.config.js reads config.reader right after app.v2.js evaluates, which
  // can beat the keychain round trip; the running app has to be corrected too.
  check('the restored values are pushed into the running config',
    restore.__stored.reader === 'pageflip', String(restore.__stored.reader));
  const restoreDiag = restore.window.__stvDiag.text ? restore.window.__stvDiag.text() : '';
  check('the live-config push is reported',
    String(restoreDiag).indexOf('live config updated') >= 0,
    String(restoreDiag).slice(-200));

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

  // The download list lives in the same store under the objectStore key
  // (app.v2.read.js:3189). Losing it loses every downloaded book's row, so it is
  // mirrored and restored alongside the settings.
  const records = '[{"host":"qidian","id":"1034915599","key":"offlineBook_qidian_1034915599"}]';
  const recordsBackup = makeSandbox();
  installFakeApp(recordsBackup, { displayType: 'auto', keychain: { offlineBook: records } });
  vm.runInContext(loadBlocks().join('\n'), recordsBackup);
  await tick(250);
  check('the download record list is restored from the keychain',
    recordsBackup.localStorage.getItem('offlineBook') === records,
    String(recordsBackup.localStorage.getItem('offlineBook')));

  const recordsWrite = makeSandbox();
  const recordsApp = installFakeApp(recordsWrite, { displayType: 'auto' });
  vm.runInContext(loadBlocks().join('\n'), recordsWrite);
  await tick(250);
  await recordsApp.storage.set('offlineBook', records);
  await tick(50);
  check('download records are mirrored as they change',
    recordsWrite.__keychain.offlineBook === records,
    String(recordsWrite.__keychain.offlineBook));

  // "The store is empty" and "the store cannot be read" need different repairs,
  // so they have to be told apart in the log.
  const unreadable = makeSandbox();
  const unreadableApp = installFakeApp(unreadable, {
    displayType: 'auto',
    keychain: { 'config.reader': '{"a":1}' },
  });
  unreadableApp.storage.get = () => Promise.reject(new Error('Preferences unavailable'));
  vm.runInContext(loadBlocks().join('\n'), unreadable);
  await tick(250);
  const unreadableDiag = String(unreadable.window.__stvDiag.text() || '');
  check('a store that cannot be read is reported as unreadable, not empty',
    unreadableDiag.indexOf('1 unreadable') >= 0 && unreadableDiag.indexOf('0 written') >= 0,
    unreadableDiag.slice(-300));

  // A backend that resolves the write and drops the value is the failure this
  // whole block exists to survive, so the write is read back.
  const amnesia = makeSandbox();
  const amnesiaApp = installFakeApp(amnesia, {
    displayType: 'auto',
    keychain: { 'config.reader': '{"a":1}' },
  });
  amnesiaApp.storage.set = () => Promise.resolve();
  vm.runInContext(loadBlocks().join('\n'), amnesia);
  await tick(250);
  const amnesiaDiag = String(amnesia.window.__stvDiag.text() || '');
  check('a write that does not persist is reported',
    amnesiaDiag.indexOf('readback mismatch') >= 0, amnesiaDiag.slice(-300));
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

// ------------------------------------------------------ comment translation

/**
 * The comment page (_page_vip.html:914-941): title bar, the rendered comment
 * list, and the contenteditable the reader types into.
 */
function commentPageFixture(texts) {
  const page = makeContainer('div', 'commentpage');
  const bar = makeContainer('div', 'titlebar');
  const ctx = makeContainer('div', 'rctx');
  ctx.appendChild(makeContainer('button', 'rbtn'));
  bar.appendChild(ctx);
  const view = makeContainer('div', 'commentview');
  for (const text of texts) {
    const block = makeContainer('div', '');
    block.setAttribute('view', 'commentblock');
    const body = makeContainer('div', 'cmtbody');
    body.appendChild(makeContainer('div', 'cmtcontent content', text));
    block.appendChild(body);
    view.appendChild(block);
  }
  const bottom = makeContainer('div', 'bottombar');
  const input = makeContainer('div', 'commentinput shadowinset');
  bottom.appendChild(input);
  page.appendChild(bar);
  page.appendChild(view);
  page.appendChild(bottom);
  return { page, bar, ctx, view, input };
}

function settingsPageFixture() {
  const page = makeContainer('div', '');
  page.appendChild(makeContainer('div', 'titlebar'));
  const content = makeContainer('div', '');
  content.appendChild(makeContainer('div', 'settingsection', 'interface'));
  page.appendChild(content);
  return { page, content };
}

function click(node) {
  node.__fire('click', {
    preventDefault() {},
    stopPropagation() {},
    stopImmediatePropagation() {},
  });
}

/** The Edge translatetext shape: one object per input string. */
function edgeAnswer(texts) {
  return {
    status: 200,
    data: texts.map((text) => ({ translations: [{ text: '【微软】' + text }] })),
  };
}

/**
 * A community board: page-pageposts (_page_vip.html:1087) -- a title bar and a
 * `.posts` list that app.socialpost.channel[].fetch() fills afterwards. Each row
 * is a view-post (:2671) whose text is `.postcontent > .content`.
 */
function communityBoardFixture() {
  const page = makeContainer('div', '');
  const bar = makeContainer('div', 'titlebar');
  const ctx = makeContainer('div', 'rctx');
  bar.appendChild(ctx);
  const posts = makeContainer('div', 'posts');
  page.appendChild(bar);
  page.appendChild(posts);
  const addPost = (text) => {
    const cont = makeContainer('div', 'postcont');
    const post = makeContainer('div', 'post');
    const postcontent = makeContainer('div', 'postcontent');
    postcontent.appendChild(makeContainer('div', 'content', text));
    post.appendChild(postcontent);
    cont.appendChild(post);
    posts.appendChild(cont);
    return cont;
  };
  return { page, bar, ctx, posts, addPost };
}

/**
 * page-pagepost (_page_vip.html:1105): one post body plus an embedcomment
 * (:2892) whose poster is a textarea and a `.finish` button.
 */
function singlePostFixture(text) {
  const page = makeContainer('div', '');
  const bar = makeContainer('div', 'titlebar');
  const ctx = makeContainer('div', 'rctx');
  bar.appendChild(ctx);
  const postcontent = makeContainer('div', 'postcontent');
  postcontent.appendChild(makeContainer('div', 'content', text));
  const embed = makeContainer('div', 'embedcomment');
  const poster = makeContainer('div', 'embed-poster');
  const input = makeElement('textarea');
  input.className = 'comment-input';
  const finish = makeContainer('button', 'finish');
  poster.appendChild(input);
  poster.appendChild(finish);
  embed.appendChild(poster);
  const comments = makeContainer('div', 'comments');
  embed.appendChild(comments);
  page.appendChild(bar);
  page.appendChild(postcontent);
  page.appendChild(embed);
  return { page, bar, ctx, postcontent, embed, poster, input, finish, comments };
}

function addCommentBlock(view, text) {
  const block = makeContainer('div', '');
  block.setAttribute('view', 'commentblock');
  const body = makeContainer('div', 'cmtbody');
  body.appendChild(makeContainer('div', 'cmtcontent content', text));
  block.appendChild(body);
  view.appendChild(block);
  return block;
}

async function testTranslateAllWaitsForTheList() {
  console.log('译全部 waits for the list and opens no popup');
  const fixture = commentPageFixture([]);
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, {
    appLanguage: 'zh',
    pages: { comment: fixture.page },
  });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(250);
  sandbox.document.body.appendChild(fixture.page);
  app.pushPage('comment', {});
  await tick(40);

  // Tapped before the comments have loaded: no popup, no engine call, and the
  // request is armed for the moment the list lands.
  const all = fixture.bar.querySelectorAll('.stv-translate-all')[0];
  click(all);
  await tick(60);
  check('an empty list opens no popup',
    (sandbox.__stored.toasts || []).length === 0,
    JSON.stringify(sandbox.__stored.toasts || []));
  check('an empty list calls no engine',
    (sandbox.__stored.translationTranslate || []).length === 0,
    JSON.stringify(sandbox.__stored.translationTranslate || []));
  check('the button says it is waiting', all.textContent === '等加载…', all.textContent);

  const block = addCommentBlock(fixture.view, 'Bình luận muộn');
  sandbox.__flushObservers();
  await tick(200);

  const calls = sandbox.__stored.translationTranslate || [];
  check('the armed request runs once the comments arrive',
    calls.length === 1
      && JSON.stringify(calls[0].texts) === JSON.stringify(['Bình luận muộn']),
    JSON.stringify(calls));
  check('the late comment is translated',
    block.querySelectorAll('.cmtcontent')[0].textContent === '【系统】Bình luận muộn',
    block.querySelectorAll('.cmtcontent')[0].textContent);
  check('the button goes back to its own label', all.textContent === '译全部', all.textContent);
  check('still no popup anywhere',
    (sandbox.__stored.toasts || []).length === 0,
    JSON.stringify(sandbox.__stored.toasts || []));

  // Pressing it again must not translate the translation, and must not arm a
  // pending request that would fire on the next unrelated mutation.
  const before = calls.length;
  click(all);
  await tick(150);
  sandbox.__flushObservers();
  await tick(120);
  check('pressing 译全部 again sends nothing new',
    (sandbox.__stored.translationTranslate || []).length === before,
    String((sandbox.__stored.translationTranslate || []).length));
  check('the second press leaves the translation and its original alone',
    block.querySelectorAll('.cmtcontent')[0].textContent === '【系统】Bình luận muộn'
      && block.querySelectorAll('.cmtcontent')[0].getAttribute('stv-orig')
        === 'Bình luận muộn',
    block.querySelectorAll('.cmtcontent')[0].textContent + ' / '
      + String(block.querySelectorAll('.cmtcontent')[0].getAttribute('stv-orig')));
  check('the button does not stay on the waiting label',
    all.textContent === '译全部', all.textContent);
}

async function testAutoTranslateWaitsForTheList() {
  console.log('auto-translate waits for the comments to load');
  const fixture = commentPageFixture([]);
  const sandbox = makeSandbox();
  sandbox.localStorage.setItem('stv.translate.settings', JSON.stringify({
    engine: 'apple',
    apiKey: '',
    region: '',
    endpoint: '',
    model: '',
    readSource: 'vi',
    readTarget: 'zh-Hans',
    writeTarget: 'vi',
    auto: true,
  }));
  const app = installFakeApp(sandbox, {
    appLanguage: 'zh',
    pages: { comment: fixture.page },
  });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(250);
  sandbox.document.body.appendChild(fixture.page);
  app.pushPage('comment', {});
  await tick(150);

  check('auto-translate does not run against an empty page',
    (sandbox.__stored.translationTranslate || []).length === 0,
    JSON.stringify(sandbox.__stored.translationTranslate || []));
  check('auto-translate does not report an empty list either',
    (sandbox.__stored.toasts || []).length === 0,
    JSON.stringify(sandbox.__stored.toasts || []));

  addCommentBlock(fixture.view, 'Nhận xét tự động');
  sandbox.__flushObservers();
  await tick(220);
  const calls = sandbox.__stored.translationTranslate || [];
  check('auto-translate runs once the comments arrive',
    calls.length === 1
      && JSON.stringify(calls[0].texts) === JSON.stringify(['Nhận xét tự động']),
    JSON.stringify(calls));

  // A comment pushed in later (the comment channel) is translated too, and the
  // one already translated is not sent a second time.
  addCommentBlock(fixture.view, 'Nhận xét muộn');
  sandbox.__flushObservers();
  await tick(220);
  const later = sandbox.__stored.translationTranslate || [];
  check('auto-translate picks up a comment that arrives later',
    later.length === 2
      && JSON.stringify(later[1].texts) === JSON.stringify(['Nhận xét muộn']),
    JSON.stringify(later));
}

async function testCommunityBoardTranslate() {
  console.log('community boards are translatable');
  const board = communityBoardFixture();
  const single = singlePostFixture('Nội dung bài viết');
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, {
    appLanguage: 'zh',
    pages: { pageposts: board.page, pagepost: single.page },
  });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(250);
  sandbox.document.body.appendChild(board.page);
  sandbox.document.body.appendChild(single.page);

  app.pushPage('pageposts', {});
  await tick(40);
  check('a community board gets the title buttons',
    board.bar.querySelectorAll('.stv-translate-all').length === 1
      && board.bar.querySelectorAll('.stv-translate-settings').length === 1,
    String(board.bar.querySelectorAll('.stv-translate-all').length));

  board.addPost('Bài viết một');
  board.addPost('Bài viết hai');
  sandbox.__flushObservers();
  check('every post on a board gets its own translate button',
    board.posts.querySelectorAll('.stv-translate-one').length === 2,
    String(board.posts.querySelectorAll('.stv-translate-one').length));

  click(board.bar.querySelectorAll('.stv-translate-all')[0]);
  await tick(200);
  const calls = sandbox.__stored.translationTranslate || [];
  check('译全部 translates the post bodies on a board',
    calls.length === 1
      && JSON.stringify(calls[0].texts) === JSON.stringify(['Bài viết một', 'Bài viết hai']),
    calls.length ? JSON.stringify(calls[0].texts) : 'no call');
  const bodies = board.posts.querySelectorAll('.content');
  check('the post bodies show the translation',
    bodies[0].textContent === '【系统】Bài viết một', bodies[0].textContent);
  check('a board report opens no popup',
    (sandbox.__stored.toasts || []).length === 0,
    JSON.stringify(sandbox.__stored.toasts || []));

  // A single post: the body, its comment list and its textarea.
  app.pushPage('pagepost', {});
  await tick(40);
  check('a single post gets the title buttons',
    single.bar.querySelectorAll('.stv-translate-all').length === 1,
    String(single.bar.querySelectorAll('.stv-translate-all').length));
  check('the post body gets its own translate button',
    single.postcontent.querySelectorAll('.stv-translate-one').length === 1,
    String(single.postcontent.querySelectorAll('.stv-translate-one').length));
  check('the post textarea gets a translate button',
    single.poster.querySelectorAll('.stv-translate-input').length === 1,
    String(single.poster.querySelectorAll('.stv-translate-input').length));

  addCommentBlock(single.comments, 'Bình luận bài viết');
  sandbox.__flushObservers();
  check('a post comment gets its own translate button',
    single.comments.querySelectorAll('.stv-translate-one').length === 1,
    String(single.comments.querySelectorAll('.stv-translate-one').length));

  single.input.value = '这是一条帖子评论';
  click(single.poster.querySelectorAll('.stv-translate-input')[0]);
  await tick(200);
  const inputCalls = (sandbox.__stored.translationTranslate || []).slice(1);
  check('translating a post comment reads the textarea value',
    inputCalls.length === 1
      && JSON.stringify(inputCalls[0].texts) === JSON.stringify(['这是一条帖子评论']),
    JSON.stringify(inputCalls));
  check('the translated post comment goes back into the textarea',
    single.input.value === '【系统】这是一条帖子评论', single.input.value);
}

async function testCommentTranslate() {
  console.log('comment translation (system offline engine)');
  const fixture = commentPageFixture(['Bình luận một', 'Bình luận hai']);
  const settingsFixture = settingsPageFixture();
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, {
    appLanguage: 'zh',
    pages: { comment: fixture.page, pagesetting: settingsFixture.page },
    httpResponse: (url, payload) => (
      url.indexOf('edge.microsoft.com') >= 0
        ? edgeAnswer(JSON.parse(payload.data))
        : { status: 500, data: '' }
    ),
  });

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(250);

  // The site appends a pushed page to the document; the panel and the input
  // button label are both found through a document-wide query.
  sandbox.document.body.appendChild(fixture.page);
  sandbox.document.body.appendChild(settingsFixture.page);
  app.pushPage('comment', {});
  await tick(60);

  check('the comment title bar gets a translate-all button',
    fixture.bar.querySelectorAll('.stv-translate-all').length === 1);
  check('the comment title bar gets a settings button',
    fixture.bar.querySelectorAll('.stv-translate-settings').length === 1);
  check("the site's own title button survives",
    fixture.ctx.querySelectorAll('.rbtn').length === 1);
  check('every comment block gets its own translate button',
    fixture.view.querySelectorAll('.stv-translate-one').length === 2,
    String(fixture.view.querySelectorAll('.stv-translate-one').length));

  const inputBar = fixture.input.parentNode.querySelectorAll('.stv-translate-input');
  check('the comment input gets a translate button', inputBar.length === 1);
  check('the input button names the configured write target',
    inputBar.length === 1 && inputBar[0].textContent === '译成越南语',
    inputBar.length ? inputBar[0].textContent : 'missing');

  click(fixture.bar.querySelectorAll('.stv-translate-all')[0]);
  await tick(150);

  const calls = sandbox.__stored.translationTranslate || [];
  check('the offline engine is used first', calls.length === 1,
    'native=' + calls.length + ' http=' + (sandbox.__stored.http || []).length);
  check('the whole visible comment list goes in one request',
    calls.length === 1
      && JSON.stringify(calls[0].texts) === JSON.stringify(['Bình luận một', 'Bình luận hai']),
    calls.length ? JSON.stringify(calls[0].texts) : 'no call');
  check('the reading target follows the app language',
    calls.length === 1 && calls[0].target === 'zh-Hans',
    calls.length ? String(calls[0].target) : 'no call');
  check('the comment source language is the configured one',
    calls.length === 1 && calls[0].source === 'vi',
    calls.length ? String(calls[0].source) : 'no call');

  const contents = fixture.view.querySelectorAll('.cmtcontent');
  check('translated text lands in the comment body',
    contents[0].textContent === '【系统】Bình luận một', contents[0].textContent);
  check('the original is kept for the toggle',
    contents[0].getAttribute('stv-orig') === 'Bình luận một',
    String(contents[0].getAttribute('stv-orig')));

  const one = fixture.view.querySelectorAll('.stv-translate-one');
  click(one[0]);
  await tick(40);
  check('tapping the per-comment button restores the original',
    contents[0].getAttribute('stv-orig') === undefined
      && contents[0].innerHTML === 'Bình luận một',
    String(contents[0].getAttribute('stv-orig')) + ' / ' + contents[0].innerHTML);
  check('the per-comment button flips back to 译', one[0].textContent === '译',
    one[0].textContent);

  // A comment that arrives after the first render (the site pushes new ones
  // over the comment channel) must still get its button.
  const late = makeContainer('div', '');
  late.setAttribute('view', 'commentblock');
  const lateBody = makeContainer('div', 'cmtbody');
  lateBody.appendChild(makeContainer('div', 'cmtcontent content', 'Bình luận muộn'));
  late.appendChild(lateBody);
  fixture.view.appendChild(late);
  sandbox.__flushObservers();
  check('a late comment is decorated too',
    late.querySelectorAll('.stv-translate-one').length === 1);

  fixture.input.textContent = '你好，这是一条测试评论';
  click(inputBar[0]);
  await tick(150);
  const inputCalls = (sandbox.__stored.translationTranslate || []).slice(1);
  check('translating the draft asks for the write target',
    inputCalls.length === 1 && inputCalls[0].target === 'vi',
    JSON.stringify(inputCalls));
  check('translating the draft auto-detects the source',
    inputCalls.length === 1 && inputCalls[0].source === undefined,
    JSON.stringify(inputCalls[0]));
  check('the translated draft replaces what the reader typed',
    fixture.input.innerHTML === '【系统】你好，这是一条测试评论',
    fixture.input.innerHTML);

  app.pushPage('pagesetting', {});
  await tick(40);
  const entry = settingsFixture.content.querySelectorAll('.stv-translate-entry');
  check('a 翻译 entry is added to 设置', entry.length === 1);
  click(entry[0]);
  await tick(60);

  const panel = sandbox.document.getElementById('stv-translate-panel');
  check('the translation panel opens', !!panel);
  if (!panel) { return; }

  const pickers = panel.querySelectorAll('.stv-translate-picker');
  const fields = panel.querySelectorAll('.stv-translate-field');
  check('the panel offers a picker for the engine and each language',
    pickers.length === 4 && fields.length === 4,
    'pickers=' + pickers.length + ' fields=' + fields.length);
  check('the panel uses no native select, which the webview cannot open',
    panel.querySelectorAll('select').length === 0,
    String(panel.querySelectorAll('select').length));

  // Each picker owns its own list; a panel-wide query would find the first
  // matching code in whichever list comes first in document order.
  const pickOption = (pickerIndex, value) => {
    const picker = pickers[pickerIndex];
    click(picker);
    const option = picker.parentNode.querySelectorAll('.stv-translate-option')
      .filter((node) => node.getAttribute('data-value') === value)[0];
    if (option) { click(option); }
    return option;
  };

  check('the engine picker lists every engine',
    panel.querySelectorAll('.stv-translate-option').length >= 6,
    String(panel.querySelectorAll('.stv-translate-option').length));
  check('picking a channel changes the picker label',
    !!pickOption(0, 'free') && pickers[0].textContent.indexOf('微软') >= 0,
    pickers[0].textContent);

  const keyField = panel.querySelectorAll('.stv-translate-key')[0];
  keyField.value = 'key-123';
  click(panel.querySelectorAll('.stv-translate-save')[0]);
  await tick(80);
  const saved = JSON.parse(sandbox.localStorage.getItem('stv.translate.settings') || '{}');
  check('the panel saves the engine and the key',
    saved.engine === 'free' && saved.apiKey === 'key-123', JSON.stringify(saved));

  click(panel.querySelectorAll('.stv-translate-test')[0]);
  await tick(150);
  const http = sandbox.__stored.http || [];
  check('the keyless Microsoft channel is used',
    http.length === 1
      && String(http[0].url).indexOf('edge.microsoft.com/translate/translatetext') >= 0,
    JSON.stringify(http.map((call) => call.url)));
  check('the keyless channel is told the target language',
    http.length === 1 && String(http[0].url).indexOf('to=zh-Hans') >= 0,
    http.length ? http[0].url : 'no request');
  check('the keyless channel posts the texts as a JSON array',
    http.length === 1
      && JSON.parse(http[0].data)[0] === 'Xin chào, đây là một bình luận thử nghiệm.',
    http.length ? http[0].data : 'no request');

  // The reader can pick any pair, not just Vietnamese <-> Chinese.
  const languageCount = panel.querySelectorAll('.stv-translate-option').length;
  pickOption(2, 'ja');
  click(panel.querySelectorAll('.stv-translate-save')[0]);
  await tick(60);
  const repicked = JSON.parse(sandbox.localStorage.getItem('stv.translate.settings') || '{}');
  check('any language can be chosen as the reading target',
    repicked.readTarget === 'ja', JSON.stringify(repicked.readTarget));
  check('the language list is not limited to two languages',
    languageCount > 20, String(languageCount));

  // The engine picker holds engines, so search the language picker.
  const search = pickers[2].parentNode.querySelectorAll('.stv-translate-pickersearch')[0];
  search.value = '韩';
  search.__fire('input', {});
  const visible = pickers[2].parentNode.querySelectorAll('.stv-translate-option')
    .filter((node) => node.style.display !== 'none');
  check('the language list can be searched',
    visible.length === 1 && visible[0].getAttribute('data-value') === 'ko',
    JSON.stringify(visible.map((node) => node.getAttribute('data-value'))));
}

async function testCommentTranslateFallback() {
  console.log('comment translation without the system engine');
  const fixture = commentPageFixture(['Nhận xét']);
  const sandbox = makeSandbox();
  installFakeApp(sandbox, {
    appLanguage: 'zh',
    pages: { comment: fixture.page },
    // An iOS 15-17 device: the selector exists but reports "unsupported".
    appleStatus: { status: 'unsupported', ready: false, reason: 'ios-version' },
    httpResponse: (url, payload) => (
      url.indexOf('edge.microsoft.com') >= 0
        ? edgeAnswer(JSON.parse(payload.data))
        : { status: 500, data: '' }
    ),
  });

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(250);
  sandbox.app.pushPage('comment', {});
  await tick(60);
  click(fixture.bar.querySelectorAll('.stv-translate-all')[0]);
  await tick(200);

  check('a device without the framework never calls the native translate',
    (sandbox.__stored.translationTranslate || []).length === 0,
    JSON.stringify(sandbox.__stored.translationTranslate || []));
  check('it falls through to the keyless Microsoft channel',
    (sandbox.__stored.http || []).length === 1,
    JSON.stringify((sandbox.__stored.http || []).map((call) => call.url)));
  const contents = fixture.view.querySelectorAll('.cmtcontent');
  check('the fallback still fills the comment body',
    contents[0].textContent === '【微软】Nhận xét', contents[0].textContent);
}

async function testCommentTranslateProviders() {
  console.log('comment translation provider request shapes');
  const cases = [
    {
      engine: 'azure',
      extra: { apiKey: 'azure-key', region: 'eastasia' },
      texts: (payload) => JSON.parse(payload.data).map((item) => item.Text),
      url: 'https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=zh-Hans&from=vi',
      headers: (headers) => headers['Ocp-Apim-Subscription-Key'] === 'azure-key'
        && headers['Ocp-Apim-Subscription-Region'] === 'eastasia',
      answer: (texts) => ({ status: 200, data: texts.map((text) => ({ translations: [{ text: '【Azure】' + text }] })) }),
      marker: '【Azure】',
    },
    {
      engine: 'google',
      extra: { apiKey: 'google-key' },
      texts: (payload) => JSON.parse(payload.data).q,
      url: 'https://translation.googleapis.com/language/translate/v2?key=google-key',
      headers: () => true,
      answer: (texts) => ({ status: 200, data: { data: { translations: texts.map((text) => ({ translatedText: '【谷歌】' + text })) } } }),
      marker: '【谷歌】',
    },
    {
      engine: 'deepl',
      extra: { apiKey: 'deepl-key' },
      texts: (payload) => String(payload.data).split('&')
        .filter((part) => part.indexOf('text=') === 0)
        .map((part) => decodeURIComponent(part.slice(5))),
      url: 'https://api-free.deepl.com/v2/translate',
      headers: (headers) => headers.Authorization === 'DeepL-Auth-Key deepl-key',
      answer: (texts) => ({ status: 200, data: { translations: texts.map((text) => ({ text: '【DeepL】' + text })) } }),
      marker: '【DeepL】',
    },
    {
      engine: 'openai',
      extra: { apiKey: 'openai-key', endpoint: 'https://ai.example.com/v1', model: 'gpt-4o-mini' },
      texts: (payload) => JSON.parse(JSON.parse(payload.data).messages[1].content),
      url: 'https://ai.example.com/v1/chat/completions',
      headers: (headers) => headers.Authorization === 'Bearer openai-key',
      answer: (texts) => ({
        status: 200,
        data: { choices: [{ message: { content: JSON.stringify(texts.map((text) => '【AI】' + text)) } }] },
      }),
      marker: '【AI】',
    },
  ];

  for (const item of cases) {
    const fixture = commentPageFixture(['Một bình luận']);
    const sandbox = makeSandbox();
    const seeded = Object.assign({
      engine: item.engine,
      apiKey: '',
      region: '',
      endpoint: '',
      model: '',
      readSource: 'vi',
      readTarget: 'zh-Hans',
      writeTarget: 'vi',
      auto: false,
    }, item.extra);
    sandbox.localStorage.setItem('stv.translate.settings', JSON.stringify(seeded));
    installFakeApp(sandbox, {
      appLanguage: 'zh',
      pages: { comment: fixture.page },
      httpResponse: (url, payload) => item.answer(item.texts(payload)),
    });

    vm.runInContext(loadBlocks().join('\n'), sandbox);
    await tick(250);
    sandbox.app.pushPage('comment', {});
    await tick(60);
    click(fixture.bar.querySelectorAll('.stv-translate-all')[0]);
    await tick(200);

    const http = sandbox.__stored.http || [];
    check(item.engine + ': one request to its own endpoint',
      http.length === 1 && http[0].url === item.url,
      JSON.stringify(http.map((call) => call.url)));
    check(item.engine + ': sends the key in the right header',
      http.length === 1 && item.headers(http[0].headers),
      http.length ? JSON.stringify(http[0].headers) : 'no request');
    check(item.engine + ': posts exactly the comment texts',
      http.length === 1
        && JSON.stringify(item.texts(http[0])) === JSON.stringify(['Một bình luận']),
      http.length ? JSON.stringify(item.texts(http[0])) : 'no request');
    const contents = fixture.view.querySelectorAll('.cmtcontent');
    check(item.engine + ': the answer lands in the comment body',
      contents[0].textContent === item.marker + 'Một bình luận', contents[0].textContent);
  }
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
await testBootShell();
  await testCommentButton();
  await testOfflineBookDetailPage();
  await testDomainFailover();
  await testDownloadRowControls();
  await testStorageAccessor();
  await testDownloadRange();
  await testDownloadLifecycle();
  await testDownloadSources();
  await testDownloadCompletion();
  await testDownloadRenderRace();
  await testDownloadedListHidesRunningJobs();
  await testDuplicateDownloadStart();
  await testChapterRetry();
  await testKeyboardPopup();
  await testGridLayout();
  await testTabProbe();
  await testCommentTranslate();
  await testCommentTranslateFallback();
  await testCommentTranslateProviders();
  await testTranslateAllWaitsForTheList();
  await testAutoTranslateWaitsForTheList();
  await testCommunityBoardTranslate();
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
