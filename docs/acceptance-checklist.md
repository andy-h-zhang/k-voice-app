# KVoice acceptance checklist

The one human pass that closes Phase 8. Everything an automated test *can* check
is already checked — 570 offline tests in 60 suites (`make test`). What is left
is the part a machine can't see: permission prompts, visual state, Finder
parity, and whether real voices actually get recognized.

**Time:** ~30 minutes of hands-on work for sections A–H and J. Section I adds a
60-minute recording that runs unattended — start it, go do something else.

**Build under test:** the signed Release app, not a debug build.

```sh
make release   # runs the full test suite, then builds + signs
```

Then open the `.app` printed at the end (`build/release/Build/Products/Release/KVoice.app`).
An ad-hoc signed build is Gatekeeper-rejected on first launch: **right-click →
Open**, once. See the README's "Release builds" section.

**You will need:** an AssemblyAI API key · a second person (or a second
recorded voice) · a third voice for the unknown-speaker flow · Microsoft Word ·
a Google account for Docs · ~100 MB of download for the on-device voice models.

**Before you start — force a genuine first run:**

```sh
mv ~/Documents/KVoice ~/Documents/KVoice-before-acceptance   # if it exists
security delete-generic-password -s ai.kizaki.KVoice 2>/dev/null  # clear any stored key
```

Tags mark which phase's agent flagged the item: **[Spec]** = a spec acceptance
criterion; **[P2]**–**[P7]** = a visual check that phase's work left behind.

---

## A. First run with no API key — [P4]

- [ ] App launches to an empty library without an error dialog. **[P4]**
- [ ] The library folder `~/Documents/KVoice/` is created on disk. **[P2]**
- [ ] A recording can still be made with no key configured — nothing about the
      no-key state blocks recording. **[P4]**
- [ ] The missing key is surfaced as a prompt, not a failure: "Add your
      AssemblyAI key in Settings to transcribe." with an **Open Settings…**
      affordance that actually opens Settings. **[P4]**
- [ ] Quit and relaunch: still no error, library still there. **[P4]**

## B. Microphone permission and the first recording — [Spec] [P2] [P4]

- [ ] First tap of **Start Recording** triggers the system mic prompt; the app
      shows "Waiting for microphone access…" while it is up. **[P2]**
- [ ] Deny it once: the app shows "Microphone access is off" with an **Open
      System Settings** button that lands on the right pane. Re-allow. **[P2]**
- [ ] Recording starts: elapsed time counts up smoothly and the input level
      meter tracks your voice (silence → floor, speech → movement). **[P2]**
- [ ] **Pause** — timer stops, meter goes quiet, state reads "Recording
      paused". **Resume** — both pick up without a gap. **[Spec]**
- [ ] With the recording still running, quit (⌘Q): the guard dialog "Stop
      recording and quit?" appears with **Stop and Quit** / **Cancel**. **[P4]**
- [ ] **Cancel** returns you to the still-running recording. **[P4]**
- [ ] Now **Stop**. The row appears in Recordings with a real duration, and the
      `.m4a` is playable in QuickTime — including the audio recorded *after*
      the resume. **[P2]**
- [ ] Record a second short clip and quit mid-recording with **Stop and Quit**:
      the file is finalized, not truncated garbage — it opens and plays. **[P4]**

## C. Rename, delete, and Finder parity — [Spec] [P2] [P4]

- [ ] Rename a recording inline in the library. **[Spec]**
- [ ] In Finder, the folder **and** the `.m4a` inside it both took the new
      name. **[Spec]** — this is the "renaming renames files on disk" criterion.
- [ ] If that recording had been exported, its files in `Transcripts/` took the
      new name too, and no other recording's exports moved.
- [ ] Rename to something with illegal characters (`Q3/Q4: plan?`): the title
      shows as typed, the folder name is sanitized, nothing breaks. **[P2]**
