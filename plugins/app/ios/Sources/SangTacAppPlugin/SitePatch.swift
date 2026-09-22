import Foundation

/**
 The JavaScript we inject into the remotely-loaded site at document start.

 Why this lives here (and not in a bundled .js resource): the only build we can
 run is GitHub Actions, so the fewer moving parts between "source in the repo"
 and "string inside the binary", the fewer ways this can silently fail. Swift
 multiline strings have exactly one hazard — backslash escapes are processed, so
 a stray line-feed escape becomes a real newline and breaks the JS string it sits
 in (that is the documented v5 incident). `scripts/check-ios-shim.js` therefore
 lints every multiline string literal in this target, rejects any literal
 backslash, and parses the result with `new Function`. Write escape-free JS: no
 regexes, no line-feed escape (use String.fromCharCode(10)), no escaped quote.

 Each block is injected as its own WKUserScript. Blocks are independent and
 guarded by their own `window.__stv*Installed` flag so re-injection is a no-op.
 */
enum SitePatch {

    // MARK: - Cordova globals + native TTS facade

    /**
     The site's frontend calls globals the Android APK gets from Cordova
     plugins. On iOS those globals are missing and the site references them
     *unguarded* on hot paths, so one missing global aborts the whole handler:

         app.platform.nativeClick();            // -> nativeclick.trigger()
         app.fun.openBookWithData(this.data.lid, this.data);

     `nativeclick` comes from cordova-plugin-nativeclicksound in the APK.
     Without it the first line throws ReferenceError and the book never opens.

     `window.TTS` mirrors cordova-plugin-tts-advanced's JS surface but is backed
     by SangTacAppPlugin (AVSpeechSynthesizer). `updateMediaSession` and
     `stopMediaSession` are deliberately left undefined: every call site in
     app.v2.read.js guards them with `if (TTS.updateMediaSession)`, and those
     branches only exist for Android's foreground media session.
     */
    static let compat = """
    (function () {
        if (window.__stvIOSCompatInstalled) { return; }
        window.__stvIOSCompatInstalled = true;

        if (typeof window.nativeclick === 'undefined') {
            window.nativeclick = {
                trigger: function () {},
                watch: function () {}
            };
        }

        function appPlugin() {
            return (window.Capacitor && window.Capacitor.Plugins && window.Capacitor.Plugins.App) || null;
        }

        function callApp(name, options) {
            return new Promise(function (resolve, reject) {
                var plugin = appPlugin();
                if (!plugin || typeof plugin[name] !== 'function') {
                    reject(new Error('SangTacAppPlugin.' + name + ' is unavailable'));
                    return;
                }
                plugin[name](options || {}).then(resolve).catch(reject);
            });
        }

        function asOptions(input) {
            return (typeof input === 'string') ? { text: input } : (input || {});
        }

        var tts = window.TTS || {};
        tts.speak = function (input) { return callApp('speak', asOptions(input)); };
        tts.speakToFile = function (input) { return callApp('speakToFile', asOptions(input)); };
        tts.stop = function () { return callApp('stopSpeech', {}); };
        tts.checkLanguage = function () { return Promise.resolve(true); };
        tts.getVoices = function () {
            return callApp('getVoices', {}).then(function (result) {
                return (result && result.voices) || [];
            });
        };
        tts.getEngines = function () { return Promise.resolve([]); };
        tts.setEngine = function () { return Promise.resolve(true); };
        tts.openInstallTts = function () { return Promise.resolve(true); };
        window.TTS = tts;
    })();
    """

    // MARK: - Diagnostics

