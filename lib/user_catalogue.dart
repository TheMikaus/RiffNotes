import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'atomic_file.dart';
import 'user_names.dart';

/// One user's view of one recording: the fields they have set, each with its
/// own timestamp.
///
/// Fields are stamped independently. If a single timestamp covered the whole
/// entry, toggling Best Take on this machine would re-stamp whatever title it
/// currently shows -- possibly a stale one not yet synced from a bandmate --
/// and that stale title would then outrank the bandmate's newer one after the
/// next sync. A null [title] with a non-null [titleUpdatedAt] means the user
/// deliberately cleared the title.
class UserCatalogueEntry {
  const UserCatalogueEntry({
    this.title,
    this.titleUpdatedAt,
    this.isBestTake,
    this.bestTakeUpdatedAt,
  });

  final String? title;
  final DateTime? titleUpdatedAt;
  final bool? isBestTake;
  final DateTime? bestTakeUpdatedAt;

  bool get claimsTitle => titleUpdatedAt != null;
  bool get claimsBestTake => bestTakeUpdatedAt != null;
  bool get isEmpty => !claimsTitle && !claimsBestTake;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (claimsTitle) 'title': title,
        if (claimsTitle)
          'titleUpdatedAt': titleUpdatedAt!.toUtc().toIso8601String(),
        if (claimsBestTake) 'isBestTake': isBestTake ?? false,
        if (claimsBestTake)
          'bestTakeUpdatedAt': bestTakeUpdatedAt!.toUtc().toIso8601String(),
      };

  static UserCatalogueEntry fromJson(Map<String, dynamic> json) {
    final titleStamp = _parseStamp(json['titleUpdatedAt']);
    final bestStamp = _parseStamp(json['bestTakeUpdatedAt']);
    return UserCatalogueEntry(
      title: titleStamp == null ? null : json['title'] as String?,
      titleUpdatedAt: titleStamp,
      isBestTake: bestStamp == null ? null : (json['isBestTake'] as bool?),
      bestTakeUpdatedAt: bestStamp,
    );
  }

  static DateTime? _parseStamp(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}

/// Everything one user has set across a practice folder, keyed by recording
/// id. Stored at `.riffnotes.<user>.catalogue.json` next to the audio.
class UserCatalogue {
  const UserCatalogue({required this.user, required this.entries});

  final String user;
  final Map<String, UserCatalogueEntry> entries;
}

/// The merged view of one recording across every user's fragment.
typedef MergedRecordingMetadata = ({
  String? title,
  bool isBestTake,
  List<String> bestTakeUsers,
});

/// Resolves the title and Best Take state for [recordingId].
///
/// * Title: the most recently stamped claim across users wins; ties break on
///   the user name so two machines merging the same fragments agree.
/// * Best Take: a per-user opinion. The merged flag is true when anyone has
///   starred the take, and [bestTakeUsers] lists who.
/// * Legacy values from the shared `library.riffnotes.json` are used only while
///   no fragment claims that field. The moment any user sets it, the legacy
///   value stops participating -- otherwise a legacy star could never be
///   removed, since no fragment can outvote it.
MergedRecordingMetadata mergeRecordingMetadata(
  List<UserCatalogue> fragments,
  String recordingId, {
  String? legacyTitle,
  bool legacyBestTake = false,
}) {
  UserCatalogue? titleOwner;
  UserCatalogueEntry? titleEntry;
  var anyBestTakeClaim = false;
  final starred = <String>[];

  for (final fragment in fragments) {
    final entry = fragment.entries[recordingId];
    if (entry == null) continue;
    if (entry.claimsTitle) {
      final current = titleEntry;
      final isNewer = current == null ||
          entry.titleUpdatedAt!.isAfter(current.titleUpdatedAt!) ||
          (entry.titleUpdatedAt!.isAtSameMomentAs(current.titleUpdatedAt!) &&
              fragment.user.compareTo(titleOwner!.user) < 0);
      if (isNewer) {
        titleEntry = entry;
        titleOwner = fragment;
      }
    }
    if (entry.claimsBestTake) {
      anyBestTakeClaim = true;
      if (entry.isBestTake == true) starred.add(fragment.user);
    }
  }
  starred.sort();
  return (
    title: titleEntry != null ? titleEntry.title : legacyTitle,
    isBestTake: anyBestTakeClaim ? starred.isNotEmpty : legacyBestTake,
    bestTakeUsers: List<String>.unmodifiable(starred),
  );
}

