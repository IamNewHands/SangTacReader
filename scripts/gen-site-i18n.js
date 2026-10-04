#!/usr/bin/env node
/**
 * Generate plugins/app/ios/Sources/SangTacAppPlugin/SiteI18nData.swift from
 * data/site-i18n.json.
 *
 * The generated file is a single Swift multiline string holding the whole
 * Vietnamese -> Simplified Chinese overlay script, which SitePatch injects at
 * document start. It is generated (rather than hand-written) because the
 * dictionary is ~340 pairs and a typo there is invisible until it is on a
 * device; the source of truth stays a diffable JSON file.
 *
 *   node scripts/gen-site-i18n.js           # write the Swift file
 *   node scripts/gen-site-i18n.js --check   # fail if it is out of sync (CI)
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const DATA = path.join(ROOT, 'data', 'site-i18n.json');
const OUT = path.join(
  ROOT,
  'plugins',
  'app',
  'ios',
  'Sources',
  'SangTacAppPlugin',
  'SiteI18nData.swift'
);

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

/** Render a JS string literal without ever needing a backslash escape. */
function jsString(value) {
  if (value.includes('\\')) {
    fail(`dictionary value contains a backslash, which the Swift shim forbids: ${JSON.stringify(value)}`);
  }
  if (!value.includes("'")) return `'${value}'`;
  if (!value.includes('"')) return `"${value}"`;
  fail(`dictionary value contains both quote styles: ${JSON.stringify(value)}`);
  return '';
}

function jsPairs(rows, indent) {
  return rows.map(([vi, zh]) => `${indent}[${jsString(vi)}, ${jsString(zh)}]`).join(',\n');
}

const data = JSON.parse(fs.readFileSync(DATA, 'utf8'));
for (const key of ['exact', 'fragments', 'patterns']) {
  if (!Array.isArray(data[key])) fail(`${DATA}: missing array "${key}"`);
}

