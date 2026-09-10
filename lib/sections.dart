import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'atomic_file.dart';
import 'user_names.dart';

class SongSection {
  const SongSection({
    required this.recordingId,
    required this.startMs,
    required this.endMs,
    required this.label,
    this.colorIndex = 0,
  });

  final String recordingId;
  final int startMs;
  final int endMs;
  final String label;
  final int colorIndex;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'recordingId': recordingId,
        'startMs': startMs,
        'endMs': endMs,
        'label': label,
        'colorIndex': colorIndex,
      };

  factory SongSection.fromJson(Map<String, dynamic> json) => SongSection(
        recordingId: json['recordingId'] as String,
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        label: json['label'] as String,
        colorIndex: json['colorIndex'] as int? ?? 0,
      );
}

/// Sections for a recording, stored as one complete layout per user.
///
/// Sections are structure ("Chorus at 1:32"), and two users' lists cannot be
/// merged range-by-range without producing overlaps. So each user writes
/// their own whole layout for a recording, and readers show whichever layout
/// was saved most recently. Every edit starts from that winning layout, so a
/// bandmate's sections are carried forward rather than replaced from scratch.
///
/// Files: `.riffnotes.<id>.sections.<user>.json`. The pre-fragment file
/// `.riffnotes.<id>.sections.json` is still read as the oldest candidate and
/// is never written, so an older build on the other machine keeps working on
/// what it can see. Both are written atomically; a file that fails to parse is
/// quarantined rather than silently ignored.
class SongSectionRepository {
  SongSectionRepository({
    String Function()? currentUser,
    DateTime Function()? clock,
  })  : _currentUser = currentUser,
        _clock = clock ?? DateTime.now;

  final String Function()? _currentUser;
  final DateTime Function() _clock;

  Future<List<SongSection>> load(
      String practiceFolder, String recordingId) async {
    final winner = await _winningLayout(practiceFolder, recordingId);
    if (winner == null) return <SongSection>[];
    return winner.sections.toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
  }

  Future<void> add(String practiceFolder, SongSection section) async {
    final sections = await load(practiceFolder, section.recordingId)
      ..add(section);
    await _write(practiceFolder, section.recordingId, sections);
  }

  Future<void> saveAll(String practiceFolder, String recordingId,
      List<SongSection> sections) async {
    await _write(practiceFolder, recordingId, sections.toList());
  }

  Future<void> replace(
      String practiceFolder, SongSection original, SongSection updated) async {
    final sections = await load(practiceFolder, original.recordingId);
    var index = sections.indexWhere((item) => _sameSection(item, original));
    if (index == -1) {
      index = sections.indexWhere((item) =>
          item.recordingId == original.recordingId &&
          item.label == original.label);
    }
    if (index == -1) {
      throw StateError('Could not find the section to update.');
    }
    sections[index] = updated;
    await _write(practiceFolder, original.recordingId, sections);
  }

  Future<void> delete(String practiceFolder, SongSection section) async {
    final sections = await load(practiceFolder, section.recordingId)
      ..removeWhere((item) => _sameSection(item, section));
    await _write(practiceFolder, section.recordingId, sections);
  }

  Future<void> _write(String practiceFolder, String recordingId,
      List<SongSection> sections) async {
    final user = _requireUser();
    sections.sort((a, b) => a.startMs.compareTo(b.startMs));
    await writeFileAtomic(
      _fragmentFile(practiceFolder, recordingId, user),
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'version': 2,
        'user': user,
        'recordingId': recordingId,
        'updatedAt': _clock().toUtc().toIso8601String(),
        'sections': sections.map((item) => item.toJson()).toList(),
      }),
    );
  }

  String _requireUser() {
    final user = _currentUser?.call().trim();
    if (user == null || user.isEmpty) {
      throw StateError(
          'A display name is required before sections can be saved.');
    }
    return user;
  }

  /// The most recently saved layout across the legacy file and every user's
  /// fragment. Ties on timestamp prefer a fragment over the legacy file, then
  /// the lexically smallest user, so two machines merging the same files pick
  /// the same layout.
  Future<_Layout?> _winningLayout(
      String practiceFolder, String recordingId) async {
    final folder = Directory(practiceFolder);
    if (!await folder.exists()) return null;

    final candidates = <_Layout>[];
    final legacy = _legacyFile(practiceFolder, recordingId);
    if (await legacy.exists()) {
      final parsed = await _parse(legacy, fallbackUser: null);
      if (parsed != null) candidates.add(parsed);
    }
    final pattern = _fragmentPattern(recordingId);
    await for (final entity in folder.list()) {
      if (entity is! File) continue;
      final match = pattern.firstMatch(path.basename(entity.path));
      if (match == null) continue;
      final parsed = await _parse(entity, fallbackUser: match.group(1));
      if (parsed != null) candidates.add(parsed);
    }
    if (candidates.isEmpty) return null;

    _Layout? best;
    for (final candidate in candidates) {
      if (best == null || _outranks(candidate, best)) best = candidate;
    }
    return best;
  }

  bool _outranks(_Layout candidate, _Layout incumbent) {
    if (candidate.updatedAt.isAfter(incumbent.updatedAt)) return true;
    if (candidate.updatedAt.isBefore(incumbent.updatedAt)) return false;
    if (candidate.isLegacy != incumbent.isLegacy) return incumbent.isLegacy;
    return candidate.user.compareTo(incumbent.user) < 0;
  }

  Future<_Layout?> _parse(File file, {required String? fallbackUser}) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('expected a JSON object');
      }
      final sections =
          (decoded['sections'] as List<dynamic>? ?? const <dynamic>[])
              .cast<Map<String, dynamic>>()
              .map(SongSection.fromJson)
              .toList(growable: false);
      final storedUser = (decoded['user'] as String?)?.trim();
      final stamp = decoded['updatedAt'];
      return _Layout(
        user: storedUser == null || storedUser.isEmpty
            ? (fallbackUser ?? '')
            : storedUser,
        isLegacy: fallbackUser == null,
        updatedAt: stamp is String
            ? (DateTime.tryParse(stamp)?.toUtc() ?? _epoch)
            : _epoch,
        sections: sections,
      );
    } on FormatException {
      await quarantineCorruptFile(file);
      return null;
    } on TypeError {
      await quarantineCorruptFile(file);
      return null;
    }
  }

  bool _sameSection(SongSection left, SongSection right) =>
      left.recordingId == right.recordingId &&
      left.startMs == right.startMs &&
      left.endMs == right.endMs &&
      left.label == right.label;

  static final _epoch = DateTime.utc(1970);

  File _legacyFile(String practiceFolder, String recordingId) =>
      File(path.join(practiceFolder, '.riffnotes.$recordingId.sections.json'));

  File _fragmentFile(String practiceFolder, String recordingId, String user) =>
      File(path.join(practiceFolder,
          '.riffnotes.$recordingId.sections.${safeUserName(user)}.json'));

  RegExp _fragmentPattern(String recordingId) => RegExp(
      '^${RegExp.escape('.riffnotes.$recordingId.sections.')}(.+)${RegExp.escape('.json')}\$');
}

class _Layout {
  const _Layout({
    required this.user,
    required this.isLegacy,
    required this.updatedAt,
    required this.sections,
  });

  final String user;
  final bool isLegacy;
  final DateTime updatedAt;
  final List<SongSection> sections;
}
