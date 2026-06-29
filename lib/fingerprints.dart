import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

import 'domain.dart';
import 'sections.dart';

class FingerprintRepository {
  static const _cacheFolder = '.riffnotes-cache';
  static const _cacheVersion = 2;
  static const _minimumSuggestionConfidence = .42;
  static const _sampleRate = 4000;
  static const _windowSamples = 800;

  final _learning = FingerprintLearningRepository();

  Future<List<FingerprintMatch>> matchPractice({
    required PracticeFolder practice,
    required Directory mastersFolder,
    int maxResultsPerRecording = 3,
    Set<String> skipRecordingIds = const <String>{},
  }) async {
    final masters = await PracticeRepository().openPractice(mastersFolder);
    final learning = await _learning.load(mastersFolder.path);
    final songTargets = <_MasterTarget>[];
    final sectionTargets = <_MasterTarget>[];
    for (final master in masters.recordings) {
      if (_isJamRecording(master)) continue;
      final fingerprint =
          await loadOrGenerateFingerprint(masters.directory, master);
      songTargets.add(_MasterTarget(
        recording: master,
        section: null,
        fingerprint: fingerprint,
      ));
      final sections =
          await SongSectionRepository().load(masters.directory.path, master.id);
      for (final section in sections) {
        final sectionFingerprint = _sliceFingerprint(fingerprint, section);
        if (sectionFingerprint.windowCount >= 8) {
          sectionTargets.add(_MasterTarget(
            recording: master,
            section: section,
            fingerprint: sectionFingerprint,
          ));
        }
      }
    }
    if (songTargets.isEmpty) return const <FingerprintMatch>[];

    final matches = <FingerprintMatch>[];
    for (final recording in practice.recordings) {
      if (_isJamRecording(recording)) {
        continue;
      }
      if (skipRecordingIds.contains(recording.id)) {
        continue;
      }
      final fingerprint =
          await loadOrGenerateFingerprint(practice.directory, recording);
      final songCandidates = songTargets
          .map((target) => _matchTarget(
                recording: recording,
                fingerprint: fingerprint,
                target: target,
                learning: learning,
                targetType: FingerprintTargetType.song,
              ))
          .toList()
        ..sort((a, b) => b.confidence.compareTo(a.confidence));
      final likelySongIds = _likelySongIds(songCandidates);
      final candidates = <FingerprintMatch>[
        ...songCandidates,
        for (final target in sectionTargets)
          if (likelySongIds.contains(target.recording.id))
            _matchTarget(
              recording: recording,
              fingerprint: fingerprint,
              target: target,
              learning: learning,
              targetType: FingerprintTargetType.section,
              songConfidence: songCandidates
                  .where(
                      (item) => item.masterRecordingId == target.recording.id)
                  .firstOrNull
                  ?.confidence,
            ),
      ];
      candidates.sort((a, b) => b.confidence.compareTo(a.confidence));
      var addedForRecording = 0;
      for (var index = 0;
          index < candidates.length &&
              addedForRecording < maxResultsPerRecording;
          index += 1) {
        final candidate = candidates[index];
        final nextConfidence = index + 1 < candidates.length
            ? candidates[index + 1].confidence
            : 0.0;
        final margin =
            (candidate.confidence - nextConfidence).clamp(0.0, 1.0).toDouble();
        if (candidate.confidence >= _minimumSuggestionConfidence) {
          matches.add(candidate.copyWith(confidenceMargin: margin));
          addedForRecording += 1;
        }
      }
    }
    return matches;
  }

  Set<String> _likelySongIds(List<FingerprintMatch> songCandidates) {
    if (songCandidates.isEmpty) return const <String>{};
    final best = songCandidates.first.confidence;
    final likely = songCandidates
        .where((match) =>
            match.confidence >= .40 ||
            (best >= .50 && best - match.confidence <= .12))
        .take(3)
        .map((match) => match.masterRecordingId)
        .toSet();
    if (likely.isNotEmpty) return likely;
    return songCandidates
        .take(2)
        .map((match) => match.masterRecordingId)
        .toSet();
  }

