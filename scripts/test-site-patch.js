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
const zlib = require('zlib');

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

/**
 * Parsed host of a URL string, or the empty string when it does not parse.
 * Host checks must compare this, never a substring of the URL: a substring can
 * appear in the path or query of a completely different host.
 */
function urlHost(value) {
  try {
    return new URL(String(value)).hostname;
  } catch (err) {
    return '';
  }
}

/**
 * Field NAMES of a stored object for failure messages, never values: the
 * values include API keys, and the failure detail is printed to the console.
 */
function fieldsOf(value) {
  return value && typeof value === 'object' ? Object.keys(value).sort().join(',') : String(value);
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
    // The download-list jump drives the tab bar by dispatching a click on the
    // tabitem, exactly as a finger would.
    dispatchEvent(event) {
      this.__fire(event && event.type, event);
      return true;
    },
    getBoundingClientRect() {
      // A test that cares about layout (the reader's start-of-page probe does)
      // hands the element the rect it should report; everything else keeps the
      // stand-in the other blocks were written against.
      return this.__rect || { left: 0, top: 0, width: 26, height: 26, right: 26, bottom: 26 };
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

/**
 * The rendered-line table a text node needs for the caret model below. Each
 * entry is one visual line: its slice of the node's text, and the viewport rect
 * it occupies. Real layout produces this; a stub has to be told, because the
 * whole point of the reader's start-of-page logic is that it asks layout instead
 * of assuming that the text of a node starts where the box does.
 */
function layoutLines(textNode, lines) {
  let start = 0;
  textNode.__lines = lines.map((line) => {
    const entry = {
      start,
      text: line.text,
      top: line.top,
      bottom: line.bottom,
      left: line.left === undefined ? 0 : line.left,
      right: line.right === undefined ? 200 : line.right,
    };
    start += line.text.length;
    return entry;
  });
  return textNode;
}

/**
 * caretRangeFromPoint answered from those tables, so a hit test behaves the way
 * WebKit's does: a line the splitter clipped above its box is not reachable, and
 * the point a probe asks about resolves to the character under it.
 */
function attachCaretModel(doc, root) {
  doc.caretRangeFromPoint = (x, y) => {
    let found = null;
    const visit = (node) => {
      if (found) { return; }
      if (node.nodeType === 3) {
        for (const line of node.__lines || []) {
          if (y < line.top || y >= line.bottom) { continue; }
          const width = line.right - line.left;
          const ratio = width > 0 ? (x - line.left) / width : 0;
          const within = Math.max(0, Math.min(line.text.length, Math.round(ratio * line.text.length)));
          found = { node, offset: line.start + within, line };
          return;
        }
        return;
      }
      for (const child of node.childNodes || []) { visit(child); }
    };
    visit(root);
    if (!found) { return null; }
    return {
      startContainer: found.node,
      startOffset: found.offset,
      getBoundingClientRect: () => ({
        left: found.line.left,
        top: found.line.top,
        right: found.line.right,
        bottom: found.line.bottom,
        width: found.line.right - found.line.left,
        height: found.line.bottom - found.line.top,
      }),
    };
  };
  return doc;
}

function makeSandbox(options) {
  const opts = options || {};
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
  // Logging is off unless the reader switches it on, and almost every assertion
  // below reads __stvDiag.text(). The switch itself is tested with
  // makeSandbox({ diag: false }), which leaves the flag genuinely absent.
  if (opts.diag !== false) { store['stv.diag'] = '1'; }
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
  const windowListeners = {};
  const window = {
    innerHeight: 800,
    innerWidth: 400,
    // Recorded, not ignored: the reader-prefetch block waits for the window's
    // `load` event (the document's own listeners are separate).
    addEventListener(type, handler) {
      windowListeners[type] = (windowListeners[type] || []).concat([handler]);
    },
    removeEventListener() {},
    getComputedStyle: (element) => ({
      getPropertyValue: (name) => (element.style && element.style.getPropertyValue
        ? element.style.getPropertyValue(name)
        : ''),
    }),
  };
  window.window = window;
  // A browser exposes the same store on both; the diagnostics switch reads it
  // through window.localStorage.
  window.localStorage = localStorage;

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
    // The download-list jump dispatches a click on a tabitem through the real
    // constructor path first; the createEvent fallback stays untested on purpose
    // (it is insurance for an older webview).
    MouseEvent: class {
      constructor(type, init) {
        this.type = type;
        this.bubbles = !!(init && init.bubbles);
        this.cancelable = !!(init && init.cancelable);
      }
    },
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  sandbox.__dom = { byId, store, head };
  // The page-repair block installs a capture-phase click listener on document;
  // the tests need to be able to fire it. Window listeners are fired too, so a
  // `load`-driven block can be exercised.
  sandbox.__dispatch = (type, event) => {
    for (const handler of listeners[type] || []) { handler(event); }
    for (const handler of windowListeners[type] || []) { handler(event); }
  };
  sandbox.__listenerCount = (type) => (listeners[type] || []).length;
  // Minimal MutationObserver: it records the observed node and the callback so a
  // test can flush it by hand. The comment-translation sweep and the boot
  // shell's stylesheet watch both use one.
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
  const doc = {
    documentElement: html,
    body: frameBody,
    getElementById: byId,
    // The injected frame scan looks for frames inside frames, and
    // querySelectorAll is what it delegates to; a real frame document answers
    // this, so the stub has to as well.
    querySelectorAll: (selector) => html.querySelectorAll(selector),
  };
  frame.contentDocument = doc;
  const frameWindow = {
    document: doc,
    innerHeight: 800,
    innerWidth: 400,
    addEventListener() {},
    removeEventListener() {},
  };
  doc.defaultView = frameWindow;
  // The reader asks the frame for the caret at the top of the page: the pages
  // it split out live in this document, not in the one the shim runs in.
  attachCaretModel(doc, html);
  frame.contentWindow = frameWindow;
  return frame;
}

// ---------------------------------------------------------------- fake site

function installFakeApp(sandbox, options) {
  const calls = [];
  const stored = {};
  const keychain = Object.assign({}, options.keychain || {});
  // A second namespace, mirroring the native plugin: the settings backup is
  // readable after a reinstall, the secret store is not, and the API key lives
  // only in the latter (see SangTacAppPlugin.secretSave / secretLoad).
  const secrets = Object.assign({}, options.secrets || {});
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
        // The offline chapter bodies live under
        // offlineBook_<host>_<id>_<cid> (app.v2.read.js:3295, :3402). Anything
        // the test did not supply keeps the old stand-in, which the TTS tests
        // rely on.
        getFile(key) {
          const files = options.chapterFiles || {};
          if (Object.prototype.hasOwnProperty.call(files, key)) {
            stored.fileReads = (stored.fileReads || []).concat([key]);
            return Promise.resolve(files[key]);
          }
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
    // The real popPage removes the top overlay page (page-vip:3238). Without
    // this the download-list jump would pop until its own safety cap.
    const overlay = sandbox.document.getElementById('overlay');
    if (overlay && overlay.children.length) {
      overlay.removeChild(overlay.children[overlay.children.length - 1]);
      return;
    }
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
      // The site's own remove() (app.v2.js:661) is an identity lookup, which is
      // exactly why OfflineBook.delete() (app.v2.read.js:3314) removes nothing:
      // it hands over the wrapper while data holds the record inside it.
      remove(item) {
        stored.removals = (stored.removals || []).concat([item]);
        const index = this.data.indexOf(item);
        if (index > -1) { this.data.splice(index, 1); }
        return Promise.resolve(index > -1);
      },
      save() {
        stored.storeSaves = (stored.storeSaves || 0) + 1;
        stored.savedData = JSON.stringify(this.data);
        return Promise.resolve();
      },
    },
    getNewBook(bookInfo) {
      stored.newBooks = (stored.newBooks || []).concat([bookInfo]);
      const book = { host: bookInfo.host, id: bookInfo.id };
      // `alreadyDownloaded` models getNewBook() returning the existing
      // OfflineBook singleton, whose getChapterDownloaded() reads the stored
      // chapter list (app.v2.read.js:3317).
      if (options.alreadyDownloaded) {
        book.baseObject = {
          host: bookInfo.host,
          id: bookInfo.id,
          chapterStoreKey: 'offlineBook_' + bookInfo.host + '_' + bookInfo.id + '_chapters',
          chapterPreKey: 'offlineBook_' + bookInfo.host + '_' + bookInfo.id + '_',
        };
        book.getChapterDownloaded = () => Promise.resolve(options.alreadyDownloaded.slice());
        book.getChapter = (cid) => Promise.resolve(
          (options.chapterFiles || {})[book.baseObject.chapterPreKey + cid] || '');
      }
      return Promise.resolve(book);
    },
    getExistedBook(obj) {
      stored.existedLookups = (stored.existedLookups || []).concat([obj.host + '/' + obj.id]);
      return options.existedBook || null;
    },
    // The real book objects are cached here and never invalidated
    // (app.v2.read.js:3248).
    offlineBookSingletons: {},
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
        return new Promise((resolve, reject) => { pendingChapters.push({ resolve, reject }); });
      }
      return Promise.resolve(chapter);
    }
    pause() { this.isPaused = true; }
    setStatus(text) {
      if (this.status) { this.status.textContent = text; }
    }
    start() {
      this.isPaused = false;
      stored.resumes = (stored.resumes || 0) + 1;
      return undefined;
    }
  }
  app.BookDownloadManager = FakeDownloadManager;
  stored.releaseChapters = (all, fail) => {
    if (all) { autoRelease = true; }
    while (pendingChapters.length) {
      const pending = pendingChapters.shift();
      if (fail) { pending.reject(new Error('Không thể đọc dữ liệu')); }
      else { pending.resolve(); }
    }
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
  sandbox.__secrets = secrets;

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
          // `settingsSaveRejects` models the native key allow-list / size cap,
          // which rejects rather than silently dropping the backup.
          const rejects = options.settingsSaveRejects;
          const rejected = Array.isArray(rejects) ? rejects.indexOf(payload.key) >= 0
            : (typeof rejects === 'function' ? rejects(payload) : false);
          if (rejected) {
            return Promise.reject(new Error('key not backed up by this app'));
          }
          keychain[payload.key] = payload.value;
          return Promise.resolve({ value: true });
        },
        settingsRestore() {
          // `settingsRestoreFails` models the native origin guard refusing the
          // call (or a transient keychain error) for the first N attempts.
          if ((options.settingsRestoreFails || 0) > 0) {
            options.settingsRestoreFails -= 1;
            return Promise.reject(new Error('settingsRestore is not available from this origin'));
          }
          return Promise.resolve({ entries: Object.assign({}, keychain) });
        },
        // The API key never goes through settingsSave: app.storage is plaintext
        // and the settings mirror rides into backups, so the key has its own
        // this-device-only item. An empty value clears it.
        secretSave(payload) {
          (stored.secretSave || (stored.secretSave = [])).push(payload);
          if (!payload.value) { delete secrets[payload.key]; }
          else { secrets[payload.key] = payload.value; }
          return Promise.resolve({ value: true, stored: !!payload.value });
        },
        secretLoad(payload) {
          (stored.secretLoad || (stored.secretLoad = [])).push(payload);
          const value = secrets[payload.key];
          return Promise.resolve({ value: typeof value === 'string' ? value : '' });
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
        // The export block builds the TXT/EPUB in the page and hands the bytes
        // here; the real method writes them into the temporary directory and
        // opens the share sheet. `exportFileFails` models the bridge rejecting.
        exportFile(payload) {
          (stored.exports || (stored.exports = [])).push(payload);
          if (options.exportFileFails) {
            return Promise.reject(new Error(options.exportFileFails));
          }
          return Promise.resolve({
            value: true,
            name: payload.filename,
            bytes: payload.data.length,
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
        // Covers are fetched with responseType arraybuffer, which the native
        // plugin answers as base64 (SangTacHttpPlugin.swift:749).
        get(payload) {
          (stored.httpGet || (stored.httpGet = [])).push(payload);
          if (options.httpGetResponse) {
            return Promise.resolve(options.httpGetResponse(String(payload.url), payload));
          }
          return Promise.reject(new Error('no Http.get stub for ' + payload.url));
        },
        // The diag block pushes the logging switch to the native side so it can
        // skip building diagnostic lines at all.
        setDiagnostics(payload) {
          (stored.setDiagnostics || (stored.setDiagnostics = [])).push(payload);
          return Promise.resolve({ enabled: !!payload.enabled });
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
  console.log('diagnostics panel and the logging switch');
  // Off is the shipped default: no window, no buffer, no capture at all.
  const off = makeSandbox({ diag: false });
  installFakeApp(off, { displayType: 'auto' });
  vm.runInContext(loadBlocks().join('\n'), off);
  await tick(300);
  const offDiag = off.window.__stvDiag;
  check('__stvDiag installed', !!offDiag);
  check('logging is off until the switch is turned on', offDiag.enabled() === false);
  check('no floating window exists while logging is off',
    off.document.body.querySelectorAll('[data-stvdiag]').length === 0,
    String(off.document.body.children.length) + ' child(ren) on <body>');
  offDiag.log('Http', 'GET /x -> 200');
  check('nothing is buffered while logging is off', offDiag.lines().length === 0);
  offDiag.show();
  check('show() cannot resurrect the window while logging is off',
    off.document.body.querySelectorAll('[data-stvdiag]').length === 0);
  off.console.log('must not be captured');
  check('the console is not captured while logging is off', offDiag.lines().length === 0);

  // On: the badge is always visible (not only after an error, which was the old
  // behaviour) and the switch opens the panel itself.
  const sandbox = makeSandbox();
  installFakeApp(sandbox, { displayType: 'auto' });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(300);
  const diag = sandbox.window.__stvDiag;
  check('the switch reads the stored flag', diag.enabled() === true);
  const badge = sandbox.document.body.querySelectorAll('[data-stvdiag=badge]')[0];
  const panel = sandbox.document.body.querySelectorAll('[data-stvdiag=panel]')[0];
  check('the badge and the panel are built', !!badge && !!panel);
  check('the badge is visible before anything has errored',
    !!badge && badge.style.display === 'block',
    badge ? badge.style.display : 'no badge');
  check('the panel is on screen while logging is on',
    !!panel && panel.style.display === 'block',
    panel ? panel.style.display : 'no panel');

  diag.log('Http', 'GET /x -> 200');
  diag.log('ERR', 'boom');
  const text = diag.text();
  check('lines are buffered', text.includes('GET /x -> 200') && text.includes('boom'));
  check('badge shows the line count', badge.textContent === String(diag.lines().length));
  check('the badge turns red on the first error',
    badge.style.background.indexOf('170,20,20') >= 0, badge.style.background);
  check('copy() returns the buffer', diag.copy() === text);
  sandbox.console.log('hello from the site');
  check('the console is captured while logging is on',
    diag.text().includes('hello from the site'), diag.text().slice(-200));
  diag.hide();
  check('hiding closes the panel', panel.style.display === 'none');
  diag.show();
  check('show/hide are safe', panel.style.display === 'block');

  // Switching off takes the window away and empties the buffer.
  diag.setEnabled(false);
  check('the switch turns logging off', diag.enabled() === false);
  check('the floating window is gone',
    sandbox.document.body.querySelectorAll('[data-stvdiag]').length === 0,
    String(sandbox.document.body.children.length) + ' child(ren)');
  check('the buffer is emptied', diag.lines().length === 0);
  check('the flag is written to localStorage',
    sandbox.localStorage.getItem('stv.diag') === '0',
    String(sandbox.localStorage.getItem('stv.diag')));
  check('the flag is mirrored for the keychain backup',
    sandbox.localStorage.getItem('stv.diag.settings')
      === JSON.stringify({ enabled: false }),
    String(sandbox.localStorage.getItem('stv.diag.settings')));

  diag.setEnabled(true);
  check('switching back on rebuilds the window',
    sandbox.document.body.querySelectorAll('[data-stvdiag]').length === 2,
    String(sandbox.document.body.querySelectorAll('[data-stvdiag]').length));
  check('the new state is persisted',
    sandbox.localStorage.getItem('stv.diag') === '1');
}

async function testLoggingSwitch() {
  console.log('the logging switch in 设置');
  const fixture = settingsPageFixture();
  const sandbox = makeSandbox({ diag: false });
  const app = installFakeApp(sandbox, {
    displayType: 'auto',
    pages: { pagesetting: fixture.page },
  });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(300);
  app.pushPage('pagesetting', {});
  await tick(60);

  const diag = sandbox.window.__stvDiag;
  const entry = fixture.content.querySelectorAll('.stv-log-entry')[0];
  check('a 日志 row is added to 设置', !!entry);
  const state = entry && entry.querySelectorAll('.stv-log-state')[0];
  check('the row shows the current state',
    !!state && state.textContent.indexOf('已关闭') >= 0,
    state ? state.textContent : 'no state');

  click(entry);
  await tick(40);
  check('tapping the row turns logging on', diag.enabled() === true);
  check('the row now reads 已开启', state.textContent.indexOf('已开启') >= 0, state.textContent);
  check('the window is on screen',
    sandbox.document.body.querySelectorAll('[data-stvdiag]').length === 2,
    String(sandbox.document.body.children.length) + ' child(ren)');
  check('the switch is persisted',
    sandbox.localStorage.getItem('stv.diag') === '1'
      && sandbox.localStorage.getItem('stv.diag.settings')
        === JSON.stringify({ enabled: true }),
    String(sandbox.localStorage.getItem('stv.diag.settings')));

  click(entry);
  await tick(40);
  check('tapping again turns it off', diag.enabled() === false);
  check('and the window is gone again',
    sandbox.document.body.querySelectorAll('[data-stvdiag]').length === 0);

  const open = fixture.content.querySelectorAll('.stv-log-open')[0];
  check('a 查看/复制日志 row is added', !!open);
  click(open);
  await tick(40);
  check('asking to read the log turns logging on rather than opening nothing',
    diag.enabled() === true);
  check('and the state row agrees', state.textContent.indexOf('已开启') >= 0, state.textContent);
  check('the panel is on screen',
    sandbox.document.body.querySelectorAll('[data-stvdiag=panel]').length === 1);

  // A keychain restore (a reinstall) has to bring the switch back.
  const restored = makeSandbox({ diag: false });
  installFakeApp(restored, {
    displayType: 'auto',
    keychain: { 'stv.diag.settings': JSON.stringify({ enabled: true }) },
  });
  vm.runInContext(loadBlocks().join('\n'), restored);
  await tick(600);
  check('the switch survives a reinstall through the keychain backup',
    restored.window.__stvDiag.enabled() === true,
    String(restored.window.__stvDiag.enabled()));
  check('the restore is reported',
    String(restored.window.__stvDiag.text() || '').indexOf('logging switch restored: on') >= 0,
    String(restored.window.__stvDiag.text() || '').slice(-300));
}

async function testActivityLog() {
  console.log('activity log for the common flows');
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, {
    displayType: 'auto',
    pages: { pagesetting: settingsPageFixture().page },
  });
  app.context = {
    menu: {
      downloadchapter: {
        body: '<input class="numstart"/><input class="numend"/>',
        action: { startdownload: async function () {}, cancel: function () {} },
      },
    },
    showPopup() { return makeContainer('div', 'popupedit'); },
    info(msg) {
      sandbox.__stored.infoCalls = (sandbox.__stored.infoCalls || []).concat([msg]);
    },
  };
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(300);

  app.pushPage('pagesetting', {});
  app.popPage();
  app.toast('Không thể đọc dữ liệu');
  app.context.info('Bạn chưa đăng nhập');

  const bar = makeContainer('tabbar', '');
  const item = makeContainer('tabitem', '', 'download');
  bar.appendChild(item);
  sandbox.document.body.appendChild(bar);
  sandbox.__dispatch('click', {
    target: item,
    preventDefault() {},
    stopPropagation() {},
    stopImmediatePropagation() {},
  });

  const text = String(sandbox.window.__stvDiag.text() || '');
  check('opening a page is logged',
    text.indexOf('[PAGE] open pagesetting') >= 0, text.slice(-400));
  check('popping a page is logged', text.indexOf('[PAGE] back') >= 0, text.slice(-400));
  check('a toast is logged',
    text.indexOf('[MSG] toast: Không thể đọc dữ liệu') >= 0, text.slice(-400));
  check('a site info popup is logged',
    text.indexOf('[MSG] info: Bạn chưa đăng nhập') >= 0, text.slice(-400));
  check('a tab tap is logged with its index and label',
    text.indexOf('[NAV] tab 0 download') >= 0, text.slice(-400));
  check('the block announces itself once attached',
    text.indexOf('[BOOT] activity log attached') >= 0, text.slice(-400));
  check('the wrapped calls still reach the site',
    (sandbox.__stored.infoCalls || []).length === 1
      && sandbox.__stored.pushed.length === 1,
    JSON.stringify(sandbox.__stored.infoCalls) + ' / '
      + JSON.stringify(sandbox.__stored.pushed));
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

  // The site appends its own archive notice to every chapter body. It is in the
  // chapter text (the iframe for page-flip, the chapter container for scroll),
  // so it has to come out of both, and nothing around it may move.
  const frameNotice = makeContainer('p', '', 'Bạn đang đọc bản lưu trong hệ thống');
  const frameNovel = makeContainer('p', '', 'Hắn quay đầu lại.');
  const noticeFrame = makeFakeFrame([frameNotice, frameNovel]);
  sandbox.document.body.appendChild(noticeFrame);
  const inlineNotice = makeContainer('div', '', '@Bạn đang đọc bản lưu trong hệ thống.');
  sandbox.document.body.appendChild(inlineNotice);
  const mixedNotice = makeContainer('p', '',
    '结尾一句。Bạn đang đọc bản lưu trong hệ thống');
  sandbox.document.body.appendChild(mixedNotice);

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

  // The archive notice goes, and nothing else does.
  check('the site archive notice is removed from the chapter body',
    frameNotice.textContent === '' && frameNotice.parentNode === null,
    JSON.stringify(frameNotice.textContent) + ' parent='
      + String(frameNotice.parentNode && frameNotice.parentNode.tagName));
  check('the novel text next to it is untouched',
    frameNovel.textContent === 'Hắn quay đầu lại.', JSON.stringify(frameNovel.textContent));
  check('the notice is removed in the main document too',
    inlineNotice.textContent === '', JSON.stringify(inlineNotice.textContent));
  check('a notice appended to a real sentence takes only itself away',
    mixedNotice.textContent === '结尾一句。', JSON.stringify(mixedNotice.textContent));
  // The counter, not the panel line: the diagnostics buffer is emptied by the
  // settings restore a moment after document start, so a line logged during the
  // document-start sweep is not in it. The count is what proves every notice was
  // taken exactly once.
  check('every notice is removed and counted',
    sandbox.window.__stvI18n.removed() === 3,
    String(sandbox.window.__stvI18n.removed()));

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

  // The reader builds its frame when a chapter is opened -- minutes into the
  // session, long after the fixed delay list has run out -- and assigning srcdoc
  // swaps the document inside an iframe that is already attached, which the
  // outer document sees no mutation for. The 2026-09-24 device log has no PATCH
  // line for a whole session while the notice stayed on screen, so the frame
  // scan has to keep running and every frame has to look inside itself.
  const lateNotice = makeContainer('p', '', '@Bạn đang đọc bản lưu trong hệ thống');
  const lateNovel = makeContainer('p', '', '这一句要留下。');
  const lateFrame = makeFakeFrame([lateNotice, lateNovel]);
  sandbox.document.body.appendChild(lateFrame);
  await tick(1200);
  check('a chapter frame built after document start still loses the notice',
    lateNotice.textContent === '' && lateNotice.parentNode === null,
    JSON.stringify(lateNotice.textContent) + ' parent='
      + String(lateNotice.parentNode && lateNotice.parentNode.tagName));
  check('the novel text in that frame survives',
    lateNovel.textContent === '这一句要留下。', JSON.stringify(lateNovel.textContent));

  // The chapter can be a frame inside the reader's own frame, and
  // querySelectorAll does not cross that boundary: every frame has to look
  // inside itself for the next one, or the innermost chapter is never reached.
  const nestedNotice = makeContainer('p', '', '@Bạn đang đọc bản lưu trong hệ thống');
  const nestedInner = makeFakeFrame([nestedNotice]);
  const nestedOuter = makeFakeFrame([nestedInner]);
  sandbox.document.body.appendChild(nestedOuter);
  sandbox.window.__stvI18n.sweepFrames();
  check('a chapter frame nested inside the reader frame is reached',
    nestedNotice.textContent === '' && nestedNotice.parentNode === null,
    JSON.stringify(nestedNotice.textContent) + ' parent='
      + String(nestedNotice.parentNode && nestedNotice.parentNode.tagName));

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

/**
 * The site's settings page can hand its own language setter something that is
 * not a language. Its language row carries the selection path
 * "app.config.ux.app_language" together with the onchange
 * "app.text.changeLanguage('value')" (page-vip:1464), and that onchange is
 * eval'd with the picked value substituted (page-vip:3646-3649) -- the same code
 * path the domain row goes through, so the domain's value reaches
 * changeLanguage. Its failure path is one request to /mobile/lang/<value>.json:
 * the 2026-09-23 log holds 25 of them, every one a 403, ~500ms apart, starting
 * the moment the domain row was tapped.
 */
async function testLanguageGuard() {
  console.log('language setter guard');
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, { displayType: 'auto' });
  const loads = [];
  app.lang = {
    zh: { booklist: '小说列表' },
    // The site's own loadOnline (app.v2.js:1876) -- one request per call.
    loadOnline(code) {
      loads.push(code);
      return Promise.reject(new Error('403 Forbidden'));
    },
  };
  // The site's own changeLanguage (app.v2.js:1942-1953): a code it does not have
  // yet is fetched first, and the failure path is a toast.
  app.text = {
    changeLanguage(code) {
      if (!app.lang[code]) {
        return app.lang.loadOnline(code)
          .then(() => this.changeLanguage(code))
          .catch(() => 'toast: Không thể tải ngôn ngữ ' + code);
      }
      app.language = code;
      return code;
    },
  };

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(300);
  check('the language setter is guarded', app.text.__stvLangGuarded === true);

  const refused = app.text.changeLanguage('https://sangtacviet.app');
  await app.text.changeLanguage('https://sangtacviet.app');
  await tick(40);
  check('a domain is refused before it can become a language request',
    loads.length === 0 && refused === null, loads.join('|'));
  check('the refusal names the value that was refused',
    String(sandbox.window.__stvDiag.text() || '')
      .indexOf('refused a language that is not one: https://sangtacviet.app') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-320));
  check('the site language is left where it was',
    app.language === 'vi', String(app.language));

  await app.text.changeLanguage('en');
  await tick(20);
  check('a real language code still goes through untouched',
    loads.join('|') === 'en', loads.join('|'));
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

  // The page-flip display renders the chapter into an off-screen element and
  // moves the pages it split out into the frames it shows (chapterdisplay.js
  // setContent 1641-1646, pushPageToScreen 1706-1719). That element and the
  // body are therefore leftovers, and the 2026-09-24 device log caught the shim
  // reading exactly one of them: "fallback source [document body]: 111 chars",
  // the same 111 characters on every attempt, from a page nobody was looking
  // at. The display knows the page it is on: currentPageId indexes
  // currentChapter.pageElements.
  const pageOne = makeContainer('div', 'pageparent', '第一页的内容。');
  const pageTwo = makeContainer('div', 'pageparent', '第二页第一句。第二页第二句。');
  const pageThree = makeContainer('div', 'pageparent', '第三页第一句。');
  const leftover = makeContainer('div', 'maincontent', '上一章残留下来的字。');
  leftover.id = 'maincontent';
  const flipFrame = makeFakeFrame([leftover]);
  const flipChapter = { cid: '927797006', pageElements: [pageOne, pageTwo, pageThree] };
  const flipDisplay = {
    innerWindow: flipFrame.contentWindow,
    getCurrentWindow() { return flipFrame.contentWindow; },
    getCurrentChapter() { return flipChapter; },
    currentPageId: 1,
    tokenizeSentence() { return []; },
  };
  const flipSandbox = makeSandbox();
  const flipApp = installFakeApp(flipSandbox, { displayType: 'pageflip', display: flipDisplay });
  flipSandbox.document.body.appendChild(flipFrame);
  // The site's own start() rebuilds the queue only when the CHAPTER changed
  // (app.v2.read.js app.tts.start -> player.isViewChanged()), so this stands in
  // for the player and the shim's wrapper is what has to notice the page.
  const flipPlayer = {
    sentences: [],
    currentId: 0,
    reset() { this.sentences = []; this.currentId = 0; },
    generateSentences() { this.sentences = flipDisplay.tokenizeSentence(); this.currentId = 0; },
  };
  flipApp.tts.player = flipPlayer;
  flipApp.tts.start = function () { flipApp.tts.player = flipPlayer; };
  vm.runInContext(loadBlocks().join('\n'), flipSandbox);
  await tick(250);

  flipApp.tts.start();
  await tick(20);
  check('the reader reads the page on screen, not the leftover renderer',
    flipPlayer.sentences.length === 3
      && flipPlayer.sentences[0].toText().slice(4) === '第二页第一句。',
    JSON.stringify(flipPlayer.sentences.map((s) => s.toText())));
  check('the page it read and its place in the chapter are reported',
    String(flipSandbox.window.__stvDiag.text() || '').indexOf('pageflip page 2 of 3') >= 0,
    String(flipSandbox.window.__stvDiag.text() || '').slice(-260));
  // No rendered-line table here, so WebKit has nothing to answer with: the
  // reader must still read the page and must say which start it used, or a
  // device log could not tell the two paths apart.
  check('a start WebKit could not confirm is reported as the top of the page',
    String(flipSandbox.window.__stvDiag.text() || '')
      .indexOf('pageflip page 2 of 3, from the top of the page') >= 0,
    String(flipSandbox.window.__stvDiag.text() || '').slice(-260));

  flipDisplay.currentPageId = 2;
  flipApp.tts.start();
  await tick(20);
  check('turning the page rebuilds the queue instead of replaying the old page',
    flipPlayer.sentences.length === 1
      && flipPlayer.sentences[0].toText().slice(4) === '第三页第一句。',
    JSON.stringify(flipPlayer.sentences.map((s) => s.toText())));

  flipPlayer.currentId = flipPlayer.sentences.length;
  flipApp.tts.start();
  await tick(20);
  check('a spent list is rebuilt rather than handed to the site to skip a chapter',
    flipPlayer.currentId === 0 && flipPlayer.sentences.length === 1,
    'currentId=' + String(flipPlayer.currentId)
      + ' sentences=' + String(flipPlayer.sentences.length));

  // The page's own text is not the page's visible text. The splitter cuts a
  // paragraph in two by CLONING it: the page that keeps the top gets a
  // height-clipped copy, the next page a wrapper whose child is pulled up by a
  // negative margin so the lines already shown start above its box
  // (chapterdisplay.js splitPage 1095-1113). Both clones still hold the WHOLE
  // paragraph, so a textContent read on the second page opens with the lines the
  // reader finished on the previous one -- which is what the 2026-09-23 log
  // described as playback starting a few lines early. The same page also opens
  // with the fixed header the display stamps on every page (chapter name and
  // clock, createPage 1142-1166), which is chrome, not text.
  const chrome = makeContainer('div', 'chaptertopinfo', '第三章 休伤吾主20:07');
  layoutLines(chrome.children[0],
    [{ text: '第三章 休伤吾主20:07', top: 0, bottom: 14, left: 0, right: 180 }]);
  const spill = makeElement('p');
  spill.style.marginTop = '-20px';
  const spillText = makeTextNode('上一页最后一行。第二页第一句。第二页第二句。');
  spill.appendChild(spillText);
  layoutLines(spillText, [
    { text: '上一页最后一行。', top: -20, bottom: 0, left: 0, right: 160 },
    { text: '第二页第一句。', top: 0, bottom: 20, left: 0, right: 140 },
    { text: '第二页第二句。', top: 20, bottom: 40, left: 0, right: 140 },
  ]);
  const spillWrap = makeElement('div');
  spillWrap.className = 'page';
  spillWrap.style.overflow = 'hidden';
  spillWrap.appendChild(spill);
  const pageTwoBody = makeElement('div');
  pageTwoBody.className = 'page';
  pageTwoBody.appendChild(chrome);
  pageTwoBody.appendChild(spillWrap);
  pageTwoBody.appendChild(makeContainer('p', '', '第二页第三句。'));
  pageTwoBody.__rect = { left: 0, top: 0, right: 400, bottom: 26, width: 400, height: 26 };
  // The clone the third page gets from the same cut, plus a fresh paragraph.
  const spillClone = makeElement('p');
  spillClone.style.marginTop = '-20px';
  spillClone.appendChild(makeTextNode('上一页最后一行。第二页第一句。第二页第二句。'));
  const spillWrapTwo = makeElement('div');
  spillWrapTwo.style.overflow = 'hidden';
  spillWrapTwo.appendChild(spillClone);
  const pageThreeBody = makeElement('div');
  pageThreeBody.className = 'page';
  // Every page carries its own header (createPage sets the page's innerHTML to
  // it first), so the spill is the first block that carries TEXT, not the first
  // child -- which is the shape the skip rule has to survive.
  pageThreeBody.appendChild(makeContainer('div', 'chaptertopinfo', '第三章 休伤吾主20:08'));
  pageThreeBody.appendChild(spillWrapTwo);
  pageThreeBody.appendChild(makeContainer('p', '', '第三页第一句。'));
  const pageOneBody = makeContainer('div', 'page', '第一页的内容。');

  const lineFrame = makeFakeFrame([pageOneBody, pageTwoBody, pageThreeBody]);
  const lineChapter = {
    cid: '927797006',
    pageElements: [pageOneBody, pageTwoBody, pageThreeBody],
  };
  const lineDisplay = {
    innerWindow: lineFrame.contentWindow,
    getCurrentWindow() { return lineFrame.contentWindow; },
    getCurrentChapter() { return lineChapter; },
    currentPageId: 1,
    tokenizeSentence() { return []; },
  };
  const lineSandbox = makeSandbox();
  const lineApp = installFakeApp(lineSandbox, { displayType: 'pageflip', display: lineDisplay });
  lineSandbox.document.body.appendChild(lineFrame);
  const linePlayer = {
    sentences: [],
    currentId: 0,
    reset() { this.sentences = []; this.currentId = 0; },
    generateSentences() { this.sentences = lineDisplay.tokenizeSentence(); this.currentId = 0; },
  };
  lineApp.tts.player = linePlayer;
  lineApp.tts.start = function () { lineApp.tts.player = linePlayer; };
  vm.runInContext(loadBlocks().join('\n'), lineSandbox);
  await tick(250);
  lineApp.tts.start();
  await tick(20);
  const lineText = linePlayer.sentences.map((s) => s.toText().slice(4)).join('|');
  check('the reader starts at the first line on screen, not at the top of the node',
    linePlayer.sentences.length === 4
      && linePlayer.sentences[0].toText().slice(4) === '第二页第一句。',
    lineText);
  check('the lines the splitter clipped above the box are not read again',
    lineText.indexOf('上一页最后一行。') < 0, lineText);
  check('the fixed chapter header stamped on every page is not read out',
    lineText.indexOf('20:07') < 0 && lineText.indexOf('第三章') < 0, lineText);
  check('the spill the next page repeats is read once, from the page that showed it',
    lineText.split('第二页第一句。').length === 2
      && lineText.indexOf('第三页第一句。') >= 0, lineText);
  check('the start of the reading is reported',
    String(lineSandbox.window.__stvDiag.text() || '')
      .indexOf('pageflip page 2 of 3, from the visible line') >= 0,
    String(lineSandbox.window.__stvDiag.text() || '').slice(-260));

  // The scrolling display has no pages at all: the visible top is wherever the
  // viewport was scrolled to, and the same question answers it.
  const scrolledAway = makeElement('p');
  const scrolledAwayText = makeTextNode('上面已经看过的一句。');
  scrolledAway.appendChild(scrolledAwayText);
  layoutLines(scrolledAwayText,
    [{ text: '上面已经看过的一句。', top: -20, bottom: 0, left: 0, right: 160 }]);
  const onScreen = makeElement('p');
  const onScreenText = makeTextNode('现在屏幕上的第一句。');
  onScreen.appendChild(onScreenText);
  layoutLines(onScreenText,
    [{ text: '现在屏幕上的第一句。', top: 0, bottom: 20, left: 0, right: 160 }]);
  const scrollBody = makeElement('div');
  scrollBody.className = 'contentcontainer';
  scrollBody.appendChild(scrolledAway);
  scrollBody.appendChild(onScreen);
  scrollBody.__rect = { left: 0, top: -100, right: 400, bottom: 400, width: 400, height: 500 };
  const scrollFrame = makeFakeFrame([scrollBody]);
  const scrollView = {
    cdata: { chaptername: 'Chương 1: 开局' },
    q: (selector) => (selector === '.contentcontainer' ? scrollBody : null),
  };
  const scrollDisplay = {
    innerWindow: scrollFrame.contentWindow,
    getCurrentWindow() { return scrollFrame.contentWindow; },
    getCurrentChapter() { return scrollView; },
    tokenizeSentence() { return []; },
  };
  const scrollSandbox = makeSandbox();
  const scrollApp = installFakeApp(scrollSandbox, { displayType: 'pageflip', display: scrollDisplay });
  scrollSandbox.document.body.appendChild(scrollFrame);
  const scrollPlayer = {
    sentences: [],
    currentId: 0,
    reset() { this.sentences = []; this.currentId = 0; },
    generateSentences() { this.sentences = scrollDisplay.tokenizeSentence(); this.currentId = 0; },
  };
  scrollApp.tts.player = scrollPlayer;
  scrollApp.tts.start = function () { scrollApp.tts.player = scrollPlayer; };
  vm.runInContext(loadBlocks().join('\n'), scrollSandbox);
  await tick(250);
  scrollApp.tts.start();
  await tick(20);
  check('the scrolling reader starts at the first line on screen too',
    scrollPlayer.sentences.length === 1
      && scrollPlayer.sentences[0].toText().slice(4) === '现在屏幕上的第一句。',
    JSON.stringify(scrollPlayer.sentences.map((s) => s.toText())));
  check('the scrolling reader reports where it started',
    String(scrollSandbox.window.__stvDiag.text() || '')
      .indexOf('scroll chapter, from the visible line') >= 0,
    String(scrollSandbox.window.__stvDiag.text() || '').slice(-260));

  // The reader's own titlebar lives in the document that owns the frame (the
  // RECT line in the device log puts it at 0..82) and can cover the top of the
  // frame: rows under it are painted over, so the first row the reader can see
  // is below it, and reading has to start there.
  const bar = makeContainer('div', 'titlebar', '');
  bar.__rect = { left: 0, top: 0, right: 400, bottom: 40, width: 400, height: 40 };
  const coveredFrame = makeFakeFrame([]);
  const behindP = makeElement('p');
  const behind = makeTextNode('藏在页眉后面的字。页眉下面第一句。');
  behindP.appendChild(behind);
  layoutLines(behind, [
    { text: '藏在页眉后面的字。', top: 0, bottom: 20, left: 0, right: 180 },
    { text: '页眉下面第一句。', top: 40, bottom: 60, left: 0, right: 160 },
  ]);
  const coveredPage = makeElement('div');
  coveredPage.className = 'page';
  coveredPage.appendChild(behindP);
  coveredPage.__rect = { left: 0, top: 0, right: 400, bottom: 200, width: 400, height: 200 };
  coveredFrame.contentDocument.body.appendChild(coveredPage);
  coveredFrame.contentWindow.frameElement = coveredFrame;
  const coveredDisplay = {
    innerWindow: coveredFrame.contentWindow,
    getCurrentWindow() { return coveredFrame.contentWindow; },
    getCurrentChapter() { return { cid: '1', pageElements: [coveredPage] }; },
    currentPageId: 0,
    tokenizeSentence() { return []; },
  };
  const coveredSandbox = makeSandbox();
  const coveredApp = installFakeApp(coveredSandbox, { displayType: 'pageflip', display: coveredDisplay });
  coveredSandbox.document.body.appendChild(bar);
  coveredSandbox.document.body.appendChild(coveredFrame);
  coveredFrame.contentWindow.parent = { document: coveredSandbox.document };
  const coveredPlayer = {
    sentences: [],
    currentId: 0,
    reset() { this.sentences = []; this.currentId = 0; },
    generateSentences() { this.sentences = coveredDisplay.tokenizeSentence(); this.currentId = 0; },
  };
  coveredApp.tts.player = coveredPlayer;
  coveredApp.tts.start = function () { coveredApp.tts.player = coveredPlayer; };
  vm.runInContext(loadBlocks().join('\n'), coveredSandbox);
  await tick(250);
  coveredApp.tts.start();
  await tick(20);
  check('the reader starts below the titlebar that covers the top of the frame',
    coveredPlayer.sentences.length === 1
      && coveredPlayer.sentences[0].toText().slice(4) === '页眉下面第一句。',
    JSON.stringify(coveredPlayer.sentences.map((s) => s.toText())));

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

  // Deterministic release: a stylesheet that arrives at 1.1s must take the shell
  // down then, not at the 3s sample.
  const early = makeSandbox();
  installFakeApp(early, { displayType: 'auto' });
  // Model document start, where the site's own app object does not exist yet --
  // otherwise `app.config.reader` is a release signal on its own and the
  // stylesheet path would never be exercised.
  delete early.window.app.config.reader;
  vm.runInContext(loadBlocks().join('\n'), early);
  const earlyRoot = early.document.documentElement;
  const sheet = makeElement('link');
  early.document.head.appendChild(sheet);
  early.__flushObservers();
  check('the shell stays up while the site stylesheet is still missing',
    String(earlyRoot.className).indexOf('stv-boot') >= 0, String(earlyRoot.className));

  early.document.styleSheets.push({ href: 'https://sangtacviet.app/asset/app.v2.css?v=4' });
  sheet.__fire('load', {});
  check('a stylesheet link that fires load releases the shell immediately',
    String(earlyRoot.className).indexOf('stv-boot') < 0, String(earlyRoot.className));
  check('the early release names the signal that fired',
    String(early.window.__stvDiag.text()).indexOf('link load') >= 0,
    String(early.window.__stvDiag.text()).slice(-200));
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

  // The remembered mirror: the next launch must not re-run the ping race and
  // land on the mirror that answers code 7 to every chapter.
  const mirrorOptions = () => ({
    displayType: 'pageflip',
    networkManager: {
      domains: [
        { name: bad, status: 'alive', ping: 100 },
        { name: good, status: 'alive', ping: 400 },
      ],
      defaultDomains: [good, bad, 'https://sangtacviet.app'],
    },
  });

  const warm = makeSandbox();
  warm.localStorage.setItem('stv.domain.good',
    JSON.stringify({ name: good, at: Date.now() }));
  const warmApp = installFakeApp(warm, mirrorOptions());
  const warmServed = [];
  warmApp.reader.getContent = function () {
    const domain = warmApp.net.networkManager.bestDomain();
    warmServed.push(domain);
    return Promise.resolve(domain === bad ? { code: 7 } : { code: 0, data: 'chapter' });
  };
  vm.runInContext(loadBlocks().join('\n'), warm);
  await tick(300);
  check('a remembered mirror is used without re-running the ping race',
    warmApp.net.networkManager.bestDomain() === good,
    warmApp.net.networkManager.bestDomain());
  const warmData = await warmApp.reader.getContent('qidian', '1', 'c1');
  check('the first chapter goes straight to the remembered mirror',
    String(warmData.code) === '0' && warmServed.length === 1 && warmServed[0] === good,
    JSON.stringify(warmServed));

  // Expired: the site's own race is the only source of truth again.
  const stale = makeSandbox();
  stale.localStorage.setItem('stv.domain.good',
    JSON.stringify({ name: good, at: Date.now() - (7 * 60 * 60 * 1000) }));
  const staleApp = installFakeApp(stale, mirrorOptions());
  vm.runInContext(loadBlocks().join('\n'), stale);
  await tick(300);
  check('an expired remembered mirror is ignored',
    staleApp.net.networkManager.bestDomain() === bad,
    staleApp.net.networkManager.bestDomain());

  // A forged entry pointing somewhere the site does not know is ignored, so a
  // tampered localStorage cannot redirect the app to another origin.
  const forged = makeSandbox();
  forged.localStorage.setItem('stv.domain.good',
    JSON.stringify({ name: 'https://evil.example', at: Date.now() }));
  const forgedApp = installFakeApp(forged, mirrorOptions());
  vm.runInContext(loadBlocks().join('\n'), forged);
  await tick(300);
  check('a remembered mirror outside the site list is ignored',
    forgedApp.net.networkManager.bestDomain() === bad,
    forgedApp.net.networkManager.bestDomain());

  // A mirror that answered code 7 must not stay remembered.
  const poisoned = makeSandbox();
  poisoned.localStorage.setItem('stv.domain.good',
    JSON.stringify({ name: bad, at: Date.now() }));
  const poisonedApp = installFakeApp(poisoned, mirrorOptions());
  poisonedApp.reader.getContent = function () {
    const domain = poisonedApp.net.networkManager.bestDomain();
    return Promise.resolve(domain === bad ? { code: 7 } : { code: 0, data: 'chapter' });
  };
  vm.runInContext(loadBlocks().join('\n'), poisoned);
  await tick(300);
  const recovered = await poisonedApp.reader.getContent('qidian', '1', 'c1');
  // Parse before comparing: the entry is a JSON object whose `name` field must
  // not equal the rejected mirror, and a substring test could be fooled by the
  // rejected URL appearing inside an unrelated field or host.
  const stillRememberedRaw = poisoned.localStorage.getItem('stv.domain.good');
  const stillRememberedName = stillRememberedRaw
    ? JSON.parse(stillRememberedRaw).name
    : null;
  check('a remembered mirror that fails is dropped',
    String(recovered.code) === '0' && stillRememberedName !== bad,
    'still remembering ' + String(stillRememberedName));

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

/**
 * The main shell the download-list jump drives: #mainview with #mainnavbar
 * (home / search / community / user) and #tabtusach, whose last tabitem is the
 * download list (_page_vip.html:135-166; the list itself is
 * <tabview id="downloadedlist"> at :162). Each tab carries a `current()` like
 * the one /stv.ui.js attaches, and the tabitems move it, so the jump can verify
 * itself exactly the way it does on device.
 */
function shellFixture(pushedPages) {
  const mainview = makeContainer('tab', '');
  mainview.id = 'mainview';
  const navbar = makeContainer('tabbar', '');
  navbar.id = 'mainnavbar';
  const clicks = [];
  const navItems = ['home', 'search', 'community', 'user'].map((text, index) => {
    const item = makeContainer('tabitem', '', text);
    item.addEventListener('click', () => { clicks.push('main' + index); });
    navbar.appendChild(item);
    return item;
  });

  const tusach = makeContainer('tab', '');
  tusach.id = 'tabtusach';
  const subbar = makeContainer('tabbar', '');
  let current = 0;
  const subItems = ['history', 'follow', 'bookmark', 'novel_owner', 'download']
    .map((text, index) => {
      const item = makeContainer('tabitem', '', text);
      item.addEventListener('click', () => {
        clicks.push('sub' + index);
        current = index;
      });
      subbar.appendChild(item);
      return item;
    });
  tusach.current = () => current;
  tusach.appendChild(subbar);
  mainview.appendChild(navbar);
  mainview.appendChild(tusach);

  const overlay = makeContainer('div', '');
  overlay.id = 'overlay';
  for (let i = 0; i < (pushedPages || 0); i += 1) {
    overlay.appendChild(makeContainer('div', 'pushed'));
  }
  return {
    mainview,
    navbar,
    navItems,
    tusach,
    subbar,
    subItems,
    overlay,
    clicks,
    currentIndex: () => current,
  };
}

async function testDownloadStartedDialog() {
  console.log('the "download started" dialog and the jump to the download list');
  const chapters = [];
  for (let i = 1; i <= 12; i += 1) { chapters.push({ cid: 'c' + i }); }

  const shell = shellFixture(3);
  const sandbox = makeSandbox();
  sandbox.document.body.appendChild(shell.mainview);
  sandbox.document.body.appendChild(shell.overlay);
  sandbox.getChapterList = async () => chapters;
  // Hold the chapter requests open so the job stays in flight: the second
  // confirm below has to find a live job.
  const app = installFakeApp(sandbox, { displayType: 'auto', slowChapter: true });
  app.context = {
    menu: {
      downloadchapter: {
        body: '<input class="bookid"/><input class="bookhost"/>'
          + '<input class="numstart"/><input class="numend"/>',
        action: { startdownload: async function () {}, cancel: function () {} },
      },
    },
    showPopup(template) {
      (sandbox.__stored.popups = sandbox.__stored.popups || []).push(template);
      return makeContainer('div', 'popupedit');
    },
  };
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(400);

  const menu = app.context.menu.downloadchapter;
  const inputs = {
    '.bookhost': { value: 'qidian' },
    '.bookid': { value: '1034915599' },
    '.numstart': { value: '1' },
    '.numend': { value: '12' },
  };
  const popup = { q: (selector) => inputs[selector] || null };
  await menu.action.startdownload.call({ cancel() {} }, popup);
  await tick(60);

  const popups = sandbox.__stored.popups || [];
  const started = popups[popups.length - 1];
  check('a confirmation dialog is shown after the download starts',
    !!started && started.title === '已开始下载', started ? started.title : 'no dialog');
  check('the dialog names the range that was queued',
    !!started && started.body.indexOf('第 1 - 12 章') >= 0,
    started ? started.body : 'no dialog');
  check('the dialog offers a jump to the download list',
    !!started && started.button.indexOf('action=stvqueue') >= 0
      && started.button.indexOf('查看下载') >= 0,
    started ? started.button : 'no dialog');
  check('the dialog can also just be closed',
    !!started && started.button.indexOf('action=stvclose') >= 0,
    started ? started.button : 'no dialog');

  // The site dispatches a button press to action[name](pop) (app.v2.js:2218).
  const ctxOverlay = makeContainer('div', '');
  ctxOverlay.id = 'ctxoverlay';
  let hidden = 0;
  ctxOverlay.hide = function () {
    hidden += 1;
    if (this.children.length) { this.removeChild(this.children[this.children.length - 1]); }
    return true;
  };
  const fakePop = makeContainer('div', 'popupedit');
  ctxOverlay.appendChild(fakePop);
  sandbox.document.body.appendChild(ctxOverlay);

  started.action.stvqueue(fakePop);
  check('the dialog closes itself on the way out',
    hidden === 1 && fakePop.parentNode === null,
    'hidden=' + hidden);
  check('every pushed page is closed first',
    shell.overlay.children.length === 0, String(shell.overlay.children.length));
  check('the pages are reported',
    String(sandbox.window.__stvDiag.text() || '')
      .indexOf('download list: closed 3 page(s)') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-260));

  await tick(800);
  check('the download tab ends up selected',
    shell.currentIndex() === 4, String(shell.currentIndex()));
  check('the home tab is selected first, then the download sub-tab',
    shell.clicks.join(',') === 'main0,sub4', shell.clicks.join(','));
  check('the jump is reported',
    String(sandbox.window.__stvDiag.text() || '')
      .indexOf('download tab selected by click') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-260));

  // A second confirm for a book that is already downloading says so instead of
  // queueing a duplicate.
  await menu.action.startdownload.call({ cancel() {} }, popup);
  await tick(60);
  const again = (sandbox.__stored.popups || []).slice(-1)[0];
  check('a duplicate start explains itself in the same dialog',
    !!again && again.title === '已在下载', again ? again.title : 'no dialog');
  check('the duplicate start added no job',
    app.bookDownloaderList.length === 1, String(app.bookDownloaderList.length));
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
      (sandbox.__stored.popups = sandbox.__stored.popups || []).push(template);
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

async function testDownloadPauseResume() {
  console.log('pausing a download stops it and resuming carries on');
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, {
    displayType: 'auto',
    slowChapter: true,
    bookInfoResponses: {
      '/mobile/bookinfo.php?hid=7&host=qidian': {
        book: { host: 'qidian', id: '7', chaptercount: '6' },
      },
    },
  });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(300);

  const text = () => String(sandbox.window.__stvDiag.text() || '');
  const job = new app.BookDownloadManager('qidian', '7',
    ['p1', 'p2', 'p3', 'p4', 'p5', 'p6']);
  job.status = makeElement('div');
  const run = job.start();
  await waitFor(() => (sandbox.__stored.chapterCalls || 0) === 3);

  // 暂停下载 while the batch is in flight. On the device those three were 429s
  // held open by the retry backoff, which is what made the download look
  // unstoppable: nothing consulted isPaused until the whole batch had settled.
  job.pause();
  check('the pause is reported', text().indexOf('paused qidian/7 at 0/6') >= 0,
    text().slice(-220));
  sandbox.__stored.releaseChapters(false, true);
  await run;
  await tick(80);
  check('a paused loop starts no further batch',
    (sandbox.__stored.chapterCalls || 0) === 3, String(sandbox.__stored.chapterCalls));
  check('the chapters the pause caught are kept for the resume',
    job.chapters.join(',') === 'p1,p2,p3,p4,p5,p6', job.chapters.join(','));
  check('a paused chapter is not counted as a give-up',
    text().indexOf('gave up') < 0, text().slice(-260));
  check('the row says stopped instead of the 429 read error',
    job.status.textContent === 'Đã dừng', JSON.stringify(job.status.textContent));
  check('the job stays paused', job.isPaused === true);

  // 继续下载: the range has to be picked back up and finished.
  const again = job.start();
  await waitFor(() => (sandbox.__stored.chapterCalls || 0) === 6);
  sandbox.__stored.releaseChapters(true);
  await again;
  await tick(80);
  check('the resume fetches the whole range and finishes',
    job.downloaded === 6 && job.chapters.length === 0,
    job.downloaded + '/' + job.total + ' left=' + job.chapters.join(','));
  check('no chapter of the range is skipped',
    ['p1', 'p2', 'p3', 'p4', 'p5', 'p6']
      .every((chapter) => (sandbox.__stored.chapters || []).indexOf(chapter) >= 0),
    JSON.stringify(sandbox.__stored.chapters));
  check('the finished job says so', job.status.textContent === 'Hoàn thành',
    JSON.stringify(job.status.textContent));

  // 继续下载 tapped while the paused loop is still finishing its batch: the tap
  // used to be swallowed ("start() ignored while a loop is running"), the reader
  // saw the 429 error, and the download carried on by itself later.
  const second = makeSandbox();
  const secondApp = installFakeApp(second, {
    displayType: 'auto',
    slowChapter: true,
    bookInfoResponses: {
      '/mobile/bookinfo.php?hid=8&host=qidian': {
        book: { host: 'qidian', id: '8', chaptercount: '5' },
      },
    },
  });
  vm.runInContext(loadBlocks().join('\n'), second);
  await tick(300);
  const secondText = () => String(second.window.__stvDiag.text() || '');
  const job2 = new secondApp.BookDownloadManager('qidian', '8',
    ['q1', 'q2', 'q3', 'q4', 'q5']);
  job2.status = makeElement('div');
  const run2 = job2.start();
  await waitFor(() => (second.__stored.chapterCalls || 0) === 3);
  job2.pause();
  const resumed = job2.start();
  check('a resume during the paused batch is taken in place, not swallowed',
    job2.isPaused === false
      && secondText().indexOf('resumed in place for qidian/8') >= 0,
    secondText().slice(-220));
  check('the in-place resume is not logged as an ignored start',
    secondText().indexOf('start() ignored while a loop is running for qidian/8') < 0,
    secondText().slice(-220));
  second.__stored.releaseChapters();
  await waitFor(() => (second.__stored.chapterCalls || 0) === 5);
  second.__stored.releaseChapters(true);
  await Promise.all([run2, resumed]);
  await tick(80);
  check('the loop carries on through the rest of the range',
    job2.downloaded === 5 && job2.chapters.length === 0,
    job2.downloaded + '/' + job2.total + ' left=' + job2.chapters.join(','));
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
  // "长按小说名字会弹出选项，现在会默认选择文字": the site only ever sets the
  // unprefixed user-select (app.v2.css:28, :89, :156), so the iOS long-press
  // selection and callout were still live under the menu.
  check('book cells suppress the iOS long-press selection and callout',
    css.indexOf('.booksquare, .booksquarecont') >= 0
      && css.indexOf('-webkit-touch-callout: none') >= 0
      && css.indexOf('-webkit-user-select: none') >= 0, css);
  check('the long-press menu itself is not selectable either',
    css.indexOf('.contextmenu, .contextmenu .contextmenuitem') >= 0, css);
  check('the injected sheet never re-enables text selection',
    css.indexOf('user-select: text') < 0, css);

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
  const record = { host: 'qidian', id: '1034915599', key: 'offlineBook_qidian_1034915599' };
  const book = {
    baseObject: record,
    chapters: ['1', '2', '3', '4'],
    getChapterDownloaded() { return Promise.resolve(this.chapters); },
    deleteChapter(chapter) {
      deleted.push('chapter:' + chapter);
      const index = this.chapters.indexOf(chapter);
      if (index >= 0) { this.chapters.splice(index, 1); }
      return Promise.resolve();
    },
    // Verbatim from the site: the wrapper goes in, store.data holds the record,
    // and the identity lookup misses -- so the book came back on the next launch.
    delete() { deleted.push('delete'); return app.offlineBook.store.remove(this); },
  };
  const app = installFakeApp(sandbox, {
    displayType: 'auto',
    offlineBooks: [record],
    bookInfoResponses: {
      [url]: { book: { host: 'qidian', id: '1034915599', lid: '3972206', chaptercount: '310' } },
    },
    existedBook: book,
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

  // Downloading the same book again is a NEW job, so `manager.__stvMoved` does
  // not guard it and the row it appends used to sit next to the one already on
  // screen: "多次下载同一本书...会有多条记录", every copy exporting the same
  // chapter file. The row carries its own key, so the older one is dropped.
  const again = new app.BookDownloadManager('qidian', '1034915599', ['c3']);
  await again.start();
  await waitFor(() => rendered.length === 2, 5000);
  const sameBook = manager.children.filter((child) => child.getAttribute
    && child.getAttribute('data-stvbook') === 'qidian/1034915599');
  check('a second download of the same book leaves one DOWNLOADED row',
    sameBook.length === 1, String(sameBook.length));
  check('the dropped duplicate is reported',
    String(sandbox.window.__stvDiag.text() || '')
      .indexOf('dropped 1 earlier row(s) for qidian/1034915599') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-300));

  // The row is appended to #download-manager's parent, i.e. after the
  // "DOWNLOADED" header inside the manager wrapper (page-vip:2292-2298).
  const row = manager.children[manager.children.length - 1];
  const buttons = row.querySelectorAll('button');
  check('the downloaded row gets a delete button and an export button',
    buttons.length === 2 && buttons[0].textContent === '删除'
      && buttons[1].textContent === '导出',
    JSON.stringify(buttons.map((button) => button.textContent)));
  app.offlineBook.offlineBookSingletons['qidian_1034915599'] = book;
  buttons[0].__fire('click', { stopPropagation() {}, preventDefault() {} });
  await waitFor(() => deleted.indexOf('delete') >= 0, 3000);
  await tick(60);
  check('every chapter body is deleted, not every other one',
    deleted.join(',') === 'chapter:1,chapter:2,chapter:3,chapter:4,delete',
    deleted.join(','));
  check('the record is really out of the store, so a restart cannot revive it',
    app.offlineBook.store.data.indexOf(record) < 0,
    JSON.stringify(app.offlineBook.store.data));
  check('the cached book object is dropped so a re-download rebuilds it',
    app.offlineBook.offlineBookSingletons['qidian_1034915599'] === undefined,
    String(typeof app.offlineBook.offlineBookSingletons['qidian_1034915599']));
  check('the record list is saved', (sandbox.__stored.storeSaves || 0) >= 1,
    String(sandbox.__stored.storeSaves));
  check('the saved list no longer holds the book',
    String(sandbox.__stored.savedData || '').indexOf('1034915599') < 0,
    String(sandbox.__stored.savedData));
  check('the row is removed from the page', row.parentElement === null);
  check('the wipe is reported',
    String(sandbox.window.__stvDiag.text() || '')
      .indexOf('wiped 4 chapter file(s) for qidian/1034915599') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-260));
  check('the delete is reported',
    String(sandbox.window.__stvDiag.text() || '')
      .indexOf('removed downloaded book qidian/1034915599') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-260));

  // A resume replays the loop once it has exited, so the completion hand-off can
  // run twice for the same job; the second pass must not append a second row.
  // (Two rows exist by now: the first job's and the re-download's.)
  await job.start();
  await tick(80);
  check('replaying a finished job adds no second DOWNLOADED row',
    rendered.length === 2, String(rendered.length));
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

  // The native side refuses keys outside its allow-list and values over its size
  // cap. A swallowed rejection would look exactly like "this setting was never
  // backed up", so it has to reach the panel.
  const refused = makeSandbox();
  const refusedApp = installFakeApp(refused, {
    displayType: 'auto',
    settingsSaveRejects: ['config.reader'],
  });
  vm.runInContext(loadBlocks().join('\n'), refused);
  await tick(250);
  await refusedApp.storage.set('config.reader', '{"display_type":"pageflip"}');
  await refusedApp.storage.set('config.reader', '{"display_type":"pageflip"}');
  await tick(60);
  check('a refused keychain backup is not silently dropped',
    refused.__keychain['config.reader'] === undefined);
  const refusedDiag = String(refused.window.__stvDiag.text());
  check('the refusal is reported to the panel',
    refusedDiag.indexOf('keychain backup refused config.reader') >= 0,
    refusedDiag.slice(-240));
  check('the refusal is reported once per key, not once per write',
    refusedDiag.split('keychain backup refused config.reader').length - 1 === 1,
    refusedDiag.slice(-240));

  // A single refusal from the native origin guard must not latch "already
  // restored" and cost the whole page load its backup.
  const retry = makeSandbox();
  installFakeApp(retry, {
    displayType: 'auto',
    settingsRestoreFails: 1,
    keychain: { 'config.reader': '{"display_type":"pageflip","show_title":false}' },
  });
  vm.runInContext(loadBlocks().join('\n'), retry);
  await tick(400);
  check('a refused restore is retried instead of being given up on',
    retry.localStorage.getItem('config.reader')
      === '{"display_type":"pageflip","show_title":false}',
    String(retry.localStorage.getItem('config.reader')));
  check('the refusal itself is reported',
    String(retry.window.__stvDiag.text()).indexOf('settingsRestore failed') >= 0,
    String(retry.window.__stvDiag.text()).slice(-240));

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

/**
 * The detail page's like button is bound to `app.api.likeBook`, which only ever
 * runs `ajax=like` (page-vip:4220, app.v2.js:4914) -- so tapping an already
 * liked book re-liked it and "点赞后取消没反应". The endpoint the reader needs
 * already exists (`app.api.unlike`); the wrapper picks between the two from the
 * same status call the site's own `updateBookPage` uses.
 */
/**
 * "取消点赞后会提示取消，但是实际没有取消" -- the toggle read its state from
 * queryBookExtStatus, which answers with the BOOK's own record, so `like`
 * remained true after a successful unlike and all four taps in the device log
 * took the removal path, twenty seconds apart, on a freshly opened page. The
 * state now comes from querylikestatus (`type:id`, the same key like()/unlike()
 * take) and nothing is claimed until the site agrees.
 */
async function testLikeToggle() {
  console.log('like toggles back off');
  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, { displayType: 'auto' });

  // Both buttons on the detail page (page-vip:334 and :372). Only the first
  // carries the counter, and the second must not grow one.
  const stat = makeContainer('div', 'book-tag blk-item likebook active');
  const counter = makeContainer('span', 'liked', '25');
  stat.appendChild(counter);
  sandbox.document.body.appendChild(stat);
  const actionCell = makeContainer('div', 'blk-item likebook');
  sandbox.document.body.appendChild(actionCell);

  let myLikes = ['1034915599'];
  const likes = [];
  const unlikes = [];
  const statusCalls = [];
  // The aggregate that made the previous revision lie: always true.
  app.api.queryBookExtStatus = () => {
    statusCalls.push('status');
    return Promise.resolve({ like: true, bookmark: false, follow: false });
  };
  app.api.queryLike = (list) => {
    statusCalls.push('querylikestatus:' + list.join(','));
    return Promise.resolve(myLikes.map((objectid) => ({ objectid })));
  };
  app.api.likeBook = function (bookinfo) {
    likes.push(bookinfo.host + '/' + bookinfo.id);
    myLikes = [String(bookinfo.id)];
    return Promise.resolve({ code: 100 });
  };
  app.api.unlike = function (host, id) {
    unlikes.push(host + '/' + id);
    myLikes = [];
    return Promise.resolve({ code: 100 });
  };
  // The button's only writer (app.v2.js:4932). It re-asks the aggregate, so
  // without the wrapper it re-lights the thumbs-up right after a verified
  // unlike -- indistinguishable from "the cancellation did nothing".
  app.api.updateBookPage = function (p, bookinfo) {
    return app.api.queryBookExtStatus(bookinfo).then((status) => {
      const nodes = sandbox.document.querySelectorAll('.likebook');
      for (let i = 0; i < nodes.length; i += 1) {
        if (status.like) { nodes[i].classList.add('active'); }
        else { nodes[i].classList.remove('active'); }
      }
    });
  };

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(250);
  check('the like wrapper is installed', app.api.__stvLikeWrapped === true);

  const book = { host: 'qidian', id: '1034915599', name: '这些仙子全都不正常！' };
  await app.api.likeBook(book);
  await tick(40);
  check('the state comes from the endpoint that shares the like key space',
    String(statusCalls[0] || '').indexOf('querylikestatus') === 0, statusCalls.join('|'));
  check('an already liked book is unliked instead of liked again',
    unlikes.join(',') === 'qidian/1034915599' && likes.length === 0,
    'likes=' + likes.join(',') + ' unlikes=' + unlikes.join(','));
  check('every like button drops its active state',
    !stat.classList.contains('active') && !actionCell.classList.contains('active'),
    stat.className + ' | ' + actionCell.className);
  check('the counter next to the button drops by one', counter.textContent === '24',
    String(counter.textContent));
  check('the cancellation is claimed only after the site agrees',
    String(sandbox.window.__stvDiag.text() || '')
      .indexOf('after unlike(object): querylikestatus liked=false') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-300));

  // The site's own render pass still asks the aggregate, which says "liked".
  await app.api.updateBookPage(null, book);
  await tick(40);
  check('the site own render pass cannot re-light the button',
    !stat.classList.contains('active') && !actionCell.classList.contains('active'),
    stat.className + ' | ' + actionCell.className);
  check('the aggregate really was the disagreeing answer',
    statusCalls.indexOf('status') >= 0, statusCalls.join('|'));

  // Tapping again: querylikestatus now says "not liked", so the add path has to
  // run and the counter goes back up.
  await app.api.likeBook(book);
  await tick(40);
  check('an unliked book is liked through the site endpoint',
    likes.length === 1 && unlikes.length === 1,
    'likes=' + likes.join(',') + ' unlikes=' + unlikes.join(','));
  check('the button shows as active again', stat.classList.contains('active'));
  check('the counter goes back up', counter.textContent === '25',
    String(counter.textContent));

  // A removal the server accepts and does not apply: the previous revision
  // toasted "已取消点赞" regardless. It has to report the disagreement instead.
  const stuck = makeSandbox();
  const stuckApp = installFakeApp(stuck, { displayType: 'auto' });
  stuckApp.api.queryLike = () => Promise.resolve([{ objectid: '1034915599' }]);
  stuckApp.api.unlike = () => Promise.resolve({ code: 100 });
  stuckApp.api.likeBook = () => Promise.resolve({ code: 100 });
  vm.runInContext(loadBlocks().join('\n'), stuck);
  await tick(250);
  await stuckApp.api.likeBook(book);
  await tick(40);
  check('an unlike that does not stick is not reported as a cancellation',
    (stuck.__stored.toasts || []).join('|').indexOf('已取消点赞') < 0
      && String(stuck.window.__stvDiag.text() || '').indexOf('liked=true') >= 0,
    JSON.stringify(stuck.__stored.toasts));

  // The 2026-09-23 logs, replayed. The object id is the form the site itself
  // uses -- app.api.unlike posts ajax=unlike&type=&id= (app.v2.js:4917-4931) --
  // and the server accepts it (code 100) without deleting anything, while a row
  // id comes back as {"text":"Không tìm thấy lịch sử.","code":101}: the endpoint
  // looks its id up in the reading history, not in the like table, and the site
  // only ever calls unlike for community topics. There is no book-unlike
  // contract to find, so the ladder is gone: one attempt, one verification, and
  // the honest answer.
  const oneShot = makeSandbox();
  const oneShotApp = installFakeApp(oneShot, { displayType: 'auto' });
  const shotAttempts = [];
  const shotRows = [{ type: 'qidian', objectid: '1034915599', id: '2541666' },
    { type: 'qidian', objectid: '1034915599', id: '2541667' }];
  oneShotApp.api.queryLike = () => Promise.resolve(shotRows.slice());
  oneShotApp.api.unlike = function (host, id) {
    shotAttempts.push(host + '/' + id);
    return Promise.resolve({ code: id === '1034915599' ? 100 : 0 });
  };
  oneShotApp.api.likeBook = () => Promise.resolve({ code: 100 });
  vm.runInContext(loadBlocks().join('\n'), oneShot);
  await tick(250);
  await oneShotApp.api.likeBook(book);
  await tick(150);
  check('the unlike is sent once, in the only form the site documents',
    shotAttempts.join('|') === 'qidian/1034915599', shotAttempts.join('|'));
  check('no row id is ever used as a delete key',
    shotAttempts.indexOf('qidian/2541666') < 0
      && shotAttempts.indexOf('qidian/2541667') < 0,
    shotAttempts.join('|'));
  check('the button says the site does not support it instead of claiming success',
    (oneShot.__stored.toasts || []).join('|').indexOf('已取消点赞') < 0
      && (oneShot.__stored.toasts || []).join('|').indexOf('站点不支持取消这个赞') >= 0,
    JSON.stringify(oneShot.__stored.toasts));
  check('the button stays lit when the site kept the like',
    String(oneShot.window.__stvDiag.text() || '')
      .indexOf('the button stays as the site has it') >= 0,
    String(oneShot.window.__stvDiag.text() || '').slice(-300));

  // The endpoint can be missing (an older mirror build): fall back to the site's
  // own extended status rather than deciding nothing.
  const legacy = makeSandbox();
  const legacyApp = installFakeApp(legacy, { displayType: 'auto' });
  let legacyLiked = true;
  legacyApp.api.queryBookExtStatus = () => Promise.resolve({ like: legacyLiked });
  legacyApp.api.likeBook = () => { legacyLiked = true; return Promise.resolve({ code: 100 }); };
  legacyApp.api.unlike = () => { legacyLiked = false; return Promise.resolve({ code: 100 }); };
  vm.runInContext(loadBlocks().join('\n'), legacy);
  await tick(250);
  await legacyApp.api.likeBook(book);
  await tick(40);
  check('without querylikestatus the site status is still used',
    String(legacy.window.__stvDiag.text() || '')
      .indexOf('querybookmarkstatus liked=true') >= 0,
    String(legacy.window.__stvDiag.text() || '').slice(-260));

  // A reader who is not logged in: querylikestatus answers an empty list and the
  // site's own like() raises the login prompt.
  const anon = makeSandbox();
  const anonApp = installFakeApp(anon, { displayType: 'auto' });
  const anonLikened = [];
  anonApp.api.queryLike = () => Promise.resolve([]);
  anonApp.api.likeBook = () => { anonLikened.push('like'); return Promise.resolve({ code: 0 }); };
  anonApp.api.unlike = () => { anonLikened.push('unlike'); return Promise.resolve({ code: 0 }); };
  vm.runInContext(loadBlocks().join('\n'), anon);
  await tick(250);
  await anonApp.api.likeBook(book);
  await tick(40);
  check('a signed-out tap still goes to the site own like path',
    anonLikened.join(',') === 'like', anonLikened.join(','));
}

