# OpenCode Plus

**Coding agents on an Android phone, 64-bit ARM only.**

OpenCode Plus is a trimmed derivative of [OpenCode Mobile](https://github.com/Eslamasabry/opencode-mobile-next).
It keeps the parts this project uses — the on-device Linux, the agent
sessions, the chat, terminal, approvals and diffs — and drops everything that
was built for other platforms or for release tooling we do not run. It was
called OpenCode Mini up to 0.3.13; the display name, launcher label and
documents are now OpenCode Plus, while the application id stays
`com.azx8788.opencode.mini` so an existing install upgrades in place instead
of losing its servers and its Ubuntu.

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

## Versioning

`version:` in `pubspec.yaml` is the only version the APK carries
(`0.3.14+18` is name 0.3.14, code 18). **A plain `flutter build apk` does not
move it**, so two builds of the same tree install as the same version and the
phone has no reason to treat the second one as an upgrade. Use one of these:

```sh
dart run tool/bump_version.dart              # 0.3.14+18 -> 0.3.14+19
dart run tool/bump_version.dart --patch      # 0.3.14+18 -> 0.3.15+19
tool/build_apk.sh                            # bump, then build a release APK
```

The build number always increases, including on `--patch`, `--minor` and
`--major`: Android compares `versionCode` first, and a version that calls
itself newer while carrying a smaller code installs nothing.

CI does not commit a bump back to the branch. It sets `OC_VERSION_CODE` from
`GITHUB_RUN_NUMBER` (`base + run number`), which the Gradle build prefers over
the pubspec value, so every CI run is a higher code than the last. A local
build that needs a new code must run the bump itself — or use
`tool/build_apk.sh`.

## Differences from upstream

Full list in [UPSTREAM.md](UPSTREAM.md). In short:

- Android only: no iOS, desktop or web projects.
- One ABI: `arm64-v8a`.
- Two locales: `en`, `zh`.
- Shorebird code push removed; the app never asks a third-party update service
  for patches.
- Documentation site, widgetbook, marketing assets, device QA harness and the
  185 MB test suite are not included (they stay in upstream).
- Application id `com.azx8788.opencode.mini`, kept across the rename, so it
  installs beside OpenCode Mobile rather than over it and upgrades over
  earlier OpenCode Mini builds.

## Build

- Flutter **3.47.9**
- JDK 17, Android SDK 37, NDK as required by that Flutter release
- Rust binaries are committed under `android/app/src/main/jniLibs/arm64-v8a`,
  so no Rust toolchain is needed to build the APK.

```sh
flutter pub get
dart run tool/bump_version.dart
flutter build apk --release --target-platform android-arm64
```

A release build uses `android/key.properties` when it exists (see
`android/key.properties.example`); without it Gradle falls back to the debug
key, which still proves both the Kotlin and Dart sides compile but is not a
key to publish. CI (`.github/workflows/build.yml`) builds the signed APK from
four repository secrets and uploads it as an artifact.

## Security

Read [SECURITY.md](SECURITY.md) before reporting a problem. Reports go to this
repository's private advisory page — **not** to the upstream OpenCode or
OpenCode Mobile projects, which do not maintain this app. The app stores
server passwords in the Android Keystore and approves shell-capable actions,
so a defect here can become code execution on someone's development machine.

## License

MIT — see [LICENSE](LICENSE), which keeps the original copyright notice.
Bundled fonts, native binaries and packages are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) with full texts in `LICENSES/`.
PRoot (GPL-2.0), talloc (LGPL-3.0) and libandroid-shmem (BSD-3-Clause) ship as
native libraries; their sources are linked in the notices.

This is an independent community project. It is not built, maintained,
endorsed by, or affiliated with the official OpenCode team, nor with Anthropic.

## 中文说明

OpenCode Plus 是 OpenCode Mobile 的精简衍生版，只面向 Android 64 位
（arm64-v8a）设备：保留手机内置 Linux、Agent 会话、对话/终端/审批/diff/预览
等全部功能，去掉 iOS 与桌面工程、多语言（仅中英）、Shorebird 热更新、文档站
与测试工程。0.3.13 及以前叫 OpenCode Mini；现在应用名、桌面图标名与文档统一为
OpenCode Plus，包名仍为 `com.azx8788.opencode.mini`，因此可以直接覆盖升级，
不会丢服务器配置和内置 Ubuntu。

版本号只有 `pubspec.yaml` 里的一处。直接 `flutter build apk` **不会**自动加
版本号，构建前请运行 `dart run tool/bump_version.dart`（或直接用
`tool/build_apk.sh`）；CI 用 `GITHUB_RUN_NUMBER` 注入 `versionCode`，保证每次
产出的包都能覆盖上一次。许可证仍为 MIT，原始版权与第三方声明完整保留（见
`LICENSE`、`NOTICE`、`THIRD_PARTY_NOTICES.md` 和 `UPSTREAM.md`）。
