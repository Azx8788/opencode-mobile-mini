# Security policy

OpenCode Plus is an independent community project, a trimmed derivative of
[OpenCode Mobile](https://github.com/Eslamasabry/opencode-mobile-next). It is
not built, maintained, endorsed by, or affiliated with the OpenCode team or
with Anthropic.

## Why this matters more than for a typical app

Please read this before deciding where to report something.

This app **stores credentials** and it **authorizes shell-capable actions**.
An agent server runs commands on its host as the user who started it, and this
app is the front end for approving those commands: it grants tool permissions,
answers agent questions, and resolves requests from the notification shade
without the app being opened.

So a defect here is not only an app defect. Anything that lets an attacker
read a stored secret, approve a permission the user did not approve, point the
app at a server the user did not choose, or get a request approved out of band,
is a path to code execution on somebody's development machine.

Report it privately. Do not open a public issue, a discussion, or a pull
request that demonstrates it.

## What this app holds

| Secret | Where it lives | Who can read it |
|---|---|---|
| Server password (`OPENCODE_SERVER_PASSWORD`) for each server profile | Android Keystore-backed secure storage | the app process |
| Provider API keys written as secret files | `~/.secrets/` inside the profile's Linux, mode `0600` | the profile's own user |
| Gateway key for Claude Code | the profile's `~/.claude/settings.json`, mode `0600` | the profile's own user |
| Factsbook vault passphrase | Android Keystore-backed secure storage | the app process |

The app does not upload any of these. There is no analytics SDK, no crash
reporting service and no code-push channel in these builds: diagnostics are
written to the device and leave it only when a person copies or shares them.
Network traffic is what a feature needs — the Linux download, package and
agent installs, model requests to the endpoint you configured, and update
checks against this repository's releases.

## Supported versions

**Only the current preview is supported.** This project ships a rolling
preview line; there are no maintained release branches and no backports.

| Version | Supported |
|---|---|
| Current preview (see [releases](https://github.com/Azx8788/opencode-plus/releases)) | Yes |
| Any earlier preview | No |
| Everything named OpenCode Mini (`0.3.13` and earlier) | No |

A fix ships in the next preview APK. There is no backport branch and no
patching channel, so the first step of any fix is to update.

## Reporting a vulnerability

Use **GitHub private vulnerability reporting** on this repository:

<https://github.com/Azx8788/opencode-plus/security/advisories/new>

That opens a private advisory visible only to you and the maintainer. It is
the only channel that should be used for a suspected vulnerability. Reports
sent to the upstream OpenCode Mobile project do not reach this app's
maintainer, and are not a way to report a defect in this app.

If private advisories are unavailable to you for any reason, open a public
issue that says only *"requesting a private security contact"* — with no
detail, no reproduction, and no logs — and wait to be contacted.

Please include, as far as you can:

- what an attacker gains, in one sentence;
- the app version (**Settings → About**) and Android version;
- whether the server was reached over adb reverse, an SSH forward, TLS, or
  on-device Termux, and whether it was OpenCode v1 or v2;
- a reproduction, and a proof-of-concept if you have one;
- anything you already know about scope — which stored data, which server
  actions.

**Do not include real credentials, real server addresses, session
transcripts, or unredacted diagnostics.** If a reproduction needs a password,
say so and use a throwaway one.

## What to expect

This is a single-maintainer project, not a company with an on-call rota. The
honest expectation:

- acknowledgement within **7 days**;
- an assessment, with a severity and a rough plan, within **30 days**;
- a fix in the next preview once one is agreed, prioritized over feature work.

If you have heard nothing after 7 days, comment on your own advisory — it
means the notification was missed, not ignored.

Coordinated disclosure: please give a fix a reasonable chance to ship before
publishing. Reporters are credited in the advisory and the release notes
unless they ask not to be. There is no bug bounty.

## Out of scope here

These are real security concerns, but they belong somewhere else:

- **OpenCode Mobile, and the OpenCode server itself** — this repository
  maintains the Android client and the Linux it installs, not the server or
  the upstream app. Report those upstream.
- **Your model provider or gateway** — report to that provider.
- **proot, Ubuntu, or a package installed inside the chroot** — report
  upstream.
- **"The server can run shell commands"** — that is what an agent server is.
  Documented, not a vulnerability. What *is* in scope is the app doing it
  without the user's authorization.
- **Sideload signing warnings** — these builds are signed with the project's
  own certificate, not a Play Store key, and Android says so. The installed
  fingerprint is shown in Settings → About.

## Things already known and documented

Reporting these again is welcome but will be closed as known:

- The app refuses plain HTTP to anything but the phone's own loopback;
  reaching a remote server needs adb reverse, an SSH forward, or TLS.
- The preview APKs are `profile` builds: they are debuggable by design so a
  person can attach to a running app, and they are not claimed to be hardened
  release artifacts.
- The built-in Linux is a proot environment without root. Anything running
  inside it has the same reach as the app's own data directory; it is not a
  sandbox boundary against the app, and is not presented as one.
