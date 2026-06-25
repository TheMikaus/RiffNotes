# RiffNotes

RiffNotes is an AI-built, offline-first practice-review tool for bands. It helps bandmates organize rehearsal takes, listen back with waveforms, mark song sections, write point/range notes, and keep practice metadata next to the audio files.

This project was generated and iterated with AI assistance from Codex, based on product direction, feature requests, and hands-on testing feedback from the repo owner.

## Current milestone

The repository contains an early but usable Windows-focused vertical slice:

- Select and remember a band folder.
- Discover practice folders and WAV/MP3 recordings.
- Play, pause, seek, and view cached waveforms.
- Add point notes, ranged notes, and named song sections.
- View notes for the selected track or the whole practice.
- Mark multiple recordings as Best Take.
- Apply remembered playback boosts up to +15 dB using cached processed audio.
- Preserve portable metadata in the practice folder.
- Keep long-running work visible so the app does not appear frozen.

Kindle Fire / Android support is planned around playback, note review, note editing, and sync-oriented workflows. Windows remains the primary target for heavier audio-processing features.

## Repository status

This is active experimental software. It is useful for testing the workflow, but not yet a polished production release. Expect rough edges, UI churn, and missing features while the MVP gets shaped.

## Requirements

### Windows development

- Windows 10 or newer.
- [Flutter SDK](https://docs.flutter.dev/get-started/install/windows/desktop).
- Visual Studio 2022 or Build Tools for Visual Studio with the **Desktop development with C++** workload.
- Git.
- Optional but recommended: [FFmpeg](https://ffmpeg.org/download.html) available on `PATH`.

FFmpeg is used for waveform generation, MP3/WAV conversion work, and processed playback/export features such as volume boost. The app can still open without FFmpeg, but audio-processing features will be limited or unavailable.

### Android / Kindle Fire development

- Flutter SDK.
- Android SDK / Android Studio tooling.
- A connected Kindle Fire device, Android phone/tablet, or emulator.

The Android target is present, but the current app is being developed and tested primarily on Windows.

## Run locally

From the repo root:

```powershell
flutter pub get
flutter run -d windows
```

If Flutter is not on your `PATH`, use the full path to your Flutter install instead, for example:

```powershell
C:\src\flutter\bin\flutter.bat pub get
C:\src\flutter\bin\flutter.bat run -d windows
```

## Build

### Windows release build

```powershell
flutter build windows
```

The built executable is written under:

```text
build\windows\x64\runner\Release\
```

To verify dependencies and local setup:

```powershell
flutter doctor
flutter test
```

### Android build

```powershell
flutter build apk
```

Kindle Fire installation/testing depends on your local Android device setup and developer-mode configuration.

## Practice folder data

RiffNotes stores portable metadata beside the audio so a practice folder can be copied or synced as a unit.

- `.riffnotes.<user>.bandnotes` stores one user's annotations.
- `.riffnotes.<recording-id>.sections.json` stores song sections for one track.
- `library.riffnotes.json` stores the practice recording catalogue and take metadata.
- `.riffnotes-cache\` stores regenerable waveform and processed-audio cache files.

Cache folders are safe to exclude from backups and cloud sync.

## Product decisions

- A band folder contains practice folders; each practice folder contains audio and portable metadata.
- WAV and MP3 are supported.
- A recording has a stable ID, so renaming or WAV-to-MP3 replacement never detaches notes or sections.
- Per-user annotations use `.riffnotes.<user>.bandnotes` JSON files in the practice folder.
- Google Drive sync is manual per practice folder. Regenerable cache is excluded.
- Lengthy work is queued in background operations with progress and cancellation where safe.

See [docs/product-spec.md](docs/product-spec.md) for the current, prioritized specification.

## Notable planned work

- Safer bulk rename flow after playback-based review.
- Export selected sections/ranges as WAV or MP3.
- Left/right mute and mono fold-down.
- Windows audio-output selection.
- Fuzzy fingerprint matching for takes and song sections.
- Manual Google Drive upload/download for selected practice folders.