    /**
     A sideloaded iOS build has no console we can read, so this captures
     window.onerror, unhandledrejection, every console call, every tap and every
     SangTacHttpPlugin request.

     Design constraints learned from the field:
       * It must NEVER cover the site's bottom bars. The previous version was a
         60%-tall bottom sheet that opened itself on the first error, which made
         the detail page's bookmark button and the home tab bar unreachable and
         was itself reported as a bug.
       * The user has to be able to get the text out. COPY puts the whole buffer
         on the iOS clipboard (with an execCommand fallback), which beats asking
         for a screenshot of a scrolling list.
     Collapsed state is a 24px badge on the right edge showing the line count;
     it turns red as soon as anything is logged with tag ERR. The badge stays
     HIDDEN until the first ERR and can be dismissed again from the panel — the
     reader turns pages by tapping the right third of the screen
     (app.reader.menuTapMode == "centerlr"), so an always-visible badge would eat
     page turns. Triple-tap the top-left corner opens the panel regardless. The
     expanded panel is anchored to the TOP (42% height) and its title bar can be
     dragged vertically, so the bottom 58% of the screen stays usable.
     */
    static let diag = """
    (function () {
        if (window.__stvDiagInstalled) { return; }
        window.__stvDiagInstalled = true;

        var NL = String.fromCharCode(10);
        var MAX = 800;
        var lines = [];
        var errors = 0;
        var root = null;
        var listEl = null;
        var countEl = null;
        var badge = null;
        var badgeHidden = false;
        var open = false;

        function fmt(value) {
            try {
                if (typeof value === 'string') { return value; }
                if (value && value.message) { return value.message; }
                if (typeof value === 'object') { return JSON.stringify(value); }
                return String(value);
            } catch (e) {
                return '<unprintable>';
            }
        }

        function pad(n) { return ('0' + n).slice(-2); }

        function stamp() {
            var d = new Date();
            return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
        }

        function make(tag, css, text) {
            var e = document.createElement(tag);
            if (css) { e.style.cssText = css; }
            if (text !== undefined && text !== null) { e.textContent = text; }
            return e;
        }

        function describe(node) {
            if (!node || !node.tagName) { return String(node); }
            var out = node.tagName.toLowerCase();
            if (node.id) { out += '#' + node.id; }
            var cls = node.className;
            if (typeof cls === 'string' && cls) { out += '.' + cls.split(' ').join('.'); }
            return out;
        }

        function isOurs(node) {
            var n = node;
            while (n) {
                if (n === root || n === badge) { return true; }
                n = n.parentNode;
            }
            return false;
        }

        function stopEvent(e) {
            e.stopPropagation();
            e.preventDefault();
        }

        // ---- collapsed badge -------------------------------------------------

        function buildBadge() {
            if (badge) { return !!badge.parentNode; }
            var host = document.body || document.documentElement;
            if (!host) { return false; }
            badge = make('div', 'position:fixed;right:3px;top:42%;width:26px;height:26px;'
                + 'border-radius:13px;background:rgba(25,25,25,0.6);color:#cfc;'
                + 'font:10px/26px Menlo,monospace;text-align:center;z-index:2147483645;'
                + 'opacity:0.7;-webkit-user-select:none;user-select:none;display:none;');
            badge.textContent = '0';
            badge.setAttribute('data-stvdiag', 'badge');
            host.appendChild(badge);
            bindDrag(badge, badge, function () { toggle(); }, true);
            return true;
        }

        function paintBadge() {
            if (!badge) { return; }
            badge.textContent = String(lines.length);
            if (errors > 0) {
                badge.style.background = 'rgba(170,20,20,0.85)';
                badge.style.color = '#fff';
            } else {
                badge.style.background = 'rgba(25,25,25,0.6)';
                badge.style.color = '#cfc';
            }
            badge.style.display = (errors > 0 && !badgeHidden) ? 'block' : 'none';
        }

        // ---- expanded panel --------------------------------------------------

        function buildPanel() {
            if (root) { return !!root.parentNode; }
            var host = document.body || document.documentElement;
            if (!host) { return false; }

            root = make('div', 'position:fixed;left:0;top:0;width:100%;height:42%;display:none;'
                + 'z-index:2147483646;background:rgba(10,10,10,0.94);color:#7f7;'
                + 'font:11px/1.35 Menlo,monospace;box-shadow:0 3px 12px rgba(0,0,0,0.6);');
            root.setAttribute('data-stvdiag', 'panel');

            var bar = make('div', 'position:absolute;top:0;left:0;right:0;height:30px;'
                + 'background:#1d1d1d;display:flex;align-items:center;padding:0 4px;'
                + 'color:#ddd;font:11px/30px Menlo,monospace;');
            countEl = make('span', 'flex:1;padding-left:6px;overflow:hidden;white-space:nowrap;', 'stvdiag');
            bar.appendChild(countEl);

            function barButton(label, handler) {
                var b = make('button', 'font:11px Menlo,monospace;padding:3px 8px;margin-left:4px;'
                    + 'background:#333;color:#eee;border:1px solid #555;border-radius:3px;', label);
                b.addEventListener('click', function (e) { stopEvent(e); handler(); }, true);
                return b;
            }
            bar.appendChild(barButton('COPY', copyAll));
            bar.appendChild(barButton('CLEAR', function () {
                lines = [];
                errors = 0;
                render();
            }));
            bar.appendChild(barButton('HIDE', function () {
                hide();
                badgeHidden = true;
                paintBadge();
            }));
            bar.appendChild(barButton('CLOSE', function () { hide(); }));
            root.appendChild(bar);

            listEl = make('div', 'position:absolute;top:30px;left:0;right:0;bottom:0;'
                + 'overflow:auto;-webkit-overflow-scrolling:touch;padding:4px 6px 10px;'
                + 'white-space:pre-wrap;word-break:break-all;'
                + '-webkit-user-select:text;user-select:text;');
            root.appendChild(listEl);

            host.appendChild(root);
            bindDrag(bar, root, null, true);
            return true;
        }

        function render() {
            if (listEl) {
                listEl.textContent = lines.join(NL);
                listEl.scrollTop = listEl.scrollHeight;
            }
            if (countEl) {
                countEl.textContent = 'stvdiag ' + lines.length + ' lines, ' + errors + ' errors';
            }
            paintBadge();
        }

        function show() {
            if (!buildPanel()) { return; }
            open = true;
            badgeHidden = false;
            root.style.display = 'block';
            render();
        }

        function hide() {
            open = false;
            if (root) { root.style.display = 'none'; }
        }

        function toggle() {
            if (open) { hide(); } else { show(); }
        }

        function copyAll() {
            var text = lines.join(NL);
            function fallback() {
                var ta = make('textarea', 'position:fixed;left:-9999px;top:0;opacity:0;');
                ta.value = text;
                var host = document.body || document.documentElement;
                host.appendChild(ta);
                ta.select();
                try { document.execCommand('copy'); } catch (e) {}
                host.removeChild(ta);
            }
            try {
                if (navigator.clipboard && navigator.clipboard.writeText) {
                    navigator.clipboard.writeText(text).catch(fallback);
                } else {
                    fallback();
                }
            } catch (e) {
                fallback();
            }
            return text;
        }

        // ---- drag ------------------------------------------------------------

        function bindDrag(handle, target, onTap, verticalOnly) {
            var startX = 0;
            var startY = 0;
            var originX = 0;
            var originY = 0;
            var moved = false;
            var active = false;

            handle.addEventListener('touchstart', function (e) {
                var t = e.touches && e.touches[0];
                if (!t) { return; }
                active = true;
                moved = false;
                startX = t.clientX;
                startY = t.clientY;
                var rect = target.getBoundingClientRect();
                originX = rect.left;
                originY = rect.top;
                e.stopPropagation();
            }, true);

            handle.addEventListener('touchmove', function (e) {
                if (!active) { return; }
                var t = e.touches && e.touches[0];
                if (!t) { return; }
                var dx = t.clientX - startX;
                var dy = t.clientY - startY;
                if (!moved && Math.abs(dx) < 8 && Math.abs(dy) < 8) { return; }
                moved = true;
                var top = originY + dy;
                if (top < 0) { top = 0; }
                var limit = window.innerHeight - 40;
                if (top > limit) { top = limit; }
                target.style.top = top + 'px';
                target.style.bottom = 'auto';
                if (!verticalOnly) {
                    var left = originX + dx;
                    if (left < 0) { left = 0; }
                    var maxLeft = window.innerWidth - 40;
                    if (left > maxLeft) { left = maxLeft; }
                    target.style.left = left + 'px';
                    target.style.right = 'auto';
                }
                e.preventDefault();
                e.stopPropagation();
            }, true);

            handle.addEventListener('touchend', function (e) {
                if (!active) { return; }
                active = false;
                if (!moved && onTap) { onTap(); }
                e.stopPropagation();
            }, true);
        }

        // ---- logging ---------------------------------------------------------

        function log(tag, msg) {
            lines.push(stamp() + ' [' + tag + '] ' + fmt(msg));
            while (lines.length > MAX) { lines.shift(); }
            if (tag === 'ERR') {
                errors++;
                badgeHidden = false;
            }
            if (open) {
                render();
            } else {
                paintBadge();
            }
        }

        window.__stvDiag = {
            log: log,
            show: show,
            hide: hide,
            toggle: toggle,
            copy: copyAll,
            text: function () { return lines.join(NL); },
            lines: function () { return lines.slice(); }
        };

        window.addEventListener('error', function (e) {
            log('ERR', 'onerror ' + (e.message || '') + ' @' + (e.filename || '') + ':' + (e.lineno || 0));
        }, true);
        window.addEventListener('unhandledrejection', function (e) {
            var r = e.reason;
            log('ERR', 'unhandledrejection ' + fmt((r && (r.stack || r.message)) || r));
        });

        function tee(orig, tag) {
            return function () {
                var parts = [];
                for (var i = 0; i < arguments.length; i++) { parts.push(fmt(arguments[i])); }
                log(tag, parts.join(' '));
                return orig.apply(console, arguments);
            };
        }
        console.error = tee(console.error, 'ERR');
        console.warn = tee(console.warn, 'WARN');
        console.log = tee(console.log, 'LOG');

        // Every tap is logged with its target, and with whatever element is
        // actually on top at that point when the two differ. That is what tells
        // "the handler never ran" apart from "something is covering the button".
        document.addEventListener('click', function (e) {
            if (isOurs(e.target)) { return; }
            var line = 'tap ' + describe(e.target);
            try {
                var top = document.elementFromPoint(e.clientX, e.clientY);
                if (top && top !== e.target && !isOurs(top)) {
                    line += ' | topmost=' + describe(top);
                }
            } catch (err) {}
            log('TAP', line);
        }, true);

        var taps = 0;
        var lastTap = 0;
        document.addEventListener('touchstart', function (e) {
            var t = e.touches && e.touches[0];
            if (!t) { return; }
            if (t.clientX < 70 && t.clientY < 70) {
                var now = Date.now();
                taps = (now - lastTap < 700) ? taps + 1 : 1;
                lastTap = now;
                if (taps >= 3) {
                    taps = 0;
                    toggle();
                }
            }
        }, true);

        if (!buildBadge()) {
            document.addEventListener('DOMContentLoaded', function () { buildBadge(); paintBadge(); });
        } else {
            paintBadge();
        }
    })();
    """

