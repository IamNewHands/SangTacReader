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
        if (root.classList && (root.classList.contains('chaptername')
            || root.classList.contains('chapternamefixed'))) { applyChapterTitle(root); }
        if (!root.querySelectorAll) { return; }
        var nodes = root.querySelectorAll(TITLE_SELECTOR);
        for (var i = 0; i < nodes.length; i++) { applyChapterTitle(nodes[i]); }
    }

    function walk(node) {
        if (!node) { return; }
        if (node.nodeType === 3) {
            var current = node.nodeValue || '';
            var next = translate(current);
            if (next !== null) {
                if (next !== current) { node.nodeValue = next; rewritten++; }
                return;
            }
            if (current.length >= 5) {
                var fragments = translateFragments(current);
                if (fragments !== current) { node.nodeValue = fragments; rewritten++; }
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

    function sweep() {
        try {
            walk(document.body || document.documentElement);
            fixChapterTitles(document.documentElement);
        } catch (e) {
            if (window.__stvDiag) { window.__stvDiag.log('ERR', 'i18n sweep failed: ' + e); }
        }
    }

    // The chapter text -- and therefore the pinned chapter name -- lives in a
    // same-origin srcdoc iframe, not in this document, so the main sweep can
    // never reach it. Only the title pass runs inside frames: walking the whole
    // frame would put the fragment table on top of novel text, and that table is
    // only meant for the site's own UI strings.
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
        } catch (e) {
            if (window.__stvDiag) { window.__stvDiag.log('ERR', 'i18n frame sweep failed: ' + e); }
        }
    }

    function frameRecords(records) {
        for (var i = 0; i < records.length; i++) {
            var record = records[i];
            if (record.target && record.target.nodeType === 1) {
                fixChapterTitles(record.target);
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
    }

    function attachFrames() {
        var list = document.querySelectorAll('iframe');
        for (var i = 0; i < list.length; i++) { attachFrame(list[i]); }
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

    window.__stvI18n = {
        translate: translate,
        sweep: sweep,
        sweepFrames: attachFrames,
        fixChapterTitle: fixChapterTitle,
        chineseChapterName: chineseChapterName,
        chapterNames: chapterNames,
        size: EXACT.length,
        rewritten: function () { return rewritten; }
    };

    if (window.MutationObserver) {
        var observer = new MutationObserver(function (records) {
            for (var i = 0; i < records.length; i++) {
                var record = records[i];
                if (record.type === 'characterData') {
                    walk(record.target);
                } else {
                    var added = record.addedNodes || [];
                    for (var j = 0; j < added.length; j++) {
                        var node = added[j];
                        walk(node);
                        if (node.nodeType === 1 && node.tagName === 'IFRAME') { attachFrame(node); }
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

    if (document.body) {
        sweep();
    } else {
        document.addEventListener('DOMContentLoaded', function () { sweep(); });
    }
    // The reader builds its iframe lazily and rebuilds it on every display-type
    // change, so re-scan a handful of times instead of trusting one pass.
    var FRAME_DELAYS = [0, 300, 1000, 2000, 4000, 8000];
    for (var f = 0; f < FRAME_DELAYS.length; f++) {
        setTimeout(function () { sweep(); attachFrames(); attachContent(); }, FRAME_DELAYS[f]);
    }

    var contentAttempts = 0;
    var contentTimer = setInterval(function () {
        contentAttempts++;
        if (attachContent() || contentAttempts > 600) { clearInterval(contentTimer); }
    }, 200);

    if (window.__stvDiag) {
        window.__stvDiag.log('PATCH', 'i18n overlay ready: ' + EXACT.length + ' labels, '
            + FRAGMENTS.length + ' fragments, ' + PATTERNS.length + ' patterns, chapter titles on');
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
