# RiffNotes technical reference

Feature-by-feature reference for contributors (human or AI). Each entry states **what** it does, **where** it lives, **how** it works, and **why** it is built that way. The "why" matters more than the "how" here: most of this code is shaped by constraints that are not obvious from any single file.

Product priorities live in [product-spec.md](product-spec.md); commands and setup in the [README](../README.md); manual verification steps in [manual-test-plan.md](manual-test-plan.md).

---

## 0. The five invariants

Break any of these and something corrupts silently. Read this section before changing anything.

| # | Invariant | Why |
|---|---|---|
| I1 | **All cross-references use recording UUIDs, never filenames.** | Takes get renamed and WAV→MP3 converted constantly. Filename-keyed notes would detach on every rename. |
| I2 | **Practice metadata lives in the practice folder, never in an app database.** | Two bandmates work on separate computers and sync folders through Google Drive. A folder must be a self-contained, copyable unit. |
| I3 | **`library.riffnotes.json` is the root of trust.** Lose it and every recording gets a new UUID, orphaning every note and section. | It is the only filename→UUID map. Writes to it are the highest-risk operation in the app. |
| I4 | **Anything slower than ~200 ms runs through `ActivityQueue`.** | The app scans folders, shells out to FFmpeg, and moves gigabytes. A frozen window reads as a crash. |
| I5 | **Audio is never mutated in place.** Every transformation writes a new file or a cache entry. | Rehearsal recordings are irreplaceable. The only exceptions are explicit, confirmed, verified flows (§7.4, §7.5). |
| I6 | **Portable metadata is written atomically** via `writeFileAtomic`, never `writeAsString`. | A truncated `library.riffnotes.json` violates I3. |

**Architecture in one line:** `_LibraryScreenState` in `lib/main.dart` owns one instance of every repository and controller and drives the whole UI. Repositories are stateless classes doing filesystem and `Process` work; controllers are `ChangeNotifier`s. No state-management package.

**Adding a feature** normally means: new repository in its own `lib/*.dart` → new field on `_LibraryScreenState` → handler method → wire into `_RecordingList`, `_PlayerPanel`, or Preferences.

---

## 1. On-disk data model

Inside each practice folder:

| File | Scope | Contents |
|---|---|---|
| `library.riffnotes.json` | shared | Catalogue: `filename → {id, title, isBestTake, size, modifiedMs}` |
| `.riffnotes.<user>.bandnotes` | **per user** | One user's point and range annotations |
| `.riffnotes.<recording-id>.sections.json` | shared | Song sections for one track |
| `.riffnotes-cache/` | local only | Regenerable waveform, processed-audio, fingerprint caches |
| `mixed_Down/` | shared | Archived multitrack source folders after bulk mixdown |

**Why per-user notes:** avoids merges entirely — each person writes only their own file, everyone reads all files. **Known gap:** the catalogue and sections files are *not* per-user, so titles, Best Take, and sections are still last-writer-wins across machines. Newer-wins protection (§10) prevents an older copy from overwriting a newer one, but two people editing the same field between syncs will still resolve to one winner.

**Why `size` + `modifiedMs` in the catalogue:** `_findRenamedCatalogueEntry` re-attaches an entry to a renamed file by matching both, which is what preserves UUIDs (I1) when someone renames a take outside the app. It requires a *unique* match — ambiguity mints a new UUID rather than guessing wrong.

---

## 2. Library and discovery

**2.1 Band folder** — `_chooseBandFolder` / `_openBandFolder` → `PracticeRepository.discoverBandFolder`. Every direct subfolder is a practice, sorted name-descending so newest dates land on top. Persisted to `SharedPreferences`.

Exclusions are centralized in `domain.dart` (`ignoredPracticeFolderNames`): `.backup`, `.cache`, `.riffnotes-cache`, `cache`, `mixed_down`, `masters`, plus any dot-prefixed folder. *Adding a generated folder means updating `ignoredPracticeFolderNames` in `domain.dart` (practice discovery), `shouldSkipSyncPath` in `drive_folder_sync.dart` (both sync directions, shared), and `test/domain_test.dart`.*

