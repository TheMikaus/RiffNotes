import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

import 'domain.dart';

/// A review comment. A point note has no [endMs]; a range note has a distinct
/// start/end span. Song-structure sections deliberately use a separate model.
class PracticeAnnotation {
  const PracticeAnnotation({
    required this.id,
    required this.recordingId,
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.createdAt,
  });

  final String id;
  final String recordingId;
  final int startMs;
  final int? endMs;
  final String text;
  final DateTime createdAt;

  bool get isRange => endMs != null && endMs! > startMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'recordingId': recordingId,
        'startMs': startMs,
        'endMs': endMs,
        'text': text,
        'createdAt': createdAt.toIso8601String(),
      };

  factory PracticeAnnotation.fromJson(Map<String, dynamic> json) =>
      PracticeAnnotation(
        id: json['id'] as String,
        recordingId: json['recordingId'] as String,
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int?,
        text: json['text'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}

class UserAnnotation {
  const UserAnnotation({required this.user, required this.annotation});

  final String user;
  final PracticeAnnotation annotation;
}

class AnnotationRepository {
  Future<List<UserAnnotation>> loadAll(String practiceFolder) async {
    final folder = Directory(practiceFolder);
    final result = <UserAnnotation>[];
    await for (final entity in folder.list()) {
      if (entity is! File) continue;
      final filename = path.basename(entity.path);
      final match =
          RegExp(r'^\.riffnotes\.(.+)\.bandnotes$').firstMatch(filename);
      if (match == null) continue;
      try {
        final content =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final user = content['user'] as String? ?? match.group(1)!;
        final annotations =
            (content['annotations'] as List<dynamic>? ?? const <dynamic>[])
                .cast<Map<String, dynamic>>()
                .map(PracticeAnnotation.fromJson);
        result.addAll(annotations.map((annotation) =>
            UserAnnotation(user: user, annotation: annotation)));
      } on FormatException {
        // A malformed bandmate file should not hide the rest of the review.
      }
    }
    result.sort(
        (a, b) => a.annotation.createdAt.compareTo(b.annotation.createdAt));
    return result;
  }

  Future<List<PracticeAnnotation>> loadForUser(
      String practiceFolder, String user) async {
    final file = _fileFor(practiceFolder, user);
    if (!await file.exists()) return <PracticeAnnotation>[];
    final content =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final notes = (content['annotations'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(PracticeAnnotation.fromJson)
        .toList();
    notes.sort((a, b) => a.startMs.compareTo(b.startMs));
    return notes;
  }

  Future<PracticeAnnotation> add({
    required String practiceFolder,
    required String user,
    required Recording recording,
    required int startMs,
    int? endMs,
    required String text,
  }) async {
    if (endMs != null && endMs <= startMs) {
      throw ArgumentError.value(endMs, 'endMs', 'must be after the start time');
    }
    final notes = await loadForUser(practiceFolder, user);
    final annotation = PracticeAnnotation(
      id: _id(),
      recordingId: recording.id,
      startMs: startMs,
      endMs: endMs,
      text: text,
      createdAt: DateTime.now().toUtc(),
    );
    notes.add(annotation);
    notes.sort((a, b) => a.startMs.compareTo(b.startMs));
    await _write(practiceFolder, user, notes);
    return annotation;
  }

  Future<void> _write(
      String folder, String user, List<PracticeAnnotation> notes) async {
    final file = _fileFor(folder, user);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
        encoder.convert({
          'version': 1,
          'user': user,
          'annotations': notes.map((note) => note.toJson()).toList(),
        }),
        flush: true);
  }

  File _fileFor(String folder, String user) =>
      File(path.join(folder, '.riffnotes.${_safeUser(user)}.bandnotes'));
  String _safeUser(String user) =>
      user.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  String _id() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
}