    // MARK: - Reader display type

    /**
     The site's own default is vertical scrolling, on every platform:

         app.config.readerDefault.display_type = "auto"
         loadChapterDisplay(): "auto" | "" -> "default"
         ChapterDisplayTypeRegistry.default = SlideChapterDisplay

     Android does not override it either — the APK loads the same
     /asset/app.v2.config.js and nothing in the frontend ever writes
     display_type. So a left/right page-turn reader on Android is a per-device
     setting stored in that install's config.reader blob, not a platform
     default. To give iOS the same out-of-the-box behaviour we seed the value to
     "pageflip" *only while it is still untouched* ("auto"/"default"/empty), so
     a choice made in 阅读设置 is never overwritten. The setting is written
     through app.config.reader's setter, which persists it like a manual change.
     */
    static let readerDefaults = """
    (function () {
        if (window.__stvReaderDefaultsInstalled) { return; }
        window.__stvReaderDefaultsInstalled = true;

        var done = false;
        var timer = setInterval(function () {
            if (done) { clearInterval(timer); return; }
            var app = window.app;
            if (!app || !app.config || !app.config._reader) { return; }
            if (!app.platform || !app.platform.isIOS) { done = true; clearInterval(timer); return; }
            var current = app.config._reader.display_type;
            if (current === undefined || current === null || current === '' || current === 'auto' || current === 'default') {
                try {
                    app.config.reader.display_type = 'pageflip';
                    if (window.__stvDiag) {
                        window.__stvDiag.log('PATCH', 'reader display_type auto -> pageflip');
                    }
                } catch (e) {
                    if (window.__stvDiag) { window.__stvDiag.log('ERR', 'display_type patch failed: ' + e); }
                }
            }
            done = true;
            clearInterval(timer);
        }, 200);

        setTimeout(function () { clearInterval(timer); }, 180000);
    })();
    """