**2.2 Practice open** — `PracticeRepository.openPractice`, the most load-bearing function in the codebase: load catalogue → list supported audio (`.wav .wave .mp3 .flac`) → per file, reuse entry by filename, else rename-detect by size+mtime, else mint a UUID → rewrite if changed. Entries whose audio is absent are **retained**, not pruned, so a partially synced machine cannot destroy the titles of takes it has not downloaded yet. It throws `CatalogueUnreadableException` rather than treating a damaged catalogue as empty.

**2.3 Selection memory** — `_selectPractice`, `_selectRecording`. Remembers band folder, last practice, and last recording *per practice*, falling back to the first take when the remembered one is gone. **Why:** you reopen the same practice across several review sessions.

**2.4 Folder watching** — `_watchSelectedFolder` → `_scheduleSelectedFolderRefresh` → `_refreshSelectedFolderFromDisk`. Debounced, because a single file copy fires dozens of filesystem events.

**2.5 Reviewed flag** — `_togglePracticeReviewed`, stored per-user in `SharedPreferences`, deliberately **not** in the practice folder. **Why:** "have I listened to this yet" is personal state, not band state, so it must not sync.

---

## 3. Playback

**3.1 Transport** — `AudioController` (`audio_controller.dart`) wraps a media_kit `Player`, republishing position, duration, playing, devices, and errors as `ChangeNotifier` state. `AudioController.inert()` is a no-op constructor used by `RiffNotesApp(disableAudio: true)`. **Why:** widget tests must run without media_kit's native libraries. Any new audio path must respect that flag.

**3.2 Keyboard** — `_handleWaveformKey`: `Space` play/pause, `←`/`→` seek ∓5 s, `Delete`/`Backspace` delete selected section, `Ctrl+Z` undo section edit.

**3.3 Processed playback** — `_setPlaybackProcessing` → `AudioProcessingRepository.createPlaybackFile`. Boost (0 to +15 dB), mute-left, mute-right, and mono fold-down are **rendered by FFmpeg into a cache file**, not applied live:

```
.riffnotes-cache/<id>-<mode>-gain-<db>.wav
```

**Why a file:** media_kit has no reliable cross-platform filter graph, and rendering once makes repeat playback instant. **The filename is the cache key** — the function returns the original file untouched when no processing is needed, and returns the existing cache file when present. Settings are remembered per recording.

**3.4 Output device** — `_setAudioOutputDevice` / `_applyPreferredAudioOutputIfPossible`. The remembered device is re-applied whenever it reappears. **Why:** review happens on monitors or an interface, not default laptop speakers.

**3.5 Range and section looping** — `AudioController` holds a range timer that re-seeks at the range end: range notes play once, sections loop.

---

## 4. Waveform

**4.1 Generation** — `WaveformRepository.loadOrGenerate`: FFmpeg decodes to 8 kHz mono `s16le` on stdout, reduced to normalized peaks, cached at `.riffnotes-cache/<id>.waveform.json` (`_cacheVersion = 2`, invalidated by version plus source size/mtime). **Why 8 kHz mono:** a peak envelope needs amplitude, not fidelity.

**4.2 Rendering** — `waveform_view.dart`: `WaveformView` + `_WaveformPainter` (a `CustomPainter`), with `SectionTimeline` as a separate lane above. Zoom 1×–4× in 0.5× steps. **Why a painter:** thousands of peaks as widgets would be unusable.

**4.3 Section lane** — `SectionTimeline` handles click-to-seek, edge dragging (`_SectionResizeHandle`), create-from-gap, split, merge, colour assignment, and a context menu. Resize gestures bracket with `_startSectionResizeGesture` / `_endSectionResizeGesture` and log at a throttled rate so dragging doesn't flood the log.

---

## 5. Sections

`SongSection` + `SongSectionRepository` (`sections.dart`), stored per recording at `.riffnotes.<recording-id>.sections.json`.