const js = `(function () {
    if (window.__stvI18nInstalled) { return; }
    window.__stvI18nInstalled = true;

    // Pairs are [vietnamese, chinese]. The site translates anything written as
    // <text>some_key</text> itself from /mobile/lang/zh.json; these are the
    // strings it hardcodes in the server HTML and in its own JS.
    var EXACT = [
${jsPairs(data.exact, '        ')}
    ];

    // Concatenated messages ("Đã dừng đọc sau " + n + " phút"), matched as
    // substrings, longest first. Only fragments of 5+ characters are listed, so
    // a short common word can never be rewritten in the middle of user data.
    var FRAGMENTS = [
${jsPairs(data.fragments, '        ')}
    ];

    // [viPrefix, viSuffix, zhPrefix, zhSuffix] for messages whose middle part is
    // a value we must keep.
    var PATTERNS = [
${data.patterns
  .map(([a, b, c, d]) => `        [${jsString(a)}, ${jsString(b)}, ${jsString(c)}, ${jsString(d)}]`)
  .join(',\n')}
    ];

    var MAP = {};
    for (var i = 0; i < EXACT.length; i++) { MAP[EXACT[i][0]] = EXACT[i][1]; }

    // Containers holding user data: chapter body, comments, book blurbs, titles,
    // the name editor. Never rewrite text inside these.
    var SKIP = {};
    var SKIP_NAMES = ['pageflipper', 'chapterdpageflip', 'chapterdcontinuos', 'chapterdisplay',
        'chapterview', 'chapterscroller', 'chaptercontent', 'chapterd', 'info', 'comment',
        'post', 'previewcontent', 'name', 'cname', 'chaptername', 'chapter-name',
        'contentcontainer', 'searchinput'];
    for (var s = 0; s < SKIP_NAMES.length; s++) { SKIP[SKIP_NAMES[s]] = true; }

    function hasSkipClass(element) {
        var classes = element.className;
        if (typeof classes !== 'string' || !classes) { return false; }
        var parts = classes.split(' ');
        for (var i = 0; i < parts.length; i++) { if (SKIP[parts[i]]) { return true; } }
        return false;
    }

    // ------------------------------------------------------------------ language
    //
    // This whole block is a Vietnamese -> Chinese layer, so every pass in it is
    // only correct while the reader has actually asked for Chinese. The site's
    // own <text> i18n follows the "lang" cookie (app.v2.js:1887 reads it,
    // app.v2.js:1959-1961 applies it) and the settings row writes both that
    // cookie and app.config.ux.app_language (page-vip:1464), so the cookie is
    // both the live answer and the value the site will read on the next load --
    // it is read first.
    var SITE_LANGUAGES = { vi: true, en: true, zh: true };

    function isLanguageCode(value) {
        return typeof value === 'string' && SITE_LANGUAGES[value] === true;
    }

    function cookieValue(name) {
        var raw = '';
        try { raw = String(document.cookie || ''); } catch (e) { raw = ''; }
        var parts = raw.split(';');
        var head = name + '=';
        for (var i = 0; i < parts.length; i++) {
            var item = parts[i];
            while (item.length && item.charCodeAt(0) === 32) { item = item.substring(1); }
            if (item.indexOf(head) !== 0) { continue; }
            var value = item.substring(head.length);
            try { return decodeURIComponent(value); } catch (e) { return value; }
        }
        return '';
    }

    // The site's own setCookie (app.v2.js:222) is a top-level function in
    // app.v2.js, so it does not exist yet at document start; this writes the
    // same cookie without it.
    function writeLanguageCookie(code) {
        var expires = '';
        try {
            var date = new Date();
            date.setTime(date.getTime() + 365 * 24 * 60 * 60 * 1000);
            expires = '; expires=' + date.toUTCString();
        } catch (e) { expires = ''; }
        try { document.cookie = 'lang=' + code + expires + '; path=/'; } catch (e) {}
    }

    // The cookie first, then the site's own live value: app.language starts as
    // "vi" (app.v2.js:1886) and only becomes the cookie's language once
    // changeLanguage has loaded that language file, so a cookie that already
    // says zh is both earlier and more reliable than app.language.
    function currentLanguage() {
        var cookie = cookieValue('lang');
        if (isLanguageCode(cookie)) { return cookie; }
        var app = window.app;
        if (app && isLanguageCode(app.language)) { return app.language; }
        return 'vi';
    }

    // True while this overlay may rewrite anything at all.
    function chineseUi() {
        return currentLanguage() === 'zh';
    }

    // ------------------------------------------------- first launch picks a language
    //
    // Nothing on the site chooses a language by itself: with no "lang" cookie it
    // boots in Vietnamese (app.v2.js:1886) and the settings row keeps showing
    // app.config.ux.app_language's "vi" default (app.v2.config.js:36). iOS knows
    // which language the reader reads, and the web view cannot: WKWebView's
    // navigator.language is the *app's* localisation, and the Capacitor template
    // ships English only -- so the native side passes Locale.preferredLanguages
    // down as window.__stvDeviceLang and the first launch adopts it. Once the
    // cookie exists the reader's own choice wins, permanently.
    function deviceLanguage() {
        if (typeof window.__stvDeviceLang === 'string' && window.__stvDeviceLang) {
            return window.__stvDeviceLang;
        }
        var nav = window.navigator;
        if (nav && typeof nav.language === 'string' && nav.language) { return nav.language; }
        return '';
    }

    // zh-Hans / zh-Hant / zh-CN all mean the same thing to a site with one
    // Chinese file. Anything the site does not publish (it has vi, en and zh)
    // gets its English UI rather than a language the reader never asked for.
    function mapDeviceLanguage(raw) {
        var text = String(raw === undefined || raw === null ? '' : raw).toLowerCase();
        if (text.indexOf('zh') === 0) { return 'zh'; }
        if (text.indexOf('vi') === 0) { return 'vi'; }
        if (text.indexOf('en') === 0) { return 'en'; }
        return 'en';
    }

    function seedLanguage() {
        if (cookieValue('lang')) { return false; }
        var device = deviceLanguage();
        if (!device) { return false; }
        var seeded = mapDeviceLanguage(device);
        writeLanguageCookie(seeded);
        note('PATCH', 'first launch: language seeded to ' + seeded
            + ' from device ' + device);
        return true;
    }

    // The settings row reads app.config.ux.app_language (page-vip:1464), and the
    // cookie is the language the page is actually rendering in -- so the row is
    // kept equal to the cookie, not only while a fresh seed is being placed. Two
    // things make the standing check necessary:
    //
    //   * the site writes the pick and *then* runs the row's onchange in the same
    //     click (app.v2.js:2049-2054): assigning app.config.ux.app_language goes
    //     through the setter into app.storage, an async bridge call
    //     (app.v2.config.js:77-82, :101-108), and only then does changeLanguage
    //     run -- which is what reloads the page. A write still in flight when the
    //     page goes away is simply lost, so the reloaded page reads the old value
    //     back and shows the language the reader just left while the whole UI is
    //     already in the new one. That is the report.
    //   * settingsBackup restores config.ux from the Keychain a few seconds in
    //     (it waits for the site's own store round trip), which can put an older
    //     value back after the row was already right.
    //
    // The compare keeps it to one write per disagreement.
    function syncSettingLanguage() {
        var app = window.app;
        if (!app || !app.config || !app.config.ux) { return false; }
        var live = currentLanguage();
        try {
            if (app.config.ux.app_language !== live) {
                app.config.ux.app_language = live;
                note('PATCH', 'settings row language set to ' + live);
            }
        } catch (e) {
            note('ERR', 'could not store the language in the settings row: ' + e);
        }
        return true;
    }

    function translate(value) {
        if (!value) { return null; }
        var trimmed = value.trim();
        if (!trimmed) { return null; }
        var direct = MAP[trimmed];
        if (direct !== undefined) {
            return value.replace(trimmed, function () { return direct; });
        }
        for (var i = 0; i < PATTERNS.length; i++) {
            var prefix = PATTERNS[i][0];
            var suffix = PATTERNS[i][1];
            if (prefix.length + suffix.length >= trimmed.length) { continue; }
            if (trimmed.indexOf(prefix) !== 0) { continue; }
            if (trimmed.slice(trimmed.length - suffix.length) !== suffix) { continue; }
            var middle = trimmed.slice(prefix.length, trimmed.length - suffix.length);
            var replacement = PATTERNS[i][2] + middle + PATTERNS[i][3];
            return value.replace(trimmed, function () { return replacement; });
        }
        return null;
    }

    function translateFragments(value) {
        for (var i = 0; i < FRAGMENTS.length; i++) {
            var vi = FRAGMENTS[i][0];
            if (value.indexOf(vi) >= 0) {
                value = value.split(vi).join(FRAGMENTS[i][1]);
            }
        }
        return value;
    }

    // Letters that exist only in Vietnamese. A fragment pass that leaves one of
    // these behind has translated part of the string and left the rest.
    var VIETNAMESE_ONLY = 'ăâđêôơưĂÂĐÊÔƠƯ'
        + 'áàảãạấầẩẫậắằẳẵặéèẻẽẹếềểễệíìỉĩịóòỏõọốồổỗộớờởỡợúùủũụứừửữựýỳỷỹỵ';

    function hasVietnameseLetter(text) {
        for (var i = 0; i < text.length; i++) {
            if (VIETNAMESE_ONLY.indexOf(text.charAt(i)) >= 0) { return true; }
        }
        return false;
    }

    // The 修炼 row (.value.danhhao, page-vip:2750) holds ONE datum: the server's
    // danh hào, "<realm> <layer>". The table knows every layer and the realms
    // that have been observed, so a realm it does not know came out half
    // translated -- "Chân Đế三重" (2026-10-04 report) -- which reads as a broken
    // row rather than as an untranslated one. For this one node the rule is
    // all-or-nothing, and the string that could not be finished is logged so the
    // next report can name it instead of describing it.
    function isDanhhaoNode(node) {
        var parent = node.parentNode;
        if (!parent || parent.nodeType !== 1) { return false; }
        var classes = parent.className;
        if (typeof classes !== 'string' || !classes) { return false; }
        return classes.split(' ').indexOf('danhhao') >= 0;
    }

    var reportedDanhhao = {};
    var danhhaoQueue = [];

    function flushDanhhao() {
        if (!danhhaoQueue.length || !window.__stvDiag) { return; }
        while (danhhaoQueue.length) {
            window.__stvDiag.log('I18N',
                '名号没有对应词条，整条保持原文: ' + danhhaoQueue.shift());
        }
    }

    function reportDanhhao(value) {
        if (reportedDanhhao[value]) { return; }
        reportedDanhhao[value] = true;
        danhhaoQueue.push(value);
        flushDanhhao();
        // The diagnostics block is injected before this one in the app, so the
        // line lands immediately. The retry is for any load order that puts it
        // after: this overlay must not depend on being injected last.
        if (danhhaoQueue.length) { setTimeout(flushDanhhao, 200); }
    }

    var rewritten = 0;

    // The reader header prints the site's own Vietnamese machine translation of
    // the chapter name. The server never exposes the original Chinese title:
    // sajax=readchapter returns only bookname and chaptername,
    // mobile/bookinfo.php carries no chapter list, and transmode=original
    // switches the BODY to Chinese while leaving the title Vietnamese. So the
    // words cannot be recovered here. What we can fix is the scaffolding.
    //
    // Two number formats show up in the wild:
    //     "Chương 3:. Giao phong"   (qidian)
    //     "Thứ 2 chương Ngọc Long"  (fanqie)
    // both become "第<n>章 <title>".
    //
    // Deliberately no regular expression: the whole block has to survive being
    // embedded in a Swift multiline string, which forbids backslashes.
    function skipSpaces(text, index) {
        while (index < text.length && text.charCodeAt(index) <= 32) { index++; }
        return index;
    }

    function digitsAfter(text, index) {
        var digits = '';
        while (index < text.length) {
            var code = text.charCodeAt(index);
            if (code < 48 || code > 57) { break; }
            digits += text.charAt(index);
            index++;
        }
        return digits;
    }

    function stripSeparators(text) {
        while (text.length) {
            var first = text.charAt(0);
            if (first === ':' || first === '.' || first === '-' || text.charCodeAt(0) <= 32) {
                text = text.substring(1);
            } else {
                break;
            }
        }
        return text;
    }

    var TITLE_HEADS = [['Chương', ''], ['Thứ', 'chương']];

    function fixChapterTitle(raw) {
        if (!raw) { return raw; }
        var text = raw;
        var start = skipSpaces(text, 0);
        for (var h = 0; h < TITLE_HEADS.length; h++) {
            var head = TITLE_HEADS[h][0];
            if (text.substring(start, start + head.length) !== head) { continue; }
            var index = skipSpaces(text, start + head.length);
            var digits = digitsAfter(text, index);
            if (!digits) { continue; }
            index += digits.length;
            // qidian zero-pads ("Chương 03:. Giao phong"); 第03章 reads wrong.
            while (digits.length > 1 && digits.charAt(0) === '0') {
                digits = digits.substring(1);
            }
            var between = TITLE_HEADS[h][1];
            if (between) {
                index = skipSpaces(text, index);
                if (text.substring(index, index + between.length) !== between) { continue; }
                index += between.length;
            }
            var tail = stripSeparators(text.substring(index));
            var out = '第' + digits + '章';
            if (tail.length) { out += ' ' + tail; }
            return out;
        }
        return raw;
    }

    // Chapter names sit in SKIP, so walk() never descends into them. That is
    // deliberate: chapter titles are per-book data and must not be run through
    // the fragment table. This pass is the only thing allowed to touch them.
    //
    // Two different elements carry the title and both must be covered:
    //   .chaptername      -- the reader's bottom bar (page-readchapter)
    //   .chapternamefixed -- the static name pinned to the top of the page
    //                        (PageFlipChapterDisplay.updateFixedChapterName)
    // Missing .chapternamefixed is why the top of the reader kept printing
    // "Chương 03:. Giao phong" after the first fix.
    var TITLE_SELECTOR = '.chaptername, .chapternamefixed';

    function applyChapterTitle(node) {
        var text = node.textContent || '';
        var fixed = fixChapterTitle(text);
        if (fixed !== text) { node.textContent = fixed; rewritten++; }
    }

    function fixChapterTitles(root) {
        if (!root || root.nodeType !== 1) { return; }
        // "Chương 03:" -> "第3章" is Chinese scaffolding, so a reader who asked
        // for Vietnamese keeps the site's own title.
        if (!chineseUi()) { return; }
        if (root.classList && (root.classList.contains('chaptername')
            || root.classList.contains('chapternamefixed'))) { applyChapterTitle(root); }
        if (!root.querySelectorAll) { return; }
        var nodes = root.querySelectorAll(TITLE_SELECTOR);
        for (var i = 0; i < nodes.length; i++) { applyChapterTitle(nodes[i]); }
    }

    /**
     Every chapter body the site hands out ends with the site's own archive
     notice ("Bạn đang đọc bản lưu trong hệ thống" -- you are reading the copy
     kept in the system). It is not in any file the client owns: it arrives
     inside the chapter payload, so the only places to take it out are the two
     that consume the payload -- here, for the reader, and the same function
     through window.__stvI18n for the exporter. One definition of what the
     notice is, not two.

     Only the notice goes: the sentence, an optional "Bạn đang đọc " lead-in, a
     decorative "@" in front of it and the punctuation behind it. The rest of
     the paragraph is left exactly as it was, and a second pass is a no-op
     because the marker is gone.
     */
    var NOTICE = 'bản lưu trong hệ thống';
    var NOTICE_LEAD = 'bạn đang đọc';
    var removed = 0;

    function stripNotice(text) {
        var source = String(text === undefined || text === null ? '' : text);
        var lower = source.toLowerCase();
        var at = lower.indexOf(NOTICE);
        if (at < 0) { return source; }
        var start = at;
        var lead = lower.lastIndexOf(NOTICE_LEAD, at);
        if (lead >= 0 && trimText(source.substring(lead + NOTICE_LEAD.length, at)) === '') {
            start = lead;
        }
        while (start > 0) {
            var before = source.charCodeAt(start - 1);
            if (before === 64 || before === 32 || before === 9 || before === 160) { start--; }
            else { break; }
        }
        var end = at + NOTICE.length;
        while (end < source.length) {
            var after = source.charAt(end);
            if (after === '.' || after === '!' || after === '。' || after === '！'
                || after === ' ') { end++; } else { break; }
        }
        return source.substring(0, start) + source.substring(end);
    }

    function stripNoticeNode(node) {
        var text = node.nodeValue || '';
        var next = stripNotice(text);
        if (next === text) { return; }
        node.nodeValue = next;
        removed++;
        if (removed === 1) {
            note('PATCH', 'dropped the site archive notice from the chapter body');
        }
        // The notice is normally a paragraph of its own, and leaving an empty
        // one behind would show up as a blank line: drop the element only when
        // this pass emptied it completely and there is no image inside it.
        var parent = node.parentNode;
        if (next || !parent || parent.nodeType !== 1 || parent.textContent) { return; }
        if (parent.querySelector && parent.querySelector('img')) { return; }
        if (parent.parentNode) { parent.parentNode.removeChild(parent); }
    }

    // Walks text nodes only, and deliberately ignores SKIP: the notice lives in
    // chapter text, which the translation pass is required to stay out of.
    function stripNotices(root) {
        if (!root || root.nodeType !== 1) { return; }
        var children = root.childNodes || [];
        for (var i = children.length - 1; i >= 0; i--) {
            var node = children[i];
            if (node.nodeType === 3) { stripNoticeNode(node); continue; }
            if (node.nodeType !== 1) { continue; }
            var tag = node.tagName ? node.tagName.toLowerCase() : '';
            if (tag === 'script' || tag === 'style' || tag === 'textarea') { continue; }
            stripNotices(node);
        }
    }

    function walk(node) {
        if (!node) { return; }
        // The overlay exists for a Chinese reader only; every other language
        // gets the site's own text untouched.
        if (!chineseUi()) { return; }
        if (node.nodeType === 3) {
            var current = node.nodeValue || '';
            var next = translate(current);
            if (next !== null) {
                if (next !== current) { node.nodeValue = next; rewritten++; }
                return;
            }
            if (current.length >= 5) {
                var fragments = translateFragments(current);
                if (fragments !== current) {
                    if (isDanhhaoNode(node) && hasVietnameseLetter(fragments)) {
                        reportDanhhao(current);
                    } else {
                        node.nodeValue = fragments;
                        rewritten++;
                    }
                }
            }
            return;
        }
        if (node.nodeType !== 1) { return; }
        if (hasSkipClass(node)) { return; }
        if (node.getAttribute && node.getAttribute('data-stvdiag')) { return; }
        if (node.getAttribute) {
            var placeholder = node.getAttribute('placeholder');
            if (placeholder) {
                var translatedPlaceholder = translate(placeholder);
                if (translatedPlaceholder !== null) { node.setAttribute('placeholder', translatedPlaceholder); }
            }
            var title = node.getAttribute('title');
            if (title) {
                var translatedTitle = translate(title);
                if (translatedTitle !== null) { node.setAttribute('title', translatedTitle); }
            }
        }
        var tag = node.tagName ? node.tagName.toLowerCase() : '';
        if (tag === 'script' || tag === 'style' || tag === 'textarea' || tag === 'input') { return; }
        var children = node.childNodes || [];
        for (var i = 0; i < children.length; i++) { walk(children[i]); }
    }

    // ------------------------------------------------------- the reader's alert
    //
    // The reader's error alert -- the unlock message with its "Tải lại" button --
    // is built inside the chapter frame, or inside .contentcontainer, which the
    // translation pass skips on purpose because the chapter text lives there too
    // (app.v2.chapterdisplay.js:873 showAlert writes into the frame's
    // #maincontent, :1967 writes a page of its own, :3816 writes into
    // .contentcontainer). So neither the message nor the button was ever walked,
    // and both stayed Vietnamese inside a Chinese UI. Only the alert subtree is
    // walked here: it never holds novel text, so the skip list does not apply.
    var ALERT_SELECTOR = '.erroralert';

    function walkAlert(node) {
        if (!node) { return; }
        if (node.nodeType === 3) {
            var current = node.nodeValue || '';
            var next = translate(current);
            if (next === null && current.length >= 5) { next = translateFragments(current); }
            if (next !== null && next !== current) { node.nodeValue = next; rewritten++; }
            return;
        }
        if (node.nodeType !== 1) { return; }
        var children = node.childNodes || [];
        for (var i = 0; i < children.length; i++) { walkAlert(children[i]); }
    }

    // Works for a document and for an element. querySelectorAll does not match
    // the node itself, so a subtree that *is* the alert is walked directly.
    function sweepAlertsIn(root) {
        if (!chineseUi()) { return; }
        if (!root || root.nodeType !== 1) { return; }
        if (root.classList && root.classList.contains('erroralert')) { walkAlert(root); }
        if (typeof root.querySelectorAll !== 'function') { return; }
        var found = null;
        try { found = root.querySelectorAll(ALERT_SELECTOR); } catch (e) { found = null; }
        for (var i = 0; found && i < found.length; i++) { walkAlert(found[i]); }
    }

    function sweep() {
        try {
            walk(document.body || document.documentElement);
            fixChapterTitles(document.documentElement);
            stripNotices(document.documentElement);
            sweepAlertsIn(document.documentElement);
        } catch (e) {
            if (window.__stvDiag) { window.__stvDiag.log('ERR', 'i18n sweep failed: ' + e); }
        }
    }

    // The chapter text -- and therefore the pinned chapter name -- lives in a
    // same-origin srcdoc iframe, not in this document, so the main sweep can
    // never reach it. Inside frames only three passes run, none of which rewrites
    // the novel: the title pass, the notice pass, and the alert pass (whose
    // selector is the only thing it touches). The general translation pass stays
    // out, because putting the fragment table on top of novel text is exactly
    // what it is not meant for.
    function frameDocument(frame) {
        var doc = null;
        try { doc = frame.contentDocument; } catch (e) { doc = null; }
        return doc || null;
    }

    function sweepFrame(frame) {
        var doc = frameDocument(frame);
        if (!doc || !doc.documentElement) { return; }
        try {
            fixChapterTitles(doc.documentElement);
            stripNotices(doc.documentElement);
            sweepAlertsIn(doc.documentElement);
        } catch (e) {
            if (window.__stvDiag) { window.__stvDiag.log('ERR', 'i18n frame sweep failed: ' + e); }
        }
    }

    function frameRecords(records) {
        for (var i = 0; i < records.length; i++) {
            var record = records[i];
            if (record.target && record.target.nodeType === 1) {
                fixChapterTitles(record.target);
                stripNotices(record.target);
                sweepAlertsIn(record.target);
            }
        }
    }

    function attachFrame(frame) {
        var doc = frameDocument(frame);
        if (!doc) { return; }
        // The flag lives on the document, not the window: assigning srcdoc
        // navigates the iframe and swaps the document out, so a window-scoped
        // flag would leave the observer attached to a dead document and the
        // pinned name would stop being translated after the first chapter change.
        if (!doc.__stvI18nFrame) {
            doc.__stvI18nFrame = true;
            var win = null;
            try { win = frame.contentWindow; } catch (e) { win = null; }
            if (win) {
                try {
                    win.addEventListener('load', function () { sweepFrame(frame); });
                } catch (e) {}
            }
            if (window.MutationObserver) {
                try {
                    new window.MutationObserver(frameRecords).observe(doc, {
                        childList: true, subtree: true, characterData: true
                    });
                } catch (e) {}
            }
        }
        sweepFrame(frame);
        // The reader nests. The page-flip template is one srcdoc frame and a
        // chapter can be another frame inside it, and querySelectorAll does not
        // cross a document boundary -- so the frame that actually holds the
        // chapter text was never reached, and the archive notice stayed in the
        // body the reader was looking at (2026-09-23 device log, no PATCH line
        // for a whole session). Every frame now looks for its own children.
        attachFramesIn(doc);
    }

    // Works for a document and for an element: both answer querySelectorAll,
    // and a chapter frame is normally inserted as part of a subtree rather than
    // on its own, which is why the observer hands the added node straight in.
    function attachFramesIn(root) {
        if (!root || typeof root.querySelectorAll !== 'function') { return; }
        var frames = null;
        try { frames = root.querySelectorAll('iframe'); } catch (e) { frames = null; }
        for (var i = 0; frames && i < frames.length; i++) { attachFrame(frames[i]); }
    }

    function attachFrames() {
        attachFramesIn(document);
    }

    // Translating the title element in place is not enough on its own: the site
    // compares what it wrote last time with the chapter's own name and, when the
    // two differ, re-runs a whole recycle pass --
    //
    //     updateFixedChapterName(c)  (chapterdisplay.js:3579)
    //         var oldName = fixed.textContent;
    //         if (oldName != name) { fixed.textContent = name; this.recycle(c);
    //                                app.reader.updateHistory2(); }
    //
    // so a translated DOM value makes that branch fire on every scroll tick.
    // The name itself comes from one place -- cdata.chaptername, produced by
    // app.reader.getContent() -- and every consumer (createPage, resetPageHtml,
    // getPrependChapterNameHTML, updateFixedChapterName, the bottom bar) reads
    // it from there. Translating at that single source keeps the comparison
    // equal, so the title is Chinese everywhere and the recycle branch stays
    // quiet. The DOM pass above remains as a fallback for anything rendered
    // before this wrapper is installed.
    var CONTENT_FIELDS = ['chaptername'];

    function fixChapterData(cdata) {
        if (!cdata || typeof cdata !== 'object') { return cdata; }
        // The chapter name is rewritten to the Chinese scaffolding here, at the
        // single source every consumer reads; a Vietnamese reader keeps it.
        if (!chineseUi()) { return cdata; }
        for (var i = 0; i < CONTENT_FIELDS.length; i++) {
            var field = CONTENT_FIELDS[i];
            var raw = cdata[field];
            if (typeof raw !== 'string' || !raw) { continue; }
            var fixed = fixChapterTitle(raw);
            if (fixed !== raw) {
                cdata[field] = fixed;
                rewritten++;
            }
        }
        return cdata;
    }

    // The chapter NAME the reader receives is the site's Vietnamese machine
    // translation, and readchapter carries no original: the chaptername field stays
    // Vietnamese even when the body comes back in Chinese (transmode=chinese).
    // The chapter LIST does have it -- getChapterListOnline (app.v2.js:270)
    // prefers x.oridata, the original, whenever app.language is not Vietnamese
    // -- so the Chinese title is one chapterlist request away, keyed by the same
    // cid the reader already knows.
    var titleMaps = {};
    var titleTried = {};
    var titleOrders = {};
    var titleRequests = {};

    function note(tag, message) {
        if (window.__stvDiag) { window.__stvDiag.log(tag, message); }
    }

    function trimText(value) {
        var s = String(value == null ? '' : value);
        while (s.length && s.charCodeAt(0) <= 32) { s = s.substring(1); }
        while (s.length && s.charCodeAt(s.length - 1) <= 32) {
            s = s.substring(0, s.length - 1);
        }
        return s;
    }

    function cjkCount(text) {
        var n = 0;
        for (var i = 0; i < text.length; i++) {
            var code = text.charCodeAt(i);
            if (code >= 0x3400 && code <= 0x9FFF) { n++; }
        }
        return n;
    }

    // The list is "index-/-cid-/-title-/-vip" entries joined by "-//-". The
    // order is the book's own reading order, which the exporter needs so a
    // downloaded slice keeps the book's chapter numbers.
    function parseChapterList(text) {
        var names = {};
        var order = [];
        var list = String(text).split('-//-');
        for (var i = 0; i < list.length; i++) {
            var parts = list[i].split('-/-');
            if (parts.length < 3) { continue; }
            var cid = trimText(parts[1]);
            var title = trimText(parts[2]);
            if (!cid) { continue; }
            order.push(cid);
            if (title) { names[cid] = title; }
        }
        return { names: names, order: order };
    }

    function firstChinese(map) {
        for (var cid in map) {
            if (cjkCount(map[cid])) { return map[cid].substring(0, 20); }
        }
        return '';
    }

    // "Chương 03:. Giao phong" + original "交锋" -> "第3章 交锋". When the
    // original already carries its own numbering the Vietnamese scaffolding is
    // dropped instead of duplicated.
    function chineseChapterName(vietnamese, original) {
        var text = trimText(original);
        if (!text) { return null; }
        if (text.indexOf('章') >= 0) { return text; }
        var numbered = fixChapterTitle(vietnamese || '');
        var head = '';
        if (numbered.indexOf('第') === 0) {
            var index = numbered.indexOf('章');
            if (index > 0) { head = numbered.substring(0, index + 1); }
        }
        return head ? head + ' ' + text : text;
    }

    function currentCid() {
        try { return String(window.app.reader.getPCN().current.cid); } catch (e) { return ''; }
    }

    // The name the bottom bar should show for the chapter on screen when the
    // display has none of its own: the original title the chapter list carries,
    // keyed by cid. Empty when that list is not loaded (a vi/en reader never asks
    // for it) or the cid is not in it.
    function originalNameFor(view) {
        if (!view) { return ''; }
        var cid = view.cid ? String(view.cid) : '';
        if (!cid || cid === '0') { return ''; }
        var app = window.app;
        var map = titleMaps[app.reader.host + '/' + app.reader.id];
        if (!map || !map[cid]) { return ''; }
        var vietnamese = (view.cdata && view.cdata.chaptername) || '';
        return chineseChapterName(vietnamese, map[cid]) || '';
    }

    // Called once the list arrives: the chapter is already on screen with its
    // Vietnamese name, so rewrite the rendered title and the chapter's own
    // cdata. Keeping cdata in step is what stops updateFixedChapterName()'s
    // oldName != name guard from firing a recycle pass on every scroll.
    function applyTitles(host, id) {
        var map = titleMaps[host + '/' + id];
        if (!map) { return; }
        var app = window.app;
        var cid = currentCid();
        if (!cid || !map[cid]) { return; }
        var display = null;
        try { display = app.reader.getDisplay(); } catch (e) { display = null; }
        var view = null;
        try { view = display.getCurrentChapter(); } catch (e) { view = null; }
        var vietnamese = (view && view.cdata && view.cdata.chaptername) || '';
        var name = chineseChapterName(vietnamese, map[cid]);
        if (!name) { return; }
        if (view && view.cdata) { view.cdata.chaptername = name; }
        // Scoped to the reader page: .chaptername is the bottom bar there, and
        // an unscoped query could catch an unrelated element.
        var nodes = document.querySelectorAll('#chapterview .chaptername');
        for (var i = 0; i < nodes.length; i++) { nodes[i].textContent = name; }
        try {
            var list = display.innerWindow.q('.chapternamefixed');
            for (var j = 0; j < list.length; j++) { list[j].textContent = name; }
        } catch (e) {}
        note('TITLE', 'chapter ' + cid + ' -> ' + name);
    }

    // Returns the map when it is already loaded, null otherwise. The lookup is
    // deliberately not awaited: the first chapter of a book must not wait for a
    // 100 KB chapterlist response, so the title is corrected a moment later.
    function chapterTitleMap(host, id) {
        // The Chinese original is only wanted by the Chinese reader, and this is
        // where the 100 KB chapterlist request is paid for: a reader on vi/en
        // never sends it.
        if (!chineseUi()) { return null; }
        var key = host + '/' + id;
        if (titleMaps[key]) { return titleMaps[key]; }
        if (titleTried[key]) { return null; }
        var app = window.app;
        if (!app || !app.net || typeof app.net.get !== 'function') { return null; }
        titleTried[key] = true;
        var url = '/index.php?ngmar=chapterlist&h=' + host + '&bookid=' + id
            + '&sajax=getchapterlist';
        app.net.get(url).then(function (down) {
            var parsed = null;
            if (down && typeof down.oridata === 'string' && down.oridata) {
                parsed = parseChapterList(down.oridata);
            }
            var map = parsed ? parsed.names : null;
            if (parsed) { titleOrders[key] = parsed.order; }
            var usable = 0;
            for (var cid in map) { if (cjkCount(map[cid])) { usable++; } }
            if (!usable) {
                note('TITLE', 'no original chapter names for ' + key + ' (oridata '
                    + (down && down.oridata ? 'present but not Chinese' : 'absent') + ')');
                return;
            }
            titleMaps[key] = map;
            note('TITLE', 'original chapter names for ' + key + ': ' + usable + ' of '
                + Object.keys(map).length + ', sample=' + firstChinese(map));
            applyTitles(host, id);
            // The bar may already be blank -- it was drawn while the chapter had
            // no name to give. This is the moment the fallback becomes possible,
            // so ask the site to draw it again.
            try { window.app.reader.updateCnameAndProgress(); } catch (e) {}
        }, function (error) {
            note('ERR', 'chapter name lookup failed for ' + key + ': ' + error);
        });
        return null;
    }

    // The export path can wait for the list, and it has to: a chapter's Chinese
    // name comes from this response and nowhere else (readchapter never carries
    // the original). Resolves with whatever is known -- names may be null while
    // order is usable, which still numbers the headings correctly -- and a
    // lookup that found nothing is not cached, so a later export retries instead
    // of exporting Vietnamese titles forever.
    function chapterNames(host, id) {
        var key = host + '/' + id;
        if (titleRequests[key]) { return titleRequests[key]; }
        var pending;
        if (titleMaps[key]) {
            pending = Promise.resolve({ names: titleMaps[key],
                                        order: titleOrders[key] || [] });
        } else {
            pending = new Promise(function (resolve) {
                var app = window.app;
                if (!app || !app.net || typeof app.net.get !== 'function') {
                    resolve({ names: null, order: [] });
                    return;
                }
                var url = '/index.php?ngmar=chapterlist&h=' + host + '&bookid=' + id
                    + '&sajax=getchapterlist';
                app.net.get(url).then(function (down) {
                    var parsed = null;
                    if (down && typeof down.oridata === 'string' && down.oridata) {
                        parsed = parseChapterList(down.oridata);
                    }
                    if (!parsed) {
                        note('TITLE', 'export: no chapter list for ' + key);
                        resolve({ names: null, order: [] });
                        return;
                    }
                    titleOrders[key] = parsed.order;
                    var usable = 0;
                    for (var cid in parsed.names) {
                        if (cjkCount(parsed.names[cid])) { usable++; }
                    }
                    if (!usable) {
                        note('TITLE', 'export: chapter names for ' + key
                            + ' have no Chinese original');
                        resolve({ names: null, order: parsed.order });
                        return;
                    }
                    titleMaps[key] = parsed.names;
                    note('TITLE', 'export: ' + usable + ' of '
                        + Object.keys(parsed.names).length + ' chapter names for '
                        + key + ', sample=' + firstChinese(parsed.names));
                    resolve({ names: parsed.names, order: parsed.order });
                }, function (error) {
                    note('ERR', 'chapter name lookup failed for ' + key + ': ' + error);
                    resolve({ names: null, order: [] });
                });
            });
        }
        titleRequests[key] = pending.then(function (found) {
            if (!found || !found.names) { delete titleRequests[key]; }
            return found;
        });
        return titleRequests[key];
    }

    function attachContent() {
        var app = window.app;
        if (!app || !app.reader || typeof app.reader.getContent !== 'function') { return false; }
        if (app.reader.__stvTitleSourceWrapped) { return true; }
        app.reader.__stvTitleSourceWrapped = true;
        var original = app.reader.getContent;
        app.reader.getContent = function (host, id, cid, reload) {
            var args = arguments;
            var result = original.apply(this, args);
            if (!result || typeof result.then !== 'function') {
                return fixChapterData(result, host, id, cid);
            }
            return result.then(function (cdata) {
                var fixed = fixChapterData(cdata, host, id, cid);
                var map = chapterTitleMap(host, id);
                if (map && cid && map[String(cid)]) {
                    var name = chineseChapterName(fixed && fixed.chaptername, map[String(cid)]);
                    if (name && fixed) { fixed.chaptername = name; rewritten++; }
                }
                return fixed;
            });
        };
        return true;
    }

    /**
     The site's settings page can hand its own language setter something that is
     not a language. Its language row carries the selection path
     "app.config.ux.app_language" and the onchange
     "app.text.changeLanguage('value')" (page-vip:1464), and that onchange is
     eval'd with the picked value substituted (page-vip:3646-3649) -- the same
     handler stack the domain row goes through, so the domain's value has been
     seen arriving here: the 2026-09-23 log is 25 requests to
     /mobile/lang/https://sangtacviet.app.json, ~500ms each, all 403, starting
     the moment the domain row was tapped.

     changeLanguage's failure path is one request to /mobile/lang/<value>.json,
     so a value that cannot be a language is refused before it can reach the
     network. Language codes are letters, digits, "-" and "_": the site's own
     three are vi, en and zh.
     */
    var LANG_CODE = new RegExp('^[A-Za-z][A-Za-z0-9_-]{0,11}$');

    // Switching language has to re-render the page from the new cookie. The
    // site's own changeLanguage only swaps the app.text table and re-runs the
    // <text> nodes (app.v2.js:1952-1956), which leaves every hardcoded string it
    // already rendered in the old language -- and, with this overlay, every
    // string already rewritten to Chinese still Chinese while the strings that
    // must now be rewritten are still Vietnamese. That half-translated page is
    // exactly the report. A reload is also what the rest of the site's settings
    // UI needs, so it is done once, from the cookie the site has already written.
    //
    // No loop is possible: the reloaded page reads the cookie the switch just
    // wrote, so the site's own boot call re-applies the language it is already
    // in and the difference test above is false. The one-shot flag only covers a
    // reload that never happened.
    var reloadedFor = '';

    function reloadForLanguage(code) {
        if (reloadedFor === code) { return; }
        reloadedFor = code;
        note('PATCH', 'language switched to ' + code + '; reloading so the page re-renders');
        // A moment, not immediately: the row's own write goes through
        // app.storage (an async bridge call) and the site runs it in the same
        // click as this changeLanguage, so navigating away in the same turn
        // drops it -- the reloaded page would then show the language the reader
        // just left. syncSettingLanguage repairs that too, but not losing the
        // write in the first place is the cheaper half of the fix.
        setTimeout(function () {
            try { window.location.reload(); } catch (e) {}
        }, 300);
    }

    function installLanguageGuard() {
        var app = window.app;
        if (!app || !app.text || typeof app.text.changeLanguage !== 'function') { return false; }
        if (app.text.__stvLangGuarded) { return true; }
        app.text.__stvLangGuarded = true;
        var original = app.text.changeLanguage;
        app.text.changeLanguage = function (langCode) {
            var code = String(langCode === undefined || langCode === null ? '' : langCode);
            if (!LANG_CODE.test(code)) {
                note('PATCH', 'refused a language that is not one: '
                    + code.substring(0, 60) + ' (the site stays on '
                    + currentLanguage() + ')');
                return null;
            }
            var before = currentLanguage();
            var result = original.apply(this, arguments);
            // The site's own boot call re-applies the cookie it just read, so
            // the two agree there and no reload is triggered.
            if (isLanguageCode(code) && code !== before) { reloadForLanguage(code); }
            return result;
        };
        note('PATCH', 'language setter guarded');
        return true;
    }

    // ------------------------------------------------ the reader's two funnels
    //
    // Both repairs below hang off a funnel the site itself owns, because the
    // display classes live in site-assets/ (verbatim mirrors: editing them would
    // break gen-site-assets.js --check) and because each of these is the single
    // point every display implementation passes through.
    //
    // 1. app.reader.showAlert (app.v2.read.js:790) is where an alert message
    //    enters the reader: every exc[] handler funnels through it and it then
    //    calls the active display's own showAlert, each of which bakes the text
    //    into its own template (app.v2.chapterdisplay.js:873 writes into the
    //    frame's #maincontent, :1967 sets a page of its own, :3816 writes into
    //    .contentcontainer). Translating at that funnel does not depend on
    //    reaching any of those DOM shapes; the alert-scoped pass below still runs
    //    for the literal "Tải lại" inside the template.
    //
    // 2. app.reader.handlingException (app.v2.read.js:729) is where a chapter
    //    that could NOT be loaded ends up. All three displays take the same
    //    failure branch -- setNotLoading(view) then
    //    app.reader.handlingException(cdata, view)
    //    (app.v2.chapterdisplay.js:1829-1832, :800, :3697) -- and never reach
    //    assignNavigator(...), which is the only place
    //    previd/nextid are filled in. So the failed chapter keeps "0" for both,
    //    and the page-flip chain reads that "0" as "there is no neighbour":
    //    ensurePreload calls prev.remove()/next.remove()
    //    (app.v2.chapterdisplay.js:1663-1665, :1679-1681), which EMPTIES that
    //    neighbour's pages (PageClipChapter.remove, :1236) while leaving its cid
    //    set. goPrevChapter then passes its cid != "0" guard, swaps
    //    currentChapter to the emptied object, and jumpToPage(firstPage()) gets
    //    undefined and returns early (:1776-1784): the chapter pointer moves and
    //    the screen does not. The next tap therefore looks like a two-chapter
    //    jump -- exactly the 2026-10-03 report, "再点一下< 会切换到前两章".
    //    Asking for the same navigator the success path asks for makes the failed
    //    chapter a first-class link in that chain, so < and > move one chapter.
    //    The argument matters: assignNavigator only asks the server when it was
    //    handed a zero (:1848), and the failure response has no prev/next at all,
    //    so undefined would pass that gate as false and silently skip the lookup
    //    -- the "no reaction at all" half of the 2026-10-03 report (a chapter
    //    opened straight onto the locked one keeps previd/nextid "0", so both
    //    nav buttons are dead until the reader is left and re-entered).
    //
    // 3. Resolving that navigator is not enough on its own. A chapter enters the
    //    chain with its cid already set: preload assigns it before the answer
    //    comes back (:1806), so tapping < or > onto a locked chapter runs
    //    ensurePreload while that chapter still reports previd/nextid "0" -- read
    //    as "there is no neighbour" -- and the chain calls
    //    prev.remove()/next.remove() (:1663-1665, :1679-1681).
    //    PageClipChapter.remove() (:1236) empties pages and pageElements but
    //    keeps cid, and goPrevChapter's only guard is cid (:1917), so the tap
    //    swaps the chapter pointer to an object with nothing to render: the
    //    chapter name in the bar moves and the body does not. The response that
    //    would have said otherwise arrives afterwards, so the damage is already
    //    done; the unload itself has to ask whether the chapter that ordered it
    //    knew anything. A chapter with content has had setContent run and
    //    assignNavigator follow it (:1815-1821); a chapter whose load failed, or
    //    has not answered yet, has no cdata at all. Only the second kind gets its
    //    real neighbours kept -- a stub neighbour, built with cid "0" (:992), is
    //    still unloaded exactly as before, and so is any neighbour of a chapter
    //    that did load.
    function translateAlertMessage(msg) {
        if (typeof msg !== 'string' || !msg || !chineseUi()) { return msg; }
        var direct = translate(msg);
        if (direct !== null) { return direct; }
        return translateFragments(msg);
    }

    function installReaderFunnels() {
        var app = window.app;
        if (!app || !app.reader) { return false; }
        if (typeof app.reader.showAlert !== 'function'
            || typeof app.reader.handlingException !== 'function') { return false; }
        if (app.reader.__stvReaderFunnels) { return true; }
        app.reader.__stvReaderFunnels = true;

        var showAlert = app.reader.showAlert;
        app.reader.showAlert = function (msg, view) {
            var result = showAlert.call(this, translateAlertMessage(msg), view);
            // The display templates carry a literal "Tải lại". The alert subtree
            // is the one place the translation pass may touch inside a frame, so
            // run it now instead of waiting for the observer or the 1s timer.
            try {
                sweepAlertsIn(document.documentElement);
                attachFrames();
                installChapterUnloadGuard(view);
            } catch (e) {}
            return result;
        };

        var handlingException = app.reader.handlingException;
        app.reader.handlingException = function (x, view) {
            var result = handlingException.apply(this, arguments);
            // The failure branch skips assignNavigator, so the chapter that could
            // not be opened would keep previd/nextid "0" -- and the chain would
            // drop its real neighbours. Ask for them the same way the success
            // path does; the display's own ensurePreload() re-arms the chain.
            // The zeros are what makes the display ask at all: the failure
            // response carries neither prev nor next, and undefined fails the
            // == 0 gate it checks.
            try {
                installChapterUnloadGuard(view);
                var display = app.reader.getDisplay();
                if (display && typeof display.assignNavigator === 'function'
                    && view && view.cid && app.reader.host && app.reader.id) {
                    display.assignNavigator(app.reader.host, app.reader.id,
                                            view.cid, { prev: 0, next: 0 }, view);
                }
            } catch (e) {
                note('ERR', 'failed-chapter navigator: ' + e);
            }
            return result;
        };
        // A display is built in exactly one place (app.v2.read.js:400-416, called
        // from the reader's own init at :357 and from changeDisplay at :423), so
        // hooking the builder covers both, and covers a display type the reader
        // switches to later. The 200ms poll is the belt to this brace.
        var loadChapterDisplay = app.reader.loadChapterDisplay;
        if (typeof loadChapterDisplay === 'function' && !app.reader.__stvDisplayNameHook) {
            app.reader.__stvDisplayNameHook = true;
            app.reader.loadChapterDisplay = function () {
                var display = loadChapterDisplay.apply(this, arguments);
                installDisplayName(display);
                return display;
            };
        }
        note('PATCH', 'reader alert and failed-chapter navigator hooked');
        return true;
    }

    // The page-flip chapter objects are the only ones this overlay touches, and
    // they are identified by shape rather than by name alone: the class is a
    // global binding created by a mirrored site script, so a bare reference is
    // the cheapest route, with the live instance as a fallback. A frame-based
    // display keeps its chapters as DOM elements, whose remove() is the native
    // Element method and must never be wrapped.
    function isClipChapter(v) {
        return !!v && !v.nodeType
            && typeof v.remove === 'function'
            && v.pages && typeof v.pages.length === 'number'
            && v.pageElements && typeof v.pageElements.length === 'number';
    }

    function clipChapterProto(view) {
        try {
            if (typeof PageClipChapter === 'function') {
                var named = PageClipChapter.prototype;
                if (named && typeof named.remove === 'function') { return named; }
            }
        } catch (e) {}
        var candidates = [];
        if (isClipChapter(view)) { candidates.push(view); }
        var display = null;
        try {
            display = window.app && window.app.reader && window.app.reader.getDisplay
                ? window.app.reader.getDisplay() : null;
        } catch (e2) { display = null; }
        if (display && isClipChapter(display.currentChapter)) {
            candidates.push(display.currentChapter);
        }
        for (var i = 0; i < candidates.length; i++) {
            var proto = candidates[i].constructor && candidates[i].constructor.prototype;
            if (proto && typeof proto.remove === 'function') { return proto; }
        }
        return null;
    }

    // remove() is only ever called by ensurePreload's "the current chapter says
    // there is no neighbour" branch, so the order is trustworthy exactly when
    // that current chapter has content: setContent fills cdata and
    // assignNavigator follows it (:1815-1821). No cdata means the chapter is
    // still loading or failed, and its "0" is a placeholder, not a fact.
    function unloadOrderIsUninformed() {
        var display = null;
        try {
            display = window.app && window.app.reader && window.app.reader.getDisplay
                ? window.app.reader.getDisplay() : null;
        } catch (e) { display = null; }
        var current = display && display.currentChapter;
        return !!current && !current.cdata;
    }

    function installChapterUnloadGuard(view) {
        var proto = clipChapterProto(view);
        if (!proto) { return false; }
        if (proto.__stvUnloadGuard) { return true; }
        var remove = proto.remove;
        proto.remove = function () {
            // A chapter that knows its id is real content, not a spent worker.
            if (this.cid && this.cid !== '0' && unloadOrderIsUninformed()) { return; }
            return remove.apply(this, arguments);
        };
        proto.__stvUnloadGuard = true;
        note('PATCH', 'chapter unload keeps a real chapter while its own chapter is still loading');
        return true;
    }

    function currentDisplay() {
        try { return window.app.reader.getDisplay(); } catch (e) { return null; }
    }

    // The bar's chapter name comes from the active display and from nowhere else:
    // app.v2.read.js:877-883 writes .line2 .chaptername with whatever
    // getChapterNameAndProgress answers. Every display answers with an empty name
    // while its chapter has no content -- app.v2.chapterdisplay.js:1999-2010
    // returns "" without cdata, :942 and :3882 do the same for the frame displays
    // -- and a chapter that needs unlocking never gets cdata, because its body
    // never arrives. So the bar goes blank on exactly the chapters where it is
    // the only proof that a < or > tap moved: every locked chapter renders the
    // same alert page. The 2026-10-03 report is that, verbatim: < switched (the
    // drawer agreed) but nothing on the reading screen said so.
    //
    // Patch the answer, not the DOM: the site keeps its own writer, and the name
    // it then shows is the original chapter title the overlay has already fetched
    // for this book (titleMaps, from getchapterlist), so the bar, the drawer and
    // the exported file agree on one name.
    function installDisplayName(display) {
        if (!display) { return false; }
        var proto = display.constructor && display.constructor.prototype;
        if (!proto || typeof proto.getChapterNameAndProgress !== 'function') { return false; }
        if (proto.__stvNameFallback) { return true; }
        proto.__stvNameFallback = true;
        var own = proto.getChapterNameAndProgress;
        proto.getChapterNameAndProgress = function () {
            var answer = own.apply(this, arguments);
            if (answer && answer.name) { return answer; }
            var view = null;
            try { view = this.getCurrentChapter(); } catch (e) { view = null; }
            var name = originalNameFor(view);
            if (!name) { return answer; }
            return { name: name, progress: answer ? answer.progress : 0 };
        };
        note('PATCH', 'the chapter bar keeps a name while the chapter has no content');
        return true;
    }

    window.__stvI18n = {
        translate: translate,
        sweep: sweep,
        sweepFrames: attachFrames,
        fixChapterTitle: fixChapterTitle,
        chineseChapterName: chineseChapterName,
        chapterNames: chapterNames,
        stripNotice: stripNotice,
        // The language this overlay resolved, and whether it is allowed to
        // rewrite anything: one definition, read by the tests and by anything
        // that needs to know whether the page is Chinese.
        language: currentLanguage,
        chineseUi: chineseUi,
        sweepAlerts: sweepAlertsIn,
        installReaderFunnels: installReaderFunnels,
        unloadGuard: installChapterUnloadGuard,
        displayName: installDisplayName,
        size: EXACT.length,
        rewritten: function () { return rewritten; },
        removed: function () { return removed; }
    };

    if (window.MutationObserver) {
        var observer = new MutationObserver(function (records) {
            for (var i = 0; i < records.length; i++) {
                var record = records[i];
                if (record.type === 'characterData') {
                    walk(record.target);
                    stripNoticeNode(record.target);
                } else {
                    var added = record.addedNodes || [];
                    for (var j = 0; j < added.length; j++) {
                        var node = added[j];
                        walk(node);
                        // The archive notice arrives with the chapter text, and
                        // the reader mounts that minutes into the session --
                        // long after the delay list below has run out. Strip on
                        // the mutation and look for frames inside what arrived,
                        // not only on a timer and not only when the added node
                        // is itself an iframe.
                        stripNotices(node);
                        // The reader's error alert is inserted the same way.
                        sweepAlertsIn(node);
                        if (node.nodeType === 1) { attachFramesIn(node); }
                    }
                }
                // The reader rewrites .chaptername.textContent on every chapter
                // change, which arrives as a childList mutation ON that node.
                if (record.target && record.target.nodeType === 1) {
                    fixChapterTitles(record.target);
                }
            }
        });
        observer.observe(document, { childList: true, subtree: true, characterData: true });
    }

    // Before the first sweep, and before any site script can read the cookie:
    // the very first launch adopts the device's language (see seedLanguage).
    seedLanguage();

    if (document.body) {
        sweep();
    } else {
        document.addEventListener('DOMContentLoaded', function () { sweep(); });
    }
    // The reader builds its iframe lazily and rebuilds it on every display-type
    // change, so re-scan a handful of times instead of trusting one pass.
    var FRAME_DELAYS = [0, 300, 1000, 2000, 4000, 8000];
    for (var f = 0; f < FRAME_DELAYS.length; f++) {
        setTimeout(function () {
            sweep(); attachFrames(); attachContent(); installLanguageGuard();
            syncSettingLanguage(); installReaderFunnels(); installChapterUnloadGuard();
            installDisplayName(currentDisplay());
        }, FRAME_DELAYS[f]);
    }

    // ...and keep looking. The reader frame is built when a chapter is opened,
    // which can be any time in the session, and assigning srcdoc swaps the
    // document inside an iframe that is already attached and produces no
    // mutation this document can see. Attaching is what arms the notice pass
    // for the chapter text the frame is about to hold. An hour is longer than
    // any reading session and keeps the timer from outliving the page.
    //
    // The settings row rides along on this tick: a language switch reloads the
    // page, and the row's own persisted value can be lost in that navigation or
    // put back by the Keychain restore, so the row is re-checked against the
    // cookie once a second for as long as the page lives.
    var frameAttempts = 0;
    var frameTimer = setInterval(function () {
        frameAttempts++;
        attachFrames();
        stripNotices(document.documentElement);
        syncSettingLanguage();
        if (frameAttempts > 3600) { clearInterval(frameTimer); }
    }, 1000);

    var contentAttempts = 0;
    var contentTimer = setInterval(function () {
        contentAttempts++;
        if (attachContent() || contentAttempts > 600) { clearInterval(contentTimer); }
    }, 200);

    // app.text.changeLanguage is created with app.text, which can land after
    // this block: poll for it rather than assume the order.
    var langAttempts = 0;
    var langTimer = setInterval(function () {
        langAttempts++;
        if (installLanguageGuard() || langAttempts > 600) { clearInterval(langTimer); }
    }, 200);

    // app.reader.showAlert / handlingException are created with app.reader in
    // app.v2.read.js, which the reader prefetch loads once the home screen has
    // painted -- long before a reader is opened, so this lands in time. The
    // chapter class arrives with app.v2.chapterdisplay.js, right behind it, and
    // the reader's display only exists once a chapter is opened, so both are
    // retried here until they are hooked.
    var funnelAttempts = 0;
    var funnelTimer = setInterval(function () {
        funnelAttempts++;
        var funnels = installReaderFunnels();
        var unload = installChapterUnloadGuard();
        var names = installDisplayName(currentDisplay());
        if ((funnels && unload && names) || funnelAttempts > 600) {
            clearInterval(funnelTimer);
        }
    }, 200);

    if (window.__stvDiag) {
        window.__stvDiag.log('PATCH', 'i18n overlay ready: ' + EXACT.length + ' labels, '
            + FRAGMENTS.length + ' fragments, ' + PATTERNS.length + ' patterns, language '
            + currentLanguage() + ', rewriting ' + (chineseUi() ? 'on' : 'off'));
    }
})();`;

