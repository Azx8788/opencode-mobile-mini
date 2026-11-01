# OpenCode Mini

**Coding agents on an Android phone, 64-bit ARM only.**

OpenCode Mini is a trimmed derivative of [OpenCode Mobile](https://github.com/Eslamasabry/opencode-mobile-next).
It keeps the parts this project uses — the on-device Linux, the agent sessions,
the chat, terminal, approvals and diffs — and drops everything that was built
for other platforms or for release tooling we do not run.

## What it does

- **Agents run on the phone.** The app installs its own Ubuntu (proot, no root),
  then runs OpenCode 2, Claude Code, Codex, Gemini, Kilo or Cline inside it.
  The first run downloads about 210 MB of Linux and tools over Wi-Fi.
- **Or connect to a computer** running an OpenCode 2 / Codex / Paseo server.
- **Approve from anywhere**: notification, home-screen widget or the chat.
- **See the result**: built-in terminal, in-app preview, phone-sized diffs.
- **Scheduled prompts**, widgets, voice input, and multi-agent teams are kept.

## Platform

| | Status |
| --- | --- |
| Android | 8.0 (API 26) or newer, **arm64-v8a only** |
| iOS, Linux, Windows, macOS | Not built from this repository |
| Languages | English and Simplified Chinese |
| Updates | Plain APKs from this repository's Releases. No code-push channel. |

## Differences from upstream

Full list in [UPSTREAM.md](UPSTREAM.md). In short:

- Android only: no iOS, desktop or web projects.
- One ABI: `arm64-v8a`.
- Two locales: `en`, `zh`.
- Shorebird code push removed; the app never asks a third-party update service
  for patches.
- Documentation site, widgetbook, marketing assets, device QA harness and the
  185 MB test suite are not included (they stay in upstream).
- New application id `com.azx8788.opencode.mini`, so it installs beside
  OpenCode Mobile rather than over it.

## Build

Toolchain matches what upstream pins:

- Flutter **3.47.1**
- JDK 17, Android SDK 37, NDK as required by that Flutter release
- Rust binaries are committed under `android/app/src/main/jniLibs/arm64-v8a`,
  so no Rust toolchain is needed to build the APK.

```sh
flutter pub get
flutter build apk --release --target-platform android-arm64
```

A release build needs `android/key.properties` (see
`android/key.properties.example`); without it Gradle fails at
`validateSigningRelease`, which still proves both the Kotlin and Dart sides
compile. CI (`.github/workflows/build.yml`) builds the signed APK from four
repository secrets and uploads it as an artifact.

## License

MIT — see [LICENSE](LICENSE), which keeps the original copyright notice.
Bundled fonts, native binaries and packages are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) with full texts in `LICENSES/`.
PRoot (GPL-2.0), talloc (LGPL-3.0) and libandroid-shmem (BSD-3-Clause) ship as
native libraries; their sources are linked in the notices.

This is an independent community project. It is not built, maintained,
endorsed by, or affiliated with the official OpenCode team, nor with Anthropic.

## 中文说明

OpenCode Mini 是 OpenCode Mobile 的精简衍生版，只面向 Android 64 位（arm64-v8a）
设备：保留手机内置 Linux、Agent 会话、对话/终端/审批/diff/预览等全部功能，
去掉 iOS 与桌面工程、多语言（仅中英）、Shorebird 热更新、文档站与测试工程。
包名独立（com.azx8788.opencode.mini），可与原版共存。许可证仍为 MIT，
原始版权与第三方声明完整保留（见 `LICENSE`、`NOTICE`、`THIRD_PARTY_NOTICES.md`
和 `UPSTREAM.md`）。