/**
 * "第二次继续下载 1-20 还是会创建新的下载任务，应该要检查已下载的章节" -- the
 * range dialog handed every id in [start, end] to a brand new job. OfflineBook
 * already knows what is on disk (`getChapterDownloaded`, app.v2.read.js:3317),
 * so only the missing chapters may be queued.
 */
async function testDownloadSkipsDownloaded() {
  console.log('a re-run range only queues the missing chapters');
  const sandbox = makeSandbox();
  sandbox.getChapterList = async () => {
    const list = [];
    for (let i = 1; i <= 30; i += 1) { list.push({ cid: 'c' + i }); }
    return list;
  };
  const app = installFakeApp(sandbox, {
    displayType: 'auto',
    slowChapter: true,
    alreadyDownloaded: ['c1', 'c2', 'c3', 'c4', 'c5'],
  });

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
  endInput.value = '20';
  [hostInput, idInput, startInput, endInput]
    .forEach((node) => popupNode.appendChild(node));

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
    showPopup: (template) => {
      (sandbox.__stored.popups = sandbox.__stored.popups || []).push(template);
      return popupNode;
    },
  };

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(400);

  const action = app.context.menu.downloadchapter.action.startdownload;
  await action.call({ cancel() {} }, popupNode);
  await tick(60);
  const job = app.bookDownloaderList[app.bookDownloaderList.length - 1];
  check('chapters already on disk are not queued again',
    !!job && job.chaptersOrginal.length === 15
      && job.chaptersOrginal[0] === 'c6' && job.chaptersOrginal[14] === 'c20',
    JSON.stringify(job && job.chaptersOrginal));
  check('the remaining chapters still come from the chosen source',
    !!job && job.host === 'qidian' && job.id === '1034915599',
    job ? job.host + '/' + job.id : '(no job)');
  const diag = String(sandbox.window.__stvDiag.text() || '');
  check('the skip is reported',
    diag.indexOf('15 new chapter(s), 5 already downloaded') >= 0, diag.slice(-260));
  const opened = sandbox.__stored.popups[sandbox.__stored.popups.length - 1];
  check('the dialog says what was skipped',
    !!opened && String(opened.body).indexOf('已有 5 章') >= 0,
    JSON.stringify(opened && opened.body));

  // A range that is entirely on disk must not create a job at all. The first
  // job is dropped first: a live job for the same book is ignored on purpose.
  app.bookDownloaderList.length = 0;
  startInput.value = '1';
  endInput.value = '5';
  await action.call({ cancel() {} }, popupNode);
  await tick(60);
  check('a fully downloaded range creates no job',
    app.bookDownloaderList.length === 0, String(app.bookDownloaderList.length));
  const closed = sandbox.__stored.popups[sandbox.__stored.popups.length - 1];
  check('the dialog says there is nothing left to download',
    !!closed && closed.title === '无需重复下载'
      && String(closed.body).indexOf('都已经下载过了') >= 0,
    JSON.stringify(closed && { title: closed.title, body: closed.body }));
}

