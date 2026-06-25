import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

import 'domain.dart';
import 'sections.dart';

class FingerprintRepository {
  static const _cacheFolder = '.riffnotes-cache';
  static const _cacheVersion = 1;

  Future<List<FingerprintMatch>> matchPractice({
    required PracticeFolder practice,
    required Directory mastersFolder,
    int maxResultsPerRecording = 3,
  }) async {
    final masters = await PracticeRepository().openPractice(mastersFolder);
    final masterTargets = <_MasterTarget>[];
    for (final master in masters.recordings) {
      final fingerprint =
          await loadOrGenerateFingerprint(masters.directory, master);
      masterTargets.add(_MasterTarget(
        recording: master,
        section: null,
        fingerprint: fingerprint,
      ));
      final sections =
          await SongSectionRepository().load(masters.directory.path, master.id);
      for (final section in sections) {
        final sectionFingerprint = _sliceFingerprint(fingerprint, section);
        if (sectionFingerprint.values.length >= 8) {
          masterTargets.add(_MasterTarget(
            recording: master,
            section: section,
            fingerprint: sectionFingerprint,
          ));
        }
      }
    }
    if (masterTargets.isEmpty) return const <FingerprintMatch>[];

    final matches = <FingerprintMatch>[];
    for (final recording in practice.recordings) {
      final fingerprint =
          await loadOrGenerateFingerprint(practice.directory, recording);
      final ranked = masterTargets
          .map((target) => FingerprintMatch(
                recordingId: recording.id,
                recordingFilename: recording.filename,
                masterRecordingId: target.recording.id,
                masterFilename: target.recording.filename,
                masterTitle: target.recording.title,
                sectionLabel: target.section?.label,
                confidence: _similarity(fingerprint, target.fingerprint),
              ))
          .where((match) => match.confidence >= .55)
          .toList()
        ..sort((a, b) => b.confidence.compareTo(a.confidence));
      matches.addAll(ranked.take(maxResultsPerRecording));
    }
    return matches;
  }