| Operation | Handler |
|---|---|
| Add at playhead | `_startSection` → `_addSection` |
| Add from lane gap | `_addSectionRangeFromLane` |
| Split at time | `_splitSectionAt` |
| Resize edge | `_resizeSection` |
| Merge adjacent | `_mergeSections` |
| Edit label / colour | `_editSection` |
| Nudge boundaries | `_adjustSection` |
| Delete | `_deleteSection` |
| Auto-assign colours | `_autoAssignSectionColors` |
| Undo | `_undoLastSectionEdit` |

**Undo model:** `_sectionUndoStack` holds whole section-list snapshots pushed by `_rememberSectionUndo` before each mutation. **Why snapshots, not a command log:** section lists are small and edits come in rapid drag-bursts; snapshots are trivially correct and cheap. Session-only, not persisted.

Colours come from `sectionPalette` in `waveform_view.dart`.

---

## 6. Notes

`PracticeAnnotation` + `AnnotationRepository` (`annotations.dart`).

- **Point note** — comment at one timestamp (`endMs == null`).
- **Range note** — comment spanning `startMs`→`endMs`; clicking plays exactly that span.

Range capture is two-step: `_startRangeNote` marks the start, the next action closes it (`_addRangeAnnotation`). `_rangeRecordingId` guards against the user switching tracks mid-capture.

Stored at `.riffnotes.<user>.bandnotes` with `<user>` sanitized to `[a-zA-Z0-9_-]`. `loadAll` discovers every user's file by regex, so everyone sees everyone's notes. Display name is editable in Preferences, defaulting to the Windows login.

**Why notes and sections are separate:** a note is an opinion ("bass rushes here"); a section is structure ("Chorus"). Conflating them made the review list unusable.

**6.1 Practice review** — `_refreshPracticeReview` / `_showPracticeReview` collects notes across every track, filterable by user and track, sortable via `_ReviewSort`. `_playReviewNote` jumps playback to the referenced clip, switching tracks if needed. **Why:** the payoff of note-taking is the cross-track read-back, not the individual note.

---

## 7. Take management

**7.1 Title and Best Take** — `_editTitle`, `_quickSetRecordingTitle`, `_updateRecording` → `PracticeRepository.updateRecording`. **Quick titles** (`_quickSongTitlesForPractice`) offer one-click reuse of titles already used in this practice. **Why:** a rehearsal is the same handful of songs played repeatedly, so this is the single most repeated action in the app. Choosing a quick title also teaches the fingerprint system (§9.6). **Best Take is multi-select** — a practice usually yields several keepers for different reasons.

**7.2 Batch rename** — `_previewAndApplyRename` → `planRename` / `applyRename`. Target pattern `##_Title_Take#.<ext>`: sequence across the practice, take number per title. `planRename` flags `Duplicate target name` and `A different file already uses this name`; `applyRename` refuses to run while any remain. Execution is **two-phase** — every file renames to `.riffnotes-rename-<id>-<micros>` first, then to its target. **Why:** single-phase renaming breaks on cycles (`A→B`, `B→A`). The original catalogue JSON is held for rollback.

**7.3 Delete take** — `_deleteTake` → `deleteRecording`. Confirmed; removes file and catalogue entry. Notes and sections for that UUID are left behind (harmless, and recoverable if the file returns).

**7.4 Convert to MP3** — `_convertSelectedRecordingToMp3` → `convertRecordingToMp3` (libmp3lame `-q:a 2`). Flow: refuse if the target exists → confirm → stop playback → encode → verify → delete original → `replaceRecordingFile` remaps the catalogue entry **keeping the same UUID** (I1). *Verification is currently exit code + non-zero length only (§11).*

**7.5 Bulk multitrack mixdown** — `_refreshBulkMixDownAvailability` detects numerically-named subfolders (`12/`) holding multiple tracks; the button only appears when they exist. `_bulkMixDownNumericMultitrackFolders` mixes each to `<number>.wav` in the practice root via `mixDownTracksToStereo` (`amix=inputs=N:duration=longest:normalize=0,alimiter=limit=0.95`), then archives the source folder to `mixed_Down/`.

