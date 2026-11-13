# Upstream and modifications

OpenCode Plus is a derivative work of **OpenCode Mobile**, distributed under
the MIT License.

| | |
| --- | --- |
| Upstream repository | https://github.com/Eslamasabry/opencode-mobile-next |
| Upstream commit | `16170653d961e4c9232d285638bbef3b09b3a1e0` (master, 2026-10-31) |
| Upstream version at that commit | `2.1.0+57` |
| License | MIT, Copyright (c) 2026 Eslam Sabry (`LICENSE`) |
| This repository | https://github.com/Azx8788/opencode-mobile-mini |

The upstream license requires the copyright notice and permission notice to be
included in all copies or substantial portions of the software. `LICENSE` is
kept verbatim, `NOTICE` keeps the upstream text and adds the derivative
statement, and `THIRD_PARTY_NOTICES.md` plus `LICENSES/` are carried over with
the additions listed below.

## What this tree contains

Imported from upstream at the commit above:

- `lib/` — the Flutter application (Android paths only; desktop-only widgets
  remain where they are shared, but no desktop runner is built)
- `android/` — the Android project, including the committed arm64 native
  libraries (`jniLibs/arm64-v8a`)
- `assets/` — fonts, marks, branding, AI Team manifests, localized privacy text
- `engine/phone/` — Rust source of the phone engine (the build uses the
  committed `.so` files)
- `third_party/xterm/` — path dependency of `pubspec.yaml`
- `tool/builtin_linux/fetch_proot.sh`, `tool/quota/*.mjs`,
  `tool/qa/verify_phone_engine_apk.py`, `LICENSES/`

## Changes made for Mini

1. **Android only.** iOS, Linux and Windows projects, CI workflows for them,
   the documentation site, marketing assets, widgetbook and fastlane metadata
   are not included.
2. **arm64-v8a only.** `x86_64` native libraries removed; Gradle pins
   `abiFilters += listOf("arm64-v8a")`; the release build targets
   `--target-platform android-arm64`.
3. **Two locales.** `ar`, `es`, `ja`, `pt`, `ru` ARB files and their generated
   Dart files removed; `AppLocalizations.supportedLocales` and lookups reduced
   to `en` and `zh`.
4. **No code push.** `shorebird_code_push` dependency, `shorebird.yaml` and the
   updater implementation were removed. `ShorebirdAppUpdateService` is now a
   no-op that reports updates unavailable, so no third party can deliver code
   to this build. Release checks point at this repository, not upstream.
5. **Branding.** Application id and namespace `com.azx8788.opencode.mini`,
   label `OpenCode Plus`, title strings updated in `app_en.arb` / `app_zh.arb`
   and in code paths that print the product name.
6. **Trimmed test and QA surface.** `test/`, `androidTest/`, `androidTest`
   sources, the QA/capture/demo tooling and their Gradle hooks were removed.
   The APK hash verification against `aiteam-engine-manifest.json` is kept.
7. **Version.** `pubspec.yaml` starts this line at `0.1.0+1`.
8. **Third-party notices.** Added the bundled runtime binaries that upstream
   did not list: PRoot (GPL-2.0), talloc (LGPL-3.0) and libandroid-shmem
   (BSD-3-Clause), with license texts and source links.

No source file's copyright header was removed. Files that were modified keep
their original headers; the MIT notice covers the whole tree.

## Pulling updates from upstream

The histories are unrelated (this repository starts from a fresh commit). To
bring a newer upstream revision in:

```sh
git remote add upstream https://github.com/Eslamasabry/opencode-mobile-next.git
git fetch upstream master
git diff --stat HEAD upstream/master -- lib android assets engine
```

Apply the same reductions to anything new: drop desktop/iOS runners and
`x86_64` libraries, drop ARB files other than `en`/`zh`, and keep the
code-push removal in place. Re-check `THIRD_PARTY_NOTICES.md` whenever the
dependency set or the native binaries change.