/** Read a ZIP the way a reader would, so the writer is checked, not restated. */
function readZip(buffer) {
  let eocd = -1;
  for (let i = buffer.length - 22; i >= 0; i -= 1) {
    if (buffer.readUInt32LE(i) === 0x06054B50) { eocd = i; break; }
  }
  if (eocd < 0) { throw new Error('no end-of-central-directory record'); }
  const count = buffer.readUInt16LE(eocd + 10);
  let at = buffer.readUInt32LE(eocd + 16);
  const entries = [];
  for (let i = 0; i < count; i += 1) {
    if (buffer.readUInt32LE(at) !== 0x02014B50) {
      throw new Error('bad central directory header at ' + at);
    }
    const method = buffer.readUInt16LE(at + 10);
    const crc = buffer.readUInt32LE(at + 16);
    const compressed = buffer.readUInt32LE(at + 20);
    const size = buffer.readUInt32LE(at + 24);
    const nameLength = buffer.readUInt16LE(at + 28);
    const extraLength = buffer.readUInt16LE(at + 30);
    const commentLength = buffer.readUInt16LE(at + 32);
    const offset = buffer.readUInt32LE(at + 42);
    const name = buffer.toString('utf8', at + 46, at + 46 + nameLength);
    const localNameLength = buffer.readUInt16LE(offset + 26);
    const localExtraLength = buffer.readUInt16LE(offset + 28);
    const start = offset + 30 + localNameLength + localExtraLength;
    entries.push({
      name, method, crc, compressed, size,
      data: buffer.subarray(start, start + compressed),
    });
    at += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

/**
 * CRC32 without a lookup table. The committed check uses zlib.crc32 when the
 * runtime has it (Node 22+); this is the fallback, and either way it is a
 * second implementation rather than a restatement of the block's own.
 */
function slowCrc32(buffer) {
  let crc = 0xFFFFFFFF;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc & 1) ? ((crc >>> 1) ^ 0xEDB88320) : (crc >>> 1);
    }
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

function crcOf(buffer) {
  return typeof zlib.crc32 === 'function' ? zlib.crc32(buffer) : slowCrc32(buffer);
}

/**
 * The downloaded rows only ever offered 删除, so a book the reader had paid to
 * download could not leave the app. The export button builds the TXT or the
 * EPUB in the page and hands the bytes to App.exportFile, which writes the file
 * and raises the share sheet.
 */
async function testExportDownloadedBook() {
  console.log('export a downloaded book');
  const prefix = 'offlineBook_qidian_1034915599_';
  const ids = ['7001', '7002', '7003'];
  const files = {};
  ids.forEach((cid, index) => {
    files[prefix + cid] = JSON.stringify({
      code: '0',
      // readchapter answers with the site's Vietnamese machine translation. The
      // third chapter carries no number at all, which is the case the chapter
      // list's own order has to cover.
      chaptername: index === 2 ? 'Không có số hiệu'
        : 'Chương ' + (index + 1) + ': <mở đầu>',
      // Every body ends with the site's own archive notice, which must not
      // reach the exported file.
      data: '<p>第一段 &amp; 第二段</p><p>第三段</p>'
        + '<p>@Bạn đang đọc bản lưu trong hệ thống</p>',
    });
  });

  const sandbox = makeSandbox();
  const app = installFakeApp(sandbox, {
    displayType: 'auto',
    chapterFiles: files,
    // The only place the original chapter names exist (app.v2.js:270).
    oridata: '1-/-7001-/-交锋-/-vip-//-2-/-7002-/-入门-/-vip-//-3-/-7003-/-决战-/-vip',
    existedBook: {
      host: 'qidian',
      id: '1034915599',
      baseObject: { chapterPreKey: prefix },
      getChapterDownloaded: () => Promise.resolve(ids.slice()),
      getChapter: (cid) => Promise.resolve(files[prefix + cid]),
    },
    httpGetResponse: () => ({
      status: 200,
      data: Buffer.from('FAKE-JPEG-BYTES').toString('base64'),
    }),
  });

  // The row's own action bar: pageRepair builds it and asks the export block for
  // this button. The format dialog goes through the site's own popup
  // (app.context.showPopup), so the stub records it.
  const row = makeContainer('div', 'bookrowcont');
  sandbox.document.body.appendChild(row);
  app.context = {
    showPopup(template) {
      (sandbox.__stored.popups = sandbox.__stored.popups || []).push(template);
      return makeContainer('div', 'popupedit');
    },
  };
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(400);
  check('the export block publishes its API', !!sandbox.window.__stvExport);

  const book = {
    host: 'qidian',
    id: '1034915599',
    name: '这些仙子全都不正常！',
    author: '叁司',
    thumb: 'https://bookcover.yuewen.com/qdbimg/349573/1034915599/180',
  };
  const exportButton = sandbox.window.__stvExport.button(book);
  check('the export button exists', !!exportButton && exportButton.textContent === '导出',
    exportButton && exportButton.textContent);

  exportButton.__fire('click', { stopPropagation() {}, preventDefault() {} });
  const choices = sandbox.__stored.popups || [];
  const dialog = choices[choices.length - 1];
  check('the format dialog is offered',
    !!dialog && String(dialog.button).indexOf('stvtxt') >= 0
      && String(dialog.button).indexOf('stvepub') >= 0,
    JSON.stringify(dialog && dialog.button));

  // ---- TXT ----
  dialog.action.stvtxt(makeContainer('div', 'popupedit'));
  await waitFor(() => (sandbox.__stored.exports || []).length === 1, 5000);
  const txt = sandbox.__stored.exports[0];
  const txtBody = Buffer.from(txt.data, 'base64').toString('utf8');
  check('the txt is named after the book',
    txt.filename === '这些仙子全都不正常！.txt', txt.filename);
  check('the txt carries the title, author and source',
    txtBody.indexOf('这些仙子全都不正常！') === 0
      && txtBody.indexOf('作者：叁司') >= 0
      && txtBody.indexOf('来源：qidian / 1034915599') >= 0,
    txtBody.slice(0, 120));
  check('the txt headings are Chinese, numbered and in download order',
    txtBody.indexOf('第1章 交锋') >= 0
      && txtBody.indexOf('第2章 入门') > txtBody.indexOf('第1章 交锋')
      && txtBody.indexOf('Chương') < 0,
    txtBody.slice(0, 300));
  // The third chapter has no number in the site's own title, so the heading has
  // to take its place from the book's chapter list -- the export's own index
  // would number a 15-30 download from 1.
  check('a heading the source left unnumbered takes the book chapter number',
    txtBody.indexOf('第3章 决战') >= 0, txtBody.slice(-200));
  check('the heading relabelling is reported to the panel',
    String(sandbox.window.__stvDiag.text() || '')
      .indexOf('chapter headings: 3 of 3 carry a Chinese name, first=第1章 交锋') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-320));
  check('the chapter markup is reduced to text',
    txtBody.indexOf('第一段 & 第二段') >= 0 && txtBody.indexOf('<p>') < 0,
    txtBody.slice(0, 300));
  check('the site archive notice is stripped from the exported text',
    txtBody.indexOf('bản lưu') < 0 && txtBody.indexOf('第三段') >= 0,
    txtBody.slice(0, 300));
  check('the export is reported to the panel',
    String(sandbox.window.__stvDiag.text() || '').indexOf('read 3 of 3 chapter(s)') >= 0,
    String(sandbox.window.__stvDiag.text() || '').slice(-260));
  check('the button is usable again after the export',
    exportButton.textContent === '导出' && exportButton.__stvExportBusy === false,
    exportButton.textContent);

  // ---- EPUB ----
  exportButton.__fire('click', { stopPropagation() {}, preventDefault() {} });
  const epubDialog = (sandbox.__stored.popups || [])[
    (sandbox.__stored.popups || []).length - 1];
  epubDialog.action.stvepub(makeContainer('div', 'popupedit'));
  await waitFor(() => (sandbox.__stored.exports || []).length === 2, 5000);
  const epub = sandbox.__stored.exports[1];
  check('the epub is named after the book and carries the epub mime type',
    epub.filename === '这些仙子全都不正常！.epub'
      && epub.mime === 'application/epub+zip', epub.filename + ' ' + epub.mime);
  check('the cover is fetched as an arraybuffer',
    (sandbox.__stored.httpGet || []).length === 1
      && sandbox.__stored.httpGet[0].responseType === 'arraybuffer',
    JSON.stringify(sandbox.__stored.httpGet));

  const archive = Buffer.from(epub.data, 'base64');
  const entries = readZip(archive);
  const names = entries.map((entry) => entry.name);
  check('mimetype is the first entry', names[0] === 'mimetype', names.join(','));
  check('mimetype is stored uncompressed, as the format requires',
    entries[0].method === 0
      && entries[0].data.toString('utf8') === 'application/epub+zip',
    entries[0].data.toString('utf8'));
  check('every entry carries a correct CRC32',
    entries.every((entry) => crcOf(entry.data) === entry.crc),
    entries.map((entry) => entry.name + '=' + entry.crc).join(','));
  check('the archive holds the container, the opf, both navigation files and the cover',
    ['META-INF/container.xml', 'OEBPS/content.opf', 'OEBPS/nav.xhtml',
      'OEBPS/toc.ncx', 'OEBPS/images/cover.jpg', 'OEBPS/cover.xhtml']
      .every((name) => names.indexOf(name) >= 0),
    names.join(','));
  const byName = {};
  entries.forEach((entry) => { byName[entry.name] = entry.data.toString('utf8'); });
  check('the container points at the package document',
    byName['META-INF/container.xml'].indexOf('full-path="OEBPS/content.opf"') >= 0,
    byName['META-INF/container.xml']);
  check('the package document names the book and its author',
    byName['OEBPS/content.opf'].indexOf('<dc:title>这些仙子全都不正常！</dc:title>') >= 0
      && byName['OEBPS/content.opf'].indexOf('<dc:creator>叁司</dc:creator>') >= 0,
    byName['OEBPS/content.opf'].slice(0, 400));
  check('the spine orders every chapter',
    byName['OEBPS/content.opf'].indexOf('<itemref idref="chapter-0001"/>') >= 0
      && byName['OEBPS/content.opf'].indexOf('<itemref idref="chapter-0002"/>') >= 0
      && byName['OEBPS/content.opf'].indexOf('<itemref idref="cover"/>') >= 0,
    byName['OEBPS/content.opf'].slice(0, 600));
  check('the chapters are well-formed XHTML with escaped text',
    byName['OEBPS/chapter-0001.xhtml'].indexOf('第一段 &amp; 第二段') >= 0
      && byName['OEBPS/chapter-0001.xhtml'].indexOf('<h2>第1章 交锋</h2>') >= 0,
    byName['OEBPS/chapter-0001.xhtml'].slice(0, 400));
  check('the archive notice is stripped from the epub too',
    byName['OEBPS/chapter-0001.xhtml'].indexOf('bản lưu') < 0
      && byName['OEBPS/chapter-0001.xhtml'].indexOf('第三段') >= 0,
    byName['OEBPS/chapter-0001.xhtml'].slice(0, 400));
  // The body and the headings are Chinese, so the package has to say so: a
  // declared `vi` makes a reader lay the book out with Vietnamese rules.
  check('the epub declares the language of the text it carries',
    byName['OEBPS/content.opf'].indexOf('<dc:language>zh</dc:language>') >= 0
      && byName['OEBPS/chapter-0001.xhtml'].indexOf('xml:lang="zh"') >= 0
      && byName['OEBPS/content.opf'].indexOf('<dc:language>vi</dc:language>') < 0,
    byName['OEBPS/content.opf'].slice(0, 520));
  check('both navigation files carry the Chinese headings',
    byName['OEBPS/nav.xhtml'].indexOf('第1章 交锋') >= 0
      && byName['OEBPS/toc.ncx'].indexOf('第3章 决战') >= 0,
    byName['OEBPS/nav.xhtml'].slice(0, 300));
  check('the navigation lists every chapter',
    byName['OEBPS/nav.xhtml'].indexOf('chapter-0002.xhtml') >= 0
      && byName['OEBPS/toc.ncx'].indexOf('chapter-0002.xhtml') >= 0);
  check('the cover is embedded and referenced by the cover page',
    byName['OEBPS/cover.xhtml'].indexOf('images/cover.jpg') >= 0
      && entries.filter((entry) => entry.name === 'OEBPS/images/cover.jpg')
        .map((entry) => entry.data.toString('utf8')).join('') === 'FAKE-JPEG-BYTES',
    entries.map((entry) => entry.name).join(','));

  // The helpers the byte and name handling rests on, checked against the
  // platform's own encoders rather than against themselves.
  const utf8 = sandbox.window.__stvExport.textBytes('a汉𠮷z');
  check('the UTF-8 encoder agrees with the platform, including astral characters',
    Buffer.from(utf8).toString('hex')
      === Buffer.from('a汉𠮷z', 'utf8').toString('hex'),
    Buffer.from(utf8).toString('hex'));
  check('file names lose the characters iOS rejects',
    sandbox.window.__stvExport.safeName('a/b:c*?"<>|') === 'a_b_c_',
    sandbox.window.__stvExport.safeName('a/b:c*?"<>|'));
  check('a name that is nothing but separators still yields a file',
    sandbox.window.__stvExport.safeName('///') === '_',
    sandbox.window.__stvExport.safeName('///'));

  if (process.env.STV_EXPORT_DUMP) {
    const dir = path.join(__dirname, '..', '_export-check');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'book.txt'),
      Buffer.from(txt.data, 'base64'));
    fs.writeFileSync(path.join(dir, 'book.epub'), archive);
  }

  // A book with no chapters on disk must say so instead of exporting nothing.
  const empty = makeSandbox();
  installFakeApp(empty, {
    displayType: 'auto',
    existedBook: {
      host: 'qidian',
      id: '1',
      baseObject: { chapterPreKey: 'offlineBook_qidian_1_' },
      getChapterDownloaded: () => Promise.resolve([]),
      getChapter: () => Promise.resolve(''),
    },
  });
  vm.runInContext(loadBlocks().join('\n'), empty);
  await tick(300);
  const emptyBook = { host: 'qidian', id: '1', name: 'X' };
  const emptyButton = empty.window.__stvExport.button(emptyBook);
  await empty.window.__stvExport.run(emptyBook, 'txt', emptyButton);
  await tick(60);
  check('an empty book is refused with a message, not an empty file',
    (empty.__stored.exports || []).length === 0
      && (empty.__stored.toasts || []).join('|').indexOf('导出失败') >= 0,
    JSON.stringify(empty.__stored.toasts));
  check('the refusal reaches the diagnostics panel',
    String(empty.window.__stvDiag.text() || '').indexOf('没有读到章节内容') >= 0,
    String(empty.window.__stvDiag.text() || '').slice(-240));
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
      urlHost(url) === 'edge.microsoft.com'
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
  check('the panel never echoes a stored key back into the DOM',
    keyField.value === '', 'field empty: ' + String(keyField.value === ''));
  keyField.value = 'key-123';
  click(panel.querySelectorAll('.stv-translate-save')[0]);
  await tick(80);
  const saved = JSON.parse(sandbox.localStorage.getItem('stv.translate.settings') || '{}');
  check('the panel saves the engine', saved.engine === 'free', fieldsOf(saved));
  check('the key is NOT written to app.storage',
    saved.apiKey === '', 'apiKey empty: ' + String(saved.apiKey === ''));
  check('app.storage only records that a key exists',
    saved.hasApiKey === true, 'hasApiKey set: ' + String(saved.hasApiKey === true));
  check('the key went to the secret store instead',
    sandbox.__secrets['translate.apiKey'] === 'key-123',
    'secret store keys: ' + Object.keys(sandbox.__secrets).sort().join(','));
  check('the key field is emptied again after saving',
    keyField.value === '' && keyField.placeholder.indexOf('已保存') === 0,
    'field empty: ' + String(keyField.value === ''));

  click(panel.querySelectorAll('.stv-translate-test')[0]);
  await tick(150);
  const http = sandbox.__stored.http || [];
  check('the keyless Microsoft channel is used',
    http.length === 1
      && urlHost(http[0].url) === 'edge.microsoft.com'
      && String(http[0].url).indexOf('/translate/translatetext') >= 0,
    JSON.stringify(http.map((call) => urlHost(call.url))));
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
      urlHost(url) === 'edge.microsoft.com'
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
      // The key must NOT be in the query string: the native Http plugin writes
      // every request URL into the diagnostic panel, which has a COPY button.
      url: 'https://translation.googleapis.com/language/translate/v2',
      headers: (headers) => headers['X-goog-api-key'] === 'google-key',
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
      http.length ? 'sent header names: ' + Object.keys(http[0].headers).sort().join(',') : 'no request');
    check(item.engine + ': posts exactly the comment texts',
      http.length === 1
        && JSON.stringify(item.texts(http[0])) === JSON.stringify(['Một bình luận']),
      http.length ? JSON.stringify(item.texts(http[0])) : 'no request');
    const contents = fixture.view.querySelectorAll('.cmtcontent');
    check(item.engine + ': the answer lands in the comment body',
      contents[0].textContent === item.marker + 'Một bình luận', contents[0].textContent);
  }
}

