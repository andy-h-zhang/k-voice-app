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
make clean      # removes .build/, the generated project, and build/
```

## Release builds

`make release` runs `make test` first — a release never ships untested — then
builds the Release configuration and signs it. The final `.app` path is printed
in a banner at the end (`build/release/Build/Products/Release/KVoice.app`).

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
and the app's **File** menu points at both halves of it:

```
~/Documents/KVoice/                 # configurable in Settings → Storage
├── 2026-08-13 Standup/             # one folder per recording
│   ├── 2026-08-13 Standup.m4a
│   └── transcript.raw.json         # verbatim provider response
├── Transcripts/                    # every rendered export, created on demand
│   └── 2026-08-13 Standup.md
└── KVoice.store                    # the SwiftData database
```

Rendered exports (`.md`, `.txt`, `.docx`) share one `Transcripts/` folder rather
than sitting inside each recording's folder, so there is a single place to look
for readable transcripts. Renaming a recording renames its exports there too;
deleting one trashes them with it. A backup of the root is a backup of
everything.

## AssemblyAI API key

Transcription needs an AssemblyAI API key. **Placeholder — no key is configured yet.** When you have one:

```sh
# For the speakerlab CLI:
export ASSEMBLYAI_API_KEY="paste-your-key-here"
```

The app will store the key in the macOS Keychain via its Settings screen (the CLI also falls back to that Keychain entry when the env var is unset). Everything except live transcription — builds, tests, recording, exports, speaker matching against saved transcripts — works without a key.

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

Phases 0–7 of [docs/implementation-plan.md](docs/implementation-plan.md) are complete and merged: recording, transcription, speaker ID with auto-learn, persistence, the full app (record / library / editor / people / settings), exports, and the CLI harness. **570 offline tests in 60 suites** (`make test`), zero warnings from our own code in `make build`, `make app-build`, and `make release`.

What is left is the part that needs a person, not a test:

- **[docs/acceptance-checklist.md](docs/acceptance-checklist.md)** — the single ~30-minute walkthrough that closes Phase 8. It merges the spec's acceptance criteria with the visual checks accumulated across every phase: first-run with no key, mic permission, the recording flow, Finder parity, Settings, enrollment, the full transcribe pipeline, the editor's speaker operations, exports in Word and Google Docs, and the 60-minute and three-voice acceptance recordings.
- **Speaker-ID accuracy validation** (implementation plan Phase 1b) still needs real audio: an AssemblyAI API key, a 60-minute two-person recording, and a three-voice recording. `speakerlab eval` on a labeled corpus confirms or moves the shipped 0.62 threshold — the last item on the checklist.