  FingerprintMatch _matchTarget({
    required Recording recording,
    required AudioFingerprint fingerprint,
    required _MasterTarget target,
    required FingerprintLearning learning,
    required FingerprintTargetType targetType,
    double? songConfidence,
  }) {
    final score = _similarity(fingerprint, target.fingerprint);
    final adjustment = learning.adjustmentFor(
      masterRecordingId: target.recording.id,
      sectionLabel: target.section?.label,
    );
    final sectionPenalty =
        targetType == FingerprintTargetType.section && songConfidence != null
            ? ((1 - songConfidence) * .10).clamp(0.0, .08).toDouble()
            : 0.0;
    final adjustedConfidence = (score.confidence + adjustment - sectionPenalty)
        .clamp(0.0, 1.0)
        .toDouble();
    return FingerprintMatch(
      recordingId: recording.id,
      recordingFilename: recording.filename,
      masterRecordingId: target.recording.id,
      masterFilename: target.recording.filename,
      masterTitle: target.recording.title,
      sectionLabel: target.section?.label,
      confidence: adjustedConfidence,
      rawConfidence: score.confidence,
      confidenceMargin: 0,
      learningAdjustment: adjustment,
      sectionSongPenalty: sectionPenalty,
      songConfidence: songConfidence,
      matchOffsetMs: _offsetMsFor(score.offset, fingerprint),
      targetType: targetType,
      featureScores: score.featureScores,
    );
  }