    // MARK: - Native iOS TTS provider

    /**
     app.tts.engineList() hands Android a native engine as its first entry
     ("Android TextToSpeech" / value "google") and hands iOS only network
     providers (Bing / Zalo / FPT / Viettel / Sáng Tác Việt). We add the
     equivalent iOS entry and register a matching provider with ttsEngine.

     The provider contract comes from /stv.tts.js: `props` for the settings UI
     and `async speak(text, options)` returning an audio Blob that
     ttsEngine.decodeAudio() can feed to decodeAudioData(). AVSpeechSynthesizer
     cannot hand out a Blob, so SangTacAppPlugin synthesises the utterance to an
     in-memory 16-bit PCM WAV (AVSpeechSynthesizer.write(_:toBufferCallback:)),
     base64-encodes it, and this shim turns it back into a Blob.

     `app.tts.setting[provider].voice` is dereferenced unguarded by
     loadProviderOption (app.v2.read.js:3042), so the provider sub-object is
     created up front and getVoices() always returns at least one entry.
     */
    static let ttsProvider = """
    (function () {
        if (window.__stvTtsProviderInstalled) { return; }
        window.__stvTtsProviderInstalled = true;

        function base64ToBlob(b64, mime) {
            var binary = atob(b64);
            var length = binary.length;
            var bytes = new Uint8Array(length);
            for (var i = 0; i < length; i++) { bytes[i] = binary.charCodeAt(i); }
            return new Blob([bytes], { type: mime });
        }

        function IosTts(options) {
            this.options = options || {};
            if (this.options.voice === undefined || this.options.voice === null) { this.options.voice = ''; }
            if (!this.options.rate) { this.options.rate = 1; }
            if (!this.options.pitch) { this.options.pitch = 1; }
            this.props = {
                voice: { type: 'select', default: '', description: 'Giọng đọc' },
                rate: { type: 'float', default: 1, min: 0.5, max: 2, description: 'Tốc độ đọc' },
                pitch: { type: 'float', default: 1, min: 0.5, max: 2, description: 'Độ cao giọng' }
            };
        }

        IosTts.prototype.checkConfig = function () {};

        IosTts.prototype.sleep = function (ms) {
            return new Promise(function (resolve) { setTimeout(resolve, ms); });
        };

        IosTts.prototype.speak = function (text, options) {
            var self = this;
            var merged = options || {};
            var param = {
                text: text,
                identifier: merged.voice || self.options.voice || '',
                rate: merged.rate || self.options.rate || 1,
                pitch: merged.pitch || self.options.pitch || 1
            };
            if (merged.voice) { self.options.voice = merged.voice; }
            if (merged.rate) { self.options.rate = merged.rate; }
            return window.TTS.speakToFile(param).then(function (encoded) {
                if (typeof encoded !== 'string' || encoded.length === 0) {
                    throw new Error('iOS TTS returned no audio');
                }
                return base64ToBlob(encoded, 'audio/wav');
            });
        };

        IosTts.prototype.getVoices = function () {
            return window.TTS.getVoices().then(function (voices) {
                var list = voices || [];
                var mapped = [];
                for (var i = 0; i < list.length; i++) {
                    var voice = list[i];
                    if (!voice || !voice.identifier) { continue; }
                    mapped.push({
                        name: voice.name || ('Giọng ' + (i + 1)),
                        value: voice.identifier,
                        gender: (voice.gender === 1) ? 0 : 1
                    });
                }
                if (mapped.length === 0) {
                    mapped.push({ name: 'iOS TextToSpeech', value: '', gender: 1 });
                }
                return mapped;
            });
        };

        IosTts.prototype.getEngines = function () {
            return Promise.resolve([]);
        };

        function installProvider() {
            if (!window.ttsEngine || typeof window.ttsEngine.createProvider !== 'function') { return false; }
            if (window.ttsEngine.__stvIosProviderInstalled) { return true; }
            window.ttsEngine.__stvIosProviderInstalled = true;
            var original = window.ttsEngine.createProvider;
            window.ttsEngine.createProvider = function (name, options) {
                if (name === 'ios') {
                    this.provider = new IosTts(options);
                    return;
                }
                return original.call(this, name, options);
            };
            if (window.__stvDiag) { window.__stvDiag.log('PATCH', 'ttsEngine provider "ios" registered'); }
            return true;
        }

        function installEngineList() {
            var app = window.app;
            if (!app || !app.tts || typeof app.tts.engineList !== 'function') { return false; }
            if (app.tts.__stvIosEngineListInstalled) { return true; }
            app.tts.__stvIosEngineListInstalled = true;
            var originalList = app.tts.engineList;
            app.tts.engineList = function () {
                var list = originalList.call(this) || [];
                for (var i = 0; i < list.length; i++) {
                    if (list[i] && list[i].value === 'ios') { return list; }
                }
                list.unshift({ name: 'iOS TextToSpeech', value: 'ios' });
                return list;
            };

            var setting = app.tts.setting;
            if (setting && setting.provider !== 'ios') {
                try {
                    app.storage.cache.getFile('tts.setting').then(function (stored) {
                        if (stored) { return; }
                        setting.provider = 'ios';
                        if (!setting.ios) { setting.ios = {}; }
                        if (typeof setting.set === 'function') { setting.set('provider', 'ios'); }
                        if (window.__stvDiag) {
                            window.__stvDiag.log('PATCH', 'tts provider default -> ios');
                        }
                    }).catch(function () {});
                } catch (e) {}
            }
            return true;
        }

        var timer = setInterval(function () {
            var providerReady = installProvider();
            var listReady = installEngineList();
            if (providerReady && listReady) { clearInterval(timer); }
        }, 250);

        setTimeout(function () { clearInterval(timer); }, 180000);
    })();
    """

    /// Injected in order; every block is independently guarded. `SiteI18nData`
    /// is generated from data/site-i18n.json by scripts/gen-site-i18n.js.
    static let all: [String] = [compat, diag, readerDefaults, ttsProvider, SiteI18nData.script]
}
