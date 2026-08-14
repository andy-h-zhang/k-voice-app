# Implementation Plan: Meeting Recorder + Speaker-Aware Transcription

Companion to [spec.md](spec.md). Working app name below is **KVoice** (placeholder — rename is a find/replace plus folder default).

The plan follows the spec's two hard sequencing rules:

1. The speaker-ID pipeline is the only novel engineering — it is built and validated **first, as a CLI harness**, before any UI exists (Phase 1).
2. `Core` stays free of AppKit/UIKit so an iOS target can be added later.

---

## 0. Facts verified against current docs (2026-08-13)

The spec says "verify model names and request options at build time — do not hardcode from this spec." Verified as of this writing; **re-verify at the start of Phase 1** (AssemblyAI publishes a machine-readable index at `https://assemblyai.com/docs/llms.txt`).

### AssemblyAI

- The current top-tier async model is **Universal-3.5 Pro**, one notch newer than the "Universal-3 Pro" named in the spec. It is selected with an **array parameter in priority order**, not a scalar:
  ```json
  { "audio_url": "...", "speech_models": ["universal-3-5-pro"] }
  ```
  A fallback entry (e.g. `["universal-3-5-pro", "universal-2"]`) is supported. Docs: [Universal-3 Pro (Async)](https://www.assemblyai.com/docs/pre-recorded-audio/universal-3-pro).
- `speaker_labels: true` enables diarization; the response carries `utterances[]` (`speaker` letter, `text`, `start`/`end` ms, nested `words[]`) and a flat `words[]` with per-word `speaker` attribution. Word-level timestamps are always present.
- Vocabulary boosting is **keyterm prompting**: `keyterms_prompt` accepts up to ~1,000 terms. Note `prompt` and `keyterms_prompt` are **mutually exclusive** — we use `keyterms_prompt` only. Verify in Phase 1 that it is supported alongside `speech_models: ["universal-3-5-pro"]` (it shipped with the Universal-3 Pro line; see [STT prompting blog](https://www.assemblyai.com/blog/speech-to-text-prompting-assemblyai-universal-3-pro)).
- Async flow: `POST /v2/upload` (raw bytes) → `upload_url` → `POST /v2/transcript` → poll `GET /v2/transcript/{id}` until `status` is `completed` / `error`.

### FluidAudio (speaker embeddings, on-device)

Repo: [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) (SPM, macOS 14+/iOS 17+, MIT-licensed code, CoreML models run on ANE — fully offline at inference time).

- `DiarizerManager.performCompleteDiarization(_ samples: [Float])` takes 16 kHz mono Float32 and returns segments (`speakerId`, start/end) **plus a `speakerDatabase: [String: [Float]]`** — 256-dimensional L2-normalized WeSpeaker v2 embeddings keyed by speaker. This is our embedding extractor: run it over a clip, take the dominant speaker's embedding.
- `SpeakerManager` / `Speaker(id:name:currentEmbedding:)` provide enrollment-style known-speaker matching; `AudioConverter` handles resampling any file/buffer to 16 kHz mono Float32.
- Models (`pyannote_segmentation.mlmodelc` + `wespeaker_v2.mlmodelc`, ~100 MB total) download once from Hugging Face via `DiarizerModels.downloadIfNeeded()` and cache in `~/Library/Application Support/FluidAudio/Models/`; `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)` supports fully-offline staging. ([Getting started](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md))

**Fallback** if Phase 1 shows FluidAudio's public API can't cleanly produce per-clip embeddings or accuracy is poor: ECAPA-TDNN ONNX via `onnxruntime` (e.g. the sherpa-onnx speaker-embedding models). The `SpeakerEmbedder` protocol below isolates this decision.

---

## 1. Architecture

### Repository layout

```
k-voice-app/
├── docs/                      # this plan + spec
├── project.yml                # XcodeGen manifest → generates KVoice.xcodeproj
├── Core/                      # Swift package, platform-UI-free
│   ├── Package.swift          # products: KVoiceCore (library), speakerlab (executable)
│   ├── Sources/
│   │   ├── KVoiceCore/
│   │   │   ├── Recording/     # RecordingEngine, AudioSource protocol, level metering
│   │   │   ├── Transcription/ # AssemblyAIClient, TranscriptionJob state machine
│   │   │   ├── SpeakerID/     # SpeakerEmbedder protocol, FluidAudioEmbedder,
│   │   │   │                  # UtteranceSelector, ClusterMatcher, ProfileStore math
│   │   │   ├── Export/        # Markdown, plain text, docx (minimal OOXML + zip writer)
│   │   │   ├── Storage/       # RecordingStore (folder layout, rename), filename sanitizer
│   │   │   └── Models/        # SwiftData @Model classes + DTOs for the API JSON
│   │   └── speakerlab/        # CLI harness (Phase 1) — ArgumentParser executable
│   └── Tests/KVoiceCoreTests/
└── App/                       # macOS SwiftUI target (AppKit allowed here only)
    ├── KVoiceApp.swift
    ├── Recording/  Library/  Editor/  People/  Settings/
    └── Resources/ (Info.plist: NSMicrophoneUsageDescription)
```

- **XcodeGen** generates the app project so the `.xcodeproj` never needs hand-maintenance in a repo driven by CLI tooling. `Core` is consumed as a local package dependency. (If XcodeGen proves annoying, fall back to a checked-in `.xcodeproj` created once in Xcode.)
- Dependency rule, enforced by `Core` having no AppKit/UIKit import anywhere: `App → KVoiceCore → (AVFoundation, SwiftData, FluidAudio, Foundation)`. AVFoundation and SwiftData are cross-platform, so the iOS path stays open.
- Concurrency: `KVoiceCore` services are actors or `Sendable` structs; the app layer holds `@Observable` view models. All upload/poll/embedding work runs off the main thread by construction — this is how the "UI never blocks" acceptance criterion is met.

### Key protocols

```swift
public protocol AudioSource {            // v1: MicSource. v2 adds SystemAudioSource
    func start(into file: AVAudioFile) async throws
    func pause() / resume() / stop()
    var levelStream: AsyncStream<Float> { get }
}

public protocol SpeakerEmbedder {        // FluidAudioEmbedder now, ONNX fallback later
    func embedding(for samples: [Float]) async throws -> [Float]  // 16 kHz mono in
}

public protocol TranscriptionProvider {  // AssemblyAIClient; mockable for tests
    func upload(fileURL: URL) async throws -> URL
    func createTranscript(_ request: TranscriptRequest) async throws -> String
    func poll(id: String) async throws -> TranscriptResponse
}
```

### Data model (SwiftData)

```
Recording      id, title, folderName, createdAt, durationSec, status
               (recorded | uploading | queued | transcribing | matching | done | failed(msg)),
               rawResponseFile (relative path), → [Utterance], → [SpeakerSlot]
Utterance      index, diarizedSpeaker ("A"…), text (edited copy), startMs, endMs,
               → SpeakerSlot
SpeakerSlot    per-recording diarized speaker: letter, → Person?, unknownIndex?,
               clusterEmbedding [Float]           // kept so later naming can auto-learn
Person         id, name, createdAt, → [ProfileEmbedding], → [SourceClip]?
ProfileEmbedding vector [Float] (256-d), addedAt, source (enrollment | upload | autolearn)
Settings       stored in UserDefaults (folder path, threshold, keyterms, default export,
               input device UID) — not SwiftData. API key in Keychain only.
```

Deliberate choices:

- **Words are not SwiftData rows.** A 60-minute meeting is ~9k words; row-per-word bloats the store for no benefit. Segment-level sync (click-to-seek, highlight current utterance) only needs utterance timestamps. Word detail stays in the retained raw JSON, parsed on demand if ever needed.
- **The raw API response lives on disk** in the recording's folder (spec: retain for re-processing). Edits go to `Utterance` rows only; "re-process" rebuilds rows from the raw JSON.
- **`SpeakerSlot` persists the cluster embedding** even when unmatched, so naming an unknown speaker weeks later still feeds auto-learn without re-reading audio.

### On-disk layout (user-visible, Finder-grabbable)

```
~/Documents/KVoice/                     # configurable root
└── 2026-08-13 Standup/                 # folderName = sanitized title (unique-suffixed)
    ├── 2026-08-13 Standup.m4a
    ├── transcript.raw.json             # verbatim AssemblyAI response
    └── exports: 2026-08-13 Standup.md / .txt / .docx (on demand)
```

Rename = sanitize new title → rename folder, `.m4a`, and existing exports via FileManager → update `folderName` in DB only after the FS operations succeed (rollback on partial failure). Collisions get ` 2`, ` 3` suffixes. SwiftData IDs, not paths, are the stable identity.

---

## 2. Phases

Each phase ends green: `swift test` passes in `Core`, the app builds, and the phase's exit criteria are demonstrable. Phases are ordered so every phase has a runnable artifact.

### Phase 0 — Scaffolding (S)

- `Core` package with empty module folders + placeholder test; `speakerlab` executable printing its version; XcodeGen manifest; app target that launches an empty window and passes mic-permission plumbing (`NSMicrophoneUsageDescription`).
- A `Makefile` or `Scripts/` for `generate`, `build`, `test` so every later phase has one-command verification.
- **Exit:** `make test && make build` green on a clean checkout.

### Phase 1 — Speaker-ID pipeline + CLI harness (L) ← the spec's mandated first build

All in `Core`, exercised through `speakerlab`. No UI.

1. **Re-verify AssemblyAI request surface** (fetch `llms.txt` / API reference; confirm `speech_models` value, `keyterms_prompt` compatibility, utterance/word response shape). Record findings in `docs/api-notes.md`.
2. `AssemblyAIClient` (upload / create / poll with exponential backoff, typed errors, raw-JSON passthrough). API key from `ASSEMBLYAI_API_KEY` env var in CLI; Keychain comes later.
3. `UtteranceSelector`: from a parsed response, per diarized speaker pick 3–5 longest *clean* utterances — target 5–15 s spans, trimmed to word boundaries, skipping spans that overlap another speaker's words.
4. Span extraction: `AVAudioFile` read of the `.m4a` → `AudioConverter` → 16 kHz mono Float32.
5. `FluidAudioEmbedder` behind `SpeakerEmbedder`: run FluidAudio on each span, take the dominant speaker's 256-d embedding from `speakerDatabase`; average spans → L2-normalized cluster embedding. Model bootstrap via `downloadIfNeeded()` with a documented offline-staging path.
6. `ClusterMatcher`: cosine similarity of cluster embedding vs. each `Person`'s profile (score = max over stored embeddings); threshold default **0.62** (spec's 0.60–0.65 band, tuned here); below threshold → unknown.
7. Profile math: running-average fold-in, 20-embedding FIFO cap, source tagging (this is the auto-learn core, UI-free).
8. `speakerlab` commands: `transcribe <file>` (calls AssemblyAI, saves raw JSON), `enroll <name> <clips...>`, `identify <file> <raw.json>` (prints per-speaker best match + score), `eval <dir>` (batch accuracy over a labeled corpus). Profiles persist to a JSON file — the CLI does not touch SwiftData.
9. **Validate on real audio**: user-supplied recordings incl. a 60-min two-person meeting and a three-voice case. Tune threshold; confirm the fallback decision (keep FluidAudio vs. switch to ONNX ECAPA-TDNN).

- **Exit:** `speakerlab identify` names both known speakers correctly and flags the unknown one on real recordings; threshold chosen from `eval` output; embedding backend decision locked.

### Phase 2 — Recording engine (M)

- `MicSource` on `AVAudioEngine`: input tap → `AVAudioConverter` → AAC `.m4a` at 48 kHz via `AVAudioFile`, streaming to disk continuously (no in-memory growth; a 2-hour recording is fine by construction). RMS level via the tap → `levelStream`.
- Pause/resume (stop consuming tap without closing the file), duration tracking, input-device selection (on macOS: set the input AudioUnit's `kAudioOutputUnitProperty_CurrentDevice`; enumerate devices with CoreAudio — this stays in `Core`, it's not UI).
- Failure handling: device disappears mid-recording → pause + surface error, file remains valid to its last frame.
- `RecordingStore`: create the recording folder, finalize file, compute duration; filename sanitizer with unit tests.
- **Exit:** `speakerlab record` (thin CLI wrapper) produces a valid 48 kHz AAC `.m4a` with pause/resume verified; a long (≥1 h) test recording plays back complete.

### Phase 3 — Persistence + pipeline orchestration (M)

- SwiftData schema (§1), `ModelContainer` setup shared by app (and, in tests, in-memory).
- `TranscriptionJob` actor: state machine `recorded → uploading → queued → transcribing → matching → done | failed`, driving `AssemblyAIClient` then the Phase-1 matcher; persists state transitions so a relaunch resumes/retries cleanly; retry never re-records (raw file + raw JSON are the recovery points).
- Keyterms from settings passed as `keyterms_prompt`; keychain-backed API key storage (`kSecClassGenericPassword` wrapper in `Core` — Security framework is UI-free).
- Auto-learn hookup: naming/confirming a `SpeakerSlot` folds its cluster embedding into the `Person` (Phase-1 math, now against SwiftData).
- **Exit:** integration test with a mocked `TranscriptionProvider` walks a recording end-to-end to `done`, including a failure + retry path; a real end-to-end run works via a temporary debug entry point.

### Phase 4 — App shell: record + library (M)

- Record view: big record button, elapsed time, level meter, pause/resume; on stop → auto-enqueue `TranscriptionJob`; quit guard while recording (`applicationShouldTerminate` → confirm dialog).
- Library: list with title, date, duration, status badge (live per-phase progress from the job actor), participant names once matched; inline rename wired to the Phase-2/3 rename logic; delete (moves folder to Trash); "Transcribe" action for any item (covers imported/failed items).
- **Exit:** record → watch statuses advance → transcript arrives with auto-named speakers, all without the UI ever blocking; rename visibly renames files in Finder.

### Phase 5 — Transcript editor (M/L)

- Turn-grouped transcript (speaker name + `[hh:mm:ss]`), current-segment highlight during `AVAudioPlayer`/`AVPlayer` playback, click-to-seek.
- Inline text editing → `Utterance.text`.
- Speaker operations: reassign one utterance; reassign a whole diarized speaker; merge two speakers (all with the auto-learn trigger from Phase 3, and "create new person" inline). Unknown speakers render as "Unknown Speaker N" with a name-me affordance.
- **Exit:** the three-voice acceptance flow works end-to-end in UI: unknown flagged → named → recognized automatically in the *next* recording.

### Phase 6 — People + Settings UI (M)

- People section: profile list with embedding-count/source summary; guided enrollment (~30 s scripted read using `MicSource`, chunked into ~5 s windows → enrollment embeddings); clip upload (drag in files → same chunking); rename / re-enroll / delete / "reset learned voice" (drops `autolearn`-sourced embeddings, keeps enrollment ones).
- Settings scene: API key (Keychain), storage folder picker (with migration move), threshold slider (0.40–0.80, default from Phase 1), keyterms editor, default export format, input device picker.
- **Exit:** all three profile-creation paths produce profiles that `identify` real audio; every settings value takes effect without relaunch.

### Phase 7 — Export + Finder integration (M)

- `TranscriptDocument` (speaker-resolved turns) → three renderers in `Core/Export`:
  - Markdown: `## Name — [hh:mm:ss]` + paragraphs.
  - Plain text: same structure, no markup.
  - **docx**: hand-built minimal OOXML (`[Content_Types].xml`, `_rels/.rels`, `word/document.xml`, `word/styles.xml`) in a **stored-entry (no-compression) zip written by ~150 lines of our own code** — valid per the spec's "no heavyweight dependency" note. Speaker names bold, timestamps in subdued gray.
- Golden-file unit tests for all three; manual check: opens cleanly in Word *and* imports into Google Docs (acceptance criterion).
- App: export menu + default-format button, "Reveal in Finder", drag-out of audio + transcript (`NSItemProvider` / `Transferable`), filenames follow title.
- **Exit:** exports of a real meeting verified in Word and Google Docs.

### Phase 8 — Hardening + acceptance pass (M)

- Run the full acceptance checklist (§4) on real recordings, including the 60-minute case.
- Edge sweep: app relaunch mid-poll (job resumes), network loss (retryable failed state), API-key absent (clear settings prompt), storage folder moved/deleted, model-download failure on first run (blocking-with-explanation UX + offline staging instructions).
- Signing: Developer ID (or local ad-hoc) signed build, hardened runtime, mic TCC verified on a clean user account; `make release` producing the `.app`.
- **Exit:** every acceptance criterion in §4 checked off on the signed build.

---

## 3. Design decisions & risks

| # | Decision / risk | Rationale / mitigation |
|---|---|---|
| 1 | **Model identifier drift** — spec says Universal-3 Pro, current docs say `universal-3-5-pro` | `speech_models` array is a settings-backed constant with fallback (`["universal-3-5-pro", "universal-2"]`); Phase 1 re-verifies against `llms.txt` before any code hardcodes it |
| 2 | **FluidAudio per-clip embedding access** — public API is diarizer-shaped, embeddings come via `speakerDatabase` | Exactly what the Phase-1 harness validates first; `SpeakerEmbedder` protocol keeps the ONNX ECAPA-TDNN fallback a drop-in |
| 3 | **~100 MB model download on first run** | Acceptable for a personal tool; cache in Application Support, support `DiarizerModels.load(local…)` staging for fully-offline installs; first-run UX explains the one-time download |
| 4 | **AVAudioEngine over AVAudioRecorder** despite recorder being simpler | Spec names AVAudioEngine, and the `AudioSource` protocol is the v2 path to system-audio capture (process taps / ScreenCaptureKit) |
| 5 | **Words not persisted as rows** | 9k+ rows per hour of audio for a feature (word-level highlight) v1 doesn't need; raw JSON retains full fidelity |
| 6 | **Rename is FS-first, DB-second** | Files are the user-visible truth; DB updates only after successful renames, with rollback, so Finder and library never disagree |
| 7 | **Threshold 0.62 default, settings-tunable 0.40–0.80** | Inside spec's band; Phase-1 `eval` on real voices picks the shipped default |
| 8 | **Hand-rolled stored-entry zip for docx** | Spec explicitly wants no heavyweight dependency; stored (uncompressed) entries are valid zip and Word/Google Docs accept them; golden-file tests lock the format |
| 9 | **Enrollment quality variance** (30 s read ≠ meeting speech) | Enrollment chunks into multiple embeddings (not one average), and auto-learn continuously adds real-meeting embeddings, which dominate over time |
| 10 | **SwiftData maturity** | Schema kept flat and small; DTO layer between API JSON and models; in-memory container for tests |

## 4. Acceptance criteria → where proven

| Criterion | Proven in |
|---|---|
| 60-min two-person meeting records + transcribes end-to-end in one action | Phase 2 (long-recording test), 4 (one-action flow), 8 (full run) |
| Both speakers auto-named when profiles exist | Phase 1 (`speakerlab identify`), 4 (in-app) |
| Unknown third voice flagged, then auto-recognized next time | Phase 1 (`eval`), 5 (naming flow), 8 |
| Renaming a recording renames files on disk | Phase 2 (unit), 4 (UI + Finder check) |
| All three export formats correct + open in Word / import to Google Docs | Phase 7 (golden files + manual) |
| UI never blocks; failed transcription retryable without re-recording | Phase 3 (actor design + retry test), 8 (network-loss sweep) |

## 5. Out of scope (unchanged from spec)

System-audio capture, iOS target, live streaming, summaries, sync — but the `AudioSource` protocol, `Core`/App split, and provider protocol are the seams that keep each of them additive.
