/// Sanitizes a display name for use inside a per-user metadata filename
/// (`.riffnotes.<user>.bandnotes`, `.riffnotes.<user>.catalogue.json`, ...).
///
/// Only `[a-zA-Z0-9_-]` survive so the result is safe on every filesystem the
/// folder might be synced to. An empty result falls back to `user`: the
/// discovery patterns require at least one character between the dots, and a
/// name like `.riffnotes..bandnotes` would be written but never read back.
String safeUserName(String user) {
  final cleaned = user.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  return cleaned.isEmpty ? 'user' : cleaned;
}