  Future<List<SongSection>> alignSectionsToRecording({
    required Directory practiceFolder,
    required Recording recording,
    required Directory mastersFolder,
    required Recording masterRecording,
    required List<SongSection> masterSections,
    double minimumSectionConfidence = .52,
  }) async {
    if (masterSections.isEmpty) return const <SongSection>[];
    final recordingFingerprint =
        await loadOrGenerateFingerprint(practiceFolder, recording);
    final masterFingerprint =
        await loadOrGenerateFingerprint(mastersFolder, masterRecording);
    if (recordingFingerprint.windowCount < 8 ||
        masterFingerprint.windowCount < 8) {
      return const <SongSection>[];
    }
    final candidates = <_AlignedSectionCandidate>[];
    for (final section in masterSections) {
      final sectionFingerprint = _sliceFingerprint(masterFingerprint, section);
      if (sectionFingerprint.windowCount < 8) continue;
      final score = _similarity(recordingFingerprint, sectionFingerprint);
      if (score.confidence < minimumSectionConfidence || score.offset == null) {
        continue;
      }
      final startRatio = score.offset! / recordingFingerprint.windowCount;
      final endRatio = (score.offset! + sectionFingerprint.windowCount) /
          recordingFingerprint.windowCount;
      final startMs = (startRatio * recordingFingerprint.durationMs)
          .round()
          .clamp(0, recordingFingerprint.durationMs);
      final endMs = (endRatio * recordingFingerprint.durationMs)
          .round()
          .clamp(startMs + 1, recordingFingerprint.durationMs);
      if (endMs - startMs < 250) continue;
      candidates.add(_AlignedSectionCandidate(
        section: SongSection(
          recordingId: recording.id,
          startMs: startMs,
          endMs: endMs,
          label: section.label,
          colorIndex: section.colorIndex,
        ),
        confidence: score.confidence,
      ));
    }
    if (candidates.isEmpty) return const <SongSection>[];
    candidates.sort((a, b) => b.confidence.compareTo(a.confidence));
    final accepted = <SongSection>[];
    for (final candidate in candidates) {
      final overlapsExisting = accepted.any((existing) =>
          candidate.section.startMs < existing.endMs &&
          candidate.section.endMs > existing.startMs);
      if (!overlapsExisting) {
        accepted.add(candidate.section);
      }
    }
    accepted.sort((a, b) => a.startMs.compareTo(b.startMs));
    return accepted;
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
        '$_sampleRate',
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
    final fingerprint = calculateAudioFingerprint(output);
    await cache.parent.create(recursive: true);
    await cache.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'version': _cacheVersion,
        'sourceBytes': sourceStat.size,
        'sourceModifiedMs': sourceStat.modified.millisecondsSinceEpoch,
        'algorithm': 'multi-feature-v2',
        'sampleRate': _sampleRate,
        'windowSamples': _windowSamples,
        'durationMs': fingerprint.durationMs,
        'features': fingerprint.features,
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
      final featuresJson = decoded['features'] as Map<String, dynamic>?;
      if (featuresJson == null) return null;
      return AudioFingerprint(
        durationMs: decoded['durationMs'] as int,
        features: featuresJson.map(
          (key, value) => MapEntry(
            key,
            (value as List<dynamic>)
                .map((item) => (item as num).toDouble())
                .toList(growable: false),
          ),
        ),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static AudioFingerprint calculateAudioFingerprint(List<int> pcmBytes,
      {int sampleRate = _sampleRate, int windowSamples = _windowSamples}) {
    final sampleCount = pcmBytes.length ~/ 2;
    if (sampleCount == 0) {
      return const AudioFingerprint(durationMs: 0, features: {});
    }
    final windows = max(1, sampleCount ~/ windowSamples);
    final energy = <double>[];
    final zeroCrossing = <double>[];
    final attack = <double>[];
    final lowMotion = <double>[];
    final highMotion = <double>[];
    final peaks = <double>[];
    var previousWindowEnergy = 0.0;

    for (var window = 0; window < windows; window += 1) {
      final start = window * windowSamples;
      final end = min(sampleCount, start + windowSamples);
      var absoluteEnergy = 0.0;
      var crossings = 0;
      var highDifference = 0.0;
      var lowAccumulator = 0.0;
      var peakCount = 0;
      var previous = 0.0;
      var smoothed = 0.0;
      for (var sample = start; sample < end; sample += 1) {
        final value = _readSignedSample(pcmBytes, sample) / 32768.0;
        final absValue = value.abs();
        absoluteEnergy += absValue;
        if (sample > start &&
            ((value >= 0 && previous < 0) || (value < 0 && previous >= 0))) {
          crossings += 1;
        }
        if (sample > start) highDifference += (value - previous).abs();
        smoothed = (smoothed * .92) + (value * .08);
        lowAccumulator += smoothed.abs();
        if (absValue >= .62) peakCount += 1;
        previous = value;
      }
      final length = max(1, end - start);
      final currentEnergy = absoluteEnergy / length;
      energy.add(currentEnergy);
      zeroCrossing.add(crossings / length);
      highMotion.add(highDifference / length);
      lowMotion.add(lowAccumulator / length);
      attack.add(max(0, currentEnergy - previousWindowEnergy));
      peaks.add(peakCount / length);
      previousWindowEnergy = currentEnergy;
    }

    final features = <String, List<double>>{
      'energy': _normalize(energy),
      'zeroCrossing': _normalize(zeroCrossing),
      'attack': _normalize(attack),
      'lowMotion': _normalize(lowMotion),
      'highMotion': _normalize(highMotion),
      'peaks': _normalize(peaks),
    };
    return AudioFingerprint(
      durationMs: sampleCount * 1000 ~/ sampleRate,
      features: features,
    );
  }

  static List<double> calculateFingerprint(List<int> pcmBytes,
      {int windowSamples = _windowSamples}) {
    return calculateAudioFingerprint(pcmBytes, windowSamples: windowSamples)
        .values;
  }

  AudioFingerprint _sliceFingerprint(
      AudioFingerprint fingerprint, SongSection section) {
    if (fingerprint.durationMs <= 0 || fingerprint.windowCount == 0) {
      return const AudioFingerprint(durationMs: 0, features: {});
    }
    final start =
        (section.startMs / fingerprint.durationMs * fingerprint.windowCount)
            .floor()
            .clamp(0, fingerprint.windowCount - 1);
    final end =
        (section.endMs / fingerprint.durationMs * fingerprint.windowCount)
            .ceil()
            .clamp(start + 1, fingerprint.windowCount);
    return AudioFingerprint(
      durationMs: section.endMs - section.startMs,
      features: fingerprint.features.map(
        (name, values) => MapEntry(name, values.sublist(start, end)),
      ),
    );
  }

  _SimilarityResult _similarity(
      AudioFingerprint query, AudioFingerprint target) {
    if (query.windowCount == 0 || target.windowCount == 0) {
      return const _SimilarityResult(confidence: 0, offset: null);
    }
    final shorter = query.windowCount <= target.windowCount ? query : target;
    final longer = identical(shorter, query) ? target : query;
    if (shorter.windowCount < 4) {
      return const _SimilarityResult(confidence: 0, offset: null);
    }

    var best = 0.0;
    var bestOffset = 0;
    final maxOffset = max(0, longer.windowCount - shorter.windowCount);
    final coarseStep = max(1, shorter.windowCount ~/ 24);
    for (var offset = 0; offset <= maxOffset; offset += coarseStep) {
      final score = _windowSimilarity(shorter, longer, offset);
      if (score > best) {
        best = score;
        bestOffset = offset;
      }
    }
    if (maxOffset > 0) {
      final score = _windowSimilarity(shorter, longer, maxOffset);
      if (score > best) {
        best = score;
        bestOffset = maxOffset;
      }
    }
    final refineStart = max(0, bestOffset - coarseStep);
    final refineEnd = min(maxOffset, bestOffset + coarseStep);
    for (var offset = refineStart; offset <= refineEnd; offset += 1) {
      final score = _windowSimilarity(shorter, longer, offset);
      if (score > best) {
        best = score;
        bestOffset = offset;
      }
    }
    final durationRatio = min(query.durationMs, target.durationMs) /
        max(query.durationMs, target.durationMs);
    final confidence = (best * .9) + (durationRatio * .1);
    final offset = identical(longer, query) ? bestOffset : 0;
    final featureScores = _windowFeatureScores(shorter, longer, bestOffset);
    return _SimilarityResult(
      confidence: confidence.clamp(0.0, 1.0).toDouble(),
      offset: offset,
      featureScores: featureScores,
    );
  }

  double _windowSimilarity(
      AudioFingerprint left, AudioFingerprint right, int offset) {
    final featureNames = left.features.keys
        .where((name) => right.features.containsKey(name))
        .toList(growable: false);
    if (featureNames.isEmpty) return 0;
    var weightedScore = 0.0;
    var totalWeight = 0.0;
    for (final name in featureNames) {
      final leftValues = left.features[name]!;
      final rightValues = right.features[name]!;
      if (leftValues.isEmpty ||
          rightValues.length < leftValues.length + offset) {
        continue;
      }
      final weight = _featureWeight(name);
      var difference = 0.0;
      for (var index = 0; index < leftValues.length; index += 1) {
        difference += (leftValues[index] - rightValues[index + offset]).abs();
      }
      final averageDifference = difference / leftValues.length;
      weightedScore += (1 - averageDifference).clamp(0.0, 1.0) * weight;
      totalWeight += weight;
    }
    return totalWeight == 0 ? 0 : weightedScore / totalWeight;
  }

  Map<String, double> _windowFeatureScores(
      AudioFingerprint left, AudioFingerprint right, int offset) {
    final scores = <String, double>{};
    final featureNames = left.features.keys
        .where((name) => right.features.containsKey(name))
        .toList(growable: false);
    for (final name in featureNames) {
      final leftValues = left.features[name]!;
      final rightValues = right.features[name]!;
      if (leftValues.isEmpty ||
          rightValues.length < leftValues.length + offset) {
        continue;
      }
      var difference = 0.0;
      for (var index = 0; index < leftValues.length; index += 1) {
        difference += (leftValues[index] - rightValues[index + offset]).abs();
      }
      scores[name] =
          (1 - (difference / leftValues.length)).clamp(0.0, 1.0).toDouble();
    }
    return scores;
  }

  int? _offsetMsFor(int? offset, AudioFingerprint fingerprint) {
    if (offset == null || fingerprint.windowCount == 0) return null;
    return (offset / fingerprint.windowCount * fingerprint.durationMs).round();
  }

  static int _readSignedSample(List<int> pcmBytes, int sample) {
    final low = pcmBytes[sample * 2];
    final high = pcmBytes[sample * 2 + 1];
    var value = low | (high << 8);
    if (value >= 0x8000) value -= 0x10000;
    return value;
  }

  static List<double> _normalize(List<double> values) {
    if (values.isEmpty) return const <double>[];
    final minimum =
        values.reduce((smallest, value) => value < smallest ? value : smallest);
    final maximum =
        values.reduce((largest, value) => value > largest ? value : largest);
    final range = maximum - minimum;
    if (range <= 0) {
      final constant = maximum == 0 ? 0.0 : 1.0;
      return values.map((_) => constant).toList(growable: false);
    }
    return values
        .map((value) => (value - minimum) / range)
        .toList(growable: false);
  }

  double _featureWeight(String name) => switch (name) {
        'energy' => 1.25,
        'attack' => 1.15,
        'lowMotion' => .9,
        'highMotion' => .8,
        'zeroCrossing' => .65,
        'peaks' => .55,
        _ => .5,
      };

  bool _isJamRecording(Recording recording) =>
      recording.title?.trim().toLowerCase() == 'jam';
}

class FingerprintSuggestionRepository {
  static const _filename = '.riffnotes.fingerprint-suggestions.json';

  Future<List<FingerprintMatch>> load(String practiceFolder) async {
    final file = File(path.join(practiceFolder, _filename));
    if (!await file.exists()) return const <FingerprintMatch>[];
    try {
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (decoded['matches'] as List<dynamic>? ?? const <dynamic>[])
          .cast<Map<String, dynamic>>()
          .map(FingerprintMatch.fromJson)
          .toList(growable: false);
    } on FormatException {
      return const <FingerprintMatch>[];
    } on TypeError {
      return const <FingerprintMatch>[];
    }
  }

  Future<void> save(
      String practiceFolder, List<FingerprintMatch> matches) async {
    final file = File(path.join(practiceFolder, _filename));
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      encoder.convert(<String, dynamic>{
        'version': 2,
        'matches': matches.map((item) => item.toJson()).toList(),
      }),
      flush: true,
    );
  }

  Future<void> clear(String practiceFolder) async {
    final file = File(path.join(practiceFolder, _filename));
    if (await file.exists()) await file.delete();
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

  Future<void> clear(String practiceFolder) async {
    final file = File(path.join(practiceFolder, _filename));
    if (await file.exists()) await file.delete();
  }
}

class FingerprintLearningRepository {
  static const _filename = '.riffnotes.fingerprint-learning.json';

  Future<FingerprintLearning> load(String mastersFolder) async {
    final file = File(path.join(mastersFolder, _filename));
    if (!await file.exists()) return const FingerprintLearning();
    try {
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return FingerprintLearning(
        examples: (decoded['examples'] as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<String, dynamic>>()
            .map(FingerprintLearningExample.fromJson)
            .toList(growable: false),
      );
    } on FormatException {
      return const FingerprintLearning();
    } on TypeError {
      return const FingerprintLearning();
    }
  }

  Future<void> recordAccepted(
      String mastersFolder, FingerprintMatch match) async {
    await _append(mastersFolder, match, accepted: true);
  }

  Future<void> recordIgnored(
      String mastersFolder, FingerprintMatch match) async {
    await _append(mastersFolder, match, accepted: false);
  }

  Future<void> _append(
    String mastersFolder,
    FingerprintMatch match, {
    required bool accepted,
  }) async {
    final learning = await load(mastersFolder);
    final examples = learning.examples.toList()
      ..add(FingerprintLearningExample(
        masterRecordingId: match.masterRecordingId,
        sectionLabel: match.sectionLabel,
        accepted: accepted,
        confidence: match.confidence,
        recordedAt: DateTime.now().toUtc(),
      ));
    final file = File(path.join(mastersFolder, _filename));
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      encoder.convert(<String, dynamic>{
        'version': 1,
        'examples': examples.map((item) => item.toJson()).toList(),
      }),
      flush: true,
    );
  }
}

class FingerprintLearning {
  const FingerprintLearning(
      {this.examples = const <FingerprintLearningExample>[]});

  final List<FingerprintLearningExample> examples;

  double adjustmentFor({
    required String masterRecordingId,
    required String? sectionLabel,
  }) {
    var accepted = 0;
    var ignored = 0;
    for (final example in examples) {
      if (example.masterRecordingId != masterRecordingId) continue;
      final sameSection = example.sectionLabel == sectionLabel;
      final sameSongWholeTrack =
          sectionLabel == null || example.sectionLabel == null;
      if (!sameSection && !sameSongWholeTrack) continue;
      if (example.accepted) {
        accepted += sameSection ? 2 : 1;
      } else {
        ignored += sameSection ? 2 : 1;
      }
    }
    final boost = min(.10, accepted * .015);
    final penalty = min(.14, ignored * .025);
    return boost - penalty;
  }
}

class FingerprintLearningExample {
  const FingerprintLearningExample({
    required this.masterRecordingId,
    required this.sectionLabel,
    required this.accepted,
    required this.confidence,
    required this.recordedAt,
  });

  final String masterRecordingId;
  final String? sectionLabel;
  final bool accepted;
  final double confidence;
  final DateTime recordedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'masterRecordingId': masterRecordingId,
        'sectionLabel': sectionLabel,
        'accepted': accepted,
        'confidence': confidence,
        'recordedAt': recordedAt.toIso8601String(),
      };

  factory FingerprintLearningExample.fromJson(Map<String, dynamic> json) =>
      FingerprintLearningExample(
        masterRecordingId: json['masterRecordingId'] as String,
        sectionLabel: json['sectionLabel'] as String?,
        accepted: json['accepted'] as bool,
        confidence: (json['confidence'] as num).toDouble(),
        recordedAt: DateTime.parse(json['recordedAt'] as String),
      );
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
  const AudioFingerprint({required this.durationMs, required this.features});

  final int durationMs;
  final Map<String, List<double>> features;

  List<double> get values => features['energy'] ?? const <double>[];

  int get windowCount =>
      features.values.isEmpty ? 0 : features.values.first.length;
}

enum FingerprintTargetType { song, section }

class FingerprintMatch {
  const FingerprintMatch({
    required this.recordingId,
    required this.recordingFilename,
    required this.masterRecordingId,
    required this.masterFilename,
    required this.masterTitle,
    required this.sectionLabel,
    required this.confidence,
    this.rawConfidence,
    this.confidenceMargin = 0,
    this.learningAdjustment = 0,
    this.sectionSongPenalty = 0,
    this.songConfidence,
    this.matchOffsetMs,
    this.targetType = FingerprintTargetType.song,
    this.featureScores = const <String, double>{},
  });