/**
 * The API key is the one setting that must not sit in app.storage -- that store
 * is plaintext inside the app container and `settingsBackup` mirrors all of it
 * into the keychain backup -- and must never be echoed back into the DOM, which
 * shares a JS context with the site's own scripts.
 */
async function testTranslateKeyStorage() {
  console.log('translate API key storage');

  const openPanel = async (sandbox, settingsFixture) => {
    sandbox.app.pushPage('pagesetting', {});
    await tick(40);
    const entry = settingsFixture.content.querySelectorAll('.stv-translate-entry');
    click(entry[0]);
    await tick(60);
    return sandbox.document.getElementById('stv-translate-panel');
  };

  // An install that predates this change kept the key in plaintext.
  const fixture = settingsPageFixture();
  const sandbox = makeSandbox();
  sandbox.localStorage.setItem('stv.translate.settings', JSON.stringify({
    engine: 'google', apiKey: 'legacy-plaintext-key', region: '', endpoint: '',
    model: '', readSource: 'vi', readTarget: 'zh-Hans', writeTarget: 'vi', auto: false,
  }));
  const http = [];
  installFakeApp(sandbox, {
    appLanguage: 'zh',
    pages: { pagesetting: fixture.page },
    httpResponse: (url, payload) => {
      http.push({ url, headers: payload.headers });
      return {
        status: 200,
        data: { data: { translations: [{ translatedText: '【谷歌】ok' }] } },
      };
    },
  });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(250);

  const panel = await openPanel(sandbox, fixture);
  check('the translation panel opens', !!panel);
  if (!panel) { return; }

  const migrated = JSON.parse(sandbox.localStorage.getItem('stv.translate.settings') || '{}');
  check('a legacy plaintext key is moved into the secret store',
    sandbox.__secrets['translate.apiKey'] === 'legacy-plaintext-key',
    'secret store keys: ' + Object.keys(sandbox.__secrets).sort().join(','));
  check('the plaintext copy is rewritten out of app.storage',
    migrated.apiKey === '' && migrated.hasApiKey === true, fieldsOf(migrated));

  const keyField = panel.querySelectorAll('.stv-translate-key')[0];
  check('the stored key is not echoed into the DOM',
    keyField.value === '', 'field empty: ' + String(keyField.value === ''));
  check('the key field says a key is already saved',
    keyField.placeholder.indexOf('已保存') === 0,
    'placeholder starts saved: ' + String(keyField.placeholder.indexOf('已保存') === 0));

  // Saving with the field left empty must keep the key: the field is always
  // empty when a key is stored, so "empty" cannot mean "delete".
  click(panel.querySelectorAll('.stv-translate-save')[0]);
  await tick(80);
  check('saving an untouched panel keeps the stored key',
    sandbox.__secrets['translate.apiKey'] === 'legacy-plaintext-key',
    'secret store keys: ' + Object.keys(sandbox.__secrets).sort().join(','));
  check('and keeps the hasApiKey marker set',
    JSON.parse(sandbox.localStorage.getItem('stv.translate.settings') || '{}').hasApiKey === true,
    fieldsOf(JSON.parse(sandbox.localStorage.getItem('stv.translate.settings') || '{}')));

  // Typing a new key replaces it, and the field is masked again afterwards.
  keyField.value = 'replacement-key';
  click(panel.querySelectorAll('.stv-translate-save')[0]);
  await tick(80);
  check('a typed key replaces the stored one',
    sandbox.__secrets['translate.apiKey'] === 'replacement-key',
    'secret store keys: ' + Object.keys(sandbox.__secrets).sort().join(','));
  check('the field is emptied again after saving',
    keyField.value === '', 'field empty: ' + String(keyField.value === ''));
  check('the replacement key never reaches app.storage',
    JSON.parse(sandbox.localStorage.getItem('stv.translate.settings') || '{}').apiKey === '',
    fieldsOf(JSON.parse(sandbox.localStorage.getItem('stv.translate.settings') || '{}')));

  // The field is empty whenever a key is stored, so 测试 must resolve it to the
  // stored key rather than testing the engine without one.
  keyField.value = '';
  click(panel.querySelectorAll('.stv-translate-test')[0]);
  await tick(120);
  check('the 测试 button uses the stored key, not an empty one',
    http.length === 1 && http[0].headers['X-goog-api-key'] === 'replacement-key',
    'sent header names: ' + (http.length ? Object.keys(http[0].headers).sort().join(',') : 'none'));

  // 清除 is the only thing that removes it.
  click(panel.querySelectorAll('.stv-translate-key-clear')[0]);
  click(panel.querySelectorAll('.stv-translate-save')[0]);
  await tick(80);
  check('清除 removes the key from the secret store',
    sandbox.__secrets['translate.apiKey'] === undefined,
    'secret store keys: ' + Object.keys(sandbox.__secrets).sort().join(','));
  check('清除 clears the hasApiKey marker',
    JSON.parse(sandbox.localStorage.getItem('stv.translate.settings') || '{}').hasApiKey === false,
    fieldsOf(JSON.parse(sandbox.localStorage.getItem('stv.translate.settings') || '{}')));
}

