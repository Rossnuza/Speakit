# Speakit

A native Swift/SwiftUI macOS app inspired by [Speechify](https://speechify.com) — a voice
productivity assistant that turns anything you read into audio and turns your voice into
clean, written text, system-wide.

Everything runs **on-device with Apple frameworks only**: no accounts, no subscriptions,
no network services required (web-page import fetches the page you ask for, nothing else).

## Features

| Speechify feature | Speakit implementation |
|---|---|
| Listen to PDFs, docs, books, articles | Import **PDF, DOCX, DOC, RTF, ODT, EPUB, HTML, TXT, Markdown**, any **web URL**, or **pasted text** into a persistent library |
| Scan & listen (OCR) | Import **images** (PNG/JPEG/TIFF/HEIC/…) — text is recognized with the Vision framework |
| 1,000+ voices, 60+ languages | Every speech voice installed on your Mac, grouped by language with **Standard / Enhanced / Premium** quality badges, searchable, with one-click preview. Download more in System Settings → Accessibility → Spoken Content |
| Listen up to 4.5× speed | Speed menu from **0.5× to 4.5×**, changeable live during playback |
| Text highlighting that follows along | **Word-level highlight** plus a sentence wash, synchronized with speech and auto-scrolling; double-click anywhere to jump playback there |
| Resume where you left off | Reading position and percent progress are saved per document |
| Voice typing in any app (⌥Z) | **System-wide dictation**: press ⌥Z anywhere, speak, press ⌥Z again — Speakit transcribes on-device, strips filler words (“um”, “uh”, “you know”), fixes spacing/capitalization, and types the result into the focused field. A floating HUD shows the live transcript |
| Listen to anything on screen | **⌥R** reads the text currently selected in any app; press ⌥R again to stop |
| Offline listening / downloads | **Export narration to an audio file** (.caf) from the player bar |
| Menu bar convenience | Menu-bar mini player: play/pause, skip, speed, voice typing, listen-to-clipboard — works with the main window closed |

Not included (they require cloud AI services, out of scope for a fully native, offline app):
AI summaries/chat about documents, podcast generation, voice cloning, and celebrity voices.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ (or Swift 5.9+ toolchain with Command Line Tools) to build

## Build & run

```bash
git clone <this repo> && cd Speakit
./scripts/build-app.sh
open build/Speakit.app
```

Or open the folder directly in Xcode (`File → Open…` — it's a Swift package) and run the
`Speakit` scheme. Note: running the bare SwiftPM binary with `swift run` works for the
reader, but microphone/speech-recognition permission prompts require the real `.app`
bundle produced by the build script (they're tied to the bundle's Info.plist).

### Permissions

Speakit asks for these the first time each feature is used:

- **Microphone** + **Speech Recognition** — voice typing (⌥Z)
- **Accessibility** (System Settings → Privacy & Security → Accessibility) — needed to
  type dictated text into other apps and to grab the selection for ⌥R

### Getting better voices

Speakit uses whatever system voices are installed. For dramatically more natural voices:
System Settings → Accessibility → Spoken Content → System Voice → **Manage Voices…**, then
download Enhanced/Premium voices in any of 60+ languages. They appear in Speakit's voice
picker automatically.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌥Z | Start/finish voice typing (works system-wide) |
| ⌥R | Read the selected text in any app / stop reading |

## Architecture

```
Sources/Speakit/
├── SpeakitApp.swift          # App entry: main window, Settings, MenuBarExtra
├── AppState.swift            # Coordinator: services, hotkeys, import routing
├── Models/
│   ├── Document.swift        # Library item metadata
│   └── LibraryStore.swift    # JSON index + per-document text files on disk
├── Services/
│   ├── SpeechPlayer.swift    # AVSpeechSynthesizer engine: sentence-chunked playback,
│   │                         #   word highlighting, speed mapping, seek/skip, resume
│   ├── TextExtractor.swift   # PDFKit, NSAttributedString importers, EPUB unzip,
│   │                         #   web fetch + readability strip, Vision OCR
│   ├── DictationService.swift# SFSpeechRecognizer + AVAudioEngine voice typing,
│   │                         #   filler-word cleanup, paste-based text insertion
│   ├── HotkeyManager.swift   # Carbon global hotkeys (⌥Z, ⌥R)
│   └── AudioExporter.swift   # AVSpeechSynthesizer.write → .caf for offline listening
└── Views/                    # SwiftUI: library sidebar, reader with live highlights,
                              #   player bar, voice picker, settings, menu-bar player,
                              #   dictation HUD (floating NSPanel)
```

Design notes:

- **Sentence-chunked playback.** Documents are tokenized into sentences
  (NaturalLanguage framework); each sentence is a separate `AVSpeechUtterance`. That makes
  skip-forward/back, live speed/voice changes, click-to-jump, and progress persistence
  cheap — no restarting the whole document.
- **Highlighting** maps `willSpeakRangeOfSpeechString` word ranges from utterance-local to
  document coordinates and paints them into an `NSTextView` via temporary background
  attributes (no re-layout of the full attributed string per word).
- **Dictation insertion** goes through the pasteboard plus a synthesized ⌘V (the approach
  system-wide dictation utilities use), preserving and restoring the user's clipboard.
- **Speed mapping**: `AVSpeechUtterance.rate` is a 0–1 scale where 0.5 is normal speech;
  Speakit maps its human-facing 0.5×–4.5× multiplier onto that scale.
