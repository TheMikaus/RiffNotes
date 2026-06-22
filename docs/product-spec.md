# RiffNotes product specification

## Product goal

Make band-practice review fast: identify takes, listen, annotate, share notes, preserve great recordings, and complete repeated housekeeping without making the user wait at a frozen screen.

## Platforms

- **Windows:** full application, shipped as a standalone executable.
- **Kindle Fire 10 (Android):** playback, waveform, note/section viewing and editing, and Google Drive sync.
- Local review is fully offline. Only explicit Google Drive operations use the network.

## MVP acceptance criteria

1. A user selects a Band Folder and sees its direct subfolders as practices.
2. Opening a practice lists WAV and MP3 recordings (typical maximum: 40 takes).
3. The user can play, pause, seek, and view a waveform.
4. A recording can be given a song title and safely renamed to `##SongName_Take#`.
5. The user can create timestamped annotations and named sections.
6. Best Take is a multi-select flag, not a single winner.
7. Each user has an independent portable note file; all discovered users' notes are readable.
8. The UI remains interactive during scanning, waveform generation, conversion, matching, export, and sync. Each task gives a name, status, measurable progress when available, and a completion/failure result.
9. Preferences persist, including the Windows-login-derived user name, editable display name, Band Folder, and playback settings.
10. Metadata survives a rename and is backed up before a destructive operation.

## Phases after MVP

### Phase 2: review power tools

- Left/right channel mute, mono fold-down, volume boost.
- Export selected regions and processed audio as user-selected WAV or MP3.
- WAV-to-MP3 conversion via FFmpeg. Conversion verifies the result before deleting the original WAV and updates the stable recording mapping transactionally.
- Windows audio-output selection.

### Phase 3: Windows fingerprint matching

- Fuzzy matching against reference audio, previous takes, and named sections.
- Suggestions include confidence and always require user confirmation.
- An unknown/new musical idea remains explicitly unmatched.

### Phase 4: Google Drive collaboration

- Explicit upload/download for one practice folder at a time.
- Sync audio, `.bandnotes` user files, and portable metadata; exclude cache and local backup by default.
- Show remote/local changes before applying them and avoid silent overwrites.

## Portable practice metadata

`library.riffnotes.json` contains the recordings catalogue, sections, aliases, and Best Take state. User annotations are JSON content in files named `.riffnotes.<user>.bandnotes`.

Each recording has a generated UUID and current filename. All cross-references use UUIDs, never filenames.

