<h1 align="center">Scribe</h1>

<p align="center">A compact glass panel for your Mac that transcribes lectures and turns them into study material — entirely on‑device.</p>

---

## What it does

Scribe is a small floating window, about the size of a Stickies note. Press record and it
writes down what it hears. When the lecture is over, the same panel can:

- **Summarize** the whole transcript
- Hold your own **notes** alongside it
- Generate **flashcards** (question / answer pairs)
- Auto‑create a **to‑do list** of action items, each with a button that jumps back to the
  moment in the transcript it came from

Transcription uses macOS 26's `SpeechAnalyzer` / `SpeechTranscriber`. Summaries, flashcards
and to‑dos use Apple's on‑device Foundation Models. Nothing is sent anywhere.

## Where your work lives

On first launch Scribe asks for a folder. Each session becomes a subfolder of plain files
you can open in any editor:

```
<your folder>/2026-08-29 14.12 Cognitive Psych — Lec 14/
    session.json        title, dates, duration
    transcript.md       the transcript, with [m:ss] markers
    summary.md
    notes.md
    flashcards.json
    todos.json
```

## Requirements

- macOS 26 (Tahoe) or newer, on Apple Silicon
- Apple Intelligence turned on (for the summary / flashcard / to‑do features)
- Xcode 26 to build

## Building

Open `Scribe.xcodeproj` and run the **Scribe** scheme. It signs to run locally; to
distribute it, set your own team in the target's Signing settings.

## History

Scribe began as a fork of [OpenSpoken](https://github.com/talaviram/OpenSpoken) by Tal
Aviram — a live microphone transcriber for iOS and macOS. The original microphone‑to‑text
idea and the MIT license carry over; everything else has been rebuilt as a native macOS 26
app. See `LICENSE`.