  final String recordingId;
  final String recordingFilename;
  final String masterRecordingId;
  final String masterFilename;
  final String? masterTitle;
  final String? sectionLabel;
  final double confidence;
  final double? rawConfidence;
  final double confidenceMargin;
  final double learningAdjustment;
  final double sectionSongPenalty;
  final double? songConfidence;
  final int? matchOffsetMs;
  final FingerprintTargetType targetType;
  final Map<String, double> featureScores;

  FingerprintMatch copyWith({
    double? confidence,
    double? rawConfidence,
    double? confidenceMargin,
    double? learningAdjustment,
    double? sectionSongPenalty,
    double? songConfidence,
    int? matchOffsetMs,
    FingerprintTargetType? targetType,
    Map<String, double>? featureScores,
  }) =>
      FingerprintMatch(
        recordingId: recordingId,
        recordingFilename: recordingFilename,
        masterRecordingId: masterRecordingId,
        masterFilename: masterFilename,
        masterTitle: masterTitle,
        sectionLabel: sectionLabel,
        confidence: confidence ?? this.confidence,
        rawConfidence: rawConfidence ?? this.rawConfidence,
        confidenceMargin: confidenceMargin ?? this.confidenceMargin,
        learningAdjustment: learningAdjustment ?? this.learningAdjustment,
        sectionSongPenalty: sectionSongPenalty ?? this.sectionSongPenalty,
        songConfidence: songConfidence ?? this.songConfidence,
        matchOffsetMs: matchOffsetMs ?? this.matchOffsetMs,
        targetType: targetType ?? this.targetType,
        featureScores: featureScores ?? this.featureScores,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'recordingId': recordingId,
        'recordingFilename': recordingFilename,
        'masterRecordingId': masterRecordingId,
        'masterFilename': masterFilename,
        'masterTitle': masterTitle,
        'sectionLabel': sectionLabel,
        'confidence': confidence,
        'rawConfidence': rawConfidence,
        'confidenceMargin': confidenceMargin,
        'learningAdjustment': learningAdjustment,
        'sectionSongPenalty': sectionSongPenalty,
        'songConfidence': songConfidence,
        'matchOffsetMs': matchOffsetMs,
        'targetType': targetType.name,
        'featureScores': featureScores,
      };