**Why `normalize=0` plus a limiter:** FFmpeg's `amix` divides by input count by default, making a 6-track mix inaudibly quiet; disabling that and catching peaks with a limiter preserves level. **Order matters:** mix first, archive only on success; skip (never overwrite) if the output exists.

**7.6 Export** — `_exportAudio` → `exportAudio`. Whole track or selected section, WAV or MP3, **with the current boost and channel mode applied**. Filename from `_exportBaseName` (title + section label, sanitized against Windows-illegal characters). **Why apply processing:** the clip is for sending to a bandmate, so it should sound like what you were listening to.

---

## 8. Masters library

`_selectMastersLibrary`, `_loadMastersPractice`, `_refreshMastersList`. The Masters folder (default `<band folder>/Masters`, overridable, may be relative) is opened with the same `PracticeRepository`, so masters are just recordings with sections. It appears as a pseudo-practice flagged by `_selectedIsMasters`, which disables sync and fingerprint actions for it.

`_saveRecordingAsMaster` / `_saveSectionAsMaster` copy a take or section clip in. **Why sections-as-masters:** matching a 20-second chorus against a chorus reference is far more reliable than against a whole song.

---

## 9. Fingerprint matching

`fingerprints.dart`, ~2.4k lines. **Everything it produces is a suggestion requiring review — never auto-apply.**

**9.1 Feature extraction** — `calculateAudioFingerprint`. FFmpeg → 4 kHz mono `s16le` → 200 ms non-overlapping windows (`_windowSamples = 800`). Per window:

| Feature | Meaning |
|---|---|
| `energy` | mean absolute amplitude |
| `zeroCrossing` | sign changes per sample — rough brightness |
| `attack` | positive energy delta vs previous window — transient density |
| `lowMotion` | mean abs of a one-pole smoothed signal (α = .08) — low-frequency movement |
| `highMotion` | mean abs first difference — high-frequency movement |
| `peaks` | fraction of samples ≥ .62 — hit/clip density |
| `chroma0..11` | Goertzel magnitude at MIDI 40–83 folded to 12 pitch classes, per-window max-normalized |

Envelope features are globally min-max normalized; chroma is not. Cached at `.riffnotes-cache/<id>.fingerprint.json`, invalidated by `_cacheVersion` (4), `_cacheAlgorithm`, sample rate, window size, and source size/mtime. **Bump `_cacheVersion` and `_cacheAlgorithm` whenever extraction changes**, or stale caches are silently reused.

Heavy work runs in `Isolate.run` (`matchPracticeInBackground`, `loadOrGenerateFingerprint`) — multi-second CPU-bound work that would otherwise violate I4.

**9.2 Similarity** — `_similarity` → `_similarityAtCurrentTempo` → `_windowSimilarity`. Score is `1 − mean|Δ|` per feature, weighted, lag-scanned (coarse step then refine) across 5 fixed tempo scales (0.92–1.08). Final confidence is `0.9 × best + 0.1 × durationRatio`. *Read §11 (B7, B8) before tuning weights.*

**9.3 Two-stage matching** — `matchPractice` builds song targets (whole masters) and section targets (master sections ≥ 8 windows), matching song-level first, then sections within the winning song. **Why two stages:** a take usually contains one song; identifying it first shrinks the section search space and lets section results inherit song confidence as a sanity gate. `_isJamRecording` excludes jams from both sides.

**9.4 Actionability gates** — `isActionableSuggestion` / `actionabilitySummary`. A song match must clear confidence ≥ .84, margin ≥ .03, raw confidence ≥ .82, chroma agreement ≥ .50, and a tempo-drift rule; a section match .84 / .03, song confidence ≥ .80, chroma agreement ≥ .45. **Why gates rather than one score:** the score has poor dynamic range, so several independent conditions are the practical way to suppress confident-looking nonsense. `actionabilitySummary` exists so the UI can say *which* gate failed.