- [ ] Rename a second recording to the *same* title: it gets a " 2" suffix on
      disk rather than colliding. **[P2]**
- [ ] **Move to Trash…** removes the row and puts the folder in the Trash
      (recoverable — check the Trash). **[P4]**
- [ ] That recording's exports in `Transcripts/` went to the Trash with it, and
      nobody else's did.

## D. Settings walkthrough — [P6]

- [ ] **API key:** paste your AssemblyAI key. It reports being stored in the
      login Keychain. Confirm with `security find-generic-password -s
      ai.kizaki.KVoice` that it is there — and that it is *not* in any plist.
- [ ] **Input device:** the picker lists your real devices plus "System
      default"; pick a specific one and confirm the record view's "Recording
      will use" line reflects it.
- [ ] Unplug/disable the selected device (if you have a USB mic): the app
      degrades gracefully rather than hanging.
- [ ] **Similarity threshold:** the slider moves between Strict and Lenient and
      the value persists across a relaunch.
- [ ] **Keyterms:** add a few domain terms (names, jargon). They persist.
- [ ] **Default format:** switch it; the editor's Export menu's first item
      changes to match ("Export as …").
- [ ] **Library folder → Move…:** pick a new empty folder, confirm **Move
      Library Here**. Every recording folder — and the `Transcripts/` folder —
      moves with it (check Finder), and the app says it needs a relaunch to
      finish.
- [ ] Relaunch: the library is intact at the new location, recordings still
      play, and nothing was left behind but an empty old folder.
- [ ] Try moving into a folder that already has files: it is refused with an
      explanation, and nothing moves. **[P6]**
- [ ] Move it back to `~/Documents/KVoice` for the rest of this checklist.

## E. Enrollment and the model download — [Spec] [P6]

- [ ] **People → Add Person → Record a Voice…** The first enrollment triggers
      the one-time model download: "Preparing on-device voice models" with
      visible progress, and an explanation that this happens once. **[P6]**
      — This is the ~100 MB FluidAudio download. Watch it complete.
- [ ] Read the on-screen script (~30 seconds). The level feedback moves as you
      read, and it completes on its own at the end. **[P6]**
- [ ] The profile now shows voice samples tagged **Enrolled**. **[P6]**
- [ ] Enroll a *second* person the same way (or via clips, below). **[Spec]**
- [ ] **Add Audio Files…** on a third profile: drop in existing clips of that
      person; the samples are tagged as coming from files. **[Spec]**
- [ ] Stop an enrollment after ~2 seconds: it refuses with "That was too short
      to learn from" rather than storing a garbage profile. **[P6]**
- [ ] **Re-enroll…** and **Reset Learned Voice** both do what they say —
      reset drops only auto-learned samples and keeps the enrolled ones. **[P6]**
- [ ] *Offline-failure path (optional, 2 min):* turn off Wi-Fi, delete
      `~/Library/Application Support/FluidAudio/Models/`, and start an
      enrollment. It must fail with "The voice models aren't available" and a
      **Show Model Folder** button — not hang and not crash. Restore Wi-Fi and
      let it re-download. **[P6]**

## F. Full pipeline with a key: record → transcribe → auto-name — [Spec] [P4]

- [ ] Record a few minutes with **both enrolled people** speaking, taking real
      turns. Stop.
- [ ] Transcription starts **automatically** on stop — one action, no separate
      "transcribe" step. **[Spec]**
- [ ] The status badge advances through Uploading → Queued → Transcribing →
      Matching speakers → Done. **[P4]**
- [ ] **The UI never blocks** during any of it: scroll the library, open
      Settings, start another recording while the first uploads. **[Spec]**
- [ ] When it lands, both speakers are **auto-named** with the right names —
      not Speaker A/B. **[Spec]**
- [ ] The library row lists the detected participants. **[P4]**
- [ ] *Network-loss retry:* start another transcription and turn off Wi-Fi
      mid-upload. It lands in a **failed** state with a readable message and a
      **Retry** action. Turn Wi-Fi back on, hit Retry: it completes **without
      re-recording**. **[Spec]**
