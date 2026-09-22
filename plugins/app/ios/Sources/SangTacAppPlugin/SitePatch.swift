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
            return window.TTS.speakToFile(param).then(function (result) {
                // SangTacAppPlugin.speakToFile resolves {data, mime}; Cordova's
                // TTS.speakToFile resolves the payload itself. This shim is the
                // adapter between the two, so accept either shape -- the site's
                // provider does `new Blob([await TTS.speakToFile(...)])` and only
                // ever sees a Blob.
                var encoded = result;
                if (result && typeof result === 'object') { encoded = result.data; }
                if (window.__stvDiag) {
                    window.__stvDiag.log('TTS', 'speak result kind='
                        + (result === null ? 'null' : typeof result)
                        + ' payload=' + (typeof encoded === 'string' ? encoded.length + ' chars'
                            : typeof encoded)
                        + ' text=' + (text || '').length + ' chars');
                }
                if (typeof encoded !== 'string' || encoded.length === 0) {
                    throw new Error('iOS TTS returned no audio (got '
                        + (result === null ? 'null' : typeof result) + ')');
                }
                return base64ToBlob(encoded, (result && result.mime) || 'audio/wav');
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

    // MARK: - Followed-books fallback probe

    /**
     The 关注 (following) tab is broken on the site itself, not here:

         GET /mobile/booklist.php?method=following&p=0   -> 500, zero-byte body
         GET /mobile/booklist.php?method=bookmarked&p=0  -> 200, 34 KB of JSON
         GET /mobile/booklist.php?method=mybook&p=0      -> 200, {"list":[],"code":100}

     Same host, same cookies, same headers, same endpoint — only the `method`
     value differs. Anonymous probes answer {"code":102} for all three, so the
     handler exists and the auth check passes; it then crashes. The site's own
     markup declares the broken URL (`<bookdisplay from="/mobile/booklist.php
     ?method=following&p=0">`), so the Android build is equally broken.

     Nothing on the client can repair a server-side crash. What this block does
     is capture the site's own legacy replacement, which its markup still
     references in a commented-out line and which is still alive:

         GET /?ajax=getfollowing&user=0  ->  "Bạn chưa đăng nhập." when anonymous

     With a session that endpoint should return the same book items. The
     response is logged to the diagnostic panel so the next build can convert it
     into the JSON shape <bookgrid from="..."> expects, instead of guessing.
     */
    static let followFallback = """
    (function () {
        if (window.__stvFollowFallbackInstalled) { return; }
        window.__stvFollowFallbackInstalled = true;

        var PROBE = '/?ajax=getfollowing&user=0';
        var tried = false;

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        function probe(reason) {
            if (tried) { return; }
            tried = true;
            note('FOLLOW', 'method=following failed (' + reason + '); probing ' + PROBE);
            try {
                var xhr = new XMLHttpRequest();
                xhr.open('GET', PROBE, true);
                xhr.withCredentials = true;
                xhr.onload = function () {
                    var body = String(xhr.responseText || '');
                    note('FOLLOW', PROBE + ' -> ' + xhr.status + ' ' + body.length + 'b :: '
                        + body.slice(0, 400));
                };
                xhr.onerror = function () { note('ERR', PROBE + ' request failed'); };
                xhr.send();
            } catch (e) {
                note('ERR', PROBE + ' threw: ' + e);
            }
        }

        function isFollowingCall(url) {
            return String(url || '').indexOf('method=following') >= 0;
        }

        // app.net.get is a plain property on a plain object, so wrapping it is
        // reliable -- unlike Capacitor.Plugins.Http, which is a proxy and may
        // silently refuse the assignment. Every book-list view goes through it.
        function looksLikeABookList(value) {
            if (!value) { return false; }
            if (typeof value === 'string') { return value.indexOf('"list"') >= 0; }
            return Array.isArray(value.list);
        }

        function attach() {
            var app = window.app;
            if (!app || !app.net || typeof app.net.get !== 'function') { return false; }
            if (app.net.__stvFollowWrapped) { return true; }
            app.net.__stvFollowWrapped = true;

            var original = app.net.get;
            app.net.get = function (url) {
                var call = original.apply(this, arguments);
                if (!isFollowingCall(url) || !call || typeof call.then !== 'function') { return call; }
                return call.then(function (result) {
                    if (!looksLikeABookList(result)) {
                        probe('unusable body: ' + String(JSON.stringify(result) || result).slice(0, 120));
                    }
                    return result;
                }, function (error) {
                    probe('rejected: ' + error);
                    throw error;
                });
            };
            return true;
        }

        if (!attach()) {
            var attempts = 0;
            var timer = setInterval(function () {
                attempts++;
                if (attach() || attempts > 200) { clearInterval(timer); }
            }, 100);
        }
    })();
    """

    // MARK: - iOS safe area (Dynamic Island / home indicator)

    /**
     The site models the notch itself, but only for the chrome it draws: its
     stylesheet pads `body[ovlwv] .titlebar` with `--status-bar-height` and
     `.bottombar` with `--screensafebottom`. Two of its own surfaces are left out:

         #chapterview .titlebar   position:fixed; top:0 when the menu opens,
                                  height 40px, no status-bar padding -> the
                                  reader's top bar renders under the Dynamic
                                  Island, where its left/right buttons cannot be
                                  tapped.
         #chapterview .coption    position:fixed; bottom:0, no
                                  --screensafebottom -> the reader's option
                                  sheet runs into the home indicator.

     With `contentInset: never` and `viewport-fit=cover` the web view is
     full-bleed, so nothing else compensates. The insets come from the native
     safe area (App.getSafeArea) rather than `env(safe-area-inset-*)` so the
     patch still works if the site's own detection never runs -- its
     `--status-bar-height` is written from `getSafeHeight()` inside
     `window.onresize`, which is only ever scheduled by `overlayStatusBar(true)`.
     */
    static let safeArea = """
    (function () {
        if (window.__stvSafeAreaInstalled) { return; }
        window.__stvSafeAreaInstalled = true;

        // Two distinct defects, one stylesheet.
        //
        // 1. The reader's own bar is `position: fixed; top: var(--ntitlebarovl)`
        //    (== -(statusBarHeight + 45)px) and only moves to 0 when
        //    #chapterview carries .showmenu. It has no status-bar padding of its
        //    own, so whatever the site computes for --status-bar-height has to be
        //    correct at that instant or the back button lands under the Dynamic
        //    Island. max(var, env()) removes the dependency on the site's own
        //    detection (window.getSafeHeight(), which reads env() itself).
        //
        // 2. `body[ovlwv] .titlebar { height: var(--titlebarovl); padding-top:
        //    var(--status-bar-height) }` is content-box, so the bar renders
        //    102 + 62 = 164px tall with 62px of dead space under it. Every page
        //    that follows a .titlebar (the inventory page's tab bar, for one)
        //    is pushed down by exactly that much. height:auto makes the total
        //    40 + 62 = 102px, which is what --titlebarovl means.
        var INSET_TOP = 'max(var(--status-bar-height), env(safe-area-inset-top))';
        var INSET_BOTTOM = 'max(var(--screensafebottom), env(safe-area-inset-bottom))';

        var CSS = '#chapterview .titlebar{padding-top:' + INSET_TOP + ' !important;'
            + 'height:auto !important;box-sizing:content-box !important;}'
            + '#chapterview.showmenu .titlebar{top:0 !important;}'
            + '#chapterview .coption{padding-bottom:calc(12px + ' + INSET_BOTTOM + ') !important;}'
            + 'body[ovlwv] .titlebar{height:auto !important;box-sizing:content-box !important;'
            + 'padding-top:' + INSET_TOP + ' !important;}'
            + 'body[ovlwv] .bottombar{padding-bottom:' + INSET_BOTTOM + ' !important;}';

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        function style() {
            if (document.getElementById('stv-safe-area')) { return true; }
            var head = document.head;
            if (!head) { return false; }
            var el = document.createElement('style');
            el.id = 'stv-safe-area';
            el.textContent = CSS;
            head.appendChild(el);
            return true;
        }

        function viewportFit() {
            var meta = document.getElementById('metaviewport');
            if (!meta) { return; }
            var content = meta.getAttribute('content') || '';
            if (content.indexOf('viewport-fit') >= 0) { return; }
            meta.setAttribute('content', content + ', viewport-fit=cover');
        }

        function px(value) {
            var n = parseFloat(value);
            return isNaN(n) ? 0 : n;
        }

        var applied = null;

        function apply(insets) {
            if (!insets) { return; }
            var root = document.documentElement;
            if (!root) { return; }
            var computed = window.getComputedStyle(root);
            var top = px(computed.getPropertyValue('--status-bar-height'));
            var bottom = px(computed.getPropertyValue('--screensafebottom'));
            // Only fill in what the site failed to set; never fight a value it
            // already produced (it re-derives both on every resize).
            if (top <= 0 && insets.top > 0) {
                root.style.setProperty('--status-bar-height', insets.top + 'px');
            }
            if (bottom <= 0 && insets.bottom > 0) {
                root.style.setProperty('--screensafebottom', insets.bottom + 'px');
            }
            style();
            viewportFit();
            var key = insets.top + 'x' + insets.bottom;
            if (applied !== key) {
                applied = key;
                note('SAFE', 'safe area top=' + insets.top + ' bottom=' + insets.bottom
                    + ' | css status-bar-height='
                    + root.style.getPropertyValue('--status-bar-height')
                    + ' screensafebottom=' + root.style.getPropertyValue('--screensafebottom'));
            }
        }

        function fetchInsets() {
            var plugin = (window.Capacitor && window.Capacitor.Plugins
                && window.Capacitor.Plugins.App) || null;
            if (!plugin || typeof plugin.getSafeArea !== 'function') { return false; }
            plugin.getSafeArea({}).then(apply).catch(function (e) {
                note('ERR', 'getSafeArea failed: ' + e);
            });
            return true;
        }

        // The device is the only place these two layout complaints can be
        // settled, so measure the real boxes instead of guessing again. Reported
        // whenever the reader's menu opens (all three entry points go through
        // showMenuOl) and on the boot samples.
        function box(selector, last) {
            var nodes = document.querySelectorAll(selector);
            if (!nodes.length) { return selector + '=none'; }
            var node = nodes[last ? nodes.length - 1 : 0];
            var r = node.getBoundingClientRect();
            return selector + '[' + Math.round(r.top) + '..' + Math.round(r.bottom)
                + ' h' + Math.round(r.height) + ']';
        }

        function reportRects() {
            var root = document.documentElement;
            var declared = px(root.style.getPropertyValue('--status-bar-height'));
            var resolved = px(window.getComputedStyle(root).getPropertyValue('--status-bar-height'));
            note('RECT', box('#chapterview .titlebar') + ' ' + box('#chapterview .coption')
                + ' ' + box('#overlay .titlebar', true) + ' ' + box('.usertop')
                + ' status-bar=' + declared + '/' + resolved
                + ' env=' + (window.getSafeHeight ? JSON.stringify(window.getSafeHeight()) : 'n/a'));
        }

        function watchReaderMenu() {
            var app = window.app;
            if (!app || !app.reader || typeof app.reader.showMenuOl !== 'function') { return false; }
            if (app.reader.__stvRectWrapped) { return true; }
            app.reader.__stvRectWrapped = true;
            var original = app.reader.showMenuOl;
            app.reader.showMenuOl = function () {
                var result = original.apply(this, arguments);
                // the bar slides for 0.3s; measure once it has settled
                setTimeout(reportRects, 400);
                return result;
            };
            note('SAFE', 'reader menu geometry probe installed');
            return true;
        }

        function tick() {
            style();
            viewportFit();
            fetchInsets();
            watchReaderMenu();
        }

        // The site writes its own values about a second into boot and rewrites
        // them on resize, so sample a handful of times rather than continuously.
        var DELAYS = [0, 200, 600, 1200, 2500, 5000, 10000];
        for (var i = 0; i < DELAYS.length; i++) {
            (function (delay) {
                setTimeout(function () { tick(); if (delay >= 2500) { reportRects(); } }, delay);
            })(DELAYS[i]);
        }
        window.addEventListener('resize', fetchInsets);
        window.addEventListener('orientationchange', fetchInsets);
        document.addEventListener('DOMContentLoaded', tick);
    })();
    """

    // MARK: - Settings backup across reinstalls

    /**
     The site persists every setting in localStorage:

         app.config.saveReaderSetting() -> app.storage.cache.setFile('config.reader', ...)
         app.storage.cache.setFile     -> app.storage.set
         app.storage.set               -> localStorage.setItem

     A sideloaded IPA gets reinstalled constantly (every build of this project),
     and a reinstall hands the app a fresh data container, so localStorage is
     empty and every reader/UX/TTS setting silently falls back to its default.
     `app.storage.set` is the single funnel, so wrapping it is enough to mirror
     the keys that hold the user's own configuration -- including the dynamic
     `reader.style.<name>` font/size entries.

     The iOS keychain is not deleted with the app, so it is the one place on the
     device that survives a reinstall. The restore runs at document start; the
     site does not read its config until `onDbLoad.waitForLoad()` resolves
     (measured at ~4s on device), so the write always lands first.
     */
    static let settingsBackup = """
    (function () {
        if (window.__stvSettingsBackupInstalled) { return; }
        window.__stvSettingsBackupInstalled = true;

        var KEYS = ['config.reader', 'config.ux', 'config.comicReader', 'tts.setting',
                    'readthemeset'];
        var PREFIXES = ['reader.style.'];

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        function appPlugin() {
            return (window.Capacitor && window.Capacitor.Plugins
                && window.Capacitor.Plugins.App) || null;
        }

        function isBackedUp(key) {
            if (typeof key !== 'string') { return false; }
            for (var i = 0; i < KEYS.length; i++) { if (KEYS[i] === key) { return true; } }
            for (var j = 0; j < PREFIXES.length; j++) {
                if (key.indexOf(PREFIXES[j]) === 0) { return true; }
            }
            return false;
        }

        var restored = false;

        function restore() {
            var plugin = appPlugin();
            if (!plugin || typeof plugin.settingsRestore !== 'function') { return false; }
            restored = true;
            plugin.settingsRestore({}).then(function (result) {
                var entries = (result && result.entries) || {};
                var written = 0;
                var seen = 0;
                for (var key in entries) {
                    if (!isBackedUp(key)) { continue; }
                    seen++;
                    var value = entries[key];
                    if (typeof value !== 'string' || value.length === 0) { continue; }
                    var existing = null;
                    try { existing = localStorage.getItem(key); } catch (e) { existing = null; }
                    if (existing) { continue; }
                    try { localStorage.setItem(key, value); written++; } catch (e) {}
                }
                note('SETTINGS', 'keychain restore: ' + written + ' of ' + seen
                    + ' backed-up key(s) written back');
            }).catch(function (e) {
                note('ERR', 'settingsRestore failed: ' + e);
            });
            return true;
        }

        function mirror(key, value) {
            var plugin = appPlugin();
            if (!plugin || typeof plugin.settingsSave !== 'function') { return; }
            try {
                var call = plugin.settingsSave({ key: key, value: value });
                if (call && typeof call.catch === 'function') { call.catch(function () {}); }
            } catch (e) {}
        }

        function attach() {
            var app = window.app;
            if (!app || !app.storage || typeof app.storage.set !== 'function') { return false; }
            if (app.storage.__stvBackedUp) { return true; }
            app.storage.__stvBackedUp = true;
            var original = app.storage.set;
            app.storage.set = function (key, value) {
                if (isBackedUp(key) && typeof value === 'string' && value.length > 0) {
                    mirror(key, value);
                }
                return original.apply(this, arguments);
            };
            note('SETTINGS', 'settings mirror attached');
            return true;
        }

        var attempts = 0;
        var timer = setInterval(function () {
            attempts++;
            if (!restored) { restore(); }
            if ((restored && attach()) || attempts > 400) { clearInterval(timer); }
        }, 25);
    })();
    """

    // MARK: - Bookmark cancel

    /**
     The site can add a bookmark but its client cannot remove one:
     `app.api.bookmark` only ever calls `ajax=addbookmark`, and there is no
     un-bookmark action anywhere in app.v2.js (likes, by contrast, do have
     `ajax=unlike`). Tapping the bookmark button on an already-bookmarked book
     therefore just re-adds it -- which is exactly what "点击书签就取消不了"
     describes, and the Android build behaves the same way.

     This block makes the button a real toggle: when the book is already
     bookmarked (the site marks the button `.active` from `querybookmarkstatus`)
     it tries the plausible removal actions and reports each answer to the
     panel, so the working endpoint -- if one exists -- is identified from the
     device instead of guessed. The first action answering code 100 wins.
     */
    static let bookmarkToggle = """
    (function () {
        if (window.__stvBookmarkToggleInstalled) { return; }
        window.__stvBookmarkToggleInstalled = true;

        var ACTIONS = ['unbookmark', 'removebookmark', 'delbookmark', 'deletebookmark'];

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        function bookmarked() {
            var nodes = document.querySelectorAll('.btnbookmark');
            for (var i = 0; i < nodes.length; i++) {
                if (nodes[i].classList && nodes[i].classList.contains('active')) { return true; }
            }
            return false;
        }

        function clearActive() {
            var nodes = document.querySelectorAll('.btnbookmark');
            for (var i = 0; i < nodes.length; i++) {
                if (nodes[i].classList) { nodes[i].classList.remove('active'); }
            }
        }

        function target(bookdata) {
            var app = window.app || {};
            var context = app.context || {};
            var candidates = [bookdata, bookdata && bookdata.data, context.attach,
                              context.attach && context.attach.data];
            for (var i = 0; i < candidates.length; i++) {
                var item = candidates[i];
                if (item && item.id && item.host) { return item; }
            }
            return null;
        }

        function attach() {
            var app = window.app;
            if (!app || !app.api || typeof app.api.bookmark !== 'function') { return false; }
            if (app.api.__stvBookmarkWrapped) { return true; }
            app.api.__stvBookmarkWrapped = true;
            var original = app.api.bookmark;

            function remove(book) {
                note('BOOKMARK', 'already bookmarked; probing removal actions for '
                    + book.host + '/' + book.id);
                var index = 0;
                function next() {
                    if (index >= ACTIONS.length) {
                        note('BOOKMARK', 'no removal action answered code 100 -- the site has '
                            + 'no un-bookmark endpoint');
                        return null;
                    }
                    var action = ACTIONS[index++];
                    var body = 'ajax=' + action + '&id=' + encodeURIComponent(book.id)
                        + '&host=' + encodeURIComponent(book.host);
                    return app.net.post('/mobile/jsonify.php', body).then(function (down) {
                        note('BOOKMARK', action + ' -> '
                            + String(JSON.stringify(down)).slice(0, 200));
                        if (down && down.code == 100) {
                            clearActive();
                            if (app.toast) { app.toast('已取消书签'); }
                            return down;
                        }
                        return next();
                    }, function (error) {
                        note('BOOKMARK', action + ' rejected: ' + error);
                        return next();
                    });
                }
                return next();
            }

            app.api.bookmark = function (bookdata) {
                if (!bookmarked()) { return original.apply(this, arguments); }
                var book = target(bookdata);
                if (!book) {
                    note('BOOKMARK', 'bookmarked, but the tapped book could not be resolved; '
                        + 'falling back to add');
                    return original.apply(this, arguments);
                }
                return remove(book);
            };
            note('BOOKMARK', 'bookmark toggle installed');
            return true;
        }

        if (!attach()) {
            var attempts = 0;
            var timer = setInterval(function () {
                attempts++;
                if (attach() || attempts > 400) { clearInterval(timer); }
            }, 100);
        }
    })();
    """

    // MARK: - Reader TTS

    /**
     Tapping play inside the reader produced no audio and no log line at all,
     while the same provider speaks fine from the TTS settings page. The reader
     path is not the settings path:

         app.tts.start() -> player.generateSentences() -> getSentences()
             -> getCurrentWindow().speaker            (must exist)
             -> display.tokenizeSentence()            (throws on speaker.viRgx)
         player.play() -> sen.prefetch() -> ttsEngine.requestAudioInstant()
             -> provider.speak()                      (works -- proven by the test)

     `speaker` is installed by qtOnline.js, which the reader iframe loads from
     networkManagerXHR.bestDomain() -- a different origin from the page. When it
     does not arrive, getSentences() returns null after a toast and
     PageFlipChapterDisplay.tokenizeSentence() throws on speaker.viRgx. Both
     failures are swallowed, so the button simply does nothing.

     This block does not guess: it reports what actually happened, and when the
     sentence source is missing it supplies one built from the chapter text so
     the site's own queue, provider and audio element still do the playing.
     */
    static let readerTts = """
    (function () {
        if (window.__stvReaderTtsInstalled) { return; }
        window.__stvReaderTtsInstalled = true;

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        function noop() {}

        // No regular expressions: this block has to survive a Swift multiline
        // string, which forbids backslashes.
        var BREAKS = ['.', '!', '?', ',', ';', '。', '！', '？', '，', '、', '；',
                      String.fromCharCode(10)];

        function trim(value) {
            var s = value;
            while (s.length && s.charCodeAt(0) <= 32) { s = s.substring(1); }
            while (s.length && s.charCodeAt(s.length - 1) <= 32) { s = s.substring(0, s.length - 1); }
            return s;
        }

        function isBreak(ch) {
            for (var i = 0; i < BREAKS.length; i++) { if (ch === BREAKS[i]) { return true; } }
            return false;
        }

        function splitSentences(text) {
            var out = [];
            var buffer = '';
            for (var i = 0; i < text.length; i++) {
                var ch = text.charAt(i);
                buffer += ch;
                if (isBreak(ch)) {
                    var piece = trim(buffer);
                    if (piece) { out.push(piece); }
                    buffer = '';
                }
            }
            var rest = trim(buffer);
            if (rest) { out.push(rest); }
            return out;
        }

        function toTextFor(value) {
            return function () { return value; };
        }

        function readerWindow(display) {
            var w = null;
            try {
                w = display.getCurrentWindow ? display.getCurrentWindow() : display.innerWindow;
            } catch (e) { w = null; }
            return w || null;
        }

        function ensureSpeaker(display) {
            var w = readerWindow(display);
            if (!w) { return null; }
            if (!w.speaker) {
                // Only the guard `if(!wd.speaker)` in getSentences() needs this.
                // Our own sentence objects carry toText(), so senToText() is
                // never called -- which is why an empty stub is enough.
                w.speaker = {
                    sentences: [],
                    senToText: function () { return ''; },
                    parseSen: noop,
                    highlightOn: noop,
                    highlightOff: noop
                };
                note('TTS', 'reader iframe has no speaker (qtOnline.js never installed one) -- shimmed');
            }
            return w;
        }

        function fallbackSentences(display) {
            var w = readerWindow(display);
            if (!w || !w.document) { return []; }
            var doc = w.document;
            var root = doc.getElementById('maincontent') || doc.body;
            if (!root) { return []; }
            var text = root.innerText || root.textContent || '';
            var pieces = splitSentences(text);
            var list = [];
            for (var i = 0; i < pieces.length; i++) {
                list.push({ toText: toTextFor(pieces[i]), highlightOn: noop, highlightOff: noop });
            }
            return list;
        }

        function patchDisplay(display) {
            if (!display || display.__stvTtsPatched) { return; }
            display.__stvTtsPatched = true;
            var original = display.tokenizeSentence;
            display.tokenizeSentence = function () {
                ensureSpeaker(this);
                var list = null;
                if (typeof original === 'function') {
                    try {
                        list = original.call(this);
                    } catch (e) {
                        note('TTS', 'site tokenizeSentence threw: ' + e);
                    }
                }
                if (list && list.length) { return list; }
                var mine = fallbackSentences(this);
                note('TTS', 'tokenizeSentence fallback -> ' + mine.length + ' sentence(s)');
                return mine;
            };
        }

        function currentDisplay() {
            var app = window.app;
            if (!app || !app.reader || typeof app.reader.getDisplay !== 'function') { return null; }
            try { return app.reader.getDisplay(); } catch (e) { return null; }
        }

        function attach() {
            var app = window.app;
            if (!app || !app.tts || typeof app.tts.start !== 'function') { return false; }
            if (app.tts.__stvReaderTtsWrapped) { return true; }
            app.tts.__stvReaderTtsWrapped = true;

            var originalStart = app.tts.start;
            app.tts.start = function () {
                var display = currentDisplay();
                patchDisplay(display);
                ensureSpeaker(display);
                var failure = '';
                try {
                    originalStart.apply(this, arguments);
                } catch (e) {
                    failure = ' threw: ' + e;
                }
                var player = this.player;
                var count = (player && player.sentences) ? player.sentences.length : -1;
                note(failure ? 'ERR' : 'TTS', 'reader TTS start: sentences=' + count
                    + ' provider=' + ((this.setting || {}).provider || '?') + failure);
            };

            if (app.reader && typeof app.reader.loadChapterDisplay === 'function'
                && !app.reader.__stvTtsDisplayWrapped) {
                app.reader.__stvTtsDisplayWrapped = true;
                var originalLoad = app.reader.loadChapterDisplay;
                app.reader.loadChapterDisplay = function () {
                    var display = originalLoad.apply(this, arguments);
                    patchDisplay(display);
                    ensureSpeaker(display);
                    return display;
                };
            }

            patchDisplay(currentDisplay());
            note('TTS', 'reader TTS diagnostics installed');
            return true;
        }

        if (!attach()) {
            var attempts = 0;
            var timer = setInterval(function () {
                attempts++;
                if (attach() || attempts > 400) { clearInterval(timer); }
            }, 100);
        }
    })();
    """

    // MARK: - Comment button and offline book detail page

    /**
     Two unrelated dead ends that share one cause: the site reads a value the
     app-mode webview never populated.

       * `.btncomment` dereferences `app.reader.bookinfo.host` unguarded
         (app.v2.read.js:299). bookinfo is only filled in by updateHistory()'s
         asynchronous bookinfo.php response, so any open path that skips
         updateHistory makes the button throw -- "tapping comment does nothing".

       * The download manager builds its rows from
         `app.storage.cache.get('/mobile/bookinfo.php?...')` and hands the result
         to `openBookWithData(0, bi)`. On a cache miss `bi` is undefined and
         `page-bookinfo`'s first expression is
         `['sangtac','dich'].indexOf(root.data.host)` -- a TypeError, so the
         detail page renders blank ("even the detail page will not load").

     So: resolve bookinfo on demand for the comment button, warm the cache for
     every downloaded book, and refuse to push a detail page with no data.
     */
    static let pageRepair = """
    (function () {
        if (window.__stvPageRepairInstalled) { return; }
        window.__stvPageRepairInstalled = true;

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        function resolveBookInfo() {
            var app = window.app;
            var reader = app && app.reader;
            if (!reader) { return null; }
            var info = reader.bookinfo;
            if (info && info.host && info.id) { return Promise.resolve(info); }
            var host = reader.host;
            var id = reader.id;
            if (!host || !id) { return null; }
            return app.net.getCacheLater('/mobile/bookinfo.php?hid=' + id + '&host=' + host)
                .then(function (down) {
                    var book = down && down.book;
                    if (!book) { throw new Error('bookinfo.php returned no book'); }
                    reader.bookinfo = book;
                    note('BOOKINFO', 'resolved ' + host + '/' + id + ' for the comment button');
                    return book;
                });
        }

        document.addEventListener('click', function (event) {
            var node = event.target;
            while (node && node.nodeType === 1) {
                if (node.classList && node.classList.contains('btncomment')) { break; }
                node = node.parentElement;
            }
            if (!node || node.nodeType !== 1) { return; }
            var app = window.app;
            var info = app && app.reader && app.reader.bookinfo;
            if (info && info.host && info.id) { return; }
            event.stopImmediatePropagation();
            event.preventDefault();
            note('COMMENT', 'app.reader.bookinfo is empty; resolving it before opening comments');
            var pending = resolveBookInfo();
            if (!pending) {
                if (app && app.toast) { app.toast('无法确定书籍信息，评论暂不可用'); }
                return;
            }
            pending.then(function (book) {
                app.fun.showComment(book.host, book.id);
            }, function (error) {
                note('ERR', 'comment bookinfo lookup failed: ' + error);
                if (app && app.toast) { app.toast('评论加载失败'); }
            });
        }, true);

        function warmBookInfo() {
            var app = window.app;
            if (!app || !app.offlineBook || !app.offlineBook.store) { return; }
            var books = app.offlineBook.store.data || [];
            var index = 0;
            function step() {
                if (index >= books.length) {
                    note('BOOKINFO', 'offline bookinfo cache warm-up done ('
                        + books.length + ' book(s))');
                    return;
                }
                var book = books[index++];
                var base = (book && book.baseObject) || {};
                var host = (book && book.host) || base.host;
                var id = (book && book.id) || base.id;
                if (!host || !id) { step(); return; }
                var url = '/mobile/bookinfo.php?hid=' + id + '&host=' + host;
                app.net.getCacheLater(url).then(function (down) {
                    if (down && down.book) { note('BOOKINFO', 'cached ' + host + '/' + id); }
                    step();
                }, function (error) {
                    note('ERR', 'bookinfo warm-up failed for ' + host + '/' + id + ': ' + error);
                    step();
                });
            }
            step();
        }

        function attach() {
            var app = window.app;
            if (!app || !app.fun || typeof app.fun.openBookWithData !== 'function') { return false; }
            if (app.fun.__stvOpenBookWrapped) { return true; }
            app.fun.__stvOpenBookWrapped = true;
            var original = app.fun.openBookWithData;
            app.fun.openBookWithData = function (bookid, data) {
                if (data && data.host && data.id) { return original.call(this, bookid, data); }
                note('ERR', 'openBookWithData called with no book data (bookid=' + bookid
                    + ') -- refusing to push a blank detail page');
                if (app.toast) { app.toast('书籍信息缺失，请返回后重试'); }
                return null;
            };
            note('BOOKINFO', 'openBookWithData guard installed');
            return true;
        }

        if (!attach()) {
            var attempts = 0;
            var timer = setInterval(function () {
                attempts++;
                if (attach() || attempts > 400) { clearInterval(timer); }
            }, 100);
        }

        // `store.data` starts empty and is filled by the site's own async
        // store.load(); wait for it, but do not keep a 200ms timer alive for a
        // minute when the user has simply never downloaded a book.
        var warmAttempts = 0;
        var warmTimer = setInterval(function () {
            warmAttempts++;
            var app = window.app;
            var store = app && app.offlineBook && app.offlineBook.store;
            var loaded = !!(store && store.data && store.data.length);
            if (loaded || warmAttempts > 25) {
                clearInterval(warmTimer);
                warmBookInfo();
            }
        }, 200);
    })();
    """

    /// Injected in order; every block is independently guarded. `SiteI18nData`
    /// is generated from data/site-i18n.json by scripts/gen-site-i18n.js.
    static let all: [String] = [compat, diag, readerDefaults, ttsProvider,
                                followFallback, safeArea, settingsBackup,
                                bookmarkToggle, readerTts, pageRepair,
                                SiteI18nData.script]
}