  Future<AudioFingerprint> loadOrGenerateFingerprint(
      Directory folder, Recording recording) async {
    final sourceStat = await recording.file.stat();
    final cache = File(path.join(
        folder.path, _cacheFolder, '${recording.id}.fingerprint.json'));
    final cached = await _readCache(cache, sourceStat);
    if (cached != null) return cached;

    final result = await Process.run(
      'ffmpeg',
      <String>[
        '-v',
        'error',
        '-i',
        recording.file.path,
        '-vn',
        '-ac',
        '1',
        '-ar',
        '4000',
        '-f',
        's16le',
        'pipe:1',
      ],
      stdoutEncoding: null,
      stderrEncoding: null,
    );
    if (result.exitCode != 0) {
      throw StateError('FFmpeg could not fingerprint ${recording.filename}.');
    }
    final output = result.stdout;
    if (output is! List<int> || output.length < 2) {
      throw StateError('No usable audio samples for ${recording.filename}.');
    }
    final fingerprint = AudioFingerprint(
      durationMs: output.length ~/ 2 * 1000 ~/ 4000,
      values: calculateFingerprint(output),
    );
    await cache.parent.create(recursive: true);
    await cache.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'version': _cacheVersion,
        'sourceBytes': sourceStat.size,
        'sourceModifiedMs': sourceStat.modified.millisecondsSinceEpoch,
        'durationMs': fingerprint.durationMs,
        'values': fingerprint.values,
      }),
      flush: true,
    );
    return fingerprint;
  }

  Future<AudioFingerprint?> _readCache(File cache, FileStat sourceStat) async {
    if (!await cache.exists()) return null;
    try {
      final decoded =
          jsonDecode(await cache.readAsString()) as Map<String, dynamic>;
      if (decoded['version'] != _cacheVersion ||
          decoded['sourceBytes'] != sourceStat.size ||
          decoded['sourceModifiedMs'] !=
              sourceStat.modified.millisecondsSinceEpoch) {
        return null;
      }
      return AudioFingerprint(
        durationMs: decoded['durationMs'] as int,
        values: (decoded['values'] as List<dynamic>)
            .map((value) => (value as num).toDouble())
            .toList(growable: false),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static List<double> calculateFingerprint(List<int> pcmBytes,
      {int windowSamples = 800}) {
    final sampleCount = pcmBytes.length ~/ 2;
    if (sampleCount == 0) return const <double>[];
    final windows = max(1, sampleCount ~/ windowSamples);
    final values = <double>[];
    for (var window = 0; window < windows; window += 1) {
      final start = window * windowSamples;
      final end = min(sampleCount, start + windowSamples);
      var energy = 0.0;
      var crossings = 0;
      var previous = 0;
      for (var sample = start; sample < end; sample += 1) {
        final low = pcmBytes[sample * 2];
        final high = pcmBytes[sample * 2 + 1];
        var value = low | (high << 8);
        if (value >= 0x8000) value -= 0x10000;
        energy += value.abs() / 32768;
        if (sample > start &&
            ((value >= 0 && previous < 0) || (value < 0 && previous >= 0))) {
          crossings += 1;
        }
        previous = value;
      }
      final length = max(1, end - start);
      final normalizedEnergy = energy / length;
      final normalizedCrossings = crossings / length;
      values.add((normalizedEnergy * .8) + (normalizedCrossings * .2));
    }
    final maximum =
        values.reduce((largest, value) => value > largest ? value : largest);
    if (maximum == 0) return values;
    return values.map((value) => value / maximum).toList(growable: false);
  }

  AudioFingerprint _sliceFingerprint(
      AudioFingerprint fingerprint, SongSection section) {
    if (fingerprint.durationMs <= 0 || fingerprint.values.isEmpty) {
      return const AudioFingerprint(durationMs: 0, values: <double>[]);
    }
    final start =
        (section.startMs / fingerprint.durationMs * fingerprint.values.length)
            .floor()
            .clamp(0, fingerprint.values.length - 1);
    final end =
        (section.endMs / fingerprint.durationMs * fingerprint.values.length)
            .ceil()
            .clamp(start + 1, fingerprint.values.length);
    return AudioFingerprint(
      durationMs: section.endMs - section.startMs,
      values: fingerprint.values.sublist(start, end),
    );
  }

  double _similarity(AudioFingerprint query, AudioFingerprint target) {
    if (query.values.isEmpty || target.values.isEmpty) return 0;
    final shorter =
        query.values.length <= target.values.length ? query : target;
    final longer = identical(shorter, query) ? target : query;
    if (shorter.values.length < 4) return 0;

    var best = 0.0;
    final maxOffset = max(0, longer.values.length - shorter.values.length);
    final step = max(1, shorter.values.length ~/ 24);
    for (var offset = 0; offset <= maxOffset; offset += step) {
      best =
          max(best, _windowSimilarity(shorter.values, longer.values, offset));
    }
    if (maxOffset > 0) {
      best = max(
          best, _windowSimilarity(shorter.values, longer.values, maxOffset));
    }
    final durationRatio = min(query.durationMs, target.durationMs) /
        max(query.durationMs, target.durationMs);
    return (best * .85) + (durationRatio * .15);
  }

  double _windowSimilarity(List<double> left, List<double> right, int offset) {
    var difference = 0.0;
    for (var index = 0; index < left.length; index += 1) {
      difference += (left[index] - right[index + offset]).abs();
    }
    final averageDifference = difference / left.length;
    return (1 - averageDifference).clamp(0, 1);
  }
}

class FingerprintDecisionRepository {
  static const _filename = '.riffnotes.fingerprint-decisions.json';

  Future<FingerprintDecisions> load(String practiceFolder) async {
    final file = File(path.join(practiceFolder, _filename));
    if (!await file.exists()) return const FingerprintDecisions();
    try {
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return FingerprintDecisions(
        accepted: (decoded['accepted'] as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<String, dynamic>>()
            .map(FingerprintDecision.fromJson)
            .toList(growable: false),
        ignoredKeys:
            (decoded['ignoredKeys'] as List<dynamic>? ?? const <dynamic>[])
                .map((value) => value as String)
                .toSet(),
      );
    } on FormatException {
      return const FingerprintDecisions();
    } on TypeError {
      return const FingerprintDecisions();
    }
  }

  Future<void> accept(String practiceFolder, FingerprintMatch match) async {
    final decisions = await load(practiceFolder);
    final accepted = decisions.accepted
        .where((item) => item.recordingId != match.recordingId)
        .toList()
      ..add(FingerprintDecision(
        recordingId: match.recordingId,
        masterRecordingId: match.masterRecordingId,
        displayName: match.displayName,
        confidence: match.confidence,
        decidedAt: DateTime.now().toUtc(),
      ));
    final ignored = {...decisions.ignoredKeys}..remove(match.key);
    await _write(practiceFolder,
        FingerprintDecisions(accepted: accepted, ignoredKeys: ignored));
  }

  Future<void> ignore(String practiceFolder, FingerprintMatch match) async {
    final decisions = await load(practiceFolder);
    await _write(
      practiceFolder,
      FingerprintDecisions(
        accepted: decisions.accepted,
        ignoredKeys: {...decisions.ignoredKeys, match.key},
      ),
    );
  }

  Future<void> _write(
      String practiceFolder, FingerprintDecisions decisions) async {
    final file = File(path.join(practiceFolder, _filename));
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      encoder.convert(<String, dynamic>{
        'version': 1,
        'accepted': decisions.accepted.map((item) => item.toJson()).toList(),
        'ignoredKeys': decisions.ignoredKeys.toList()..sort(),
      }),
      flush: true,
    );
  }
}

class FingerprintDecisions {
  const FingerprintDecisions({
    this.accepted = const <FingerprintDecision>[],
    this.ignoredKeys = const <String>{},
  });

  final List<FingerprintDecision> accepted;
  final Set<String> ignoredKeys;
}

class FingerprintDecision {
  const FingerprintDecision({
    required this.recordingId,
    required this.masterRecordingId,
    required this.displayName,
    required this.confidence,
    required this.decidedAt,
  });

  final String recordingId;
  final String masterRecordingId;
  final String displayName;
  final double confidence;
  final DateTime decidedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'recordingId': recordingId,
        'masterRecordingId': masterRecordingId,
        'displayName': displayName,
        'confidence': confidence,
        'decidedAt': decidedAt.toIso8601String(),
      };

  factory FingerprintDecision.fromJson(Map<String, dynamic> json) =>
      FingerprintDecision(
        recordingId: json['recordingId'] as String,
        masterRecordingId: json['masterRecordingId'] as String,
        displayName: json['displayName'] as String,
        confidence: (json['confidence'] as num).toDouble(),
        decidedAt: DateTime.parse(json['decidedAt'] as String),
      );
}

class AudioFingerprint {
  const AudioFingerprint({required this.durationMs, required this.values});

  final int durationMs;
  final List<double> values;
}

class FingerprintMatch {
  const FingerprintMatch({
    required this.recordingId,
    required this.recordingFilename,
    required this.masterRecordingId,
    required this.masterFilename,
    required this.masterTitle,
    required this.sectionLabel,
    required this.confidence,
  });

  final String recordingId;
  final String recordingFilename;
  final String masterRecordingId;
  final String masterFilename;
  final String? masterTitle;
  final String? sectionLabel;
  final double confidence;

  String get key =>
      '$recordingId|$masterRecordingId|${sectionLabel ?? ''}|$masterFilename';

  String get displayName {
    final song = masterTitle ?? path.basenameWithoutExtension(masterFilename);
    return sectionLabel == null ? song : '$song / $sectionLabel';
  }
}

class _MasterTarget {
  const _MasterTarget({
    required this.recording,
    required this.section,
    required this.fingerprint,
  });

  final Recording recording;
  final SongSection? section;
  final AudioFingerprint fingerprint;
}
