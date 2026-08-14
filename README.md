# KVoice

A native macOS meeting recorder with speaker-aware transcription: record with one click, transcribe via AssemblyAI with diarization, and resolve "Speaker A/B/C" to *named people* using on-device voice profiles that improve with use. See [docs/spec.md](docs/spec.md) and [docs/implementation-plan.md](docs/implementation-plan.md).

## Prerequisites

- macOS 14+ (Apple Silicon), Xcode 26+ (or Command Line Tools — the Makefile adapts)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the app target: `brew install xcodegen`

## Build and test

```sh
make build      # builds the Core package + speakerlab CLI
make test       # runs the full offline test suite (no network, no API key)
make generate   # generates KVoice.xcodeproj from project.yml
make app-build  # builds the macOS app
```

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

## Pending validation (needs real audio)

Speaker-ID accuracy validation (docs/implementation-plan.md Phase 1b) is waiting on: an AssemblyAI API key, a 60-minute two-person recording, and a three-voice recording.
