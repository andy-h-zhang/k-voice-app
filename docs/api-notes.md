# AssemblyAI API notes (verified 2026-08-13)

Fulfils the Phase-1 task "re-verify the AssemblyAI request surface." Verified against the live docs on this date. Sources: [transcript submit reference](https://www.assemblyai.com/docs/pre-recorded-audio/api-reference/transcripts/submit), [upload reference](https://www.assemblyai.com/docs/pre-recorded-audio/api-reference/files/upload), [Universal-3.5 Pro prompting](https://www.assemblyai.com/docs/pre-recorded-audio/universal-3-5-pro/prompting). Machine-readable doc index: `https://assemblyai.com/docs/llms.txt`.

## Auth

- Header: `Authorization: Bearer <API_KEY>` on every request.
- Base URL `https://api.assemblyai.com` (EU region exists: `api.eu.assemblyai.com` — not used by us).
- The transcribe call must use an API key from the **same project** as the upload call, else 403 "Cannot access uploaded file."

## 1. Upload — `POST /v2/upload`

- Body: **raw binary** file bytes, `Content-Type: application/octet-stream` (no multipart).
- Response 200: `{ "upload_url": "https://cdn.assemblyai.com/upload/<id>" }` — URL is only readable by AssemblyAI's servers.
- Errors: 400/401/403/404/422/429/500/503/504 (422 body is plain text, not JSON).

## 2. Create transcript — `POST /v2/transcript`

Request body we send (v1 scope):

```json
{
  "audio_url": "<upload_url>",
  "speech_models": ["universal-3-5-pro", "universal-2"],
  "speaker_labels": true,
  "keyterms_prompt": ["<from settings>"]
}
```

Facts that matter to us:

- `speech_models` is a **priority-ordered array**; allowed values today: `universal-3-5-pro`, `universal-2`. Our value equals the current server default, but we send it explicitly to pin behavior. Response echoes `speech_model_used`.
- `speaker_labels: true` requires `punctuate: true` — `punctuate` defaults to true; do not turn it off.
- `keyterms_prompt`: array of strings, ≤ 6 words per phrase, capacity ~1,000 **words total** (each word of a multi-word phrase counts; longer/uppercase terms consume more). Supported on universal-3-5-pro (and universal-2 with a lower 200 cap). Sanitize the settings list against these limits client-side; omit the field entirely when the list is empty.
- `prompt` (free-text context, ≤1,500 words) also exists on universal-3-5-pro and is **not** mutually exclusive with `keyterms_prompt` per current docs (older guidance said it was). v1 sends only `keyterms_prompt`.
- Optional knobs we may expose later: `speakers_expected` (int) or `speaker_options.{min,max}_speakers_expected` (mutually exclusive with `speakers_expected`); `language_code` (mutually exclusive with `language_detection: true`, which is the default); `disfluencies`; `audio_start_from`/`audio_end_at` (ms).

## 3. Poll — `GET /v2/transcript/{id}`

- `status`: `queued` → `processing` → `completed` | `error` (message in `error` field). No separate "uploading" state server-side — that's our client state.
- Response fields we consume:
  - `id`, `status`, `error`, `audio_duration` (seconds), `confidence`, `language_code`
  - `utterances[]` (present because `speaker_labels` on): `{ speaker: "A", text, start, end, confidence, words[] }` — start/end in **milliseconds**
  - `words[]` (flat): `{ text, start, end, confidence, speaker }` (`speaker` non-null with diarization)
- Webhooks exist (`webhook_url` + optional auth header pair) — v1 polls instead; webhook is a possible later optimization but useless for a desktop app behind NAT.

## Decisions locked for the code

1. DTOs decode exactly the shapes above with snake_case keys; unknown fields ignored; **raw response body persisted verbatim to disk before decoding** (spec: retain for re-processing).
2. Poll with exponential backoff starting ~3 s, capped at 30 s (audio_duration-aware initial delay is fine); every non-`completed`/`error` status maps to our `queued`/`transcribing` UI states.
3. Treat 429/5xx as retryable with backoff; 4xx (other than 429) as terminal for that attempt but the job stays user-retryable.
4. Model identifiers, parameter names, and limits above are constants in one file (`Transcription/AssemblyAIConstants.swift`) with this doc referenced, so the next model bump is a one-line change.
