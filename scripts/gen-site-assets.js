#!/usr/bin/env node
/**
 * Generate the bundled site-asset mirror.
 *
 * Why this exists: the site's own shell HTML randomises the URL of every
 * boot-critical file (`/asset/app.v2.js?` + Math.random()), and 17 more static
 * files load from the parser before the site's JS can run. WebKit can never
 * cache the randomised ones, and the parser-created ones are unreachable from
 * JavaScript, so the only way to take them off the network is to ship a copy
 * inside the app and serve it from the document-start shim.
 *
 * This script downloads that copy into the plugin's SPM resource directory and
 * writes a manifest of what it fetched. CI runs `--check`, which re-hashes the
 * files on disk and fails if they and the manifest disagree, so the two cannot
 * drift apart silently.
 *
 * The snapshot is only the *baseline*: `assetMirror` revalidates against the
 * live site with `If-Modified-Since` and stores anything that changed in the
 * app container, so a stale snapshot costs one launch at most.
 *
 * Run: node scripts/gen-site-assets.js          (download + write)
 *      node scripts/gen-site-assets.js --check   (verify only, no network)
 */
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const OUT_DIR = path.join(
  __dirname,
  '..',
  'plugins',
  'app',
  'ios',
  'Sources',
  'SangTacAppPlugin',
  'site-assets'
);
const MANIFEST = path.join(OUT_DIR, 'manifest.json');

const HOST = process.env.STV_ASSET_HOST || 'https://sangtacviet.com';
const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 ' +
  '(KHTML, like Gecko) Mobile/15E148';

/**
 * The mirror set, in load order. `path` is what the page asks for; `name` is the
 * file we store it as. Only files the shim can actually reach are listed: the
 * parser-created `<script src>` tags in the shell's head need the document to be
 * taken over, which this round does not do.
 */
const ASSETS = [
  { name: 'app.v2.js', path: '/asset/app.v2.js' },
  { name: 'app.v2.css', path: '/asset/app.v2.css' },
  { name: 'app.v2.bookdisplay.js', path: '/asset/app.v2.bookdisplay.js' },
  { name: 'app.v2.config.js', path: '/asset/app.v2.config.js' },
  { name: 'app.v2.read.js', path: '/asset/app.v2.read.js' },
  { name: 'app.v2.chapterdisplay.js', path: '/asset/app.v2.chapterdisplay.js' },
  { name: 'stv.tts.js', path: '/stv.tts.js' },
  { name: 'hanviet.js', path: '/hanviet.js' },
];

function fail(message) {
  console.error(`::error::${message}`);
  process.exit(1);
}

function sha256(text) {
  return crypto.createHash('sha256').update(normalise(text), 'utf8').digest('hex');
}

/**
 * The site serves these files with CRLF line endings, and Git may hand them back
 * with LF depending on the machine's `core.autocrlf`. Hashing the raw bytes would
 * therefore make `--check` fail on a runner that checks out differently from the
 * machine that generated the manifest -- a false alarm about a file that is
 * functionally identical. Normalise before hashing and sizing; `.gitattributes`
 * pins the mirror to `-text` as well, so the two agree either way.
 */
function normalise(text) {
  return text.split('\r\n').join('\n');
}

function byteLength(text) {
  return Buffer.byteLength(normalise(text), 'utf8');
}

function readManifest() {
  if (!fs.existsSync(MANIFEST)) {
    fail(`missing ${MANIFEST}; run node scripts/gen-site-assets.js`);
  }
  try {
    return JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
  } catch (error) {
    fail(`${MANIFEST} is not valid JSON: ${error.message}`);
  }
}

/**
 * A mirrored file that is not valid JavaScript is worse than no mirror at all:
 * the shim would hand the page a broken module and the app would never boot.
 * A Cloudflare interstitial or a 404 page saved under a .js name is exactly the
 * failure this catches, and it catches it at build time instead of on device.
 */
function validate(asset, text) {
  // Only the *start* counts: the site's own JS builds srcdoc strings that
  // contain `<html`, so a substring test would reject the real file.
  const head = text.slice(0, 200).trimStart().toLowerCase();
  if (head.startsWith('<!doctype') || head.startsWith('<html')) {
    return 'looks like an HTML document, not a script';
  }
  if (asset.name.endsWith('.js')) {
    try {
      // eslint-disable-next-line no-new-func
      new Function(text);
    } catch (error) {
      return `is not valid JavaScript: ${error.message}`;
    }
  } else if (asset.name.endsWith('.css') && text.indexOf('{') < 0) {
    return 'has no CSS rule block';
  }
  return '';
}

async function download(asset) {
  const response = await fetch(HOST + asset.path, {
    headers: { 'user-agent': UA, accept: '*/*' },
    redirect: 'follow',
  });
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }
  const text = await response.text();
  const problem = validate(asset, text);
  if (problem) {
    throw new Error(problem);
  }
  return { text, stamp: response.headers.get('last-modified') || '' };
}

async function generate() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const files = [];
  for (const asset of ASSETS) {
    let result;
    try {
      result = await download(asset);
    } catch (error) {
      fail(`${asset.path}: ${error.message}`);
    }
    fs.writeFileSync(path.join(OUT_DIR, asset.name), result.text, 'utf8');
    files.push({
      name: asset.name,
      path: asset.path,
      bytes: byteLength(result.text),
      sha256: sha256(result.text),
      lastModified: result.stamp,
    });
    console.log(
      `  ${asset.name}  ${result.text.length} chars  ${result.stamp || '(no last-modified)'}`
    );
  }
  const manifest = { host: HOST, generated: new Date().toISOString(), files };
  fs.writeFileSync(MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
  const total = files.reduce((sum, file) => sum + file.bytes, 0);
  console.log(
    `✓ site-assets: ${files.length} files, ${total} bytes, manifest written`
  );
}

function check() {
  const manifest = readManifest();
  if (!Array.isArray(manifest.files) || manifest.files.length === 0) {
    fail(`${MANIFEST} lists no files`);
  }
  const listed = new Set(manifest.files.map((file) => file.name));
  for (const asset of ASSETS) {
    if (!listed.has(asset.name)) {
      fail(`${MANIFEST} is missing ${asset.name}; rerun the generator`);
    }
  }
  let total = 0;
  for (const file of manifest.files) {
    const target = path.join(OUT_DIR, file.name);
    if (!fs.existsSync(target)) {
      fail(`${OUT_DIR} is missing ${file.name}; rerun the generator`);
    }
    const text = fs.readFileSync(target, 'utf8');
    if (byteLength(text) !== file.bytes) {
      fail(
        `${file.name} is ${byteLength(text)} bytes on disk but ` +
          `${file.bytes} in the manifest; rerun the generator`
      );
    }
    if (sha256(text) !== file.sha256) {
      fail(`${file.name} does not match the manifest hash; rerun the generator`);
    }
    const problem = validate({ name: file.name }, text);
    if (problem) {
      fail(`${file.name} ${problem}`);
    }
    total += file.bytes;
  }
  for (const name of fs.readdirSync(OUT_DIR)) {
    if (name === 'manifest.json' || listed.has(name)) { continue; }
    fail(`${OUT_DIR}/${name} is not in the manifest`);
  }
  console.log(
    `✓ site-assets in sync (${manifest.files.length} files, ${total} bytes, ` +
      `host ${manifest.host})`
  );
}

if (process.argv.includes('--check')) {
  check();
} else {
  generate().catch((error) => fail(error.message));
}
