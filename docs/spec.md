# Spec: Meeting Recorder + Speaker-Aware Transcription for macOS

## Summary

A native macOS app (SwiftUI) that records audio with one click, transcribes recordings after they finish using a cloud STT API with diarization, and resolves diarized speakers to *named people* using locally stored voice profiles — so the user labels a person once and the app recognizes them in future recordings. Recordings and transcripts live in a library where items can be renamed inline (renaming updates both the audio and transcript files) and exported to Markdown, plain text, and Word. Personal tool, not App Store distribution. Architecture should keep a clean separation between UI and core logic so the core can later be reused on iOS.

## Platform and stack

- Swift 5.10+, SwiftUI, macOS 14+ (Sonoma minimum; 15 acceptable if it simplifies audio work)
- SwiftData for persistence; AVFoundation (`AVAudioEngine`) for capture; Keychain for the API key
- Xcode workspace with a `Core` Swift package (recording, transcription, speaker ID, export — no AppKit/UIKit dependencies) plus a macOS app target, so an iOS target can be added later without a rewrite
- Distribution: signed local build for personal use; no sandboxing constraints beyond mic permission (`NSMicrophoneUsageDescription`)

## Core pipeline

### 1. Record

- Mic capture only in v1. Record to AAC `.m4a` at 48 kHz
- Elapsed-time display and input level meter
- Pause/resume; confirm dialog guards against quitting mid-recording
- Recordings up to ~2 hours handled gracefully; 30–90 minute meetings are the primary case

### 2. Transcribe

- On completion (or on demand for any library item), upload the file to AssemblyAI's async transcription API with `speaker_labels: true` and word-level timestamps
- Use the current top-tier model (the user has standardized on Universal-3 Pro; **verify the current model identifier and request options against AssemblyAI's docs at build time**)
- Pass a configurable keyterms/vocabulary list from settings to boost domain terms
- Poll for completion with progress states surfaced in the UI: Uploading → Queued → Transcribing → Matching speakers → Done / Failed (retryable)
- Store the returned utterances (speaker letter, text, start/end ms) and words; retain the raw API response for re-processing

### 3. Identify speakers (differentiating feature)

AssemblyAI returns generic labels (Speaker A, B, C). Locally:

1. For each diarized speaker, select 3–5 of their longest clean utterances
2. Extract those audio spans and convert to 16 kHz mono WAV
3. Compute speaker embeddings with an on-device model and average them into a cluster embedding
4. Cosine-match against the enrolled voice-profile library
5. Above a similarity threshold (tunable, default ≈0.60–0.65), auto-assign the person's name; below it, label "Unknown Speaker N" and prompt the user to name them

Recommended implementation path: FluidAudio's Swift/CoreML speaker-embedding models, or an ECAPA-TDNN ONNX model via onnxruntime — implementer's choice, but it must run fully offline.

**Build and validate this pipeline first with a CLI harness before any UI exists.**

### 4. Auto-learn

When the user assigns or corrects a speaker name, fold that recording's cluster embedding into the person's profile as a running average (cap stored embeddings per profile, e.g. 20, drop oldest). Recognition improves with use — this satisfies the "label once, it remembers" requirement.

## Voice profiles

A People section where profiles are created three ways, all feeding the same embedding pipeline:

1. **Guided in-app enrollment** — the person reads ~30 seconds of on-screen text, captured and embedded
2. **Uploaded clips** — existing audio of that person speaking
3. **Auto-learning** — from labeled recordings, per above

Each profile stores name, embeddings, and optionally the source clips. Profiles are local-only data. Per-profile actions: rename, re-enroll, delete, "reset learned voice."

## Library and editor

- Library lists recordings with title, date, duration, transcription status, and detected participants
- Inline rename edits the title and renames the underlying audio file and export baseline name to match (sanitize illegal filename characters)
- Files live in a user-visible folder (default `~/Documents/<AppName>/`, configurable), one subfolder per recording containing the `.m4a` and exports — not an opaque bundle, so files are grabbable in Finder

Transcript editor:

- Utterances grouped into speaker turns with timestamps
- Synced playback: click a segment to jump audio; highlight the current segment during playback
- Edit transcript text inline
- Reassign one segment's speaker; reassign *all* segments of a diarized speaker at once; merge two speakers that diarization split
- Speaker reassignment triggers the auto-learn update
- Edits persist to the database, not the raw API response

## Export

Per recording:

- **Markdown** — `## Speaker — [hh:mm:ss]` turn headers with paragraphs
- **Plain text** — same structure, no formatting
- **Word `.docx`** — speaker names bold, timestamps subdued; generate the OOXML directly (a docx is a zip of XML; no heavyweight dependency needed). Must open cleanly in Word and import into Google Docs
- "Reveal in Finder" and drag-out of both audio and transcript
- Filenames follow the recording title

## Settings

- AssemblyAI API key (Keychain-stored, pasted by the user)
- Storage folder
- Similarity threshold
- Keyterms list
- Default export format
- Input device selection

## Out of scope for v1 (planned later)

- System-audio capture of Zoom/Meet calls (v2: Core Audio process taps / ScreenCaptureKit — design the recorder protocol so a second audio source can be added)
- iOS app (motivates the Core package split)
- Live streaming transcription
- Summaries / AI notes
- Sync or multi-device features

## Acceptance criteria

- A 60-minute two-person meeting records without drops and transcribes end-to-end in one action
- Both speakers are auto-named correctly when profiles exist
- A third unknown voice is flagged and, once named, is auto-recognized in the next recording
- Renaming a recording renames its files on disk
- All three export formats produce correct speaker-attributed documents
- The UI never blocks during upload/polling; a failed transcription is retryable without re-recording

## Implementation notes for the agent

- Verify AssemblyAI model names and request options against current documentation — do not hardcode from this spec
- The speaker-ID layer (Core pipeline §3) is the only novel engineering; validate it standalone before building UI
- Keep `Core` free of platform UI frameworks to preserve the iOS path
