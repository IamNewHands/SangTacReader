#!/usr/bin/env node
/**
 * Guard: every `"""..."""` block in the SangTacAppPlugin Swift target is
 * JavaScript that the web view will actually run.
 *
 * Why this exists: a Swift string-escaping slip inside one of those blocks once
 * shipped a shim that was a JS syntax error, so it never executed and the whole
 * compatibility layer was silently dead on device (see
 * docs/capacitor-port.md §6.1). Nothing else in the build would
 * have caught it — Swift compiles it happily, and the binary-level check only
 * proves the marker string is present, not that it parses.
 *
 * Run: node scripts/check-ios-shim.js
 */
const fs = require('fs');
const path = require('path');

const TARGET_DIR = path.join(
  __dirname,
  '..',
  'plugins',
  'app',
  'ios',
  'Sources',
  'SangTacAppPlugin'
);

/** Markers that must survive somewhere in the injected JavaScript. */
const REQUIRED_MARKERS = [
  'window.__stvIOSCompatInstalled',
  'window.nativeclick',
  'window.TTS',
  'window.__stvDiag',
  'window.__stvTabProbeInstalled',
  'window.__stvStorageAccessorInstalled',
  'window.__stvGridLayoutInstalled',
  'window.__stvKeyboardPopupInstalled',
  'window.__stvReaderDefaultsInstalled',
  'window.__stvTtsProviderInstalled',
  'window.__stvI18nInstalled',
  'window.__stvFollowFallbackInstalled',
  'window.__stvSafeAreaInstalled',
  'window.__stvSettingsBackupInstalled',
  'window.__stvDomainFailoverInstalled',
  'window.__stvBookmarkToggleInstalled',
  'window.__stvReaderTtsInstalled',
  'window.__stvPageRepairInstalled',
  'window.__stvCommentTranslateInstalled',
  'window.__stvBootShellInstalled',
  'pageflip',
];

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

if (!fs.existsSync(TARGET_DIR)) {
  fail(`missing ${TARGET_DIR}`);
}

const swiftFiles = fs
  .readdirSync(TARGET_DIR)
  .filter((name) => name.endsWith('.swift'))
  .sort();

if (swiftFiles.length === 0) {
  fail(`${TARGET_DIR} contains no Swift sources`);
}

const blocks = [];
for (const name of swiftFiles) {
  const file = path.join(TARGET_DIR, name);
  const swift = fs.readFileSync(file, 'utf8');
  const declared = (swift.match(/=\s*"""/g) || []).length;
  const found = [...swift.matchAll(/"""([\s\S]*?)"""/g)].map((m) => m[1]);
  if (declared !== found.length) {
    fail(
      `${name}: found ${declared} multiline-string openers but paired ${found.length} blocks — ` +
        'a stray `"""` inside a string or comment has unbalanced the file'
    );
  }
  found.forEach((js, index) => blocks.push({ file: name, index, js }));
}

if (blocks.length === 0) {
  fail('no `"""..."""` JavaScript block found in the SangTacAppPlugin target');
}

let total = 0;
for (const block of blocks) {
  const label = `${block.file} block #${block.index + 1}`;

  // Swift processes escapes inside multiline string literals, so a stray `\n`
  // reaches JS as a real newline and breaks the string it sits in. These blocks
  // are written without any backslash on purpose.
  const backslashes = (block.js.match(/\\/g) || []).length;
  if (backslashes > 0) {
    fail(`${label} contains ${backslashes} literal backslash(es); write it escape-free`);
  }

  try {
    // eslint-disable-next-line no-new-func
    new Function(block.js);
  } catch (error) {
    fail(`${label} is not valid JavaScript: ${error.message}`);
  }

  total += block.js.length;
}

const combined = blocks.map((block) => block.js).join('\n');
for (const marker of REQUIRED_MARKERS) {
  if (!combined.includes(marker)) {
    fail(`injected JavaScript is missing required marker: ${marker}`);
  }
}

console.log(
  `✓ injected document-start JavaScript is valid (${blocks.length} blocks, ${total} bytes, ` +
    `${REQUIRED_MARKERS.length} markers)`
);
