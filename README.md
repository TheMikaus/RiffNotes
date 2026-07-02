# RiffNotes

RiffNotes is an AI-built, offline-first practice-review tool for bands. It helps bandmates organize rehearsal takes, listen back with waveforms, mark song sections, write point/range notes, and keep practice metadata next to the audio files.

This project was generated and iterated with AI assistance from Codex, based on product direction, feature requests, and hands-on testing feedback from the repo owner.

## What's New in v0.6.8

- Added per-take section labeling choices from the fingerprint menu:
- Label sections (unique labels)
- Label sections (allow repeats)
- Added bulk section labeling actions for matching takes and selected practices.
- Improved section alignment quality with partial-aware matching and tighter duration limits.
- Added a Preferences slider for section-label confidence tuning.
- Song section automation is experimental and auto-labeled results should be reviewed before finalizing.

## Current milestone

The repository contains an early but usable Windows-focused practice-review application:

- Select and remember a band folder.
- Discover practice folders and WAV/MP3 recordings while excluding cache/backup folders.
- Remember the last selected practice and the last selected track per practice, with safe fallbacks.
- Play, pause, seek, scrub with keyboard shortcuts, and view cached waveforms.
- Zoom the waveform from 1x to 4x in 0.5x steps from the playback controls.
- Add point notes, ranged notes, and named song sections.
- Click notes, ranges, and sections to jump playback to the relevant time.
- Loop the selected song section.
- Show sections as a colored lane on the waveform timeline.
- Drag section starts/stops and add adjacent sections from the section lane.
- View notes for the selected track or the whole practice.
- Mark multiple recordings as Best Take.
- Apply remembered playback boosts up to +15 dB using cached processed audio.
- Mute the left channel, mute the right channel, or fold playback down to mono; processed playback is cached and remembered per recording.
- Select the Windows playback output device.
- Export processed tracks or selected clips as WAV or MP3.
- Convert WAV/WAVE recordings to MP3, replacing the source recording after a successful conversion.
- Open the Masters library, mark tracks/clips as masters, section master recordings, and run fuzzy fingerprint suggestions against practice folders.
- Use each take's fingerprint menu to inspect two-stage song/section match details, accept a guessed title/sections, teach the correct result, or mark the guess as unknown.
- Song section automation (auto-labeling from masters) is experimental and should be reviewed before saving.
- Quick title selection now also teaches the fingerprint system and clears the current guess from the take row.
- Manually sync a selected practice folder to/from a local Google Drive-style sync folder while excluding regenerable cache.
- Connect to a Google Drive account using a bundled app OAuth client, browse Drive folders, create a RiffNotes folder, and remember a remote sync root. Direct Drive upload/download is in progress.
- Clear generated cache for a selected practice from Preferences, including waveform, processed-audio, fingerprint cache, pending fingerprint suggestions, and fingerprint review state.
- Preserve portable metadata in the practice folder.
- Keep long-running work visible so the app does not appear frozen.

Kindle Fire / Android support is planned around playback, note review, note editing, and sync-oriented workflows. Windows remains the primary target for heavier audio-processing features.

## Repository status

This is active experimental software. It is useful for testing the workflow, but not yet a polished production release. Expect rough edges, UI churn, and missing features while the MVP gets shaped.

Fingerprint-driven section automation is also experimental. Auto-labeled sections should be treated as suggestions and verified by ear before finalizing.

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

## Release automation

Use `scripts/publish-release.ps1` to build the Windows release, zip the release folder, create or reuse a GitHub release, and upload the zip asset.

### Release runbook

1. Dry run (no build, no tag push, no release changes):

```powershell
.\scripts\publish-release.ps1 -DryRun
```

2. Full release using version from `pubspec.yaml`:

```powershell
.\scripts\publish-release.ps1
```

3. Re-run fast after a partial failure (skip rebuild):

```powershell
.\scripts\publish-release.ps1 -SkipBuild
```

4. Publish a prerelease:

```powershell
.\scripts\publish-release.ps1 -Prerelease
```

### Authentication and token precedence

The script uses tokens in this order:

1. `-Token <value>`
2. `GITHUB_TOKEN` environment variable
3. `gh auth token` (requires `gh` installed and logged in)

If `gh` is not installed or logged in, the script prints install/login guidance.

### Notes and inputs

- The script reads the version from `pubspec.yaml` unless `-Version` is provided.
- Release notes must exist at `docs/releases/vX.Y.Z.md` for the release tag being published.
- The repository defaults to the `origin` remote unless `-Repository owner/repo` is provided.

### Android build

```powershell
flutter build apk
```

Kindle Fire installation/testing depends on your local Android device setup and developer-mode configuration.

## Basic workflow

1. Choose the band folder. RiffNotes lists each direct subfolder as a practice, except generated cache/backup folders.
2. Open a practice. The app lists supported recordings and restores the last selected track for that practice when possible.
3. Listen first. Use the waveform transport to play, seek, zoom, boost volume, select output, or switch channel mode.
4. Add structure. Use the section lane to create named sections, drag edges into place, and loop a selected section while reviewing. Use the Masters library to mark sections on reference recordings.
5. Add notes. Point notes mark a single time; range notes describe a span of the performance.
6. Review the practice. The practice review view collects notes across all tracks and can jump directly to the referenced clip.
7. Apply housekeeping. Rename, mark Best Takes, convert WAV to MP3, export processed audio, sync, or run fingerprint matching when ready.

## Practice folder data

RiffNotes stores portable metadata beside the audio so a practice folder can be copied or synced as a unit.

- `.riffnotes.<user>.bandnotes` stores one user's annotations.
- `.riffnotes.<recording-id>.sections.json` stores song sections for one track.
- `library.riffnotes.json` stores the practice recording catalogue and take metadata.
- `.riffnotes-cache\` stores regenerable waveform, processed-audio, and fingerprint cache files.
- `Masters\` can live inside the band/practice area and contain reference recordings for fingerprint matching.

Cache folders are safe to exclude from backups and cloud sync.

## Product decisions

- A band folder contains practice folders; each practice folder contains audio and portable metadata.
- WAV and MP3 are supported.
- A recording has a stable ID, so renaming or WAV-to-MP3 replacement never detaches notes or sections.
- Per-user annotations use `.riffnotes.<user>.bandnotes` JSON files in the practice folder.
- Google Drive-style local-folder sync is manual per practice folder. Regenerable cache is excluded.
- Direct Google Drive account sync is being added in slices. See [docs/google-drive-setup.md](docs/google-drive-setup.md).
- Lengthy work is queued in background operations with progress and cancellation where safe.
- Heavy processing is Windows-first; the Android/Kindle path is intended to focus on playback, notes, sections, and sync.

See [docs/product-spec.md](docs/product-spec.md) for the current, prioritized specification.

## Notable planned work

- Continue refining section editing and waveform ergonomics.
- Improve bulk rename around the listen-first workflow.
- Harden fingerprint confidence scoring and review UX.
- Package a friendlier Windows installer/release bundle.
- Flesh out the Android/Kindle playback and note-review experience.
