# RiffNotes product specification

## Product goal

Make band-practice review fast: identify takes, listen, annotate, share notes, preserve great recordings, and complete repeated housekeeping without making the user wait at a frozen screen.

## Platforms

- **Windows:** full application, shipped as a standalone executable.
- **Kindle Fire 10 (Android):** playback, waveform, note/section viewing and editing, and Google Drive sync.
- Local review is fully offline. Only explicit Google Drive operations use the network.

## Current implemented scope

1. A user selects a Band Folder and sees its direct subfolders as practices.
2. Opening a practice lists WAV and MP3 recordings (typical maximum: 40 takes) while excluding cache and backup folders.
3. The app remembers the band folder, last practice, and last selected recording per practice, with safe fallbacks when files move or disappear.
4. The user can play, pause, seek, zoom, and view a cached waveform.
5. The playback controls support volume boost up to +15 dB, left/right mute, mono fold-down, and Windows output-device selection.
6. Processed playback is cached and remembered per recording where appropriate.
7. A recording can be given a song title and safely renamed to `##SongName_Take#`.
8. The user can create point annotations and range annotations (a note with a start/end span), plus named sections.
9. Notes and sections are clickable playback targets. Range notes play the selected range; sections can jump to start and loop.
10. Sections are shown in their own lane on the waveform and can be added/adjusted from that lane.
11. Best Take is a multi-select flag, not a single winner.
12. Each user has an independent portable note file; all discovered users' notes are readable.
13. The practice review view shows notes across the selected practice and can jump playback to the referenced clip.
14. The user can export selected regions or processed tracks as WAV or MP3.
15. WAV/WAVE recordings can be converted to MP3 via FFmpeg; after a successful conversion the recording mapping is updated.
16. The user can select a Masters folder, copy tracks/clips into it as masters, section masters, and run fuzzy fingerprint matching against selected practice folders.
17. Fingerprint suggestions include confidence and require user review before applying or ignoring. Teaching a correction or choosing a quick remembered title clears the current guess from the take row. Song section automation is experimental and should be treated as suggested structure.
18. Manual Google Drive-style sync copies a selected practice folder to/from a local sync folder while excluding regenerable cache.
19. The UI remains interactive during scanning, waveform generation, conversion, matching, export, and sync. Each task gives a name, status, measurable progress when available, and a completion/failure result.
20. Preferences persist, including the Windows-login-derived user name, editable display name, Band Folder, Masters folder, selected sync folder, and playback settings.
21. Metadata survives rename/conversion flows and is backed up before destructive operations where applicable.

## Next refinement areas

- Make the bulk rename flow smoother after playback-based review.
- Improve section editing speed for adjacent sections and dense song structures.
- Improve waveform zoom, hover, and selection feedback based on real rehearsal files.
- Strengthen fingerprint confidence scoring, section-level matching, and review/apply ergonomics.
- Package a friendlier Windows release/installer.
- Complete the Android/Kindle playback, note, section, and sync workflow.

## Portable practice metadata

`library.riffnotes.json` contains the recordings catalogue, aliases, and Best Take state. User annotations are JSON content in files named `.riffnotes.<user>.bandnotes`. Track sections are stored in `.riffnotes.<recording-id>.sections.json` files so section edits stay portable with the practice folder.

Each recording has a generated UUID and current filename. All cross-references use UUIDs, never filenames.

### Annotation types

- **Point annotation:** a comment at one playback time.
- **Range annotation:** a comment that applies from a selected start time through an end time; it is not a song-structure label.
- **Section:** a separate structural marker such as verse, chorus, bridge, or outro, intended for later reference and navigation.
