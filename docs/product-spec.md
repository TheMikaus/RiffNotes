# RiffNotes product specification

## Product goal

Make band-practice review fast: identify takes, listen, annotate, share notes, preserve great recordings, and complete repeated housekeeping without making the user wait at a frozen screen.

## Platforms

- **Windows:** full application, shipped as a standalone executable.
- **Kindle Fire 10 (Android):** playback, waveform, note/section viewing and editing, and Google Drive sync.
- Local review is fully offline. Only explicit Google Drive operations use the network.

## Current implemented scope

1. A user selects a Band Folder and sees its direct subfolders as practices.
2. Opening a practice lists WAV/WAVE, MP3, and FLAC recordings (typical maximum: 40 takes) while excluding cache and backup folders.
3. The app remembers the band folder, last practice, and last selected recording per practice, with safe fallbacks when files move or disappear.
4. The user can play, pause, seek, zoom, and view a cached waveform.
5. The playback controls support volume boost up to +15 dB, left/right mute, mono fold-down, and Windows output-device selection.
6. Processed playback is cached and remembered per recording where appropriate.
7. A recording can be given a song title and safely renamed to `##SongName_Take#`.
8. The user can create point annotations and range annotations (a note with a start/end span), plus named sections.
9. Notes and sections are clickable playback targets. Range notes play the selected range; sections can jump to start and loop.
10. Sections are shown in their own lane on the waveform and can be added/adjusted from that lane.
11. Best Take is a multi-select flag, not a single winner.
12. Each user has independent portable files for notes, titles/Best Take, and section layouts; all discovered users' files are readable and merged on read. Two machines never write the same file.
13. The practice review view shows notes across the selected practice and can jump playback to the referenced clip.
14. The user can export selected regions or processed tracks as WAV or MP3.
15. WAV/WAVE/FLAC recordings can be converted to MP3 via FFmpeg; after a successful conversion the recording mapping is updated.
16. The user can select a Masters folder, copy tracks/clips into it as masters, section masters, and run fuzzy fingerprint matching against selected practice folders.
17. Fingerprint suggestions include confidence and require user review before applying or ignoring. Teaching a correction or choosing a quick remembered title clears the current guess from the take row. Song section automation is experimental and should be treated as suggested structure.
18. Manual Google Drive-style sync copies a selected practice folder to/from a local sync folder while excluding regenerable cache.
19. Direct Google Drive sync is available for selected practices and Initialize Sync. The user can choose between the Drive API and a local mirror path when initializing sync.
20. The UI remains interactive during scanning, waveform generation, conversion, matching, export, and sync. Each task gives a name, live status, measurable progress when available, and a completion/failure result. Sync operations support cancellation.
21. Preferences persist, including the Windows-login-derived user name, editable display name, Band Folder, Masters folder, selected sync folder, and playback settings.
22. Metadata survives rename/conversion flows. Portable metadata files are written atomically (temp file, then rename) so an interrupted write cannot truncate them, and a metadata file that fails to parse is quarantined with its bytes intact rather than overwritten. There is no separate backup step before destructive operations.
23. If a selected practice contains numbered multitrack folders (for example `12/` with multiple tracks), the user can preview a bulk mixdown, create stereo `12.wav` outputs in the practice root, and archive the source folders to `mixed_Down`.

## Next refinement areas

- Make the bulk rename flow smoother after playback-based review.
- Improve section editing speed for adjacent sections and dense song structures.
- Improve waveform zoom, hover, and selection feedback based on real rehearsal files.
- Strengthen fingerprint confidence scoring, section-level matching, and review/apply ergonomics.
- Package a friendlier Windows release/installer.
- Complete the Android/Kindle playback, note, section, and sync workflow.

## Portable practice metadata

`library.riffnotes.json` maps each audio filename to a stable recording id. Everything a user edits is per user: titles and Best Take in `.riffnotes.<user>.catalogue.json` (newest title wins; Best Take is true if anyone starred it), annotations in `.riffnotes.<user>.bandnotes`, and section layouts in `.riffnotes.<recording-id>.sections.<user>.json` (most recently saved layout wins; edits start from it). Legacy `title`/`isBestTake` fields and `.riffnotes.<recording-id>.sections.json` files written before v0.7.0 are still read, never rewritten. See `technical-reference.md` §1 for the merge rules.

Each recording has a generated UUID and current filename. All cross-references use UUIDs, never filenames.

### Annotation types

- **Point annotation:** a comment at one playback time.
- **Range annotation:** a comment that applies from a selected start time through an end time; it is not a song-structure label.
- **Section:** a separate structural marker such as verse, chorus, bridge, or outro, intended for later reference and navigation.
