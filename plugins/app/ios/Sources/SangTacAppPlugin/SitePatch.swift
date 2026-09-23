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

        // The "static chapter name" option (static_chapter_name) is a one-way
        // trap in the site's own code. chapterdisplay.js:3350 apply() does
        //
        //     case "none": { cs.style.display = "none"; break; }
        //
        // and nothing ever clears that flag: the "top" / "bottom" cases only
        // rewrite cs.style.top / .bottom on a node that is still display:none.
        // So the moment 不显示 is chosen once, the pinned chapter name can never
        // come back -- switching the setting to 顶部 or 底部 changes nothing,
        // which is exactly "无论在设置里设置顶部还是底部 都不显示了".
        //
        // The pinned element itself (the body-level .chaptertopinfo in the
        // srcdoc template) is never removed, so re-applying the chosen side and
        // clearing the display flag is enough to bring the name straight back.
        function fixChapterPlace() {
            var app = window.app;
            if (!app || !app.config || !app.config.reader) { return; }
            var place = app.config.reader.chapter_name_fixed_place;
            var visible = (place === 'top' || place === 'bottom');
            var win = null;
            try { win = app.reader.getDisplay().innerWindow; } catch (e) { win = null; }
            if (!win || typeof win.q !== 'function') { return; }
            var list = win.q('.chaptertopinfo');
            var hidden = 0;
            for (var i = 0; i < list.length; i++) {
                var el = list[i];
                if (!el || !el.style) { continue; }
                if (el.style.display === 'none') { hidden++; }
                el.style.display = visible ? '' : 'none';
                if (!visible) { continue; }
                el.style.top = (place === 'top') ? '0' : 'unset';
                el.style.bottom = (place === 'bottom') ? '0' : 'unset';
            }
            if (window.__stvDiag) {
                window.__stvDiag.log('PATCH', 'chapter name place=' + place
                    + ' infos=' + list.length + ' were-hidden=' + hidden);
            }
        }

        function patchChapterPlace() {
            var app = window.app;
            if (!app || !app.reader || !app.reader.behaviour
                || !app.reader.behaviour.chapter_name_fixed_place) { return false; }
            var behaviour = app.reader.behaviour.chapter_name_fixed_place;
            if (behaviour.__stvPlacePatched) { return true; }
            behaviour.__stvPlacePatched = true;
            var original = behaviour.apply;
            behaviour.apply = function () {
                var result = null;
                try {
                    result = original.apply(this, arguments);
                } catch (e) {
                    if (window.__stvDiag) {
                        window.__stvDiag.log('ERR', 'chapter_name_fixed_place apply threw: ' + e);
                    }
                }
                fixChapterPlace();
                return result;
            };
            fixChapterPlace();
            return true;
        }

        var placeAttempts = 0;
        var placeTimer = setInterval(function () {
            placeAttempts++;
            if (patchChapterPlace() || placeAttempts > 400) { clearInterval(placeTimer); }
        }, 250);
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
                voice: { type: 'select', default: '', description: '发音人' },
                rate: { type: 'float', default: 1, min: 0.5, max: 2, description: '语速' },
                pitch: { type: 'float', default: 1, min: 0.5, max: 2, description: '音调' }
            };
        }

        IosTts.prototype.checkConfig = function () {};

        IosTts.prototype.sleep = function (ms) {
            return new Promise(function (resolve) { setTimeout(resolve, ms); });
        };

        // Counterpart of the MARK prefix the readerTts block puts on every
        // sentence it builds. The site's hasText() filter needs one ASCII word
        // character for a sentence to survive, and this is that character;
        // stripping it here is what keeps it out of the audio.
        var READER_MARK = 'stv0';

        IosTts.prototype.speak = function (text, options) {
            var self = this;
            var merged = options || {};
            var marked = (typeof text === 'string' && text.indexOf(READER_MARK) === 0);
            var spoken = marked ? text.substring(READER_MARK.length) : text;
            var param = {
                text: spoken,
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
                        + ' text=' + (spoken || '').length + ' chars'
                        + (marked ? ' (reader sentence, mark stripped)' : ''));
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
                        name: voice.name || ('发音人 ' + (i + 1)),
                        value: voice.identifier,
                        gender: (voice.gender === 1) ? 0 : 1
                    });
                }
                if (mapped.length === 0) {
                    mapped.push({ name: 'iOS 语音', value: '', gender: 1 });
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
            // The list is a fresh array literal on every call, so renaming in
            // place is safe. Only the Vietnamese-branded entries are renamed;
            // Bing / Zalo / FPT are brand names either way.
            var RENAMES = {
                'Sáng Tác Việt': '本站语音',
                'Viettelgroup TextToSpeech': 'Viettel 语音'
            };
            app.tts.engineList = function () {
                var list = originalList.call(this) || [];
                for (var i = 0; i < list.length; i++) {
                    if (list[i] && RENAMES[list[i].name]) { list[i].name = RENAMES[list[i].name]; }
                }
                for (var j = 0; j < list.length; j++) {
                    if (list[j] && list[j].value === 'ios') { return list; }
                }
                list.unshift({ name: 'iOS 语音（本机）', value: 'ios' });
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
        var VH100 = 'max(var(--vh100, 100vh), 100vh)';

        // 3. The main navbar (首页/搜索/社区/用户) shows through under every
        //    pushed page. #overlay is `position: fixed; height: var(--vh100)`
        //    (app.v2.css:262) while #mainview -- which owns #mainnavbar -- is
        //    given an inline `height: 100vh` by the site's own window.onresize
        //    (app.v2.js:4507). --vh100 comes from visualViewport.height and is
        //    re-derived on every resize, so any sample where it lands below the
        //    real viewport leaves the bottom strip of #mainview uncovered and
        //    the navbar sits in it. Matching the overlay to 100vh removes the
        //    dependency. The keyboard case is excluded: the site shrinks the
        //    overlay on purpose there and marks it with body[keyboardopen].
        var CSS = '#chapterview .titlebar{padding-top:' + INSET_TOP + ' !important;'
            + 'height:auto !important;box-sizing:content-box !important;}'
            + '#chapterview.showmenu .titlebar{top:0 !important;}'
            + '#chapterview .coption{padding-bottom:calc(12px + ' + INSET_BOTTOM + ') !important;}'
            + 'body[ovlwv] .titlebar{height:auto !important;box-sizing:content-box !important;'
            + 'padding-top:' + INSET_TOP + ' !important;}'
            + 'body[ovlwv] .bottombar{padding-bottom:' + INSET_BOTTOM + ' !important;}'
            + 'body:not([keyboardopen]) #overlay{height:' + VH100 + ' !important;}'
            + 'body:not([keyboardopen]) #overlay > div{height:' + VH100 + ' !important;}';

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
            var vh100 = (window.getComputedStyle(root).getPropertyValue('--vh100') || '').replace(' ', '');
            note('RECT', box('#chapterview .titlebar') + ' ' + box('#chapterview .coption')
                + ' ' + box('#overlay .titlebar', true) + ' ' + box('.usertop')
                + ' ' + box('#overlay') + ' ' + box('#mainnavbar')
                + ' viewport=' + window.innerHeight
                + ' status-bar=' + declared + '/' + resolved
                + ' vh100=' + (vh100 || 'unset')
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
     The site persists every setting through `app.storage`:

         app.config.saveReaderSetting() -> app.storage.cache.setFile('config.reader', ...)
         app.storage.cache.setFile     -> app.storage.set

     and `app.storage.set` is NOT localStorage. app.v2.js:531 picks the backend:

         if (Capacitor && Capacitor.Plugins.Preferences) { ... prefs.set ... }
         else { ... localStorage.setItem ... }

     Capacitor ships Preferences, so on iOS every one of these keys lands in
     UserDefaults -- while the previous version of this block restored into
     localStorage, which the site never reads. The backup was written correctly
     and then thrown away on the way back in: the device log said
     "0 of 3 backed-up key(s) written back" and the settings were still default.

     A sideloaded IPA gets reinstalled constantly (every build of this project),
     and a reinstall hands the app a fresh data container, so both stores are
     empty and every reader/UX/TTS setting silently falls back to its default.
     `app.storage.set` is the single funnel, so wrapping it is enough to mirror
     the keys that hold the user's own configuration -- including the dynamic
     `reader.style.<name>` font/size entries.

     The iOS keychain is not deleted with the app, so it is the one place on the
     device that survives a reinstall. The restore runs as soon as app.storage
     exists, and the site does not read its config until
     `onDbLoad.waitForLoad()` resolves (measured at ~4s on device), so the write
     always lands first. A key the store already holds is left alone; the backup
     only fills gaps, which after a wipe is every key.
     */
    static let settingsBackup = """
    (function () {
        if (window.__stvSettingsBackupInstalled) { return; }
        window.__stvSettingsBackupInstalled = true;

        var KEYS = ['config.reader', 'config.ux', 'config.comicReader', 'tts.setting',
                    'readthemeset', 'offlineBook'];
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

        // The store the site actually reads. Restoring anywhere else is a no-op,
        // which is what the localStorage version was.
        function siteStorage() {
            var app = window.app;
            if (!app || !app.storage) { return null; }
            if (typeof app.storage.get !== 'function' || typeof app.storage.set !== 'function') {
                return null;
            }
            return app.storage;
        }

        // `value: ''` means the store answered "nothing"; `failed` records a
        // backend that threw. The two need different repairs, and the previous
        // version collapsed them into the same empty string, which is why
        // "存储是空的" and "存储读不出来" were indistinguishable on device.
        function read(storage, key) {
            return Promise.resolve(storage.get(key)).then(function (value) {
                return { value: typeof value === 'string' ? value : '', failed: '' };
            }, function (error) {
                return { value: '', failed: String(error) };
            });
        }

        var restored = false;
        var lastEntries = null;
        var restoredKeys = [];

        function restore() {
            var plugin = appPlugin();
            if (!plugin || typeof plugin.settingsRestore !== 'function') { return false; }
            var storage = siteStorage();
            if (!storage) { return false; }
            if (restored) { return true; }
            restored = true;
            plugin.settingsRestore({}).then(function (result) {
                var entries = (result && result.entries) || {};
                lastEntries = entries;
                var keys = [];
                for (var key in entries) { if (isBackedUp(key)) { keys.push(key); } }
                var written = 0;
                var kept = [];
                var unusable = [];
                var unreadable = [];
                var mismatched = [];
                var chain = Promise.resolve();
                keys.forEach(function (key) {
                    chain = chain.then(function () {
                        var value = entries[key];
                        if (typeof value !== 'string' || value.length === 0) {
                            unusable.push(key + ':' + (value === null ? 'null' : typeof value));
                            return null;
                        }
                        return read(storage, key).then(function (found) {
                            // The store the site reads is authoritative whenever
                            // it has something: after a wipe it is empty and the
                            // backup is the only thing left, which is the case
                            // this whole block exists for.
                            if (found.failed) {
                                unreadable.push(key + ':' + found.failed);
                                return null;
                            }
                            if (found.value) {
                                kept.push(key + ':' + found.value.length);
                                return null;
                            }
                            return Promise.resolve(storage.set(key, value)).then(function () {
                                written++;
                                restoredKeys.push(key);
                                note('SETTINGS', 'restore ' + key + ' -> ' + value.length
                                    + ' chars (store was empty)');
                                // Write-through is the point of this block, and a
                                // backend that accepts a write and forgets it is
                                // exactly the failure being defended against, so
                                // read the value back instead of trusting resolve().
                                return read(storage, key).then(function (back) {
                                    if (back.value === value) { return null; }
                                    mismatched.push(key + ':' + back.value.length);
                                    note('ERR', 'restore readback mismatch for ' + key
                                        + ' (wrote ' + value.length + ' chars, read back '
                                        + back.value.length + ')');
                                    return null;
                                });
                            }, function (error) {
                                note('ERR', 'restore write failed for ' + key + ': ' + error);
                            });
                        });
                    });
                });
                return chain.then(function () {
                    note('SETTINGS', 'keychain restore: ' + written + ' written, '
                        + kept.length + ' kept [' + kept.join(' ') + '], '
                        + unreadable.length + ' unreadable [' + unreadable.join(' ') + '], '
                        + mismatched.length + ' not-persisted [' + mismatched.join(' ') + '], '
                        + unusable.length + ' unusable [' + unusable.join(' ') + '], of '
                        + keys.length + ' backed-up key(s)');
                });
            }).catch(function (e) {
                note('ERR', 'settingsRestore failed: ' + e);
            });
            return true;
        }

        // The site reads config.reader / config.ux / config.comicReader in
        // app.v2.config.js, right after app.v2.js evaluates -- which can easily
        // beat this block's keychain round trip. When it does, the running app
        // is already sitting on the defaults even though the store now holds the
        // restored values, so push them into the live config as well. Each key
        // has a setter that writes through to app.config._reader and re-saves,
        // so this also keeps the store and the UI consistent.
        //
        // Only the keys this block actually wrote are pushed. A key the store
        // already held is newer than the backup (that is why it was kept), and
        // replaying the backup over it would undo whatever the user changed since
        // the mirror was taken.
        var CONFIG_TARGETS = {
            'config.reader': 'reader',
            'config.ux': 'ux',
            'config.comicReader': 'comicReader'
        };

        function applyToLiveConfig(entries, restoredKeys) {
            var app = window.app;
            if (!app || !app.config) { return 0; }
            // app.v2.config.js only builds the getter/setter surface after its
            // own store round trip; before that there is nothing to assign to.
            if (!app.config.reader) { return 0; }
            var applied = 0;
            for (var storageKey in CONFIG_TARGETS) {
                if (restoredKeys && restoredKeys.indexOf(storageKey) < 0) { continue; }
                var target = app.config[CONFIG_TARGETS[storageKey]];
                var raw = entries[storageKey];
                if (!target || typeof raw !== 'string' || !raw) { continue; }
                var parsed = null;
                try { parsed = JSON.parse(raw); } catch (e) { continue; }
                if (!parsed || typeof parsed !== 'object') { continue; }
                for (var key in parsed) {
                    try {
                        target[key] = parsed[key];
                        applied++;
                    } catch (e) {}
                }
            }
            if (applied) {
                note('SETTINGS', 'live config updated: ' + applied + ' key(s)');
            }
            return applied;
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
        var liveApplied = false;
        var timer = setInterval(function () {
            attempts++;
            if (!restored) { restore(); }
            // The live push has to wait for app.v2.config.js, which on device
            // builds app.config.reader ~10s in; doing it only once inside the
            // restore chain is what left the running app on the defaults in the
            // device log (the chain finished long before the config module did).
            if (restored && !liveApplied && lastEntries && window.app && window.app.config
                && window.app.config.reader) {
                liveApplied = true;
                applyToLiveConfig(lastEntries, restoredKeys);
            }
            // Mirroring must not wait on the config module: it is what keeps the
            // next launch's backup current.
            var attached = attach();
            if ((restored && liveApplied && attached) || attempts > 1600) { clearInterval(timer); }
        }, 25);
    })();
    """

    // MARK: - Mirror failover for readchapter

    /**
     readchapter is answered by whichever mirror `networkManager.bestDomain()`
     picked, and the mirrors are not equivalent. The device log shows every
     chapter coming back as `{"code": 7,"time": 1000}` on
     `dns1.stv-appdomain-00000001.org` while the downloader -- which talks to a
     fixed host -- kept returning chapters throughout, and the same reader
     request on `sangtacviet.com` worked in the previous round's log.
     `verifyDomain()` only probes `/warp.php` and ranks the mirrors by ping, so a
     mirror that cannot serve the app read path still wins the race;
     `handlingException` then turns code 7 into the dead-end alert
     "Thiết bị không phù hợp hoặc phiên bản ứng dụng đã lỗi thời" and the chapter
     never appears.

     Two repairs, both driven by the server's own answer rather than a hard-coded
     host list:

       1. `bestDomain()` never returns a mirror that already answered code 7.
       2. a code 7 answer is intercepted on the way out of
          `app.reader.getContent` -- the single funnel every chapter goes through
          (chapterdisplay.js:788 / :1812 / :3680). The mirror that produced it is
          banned, the cached chapter key is dropped (it was issued by the mirror
          being left, and `getKey()` would otherwise keep reusing it), and the
          chapter is fetched again.

     The alert only survives if every mirror refuses.
     */
    static let domainFailover = """
    (function () {
        if (window.__stvDomainFailoverInstalled) { return; }
        window.__stvDomainFailoverInstalled = true;

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        var banned = {};
        var banCount = 0;
        var MAX_BANS = 3;
        var noted = {};

        function manager() {
            var app = window.app;
            return (app && app.net && app.net.networkManager) || null;
        }

        function origin(url) {
            if (!url) { return ''; }
            try { return new URL(String(url)).origin; } catch (e) { return ''; }
        }

        // Alive mirrors first, cheapest ping first -- the same ranking
        // bestDomain() uses -- then whatever else the site knows about, so a
        // banned mirror always has somewhere to fail over to.
        function candidates(mgr) {
            var list = [];
            var known = (mgr.domains || []).slice().sort(function (a, b) {
                var aAlive = a.status === 'alive' ? 0 : 1;
                var bAlive = b.status === 'alive' ? 0 : 1;
                if (aAlive !== bAlive) { return aAlive - bAlive; }
                return (a.ping || 0) - (b.ping || 0);
            });
            var i;
            for (i = 0; i < known.length; i++) { list.push(known[i].name); }
            var defaults = mgr.defaultDomains || [];
            for (i = 0; i < defaults.length; i++) {
                if (list.indexOf(defaults[i]) < 0) { list.push(defaults[i]); }
            }
            return list;
        }

        function pick(mgr, siteChoice) {
            var list = candidates(mgr);
            for (var i = 0; i < list.length; i++) {
                if (!banned[list[i]]) { return list[i]; }
            }
            return siteChoice;
        }

        function ban(domain, why) {
            if (!domain || banned[domain]) { return false; }
            banned[domain] = true;
            banCount++;
            note('DOMAIN', 'mirror ' + domain + ' banned: ' + why);
            return true;
        }

        function patchBestDomain() {
            var mgr = manager();
            if (!mgr || typeof mgr.bestDomain !== 'function') { return false; }
            if (mgr.__stvFailoverInstalled) { return true; }
            mgr.__stvFailoverInstalled = true;
            var original = mgr.bestDomain;
            mgr.bestDomain = function () {
                var siteChoice = original.apply(this, arguments);
                var chosen = pick(this, siteChoice);
                if (chosen && chosen !== siteChoice && !noted[siteChoice]) {
                    noted[siteChoice] = true;
                    note('DOMAIN', 'bestDomain ' + siteChoice + ' -> ' + chosen);
                }
                return chosen;
            };
            note('DOMAIN', 'mirror failover installed');
            return true;
        }

        function patchContent() {
            var app = window.app;
            if (!app || !app.reader || typeof app.reader.getContent !== 'function') { return false; }
            if (app.reader.__stvFailoverInstalled) { return true; }
            app.reader.__stvFailoverInstalled = true;
            var original = app.reader.getContent;
            app.reader.getContent = function (h, i, c, rl) {
                var self = this;
                var args = arguments;
                // Retried through this same wrapper, so more than one bad mirror
                // can be walked past in a single read. Each round either bans a
                // new mirror (banCount is bounded) or gives up and hands the
                // code 7 back to the site.
                function attempt() {
                    return Promise.resolve(original.apply(self, args)).then(function (data) {
                        if (!data || String(data.code) !== '7' || banCount >= MAX_BANS) {
                            return data;
                        }
                        var mgr = manager();
                        var bad = mgr ? origin(mgr.bestDomain ? mgr.bestDomain() : '') : '';
                        if (!ban(bad, 'readchapter answered code 7')) { return data; }
                        if (app.reader) { app.reader.cachekey = null; }
                        note('DOMAIN', 'refetching ' + h + '/' + i + ' chapter ' + c
                            + ' after code 7');
                        return attempt();
                    });
                }
                return attempt();
            };
            note('DOMAIN', 'readchapter failover installed');
            return true;
        }

        var attempts = 0;
        var timer = setInterval(function () {
            attempts++;
            var a = patchBestDomain();
            var b = patchContent();
            if ((a && b) || attempts > 600) { clearInterval(timer); }
        }, 50);
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

        // The site's sentence filter is
        //
        //     this.hasText = function () { return this.text.match(ASCII_WORD); }
        //     (app.v2.read.js:2357, written there as a literal regex)
        //
        // and that regex matches ASCII only, so every pure-Chinese sentence is
        // dropped before it ever reaches the queue. That is the whole of the
        // reader-TTS silence, and the device log proves it: the fallback built 23
        // sentences and the very next line reported sentences=0.
        //
        // Each sentence therefore carries this marker. It satisfies the regex,
        // it survives the site's own formatText(), and IosTts.speak strips it
        // again before the string is handed to AVSpeechSynthesizer -- so nothing
        // extra is ever spoken and the site's queue, prefetch and auto-advance
        // all keep working untouched.
        var MARK = 'stv0';

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

        // The reader iframe has no #maincontent: the pageflip template only
        // builds .chaptertopinfo, #mainscroller and #dragbar, and the scroller
        // holds the previous, current and next chapter side by side. Reading
        // body text therefore reads whichever chapters happen to be mounted --
        // which is why the device played text that was not the chapter on
        // screen. The current chapter owns exactly one .contentcontainer
        // (chapterdisplay.js:3615), so read that.
        function chapterHolder(display) {
            var view = null;
            try {
                view = display.getCurrentChapter ? display.getCurrentChapter()
                    : display.currentContainer;
            } catch (e) { view = null; }
            if (!view || typeof view.q !== 'function') { return null; }
            var holder = null;
            try { holder = view.q('.contentcontainer'); } catch (e) { holder = null; }
            return holder || null;
        }

        function textOf(node) {
            if (!node) { return ''; }
            return node.innerText || node.textContent || '';
        }

        function fallbackSentences(display) {
            var w = readerWindow(display);
            if (!w || !w.document) { return []; }
            var doc = w.document;
            var holder = chapterHolder(display);
            var text = textOf(holder);
            var source = 'current chapter';
            if (!text) {
                // Transient: the display is being rebuilt. Fall back to whatever
                // the document has rather than reporting nothing to play.
                source = 'document body';
                text = textOf(doc.getElementById('maincontent')) || textOf(doc.body);
            }
            var pieces = splitSentences(text);
            var list = [];
            for (var i = 0; i < pieces.length; i++) {
                list.push({ toText: toTextFor(MARK + pieces[i]), highlightOn: noop, highlightOff: noop });
            }
            note('TTS', 'fallback source [' + source + ']: ' + text.length + ' chars -> '
                + pieces.length + ' sentence(s), first='
                + (pieces.length ? pieces[0].substring(0, 20) : ''));
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
                if (list && list.length) {
                    note('TTS', 'site tokenizeSentence -> ' + list.length + ' sentence(s)');
                    return list;
                }
                var mine = fallbackSentences(this);
                note('TTS', 'site tokenizeSentence empty, using the chapter-text fallback -> '
                    + mine.length + ' sentence(s)');
                return mine;
            };
        }

        function currentDisplay() {
            var app = window.app;
            if (!app || !app.reader || typeof app.reader.getDisplay !== 'function') { return null; }
            try { return app.reader.getDisplay(); } catch (e) { return null; }
        }

        // app.tts.test() hardcodes a Vietnamese sample sentence
        // (app.v2.read.js:3174), so a Chinese reader gets a Vietnamese voice
        // reading Vietnamese words. Same five lines, Chinese text.
        function attachTest() {
            var app = window.app;
            if (!app || !app.tts || typeof app.tts.test !== 'function') { return false; }
            if (app.tts.__stvTestWrapped) { return true; }
            app.tts.__stvTestWrapped = true;
            app.tts.test = function () {
                var text = '这是一段中文语音测试，用来检查朗读是否正常。';
                if (typeof this.applyPlaybackSetting === 'function') { this.applyPlaybackSetting(); }
                if (!window.ttsEngine) { return; }
                window.ttsEngine.clearQueue();
                window.ttsEngine.requestAudio(text, {});
                window.ttsEngine.onFirstLoad(function () { app.tts.playQueue(); });
                note('TTS', 'test sentence is Chinese now');
            };
            return true;
        }

        // The site has no way to stop playback once the reader page is gone --
        // the queue keeps reading the old chapter from behind whatever page the
        // user moved on to. Stop it when #chapterview leaves the document; a
        // sub-page pushed from inside the reader keeps it mounted, so this only
        // fires on a real exit.
        function stopReaderTts(reason) {
            var app = window.app;
            if (!app || !app.tts) { return; }
            if (app.tts.__stvStoppedFor) { return; }
            app.tts.__stvStoppedFor = true;
            try {
                if (app.tts.player && typeof app.tts.player.stop === 'function') {
                    app.tts.player.stop();
                }
            } catch (e) {}
            try {
                if (window.ttsEngine && typeof window.ttsEngine.clearQueue === 'function') {
                    window.ttsEngine.clearQueue();
                }
            } catch (e) {}
            note('TTS', 'reader closed (' + reason + ') -> playback stopped');
        }

        function attachClose() {
            var app = window.app;
            if (!app || typeof app.popPage !== 'function') { return false; }
            if (app.__stvTtsCloseWrapped) { return true; }
            app.__stvTtsCloseWrapped = true;
            var original = app.popPage;
            app.popPage = function () {
                var hadReader = !!document.getElementById('chapterview');
                var result = original.apply(this, arguments);
                if (!hadReader) { return result; }
                // popPage animates; the element is gone a moment later.
                setTimeout(function () {
                    if (!document.getElementById('chapterview')) { stopReaderTts('page popped'); }
                }, 500);
                return result;
            };
            return true;
        }

        // The TTS settings page is the one screen whose labels come from JS
        // literals and from the engine list, so report what it actually shows
        // instead of assuming the overlay caught everything.
        function reportTtsPage() {
            var names = [];
            var nodes = document.querySelectorAll('.optionname');
            for (var i = 0; i < nodes.length; i++) {
                names.push((nodes[i].textContent || '').substring(0, 16));
            }
            var engines = [];
            try {
                var list = window.app.tts.engineList() || [];
                for (var j = 0; j < list.length; j++) { engines.push(list[j].name); }
            } catch (e) {}
            note('TTS', 'settings page: options=[' + names.join(' | ') + '] engines=['
                + engines.join(' | ') + ']');
        }

        function attachTtsPageProbe() {
            var app = window.app;
            if (!app || !app.tts || typeof app.tts.openSetting !== 'function') { return false; }
            if (app.tts.__stvPageProbeWrapped) { return true; }
            app.tts.__stvPageProbeWrapped = true;
            var originalOpen = app.tts.openSetting;
            app.tts.openSetting = function () {
                var result = originalOpen.apply(this, arguments);
                setTimeout(reportTtsPage, 600);
                return result;
            };
            return true;
        }

        function attach() {
            var app = window.app;
            if (!app || !app.tts || typeof app.tts.start !== 'function') { return false; }
            var testReady = attachTest();
            var closeReady = attachClose();
            var pageReady = attachTtsPageProbe();
            if (app.tts.__stvReaderTtsWrapped) { return testReady && closeReady && pageReady; }
            app.tts.__stvReaderTtsWrapped = true;

            var originalStart = app.tts.start;
            app.tts.start = function () {
                // Playing again clears the "already stopped for this reader"
                // latch that app.popPage set.
                this.__stvStoppedFor = false;
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
                var first = (player && player.sentences && player.sentences[0])
                    ? (player.sentences[0].text || '') : '';
                note(failure ? 'ERR' : 'TTS', 'reader TTS start: sentences=' + count
                    + ' first=' + first.length + ' chars provider='
                    + ((this.setting || {}).provider || '?') + failure);
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
            return testReady && closeReady && pageReady;
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

        // key -> bookinfo.php response. The response is memoised rather than a
        // boolean so a row that rendered without book data can still resolve the
        // book on tap without a second request.
        var warmed = {};

        // populateBookInfo() (app.v2.read.js:3258) answers from
        // app.storage.cache.get('/mobile/bookinfo.php?hid=<id>&host=<host>') and
        // silently returns [] on a cache miss. DownloadManager.render() (:3609)
        // then hands that `undefined` to openBookWithData, and the row's click
        // handler is bound to it -- so tapping a downloaded book opens nothing.
        // DownloadManager's constructor renders the row the instant the download
        // starts (:3481), before anything has had a chance to fill the cache, so
        // the only reliable repair is to fill it before render() reads it.
        function warmOne(host, id) {
            var app = window.app;
            if (!host || !id || !app || !app.net
                || typeof app.net.getCacheLater !== 'function') {
                return Promise.resolve(null);
            }
            var key = host + '/' + id;
            if (Object.prototype.hasOwnProperty.call(warmed, key)) {
                return Promise.resolve(warmed[key]);
            }
            var url = '/mobile/bookinfo.php?hid=' + id + '&host=' + host;
            return app.net.getCacheLater(url).then(function (down) {
                warmed[key] = down || null;
                note('BOOKINFO', 'warmed ' + key + ' -> '
                    + ((down && down.book) ? 'book cached' : 'no book in response'));
                return warmed[key];
            }, function (error) {
                // A failure is not memoised: the row is still on screen and the
                // next tap is a perfectly good time to try again.
                note('ERR', 'bookinfo warm-up failed for ' + key + ': ' + error);
                return null;
            });
        }

        function warmStore() {
            var app = window.app;
            var store = app && app.offlineBook && app.offlineBook.store;
            var books = (store && store.data) || [];
            var chain = Promise.resolve();
            for (var i = 0; i < books.length; i++) {
                (function (book) {
                    var base = (book && book.baseObject) || {};
                    var host = (book && book.host) || base.host;
                    var id = (book && book.id) || base.id;
                    chain = chain.then(function () { return warmOne(host, id); });
                })(books[i]);
            }
            return chain;
        }

        // The download endpoint is rate limited: the device log shows the first
        // eighteen chapters answered 200 and then everything came back 429 with
        // an HTML body, which fails JSON.parse and surfaces as
        // "Lỗi: Không thể đọc dữ liệu". DownloadManager.start() fires three
        // requests at once with no spacing, so the fix is to space the request
        // starts out; a failure widens the gap for the rest of the session.
        var DOWNLOAD_GAP = 900;
        var DOWNLOAD_GAP_MAX = 2500;
        var lastDownloadStart = 0;

        function downloadGate() {
            var now = Date.now();
            var wait = lastDownloadStart + DOWNLOAD_GAP - now;
            if (wait < 0) { wait = 0; }
            lastDownloadStart = now + wait;
            if (!wait) { return Promise.resolve(); }
            return new Promise(function (resolve) { setTimeout(resolve, wait); });
        }

        // The site's download row has no controls at all: pausing and retrying
        // live behind a long-press context menu and there is no way to drop a
        // task. Add both as buttons.
        //
        // Placement is the whole problem. The row is
        // `<div class="bookrowcont"><div class="bookrow">...` and app.v2.css
        // gives `.bookrowcont` a fixed `height: 77px` with `.bookrow`
        // `position: absolute` inside it, so a control bar appended in normal
        // flow is painted *under* the absolutely positioned row and every tap
        // lands on the row instead. The device log is unambiguous: tapping the
        // pause/delete area produced `openBookWithData called with no book data
        // (bookid=0)` -- the row's own handler, never ours. Grow the container
        // and lift the bar above the positioned row.
        function decorateRow(manager, node, book) {
            if (!node || node.__stvActions) { return; }
            node.__stvActions = true;
            node.__stvManager = manager;
            node.__stvBook = book || null;
            if (node.setAttribute) {
                node.setAttribute('data-stv-host', manager.host);
                node.setAttribute('data-stv-id', manager.id);
            }
            node.style.height = 'auto';
            node.style.minHeight = '77px';
            node.style.paddingBottom = '46px';
            var bar = document.createElement('div');
            node.__stvBar = bar;
            bar.setAttribute('style',
                'position:relative;z-index:5;display:flex;gap:6px;padding:0 6px 8px;');
            var toggle = document.createElement('button');
            var drop = document.createElement('button');
            toggle.setAttribute('style',
                'flex:1;padding:6px 0;font-size:13px;border-radius:6px;');
            drop.setAttribute('style',
                'flex:1;padding:6px 0;font-size:13px;border-radius:6px;');
            drop.textContent = '删除任务';
            function refresh() {
                toggle.textContent = manager.isPaused ? '继续下载' : '暂停下载';
            }
            toggle.addEventListener('click', function (event) {
                event.stopPropagation();
                event.preventDefault();
                if (manager.isPaused) { manager.start(); } else { manager.pause(); }
                refresh();
            });
            drop.addEventListener('click', function (event) {
                event.stopPropagation();
                event.preventDefault();
                manager.pause();
                var list = window.app.bookDownloaderList || [];
                var index = list.indexOf(manager);
                if (index >= 0) { list.splice(index, 1); }
                if (node.parentElement) { node.parentElement.removeChild(node); }
                note('DOWNLOAD', 'task removed from the download list');
            });
            refresh();
            bar.appendChild(toggle);
            bar.appendChild(drop);
            node.appendChild(bar);
        }

        function within(ancestor, node) {
            while (node) {
                if (node === ancestor) { return true; }
                node = node.parentNode;
            }
            return false;
        }

        function rowOf(node) {
            while (node && node.nodeType === 1) {
                if (node.__stvManager) { return node; }
                node = node.parentElement;
            }
            return null;
        }

        // Did the site's own render() get book data out of the cache? It writes
        // the title into `.tname` and nothing at all when populateBookInfo()
        // returned [].
        function rowHasBookData(node) {
            var title = node.querySelector ? node.querySelector('.tname') : null;
            return !!(title && String(title.textContent || '').length > 0);
        }

        // render() captures the bookinfo it read (:3609) into the row's click
        // handler (:3621), so a row that rendered without data can never open its
        // book -- the listener is anonymous and cannot be rebound. Handle that
        // tap here instead of letting the openBookWithData guard refuse it with
        // "书籍信息缺失": resolve the book and open the detail page.
        document.addEventListener('click', function (event) {
            var row = rowOf(event.target);
            if (!row || rowHasBookData(row)) { return; }
            var bar = row.__stvBar;
            if (bar && within(bar, event.target)) { return; }
            var manager = row.__stvManager;
            if (!manager) { return; }
            event.stopPropagation();
            event.preventDefault();
            note('DOWNLOAD', 'row ' + manager.host + '/' + manager.id
                + ' rendered without book info; resolving it for the tap');
            var pending = row.__stvBook
                ? Promise.resolve(row.__stvBook)
                : warmOne(manager.host, manager.id).then(function (down) {
                    var book = down && down.book ? down.book : null;
                    if (book) { row.__stvBook = book; }
                    return book;
                });
            pending.then(function (resolved) {
                var app = window.app;
                if (!resolved) {
                    if (app && app.toast) { app.toast('书籍信息缺失，请返回后重试'); }
                    return;
                }
                app.fun.openBookWithData(0, resolved);
            }, function (error) {
                note('ERR', 'download row bookinfo lookup failed: ' + error);
            });
        }, true);

        // Two entry points read that cache for a list of books: the download
        // manager's rows (render) and the 储物袋 downloaded list
        // (getDownloadBooks -> populateBookInfo). Warm in front of both.
        function patchReaders() {
            var app = window.app;
            if (!app || !app.offlineBook) { return false; }
            var manager = app.BookDownloadManager;
            if (manager && manager.prototype && !manager.prototype.__stvWarmed) {
                manager.prototype.__stvWarmed = true;
                var originalRender = manager.prototype.render;
                manager.prototype.render = function () {
                    var self = this;
                    var args = arguments;
                    return warmOne(self.host, self.id).then(function (down) {
                        return Promise.resolve(originalRender.apply(self, args))
                            .then(function (node) {
                                decorateRow(self, node, down && down.book ? down.book : null);
                                return node;
                            });
                    });
                };
                note('BOOKINFO', 'download manager render warmed');
            }
            if (manager && manager.prototype && !manager.prototype.__stvThrottled) {
                manager.prototype.__stvThrottled = true;
                var originalChapter = manager.prototype.downloadChapter;
                manager.prototype.downloadChapter = function () {
                    var self = this;
                    var args = arguments;
                    return downloadGate().then(function () {
                        return originalChapter.apply(self, args);
                    }, function (error) {
                        if (DOWNLOAD_GAP < DOWNLOAD_GAP_MAX) {
                            DOWNLOAD_GAP = DOWNLOAD_GAP_MAX;
                            note('DOWNLOAD', 'download failed, widening the gap to '
                                + DOWNLOAD_GAP + 'ms: ' + (error && error.message));
                        }
                        throw error;
                    });
                };
                note('DOWNLOAD', 'download throttle installed (' + DOWNLOAD_GAP + 'ms gap)');
            }
            if (typeof app.offlineBook.getDownloadBooks === 'function'
                && !app.offlineBook.__stvWarmedList) {
                app.offlineBook.__stvWarmedList = true;
                var originalList = app.offlineBook.getDownloadBooks;
                app.offlineBook.getDownloadBooks = function () {
                    var self = this;
                    var args = arguments;
                    return warmStore().then(function () {
                        return originalList.apply(self, args);
                    });
                };
                note('BOOKINFO', 'downloaded-list bookinfo warm-up installed');
            }
            return !!(manager && manager.prototype && manager.prototype.__stvWarmed
                    && manager.prototype.__stvThrottled)
                && !!app.offlineBook.__stvWarmedList;
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

        var patchAttempts = 0;
        var patchTimer = setInterval(function () {
            patchAttempts++;
            if (patchReaders() || patchAttempts > 600) { clearInterval(patchTimer); }
        }, 200);

        // Books downloaded after boot enter store.data later, so keep sweeping.
        // Cheap: warmOne() answers immediately for anything already warmed, and
        // the store holds a handful of entries.
        setInterval(warmStore, 3000);
    })();
    """

    // MARK: - First-paint shell

    /**
     The site's HTML arrives complete: `<tab id="mainview">` already contains
     `<tabbar id="mainnavbar">` with the four tabs. None of it is styled or wired
     until the site's stylesheet and roughly 750 KB of unminified JavaScript have
     been fetched and parsed, which on the device takes 8-20s (the boot samples
     in 日志.txt show `db loaded` -- i.e. app.v2.js finished evaluating -- eight
     seconds after document start). Until then the page is an unstyled pile of
     text on a white background.

     This block paints that window: a themed background, the bottom tab bar laid
     out, and a hint that fades itself out. It is scoped to `html.stv-boot` and
     the class is dropped as soon as the site's own stylesheet is in play, so
     nothing here can outlive the boot or fight the real UI.

     It also records the boot timeline, because "启动慢" needs numbers before it
     can be improved twice.
     */
    static let bootShell = """
    (function () {
        if (window.__stvBootShellInstalled) { return; }
        window.__stvBootShellInstalled = true;

        var started = Date.now();

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        var CSS = 'html.stv-boot{--background:#101014;--color:#e8e8ea;}'
            + 'html.stv-boot body{margin:0;background:var(--background);color:var(--color);'
            + 'font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;}'
            + 'html.stv-boot #mainview{display:flex;flex-direction:column;height:100vh;}'
            + 'html.stv-boot #mainnavbar{display:flex;align-items:stretch;'
            + 'justify-content:space-around;background:rgba(255,255,255,0.04);'
            + 'border-top:1px solid rgba(255,255,255,0.08);'
            + 'padding-bottom:env(safe-area-inset-bottom);}'
            + 'html.stv-boot #mainnavbar tabitem{flex:1;display:flex;flex-direction:column;'
            + 'align-items:center;justify-content:center;gap:2px;padding:8px 0;'
            + 'font-size:12px;opacity:0.7;}'
            + 'html.stv-boot #mainnavbar tabitem.active{opacity:1;}'
            + 'html.stv-boot #stv-boot-hint{position:fixed;left:0;right:0;top:44%;'
            + 'text-align:center;font-size:14px;opacity:0.55;'
            + 'animation:stv-boot-fade 1s ease 8s forwards;}'
            + '@keyframes stv-boot-fade{to{opacity:0;}}';

        var applied = false;
        var released = false;

        function style() {
            if (applied) { return true; }
            var head = document.head;
            if (!head) { return false; }
            var el = document.createElement('style');
            el.id = 'stv-boot-css';
            el.textContent = CSS;
            head.appendChild(el);
            applied = true;
            return true;
        }

        function hint() {
            if (!applied || document.getElementById('stv-boot-hint')) { return; }
            var node = document.createElement('div');
            node.id = 'stv-boot-hint';
            node.textContent = '载入中…';
            var host = document.body || document.documentElement;
            if (host) { host.appendChild(node); }
        }

        function release(reason) {
            if (released) { return; }
            released = true;
            var root = document.documentElement;
            if (root && root.className) {
                root.className = root.className.split('stv-boot').join('')
                    .split('  ').join(' ').replace(' ', '');
            }
            var node = document.getElementById('stv-boot-hint');
            if (node && node.parentNode) { node.parentNode.removeChild(node); }
            note('BOOT', 'shell released at +' + (Date.now() - started) + 'ms (' + reason + ')');
        }

        // The site's own stylesheet is the signal that the real UI is styled.
        // app.config is the belt-and-braces signal: if the file is ever renamed
        // or served from a different path, the site's JS booting is still proof
        // that our shell has done its job and must stop applying.
        function siteCssReady() {
            var sheets = document.styleSheets || [];
            for (var i = 0; i < sheets.length; i++) {
                var href = sheets[i].href || '';
                if (href.indexOf('app.v2.css') >= 0) { return 'app.v2.css'; }
            }
            if (window.app && window.app.config && window.app.config.reader) { return 'app.config'; }
            return '';
        }

        var samples = [
            [0, 'document start'],
            [1000, 'stylesheet'],
            [3000, 'stylesheet'],
            [6000, 'stylesheet'],
            [10000, 'stylesheet'],
            [20000, 'stylesheet']
        ];
        for (var i = 0; i < samples.length; i++) {
            (function (delay, label) {
                setTimeout(function () {
                    var ready = siteCssReady();
                    if (ready) {
                        release(ready + ' at +' + (Date.now() - started) + 'ms');
                    }
                    note('BOOT', '+' + (Date.now() - started) + 'ms ' + label
                        + ': app=' + (window.app ? 'yes' : 'no')
                        + ' config=' + ((window.app && window.app.config && window.app.config.reader)
                            ? 'yes' : 'no')
                        + ' navbar=' + (function () {
                            var node = document.getElementById('mainnavbar');
                            if (!node) { return 'absent'; }
                            return node.getBoundingClientRect
                                ? Math.round(node.getBoundingClientRect().height) + 'px' : 'unknown';
                        })());
                }, delay);
            })(samples[i][0], samples[i][1]);
        }

        var root = document.documentElement;
        if (root) {
            root.className = (root.className ? root.className + ' ' : '') + 'stv-boot';
        }
        if (!style()) {
            var headTimer = setInterval(function () {
                if (style()) { clearInterval(headTimer); }
            }, 20);
            setTimeout(function () { clearInterval(headTimer); }, 10000);
        }
        if (document.body) { hint(); }
        else { document.addEventListener('DOMContentLoaded', hint); }
        setTimeout(function () { release('timeout'); }, 30000);
    })();
    """

    /// Injected in order; every block is independently guarded. `SiteI18nData`
    /// is generated from data/site-i18n.json by scripts/gen-site-i18n.js.
    static let all: [String] = [compat, diag, readerDefaults, ttsProvider,
                                followFallback, safeArea, settingsBackup,
                                domainFailover, bookmarkToggle, readerTts,
                                pageRepair, bootShell, SiteI18nData.script]
}
