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
        var win = null;
        try { win = frame.contentWindow; } catch (e) { win = null; }
        if (win && !win.__stvI18nFrame) {
            win.__stvI18nFrame = true;
            try {
                win.addEventListener('load', function () { sweepFrame(frame); });
            } catch (e) {}
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

    window.__stvI18n = {
        translate: translate,
        sweep: sweep,
        sweepFrames: attachFrames,
        fixChapterTitle: fixChapterTitle,
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
        setTimeout(function () { sweep(); attachFrames(); }, FRAME_DELAYS[f]);
    }

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
