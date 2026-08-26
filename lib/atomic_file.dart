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