/**
 * The site sends Cache-Control: max-age=86400 for /asset/* and then defeats it
 * by appending Math.random() to the URL of every bundle on the critical path
 * (_page_vip.html:5207-5211 and :3066), so the disk cache can never hit.
 */
async function testAssetCacheStabiliser() {
  console.log('asset cache-buster stabiliser');

  const sandbox = makeSandbox();
  installFakeApp(sandbox, { appLanguage: 'zh' });
  // The real web view has these; the stub has to model them for the property
  // hooks to be exercised at all.
  // The sandbox keeps a separate `window` object from the vm global (see
  // makeSandbox), and the blocks reach the DOM through `window.*`.
  const view = sandbox.window;
  const accessor = (store) => ({
    configurable: true,
    enumerable: true,
    get() { return store.value || ''; },
    set(value) { store.value = String(value); },
  });
  const scriptSrc = {};
  const linkHref = {};
  view.HTMLScriptElement = function () {};
  view.HTMLScriptElement.prototype = {};
  Object.defineProperty(view.HTMLScriptElement.prototype, 'src', accessor(scriptSrc));
  view.HTMLLinkElement = function () {};
  view.HTMLLinkElement.prototype = {};
  Object.defineProperty(view.HTMLLinkElement.prototype, 'href', accessor(linkHref));
  view.Element = function () {};
  view.Element.prototype = {
    setAttribute(name, value) {
      this.attrs = this.attrs || {};
      this.attrs[name] = String(value);
    },
  };

  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(60);

  const cache = view.__stvAssetCache;
  check('the asset cache block is installed', !!cache);
  if (!cache) { return; }
  check('it hooked every insertion path it could find', cache.hooks >= 3,
    String(cache.hooks));
  check('the token is stable within a load', cache.token === cache.token,
    cache.token);

  const stable = cache.token;
  // The generation counter, and deliberately not the date: a date in the token
  // changes every /asset/ URL at midnight UTC, so the first launch of every day
  // re-downloads the boot-critical trio even though the server's own
  // max-age=86400 would have served it from disk or revalidated it for a 304.
  check('the token carries the generation and not the date',
    /^stv[0-9]+$/.test(stable), stable);
  // The four cache-busted URLs the shell actually builds.
  check('a random query on a bundle is replaced with the stable token',
    cache.stabilize('/asset/app.v2.js?0.84921') === '/asset/app.v2.js?' + stable,
    cache.stabilize('/asset/app.v2.js?0.84921'));
  check('the ?r= cache-buster on the stylesheet is replaced too',
    cache.stabilize('/asset/app.v2.css?r=0.331') === '/asset/app.v2.css?r=' + stable,
    cache.stabilize('/asset/app.v2.css?r=0.331'));
  check('the bookdisplay bundle is stabilised',
    cache.stabilize('/asset/app.v2.bookdisplay.js?0.77')
      === '/asset/app.v2.bookdisplay.js?' + stable,
    cache.stabilize('/asset/app.v2.bookdisplay.js?0.77'));
  check('a second random value maps to the same URL',
    cache.stabilize('/asset/app.v2.js?0.111') === cache.stabilize('/asset/app.v2.js?0.999'),
    cache.stabilize('/asset/app.v2.js?0.111') + ' vs '
      + cache.stabilize('/asset/app.v2.js?0.999'));

  // The site's real version numbers are its version contract.
  check('a real version number is left alone',
    cache.stabilize('/stv.ui.js?v=1.360') === '/stv.ui.js?v=1.360',
    cache.stabilize('/stv.ui.js?v=1.360'));
  check('a ?v2 bundle version is left alone',
    cache.stabilize('/asset/app.v2.db.js?v2') === '/asset/app.v2.db.js?v2',
    cache.stabilize('/asset/app.v2.db.js?v2'));
  check('a tts bundle version is left alone',
    cache.stabilize('/stv.tts.js?v=7') === '/stv.tts.js?v=7',
    cache.stabilize('/stv.tts.js?v=7'));
  check('a URL outside /asset/ is untouched',
    cache.stabilize('/mobile/bookinfo.php?bookid=1') === '/mobile/bookinfo.php?bookid=1',
    cache.stabilize('/mobile/bookinfo.php?bookid=1'));
  check('a cover image URL is untouched',
    cache.stabilize('https://img.sangtacviet.com/a/b.jpg?0.5')
      === 'https://img.sangtacviet.com/a/b.jpg?0.5',
    cache.stabilize('https://img.sangtacviet.com/a/b.jpg?0.5'));
  check('a non-string is passed straight through', cache.stabilize(null) === null);

  // The property hook: stv.ui.js appends the <script> and only then assigns
  // .src, so the setter is the hook that has to do the work.
  const script = new view.HTMLScriptElement();
  script.src = '/asset/app.v2.js?0.4242';
  check('assigning <script>.src after insertion still gets stabilised',
    script.src === '/asset/app.v2.js?' + stable, script.src);
  const link = new view.HTMLLinkElement();
  link.href = '/asset/app.v2.css?r=0.9';
  check('assigning <link>.href is stabilised',
    link.href === '/asset/app.v2.css?r=' + stable, link.href);

  // The setAttribute path, which is how the shell builds the stylesheet link.
  const node = new view.Element();
  node.setAttribute('href', '/asset/app.v2.css?r=0.5');
  check('setAttribute href is stabilised',
    node.attrs.href === '/asset/app.v2.css?r=' + stable, node.attrs.href);
  const other = new view.Element();
  other.setAttribute('data-x', '0.5');
  check('setAttribute on anything else is untouched',
    other.attrs['data-x'] === '0.5', other.attrs['data-x']);

  // A forced refresh must move every URL, not just today's.
  view.location = { reload() { sandbox.__reloaded = true; } };
  cache.refresh();
  check('强制刷新 reloads the page', sandbox.__reloaded === true);
  const after = makeSandbox();
  after.localStorage.setItem('stv.asset.generation', '2');
  installFakeApp(after, { appLanguage: 'zh' });
  vm.runInContext(loadBlocks().join('\n'), after);
  await tick(60);
  check('a forced refresh changes the token',
    after.window.__stvAssetCache.token !== stable,
    after.window.__stvAssetCache.token + ' vs ' + stable);

  // The same generation on a later day is the same URL, which is what makes the
  // second-day cold start hit the disk cache instead of the network.
  const nextDay = makeSandbox();
  // Stubbed inside the context: the sandbox's globe is its own realm, so the
  // host's Date is not the one the blocks call.
  vm.runInContext('Date.now = function () { return ' + (Date.now() + 3 * 86400000)
    + '; };', nextDay);
  installFakeApp(nextDay, { appLanguage: 'zh' });
  vm.runInContext(loadBlocks().join('\n'), nextDay);
  await tick(60);
  check('a later day produces the same token',
    nextDay.window.__stvAssetCache.token === stable,
    nextDay.window.__stvAssetCache.token + ' vs ' + stable);
}