- [ ] *Relaunch mid-poll:* start a transcription and quit the app while it is
      Transcribing. Relaunch: it **resumes** and finishes on its own, rather
      than restarting the upload. **[P3] [P4]**
- [ ] **Re-process Transcript** on a finished recording rebuilds it with no
      network at all (turn Wi-Fi off to prove it). **[P4]**

## G. The editor and the three-voice flow — [Spec] [P5]

Use a recording with your two enrolled people **plus a third, unenrolled
voice**.

- [ ] Transcript is grouped into speaker turns with `[hh:mm:ss]` timestamps.
- [ ] Play: the current turn highlights and the view follows along (**Follow
      Playback**); toggling follow off stops the auto-scroll. **[P5]**
- [ ] Click a turn / **Play from Here**: audio jumps to that point. **[Spec]**
- [ ] **Edit Text** on a turn, change wording, and confirm it persists after
      closing and reopening the recording. **[Spec]**
- [ ] The third voice is flagged as **Unknown Speaker 1** rather than
      mis-attributed to an enrolled person. **[Spec]**
- [ ] Speaker op 1 — **Name This Speaker…**: name the unknown speaker. Every
      line of theirs updates. **[P5]**
- [ ] Speaker op 2 — **Reassign This Line to a Person…**: move a single
      misattributed line. Note the UI's own warning that a single-line move
      deliberately does *not* train the voice profile. **[P5]**
- [ ] Speaker op 3 — **Reassign to Another Person…** (whole diarized speaker):
      every line moves at once. **[Spec]**
- [ ] Speaker op 4 — **Merge Speakers**: merge two labels diarization split
      apart; the lines combine under one person and the empty label
      disappears. **[Spec]**
- [ ] People now shows the newly-named person with **Auto-learned** samples —
      naming folded the voice in. **[Spec]**
- [ ] **The payoff:** record a *new* short clip with that third person
      speaking. They are **auto-recognized by name**, with no prompting. **[Spec]**
      — this is the "label once, it remembers" criterion.

## H. Exports — [Spec] [P7]

For one finished, speaker-named recording, export all three formats:

- [ ] **Export as …** (the default-format item) matches your Settings choice. **[P7]**
- [ ] Markdown, plain text, and `.docx` all land in `~/Documents/KVoice/Transcripts/`,
      named after the recording title — *not* in the recording's own folder,
      which keeps only the `.m4a` and `transcript.raw.json`. **[Spec]**
- [ ] The `Transcripts/` folder did not exist before the first export and was
      created by it.
- [ ] Markdown: `## Name — [hh:mm:ss]` headers, readable paragraphs. **[Spec]**
- [ ] Plain text: same structure, no markup. **[Spec]**
- [ ] **The `.docx` opens cleanly in Microsoft Word** — speaker names bold,
      timestamps subdued gray, no repair prompt. **[Spec] [P7]**
- [ ] **The same `.docx` imports into Google Docs** with formatting intact
      (upload to Drive → Open with Google Docs). **[Spec] [P7]**
- [ ] All three contain your *edited* text, not the original API text. **[P5]**
- [ ] **Reveal in Finder** / the magnifying-glass button opens the right
      folder: the recording's own folder for the audio chip, `Transcripts/`
      (or the exported file itself, after an export) for the transcript
      chip. **[P7]**
- [ ] **Drag the audio out** of the app into Finder or Mail — the `.m4a`
      arrives. **[P7]**
- [ ] **Drag the transcript out** — it exports into `Transcripts/` first, then
      drags, as the tooltip says. **[P7]**
- [ ] **File ▸ Show Transcripts in Finder** opens that same folder, and
      **File ▸ Show Recordings in Finder** opens the library root above it.

## I. The acceptance recordings — [Spec]

