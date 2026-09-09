# Manual test plan — v0.6.11 data-safety release

Verifies the changes that automated tests cannot reach: real Google Drive behaviour, and the write
paths against a real practice folder.

**Before you start**

1. Work on a **copy** of one practice folder, not your live band folder. Several steps deliberately
   damage files.
   ```powershell
   Copy-Item -Recurse "D:\Band\2026-07-22" "D:\Band-Test\2026-07-22"
   ```
2. Point RiffNotes at `D:\Band-Test` with **Band Folder**.
3. Keep the log viewer (toolbar, document icon) open — several checks read it.

Each step lists **Do**, **Expect**, and **Fails if**. A "Fails if" outcome means stop and report it.

---

## 1. Baseline — nothing regressed

| | |
|---|---|
| **Do** | Launch the app. Select a practice. Select a take. Let the waveform load. Press Space, then `←` and `→`. |
| **Expect** | Practice list populates, waveform renders, playback starts and seeks by 5 s. |
| **Fails if** | Any practice shows "Cannot be opened", or the take list is empty for a folder that has audio. |

---

## 2. Atomic writes (B2)

| | |
|---|---|
| **Do** | Add a point note to a take. Then in the practice folder run: `Get-ChildItem D:\Band-Test\2026-07-22 -Filter *.tmp` |
| **Expect** | The note appears. **No `.tmp` files exist.** |
| **Fails if** | A `.riffnotes.<user>.bandnotes.tmp` or `library.riffnotes.json.tmp` is left behind — the rename step is not completing. |

Repeat with a section edit and a title change; each writes a different file.

---

## 3. Unreadable catalogue is refused, not overwritten (B1)

This is the most important check. It is the failure that used to destroy notes silently.

| | |
|---|---|
| **Do** | Close the app. Truncate the catalogue: <br>`Set-Content D:\Band-Test\2026-07-22\library.riffnotes.json '{"recordings": {"0001.wav"'` <br>Relaunch and look at the practice list. |
| **Expect** | The practice is **listed** with a red error icon and "Cannot be opened — the file is not valid JSON…". Clicking it shows a copyable error and does **not** select it. |
| **Fails if** | The practice opens normally with takes listed — that means the catalogue was treated as empty and re-keyed. |

**Then confirm nothing was written over the damage:**

| | |
|---|---|
| **Do** | `Get-Content D:\Band-Test\2026-07-22\library.riffnotes.json` |
| **Expect** | Still the truncated text you wrote. Byte-for-byte unchanged. |
| **Fails if** | It now contains a full valid catalogue — the app overwrote your only recovery path. |

**Then confirm recovery works:**

| | |
|---|---|
| **Do** | Restore the file from your copy. Relaunch. Open the practice and check a take that had notes. |
| **Expect** | The practice opens; notes and sections are still attached to their takes. |

**Then confirm one bad folder does not break the rest:**

| | |
|---|---|
| **Do** | Damage the catalogue in one practice again, relaunch, and look at the other practices. |
| **Expect** | Every other practice loads and opens normally. |
| **Fails if** | The whole band folder fails to load, or the list is empty. |

---

## 4. Absent takes keep their titles (B3)

Simulates a machine that has the metadata but not all the audio.

| | |
|---|---|
| **Do** | Title a take (e.g. "Dead Reckoning") and mark it Best Take. Close the app. Move that `.wav` out of the folder. Relaunch and open the practice. |
| **Expect** | The take is **not** listed (its audio is gone). |
| **Do** | Inspect the catalogue: `Select-String -Path D:\Band-Test\2026-07-22\library.riffnotes.json -Pattern "Dead Reckoning"` |
| **Expect** | **The entry is still there, with its title.** |
| **Fails if** | No match — the entry was pruned, which is what used to destroy titles on partial syncs. |
| **Do** | Move the `.wav` back. Relaunch. |
| **Expect** | The take reappears with "Dead Reckoning" and Best Take still set. |

---

## 5. Delete still prunes

Confirms step 4 did not make deletion leaky.

| | |
|---|---|
| **Do** | Delete a take through the app (trash icon, confirm). Inspect the catalogue for its filename. |
| **Expect** | The entry is gone. |

---

## 6. Google Drive upload converges (B4) — the one that needs a live account

**This is the check I could not run.** It depends on the Drive API honouring the `modifiedTime` we
now send.

| | |
|---|---|
| **Do** | Select the test practice. Upload to Drive. Note the "copied" count. |
| **Expect** | All selected files copied. |
| **Do** | **Without changing anything**, upload the same practice again. Read the result line. |
| **Expect** | **`0 copied`**, and the rest reported as skipped. |
| **Fails if** | The second run copies everything again. That means Drive is overriding the timestamp we send, and the fix needs a different change key (a content hash or an app property). **Report the exact copied count.** |

Also check the log for `sync.drive.upload done … skipUnchanged=N` with N equal to your file count.

---

## 7. Download protects newer local edits (B5)

| | |
|---|---|
| **Do** | With the practice already uploaded, add a note locally (this makes the local `.bandnotes` newer than the Drive copy). Now **download** the practice from Drive. |
| **Expect** | Your note is **still there**. The summary includes "Kept 1 newer local file instead of overwriting." |
| **Fails if** | The note is gone — the newer-wins guard is not firing. |

| | |
|---|---|
| **Do** | Check the log for `sync.drive.download … skipLocalNewer=1` and the "kept newer local copies" line naming the file. |
| **Expect** | Both present. |

---

## 8. Download leaves no partial files

| | |
|---|---|
| **Do** | Download a practice. Then: `Get-ChildItem D:\Band-Test\2026-07-22 -Filter *.tmp -Recurse` |
| **Expect** | Nothing. |