**9.5 Review UI** — `_matchSelectedPracticeFingerprints`, `_showFingerprintInfoForRecording`, `_acceptFingerprintMatch`, `_acceptBestFingerprintGuessForRecording`, `_ignoreFingerprintMatch`, `_dontKnowFingerprintForRecording`, `_clearFingerprintGuessForRecording`. Accept applies the title and optionally the master's sections via `_applyMasterSectionsForAcceptedMatch`.

**9.6 Learning and corrections** — four repositories persist separately: `FingerprintSuggestionRepository` (pending guesses), `FingerprintDecisionRepository` (accepted/ignored), `FingerprintLearningRepository` (examples from accepts/ignores), `FingerprintCorrectionRepository` (explicit corrections, via `_teachFingerprintCorrectionForRecording`). **Why four:** a suggestion, a decision, a learned example, and a correction have different lifetimes; merging them made clearing one wipe the others.

**9.7 Section auto-labelling (experimental)** — `_labelSectionsFromSelectedSong`, `_bulkLabelSectionsForSelectedPractice`, `_applyLabeledSections` copy a master's section layout onto a matched take. **Verify by ear before saving.**

**9.8 Tuning and evaluation** — `_showFingerprintFeatureChartDialog`, `_buildFingerprintFeatureChartData`, `_exportFingerprintFeatureChartSnapshot`, `_buildFingerprintEvaluationReport`, `_evaluateFingerprintCorrections`, `_reEvaluateFingerprintWeightsFromHistory`, `_applyFingerprintWeightProfile`, `_saveFingerprintWeightProfile`. Weights persist to `fingerprint_feature_weights`. **Note:** weights are hand-tuned against no held-out labelled set. Establish one first, or changes are unmeasurable.

---

## 10. Sync

Two independent implementations with matching semantics.

**10.1 Local folder** — `sync.dart`: `uploadPractice`, `uploadPracticeSelection`, `downloadPractice`, `syncFolderContents`, all funnelling into `_copyPractice`. Recursive copy using the shared `shouldSkipSyncPath`. `changedOnly` compares size + mtime, and after copying calls `setLastModified` from the source so the comparison converges next run. `deleteMissingFiles` prunes the target and removes empty directories. `listUploadCandidates` powers the pre-upload picker so the user sees exactly what will move.

**10.2 Google Drive** — split across three files so the algorithms are testable: `drive_file_store.dart` (the `DriveFileStore` interface), `drive_api_file_store.dart` (the Drive API adapter), and `drive_folder_sync.dart` (`DriveFolderSync`, the upload/download algorithms). `google_drive_sync.dart` keeps OAuth and delegates. Tests drive `DriveFolderSync` against `FakeDriveFileStore` with no network.

OAuth via loopback redirect with PKCE and state validation (`_clientViaRiffNotesBrowserFlow`), using the bundled client in `assets/google_oauth.json` (overridable in Preferences). Credentials persist to `SharedPreferences`; `credentialUpdates` re-saves refreshed tokens.

`uploadLocalFolder` / `downloadFolderToLocal` mirror the local semantics against the Drive API: paginated recursive listing (`_listChildren`), idempotent folder creation (`_ensureChildFolder`, `_ensureDriveFolderPath`), the same skip list, same flags. `includeLocalRootFolder: false` lets Initialize Sync operate on the band folder as a whole.

**Change detection** (`sync_policy.dart`): size plus modification time within `syncTimestampTolerance` (2 s). Exact equality is unusable because exFAT rounds to 2 s and Drive reports milliseconds while NTFS stores 100 ns ticks.

**Newer-wins:** downloads skip a file whose local copy is newer than the remote by more than the tolerance, and report the count. Pass `overwriteNewerLocalFiles: true` to force a restore. Uploads are not protected this way — the pre-upload picker already shows exactly what will move.

**Blast radius:** `_initializeSyncDrive` runs these primitives over the *entire* band folder. It is the most dangerous action in the app — direction and `deleteMissingFiles` must both be right.

---

## 11. Defect status