  factory FingerprintMatch.fromJson(Map<String, dynamic> json) =>
      FingerprintMatch(
        recordingId: json['recordingId'] as String,
        recordingFilename: json['recordingFilename'] as String,
        masterRecordingId: json['masterRecordingId'] as String,
        masterFilename: json['masterFilename'] as String,
        masterTitle: json['masterTitle'] as String?,
        sectionLabel: json['sectionLabel'] as String?,
        confidence: (json['confidence'] as num).toDouble(),
        rawConfidence: (json['rawConfidence'] as num?)?.toDouble(),
        confidenceMargin: (json['confidenceMargin'] as num?)?.toDouble() ?? 0,
        learningAdjustment:
            (json['learningAdjustment'] as num?)?.toDouble() ?? 0,
        sectionSongPenalty:
            (json['sectionSongPenalty'] as num?)?.toDouble() ?? 0,
        songConfidence: (json['songConfidence'] as num?)?.toDouble(),
        matchOffsetMs: json['matchOffsetMs'] as int?,
        targetType: FingerprintTargetType.values
                .where((value) => value.name == json['targetType'])
                .firstOrNull ??
            (json['sectionLabel'] == null
                ? FingerprintTargetType.song
                : FingerprintTargetType.section),
        featureScores: (json['featureScores'] as Map<String, dynamic>? ?? {})
            .map((key, value) => MapEntry(key, (value as num).toDouble())),
      );