class UserCatalogueRepository {
  static final _pattern = RegExp(r'^\.riffnotes\.(.+)\.catalogue\.json$');

  File fileFor(Directory folder, String user) => File(
      path.join(folder.path, '.riffnotes.${safeUserName(user)}.catalogue.json'));

  /// Every user's fragment in [folder], sorted by user for deterministic
  /// merging. A fragment that fails to parse is quarantined and skipped; the
  /// others still load.
  Future<List<UserCatalogue>> loadAll(Directory folder) async {
    if (!await folder.exists()) return const <UserCatalogue>[];
    final result = <UserCatalogue>[];
    await for (final entity in folder.list()) {
      if (entity is! File) continue;
      final match = _pattern.firstMatch(path.basename(entity.path));
      if (match == null) continue;
      final loaded = await _read(entity, fallbackUser: match.group(1)!);
      if (loaded != null) result.add(loaded);
    }
    result.sort((a, b) => a.user.compareTo(b.user));
    return result;
  }

  Future<UserCatalogue> loadForUser(Directory folder, String user) async {
    final file = fileFor(folder, user);
    if (!await file.exists()) {
      return UserCatalogue(user: user, entries: const {});
    }
    return await _read(file, fallbackUser: user) ??
        UserCatalogue(user: user, entries: const {});
  }

  /// Sets the given fields for [recordingId] in [user]'s fragment, stamping
  /// only the fields passed. [now] is injectable so tests can order events.
  Future<void> update(
    Directory folder,
    String user,
    String recordingId, {
    bool setTitle = false,
    String? title,
    bool setBestTake = false,
    bool? isBestTake,
    DateTime? now,
  }) async {
    if (!setTitle && !setBestTake) return;
    final stamp = (now ?? DateTime.now()).toUtc();
    final current = await loadForUser(folder, user);
    final existing = current.entries[recordingId] ?? const UserCatalogueEntry();
    final next = UserCatalogueEntry(
      title: setTitle ? title : existing.title,
      titleUpdatedAt: setTitle ? stamp : existing.titleUpdatedAt,
      isBestTake: setBestTake ? (isBestTake ?? false) : existing.isBestTake,
      bestTakeUpdatedAt: setBestTake ? stamp : existing.bestTakeUpdatedAt,
    );
    await _write(folder, user, <String, UserCatalogueEntry>{
      ...current.entries,
      recordingId: next,
    });
  }

  Future<void> remove(Directory folder, String user, String recordingId) async {
    final current = await loadForUser(folder, user);
    if (!current.entries.containsKey(recordingId)) return;
    final next = Map<String, UserCatalogueEntry>.from(current.entries)
      ..remove(recordingId);
    await _write(folder, user, next);
  }

  Future<UserCatalogue?> _read(File file, {required String fallbackUser}) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('expected a JSON object');
      }
      final entries = <String, UserCatalogueEntry>{};
      final rawEntries = decoded['entries'];
      if (rawEntries is Map<String, dynamic>) {
        for (final item in rawEntries.entries) {
          final value = item.value;
          if (value is Map<String, dynamic>) {
            entries[item.key] = UserCatalogueEntry.fromJson(value);
          }
        }
      }
      final storedUser = (decoded['user'] as String?)?.trim();
      return UserCatalogue(
        user: storedUser == null || storedUser.isEmpty
            ? fallbackUser
            : storedUser,
        entries: entries,
      );
    } on FormatException {
      await quarantineCorruptFile(file);
      return null;
    } on TypeError {
      await quarantineCorruptFile(file);
      return null;
    }
  }

  Future<void> _write(
    Directory folder,
    String user,
    Map<String, UserCatalogueEntry> entries,
  ) async {
    final keys = entries.keys.toList()..sort();
    const encoder = JsonEncoder.withIndent('  ');
    await writeFileAtomic(
      fileFor(folder, user),
      encoder.convert(<String, dynamic>{
        'version': 1,
        'user': user,
        'entries': <String, dynamic>{
          for (final key in keys) key: entries[key]!.toJson(),
        },
      }),
    );
  }
}
