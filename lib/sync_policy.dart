/// Shared rules for deciding whether two copies of a file are "the same".
///
/// Both sync implementations (local folder and Google Drive) compare size plus
/// modification time. Exact timestamp equality is not usable in practice:
///
/// * exFAT and FAT32 store modification times with 2-second granularity, so a
///   file copied to an SD card or a phone comes back rounded.
/// * NTFS stores 100-nanosecond ticks while the Drive API reports RFC 3339
///   milliseconds, so a Drive round trip truncates.
///
/// A tolerance of two seconds is the coarsest granularity in play, so anything
/// inside it is treated as unchanged.
const syncTimestampTolerance = Duration(seconds: 2);

/// True when two timestamps are close enough to be considered the same instant.
bool syncTimestampsMatch(DateTime left, DateTime right) =>
    left.toUtc().difference(right.toUtc()).abs() <= syncTimestampTolerance;

/// True when [candidate] is newer than [reference] by more than the tolerance.
///
/// Used to protect local edits: a download must not replace a file the user has
/// changed since the remote copy was written. Without this check, downloading
/// before uploading silently reverts your own notes.
bool isMeaningfullyNewer(DateTime candidate, DateTime reference) =>
    candidate.toUtc().difference(reference.toUtc()) > syncTimestampTolerance;