Findings from the v0.6.10 audit; fixes shipped in v0.6.11. Fixed items list the change so the reasoning is not lost.

### Fixed

| ID | Change |
|---|---|
| B1 | `_loadCatalogue` now throws `CatalogueUnreadableException` instead of returning `{}`. The damaged file is left on disk, the practice is listed but not openable, and `discoverBandFolder` catches per folder so one bad practice cannot take down the whole band folder. |
| B2 | All three metadata writers go through `writeFileAtomic` (`atomic_file.dart`): temp file, then rename over the target. |
| B3 | `openPractice` retains catalogue entries whose audio is absent. Only `deleteRecording` prunes. Protects titles on partially synced machines. |
| B4 | Drive upload writes the local modification time through to the remote store, so change detection converges. Enforced by the `DriveFileStore` interface, which makes `modifiedTime` a required argument. |
| B5 | Downloads skip files whose local copy is newer than the remote by more than `syncTimestampTolerance`, in both sync implementations. Override with `overwriteNewerLocalFiles`. The count is reported in the sync summary. |
| B6 | The stale actionability test is replaced by a group that trips each gate independently. |
| B7 | The configured chroma weight is divided across the twelve bins, so the knob means what it says. **Existing tuned weight profiles were fitted against the old 12x behaviour and should be re-evaluated.** |
| B9 | `mixed_Down` is excluded from sync, via one `shouldSkipSyncPath` now shared by both implementations. |
| B12 | Downloads stream to a temp file and rename into place, so an interrupted download leaves no truncated file. |

### Open

| ID | Area | Defect |
|---|---|---|
| B8 | `fingerprints.dart::_sliceFingerprint` | Slices inherit the parent track's global min-max normalization, so section comparisons are scale-mismatched. Fixing this changes match scores, so it needs the labelled evaluation set first. |
| B10 | `google_drive_sync.dart:8` | Imports `package:googleapis_auth/src/...` (private). Left in place deliberately: replacing it means reimplementing the PKCE auth-code flow, and OAuth has no test coverage to catch a regression. Pin `googleapis_auth` and revisit with the auth flow under test. |
| B11 | -- | `product-spec.md` item 22 claims backup-before-destructive; no backup code exists. Either implement or drop the claim. |
| B13 | `app_preferences.dart` | Drive refresh token stored in plaintext `SharedPreferences`. |
| B14 | `drive_api_file_store.dart` | Drive permits duplicate names in one folder; the relative-path map keeps only the last. |

### Verification status

`DriveFolderSync` is covered by `test/drive_folder_sync_test.dart` against `FakeDriveFileStore`.
`DriveApiFileStore` -- the adapter that actually talks to Google -- has **no automated coverage**.
The B4 fix depends on the Drive API honouring a supplied `modifiedTime`, which has not been
confirmed against a live account. Verify manually with step 6 of
[manual-test-plan.md](manual-test-plan.md): sync a practice twice and check that the second run
reports 0 copied.

## 12. Cross-cutting rules

1. **Wrap long work** in `_activity.run` / `runCancellable`; report progress and honour cancellation.
2. **Log through `AppLog`** with a category (`'sync'`, `'fingerprint'`) — users read this when reporting problems, and messages are copyable.
3. **Repositories return new value objects** (`copyWith`); the screen re-assigns in `setState`.
4. **Confirm every destructive action** with a dialog naming the exact files affected.
5. **Guard `BuildContext` across async gaps** with `mounted`.
6. **Respect `disableAudio`** in any new playback path so widget tests keep running.
7. **Tests use real temp directories** (`Directory.systemTemp.createTemp` + `addTearDown`), not mocks — filesystem behaviour is what's worth testing here.
8. **Keep the four exclusion lists in sync** when adding generated folders (§2.1).
9. **Bump the fingerprint cache constants** when extraction changes (§9.1).
10. **Write portable metadata with `writeFileAtomic`**, never `File.writeAsString` (I6).
11. **New remote operations go on `DriveFileStore`**, not directly on `drive.DriveApi`, so sync stays testable.