/**
 * The injection order is a performance contract, not a style choice: every
 * block is a WKUserScript at document start, so the whole list parses and runs
 * before the page's first inline script. The blocks the first frame needs have
 * to come before the heavy page-specific ones, or the fake shell cannot paint
 * until ~285KB of injected JavaScript has been parsed.
 *
 * Nothing else in the build would notice a block being dropped from the list,
 * listed twice, or moved back to the end.
 */
function testInjectionOrder() {
  console.log('injection order');

  const swift = fs.readFileSync(path.join(TARGET_DIR, 'SitePatch.swift'), 'utf8');
  const declared = [...swift.matchAll(/static let (\w+) = """/g)].map((m) => m[1]);
  const allMatch = swift.match(/static let all: \[String\] = \[([\s\S]*?)\]/);
  check('SitePatch declares the injection list', !!allMatch);
  if (!allMatch) { return; }

  const raw = allMatch[1];
  const listed = raw.split(',')
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => entry.replace(/^SiteI18nData[.]/, ''));

  check('every declared block is injected',
    declared.every((name) => listed.indexOf(name) >= 0),
    declared.filter((name) => listed.indexOf(name) < 0).join(', '));
  check('no block is injected twice',
    listed.length === new Set(listed).size, listed.join(', '));
  check('the generated i18n overlay is injected',
    /SiteI18nData[.]script/.test(raw));

  check('compat runs first, because the site calls nativeclick unguarded',
    listed[0] === 'compat', listed[0]);
  check('the asset URL hooks are installed before anything creates elements',
    listed[1] === 'assetCache', listed[1]);
  check('diag runs before every block that logs through it',
    listed[2] === 'diag', listed[2]);

  const bootCritical = ['compat', 'assetCache', 'diag', 'storageAccessor',
    'readerDefaults', 'safeArea', 'domainFailover', 'bootShell'];
  check('the boot-critical blocks are a prefix of the injection list',
    bootCritical.every((name, index) => listed[index] === name),
    listed.slice(0, bootCritical.length).join(', '));
  check('the shell is injected before the page-specific heavy blocks',
    listed.indexOf('bootShell') < listed.indexOf('pageRepair')
      && listed.indexOf('bootShell') < listed.indexOf('commentTranslate'),
    listed.join(', '));
}

/**
 * The reader's four modules are only requested once the reader opens, each
 * behind its own TTFB (app.v2.js:3943, app.v2.read.js:237/:2341,
 * _page_vip.html:4546). They are prefetched once the home screen has painted.
 */
async function testReaderPrefetch() {
  console.log('reader module prefetch');

  const sandbox = makeSandbox();
  installFakeApp(sandbox, { appLanguage: 'zh' });
  // The site's own loader, with the real de-duplication rule: `stack` is keyed
  // on the URL as passed, BEFORE `nocache` is appended.
  const loaded = [];
  sandbox.window.ui = {
    scriptmanager: {
      stack: {},
      load(url, onload) {
        if (url in this.stack) {
          if (onload) { onload(); }
          return;
        }
        loaded.push(url);
        this.stack[url] = Promise.resolve();
        if (onload) { onload(); }
      },
    },
  };
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(60);

  check('nothing is prefetched before the page has loaded',
    loaded.length === 0, JSON.stringify(loaded));

  sandbox.__dispatch('load', {});
  await tick(1600);

  check('the reader modules are prefetched after load',
    loaded.length === 4, JSON.stringify(loaded));
  check('app.v2.read.js is prefetched',
    loaded.indexOf('/asset/app.v2.read.js') >= 0, JSON.stringify(loaded));
  check('chapterdisplay is prefetched with the same key the site uses',
    loaded.indexOf('/asset/app.v2.chapterdisplay.js') >= 0, JSON.stringify(loaded));
  check('the tts module keeps its real version number',
    loaded.indexOf('/stv.tts.js?v=7') >= 0, JSON.stringify(loaded));
  check('hanviet.js is prefetched',
    loaded.indexOf('/hanviet.js') >= 0, JSON.stringify(loaded));
  check('the prefetch is reported',
    String(sandbox.window.__stvDiag.text()).indexOf('[PREFETCH]') >= 0,
    String(sandbox.window.__stvDiag.text()).slice(-160));

  // The site's own later request must be served from `stack`, not refetched.
  sandbox.window.ui.scriptmanager.load('/asset/app.v2.read.js', function () {});
  check('the site\'s own later load is de-duplicated against the prefetch',
    loaded.length === 4, JSON.stringify(loaded));
}

/**
 * The native Http plugin ships its diagnostic lines in batches, pre-formatted as
 * "[TAG] message", through `window.__stvDiag.logBatch`. If that entry point is
 * missing the call throws inside `evaluateJavaScript` and every `[Http]` line
 * disappears from the panel silently. The logging switch has to reach the native
 * side too, or the hot-path gate stays closed and the lines are never built.
 */
async function testNativeDiagnosticsBridge() {
  console.log('native diagnostics bridge');

  const sandbox = makeSandbox();
  installFakeApp(sandbox, { appLanguage: 'zh' });
  vm.runInContext(loadBlocks().join('\n'), sandbox);
  await tick(60);

  const diag = sandbox.window.__stvDiag;
  check('the panel exports the batch entry point the native side calls',
    !!diag && typeof diag.logBatch === 'function');

  diag.logBatch(['[Http] GET /mobile/bookinfo.php -> 200 1234b',
    '[ERR] GET /x -> 500']);
  const text = String(diag.text());
  check('a native batch is appended to the buffer',
    text.indexOf('[Http] GET /mobile/bookinfo.php -> 200 1234b') >= 0,
    text.slice(-200));
  check('a native line tagged ERR is recorded as an error',
    text.indexOf('[ERR] GET /x -> 500') >= 0, text.slice(-200));

  const pushes = sandbox.__stored.setDiagnostics || [];
  check('the panel tells the native side the switch is on',
    pushes.length >= 1 && pushes[0].enabled === true, JSON.stringify(pushes));

  diag.setEnabled(false);
  await tick(20);
  const off = (sandbox.__stored.setDiagnostics || []).slice(-1)[0];
  check('switching logging off tells the native side too',
    !!off && off.enabled === false, JSON.stringify(off));

  // With the switch off the native side still sends failures, marked `forced`.
  // Those are kept (bounded, and the whole point of a bug report) while the
  // per-request firehose is dropped.
  diag.logBatch(['[Http] late line']);
  check('a non-forced batch arriving while logging is off is dropped',
    String(diag.text()).indexOf('late line') < 0, String(diag.text()).slice(-200));
  diag.logBatch(['[ERR] GET /x FAILED'], true);
  check('a forced failure batch is kept while logging is off',
    String(diag.text()).indexOf('[ERR] GET /x FAILED') >= 0,
    String(diag.text()).slice(-200));

  // Turning it on shows what was collected.
  diag.setEnabled(true);
  await tick(20);
  check('turning logging on surfaces the failures collected while it was off',
    String(diag.text()).indexOf('[ERR] GET /x FAILED') >= 0,
    String(diag.text()).slice(-200));
}

(async () => {
  await testCompatAndTtsProvider();
  await testTtsProviderRespectsStoredChoice();
  await testReaderDefaults();
await testChapterNamePlace();
  await testDiagPanel();
  await testLoggingSwitch();
  await testActivityLog();
  await testI18nOverlay();
await testLanguageGuard();
  await testSafeArea();
  await testSafeAreaRespectsSiteValues();
  await testSettingsBackup();
  await testBookmarkToggle();
  await testLikeToggle();
  await testDownloadSkipsDownloaded();
  await testExportDownloadedBook();
  await testReaderTts();
await testBootShell();
  await testCommentButton();
  await testOfflineBookDetailPage();
  await testDomainFailover();
  await testDownloadRowControls();
  await testStorageAccessor();
  await testDownloadRange();
  await testDownloadStartedDialog();
  await testDownloadLifecycle();
  await testDownloadPauseResume();
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
  await testTranslateKeyStorage();
  await testAssetCacheStabiliser();
  testInjectionOrder();
  await testReaderPrefetch();
  await testNativeDiagnosticsBridge();
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
