# Android — sideload Shelf

Personal use only. **Do not** submit this build to the Play Store unless Lewis asks.

Lewis does not have a physical Android phone in hand yet. Success for this drop is a green `flutter build apk` (and/or `flutter run` on an emulator). Sideload steps are here for later — when Lewis is home, or if someone else clones the public repo and installs themselves.

## 1. Clone

```bash
git clone https://github.com/Lewis-AI-Collab/shelf.git
cd shelf
```

## 2. Flutter deps

Need **Flutter 3.47+** (same as iOS; `pdfrx` requires it) and an Android SDK (platform 36 is what CI / this agent used).

```bash
flutter pub get
```

## 3. Run or build

Emulator or USB device:

```bash
flutter devices
flutter run -d android
```

Release APK (preferred to pass around):

```bash
flutter build apk --release
```

App Bundle (only if a Play upload is requested later):

```bash
flutter build appbundle --release
```

## 4. Where the APK lands

| Command | Output |
| --- | --- |
| `flutter build apk --release` | `build/app/outputs/flutter-apk/app-release.apk` |
| `flutter build apk` (debug) | `build/app/outputs/flutter-apk/app-debug.apk` |
| `flutter build appbundle --release` | `build/app/outputs/bundle/release/app-release.aab` |

## 5. Sideload on a phone (later)

Enable **Install unknown apps** / **unknown sources** for the app you use to open the APK (Files, Chrome, Drive, Telegram, …). Then open `app-release.apk`.

From a computer:

```bash
adb devices
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

USB debugging must be on. `adb` is in the Android SDK `platform-tools`.

## Permissions the APK declares

In `android/app/src/main/AndroidManifest.xml`:

- `INTERNET` — BYO AI HTTPS calls
- `RECORD_AUDIO` — dictate notes (`speech_to_text`)
- `BLUETOOTH` / `BLUETOOTH_ADMIN` / `BLUETOOTH_CONNECT` — headset dictation
- Speech `queries` for `android.speech.RecognitionService` (Android 11+ package visibility)
- Backup **off** so Android Keystore keys are not restored without the key material

PDF import uses the system file picker (SAF). No broad storage permission.

API keys use `flutter_secure_storage` → Android Keystore (RSA-OAEP + AES-GCM), the Keychain equivalent.

## Smoke notes — parity vs iOS

| Feature | Android vs iOS |
| --- | --- |
| PDF library, notes, Comment \| Select | Same Dart UI. `pdfrx` uses native assets on Android. |
| Export JSON + `.md` | Same files. Share sheet is Android’s chooser, not an iPad popover. `sharePositionOrigin` is **omitted** on Android (iOS still gets a non-zero origin). |
| BYO AI | Same Settings. Keys in Android Keystore instead of iOS Keychain. |
| File picker | Android Storage Access Framework vs iOS Files. |
| Speech on emulator | Often missing / needs Google speech extras. Type instead. Physical phone + mic permission is the real test. |
| Speech locale | App asks for `en_GB`. If the device pack is missing, dictation may fail — type the note. |
| Share UX | Destinations differ (Files, Drive, Nearby Share, WhatsApp, …). |

Energy / Play listing / iOS-only chrome beyond shared-code fixes are out of scope.
