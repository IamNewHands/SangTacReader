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
     OFF by default, switched from 设置 -> 诊断 (that row is added by the
     comment-translation block, which already owns the settings page). This is
     what the reader asked for: with logging off there is no floating window at
     all -- no badge, no panel, no tap or console capture -- and `log()` returns
     immediately, so the buffer cannot grow. With logging on the badge is ALWAYS
     visible (not only after an error, which was the old behaviour) and the panel
     opens straight away. The choice survives a reinstall: it is mirrored into
     the keychain backup alongside the other settings (settingsBackup, key
     `stv.diag.settings`).

     Collapsed state is a 24px badge on the right edge showing the line count; it
     turns red as soon as anything is logged with tag ERR. The reader turns pages
     by tapping the right third of the screen
     (app.reader.menuTapMode == "centerlr"), so the panel keeps a HIDE button that
     dismisses the badge. Triple-tap the top-left corner opens the panel
     regardless. The expanded panel is anchored to the TOP (42% height) and its
     title bar can be dragged vertically, so the bottom 58% of the screen stays
     usable.
     */
    static let diag = """
    (function () {
        if (window.__stvDiagInstalled) { return; }
        window.__stvDiagInstalled = true;

        var NL = String.fromCharCode(10);
        var MAX = 800;
        // localStorage is the only store readable synchronously at document
        // start. app.storage is Capacitor Preferences and resolves a tick later,
        // which is too late to decide whether the floating window should exist.
        // The second key is the mirror the keychain backup carries across a
        // reinstall (settingsBackup mirrors every app.storage.set).
        var FLAG_KEY = 'stv.diag';
        var STORE_KEY = 'stv.diag.settings';
        var lines = [];
        var errors = 0;
        var root = null;
        var listEl = null;
        var countEl = null;
        var badge = null;
        var badgeHidden = false;
        var open = false;
        var enabled = readEnabled();

        function readEnabled() {
            try {
                return !!(window.localStorage
                    && window.localStorage.getItem(FLAG_KEY) === '1');
            } catch (e) {
                return false;
            }
        }

        function writeEnabled(on) {
            try {
                if (window.localStorage) {
                    window.localStorage.setItem(FLAG_KEY, on ? '1' : '0');
                }
            } catch (e) {}
        }

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
            badge.style.display = (enabled && !badgeHidden) ? 'block' : 'none';
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
            // Showing a window that the switch has turned off would contradict
            // the setting, so this is the one other place `enabled` is read.
            if (!enabled) { return; }
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
            // The switch is checked here and nowhere else: every caller (all the
            // other blocks, the console tee, the tap listeners) keeps working
            // unchanged and pays one boolean while logging is off.
            if (!enabled) { return; }
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

        // ---- the switch ------------------------------------------------------

        function activate() {
            if (!buildBadge()) { return false; }
            paintBadge();
            return true;
        }

        function persist(on) {
            var app = window.app;
            var storage = app && app.storage;
            if (!storage || typeof storage.set !== 'function') { return; }
            try {
                var call = storage.set(STORE_KEY, JSON.stringify({ enabled: !!on }));
                if (call && typeof call.catch === 'function') { call.catch(function () {}); }
            } catch (e) {}
        }

        /**
         Turn logging on or off. Off removes the badge and the panel and empties
         the buffer; on builds them and shows the panel immediately ("启用后就一直
         显示") -- the panel can still be closed with CLOSE/HIDE and reopened from
         the badge or from 设置 -> 诊断.
         */
        function setEnabled(on) {
            enabled = !!on;
            writeEnabled(enabled);
            persist(enabled);
            if (!enabled) {
                lines = [];
                errors = 0;
                badgeHidden = false;
                open = false;
                if (root && root.parentNode) { root.parentNode.removeChild(root); }
                if (badge && badge.parentNode) { badge.parentNode.removeChild(badge); }
                root = null;
                listEl = null;
                countEl = null;
                badge = null;
                return;
            }
            if (!activate()) {
                // document.body does not exist yet at document start.
                document.addEventListener('DOMContentLoaded', function () {
                    if (!enabled) { return; }
                    activate();
                    show();
                });
                return;
            }
            show();
            log('DIAG', 'logging on: the floating window stays until the switch is '
                + 'turned off (设置 -> 诊断)');
        }

        window.__stvDiag = {
            log: log,
            show: show,
            hide: hide,
            toggle: toggle,
            copy: copyAll,
            text: function () { return lines.join(NL); },
            lines: function () { return lines.slice(); },
            enabled: function () { return enabled; },
            setEnabled: setEnabled
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
                if (!enabled) { return orig.apply(console, arguments); }
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
            if (!enabled) { return; }
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
            if (!enabled) { return; }
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

        // A switch that was left on stays on across launches: the badge is
        // always visible and the panel opens with it, which is the "启用后就一直
        // 显示" the reader asked for. Everything stays off until then.
        if (enabled) {
            if (!activate()) {
                document.addEventListener('DOMContentLoaded', function () {
                    if (!enabled) { return; }
                    activate();
                    show();
                });
            } else {
                show();
            }
        }
    })();
    """

    // MARK: - Activity log for the common flows

    /**
     The diagnostics buffer is only useful when the flows a bug report goes
     through are in it. The other blocks each log their own subject (downloads,
     translation, TTS, bookmarks, storage, the mirror failover, the reader
     defaults); what was missing is the generic navigation surface every report
     starts from:

       * `[PAGE]` every page the app opens and every pop. `pushPage`
         (_page_vip.html:3125) is the single funnel for opening, `popPage`
         (:3238) the single exit, so the reader's path through the app becomes one
         line per step.
       * `[NAV]` every tab-bar tap, with the item's index and label. That is what
         separates "the tab never switched" from "the pane was empty", and it is
         the evidence for the download-list jump in `pageRepair`.
       * `[MSG]` every `app.toast` / `app.context.info` (app.v2.js:616 / :2300).
         Both are modal popups, and "what did the site say" is usually the whole
         question in a report.
       * `[BOOT]` when the app object appeared, so the buffer has a zero point.

     Every line goes through `__stvDiag.log`, which returns immediately while the
     logging switch is off, so this block costs one wrapped call per user action
     and nothing else.
     */
    static let activityLog = """
    (function () {
        if (window.__stvActivityLogInstalled) { return; }
        window.__stvActivityLogInstalled = true;

        var NL = String.fromCharCode(10);
        var TAB = String.fromCharCode(9);
        var CR = String.fromCharCode(13);

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        function tagOf(node) {
            return String((node && node.tagName) || '').toLowerCase();
        }

        // A tabitem's label is <text>...</text> once the site has localised it
        // (app.celoader.text), so read the text content and collapse runs of
        // whitespace by hand -- a regex would need a backslash, which both the
        // Swift literal and check-ios-shim.js forbid.
        function label(node) {
            var text = (node && node.textContent) ? String(node.textContent) : '';
            var out = '';
            var spaced = false;
            for (var i = 0; i < text.length; i++) {
                var ch = text.charAt(i);
                var blank = (ch === ' ' || ch === NL || ch === TAB || ch === CR);
                if (blank) {
                    if (!spaced && out) { out += ' '; }
                } else {
                    out += ch;
                }
                spaced = blank;
            }
            return out;
        }

        function childIndex(node) {
            var parent = node && node.parentNode;
            var kids = (parent && parent.children) || [];
            for (var i = 0; i < kids.length; i++) {
                if (kids[i] === node) { return i; }
            }
            return -1;
        }

        // Wraps one method so the call is logged with what the caller passed and
        // what came back. `this`, the arguments and the return value are all
        // preserved exactly, including a thrown error.
        function wrap(object, name, tag, describe) {
            if (!object || typeof object[name] !== 'function') { return false; }
            var flag = '__stvLogged_' + name;
            if (object[flag]) { return true; }
            object[flag] = true;
            var original = object[name];
            object[name] = function () {
                var out = original.apply(this, arguments);
                try { note(tag, describe(arguments, out)); } catch (e) {}
                return out;
            };
            return true;
        }

        function install() {
            var app = window.app;
            if (!app) { return false; }
            var ready = true;
            if (!wrap(app, 'pushPage', 'PAGE', function (args) {
                return 'open ' + args[0];
            })) { ready = false; }
            if (!wrap(app, 'popPage', 'PAGE', function () {
                return 'back';
            })) { ready = false; }
            if (!wrap(app, 'toast', 'MSG', function (args) {
                return 'toast: ' + args[0];
            })) { ready = false; }
            if (!wrap(app.context, 'info', 'MSG', function (args) {
                return 'info: ' + args[0];
            })) { ready = false; }
            return ready;
        }

        // A tabitem is what a finger hits, so this reads the same event the site
        // reads. Capture phase, so the line lands even when a handler stops
        // propagation.
        document.addEventListener('click', function (event) {
            var node = event.target;
            var item = null;
            while (node && node.nodeType === 1) {
                if (tagOf(node) === 'tabitem') { item = node; break; }
                node = node.parentNode;
            }
            if (!item) { return; }
            note('NAV', 'tab ' + childIndex(item) + ' ' + label(item));
        }, true);

        var attempts = 0;
        var timer = setInterval(function () {
            attempts++;
            if (install()) {
                clearInterval(timer);
                note('BOOT', 'activity log attached (pages, tabs, popups)');
                return;
            }
            if (attempts > 1500) {
                clearInterval(timer);
                note('BOOT', 'activity log attached without app.context.info'
                    + ' (that method never appeared)');
            }
        }, 40);
    })();
    """

    // MARK: - Site storage accessor

    /**
     The site persists everything through `app.storage`, and on iOS it picks the
     Capacitor Preferences branch (app.v2.js:534):

         app.storage.get = async function (key) {
             return await prefs.get({ key: key }).value;
         }

     Member access binds tighter than `await`, so that expression is
     `await ((prefs.get({ key: key })).value)` -- `.value` of a Promise is
     `undefined`, so the function returns `undefined` for every key, including
     keys it wrote a moment earlier. The Android APK never hits this:
     `@capacitor/preferences` is not a dependency there, so the site takes the
     localStorage branch and reads work. This build ships the plugin (CI's
     packageClassList contains `PreferencesPlugin`), so the broken branch is the
     live one -- the device log says so on every launch:

         [SETTINGS] restore config.reader -> 517 chars (store was empty)
         [ERR] restore readback mismatch for config.reader (wrote 517 chars, read back 0)

     Everything the site stores is affected: `config.reader` / `config.ux` (every
     setting), `offlineBook` (the download list), `readhistory`, and the bookinfo
     cache. Writes land; nothing is readable, so the site always falls back to its
     defaults and the download list is always empty on start.

     Replacing the accessor -- not wrapping it, because the original discards the
     value inside its own body -- is the smallest repair at the exact seam.
     */
    static let storageAccessor = """
    (function () {
        if (window.__stvStorageAccessorInstalled) { return; }
        window.__stvStorageAccessorInstalled = true;

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        function unwrap(result) {
            if (result && typeof result === 'object' && 'value' in result) {
                return result.value;
            }
            return result;
        }

        function patch() {
            var app = window.app;
            var Capacitor = window.Capacitor;
            if (!app || !app.storage || typeof app.storage.get !== 'function') { return false; }
            if (app.storage.__stvGetFixed) { return true; }
            var prefs = Capacitor && Capacitor.Plugins && Capacitor.Plugins.Preferences;
            if (!prefs) {
                // No Preferences plugin: the site is on the localStorage branch,
                // whose reads already work. Nothing to repair -- but the settings
                // restore waits for this flag, so publish it.
                window.__stvStorageAccessorPatched = true;
                return true;
            }
            app.storage.__stvGetFixed = true;
            app.storage.get = function (key) {
                // Resolve the call inside the chain so a synchronous throw from
                // the bridge is handled like a rejection.
                return Promise.resolve().then(function () {
                    return prefs.get({ key: key });
                }).then(unwrap, function (error) {
                    note('ERR', 'app.storage.get failed for ' + key + ': ' + error);
                    return undefined;
                });
            };
            window.__stvStorageAccessorPatched = true;
            note('STORAGE', 'app.storage.get reads the Preferences result properly');
            return true;
        }

        var attempts = 0;
        var timer = setInterval(function () {
            attempts++;
            if (patch() || attempts > 800) { clearInterval(timer); }
        }, 25);
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

    // MARK: - Keyboard vs popup inputs

    /**
     "点击下载时弹出起始章-结束章的输入框，此时系统的输入法也弹出来，但是这个下载框
     没有相应的往上移动，用户在输入时看不到输入框，只能盲打".

     The site does have a mechanism: with `Capacitor.Plugins.Keyboard` present it
     listens for `keyboardWillShow` and writes `--nkbheight: -<kbHeight>px` and
     `--popwithkb: 5%` onto `:root` (app.v2.js:4509-4531), and app.v2.css:1605-1608
     positions `.popupedit[hasedit]` with exactly those two variables. The plugin is
     in the build (CI's packageClassList carries `KeyboardPlugin`), yet the device log
     has no keyboard line at all, so whether those variables land -- and whether
     `position: absolute` survives the keyboard on iOS -- is unproven.

     Rather than depend on it, measure and place the popup directly: while the
     keyboard is up, anchor the popup just above it and let the popup body scroll,
     then hand the site's own CSS back when it hides. Both channels are watched
     (`visualViewport` always works in a WKWebView; the Capacitor events fire when
     the plugin does), and the numbers are reported so the next log can confirm.
     */
    static let keyboardPopup = """
    (function () {
        if (window.__stvKeyboardPopupInstalled) { return; }
        window.__stvKeyboardPopupInstalled = true;

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        function visualHeight() {
            var viewport = window.visualViewport;
            return (viewport && viewport.height) || window.innerHeight || 0;
        }

        // How much of the layout viewport the keyboard covers: the visual viewport
        // shrinks when it opens, so the difference is the keyboard.
        function keyboardHeight() {
            var viewport = window.visualViewport;
            if (!viewport) { return 0; }
            var covered = (window.innerHeight || 0) - viewport.height
                - (viewport.offsetTop || 0);
            return covered > 60 ? Math.round(covered) : 0;
        }

        var applied = '';

        function fix() {
            var pop = document.querySelector('.popupedit[hasedit]');
            var kb = keyboardHeight();
            var key = (pop ? 'popup' : 'none') + ':' + kb;
            if (key === applied) { return; }
            applied = key;
            if (!pop) { return; }
            var body = pop.querySelector('.popupedit_body');
            if (!kb) {
                pop.style.transform = '';
                pop.style.bottom = '';
                pop.style.maxHeight = '';
                if (body) { body.style.maxHeight = ''; }
                note('KEYBOARD', 'hidden, popup placement restored');
                return;
            }
            // Own the vertical placement while the keyboard is up: the site's own
            // transform lifts by its --nkbheight, which would double up with this.
            var visible = visualHeight();
            pop.style.transform = 'translate(-50%, 0px)';
            pop.style.bottom = (kb + 10) + 'px';
            pop.style.maxHeight = Math.max(160, visible - 20) + 'px';
            if (body) { body.style.maxHeight = Math.max(120, visible - 140) + 'px'; }
            var focused = document.activeElement;
            var name = (focused && focused.className) ? focused.className : '?';
            note('KEYBOARD', 'kb=' + kb + 'px visible=' + visible
                + 'px, popup anchored above the keyboard (focused=' + name + ')');
        }

        function soon() {
            fix();
            setTimeout(fix, 80);
            setTimeout(fix, 260);
            setTimeout(fix, 600);
        }

        if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', fix);
            window.visualViewport.addEventListener('scroll', fix);
        }
        window.addEventListener('resize', fix);
        document.addEventListener('focusin', soon, true);
        document.addEventListener('focusout', soon, true);
        var plugin = window.Capacitor && window.Capacitor.Plugins
            && window.Capacitor.Plugins.Keyboard;
        if (plugin && plugin.addListener) {
            plugin.addListener('keyboardWillShow', soon);
            plugin.addListener('keyboardWillHide', soon);
        }
        note('KEYBOARD', 'popup placement shim installed');
    })();
    """

    // MARK: - Grid tap targets

    /**
     The history / followed / bookmarked grids are built by
     `app.celoader.infbookgrid` (_page_vip.html:3873), which after rendering the
     cells does:

         var h = addedElements[0].scrollHeight;
         for (...) { addedElements[i].style.height = h + "px"; }

     Every cell is forced to the height of the *first* book, on top of flexbox
     already stretching each row's cells to its tallest one. The cell is also the
     click target (`e.addEventListener("click", ... openBookWithData)`, :3897), so
     the blank strip under a shorter card still belongs to that card. That is the
     "第一行和第二行之间空白很大，点空白处实际会变成点第一行的小说" report: the
     first book's title wraps furthest, its height wins, and every row inherits the
     leftover space as a tappable blank.

     Let each cell size to its own content and clamp the title to two lines, so the
     rows stay even without a forced height.
     */
    static let gridLayout = """
    (function () {
        if (window.__stvGridLayoutInstalled) { return; }
        window.__stvGridLayoutInstalled = true;

        var CSS = '.f-3-col, .f-sm-4-col, .f-md-6-col { align-items: flex-start;'
            + ' align-content: flex-start; }'
            + '.booksquarecont { height: auto !important; }'
            + '.booksquare .tname { display: -webkit-box; -webkit-line-clamp: 2;'
            + ' -webkit-box-orient: vertical; overflow: hidden; }'
            // The history grid is the one book grid built as a flex row of fixed
            // 33.33% cells; every other one (bookmark tab, search, ranking) is
            // `.grid.g-100px`, i.e. `repeat(auto-fill, minmax(100px, 1fr))`, which
            // packs as many columns as fit. Give the history grid the same shape so
            // it matches, and start-align the rows so the container's own
            // `height: 100%` (page-vip:3936) cannot stretch them apart.
            + '.stv-bookgrid4 { display: grid !important;'
            + ' grid-template-columns: repeat(auto-fill, minmax(100px, 1fr));'
            + ' gap: 3vw !important; align-content: start; }'
            + '.stv-bookgrid4 > * { max-width: none !important; }';

        function inject() {
            if (document.getElementById('stv-grid-layout')) { return true; }
            var head = document.head;
            if (!head) { return false; }
            var el = document.createElement('style');
            el.id = 'stv-grid-layout';
            el.textContent = CSS;
            head.appendChild(el);
            if (window.__stvDiag) {
                window.__stvDiag.log('GRID',
                    'cells size to their own content, titles clamped to 2 lines');
            }
            return true;
        }

        // `app.history.setContainer` (app.v2.js:3178-3217) builds the history grid
        // through app.celoader.infbookgrid and appends the flex container it
        // creates; infbookgrid has exactly one caller, so tagging that container is
        // how the CSS above is scoped to the history tab alone.
        function tagHistoryGrid() {
            var app = window.app;
            var history = app && app.history;
            if (!history || typeof history.setContainer !== 'function') { return false; }
            if (history.__stvGridTagged) { return true; }
            history.__stvGridTagged = true;
            var original = history.setContainer;
            history.setContainer = function () {
                var out = original.apply(this, arguments);
                try {
                    var host = this.container;
                    var kids = (host && host.children) || [];
                    var wrapper = kids.length ? kids[kids.length - 1] : null;
                    var grid = wrapper && wrapper.querySelector
                        ? wrapper.querySelector('.flex2.f-3-col') : null;
                    if (grid && grid.classList) {
                        grid.classList.add('stv-bookgrid4');
                        if (window.__stvDiag) {
                            window.__stvDiag.log('GRID',
                                'history grid switched to auto-fill columns');
                        }
                    }
                } catch (e) {}
                return out;
            };
            return true;
        }

        var attempts = 0;
        var timer = setInterval(function () {
            attempts++;
            var styled = inject();
            var tagged = tagHistoryGrid();
            if ((styled && tagged) || attempts > 2500) { clearInterval(timer); }
        }, 20);
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
                    'readthemeset', 'offlineBook', 'stv.translate.settings',
                    'stv.diag.settings'];
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

        // The logging switch (the diag block) is ours, not the site's, so it is
        // applied to that block rather than to a config object. Only when this
        // restore actually wrote the key: a value the store already held is newer
        // than the backup, which is the same rule CONFIG_TARGETS follows.
        var DIAG_KEY = 'stv.diag.settings';

        function applyDiagSetting(entries, keys) {
            if (!keys || keys.indexOf(DIAG_KEY) < 0) { return; }
            var raw = entries[DIAG_KEY];
            if (typeof raw !== 'string' || !raw) { return; }
            var parsed = null;
            try { parsed = JSON.parse(raw); } catch (e) { return; }
            var diag = window.__stvDiag;
            if (!diag || typeof diag.setEnabled !== 'function') { return; }
            diag.setEnabled(!!(parsed && parsed.enabled));
            note('SETTINGS', 'logging switch restored: '
                + (parsed && parsed.enabled ? 'on' : 'off'));
        }

        function restore() {
            var plugin = appPlugin();
            if (!plugin || typeof plugin.settingsRestore !== 'function') { return false; }
            var storage = siteStorage();
            if (!storage) { return false; }
            // Wait for the storage accessor repair. Until app.storage.get returns
            // what was written, an empty read is indistinguishable from a broken
            // one -- and treating a broken read as "the store is empty" would
            // write this backup over settings the user has changed since it was
            // taken. The accessor block publishes the flag; it always does, even
            // when there is nothing to repair.
            if (!window.__stvStorageAccessorPatched) { return false; }
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
                    applyDiagSetting(entries, restoredKeys);
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

        // The same race the live-config push solves, for the download list: the
        // records are restored into the store, but `app.offlineBook.store.load()`
        // (app.v2.js:624) has usually already run -- and before the storage
        // accessor was repaired it always read nothing -- so the in-memory list
        // the download page renders from stays empty. Push the records in.
        function applyOfflineBookToLiveStore(entries, restoredKeys) {
            var app = window.app;
            if (!app || !app.offlineBook || !app.offlineBook.store) { return 0; }
            if (restoredKeys.indexOf('offlineBook') < 0) { return 0; }
            var raw = entries['offlineBook'];
            if (typeof raw !== 'string' || !raw) { return 0; }
            var parsed = null;
            try { parsed = JSON.parse(raw); } catch (e) { return 0; }
            if (!parsed || !parsed.length) { return 0; }
            var store = app.offlineBook.store;
            var current = store.data || [];
            var merged = current.slice();
            for (var i = 0; i < parsed.length; i++) {
                var record = parsed[i];
                if (!record || !record.host || !record.id) { continue; }
                var known = false;
                for (var j = 0; j < merged.length; j++) {
                    if (merged[j] && merged[j].host === record.host
                        && merged[j].id === record.id) { known = true; break; }
                }
                if (!known) { merged.push(record); }
            }
            if (merged.length === current.length) { return 0; }
            store.data = merged;
            note('SETTINGS', 'download records restored into the live store: '
                + merged.length + ' book(s)');
            return merged.length;
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
        var offlineApplied = false;
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
            // app.offlineBook is built inside its own async IIFE (read.js:3186),
            // so it appears even later than the config module.
            if (restored && !offlineApplied && lastEntries && window.app
                && window.app.offlineBook && window.app.offlineBook.store) {
                offlineApplied = true;
                applyOfflineBookToLiveStore(lastEntries, restoredKeys);
            }
            // Mirroring must not wait on the config module: it is what keeps the
            // next launch's backup current.
            var attached = attach();
            if ((restored && liveApplied && offlineApplied && attached)
                || attempts > 1600) {
                clearInterval(timer);
            }
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

     The block has since taken on the whole download flow, because that is where
     the device reports landed: the range dialog (an end chapter instead of the
     hard-coded count of 20), duplicate starts and duplicate rows, keeping a
     running book out of the DOWNLOADED list, the missing delete button, and a
     confirmation dialog whose button jumps to the download list.
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
        // eighteen chapters answered 200 and then everything came back 429 with an
        // HTML body, which fails JSON.parse and surfaces as
        // "Lỗi: Không thể đọc dữ liệu". DownloadManager.start() fires three
        // requests at once with no spacing, so request starts are spaced out.
        //
        // The gap adapts: a failure widens it (the server is throttling), a run of
        // successes walks it back towards the floor. It is the only pacing knob --
        // the site's own 3s nap between batches is dropped in the start() wrapper
        // below, because this gap already spaces every request start.
        var DOWNLOAD_GAP_MIN = 900;
        var DOWNLOAD_GAP_MAX = 2500;
        var DOWNLOAD_GAP = DOWNLOAD_GAP_MIN;
        var DOWNLOAD_OK_RUN = 0;
        var lastDownloadStart = 0;

        function sleep(ms) {
            return new Promise(function (resolve) { setTimeout(resolve, ms); });
        }

        function downloadGate() {
            var now = Date.now();
            var wait = lastDownloadStart + DOWNLOAD_GAP - now;
            if (wait < 0) { wait = 0; }
            lastDownloadStart = now + wait;
            if (!wait) { return Promise.resolve(); }
            return sleep(wait);
        }

        function widenGate(why) {
            DOWNLOAD_OK_RUN = 0;
            if (DOWNLOAD_GAP >= DOWNLOAD_GAP_MAX) { return; }
            DOWNLOAD_GAP = DOWNLOAD_GAP_MAX;
            note('DOWNLOAD', 'throttled (' + why + '), gap widened to '
                + DOWNLOAD_GAP + 'ms');
        }

        function relaxGate() {
            DOWNLOAD_OK_RUN++;
            if (DOWNLOAD_OK_RUN < 10 || DOWNLOAD_GAP <= DOWNLOAD_GAP_MIN) { return; }
            DOWNLOAD_GAP = Math.max(DOWNLOAD_GAP_MIN, DOWNLOAD_GAP - 400);
            DOWNLOAD_OK_RUN = 0;
            note('DOWNLOAD', 'gap relaxed to ' + DOWNLOAD_GAP + 'ms');
        }

        // The site's download row has no controls at all: pausing and retrying
        // live behind a long-press context menu and there is no way to drop a
        // task. Add both as buttons.
        //
        // Placement is the whole problem. The row is
        // `<div class="bookrowcont"><div class="bookrow">...` and app.v2.css
        // gives `.bookrowcont` a fixed `height: 77px` with `.bookrow`
        // `position: absolute` inside it, so a control bar appended in normal
        // flow starts at the container's top (the row is out of flow), is painted
        // *under* the positioned row, and every tap lands on the row instead. The
        // device log is unambiguous: tapping the pause/delete area produced
        // `openBookWithData called with no book data (bookid=0)` -- the row's own
        // handler, never ours. Let the container grow, push the bar below the
        // 77px the row occupies, and lift it above the positioned row.
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
            var bar = document.createElement('div');
            node.__stvBar = bar;
            bar.setAttribute('style',
                'position:relative;z-index:5;margin-top:77px;display:flex;gap:6px;'
                + 'padding:0 6px 8px;');
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
                // The "DOWNLOADING (n)" counter and the list are redrawn by
                // onUpdate() (page-vip:4044 reads the list length into .total).
                // Without it the row disappears while the page still says (1).
                if (typeof list.onUpdate === 'function') { list.onUpdate(); }
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

        // A job is live while its loop is running and it still has chapters to
        // fetch. A paused or finished job is not live: a paused job's book is a
        // perfectly good entry for the DOWNLOADED list, and a fresh start() is a
        // legitimate new task.
        function liveJob(host, id) {
            var list = (window.app && window.app.bookDownloaderList) || [];
            for (var i = 0; i < list.length; i++) {
                var job = list[i];
                if (!job || job.host != host || job.id != id) { continue; }
                if (job.isPaused) { continue; }
                if (job.total && job.downloaded >= job.total) { continue; }
                return job;
            }
            return null;
        }

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
                // render() (:3605) is async and its only guard is `if (this.node)`,
                // which it reads before its first await. Two onUpdate() calls in
                // flight -- the constructor's, plus the ones our own buttons and
                // the completion hand-off fire -- therefore both get past that
                // guard, both build a node, and the list shows one job twice
                // ("下载页面有时会出现两次相同的下载"). Memoise the promise, not
                // just the finished node, so the second caller awaits the first.
                manager.prototype.render = function () {
                    var self = this;
                    var args = arguments;
                    if (self.node) { return Promise.resolve(self.node); }
                    if (self.__stvRenderPending) { return self.__stvRenderPending; }
                    self.__stvRenderPending = warmOne(self.host, self.id).then(
                        function (down) {
                            return Promise.resolve(originalRender.apply(self, args))
                                .then(function (node) {
                                    decorateRow(self, node,
                                        down && down.book ? down.book : null);
                                    self.__stvRenderPending = null;
                                    return node;
                                });
                        }, function (error) {
                            self.__stvRenderPending = null;
                            throw error;
                        });
                    return self.__stvRenderPending;
                };
                note('BOOKINFO', 'download manager render warmed');
            }
            if (manager && manager.prototype && !manager.prototype.__stvThrottled) {
                manager.prototype.__stvThrottled = true;
                var originalChapter = manager.prototype.downloadChapter;
                // The site retries a chapter a few times at 200-300ms and then
                // gives up, and start()'s catch turns that into `isBreak = true`
                // and abandons every remaining chapter. Retry here with a real
                // backoff instead, so a throttled chapter delays the job instead of
                // truncating the book.
                var CHAPTER_BACKOFF = [1500, 3000, 6000];
                manager.prototype.downloadChapter = function () {
                    var self = this;
                    var args = arguments;
                    var round = 0;
                    function once() {
                        return downloadGate().then(function () {
                            return originalChapter.apply(self, args);
                        }).then(function (result) {
                            relaxGate();
                            return result;
                        }, function (error) {
                            if (round >= CHAPTER_BACKOFF.length) { throw error; }
                            var wait = CHAPTER_BACKOFF[round];
                            round++;
                            widenGate('chapter failed: ' + (error && error.message));
                            note('DOWNLOAD', 'retry ' + round + '/'
                                + CHAPTER_BACKOFF.length + ' for ' + self.host + '/'
                                + self.id + ' chapter ' + args[0] + ' in ' + wait + 'ms');
                            return sleep(wait).then(once);
                        });
                    }
                    return once();
                };
                note('DOWNLOAD', 'download throttle installed (' + DOWNLOAD_GAP + 'ms gap)');
            }
            if (manager && manager.prototype && !manager.prototype.__stvStartGuarded) {
                manager.prototype.__stvStartGuarded = true;
                var originalStart = manager.prototype.start;
                manager.prototype.start = function () {
                    var self = this;
                    // A start() that arrives while the loop is still winding down
                    // after a pause is a resume and is replayed once it exits; a
                    // plain repeat start() is a no-op, otherwise the replay would
                    // spawn the second loop this guard exists to prevent.
                    if (self.__stvStartRunning) {
                        if (self.isPaused) { self.__stvStartAgain = true; }
                        note('DOWNLOAD', 'start() ignored while a loop is running for '
                            + self.host + '/' + self.id);
                        return Promise.resolve();
                    }
                    self.__stvStartRunning = true;
                    var done = function () {
                        self.__stvStartRunning = false;
                        if (self.__stvStartAgain) {
                            self.__stvStartAgain = false;
                            return self.start();
                        }
                        return null;
                    };
                    var run;
                    try {
                        run = runJob(self);
                    } catch (error) {
                        note('ERR', 'download loop failed, falling back to the site one: '
                            + error);
                        run = originalStart.apply(self, arguments);
                    }
                    return Promise.resolve(run)
                        .then(function (result) { done(); return result; },
                              function (error) { done(); throw error; });
                };
                note('DOWNLOAD', 'download loop replaced (no 3s nap, a failure no longer'
                    + ' truncates the job)');
            }
            if (typeof app.offlineBook.getDownloadBooks === 'function'
                && !app.offlineBook.__stvWarmedList) {
                app.offlineBook.__stvWarmedList = true;
                var originalList = app.offlineBook.getDownloadBooks;
                // getNewBook() (app.v2.read.js:3231) calls book.save(), which
                // prepends the record to store.data, the instant the download
                // starts -- so an unfinished job was already listed under
                // DOWNLOADED ("正在下载中的任务还没完成就已经在已下载中显示了").
                // Serve the list from the store minus every live job instead.
                //
                // The record itself stays: the reader resolves offline chapters
                // through isBookExist(), so removing it would break offline
                // reading of a partially downloaded book. Only the view changes.
                //
                // store.data is swapped for the duration of the call because
                // getDownloadBooks slices it by index before populating, so
                // filtering afterwards would shift the page's 20-per-page
                // accounting. The swap is not reentrant, hence the chain.
                var listChain = Promise.resolve();
                app.offlineBook.getDownloadBooks = function () {
                    var self = this;
                    var args = arguments;
                    var run = function () {
                        return warmStore().then(function () {
                            var store = app.offlineBook.store;
                            var all = (store && store.data) || [];
                            var visible = [];
                            for (var i = 0; i < all.length; i++) {
                                if (!liveJob(all[i].host, all[i].id)) {
                                    visible.push(all[i]);
                                }
                            }
                            if (visible.length === all.length) {
                                return originalList.apply(self, args);
                            }
                            store.data = visible;
                            return Promise.resolve(originalList.apply(self, args))
                                .then(function (books) {
                                    store.data = all;
                                    return books;
                                }, function (error) {
                                    store.data = all;
                                    throw error;
                                });
                        });
                    };
                    var next = listChain.then(run, run);
                    listChain = next.then(function () {}, function () {});
                    return next;
                };
                note('BOOKINFO', 'downloaded-list bookinfo warm-up installed');
            }
            return !!(manager && manager.prototype && manager.prototype.__stvWarmed
                    && manager.prototype.__stvThrottled)
                && !!app.offlineBook.__stvWarmedList;
        }

        // The site's loop (app.v2.read.js:3488-3532) runs three chapters at a time,
        // sleeps 3000ms between batches, and abandons the whole job on the first
        // chapter that fails. Re-implemented with the same total/downloaded
        // accounting so that the redundant nap is gone (the adaptive gap already
        // paces request starts), a failing chapter is recorded instead of
        // truncating the book, and completion can hand the book to the DOWNLOADED
        // list.
        var MAX_PARALLEL = 3;

        function runJob(manager) {
            var self = manager;
            self.isPaused = false;
            if (self.setStatus) { self.setStatus('Đang tải...'); }
            var queue = (self.chapters || []).slice();
            var failed = [];
            function step() {
                if (self.isPaused || !queue.length) { return Promise.resolve(); }
                var batch = queue.splice(0, MAX_PARALLEL);
                return Promise.all(batch.map(function (cid) {
                    return self.downloadChapter(cid).then(function () {
                        self.downloaded++;
                        if (self.onProgress) { self.onProgress(); }
                        var index = self.chapters.indexOf(cid);
                        if (index >= 0) { self.chapters.splice(index, 1); }
                        console.log(self.downloaded + '/' + self.total);
                    }, function (error) {
                        failed.push(cid);
                        note('DOWNLOAD', 'chapter ' + cid + ' of ' + self.host + '/'
                            + self.id + ' gave up: ' + (error && error.message));
                    });
                })).then(function () {
                    if (self.isPaused) { return null; }
                    return step();
                });
            }
            return step().then(function () {
                if (self.total && self.total === self.downloaded) {
                    if (self.setStatus) { self.setStatus('Hoàn thành'); }
                    if (self.book && self.book.save) { self.book.save(); }
                    moveJobToDownloaded(self);
                } else if (failed.length) {
                    note('DOWNLOAD', 'finished with ' + failed.length + ' chapter(s)'
                        + ' missing for ' + self.host + '/' + self.id);
                }
                if (self.status && self.status.textContent === 'Đang tải...') {
                    if (self.setStatus) { self.setStatus('Đã dừng'); }
                }
                if (self.onProgress) { self.onProgress(); }
                if (failed.length) { self.isPaused = true; }
            });
        }

        // The site's completion branch only sets a status and saves the record
        // (app.v2.read.js:3521-3524): the finished job stays in the DOWNLOADING
        // list, the "(n)" counter never drops, and the DOWNLOADED list -- built
        // once when the view loads (page-vip:4038-4076, its pull-to-refresh is
        // commented out) -- never learns about the new book.
        function moveJobToDownloaded(manager) {
            var app = window.app;
            var list = app.bookDownloaderList || [];
            var index = list.indexOf(manager);
            if (index >= 0) { list.splice(index, 1); }
            if (manager.node && manager.node.parentElement) {
                manager.node.parentElement.removeChild(manager.node);
            }
            if (typeof list.onUpdate === 'function') { list.onUpdate(); }
            var host = manager.host;
            var id = manager.id;
            warmOne(host, id).then(function (down) {
                var book = down && down.book ? down.book : null;
                var container = document.getElementById('download-manager');
                var area = container ? container.parentElement : null;
                if (!book || !area || !app.celoader
                    || typeof app.celoader.bookdownloadedrow !== 'function') {
                    note('DOWNLOAD', 'finished ' + host + '/' + id
                        + '; the DOWNLOADED list is not open');
                    return;
                }
                var data = {};
                var key;
                for (key in book) { data[key] = book[key]; }
                var base = (manager.book && manager.book.baseObject) || {};
                for (key in base) { data[key] = base[key]; }
                if (!data.chaptercount) { data.chaptercount = manager.total; }
                data.totalDownloaded = manager.downloaded;
                var row = app.celoader.bookdownloadedrow(null, data);
                if (row) {
                    area.appendChild(row);
                    note('DOWNLOAD', 'moved ' + host + '/' + id + ' into the DOWNLOADED list');
                }
            }, function () {});
        }

        // Nothing in the site can delete a downloaded book: the row
        // (page-vip:4014-4037) renders the cover, the title and "Đã tải N/M" and
        // that is all, while OfflineBook.deleteAll() (app.v2.read.js:3368) removes
        // the chapter bodies and delete() (:3314) removes the record. Add both.
        //
        // The loader is `app.celoader` (page-vip:3610; bookdownloadedrow at
        // :4014, called from the downloaded list at :4074). An earlier revision
        // guarded on `app.celldisplay`, which does not exist anywhere in the
        // site bundle, so this patch never installed and the rows had no delete
        // button at all.
        function patchDownloadedRow() {
            var app = window.app;
            if (!app || !app.celoader
                || typeof app.celoader.bookdownloadedrow !== 'function') { return false; }
            if (app.celoader.__stvRowPatched) { return true; }
            app.celoader.__stvRowPatched = true;
            var original = app.celoader.bookdownloadedrow;
            app.celoader.bookdownloadedrow = function (ele, data) {
                var node = original.apply(this, arguments);
                decorateDownloadedRow(node, data);
                return node;
            };
            note('DOWNLOAD', 'downloaded rows get a delete button');
            return true;
        }

        function decorateDownloadedRow(node, data) {
            if (!node || node.__stvDelete) { return; }
            node.__stvDelete = true;
            var book = data || {};
            // Same trap as the job row: `.bookrowcont` is a fixed 77px box with an
            // absolutely positioned `.bookrow` inside, so anything appended in
            // normal flow is painted underneath and cannot be tapped.
            node.style.height = 'auto';
            node.style.minHeight = '77px';
            var bar = document.createElement('div');
            bar.setAttribute('style',
                'position:relative;z-index:5;margin-top:77px;display:flex;gap:6px;'
                + 'padding:0 6px 8px;justify-content:flex-end;');
            var button = document.createElement('button');
            button.textContent = '删除';
            button.setAttribute('style', 'padding:6px 12px;font-size:13px;border-radius:6px;');
            button.addEventListener('click', function (event) {
                event.stopPropagation();
                event.preventDefault();
                var app = window.app;
                var target = app.offlineBook && app.offlineBook.getExistedBook
                    ? app.offlineBook.getExistedBook({ host: book.host, id: book.id })
                    : null;
                var finish = function () {
                    if (node.parentElement) { node.parentElement.removeChild(node); }
                    note('DOWNLOAD', 'removed downloaded book ' + book.host + '/' + book.id);
                };
                if (!target) { finish(); return; }
                note('DOWNLOAD', 'deleting downloaded book ' + book.host + '/' + book.id);
                Promise.resolve(target.deleteAll())
                    .then(function () { return target.delete(); })
                    .then(function () {
                        return app.offlineBook.store && app.offlineBook.store.save
                            ? app.offlineBook.store.save() : null;
                    })
                    .then(finish, function (error) {
                        note('ERR', 'delete failed for ' + book.host + '/' + book.id
                            + ': ' + error);
                    });
            });
            bar.appendChild(button);
            node.appendChild(bar);
        }

        // The same novel is usually mirrored on several hosts, and the source the
        // detail page happened to open is not always the one worth downloading.
        // The chapter-list page already asks
        // /mobile/bookmanage.php?act=getallhost&name=&author= and builds a tab per
        // source (app.v2.js:4429-4472); reuse that endpoint for the dialog.
        function fillSources(select, book) {
            if (!select || !book || !book.name) { return; }
            var url = '/mobile/bookmanage.php?act=getallhost&name='
                + encodeURIComponent(book.name) + '&author='
                + encodeURIComponent(book.author || '');
            app.net.get(url, true).then(function (down) {
                var list = down && down.code != -1 && down.data ? down.data : null;
                if (!list || !list.length) {
                    list = [{ host: book.host, id: book.id, chaptercount: book.chaptercount }];
                }
                var current = -1;
                var names = [];
                for (var i = 0; i < list.length; i++) {
                    names.push(list[i].host);
                    if (list[i].host === book.host
                        && String(list[i].id) === String(book.id)) {
                        current = i;
                    }
                }
                if (current < 0) {
                    list.unshift({ host: book.host, id: book.id,
                                   chaptercount: book.chaptercount });
                    names.unshift(book.host);
                    current = 0;
                }
                select.innerHTML = '';
                for (var j = 0; j < list.length; j++) {
                    var option = document.createElement('option');
                    option.value = list[j].host + '|' + list[j].id;
                    option.textContent = list[j].host + ' (' + list[j].chaptercount + ')';
                    select.appendChild(option);
                }
                select.selectedIndex = current;
                select.__stvSources = list;
                note('DOWNLOAD', 'sources: ' + list.length + ' [' + names.join(' ') + ']');
            }, function (error) {
                note('ERR', 'source list failed: ' + error);
            });
        }

        // ---- "download started" dialog and the jump to the download list ----

        // "选好下载范围点击下载后，要有个提示窗口说明开始下载了，然后有按钮可以直接
        // 跳转到下载界面". The site shows nothing: startdownload closes the range
        // dialog and the job's row only appears inside 书架 -> 下载, which is two
        // taps away and invisible while the reader is still on the detail page.
        //
        // The dialog reuses the site's own popup template (app.context.popup,
        // app.v2.js:2195): `button` HTML whose elements carry an `action`
        // attribute, dispatched to action[name](pop) at :2218-2243.
        function dismissPopup(pop) {
            var overlay = pop && pop.parentNode;
            if (!overlay) { return; }
            if (typeof overlay.hide === 'function') { overlay.hide(); return; }
            if (overlay.removeChild) { overlay.removeChild(pop); }
        }

        function showStartedDialog(host, bookid, start, end, count, running) {
            var app = window.app;
            var ctx = app && app.context;
            if (!ctx || typeof ctx.showPopup !== 'function') { return; }
            var detail = running
                ? '这本书已经在下载中，没有重复添加。'
                : '第 ' + start + ' - ' + end + ' 章，共 ' + count + ' 章';
            var template = {
                title: running ? '已在下载' : '已开始下载',
                body: '<center>' + host + ' / ' + bookid + '<br>' + detail + '</center>',
                button: '<button action=stvclose>关闭</button>'
                    + '<button action=stvqueue>查看下载</button>',
                action: {
                    stvclose: function (pop) { dismissPopup(pop); },
                    stvqueue: function (pop) {
                        dismissPopup(pop);
                        openDownloadList();
                    }
                }
            };
            try {
                ctx.showPopup(template);
                note('DOWNLOAD', 'started dialog shown: ' + detail);
            } catch (error) {
                note('ERR', 'started dialog failed: ' + error);
            }
        }

        function childrenWithTag(node, tag) {
            var out = [];
            var kids = (node && node.children) || [];
            for (var i = 0; i < kids.length; i++) {
                if (String(kids[i].tagName).toLowerCase() === tag) { out.push(kids[i]); }
            }
            return out;
        }

        // The items live in the <tabbar> inside the <tab>, not directly under it
        // (_page_vip.html:140-146), so the bar is looked up first.
        function tabItemsOf(tab) {
            var direct = childrenWithTag(tab, 'tabitem');
            if (direct.length) { return direct; }
            var bars = childrenWithTag(tab, 'tabbar');
            var out = [];
            for (var i = 0; i < bars.length; i++) {
                out = out.concat(childrenWithTag(bars[i], 'tabitem'));
            }
            return out;
        }

        // The tab framework lives in /stv.ui.js, which is not part of this repo,
        // so the tab is driven the way a finger drives it -- a click on the
        // tabitem -- and the result is verified afterwards.
        function clickTabitem(item) {
            if (!item || typeof item.dispatchEvent !== 'function') { return false; }
            var event = null;
            try {
                event = new MouseEvent('click', { bubbles: true, cancelable: true });
            } catch (e) {
                event = null;
            }
            if (!event) {
                try {
                    event = document.createEvent('MouseEvents');
                    event.initMouseEvent('click', true, true, window, 0, 0, 0, 0,
                        false, false, false, false, 0, null);
                } catch (e2) {
                    return false;
                }
            }
            item.dispatchEvent(event);
            return true;
        }

        function currentTabIndex(tab) {
            if (tab && typeof tab.current === 'function') {
                try { return tab.current(); } catch (e) { return null; }
            }
            return null;
        }

        // The setter's name is unknown, so it is probed rather than assumed, and
        // whichever path worked is written to the log -- the next device log
        // settles the API question.
        var TAB_SETTERS = ['select', 'go', 'switchTo', 'setIndex', 'activate', 'to'];

        function forceTab(tab, index) {
            if (!tab) { return ''; }
            for (var i = 0; i < TAB_SETTERS.length; i++) {
                var name = TAB_SETTERS[i];
                if (typeof tab[name] !== 'function') { continue; }
                try {
                    tab[name](index);
                    return name;
                } catch (e) {}
            }
            return '';
        }

        // 书架 is the home tab, i.e. the first tabview of #mainview
        // (_page_vip.html:135-166), and the download list is its fifth sub-tab
        // (history / follow / bookmark / novel_owner / download, the list itself
        // is <tabview id="downloadedlist"> at :162).
        function selectDownloadTab() {
            var tusach = document.getElementById('tabtusach');
            var items = tabItemsOf(tusach);
            var wanted = items.length - 1;
            var navItems = childrenWithTag(document.getElementById('mainnavbar'), 'tabitem');
            if (navItems.length) { clickTabitem(navItems[0]); }
            if (!items.length) {
                note('ERR', 'download list: 书架 has no tab to select');
                return;
            }
            clickTabitem(items[wanted]);
            setTimeout(function () {
                var index = currentTabIndex(tusach);
                if (index === wanted) {
                    note('DOWNLOAD', 'download tab selected by click');
                    return;
                }
                var via = forceTab(tusach, wanted);
                note('DOWNLOAD', via
                    ? 'download tab selected via ' + via + '()'
                    : 'could not confirm the download tab (current=' + index
                        + ', wanted=' + wanted + ')');
            }, 300);
        }

        function openDownloadList() {
            var app = window.app;
            if (!app || typeof app.popPage !== 'function') { return; }
            var popped = 0;
            try {
                var overlay = document.getElementById('overlay');
                while (overlay && overlay.children && overlay.children.length > 0
                    && popped < 20) {
                    app.popPage();
                    popped++;
                }
            } catch (error) {
                note('ERR', 'closing pages before the download list failed: ' + error);
            }
            note('DOWNLOAD', 'download list: closed ' + popped + ' page(s)');
            // popPage animates for 250ms and calls mainview.ontabchange() when the
            // stack empties; switching the tab before that lands would be undone.
            setTimeout(selectDownloadTab, 300);
        }

        // The download dialog asks for a chapter COUNT and hard-codes 20 of them.
        // `showDownloadBook` (page-vip:4939-4953) fetches the book's
        // `chaptercount` into `ccount`, never uses it, and sets `total = 20`; the
        // action then runs `clist.slice(start-1, start-1+count)`
        // (app.v2.js:2768-2783). Typing 4 and 20 therefore downloads chapters
        // 4..23, which is exactly the "实际下载的范围会超过这个选定的章节范围"
        // report. Turn the second field into an end chapter, default the pair to
        // the whole book, and slice on the end chapter.
        function patchDownloadRange() {
            var app = window.app;
            var menu = app && app.context && app.context.menu
                && app.context.menu.downloadchapter;
            if (!menu || !menu.action || typeof menu.action.startdownload !== 'function') {
                return false;
            }
            if (menu.__stvRangePatched) { return true; }
            menu.__stvRangePatched = true;
            // Same classes for bookid/bookhost (the popup binds template.data keys
            // to `.<key>` inputs, app.v2.js:2244-2251); the count field becomes an
            // end chapter, and a source picker is added because the same novel is
            // usually mirrored on several hosts (the chapter-list page already
            // offers them, app.v2.js:4429-4472).
            menu.body = 'Nhập khoảng chương để tải:<br>'
                + '<input class="bookid" type="hidden"/>'
                + '<input class="bookhost" type="hidden"/>'
                + '<input class="numstart" type="text" placeholder="Bắt đầu từ" />'
                + '<input class="numend" type="text" placeholder="Đến chương" />'
                + '<div class="dlsourcelabel">Nguồn truyện</div>'
                + '<select class="dlsource"></select>';
            // app.context.popup() focuses `template.focus` unguarded
            // (app.v2.js:2252-2257). The site's value names the old count field,
            // which no longer exists after the rename above, so the device log
            // gets `TypeError: null is not an object (... .focus)`. Point it at
            // the field that does exist.
            menu.focus = 'numend';
            var originalStart = menu.action.startdownload;
            menu.action.startdownload = async function (p) {
                var host = p.q('.bookhost').value;
                var bookid = p.q('.bookid').value;
                // The picker holds "host|id" and defaults to the host the detail
                // page opened, so an untouched dialog behaves as before.
                var select = p.q('.dlsource');
                if (select && select.value && select.value.indexOf('|') > 0) {
                    var chosen = select.value.split('|');
                    host = chosen[0];
                    bookid = chosen[1];
                }
                var start = parseInt(p.q('.numstart').value, 10);
                var end = parseInt(p.q('.numend').value, 10);
                if (!(start > 0)) { start = 1; }
                this.cancel(p);
                // A second confirm while the first job is still running would
                // push a second row for the same book, and the site's own
                // filterDownloadingChapters() (:3445) would hand that job an
                // empty chapter list -- a row stuck at 0/N that never finishes
                // and never leaves the DOWNLOADING list. The first job already
                // covers the book, so the second start is a no-op.
                var running = liveJob(host, bookid);
                if (running) {
                    note('DOWNLOAD', 'a download for ' + host + '/' + bookid
                        + ' is already running; ignoring the second start');
                    showStartedDialog(host, bookid, 0, 0, running.total, true);
                    return;
                }
                try {
                    var book = await app.offlineBook.getNewBook({ id: bookid, host: host });
                    var clist = await getChapterList(host, bookid);
                    if (!(end > 0) || end > clist.length) { end = clist.length; }
                    if (end < start) { end = start; }
                    var lists = clist.slice(start - 1, end)
                        .map(function (e) { return e.cid; });
                    note('DOWNLOAD', 'range ' + start + '-' + end + ' of ' + clist.length
                        + ' -> ' + lists.length + ' chapter(s)');
                    var job = new app.BookDownloadManager(host, bookid, lists, book);
                    job.start();
                    showStartedDialog(host, bookid, start, end, lists.length, false);
                } catch (error) {
                    // getChapterList() is a top-level function in app.v2.js; if it
                    // ever stops being reachable, keep the site's own action.
                    note('ERR', 'range download failed, using the site action: ' + error);
                    return originalStart.call(this, p);
                }
            };
            if (!app.context.__stvRangePopup) {
                app.context.__stvRangePopup = true;
                var originalPopup = app.context.showPopup;
                app.context.showPopup = function (template, attach) {
                    var pop = originalPopup.apply(this, arguments);
                    try {
                        // Only the download-range dialog carries .numend. The popup
                        // element exposes the site's `q()` helper; fall back to
                        // querySelector so a missing helper cannot silently leave
                        // the old defaults in place.
                        var body = (template && template.body) || '';
                        if (body.indexOf('numend') >= 0 && pop) {
                            var pick = pop.q ? function (s) { return pop.q(s); }
                                : function (s) {
                                    return pop.querySelector ? pop.querySelector(s) : null;
                                };
                            var startInput = pick('.numstart');
                            var endInput = pick('.numend');
                            var latest = attach && attach.chaptercount;
                            // 1 .. latest, not "where I stopped reading + 20".
                            if (startInput) { startInput.value = '1'; }
                            if (endInput && latest) { endInput.value = String(latest); }
                            note('DOWNLOAD', 'range dialog defaulted to 1-'
                                + (latest ? latest : '?'));
                            var sourceSelect = pick('.dlsource');
                            fillSources(sourceSelect, attach);
                            if (sourceSelect && sourceSelect.addEventListener) {
                                sourceSelect.addEventListener('change', function () {
                                    var sources = sourceSelect.__stvSources || [];
                                    var picked = null;
                                    for (var i = 0; i < sources.length; i++) {
                                        if (sources[i].host + '|' + sources[i].id
                                            === sourceSelect.value) { picked = sources[i]; }
                                    }
                                    if (!picked) { return; }
                                    // The range is per source: the mirror can have
                                    // fewer chapters than the one first shown.
                                    if (endInput) {
                                        endInput.value = String(picked.chaptercount || '');
                                    }
                                    note('DOWNLOAD', 'source -> ' + picked.host + '/'
                                        + picked.id + ' (' + picked.chaptercount
                                        + ' chapters)');
                                });
                            }
                        }
                    } catch (e) {}
                    return pop;
                };
            }
            return true;
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
            var readers = patchReaders();
            var range = patchDownloadRange();
            var rows = patchDownloadedRow();
            if ((readers && range && rows) || patchAttempts > 600) {
                clearInterval(patchTimer);
            }
        }, 200);

        // Books downloaded after boot enter store.data later, so keep sweeping.
        // Cheap: warmOne() answers immediately for anything already warmed, and
        // the store holds a handful of entries.
        setInterval(warmStore, 3000);
    })();
    """

    // MARK: - Comment and community-post translation

    /**
     Translation for everything the app renders as text the reader did not write:
     book comments (_page_vip.html:914), and the 社区 boards -- the channel/post
     list (pageposts, :1087, reached from Kênh truyện / Kênh linh tinh / 势力 /
     a user's posts), a single post with its comments (:1105), a user home's
     comments (:4843) and the broadcast/fromuser comment boards. The Cbox board
     is a cross-origin iframe (:982) and cannot be reached from this page.

       * a 译全部 button in the page's title bar translates every comment and
         post body the page has loaded -- with no popup: the button carries the
         progress, and if the list has not arrived yet the request is armed and
         runs the moment the first item lands;
       * every comment and every post gets its own 译 that toggles back to the
         original;
       * the comment input (both the page's contenteditable and a post's
         textarea) gets a 译成X button that rewrites what the reader typed into
         the language the site's commenters actually read;
       * 设置 -> 翻译 opens a panel for the engine, the API key and the languages.

     Engines, in the order the UI offers them:

       apple  iOS 18+ Translation framework: native, offline, no key. Probed
              through the always-present App.translationStatus selector, so an
              iOS 15-17 device falls through to the next engine by itself.
       free   Microsoft's keyless Edge endpoint
              (edge.microsoft.com/translate/translatetext) -- the same channel
              newsnook-ios uses. No key, IP rate limited.
       azure / google / deepl / openai
              the reader's own key, sent through the native Http plugin: a
              page-level fetch to those hosts would be blocked by CORS.

     Settings live in the site's own storage (app.storage) under
     stv.translate.settings, which is also in settingsBackup's KEYS, so they
     survive a reinstall exactly like the reader settings do.

     Read vs write target are deliberately separate settings. Comments are
     Vietnamese and the reader wants Chinese; the reader types Chinese and the
     commenters want Vietnamese. One target cannot serve both directions.
     */
    static let commentTranslate = """
    (function () {
        if (window.__stvCommentTranslateInstalled) { return; }
        window.__stvCommentTranslateInstalled = true;

        var STORE_KEY = 'stv.translate.settings';
        var PANEL_ID = 'stv-translate-panel';
        var NL = String.fromCharCode(10);

        var ENGINE_LABELS = [
            ['apple', 'iOS 系统离线（推荐，免密钥）'],
            ['free', '免密钥联网（微软 Edge 通道）'],
            ['azure', 'Azure Translator（自备 Key）'],
            ['google', 'Google Cloud Translation（自备 Key）'],
            ['deepl', 'DeepL（自备 Key）'],
            ['openai', 'OpenAI 兼容接口（自备 Key）']
        ];

        // The reader picks the pair freely -- the two defaults below are only
        // starting points. Codes are the ones Apple's Translation framework and
        // the HTTP engines both accept (DeepL is mapped separately, see
        // deeplLanguage()).
        var LANGUAGES = [
            ['zh-Hans', '简体中文'], ['zh-Hant', '繁体中文'], ['vi', '越南语'],
            ['en', '英语'], ['ja', '日语'], ['ko', '韩语'], ['th', '泰语'],
            ['id', '印尼语'], ['ms', '马来语'], ['tl', '菲律宾语'],
            ['my', '缅甸语'], ['km', '高棉语'], ['lo', '老挝语'],
            ['hi', '印地语'], ['bn', '孟加拉语'], ['ta', '泰米尔语'],
            ['ur', '乌尔都语'], ['fa', '波斯语'], ['ar', '阿拉伯语'],
            ['he', '希伯来语'], ['tr', '土耳其语'], ['ru', '俄语'],
            ['uk', '乌克兰语'], ['pl', '波兰语'], ['cs', '捷克语'],
            ['sk', '斯洛伐克语'], ['hu', '匈牙利语'], ['ro', '罗马尼亚语'],
            ['bg', '保加利亚语'], ['el', '希腊语'], ['de', '德语'],
            ['fr', '法语'], ['es', '西班牙语'], ['pt', '葡萄牙语'],
            ['it', '意大利语'], ['nl', '荷兰语'], ['sv', '瑞典语'],
            ['no', '挪威语'], ['da', '丹麦语'], ['fi', '芬兰语'],
            ['et', '爱沙尼亚语'], ['lv', '拉脱维亚语'], ['lt', '立陶宛语'],
            ['sl', '斯洛文尼亚语'], ['hr', '克罗地亚语'], ['sr', '塞尔维亚语'],
            ['ca', '加泰罗尼亚语'], ['af', '南非荷兰语'], ['sw', '斯瓦希里语']
        ];

        var SOURCE_LANGUAGES = [['auto', '自动识别']].concat(LANGUAGES);

        var EDGE_URL = 'https://edge.microsoft.com/translate/translatetext';
        // Edge's own translation endpoint answers on an Edge UA; this mirrors
        // what newsnook-ios sends.
        var EDGE_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            + ' (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36 Edg/153.0.0.0';

        var BUTTON_CSS = 'padding:5px 10px;margin-left:6px;border-radius:7px;'
            + 'border:1px solid rgba(128,128,128,0.45);background:rgba(128,128,128,0.18);'
            + 'color:inherit;font:13px/1.2 inherit;cursor:pointer;';

        var FIELD_CSS = 'width:100%;box-sizing:border-box;padding:7px 9px;'
            + 'border-radius:8px;border:1px solid #555;background:#2a2a2a;'
            + 'color:#eee;font-size:13px;';

        // Some engines cap a single request; a translate-all of fifty comments
        // is one string well past that.
        var MAX_CHARS = 3000;

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        function messageOf(error) {
            if (error && error.message) { return String(error.message); }
            return String(error);
        }

        function stop(event) {
            if (!event) { return; }
            if (typeof event.preventDefault === 'function') { event.preventDefault(); }
            if (typeof event.stopPropagation === 'function') { event.stopPropagation(); }
            if (typeof event.stopImmediatePropagation === 'function') {
                event.stopImmediatePropagation();
            }
        }

        // The site puts q()/qq() on Element.prototype from /stv.ui.js; fall back
        // to the standard pair so this block also works before that loads and
        // under the stub DOM the test suite drives it with.
        function q(node, selector) {
            if (!node) { return null; }
            if (typeof node.q === 'function') { return node.q(selector); }
            if (typeof node.querySelector === 'function') { return node.querySelector(selector); }
            return null;
        }

        function qq(node, selector) {
            if (!node) { return []; }
            if (typeof node.qq === 'function') { return node.qq(selector); }
            if (typeof node.querySelectorAll === 'function') {
                var list = node.querySelectorAll(selector);
                return list ? Array.prototype.slice.call(list) : [];
            }
            return [];
        }

        function textOf(node) {
            if (!node) { return ''; }
            var tag = String(node.tagName || '').toUpperCase();
            // A post's comment box is a plain <textarea> (_dl_app.v2.js:3603
            // reads `.value`), which carries neither innerText nor textContent.
            if ((tag === 'TEXTAREA' || tag === 'INPUT')
                && typeof node.value === 'string' && node.value) {
                return node.value;
            }
            var text = node.innerText;
            if (typeof text !== 'string' || !text) { text = node.textContent; }
            return typeof text === 'string' ? text : '';
        }

        function escapeHtml(text) {
            return String(text)
                .split('&').join('&amp;')
                .split('<').join('&lt;')
                .split('>').join('&gt;');
        }

        function languageName(code) {
            for (var i = 0; i < LANGUAGES.length; i++) {
                if (LANGUAGES[i][0] === code) { return LANGUAGES[i][1]; }
            }
            return String(code);
        }

        function engineName(code) {
            for (var i = 0; i < ENGINE_LABELS.length; i++) {
                if (ENGINE_LABELS[i][0] === code) { return ENGINE_LABELS[i][1]; }
            }
            return String(code);
        }

        // ---- settings ----------------------------------------------------

        var settings = null;

        function defaults() {
            var app = window.app;
            var ui = (app && app.language) || 'vi';
            var readTarget = 'vi';
            if (ui === 'zh') { readTarget = 'zh-Hans'; }
            if (ui === 'en') { readTarget = 'en'; }
            return {
                engine: 'apple',
                apiKey: '',
                region: '',
                endpoint: '',
                model: '',
                readSource: 'vi',
                readTarget: readTarget,
                writeTarget: 'vi',
                auto: false
            };
        }

        function mergeSettings(base, raw) {
            if (typeof raw !== 'string' || !raw) { return base; }
            var parsed = null;
            try { parsed = JSON.parse(raw); } catch (e) { parsed = null; }
            if (!parsed || typeof parsed !== 'object') { return base; }
            for (var key in base) {
                if (Object.prototype.hasOwnProperty.call(parsed, key)
                    && typeof parsed[key] === typeof base[key]) {
                    base[key] = parsed[key];
                }
            }
            return base;
        }

        function loadSettings() {
            if (settings) { return Promise.resolve(settings); }
            var base = defaults();
            var app = window.app;
            var storage = app && app.storage;
            if (!storage || typeof storage.get !== 'function') {
                settings = base;
                return Promise.resolve(settings);
            }
            return Promise.resolve(storage.get(STORE_KEY)).then(function (raw) {
                settings = mergeSettings(base, raw);
                return settings;
            }, function (error) {
                note('ERR', 'translate settings read failed: ' + messageOf(error));
                settings = base;
                return settings;
            });
        }

        function saveSettings(next) {
            settings = next;
            var app = window.app;
            var storage = app && app.storage;
            if (!storage || typeof storage.set !== 'function') {
                return Promise.resolve();
            }
            return Promise.resolve(storage.set(STORE_KEY, JSON.stringify(next)))
                .then(function () {
                    note('TRANSLATE', 'settings saved (engine=' + next.engine + ')');
                }, function (error) {
                    note('ERR', 'translate settings save failed: ' + messageOf(error));
                });
        }

        // ---- engines -----------------------------------------------------

        function appPlugin() {
            return (window.Capacitor && window.Capacitor.Plugins
                && window.Capacitor.Plugins.App) || null;
        }

        function httpPlugin() {
            return (window.Capacitor && window.Capacitor.Plugins
                && window.Capacitor.Plugins.Http) || null;
        }

        function httpRequest(method, url, headers, data) {
            var plugin = httpPlugin();
            if (!plugin || typeof plugin.request !== 'function') {
                return Promise.reject(new Error('原生 Http 插件不可用'));
            }
            var options = { url: url, method: method, headers: headers || {} };
            if (data !== undefined && data !== null) { options.data = data; }
            return plugin.request(options);
        }

        function bodyOf(response) {
            if (!response) { throw new Error('翻译接口没有响应'); }
            if (response.status < 200 || response.status >= 300) {
                if (response.status === 429) {
                    throw new Error('接口限流（429），请稍后再试或换用自备 Key');
                }
                throw new Error('接口返回 HTTP ' + response.status);
            }
            var data = response.data;
            if (typeof data === 'string') {
                var text = data.trim();
                if (text && (text.charAt(0) === '{' || text.charAt(0) === '[')) {
                    try { return JSON.parse(text); } catch (e) { return text; }
                }
                return text;
            }
            return data;
        }

        function trimSlashes(url) {
            var out = String(url);
            while (out.length && out.charAt(out.length - 1) === '/') {
                out = out.substring(0, out.length - 1);
            }
            return out;
        }

        function pick(list, index, texts, key) {
            var item = list[index];
            var piece = item && item[key];
            if (typeof piece === 'string' && piece) { return piece; }
            return texts[index];
        }

        function appleBatch(texts, source, target) {
            var plugin = appPlugin();
            if (!plugin || typeof plugin.translationTranslate !== 'function') {
                return Promise.reject(new Error('原生翻译桥不可用'));
            }
            var payload = { texts: texts, target: target };
            if (source && source !== 'auto') { payload.source = source; }
            return Promise.resolve(plugin.translationTranslate(payload)).then(function (result) {
                var out = result && result.translations;
                if (!out || out.length !== texts.length) {
                    throw new Error('系统翻译返回条数不符');
                }
                return out;
            });
        }

        function freeBatch(texts, source, target) {
            var url = EDGE_URL + '?to=' + encodeURIComponent(target)
                + '&isEnterpriseClient=false';
            if (source && source !== 'auto') {
                url += '&from=' + encodeURIComponent(source);
            }
            return httpRequest('POST', url, {
                'Content-Type': 'application/json; charset=UTF-8',
                'User-Agent': EDGE_UA
            }, JSON.stringify(texts)).then(function (response) {
                var data = bodyOf(response);
                if (!data || !data.length) { throw new Error('微软通道没有返回译文'); }
                var out = [];
                for (var i = 0; i < texts.length; i++) {
                    var item = data[i];
                    var piece = item && item.translations && item.translations[0]
                        && item.translations[0].text;
                    out.push(typeof piece === 'string' && piece ? piece : texts[i]);
                }
                return out;
            });
        }

        function azureBatch(texts, source, target, config) {
            var url = 'https://api.cognitive.microsofttranslator.com/translate'
                + '?api-version=3.0&to=' + encodeURIComponent(target);
            if (source && source !== 'auto') {
                url += '&from=' + encodeURIComponent(source);
            }
            var headers = {
                'Content-Type': 'application/json; charset=UTF-8',
                'Ocp-Apim-Subscription-Key': config.apiKey
            };
            if (config.region) { headers['Ocp-Apim-Subscription-Region'] = config.region; }
            var payload = [];
            for (var i = 0; i < texts.length; i++) { payload.push({ Text: texts[i] }); }
            return httpRequest('POST', url, headers, JSON.stringify(payload))
                .then(function (response) {
                    var data = bodyOf(response);
                    if (!data || !data.length) { throw new Error('Azure 没有返回译文'); }
                    var out = [];
                    for (var j = 0; j < texts.length; j++) {
                        var item = data[j];
                        var piece = item && item.translations && item.translations[0]
                            && item.translations[0].text;
                        out.push(typeof piece === 'string' && piece ? piece : texts[j]);
                    }
                    return out;
                });
        }

        function googleBatch(texts, source, target, config) {
            var url = 'https://translation.googleapis.com/language/translate/v2?key='
                + encodeURIComponent(config.apiKey);
            var payload = { q: texts, target: target, format: 'text' };
            if (source && source !== 'auto') { payload.source = source; }
            return httpRequest('POST', url,
                { 'Content-Type': 'application/json; charset=UTF-8' },
                JSON.stringify(payload)).then(function (response) {
                    var data = bodyOf(response);
                    var list = data && data.data && data.data.translations;
                    if (!list || !list.length) { throw new Error('Google 没有返回译文'); }
                    var out = [];
                    for (var i = 0; i < texts.length; i++) {
                        var piece = list[i] && list[i].translatedText;
                        out.push(typeof piece === 'string' && piece ? piece : texts[i]);
                    }
                    return out;
                });
        }

        // DeepL wants ZH / ZH-HANT / EN-US / PT-BR rather than the BCP-47 the
        // rest of the pipeline speaks.
        function deeplLanguage(code) {
            var lower = String(code).toLowerCase();
            if (lower.indexOf('zh-hant') === 0) { return 'ZH-HANT'; }
            if (lower.indexOf('zh') === 0) { return 'ZH'; }
            if (lower.indexOf('en') === 0) { return 'EN-US'; }
            if (lower.indexOf('pt') === 0) { return 'PT-BR'; }
            return String(code).toUpperCase();
        }

        function deeplBatch(texts, source, target, config) {
            var url = trimSlashes(config.endpoint || 'https://api-free.deepl.com')
                + '/v2/translate';
            var parts = [];
            for (var i = 0; i < texts.length; i++) {
                parts.push('text=' + encodeURIComponent(texts[i]));
            }
            parts.push('target_lang=' + encodeURIComponent(deeplLanguage(target)));
            if (source && source !== 'auto') {
                parts.push('source_lang=' + encodeURIComponent(deeplLanguage(source)));
            }
            return httpRequest('POST', url, {
                'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
                'Authorization': 'DeepL-Auth-Key ' + config.apiKey
            }, parts.join('&')).then(function (response) {
                var data = bodyOf(response);
                var list = data && data.translations;
                if (!list || !list.length) { throw new Error('DeepL 没有返回译文'); }
                var out = [];
                for (var j = 0; j < texts.length; j++) {
                    var piece = list[j] && list[j].text;
                    out.push(typeof piece === 'string' && piece ? piece : texts[j]);
                }
                return out;
            });
        }

        function parseJsonArray(text) {
            var trimmed = String(text).trim();
            var start = trimmed.indexOf('[');
            var end = trimmed.lastIndexOf(']');
            if (start < 0 || end <= start) { return null; }
            try {
                var parsed = JSON.parse(trimmed.substring(start, end + 1));
                return parsed && parsed.length ? parsed : null;
            } catch (e) {
                return null;
            }
        }

        function openaiBatch(texts, source, target, config) {
            var url = trimSlashes(config.endpoint || 'https://api.openai.com/v1')
                + '/chat/completions';
            var system = 'You are a translation engine. Translate every item of the'
                + ' JSON array the user sends into ' + target
                + '. Keep the array length and order. Reply with the JSON array only,'
                + ' no prose, no code fences.';
            var payload = {
                model: config.model || 'gpt-4o-mini',
                temperature: 0,
                messages: [
                    { role: 'system', content: system },
                    { role: 'user', content: JSON.stringify(texts) }
                ]
            };
            return httpRequest('POST', url, {
                'Content-Type': 'application/json; charset=UTF-8',
                'Authorization': 'Bearer ' + config.apiKey
            }, JSON.stringify(payload)).then(function (response) {
                var data = bodyOf(response);
                var text = data && data.choices && data.choices[0]
                    && data.choices[0].message && data.choices[0].message.content;
                if (typeof text !== 'string') {
                    throw new Error('OpenAI 兼容接口没有返回内容');
                }
                var parsed = parseJsonArray(text);
                if (!parsed) { throw new Error('OpenAI 兼容接口没有返回 JSON 数组'); }
                var out = [];
                for (var i = 0; i < texts.length; i++) {
                    out.push(typeof parsed[i] === 'string' && parsed[i]
                        ? parsed[i] : texts[i]);
                }
                return out;
            });
        }

        function engineBatch(texts, source, target, config) {
            var engine = config.engine || 'apple';
            if (engine === 'free') { return freeBatch(texts, source, target); }
            if (engine === 'azure') { return azureBatch(texts, source, target, config); }
            if (engine === 'google') { return googleBatch(texts, source, target, config); }
            if (engine === 'deepl') { return deeplBatch(texts, source, target, config); }
            if (engine === 'openai') { return openaiBatch(texts, source, target, config); }
            return appleBatch(texts, source, target);
        }

        // null until probed; true only when the native framework answered
        // something other than "unsupported".
        var appleReady = null;

        function probeApple(target) {
            if (appleReady !== null) { return Promise.resolve(appleReady); }
            var plugin = appPlugin();
            if (!plugin || typeof plugin.translationStatus !== 'function') {
                appleReady = false;
                return Promise.resolve(false);
            }
            return Promise.resolve(plugin.translationStatus({ target: target }))
                .then(function (result) {
                    appleReady = !!(result && result.status !== 'unsupported');
                    note('TRANSLATE', 'system translation: '
                        + ((result && result.status) || 'unknown'));
                    return appleReady;
                }, function (error) {
                    note('TRANSLATE', 'system translation probe failed: ' + messageOf(error));
                    appleReady = false;
                    return false;
                });
        }

        function chunkTexts(texts) {
            var chunks = [];
            var current = [];
            var size = 0;
            for (var i = 0; i < texts.length; i++) {
                var length = String(texts[i]).length;
                if (current.length && size + length > MAX_CHARS) {
                    chunks.push(current);
                    current = [];
                    size = 0;
                }
                current.push(texts[i]);
                size += length;
            }
            if (current.length) { chunks.push(current); }
            return chunks;
        }

        function runChunks(texts, source, target, config) {
            var chunks = chunkTexts(texts);
            var out = [];
            var failed = 0;
            var lastError = null;
            var chain = Promise.resolve();
            chunks.forEach(function (chunk) {
                chain = chain.then(function () {
                    return engineBatch(chunk, source, target, config).then(function (part) {
                        for (var i = 0; i < part.length; i++) { out.push(part[i]); }
                    }, function (error) {
                        // One bad chunk must not throw away the rest of a long
                        // list; the untouched entries keep their original text.
                        failed++;
                        lastError = error;
                        note('ERR', 'translate chunk failed: ' + messageOf(error));
                        for (var j = 0; j < chunk.length; j++) { out.push(chunk[j]); }
                    });
                });
            });
            return chain.then(function () {
                if (failed && failed === chunks.length) { throw lastError; }
                if (failed) {
                    note('TRANSLATE', failed + ' of ' + chunks.length
                        + ' chunk(s) kept the original text');
                }
                return out;
            });
        }

        function runTranslate(texts, source, target, config) {
            if ((config.engine || 'apple') !== 'apple') {
                return runChunks(texts, source, target, config);
            }
            return probeApple(target).then(function (ready) {
                if (ready) { return runChunks(texts, source, target, config); }
                var fallback = {};
                for (var key in config) { fallback[key] = config[key]; }
                fallback.engine = 'free';
                note('TRANSLATE', 'no system offline translation here;'
                    + ' using the keyless Microsoft channel');
                return runChunks(texts, source, target, fallback);
            });
        }

        // ---- UI ----------------------------------------------------------

        function makeButton(label, className) {
            var button = document.createElement('button');
            button.className = 'stv-translate-btn ' + className;
            button.textContent = label;
            button.style.cssText = BUTTON_CSS;
            return button;
        }

        // app.toast() is `app.context.info(msg, true)` (app.v2.js:614) -- a modal
        // info popup, not a transient strip. Every report from this feature used
        // to go through it, so "译全部" opened a window instead of just
        // translating. Reports now go to the button label, the panel's status
        // line, the diagnostic log, and this non-interactive strip.
        function hint(message) {
            note('TRANSLATE', message);
            var host = document.body || document.documentElement;
            if (!host) { return; }
            var node = document.createElement('div');
            node.className = 'stv-translate-hint';
            node.setAttribute('data-stvtranslate', 'hint');
            node.style.cssText = 'position:fixed;left:50%;bottom:26px;'
                + 'transform:translateX(-50%);z-index:2147483645;max-width:86vw;'
                + 'padding:7px 12px;border-radius:9px;background:rgba(0,0,0,0.82);'
                + 'color:#fff;font:12px/1.4 -apple-system,BlinkMacSystemFont,sans-serif;'
                + 'pointer-events:none;text-align:center;';
            node.textContent = message;
            host.appendChild(node);
            setTimeout(function () {
                if (node.parentNode) { node.parentNode.removeChild(node); }
            }, 2600);
        }

        function fail(error) {
            var text = messageOf(error);
            note('ERR', 'translate failed: ' + text);
            hint('翻译失败：' + text);
        }

        function decorateComment(block) {
            if (!block || !block.getAttribute) { return; }
            if (block.getAttribute('stv-tr')) { return; }
            var content = q(block, '.cmtcontent');
            if (!content) { return; }
            block.setAttribute('stv-tr', '1');
            var row = document.createElement('div');
            row.className = 'stv-translate-row';
            row.style.cssText = 'margin-top:4px;';
            var button = makeButton('译', 'stv-translate-one');
            button.style.fontSize = '12px';
            button.style.padding = '2px 8px';
            button.style.marginLeft = '0';
            button.addEventListener('click', function (event) {
                stop(event);
                translateOne(button, content);
            }, true);
            row.appendChild(button);
            var body = q(block, '.cmtbody') || content.parentNode;
            if (!body) { return; }
            body.appendChild(row);
        }

        // A community board row is `view-post` (page-vip:2671) and its text is
        // `.postcontent > .content`; the single-post page (:1105) has the same
        // pair. One 译 per post, inserted right under the body.
        function decoratePost(body) {
            if (!body || !body.getAttribute) { return; }
            if (body.getAttribute('stv-tr')) { return; }
            var host = body.parentNode;
            if (!host) { return; }
            body.setAttribute('stv-tr', '1');
            var row = document.createElement('div');
            row.className = 'stv-translate-row';
            row.style.cssText = 'margin-top:4px;';
            var button = makeButton('译', 'stv-translate-one');
            button.style.fontSize = '12px';
            button.style.padding = '2px 8px';
            button.style.marginLeft = '0';
            button.addEventListener('click', function (event) {
                stop(event);
                translateOne(button, body);
            }, true);
            row.appendChild(button);
            host.appendChild(row);
        }

        function originalOf(node) {
            var stored = node.getAttribute('stv-orig');
            return (stored === null || stored === undefined) ? null : stored;
        }

        function restore(node, button) {
            var stored = originalOf(node);
            if (stored === null) { return false; }
            node.innerHTML = stored;
            if (node.removeAttribute) { node.removeAttribute('stv-orig'); }
            button.textContent = '译';
            return true;
        }

        function translateOne(button, content) {
            if (restore(content, button)) { return; }
            var text = textOf(content);
            if (!text) { return; }
            loadSettings().then(function (config) {
                button.textContent = '…';
                return runTranslate([text], config.readSource, config.readTarget, config)
                    .then(function (out) {
                        if (typeof out[0] !== 'string' || !out[0]) {
                            button.textContent = '译';
                            return;
                        }
                        content.setAttribute('stv-orig', content.innerHTML);
                        content.textContent = out[0];
                        button.textContent = '原文';
                        note('TRANSLATE', 'one comment translated with ' + config.engine);
                    }, function (error) {
                        button.textContent = '译';
                        fail(error);
                    });
            });
        }

        // Everything on a page that can be translated, whatever shape it has.
        // Written with single-class selectors on purpose: the site's own q()/qq()
        // (and the test stub that stands in for them) do not implement the
        // descendant or child combinators.
        //
        // A node that already carries `stv-orig` (translated, original kept) or
        // `stv-tr-done` (already sent to an engine, even if the answer matched)
        // is left alone. Without that, a second 译全部 -- or the auto setting
        // firing again on a late comment -- would translate the translation and
        // overwrite the stored original.
        function textTargets(scope) {
            var out = [];
            var blocks = qq(scope, '[view=commentblock]');
            for (var i = 0; i < blocks.length; i++) {
                var content = q(blocks[i], '.cmtcontent');
                if (!content || !content.getAttribute) { continue; }
                if (content.getAttribute('stv-orig') !== undefined
                    && content.getAttribute('stv-orig') !== null) { continue; }
                if (content.getAttribute('stv-tr-done')) { continue; }
                var comment = textOf(content);
                if (comment) { out.push({ node: content, kind: 'comment', text: comment }); }
            }
            var wraps = qq(scope, '.postcontent');
            for (var j = 0; j < wraps.length; j++) {
                var body = q(wraps[j], '.content');
                if (!body || !body.getAttribute) { continue; }
                if (body.getAttribute('stv-orig') !== undefined
                    && body.getAttribute('stv-orig') !== null) { continue; }
                if (body.getAttribute('stv-tr-done')) { continue; }
                var post = textOf(body);
                if (post) { out.push({ node: body, kind: 'post', text: post }); }
            }
            return out;
        }

        function applyTranslations(targets, out) {
            var done = 0;
            for (var i = 0; i < targets.length; i++) {
                var node = targets[i].node;
                // Recorded even when the answer is unusable, so a page that is
                // already in the target language is not re-sent on every sweep.
                node.setAttribute('stv-tr-done', '1');
                var piece = out[i];
                if (typeof piece !== 'string' || !piece || piece === targets[i].text) {
                    continue;
                }
                node.setAttribute('stv-orig', node.innerHTML);
                node.textContent = piece;
                done++;
            }
            return done;
        }

        // The reader pressed 译全部. No popup: the button itself carries the
        // progress, and a list that has not arrived yet arms a one-shot instead
        // of answering "还没有可翻译的评论".
        function translateAll(page, button) {
            var targets = textTargets(page);
            if (!targets.length) {
                if (qq(page, '[stv-orig]').length) {
                    // Nothing left to do: everything here is already translated.
                    if (button) { button.textContent = '译全部'; }
                    note('TRANSLATE', 'everything on this page is already translated');
                    return;
                }
                page.__stvPendingAll = true;
                if (button) { button.textContent = '等加载…'; }
                note('TRANSLATE', 'nothing loaded yet; translating when it arrives');
                return;
            }
            loadSettings().then(function (config) {
                var texts = [];
                for (var i = 0; i < targets.length; i++) { texts.push(targets[i].text); }
                if (button) { button.textContent = '翻译中…'; }
                return runTranslate(texts, config.readSource, config.readTarget, config)
                    .then(function (out) {
                        var done = applyTranslations(targets, out);
                        if (button) { button.textContent = '译全部'; }
                        note('TRANSLATE', 'translated ' + done + ' of ' + targets.length
                            + ' item(s) with ' + config.engine);
                    }, function (error) {
                        if (button) { button.textContent = '译全部'; }
                        fail(error);
                    });
            });
        }

        // The page a comment embed lives on. The site's own topPage() is the
        // authoritative answer while a page is open (app.comment.reset() uses
        // it, app.v2.js:3616); walking up is the fallback, and it stops at the
        // first ancestor that owns a title bar.
        function containsNode(ancestor, node) {
            var walk = node;
            while (walk) {
                if (walk === ancestor) { return true; }
                walk = walk.parentElement;
            }
            return false;
        }

        function pageOf(node) {
            var app = window.app;
            if (node && app && typeof app.topPage === 'function') {
                var top = null;
                try { top = app.topPage(); } catch (error) { top = null; }
                if (top && top.nodeType === 1 && containsNode(top, node)) { return top; }
            }
            var page = node;
            while (page && page.nodeType === 1) {
                if (q(page, '.titlebar')) { return page; }
                page = page.parentElement;
            }
            return null;
        }

        // Boards and comment hosts, i.e. everything under 社区 that is rendered
        // in this webview: the channel/post list (`.posts`, page-vip:1087), the
        // book comment page (`.commentview`, :914) and the embeds used by a
        // single post and by a user home (`.comments`/`.embedcomment`, :2892).
        // The Cbox board is a cross-origin iframe and cannot be reached from
        // here.
        function hasTranslatableContent(page) {
            return !!(q(page, '.commentview') || q(page, '.comments')
                || q(page, '.embedcomment') || q(page, '.posts'));
        }

        function setInputText(input, text) {
            var tag = String(input.tagName || '').toUpperCase();
            if (tag === 'TEXTAREA') {
                // The post embed reads `.value` off its textarea
                // (_dl_app.v2.js:3603).
                input.value = text;
                return;
            }
            // The site reads innerHTML off this contenteditable
            // (_page_vip.html:4586 hands it to replyContext.set()), so write
            // escaped text with <br> for the line breaks the editable would
            // otherwise have produced itself.
            var lines = String(text).split(NL);
            var html = '';
            for (var i = 0; i < lines.length; i++) {
                if (i > 0) { html += '<br>'; }
                html += escapeHtml(lines[i]);
            }
            input.innerHTML = html;
            input.value = text;
        }

        function translateInput(button, input) {
            var text = textOf(input);
            if (!text) {
                hint('请先输入内容');
                return;
            }
            loadSettings().then(function (config) {
                button.textContent = '翻译中…';
                return runTranslate([text], 'auto', config.writeTarget, config)
                    .then(function (out) {
                        if (typeof out[0] === 'string' && out[0]) {
                            setInputText(input, out[0]);
                            note('TRANSLATE', 'comment input translated into '
                                + config.writeTarget);
                            hint('已译成' + languageName(config.writeTarget)
                                + '，可以直接发送');
                        }
                        refreshLabels();
                    }, function (error) {
                        refreshLabels();
                        fail(error);
                    });
            });
        }

        function decorateInput(input) {
            if (!input || !input.getAttribute) { return; }
            if (input.getAttribute('stv-tr-input')) { return; }
            var host = input.parentNode;
            if (!host) { return; }
            input.setAttribute('stv-tr-input', '1');
            var bar = document.createElement('div');
            bar.className = 'stv-translate-inputbar';
            // page-comment: `.lock-bot` is a flex row (replyinfo | input | send),
            // so the button goes between the input and the paper plane rather
            // than onto a line of its own -- that row is already
            // absolute-positioned above the safe area and must not grow.
            // A post's embed poster (`.embed-poster`, page-vip:2906) is the same
            // shape with `.comment-input` + `.finish`.
            bar.style.cssText = 'display:flex;align-items:center;padding:0 2px;';
            var button = makeButton('译', 'stv-translate-input');
            button.style.fontSize = '12px';
            button.style.padding = '4px 8px';
            button.addEventListener('click', function (event) {
                stop(event);
                translateInput(button, input);
            }, true);
            bar.appendChild(button);
            var send = q(host, '.sendcmt') || q(host, '.finish');
            if (send && send.parentNode === host) { host.insertBefore(bar, send); }
            else { host.insertBefore(bar, null); }
            refreshLabels();
        }

        function decorateInputs(page) {
            var node = q(page, '.commentinput');
            if (node) { decorateInput(node); }
            var embed = q(page, '.comment-input');
            if (embed) { decorateInput(embed); }
        }

        function refreshLabels() {
            var config = settings || defaults();
            var label = '译成' + languageName(config.writeTarget);
            var nodes = document.querySelectorAll('.stv-translate-input');
            for (var i = 0; i < nodes.length; i++) { nodes[i].textContent = label; }
        }

        function decorateAll(page) {
            var blocks = qq(page, '[view=commentblock]');
            for (var i = 0; i < blocks.length; i++) { decorateComment(blocks[i]); }
            var wraps = qq(page, '.postcontent');
            for (var j = 0; j < wraps.length; j++) {
                var body = q(wraps[j], '.content');
                if (body) { decoratePost(body); }
            }
            decorateInputs(page);
        }

        // Comments and posts arrive twice: the initial loadEmbed()/fetch()
        // render, and later pushes over the comment channel or a "load more".
        // Only a mutation observer catches the second one -- and it is also what
        // makes 译全部 and the auto-translate setting wait for the list instead
        // of running against an empty page.
        function observePage(page) {
            if (!page || page.__stvSweep) { return page ? page.__stvSweep : null; }
            var sweep = function () {
                decorateAll(page);
                if (!page.__stvPendingAll && !page.__stvAutoOn) { return; }
                if (!textTargets(page).length) { return; }
                var manual = !!page.__stvPendingAll;
                page.__stvPendingAll = false;
                var button = manual ? q(page, '.stv-translate-all') : null;
                if (button) { button.textContent = '译全部'; }
                translateAll(page, button);
            };
            page.__stvSweep = sweep;
            sweep();
            if (typeof MutationObserver === 'function') {
                var observer = new MutationObserver(sweep);
                observer.observe(page, { childList: true, subtree: true });
                page.__stvTranslateObserver = observer;
                note('TRANSLATE', 'watching the page for late comments and posts');
            }
            return sweep;
        }

        function addTitleButtons(bar, page) {
            if (q(bar, '.stv-translate-all')) { return; }
            var host = q(bar, '.rctx') || bar;
            var group = document.createElement('div');
            group.style.cssText = 'display:flex;align-items:center;';
            var translate = makeButton('译全部', 'stv-translate-all');
            translate.addEventListener('click', function (event) {
                stop(event);
                translateAll(page, translate);
            }, true);
            var gear = makeButton('⚙', 'stv-translate-settings');
            gear.addEventListener('click', function (event) {
                stop(event);
                openPanel();
            }, true);
            group.appendChild(translate);
            group.appendChild(gear);
            host.insertBefore(group, host.firstChild);
        }

        // One entry point for every page that carries comments or posts: the
        // book comment page, the community channel boards, a single post, a user
        // home. pushPage covers the pages that exist when they open; the
        // loadEmbed hook covers the embeds the site appends afterwards.
        function installOnPage(page) {
            if (!page || page.nodeType !== 1) { return; }
            if (!hasTranslatableContent(page)) { return; }
            var bar = q(page, '.titlebar');
            if (bar) { addTitleButtons(bar, page); }
            observePage(page);
            decorateAll(page);
            loadSettings().then(function (config) {
                refreshLabels();
                if (!config.auto) { return; }
                // The list is filled asynchronously, so arm the sweep rather
                // than translating an empty page (the device log showed
                // "还没有可翻译的评论" from exactly that race). The flag stays on
                // for the life of the page, so comments pushed in later are
                // translated too -- textTargets() skips what is already done.
                page.__stvAutoOn = true;
                if (page.__stvSweep) { page.__stvSweep(); }
            });
        }

        // The logging switch is rendered here rather than from the diag block:
        // this block already owns the settings page, and the diag block has no
        // way to know when that page exists. The state is read back from
        // __stvDiag, so there is exactly one owner of the flag.
        function paintLogState(node) {
            var diag = window.__stvDiag;
            var on = !!(diag && typeof diag.enabled === 'function' && diag.enabled());
            node.textContent = on ? '已开启 · 点这里关闭' : '已关闭 · 点这里开启';
            node.style.cssText = 'font-size:12px;opacity:0.9;'
                + (on ? 'color:#7fdc7f;' : '');
        }

        function onSettingsPage(page) {
            if (!page || page.nodeType !== 1) { return; }
            if (q(page, '.stv-translate-entry')) { return; }
            var section = q(page, '.settingsection');
            var host = section && section.parentNode;
            if (!host) { return; }
            var header = document.createElement('div');
            header.className = 'settingsection mt-3';
            header.textContent = '翻译';
            var item = document.createElement('div');
            item.className = 'settingitem stv-translate-entry';
            item.innerHTML = '<div class="settingitemtitle">评论/帖子翻译与发帖语言</div>'
                + '<div class=""><i class="fas fa-chevron-right"></i></div>';
            item.addEventListener('click', function (event) {
                stop(event);
                openPanel();
            }, true);
            host.appendChild(header);
            host.appendChild(item);
            note('TRANSLATE', 'settings entry added');

            var logHeader = document.createElement('div');
            logHeader.className = 'settingsection mt-3';
            logHeader.textContent = '诊断';
            var logItem = document.createElement('div');
            logItem.className = 'settingitem stv-log-entry';
            var logTitle = document.createElement('div');
            logTitle.className = 'settingitemtitle';
            logTitle.textContent = '日志（悬浮日志窗口）';
            var logState = document.createElement('div');
            logState.className = 'stv-log-state';
            logItem.appendChild(logTitle);
            logItem.appendChild(logState);
            logItem.addEventListener('click', function (event) {
                stop(event);
                var diag = window.__stvDiag;
                if (!diag || typeof diag.setEnabled !== 'function') { return; }
                diag.setEnabled(!diag.enabled());
                paintLogState(logState);
            }, true);
            var logOpen = document.createElement('div');
            logOpen.className = 'settingitem stv-log-open';
            logOpen.innerHTML = '<div class="settingitemtitle">查看/复制日志</div>'
                + '<div class=""><i class="fas fa-chevron-right"></i></div>';
            logOpen.addEventListener('click', function (event) {
                stop(event);
                var diag = window.__stvDiag;
                if (!diag || typeof diag.show !== 'function') { return; }
                // Asking to look at the log implies wanting it: turn the switch
                // on first rather than opening nothing.
                if (typeof diag.enabled === 'function' && !diag.enabled()) {
                    diag.setEnabled(true);
                }
                diag.show();
                paintLogState(logState);
            }, true);
            host.appendChild(logHeader);
            host.appendChild(logItem);
            host.appendChild(logOpen);
            paintLogState(logState);
            note('DIAG', 'logging switch added to 设置');
        }

        // ---- settings panel ---------------------------------------------

        function openPanel() {
            var existing = document.getElementById(PANEL_ID);
            if (existing && existing.parentNode) {
                existing.parentNode.removeChild(existing);
            }
            loadSettings().then(buildPanel);
        }

        function buildPanel(config) {
            var host = document.body || document.documentElement;
            if (!host) { return; }

            var root = document.createElement('div');
            root.id = PANEL_ID;
            root.setAttribute('data-stvtranslate', 'panel');
            // Top-anchored on purpose: the panel has text fields, and a centred
            // card would put the focused field behind the keyboard. Every field
            // that matters (engine, API Key) is in the first two rows.
            //
            // user-select is re-enabled because the site turns it off on <body>
            // (app.v2.css:28); with it inherited, the text fields and the
            // picker's search box cannot be focused reliably.
            root.style.cssText = 'position:fixed;left:0;top:0;right:0;bottom:0;'
                + 'z-index:2147483644;background:rgba(0,0,0,0.55);display:flex;'
                + 'align-items:flex-start;justify-content:center;padding:12px;'
                + 'padding-top:5vh;overflow:auto;'
                + '-webkit-user-select:text;user-select:text;';

            var card = document.createElement('div');
            card.style.cssText = 'width:100%;max-width:430px;max-height:74vh;'
                + 'overflow:auto;background:#1e1e1e;color:#eee;border-radius:12px;'
                + 'padding:14px;font:13px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;'
                + 'box-shadow:0 10px 34px rgba(0,0,0,0.55);';
            root.appendChild(card);

            var head = document.createElement('div');
            head.style.cssText = 'display:flex;align-items:center;margin-bottom:4px;';
            var title = document.createElement('div');
            title.style.cssText = 'flex:1;font-size:16px;font-weight:600;';
            title.textContent = '评论/帖子翻译';
            var close = makeButton('关闭', 'stv-translate-close');
            close.style.fontSize = '13px';
            close.addEventListener('click', function (event) {
                stop(event);
                if (root.parentNode) { root.parentNode.removeChild(root); }
            }, true);
            head.appendChild(title);
            head.appendChild(close);
            card.appendChild(head);

            function row(label, control) {
                var wrap = document.createElement('div');
                wrap.style.cssText = 'margin:9px 0;';
                var caption = document.createElement('div');
                caption.style.cssText = 'font-size:12px;opacity:0.75;margin-bottom:3px;';
                caption.textContent = label;
                wrap.appendChild(caption);
                wrap.appendChild(control);
                card.appendChild(wrap);
                return control;
            }

            function textInput(value, placeholder, className) {
                var el = document.createElement('input');
                el.type = 'text';
                el.value = value || '';
                el.placeholder = placeholder || '';
                el.className = 'stv-translate-field'
                    + (className ? ' ' + className : '');
                el.style.cssText = FIELD_CSS;
                return el;
            }

            // A native <select> is the wrong control in this webview: the site
            // sets `user-select: none` on <body> (app.v2.css:28), and a native
            // picker inside a fixed, scrollable overlay is not reliably
            // tappable. The device log is the evidence -- not one tap in the
            // panel ever reported `select` as its target, only the rows around
            // it, so the engine and the languages could not be changed at all.
            // This picker is made of ordinary elements, so it always works.
            function picker(pairs, value) {
                var wrap = document.createElement('div');
                var current = value || (pairs.length ? pairs[0][0] : '');
                var currentLabel = pairs.length ? pairs[0][1] : '';
                for (var i = 0; i < pairs.length; i++) {
                    if (pairs[i][0] === current) { currentLabel = pairs[i][1]; }
                }
                var button = makeButton('', 'stv-translate-picker');
                button.setAttribute('data-stvtranslate', 'picker');
                button.style.cssText = FIELD_CSS + 'display:flex;align-items:center;'
                    + 'justify-content:space-between;text-align:left;';
                var label = document.createElement('span');
                label.textContent = currentLabel;
                var caret = document.createElement('span');
                caret.textContent = '▾';
                caret.style.cssText = 'opacity:0.6;margin-left:8px;';
                button.appendChild(label);
                button.appendChild(caret);

                var list = document.createElement('div');
                list.className = 'stv-translate-pickerlist';
                list.style.cssText = 'display:none;max-height:40vh;overflow:auto;'
                    + 'border:1px solid #555;border-radius:8px;margin-top:5px;'
                    + 'background:#242424;';
                var search = document.createElement('input');
                search.type = 'text';
                search.className = 'stv-translate-pickersearch';
                search.placeholder = '搜索语言…';
                search.style.cssText = FIELD_CSS + 'margin:6px;width:calc(100% - 12px);';
                list.appendChild(search);

                var options = [];
                for (var j = 0; j < pairs.length; j++) {
                    var option = document.createElement('div');
                    option.className = 'stv-translate-option';
                    option.setAttribute('data-stvtranslate', 'option');
                    option.setAttribute('data-value', pairs[j][0]);
                    option.style.cssText = 'padding:9px 12px;font-size:13px;'
                        + 'border-bottom:1px solid rgba(128,128,128,0.18);';
                    option.textContent = pairs[j][1] + '（' + pairs[j][0] + '）';
                    option.__code = pairs[j][0];
                    option.__name = pairs[j][1];
                    (function (node) {
                        node.addEventListener('click', function (event) {
                            stop(event);
                            current = node.__code;
                            currentLabel = node.__name;
                            label.textContent = currentLabel;
                            list.style.display = 'none';
                            search.value = '';
                            filter('');
                        }, true);
                    })(option);
                    list.appendChild(option);
                    options.push(option);
                }

                function filter(needle) {
                    var q2 = String(needle || '').toLowerCase();
                    for (var k = 0; k < options.length; k++) {
                        var hay = (options[k].__name + ' ' + options[k].__code)
                            .toLowerCase();
                        options[k].style.display = (q2 && hay.indexOf(q2) < 0) ? 'none' : '';
                    }
                }
                search.addEventListener('input', function () { filter(search.value); });
                button.addEventListener('click', function (event) {
                    stop(event);
                    var open = list.style.display !== 'none';
                    list.style.display = open ? 'none' : 'block';
                    if (!open) { filter(''); }
                }, true);

                wrap.appendChild(button);
                wrap.appendChild(list);
                wrap.__value = function () { return current; };
                return wrap;
            }

            var enginePicker = row('翻译引擎', picker(ENGINE_LABELS, config.engine));
            var keyInput = row('API Key（系统离线与免密钥通道不用填）',
                textInput(config.apiKey, 'Azure / Google / DeepL / OpenAI 的 Key',
                    'stv-translate-key'));
            var regionInput = row('区域 Region（Azure 需要，可选）',
                textInput(config.region, '例如 eastasia'));
            var endpointInput = row('自定义接口地址（可选）',
                textInput(config.endpoint, 'DeepL 或 OpenAI 兼容接口的地址'));
            var modelInput = row('模型名（OpenAI 兼容接口用）',
                textInput(config.model, '例如 gpt-4o-mini'));
            var readSourcePicker = row('原文语言（评论和帖子）',
                picker(SOURCE_LANGUAGES, config.readSource));
            var readTargetPicker = row('翻译成（评论和帖子）',
                picker(LANGUAGES, config.readTarget));
            var writeTargetPicker = row('我发评论时译成',
                picker(LANGUAGES, config.writeTarget));

            var autoWrap = document.createElement('label');
            autoWrap.style.cssText = 'display:flex;align-items:center;margin:9px 0;'
                + 'font-size:13px;';
            var autoBox = document.createElement('input');
            autoBox.type = 'checkbox';
            autoBox.checked = !!config.auto;
            autoBox.style.cssText = 'margin-right:7px;';
            autoWrap.appendChild(autoBox);
            var autoText = document.createElement('span');
            autoText.textContent = '打开评论/帖子页时，等内容加载完自动翻译';
            autoWrap.appendChild(autoText);
            card.appendChild(autoWrap);

            var status = document.createElement('div');
            status.style.cssText = 'font-size:12px;opacity:0.85;margin-top:10px;'
                + 'min-height:18px;word-break:break-word;';
            card.appendChild(status);

            var actions = document.createElement('div');
            actions.style.cssText = 'margin-top:4px;display:flex;flex-wrap:wrap;';
            card.appendChild(actions);

            function collect() {
                return {
                    engine: enginePicker.__value() || 'apple',
                    apiKey: keyInput.value || '',
                    region: regionInput.value || '',
                    endpoint: endpointInput.value || '',
                    model: modelInput.value || '',
                    readSource: readSourcePicker.__value() || 'vi',
                    readTarget: readTargetPicker.__value() || 'zh-Hans',
                    writeTarget: writeTargetPicker.__value() || 'vi',
                    auto: !!autoBox.checked
                };
            }

            var saveButton = makeButton('保存', 'stv-translate-save');
            saveButton.style.cssText = BUTTON_CSS
                + 'background:#2563eb;border-color:#3b82f6;color:#fff;';
            saveButton.addEventListener('click', function (event) {
                stop(event);
                var next = collect();
                saveSettings(next).then(function () {
                    status.textContent = '已保存：' + engineName(next.engine);
                    refreshLabels();
                });
            }, true);
            actions.appendChild(saveButton);

            var testButton = makeButton('测试', 'stv-translate-test');
            testButton.addEventListener('click', function (event) {
                stop(event);
                var next = collect();
                status.textContent = '正在测试…';
                runTranslate(['Xin chào, đây là một bình luận thử nghiệm.'],
                    next.readSource, next.readTarget, next).then(function (out) {
                        status.textContent = '测试成功（' + engineName(next.engine)
                            + '）：' + out[0];
                    }, function (error) {
                        status.textContent = '测试失败：' + messageOf(error);
                    });
            }, true);
            actions.appendChild(testButton);

            var packButton = makeButton('下载系统语言包', 'stv-translate-pack');
            packButton.addEventListener('click', function (event) {
                stop(event);
                var next = collect();
                var plugin = appPlugin();
                if (!plugin || typeof plugin.translationPrepare !== 'function') {
                    status.textContent = '原生翻译桥不可用';
                    return;
                }
                var payload = { target: next.readTarget };
                if (next.readSource && next.readSource !== 'auto') {
                    payload.source = next.readSource;
                }
                status.textContent = '正在申请语言包…（系统会弹出下载确认）';
                Promise.resolve(plugin.translationPrepare(payload)).then(function (result) {
                    status.textContent = '语言包状态：'
                        + ((result && result.status) || 'unknown');
                }, function (error) {
                    status.textContent = '语言包申请失败：' + messageOf(error);
                });
            }, true);
            actions.appendChild(packButton);

            host.appendChild(root);
        }

        // ---- wiring ------------------------------------------------------

        // pushPage is the single funnel for every page the app opens, so this
        // covers the book comment page (app.fun.showComment), the settings page,
        // the community channel boards (showCommChannel/showUserPosts ->
        // pageposts, _page_vip.html:4710) and the single-post page (:4846).
        function hookPushPage() {
            var app = window.app;
            if (!app || typeof app.pushPage !== 'function') { return false; }
            if (app.__stvTranslateHooked) { return true; }
            app.__stvTranslateHooked = true;
            var original = app.pushPage;
            app.pushPage = function (name) {
                var page = original.apply(this, arguments);
                try {
                    if (name === 'pagesetting') { onSettingsPage(page); }
                    else { installOnPage(page); }
                } catch (error) {
                    note('ERR', 'translate page hook: ' + messageOf(error));
                }
                return page;
            };
            note('TRANSLATE', 'comment translation ready');
            return true;
        }

        // Every comment list in the app is created by app.comment.loadEmbed
        // (app.v2.js:3560): the book comment page, a single post's comments
        // (:5230), a user home (:4843) and the fromuser board. Hooking it is
        // what makes a board translatable even when the site appends the
        // container after pushPage has already returned.
        function hookCommentEmbed() {
            var app = window.app;
            if (!app || !app.comment
                || typeof app.comment.loadEmbed !== 'function') { return false; }
            if (app.comment.__stvTranslateHooked) { return true; }
            app.comment.__stvTranslateHooked = true;
            var original = app.comment.loadEmbed;
            app.comment.loadEmbed = function (container) {
                var result = original.apply(this, arguments);
                try {
                    var page = pageOf(container);
                    if (page) { installOnPage(page); }
                } catch (error) {
                    note('ERR', 'translate comment-embed hook: ' + messageOf(error));
                }
                return result;
            };
            note('TRANSLATE', 'community comment embeds are covered');
            return true;
        }

        var attempts = 0;
        var timer = setInterval(function () {
            attempts++;
            var ready = hookPushPage() && hookCommentEmbed();
            if (ready || attempts > 2500) { clearInterval(timer); }
        }, 20);
    })();
    """

    // MARK: - Inventory tab probe

    /**
     "储物袋 顶部的tab标签点击有错位，点击最后一个tab页，实际会显示到最后一处空白位置".

     The inventory page (_page_vip.html:1914-1938) has six `tabitem`s over six
     `tabview`s and is driven by `ui.smtab()` from /stv.ui.js -- a file that is not
     part of this repo, so the pointer-mark and `tabdiv` translate maths cannot be
     read here. Two mechanisms fit the symptom and they need different repairs:

       a) geometry -- the pointer mark and the pane offset are computed from a
          stale or hard-coded width (the template ships
          `tabpointermark{width:85px}`), so the last pane lands on blank space;
       b) data -- the last pane ("Đang kích hoạt") is filled from `inv.activate`
          (app.v2.js:7760, 7828) and stays empty when the server sends no `act`,
          so it is blank by content.

     Measure both at the tap instead of guessing: item count and per-item
     offsetLeft/offsetWidth, the mark's width and transform, the tabdiv transform,
     and the pane child counts -- before and after the framework reacts. Temporary,
     like the diagnostics panel; retire it with `diag` once this is settled.
     */
    static let tabProbe = """
    (function () {
        if (window.__stvTabProbeInstalled) { return; }
        window.__stvTabProbeInstalled = true;

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        function name(node) {
            return String((node && node.tagName) || '').toLowerCase();
        }

        function itemsOf(tabbar) {
            var out = [];
            var kids = (tabbar && tabbar.children) || [];
            for (var i = 0; i < kids.length; i++) {
                if (name(kids[i]) == 'tabitem') { out.push(kids[i]); }
            }
            return out;
        }

        function describe(item) {
            var node = item;
            var tabbar = null;
            var tab = null;
            while (node && node.nodeType === 1) {
                if (!tabbar && name(node) == 'tabbar') { tabbar = node; }
                if (name(node) == 'tab') { tab = node; break; }
                node = node.parentElement;
            }
            if (!tab) { return 'not inside a tab'; }
            var items = itemsOf(tabbar);
            var widths = [];
            for (var i = 0; i < items.length; i++) {
                widths.push(items[i].offsetLeft + '+' + items[i].offsetWidth);
            }
            var mark = tab.querySelector ? tab.querySelector('tabpointermark') : null;
            var div = tab.querySelector ? tab.querySelector('tabdiv') : null;
            var views = (div && div.children) || [];
            var lastChildren = views.length
                ? ((views[views.length - 1].children || []).length) : -1;
            // Every pane's child count, not just the last one: it separates "the
            // tapped pane was never filled" from "the framework never switched to
            // it". The inventory's last pane ("Đang kích hoạt") is filled from
            // app.items.inv.activate (app.v2.js:7760, 7828), so report that length
            // too -- an empty array there is data, not a layout bug.
            var panes = [];
            for (var k = 0; k < views.length; k++) {
                panes.push(k + ':' + (((views[k].children) || []).length));
            }
            var inv = window.app && window.app.items && window.app.items.inv;
            var activate = (inv && inv.activate) ? inv.activate.length : -1;
            return 'index=' + items.indexOf(item) + '/' + items.length
                + ' items=[' + widths.join(' ') + ']'
                + ' mark=' + (mark ? (mark.style.width || '?') + ' '
                    + (mark.style.transform || '?') : 'none')
                + ' div=' + (div ? (div.style.transform || '?') : 'none')
                + ' views=' + views.length + ' lastview=' + lastChildren + ' child(ren)'
                + ' panes=[' + panes.join(' ') + ']'
                + ' activate=' + activate;
        }

        document.addEventListener('click', function (event) {
            var node = event.target;
            var item = null;
            while (node && node.nodeType === 1) {
                if (name(node) == 'tabitem') { item = node; break; }
                node = node.parentElement;
            }
            if (!item) { return; }
            note('TAB', 'before ' + describe(item));
            setTimeout(function () { note('TAB', 'after  ' + describe(item)); }, 400);
        }, true);
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
    static let all: [String] = [compat, diag, activityLog, tabProbe, storageAccessor,
                                readerDefaults, ttsProvider, followFallback,
                                safeArea, keyboardPopup, gridLayout, settingsBackup,
                                domainFailover, bookmarkToggle, readerTts,
                                pageRepair, commentTranslate, bootShell,
                                SiteI18nData.script]
}