- [ ] **60-minute two-person meeting.** Record a real (or simulated) hour with
      two enrolled people. Start it and leave it alone. **[Spec]**
- [ ] It records for the full hour with **no drops** — the `.m4a` is ~60
      minutes and plays through to the end. **[Spec] [P2]**
- [ ] It transcribes end-to-end in **one action** and both speakers are named
      correctly throughout — spot-check the start, middle, and end. **[Spec]**
- [ ] Memory does not balloon during the hour (glance at Activity Monitor). **[P2]**
- [ ] **Three-voice recording** (covered in G) is signed off. **[Spec]**
- [ ] Export the 60-minute transcript to `.docx` and confirm Word opens it —
      long documents are where the hand-rolled zip would show a defect. **[P7]**

## J. speakerlab CLI spot-checks — [P1]

Not user-facing, but it is the validation harness the speaker-ID pipeline was
built against, and Phase 1b's accuracy validation still runs through it.

```sh
export ASSEMBLYAI_API_KEY="…"
swift build --package-path Core -c release
```

- [ ] `speakerlab record --list-devices` lists your real input devices. **[P2]**
- [ ] `speakerlab transcribe meeting.m4a` writes `meeting.raw.json`. **[P1]**
- [ ] `speakerlab enroll "Name" clip1.m4a clip2.m4a` creates a profile. **[P1]**
- [ ] `speakerlab identify meeting.m4a meeting.raw.json` names the known
      speakers and flags the unknown one, matching what the app decided. **[P1]**
- [ ] `speakerlab identify … --learn A=Name` folds the correction in. **[P1]**
- [ ] `speakerlab eval <labeled-dir>` prints accuracy and a threshold sweep —
      confirm the shipped default (0.62) still looks right for *your* voices,
      and adjust Settings → Similarity threshold if the sweep says otherwise.
      **[P1]** — this is the open item from Phase 1b.

---

## K. First-use QA round — [QA1]

The four things a first real user hit on day one. Worth re-walking after any
change to the library row, the detail screen, or the window's layout.

- [ ] **With no API key configured**, double-click an untranscribed recording:
      it opens, the transport bar at the bottom is enabled, and it plays.
- [ ] The same recording opens from the trailing **›** control and from the
      context menu's **Open Recording**. All three work on every row.
- [ ] The middle of that screen says **No Transcript Yet**, explains that the
      audio can still be played, and offers **Open Settings…** (no key) or
      **Transcribe** (key present).
- [ ] Every library row shows a **folder** button that reveals that recording's
      folder in Finder, without opening a context menu.
- [ ] The **path footer** under the list shows `~/Documents/KVoice` (or wherever
      the library is), is visible in the empty state too, and opens Finder when
      clicked.
- [ ] **File ▸ Show Recordings in Finder** and **File ▸ Show Transcripts in
      Finder** both work from every sidebar section, including Record.
- [ ] Resize the window very wide, very tall, and very small. It resizes freely
      in both axes and stops only at a sane minimum.
- [ ] Switch Record → Recordings → People → Record. The window keeps the size
      you gave it at every step — no snap back to the default.
- [ ] Resize, quit, relaunch: the window comes back the size and position you
      left it.

---

## Sign-off

| Spec acceptance criterion | Section | Pass |
|---|---|---|
| 60-min two-person meeting records + transcribes in one action | I | ☐ |
| Both speakers auto-named when profiles exist | F | ☐ |
| Unknown third voice flagged, then auto-recognized next time | G | ☐ |
| Renaming a recording renames its files on disk | C | ☐ |
| All three exports correct, open in Word + Google Docs | H | ☐ |
| UI never blocks; failed transcription retryable without re-recording | F | ☐ |

Date: ________  Build: `KVoice 0.1.0 (1)`, signature: ad-hoc / Developer ID

**Anything that fails here is a defect, not a checklist bug** — file it against
the phase tagged on the line.
