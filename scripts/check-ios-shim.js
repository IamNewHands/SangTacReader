#!/usr/bin/env node
/**
 * Guard: the WKUserScript source embedded in SangTacAppPlugin.swift must be
 * valid JavaScript.
 *
 * Why this exists: a Swift string-escaping slip inside that `"""..."""` block
 * once shipped a shim that was a JS syntax error, so it never executed and the
 * whole compatibility layer was silently dead on device (see
 * debug-ios-catalog-load-fail.md, "v5 根因"). Nothing else in the build would
 * have caught it — Swift compiles it happily, and the binary-level check only
 * proves the marker string is present, not that it parses.
 *
 * Run: node scripts/check-ios-shim.js
 */
const fs = require('fs');
const path = require('path');

const SWIFT = path.join(
  __dirname,
  '..',
  'plugins',
  'app',
  'ios',
  'Sources',
  'SangTacAppPlugin',
  'SangTacAppPlugin.swift'
);

const REQUIRED_MARKERS = [
  'window.__stvIOSCompatInstalled',
  'window.nativeclick',
  'window.TTS',
  'window.__stvDiag',
];

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

if (!fs.existsSync(SWIFT)) {
  fail(`missing ${SWIFT}`);
}

const swift = fs.readFileSync(SWIFT, 'utf8');
const match = swift.match(/let source = """([\s\S]*?)"""/);
if (!match) {
  fail('SangTacAppPlugin.swift: no `let source = """..."""` WKUserScript block found');
}

const js = match[1];

// Swift processes escapes inside multiline string literals, so a stray `\n`
// reaches JS as a real newline and breaks the string it sits in. The shim is
// written without any backslash on purpose.
const backslashes = (js.match(/\\/g) || []).length;
if (backslashes > 0) {
  fail(`injected shim contains ${backslashes} literal backslash(es); write it escape-free (see SangTacAppPlugin.swift)`);
}

try {
  // eslint-disable-next-line no-new-func
  new Function(js);
} catch (error) {
  fail(`injected shim is not valid JavaScript: ${error.message}`);
}

for (const marker of REQUIRED_MARKERS) {
  if (!js.includes(marker)) {
    fail(`injected shim is missing required marker: ${marker}`);
  }
}

console.log(`✓ injected document-start shim is valid JavaScript (${js.length} bytes, ${REQUIRED_MARKERS.length} markers)`);
