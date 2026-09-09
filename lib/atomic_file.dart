import 'dart:io';

/// Writes portable practice metadata so a reader never observes a half-written
/// file.
///
/// The naive `File.writeAsString` truncates the target and then streams into
/// it. A crash, a power loss, or the Google Drive desktop client reading the
/// file mid-write leaves valid-looking JSON that is actually truncated. For
/// `library.riffnotes.json` that is catastrophic: a catalogue that fails to
/// parse means every recording is re-assigned a new UUID and every note and
/// section in the practice is orphaned.
///
/// Writing to a sibling temp file and renaming over the target makes the swap
/// atomic (POSIX `rename`, Windows `MoveFileEx` with `REPLACE_EXISTING`), so a
/// reader sees either the complete old file or the complete new one.
///
/// The `.tmp` suffix is deliberate: both sync implementations already exclude
/// `*.tmp`, so a temp file left behind by a crash is never uploaded.
Future<void> writeFileAtomic(File file, String contents) async {
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.tmp');
  try {
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(file.path);
  } catch (_) {
    // Leave the original untouched; drop the partial temp file so a later
    // write is not confused by it.
    if (await temporary.exists()) {
      try {
        await temporary.delete();
      } on FileSystemException {
        // Best effort only -- the original file is still intact either way.
      }
    }
    rethrow;
  }
}

/// Moves a metadata file that failed to parse out of the way, keeping its
/// bytes, so the caller can safely fall back to an empty state and write a
/// fresh file without destroying the only copy of whatever was in it.
///
/// Used for files where "refuse to open" is the wrong response -- fingerprint
/// suggestions, decisions, learning, and corrections are not referenced by
/// UUID from anything else, so the practice can keep working without them.
/// Silently returning empty and then overwriting on the next write, which is
/// what these repositories used to do, would have erased ear-verified
/// decisions that cannot be recomputed.
///
/// Returns the quarantine path, or null if the move failed (the original is
/// left untouched in that case).
Future<File?> quarantineCorruptFile(File file) async {
  if (!await file.exists()) return null;
  final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
  final target = File('${file.path}.corrupt-$stamp');
  try {
    return await file.rename(target.path);
  } on FileSystemException {
    return null;
  }
}
