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
    style: {},
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
    addEventListener() {},
    removeEventListener() {},
    getBoundingClientRect() {
      return { left: 0, top: 0, width: 26, height: 26, right: 26, bottom: 26 };
    },
    select() {},
    querySelector() {
      return null;
    },
    querySelectorAll(selector) {
      const wanted = selector.charAt(0) === '.' ? selector.slice(1) : null;
      const found = [];
      const visit = (node) => {
        for (const child of node.children) {
          if (child.nodeType !== 1) { continue; }
          if (wanted && String(child.className || '').split(/\s+/).indexOf(wanted) >= 0) {
            found.push(child);
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
  const documentElement = makeElement('html');
  documentElement.appendChild(body);
  const document = {
    body,
    documentElement,
    createElement: (tag) => makeElement(tag),
    addEventListener() {},
    removeEventListener() {},
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
  };
  window.window = window;

  const sandbox = {
    window,
    document,
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
  return sandbox;
}

// ---------------------------------------------------------------- fake site

function installFakeApp(sandbox, options) {
  const calls = [];
  const stored = {};

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
      cache: {
        getFile() {
          return Promise.resolve(options.storedTtsSetting || '');
        },
        setFile() {},
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
  };
  app.config.reader.__defineSetter__('display_type', function (value) {
    app.config._reader.display_type = value;
    stored.reader = value;
  });
  app.config.reader.__defineGetter__('display_type', function () {
    return app.config._reader.display_type;
  });

  sandbox.app = app;
  sandbox.window.app = app;
  sandbox.__calls = calls;
  sandbox.__stored = stored;

  sandbox.Capacitor = {
    Plugins: {
      App: {
        speakToFile(payload) {
          calls.push(payload);
          return Promise.resolve(Buffer.from('RIFFfakewav').toString('base64'));
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

  const base64 = await sandbox.window.TTS.speakToFile({ text: 'Xin chào', identifier: 'v', rate: 1, pitch: 1 });
  check('speakToFile returns base64 through Capacitor.Plugins.App', typeof base64 === 'string' && base64.length > 0);
  check('speakToFile forwarded the text', sandbox.__calls[0] && sandbox.__calls[0].text === 'Xin chào');

  // The provider registration polls; give it a tick.
  await tick(400);
  check('ttsEngine.createProvider was patched', !!sandbox.ttsEngine.__stvIosProviderInstalled);

  sandbox.ttsEngine.createProvider('ios', {});
  const provider = sandbox.ttsEngine.provider;
  check('ios provider created', !!provider && typeof provider.speak === 'function');
  check('provider exposes props', !!provider.props && !!provider.props.voice);

  const blob = await provider.speak('Xin chào', { voice: 'v', rate: 1.2 });
  check('provider.speak returns a Blob', !!blob && typeof blob.size === 'number' && blob.size > 0);
  check('provider.speak asks for audio/wav', !!blob && blob.type === 'audio/wav');

  const voices = await provider.getVoices();
  check('getVoices returns the native voice', voices.length === 1 && voices[0].value.includes('vi-VN'));
  check('female voice maps to site gender 1', voices[0].gender === 1);

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

  vm.runInContext(loadBlocks().join('\n'), sandbox);

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
}

(async () => {
  await testCompatAndTtsProvider();
  await testTtsProviderRespectsStoredChoice();
  await testReaderDefaults();
  await testDiagPanel();
  await testI18nOverlay();
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
