import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'domain.dart';

class SongSection {
  const SongSection({
    required this.recordingId,
    required this.startMs,
    required this.endMs,
    required this.label,
  });

  final String recordingId;
  final int startMs;
  final int endMs;
  final String label;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'recordingId': recordingId,
        'startMs': startMs,
        'endMs': endMs,
        'label': label,
      };

  factory SongSection.fromJson(Map<String, dynamic> json) => SongSection(
        recordingId: json['recordingId'] as String,
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        label: json['label'] as String,
      );
}

class SongSectionRepository {
  Future<List<SongSection>> load(
      String practiceFolder, String recordingId) async {
    final file = _fileFor(practiceFolder, recordingId);
    if (!await file.exists()) return <SongSection>[];
    try {
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (decoded['sections'] as List<dynamic>? ?? const <dynamic>[])
          .cast<Map<String, dynamic>>()
          .map(SongSection.fromJson)
          .toList()
        ..sort((a, b) => a.startMs.compareTo(b.startMs));
    } on FormatException {
      return <SongSection>[];
    } on TypeError {
      return <SongSection>[];
    }
  }

  Future<void> add(String practiceFolder, SongSection section) async {
    final sections = await load(practiceFolder, section.recordingId)
      ..add(section);
    await _write(practiceFolder, section.recordingId, sections);
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
    sections.sort((a, b) => a.startMs.compareTo(b.startMs));
    final file = _fileFor(practiceFolder, recordingId);
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
          'version': 1,
          'sections': sections.map((item) => item.toJson()).toList(),
        }),
        flush: true);
  }

  bool _sameSection(SongSection left, SongSection right) =>
      left.recordingId == right.recordingId &&
      left.startMs == right.startMs &&
      left.endMs == right.endMs &&
      left.label == right.label;

  File _fileFor(String practiceFolder, String recordingId) =>
      File(path.join(practiceFolder, '.riffnotes.$recordingId.sections.json'));
}