  String get key =>
      '$recordingId|$masterRecordingId|${sectionLabel ?? ''}|$masterFilename';

  String get displayName {
    final song = masterTitle ?? path.basenameWithoutExtension(masterFilename);
    return sectionLabel == null ? song : '$song / $sectionLabel';
  }

  String get confidenceLabel {
    if (confidence >= .78 && confidenceMargin >= .08) return 'strong';
    if (confidence >= .62 && confidenceMargin >= .04) return 'likely';
    if (confidence >= .50) return 'possible';
    return 'weak';
  }

  String get scoreDetails {
    final pieces = <String>[
      targetType == FingerprintTargetType.section ? 'section' : 'song',
      '${(confidence * 100).round()}% $confidenceLabel',
      'margin ${(confidenceMargin * 100).round()}%',
    ];
    if (rawConfidence != null && (rawConfidence! - confidence).abs() > .004) {
      pieces.add('raw ${(rawConfidence! * 100).round()}%');
    }
    if (learningAdjustment.abs() > .004) {
      final sign = learningAdjustment > 0 ? '+' : '';
      pieces.add('learned $sign${(learningAdjustment * 100).round()}%');
    }
    if (sectionSongPenalty.abs() > .004) {
      pieces.add('song gate -${(sectionSongPenalty * 100).round()}%');
    }
    if (songConfidence != null) {
      pieces.add('song ${(songConfidence! * 100).round()}%');
    }
    if (matchOffsetMs != null && matchOffsetMs! > 0) {
      pieces.add('offset ${_formatMilliseconds(matchOffsetMs!)}');
    }
    return pieces.join(' • ');
  }

  String get diagnosticDetails {
    final lines = <String>[scoreDetails];
    if (featureScores.isNotEmpty) {
      final featureLine = featureScores.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      lines.add(
          'features: ${featureLine.map((entry) => '${entry.key} ${(entry.value * 100).round()}%').join(', ')}');
    }
    return lines.join('\n');
  }

  static String _formatMilliseconds(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
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

class _AlignedSectionCandidate {
  const _AlignedSectionCandidate({
    required this.section,
    required this.confidence,
  });

  final SongSection section;
  final double confidence;
}

class _SimilarityResult {
  const _SimilarityResult({
    required this.confidence,
    required this.offset,
    this.featureScores = const <String, double>{},
  });

  final double confidence;
  final int? offset;
  final Map<String, double> featureScores;
}
