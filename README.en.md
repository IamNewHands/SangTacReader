[中文](README.md) | **English**

# SangTacReader — an unofficial iOS client for sangtacviet

It wraps the sangtacviet website in a native iOS shell: a Capacitor 8 app that loads
`sangtacviet.com/app.v2.php` remotely and supplies the native capabilities the site's
front end expects, so the site runs in **app mode** — the same reason the official Android
build gets the full reading experience.

Only an Android APK is officially published; this project is an independent wrapper, for
personal study use only.

## Features

- Book list / search / latest updates / rankings, novel details, follow / bookmark / like
- Chapter list and reading (page-flip by default, switchable to scrolling)
- Native TTS that starts from the line currently visible on screen
- Offline downloads: resumable transfer, already-downloaded chapters skipped automatically, pause / resume / delete
- Export to TXT / EPUB (with cover and title) through the system share sheet
- Comment and community-post translation, on-device offline by default, or bring your own API key
- Chinese UI localization (Vietnamese → Simplified Chinese); follows the iOS system language on first launch and can be changed later in Settings
- Settings, download history and the log toggle survive reinstalls
- Reader safe-area handling (Dynamic Island / Home Indicator), long-press menu, keyboard popup positioning

## Install

Pushing to `main` makes GitHub Actions build an **unsigned** IPA and refresh the same
rolling release:

```
https://github.com/IamNewHands/SangTacReader/releases/latest/download/SangTacReader-unsigned.ipa
```

Download it and install with SideStore / LiveContainer / SideInstaller, signed locally with
your own Apple ID. The repository contains no certificates or provisioning profiles.

## How it works

The site front end decides between **app mode** (native network stack) and **web mode**
(page XHR, which tends to hit Cloudflare) based on whether `window.Capacitor` exists. This
shell provides the native plugins the site depends on, and injects a set of site patches at
document start: local mirroring and cache stabilization of site assets, mirror failover,
settings backup, downloads and export, comment translation, body-text speech, Chinese UI
localization, and more.

What each patch does, its evidence chain, and the root cause of every on-device problem per
round are recorded in [`docs/capacitor-port.md`](docs/capacitor-port.md).

## Layout

```
SangTacReader/
├── capacitor.config.json        # server.url loads the site remotely
├── package.json                 # Capacitor 8 deps + three local plugins
├── plugins/
│   ├── http/                    # native URLSession Http (with WKWebView cookie bridging)
│   ├── app/                     # App plugin + site-patch injection + native TTS + zh dictionary + comment translation
│   └── webnativeview/           # iOS placeholder for the Android reflection bridge (comics, not implemented yet)
├── data/site-i18n.json          # site-string zh dictionary (single source of truth, generates SiteI18nData.swift)
├── scripts/                     # four local / CI guards
├── docs/capacitor-port.md       # ★ porting archive: evidence chain, decisions, per-round root causes
└── .github/workflows/build-ipa.yml
```

`ios/` is **not committed**: it must be generated on macOS with `npx cap add ios` (on
Windows the backslash paths end up in `CapApp-SPM/Package.swift`, which macOS SwiftPM
cannot parse).

## Local verification

This machine (Windows) cannot compile Swift, so Swift changes can only wait for CI; the
injected JavaScript can be verified locally in full, and CI runs the same four guards on
every build:

```bash
node scripts/check-ios-shim.js          # injected blocks parse, no escaping traps, required markers present
node scripts/test-site-patch.js         # verifies every patch's behaviour in a stub DOM
node scripts/gen-site-i18n.js --check   # generated zh block is in sync with the JSON
node scripts/gen-site-assets.js --check # bundled site-asset mirror is in sync with the manifest
```

## Diagnostics

Sideloaded builds have no console, so there is a built-in in-page diagnostics panel:
**Settings → Diagnostics → Log**. It is off by default — no floating overlay on the page and
no log buffering; once enabled the badge is always visible, the panel follows the toggle, and
the log can be copied with one tap.

## License

This project uses a custom **Personal Non-Commercial Share-Alike Open Source License 1.0**
(`LICENSE`, SPDX `LicenseRef-SangTacReader-NC-SA-1.0`):

| Term | Meaning |
|---|---|
| Personal use | Use and modify for personal study, research and private use |
| No commercial use | Any form of commercial use (selling, subscriptions, ads, internal production use, paid hosting, etc.) is forbidden |
| Attribution | You must keep `LICENSE`, the copyright notice and the credit `IamNewHands` plus the repository URL in full, and state your modifications |
| Share-alike | Once you distribute it to others (IPA/APK, app stores, sideload packages, mirrors, re-wrappers), the modified version must publish its complete source under the same license |

This license covers only the code and documentation in this repository written by this
project's author. The site's own content, APIs, assets and trademarks are not covered; their
rights belong to sangtacviet.

**About the bundled site assets**: `plugins/app/ios/Sources/SangTacAppPlugin/site-assets/`
holds the site's own eight published front-end bundles (906296 bytes in total), downloaded
verbatim by `scripts/gen-site-assets.js` purely so the app does not have to re-download them
on every launch. These files are **not** the work of this project's author and are not
covered by the license above — the copyright belongs to sangtacviet. They only enter an IPA
as part of a personal-use build, and at runtime they are still checked against the site and
overwritten with the site's newer versions whenever they change. If you do not want them,
delete that directory and remove the `resources` line from `Package.swift` (the app then
falls back to loading everything over the network).

## Notes / Disclaimer

- This project is for personal study use only; the data and copyright belong to sangtacviet — do not use it commercially.
- The icon is a placeholder; replace the 1024x1024 image inside the AppIcon asset if you want your own.
