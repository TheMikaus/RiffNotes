# RiffNotes

An offline-first practice-review tool for bands. RiffNotes is being built as a shared Flutter application for Windows and Kindle Fire (Android), with Windows-only fingerprint matching and audio-processing work.

## Current milestone

The repository contains the first vertical slice: select a band folder, discover practice folders and WAV/MP3 takes, display the library, and show visible background activity. The UI is intentionally wired around responsive operations from day one.

## Run locally

Install the [Flutter SDK](https://docs.flutter.dev/get-started/install/windows/desktop), then run:

```powershell
flutter pub get
flutter run -d windows
```

Android/Kindle Fire development requires an Android SDK and a physical device or emulator. The Kindle app will use the same UI and metadata model, but Windows-only features (fingerprinting, audio output selection, conversion) will be unavailable there.

## Product decisions

- A band folder contains practice folders; each practice folder contains audio and portable metadata.
- WAV and MP3 are supported.
- A recording has a stable ID, so renaming or WAV-to-MP3 replacement never detaches notes or sections.
- Per-user annotations use `.riffnotes.<user>.bandnotes` JSON files in the practice folder.
- Google Drive sync is manual per practice folder. Regenerable cache is excluded.
- Lengthy work is queued in background operations with progress and cancellation where safe.

See [docs/product-spec.md](docs/product-spec.md) for the current, prioritized specification.