---

## 9. `mixed_Down` is not uploaded (B9)

| | |
|---|---|
| **Do** | Use a practice that has a `mixed_Down` folder (or create one with a dummy file). Open the upload dialog and read the file list. |
| **Expect** | No path under `mixed_Down/` appears as a candidate. |
| **Fails if** | Multitrack sources are listed — they would be uploaded to Drive. |

---

## 10. Fingerprint chroma weighting A/B (B7)

**This is a measurement, not a pass/fail step, and the fix may be a regression.** Read the reasoning
before running it.

`_featureWeight` used to return the configured chroma weight for *each* of the twelve pitch-class
bins, so the chroma group summed to twelve times the configured value. With the default profile that
made chroma about **28%** of the score — the largest single group, and the opposite of what the
comment above it claimed. It is now divided across the bins, which drops the chroma group to about
**3.2%**.

That makes the code match its stated intent. Whether the stated intent is *correct* is a separate
question, and there is reason to doubt it: chroma is the feature that carries song identity
(harmony and melody), while energy, zero-crossing, attack, and peaks largely describe the loudness
envelope, which is dominated by mic placement, room, and how hard the band played that night. The
accidental 28% may well have matched better than the documented 3.2%.

Setting the chroma weight to **`1.44`** reproduces the old scoring exactly (1.44 ÷ 12 = 0.12 per
bin, the previous per-bin value), which gives a clean comparison.

**Do not clear anything first.** Feature extraction is unchanged, so the cached fingerprints under
`.riffnotes-cache/` are still valid — clearing them only forces a slow FFmpeg re-decode of every
recording. Re-running matching replaces pending suggestions on its own. Avoid *Clear generated cache
for selected practice* and the fingerprint-state clear entirely: both also delete your accepted and
ignored decisions, which are ground truth you produced by ear and cannot be recomputed.

**Procedure.** Use one practice whose correct titles you already know, and do not accept or ignore
anything between runs — that would change `skipRecordingIds` and make the runs incomparable.

| | |
|---|---|
| **Run A** | Preferences → Fingerprint weight profile → **Apply defaults** (chroma ≈ 3.2% of score). Run fingerprint matching on the practice. |
| **Record** | Total takes matched; suggestions shown as actionable; how many of those are the *right* song; how many correct titles it missed entirely. |
| **Run B** | Set the chroma weight to **`1.44`** and save the profile (chroma ≈ 28%, i.e. pre-v0.6.11 behaviour). Re-run matching on the same practice. |
| **Record** | The same four numbers. |

| Metric | Run A (chroma 0.12) | Run B (chroma 1.44) |
|---|---|---|
| Takes matched | | |
| Actionable suggestions | | |
| ...of which correct | | |
| Correct songs missed | | |

**Interpreting it**

- **Run B clearly better** → the pre-change weighting was right for real rehearsal audio, and the
  default profile should be raised toward 1.44 rather than left at 0.12. The fix stays (the knob now
  means what it says), but the default was calibrated against the buggy behaviour.
- **Run A better or equal** → the documented intent holds; keep defaults.
- **Both poor** → the weighting is not the limiting factor, and the real problem is the similarity
  metric itself (`1 − mean|Δ|` has very little dynamic range) rather than how the features are mixed.

Run B should reproduce whatever you remember from v0.6.10. If it does not, the arithmetic above is
wrong and worth reporting.

---

## 11. Regression sweep on real data

| | |
|---|---|
| **Do** | On your **real** band folder (read-only actions): open several practices, switch takes, load waveforms, open Practice review, open the Masters library. |
| **Expect** | No errors in the log. No practice reported unreadable. |
| **Fails if** | Any practice that opened before v0.6.11 now reports "Cannot be opened" — that would mean the stricter catalogue reader is rejecting a file the old lenient reader tolerated. **Report the exact message.** |

---

## 12. Corrupt fingerprint decisions are quarantined, not overwritten (B16)

| | |
|---|---|
| **Do** | Pick a practice with accepted/ignored fingerprint decisions. Close the app. Truncate the decisions file: <br>`Set-Content D:\Band-Test\2026-07-22\.riffnotes.fingerprint-decisions.json '{"accepted": [{'` <br>Relaunch, open the practice, accept one fingerprint suggestion. |
| **Expect** | A file named `.riffnotes.fingerprint-decisions.json.corrupt-<number>` now exists next to the fresh decisions file, and it still contains the truncated text you wrote. |
| **Fails if** | No `.corrupt-` file — the damaged decisions were overwritten and are gone. |

---

## 13. Fresh clone builds without the OAuth file (B15)

Only needed if you or a bandmate ever build from a clean checkout.

| | |
|---|---|
| **Do** | `git clone` the repo to a new folder. Do **not** copy `assets/google_oauth.json` in. Run `flutter build windows`. |
| **Expect** | Build succeeds. Launching the app and opening Preferences → Google Drive account shows the client is not configured, with the `Import JSON` / `Add OAuth` path available. |
| **Fails if** | The build errors on a missing asset — the `pubspec.yaml` directory declaration is not taking effect. |

---

## Automated coverage for reference

`flutter test` — 57 tests. Covers catalogue durability, atomic writes, retained entries, fingerprint
repository quarantine, and both sync directions against an in-memory Drive store. It does **not**
cover `DriveApiFileStore`, the adapter that talks to Google, which is why step 6 exists.

**Before running any of this:** rotate the OAuth client in Google Cloud Console (see
`google-drive-setup.md`) and drop the new `google_oauth.json` into `assets/`. The old client id and
secret are in public git history.