if (js.includes('\\')) {
  fail('generated JavaScript contains a backslash; the Swift multiline string forbids it');
}

const swift = `import Foundation

/**
 GENERATED FILE — do not edit by hand.

 The Vietnamese -> Simplified Chinese overlay injected into the site at document
 start. Regenerate with \`node scripts/gen-site-i18n.js\`; CI runs the same script
 with --check so the Swift and data/site-i18n.json cannot drift apart.

 Why an overlay at all: the site's own i18n only covers \`<text>key</text>\`
 placeholders (fed by /mobile/lang/zh.json, which is complete — 188 keys, same as
 vi.json). Everything else is a hardcoded Vietnamese literal in the server HTML
 or in the site's JS, and the server is not ours to change.
 */
enum SiteI18nData {
    static let script = """
${js
  .split('\n')
  .map((line) => (line.length ? '    ' + line : line))
  .join('\n')}
    """
}
`;

if (process.argv.includes('--check')) {
  const existing = fs.existsSync(OUT) ? fs.readFileSync(OUT, 'utf8') : '';
  if (existing !== swift) {
    fail('SiteI18nData.swift is out of sync with data/site-i18n.json — run: node scripts/gen-site-i18n.js');
  }
  console.log(`✓ SiteI18nData.swift is in sync (${data.exact.length} labels, ${data.fragments.length} fragments)`);
  process.exit(0);
}

fs.writeFileSync(OUT, swift);
console.log(
  `✓ wrote SiteI18nData.swift (${data.exact.length} labels, ${data.fragments.length} fragments, ` +
    `${data.patterns.length} patterns, ${swift.length} bytes)`
);
