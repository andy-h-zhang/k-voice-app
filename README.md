# KVoice

A native macOS meeting recorder with speaker-aware transcription: record with one click, transcribe via AssemblyAI with diarization, and resolve "Speaker A/B/C" to *named people* using on-device voice profiles that improve with use. See [docs/spec.md](docs/spec.md) and [docs/implementation-plan.md](docs/implementation-plan.md).

## Prerequisites

- macOS 14+ (Apple Silicon). `make build` / `make test` work with Command Line Tools alone (the Makefile adapts); `make app-build` and `make release` need full Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the app target: `brew install xcodegen`

## Build and test

```sh
make build      # builds the Core package + speakerlab CLI
make test       # runs the full offline test suite (no network, no API key)
make generate   # generates KVoice.xcodeproj from project.yml
make app-build  # builds the macOS app (Debug)
make release    # runs the tests, then builds + signs a Release .app
make install    # builds a Release .app and installs it to /Applications
make clean      # removes .build/, the generated project, and build/
```

Before `make release` or `make install`, bump the build number by hand — see
[Versioning](#versioning--bump-this-by-hand-before-every-release) below.

## Iterating on the UI

**Do not use `make install` as a development loop.** It chains
`release` → `test` → a full Release build → codesign → a swap into
`/Applications`, so a one-line change to a button costs the entire test suite
and an optimized build. It also re-triggers the Keychain dialog every time, for
the reason in [Why the Keychain sometimes asks for your
password](#why-the-keychain-sometimes-asks-for-your-password) below: an ad-hoc signature's
identity is the binary's `cdhash`, which changes on every rebuild.

Two faster loops, in order of speed:

**SwiftUI previews** — the fastest, and enough for most visual work. Open the
generated project and use the canvas; edits re-render in under a second, with no
launch and no transcription.

```sh
make generate && open KVoice.xcodeproj
```

`App/Support/PreviewSupport.swift` supplies `PreviewFixture`, a whole
`AppServices` over a **temporary** library folder and an in-memory API key,
seeded with a fake transcript — two named speakers, one unnamed, six turns. The
services and models are the real ones, so speaker assignment, editing and copy
all genuinely work in the canvas. `TranscriptEditorView.swift` ends
with four previews covering the states that are otherwise expensive to reach:
`Transcript`, `No Transcript Yet`, `Transcription Failed`, and `No API Key`.

The fixture writes no audio file, so previews of the editor show the transport
bar's "audio file is missing" notice. Playback is the one thing the canvas
cannot exercise.

To preview another screen, take the same three lines:

```swift
#Preview("Whatever") {
    let fixture = PreviewFixture.make(.populated)
    SomeView().environment(fixture.services)
}
```

**⌘R from Xcode** — for anything previews can't cover (playback, recording, a
real transcription). An incremental Debug build after a one-file edit is a
couple of seconds, against minutes for `make install`.

Both are Debug-only: the fixture and the previews are behind `#if DEBUG`, which
`project.yml` sets explicitly under `settings ▸ configs ▸ Debug`. Nothing in
this section ships in a Release build.

## Versioning — bump this by hand before every release

Nothing bumps the version for you. Do it yourself, in `project.yml`, **before**
running `make release` or `make install`:

```yaml
# project.yml — under targets ▸ KVoice ▸ settings ▸ base
targets:
  KVoice:
    settings:
      base:
        SWIFT_VERSION: "5.0"
        MARKETING_VERSION: "0.1.0"        # ← the version users see
        CURRENT_PROJECT_VERSION: "1"      # ← the build number
```

Both keys are target build settings, so they belong in that nested `base:` block
— not in a top-level `settings:` of their own.

| Edit | Becomes | Rule |
|---|---|---|
| `MARKETING_VERSION` | `CFBundleShortVersionString` | The human version (`0.2.0`). Bump when you ship something worth naming. |
| `CURRENT_PROJECT_VERSION` | `CFBundleVersion` | A plain incrementing integer. **Bump on every build you hand to anyone**, even a rebuild of the same `MARKETING_VERSION`. |

There is no `Info.plist` to edit — `GENERATE_INFOPLIST_FILE: YES` means Xcode
synthesizes one from those two settings — and `KVoice.xcodeproj` is generated
and gitignored, so `project.yml` is the only file that changes. `make release`
and `make install` both run `make generate` first, so the edit is picked up with
no extra step.

**Why the build number matters more than it looks.** `CFBundleVersion` is what
macOS compares to decide whether one copy of an app is newer than another —
Gatekeeper's caches, Launch Services, and any future Sparkle or notarization
flow all key off it. Shipping two different builds that both say `1` means the
system cannot tell them apart, which shows up later as an old copy that refuses
to be replaced.

Verify the bump took: the banner at the end of `make release` reads the values
back out of the *built* `Info.plist`, not out of `project.yml`, so it is a real
check rather than an echo of what you typed:

```
 KVoice 0.2.0 (2) — Release, signed: ad-hoc
```

A running copy shows nothing — there is no About window yet — so Finder's Get
Info on `/Applications/KVoice.app` is how you check an installed build.

### The one version that is *not* part of this

`KVoiceCore.version` in [Core/Sources/KVoiceCore/KVoiceCore.swift](Core/Sources/KVoiceCore/KVoiceCore.swift)
is the Core package's own API version, surfaced only by `speakerlab --version`.
It is deliberately independent of the app bundle: bump it when the Core API
changes meaningfully, not on every app release.

## Release builds

`make release` runs `make test` first — a release never ships untested — then
builds the Release configuration and signs it. The final `.app` path is printed
in a banner at the end (`build/release/Build/Products/Release/KVoice.app`).

`make install` does the same, then swaps the result into `/Applications/KVoice.app` (quitting a running KVoice first) — the easiest way to get a real, launchable copy out of `build/` and into the normal place; use `sudo make install` if `/Applications` isn't writable.

Signing is decided by what is in your keychain, detected with
`security find-identity -v -p codesigning`:

| Keychain has… | What happens |
|---|---|
| a **Developer ID Application** identity | signed with it, **hardened runtime** on, `Scripts/KVoice.entitlements` applied, secure timestamp requested |
| nothing (current state on this machine) | **ad-hoc** signed, no hardened runtime — fine for personal use, cannot be notarized |

Nothing needs to change to switch: install a Developer ID Application
certificate (Xcode → Settings → Accounts → Manage Certificates, or import a
`.p12`) and the next `make release` picks it up automatically. To force a
particular one when several exist, edit the `grep 'Developer ID Application'`
line in `Scripts/release.sh` to match the certificate you want.

Two things worth knowing:

- **The mic entitlement is not optional under the hardened runtime.**
  `Scripts/KVoice.entitlements` grants `com.apple.security.device.audio-input`.
  Without it a Developer ID build is refused microphone access no matter what
  the user allows in System Settings — and it fails quietly. Ad-hoc builds skip
  the hardened runtime and so don't need it.
- **An ad-hoc build is Gatekeeper-rejected on first launch.** That is expected
  and the script says so. Right-click → **Open** once to run it locally.
  Notarization requires a Developer ID signature.

The script signs nested code inside-out and the bundle last, rather than using
`codesign --deep` (which re-signs nested code with the *outer* bundle's
entitlements). `--deep` is used only for verification.

## Where files live

The library is plain folders, not a bundle — everything is grabbable in Finder,
and the app's **File** menu points at it:

```
~/Documents/KVoice/                          # configurable in Settings → Storage
├── 2026-08-13 Weekly Sync/                  # one folder per recording
│   ├── 2026-08-13 Weekly Sync Recording.m4a
│   ├── 2026-08-13 Weekly Sync Transcript.md
│   ├── 2026-08-13 Weekly Sync Transcript.txt
│   └── transcript.raw.json                  # verbatim provider response
└── KVoice.store                             # the SwiftData database
```

A recording is a **project folder**: the audio and both rendered transcripts
under one name, so it is a single thing to drag, copy, back up or send. Folders
are named `YYYY-MM-DD [NAME]`, with the date filled in from your machine's time
zone when you stop recording; the name is whatever you type next.

Both transcripts are written the moment transcription finishes and rewritten
whenever you edit a paragraph or rename a speaker, so what is on disk always
matches what the app shows. There is no export step and no format setting —
Markdown for reading, plain text for everything that does not understand it.

Renaming a recording renames its folder and every file inside it; deleting one
trashes the lot. A backup of the root is a backup of everything.

Earlier versions kept rendered exports in a shared `Transcripts/` folder and
offered Word output. A library in that layout is migrated on first launch:
folders lose their clock time and trailing "Recording", audio gains its role
suffix, and exports come home. It never deletes — an existing `.docx` is moved
into its project folder and left alone.

## AssemblyAI API key

Transcription needs an AssemblyAI API key. **Placeholder — no key is configured yet.** When you have one:

```sh
# For the speakerlab CLI:
export ASSEMBLYAI_API_KEY="paste-your-key-here"
```

The app will store the key in the macOS Keychain via its Settings screen (the CLI also falls back to that Keychain entry when the env var is unset). Everything except live transcription — builds, tests, recording, exports, speaker matching against saved transcripts — works without a key.

### Why the Keychain sometimes asks for your password

Saving the key writes a login-keychain item whose ACL trusts exactly one application: the KVoice binary that wrote it. Reads from that binary satisfy the ACL silently, so the normal experience is *paste the key once, never see a dialog again*.

The ACL identifies the app by its code signature, and an **ad-hoc** signature — what `make release` produces when no Developer ID is in the keychain — has no stable identity: its designated requirement is the binary's `cdhash`, which changes on every rebuild. So after a `make install` of a new build, the app is a stranger to the item it wrote and the "KVoice wants to use your confidential information" dialog returns.

Two ways out, in order of effort:

- **Re-save the key in Settings after installing a new build.** The save deletes and re-adds the item, minting a fresh ACL for the new binary. One dialog on the delete, then silence again.
- **Sign with a Developer ID** (see "Release builds"). A stable identity survives rebuilds, and it is also the prerequisite for moving to the data-protection keychain, where entitlements gate access and there is no ACL and no dialog at all.

Within a single launch the key is read once and held in memory (`CachingAPIKeyStore`), so an unsatisfied ACL costs one dialog per launch rather than one per transcription.

## speakerlab (validation CLI)

The speaker-ID pipeline ships with a CLI harness used to validate matching before/alongside the app:

```sh
speakerlab transcribe meeting.m4a          # upload + poll; writes meeting.raw.json (needs API key)
speakerlab enroll "Andy" clip1.m4a ...     # create a voice profile from clips
speakerlab identify meeting.m4a meeting.raw.json   # who is Speaker A/B/C?
speakerlab identify ... --learn A=Andy     # confirm/correct a speaker and fold into the profile
speakerlab eval <labeled-dir>              # accuracy + threshold sweep over a labeled corpus
speakerlab record --out ~/Documents/KVoice # mic recording smoke-test
```

First real-model use downloads FluidAudio's CoreML models (~100 MB, cached in `~/Library/Application Support/FluidAudio/`).

## Status

Phases 0–7 of [docs/implementation-plan.md](docs/implementation-plan.md) are complete and merged: recording, transcription, speaker ID with auto-learn, persistence, the full app (record / library / editor / people / settings), per-project transcripts, and the CLI harness. **562 offline tests in 63 suites** (`make test`), zero warnings from our own code in `make build`, `make app-build`, and `make release`.

What is left is the part that needs a person, not a test:

- **[docs/acceptance-checklist.md](docs/acceptance-checklist.md)** — the single ~30-minute walkthrough that closes Phase 8. It merges the spec's acceptance criteria with the visual checks accumulated across every phase: first-run with no key, mic permission, the recording flow, Finder parity, Settings, enrollment, the full transcribe pipeline, the editor's speaker operations, the transcripts written into each project folder, and the 60-minute and three-voice acceptance recordings.
- **Speaker-ID accuracy validation** (implementation plan Phase 1b) still needs real audio: an AssemblyAI API key, a 60-minute two-person recording, and a three-voice recording. `speakerlab eval` on a labeled corpus confirms or moves the shipped 0.62 threshold — the last item on the checklist.
