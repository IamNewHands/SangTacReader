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
    // MARK: - Asset cache-buster stabiliser

    /**
     The site's own headers say `Cache-Control: max-age=86400` for everything
     under `/asset/`, and then its shell HTML defeats that by appending
     `Math.random()` to the URL of every file on the critical path
     (_page_vip.html):

         ui.scriptmanager.load("/asset/app.v2.js?" + Math.random(), ...)
         link.setAttribute('href', "/asset/app.v2.css?r=" + Math.random())
         ui.scriptmanager.load("/asset/app.v2.bookdisplay.js?" + Math.random(), ...)
         ui.scriptmanager.load("/asset/app.v2.config.js?" + Math.random(), ...)

     Every launch is therefore a brand-new URL and the disk cache can never hit,
     so `app.v2.js` -- the gate the whole app boots behind, documented as
     finished evaluating at +8s -- is refetched over a 300-900ms-TTFB link on
     every cold start.

     This block swaps the random token for a stable one. The token carries the
     generation counter and deliberately *not* the date: a date in the token
     changes every `/asset/` URL at midnight UTC, so the first launch of every
     day is a guaranteed cold fetch of the whole boot-critical trio (app.v2.js
     59KB + app.v2.css 10KB + app.v2.bookdisplay.js 5KB) -- while the server's
     own `max-age=86400` would have let WebKit serve the entry from disk inside
     the day and revalidate it for the price of a 304 after it. Staleness is
     bounded by that same 24h, and the "强制刷新站点资源" row on the settings page
     moves every URL to a new generation at once, which is the escape hatch for
     a site update that keeps its file names.

     Deliberately narrow: only `/asset/` URLs, and only a random-looking
     `?<value>` / `?r=<value>` / `?nocache=<value>` parameter. Real version
     numbers (`?v=1.360`, `?v2`, `?v=7`) are the site's version contract and are
     left alone, as is every other URL on the page.
     */
    static let assetCache = """
    (function () {
        if (window.__stvAssetCache) { return; }

        var GEN_KEY = 'stv.asset.generation';

        function readLocal(key) {
            try {
                return window.localStorage ? (window.localStorage.getItem(key) || '') : '';
            } catch (e) { return ''; }
        }

        function writeLocal(key, value) {
            try {
                if (window.localStorage) { window.localStorage.setItem(key, value); }
            } catch (e) {}
        }

        function generation() {
            var value = parseInt(readLocal(GEN_KEY), 10);
            return (isFinite(value) && value > 0) ? value : 1;
        }

        // One token per page load: every asset in a load has to agree, or the
        // same file ends up cached under two names. No date: see the note above
        // the block -- a daily token is a daily cache miss on the boot path.
        var TOKEN = 'stv' + generation();

        // No backslashes anywhere in these blocks: they are Swift multiline
        // strings, and a backslash reaches JavaScript as a literal backslash.
        // Hence [.] and [0-9] instead of the usual escapes.
        var RANDOM_PARAM = /([?&])(nocache|r|_)=0[.][0-9]+/g;
        var BARE_RANDOM = /[?]0[.][0-9]+$/;

        function stabilize(url) {
            if (typeof url !== 'string' || url.indexOf('/asset/') < 0) { return url; }
            var out = url.replace(RANDOM_PARAM, '$1$2=' + TOKEN);
            if (BARE_RANDOM.test(out)) { out = out.replace(BARE_RANDOM, '?' + TOKEN); }
            return out;
        }

        function wrapProperty(proto, name) {
            if (!proto) { return false; }
            var descriptor = null;
            try { descriptor = Object.getOwnPropertyDescriptor(proto, name); } catch (e) {
                return false;
            }
            if (!descriptor || typeof descriptor.set !== 'function') { return false; }
            var setter = descriptor.set;
            try {
                Object.defineProperty(proto, name, {
                    configurable: true,
                    enumerable: descriptor.enumerable,
                    get: descriptor.get,
                    set: function (value) {
                        // The property hook, not an insertion hook, is what
                        // matters: stv.ui.js appends the <script> FIRST and only
                        // then assigns `.src`, so rewriting at insertion time
                        // would already be too late.
                        return setter.call(this, stabilize(value));
                    }
                });
                return true;
            } catch (e) { return false; }
        }

        function wrapSetAttribute() {
            var proto = window.Element && window.Element.prototype;
            if (!proto || typeof proto.setAttribute !== 'function') { return false; }
            var original = proto.setAttribute;
            proto.setAttribute = function (name, value) {
                // Fast path: the site calls setAttribute constantly and almost
                // never with one of our URLs.
                if (typeof value === 'string' && value.indexOf('/asset/') >= 0) {
                    var key = String(name).toLowerCase();
                    if (key === 'src' || key === 'href') { value = stabilize(value); }
                }
                return original.call(this, name, value);
            };
            // Report honestly: on a non-writable prototype this assignment is a
            // silent no-op in sloppy mode, and `hooks` is what the panel shows.
            return proto.setAttribute !== original;
        }

        var hooks = 0;
        if (wrapProperty(window.HTMLScriptElement && window.HTMLScriptElement.prototype, 'src')) {
            hooks++;
        }
        if (wrapProperty(window.HTMLLinkElement && window.HTMLLinkElement.prototype, 'href')) {
            hooks++;
        }
        if (wrapProperty(window.HTMLImageElement && window.HTMLImageElement.prototype, 'src')) {
            hooks++;
        }
        if (wrapSetAttribute()) { hooks++; }

        window.__stvAssetCache = {
            token: TOKEN,
            stabilize: stabilize,
            hooks: hooks,
            // Drops the whole stabilised set at once by moving every URL to a
            // new generation, then reloads so the page picks them up.
            refresh: function () {
                writeLocal(GEN_KEY, String(generation() + 1));
                try { window.location.reload(); } catch (e) {}
            }
        };

        // `diag` is injected after this block, so __stvDiag does not exist yet
        // here -- announce once the document is parsed instead.
        function announce() {
            if (!window.__stvDiag) { return; }
            window.__stvDiag.log('ASSET', 'cache-buster stabilised (token=' + TOKEN
                + ', hooks=' + hooks + ')');
        }
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', announce);
        } else {
            announce();
        }
    })();
    """

    // MARK: - Local asset mirror

    /**
     Serves the site's own boot bundles from a copy inside the app.

     The problem this solves, in one line: the reader waits for roughly a
     megabyte of JavaScript that the site asks for over a link whose every
     round trip is 300-900ms, and the four largest files are requested with a
     `Math.random()` cache-buster that makes WebKit's disk cache useless
     (`_page_vip.html:3066,5207,5208,5211`). The other thirteen load from the
     HTML parser before any injected script can see them.

     This block covers the eight files it *can* reach. It cannot reach the
     parser-created ones -- those need the document itself to be served
     differently -- and `[ASSET]` below reports exactly what is still going over
     the network so that the remaining cost is measurable instead of assumed.

     Mechanism, and why:

       - JavaScript goes out as a `blob:` URL assigned through the same
         `HTMLScriptElement.src` property the site's own loader uses. The element
         stays an ordinary script, so `stv.ui.js`'s `onload` handler and its
         `stack` de-duplication map (keyed on the URL *it* passed) keep working
         untouched. Inlining the source into a new `<script>` would have broken
         both.
       - CSS becomes a `<style>` node instead of a blob `<link>`. The page-flip
         templates rebuild each frame's `<head>` from
         `document.querySelectorAll("link[rel=stylesheet],style")` and use
         `css.textContent` for style nodes (`_dl_app.v2.js` @199996), so a style
         node carries the site's stylesheet into the frames and a blob href would
         have to be resolved across an `about:srcdoc` document instead.
       - `bootShell.siteCssReady()` recognises the mirrored sheet by its
         `data-stv-mirror` attribute, because a `<style>` has no `href` to match
         on.

     Two escape hatches, because this is the one patch that can stop the app from
     booting at all and it is installed at document start:

       1. `window.error` with a `blob:` filename, or an `error` event on an
          element we served, or `STV_SERVER` -- the very first global `app.v2.js`
          declares -- still being undefined 8s after we served it. Any of those
          sets `stv.mirror.off` and reloads once; the next load skips the mirror
          entirely and behaves exactly like the version without it.
       2. 设置 -> 本地资源镜像 turns it off by hand, and clears any refreshed copy.

     Everything the block reports goes out under `[MIRROR]`, and the resource
     timeline it prints at `load` under `[ASSET]`.
     */
    static let assetMirror = """
    (function () {
        if (window.__stvAssetMirror) { return; }

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        var OFF_KEY = 'stv.mirror.off';
        var CHECK_KEY = 'stv.mirror.checked';
        var CHECK_TTL = 6 * 60 * 60 * 1000;
        var PROBE_DELAY = 8000;

        var TABLE = window.__stvSiteAssets || null;
        var STAMPS = window.__stvSiteStamps || {};
        var off = false;

        function readLocal(key) {
            try {
                return window.localStorage ? (window.localStorage.getItem(key) || '') : '';
            } catch (e) { return ''; }
        }

        function writeLocal(key, value) {
            try {
                if (window.localStorage) { window.localStorage.setItem(key, value); }
            } catch (e) {}
        }

        off = readLocal(OFF_KEY) === '1';

        // The same eight files as SiteAssets.supported in SiteAssets.swift and
        // ASSETS in scripts/gen-site-assets.js. The tests assert all three lists
        // agree, because a path that only one of them knows about fails silently:
        // the mirror simply never matches and the file keeps going over the wire.
        var PATHS = [
            ['/asset/app.v2.js', 'app.v2.js'],
            ['/asset/app.v2.css', 'app.v2.css'],
            ['/asset/app.v2.bookdisplay.js', 'app.v2.bookdisplay.js'],
            ['/asset/app.v2.config.js', 'app.v2.config.js'],
            ['/asset/app.v2.read.js', 'app.v2.read.js'],
            ['/asset/app.v2.chapterdisplay.js', 'app.v2.chapterdisplay.js'],
            ['/stv.tts.js', 'stv.tts.js'],
            ['/hanviet.js', 'hanviet.js']
        ];

        function pathOf(url) {
            var text = String(url || '');
            var cut = text.indexOf('?');
            if (cut >= 0) { text = text.slice(0, cut); }
            cut = text.indexOf('#');
            if (cut >= 0) { text = text.slice(0, cut); }
            if (text.indexOf('://') >= 0) {
                var after = text.indexOf('/', text.indexOf('://') + 3);
                text = after < 0 ? '' : text.slice(after);
            }
            return text;
        }

        function nameOf(url) {
            var path = pathOf(url);
            for (var i = 0; i < PATHS.length; i++) {
                if (PATHS[i][0] === path) { return PATHS[i][1]; }
            }
            return '';
        }

        function textOf(name) {
            var text = TABLE ? TABLE[name] : '';
            return (typeof text === 'string' && text.length > 0) ? text : '';
        }

        function isScript(element) {
            return String((element && element.tagName) || '').toUpperCase() === 'SCRIPT';
        }

        function isStylesheet(element) {
            if (String((element && element.tagName) || '').toUpperCase() !== 'LINK') { return false; }
            var rel = '';
            try { rel = String(element.getAttribute('rel') || element.rel || ''); } catch (e) { rel = ''; }
            return rel.toLowerCase() === 'stylesheet';
        }

        function giveUp(reason) {
            if (off) { return; }
            off = true;
            writeLocal(OFF_KEY, '1');
            note('ERR', reason + '; reloading without the local copy');
            try { window.location.reload(); } catch (e) {}
        }

        // A blob script that fails to load fires `error` on the element, and one
        // that fails to parse reports a blob: URL through window.onerror. Both are
        // unambiguous, so neither costs a false positive on a slow boot.
        window.addEventListener('error', function (event) {
            var file = String((event && event.filename) || '');
            if (file.indexOf('blob:') !== 0) { return; }
            giveUp('a mirrored script failed (' + file + ')');
        }, true);

        var probeArmed = false;

        /**
         `app.v2.js` opens with `var STV_SERVER`, so that global is proof the file
         ran. Checking for it rather than for `window.app` is what keeps this from
         firing on a boot that is merely slow: a mirrored file either executes
         within milliseconds of being handed to the element, or it never will.
         */
        function probe() {
            if (!probeArmed) { return; }
            if (typeof window.STV_SERVER !== 'undefined') { return; }
            giveUp('the mirrored app.v2.js never executed');
        }

        function armProbe(name, text) {
            if (name !== 'app.v2.js' || text.indexOf('STV_SERVER') < 0) { return; }
            if (probeArmed) { return; }
            probeArmed = true;
            setTimeout(probe, PROBE_DELAY);
        }

        var served = 0;
        var servedNames = [];
        var blobUrls = {};
        var styleNodes = {};

        function blobFor(name) {
            if (blobUrls[name] !== undefined) { return blobUrls[name]; }
            var url = '';
            var text = textOf(name);
            if (text) {
                try {
                    url = URL.createObjectURL(new Blob([text], { type: 'application/javascript' }));
                } catch (e) { url = ''; }
            }
            blobUrls[name] = url;
            return url;
        }

        function styleFor(name) {
            if (styleNodes[name]) { return; }
            var text = textOf(name);
            if (!text) { return; }
            var node = document.createElement('style');
            node.setAttribute('data-stv-mirror', name);
            node.textContent = text;
            (document.head || document.documentElement).appendChild(node);
            styleNodes[name] = node;
        }

        function adopt(element, name) {
            served++;
            servedNames.push(name);
            try { element.setAttribute('data-stv-mirror', name); } catch (e) {}
            if (typeof element.addEventListener === 'function') {
                element.addEventListener('error', function () {
                    giveUp('the mirrored ' + name + ' did not load');
                });
            }
            note('MIRROR', name + ' (' + Math.round(textOf(name).length / 1024)
                + 'KB) from the local copy');
        }

        function wrapScriptSrc() {
            var proto = window.HTMLScriptElement && window.HTMLScriptElement.prototype;
            if (!proto) { return false; }
            var descriptor = null;
            try { descriptor = Object.getOwnPropertyDescriptor(proto, 'src'); } catch (e) {
                return false;
            }
            if (!descriptor || typeof descriptor.set !== 'function') { return false; }
            var setter = descriptor.set;
            try {
                Object.defineProperty(proto, 'src', {
                    configurable: true,
                    enumerable: descriptor.enumerable,
                    get: descriptor.get,
                    set: function (value) {
                        if (!this.__stvMirrorDone && !off) {
                            var name = nameOf(value);
                            var url = name ? blobFor(name) : '';
                            if (url) {
                                this.__stvMirrorDone = name;
                                adopt(this, name);
                                armProbe(name, textOf(name));
                                return setter.call(this, url);
                            }
                        }
                        return setter.call(this, value);
                    }
                });
                return true;
            } catch (e) { return false; }
        }

        function maybeMirrored(value) {
            return typeof value === 'string'
                && (value.indexOf('/asset/') >= 0
                    || value.indexOf('/stv.tts.js') >= 0
                    || value.indexOf('/hanviet.js') >= 0);
        }

        /**
         The site builds its stylesheet link with setAttribute (line 3066 of the
         shell), and `stv.ui.js` appends the <script> before assigning `.src`, so
         both the property hook above and this attribute hook below are needed.
         */
        function wrapSetAttribute() {
            var proto = window.Element && window.Element.prototype;
            if (!proto || typeof proto.setAttribute !== 'function') { return false; }
            var original = proto.setAttribute;
            proto.setAttribute = function (name, value) {
                if (off || this.__stvMirrorDone || !maybeMirrored(value)) {
                    return original.call(this, name, value);
                }
                var key = String(name).toLowerCase();
                var mirror = (key === 'src' || key === 'href') ? nameOf(value) : '';
                if (mirror && key === 'src' && isScript(this)) {
                    var url = blobFor(mirror);
                    if (url) {
                        this.__stvMirrorDone = mirror;
                        adopt(this, mirror);
                        armProbe(mirror, textOf(mirror));
                        return original.call(this, name, url);
                    }
                } else if (mirror && key === 'href' && isStylesheet(this) && textOf(mirror)) {
                    this.__stvMirrorDone = mirror;
                    adopt(this, mirror);
                    styleFor(mirror);
                    return;
                }
                return original.call(this, name, value);
            };
            return proto.setAttribute !== original;
        }

        // --- resource timeline ---

        var STATIC_EXT = ['.js', '.css', '.woff2', '.woff', '.ttf', '.otf', '.png',
            '.jpg', '.jpeg', '.webp', '.svg', '.gif'];

        function isStatic(entry) {
            var name = String((entry && entry.name) || '');
            // Same-origin only. A cross-origin response (the cover CDN, the
            // font CDN) reports transferSize 0 for lack of Timing-Allow-Origin,
            // which would be counted as a cache hit and would understate the
            // bytes -- and nothing cross-origin can be mirrored by path anyway.
            var origin = (window.location && window.location.origin)
                ? String(window.location.origin) : '';
            if (origin && name.indexOf(origin) !== 0) { return false; }
            var path = pathOf(name);
            if (!path) { return false; }
            var lower = path.toLowerCase();
            for (var i = 0; i < STATIC_EXT.length; i++) {
                if (lower.slice(-STATIC_EXT[i].length) === STATIC_EXT[i]) { return true; }
            }
            return false;
        }

        function shorten(name) {
            var path = pathOf(name);
            var parts = path.split('/');
            return parts[parts.length - 1] || path;
        }

        /**
         What is still going over the network after the mirror took its eight
         files. This is deliberately independent of the mirror being enabled: it
         is the measurement that says whether the remaining static resources
         matter at all, and it counts the parser-created files the mirror cannot
         reach.
         */
        function timeline() {
            var perf = window.performance;
            if (!perf || typeof perf.getEntriesByType !== 'function') { return; }
            var entries = perf.getEntriesByType('resource') || [];
            var count = 0;
            var wire = 0;
            var decoded = 0;
            var cached = 0;
            var last = 0;
            var rows = [];
            for (var i = 0; i < entries.length; i++) {
                var entry = entries[i];
                if (!isStatic(entry)) { continue; }
                count++;
                wire += entry.transferSize || 0;
                decoded += entry.decodedBodySize || 0;
                if (!entry.transferSize) { cached++; }
                if (entry.responseEnd > last) { last = entry.responseEnd; }
                rows.push(entry);
            }
            if (!count) { return; }
            rows.sort(function (a, b) { return (b.duration || 0) - (a.duration || 0); });
            note('ASSET', count + ' static request(s) still over the network: '
                + Math.round(wire / 1024) + 'KB wire / ' + Math.round(decoded / 1024)
                + 'KB decoded, ' + cached + ' from cache, last byte at +'
                + Math.round(last) + 'ms' + (served ? '; ' + served + ' served locally ('
                + servedNames.join(',') + ')' : '; none served locally'));
            for (var j = 0; j < rows.length && j < 5; j++) {
                var row = rows[j];
                note('ASSET', shorten(row.name) + ' ' + Math.round((row.transferSize || 0) / 1024)
                    + 'KB ' + Math.round(row.duration || 0) + 'ms '
                    + (row.transferSize ? 'network' : 'cache') + ' @+'
                    + Math.round(row.startTime || 0) + 'ms');
            }
        }

        if (document.readyState === 'complete') {
            setTimeout(timeline, 500);
        } else {
            window.addEventListener('load', function () { setTimeout(timeline, 500); });
        }

        // --- revalidation ---

        function dueForCheck() {
            var last = parseInt(readLocal(CHECK_KEY), 10);
            if (!isFinite(last) || last <= 0) { return true; }
            return (Date.now() - last) > CHECK_TTL;
        }

        function revalidate() {
            var plugin = window.Capacitor && window.Capacitor.Plugins
                && window.Capacitor.Plugins.App;
            if (!plugin || typeof plugin.siteAssetRefresh !== 'function') { return; }
            if (!dueForCheck()) { return; }
            var items = [];
            for (var i = 0; i < PATHS.length; i++) {
                var name = PATHS[i][1];
                if (textOf(name)) {
                    items.push({ name: name, stamp: String(STAMPS[name] || '') });
                }
            }
            if (!items.length) { return; }
            writeLocal(CHECK_KEY, String(Date.now()));
            plugin.siteAssetRefresh({ origin: window.location.origin, items: items })
                .then(function (result) {
                    var updated = (result && result.updated) || [];
                    note('MIRROR', 'revalidated ' + ((result && result.checked) || 0)
                        + ' file(s): ' + (updated.length
                            ? 'updated ' + updated.join(',') + ' (next launch)'
                            : 'all current'));
                })
                .catch(function (error) {
                    note('ERR', 'revalidate failed: ' + error);
                });
        }

        function forget() {
            writeLocal(CHECK_KEY, '');
            var plugin = window.Capacitor && window.Capacitor.Plugins
                && window.Capacitor.Plugins.App;
            if (!plugin || typeof plugin.siteAssetForget !== 'function') { return; }
            plugin.siteAssetForget().then(function (result) {
                note('MIRROR', 'dropped ' + (((result && result.dropped) || []).length)
                    + ' refreshed file(s); the copy inside the app takes over');
            }).catch(function (error) {
                note('ERR', 'forget failed: ' + error);
            });
        }

        // --- settings rows ---

        function rows(host) {
            var item = document.createElement('div');
            item.className = 'settingitem stv-assetmirror-entry';
            var title = document.createElement('div');
            title.className = 'settingitemtitle';
            title.textContent = '本地资源镜像';
            var state = document.createElement('div');
            state.className = 'stv-assetmirror-state';
            function paint() {
                state.textContent = (off ? '已关闭' : '已开启') + ' · 点这里'
                    + (off ? '开启' : '关闭');
                state.style.cssText = 'font-size:12px;opacity:0.9;' + (off ? '' : 'color:#7fdc7f;');
            }
            paint();
            item.appendChild(title);
            item.appendChild(state);
            item.addEventListener('click', function (event) {
                if (event && event.stopPropagation) { event.stopPropagation(); }
                if (event && event.preventDefault) { event.preventDefault(); }
                off = !off;
                writeLocal(OFF_KEY, off ? '1' : '');
                if (!off) { forget(); }
                paint();
                note('MIRROR', off ? 'turned off; reloading' : 'turned on; reloading');
                try { window.location.reload(); } catch (e) {}
            }, true);
            host.appendChild(item);

            var clear = document.createElement('div');
            clear.className = 'settingitem stv-assetmirror-clear';
            clear.innerHTML = '<div class="settingitemtitle">丢弃已刷新的资源副本</div>'
                + '<div class=""><i class="fas fa-rotate-left"></i></div>';
            clear.addEventListener('click', function (event) {
                if (event && event.stopPropagation) { event.stopPropagation(); }
                if (event && event.preventDefault) { event.preventDefault(); }
                forget();
            }, true);
            host.appendChild(clear);
        }

        window.__stvAssetMirror = {
            enabled: function () { return !off; },
            served: function () { return servedNames.slice(); },
            forget: forget,
            rows: rows,
            // Exposed so the tests can drive the two safety nets without waiting
            // out their real delays, and so a device log can be read against the
            // same entry points the block itself uses.
            probe: probe,
            timeline: timeline,
            revalidate: revalidate
        };

        if (!TABLE || off) {
            // Deferred: on a device the switch may still be off at document
            // start, and the panel is the only place this can be said.
            setTimeout(function () {
                note('MIRROR', off
                    ? 'off after a failure: the page fetches every asset itself'
                    : 'no local copy bundled: the page fetches every asset itself');
            }, 0);
            return;
        }

        var hooks = 0;
        if (wrapScriptSrc()) { hooks++; }
        if (wrapSetAttribute()) { hooks++; }

        window.__stvAssetMirror.hooks = hooks;
        window.__stvAssetMirror.names = TABLE ? Object.keys(TABLE) : [];

        setTimeout(function () {
            var total = 0;
            var names = window.__stvAssetMirror.names;
            for (var i = 0; i < names.length; i++) { total += textOf(names[i]).length; }
            note('MIRROR', names.length + ' file(s), ' + Math.round(total / 1024)
                + 'KB bundled, hooks=' + hooks + ' (blob scripts, style CSS)');
        }, 0);

        if (document.readyState === 'complete') {
            setTimeout(revalidate, 3000);
        } else {
            window.addEventListener('load', function () { setTimeout(revalidate, 3000); });
        }
    })();
    """

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
            // At document start <body> does not exist yet, so the badge can land
            // on <html> -- outside the body's stacking context, and skipped by
            // anything that walks the body. Move it in as soon as there is a body.
            document.addEventListener('DOMContentLoaded', function () {
                if (badge && document.body && badge.parentNode !== document.body) {
                    document.body.appendChild(badge);
                }
            });
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
            // While the switch is on the badge is ALWAYS on screen. It is the only
            // way back to the panel, so nothing except the switch itself may take
            // it away. (The old rule kept a `badgeHidden` flag that only the next
            // ERR cleared, which is why the floating button looked like it needed
            // a failure before it appeared: HIDE collapsed the badge too.)
            badge.style.display = enabled ? 'block' : 'none';
        }

        // ---- expanded panel --------------------------------------------------

        function buildPanel() {
            if (root) { return !!root.parentNode; }
            var host = document.body || document.documentElement;
            if (!host) { return false; }

            // Not `top:0`. The web view runs edge to edge (the safe-area block
            // adds `viewport-fit=cover`), so a bar pinned to the very top sits
            // under the status bar / Dynamic Island -- where a tap belongs to the
            // system and never reaches the page, which is why HIDE and CLOSE were
            // unreachable on device. The panel starts below the safe area, from
            // the same two sources the reader bars use (site-computed
            // `--status-bar-height`, then the web view's own `env()` inset).
            root = make('div', 'position:fixed;left:0;'
                + 'top:max(var(--status-bar-height, 0px), env(safe-area-inset-top, 0px));'
                + 'width:100%;height:42%;display:none;'
                + 'z-index:2147483646;background:rgba(10,10,10,0.94);color:#7f7;'
                + 'font:11px/1.35 Menlo,monospace;box-shadow:0 3px 12px rgba(0,0,0,0.6);');
            root.setAttribute('data-stvdiag', 'panel');

            // 36px, not 30px: the buttons are the only way to close the panel, and
            // the smaller bar left them at roughly half a comfortable tap target.
            var bar = make('div', 'position:absolute;top:0;left:0;right:0;height:36px;'
                + 'background:#1d1d1d;display:flex;align-items:center;padding:0 4px;'
                + 'color:#ddd;font:11px/36px Menlo,monospace;');
            countEl = make('span', 'flex:1;padding-left:6px;overflow:hidden;white-space:nowrap;', 'stvdiag');
            bar.appendChild(countEl);

            function barButton(label, handler) {
                var b = make('button', 'font:11px Menlo,monospace;padding:6px 10px;margin-left:4px;'
                    + 'background:#333;color:#eee;border:1px solid #555;border-radius:3px;', label);
                b.addEventListener('click', function (e) { stopEvent(e); handler(); }, true);
                return b;
            }
            bar.appendChild(barButton('COPY', copyAll));
            // The buffer dies with the page, so COPY alone cannot answer "what
            // happened before the crash". SAVE hands the whole log -- including
            // the lines the file kept from earlier launches -- to the system
            // share sheet, which is the only route off the device.
            bar.appendChild(barButton('SAVE', saveAll));
            bar.appendChild(barButton('CLEAR', function () {
                lines = [];
                prior = '';
                errors = 0;
                wipeFile();
                render();
            }));
            // HIDE collapses the panel only. The badge is the tap target that
            // brings the panel back, so collapsing both would leave the reader
            // with no way in until the next error happened to reset the flag.
            bar.appendChild(barButton('HIDE', function () { hide(); }));
            bar.appendChild(barButton('CLOSE', function () { hide(); }));
            root.appendChild(bar);

            listEl = make('div', 'position:absolute;top:36px;left:0;right:0;bottom:0;'
                + 'overflow:auto;-webkit-overflow-scrolling:touch;padding:4px 6px 10px;'
                + 'white-space:pre-wrap;word-break:break-all;'
                + '-webkit-user-select:text;user-select:text;');
            root.appendChild(listEl);

            host.appendChild(root);
            bindDrag(bar, root, null, true);
            return true;
        }

        function render() {
            var body = fullText();
            if (listEl) {
                listEl.textContent = body;
                listEl.scrollTop = listEl.scrollHeight;
            }
            if (countEl) {
                countEl.textContent = 'stvdiag ' + lines.length + ' lines, ' + errors
                    + ' errors' + (prior ? ' +' + priorBytes + 'B from the file' : '');
            }
            paintBadge();
        }

        function show() {
            // Showing a window that the switch has turned off would contradict
            // the setting, so this is the one other place `enabled` is read.
            if (!enabled) { return; }
            if (!buildPanel()) { return; }
            open = true;
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
            var text = fullText();
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

        // ---- the file the app process owns ----------------------------------
        //
        // Every line the buffer takes is mirrored into
        // Library/Application Support/stv-diagnostic.log by `diagAppend`
        // (SangTacAppPlugin.swift). A crash, a jetsam kill or a WebContent
        // restart empties the page but not that file, so the next launch reads
        // it back into `prior` -- shown above the live lines, and included in
        // COPY and SAVE.
        //
        // Batched on purpose: one bridge hop per line would be a cost on every
        // request, and 300ms is short enough that a crash loses at most the
        // last few lines. An error flushes on the next turn instead, because
        // the line right before a crash is the one worth keeping.

        var FLUSH_MS = 300;
        var PRIOR_MAX = 200000;
        var pending = [];
        var flushTimer = null;
        var prior = '';
        var priorBytes = 0;
        var filePath = '';

        function appPlugin() {
            return window.Capacitor && window.Capacitor.Plugins
                && window.Capacitor.Plugins.App;
        }

        function settle(call) {
            if (call && typeof call.catch === 'function') { call.catch(function () {}); }
            return call;
        }

        function fullText() {
            if (!prior) { return lines.join(NL); }
            return prior + (prior.charAt(prior.length - 1) === NL ? '' : NL)
                + '---- this launch ----' + NL + lines.join(NL);
        }

        function flush() {
            if (flushTimer) { clearTimeout(flushTimer); flushTimer = null; }
            if (!pending.length) { return; }
            var plugin = appPlugin();
            if (!plugin || typeof plugin.diagAppend !== 'function') {
                // No native sink (a plain browser, or the plugin is not
                // published yet). Keep the lines queued so a later flush still
                // carries them, but do not grow without bound.
                while (pending.length > MAX) { pending.shift(); }
                return;
            }
            var batch = pending;
            pending = [];
            settle(plugin.diagAppend({ lines: batch }));
        }

        function scheduleFlush() {
            if (flushTimer) { return; }
            flushTimer = setTimeout(function () { flush(); }, FLUSH_MS);
        }

        function readFile() {
            var plugin = appPlugin();
            if (!plugin || typeof plugin.diagRead !== 'function') { return; }
            settle(plugin.diagRead()).then(function (result) {
                // The path and the size are recorded even when the file is
                // empty: SAVE quotes the path, and an empty file is a fact worth
                // being able to state.
                filePath = (result && result.path) || filePath;
                priorBytes = (result && result.bytes) || 0;
                var text = result && result.text;
                if (typeof text !== 'string' || !text) {
                    prior = '';
                    return;
                }
                if (text.length > PRIOR_MAX) {
                    text = text.slice(text.length - PRIOR_MAX);
                    var cut = text.indexOf(NL);
                    if (cut > 0) { text = text.slice(cut + 1); }
                }
                prior = text;
                if (open) { render(); }
            });
        }

        function wipeFile() {
            var plugin = appPlugin();
            if (!plugin || typeof plugin.diagClear !== 'function') { return; }
            settle(plugin.diagClear());
        }

        // Base64 by hand rather than through btoa: btoa takes a binary string,
        // which means building a second copy of the whole log as one JS string
        // and throwing on any lone surrogate -- and the log is exactly the place
        // a truncated UTF-8 sequence ends up. This walks the code points, so it
        // is correct for the Vietnamese and Chinese text the log is full of.
        var B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
            + '0123456789+/';

        function utf8Bytes(text) {
            var bytes = [];
            for (var i = 0; i < text.length; i++) {
                var code = text.charCodeAt(i);
                if (code < 128) {
                    bytes.push(code);
                } else if (code < 2048) {
                    bytes.push(192 | (code >> 6), 128 | (code & 63));
                } else if (code >= 55296 && code < 56320 && i + 1 < text.length) {
                    var low = text.charCodeAt(i + 1);
                    if (low >= 56320 && low < 57344) {
                        var point = 65536 + ((code - 55296) << 10) + (low - 56320);
                        bytes.push(240 | (point >> 18), 128 | ((point >> 12) & 63),
                            128 | ((point >> 6) & 63), 128 | (point & 63));
                        i++;
                    } else {
                        // An unpaired high surrogate: written as the replacement
                        // character, which is what the native side would have
                        // received anyway.
                        bytes.push(239, 191, 189);
                    }
                } else {
                    bytes.push(224 | (code >> 12), 128 | ((code >> 6) & 63),
                        128 | (code & 63));
                }
            }
            return bytes;
        }

        function toBase64(text) {
            var bytes = utf8Bytes(text);
            var out = '';
            for (var i = 0; i < bytes.length; i += 3) {
                var b0 = bytes[i];
                var b1 = i + 1 < bytes.length ? bytes[i + 1] : -1;
                var b2 = i + 2 < bytes.length ? bytes[i + 2] : -1;
                out += B64_ALPHABET.charAt(b0 >> 2);
                out += B64_ALPHABET.charAt(((b0 & 3) << 4)
                    | (b1 < 0 ? 0 : b1 >> 4));
                out += b1 < 0 ? '=' : B64_ALPHABET.charAt(((b1 & 15) << 2)
                    | (b2 < 0 ? 0 : b2 >> 6));
                out += b2 < 0 ? '=' : B64_ALPHABET.charAt(b2 & 63);
            }
            return out;
        }

        function saveAll() {
            var plugin = appPlugin();
            if (!plugin || typeof plugin.exportFile !== 'function') {
                log('ERR', 'no export channel on this device; use COPY');
                return;
            }
            var data = toBase64(fullText());
            if (!data) {
                log('ERR', 'could not encode the log for export; use COPY');
                return;
            }
            var stamp = new Date();
            var name = 'stv-diagnostic-' + stamp.getFullYear() + pad(stamp.getMonth() + 1)
                + pad(stamp.getDate()) + '-' + pad(stamp.getHours())
                + pad(stamp.getMinutes()) + pad(stamp.getSeconds()) + '.log';
            settle(plugin.exportFile({ filename: name, data: data })).then(function () {
                log('DIAG', 'exported ' + name + (filePath ? ' (file: ' + filePath + ')' : ''));
            }, function (error) {
                log('ERR', 'export failed: ' + fmt(error));
            });
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

        function raw(text, isError) {
            var line = stamp() + ' ' + text;
            lines.push(line);
            while (lines.length > MAX) { lines.shift(); }
            if (isError) { errors++; }
            // `pending` is assigned further down the same IIFE; an early error
            // event can reach here first, hence the guard rather than a
            // reordering that would put the file helpers above the buffer.
            if (pending) {
                pending.push(line);
                // An error is the line a crash would take with it, so it goes
                // out on the next turn instead of waiting for the batch timer.
                if (isError) { setTimeout(function () { flush(); }, 0); }
                else { scheduleFlush(); }
            }
        }

        function paint() {
            if (open) { render(); } else { paintBadge(); }
        }

        function log(tag, msg) {
            // The switch is checked here and nowhere else: every caller (all the
            // other blocks, the console tee, the tap listeners) keeps working
            // unchanged and pays one boolean while logging is off.
            if (!enabled) { return; }
            raw('[' + tag + '] ' + fmt(msg), tag === 'ERR');
            paint();
        }

        /**
         The native Http plugin ships its lines one batch per runloop turn -- a
         single evaluateJavaScript instead of one per request -- so they arrive
         pre-formatted as "[TAG] message" and are replayed here.

         `forced` marks a batch the native side kept because it was a failure. A
         failure is worth holding on to even while the switch is off: it costs
         nothing to render (there is no panel), it is bounded by MAX like every
         other line, and it means "why did that fail?" survives a reader who never
         turned logging on. A non-forced batch while off is still dropped, so the
         per-request firehose stays off.
         */
        function logBatch(list, forced) {
            if (!list || !list.length) { return; }
            if (!enabled && !forced) { return; }
            for (var i = 0; i < list.length; i++) {
                var text = String(list[i] === null || list[i] === undefined ? '' : list[i]);
                raw(text, text.indexOf('[ERR]') === 0);
            }
            // With the switch off there is no badge and no panel to paint into.
            if (enabled) { paint(); }
        }

        /**
         The native side keeps its own copy of the switch so it can skip building
         a diagnostic line at all -- decoding a response body and a cross-process
         evaluateJavaScript per request is the cost this removes. Tell it every
         time the switch moves.
         */
        function pushNativeSwitch() {
            var plugin = window.Capacitor && window.Capacitor.Plugins
                && window.Capacitor.Plugins.Http;
            if (!plugin || typeof plugin.setDiagnostics !== 'function') { return; }
            try {
                var call = plugin.setDiagnostics({ enabled: enabled });
                if (call && typeof call.catch === 'function') { call.catch(function () {}); }
            } catch (e) {}
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
            pushNativeSwitch();
            if (!enabled) {
                lines = [];
                errors = 0;
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
            logBatch: logBatch,
            show: show,
            hide: hide,
            toggle: toggle,
            copy: copyAll,
            save: saveAll,
            text: function () { return fullText(); },
            lines: function () { return lines.slice(); },
            file: function () { return { path: filePath, text: prior, bytes: priorBytes }; },
            reload: readFile,
            flush: function () { flush(); },
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
        //
        // The native gate defaults to off, so a switch that was left on has to be
        // re-sent. Plugins.Http may not be published yet at document start, hence
        // the retries; the function is idempotent and costs one boolean.
        pushNativeSwitch();
        document.addEventListener('DOMContentLoaded', pushNativeSwitch);
        setTimeout(pushNativeSwitch, 2000);

        // What the last launch left in the file. Read whether or not the switch
        // is on right now: the reader turns logging on precisely because the
        // previous run ended badly, and the file is the only record of it.
        // Plugins.App may not be published at document start, so retry once.
        readFile();
        document.addEventListener('DOMContentLoaded', readFile);
        setTimeout(readFile, 2500);
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
     equivalent iOS entry, register a matching provider with ttsEngine, and
     drop the Bing entry: its /bingtts.js speaks through MediaSource with a
     WebM/Opus SourceBuffer, which WebKit on iOS does not support, so the
     provider fails at new MediaSource before any audio.

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

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

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
                var blob = base64ToBlob(encoded, (result && result.mime) || 'audio/wav');
                // Playback runs through a media element (see installPlayback),
                // and the site paces its sentences off the clip length. The
                // native side already knows that length, so it rides along on
                // the Blob instead of costing a WebAudio decode per sentence.
                if (result && typeof result.duration === 'number' && result.duration > 0) {
                    // A Blob that refuses the extra property is not worth failing
                    // the sentence over: playback falls back to the WebAudio
                    // decode, which is what used to happen for every clip.
                    try { blob.__stvDuration = result.duration; } catch (e) {}
                }
                return blob;
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
            // Zalo / FPT are brand names either way.
            var RENAMES = {
                'Sáng Tác Việt': '本站语音',
                'Viettelgroup TextToSpeech': 'Viettel 语音'
            };
            app.tts.engineList = function () {
                var list = originalList.call(this) || [];
                for (var i = 0; i < list.length; i++) {
                    if (list[i] && RENAMES[list[i].name]) { list[i].name = RENAMES[list[i].name]; }
                }
                // Bing TTS is dropped, not renamed: the site's /bingtts.js
                // plays its answer through MediaSource with a WebM/Opus
                // SourceBuffer, and WebKit ships neither MediaSource for
                // this use nor a WebM decoder, so every speak() dies at
                // new MediaSource (bingtts.js:318) before a byte is spoken.
                var kept = [];
                for (var k = 0; k < list.length; k++) {
                    if (list[k] && list[k].value === 'bing') { continue; }
                    kept.push(list[k]);
                }
                list = kept;
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
                        if (!stored) {
                            setting.provider = 'ios';
                            if (!setting.ios) { setting.ios = {}; }
                            if (typeof setting.set === 'function') { setting.set('provider', 'ios'); }
                            if (window.__stvDiag) {
                                window.__stvDiag.log('PATCH', 'tts provider default -> ios');
                            }
                            return;
                        }
                        // A choice of bing saved earlier can never play: heal
                        // it to the native provider the same way.
                        try {
                            var parsed = JSON.parse(stored);
                            if (parsed && parsed.provider === 'bing') {
                                setting.provider = 'ios';
                                if (!setting.ios) { setting.ios = {}; }
                                if (typeof setting.set === 'function') { setting.set('provider', 'ios'); }
                                if (window.__stvDiag) {
                                    window.__stvDiag.log('PATCH', 'tts provider bing -> ios (no MediaSource on iOS)');
                                }
                            }
                        } catch (e) {}
                    }).catch(function () {});
                } catch (e) {}
            }
            return true;
        }

        /**
         The site plays every sentence through WebAudio: playWithEq() hands the
         decoded buffer to webeq.setAudio(), which starts an
         AudioBufferSourceNode. On iOS that graph is the whole of the
         lock-screen failure, and it fails twice over.

         Locking the screen suspends the WebKit content process, so the buffer
         source stops mid-sentence. The suspension also leaves the AudioContext
         in a state it never comes back from: after unlocking, every later
         sentence is decoded and "played" into a graph that produces no sound at
         all, and the site never re-synthesises because the queued items still
         claim haveMp3. The device log shows both halves -- thirteen "The
         operation was aborted" rejections at the instant of the lock, then
         "reader TTS start" lines with no further speakToFile ever again, and
         killing the app was the only way out.

         A media element is the one audio path iOS keeps alive for a
         backgrounded app that declares UIBackgroundModes=audio: WebKit takes the
         background assertion for it, and nothing in this page ever asked for one
         (the WebEq graph is built around an Audio() with no src, and the site's
         mdAudio.play() keep-alive is a no-op on a sourceless element). So the
         playback step moves onto the element the engine already owns.

         Nothing else changes: the queue, the prefetch, the pacing and the
         sentence-advance all still run through the site's own code.
         */
        function installPlayback() {
            var engine = window.ttsEngine;
            if (!engine || typeof engine.playWithEq !== 'function') { return false; }
            if (engine.__stvTtsPlaybackInstalled) { return true; }
            engine.__stvTtsPlaybackInstalled = true;

            var webAudioPlay = engine.playWithEq;
            var webAudioDecode = engine.decodeAudio;

            // Our own clips carry their length, so the hot path never builds an
            // AudioBuffer for them. Anything else -- a network provider's mp3 --
            // still goes through the site's own decode.
            engine.decodeAudio = function (blob) {
                if (blob && typeof blob.__stvDuration === 'number' && blob.__stvDuration > 0) {
                    return Promise.resolve({ duration: blob.__stvDuration, __stvDurationStub: true });
                }
                return webAudioDecode.apply(this, arguments);
            };

            // The site's own media-element path, minus its rate == 1 shortcut:
            // play() delegates that case straight back to playWithEq, so calling
            // play() from here would recurse forever.
            engine.playWithEq = function (audioItem) {
                var blob = audioItem && audioItem.blob;
                if (!blob) {
                    // requestAudioInstant() resolves null once synthesis has
                    // failed three times, and the site still calls through.
                    note('TTS', 'playback skipped: this sentence produced no audio');
                    return;
                }
                this.currentAudio = audioItem;
                var url;
                try {
                    url = URL.createObjectURL(blob);
                } catch (e) {
                    note('ERR', 'playback could not build a blob URL: ' + e);
                    return;
                }
                var audio = this.audio;
                try {
                    audio.pause();
                    audio.currentTime = 0;
                    if (audio.src) { URL.revokeObjectURL(audio.src); }
                } catch (e) {}
                audio.src = url;
                if (this.playbackSetting && this.playbackSetting.rate) {
                    audio.playbackRate = this.playbackSetting.rate;
                }
                var started = audio.play();
                if (started && typeof started.catch === 'function') {
                    started.catch(function (e) {
                        note('ERR', 'the media element refused playback (' + e + '), back to WebAudio');
                        try { webAudioPlay.call(engine, audioItem); } catch (e2) {
                            note('ERR', 'the WebAudio fallback failed too: ' + e2);
                        }
                    });
                }
            };

            // If iOS suspended us anyway, the element comes back paused while the
            // reader still believes it is reading. Nudge it once on the way back
            // in -- gated on the site's own playing flag so a deliberate stop is
            // never overridden.
            function resumeIfItShouldBePlaying() {
                var live = window.ttsEngine;
                if (!live || !live.audio || !live.audio.src || !live.audio.paused) { return; }
                var player = window.app && window.app.tts && window.app.tts.player;
                if (!player || player.isPlaying !== true) { return; }
                note('TTS', 'playback was suspended while the reader kept reading -> resumed');
                try { live.audio.play(); } catch (e) {}
            }

            document.addEventListener('visibilitychange', function () {
                if (document.visibilityState === 'visible') { resumeIfItShouldBePlaying(); }
            });
            window.addEventListener('pageshow', resumeIfItShouldBePlaying);

            note('PATCH', 'TTS playback moved to the media element (survives a screen lock)');
            return true;
        }

        var timer = setInterval(function () {
            var providerReady = installProvider();
            var listReady = installEngineList();
            // Deliberately not part of the exit condition: the playback patch
            // needs ttsEngine.playWithEq, which the real /stv.tts.js always has
            // but a stub may not, and a missing one must not keep this timer
            // alive for its full three minutes.
            installPlayback();
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
            + '.stv-bookgrid4 > * { max-width: none !important; }'
            // Long-pressing a book cell opens the site's own menu (ui.hold ->
            // app.context.current, page-vip:3901/3977/4000/4027), and the
            // gesture was also selecting text: the menu appears under the
            // finger and iOS carries the press on into the new node, so
            // "长按小说名字会弹出选项，但会默认选中文字". app.v2.css only ever
            // sets the unprefixed `user-select` (body:28, .booksquare:89,
            // .bookrow:156) and never the WebKit property or the callout, which
            // is the property that actually suppresses the iOS selection and
            // magnifier. Scoped to the list cells and the menu itself: the
            // comment and reader text has to stay selectable.
            + '.booksquare, .booksquarecont, .booksquarecont > .booksquare,'
            + ' .bookrow, .bookrowcont, .bookrowext'
            + ' { -webkit-user-select: none; user-select: none;'
            + ' -webkit-touch-callout: none; }'
            + '.contextmenu, .contextmenu .contextmenuitem,'
            + ' .mixedcontextmenu, .mixedcontextmenu > div'
            + ' { -webkit-user-select: none; user-select: none;'
            + ' -webkit-touch-callout: none; }';

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
        // In flight, as opposed to done. The two are separate so a refusal or a
        // transient keychain error does not latch "already restored" and cost the
        // whole page load its backup.
        var restoreStarted = false;
        var mirrorFailed = {};
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
            if (restored || restoreStarted) { return true; }
            restoreStarted = true;
            plugin.settingsRestore({}).then(function (result) {
                restored = true;
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
                // Covers a rejected settingsRestore (the native origin guard, or a
                // transient keychain error) and a failure inside the restore
                // chain. Deliberately not latched: the interval above retries, so
                // one refusal does not cost the whole page load its backup. A
                // retry is idempotent because a key the store already holds is
                // kept rather than rewritten.
                restoreStarted = false;
                restored = false;
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
                if (call && typeof call.then === 'function') {
                    call.then(function () {
                        delete mirrorFailed[key];
                    }, function (error) {
                        // Once per key, and never silently: the native side
                        // refuses keys outside its allow-list and values over its
                        // size cap, and a swallowed rejection would look exactly
                        // like "this setting was never backed up" on device.
                        if (mirrorFailed[key]) { return; }
                        mirrorFailed[key] = true;
                        note('ERR', 'keychain backup refused ' + key + ': ' + error);
                    });
                }
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

     The repairs, all driven by the server's own answer rather than a hard-coded
     host list:

       1. `bestDomain()` never returns a mirror that already answered code 7.
       2. a code 7 answer is intercepted on the way out of
          `app.reader.getContent` -- the single funnel every chapter goes through
          (chapterdisplay.js:788 / :1812 / :3680). The mirror that produced it is
          banned, the cached chapter key is dropped (it was issued by the mirror
          being left, and `getKey()` would otherwise keep reusing it), and the
          chapter is fetched again.
       3. a mirror that fails to deliver at all is banned too, on the way out of
          `app.net.get`/`app.net.post` and of `getContent`. Code 7 was the only
          failure a remembered mirror used to react to, so the mirror the app
          remembered kept winning while it stalled: the 2026-09-23 log is four
          10s timeouts in a row on the same `sajax=getchapterlist` and a chapter
          list that never arrived, with the reader pinned to `.app` for the whole
          session. A fresh probe that cannot reach the remembered mirror drops it
          as well, and a mirror the reader picked by hand in the site's own 线路
          row outranks the remembered one -- in that log two taps on that row
          (23:14:14, 23:14:16) changed nothing at all.

     A ping comparison deliberately plays no part in any of that. The mirror that
     wins the site's race is routinely the one that answers code 7 to every
     chapter (`scripts/test-site-patch.js` builds exactly that pair), so "another
     mirror pings faster" is not evidence that the remembered one is bad.

     The alert only survives if every mirror refuses.

     The repairs have to be in place **before the site's first request**, not
     merely early: the host of every `app.net` call is resolved by
     `fullUrl()`/`bestDomain()` (`app.v2.js:110-129`, `:1136-1191`), and those run
     in the same turn the managers are created. The install is therefore driven by
     accessors on `window.app`, `app.net` and the two managers -- see the note at
     the bottom of this block for why a poll lost that race on the device.

     `fullUrl()` resolves that host from three places and only two of them are the
     managers: the page origin, `window.STV_SERVER` (`app.v2.js:1` hard-codes
     `"https://sangtacviet.app"`) when the site believes the page is local, and
     `app.config.ux.app_domain` when the reader picked a line. Which one won is
     not visible in a device log, so the block reports all three -- plus the
     ranking the site measured -- once per launch.
     */
    static let domainFailover = """
    (function () {
        if (window.__stvDomainFailoverInstalled) { return; }
        window.__stvDomainFailoverInstalled = true;

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        var banned = {};
        var MAX_BANS = 3;
        // Code 7 refetches this read has already spent. Kept apart from the ban
        // list: a mirror banned for stalling must not eat the retry budget that
        // exists for the mirror that answers code 7.
        var code7Seen = 0;
        var noted = {};

        function manager() {
            var app = window.app;
            return (app && app.net && app.net.networkManager) || null;
        }

        function xhrManager() {
            var app = window.app;
            return (app && app.net && app.net.networkManagerXHR) || null;
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

        function pick(list, siteChoice) {
            for (var i = 0; i < list.length; i++) {
                if (!banned[list[i]]) { return list[i]; }
            }
            return siteChoice;
        }

        function ban(domain, why) {
            if (!domain || banned[domain]) { return false; }
            banned[domain] = true;
            note('DOMAIN', 'mirror ' + domain + ' banned: ' + why);
            return true;
        }

        // ---- remembered working mirror -----------------------------------
        //
        // The site races its mirrors on every launch and takes the cheapest
        // ping, and `verifyDomain()` only probes /warp.php -- so the mirror that
        // wins the race is routinely the one that answers `code 7` to every
        // readchapter (1.2s per attempt, then the ban/retry dance above). The
        // mirror that actually returned a chapter last time is the better first
        // guess, so it is remembered and used until it expires or fails.
        //
        // The race still runs: the site calls checkDomains() itself, and this
        // entry only ever short-circuits the *choice*, never the probing. A
        // remembered mirror that is not one of the site's own mirrors is ignored,
        // so a tampered localStorage entry cannot redirect the app.
        var GOOD_KEY = 'stv.domain.good';
        var GOOD_TTL = 6 * 60 * 60 * 1000;

        // Parsed once and kept in memory. `bestDomain()` runs on every request
        // the site makes, and a localStorage read plus a JSON.parse on that path
        // is exactly the per-request cost this block exists to remove.
        var goodEntry = null;
        var goodLoaded = false;

        function writeGood() {
            try {
                if (window.localStorage && goodEntry) {
                    window.localStorage.setItem(GOOD_KEY, JSON.stringify(goodEntry));
                }
            } catch (e) {}
        }

        function readGood() {
            if (!goodLoaded) {
                goodLoaded = true;
                var raw = '';
                try {
                    raw = window.localStorage ? (window.localStorage.getItem(GOOD_KEY) || '') : '';
                } catch (e) { raw = ''; }
                if (raw) {
                    var parsed = null;
                    try { parsed = JSON.parse(raw); } catch (e) { parsed = null; }
                    if (parsed && typeof parsed.name === 'string' && parsed.name
                        && typeof parsed.at === 'number') {
                        goodEntry = parsed;
                    }
                }
            }
            if (!goodEntry) { return null; }
            if ((Date.now() - goodEntry.at) > GOOD_TTL) {
                goodEntry = null;
                return null;
            }
            return goodEntry;
        }

        function rememberGood(domain) {
            if (!domain || banned[domain]) { return; }
            if (goodEntry && goodEntry.name === domain) {
                // Keep it alive while it keeps working, but not with a write per
                // chapter: ten minutes of slack is plenty.
                if ((Date.now() - goodEntry.at) > 600000) {
                    goodEntry.at = Date.now();
                    writeGood();
                }
                return;
            }
            goodEntry = { name: domain, at: Date.now() };
            goodLoaded = true;
            writeGood();
            note('DOMAIN', 'remembered working mirror ' + domain);
        }

        function forgetGood(domain) {
            if (!goodEntry || (domain && goodEntry.name !== domain)) { return; }
            goodEntry = null;
            try {
                if (window.localStorage) { window.localStorage.removeItem(GOOD_KEY); }
            } catch (e) {}
        }

        // ---- the ways a remembered mirror loses -------------------------------
        //
        // A ping comparison cannot decide this. The mirror that wins the site's
        // race is routinely the one that answers code 7 to every chapter
        // (`scripts/test-site-patch.js` builds exactly that pair: 100ms answering
        // code 7, 400ms serving the chapter), so "something else pings faster" is
        // not evidence that the remembered mirror is bad.
        //
        // What is evidence:
        //   * the site re-probed the remembered mirror and it did not answer
        //     (status dead/timeout) -- a fresh measurement, not a ranking;
        //   * the reader picked a line by hand in the site's own 线路 row;
        //   * a request through it produced no payload at all, see `failed()`.
        function rememberedGone(mgr, name) {
            var known = mgr && mgr.domains ? mgr.domains : [];
            for (var i = 0; i < known.length; i++) {
                var d = known[i];
                if (d && d.name === name) { return d.status !== 'alive'; }
            }
            // No entry is "no news", not "dead": `checkDomains()` clears `domains`
            // and pushes each answer as it lands (app.v2.js:1060-1091), so the
            // remembered mirror is missing from the list for the first seconds of
            // every launch.
            return false;
        }

        function preferredDomain() {
            var app = window.app;
            var ux = app && app.config ? app.config.ux : null;
            var v = ux ? ux.app_domain : '';
            v = String(v === null || v === undefined ? '' : v);
            return v === 'auto' ? '' : v;
        }

        function pageOrigin() {
            try {
                return String((window.location && window.location.origin) || '');
            } catch (e) { return ''; }
        }

        // Which of `fullUrl()`'s three host sources the app actually used is not
        // visible in the device log, and the 2026-09-23 one shows every data
        // request landing on .app for three minutes straight while the site's own
        // probe ranked .com 4.6x faster. `fullUrl()` (app.v2.js:110-130) takes the
        // page origin when the site believes it is alive, `window.STV_SERVER`
        // (app.v2.js:1 hard-codes "https://sangtacviet.app") when the page looks
        // local, and a manager otherwise. One line per launch settles it.
        var routeLogged = false;

        function routeNote(label) {
            if (routeLogged) { return; }
            routeLogged = true;
            var mgr = xhrManager();
            var alive = 'unknown';
            try {
                if (mgr && typeof mgr.isDomainAlive === 'function') {
                    alive = mgr.isDomainAlive(pageOrigin()) ? 'yes' : 'no';
                }
            } catch (e) { alive = 'unknown'; }
            var server = '';
            try { server = String(window.STV_SERVER || ''); } catch (e) { server = ''; }
            note('DOMAIN', label + ' route: page=' + pageOrigin() + ' alive=' + alive
                + ' STV_SERVER=' + server
                + ' app_domain=' + (preferredDomain() || 'auto'));
        }

        // The ranking the site just measured, once per distinct answer. Without it
        // the log cannot say whether a mirror is slow, dead, or never probed.
        var rankedSeen = {};

        function rankNote(mgr, label) {
            var known = mgr && mgr.domains ? mgr.domains : [];
            if (!known.length) { return; }
            var parts = [];
            for (var i = 0; i < known.length; i++) {
                var d = known[i];
                if (d && typeof d.name === 'string') {
                    parts.push(d.name + '=' + d.status + '/' + d.ping + 'ms');
                }
            }
            parts.sort();
            var sig = parts.join(' ');
            if (rankedSeen[label] === sig) { return; }
            rankedSeen[label] = sig;
            note('DOMAIN', label + ' ranked ' + sig);
        }

        function usedHost() {
            if (goodEntry && !banned[goodEntry.name]) { return goodEntry.name; }
            var mgr = manager() || xhrManager();
            var url = mgr && typeof mgr.bestDomain === 'function' ? mgr.bestDomain() : '';
            return origin(url);
        }

        function message(error) {
            return error && error.message ? String(error.message) : String(error);
        }

        // A mirror that answered with an HTTP status is not the problem: the
        // request reached it and the *site* returned an error --
        // `mobile/booklist.php?method=following` answers 500 in the 2026-09-23
        // log, and `getCapacitor` turns any non-2xx into a rejection
        // (app.v2.js:1175-1177). Only a failure to reach or to finish counts,
        // which is what "Network error" / "Request timed out" / no payload means.
        function reachFailure(error) {
            return message(error).indexOf('HTTP error:') < 0;
        }

        // A mirror that cannot deliver a payload is not a mirror. Until now the
        // only way one lost was answering code 7, and a stalled mirror answers
        // nothing: the 2026-09-23 log is four 10s timeouts in a row on the same
        // `sajax=getchapterlist` and a chapter list that never arrived. The failed
        // request is never replayed here -- a POST that already changed something
        // must not run twice -- the site's own retries are what lands on the next
        // mirror (`app.net.get` retries 3x, app.v2.js:702-712; `getContent2`
        // retries once, app.v2.read.js:570-598).
        function failed(domain, why) {
            if (!domain || banned[domain]) { return false; }
            ban(domain, why);
            forgetGood(domain);
            return true;
        }

        // Only a request aimed at one of the site's own mirrors can ban one;
        // `fullUrl()` leaves external URLs alone.
        function stvRequest(url) {
            var s = String(url === undefined || url === null ? '' : url);
            if (s.indexOf('http') !== 0) { return true; }
            var mgr = xhrManager();
            try {
                if (mgr && typeof mgr.isStvDomain === 'function') { return !!mgr.isStvDomain(s); }
            } catch (e) { return false; }
            return false;
        }

        function patchOne(net, name) {
            var original = net[name];
            if (typeof original !== 'function' || original.__stvFailoverWrapped) {
                return false;
            }
            var wrapper = function (url) {
                var blame = stvRequest(url) ? usedHost() : '';
                var result = original.apply(this, arguments);
                if (!result || typeof result.then !== 'function') { return result; }
                return result.then(function (data) {
                    if (data === undefined || data === null) {
                        failed(blame, name + ' answered with no payload');
                    }
                    return data;
                }, function (error) {
                    if (reachFailure(error)) {
                        failed(blame, name + ' failed: ' + message(error));
                    }
                    throw error;
                });
            };
            wrapper.__stvFailoverWrapped = true;
            net[name] = wrapper;
            return true;
        }

        // `app.net.get`/`app.net.post` are the funnel for everything that is not
        // the reader's own chapter request, so a stalled mirror is caught here for
        // the chapter list too. Wrapped on the function, not on `app.net`: the site
        // creates `app.net` as `{}` one statement before it adds `get`
        // (app.v2.js:695-696), so an object-level "already patched" flag would lock
        // in a wrapper that wrapped nothing.
        function patchNet(app) {
            if (!app || !app.net) { return false; }
            var a = patchOne(app.net, 'get');
            var b = patchOne(app.net, 'post');
            if (a || b) { note('DOMAIN', 'transport failover installed'); }
            // Asked of the slots, not of this pass: after the first wrap both
            // `patchOne` calls report false every time, and `install()`'s `&&`
            // chain would then read "not wired" forever.
            return wrappedNet(app.net, 'get') && wrappedNet(app.net, 'post');
        }

        function wrappedNet(net, name) {
            return typeof net[name] === 'function' && net[name].__stvFailoverWrapped === true;
        }

        function patchBestDomain(mgr, label) {
            if (!mgr || typeof mgr.bestDomain !== 'function') { return false; }
            if (mgr.__stvFailoverInstalled) { return true; }
            mgr.__stvFailoverInstalled = true;
            var original = mgr.bestDomain;
            mgr.bestDomain = function () {
                var siteChoice = original.apply(this, arguments);
                var list = candidates(this);
                rankNote(this, label);
                routeNote(label);
                // The reader picked this line by hand. The site honours it only
                // while that mirror answers /warp.php (app.v2.js:937-943,
                // :1040-1046), and that answer is the newest measurement there is,
                // so satisfying it here is what makes the site's own 线路 row do
                // anything at all -- the 2026-09-23 log has two taps on it at
                // 23:14:14/23:14:16 and every later request still going to .app.
                // Not gated on `siteChoice` agreeing: `original` cannot see the
                // preference until its own probe of that mirror has landed, which
                // is exactly the window the remembered mirror would win instead.
                var pref = preferredDomain();
                if (pref && !banned[pref] && list.indexOf(pref) >= 0
                    && !rememberedGone(this, pref)) {
                    if (goodEntry && goodEntry.name !== pref) { forgetGood(goodEntry.name); }
                    if (!noted['explicit:' + pref]) {
                        noted['explicit:' + pref] = true;
                        note('DOMAIN', label + ' explicit domain ' + pref);
                    }
                    return pref;
                }
                var good = readGood();
                if (good && !banned[good.name] && list.indexOf(good.name) >= 0) {
                    if (!rememberedGone(this, good.name)) {
                        if (!noted[good.name]) {
                            noted[good.name] = true;
                            note('DOMAIN', label + ' using remembered mirror ' + good.name);
                        }
                        return good.name;
                    }
                    note('DOMAIN', label + ' remembered mirror ' + good.name
                        + ' did not answer the fresh probe, dropping it');
                    forgetGood(good.name);
                }
                var chosen = pick(list, siteChoice);
                if (chosen && chosen !== siteChoice && !noted[siteChoice]) {
                    noted[siteChoice] = true;
                    note('DOMAIN', label + ' bestDomain ' + siteChoice + ' -> ' + chosen);
                }
                return chosen;
            };
            note('DOMAIN', label + ' mirror failover installed');
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
                // new mirror (`code7Seen` is what bounds the walk) or gives up and
                // hands the code 7 back to the site.
                function attempt() {
                    var mgr = manager();
                    var used = mgr && mgr.bestDomain ? origin(mgr.bestDomain()) : '';
                    return Promise.resolve(original.apply(self, args)).then(function (data) {
                        var code = data ? String(data.code) : '';
                        if (code === '7' && code7Seen < MAX_BANS) {
                            code7Seen++;
                            if (!ban(used, 'readchapter answered code 7')) { return data; }
                            forgetGood(used);
                            if (app.reader) { app.reader.cachekey = null; }
                            note('DOMAIN', 'refetching ' + h + '/' + i + ' chapter ' + c
                                + ' after code 7');
                            return attempt();
                        }
                        if (!data) {
                            // `getContent2` swallows two transport failures and
                            // answers null (app.v2.read.js:570-599), so this is the
                            // only place a stalled mirror becomes visible to the
                            // reader. A transport failure is not remembered either
                            // way -- there is no payload to trust.
                            failed(used, 'readchapter returned no payload');
                            return data;
                        }
                        if (code !== '7') { rememberGood(used); }
                        return data;
                    }, function (error) {
                        if (reachFailure(error)) {
                            failed(used, 'readchapter failed: ' + message(error));
                        }
                        throw error;
                    });
                }
                return attempt();
            };
            note('DOMAIN', 'readchapter failover installed');
            return true;
        }

        // ---- installed in the turn the site creates them ---------------------
        //
        // A poll cannot win this race, and the device log shows it losing. The
        // site builds both managers and can spend one in the same synchronous
        // turn (`app.v2.js:990-991` and `:1124-1125`), so with a 50ms interval the
        // first requests of a launch resolve their host through the *unpatched*
        // `bestDomain()`: `this.domains` is empty while `checkDomains()` is still
        // in flight, so it answers `defaultDomains[0]` -- and `fullUrl()`
        // (`app.v2.js:110-129`) plus `networkManager.bestDomain()` in
        // `getCapacitor`/`postCapacitor` (`:1136-1191`) both route through it. In
        // the 2026-09-23 device log that is the launch's first data requests
        // going to the canonical host (`booklist.php?method=history`, 4034ms)
        // while the first call that saw the remembered mirror came two seconds
        // later and used the fast one for the rest of the session.
        //
        // `window.app` is created by `var app = {` in the shell's own inline
        // script, and `app.net` by `app.v2.js:695` -- both are plain property
        // assignments, so an accessor installed at document start sees each
        // object in the turn it is made and hands it to the same idempotent
        // wrapper the timer used to install. Nothing here reads a site object
        // before the site creates it.
        function install() {
            var a = patchBestDomain(manager(), 'networkManager');
            var b = patchBestDomain(xhrManager(), 'networkManagerXHR');
            var c = patchContent();
            var d = patchNet(window.app);
            return a && b && c && d;
        }

        function watchProperty(host, name, onSet) {
            if (!host || (typeof host !== 'object' && typeof host !== 'function')) {
                return false;
            }
            var current;
            try { current = host[name]; } catch (e) { current = undefined; }
            try {
                Object.defineProperty(host, name, {
                    configurable: true,
                    enumerable: true,
                    get: function () { return current; },
                    set: function (next) { current = next; onSet(next); }
                });
            } catch (e) {
                return false;
            }
            if (current !== undefined && current !== null) { onSet(current); }
            return true;
        }

        function watchManagers(net) {
            if (!net) { return; }
            watchProperty(net, 'networkManager', function (value) {
                patchBestDomain(value, 'networkManager');
            });
            watchProperty(net, 'networkManagerXHR', function (value) {
                patchBestDomain(value, 'networkManagerXHR');
            });
        }

        function watchNet(app) {
            if (!app) { return; }
            patchNet(app);
            watchProperty(app, 'net', function (net) {
                patchNet(app);
                watchManagers(net);
            });
        }

        // Read the remembered mirror now rather than on the first `bestDomain()`:
        // that call is on the request path, and the parse belongs at document
        // start. This runs even when the trap is given up below, because the
        // manager wrapper needs the entry either way.
        readGood();

        // The accessor is given up rather than the site. `var app = {` is a plain
        // assignment, which is exactly what lets a document-start accessor see it
        // (`HasOwnProperty` is true, so the declaration is a no-op and the
        // assignment goes through `[[Set]]`) -- but if an engine refused that
        // declaration, the shell's own inline script would stop right there and the
        // site would never boot, with nothing in the log to say why. So: if the
        // document has finished loading and `app` still does not exist, the trap is
        // dropped for good and the page is reloaded once. The next launch falls back
        // to the timer alone, which is the pre-2026-09-23 behaviour.
        var TRAP_OFF_KEY = 'stv.domain.trap.off';
        var trapOff = false;
        try {
            trapOff = window.localStorage.getItem(TRAP_OFF_KEY) === '1';
        } catch (e) { trapOff = false; }

        var trapArmed = false;
        if (!trapOff) {
            trapArmed = watchProperty(window, 'app', watchNet);
            watchNet(window.app);
            if (trapArmed) {
                var checks = 0;
                var trapWatchdog = setInterval(function () {
                    checks++;
                    if (window.app || checks > 60) { clearInterval(trapWatchdog); return; }
                    // A slow load is not a broken one: only a document that got all
                    // the way to `complete` without ever creating `app` counts.
                    if (!document || document.readyState !== 'complete') { return; }
                    clearInterval(trapWatchdog);
                    var wrote = false;
                    try {
                        window.localStorage.setItem(TRAP_OFF_KEY, '1');
                        wrote = true;
                    } catch (e) { wrote = false; }
                    // Without a persisted flag the reload would just loop.
                    if (!wrote) { return; }
                    note('DOMAIN', 'app never appeared: dropping the document-start trap and reloading');
                    if (typeof location !== 'undefined' && location
                        && typeof location.reload === 'function') {
                        location.reload();
                    }
                }, 2000);
            }
        }

        // Belt and braces for an assignment the accessors cannot see -- a manager
        // replaced with `Object.defineProperty`, or one created on an object the
        // site builds some other way. `patchContent` has no property of its own to
        // hang off (`app.reader.getContent` is one method on another object the
        // site assembles), so it stays a poll.
        var attempts = 0;
        var timer = setInterval(function () {
            attempts++;
            install();
            if (attempts > 40) { clearInterval(timer); }
        }, 250);
    })();
    """

    // MARK: - Book-detail action toggles (bookmark, like)

    /**
     Both buttons on the detail page are one-way in the site's own client:

       * bookmark -- `app.api.bookmark` only ever calls `ajax=addbookmark`, and
         there is no un-bookmark action anywhere in app.v2.js. Tapping the
         button on an already-bookmarked book just re-adds it, which is what
         "点击书签就取消不了" describes.
       * like -- the endpoint the reader needs already exists (`app.api.unlike`,
         app.v2.js:4917), but nothing on the detail page calls it: `.likebook`
         is bound to `app.api.likeBook`, which only runs `ajax=like`
         (page-vip:4220, app.v2.js:4914). A second tap therefore re-likes the
         book and "点赞后取消没反应" is what the reader sees.

     Bookmark: when the book is already bookmarked (the site marks the button
     `.active` from `querybookmarkstatus`) the plausible removal actions are
     tried and each answer is reported to the panel, so the working endpoint --
     if one exists -- is identified from the device instead of guessed. The
     first action answering code 100 wins.

     Like: the toggle asks `querylikestatus` -- the endpoint whose key is the
     same `type:id` pair that `like()` and `unlike()` take -- and verifies the
     answer after the call instead of trusting it. Reading `queryBookExtStatus`
     first (the previous revision) was the bug: it answers with the book's own
     record, so `status.like` stays true after a successful unlike and every tap
     took the removal path. The count next to the button is nudged here because
     `updateBookPage` only rewrites the `.active` class; bookinfo.php re-sends
     the real number when the page is reopened, so a drift cannot survive a
     reload.

     The third action in the same row is 关注, and it has the same "no answer ever
     arrives" problem for a different reason: both `app.api.follow` and
     `app.api.bookmark` pass their result handler as the second argument of
     `app.net.get`, which is `force` -- so the handler never runs and neither the
     toast nor the list refresh the site wrote can happen. On the 关注 list's
     long-press menu there is no other feedback at all, which is why a follow that
     the server refused and one it accepted look identical. See `attachFollow`
     below: the calls are untouched, the outcome is reported and verified.
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

        function applyLiked(state) {
            var nodes = document.querySelectorAll('.likebook');
            for (var i = 0; i < nodes.length; i++) {
                if (!nodes[i].classList) { continue; }
                if (state) { nodes[i].classList.add('active'); }
                else { nodes[i].classList.remove('active'); }
            }
        }

        /**
         Scoped to the counters inside a `.likebook` on purpose: the community
         boards put a bare `.liked` counter inside every post's own like button
         (page-vip:1132), and bumping those while liking a book would be a
         visible lie. `parseInt` rather than a digit regex, so this block stays
         free of the backslashes check-ios-shim.js rejects.
         */
        function bumpLikedCount(delta) {
            var books = document.querySelectorAll('.likebook');
            for (var i = 0; i < books.length; i++) {
                var nodes = books[i].querySelectorAll('.liked');
                for (var j = 0; j < nodes.length; j++) {
                    var current = parseInt(String(nodes[j].textContent).trim(), 10);
                    if (isNaN(current)) { continue; }
                    var next = current + delta;
                    if (next < 0) { next = 0; }
                    nodes[j].textContent = String(next);
                }
            }
        }

        function attachBookmark() {
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
                var self = this;
                var args = arguments;
                if (bookmarked()) {
                    var book = target(bookdata);
                    if (!book) {
                        note('BOOKMARK', 'bookmarked, but the tapped book could not be resolved; '
                            + 'falling back to add');
                        return original.apply(self, args);
                    }
                    return remove(book);
                }
                // The add path's confirmation is what the site wrote and never
                // ran: its handler is passed as `app.net.get`'s `force` argument,
                // and its text is the *follow* message -- see the note below this
                // function.
                return Promise.resolve(original.apply(self, args)).then(function (down) {
                    note('BOOKMARK', 'addbookmark -> code ' + codeOf(down) + ' raw='
                        + String(JSON.stringify(down)).slice(0, 200));
                    if (down && down.code == 100) {
                        rerenderList('bookmarked');
                        if (app.toast) { app.toast('已加入书签'); }
                    }
                    return down;
                });
            };
            note('BOOKMARK', 'bookmark toggle installed');
            return true;
        }

        // Did *I* like this book? `querylikestatus` is the only endpoint whose
        // key space matches like()/unlike() -- `${type}:${id}`, the same pair
        // app.socialpost.queryLikeStatus builds for a post (app.v2.js:5258) -- so
        // the read and the write finally speak about the same object. `liked:
        // null` means "the site would not say" (signed out, or the call failed)
        // and is never turned into a guess.
        var likedState = {};

        /**
         The rows behind the answer are returned as well as the answer: when a
         cancellation does not stick, the row ids are the only other key the
         unlike endpoint could be deleting by, and guessing one is not an option.
         */
        function readLiked(book) {
            var api = window.app.api;
            var key = book.host + ':' + book.id;
            if (typeof api.queryLike === 'function') {
                return Promise.resolve(api.queryLike([key])).then(function (list) {
                    var entries = list && list.length ? list : [];
                    var rows = [];
                    var liked = false;
                    for (var i = 0; i < entries.length; i++) {
                        var objectid = entries[i] && entries[i].objectid !== undefined
                            ? String(entries[i].objectid) : '';
                        if (!objectid || objectid === String(book.id)
                            || objectid === key) {
                            liked = true;
                            rows.push(entries[i]);
                        }
                    }
                    return { liked: liked, source: 'querylikestatus', rows: rows,
                             raw: String(JSON.stringify(entries)).slice(0, 200) };
                }, function (error) {
                    return { liked: null, source: 'querylikestatus', rows: [],
                             raw: 'rejected: ' + error };
                });
            }
            if (typeof api.queryBookExtStatus !== 'function') {
                return Promise.resolve({ liked: null, source: 'none', rows: [], raw: '' });
            }
            return Promise.resolve(api.queryBookExtStatus(book)).then(function (status) {
                return { liked: status ? !!status.like : null,
                         source: 'querybookmarkstatus', rows: [],
                         raw: String(JSON.stringify(status)).slice(0, 200) };
            }, function (error) {
                return { liked: null, source: 'querybookmarkstatus', rows: [],
                         raw: 'rejected: ' + error };
            });
        }

        function attachLike() {
            var app = window.app;
            if (!app || !app.api || typeof app.api.likeBook !== 'function'
                || typeof app.api.unlike !== 'function') { return false; }
            if (app.api.__stvLikeWrapped) { return true; }
            app.api.__stvLikeWrapped = true;
            var api = app.api;
            var originalLike = api.likeBook;

            // The `.active` class has exactly one writer, app.api.updateBookPage
            // (app.v2.js:4932), and it asks the very call this block just proved
            // is not the reader's state: left alone it re-lights the thumbs-up a
            // moment after every verified unlike, which looks exactly like "the
            // cancellation did nothing". Hand it the verified answer instead of
            // arguing with it over the class list -- patched for the duration of
            // one call, restored the moment updateBookPage has taken the reply.
            if (typeof api.updateBookPage === 'function' && !api.__stvPageWrapped) {
                api.__stvPageWrapped = true;
                var originalPage = api.updateBookPage;
                api.updateBookPage = function (p, bookinfo) {
                    var info = bookinfo;
                    if (!info && p) {
                        info = p.data || (p.q && p.q('div') ? p.q('div').data : null);
                    }
                    var key = info && info.host && info.id
                        ? info.host + '/' + info.id : null;
                    if (!key || likedState[key] === undefined
                        || typeof api.queryBookExtStatus !== 'function') {
                        return originalPage.apply(this, arguments);
                    }
                    var verified = likedState[key];
                    var originalStatus = api.queryBookExtStatus;
                    var restored = false;
                    api.queryBookExtStatus = function () {
                        return Promise.resolve(originalStatus.apply(api, arguments))
                            .then(function (status) {
                                if (status) { status.like = verified; }
                                return status;
                            });
                    };
                    try {
                        return originalPage.apply(this, arguments);
                    } finally {
                        setTimeout(function () {
                            if (!restored) {
                                restored = true;
                                api.queryBookExtStatus = originalStatus;
                            }
                        }, 0);
                    }
                };
            }

            api.likeBook = function (bookdata) {
                var book = target(bookdata);
                if (!book) {
                    note('LIKE', 'the tapped book could not be resolved; falling back to like');
                    return originalLike.apply(this, arguments);
                }
                var key = book.host + '/' + book.id;
                // Logged on both paths on purpose: the fifteenth device log held
                // no like tap at all, so this one has to say which question was
                // asked, what the server answered, and what the button did next.
                return readLiked(book).then(function (state) {
                    note('LIKE', key + ' status ' + state.source + ' liked='
                        + state.liked + ' raw=' + state.raw);
                    if (state.liked) { return remove(book); }
                    return add(book);
                });

                function add(book) {
                    return Promise.resolve(originalLike.call(api, book)).then(function (down) {
                        note('LIKE', 'liked ' + key + ' -> code ' + (down && down.code));
                        if (down && down.code == 100) {
                            likedState[key] = true;
                            applyLiked(true);
                            bumpLikedCount(1);
                        }
                        return down;
                    });
                }

                /**
                 The site's own unlike takes the *object* id (app.v2.js:5239,
                 socialpost.likeBtnEvent), and that is the form the sixteenth
                 round sent: app.api.unlike(type, id) posts
                 ajax=unlike&type=&id= (app.v2.js:4917-4931).

                 The 2026-09-23 logs answer both candidate keys, so there is
                 nothing left to guess at. The object id is accepted
                 ({"status":"success","code":100}) and deletes nothing -- the
                 same two rows come back a second later, byte for byte. Each
                 row id is refused outright: {"text":"Không tìm thấy lịch sử.",
                 "code":101}, "no history found", which says this endpoint looks
                 its id up in the reading history, not in the like table. The
                 site itself only ever unlikes community topics (app.v2.js:5239
                 is unlike's only caller), so a book unlike has no working
                 contract to follow.

                 The row-id ladder is therefore gone: it cost two extra
                 asynchronous requests and about two seconds before the same
                 answer. One attempt in the documented form, one verification,
                 and the honest result -- a failure leaves the button lit and
                 says so instead of pretending.
                 */
                function attempt(label) {
                    return Promise.resolve(api.unlike(book.host, String(book.id)))
                        .then(function (down) {
                            note('LIKE', 'unlike(' + label + ') ' + key + ' -> code '
                                + (down && down.code) + ' raw='
                                + String(JSON.stringify(down)).slice(0, 200));
                            return down;
                        });
                }

                function verify(label) {
                    return readLiked(book).then(function (state) {
                        note('LIKE', key + ' after ' + label + ': ' + state.source
                            + ' liked=' + state.liked + ' raw=' + state.raw);
                        return state;
                    });
                }

                function report(state) {
                    if (state.liked) {
                        likedState[key] = true;
                        applyLiked(true);
                        note('LIKE', 'the site did not delete the like for ' + key
                            + '; the button stays as the site has it');
                        if (app.toast) { app.toast('站点不支持取消这个赞'); }
                        return false;
                    }
                    likedState[key] = false;
                    applyLiked(false);
                    bumpLikedCount(-1);
                    note('LIKE', 'unliked ' + key);
                    if (app.toast) { app.toast('已取消点赞'); }
                    return true;
                }

                function remove(book) {
                    note('LIKE', key + ' is liked; unliking');
                    return attempt('unlike(object)').then(function (down) {
                        if (!(down && down.code == 100)) {
                            note('LIKE', 'the server refused the unlike for ' + key
                                + '; the button is left as the site drew it');
                            return down;
                        }
                        return verify('unlike(object)').then(function (state) {
                            report(state);
                            return down;
                        });
                    }, function (error) {
                        note('ERR', 'unlike failed for ' + book.host + '/' + book.id
                            + ': ' + error);
                        return null;
                    });
                }
            };
            note('LIKE', 'like toggle installed');
            return true;
        }

        // ---- the site's own write actions swallow their answer ----------------
        //
        // `app.api.bookmark` (app.v2.js:4839) and `app.api.follow` (app.v2.js:4856)
        // hand their result handler to `app.net.get` as its SECOND argument, and
        // that parameter is `force` (app.v2.js:696) -- not a callback -- so the
        // handler is dead code. A follow or a bookmark can therefore succeed with
        // no toast and no list refresh at all, and a refusal looks exactly the
        // same. The device log has a refusal: the 关注 list's long-press menu wires
        // its 删除 item to `app.api.follow` (app.v2.js:2685-2686 -- the site has no
        // un-follow endpoint anywhere), the book was already in that list
        // (`booklist.php?method=following` answered with exactly that one book 11
        // seconds before the tap), and the server answered
        // {"status":"success","code":400} to the duplicate.
        //
        // The requests are left exactly as the site makes them. What is added is
        // the report, the verification against the endpoint that owns the reader's
        // state (`ajax=querybookmarkstatus`, whose answer carries `follow` and
        // `bookmark`), and a truthful toast -- so a menu item that cannot do what
        // its label says says so instead of doing nothing.
        function codeOf(down) {
            if (!down || down.code === undefined || down.code === null) { return 'none'; }
            return String(down.code);
        }

        /**
         The site's own refresh target (`q("#mainview div[view=bookfollowing]")`,
         app.v2.js:4858). Written as a walk instead of a descendant selector because
         the stub DOM that verifies these blocks has no descendant combinators, and
         the answer on the device is the same one: the `div[view=...]` under
         #mainview. An element outside #mainview is deliberately not accepted.
         */
        function listView(name) {
            var nodes = document.querySelectorAll('div[view=' + name + ']');
            for (var i = 0; i < nodes.length; i++) {
                var parent = nodes[i].parentNode;
                while (parent) {
                    if (parent.id === 'mainview') { return nodes[i]; }
                    parent = parent.parentNode;
                }
            }
            return null;
        }

        function rerenderList(name) {
            var app = window.app;
            var node = listView(name);
            if (!node || !app || typeof app.rerender !== 'function') { return false; }
            try { app.rerender(node); } catch (e) { return false; }
            return true;
        }

        /**
         `null` means "the site would not say" (signed out, or the call failed) and
         is never turned into a guess -- the same rule the like block follows.
         */
        function readFollowed(book) {
            var app = window.app;
            if (!app || !app.api || typeof app.api.queryBookExtStatus !== 'function') {
                return Promise.resolve({ followed: null, raw: '' });
            }
            return Promise.resolve(app.api.queryBookExtStatus(book)).then(function (status) {
                return { followed: status ? !!status.follow : null,
                         raw: String(JSON.stringify(status)).slice(0, 200) };
            }, function (error) {
                return { followed: null, raw: 'rejected: ' + error };
            });
        }

        function attachFollow() {
            var app = window.app;
            if (!app || !app.api || typeof app.api.follow !== 'function') { return false; }
            if (app.api.__stvFollowWrapped) { return true; }
            app.api.__stvFollowWrapped = true;
            var api = app.api;
            var original = api.follow;

            app.api.follow = function (bookdata) {
                var self = this;
                var args = arguments;
                // Signed out: the site shows its own login page and there is
                // nothing to verify. Only a definite `false` skips the wrapper, so
                // a page that has not built `app.user` yet still gets the report.
                if (app.user && app.user.isLogin === false) {
                    return original.apply(self, args);
                }
                var book = target(bookdata);
                if (!book) {
                    note('FOLLOW', 'the tapped book could not be resolved');
                    return original.apply(self, args);
                }
                var key = book.host + '/' + book.id;
                return readFollowed(book).then(function (before) {
                    return Promise.resolve(original.apply(self, args)).then(function (down) {
                        note('FOLLOW', 'followbook ' + key + ' -> code ' + codeOf(down)
                            + ' raw=' + String(JSON.stringify(down)).slice(0, 200));
                        return readFollowed(book).then(function (after) {
                            note('FOLLOW', key + ' before=' + before.followed
                                + ' after=' + after.followed + ' raw=' + after.raw);
                            report(before, after, codeOf(down));
                            return down;
                        });
                    });
                });

                function report(before, after, code) {
                    if (after.followed === true && before.followed === true) {
                        // What the 关注 list's 删除 item hits: the site has no
                        // un-follow endpoint at all, so the tap re-follows.
                        if (app.toast) { app.toast('已经在关注列表里（站点没有取消关注的接口）'); }
                        return;
                    }
                    if (after.followed === true) {
                        rerenderList('bookfollowing');
                        if (app.toast) { app.toast('已关注'); }
                        return;
                    }
                    if (after.followed === false && code === '100') {
                        if (app.toast) { app.toast('站点说成功，但复查仍显示未关注'); }
                        return;
                    }
                    if (after.followed === false) {
                        if (app.toast) { app.toast('关注没生效（code ' + code + '）'); }
                    }
                    // followed === null: nothing is claimed; the panel has the raw
                    // answer, which is what the next log needs.
                }
            };
            note('FOLLOW', 'follow outcome reporting installed');
            return true;
        }

        /**
         Every wrapper is attempted on every attempt. `a && b && c` would skip the
         rest as soon as one of them is not ready yet, and the three arrive at
         different times: `app.api.bookmark` exists as soon as app.v2.js has run,
         while `likeBook`/`unlike` and `follow` are separate assignments. The
         `__stv*Wrapped` guards make the repeats free.
         */
        function install() {
            var a = attachBookmark();
            var b = attachLike();
            var c = attachFollow();
            return a && b && c;
        }

        if (!install()) {
            var attempts = 0;
            var timer = setInterval(function () {
                attempts++;
                if (install() || attempts > 400) { clearInterval(timer); }
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

     Which text, though, is the whole of the eighteenth round: the page-flip
     display keeps the chapter in an off-screen renderer and moves the pages it
     split out into the frames it shows, so the renderer, the body and the
     chapter list all answer with text that is not on screen. The sentence
     source is the page the reader is looking at, and the queue still walks the
     rest of the chapter and then the next one.
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

        // Does this piece have anything a voice can actually pronounce?
        //
        // The chapter text ends dialogue with a closing quote, and when that
        // quote sits between two break characters the splitter cut it into a
        // sentence of its own. The site's own filter (hasText, ASCII_WORD) would
        // have dropped it, but the stv0 marker below IS an ASCII word, so it got
        // carried through -- and the native side, finding no CJK in it, called
        // the fragment Vietnamese and read a lone quote with the Vietnamese
        // voice. That is what the reader heard as a stray Vietnamese sentence
        // after "…看景？" and after "…准时赴约啊。".
        //
        // Surrogates count as content: dropping half of a real character would
        // be worse than reading a stray mark.
        function hasSpokenContent(piece) {
            for (var i = 0; i < piece.length; i++) {
                var c = piece.charCodeAt(i);
                if ((c >= 0x30 && c <= 0x39)             // 0-9
                    || (c >= 0x41 && c <= 0x5a)          // A-Z
                    || (c >= 0x61 && c <= 0x7a)          // a-z
                    || (c >= 0x00c0 && c <= 0x024f)      // Latin-1 + Latin Extended (Vietnamese)
                    || (c >= 0x3040 && c <= 0x30ff)      // kana
                    || (c >= 0x3400 && c <= 0x4dbf)      // CJK ext A
                    || (c >= 0x4e00 && c <= 0x9fff)      // CJK unified
                    || (c >= 0xf900 && c <= 0xfaff)      // compatibility ideographs
                    || (c >= 0xff10 && c <= 0xff19)      // fullwidth digits
                    || (c >= 0xff21 && c <= 0xff3a)      // fullwidth A-Z
                    || (c >= 0xff41 && c <= 0xff5a)      // fullwidth a-z
                    || (c >= 0xd800 && c <= 0xdfff)) {   // surrogate half
                    return true;
                }
            }
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
                    if (piece && hasSpokenContent(piece)) { out.push(piece); }
                    buffer = '';
                }
            }
            var rest = trim(buffer);
            if (rest && hasSpokenContent(rest)) { out.push(rest); }
            return out;
        }

        // The archive notice is the i18n block's business, and that block owns
        // the one definition of what it is (SiteI18nData.script), used by the
        // reader DOM and by the exporter alike. Asked for rather than copied:
        // two definitions would drift.
        function stripNoticeText(value) {
            var api = window.__stvI18n;
            if (!api || typeof api.stripNotice !== 'function') { return value; }
            try { return api.stripNotice(value); } catch (e) { return value; }
        }

        function toTextFor(value) {
            return function () { return value; };
        }

        // A sentence object the site's queue accepts: toText() feeds the engine
        // (with the stv0 marker the ASCII filter needs), and highlightOn
        // dispatches `stvspeak` on the reader document with the sentence's page
        // element as its target -- the hook attachPageTurn listens for, in the
        // capture phase, to turn the pageflip display while the voice moves.
        function makeSentence(text, pageEl, doc) {
            return {
                toText: toTextFor(text),
                highlightOn: function () {
                    if (!pageEl) { return; }
                    // The document is the one the sentence list was built from
                    // (the reader iframe's); pageEl.ownerDocument would be the
                    // same object, but the site keeps its page elements
                    // attached to nothing it exposes, so take it from here.
                    var target = doc || pageEl.ownerDocument;
                    if (!target || typeof target.dispatchEvent !== 'function') { return; }
                    try { target.dispatchEvent({ type: 'stvspeak', target: pageEl }); } catch (e) {}
                },
                highlightOff: noop
            };
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

        function chapterOf(display) {
            var chapter = null;
            try {
                chapter = display.getCurrentChapter
                    ? display.getCurrentChapter() : display.currentChapter;
            } catch (e) { chapter = null; }
            if (!chapter && display.currentChapter) { chapter = display.currentChapter; }
            return chapter || null;
        }

        // The page-flip display keeps the whole chapter in an off-screen
        // renderer and moves the pages it split out into the frames it shows
        // (chapterdisplay.js setContent 1641-1646, pushPageToScreen 1706-1719),
        // so that renderer and the document body both hold leftovers rather
        // than what is on screen. The 2026-09-23 log caught exactly that:
        // "fallback source [document body]: 111 chars", the same 111 characters
        // on every attempt, from a page nobody was looking at. Reading the page
        // currentPageId names fixed that, and the next log exposed the rest of
        // it: the page's own text is not the page's visible text.
        //
        // The splitter cuts a paragraph in two by CLONING it. The page that
        // keeps the top gets a height-clipped copy; the next page gets a
        // wrapper whose child is pulled up by a negative margin so that the
        // lines already shown start above its box (chapterdisplay.js splitPage
        // 1095-1113). Both copies still hold the WHOLE paragraph, so a plain
        // textContent read on the second page opens with the lines the reader
        // has finished -- which is what the second report described: playback
        // starting a few lines before the page on screen. The same page also
        // opens with the fixed header the display stamps on every page (chapter
        // name and clock, createPage 1142-1166), which is chrome, not text.
        //
        // So the reading order is taken from the screen instead of the node
        // tree: WebKit is asked for the caret at the top of the box that is on
        // screen, and the text is collected from there. The same question
        // answers for the scrolling display, where the visible top is simply
        // wherever the viewport was scrolled to.
        //
        // The site's own queue carries on from there by itself (app.v2.read.js
        // play() -> nextChapter(true) once the list runs out), which is why the
        // rest of the chapter is appended page by page.

        // The display's own page turn (jumpToNextPage, chapterdisplay.js
        // ~111548) walks currentFrame.nextElementSibling and lands on
        // pushPageToScreen, which is what advances currentPageId. jumpToPage
        // accepts any element of the three chapters, and turning to the page
        // already on screen is a cheap early return for the site.
        function turnToPage(display, page) {
            if (!display || !page) { return; }
            var chapter = chapterOf(display);
            var pages = chapter && chapter.pageElements;
            if (!pages) { return; }
            var at = pages.indexOf(page);
            if (at < 0 || display.currentPageId === at) { return; }
            if (typeof display.jumpToPage === 'function') {
                try {
                    display.jumpToPage(page);
                    note('TTS', 'page turn -> page ' + (at + 1));
                } catch (e) {
                    note('ERR', 'page turn failed: ' + e);
                }
            }
        }

        // Turn the display as the voice moves: one capture-phase listener on
        // the reader iframe walks up from the highlighted node to its page
        // element. Capture (not bubble) because the same touch stream is what
        // the site's own swipe path eats on other pages.
        function attachPageTurn(display) {
            var w = readerWindow(display);
            var chapter = chapterOf(display);
            var pages = chapter && chapter.pageElements;
            if (!w || !w.document || !pages || !pages.length) { return; }
            if (w.__stvPageTurnInstalled) { return; }
            w.__stvPageTurnInstalled = true;
            w.document.addEventListener('stvspeak', function (event) {
                try {
                    var node = event.target;
                    while (node && node.nodeType === 1) {
                        if (pages.indexOf(node) >= 0) {
                            turnToPage(display, node);
                            return;
                        }
                        node = node.parentElement || node.parentNode;
                    }
                } catch (e) {}
            }, true);
            note('TTS', 'page turn listener installed');
        }

        function isChromeNode(node) {
            var el = node;
            while (el) {
                if (el.nodeType === 1) {
                    var cls = ' ' + String(el.className || '') + ' ';
                    if (cls.indexOf(' chaptertopinfo ') >= 0
                        || cls.indexOf(' chapternamefixed ') >= 0
                        || cls.indexOf(' currenttime ') >= 0) { return true; }
                }
                el = el.parentNode;
            }
            return false;
        }

        // The second half of a paragraph the splitter cut in two: a wrapper
        // whose child is pulled up so the lines the previous page already
        // showed sit outside the box.
        function isSpillBlock(block) {
            if (!block || block.nodeType !== 1) { return false; }
            if (String(block.tagName).toUpperCase() !== 'DIV') { return false; }
            var inner = (block.children && block.children[0]) || null;
            if (!inner || !inner.style || !inner.style.marginTop) { return false; }
            var margin = parseFloat(inner.style.marginTop);
            return isFinite(margin) && margin < 0;
        }

        function boxOf(node) {
            if (!node || typeof node.getBoundingClientRect !== 'function') { return null; }
            var rect = null;
            try { rect = node.getBoundingClientRect(); } catch (e) { return null; }
            if (!rect || (!rect.height && !rect.width)) { return null; }
            return rect;
        }

        function caretAt(doc, api, x, y) {
            var range = null;
            try { range = api.call(doc, x, y); } catch (e) { return null; }
            if (!range) { return null; }
            var node = range.startContainer || range.offsetNode || null;
            var offset = (typeof range.startOffset === 'number') ? range.startOffset
                : ((typeof range.offset === 'number') ? range.offset : -1);
            if (!node || node.nodeType !== 3) { return null; }
            if (!node.nodeValue || offset < 0 || offset > node.nodeValue.length) { return null; }
            return { node: node, offset: offset, range: range };
        }

        // The reader's own titlebar is in the document that owns the frame and
        // may cover the top of it (the RECT log shows it at 0..82). A row the
        // titlebar paints over is not a row the reader can see, so the scan
        // starts below it. Nothing to report when the frame already starts under
        // the bar, which is the other layout the site uses.
        function coveredTop(win) {
            var top = null;
            try {
                top = (win && win.parent && win.parent !== win && win.parent.document)
                    ? win.parent.document : null;
            } catch (e) { top = null; }
            if (!top || typeof top.querySelector !== 'function') { return 0; }
            var bar = null;
            var frame = null;
            try { bar = top.querySelector('.titlebar'); } catch (e) { bar = null; }
            try { frame = win.frameElement || null; } catch (e) { frame = null; }
            if (!bar || !frame) { return 0; }
            if (typeof bar.getBoundingClientRect !== 'function') { return 0; }
            if (typeof frame.getBoundingClientRect !== 'function') { return 0; }
            var barRect = null;
            var frameRect = null;
            try { barRect = bar.getBoundingClientRect(); } catch (e) { return 0; }
            try { frameRect = frame.getBoundingClientRect(); } catch (e) { return 0; }
            if (!barRect || !frameRect) { return 0; }
            var covered = barRect.bottom - frameRect.top;
            return covered > 0 ? covered : 0;
        }

        // The caret at the top of the box, walked down a few pixels at a time:
        // the first line can sit under a fixed header or below a margin, and the
        // answer has to be a character the reader can actually see.
        function caretAtTop(doc, box) {
            if (!doc || !box) { return null; }
            var api = doc.caretRangeFromPoint || doc.webkitCaretRangeFromPoint
                || doc.caretPositionFromPoint;
            if (typeof api !== 'function') { return null; }
            var win = doc.defaultView || {};
            var top = Math.max(box.top, coveredTop(win), 0);
            var bottom = Math.min(box.bottom, Math.min(win.innerHeight || box.bottom, top + 320));
            var left = box.left;
            var probes = [left + 3, left + (box.right - left) / 2];
            for (var i = 0; i < probes.length; i++) {
                for (var y = top + 1; y < bottom; y += 2) {
                    var found = caretAt(doc, api, probes[i], y);
                    if (!found || isChromeNode(found.node)) { continue; }
                    return leftmostCaret(doc, api, found, box);
                }
            }
            return null;
        }

        // The probe can land in the middle of a line; step to its first
        // character so the reader hears the whole line rather than its second
        // half. Text nodes split by the site's own <i> markers make the first
        // character a different node, which is fine -- the new caret is the one
        // the line starts with.
        function leftmostCaret(doc, api, found, box) {
            var range = found.range;
            if (!range || typeof range.getBoundingClientRect !== 'function') { return found; }
            var rect = null;
            try { rect = range.getBoundingClientRect(); } catch (e) { return found; }
            if (!rect || !rect.height) { return found; }
            var again = caretAt(doc, api, Math.max(box.left + 1, rect.left + 1),
                rect.top + rect.height / 2);
            if (again && !isChromeNode(again.node)) { return again; }
            return found;
        }

        function nodeText(node, options, started) {
            if (node.nodeType === 3) {
                var text = node.nodeValue || '';
                if (!text) { return { text: '', started: started }; }
                if (options.skipChrome && isChromeNode(node)) { return { text: '', started: started }; }
                if (started) { return { text: text, started: true }; }
                if (!options.from || node !== options.from.node) { return { text: '', started: false }; }
                return { text: text.substring(options.from.offset), started: true };
            }
            var out = '';
            var kids = node.childNodes || [];
            for (var i = 0; i < kids.length; i++) {
                var part = nodeText(kids[i], options, started);
                started = part.started;
                out += part.text;
            }
            return { text: out, started: started };
        }

        // The block's text, then the next block after a newline: the site builds
        // every page and every chapter out of <p> elements, and a newline is
        // what the sentence splitter wants between them.
        function blocksText(root, options) {
            var parts = [];
            var started = !options.from;
            var emitted = 0;
            var blocks = (root.children && root.children.length) ? root.children : [root];
            for (var i = 0; i < blocks.length; i++) {
                var block = blocks[i];
                if (options.skipChrome && isChromeNode(block)) { continue; }
                // The second half of a split paragraph repeats what the page
                // before it already handed over. Only the page on screen needs
                // that half, and it takes it from the caret. The display stamps
                // its page header ahead of it (createPage sets the page's
                // innerHTML first), so this is the first block that carried
                // text, not the first child.
                if (options.skipSpill && !emitted && isSpillBlock(block)) { continue; }
                var part = nodeText(block, options, started);
                started = part.started;
                if (part.text) {
                    parts.push(part.text);
                    emitted++;
                }
            }
            return parts.join(String.fromCharCode(10));
        }

        // What is on screen, in reading order: the visible part of the page the
        // reader is on, then every page after it in the chapter.
        function visiblePageText(display) {
            var w = readerWindow(display);
            var chapter = chapterOf(display);
            var pages = chapter && chapter.pageElements;
            if (pages && pages.length) {
                var at = display.currentPageId;
                if (typeof at !== 'number' || at < 0 || at >= pages.length) { at = 0; }
                var onScreen = pages[at];
                var doc = onScreen.ownerDocument || (w && w.document) || null;
                var caret = caretAtTop(doc, boxOf(onScreen));
                var text = caret ? blocksText(onScreen, { skipChrome: true, from: caret }) : '';
                if (!text) {
                    caret = null;
                    text = blocksText(onScreen, { skipChrome: true });
                }
                // Each later page keeps its own element: the queue has to turn
                // the display to it when the voice gets there (turnToPage).
                var parts = [];
                var segments = [];
                if (text) {
                    parts.push(text);
                    segments.push({ el: onScreen, text: text });
                }
                for (var i = at + 1; i < pages.length; i++) {
                    var later = blocksText(pages[i], { skipChrome: true, skipSpill: true });
                    if (later) {
                        parts.push(later);
                        segments.push({ el: pages[i], text: later });
                    }
                }
                if (!parts.length) { return null; }
                return {
                    text: parts.join(String.fromCharCode(10)),
                    segments: segments,
                    source: 'pageflip page ' + (at + 1) + ' of ' + pages.length
                        + (caret ? ', from the visible line' : ', from the top of the page')
                };
            }
            var holder = chapterHolder(display);
            if (!holder) { return null; }
            var hdoc = holder.ownerDocument || (w && w.document) || null;
            var hcaret = caretAtTop(hdoc, boxOf(holder));
            var scroll = hcaret ? blocksText(holder, { skipChrome: true, from: hcaret }) : '';
            if (!scroll) {
                hcaret = null;
                scroll = blocksText(holder, { skipChrome: true });
            }
            if (!scroll) { return null; }
            return {
                text: scroll,
                source: 'scroll chapter'
                    + (hcaret ? ', from the visible line' : ', from the top of the chapter')
            };
        }

        // The page-flip display answers getCurrentChapter() with a chapter
        // object; the scrolling display answers with an element that owns the
        // chapter's .contentcontainer. Only the second one has a q(), which is
        // why this used to return null on the device and hand the body over to
        // TTS. When there is no .contentcontainer the chapter element itself is
        // still the right text.
        function chapterHolder(display) {
            var view = null;
            try {
                view = display.getCurrentChapter ? display.getCurrentChapter()
                    : display.currentContainer;
            } catch (e) { view = null; }
            if (!view || typeof view.q !== 'function') { return null; }
            var holder = null;
            try { holder = view.q('.contentcontainer'); } catch (e) { holder = null; }
            return holder || view;
        }

        function textOf(node) {
            if (!node) { return ''; }
            return node.innerText || node.textContent || '';
        }

        function fallbackSentences(display) {
            var w = readerWindow(display);
            if (!w || !w.document) { return []; }
            var doc = w.document;            var text = '';
            var source = '';
            var model = visiblePageText(display);
            if (model) { text = model.text; source = model.source; }
            if (!text) {
                text = textOf(chapterHolder(display));
                source = 'current chapter';
            }
            if (!text) {
                // Transient: the display is being rebuilt. Fall back to whatever
                // the document has rather than reporting nothing to play.
                source = 'document body';
                text = textOf(doc.getElementById('maincontent')) || textOf(doc.body);
            }
            text = stripNoticeText(text);
            var pieces = splitSentences(text);
            var list = [];
            // Map each piece back to the page element it came from so the
            // highlight can turn the display (attachPageTurn). Text matching is
            // done with indexOf on the remaining tail, not a hard offset: the
            // piece may start mid-segment. Reference identity of the page
            // element is what turns the page, so a mismatch here only costs a
            // page turn, never a wrong page.
            var segments = (model && model.segments) ? model.segments : null;
            var segIdx = 0;
            var segPos = 0;
            for (var i = 0; i < pieces.length; i++) {
                if (segments) {
                    while (segIdx < segments.length
                        && segPos >= segments[segIdx].text.length) {
                        segIdx++;
                        segPos = 0;
                    }
                    if (segIdx < segments.length) {
                        var at2 = segments[segIdx].text.indexOf(pieces[i], segPos);
                        if (at2 >= 0) { segPos = at2 + pieces[i].length; }
                    }
                }
                var pageEl = segments ? segments[segIdx].el : null;
                list.push(makeSentence(MARK + pieces[i], pageEl, doc));
            }
            note('TTS', 'fallback source [' + source + ']: ' + text.length + ' chars -> '
                + pieces.length + ' sentence(s), first='
                + (pieces.length ? pieces[0].substring(0, 20) : ''));
            return list;
        }

        function patchDisplay(display) {
            if (!display || display.__stvTtsPatched) { return; }
            display.__stvTtsPatched = true;
            attachPageTurn(display);
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

        // What the queue is built from: the chapter, and the page of it that is
        // on screen. The site's own isViewChanged() compares chapter ids only,
        // so the page has to be part of the key here or a replay reads the page
        // the reader has already left.
        function pageKey(display) {
            if (!display) { return 'none'; }
            var chapter = chapterOf(display);
            var cid = (chapter && chapter.cid) ? String(chapter.cid) : '?';
            var at = (typeof display.currentPageId === 'number') ? display.currentPageId : '?';
            return cid + '#' + at;
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
                var player = this.player;
                var key = pageKey(display);
                // The site rebuilds the queue only when the CHAPTER changed
                // (app.v2.read.js app.tts.start -> player.isViewChanged()), so a
                // play after the list ran out -- or after the reader turned the
                // page -- replayed the page the reader had already left; and an
                // exhausted list makes the site's own play() jump to the next
                // chapter outright. Rebuild when the page moved and when the
                // list is spent.
                var stale = !!player && (!player.sentences || !player.sentences.length
                    || player.__stvPageKey !== key
                    || (typeof player.currentId === 'number'
                        && player.currentId >= player.sentences.length));
                if (stale && typeof player.generateSentences === 'function') {
                    try {
                        if (typeof player.reset === 'function') { player.reset(); }
                        player.generateSentences();
                    } catch (e) {
                        note('ERR', 'rebuilding the reader sentence list failed: ' + e);
                    }
                }
                if (player) { player.__stvPageKey = key; }
                var failure = '';
                try {
                    originalStart.apply(this, arguments);
                } catch (e) {
                    failure = ' threw: ' + e;
                }
                player = this.player;
                var count = (player && player.sentences) ? player.sentences.length : -1;
                var first = (player && player.sentences && player.sentences[0])
                    ? (player.sentences[0].text || '') : '';
                note(failure ? 'ERR' : 'TTS', 'reader TTS start: sentences=' + count
                    + ' first=' + first.length + ' chars page=' + key + ' provider='
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
                    // Tagged so the loop can tell "the reader paused" from "the
                    // server gave up" and hand the chapter back to the resume.
                    function paused() {
                        var stop = new Error('tam dung');
                        stop.stvPaused = true;
                        return stop;
                    }
                    function once() {
                        // A pause has to bite before the next request goes out,
                        // not after the whole batch has been retried: the backoff
                        // below can hold a batch for 10s, and the reader sees the
                        // download keep going after tapping 暂停下载.
                        if (self.isPaused) { return Promise.reject(paused()); }
                        return downloadGate().then(function () {
                            return originalChapter.apply(self, args);
                        }).then(function (result) {
                            relaxGate();
                            return result;
                        }, function (error) {
                            if (self.isPaused) {
                                // The site's downloadChapter has already written
                                // "Lỗi: Không thể đọc dữ liệu" into the row status
                                // by now; that is the "报错" the reader sees after
                                // pausing. Put "Đã dừng" back and stop retrying.
                                if (self.setStatus) { self.setStatus('Đã dừng'); }
                                return Promise.reject(paused());
                            }
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
                        if (self.isPaused) {
                            // 继续下载 tapped while the paused loop is still
                            // finishing its batch: unpause in place so the retry
                            // backoff stops aborting, and arm the replay in case
                            // the loop was already past its last isPaused check
                            // and is about to exit.
                            self.isPaused = false;
                            self.__stvStartAgain = true;
                            if (self.setStatus) { self.setStatus('Đang tải...'); }
                            note('DOWNLOAD', 'resumed in place for '
                                + self.host + '/' + self.id);
                            return Promise.resolve();
                        }
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
                            var seen = {};
                            var collapsed = 0;
                            for (var i = 0; i < all.length; i++) {
                                var record = all[i];
                                if (liveJob(record.host, record.id)) { continue; }
                                var bookKey = record.host + '/' + record.id;
                                if (seen[bookKey]) {
                                    // One row per novel whatever the store holds:
                                    // the chapter file is keyed by host/id, so every
                                    // duplicate record renders the same content and
                                    // the newest counts are the true ones.
                                    var held = seen[bookKey];
                                    if ((record.lastDownload || 0)
                                        > (held.record.lastDownload || 0)) {
                                        visible[held.index] = record;
                                        held.record = record;
                                    }
                                    collapsed++;
                                    continue;
                                }
                                seen[bookKey] = { index: visible.length, record: record };
                                visible.push(record);
                            }
                            if (collapsed) {
                                note('BOOKINFO', 'collapsed ' + collapsed
                                    + ' duplicate download record(s)');
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
            var store = app.offlineBook.store;
            if (store && typeof store.remove === 'function' && !store.__stvRemovePatched) {
                store.__stvRemovePatched = true;
                var originalRemove = store.remove;
                // OfflineBook.delete() (app.v2.read.js:3314) hands store.remove()
                // the wrapper, but store.data holds the plain record it wraps
                // (store.prepend(this.baseObject), :3309), so indexOf() never
                // matches, nothing is spliced, and the "deleted" book is back the
                // next time the app starts. Unwrap before looking it up.
                store.remove = function (item) {
                    if (item && item.baseObject) { item = item.baseObject; }
                    return originalRemove.call(this, item);
                };
                note('DOWNLOAD', 'store.remove unwraps OfflineBook records');
            }
            if (manager && manager.prototype && !manager.prototype.__stvPauseNoted) {
                manager.prototype.__stvPauseNoted = true;
                var originalPause = manager.prototype.pause;
                manager.prototype.pause = function () {
                    originalPause.apply(this, arguments);
                    note('DOWNLOAD', 'paused ' + this.host + '/' + this.id + ' at '
                        + this.downloaded + '/' + this.total);
                };
            }
            return !!(manager && manager.prototype && manager.prototype.__stvWarmed
                    && manager.prototype.__stvThrottled)
                && !!app.offlineBook.__stvWarmedList
                && !!(store && store.__stvRemovePatched);
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
                var requeue = [];
                return Promise.all(batch.map(function (cid) {
                    return self.downloadChapter(cid).then(function () {
                        self.downloaded++;
                        if (self.onProgress) { self.onProgress(); }
                        var index = self.chapters.indexOf(cid);
                        if (index >= 0) { self.chapters.splice(index, 1); }
                        console.log(self.downloaded + '/' + self.total);
                    }, function (error) {
                        if (error && error.stvPaused) {
                            // Paused mid-batch: the chapter was never fetched, so
                            // keep it for the resume instead of counting it as a
                            // give-up (a give-up leaves the job paused and drops
                            // the chapter for good).
                            requeue.push(cid);
                            return;
                        }
                        failed.push(cid);
                        note('DOWNLOAD', 'chapter ' + cid + ' of ' + self.host + '/'
                            + self.id + ' gave up: ' + (error && error.message));
                    });
                })).then(function () {
                    if (requeue.length) { queue = requeue.concat(queue); }
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
                // A resume that is already waiting to be replayed owns the status
                // text now; flipping it back to "Đã dừng" here would make a job
                // that is about to carry on look stopped.
                if (!self.__stvStartAgain && self.status
                    && self.status.textContent === 'Đang tải...') {
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
            // A resume replays the loop once it has exited, so this can be
            // reached twice for the same job; the second pass would append a
            // duplicate row for a book the list already shows.
            if (manager.__stvMoved) { return; }
            manager.__stvMoved = true;
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
                // The site renders the DOWNLOADED list from store.data, one
                // record per book (getNewBook, app.v2.read.js:3218), so a book
                // that is already in the store is already on screen. Appending
                // the finished job's row unconditionally is what put the same
                // novel in the list once per download ("多次下载同一本书...会有多
                // 条记录"): drop the copy this row replaces.
                var bookKey = String(host) + '/' + String(id);
                var rows = area.children || [];
                var dropped = 0;
                for (var r = rows.length - 1; r >= 0; r--) {
                    var stale = rows[r];
                    if (stale && stale.getAttribute
                        && stale.getAttribute('data-stvbook') === bookKey) {
                        area.removeChild(stale);
                        dropped++;
                    }
                }
                if (dropped) {
                    note('DOWNLOAD', 'dropped ' + dropped + ' earlier row(s) for ' + bookKey);
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
            // One row per novel: the row carries its own key so
            // moveJobToDownloaded can drop the copy it is about to duplicate.
            if (book.host && book.id) {
                node.setAttribute('data-stvbook',
                    String(book.host) + '/' + String(book.id));
            }
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
                // OfflineBook.deleteAll() (app.v2.read.js:3368) walks the chapter
                // list while deleteChapter() splices that very array, so it drops
                // every second chapter body and leaves the rest behind. Walk a
                // copy instead.
                var wiped = 0;
                Promise.resolve(target.getChapterDownloaded())
                    .then(function (chapters) {
                        var list = (chapters || []).slice();
                        var chain = Promise.resolve();
                        for (var i = 0; i < list.length; i++) {
                            chain = chain.then(function (chapter) {
                                return function () {
                                    wiped++;
                                    return target.deleteChapter(chapter);
                                };
                            }(list[i]));
                        }
                        return chain;
                    })
                    .then(function () { return target.delete(); })
                    .then(function () {
                        // One row now stands for one book, so the delete has to
                        // take every record carrying that host/id: a store that
                        // already held several (one per past download) would
                        // otherwise leave siblings behind and the book would be
                        // back on the next reload. OfflineBook.delete() only
                        // removes the one record its wrapper holds, which is why
                        // the leftovers are swept here rather than instead.
                        var store = app.offlineBook.store;
                        var records = (store && store.data) || [];
                        var dropped = 0;
                        for (var r = records.length - 1; r >= 0; r--) {
                            var record = records[r];
                            if (record && record.host === book.host
                                && String(record.id) === String(book.id)) {
                                records.splice(r, 1);
                                dropped++;
                            }
                        }
                        if (dropped) {
                            note('DOWNLOAD', 'removed ' + dropped
                                + ' leftover record(s) for ' + book.host + '/'
                                + book.id);
                        }
                        // The book object is cached per host/id and never
                        // invalidated (app.v2.read.js:3248). Re-downloading a book
                        // in the same session would hand back this stale wrapper,
                        // whose baseObject is no longer in store.data, so save()
                        // would skip the prepend and the book would never come
                        // back. Drop it and let the next download rebuild it.
                        var singletons = app.offlineBook.offlineBookSingletons;
                        var key = book.host + '_' + book.id;
                        if (singletons && singletons[key]) { delete singletons[key]; }
                        return app.offlineBook.store && app.offlineBook.store.save
                            ? app.offlineBook.store.save() : null;
                    })
                    .then(function () {
                        note('DOWNLOAD', 'wiped ' + wiped + ' chapter file(s) for '
                            + book.host + '/' + book.id);
                        finish();
                    }, function (error) {
                        note('ERR', 'delete failed for ' + book.host + '/' + book.id
                            + ': ' + error);
                    });
            });
            bar.appendChild(button);
            // The export UI lives in its own block (`downloadExport`), which owns
            // the TXT/EPUB builders and the native file hand-off; this block owns
            // the row's action bar. Asking for the button keeps a single wrapper
            // around app.celoader.bookdownloadedrow -- two independent wrappers
            // around one renderer is how a row gets decorated twice.
            var exporter = window.__stvExport;
            if (exporter && typeof exporter.button === 'function') {
                var exportButton = exporter.button(book);
                if (exportButton) { bar.appendChild(exportButton); }
            }
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

        function showStartedDialog(host, bookid, start, end, count, running, skipped) {
            var app = window.app;
            var ctx = app && app.context;
            if (!ctx || typeof ctx.showPopup !== 'function') { return; }
            var detail;
            if (running) {
                detail = '这本书已经在下载中，没有重复添加。';
            } else if (!count) {
                detail = '第 ' + start + ' - ' + end + ' 章都已经下载过了（跳过 '
                    + skipped + ' 章），没有需要下载的内容。';
            } else if (skipped) {
                detail = '新增 ' + count + ' 章（第 ' + start + ' - ' + end + ' 章里已有 '
                    + skipped + ' 章，直接跳过）';
            } else {
                detail = '第 ' + start + ' - ' + end + ' 章，共 ' + count + ' 章';
            }
            var template = {
                title: running ? '已在下载' : (count ? '已开始下载' : '无需重复下载'),
                body: '<center>' + host + ' / ' + bookid + '<br>' + detail + '</center>',
                button: '<button action=stvclose>关闭</button>'
                    + (count ? '<button action=stvqueue>查看下载</button>' : ''),
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
                    var wanted = clist.slice(start - 1, end);
                    // Chapters already on disk are skipped. OfflineBook keeps one
                    // entry per chapter id under the book's own key
                    // (app.v2.read.js:3322), so re-running a finished range used to
                    // queue every chapter again -- "第二次继续下载 1-20 还是会创建
                    // 新的下载任务". The record is per (host, id) on purpose:
                    // another source of the same novel is a different book with
                    // its own chapter ids, and has to be fetched from that source.
                    var have = {};
                    var done = [];
                    if (book && typeof book.getChapterDownloaded === 'function') {
                        done = (await book.getChapterDownloaded()) || [];
                    }
                    for (var d = 0; d < done.length; d++) { have[String(done[d])] = true; }
                    var lists = [];
                    for (var w = 0; w < wanted.length; w++) {
                        if (have[String(wanted[w].cid)]) { continue; }
                        lists.push(wanted[w].cid);
                    }
                    var skipped = wanted.length - lists.length;
                    note('DOWNLOAD', 'range ' + start + '-' + end + ' of ' + clist.length
                        + ' -> ' + lists.length + ' new chapter(s), ' + skipped
                        + ' already downloaded');
                    if (!lists.length) {
                        showStartedDialog(host, bookid, start, end, 0, false, skipped);
                        return;
                    }
                    var job = new app.BookDownloadManager(host, bookid, lists, book);
                    job.start();
                    showStartedDialog(host, bookid, start, end, lists.length, false, skipped);
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

        // 用户 → 我的页面 (app.fun.showUserPages, _page_vip.html:4784) pushes an
        // empty pagewithtitle and fills it from
        // /mobile/staticpost.php?author=<uid> (:4790). For an account that has
        // never published a static page the server answers 200 with an EMPTY body
        // (device log 23:17:05 "staticpost.php?author=306185 -> 200 text/html
        // string 0b"), and `innerHTML = ''` leaves a white screen under the title
        // bar -- indistinguishable from a broken page. The endpoint itself works,
        // so the repair is one sentence instead of a blank page.
        //
        // Hooked on app.net.get rather than on showUserPages: the site's own
        // `.then` writes the string straight into innerHTML, and a blank response
        // produces NO DOM mutation, so an observer on the page could never tell
        // "the answer was empty" apart from "the answer has not arrived yet".
        var SPACE = ' ';
        var NL = String.fromCharCode(10);
        var TAB = String.fromCharCode(9);
        var CR = String.fromCharCode(13);

        var EMPTY_PAGES_HTML = '<div class="stv-emptypages" style="padding:28px 18px;'
            + 'text-align:center;opacity:0.75;font-size:14px;line-height:1.8;">'
            + '这个账号还没有发布过页面<br>'
            + '<span style="font-size:12px;opacity:0.85;">'
            + '（站点的「页面」指作者发布的专栏/静态页，不是个人主页）</span></div>';

        function isBlankText(text) {
            for (var i = 0; i < text.length; i++) {
                var ch = text.charAt(i);
                if (ch !== SPACE && ch !== NL && ch !== TAB && ch !== CR) { return false; }
            }
            return true;
        }

        function patchStaticPostEmptyState() {
            var app = window.app;
            var net = app && app.net;
            if (!net || typeof net.get !== 'function') { return false; }
            if (net.__stvStaticPostPatched) { return true; }
            net.__stvStaticPostPatched = true;
            var original = net.get;
            net.get = function (url) {
                var call = original.apply(this, arguments);
                if (typeof url !== 'string'
                    || url.indexOf('/mobile/staticpost.php') !== 0) { return call; }
                if (!call || typeof call.then !== 'function') { return call; }
                return call.then(function (body) {
                    if (typeof body !== 'string' || !isBlankText(body)) { return body; }
                    note('PAGE', 'staticpost.php answered with an empty body; showing the '
                        + 'empty state instead of a blank page');
                    return EMPTY_PAGES_HTML;
                });
            };
            note('PATCH', 'an empty 我的页面 gets a sentence instead of a white screen');
            return true;
        }

        // 用户 → 通知 (app.fun.showNotify, page-vip:4607) renders one line per item
        // from /mobile/jsonify.php?ajax=getnotify. The chapter-update line is the
        // site's own template -- "《{0}》来自{1}有{2}个新章节" -- and {0} is the
        // book's VIETNAMESE name; the server never sends the Chinese one. The item
        // does carry the book's link, though (`href`, the same value its click
        // handler hands to app.url.handler), and the reader follows the book, so
        // the Chinese name can be fetched from the book itself.
        function bookFromHref(href) {
            var parts = String(href || '').split('/');
            for (var i = 0; i < parts.length; i++) {
                if (parts[i] !== 'truyen' && parts[i] !== 'truyenn') { continue; }
                var host = parts[i + 1];
                var id = parts[i + 3];
                if (host && id) { return { host: host, id: id }; }
            }
            return null;
        }

        // The title is the text the site itself wrapped in 《 》.
        function titleInNotify(text) {
            var open = text.indexOf('《');
            if (open < 0) { return ''; }
            var close = text.indexOf('》', open + 1);
            if (close < 0 || close <= open + 1) { return ''; }
            return text.substring(open + 1, close);
        }

        var bookNames = {};

        function askBookName(book, done) {
            var key = book.host + '/' + book.id;
            if (bookNames[key] !== undefined) { done(bookNames[key]); return; }
            var app = window.app;
            if (!app || !app.net || typeof app.net.getCacheLater !== 'function') { return; }
            app.net.getCacheLater('/mobile/bookinfo.php?hid=' + book.id
                + '&host=' + book.host).then(function (down) {
                    var name = down && down.book && down.book.name;
                    bookNames[key] = typeof name === 'string' ? name : '';
                    done(bookNames[key]);
                }, function (error) {
                    bookNames[key] = '';
                    note('ERR', 'the notification book lookup failed for ' + key + ': '
                        + String(error));
                });
        }

        function retitleNotify(item) {
            if (!item || !item.querySelector) { return; }
            var body = item.querySelector('.content');
            if (!body || !body.childNodes) { return; }
            var data = item.data || {};
            var book = bookFromHref(data.href);
            if (!book) { return; }
            for (var i = 0; i < body.childNodes.length; i++) {
                var node = body.childNodes[i];
                if (node.nodeType !== 3 || node.__stvNotifyAsked) { continue; }
                var text = String(node.nodeValue || '');
                var vietnamese = titleInNotify(text);
                if (!vietnamese) { continue; }
                node.__stvNotifyAsked = true;
                askBookName(book, function (name) {
                    if (!name || name === vietnamese) { return; }
                    node.nodeValue = text.split(vietnamese).join(name);
                    note('NOTIFY', 'a notification title became ' + name);
                });
                return;
            }
        }

        function watchNotify(page) {
            if (!page || page.__stvNotifyWatched) { return; }
            page.__stvNotifyWatched = true;
            var scan = function () {
                var items = page.querySelectorAll('.notify');
                for (var i = 0; i < items.length; i++) { retitleNotify(items[i]); }
            };
            scan();
            if (typeof MutationObserver !== 'function') { return; }
            var observer = new MutationObserver(scan);
            observer.observe(page, { childList: true, subtree: true });
        }

        function patchNotifyTitles() {
            var app = window.app;
            var fun = app && app.fun;
            if (!fun || typeof fun.showNotify !== 'function') { return false; }
            if (fun.__stvNotifyTitlesPatched) { return true; }
            fun.__stvNotifyTitlesPatched = true;
            var original = fun.showNotify;
            fun.showNotify = function () {
                var result = original.apply(this, arguments);
                try {
                    var page = app.topPage ? app.topPage() : null;
                    if (page) { watchNotify(page); }
                } catch (error) {
                    note('ERR', 'notify title patch: ' + String(error));
                }
                return result;
            };
            note('PATCH', 'notification book titles are looked up in Chinese');
            return true;
        }

        var patchAttempts = 0;
        var patchTimer = setInterval(function () {
            patchAttempts++;
            var readers = patchReaders();
            var range = patchDownloadRange();
            var rows = patchDownloadedRow();
            var pages = patchStaticPostEmptyState();
            var notify = patchNotifyTitles();
            if ((readers && range && rows && pages && notify) || patchAttempts > 600) {
                clearInterval(patchTimer);
            }
        }, 200);

        // Books downloaded after boot enter store.data later, so keep sweeping.
        // Cheap: warmOne() answers immediately for anything already warmed, and
        // the store holds a handful of entries.
        setInterval(warmStore, 3000);
    })();
    """

    // MARK: - Export a downloaded book

    /**
     The downloaded list (page-vip:4014-4037) shows a cover, a title and
     "Đã tải N/M" and nothing else, so a book the reader has paid to download
     cannot leave the app: reinstalling the sideloaded IPA drops the whole
     data container with it. This block adds an 导出 button to every row and
     turns the stored chapters into a real file:

        txt   title, author, source and one section per chapter, in the order
              they were downloaded (which is the order the chapter list was
              sliced in, so it is reading order);
        epub  the same text as XHTML inside a ZIP, with the cover image and the
              site's own chapter titles, plus nav.xhtml and toc.ncx so both
              EPUB 3 and older readers can build a table of contents.

     The file itself is handed to the native side (`App.exportFile`), which
     writes it into the app's temporary directory and opens the system share
     sheet -- 存储到"文件", AirDrop, or straight into another reader. The site
     cannot deliver a file any other way: a WKWebView ignores `<a download>`, and
     there is no Filesystem plugin in this build.

     The ZIP writer is stored-only on purpose. EPUB requires the `mimetype`
     entry to be uncompressed, and the remaining entries are one novel that is
     handed to another app immediately, so a DEFLATE pass (pako, or
     CompressionStream on iOS 16.4+) would only add a dependency and a place for
     the archive to be subtly wrong.

     Written escape-free, like every block in this file: check-ios-shim.js
     rejects a literal backslash, so there is no regex literal and no escaped
     character anywhere. Line feeds come from String.fromCharCode.
     */
    static let downloadExport = """
    (function () {
        if (window.__stvExportInstalled) { return; }
        window.__stvExportInstalled = true;

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        function toast(message) {
            var app = window.app;
            if (app && app.toast) { app.toast(message); }
        }

        var LF = String.fromCharCode(10);
        var CRLF = String.fromCharCode(13, 10);
        var TAB = String.fromCharCode(9);
        var NBSP = String.fromCharCode(0xA0);
        var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

        // ---- text -> UTF-8 bytes ------------------------------------------

        // Two passes over the string (measure, then fill) rather than an array
        // of char codes: a full novel is megabytes and an array of numbers per
        // byte is what makes this run out of memory on a phone.
        function utf8Length(text) {
            var size = 0;
            for (var i = 0; i < text.length; i++) {
                var code = text.charCodeAt(i);
                if (code < 0x80) { size += 1; }
                else if (code < 0x800) { size += 2; }
                else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length
                    && text.charCodeAt(i + 1) >= 0xDC00
                    && text.charCodeAt(i + 1) <= 0xDFFF) {
                    size += 4;
                    i++;
                } else if (code >= 0xD800 && code <= 0xDFFF) { size += 3; }
                else { size += 3; }
            }
            return size;
        }

        function textBytes(text) {
            var bytes = new Uint8Array(utf8Length(text));
            var at = 0;
            for (var i = 0; i < text.length; i++) {
                var code = text.charCodeAt(i);
                if (code < 0x80) {
                    bytes[at++] = code;
                } else if (code < 0x800) {
                    bytes[at++] = 0xC0 | (code >> 6);
                    bytes[at++] = 0x80 | (code & 0x3F);
                } else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length
                    && text.charCodeAt(i + 1) >= 0xDC00
                    && text.charCodeAt(i + 1) <= 0xDFFF) {
                    var point = 0x10000 + ((code - 0xD800) << 10)
                        + (text.charCodeAt(i + 1) - 0xDC00);
                    bytes[at++] = 0xF0 | (point >> 18);
                    bytes[at++] = 0x80 | ((point >> 12) & 0x3F);
                    bytes[at++] = 0x80 | ((point >> 6) & 0x3F);
                    bytes[at++] = 0x80 | (point & 0x3F);
                    i++;
                } else if (code >= 0xD800 && code <= 0xDFFF) {
                    // A lone surrogate has no UTF-8 form; emit the same U+FFFD
                    // the platform encoders do so the measured length still
                    // matches what is written.
                    bytes[at++] = 0xEF;
                    bytes[at++] = 0xBF;
                    bytes[at++] = 0xBD;
                } else {
                    bytes[at++] = 0xE0 | (code >> 12);
                    bytes[at++] = 0x80 | ((code >> 6) & 0x3F);
                    bytes[at++] = 0x80 | (code & 0x3F);
                }
            }
            return bytes;
        }

        function base64(bytes) {
            var out = '';
            for (var i = 0; i < bytes.length; i += 3) {
                var b0 = bytes[i];
                var b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
                var b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
                out += B64.charAt(b0 >> 2);
                out += B64.charAt(((b0 & 3) << 4) | (b1 >> 4));
                out += i + 1 < bytes.length
                    ? B64.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '=';
                out += i + 2 < bytes.length ? B64.charAt(b2 & 63) : '=';
            }
            return out;
        }

        function base64Bytes(text) {
            var binary = atob(text);
            var bytes = new Uint8Array(binary.length);
            for (var i = 0; i < binary.length; i++) {
                bytes[i] = binary.charCodeAt(i) & 0xFF;
            }
            return bytes;
        }

        // ---- stored chapter -> paragraphs ---------------------------------

        var TRIM_RE = new RegExp('^[ ' + TAB + NBSP + ']+|[ ' + TAB + NBSP + ']+$', 'g');
        var BREAK_RE = new RegExp('<br[^>]*>', 'gi');
        var BLOCK_RE = new RegExp('</(p|div|h[1-6]|li|tr)>', 'gi');
        var TAG_RE = new RegExp('<[^>]*>', 'g');
        var ENTITY_RE = new RegExp('&#([0-9]+);', 'g');

        function decodeEntities(text) {
            var out = text
                .replace(new RegExp('&nbsp;', 'gi'), ' ')
                .replace(new RegExp('&quot;', 'gi'), '"')
                .replace(new RegExp('&apos;', 'gi'), "'")
                .replace(new RegExp('&lt;', 'gi'), '<')
                .replace(new RegExp('&gt;', 'gi'), '>');
            // Ampersand last: decoding it first would turn a doubly-encoded
            // entity into one more level of markup.
            out = out.replace(new RegExp('&amp;', 'gi'), '&');
            out = out.replace(ENTITY_RE, function (match, digits) {
                var value = parseInt(digits, 10);
                return value > 0 && value <= 0xFFFF ? String.fromCharCode(value) : '';
            });
            return out;
        }

        // The chapter body is the site's own HTML-ish markup (app.v2.read.js
        // stores the raw response string). Tags are dropped rather than
        // re-emitted: the source is not well-formed XML, and one stray <br>
        // would make the whole XHTML document unreadable in a strict reader.
        // The site appends its own archive notice to every chapter body
        // ("Bạn đang đọc bản lưu trong hệ thống" -- you are reading the copy kept
        // in the system). It is not ours to keep in an exported book, and it is
        // not ours to define twice: the reader's copy of this rule lives in the
        // i18n block, and this asks it. No owner means no stripping rather than
        // a crash, and the injection order makes the owner present.
        function stripNotice(text) {
            var i18n = window.__stvI18n;
            if (i18n && typeof i18n.stripNotice === 'function') { return i18n.stripNotice(text); }
            return text;
        }

        function chapterParagraphs(html) {
            var text = String(html === undefined || html === null ? '' : html);
            text = text.replace(BREAK_RE, LF);
            text = text.replace(BLOCK_RE, LF + LF);
            text = text.replace(TAG_RE, '');
            text = decodeEntities(text);
            var lines = text.split(LF);
            var out = [];
            for (var i = 0; i < lines.length; i++) {
                // Stripped before the trim, because the notice is normally a
                // paragraph of its own and has to disappear whole: a blank line
                // left behind in the .txt is a visible artefact.
                var line = stripNotice(lines[i]).replace(TRIM_RE, '');
                if (line) { out.push(line); }
            }
            return out;
        }

        function parseChapter(raw, cid) {
            if (raw === null || raw === undefined || raw === '') { return null; }
            var text = String(raw);
            var json = null;
            try { json = JSON.parse(text); } catch (error) { json = null; }
            if (!json || typeof json !== 'object') { return null; }
            var body = json.data;
            if (body === undefined || body === null) { body = json.content; }
            var paragraphs = chapterParagraphs(body);
            if (!paragraphs.length) { return null; }
            return {
                // readchapter carries no original title, so the cid is kept: it is
                // the only handle back to the Chinese name in the chapter list.
                cid: String(cid === undefined || cid === null ? '' : cid),
                title: String(json.chaptername || json.chapterName || '').trim(),
                paragraphs: paragraphs
            };
        }

        // ---- reading the stored chapters ----------------------------------

        // getChapter() is one Preferences round trip per chapter, so the reads
        // are windowed instead of sequential: a 300 chapter book is otherwise
        // three hundred cross-process waits in a row. The results keep their
        // original positions, so the reading order is untouched.
        var READ_WINDOW = 6;

        function readChapters(target, onProgress) {
            return Promise.resolve(target.getChapterDownloaded()).then(function (ids) {
                var list = (ids || []).slice();
                var results = new Array(list.length);
                var at = 0;
                function batch() {
                    if (at >= list.length) { return Promise.resolve(); }
                    var group = [];
                    while (group.length < READ_WINDOW && at < list.length) {
                        group.push(at);
                        at++;
                    }
                    return Promise.all(group.map(function (position) {
                        return Promise.resolve(target.getChapter(list[position]))
                            .then(function (raw) {
                                results[position] = parseChapter(raw, list[position]);
                            },
                                  function (error) {
                                      results[position] = null;
                                      note('EXPORT', 'chapter ' + list[position]
                                          + ' could not be read: ' + error);
                                  });
                    })).then(function () {
                        if (onProgress) { onProgress(at, list.length); }
                        return batch();
                    });
                }
                return batch().then(function () {
                    var chapters = [];
                    var unreadable = 0;
                    for (var i = 0; i < results.length; i++) {
                        if (results[i]) { chapters.push(results[i]); }
                        else { unreadable++; }
                    }
                    return { chapters: chapters, unreadable: unreadable,
                             total: list.length };
                });
            });
        }

        // ---- file naming --------------------------------------------------

        // No regex: the character class would need a literal backslash, which
        // check-ios-shim.js rejects. A code-point test is clearer anyway.
        function safeName(text) {
            var source = String(text || '');
            var out = '';
            for (var i = 0; i < source.length; i++) {
                var code = source.charCodeAt(i);
                var bad = code < 32 || code === 92 || code === 47
                    || code === 58 || code === 42 || code === 63
                    || code === 34 || code === 60 || code === 62 || code === 124;
                out += bad ? '_' : source.charAt(i);
            }
            out = out.replace(TRIM_RE, '').replace(new RegExp('_+', 'g'), '_');
            if (out.length > 60) { out = out.slice(0, 60); }
            return out || 'book';
        }

        // ---- ZIP (stored entries only) ------------------------------------

        var CRC_TABLE = (function () {
            var table = new Array(256);
            for (var n = 0; n < 256; n++) {
                var value = n;
                for (var bit = 0; bit < 8; bit++) {
                    value = (value & 1) ? (0xEDB88320 ^ (value >>> 1)) : (value >>> 1);
                }
                table[n] = value >>> 0;
            }
            return table;
        })();

        function crc32(bytes) {
            var value = 0xFFFFFFFF;
            for (var i = 0; i < bytes.length; i++) {
                value = (value >>> 8) ^ CRC_TABLE[(value ^ bytes[i]) & 0xFF];
            }
            return (value ^ 0xFFFFFFFF) >>> 0;
        }

        function u16(view, offset, value) {
            view[offset] = value & 0xFF;
            view[offset + 1] = (value >>> 8) & 0xFF;
        }

        function u32(view, offset, value) {
            view[offset] = value & 0xFF;
            view[offset + 1] = (value >>> 8) & 0xFF;
            view[offset + 2] = (value >>> 16) & 0xFF;
            view[offset + 3] = (value >>> 24) & 0xFF;
        }

        // 1980-01-01. Fixed rather than "now" so the same book exports to
        // byte-identical archives, which is what makes this testable.
        var DOS_DATE = 0x0021;

        function zip(files) {
            var entries = [];
            // Two separate accumulators: `localSize` is where each entry's own
            // header goes, `centralSize` is the directory's size. Using one
            // running total for both writes the central directory's position
            // into every local-header offset, and a reader then finds garbage.
            var localSize = 0;
            var i;
            for (i = 0; i < files.length; i++) {
                var name = textBytes(files[i].name);
                var data = files[i].bytes;
                var entry = {
                    name: name,
                    data: data,
                    crc: crc32(data),
                    offset: localSize
                };
                entries.push(entry);
                localSize += 30 + name.length + data.length;
            }
            var centralSize = 0;
            for (i = 0; i < entries.length; i++) {
                centralSize += 46 + entries[i].name.length;
            }
            var out = new Uint8Array(localSize + centralSize + 22);
            var at = 0;
            for (i = 0; i < entries.length; i++) {
                var entry = entries[i];
                u32(out, at, 0x04034B50);
                u16(out, at + 4, 20);
                u16(out, at + 6, 0x0800);
                u16(out, at + 8, 0);
                u16(out, at + 10, 0);
                u16(out, at + 12, DOS_DATE);
                u32(out, at + 14, entry.crc);
                u32(out, at + 18, entry.data.length);
                u32(out, at + 22, entry.data.length);
                u16(out, at + 26, entry.name.length);
                u16(out, at + 28, 0);
                out.set(entry.name, at + 30);
                out.set(entry.data, at + 30 + entry.name.length);
                at += 30 + entry.name.length + entry.data.length;
            }
            var central = at;
            for (i = 0; i < entries.length; i++) {
                var item = entries[i];
                u32(out, at, 0x02014B50);
                u16(out, at + 4, 20);
                u16(out, at + 6, 20);
                u16(out, at + 8, 0x0800);
                u16(out, at + 10, 0);
                u16(out, at + 12, 0);
                u16(out, at + 14, DOS_DATE);
                u32(out, at + 16, item.crc);
                u32(out, at + 20, item.data.length);
                u32(out, at + 24, item.data.length);
                u16(out, at + 28, item.name.length);
                u16(out, at + 30, 0);
                u16(out, at + 32, 0);
                u16(out, at + 34, 0);
                u16(out, at + 36, 0);
                u32(out, at + 38, 0);
                u32(out, at + 42, item.offset);
                out.set(item.name, at + 46);
                at += 46 + item.name.length;
            }
            u32(out, at, 0x06054B50);
            u16(out, at + 4, 0);
            u16(out, at + 6, 0);
            u16(out, at + 8, entries.length);
            u16(out, at + 10, entries.length);
            u32(out, at + 12, at - central);
            u32(out, at + 16, central);
            u16(out, at + 20, 0);
            return out;
        }

        // ---- TXT ----------------------------------------------------------

        function titleOf(book) {
            return book.name || (book.host + ' / ' + book.id);
        }

        function arrayIndex(list, value) {
            for (var i = 0; i < list.length; i++) {
                if (String(list[i]) === String(value)) { return i; }
            }
            return -1;
        }

        // Every heading has to read "第N章 <中文名>" or the file opens as one long
        // blob: a reader that splits a book into chapters looks for 第N章, and
        // readchapter answers with the site's Vietnamese machine translation
        // ("Chương 15: ..."). The Chinese original exists only in the chapter
        // list (`oridata`, app.v2.js:270) -- the same source the in-app reader
        // already uses for its own chapter titles -- so it is fetched once per
        // export and reused for every heading.
        //
        // The fallback number is the chapter's own place in the book, never the
        // export's index: a download of chapters 15-30 must not be relabelled
        // 1-16.
        function labelChapters(book, chapters) {
            var i18n = window.__stvI18n;
            if (!i18n || typeof i18n.chapterNames !== 'function') {
                return Promise.resolve(0);
            }
            return Promise.resolve(i18n.chapterNames(book.host, book.id))
                .then(function (found) {
                    var names = (found && found.names) || null;
                    var order = (found && found.order) || [];
                    var renamed = 0;
                    for (var i = 0; i < chapters.length; i++) {
                        var chapter = chapters[i];
                        var vietnamese = chapter.title || '';
                        var original = names && chapter.cid ? names[chapter.cid] : null;
                        var label = original
                            ? i18n.chineseChapterName(vietnamese, original) : null;
                        if (!label) { label = i18n.fixChapterTitle(vietnamese); }
                        label = String(label === undefined || label === null ? '' : label)
                            .replace(TRIM_RE, '');
                        if (label.indexOf('章') < 0) {
                            var position = arrayIndex(order, chapter.cid) + 1;
                            if (!position) { position = i + 1; }
                            label = '第' + position + '章' + (label ? ' ' + label : '');
                        }
                        chapter.label = label;
                        if (original) { renamed++; }
                    }
                    return renamed;
                }, function () { return 0; });
        }

        function chapterLabel(chapter, index) {
            var label = String(chapter.label || chapter.title || '').replace(TRIM_RE, '');
            return label || ('第' + (index + 1) + '章');
        }

        function buildTxt(book, chapters) {
            var title = titleOf(book);
            var lines = [];
            lines.push(title);
            if (book.author) { lines.push('作者：' + book.author); }
            lines.push('来源：' + book.host + ' / ' + book.id);
            lines.push('章节：' + chapters.length);
            for (var i = 0; i < chapters.length; i++) {
                lines.push('');
                lines.push('----------');
                lines.push(chapterLabel(chapters[i], i));
                lines.push('');
                for (var j = 0; j < chapters[i].paragraphs.length; j++) {
                    lines.push(chapters[i].paragraphs[j]);
                    lines.push('');
                }
            }
            return {
                title: title,
                chapters: chapters.length,
                filename: safeName(title) + '.txt',
                mime: 'text/plain',
                bytes: textBytes(lines.join(CRLF))
            };
        }

        // ---- EPUB ---------------------------------------------------------

        var CONTAINER_XML = '<?xml version="1.0" encoding="UTF-8"?>'
            + '<container version="1.0"'
            + ' xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            + '<rootfiles><rootfile full-path="OEBPS/content.opf"'
            + ' media-type="application/oebps-package+xml"/></rootfiles></container>';

        var STYLE_CSS = 'body { line-height: 1.6; margin: 1em; }'
            + 'p { margin: 0 0 0.9em 0; text-indent: 2em; }'
            + 'h2 { font-size: 1.15em; margin: 1.2em 0 0.8em 0;'
            + ' text-align: center; text-indent: 0; }'
            + 'body.cover { margin: 0; text-align: center; }'
            + 'body.cover img { max-width: 100%; }';

        function escapeXml(text) {
            return String(text)
                .replace(new RegExp('&', 'g'), '&amp;')
                .replace(new RegExp('<', 'g'), '&lt;')
                .replace(new RegExp('>', 'g'), '&gt;');
        }

        function pad4(value) {
            return ('0000' + value).slice(-4);
        }

        function xhtmlDocument(lang, title, bodyClass, body) {
            return '<?xml version="1.0" encoding="utf-8"?>'
                + '<!DOCTYPE html>'
                + '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="' + lang + '">'
                + '<head><title>' + escapeXml(title) + '</title>'
                + '<link rel="stylesheet" type="text/css" href="style.css"/></head>'
                + '<body' + (bodyClass ? ' class="' + bodyClass + '"' : '') + '>'
                + body + '</body></html>';
        }

        function chapterXhtml(lang, label, paragraphs) {
            var body = '<h2>' + escapeXml(label) + '</h2>';
            for (var i = 0; i < paragraphs.length; i++) {
                body += '<p>' + escapeXml(paragraphs[i]) + '</p>';
            }
            return xhtmlDocument(lang, label, '', body);
        }

        function coverXhtml(lang, title) {
            return xhtmlDocument(lang, title, 'cover',
                '<div><img src="images/cover.jpg" alt="' + escapeXml(title)
                + '"/></div>');
        }

        function buildEpub(book, chapters, cover) {
            var title = titleOf(book);
            var author = book.author || '';
            // The text this file carries is the translated side of the site:
            // chapter bodies arrive in Chinese, and since the sixteenth round so
            // do the headings. Declaring `vi` made a reader such as iOS Books lay
            // the whole book out with Vietnamese hyphenation, dictionary and
            // speech rules while showing Chinese characters.
            var lang = 'zh';
            var manifest = [];
            var spine = [];
            var navPoints = [];
            var navItems = [];
            var files = [];
            var i;
            var label;

            files.push({ name: 'mimetype', bytes: textBytes('application/epub+zip') });
            files.push({ name: 'META-INF/container.xml', bytes: textBytes(CONTAINER_XML) });
            files.push({ name: 'OEBPS/style.css', bytes: textBytes(STYLE_CSS) });

            if (cover && cover.length) {
                files.push({ name: 'OEBPS/images/cover.jpg', bytes: cover });
                files.push({ name: 'OEBPS/cover.xhtml',
                             bytes: textBytes(coverXhtml(lang, title)) });
                manifest.push('<item id="cover-image" href="images/cover.jpg"'
                    + ' media-type="image/jpeg"/>');
                manifest.push('<item id="cover" href="cover.xhtml"'
                    + ' media-type="application/xhtml+xml"/>');
                spine.push('<itemref idref="cover"/>');
            }

            for (i = 0; i < chapters.length; i++) {
                var id = 'chapter-' + pad4(i + 1);
                var href = id + '.xhtml';
                label = chapterLabel(chapters[i], i);
                files.push({ name: 'OEBPS/' + href,
                             bytes: textBytes(chapterXhtml(lang, label,
                                 chapters[i].paragraphs)) });
                manifest.push('<item id="' + id + '" href="' + href
                    + '" media-type="application/xhtml+xml"/>');
                spine.push('<itemref idref="' + id + '"/>');
                navPoints.push('<navPoint id="navPoint-' + (i + 1) + '" playOrder="'
                    + (i + 1) + '"><navLabel><text>' + escapeXml(label)
                    + '</text></navLabel><content src="' + href + '"/></navPoint>');
                navItems.push('<li><a href="' + href + '">' + escapeXml(label) + '</a></li>');
            }

            manifest.push('<item id="nav" href="nav.xhtml"'
                + ' media-type="application/xhtml+xml" properties="nav"/>');
            manifest.push('<item id="ncx" href="toc.ncx"'
                + ' media-type="application/x-dtbncx+xml"/>');
            manifest.push('<item id="style" href="style.css" media-type="text/css"/>');

            var identifier = 'urn:sangtacreader:' + safeName(book.host) + '-'
                + String(book.id);
            var opf = '<?xml version="1.0" encoding="utf-8"?>'
                + '<package xmlns="http://www.idpf.org/2007/opf" version="3.0"'
                + ' unique-identifier="bookid">'
                + '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
                + '<dc:identifier id="bookid">' + escapeXml(identifier) + '</dc:identifier>'
                + '<dc:title>' + escapeXml(title) + '</dc:title>'
                + '<dc:creator>' + escapeXml(author) + '</dc:creator>'
                + '<dc:language>' + lang + '</dc:language>'
                + '<meta property="dcterms:modified">1980-01-01T00:00:00Z</meta>'
                + (cover && cover.length
                    ? '<meta name="cover" content="cover-image"/>' : '')
                + '</metadata>'
                + '<manifest>' + manifest.join('') + '</manifest>'
                + '<spine toc="ncx">' + spine.join('') + '</spine>'
                + '</package>';
            files.push({ name: 'OEBPS/content.opf', bytes: textBytes(opf) });

            var ncx = '<?xml version="1.0" encoding="utf-8"?>'
                + '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
                + '<head><meta name="dtb:uid" content="' + escapeXml(identifier) + '"/>'
                + '<meta name="dtb:depth" content="1"/>'
                + '<meta name="dtb:totalPageCount" content="0"/>'
                + '<meta name="dtb:maxPageNumber" content="0"/></head>'
                + '<docTitle><text>' + escapeXml(title) + '</text></docTitle>'
                + '<navMap>' + navPoints.join('') + '</navMap></ncx>';
            files.push({ name: 'OEBPS/toc.ncx', bytes: textBytes(ncx) });

            var navBody = '<nav xmlns:epub="http://www.idpf.org/2007/ops"'
                + ' epub:type="toc" id="toc"><h2>' + escapeXml(title)
                + '</h2><ol>' + navItems.join('') + '</ol></nav>';
            files.push({ name: 'OEBPS/nav.xhtml',
                         bytes: textBytes(xhtmlDocument(lang, title, '', navBody)) });

            return {
                title: title,
                chapters: chapters.length,
                filename: safeName(title) + '.epub',
                mime: 'application/epub+zip',
                bytes: zip(files)
            };
        }

        // ---- cover --------------------------------------------------------

        // Covers arrive as base64 because the native Http plugin returns
        // responseType arraybuffer that way (SangTacHttpPlugin.swift:749). A
        // failure is not fatal: the book exports without a cover image.
        function fetchCover(book) {
            var plugin = window.Capacitor && window.Capacitor.Plugins
                && window.Capacitor.Plugins.Http;
            var url = book.thumb || book.cover || '';
            if (!plugin || !url || typeof plugin.get !== 'function') {
                return Promise.resolve(null);
            }
            if (typeof window.imgSrc === 'function') { url = window.imgSrc(url); }
            return plugin.get({ url: url, responseType: 'arraybuffer' })
                .then(function (response) {
                    if (!response || typeof response.data !== 'string'
                        || !response.data) {
                        return null;
                    }
                    return base64Bytes(response.data);
                }, function (error) {
                    note('EXPORT', 'cover fetch failed for ' + url + ': ' + error);
                    return null;
                });
        }

        // ---- native hand-off ----------------------------------------------

        // The bridge carries the archive as one base64 string, so the ceiling is
        // about memory on both sides rather than any protocol limit. A book this
        // large is hundreds of chapters of unbroken text.
        var MAX_EXPORT_BYTES = 48 * 1024 * 1024;

        function sendFile(filename, mime, bytes) {
            var plugin = window.Capacitor && window.Capacitor.Plugins
                && window.Capacitor.Plugins.App;
            if (!plugin || typeof plugin.exportFile !== 'function') {
                return Promise.reject(new Error('这个版本还没有导出功能'));
            }
            if (bytes.length > MAX_EXPORT_BYTES) {
                return Promise.reject(new Error('内容太大，无法一次导出'));
            }
            return plugin.exportFile({
                filename: filename,
                mime: mime,
                data: base64(bytes)
            });
        }

        // ---- entry point --------------------------------------------------

        function resolveMeta(book) {
            var meta = {
                host: book.host,
                id: book.id,
                name: book.name || '',
                author: book.author || '',
                thumb: book.thumb || ''
            };
            if (meta.name) { return Promise.resolve(meta); }
            var app = window.app;
            if (!app || !app.net || typeof app.net.getCacheLater !== 'function') {
                return Promise.resolve(meta);
            }
            var url = '/mobile/bookinfo.php?hid=' + book.id + '&host=' + book.host;
            return app.net.getCacheLater(url).then(function (down) {
                var info = down && down.book ? down.book : null;
                if (info) {
                    if (info.name) { meta.name = info.name; }
                    if (info.author) { meta.author = info.author; }
                    if (info.thumb) { meta.thumb = info.thumb; }
                }
                return meta;
            }, function () { return meta; });
        }

        function reset(node, label) {
            node.__stvExportBusy = false;
            node.textContent = label || '导出';
            node.disabled = false;
        }

        function run(book, format, node) {
            if (node.__stvExportBusy) { return; }
            node.__stvExportBusy = true;
            node.disabled = true;
            node.textContent = '准备中';
            var app = window.app;
            var target = app && app.offlineBook && app.offlineBook.getExistedBook
                ? app.offlineBook.getExistedBook({ host: book.host, id: book.id })
                : null;
            if (!target || typeof target.getChapterDownloaded !== 'function') {
                toast('这本书没有可导出的离线内容');
                reset(node);
                return;
            }
            resolveMeta(book).then(function (meta) {
                return readChapters(target, function (done, total) {
                    node.textContent = '读取 ' + done + '/' + total;
                }).then(function (read) {
                    if (!read.chapters.length) {
                        throw new Error('没有读到章节内容');
                    }
                    note('EXPORT', 'read ' + read.chapters.length + ' of ' + read.total
                        + ' chapter(s) for ' + book.host + '/' + book.id
                        + (read.unreadable ? ', ' + read.unreadable + ' unreadable' : ''));
                    node.textContent = '整理章节名';
                    return labelChapters(meta, read.chapters).then(function (renamed) {
                        note('EXPORT', 'chapter headings: ' + renamed + ' of '
                            + read.chapters.length + ' carry a Chinese name, first='
                            + chapterLabel(read.chapters[0], 0));
                        node.textContent = '打包中';
                        if (format !== 'epub') { return buildTxt(meta, read.chapters); }
                        return fetchCover(meta).then(function (cover) {
                            return buildEpub(meta, read.chapters, cover);
                        });
                    });
                });
            }).then(function (payload) {
                node.textContent = '导出中';
                note('EXPORT', payload.filename + ' (' + payload.mime + '), '
                    + payload.chapters + ' chapter(s), ' + payload.bytes.length
                    + ' byte(s)');
                return sendFile(payload.filename, payload.mime, payload.bytes)
                    .then(function () {
                        toast('已导出《' + payload.title + '》：' + payload.chapters
                            + ' 章，' + format.toUpperCase());
                        note('EXPORT', 'handed ' + payload.filename + ' to the system');
                        reset(node);
                    });
            }).then(null, function (error) {
                note('ERR', 'export failed for ' + book.host + '/' + book.id + ': '
                    + error);
                toast('导出失败：' + (error && error.message ? error.message : error));
                reset(node);
            });
        }

        function dismiss(pop) {
            var overlay = pop && pop.parentNode;
            if (!overlay) { return; }
            if (typeof overlay.hide === 'function') { overlay.hide(); return; }
            if (overlay.removeChild) { overlay.removeChild(pop); }
        }

        function chooseFormat(book, node) {
            var app = window.app;
            var ctx = app && app.context;
            if (!ctx || typeof ctx.showPopup !== 'function') { return; }
            ctx.showPopup({
                title: '导出《' + titleOf(book) + '》',
                body: '<center>选择导出格式<br>'
                    + 'TXT：纯文本，带章节标题<br>'
                    + 'EPUB：带封面，可在阅读器里直接打开</center>',
                button: '<button action=stvtxt>导出 TXT</button>'
                    + '<button action=stvepub>导出 EPUB</button>',
                action: {
                    stvtxt: function (pop) { dismiss(pop); run(book, 'txt', node); },
                    stvepub: function (pop) { dismiss(pop); run(book, 'epub', node); }
                }
            });
        }

        // Called by the downloaded row's own action bar (pageRepair,
        // decorateDownloadedRow) so the row keeps a single renderer wrapper.
        function button(book) {
            if (!book || !book.host || !book.id) { return null; }
            var node = document.createElement('button');
            node.textContent = '导出';
            node.setAttribute('style', 'padding:6px 12px;font-size:13px;border-radius:6px;');
            node.addEventListener('click', function (event) {
                event.stopPropagation();
                event.preventDefault();
                chooseFormat(book, node);
            });
            return node;
        }

        window.__stvExport = {
            button: button,
            buildTxt: buildTxt,
            buildEpub: buildEpub,
            zip: zip,
            textBytes: textBytes,
            base64: base64,
            chapterParagraphs: chapterParagraphs,
            safeName: safeName,
            run: run
        };
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
        // The API key does NOT live in STORE_KEY. app.storage is plaintext inside
        // the app container, this page shares a JS context with the site's own
        // scripts, and settingsBackup mirrors every app.storage key into the
        // keychain backup. The key gets its own this-device-only keychain item and
        // the stored record keeps only a boolean (hasApiKey).
        var SECRET_KEY = 'translate.apiKey';
        var PANEL_ID = 'stv-translate-panel';
        var NL = String.fromCharCode(10);

        var ENGINE_LABELS = [
            ['apple', 'iOS 系统离线（推荐，免密钥）'],
            ['free', '免密钥联网（微软 Edge 通道）'],
            ['googlefree', '免密钥联网（谷歌翻译通道）'],
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
                hasApiKey: false,
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

        // ---- secret store (the API key) -----------------------------------

        function secretPlugin() {
            var plugin = appPlugin();
            return (plugin && typeof plugin.secretSave === 'function'
                && typeof plugin.secretLoad === 'function') ? plugin : null;
        }

        function writeSecret(value) {
            var plugin = secretPlugin();
            if (!plugin) { return Promise.reject(new Error('原生密钥存储不可用')); }
            return Promise.resolve(plugin.secretSave({ key: SECRET_KEY, value: value || '' }));
        }

        // What actually goes into app.storage: everything except the key itself.
        // `apiKey` stays in the object (the engines read config.apiKey) but is
        // written as an empty string, so a script that dumps the store -- or the
        // keychain mirror of it -- learns only whether a key is configured.
        function storedForm(config) {
            var out = {};
            for (var field in config) {
                if (!Object.prototype.hasOwnProperty.call(config, field)) { continue; }
                if (field === 'apiKey' || field === 'clearKey') { continue; }
                out[field] = config[field];
            }
            out.apiKey = '';
            return out;
        }

        function persistSettings(config) {
            var app = window.app;
            var storage = app && app.storage;
            if (!storage || typeof storage.set !== 'function') { return Promise.resolve(); }
            return Promise.resolve(storage.set(STORE_KEY, JSON.stringify(storedForm(config))));
        }

        /**
         Pull the key out of the keychain into memory. Called from loadSettings,
         so every engine sees the same config.apiKey it always did.

         The `legacy` branch is the upgrade path: builds before this change wrote
         the key in plaintext into app.storage. When one of those records is found
         the key is moved to the keychain and the record rewritten without it, so
         the plaintext copy does not survive. If the keychain write fails the
         plaintext value is kept -- losing the user's key is worse than leaving it
         where it was.
         */
        function hydrateSecret(config) {
            var plugin = secretPlugin();
            if (!plugin) { return Promise.resolve(config); }
            var legacy = typeof config.apiKey === 'string' ? config.apiKey : '';
            if (legacy && !config.hasApiKey) {
                return writeSecret(legacy).then(function () {
                    config.hasApiKey = true;
                    note('TRANSLATE', 'API Key 已移入 Keychain（原明文存储已清除）');
                    return persistSettings(config);
                }, function (error) {
                    note('ERR', 'API Key 迁移失败，保留原存储: ' + messageOf(error));
                }).then(function () { return config; });
            }
            if (!config.hasApiKey) { return Promise.resolve(config); }
            return Promise.resolve(plugin.secretLoad({ key: SECRET_KEY })).then(function (result) {
                var value = result && typeof result.value === 'string' ? result.value : '';
                if (value) { config.apiKey = value; }
                return config;
            }, function (error) {
                note('ERR', 'API Key 读取失败: ' + messageOf(error));
                return config;
            });
        }

        function loadSettings() {
            if (settings) { return Promise.resolve(settings); }
            var base = defaults();
            var app = window.app;
            var storage = app && app.storage;
            if (!storage || typeof storage.get !== 'function') {
                settings = base;
                return hydrateSecret(settings);
            }
            return Promise.resolve(storage.get(STORE_KEY)).then(function (raw) {
                settings = mergeSettings(base, raw);
                return hydrateSecret(settings);
            }, function (error) {
                note('ERR', 'translate settings read failed: ' + messageOf(error));
                settings = base;
                return hydrateSecret(settings);
            });
        }

        /**
         Save the panel's values. The key field starts empty on every open, so an
         empty field means "leave the stored key alone" and only the 清除 button
         removes it -- a save can never silently wipe a credential the user cannot
         see.
         */
        function saveSettings(next) {
            var typed = typeof next.apiKey === 'string' ? next.apiKey : '';
            var has = !!next.hasApiKey;
            var live = settings ? settings.apiKey : '';
            var work = Promise.resolve();

            if (next.clearKey) {
                has = false;
                live = '';
                work = writeSecret('');
            } else if (typed) {
                has = true;
                live = typed;
                work = writeSecret(typed);
            }

            return work.then(function () {
                settings = next;
                settings.apiKey = live;
                settings.hasApiKey = has;
                delete settings.clearKey;
                return persistSettings(settings).then(function () {
                    note('TRANSLATE', 'settings saved (engine=' + next.engine
                        + ', key=' + (has ? 'set' : 'none') + ')');
                    // The Cbox frame is a separate document with no access to
                    // app.storage, so it keeps its own copy of the auto flag and
                    // can only be told about a change over postMessage.
                    cboxMessage({ stvCbox: 'settings', auto: !!settings.auto });
                }, function (error) {
                    note('ERR', 'translate settings save failed: ' + messageOf(error));
                });
            }, function (error) {
                note('ERR', 'API Key 保存失败: ' + messageOf(error));
                throw error;
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

        // Chrome's own translation endpoint: the same keyless channel
        // newsnook-ios uses for Google (`translate_a/single` with `client=gtx`).
        // It answers one text per request -- the multi-`q` form is not stable --
        // so throughput here is concurrency, not batch size, and everything
        // below exists to cut the number of requests and widen the pool.
        var GTX_URL = 'https://translate.googleapis.com/translate_a/single';
        // newsnook-ios pins 3 because its feed is a handful of paragraphs. A
        // faction board is 117 rows in one tap and the reader waits through all
        // of it, so the pool starts at the same conservative 3 and then ramps:
        // every GTX_RAMP_AFTER clean answers add one worker up to the ceiling,
        // and any failure halves the width. A channel that begins to
        // rate-limit therefore settles at whatever it is actually serving
        // instead of failing a fixed fraction of the page.
        var GTX_MIN_CONCURRENCY = 2;
        var GTX_START_CONCURRENCY = 3;
        var GTX_MAX_CONCURRENCY = 8;
        var GTX_RAMP_AFTER = 6;

        // The same string recurs inside one sweep (a faction name reappears in
        // its own description) and the whole board is re-read on the next visit,
        // so answers are kept. localStorage rather than app.storage: this is
        // read inside the request path and Capacitor Preferences resolves a
        // tick later, which is too late to skip the request.
        var GTX_CACHE_KEY = 'stv.translate.cache';
        var GTX_CACHE_MAX = 4000;
        var gtxCache = null;
        var gtxCacheDirty = false;

        // gtx speaks Google's own codes: zh-Hans / zh-Hant are BCP-47 and are
        // not what it expects for Chinese.
        function gtxLanguage(code) {
            var lower = String(code).toLowerCase();
            if (lower.indexOf('zh-hant') === 0) { return 'zh-TW'; }
            if (lower.indexOf('zh') === 0) { return 'zh-CN'; }
            return String(code);
        }

        function gtxCacheLoad() {
            if (gtxCache) { return gtxCache; }
            gtxCache = {};
            try {
                var raw = window.localStorage
                    && window.localStorage.getItem(GTX_CACHE_KEY);
                if (raw) {
                    var parsed = JSON.parse(raw);
                    if (parsed && typeof parsed === 'object') { gtxCache = parsed; }
                }
            } catch (e) {
                gtxCache = {};
            }
            return gtxCache;
        }

        function gtxCacheSave() {
            if (!gtxCacheDirty || !gtxCache) { return; }
            gtxCacheDirty = false;
            try {
                if (window.localStorage) {
                    window.localStorage.setItem(GTX_CACHE_KEY,
                        JSON.stringify(gtxCache));
                }
            } catch (e) {
                // A full store is not worth failing a translation over: drop it
                // and let the next sweep rebuild what it needs.
                gtxCache = {};
                try { window.localStorage.removeItem(GTX_CACHE_KEY); } catch (e2) {}
            }
        }

        function gtxKey(text, source, target) {
            return gtxLanguage(source || 'auto') + '>' + gtxLanguage(target)
                + '>' + text;
        }

        function gtxRemember(key, value) {
            var cache = gtxCacheLoad();
            if (key in cache) { return; }
            var keys = Object.keys(cache);
            if (keys.length >= GTX_CACHE_MAX) {
                // Oldest insertion order, dropped in a batch: one eviction pass
                // per 200 new entries rather than one per entry.
                for (var i = 0; i < keys.length && i < 200; i++) {
                    delete cache[keys[i]];
                }
            }
            cache[key] = value;
            gtxCacheDirty = true;
        }

        // A string with no Latin letter cannot come back changed: a bare URL, a
        // run of punctuation, an emoji-only name and whitespace are all answers
        // that equal their input, and each one still costs a round trip. CJK is
        // already the target language, so it is skipped too. Vietnamese is Latin
        // script with diacritics, hence the 192..537 band.
        function gtxWorthSending(text) {
            var value = String(text);
            for (var i = 0; i < value.length; i++) {
                var code = value.charCodeAt(i);
                if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122)) {
                    return true;
                }
                if (code >= 192 && code <= 537) { return true; }
            }
            return false;
        }

        function gtxOne(text, source, target) {
            var url = GTX_URL + '?client=gtx&dt=t&sl='
                + encodeURIComponent(source && source !== 'auto'
                    ? gtxLanguage(source) : 'auto')
                + '&tl=' + encodeURIComponent(gtxLanguage(target))
                + '&q=' + encodeURIComponent(text);
            return httpRequest('GET', url, { 'Accept': 'application/json' })
                .then(function (response) {
                    var data = bodyOf(response);
                    var segments = data && data[0];
                    if (!segments || !segments.length) {
                        throw new Error('谷歌通道没有返回译文');
                    }
                    var out = '';
                    for (var i = 0; i < segments.length; i++) {
                        var piece = segments[i] && segments[i][0];
                        if (typeof piece === 'string') { out += piece; }
                    }
                    if (!out) { throw new Error('谷歌通道没有返回译文'); }
                    return out;
                });
        }

        /**
         Four things happen before a request is made, because each one removes
         requests rather than making them faster:

           * a cached answer is used as-is (a revisit of the same board costs
             nothing);
           * a text that cannot change is answered with itself;
           * identical texts inside one sweep share a single request;
           * whatever is left goes through a pool that widens while the channel
             is healthy and halves when it is not.
         */
        function googleFreeBatch(texts, source, target) {
            var out = new Array(texts.length);
            var cache = gtxCacheLoad();
            var order = [];
            var slots = {};
            var skipped = 0;
            var cached = 0;
            var i;

            for (i = 0; i < texts.length; i++) {
                var text = texts[i];
                var key = gtxKey(text, source, target);
                if (Object.prototype.hasOwnProperty.call(cache, key)) {
                    out[i] = cache[key];
                    cached++;
                    continue;
                }
                if (!gtxWorthSending(text)) {
                    out[i] = text;
                    gtxRemember(key, text);
                    skipped++;
                    continue;
                }
                if (!slots[key]) {
                    slots[key] = [];
                    order.push({ key: key, text: text });
                }
                slots[key].push(i);
            }

            if (!order.length) {
                gtxCacheSave();
                note('TRANSLATE', 'nothing to send (谷歌通道): ' + cached
                    + ' cached, ' + skipped + ' cannot change');
                return Promise.resolve(out);
            }

            var next = 0;
            var width = Math.min(GTX_START_CONCURRENCY, order.length);
            var clean = 0;
            var failed = 0;
            var firstError = null;

            function place(item, piece, remember) {
                var list = slots[item.key];
                for (var j = 0; j < list.length; j++) { out[list[j]] = piece; }
                if (remember) { gtxRemember(item.key, piece); }
            }

            function worker() {
                if (next >= order.length) { return Promise.resolve(); }
                var item = order[next++];
                return gtxOne(item.text, source, target).then(function (piece) {
                    place(item, piece, true);
                    clean++;
                    if (clean >= GTX_RAMP_AFTER && width < GTX_MAX_CONCURRENCY) {
                        clean = 0;
                        width++;
                        // The new worker shares `next`, so widening the pool
                        // never sends the same text twice.
                        return worker();
                    }
                    return worker();
                }, function (error) {
                    failed++;
                    clean = 0;
                    if (!firstError) { firstError = error; }
                    if (width > GTX_MIN_CONCURRENCY) {
                        width = Math.max(GTX_MIN_CONCURRENCY,
                            Math.floor(width / 2));
                    }
                    // A failure is transient, so it is NOT cached: the next
                    // sweep has to try this text again.
                    place(item, item.text, false);
                    return worker();
                });
            }

            var workers = [];
            for (i = 0; i < width; i++) { workers.push(worker()); }
            return Promise.all(workers).then(function () {
                gtxCacheSave();
                if (failed && failed === order.length) { throw firstError; }
                if (failed) {
                    note('TRANSLATE', failed + ' of ' + order.length
                        + ' request(s) kept the original text (谷歌通道)');
                }
                note('TRANSLATE', '谷歌通道 sent ' + order.length + ' request(s)'
                    + ' for ' + texts.length + ' item(s): ' + cached + ' cached, '
                    + skipped + ' cannot change, width ended at ' + width);
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

        // The key rides in a header, never in the query string. The native Http
        // plugin writes every request URL into the diagnostic panel -- which has a
        // COPY button -- and into the system log, so a `?key=` would hand the
        // user's Google credential to anyone who taps COPY once. Same header the
        // official client sends.
        function googleBatch(texts, source, target, config) {
            var url = 'https://translation.googleapis.com/language/translate/v2';
            var payload = { q: texts, target: target, format: 'text' };
            if (source && source !== 'auto') { payload.source = source; }
            return httpRequest('POST', url,
                { 'Content-Type': 'application/json; charset=UTF-8',
                  'X-goog-api-key': config.apiKey },
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
            if (engine === 'googlefree') {
                return googleFreeBatch(texts, source, target);
            }
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

        // Chunking exists to bound a request BODY: free (Edge), azure, google,
        // deepl and openai all send a whole array in one call, so MAX_CHARS
        // decides how many calls there are. gtx sends one text per call and
        // fans out on its own, so chunking it only serialises the sweep -- the
        // 2026-10-04 log shows the faction board split into two chunks of ~60
        // and the second waiting for the first, which is half of the 14 seconds
        // the reader sat through. It gets the whole list and decides its own
        // width.
        var POOLED_ENGINES = ['googlefree'];

        function runTranslate(texts, source, target, config) {
            var engine = config.engine || 'apple';
            if (engine !== 'apple') {
                if (POOLED_ENGINES.indexOf(engine) >= 0) {
                    return engineBatch(texts, source, target, config);
                }
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

        // A faction row is `view-listthelucitem` (page-vip:2222): `.name` and
        // `.description` under `.theluciteminfo`. One 译 per row, under the
        // description. Two nodes, one request -- the name alone reads like a
        // fragment, and the row is what the reader is looking at.
        function decorateFaction(item) {
            if (!item || !item.getAttribute) { return; }
            if (item.getAttribute('stv-tr')) { return; }
            var info = q(item, '.theluciteminfo');
            if (!info) { return; }
            item.setAttribute('stv-tr', '1');
            var row = document.createElement('div');
            row.className = 'stv-translate-row';
            row.style.cssText = 'margin-top:4px;';
            var button = makeButton('译', 'stv-translate-one');
            button.style.fontSize = '12px';
            button.style.padding = '2px 8px';
            button.style.marginLeft = '0';
            button.addEventListener('click', function (event) {
                stop(event);
                translateNodes(button, [q(info, '.name'), q(info, '.description')]);
            }, true);
            row.appendChild(button);
            info.appendChild(row);
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

        // The multi-node sibling of translateOne(): a faction row is a name plus a
        // description, and one tap should cost one request rather than two. Same
        // restore/attribute rules as everywhere else, so 原文 still undoes it.
        function translateNodes(button, nodes) {
            var live = [];
            var texts = [];
            var restored = false;
            for (var i = 0; i < nodes.length; i++) {
                var node = nodes[i];
                if (!node || !node.getAttribute) { continue; }
                if (originalOf(node) !== null) { restore(node, button); restored = true; continue; }
                if (node.getAttribute('stv-tr-done')) { continue; }
                var text = textOf(node);
                if (!text) { continue; }
                live.push(node);
                texts.push(text);
            }
            if (!live.length) {
                if (restored) { button.textContent = '译'; }
                return;
            }
            loadSettings().then(function (config) {
                button.textContent = '…';
                return runTranslate(texts, config.readSource, config.readTarget, config)
                    .then(function (out) {
                        var done = 0;
                        for (var j = 0; j < live.length; j++) {
                            var piece = out[j];
                            if (typeof piece !== 'string' || !piece || piece === texts[j]) {
                                live[j].setAttribute('stv-tr-done', '1');
                                continue;
                            }
                            live[j].setAttribute('stv-orig', live[j].innerHTML);
                            live[j].textContent = piece;
                            done++;
                        }
                        button.textContent = done ? '原文' : '译';
                        note('TRANSLATE', 'translated ' + done + ' of ' + live.length
                            + ' node(s) in one row with ' + config.engine);
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
            // 社区 → 势力 (app.fun.showListFaction, page-vip:4891): the board is
            // built from /mobile/jsonify.php?ajax=getlistfaction and every row is
            // a faction name plus a Vietnamese description.
            var factions = qq(scope, '.listthelucitem');
            for (var k = 0; k < factions.length; k++) {
                var info = q(factions[k], '.theluciteminfo');
                if (!info) { continue; }
                var parts = [q(info, '.name'), q(info, '.description')];
                for (var m = 0; m < parts.length; m++) {
                    var part = parts[m];
                    if (!part || !part.getAttribute) { continue; }
                    if (part.getAttribute('stv-orig') !== undefined
                        && part.getAttribute('stv-orig') !== null) { continue; }
                    if (part.getAttribute('stv-tr-done')) { continue; }
                    var factionText = textOf(part);
                    if (factionText) {
                        out.push({ node: part, kind: 'faction', text: factionText });
                    }
                }
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
            // The Cbox board is a cross-origin frame: none of its text is in this
            // document, so there is nothing for textTargets() to collect. Hand the
            // sweep to the frame and let it report progress on its own button.
            if (q(page, '.cbox')) {
                var sent = cboxMessage({ stvCbox: 'sweep' });
                if (button) { button.textContent = sent ? '翻译中…' : '等加载…'; }
                note('TRANSLATE', 'Cbox sweep requested (' + sent + ' frame(s) known)');
                setTimeout(function () {
                    if (button) { button.textContent = '译全部'; }
                }, 8000);
                return;
            }
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
        // book comment page (`.commentview`, :914), the embeds used by a single
        // post and by a user home (`.comments`/`.embedcomment`, :2892) and the
        // faction board (`.listtheluc`, :1888).
        // The Cbox board is a cross-origin iframe and cannot be reached from
        // here.
        function hasTranslatableContent(page) {
            return !!(q(page, '.commentview') || q(page, '.comments')
                || q(page, '.embedcomment') || q(page, '.posts')
                || q(page, '.listtheluc') || q(page, '.cbox'));
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
            var factions = qq(page, '.listthelucitem');
            for (var k = 0; k < factions.length; k++) { decorateFaction(factions[k]); }
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
                // The Cbox board has nothing to sweep on this side -- its text
                // lives in the cross-origin frame, which keeps its own observer
                // once it has been told the setting is on.
                if (q(page, '.cbox')) { cboxMessage({ stvCbox: 'settings', auto: true }); }
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

            // The asset cache (the assetCache block) can hold a stale file for
            // up to a day if the site republishes one without changing its name.
            // One tap here moves every stabilised URL to a new generation and
            // reloads, which is the only way out of a bad cache without a
            // reinstall.
            var cacheItem = document.createElement('div');
            cacheItem.className = 'settingitem stv-assetcache-entry';
            cacheItem.innerHTML = '<div class="settingitemtitle">强制刷新站点资源</div>'
                + '<div class=""><i class="fas fa-rotate-right"></i></div>';
            cacheItem.addEventListener('click', function (event) {
                stop(event);
                var cache = window.__stvAssetCache;
                if (!cache || typeof cache.refresh !== 'function') {
                    note('ERR', 'asset cache block is not installed');
                    return;
                }
                note('ASSET', 'forcing a refresh (generation ' + cache.token + ')');
                // The mirror's refreshed copies are the other half of "resources
                // the site has moved past": drop them in the same gesture, or the
                // row would only fix the half WebKit caches.
                var mirror = window.__stvAssetMirror;
                if (mirror && typeof mirror.forget === 'function') { mirror.forget(); }
                cache.refresh();
            }, true);
            host.appendChild(cacheItem);

            // The asset mirror keeps its own rows: a copy the site has moved past,
            // and the mirror itself, both have to be undoable without a reinstall.
            var mirrorBlock = window.__stvAssetMirror;
            if (mirrorBlock && typeof mirrorBlock.rows === 'function') {
                mirrorBlock.rows(host);
            } else {
                note('MIRROR', 'no settings rows: the mirror block is not installed');
            }

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

            // The stored key is never written back into the DOM. This panel shares
            // a JS context with the site's own scripts, and the field is a plain
            // text input, so echoing the key would hand it to anything running on
            // the page. The field starts empty; an empty field on save means
            // "keep the stored key", and only the 清除 button removes it.
            var keyStored = !!config.hasApiKey;
            var clearingKey = false;

            function keyPlaceholder() {
                return (keyStored && !clearingKey)
                    ? '已保存（留空则不修改）'
                    : 'Azure / Google / DeepL / OpenAI 的 Key';
            }

            var keyInput = textInput('', keyPlaceholder(), 'stv-translate-key');
            keyInput.style.flex = '1';
            var keyClear = makeButton('清除', 'stv-translate-key-clear');
            keyClear.style.cssText = BUTTON_CSS + 'margin-left:6px;';
            keyClear.style.display = keyStored ? '' : 'none';
            var keyWrap = document.createElement('div');
            keyWrap.style.cssText = 'display:flex;align-items:center;';
            keyWrap.appendChild(keyInput);
            keyWrap.appendChild(keyClear);
            row('API Key（系统离线与免密钥通道不用填）', keyWrap);
            keyClear.addEventListener('click', function (event) {
                stop(event);
                clearingKey = true;
                keyInput.value = '';
                keyInput.placeholder = keyPlaceholder();
                keyClear.style.display = 'none';
                status.textContent = 'Key 将在点“保存”后清除';
            }, true);

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
                // The field is empty whenever a key is already stored -- it is
                // never echoed back -- so an empty field has to resolve to the
                // stored key. Resolving it to "no key" would make the 测试 button
                // exercise the engine without a credential and report a
                // misleading failure.
                var typed = keyInput.value || '';
                var effective = clearingKey
                    ? ''
                    : (typed || (settings ? settings.apiKey : ''));
                return {
                    engine: enginePicker.__value() || 'apple',
                    apiKey: effective,
                    hasApiKey: keyStored,
                    clearKey: clearingKey,
                    region: regionInput.value || '',
                    endpoint: endpointInput.value || '',
                    model: modelInput.value || '',
                    readSource: readSourcePicker.__value() || 'vi',
                    readTarget: readTargetPicker.__value() || 'zh-Hans',
                    writeTarget: writeTargetPicker.__value() || 'vi',
                    auto: !!autoBox.checked
                };
            }

            // The field is emptied and re-masked after every save, so a key the
            // user just typed does not stay on screen (or in the DOM) either.
            function reflectKeyState() {
                keyStored = !!(settings && settings.hasApiKey);
                clearingKey = false;
                keyInput.value = '';
                keyInput.placeholder = keyPlaceholder();
                keyClear.style.display = keyStored ? '' : 'none';
            }

            var saveButton = makeButton('保存', 'stv-translate-save');
            saveButton.style.cssText = BUTTON_CSS
                + 'background:#2563eb;border-color:#3b82f6;color:#fff;';
            saveButton.addEventListener('click', function (event) {
                stop(event);
                var next = collect();
                saveSettings(next).then(function () {
                    reflectKeyState();
                    status.textContent = '已保存：' + engineName(next.engine)
                        + (keyStored ? '（Key 已存入 Keychain）' : '');
                    refreshLabels();
                }, function (error) {
                    status.textContent = '保存失败：' + messageOf(error);
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

        // ---- the delete button on a comment --------------------------------
        //
        // The site renders `.cmtdel` for the reader's own comments
        // (view-commentblock, page-vip:2350) and then never binds it:
        // app.comment.applyEvent (app.v2.js:3730) wires `.avatar`, `.name` and
        // `.cmtresp` and stops there, and no delete-comment call exists anywhere
        // in the bundles this repo mirrors -- the Android app's older page copy
        // has the same dead button, so it has never worked.
        //
        // Which endpoint deletes a comment is in no file we have: the site's PHP
        // is not shipped, the desktop bundle has no caller either, and the local
        // TLS block rules out probing with a real session. So this is the same
        // ladder the unlike button uses -- try the two shapes the site's own
        // comment API suggests, in order, and stop at the first answer that reads
        // as success. Whatever happened goes to the panel, so the next device log
        // settles it instead of guessing a second time.
        var DELETE_CALLS = [
            { how: 'post', target: '/', body: 'ajax=delcomment&cid=' },
            { how: 'post', target: '/', body: 'ajax=comment&sub=delcomment&cid=' },
            { how: 'get', target: '/mobile/comment.php?act=delcomment&cid=' }
        ];

        function dismissPopup(pop) {
            var overlay = pop && pop.parentNode;
            if (!overlay) { return; }
            if (typeof overlay.hide === 'function') { overlay.hide(); return; }
            if (overlay.removeChild) { overlay.removeChild(pop); }
        }

        // The block that owns the tapped button, walking up to the comment
        // template's root. `data-id` is stamped on it by applyEvent.
        function commentOf(target) {
            var node = target;
            var button = null;
            while (node && node.nodeType === 1) {
                if (!button && node.classList && node.classList.contains('cmtdel')) {
                    button = node;
                }
                if (node.getAttribute && node.getAttribute('view') === 'commentblock') {
                    return {
                        button: button || node,
                        block: node,
                        id: node.getAttribute('data-id')
                    };
                }
                node = node.parentElement;
            }
            return button ? { button: button, block: null, id: null } : null;
        }

        // Deliberately strict: a false "success" would tell the reader the comment
        // is gone while it is still there, and a false "failure" only costs the
        // next candidate. The site's own post path answers the bare string
        // "success" (app.v2.js:3872), so that plus the two JSON shapes is enough.
        function readsAsSuccess(answer) {
            if (answer === null || answer === undefined) { return false; }
            if (typeof answer === 'string') {
                var text = answer.replace(/ /g, '').toLowerCase();
                return text === 'success' || text.indexOf('"code":100') >= 0
                    || text.indexOf('"status":"success"') >= 0;
            }
            if (typeof answer === 'object') {
                return answer.code === 100 || answer.status === 'success'
                    || answer.ok === true;
            }
            return false;
        }

        function attemptDelete(step, cid) {
            var app = window.app;
            var net = app && app.net;
            if (!net) { return Promise.reject(new Error('app.net is missing')); }
            if (step.how === 'get') {
                return net.get(step.target + encodeURIComponent(cid), true);
            }
            return net.post(step.target, step.body + encodeURIComponent(cid));
        }

        function deleteComment(comment) {
            if (!comment.id) {
                note('ERR', 'comment delete: the block carries no data-id');
                hint('这条评论没有 id，无法删除');
                return;
            }
            var index = 0;
            var tried = [];
            var next = function () {
                if (index >= DELETE_CALLS.length) {
                    note('COMMENT', 'every candidate endpoint answered nothing for comment '
                        + comment.id + ': ' + tried.join(' | '));
                    // The site's own client has no delete-comment call at all: the
                    // complete `ajax=` list in its bundles is
                    // addbookmark/cboximg/faction/followbook/getbuyhistory/
                    // getchapterlist/getfollowing/getinv/getlistfaction/getnotify/
                    // like/listsavedhistory/loadhistory/login/logout/online/
                    // postcomment/querylikestatus/readchapter/register/replycomment/
                    // reportappscript/reportscripterror/savehistory/topic/trans/
                    // unlike/verifycaptcha -- and no delete anywhere. The button is
                    // dead on the site side too, so the honest answer is that, not
                    // another guess.
                    note('COMMENT', 'the site has no delete-comment endpoint: its own client'
                        + ' never calls one, and every shape tried answers an empty body');
                    hint('删除失败：站点没有删除评论的接口（不是 App 的问题）');
                    return;
                }
                var step = DELETE_CALLS[index++];
                var label = step.how + ' ' + (step.body || step.target);
                note('COMMENT', 'trying ' + label + ' for comment ' + comment.id);
                attemptDelete(step, comment.id).then(function (answer) {
                    var ok = readsAsSuccess(answer);
                    var seen = String(answer === null || answer === undefined ? '' : answer);
                    tried.push(label + ' -> ' + (ok ? 'success'
                        : (seen ? seen.slice(0, 40) : 'empty')));
                    if (!ok) { next(); return; }
                    note('COMMENT', 'comment ' + comment.id + ' deleted by ' + label);
                    if (comment.block && comment.block.parentNode) {
                        comment.block.parentNode.removeChild(comment.block);
                    }
                    hint('已删除这条评论');
                }, function (error) {
                    tried.push(label + ' -> ' + messageOf(error));
                    next();
                });
            };
            next();
        }

        // A destructive action never rides on a single tap: the site's own popup
        // template is the confirmation (app.context.popup, app.v2.js:2195).
        function askDeleteComment(comment) {
            var app = window.app;
            var ctx = app && app.context;
            if (!ctx || typeof ctx.showPopup !== 'function') {
                note('ERR', 'no popup template for the delete confirmation');
                hint('删除需要确认，这个版本的站点没有确认框');
                return;
            }
            try {
                ctx.showPopup({
                    title: '删除这条评论？',
                    body: '<center>删除后无法恢复。</center>',
                    button: '<button action=stvdelno>取消</button>'
                        + '<button action=stvdelok>删除</button>',
                    action: {
                        stvdelno: function (pop) { dismissPopup(pop); },
                        stvdelok: function (pop) {
                            dismissPopup(pop);
                            deleteComment(comment);
                        }
                    }
                });
                note('COMMENT', 'delete confirmation shown for comment ' + comment.id);
            } catch (error) {
                note('ERR', 'delete confirmation failed: ' + messageOf(error));
            }
        }

        document.addEventListener('click', function (event) {
            var comment = commentOf(event.target);
            if (!comment) { return; }
            stop(event);
            note('COMMENT', 'delete tapped on comment ' + String(comment.id));
            askDeleteComment(comment);
        }, true);

        // ---- popups: the faction window's own text --------------------------
        //
        // 社区 → 势力 translates the list, but the window that opens on a row
        // prints the description the server sent (app_v2.html:4907) plus the
        // hardcoded labels "Cấp:" / "Nhân số:" -- none of which goes through the
        // list's translation, so the reader taps a translated row and gets a
        // Vietnamese window (2026-10-04 report: "势力中可以正常翻译，但是弹出的申请说明
        // 没有翻译"). With auto translate on, any text node in a popup body that
        // still carries a Vietnamese-only letter goes to the engine as well.
        var VI_ONLY = 'ăâđêôơưĂÂĐÊÔƠƯ'
            + 'áàảãạấầẩẫậắằẳẵặéèẻẽẹếềểễệíìỉĩịóòỏõọốồổỗộớờởỡợúùủũụứừửữựýỳỷỹỵ';

        function hasVietnamese(text) {
            for (var i = 0; i < text.length; i++) {
                if (VI_ONLY.indexOf(text.charAt(i)) >= 0) { return true; }
            }
            return false;
        }

        function popupTargets(body) {
            var out = [];
            var walk = function (node) {
                var children = node.childNodes || [];
                for (var i = 0; i < children.length; i++) {
                    var child = children[i];
                    if (child.nodeType === 1) {
                        if (child.getAttribute
                            && child.getAttribute('stv-orig') !== undefined
                            && child.getAttribute('stv-orig') !== null) { continue; }
                        walk(child);
                        continue;
                    }
                    if (child.nodeType !== 3 || child.__stvPopupDone) { continue; }
                    var text = String(child.nodeValue || '').trim();
                    if (text.length < 5 || !hasVietnamese(text)) { continue; }
                    out.push({ node: child, text: text });
                }
            };
            walk(body);
            return out;
        }

        function runPopupBody(body, config) {
            var targets = popupTargets(body);
            if (!targets.length) { return; }
            var texts = [];
            for (var i = 0; i < targets.length; i++) {
                // Marked before the request, so a second sweep of the same popup
                // (the site re-renders it on every open) does not re-send them.
                targets[i].node.__stvPopupDone = true;
                texts.push(targets[i].text);
            }
            runTranslate(texts, config.readSource, config.readTarget, config)
                .then(function (out) {
                    var done = 0;
                    for (var j = 0; j < targets.length; j++) {
                        var piece = out[j];
                        if (typeof piece !== 'string' || !piece
                            || piece === targets[j].text) { continue; }
                        targets[j].node.nodeValue = piece;
                        done++;
                    }
                    note('TRANSLATE', 'popup: translated ' + done + ' of ' + targets.length
                        + ' line(s) with ' + config.engine);
                }, function (error) {
                    fail(error);
                });
        }

        function autoTranslatePopup(popup) {
            if (!popup || !popup.querySelector) { return; }
            loadSettings().then(function (config) {
                if (!config.auto) { return; }
                var bodies = qq(popup, '.popupedit_body');
                var yesno = q(popup, '.popupyesno_text');
                if (yesno) { bodies.push(yesno); }
                for (var i = 0; i < bodies.length; i++) {
                    runPopupBody(bodies[i], config);
                }
            });
        }

        // app.context.showPopup (app.v2.js:2291) is the single funnel for the
        // site's own windows; app.context.yesno builds its own, but its text is a
        // dictionary entry and the overlay already rewrites it.
        function hookPopup() {
            var app = window.app;
            var ctx = app && app.context;
            if (!ctx || typeof ctx.showPopup !== 'function') { return false; }
            if (ctx.__stvPopupHooked) { return true; }
            ctx.__stvPopupHooked = true;
            var original = ctx.showPopup;
            ctx.showPopup = function () {
                var popup = original.apply(this, arguments);
                try {
                    autoTranslatePopup(popup);
                } catch (error) {
                    note('ERR', 'popup translate hook: ' + messageOf(error));
                }
                return popup;
            };
            note('TRANSLATE', 'popup bodies are translated when auto translate is on');
            return true;
        }

        // ---- the Cbox frame bridge ------------------------------------------
        //
        // 社区 → Cbox is an iframe to www6.cbox.ws (page-vip:995), i.e. a
        // cross-origin document. Capacitor's own bridge script is injected with
        // `forMainFrameOnly: true` (node_modules/@capacitor/ios, JSExport.swift:20),
        // so the frame has no window.Capacitor and therefore no engine, no API
        // key and no settings; the site patches are main-frame-only as well.
        // postMessage is the only channel that crosses that boundary, so the
        // frame asks and this side -- which does have all three -- answers. The
        // other half is SitePatch.cboxFrame, the one block injected into every
        // frame.
        var cboxFrames = [];

        function cboxMessage(message) {
            for (var i = 0; i < cboxFrames.length; i++) {
                try {
                    cboxFrames[i].source.postMessage(message, cboxFrames[i].origin);
                } catch (error) {
                    note('ERR', 'cbox postMessage failed: ' + messageOf(error));
                }
            }
            return cboxFrames.length;
        }

        function rememberCboxFrame(source, origin) {
            for (var i = 0; i < cboxFrames.length; i++) {
                if (cboxFrames[i].source === source) {
                    cboxFrames[i].origin = origin;
                    return;
                }
            }
            cboxFrames.push({ source: source, origin: origin });
        }

        window.addEventListener('message', function (event) {
            var data = event && event.data;
            if (!data || typeof data !== 'object' || data.stvCbox === undefined) { return; }
            // A Cbox box is served from cbox.ws (cbox.im for some assets). The
            // check is on the origin the browser reports, never on the payload:
            // any page in the web view can post to us.
            if (typeof event.origin !== 'string' || event.origin.indexOf('cbox') < 0) {
                note('ERR', 'ignored a stvCbox message from ' + String(event.origin));
                return;
            }
            var source = event.source;
            if (!source || typeof source.postMessage !== 'function') { return; }
            rememberCboxFrame(source, event.origin);

            if (data.stvCbox === 'log') {
                note(String(data.tag || 'CBOX'), String(data.message || ''));
                return;
            }
            if (data.stvCbox === 'hello') {
                note('TRANSLATE', 'the Cbox frame asked for the translator');
                loadSettings().then(function (config) {
                    source.postMessage({ stvCbox: 'settings', auto: !!config.auto },
                        event.origin);
                });
                return;
            }
            if (data.stvCbox !== 'ask') { return; }
            var id = data.id;
            var texts = data.texts || [];
            loadSettings().then(function (config) {
                return runTranslate(texts, config.readSource, config.readTarget, config);
            }).then(function (out) {
                source.postMessage({ stvCbox: 'answer', id: id, out: out }, event.origin);
                note('TRANSLATE', 'Cbox: ' + out.length + ' line(s) answered');
            }, function (error) {
                source.postMessage({ stvCbox: 'answer', id: id, out: [] }, event.origin);
                fail(error);
            });
        }, false);

        var attempts = 0;
        var timer = setInterval(function () {
            attempts++;
            // Called unconditionally: `a && b && c` short-circuits, and a hook
            // whose subject is missing (app.comment on a page that never opened
            // one) would then keep the later hooks from ever installing.
            var page = hookPushPage();
            var embed = hookCommentEmbed();
            var popup = hookPopup();
            if ((page && embed && popup) || attempts > 2500) { clearInterval(timer); }
        }, 20);
    })();
    """

    // MARK: - The Cbox board's own frame

    /**
     社区 → Cbox is an iframe to www6.cbox.ws (page-vip:995). It is the only
     cross-origin document the app puts on screen, and it needs three things the
     main frame gets for free:

       1. A script that runs there at all. Every other block -- and Capacitor's
          own native bridge (node_modules/@capacitor/ios, JSExport.swift:20) --
          is injected with `forMainFrameOnly: true`. This block is the single
          exception, so its first line has to be a refusal: the reader's chapter
          frames are same-origin and must not pay for it.
       2. A translator. The frame has no window.Capacitor, so it asks the parent
          over postMessage. The parent's half is the bridge in
          `commentTranslate`, which owns the settings, the engines and the key.
       3. A way to say "translate this" without the parent's title bar, because
          the site scales the frame (`showWebCbox`, page-vip:4597) and the
          frame's own controls are the ones the reader is looking at.

     Nothing here is keyed on Cbox's class names: the box is a third-party
     document whose markup this repo has no copy of (the local DNS blackholes
     cbox.ws) and which changes without notice. "A text node with a letter in
     it, outside the frame's own controls" is the whole rule.
     */
    static let cboxFrame = """
    (function () {
        var here = (window.location && window.location.hostname) || '';
        if (here.indexOf('cbox') < 0) { return; }
        if (window.__stvCboxFrameInstalled) { return; }
        window.__stvCboxFrameInstalled = true;

        // Sixty lines per request: a chat box holds hundreds, and the parent's
        // engine chunks whatever it is handed.
        var LIMIT = 60;
        var SKIP = ['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA', 'INPUT', 'SELECT',
            'OPTION', 'IFRAME', 'CANVAS', 'SVG', 'BUTTON', 'LABEL', 'HEAD'];
        var LETTERS = /[A-Za-z]/;
        var SPACES = / /g;
        var auto = false;
        var nextId = 1;
        var pending = {};
        var button = null;
        var label = '';
        var timer = null;

        function post(message) {
            try {
                if (window.parent && window.parent !== window) {
                    window.parent.postMessage(message, '*');
                }
            } catch (error) {}
        }

        function note(message) {
            post({ stvCbox: 'log', tag: 'CBOX', message: message });
        }

        function tagOf(node) {
            return String((node && node.tagName) || '').toUpperCase();
        }

        function skipTag(tag) {
            for (var i = 0; i < SKIP.length; i++) { if (SKIP[i] === tag) { return true; } }
            return false;
        }

        function isOurs(node) {
            var walk = node;
            while (walk) {
                if (walk.getAttribute
                    && walk.getAttribute('data-stvtranslate')) { return true; }
                walk = walk.parentNode;
            }
            return false;
        }

        function isCandidate(node) {
            var parent = node.parentNode;
            if (!parent || parent.nodeType !== 1) { return false; }
            if (skipTag(tagOf(parent))) { return false; }
            if (isOurs(parent)) { return false; }
            var text = String(node.nodeValue || '').replace(SPACES, '');
            if (text.length < 2) { return false; }
            return LETTERS.test(text);
        }

        function collect() {
            var body = document.body;
            if (!body) { return []; }
            var all = [];
            var walk = function (node) {
                var children = node.childNodes;
                if (!children) { return; }
                for (var i = 0; i < children.length; i++) {
                    var child = children[i];
                    if (child.nodeType === 1) {
                        if (skipTag(tagOf(child))) { continue; }
                        walk(child);
                    } else if (child.nodeType === 3) {
                        if (child.__stvCboxDone) { continue; }
                        if (isCandidate(child)) { all.push(child); }
                    }
                }
            };
            walk(body);
            // Newest first: a chat box appends, so the tail of the document is
            // what the reader is looking at. The rest is picked up by the next
            // sweep, which is what lets the button work through a backlog
            // instead of re-sending the same sixty lines forever.
            var out = [];
            for (var j = all.length - 1; j >= 0 && out.length < LIMIT; j--) {
                out.push(all[j]);
            }
            return out;
        }

        function paint(text) {
            if (label === text) { return; }
            label = text;
            if (button) { button.textContent = text; }
        }

        function apply(nodes, out) {
            var done = 0;
            for (var i = 0; i < nodes.length; i++) {
                var node = nodes[i];
                if (!node || !node.parentNode) { continue; }
                node.__stvCboxDone = true;
                var piece = out[i];
                if (typeof piece !== 'string' || !piece) { continue; }
                if (piece === String(node.nodeValue)) { continue; }
                if (node.__stvCboxOrig === undefined) {
                    node.__stvCboxOrig = node.nodeValue;
                }
                node.nodeValue = piece;
                done++;
            }
            return done;
        }

        function sweep() {
            var nodes = collect();
            if (!nodes.length) {
                paint('译');
                post({ stvCbox: 'done', count: 0 });
                return;
            }
            var texts = [];
            for (var i = 0; i < nodes.length; i++) {
                texts.push(String(nodes[i].nodeValue));
            }
            var id = nextId++;
            pending[id] = nodes;
            paint('翻译中…');
            post({ stvCbox: 'ask', id: id, texts: texts });
        }

        function setAuto(on) {
            auto = !!on;
            if (!auto || window.__stvCboxObserver) { return; }
            if (!document.body || typeof MutationObserver !== 'function') { return; }
            var observer = new MutationObserver(function (records) {
                for (var i = 0; i < records.length; i++) {
                    // Our own button and our own writes are not new messages.
                    if (isOurs(records[i].target)) { continue; }
                    if (timer) { clearTimeout(timer); }
                    timer = setTimeout(sweep, 900);
                    return;
                }
            });
            observer.observe(document.body, { childList: true, subtree: true });
            window.__stvCboxObserver = observer;
            note('auto translate is on for this frame');
        }

        function build() {
            if (button) { return !!button.parentNode; }
            var host = document.body;
            if (!host) { return false; }
            var bar = document.createElement('div');
            bar.setAttribute('data-stvtranslate', 'cboxbar');
            bar.style.cssText = 'position:fixed;left:6px;bottom:6px;z-index:2147483645;'
                + 'display:flex;align-items:center;';
            button = document.createElement('button');
            button.setAttribute('data-stvtranslate', 'cboxbutton');
            button.style.cssText = 'padding:6px 10px;border-radius:8px;'
                + 'border:1px solid #555;background:rgba(20,20,20,0.85);color:#eee;'
                + 'font:12px/1.3 -apple-system,BlinkMacSystemFont,sans-serif;';
            button.textContent = '译';
            button.addEventListener('click', function (event) {
                event.stopPropagation();
                event.preventDefault();
                sweep();
            }, true);
            bar.appendChild(button);
            host.appendChild(bar);
            return true;
        }

        window.addEventListener('message', function (event) {
            var data = event && event.data;
            if (!data || typeof data !== 'object' || data.stvCbox === undefined) { return; }
            if (data.stvCbox === 'settings') { setAuto(!!data.auto); return; }
            if (data.stvCbox === 'sweep') { sweep(); return; }
            if (data.stvCbox !== 'answer') { return; }
            var nodes = pending[data.id];
            if (!nodes) { return; }
            delete pending[data.id];
            var done = apply(nodes, data.out || []);
            paint('译');
            post({ stvCbox: 'done', count: done });
            note(done + ' line(s) translated');
        }, false);

        function boot() {
            if (!build()) { return; }
            post({ stvCbox: 'hello' });
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', boot);
        } else {
            boot();
        }
    })();
    """

    // MARK: - The comic sources' bot check

    /**
     漫画点进去只有顶部的分类，一条数据都没有.

     The comic browser is a site feature that scrapes third-party manga sites
     through `window.AutoHttp` (app.v2.comicprovider.js:79), and BaoziManhua --
     the default source and every one of its 32 tabs -- now answers its list API
     with

        403 {"error":"challenge_required",
             "challenge_url":"/__gatekeeper_challenge/start?return=..."}

     (device log 23:15:40 / 23:16:01 / 23:18:06 / :09 / :10). The native plugin
     RESOLVES a 4xx with `error: true` rather than rejecting
     (SangTacHttpPlugin.swift:762), so `getComicList` gets that object, reads
     `.items` off it, and throws -- which is the `unhandledrejection` at
     comicprovider.js:628 in the same log.

     Two halves:

       1. The token is minted by a script, and a URLSession never runs scripts.
          So the challenge is solved where scripts do run -- a hidden frame in
          this web view, which shares WKWebsiteDataStore with the page and
          therefore with the cookie snapshot the native plugin reads.
       2. `baozimh.com` had to be added to the plugin's cookie allow-list
          (SangTacHttpPlugin.swift `cookieHosts`), or the retry would travel
          anonymous and be challenged again.

     A source that stays gated is not retried in a loop: one pass per host per
     five minutes, and the refusal is written to the panel so the next device log
     shows whether the challenge is solvable at all.
     */
    static let comicGate = """
    (function () {
        if (window.__stvComicGateInstalled) { return; }
        window.__stvComicGateInstalled = true;

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        // Every block is its own WKUserScript and its own IIFE, so a helper
        // defined in another block is NOT in scope. `messageOf` is used by the
        // failure paths below, and it used to resolve to nothing at all: the
        // handler that was supposed to report a comic failure threw
        // `ReferenceError: messageOf is not defined` instead, which is how a
        // report turns into a second, silent failure.
        function messageOf(error) {
            if (!error) { return String(error); }
            if (typeof error === 'string') { return error; }
            return error.message ? String(error.message) : String(error);
        }

        // The challenge document sets its cookie and redirects to the API URL, so
        // the frame's load event is the signal; the extra wait is for the native
        // side, whose cookie snapshot is read asynchronously off
        // WKHTTPCookieStore and is what the retry actually travels with.
        var SETTLE_MS = 700;
        var GIVE_UP_MS = 12000;
        var GATE_TTL_MS = 300000;

        var gatedAt = {};

        function isChallenge(answer) {
            if (!answer || typeof answer !== 'object') { return false; }
            if (answer.error === 'challenge_required') { return true; }
            return typeof answer.challenge_url === 'string'
                && answer.challenge_url.length > 0;
        }

        // Built by hand rather than with URL(): the challenge URL is a path on
        // the host that issued it, and nothing else is needed.
        function absolute(raw, requestUrl) {
            var text = String(raw || '');
            if (!text) { return ''; }
            if (text.indexOf('http://') === 0 || text.indexOf('https://') === 0) {
                return text;
            }
            var request = String(requestUrl || '');
            var schemeEnd = request.indexOf('://');
            if (schemeEnd < 0) { return text; }
            var hostEnd = request.indexOf('/', schemeEnd + 3);
            if (hostEnd < 0) { hostEnd = request.length; }
            var origin = request.slice(0, hostEnd);
            if (text.charAt(0) !== '/') { return origin + '/' + text; }
            return origin + text;
        }

        function hostOf(url) {
            var request = String(url || '');
            var schemeEnd = request.indexOf('://');
            if (schemeEnd < 0) { return request; }
            var hostEnd = request.indexOf('/', schemeEnd + 3);
            if (hostEnd < 0) { hostEnd = request.length; }
            return request.slice(schemeEnd + 3, hostEnd);
        }

        function recentlyGated(host) {
            var at = gatedAt[host];
            return !!at && (Date.now() - at) < GATE_TTL_MS;
        }

        function passGate(url) {
            return new Promise(function (resolve, reject) {
                if (!url) { reject(new Error('no challenge url')); return; }
                var host = document.body || document.documentElement;
                if (!host) { reject(new Error('no document to mount the frame in')); return; }
                var frame = document.createElement('iframe');
                frame.setAttribute('data-stvcomic', 'gate');
                frame.setAttribute('style', 'position:fixed;left:-9999px;top:0;'
                    + 'width:1px;height:1px;border:0;opacity:0;');
                var done = false;
                var giveUp = null;
                var settle = null;
                var finish = function (ok, why) {
                    if (done) { return; }
                    done = true;
                    if (giveUp) { clearTimeout(giveUp); }
                    if (settle) { clearTimeout(settle); }
                    if (frame.parentNode) { frame.parentNode.removeChild(frame); }
                    if (ok) { resolve(why); } else { reject(new Error(why)); }
                };
                giveUp = setTimeout(function () {
                    finish(false, 'the challenge did not finish in ' + GIVE_UP_MS + 'ms');
                }, GIVE_UP_MS);
                frame.addEventListener('load', function () {
                    if (done || settle) { return; }
                    settle = setTimeout(function () {
                        finish(true, 'the challenge frame loaded');
                    }, SETTLE_MS);
                });
                host.appendChild(frame);
                frame.src = url;
            });
        }

        function wrap(auto) {
            if (!auto || typeof auto.get !== 'function') { return false; }
            if (auto.get.__stvComicGateWrapped) { return true; }
            var original = auto.get;
            var wrapped = function (url) {
                var args = arguments;
                var self = this;
                return original.apply(self, args).then(function (answer) {
                    if (!isChallenge(answer)) { return answer; }
                    var host = hostOf(url);
                    var gate = absolute(answer.challenge_url, url);
                    note('COMIC', 'the comic source asked for a bot check on ' + host
                        + ': ' + gate);
                    if (recentlyGated(host)) {
                        note('ERR', 'the bot check for ' + host + ' did not stick;'
                            + ' leaving the answer alone for five minutes');
                        return answer;
                    }
                    gatedAt[host] = Date.now();
                    return passGate(gate).then(function (why) {
                        note('COMIC', why + '; retrying ' + url);
                        return original.apply(self, args);
                    }, function (error) {
                        note('ERR', 'the bot check for ' + host + ' failed: '
                            + (error && error.message ? error.message : String(error)));
                        return answer;
                    });
                });
            };
            wrapped.__stvComicGateWrapped = true;
            auto.get = wrapped;
            note('PATCH', 'the comic sources bot check is handled');
            return true;
        }

        // ---- the site's own translator, which every comic source runs through ----
        //
        // Each provider's getComicList ends in `translateObject(list)`
        // (app.v2.js:8780). That helper walks the whole object, joins EVERY leaf
        // -- `url` and `thumb` included -- into one string, posts it to the site's
        // `sajax=trans`, splits the answer on the same separator and reassigns the
        // pieces with shift(). Two ways that loses the data:
        //
        //   * a piece count that does not match (the translator merges or drops
        //     something) shifts every later value, so the tail fields come back
        //     undefined -- `d[j].url` undefined is exactly the
        //     "unhandledrejection getComicProvider ... 1932:20" in the 2026-10-04
        //     device log (that line is `.replace` on a non-string);
        //   * `translateWithQt` is a bare XMLHttpRequest with NO error handler, so
        //     a request that never answers leaves the promise pending for ever and
        //     the list never renders -- the preloader just spins, which is what
        //     "所有的来源我都试了，没显示内容" looks like.
        //
        // The repair keeps the site's translation where it works and never lets it
        // touch a URL or a cover, never shifts the values, and gives up after
        // TRANSLATE_OBJECT_TIMEOUT_MS instead of hanging.
        var TRANSLATE_OBJECT_TIMEOUT_MS = 6000;
        var OBJ_SEP = '=||=';
        var NOT_TRANSLATED = ['url', 'thumb', 'avatar', 'icon', 'host', 'id',
            'bid', 'comic_id', 'languageHint', 'transModeHint'];

        function looksLikeUrl(value) {
            if (typeof value !== 'string') { return true; }
            if (value.indexOf('http://') === 0 || value.indexOf('https://') === 0) {
                return true;
            }
            return value.indexOf('/') === 0 && value.length > 1;
        }

        function safeTranslateObject(obj) {
            if (!obj || typeof obj !== 'object') { return Promise.resolve(obj); }
            var holders = [];
            var values = [];
            var collect = function (node) {
                for (var key in node) {
                    var value = node[key];
                    if (typeof value === 'function') { continue; }
                    if (value && typeof value === 'object') { collect(value); continue; }
                    if (NOT_TRANSLATED.indexOf(key) >= 0) { continue; }
                    if (looksLikeUrl(value)) { continue; }
                    holders.push({ node: node, key: key });
                    values.push(value);
                }
            };
            collect(obj);
            if (!values.length) { return Promise.resolve(obj); }
            var translator = window.translateWithQt;
            if (typeof translator !== 'function') { return Promise.resolve(obj); }

            var settled = false;
            var giveUp = new Promise(function (resolve) {
                setTimeout(function () {
                    if (settled) { return; }
                    settled = true;
                    note('COMIC', 'the site translator did not answer in '
                        + TRANSLATE_OBJECT_TIMEOUT_MS + 'ms; keeping the source names');
                    resolve(obj);
                }, TRANSLATE_OBJECT_TIMEOUT_MS);
            });
            var attempt = Promise.resolve()
                .then(function () { return translator(values.join(OBJ_SEP)); })
                .then(function (translated) {
                    if (settled) { return obj; }
                    settled = true;
                    if (typeof translated !== 'string') { return obj; }
                    var pieces = translated.split(OBJ_SEP);
                    if (pieces.length !== values.length) {
                        note('COMIC', 'the site translator answered ' + pieces.length
                            + ' piece(s) for ' + values.length + ' value(s); keeping the'
                            + ' source names instead of shifting them');
                        return obj;
                    }
                    for (var i = 0; i < holders.length; i++) {
                        holders[i].node[holders[i].key] = pieces[i];
                    }
                    return obj;
                }, function (error) {
                    if (settled) { return obj; }
                    settled = true;
                    note('ERR', 'the site translator failed: ' + messageOf(error));
                    return obj;
                });
            return Promise.race([attempt, giveUp]);
        }

        function patchTranslateObject() {
            var current = window.translateObject;
            if (current === safeTranslateObject) { return true; }
            if (typeof current !== 'function') { return false; }
            window.translateObject = safeTranslateObject;
            note('PATCH', 'the comic sources translator can no longer lose the data');
            return true;
        }

        // getComicProvider (comicprovider.js:1925) ends with
        // `domain.replace("www.","")` -- unguarded, so any non-string argument
        // throws. That is the 1932:20 rejection in the 2026-10-04 log.
        function patchGetComicProvider() {
            var original = window.getComicProvider;
            if (typeof original !== 'function') { return false; }
            if (original.__stvSafeArgument) { return true; }
            var safe = function (domain) {
                var value = domain;
                if (value && typeof value === 'object') { value = value.url; }
                if (typeof value !== 'string' || !value) {
                    note('ERR', 'getComicProvider was called with ' + String(value)
                        + '; the comic source cannot be resolved from that');
                    return null;
                }
                // A fresh instance every call (comicprovider.js:1931), so the
                // guard is per instance and shadows the prototype method.
                return guardProvider(original.call(this, value), value);
            };
            safe.__stvSafeArgument = true;
            window.getComicProvider = safe;
            note('PATCH', 'getComicProvider no longer throws on a bad argument');
            return true;
        }

        function adopt() {
            var wrapped = wrap(window.AutoHttp);
            var translator = patchTranslateObject();
            var provider = patchGetComicProvider();
            return wrapped && translator && provider;
        }

        // ---- what a failing source is allowed to do --------------------------
        //
        // renderComicBrowser (app.v2.read.js:4209) and openComicByUrl
        // (app_v2.html:4345) both attach a bare `.then()` and no rejection
        // handler, so a provider that throws leaves the preloader spinning for
        // ever ("只有顶部的分类") and the comicinfo page half built ("显示不全漫画
        // 详情"). The throw itself is ordinary: every getComicList ends in
        // `json.map(...)` over whatever the host answered, and a 403 answers
        // `{"error":...}` instead of a list -- that is the
        // `unhandledrejection getComicList@...:628:36` in the 2026-10-04 log.
        //
        // The provider is wrapped rather than the caller, because the caller is
        // site code that cannot be reached before it runs: a failure becomes an
        // empty result plus one line saying which source and why, and the page
        // gets to finish instead of hanging.
        function lengthOf(value) {
            return typeof value === 'string' ? value.length : -1;
        }

        function describeInfo(host, result) {
            var d = (result && typeof result === 'object') ? result : {};
            var missing = [];
            if (!d.name) { missing.push('name'); }
            if (!d.thumb) { missing.push('thumb'); }
            if (!d.desc) { missing.push('desc'); }
            if (!d.tags || typeof d.tags.length !== 'number') { missing.push('tags'); }
            if (!d.chapters || !d.chapters.length) { missing.push('chapters'); }
            note('COMIC', host + ' details: '
                + ((d.chapters && d.chapters.length) || 0) + ' chapter(s), name='
                + lengthOf(d.name) + ' desc=' + lengthOf(d.desc) + ' tags='
                + ((d.tags && d.tags.length) || 0)
                + (missing.length ? '; missing ' + missing.join(',') : ''));
            // app_v2.html:4360 reads `d.tags.length` and `d.desc` directly, so a
            // provider that left either out takes the whole render down with it.
            if (!d.tags || typeof d.tags.length !== 'number') { d.tags = []; }
            if (typeof d.desc !== 'string') { d.desc = ''; }
            if (typeof d.name !== 'string') { d.name = ''; }
            if (typeof d.thumb !== 'string') { d.thumb = ''; }
            if (!d.chapters || typeof d.chapters.length !== 'number') { d.chapters = []; }
            return d;
        }

        function guardProvider(provider, host) {
            if (!provider || provider.__stvGuarded) { return provider; }
            provider.__stvGuarded = true;

            var list = provider.getComicList;
            if (typeof list === 'function') {
                provider.getComicList = function () {
                    var args = arguments;
                    return Promise.resolve(list.apply(this, args)).then(
                        function (result) {
                            if (!result || typeof result.length !== 'number') {
                                note('COMIC', host + ' answered no list;'
                                    + ' showing an empty one');
                                return [];
                            }
                            return result;
                        },
                        function (error) {
                            note('ERR', host + ' could not load its list: '
                                + messageOf(error));
                            return [];
                        });
                };
            }

            var info = provider.getComicInfo;
            if (typeof info === 'function') {
                provider.getComicInfo = function () {
                    var args = arguments;
                    return Promise.resolve(info.apply(this, args)).then(
                        function (result) { return describeInfo(host, result); },
                        function (error) {
                            // Resolved, not rejected: the page has no catch, and
                            // an empty page with a reason on it is what tells the
                            // reader this source is the problem.
                            return describeInfo(host, {
                                name: '', thumb: '', tags: [],
                                desc: '这个源没有返回漫画详情：' + messageOf(error)
                            });
                        });
                };
            }
            return provider;
        }

        // ---- the chapter frame ----------------------------------------------
        //
        // initRemote (app.v2.read.js:3788) puts the chapter in an iframe pointing
        // at STV_SERVER/comictranslator.php and then treats that frame as
        // same-origin: initEventForFrame reaches into `w.document`,
        // `w.scrollY` and `w.__defineGetter__`. On this device STV_SERVER is
        // https://sangtacviet.app while the page is https://sangtacviet.com
        // ([DOMAIN] in the 2026-10-04 log), so every one of those reads throws
        // SecurityError -- which is the
        // `onerror SecurityError: Blocked a frame with origin
        // "https://sangtacviet.com"` at app.v2.read.js:4091, the
        // {"isTrusted":true} flood after it, and a reader whose menu and
        // progress never bind.
        //
        // Pointing the frame at the origin the page is already on makes it
        // same-origin again. That is a real fix and not just a quieter log: the
        // site's own scroll/click/progress wiring only works on a readable
        // frame.
        function pageOrigin() {
            var here = String(window.location.origin || '');
            return here.indexOf('http') === 0 ? here : '';
        }

        function originOf(url) {
            var text = String(url);
            var at = text.indexOf('://');
            if (at < 0) { return ''; }
            var slash = text.indexOf('/', at + 3);
            return slash < 0 ? text : text.slice(0, slash);
        }

        function patchTranslatorUrl(reader) {
            if (typeof reader.getTranslatorUrl !== 'function') { return false; }
            if (reader.getTranslatorUrl.__stvSameOrigin) { return true; }
            var original = reader.getTranslatorUrl;
            var safe = function (url) {
                var built = String(original.call(this, url));
                var origin = pageOrigin();
                if (!origin) { return built; }
                var frame = originOf(built);
                if (!frame || frame === origin) { return built; }
                var at = built.indexOf('://');
                var slash = built.indexOf('/', at + 3);
                note('COMIC', 'the chapter frame is on ' + frame + ' but the page is on '
                    + origin + '; using the page origin so the frame stays readable');
                return origin + built.slice(slash < 0 ? built.length : slash);
            };
            safe.__stvSameOrigin = true;
            reader.getTranslatorUrl = safe;
            return true;
        }

        // Every one of these reaches across the frame boundary, and each is
        // called from a place with no handler: getCurrentChapterUrl splits the
        // frame src on "?" and "=" without checking either, and
        // updateCnameAndProgress reads w.document.body.scrollHeight. One throw
        // there is an unhandled rejection and a reader stuck on the last screen
        // it managed to draw.
        function patchReaderFrame(reader) {
            // Returns true only once all four are wrapped, so the caller's poll
            // knows it can stop; a method that is not there yet keeps it false.
            var complete = true;

            if (typeof reader.initEventForFrame !== 'function') {
                complete = false;
            } else if (!reader.initEventForFrame.__stvGuarded) {
                var wire = reader.initEventForFrame;
                var safeWire = function (w) {
                    // Set before the call, so a frame that turns out to be
                    // cross-origin still leaves the reader with a window to
                    // report against instead of a null.
                    this.currentWindow = w;
                    try {
                        return wire.call(this, w);
                    } catch (error) {
                        note('ERR', 'the chapter frame could not be wired up ('
                            + messageOf(error) + '); the menu will not follow the'
                            + ' scroll, reading itself still works');
                        return null;
                    }
                };
                safeWire.__stvGuarded = true;
                reader.initEventForFrame = safeWire;
                complete = false;
            }

            if (typeof reader.updateCnameAndProgress !== 'function') {
                complete = false;
            } else if (!reader.updateCnameAndProgress.__stvGuarded) {
                var update = reader.updateCnameAndProgress;
                var safeUpdate = function () {
                    try {
                        return update.call(this);
                    } catch (error) {
                        note('ERR', 'the chapter progress could not be updated: '
                            + messageOf(error));
                        return null;
                    }
                };
                safeUpdate.__stvGuarded = true;
                reader.updateCnameAndProgress = safeUpdate;
                complete = false;
            }

            if (typeof reader.getCurrentChapterUrl !== 'function') {
                complete = false;
            } else if (!reader.getCurrentChapterUrl.__stvGuarded) {
                var current = reader.getCurrentChapterUrl;
                var safeCurrent = function () {
                    try {
                        var url = current.call(this);
                        if (typeof url === 'string') { return url; }
                    } catch (error) {
                        note('ERR', 'the current chapter url could not be read: '
                            + messageOf(error));
                    }
                    return '';
                };
                safeCurrent.__stvGuarded = true;
                reader.getCurrentChapterUrl = safeCurrent;
                complete = false;
            }

            if (typeof reader.getCurrentChapterName !== 'function') {
                complete = false;
            } else if (!reader.getCurrentChapterName.__stvGuarded) {
                // The site's version is `list.find(e => e.url == url).name`, so an
                // unknown or empty url throws inside a menu render.
                var safeName = function () {
                    var url = this.getCurrentChapterUrl();
                    var list = this.currentChapterList || [];
                    for (var i = 0; i < list.length; i++) {
                        if (list[i] && list[i].url === url) { return list[i].name; }
                    }
                    return '';
                };
                safeName.__stvGuarded = true;
                reader.getCurrentChapterName = safeName;
                complete = false;
            }

            return complete;
        }

        // What the chapter frame actually contains. This is the one measurement
        // that separates "the site's translator answered nothing" from "the
        // images are there and something else is blank".
        //
        // It used to be taken the moment the iframe ELEMENT existed -- 250ms
        // after initRemote appended it -- which is the frame's initial
        // about:blank document, not its content. Every 2026-10-04 line therefore
        // read `images=0 body=0B readyState=complete` whatever the site did, and
        // the question the measurement was added to answer stayed open. Measure
        // on arrival, then again once the frame has had time to load and draw,
        // and stop as soon as one of them shows content.
        function frameSource(frame) {
            return String((frame && frame.src) || '').slice(0, 140);
        }

        function frameReport(frame) {
            var w = null;
            try { w = frame.contentWindow; } catch (error) { w = null; }
            if (!w) { return 'no window'; }
            try {
                var doc = w.document;
                var images = doc.getElementsByTagName('img');
                return 'title=' + JSON.stringify(String(doc.title || ''))
                    + ' images=' + images.length
                    + ' body=' + ((doc.body && doc.body.innerHTML.length) || 0) + 'B'
                    + ' readyState=' + String(doc.readyState);
            } catch (error) {
                return 'unreadable: ' + messageOf(error);
            }
        }

        function followChapterFrame(frame, polls) {
            var plan = [900, 3000];
            var seen = '';
            var settled = false;
            var look = function (label) {
                var report = frameReport(frame);
                // `body=0B` is the about:blank answer; anything else is the
                // frame's own document, so the rest of the plan is noise.
                if (report !== 'no window' && report.indexOf('body=0B') < 0) {
                    settled = true;
                }
                if (report === seen) { return; }
                seen = report;
                note('COMIC', 'the chapter frame at ' + frameSource(frame)
                    + ' after ' + polls + ' poll(s), ' + label + ': ' + report);
            };
            look('on arrival');
            for (var i = 0; i < plan.length; i++) {
                (function (delay) {
                    setTimeout(function () {
                        if (!settled) { look('at +' + delay + 'ms'); }
                    }, delay);
                })(plan[i]);
            }
        }

        // ---- what the chapter frame has to hand the translator ----------------
        //
        // comictranslator.php's inline script turns each image url into the body
        // /s1213ocr.php accepts, and on 2026-10-04 both of its paths were dead:
        //
        //   * a plain url: `toRealRawData` has NO `return` when no entry carries
        //     the "LAZY:" prefix, so it yields undefined and transImage runs
        //     `a.send(undefined)`. An empty body makes the server answer
        //     {"blocks":[],"imageWidth":null,"images":["data:image/jpeg;base64,"]}
        //     -- an EMPTY data url (measured: 112 bytes). ComicRenderer.render()
        //     writes that into an `<img src>`, which WebKit draws as its
        //     broken-image glyph: that glyph is the "?" the reader reported, and
        //     no download was ever in flight.
        //   * a "LAZY:" url: lazyImageLoader.load() postMessages
        //     {type:"requestLazyImageData"} to the parent and waits for a
        //     {type:"lazyImageData"} answer. Nothing on the site listens (checked
        //     against the live app.v2.php and all seven bundles the frame loads),
        //     so that promise never settles and the page never draws at all.
        //
        // patchTranslatorUrl makes the frame same-origin, so the parent can reach
        // in and repair both halves. The bytes half uses the protocol the frame
        // already documents ("return as IMAGERAW format"): the parent fetches the
        // image through the app's own HTTP plugin and answers "IMAGERAW:" plus
        // the base64, which the server accepts.
        var frameAsking = null;
        // Paired mode asks for the SAME image twice: startTransPaired
        // (comictranslator.php:126-150) builds pair (0,1) then (1,2) then (2,3),
        // so every interior image is downloaded once per pair it belongs to. The
        // frame's own lazyImageLoader.cache cannot help -- it is keyed by the url
        // it was HANDED, and in paired mode that is the whole array, which is
        // different for every pair. Remembering the answer per image halves the
        // downloads, and remembering a host that already refused stops a dead
        // source from spending one TLS handshake per image on it.
        var frameBytes = {};
        var frameHostDown = {};
        var FRAME_BYTES_MAX = 60;
        var frameBytesKept = 0;

        // The frame asks for bytes with whatever url it was handed, and in paired
        // mode that is a JSON array of two images. Handing that array straight to
        // the app's downloader is what made the HTTP plugin answer "unsupported
        // URL" and lose the bytes the service could not fetch for itself, so the
        // array is walked instead.
        function imageCandidates(url) {
            var text = String(url || '');
            if (text.charAt(0) !== '[') { return [text]; }
            try {
                var list = JSON.parse(text);
                if (list && list.length) {
                    return Array.prototype.map.call(list, function (one) {
                        return String(one);
                    });
                }
            } catch (error) {
                note('ERR', 'the chapter frame asked for an unreadable image list: '
                    + messageOf(error));
            }
            return [text];
        }

        // One image, or null when the reader cannot produce its bytes either.
        function imageBytesOne(url) {
            if (Object.prototype.hasOwnProperty.call(frameBytes, url)) {
                return Promise.resolve(frameBytes[url] || null);
            }
            var host = imageHost(url);
            // One refusal from a host is enough to leave the rest of the chapter
            // to the server: that is the fallback that already existed, so the
            // worst a wrong guess costs is the same answer, reached at once.
            if (host && frameHostDown[host]) { return Promise.resolve(null); }
            return new Promise(function (resolve) {
                var images = window.app && window.app.images;
                if (!images || typeof images.download !== 'function') {
                    resolve(null);
                    return;
                }
                try {
                    images.download(url).then(function (blob) {
                        var reader = new FileReader();
                        reader.onload = function () {
                            var text = String(reader.result || '');
                            var comma = text.indexOf(',');
                            resolve(comma < 0
                                ? null : 'IMAGERAW:' + text.slice(comma + 1));
                        };
                        reader.onerror = function () { resolve(null); };
                        reader.readAsDataURL(blob);
                    }, function (error) {
                        note('ERR', 'the chapter frame image could not be fetched ('
                            + messageOf(error) + '); letting the server try');
                        resolve(null);
                    });
                } catch (error) {
                    note('ERR', 'the chapter frame image could not be fetched ('
                        + messageOf(error) + '); letting the server try');
                    resolve(null);
                }
            }).then(function (value) {
                // A failure carries no payload, so it is always worth keeping; the
                // bytes are capped because a long chapter's worth of base64 is
                // megabytes, and the duplicates are all inside the first pairs.
                if (!value) {
                    frameBytes[url] = '';
                    if (host && !frameHostDown[host]) {
                        frameHostDown[host] = true;
                        note('COMIC', 'the image host ' + host + ' cannot be fetched'
                            + ' from here; leaving the rest of this chapter to the'
                            + ' server');
                    }
                } else if (frameBytesKept < FRAME_BYTES_MAX) {
                    frameBytes[url] = value;
                    frameBytesKept++;
                }
                return value;
            });
        }

        function imageBytes(url) {
            var list = imageCandidates(url);
            var work = Promise.all(list.map(imageBytesOne)).then(function (parts) {
                var ok = true;
                for (var i = 0; i < parts.length; i++) {
                    if (!parts[i]) { ok = false; }
                }
                // All of them or none: the frame's format is a run of IMAGERAW
                // chunks that the service stacks back into one image, so a
                // half-filled run would be neither bytes nor a url to fetch.
                return ok ? parts.join('') : String(url);
            });
            // A downloader that never answers must not leave the frame waiting
            // for a message that is not coming.
            return Promise.race([work, new Promise(function (resolve) {
                setTimeout(function () { resolve(String(url)); }, 15000);
            })]);
        }

        function onChapterFrameMessage(event) {
            var data = event && event.data;
            if (!data || data.type !== 'requestLazyImageData'
                || typeof data.url !== 'string') {
                return;
            }
            var target = event.source || frameAsking;
            imageBytes(data.url).then(function (payload) {
                try {
                    if (target && typeof target.postMessage === 'function') {
                        target.postMessage({
                            type: 'lazyImageData',
                            url: data.url,
                            data: payload,
                        }, '*');
                    }
                } catch (error) {
                    note('ERR', 'the chapter frame image could not be handed back: '
                        + messageOf(error));
                }
            });
        }
        window.addEventListener('message', onChapterFrameMessage);

        // The server answers imageWidth=null exactly when it could not fetch the
        // image it was handed; a page it did fetch always carries the width it
        // measured. Rendering that answer is what put the broken glyph on screen,
        // so say it in words instead.
        function answerHasNoImage(data) {
            if (!data || typeof data !== 'object') { return false; }
            return data.imageWidth === null || data.imageWidth === undefined;
        }

        function imageHost(url) {
            var text = String(url || '');
            // Paired mode asks with a JSON array, and the host worth naming is the
            // first image's.
            if (text.charAt(0) === '[') {
                try {
                    var list = JSON.parse(text);
                    if (list && list.length) { text = String(list[0]); }
                } catch (error) { /* the raw text is the best name left */ }
            }
            var at = text.indexOf('://');
            if (at < 0) { return ''; }
            var slash = text.indexOf('/', at + 3);
            return slash < 0 ? text.slice(at + 3) : text.slice(at + 3, slash);
        }

        function frameNotice(w, order, data) {
            try {
                var doc = w.document;
                var host = doc.getElementById ? doc.getElementById('chapcontent') : null;
                if (!host) { return; }
                var box = doc.createElement('div');
                box.className = 'stv-img-missing';
                box.setAttribute('ord', String(order));
                box.style.order = String(order);
                box.style.padding = '28px 18px';
                box.style.textAlign = 'center';
                box.style.color = '#888';
                var source = imageHost(data && data.base && data.base.url);
                // Naming the host is the difference between "the app is broken"
                // and "this source is": a page whose image host does not answer
                // anywhere cannot be fixed from here.
                box.textContent = source
                    ? '这一页没有取到图片：图源 ' + source + ' 的图片无法访问。'
                    : '这一页没有取到图片：站点翻译服务没有返回内容。';
                host.appendChild(box);
            } catch (error) {
                note('ERR', 'the chapter frame notice could not be shown: '
                    + messageOf(error));
            }
        }

        // The OCR service answers PLAIN TEXT -- "Invalid image data: <url>",
        // status 200 -- when it cannot fetch one of the urls it was handed
        // (measured: any unfetchable element of a JSON array does this, while a
        // single unfetchable url still answers JSON with imageWidth=null). The
        // frame's transImage does JSON.parse(a.responseText) inside
        // onreadystatechange, where nothing can catch it: the promise it is
        // inside never settles, so triggerLoadImg never retries, nothing is
        // drawn and not even the notice appears. The page just stops.
        //
        // Paired mode now hands the service two urls at once, so that answer is
        // reachable on a working source and has to arrive as data the frame can
        // read. Only the OCR endpoint is rewritten: /open/autotrans.php answers
        // plain text on purpose (comictranslator.php:264 reads it as text).
        function patchOcrResponse(w) {
            var xhr = w ? w.XMLHttpRequest : null;
            var proto = xhr && xhr.prototype;
            if (!proto || proto.__stvOcr) { return false; }
            var desc = Object.getOwnPropertyDescriptor(proto, 'responseText');
            if (!desc || typeof desc.get !== 'function') { return false; }
            var read = desc.get;
            Object.defineProperty(proto, 'responseText', {
                configurable: true,
                enumerable: desc.enumerable,
                get: function () {
                    var text = read.call(this);
                    if (typeof text !== 'string' || !text.length
                        || text.charAt(0) === '{' || text.charAt(0) === '[') {
                        return text;
                    }
                    var url = '';
                    try { url = String(this.responseURL || ''); } catch (error) { url = ''; }
                    if (url.indexOf('s1213ocr.php') < 0) { return text; }
                    return '{"blocks":[],"images":["data:image/jpeg;base64,"],'
                        + '"imageWidth":null,"t_image":null}';
                },
            });
            proto.__stvOcr = true;
            return true;
        }

        function patchChapterTranslator(w) {
            patchOcrResponse(w);
            var translator = null;
            try { translator = w ? w.translator : null; } catch (error) { translator = null; }
            if (!translator || !translator.lazyImageLoader) { return false; }
            if (translator.__stvBytes) { return true; }
            translator.__stvBytes = true;
            frameAsking = w;
            // A new chapter means a new frame, so nothing remembered about the
            // last one's images or hosts applies.
            frameBytes = {};
            frameHostDown = {};
            frameBytesKept = 0;

            var loader = translator.lazyImageLoader;
            // The frame hard-codes transmode "paired" (comictranslator.php:470)
            // and startTransPaired (line 138) replaces the url it translates with
            // `JSON.stringify([img.url, img2.url])` -- two images in one OCR call,
            // so a text block that straddles the seam between them is read once.
            // toRealRawData is therefore handed a JSON ARRAY, not a url, and that
            // is the shape that was never repaired:
            //
            //   * the site's own body for it is `undefined` -- its `return` sits
            //     inside the `LAZY:` branch, and a plain pair carries no such
            //     prefix (measured: comicloader.php answers 36 plain
            //     mhpic.cartoon.reader.qq.com urls for a Qidian chapter). An
            //     empty body is what the service answers imageWidth=null to.
            //   * joining the pair instead is no better: "https://ahttps://b" is
            //     not a url either, and the service answers imageWidth=null for
            //     it too (measured).
            //
            // The service DOES parse a JSON array itself and stacks what it
            // fetched into one image (measured: two reachable urls -> one image,
            // imageWidth 404), which is exactly what paired mode is for, so that
            // is the body a plain pair has to keep. A single url goes back
            // exactly as it came, which is the path that already worked.
            loader.toRealRawData = async function (imgs) {
                var list = (typeof imgs === 'string' && imgs.charAt(0) === '[')
                    ? JSON.parse(imgs) : [imgs];
                var lazy = false;
                for (var j = 0; j < list.length; j++) {
                    if (String(list[j]).indexOf('LAZY:') === 0) { lazy = true; }
                }
                if (!lazy) {
                    return list.length > 1
                        ? JSON.stringify(list) : String(list[0]);
                }
                var out = [];
                for (var i = 0; i < list.length; i++) {
                    var one = String(list[i]);
                    // A url the server fetches itself goes back unchanged; that
                    // return is the whole repair for the LAZY path.
                    out.push(one.indexOf('LAZY:') === 0
                        ? await loader.load(one.slice(5)) : one);
                }
                return out.join('');
            };

            var render = translator.loadTranslatedImage;
            if (typeof render === 'function' && !render.__stvGuarded) {
                // The server fetches the image itself first, so a source it can
                // reach costs no extra traffic. When it answers without an image
                // the page asks its OWN network for the bytes and hands them
                // over -- the only path left when what is blocked is the site's
                // egress rather than the reader's.
                var retryWithBytes = function (data, order) {
                    var url = data && data.base && data.base.url;
                    if (!url || data.__stvBytesTried) { return false; }
                    data.__stvBytesTried = true;
                    loader.load(String(url)).then(function (payload) {
                        var text = String(payload || '');
                        if (text.indexOf('IMAGERAW:') !== 0) {
                            note('COMIC', 'the image at ' + imageHost(url)
                                + ' could not be fetched here either');
                            frameNotice(w, order, data);
                            return null;
                        }
                        return translator.transImage(text).then(function (again) {
                            if (answerHasNoImage(again)) {
                                note('COMIC', 'the translator answered no image for block '
                                    + order + ' even from the reader own bytes');
                                frameNotice(w, order, data);
                                return null;
                            }
                            again.base = data.base;
                            return render.call(translator, again, order);
                        });
                    }, function () {
                        frameNotice(w, order, data);
                    });
                    return true;
                };

                var safeRender = function (data, order) {
                    if (!answerHasNoImage(data)) {
                        return render.apply(this, arguments);
                    }
                    if (retryWithBytes(data, order)) { return null; }
                    note('COMIC', 'the translator answered no image for block '
                        + order + '; showing a notice instead of a broken picture');
                    frameNotice(w, order, data);
                    return null;
                };
                safeRender.__stvGuarded = true;
                translator.loadTranslatedImage = safeRender;
            }

            // triggerLoadImg calls this after three failures and the frame
            // defines it nowhere, so a failed image used to die as a TypeError
            // with nothing at all on screen.
            if (typeof translator.showError !== 'function') {
                translator.showError = function (order) {
                    note('COMIC', 'the translator gave up on block ' + order);
                    frameNotice(w, order, null);
                };
            }

            var start = translator.startTrans;
            if (typeof start === 'function' && !start.__stvLogged) {
                var safeStart = function () {
                    var list = translator.imgs || [];
                    note('COMIC', 'the chapter frame has ' + list.length
                        + ' image(s) to translate');
                    return start.apply(this, arguments);
                };
                safeStart.__stvLogged = true;
                translator.startTrans = safeStart;
            }
            note('COMIC', 'the chapter frame translator is patched');
            return true;
        }

        // The frame parses its inline script before `load` fires, but its src is
        // replaced on every chapter change, so the patch is attempted on a short
        // poll rather than once.
        function watchChapterTranslator(frame) {
            var tries = 0;
            var timer = setInterval(function () {
                tries++;
                var w = null;
                try { w = frame.contentWindow || null; } catch (error) { w = null; }
                if (patchChapterTranslator(w)) { clearInterval(timer); return; }
                if (tries > 100) { clearInterval(timer); }
            }, 200);
        }

        function watchChapterFrame(reader) {
            var polls = 0;
            var timer = setInterval(function () {
                polls++;
                var page = reader.page;
                if (!page && window.app && typeof window.app.topPage === 'function') {
                    try { page = window.app.topPage(); } catch (error) { page = null; }
                }
                var frame = (page && typeof page.q === 'function')
                    ? page.q('iframe') : null;
                if (frame) {
                    clearInterval(timer);
                    watchChapterTranslator(frame);
                    followChapterFrame(frame, polls);
                    return;
                }
                if (polls > 40) { clearInterval(timer); }
            }, 250);
        }

        function patchInitRemote(reader) {
            if (typeof reader.initRemote !== 'function') { return false; }
            if (reader.initRemote.__stvWatched) { return true; }
            var original = reader.initRemote;
            var watched = function (url, chapters, bookinfo) {
                note('COMIC', 'opening chapter ' + String(url)
                    + ' with ' + ((chapters && chapters.length) || 0)
                    + ' chapter(s) known');
                watchChapterFrame(reader);
                return original.apply(this, arguments);
            };
            watched.__stvWatched = true;
            reader.initRemote = watched;
            return true;
        }

        // "显示不全漫画详情": the comicinfo template clips its own detail block
        // (app_v2.html:2726, `<div class="info" style="max-height:220px;
        // overflow:hidden">`), so a long synopsis is cut off with no way to see
        // the rest. bookinfo -- the novel page with the same shape -- has no cap.
        function patchComicInfoStyle() {
            var host = document.head || document.documentElement;
            if (!host) { return false; }
            if (host.querySelector && host.querySelector('[data-stvcomic=info]')) {
                return true;
            }
            var style = document.createElement('style');
            style.setAttribute('data-stvcomic', 'info');
            style.textContent = '.comicinfo .info{max-height:none;overflow:visible;}';
            host.appendChild(style);
            return true;
        }

        // "unhandledrejection @app.v2.php:4399:9" on every comic chapter list.
        // The site's own tail is
        //
        //     history.getLastReadChapter(book.url).then(function(h){
        //         if(h){ var c = l.q('[clink="' + h.url + '"]');
        //                c.classList.add('chaplastreaded'); }
        //     });
        //
        // and getLastReadChapter (app.v2.read.js:4483) answers
        // `this.data[url].lastRead` -- the chapter URL ITSELF, a string -- so
        // `h.url` is undefined, the selector is always '[clink="undefined"]',
        // l.q() answers null and the chain dies: no last-read marker, no scroll
        // to it, and one ERR line per visit. readComicNow (app.v2.php:4533) hands
        // the same answer straight to showComicChapter AS the url, so the value
        // has to keep working as a string as well.
        //
        // A String object is both: it coerces and compares as the url everywhere
        // the site already uses it (`chapters.find(e => e.url == url)`,
        // `encodeURIComponent(url)`, `JSON.stringify`), and it answers `.url` for
        // the one caller that reads that. Repairing the value at its producer
        // leaves the chapter list itself -- which works -- out of the patch.
        function patchComicHistory() {
            var reader = window.app && window.app.comicReader;
            var history = reader && reader.history;
            if (!history || typeof history.getLastReadChapter !== 'function') {
                return false;
            }
            if (history.getLastReadChapter.__stvUrl) { return true; }
            var original = history.getLastReadChapter;
            var safe = function () {
                return Promise.resolve(original.apply(this, arguments)).then(function (h) {
                    if (!h || h.url) { return h; }
                    var carrier = new String(String(h));
                    carrier.url = String(h);
                    return carrier;
                });
            };
            safe.__stvUrl = true;
            history.getLastReadChapter = safe;
            return true;
        }

        // "下面的目录没显示，只有一个「章」字": the comicinfo template renders
        // `<span class="chaptercount"></span> Chương` (app.v2.php:443), and
        // setComicPageEvent -- the only place that page is filled -- never writes
        // the count, unlike the novel page's own bookinfo fill. With the i18n
        // overlay translating "Chương" the row reads as a bare "章" and the
        // detail page looks like it has no chapter list at all.
        function patchComicChapterCount() {
            var fun = window.app && window.app.fun;
            if (!fun || typeof fun.setComicPageEvent !== 'function') { return false; }
            if (fun.setComicPageEvent.__stvCount) { return true; }
            var original = fun.setComicPageEvent;
            var safe = function (page) {
                var result = original.apply(this, arguments);
                try {
                    var data = (page && page.data) || {};
                    var total = (data.chapters && data.chapters.length) || 0;
                    var node = (page && typeof page.q === 'function')
                        ? page.q('.chaptercount') : null;
                    if (node) { node.textContent = total ? String(total) : ''; }
                    note('COMIC', 'the detail page lists ' + total + ' chapter(s)');
                } catch (error) {
                    note('ERR', 'the comic detail count could not be filled: '
                        + messageOf(error));
                }
                return result;
            };
            safe.__stvCount = true;
            fun.setComicPageEvent = safe;
            return true;
        }

        // "上次读到" 的高亮回来了，滚到那一章却还是抛错。站点自己的尾巴是
        // （app.v2.php:4396-4402）：
        //
        //     var c = l.q('[clink="' + h.url + '"]');
        //     c.classList.add("chaplastreaded");
        //     ui.scrollto(c, -300, l);              // 4400
        //
        // 而 ui.scrollto（stv.ui.js:1015-1019）第一段就是 `$("#" + ele)`——它要的是
        // **id 字符串**，而唯一调用点给的是元素：选择器成了
        // `#[object HTMLDivElement]`，jqr 的 find 解析不了就抛。于是标记有了、滚动没了，
        // 每进一次章节列表多一行 `unhandledrejection @jqr.js`。
        //
        // 滚动量就是站点那一行算的，所以不重算：给这一行临时起个 id，让站点走它自己的
        // 路径，调用返回后撤掉（`$("#"+ele).offset().top` 是同步求值的，animate 拿到
        // 的是数值，撤 id 不影响已经开始的动画）。
        function patchScrollto() {
            var ui = window.ui;
            if (!ui || typeof ui.scrollto !== 'function') { return false; }
            if (ui.scrollto.__stvElement) { return true; }
            var original = ui.scrollto;
            var safe = function (ele, offset, scroller) {
                if (!ele || typeof ele !== 'object' || ele.nodeType !== 1) {
                    return original.apply(this, arguments);
                }
                var had = '';
                try { had = String(ele.getAttribute('id') || ''); } catch (error) { had = ''; }
                var name = had || '__stvscrollto';
                if (!had) {
                    try { ele.setAttribute('id', name); } catch (error) { /* an unnamed row still scrolls by id-less path below */ }
                }
                try {
                    return original.call(this, name, offset, scroller);
                } finally {
                    if (!had) {
                        try { ele.removeAttribute('id'); } catch (error) { /* nothing to undo */ }
                    }
                }
            };
            safe.__stvElement = true;
            ui.scrollto = safe;
            return true;
        }

        // stv.ui.js runs after this block, so ui.scrollto only exists later; the
        // repair is made at the one moment it matters -- opening the chapter list
        // whose tail calls it.
        function patchComicChapterListScroll() {
            var fun = window.app && window.app.fun;
            if (!fun || typeof fun.openComicChapterList !== 'function') { return false; }
            if (fun.openComicChapterList.__stvScroll) { return true; }
            var original = fun.openComicChapterList;
            var safe = function () {
                patchScrollto();
                return original.apply(this, arguments);
            };
            safe.__stvScroll = true;
            fun.openComicChapterList = safe;
            return true;
        }

        function adoptReader() {
            var reader = window.app && window.app.comicReader;
            if (!reader) { return false; }
            var origin = patchTranslatorUrl(reader);
            var frame = patchReaderFrame(reader);
            var remote = patchInitRemote(reader);
            var style = patchComicInfoStyle();
            var count = patchComicChapterCount();
            var history = patchComicHistory();
            var scroll = patchComicChapterListScroll();
            return !!(origin && frame && remote && style && count && history && scroll);
        }

        // app.v2.comicprovider.js is loaded on demand -- the comic browser is the
        // only thing that needs it -- so the global it defines is watched rather
        // than read. A top-level `var` in a classic script assigns through this
        // accessor, which puts the wrapper in place before the first request.
        var current = window.AutoHttp;
        var installed = false;
        try {
            Object.defineProperty(window, 'AutoHttp', {
                configurable: true,
                get: function () { return current; },
                set: function (value) {
                    current = value;
                    installed = adopt() || installed;
                }
            });
            if (current) { installed = adopt() || installed; }
        } catch (error) {
            note('ERR', 'could not watch AutoHttp: ' + error);
        }
        // Belt and braces: a bundle that defines the global some other way is
        // still caught, and the poll stops as soon as it is.
        //
        // app.comicReader is a different file again (app.v2.read.js, prefetched
        // and loaded on demand), so it is watched by the same timer rather than
        // by a second one.
        var attempts = 0;
        var readerDone = false;
        var timer = setInterval(function () {
            attempts++;
            installed = adopt() || installed;
            readerDone = adoptReader() || readerDone;
            if ((installed && readerDone) || attempts > 600) { clearInterval(timer); }
        }, 100);
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
                var sheet = sheets[i];
                var href = sheet.href || '';
                if (href.indexOf('app.v2.css') >= 0) { return 'app.v2.css'; }
                // The asset mirror serves app.v2.css as a <style> node, which has
                // no href to match on (see the assetMirror block).
                var owner = sheet.ownerNode || null;
                var mark = (owner && owner.getAttribute)
                    ? String(owner.getAttribute('data-stv-mirror') || '') : '';
                if (mark === 'app.v2.css') { return 'app.v2.css (local)'; }
            }
            if (window.app && window.app.config && window.app.config.reader) { return 'app.config'; }
            return '';
        }

        function releaseNow(reason) {
            if (released) { return true; }
            var ready = siteCssReady();
            if (!ready) { return false; }
            release(ready + ' at +' + (Date.now() - started) + 'ms (' + reason + ')');
            return true;
        }

        function stylesheetTouched(records) {
            // A bare callback (no records) means "something changed"; treat it as
            // relevant rather than ignoring a signal we cannot inspect.
            if (!records || !records.length) { return true; }
            for (var i = 0; i < records.length; i++) {
                var added = records[i] && records[i].addedNodes;
                if (!added) { continue; }
                for (var j = 0; j < added.length; j++) {
                    var name = String((added[j] && added[j].tagName) || '').toLowerCase();
                    if (name === 'link' || name === 'style') { return true; }
                }
            }
            return false;
        }

        function watchLinks() {
            var head = document.head;
            if (!head) { return; }
            var nodes = head.children || head.childNodes || [];
            for (var i = 0; i < nodes.length; i++) {
                var link = nodes[i];
                if (String((link && link.tagName) || '').toLowerCase() !== 'link') { continue; }
                if (link.__stvWatched || typeof link.addEventListener !== 'function') { continue; }
                link.__stvWatched = true;
                // `load` fires the instant the stylesheet is applied, which is
                // the earliest moment the real UI is styled.
                link.addEventListener('load', function () { releaseNow('link load'); });
                link.addEventListener('error', function () { releaseNow('link error'); });
            }
        }

        /**
         Deterministic release. The site's own stylesheet is the signal, and a
         <link> fires `load` the moment it is applied -- so the fake shell can
         come down as soon as the real one is styled.

         The old implementation only sampled at 0/1/3/6/10/20s, which meant a
         stylesheet that arrived at 1.1s kept "载入中…" on screen until the 3s
         sample. The samples stay as the fallback for a stylesheet that appears
         without either event (a sheet pushed into document.styleSheets by
         script, which is what the tests do).
         */
        function watch() {
            var head = document.head;
            if (!head) {
                document.addEventListener('DOMContentLoaded', watch);
                return;
            }
            // Bare global, like the comment-translation sweep: `window` is the
            // page's own window object, and the constructor lives on the global.
            if (typeof MutationObserver === 'function') {
                var observer = new MutationObserver(function (records) {
                    if (!stylesheetTouched(records)) { return; }
                    watchLinks();
                    if (releaseNow('stylesheet inserted')) { observer.disconnect(); }
                });
                try {
                    observer.observe(head, { childList: true, subtree: true });
                } catch (e) {}
            }
            watchLinks();
        }
        watch();

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
                    releaseNow(label);
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

    // MARK: - Swipe right to dismiss page

    /**
     Pushed pages on SangTacViet (such as user settings, inventory, buy history,
     and other overlay views) are displayed via `app.pushPage(pagename)`. They
     originally lack any horizontal swipe gesture to exit, forcing users to reach
     for top back buttons.

     This block hooks `app.pushPage` and adds touch handlers that support:
       - Edge swiping or titlebar dragging to dismiss.
       - Smooth translate3d animation and threshold detection.
       - Disables dismiss gesture on reader pages (`readchapter`, `readcomic`) to
         preserve book page-turning.
       - Disables in horizontal scroll tabs (unless dragging from left edge or titlebar).
     */
    static let swipeDismiss = """
    (function () {
        if (window.__stvSwipeDismissInstalled) { return; }
        window.__stvSwipeDismissInstalled = true;

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        var EXCLUDED = ['readchapter', 'readcomic'];

        function isExcluded(name, page) {
            if (!name && !page) { return true; }
            if (name && EXCLUDED.indexOf(name) >= 0) { return true; }
            if (page && (page.id === 'chapterview' || page.id === 'chapterviewpholder')) { return true; }
            return false;
        }

        function installSwipeOnPage(page, pageName) {
            if (!page || page.nodeType !== 1) { return; }
            if (page.__stvSwipeDismissInstalled) { return; }
            page.__stvSwipeDismissInstalled = true;

            if (isExcluded(pageName, page)) { return; }

            var startX = 0;
            var startY = 0;
            var startTime = 0;
            var isDragging = false;
            var isCancelled = false;

            // Capture phase on purpose: ui.smtab() (stv.ui.js) puts a
            // touchstart on the inventory's tabdivcontainer that calls
            // eve.stopPropagation() to keep its own tab drag exclusive, so a
            // bubble listener on the page never sees the touch. Capture runs
            // first and the site's handler keeps working below.
            page.addEventListener('touchstart', function (event) {
                if (!event.touches || event.touches.length !== 1) {
                    isCancelled = true;
                    return;
                }
                var touch = event.touches[0];
                startX = touch.clientX;
                startY = touch.clientY;
                startTime = Date.now();
                isDragging = false;
                isCancelled = false;

                var target = event.target;
                var tag = target && target.tagName ? String(target.tagName).toLowerCase() : '';
                var inputType = target && target.getAttribute ? target.getAttribute('type') : '';
                if (tag === 'input' && inputType === 'range') {
                    isCancelled = true;
                    return;
                }

                var node = target;
                var onTitlebar = false;
                var isHScroll = false;
                while (node && node !== page && node.nodeType === 1) {
                    var nodeTag = String(node.tagName || '').toLowerCase();
                    var nodeClass = String(node.className || '');
                    if (nodeClass.indexOf('titlebar') >= 0) {
                        onTitlebar = true;
                    }
                    if (nodeTag === 'tabdiv' || nodeTag === 'tabbar' || nodeClass.indexOf('themesetchoose') >= 0) {
                        isHScroll = true;
                    }
                    node = node.parentElement || node.parentNode;
                }

                var isEdge = (startX <= 80);

                if (isHScroll && !isEdge && !onTitlebar) {
                    isCancelled = true;
                    return;
                }

                var screenW = window.innerWidth || 375;
                if (!isEdge && !onTitlebar && startX > screenW * 0.45) {
                    isCancelled = true;
                    return;
                }
            }, { passive: true, capture: true });

            // Same capture reason for touchmove: smtab's own touchmove handler
            // stops propagation too, and the drag needs preventDefault to beat
            // the browser scroll.
            page.addEventListener('touchmove', function (event) {
                if (isCancelled || !event.touches || event.touches.length !== 1) { return; }
                var touch = event.touches[0];
                var dx = touch.clientX - startX;
                var dy = touch.clientY - startY;

                if (!isDragging) {
                    var absDx = Math.abs(dx);
                    var absDy = Math.abs(dy);

                    if (absDy > absDx && absDy > 8) {
                        isCancelled = true;
                        return;
                    }

                    if (dx < -8) {
                        isCancelled = true;
                        return;
                    }

                    if (dx > 8 && dx > absDy) {
                        isDragging = true;
                    }
                }

                if (isDragging) {
                    if (event.cancelable) { event.preventDefault(); }

                    var offset = Math.max(0, dx);
                    page.style.transform = 'translate3d(' + offset + 'px,0,0)';
                    page.style.transition = 'none';
                }
            }, { passive: false, capture: true });

            function onTouchFinish(event) {
                if (!isDragging) { return; }
                isDragging = false;

                var touch = (event.changedTouches && event.changedTouches[0])
                    || (event.touches && event.touches[0]);
                var currentX = touch ? touch.clientX : startX;
                var dx = currentX - startX;
                var elapsed = Date.now() - startTime;
                var velocity = elapsed > 0 ? (dx / elapsed) : 0;
                var screenW = window.innerWidth || document.body.scrollWidth || 375;
                var threshold = screenW * 0.32;

                var shouldExit = (dx > threshold) || (dx > 45 && velocity > 0.35);

                if (shouldExit) {
                    var remaining = screenW - dx;
                    var duration = Math.min(0.24, Math.max(0.12, remaining / 1200));
                    page.style.transition = 'transform ' + duration + 's cubic-bezier(0.2, 0.9, 0.3, 1)';
                    page.style.transform = 'translate3d(100vw,0,0)';
                    note('PAGE', 'swipe dismiss: ' + (pageName || 'page'));
                    setTimeout(function () {
                        var app = window.app;
                        if (app && typeof app.goback === 'function') {
                            app.goback();
                        } else if (app && typeof app.popPage === 'function') {
                            app.popPage();
                        }
                    }, Math.floor(duration * 1000));
                } else {
                    page.style.transition = 'transform 0.2s ease-out';
                    page.style.transform = 'translate3d(0,0,0)';
                    setTimeout(function () {
                        page.style.transition = '';
                        page.style.transform = '';
                    }, 200);
                }
            }

            page.addEventListener('touchend', onTouchFinish, { passive: true, capture: true });
            page.addEventListener('touchcancel', onTouchFinish, { passive: true, capture: true });
        }

        function hookPushPage() {
            var app = window.app;
            if (!app || typeof app.pushPage !== 'function') { return false; }
            if (app.__stvSwipeDismissHooked) { return true; }
            app.__stvSwipeDismissHooked = true;
            var original = app.pushPage;
            app.pushPage = function (name) {
                var page = original.apply(this, arguments);
                try {
                    installSwipeOnPage(page, name);
                } catch (error) {
                    note('ERR', 'swipe dismiss hook: ' + (error && error.message));
                }
                return page;
            };

            var overlay = document.getElementById('overlay') || window.overlay;
            if (overlay && overlay.children) {
                for (var i = 0; i < overlay.children.length; i++) {
                    installSwipeOnPage(overlay.children[i], '');
                }
            }
            note('PAGE', 'swipe-to-dismiss handler ready');
            return true;
        }

        var attempts = 0;
        var timer = setInterval(function () {
            attempts++;
            var ready = hookPushPage();
            if (ready || attempts > 2500) { clearInterval(timer); }
        }, 20);
    })();
    """

    // MARK: - Reader module prefetch

    /**
     Opening the reader for the first time pulls four modules, each behind its
     own 300-800ms TTFB, and none of them is needed until then:

         /asset/app.v2.read.js            32KB   app.v2.js:3943
         /asset/app.v2.chapterdisplay.js  25KB   app.v2.read.js:237
         /stv.tts.js?v=7                   9KB   app.v2.read.js:2341
         /hanviet.js                      80KB   _page_vip.html:4546

     146KB in series, which is the "卡一下" the first chapter tap costs. Asking
     for them once the home screen has painted moves that off the path the
     reader waits on.

     Safe without touching the site's logic because `scriptmanager.load`
     de-duplicates by URL: in app mode `isCachedFrontend` is true
     (app.v2.js:15), so `!isCachedFrontend` is false and the site requests all
     four with a clean URL -- exactly the keys used here. The site's later call
     therefore finds this entry in `stack` and just waits on it instead of
     fetching again. Passing no `nocache` argument is deliberate: with it the
     site would append `?nocache=<random>` and its own de-duplication (which
     keys on the pre-append URL) would miss.
     */
    static let readerPrefetch = """
    (function () {
        if (window.__stvReaderPrefetchInstalled) { return; }
        window.__stvReaderPrefetchInstalled = true;

        var MODULES = [
            '/asset/app.v2.read.js',
            '/asset/app.v2.chapterdisplay.js',
            '/stv.tts.js?v=7',
            '/hanviet.js'
        ];

        function note(tag, message) {
            if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
        }

        function scriptManager() {
            var ui = window.ui;
            return (ui && ui.scriptmanager && typeof ui.scriptmanager.load === 'function')
                ? ui.scriptmanager : null;
        }

        var requested = false;

        function prefetch(reason) {
            if (requested) { return true; }
            var manager = scriptManager();
            if (!manager) { return false; }
            requested = true;
            for (var i = 0; i < MODULES.length; i++) {
                try {
                    manager.load(MODULES[i], function () {});
                } catch (e) {
                    note('ERR', 'prefetch failed for ' + MODULES[i] + ': ' + e);
                }
            }
            note('PREFETCH', 'reader modules requested (' + reason + ')');
            return true;
        }

        function start() {
            // One idle slot after load, so the site's own first-screen requests
            // are already in flight and keep the connection to themselves.
            if (typeof requestIdleCallback === 'function') {
                requestIdleCallback(function () { prefetch('idle'); }, { timeout: 5000 });
            } else {
                setTimeout(function () { prefetch('timer'); }, 1500);
            }
        }

        if (document.readyState === 'complete') { start(); }
        else { window.addEventListener('load', start); }
    })();
    """

    /**
     Injected in order, and every block is independently guarded, so the order
     is about *when the reader sees something* rather than correctness.

     All of these are `WKUserScript` at document start, which means the whole
     list parses and executes before the page's first inline script runs. The
     list is therefore ordered by what the first frame needs:

       1. `compat` first -- the site calls `nativeclick` unguarded on the book
          list, so without it the very first tap throws.
       2. `assetCache` next -- its URL hooks have to be installed before the
          shell HTML starts creating <script> and <link> elements.
       3. `diag` -- so every later block's `note()` lands somewhere, and early
          errors are captured.
       4. `assetMirror` -- it wraps the two hooks `assetCache` just installed, so
          it has to run *after* them, and it must be in place before the parser
          reaches the shell's own `<script src>` lines.
       5. the rest of the boot-critical set, ending with `bootShell` and the
          Vietnamese->Chinese overlay.

     The heavy, page-specific blocks (`pageRepair` 57KB, `commentTranslate`
     62KB, and the rest of the long tail) come last: they still run before the
     page's own scripts, but only after the fake shell has painted. That drops
     the amount of injected JavaScript parsed before first paint from ~285KB to
     roughly 60KB, which is the number that matters here.

     `SiteI18nData` is generated from data/site-i18n.json by
     scripts/gen-site-i18n.js.
     */
    static let all: [String] = [compat, assetCache, diag, assetMirror,
                                storageAccessor, readerDefaults, safeArea,
                                domainFailover, bootShell, SiteI18nData.script,
                                activityLog, tabProbe, ttsProvider, followFallback,
                                keyboardPopup, gridLayout, settingsBackup,
                                bookmarkToggle, readerTts,
                                pageRepair, downloadExport, commentTranslate,
                                comicGate,
                                swipeDismiss, readerPrefetch]
}
