# Shelf

Personal, phone-only PDF library with page voice notes. Working title — Lewis may rename.

v1 is a **single-user, this-device** library. No cloud sync, no accounts, no App Store / Play Store listing.

iOS and Android are both supported. Default Android install is a **sideload APK** (debug or release) for personal use — not a Play Store submission.

## Clone here — not Documents/Grok

Put the project on the local disk:

```bash
mkdir -p ~/Developer
git clone https://github.com/Lewis-AI-Collab/shelf.git ~/Developer/shelf
cd ~/Developer/shelf
```

**Do not** clone into `~/Documents/Grok` (or any iCloud Desktop & Documents folder). The iCloud File Provider breaks iOS codesign when Xcode / Flutter writes build products under iCloud.

Use **DeviceHub** or `flutter run` from Xcode — not `Simulator.app` as the daily driver.

Expected local toolchain: **Flutter 3.47**, **Xcode 27** (iOS), and an **Android SDK** with platform 36 (Android).

## Run on iPhone (Simulator or device)

```bash
cd ~/Developer/shelf
flutter pub get
flutter run
```

Pick an iPhone simulator from DeviceHub / `flutter devices`, or a physical iPhone.

First-run iOS build: open `ios/Runner.xcworkspace` in Xcode if you need to pick a development team for a physical device.

## Android (sideload — no Play Store)

Practical path for Lewis, Madara, or anyone cloning the public repo (including a brother-in-law who just wants the APK). There is **no Play Store listing**. Personal use = debug/release APK, emulator, or later a physical phone.

```bash
git clone https://github.com/Lewis-AI-Collab/shelf.git
cd shelf
flutter pub get
```

Then either run it:

```bash
flutter run                    # pick an Android emulator or USB device
# or
flutter run -d android
```

or build a release APK to copy around:

```bash
flutter build apk --release
```

The APK lands at:

```
build/app/outputs/flutter-apk/app-release.apk
```

(`flutter build apk` without `--release` writes `app-debug.apk` in the same folder.)

### Install later on a phone (when Lewis is home)

1. Copy `app-release.apk` to the phone (USB file transfer, Drive, Messages, `adb`).
2. On the phone: **Settings → Security** (wording varies) → allow **Install unknown apps** / **Install unknown sources** for the Files / browser / Drive app you used.
3. Open the APK and install. Shelf does not need Play Protect / Play Store.
4. Or from a computer with USB debugging:

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

`flutter build appbundle` also works if someone later wants a Play upload; **do not submit to Play unless Lewis asks**.

More sideload / parity notes: [ANDROID.md](ANDROID.md).

## Demo path

1. **Import a PDF** — Library → **Import PDF** (system file picker). The file is copied into the app Documents sandbox (`…/Documents/library/` on iOS; the app documents directory on Android).
2. Open the PDF. **Long-press** the page for a short menu: **Comment** | **Select text**. **Comment** opens the Grok pill at the press point (placeholder “Leave a comment”, mic, colour square). **Select text** turns PDF handles back on for that gesture and selects the word under the press so you can grab/widen it — then **Add comment** anchors the note to that selection (quoted text + bounds). Tap a marker to reopen a note.
3. **Dictate** (microphone) or type. On a physical phone, speech-to-text runs with British English when the platform recogniser is available. After dictation, filler words (`um`, `uh`, `like`, …) are stripped automatically; **Clean up filler** does the same pass by hand.
4. New notes start on the **orange** colour label (“General note”). Tap the colour **square** to the right of the microphone to pick another Settings colour.
5. **Show / hide markers** from the top chrome (eye icon) — outside the PDF, so it does not steal page gestures.
6. Tap a marker to reopen the note. Markers use the label colour.
7. Bottom bar: previous / next page, and the unfold control to **jump to a page number** or a **chapter** if the PDF has a table of contents.
8. **Notes** tab: keyword search, filter by colour label, tap a row to open that PDF on that page. The reader waits until the viewer is ready, jumps to the page, brings the marker into view, then opens the editor — no fixed delay.
9. **Settings**: edit the seeded labels (orange = general note, purple = further research), add your own colours and meanings. They persist with the local library.
10. **Connect your own AI** (Settings): pick OpenAI, Anthropic, Grok (xAI), or OpenAI-compatible. Each provider keeps its own Keychain (iOS) / Android Keystore key and model. **Test connection** hits `/v1/models` (or a tiny chat completion if that 404s). From an open note, **Ask AI** (composer or Notes hub) offers **Ask with your AI** (unchanged BYO flow; no key still points at Settings) or **Export / Share note** — Note + PDF + guide, Note + PDF, Note + guide, or Note only. Include PDF? vs Notes only when sending a note or a whole book.
11. Library card **⋮**: **Export comments** (JSON + a short markdown schema, via the share sheet), **Send to connected AI** (all notes for that book, with Include PDF?), **View all comments** (Notes hub, search filled with the book title). Export / Send / Ask include the **heading and subheading** the note sits under, resolved at send/export time from the current PDF outline (bookmarks) or page-title fallback.

## What’s stubbed / limited

| Area | v1 behaviour |
| --- | --- |
| **Speech on Simulator / emulator** | Apple Speech is unreliable in the iOS Simulator. Android emulators often have no working recogniser / Google speech package. The editor stays usable: type the note. On a **physical phone**, grant microphone (and iOS Speech Recognition) when prompted. |
| **Android share UX** | Android’s share sheet does not use iOS `sharePositionOrigin` / UIPopover. Export still shares JSON + `.md`. Destination apps differ (Drive, Files, Nearby Share, …). |
| **Cloud / accounts / stores** | Not started. Library is local SQLite + sandbox files. BYO AI is device-to-provider only. No App Store or Play Store listing. |
| **Export JSON/MD** | Library card ⋮ → Export comments for a whole book. From **Ask AI** on one note: Export / Share note (JSON for that note, optional PDF, optional schema `.md`). Same `shelf-notes-v1` note + document shape, including `document.file_name`. Shared through the system share sheet. |
| **Commercial polish** | Intentionally light: readable British English chrome, white canvas, orange accents. |

## Persistence

SQLite (`sqflite`) in the app database directory:

- `documents` — imported PDFs
- `notes` — `document_id`, 1-based `page`, normalised `x`/`y` (0–1, origin top-left), `text`, `color_label_id`, timestamps, and optional selection-anchor fields (`selected_text`, `selection_left`/`top`/`right`/`bottom`). Heading/subheading are **not** stored; they are resolved from the PDF at export / Ask / Send time.
- `color_labels` — user-defined colour + meaning; one row marked `is_default` (seeded orange)

PDF bytes live under the application **Documents** directory (not iCloud). API keys live in iOS Keychain or the Android Keystore via `flutter_secure_storage`.

## Tests

```bash
flutter analyze
flutter test
```

Unit tests cover filler cleanup, the note / colour-label persistence model (`toMap` / `fromMap`, default orange seed, coordinate clamping), selection-anchored notes (quoted text + bounds), `FirstTapTracker` (legacy double-tap pairing), the notes-hub open sequence, the Grok-style composer (pill, mic, 4-line field, colour square; no X/Y sliders), the long-press **Comment | Select text** menu, Keychain / Keystore-backed per-provider BYO AI settings including Grok, verify-connection success/fail, Ask AI (chooser: Ask with your AI + Export / Share note; visible on the composer without a key), single-note share bundles, library card export/send/view, orange PDF selection chrome, heading/subheading resolution on export JSON/.md and Ask/Send payloads, and Android-safe share origin (origin omitted on Android, required and non-zero on iOS).
