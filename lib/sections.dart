import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'domain.dart';

class SongSection {
  const SongSection({required this.recordingId, required this.startMs, required this.endMs, required this.label});

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
  static const _filename = '.riffnotes.sections.json';

  Future<List<SongSection>> load(String practiceFolder) async {
    final file = File(path.join(practiceFolder, _filename));
    if (!await file.exists()) return <SongSection>[];
    try {
      final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (decoded['sections'] as List<dynamic>? ?? const <dynamic>[])
          .cast<Map<String, dynamic>>()
          .map(SongSection.fromJson)
          .toList()
        ..sort((a, b) => a.startMs.compareTo(b.startMs));
    } on FormatException {
      return <SongSection>[];
    }
  }

  Future<void> add(String practiceFolder, SongSection section) async {
    final sections = await load(practiceFolder)..add(section);
    sections.sort((a, b) => a.startMs.compareTo(b.startMs));
    final file = File(path.join(practiceFolder, _filename));
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'version': 1,
      'sections': sections.map((item) => item.toJson()).toList(),
    }), flush: true);
  }
}
