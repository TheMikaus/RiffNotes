import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:path/path.dart' as path;

import 'domain.dart';
import 'sections.dart';

class FingerprintRepository {
  static const _cacheFolder = '.riffnotes-cache';
  static const _cacheVersion = 4;
  static const _cacheAlgorithm = 'multi-feature-v4-chroma-confidence';
  static const _minimumSuggestionConfidence = .84;
  static const _minimumSuggestionMargin = .03;
  static const _minimumSongRawConfidence = .82;
  static const _minimumSectionConfidence = .84;
  static const _minimumSectionMargin = .03;
  static const _minimumSongConfidenceForSection = .80;
  static const _minimumChromaAgreement = .50;
  static const _sampleRate = 4000;
  static const _windowSamples = 800;
  static const _chromaClasses = 12;
  static const _defaultWeightProfile = <String, double>{
    'chroma': .12,
    'energy': .85,
    'attack': .45,
    'lowMotion': .70,
    'highMotion': .55,
    'zeroCrossing': 1.0,
    'peaks': .10,
  };

  final _learning = FingerprintLearningRepository();
  Map<String, double> _featureWeightProfile =
      Map<String, double>.from(_defaultWeightProfile);

  Future<List<FingerprintMatch>> matchPractice({
    required PracticeFolder practice,
    required Directory mastersFolder,
    int maxResultsPerRecording = 3,
    Set<String> skipRecordingIds = const <String>{},
    bool actionableOnly = true,
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
        if (_isIgnoredSection(section)) continue;
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
        final candidateWithMargin =
            candidate.copyWith(confidenceMargin: margin);
        if (!actionableOnly || isActionableSuggestion(candidateWithMargin)) {
          matches.add(candidateWithMargin);
          addedForRecording += 1;
        }
      }
    }
    return matches;
  }

  Future<List<FingerprintMatch>> matchPracticeInBackground({
    required String practicePath,
    required String mastersPath,
    int maxResultsPerRecording = 3,
    Set<String> skipRecordingIds = const <String>{},
    bool actionableOnly = true,
    Map<String, double> weightProfile = const <String, double>{},
  }) async {
    final skipIds = skipRecordingIds.toList(growable: false);
    final encodedWeightProfile = Map<String, double>.from(weightProfile);
    final encoded = await Isolate.run<List<Map<String, dynamic>>>(() async {
      final repository = FingerprintRepository();
      if (encodedWeightProfile.isNotEmpty) {
        repository.setFeatureWeightProfile(encodedWeightProfile);
      }
      final practiceFolder =
          await PracticeRepository().openPractice(Directory(practicePath));
      final matches = await repository.matchPractice(
        practice: practiceFolder,
        mastersFolder: Directory(mastersPath),
        maxResultsPerRecording: maxResultsPerRecording,
        skipRecordingIds: skipIds.toSet(),
        actionableOnly: actionableOnly,
      );
      return matches.map((item) => item.toJson()).toList(growable: false);
    });
    return encoded
        .map((item) => FingerprintMatch.fromJson(item))
        .toList(growable: false);
  }

  static Map<String, double> defaultFeatureWeightProfile() =>
      Map<String, double>.from(_defaultWeightProfile);

  Map<String, double> featureWeightProfile() =>
      Map<String, double>.from(_featureWeightProfile);

  void setFeatureWeightProfile(Map<String, double> profile) {
    final next = <String, double>{};
    for (final entry in _defaultWeightProfile.entries) {
      final raw = profile[entry.key];
      next[entry.key] = raw == null ? entry.value : raw.clamp(0.0, 2.5);
    }
    _featureWeightProfile = next;
  }

  void resetFeatureWeightProfile() {
    _featureWeightProfile = Map<String, double>.from(_defaultWeightProfile);
  }

  bool isActionableSuggestion(FingerprintMatch match) {
    final chromaAgreement = _chromaAgreement(match.featureScores);
    if (match.targetType == FingerprintTargetType.song) {
      if (match.confidence < _minimumSuggestionConfidence) return false;
      if (match.confidenceMargin < _minimumSuggestionMargin) return false;
      if ((match.rawConfidence ?? 0) < _minimumSongRawConfidence) {
        return false;
      }
      if (chromaAgreement < _minimumChromaAgreement) return false;
      final tempoDrift = (match.tempoScale - 1.0).abs();
      if (tempoDrift > .07 && match.confidenceMargin < .06) return false;
      return true;
    }

    if (match.confidence < _minimumSectionConfidence) return false;
    if (match.confidenceMargin < _minimumSectionMargin) return false;
    if ((match.songConfidence ?? 0) < _minimumSongConfidenceForSection) {
      return false;
    }
    if (chromaAgreement < .45) return false;
    return true;
  }

  String actionabilitySummary(FingerprintMatch match) {
    final chromaAgreement = _chromaAgreement(match.featureScores);
    if (match.targetType == FingerprintTargetType.song) {
      final confidencePass = match.confidence >= _minimumSuggestionConfidence;
      final marginPass = match.confidenceMargin >= _minimumSuggestionMargin;
      final raw = match.rawConfidence ?? 0;
      final rawPass = raw >= _minimumSongRawConfidence;
      final chromaPass = chromaAgreement >= _minimumChromaAgreement;
      final tempoDrift = (match.tempoScale - 1.0).abs();
      final tempoPass = !(tempoDrift > .07 && match.confidenceMargin < .06);
      final failures = <String>[];
      if (!confidencePass) failures.add('confidence');
      if (!marginPass) failures.add('margin');
      if (!rawPass) failures.add('raw');
      if (!chromaPass) failures.add('chroma');
      if (!tempoPass) failures.add('tempo');
      return 'actionable=${failures.isEmpty}; conf=${(match.confidence * 100).toStringAsFixed(1)}%/${(_minimumSuggestionConfidence * 100).toStringAsFixed(1)}%; margin=${(match.confidenceMargin * 100).toStringAsFixed(1)}%/${(_minimumSuggestionMargin * 100).toStringAsFixed(1)}%; raw=${(raw * 100).toStringAsFixed(1)}%/${(_minimumSongRawConfidence * 100).toStringAsFixed(1)}%; chroma=${(chromaAgreement * 100).toStringAsFixed(1)}%/${(_minimumChromaAgreement * 100).toStringAsFixed(1)}%; tempoDrift=${(tempoDrift * 100).toStringAsFixed(1)}%; fails=${failures.isEmpty ? 'none' : failures.join(',')}';
    }

    final confidencePass = match.confidence >= _minimumSectionConfidence;
    final marginPass = match.confidenceMargin >= _minimumSectionMargin;
    final song = match.songConfidence ?? 0;
    final songPass = song >= _minimumSongConfidenceForSection;
    final chromaPass = chromaAgreement >= .45;
    final failures = <String>[];
    if (!confidencePass) failures.add('confidence');
    if (!marginPass) failures.add('margin');
    if (!songPass) failures.add('songConfidence');
    if (!chromaPass) failures.add('chroma');
    return 'actionable=${failures.isEmpty}; conf=${(match.confidence * 100).toStringAsFixed(1)}%/${(_minimumSectionConfidence * 100).toStringAsFixed(1)}%; margin=${(match.confidenceMargin * 100).toStringAsFixed(1)}%/${(_minimumSectionMargin * 100).toStringAsFixed(1)}%; song=${(song * 100).toStringAsFixed(1)}%/${(_minimumSongConfidenceForSection * 100).toStringAsFixed(1)}%; chroma=${(chromaAgreement * 100).toStringAsFixed(1)}%/45.0%; fails=${failures.isEmpty ? 'none' : failures.join(',')}';
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
    final chromaPenalty = _chromaPenalty(
      score.featureScores,
      targetType: targetType,
    );
    final tempoPenalty = _tempoPenalty(score.tempoScale);
    final adjustedConfidence = (score.confidence +
            adjustment -
            sectionPenalty -
            chromaPenalty -
            tempoPenalty)
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
      tempoScale: score.tempoScale,
      targetType: targetType,
      featureScores: score.featureScores,
    );
  }

  Future<FingerprintMatch?> bestSongMatchForRecording({
    required Directory practiceFolder,
    required Recording recording,
    required Directory mastersFolder,
    required List<Recording> candidateMasters,
    double minimumConfidence = .45,
  }) async {
    if (candidateMasters.isEmpty) return null;
    final learning = await _learning.load(mastersFolder.path);
    final recordingFingerprint =
        await loadOrGenerateFingerprint(practiceFolder, recording);
    if (recordingFingerprint.windowCount < 8) return null;

    final candidates = <FingerprintMatch>[];
    for (final master in candidateMasters) {
      if (_isJamRecording(master)) continue;
      final masterFingerprint =
          await loadOrGenerateFingerprint(mastersFolder, master);
      if (masterFingerprint.windowCount < 8) continue;
      final alignment =
          _bestSubsequenceAlignment(recordingFingerprint, masterFingerprint);
      if (alignment == null) continue;
      final adjustment = learning.adjustmentFor(
        masterRecordingId: master.id,
        sectionLabel: null,
      );
      final chromaPenalty = _chromaPenalty(
        alignment.featureScores,
        targetType: FingerprintTargetType.song,
      );
      final tempoPenalty = _tempoPenalty(alignment.tempoScale);
      final adjustedConfidence =
          (alignment.confidence + adjustment - chromaPenalty - tempoPenalty)
              .clamp(0.0, 1.0)
              .toDouble();
      final match = FingerprintMatch(
        recordingId: recording.id,
        recordingFilename: recording.filename,
        masterRecordingId: master.id,
        masterFilename: master.filename,
        masterTitle: master.title,
        sectionLabel: null,
        confidence: adjustedConfidence,
        rawConfidence: alignment.confidence,
        learningAdjustment: adjustment,
        matchOffsetMs:
            _windowToMs(alignment.targetStartWindow, alignment.scaledTarget),
        tempoScale: alignment.tempoScale,
        targetType: FingerprintTargetType.song,
        featureScores: alignment.featureScores,
      );
      candidates.add(match);
    }

    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.confidence.compareTo(a.confidence));
    final best = candidates.first;
    if (best.confidence < minimumConfidence) return null;
    final nextConfidence =
        candidates.length > 1 ? candidates[1].confidence : 0.0;
    final margin = (best.confidence - nextConfidence).clamp(0.0, 1.0);
    return best.copyWith(confidenceMargin: margin);
  }

  Future<Map<String, List<Map<String, dynamic>>>>
      labelSectionsForSongInBackground({
    required String practicePath,
    required String mastersPath,
    required String songTitle,
    required double minimumSectionConfidence,
    List<String> recordingIds = const <String>[],
    String? preferredMasterRecordingId,
    bool enforceUniqueSectionLabels = true,
  }) async {
    final selectedRecordingIds = recordingIds.toList(growable: false);
    return Isolate.run(() async {
      final repository = FingerprintRepository();
      final practice =
          await PracticeRepository().openPractice(Directory(practicePath));
      final masters =
          await PracticeRepository().openPractice(Directory(mastersPath));
      final normalizedTitle = _normalizedSongTitle(songTitle);
      if (normalizedTitle.isEmpty) {
        return const <String, List<Map<String, dynamic>>>{};
      }

      final candidateMasters = <Recording>[];
      final sectionsByMaster = <String, List<SongSection>>{};
      for (final master in masters.recordings) {
        if (repository._isJamRecording(master)) continue;
        if (preferredMasterRecordingId != null &&
            master.id != preferredMasterRecordingId) {
          continue;
        }
        if (_normalizedSongTitle(master.title) != normalizedTitle) continue;
        final sections = await SongSectionRepository()
            .load(masters.directory.path, master.id);
        if (sections.isEmpty) continue;
        candidateMasters.add(master);
        sectionsByMaster[master.id] = sections;
      }
      if (candidateMasters.isEmpty) {
        return const <String, List<Map<String, dynamic>>>{};
      }

      final targetRecordingIds =
          selectedRecordingIds.isEmpty ? null : selectedRecordingIds.toSet();
      final encodedResults = <String, List<Map<String, dynamic>>>{};
      for (final recording in practice.recordings) {
        if (repository._isJamRecording(recording)) continue;
        if (_normalizedSongTitle(recording.title) != normalizedTitle) continue;
        if (targetRecordingIds != null &&
            !targetRecordingIds.contains(recording.id)) {
          continue;
        }

        final bestSongMatch = await repository.bestSongMatchForRecording(
          practiceFolder: practice.directory,
          recording: recording,
          mastersFolder: masters.directory,
          candidateMasters: candidateMasters,
        );
        if (bestSongMatch == null) continue;
        final bestMaster = candidateMasters
            .where((item) => item.id == bestSongMatch.masterRecordingId)
            .firstOrNull;
        if (bestMaster == null) continue;
        final masterSections = sectionsByMaster[bestMaster.id] ?? const [];
        if (masterSections.isEmpty) continue;

        final mappedSections = await repository.alignSectionsToRecording(
          practiceFolder: practice.directory,
          recording: recording,
          mastersFolder: masters.directory,
          masterRecording: bestMaster,
          masterSections: masterSections,
          minimumSectionConfidence: minimumSectionConfidence,
          enforceUniqueSectionLabels: enforceUniqueSectionLabels,
        );
        if (mappedSections.isEmpty) continue;
        encodedResults[recording.id] = mappedSections
            .map((section) => section.toJson())
            .toList(growable: false);
      }
      return encodedResults;
    });
  }

  Future<List<SongSection>> alignSectionsToRecording({
    required Directory practiceFolder,
    required Recording recording,
    required Directory mastersFolder,
    required Recording masterRecording,
    required List<SongSection> masterSections,
    double minimumSectionConfidence = .52,
    double maxSectionDurationMultiplier = 1.30,
    bool enforceUniqueSectionLabels = true,
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
    final alignment =
        _bestSubsequenceAlignment(recordingFingerprint, masterFingerprint);
    if (alignment == null || alignment.confidence < minimumSectionConfidence) {
      return const <SongSection>[];
    }

    final projected = <SongSection>[];
    final alignedTargetStart = alignment.targetStartWindow;
    final alignedTargetEnd = alignment.targetEndWindow;
    for (final section in masterSections) {
      final range = _sectionWindowRange(alignment.scaledTarget, section);
      if (range.length < 2) continue;
      final overlapStart = max(range.start, alignedTargetStart);
      final overlapEnd = min(range.end, alignedTargetEnd);
      if (overlapEnd - overlapStart < 2) continue;

      final queryStartWindow = _projectTargetWindowToQuery(
        alignment.path,
        overlapStart,
        preferEarlier: true,
      );
      final queryEndWindow = _projectTargetWindowToQuery(
        alignment.path,
        overlapEnd,
        preferEarlier: false,
      );
      if (queryEndWindow - queryStartWindow < 2) continue;

      final sectionDurationMs = section.endMs - section.startMs;
      final maxSectionDurationMs = max(
        250,
        (sectionDurationMs * maxSectionDurationMultiplier).round(),
      );
      final maxSectionWindowLength = max(
        2,
        (maxSectionDurationMs /
                recordingFingerprint.durationMs *
                recordingFingerprint.windowCount)
            .round(),
      );

      var adjustedQueryStartWindow = queryStartWindow;
      var adjustedQueryEndWindow = queryEndWindow;
      final queryWindowSpan = adjustedQueryEndWindow - adjustedQueryStartWindow;
      if (queryWindowSpan > maxSectionWindowLength) {
        final targetSlice = _sliceFingerprintByWindowRange(
          alignment.scaledTarget,
          overlapStart,
          overlapEnd,
        );
        if (targetSlice.windowCount >= 2) {
          final bestRange = _bestMatchingQueryWindowRange(
            recordingFingerprint: recordingFingerprint,
            targetFingerprint: targetSlice,
            candidateStartWindow: adjustedQueryStartWindow,
            candidateEndWindow: adjustedQueryEndWindow,
            desiredWindowLength: maxSectionWindowLength,
          );
          adjustedQueryStartWindow = bestRange.start;
          adjustedQueryEndWindow = bestRange.end;
        } else {
          adjustedQueryEndWindow =
              adjustedQueryStartWindow + maxSectionWindowLength;
        }
      }

      final startMs =
          _windowToMs(adjustedQueryStartWindow, recordingFingerprint)
              .clamp(0, recordingFingerprint.durationMs);
      var endMs = _windowToMs(adjustedQueryEndWindow, recordingFingerprint)
          .clamp(startMs + 1, recordingFingerprint.durationMs);
      if (endMs - startMs > maxSectionDurationMs) {
        endMs = min(
            recordingFingerprint.durationMs, startMs + maxSectionDurationMs);
      }
      if (endMs - startMs < 250) continue;

      projected.add(SongSection(
        recordingId: recording.id,
        startMs: startMs,
        endMs: endMs,
        label: section.label,
        colorIndex: section.colorIndex,
      ));
    }

    if (projected.isEmpty) return const <SongSection>[];
    projected.sort((a, b) => a.startMs.compareTo(b.startMs));
    final accepted = <SongSection>[];
    final usedLabels = <String>{};
    for (final section in projected) {
      final normalizedLabel = section.label.trim().toLowerCase();
      if (enforceUniqueSectionLabels &&
          normalizedLabel.isNotEmpty &&
          usedLabels.contains(normalizedLabel)) {
        continue;
      }
      if (accepted.isEmpty) {
        accepted.add(section);
        if (enforceUniqueSectionLabels && normalizedLabel.isNotEmpty) {
          usedLabels.add(normalizedLabel);
        }
        continue;
      }
      final previous = accepted.last;
      if (section.startMs >= previous.endMs) {
        accepted.add(section);
        if (enforceUniqueSectionLabels && normalizedLabel.isNotEmpty) {
          usedLabels.add(normalizedLabel);
        }
        continue;
      }
      if (section.endMs <= previous.endMs) {
        continue;
      }
      final adjustedStart = previous.endMs;
      if (section.endMs - adjustedStart < 250) continue;
      accepted.add(SongSection(
        recordingId: section.recordingId,
        startMs: adjustedStart,
        endMs: section.endMs,
        label: section.label,
        colorIndex: section.colorIndex,
      ));
      if (enforceUniqueSectionLabels && normalizedLabel.isNotEmpty) {
        usedLabels.add(normalizedLabel);
      }
    }
    return accepted;
  }

  _SubsequenceAlignment? _bestSubsequenceAlignment(
    AudioFingerprint query,
    AudioFingerprint target,
  ) {
    if (query.windowCount < 4 || target.windowCount < 4) return null;
    const tempoScales = <double>[.92, .96, 1.0, 1.04, 1.08];
    _SubsequenceAlignment? best;
    for (final tempoScale in tempoScales) {
      final scaledTarget =
          tempoScale == 1.0 ? target : _resampleFingerprint(target, tempoScale);
      if (scaledTarget.windowCount < 4) continue;
      final alignment =
          _subsequenceAlignmentAtCurrentTempo(query, scaledTarget, tempoScale);
      if (alignment == null) continue;
      if (best == null || alignment.confidence > best.confidence) {
        best = alignment;
      }
    }
    return best;
  }

  _SubsequenceAlignment? _subsequenceAlignmentAtCurrentTempo(
    AudioFingerprint query,
    AudioFingerprint target,
    double tempoScale,
  ) {
    final queryWindows = query.windowCount;
    final targetWindows = target.windowCount;
    if (queryWindows < 4 || targetWindows < 4) return null;

    const stretchPenalty = .015;
    const epsilon = 1e-9;
    final cost = List<List<double>>.generate(
      queryWindows + 1,
      (_) => List<double>.filled(targetWindows + 1, double.infinity),
    );
    final steps = List<List<int>>.generate(
      queryWindows + 1,
      (_) => List<int>.filled(targetWindows + 1, 1 << 30),
    );
    final back = List<List<int>>.generate(
      queryWindows + 1,
      (_) => List<int>.filled(targetWindows + 1, -1),
    );

    for (var targetIndex = 0; targetIndex <= targetWindows; targetIndex += 1) {
      cost[0][targetIndex] = 0;
      steps[0][targetIndex] = 0;
    }

    for (var queryIndex = 1; queryIndex <= queryWindows; queryIndex += 1) {
      for (var targetIndex = 1;
          targetIndex <= targetWindows;
          targetIndex += 1) {
        final localCost = 1 -
            _windowPairSimilarity(
              query,
              queryIndex - 1,
              target,
              targetIndex - 1,
            );

        var bestPreviousCost = cost[queryIndex - 1][targetIndex - 1];
        var bestPreviousSteps = steps[queryIndex - 1][targetIndex - 1];
        var bestDirection = 0;

        final upCost = cost[queryIndex - 1][targetIndex] + stretchPenalty;
        final upSteps = steps[queryIndex - 1][targetIndex];
        if (upCost < bestPreviousCost - epsilon ||
            ((upCost - bestPreviousCost).abs() <= epsilon &&
                upSteps < bestPreviousSteps)) {
          bestPreviousCost = upCost;
          bestPreviousSteps = upSteps;
          bestDirection = 1;
        }

        final leftCost = cost[queryIndex][targetIndex - 1] + stretchPenalty;
        final leftSteps = steps[queryIndex][targetIndex - 1];
        if (leftCost < bestPreviousCost - epsilon ||
            ((leftCost - bestPreviousCost).abs() <= epsilon &&
                leftSteps < bestPreviousSteps)) {
          bestPreviousCost = leftCost;
          bestPreviousSteps = leftSteps;
          bestDirection = 2;
        }

        cost[queryIndex][targetIndex] = localCost + bestPreviousCost;
        steps[queryIndex][targetIndex] = bestPreviousSteps + 1;
        back[queryIndex][targetIndex] = bestDirection;
      }
    }

    var bestEndTarget = -1;
    var bestAverageCost = double.infinity;
    for (var targetIndex = 1; targetIndex <= targetWindows; targetIndex += 1) {
      final stepCount = steps[queryWindows][targetIndex];
      if (stepCount <= 0 || stepCount >= (1 << 30)) continue;
      final averageCost = cost[queryWindows][targetIndex] / stepCount;
      if (averageCost < bestAverageCost) {
        bestAverageCost = averageCost;
        bestEndTarget = targetIndex;
      }
    }
    if (bestEndTarget == -1) return null;

    var queryIndex = queryWindows;
    var targetIndex = bestEndTarget;
    final reversePath = <_AlignmentPoint>[];
    while (queryIndex > 0 && targetIndex > 0) {
      reversePath.add(_AlignmentPoint(
        queryWindow: queryIndex - 1,
        targetWindow: targetIndex - 1,
      ));
      final direction = back[queryIndex][targetIndex];
      switch (direction) {
        case 0:
          queryIndex -= 1;
          targetIndex -= 1;
          break;
        case 1:
          queryIndex -= 1;
          break;
        case 2:
          targetIndex -= 1;
          break;
        default:
          queryIndex = 0;
          targetIndex = 0;
          break;
      }
    }
    if (reversePath.length < 4) return null;

    final path = reversePath.reversed.toList(growable: false);
    final confidence = (1 - bestAverageCost).clamp(0.0, 1.0).toDouble();
    return _SubsequenceAlignment(
      confidence: confidence,
      tempoScale: tempoScale,
      scaledTarget: target,
      path: path,
      featureScores: _pathFeatureScores(query, target, path),
    );
  }

  double _windowPairSimilarity(
    AudioFingerprint left,
    int leftIndex,
    AudioFingerprint right,
    int rightIndex,
  ) {
    final featureNames = left.features.keys
        .where((name) => right.features.containsKey(name))
        .toList(growable: false);
    if (featureNames.isEmpty) return 0;
    var weightedScore = 0.0;
    var totalWeight = 0.0;
    for (final name in featureNames) {
      final leftValues = left.features[name]!;
      final rightValues = right.features[name]!;
      if (leftIndex >= leftValues.length || rightIndex >= rightValues.length) {
        continue;
      }
      final weight = _featureWeight(name);
      if (weight <= 0) continue;
      final similarity =
          (1 - (leftValues[leftIndex] - rightValues[rightIndex]).abs())
              .clamp(0.0, 1.0)
              .toDouble();
      weightedScore += similarity * weight;
      totalWeight += weight;
    }
    return totalWeight == 0 ? 0 : weightedScore / totalWeight;
  }

  Map<String, double> _pathFeatureScores(
    AudioFingerprint query,
    AudioFingerprint target,
    List<_AlignmentPoint> path,
  ) {
    final scores = <String, double>{};
    if (path.isEmpty) return scores;
    final featureNames = query.features.keys
        .where((name) => target.features.containsKey(name))
        .toList(growable: false);
    for (final name in featureNames) {
      final queryValues = query.features[name]!;
      final targetValues = target.features[name]!;
      var total = 0.0;
      var count = 0;
      for (final point in path) {
        if (point.queryWindow >= queryValues.length ||
            point.targetWindow >= targetValues.length) {
          continue;
        }
        total += (1 -
                (queryValues[point.queryWindow] -
                        targetValues[point.targetWindow])
                    .abs())
            .clamp(0.0, 1.0)
            .toDouble();
        count += 1;
      }
      if (count > 0) {
        scores[name] = (total / count).clamp(0.0, 1.0).toDouble();
      }
    }
    return scores;
  }

  _WindowRange _sectionWindowRange(
    AudioFingerprint fingerprint,
    SongSection section,
  ) {
    if (fingerprint.durationMs <= 0 || fingerprint.windowCount == 0) {
      return const _WindowRange(start: 0, end: 0);
    }
    final start =
        (section.startMs / fingerprint.durationMs * fingerprint.windowCount)
            .floor()
            .clamp(0, fingerprint.windowCount - 1);
    final end =
        (section.endMs / fingerprint.durationMs * fingerprint.windowCount)
            .ceil()
            .clamp(start + 1, fingerprint.windowCount);
    return _WindowRange(start: start, end: end);
  }

  int _projectTargetWindowToQuery(
    List<_AlignmentPoint> path,
    int targetWindow, {
    required bool preferEarlier,
  }) {
    if (path.isEmpty) return 0;
    _AlignmentPoint? left;
    _AlignmentPoint? right;
    for (final point in path) {
      if (point.targetWindow <= targetWindow) {
        left = point;
      }
      if (point.targetWindow >= targetWindow) {
        right = point;
        break;
      }
    }
    if (left == null) {
      return path.first.queryWindow;
    }
    if (right == null) {
      return path.last.queryWindow + (preferEarlier ? 0 : 1);
    }
    if (left.targetWindow == right.targetWindow) {
      return preferEarlier
          ? min(left.queryWindow, right.queryWindow)
          : max(left.queryWindow, right.queryWindow) + 1;
    }
    final fraction = (targetWindow - left.targetWindow) /
        (right.targetWindow - left.targetWindow);
    final projected =
        left.queryWindow + ((right.queryWindow - left.queryWindow) * fraction);
    return preferEarlier ? projected.floor() : projected.ceil();
  }

  int _windowToMs(int windowIndex, AudioFingerprint fingerprint) {
    if (fingerprint.windowCount <= 0 || fingerprint.durationMs <= 0) return 0;
    return (windowIndex / fingerprint.windowCount * fingerprint.durationMs)
        .round();
  }

  AudioFingerprint _sliceFingerprintByWindowRange(
    AudioFingerprint fingerprint,
    int startWindow,
    int endWindow,
  ) {
    if (fingerprint.windowCount <= 0 || fingerprint.durationMs <= 0) {
      return const AudioFingerprint(durationMs: 0, features: {});
    }
    final safeStart = startWindow.clamp(0, fingerprint.windowCount - 1);
    final safeEnd = endWindow.clamp(safeStart + 1, fingerprint.windowCount);
    final windowCount = safeEnd - safeStart;
    final durationMs =
        (windowCount / fingerprint.windowCount * fingerprint.durationMs)
            .round()
            .clamp(1, fingerprint.durationMs);
    return AudioFingerprint(
      durationMs: durationMs,
      features: fingerprint.features.map(
        (name, values) => MapEntry(name, values.sublist(safeStart, safeEnd)),
      ),
    );
  }

  _WindowRange _bestMatchingQueryWindowRange({
    required AudioFingerprint recordingFingerprint,
    required AudioFingerprint targetFingerprint,
    required int candidateStartWindow,
    required int candidateEndWindow,
    required int desiredWindowLength,
  }) {
    final maxStart = candidateEndWindow - desiredWindowLength;
    if (maxStart <= candidateStartWindow) {
      return _WindowRange(
        start: candidateStartWindow,
        end: candidateEndWindow,
      );
    }

    var bestStart = candidateStartWindow;
    var bestScore = double.negativeInfinity;
    for (var start = candidateStartWindow; start <= maxStart; start += 1) {
      final end = start + desiredWindowLength;
      final querySlice =
          _sliceFingerprintByWindowRange(recordingFingerprint, start, end);
      final score = _similarity(querySlice, targetFingerprint).confidence;
      if (score > bestScore) {
        bestScore = score;
        bestStart = start;
      }
    }
    return _WindowRange(
      start: bestStart,
      end: bestStart + desiredWindowLength,
    );
  }

  static String _normalizedSongTitle(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return '';
    return trimmed.toLowerCase();
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
    final fingerprint = await Isolate.run<AudioFingerprint>(() {
      return calculateAudioFingerprint(output);
    });
    await cache.parent.create(recursive: true);
    await cache.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'version': _cacheVersion,
        'sourceBytes': sourceStat.size,
        'sourceModifiedMs': sourceStat.modified.millisecondsSinceEpoch,
        'algorithm': _cacheAlgorithm,
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
          decoded['algorithm'] != _cacheAlgorithm ||
          decoded['sampleRate'] != _sampleRate ||
          decoded['windowSamples'] != _windowSamples ||
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
    final chroma = List.generate(_chromaClasses, (_) => <double>[]);
    var previousWindowEnergy = 0.0;

    for (var window = 0; window < windows; window += 1) {
      final start = window * windowSamples;
      final end = min(sampleCount, start + windowSamples);
      final samples = <double>[];
      var absoluteEnergy = 0.0;
      var crossings = 0;
      var highDifference = 0.0;
      var lowAccumulator = 0.0;
      var peakCount = 0;
      var previous = 0.0;
      var smoothed = 0.0;
      for (var sample = start; sample < end; sample += 1) {
        final value = _readSignedSample(pcmBytes, sample) / 32768.0;
        samples.add(value);
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
      final chromaVector = _calculateChromaVector(samples, sampleRate);
      for (var index = 0; index < _chromaClasses; index += 1) {
        chroma[index].add(chromaVector[index]);
      }
      previousWindowEnergy = currentEnergy;
    }

    final features = <String, List<double>>{
      'energy': _normalize(energy),
      'zeroCrossing': _normalize(zeroCrossing),
      'attack': _normalize(attack),
      'lowMotion': _normalize(lowMotion),
      'highMotion': _normalize(highMotion),
      'peaks': _normalize(peaks),
      for (var index = 0; index < _chromaClasses; index += 1)
        'chroma$index': chroma[index],
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
    const tempoScales = <double>[.92, .96, 1.0, 1.04, 1.08];
    _SimilarityResult? best;
    for (final tempoScale in tempoScales) {
      final scaledTarget =
          tempoScale == 1.0 ? target : _resampleFingerprint(target, tempoScale);
      if (scaledTarget.windowCount < 4) continue;
      final result = _similarityAtCurrentTempo(query, scaledTarget)
          .copyWith(tempoScale: tempoScale);
      if (best == null || result.confidence > best.confidence) {
        best = result;
      }
    }
    return best ?? const _SimilarityResult(confidence: 0, offset: null);
  }

  _SimilarityResult _similarityAtCurrentTempo(
      AudioFingerprint query, AudioFingerprint target) {
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

  AudioFingerprint _resampleFingerprint(
      AudioFingerprint fingerprint, double tempoScale) {
    final nextWindowCount =
        max(4, (fingerprint.windowCount * tempoScale).round());
    return AudioFingerprint(
      durationMs: (fingerprint.durationMs * tempoScale).round(),
      features: fingerprint.features.map(
        (name, values) =>
            MapEntry(name, _resampleValues(values, nextWindowCount)),
      ),
    );
  }

  List<double> _resampleValues(List<double> values, int nextLength) {
    if (values.isEmpty || nextLength <= 0) return const <double>[];
    if (values.length == nextLength) return List<double>.of(values);
    if (nextLength == 1) return <double>[values.first];
    final output = <double>[];
    final sourceMax = values.length - 1;
    final targetMax = nextLength - 1;
    for (var index = 0; index < nextLength; index += 1) {
      final sourcePosition = index * sourceMax / targetMax;
      final left = sourcePosition.floor();
      final right = min(sourceMax, left + 1);
      final fraction = sourcePosition - left;
      output.add(values[left] + ((values[right] - values[left]) * fraction));
    }
    return output;
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
      if (weight <= 0) continue;
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

  static List<double> _calculateChromaVector(
      List<double> samples, int sampleRate) {
    if (samples.isEmpty) return List<double>.filled(_chromaClasses, 0);
    final chroma = List<double>.filled(_chromaClasses, 0);
    for (var midi = 40; midi <= 83; midi += 1) {
      final frequency = 440.0 * pow(2, (midi - 69) / 12);
      if (frequency >= sampleRate / 2) continue;
      final magnitude = _goertzelMagnitude(samples, sampleRate, frequency);
      chroma[midi % _chromaClasses] += magnitude;
    }
    final maximum = chroma.reduce(max);
    if (maximum <= 0) return chroma;
    return chroma.map((value) => value / maximum).toList(growable: false);
  }

  static double _goertzelMagnitude(
      List<double> samples, int sampleRate, double frequency) {
    final normalizedFrequency = frequency / sampleRate;
    final coefficient = 2 * cos(2 * pi * normalizedFrequency);
    var previous = 0.0;
    var previous2 = 0.0;
    final sampleCount = samples.length;
    for (var index = 0; index < sampleCount; index += 1) {
      final window = .5 - (.5 * cos(2 * pi * index / max(1, sampleCount - 1)));
      final current =
          (samples[index] * window) + (coefficient * previous) - previous2;
      previous2 = previous;
      previous = current;
    }
    final power = (previous2 * previous2) +
        (previous * previous) -
        (coefficient * previous * previous2);
    return sqrt(max(0, power)) / max(1, sampleCount);
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
        // Keep chroma contribution intentionally modest so it helps
        // disambiguate similar grooves without dominating the score.
        final chroma when chroma.startsWith('chroma') =>
          _featureWeightProfile['chroma'] ?? _defaultWeightProfile['chroma']!,
        'energy' =>
          _featureWeightProfile['energy'] ?? _defaultWeightProfile['energy']!,
        'attack' =>
          _featureWeightProfile['attack'] ?? _defaultWeightProfile['attack']!,
        'lowMotion' => _featureWeightProfile['lowMotion'] ??
            _defaultWeightProfile['lowMotion']!,
        'highMotion' => _featureWeightProfile['highMotion'] ??
            _defaultWeightProfile['highMotion']!,
        'zeroCrossing' => _featureWeightProfile['zeroCrossing'] ??
            _defaultWeightProfile['zeroCrossing']!,
        'peaks' =>
          _featureWeightProfile['peaks'] ?? _defaultWeightProfile['peaks']!,
        _ => .5,
      };

  double featureWeightFor(String name) => _featureWeight(name);

  double _chromaAgreement(Map<String, double> featureScores) {
    var total = 0.0;
    var count = 0;
    for (final entry in featureScores.entries) {
      if (!entry.key.startsWith('chroma')) continue;
      total += entry.value;
      count += 1;
    }
    if (count == 0) return 0;
    return (total / count).clamp(0.0, 1.0).toDouble();
  }

  double _chromaPenalty(
    Map<String, double> featureScores, {
    required FingerprintTargetType targetType,
  }) {
    final chromaAgreement = _chromaAgreement(featureScores);
    final chromaMinimum = _chromaMinimum(featureScores);
    final threshold = targetType == FingerprintTargetType.song ? .58 : .50;
    if (chromaAgreement >= threshold) return 0;
    final multiplier = targetType == FingerprintTargetType.song ? .32 : .18;
    final cap = targetType == FingerprintTargetType.song ? .08 : .04;
    var penalty =
        ((threshold - chromaAgreement) * multiplier).clamp(0.0, cap).toDouble();
    if (targetType == FingerprintTargetType.song && chromaMinimum < .58) {
      // A low floor in one or more chroma bins is a common pattern in
      // brittle wrong-song matches; keep this penalty modest.
      penalty += ((.58 - chromaMinimum) * .22).clamp(0.0, .03).toDouble();
    }
    return penalty.clamp(0.0, cap).toDouble();
  }

  double _chromaMinimum(Map<String, double> featureScores) {
    double? minimum;
    for (final entry in featureScores.entries) {
      if (!entry.key.startsWith('chroma')) continue;
      if (minimum == null || entry.value < minimum) {
        minimum = entry.value;
      }
    }
    return (minimum ?? 0).clamp(0.0, 1.0).toDouble();
  }

  double _tempoPenalty(double tempoScale) {
    final drift = (tempoScale - 1.0).abs();
    if (drift <= .03) return 0;
    return ((drift - .03) * .5).clamp(0.0, .04).toDouble();
  }

  bool _isJamRecording(Recording recording) =>
      recording.title?.trim().toLowerCase() == 'jam';

  bool _isIgnoredSection(SongSection section) {
    return _isIgnoredFingerprintSectionLabel(section.label);
  }
}

bool _isIgnoredFingerprintSectionLabel(String? sectionLabel) {
  if (sectionLabel == null) return false;
  final label = sectionLabel.trim().toLowerCase();
  if (label.isEmpty) return true;
  const ignoredWords = ['empty', 'silence', 'noise', 'talk', 'break'];
  return ignoredWords.any(label.contains);
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

class FingerprintCorrectionRepository {
  static const _filename = '.riffnotes.fingerprint-corrections.json';

  Future<List<FingerprintCorrection>> load(String mastersFolder) async {
    final file = File(path.join(mastersFolder, _filename));
    if (!await file.exists()) return const <FingerprintCorrection>[];
    try {
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (decoded['corrections'] as List<dynamic>? ?? const <dynamic>[])
          .cast<Map<String, dynamic>>()
          .map(FingerprintCorrection.fromJson)
          .toList(growable: false);
    } on FormatException {
      return const <FingerprintCorrection>[];
    } on TypeError {
      return const <FingerprintCorrection>[];
    }
  }

  Future<void> add(
      String mastersFolder, FingerprintCorrection correction) async {
    final corrections = await load(mastersFolder);
    final file = File(path.join(mastersFolder, _filename));
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(
      encoder.convert(<String, dynamic>{
        'version': 1,
        'corrections': <FingerprintCorrection>[
          ...corrections,
          correction,
        ].map((item) => item.toJson()).toList(),
      }),
      flush: true,
    );
  }
}

class FingerprintCorrection {
  const FingerprintCorrection({
    required this.recordingId,
    required this.recordingFilename,
    required this.recordingTitle,
    required this.practiceName,
    required this.practicePath,
    required this.correctType,
    required this.correctMasterRecordingId,
    required this.correctMasterFilename,
    required this.correctMasterTitle,
    required this.correctSectionLabel,
    required this.notes,
    required this.report,
    required this.recordedAt,
  });

  final String recordingId;
  final String recordingFilename;
  final String? recordingTitle;
  final String? practiceName;
  final String? practicePath;
  final String correctType;
  final String? correctMasterRecordingId;
  final String? correctMasterFilename;
  final String? correctMasterTitle;
  final String? correctSectionLabel;
  final String notes;
  final String report;
  final DateTime recordedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'recordingId': recordingId,
        'recordingFilename': recordingFilename,
        'recordingTitle': recordingTitle,
        'practiceName': practiceName,
        'practicePath': practicePath,
        'correctType': correctType,
        'correctMasterRecordingId': correctMasterRecordingId,
        'correctMasterFilename': correctMasterFilename,
        'correctMasterTitle': correctMasterTitle,
        'correctSectionLabel': correctSectionLabel,
        'notes': notes,
        'report': report,
        'recordedAt': recordedAt.toIso8601String(),
      };

  factory FingerprintCorrection.fromJson(Map<String, dynamic> json) =>
      FingerprintCorrection(
        recordingId: json['recordingId'] as String,
        recordingFilename: json['recordingFilename'] as String,
        recordingTitle: json['recordingTitle'] as String?,
        practiceName: json['practiceName'] as String?,
        practicePath: json['practicePath'] as String?,
        correctType: json['correctType'] as String,
        correctMasterRecordingId: json['correctMasterRecordingId'] as String?,
        correctMasterFilename: json['correctMasterFilename'] as String?,
        correctMasterTitle: json['correctMasterTitle'] as String?,
        correctSectionLabel: json['correctSectionLabel'] as String?,
        notes: json['notes'] as String? ?? '',
        report: json['report'] as String? ?? '',
        recordedAt: DateTime.parse(json['recordedAt'] as String),
      );
}

class FingerprintLearning {
  const FingerprintLearning(
      {this.examples = const <FingerprintLearningExample>[]});

  final List<FingerprintLearningExample> examples;

  double adjustmentFor({
    required String masterRecordingId,
    required String? sectionLabel,
  }) {
    if (_isIgnoredFingerprintSectionLabel(sectionLabel)) return 0;
    var accepted = 0;
    var ignored = 0;
    for (final example in examples) {
      if (example.masterRecordingId != masterRecordingId) continue;
      if (_isIgnoredFingerprintSectionLabel(example.sectionLabel)) continue;
      final sameTarget = example.sectionLabel == sectionLabel;
      if (!sameTarget) continue;
      if (example.accepted) {
        accepted += 2;
      } else {
        ignored += 2;
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
    this.tempoScale = 1.0,
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
  final double tempoScale;
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
    double? tempoScale,
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
        tempoScale: tempoScale ?? this.tempoScale,
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
        'tempoScale': tempoScale,
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
        tempoScale: (json['tempoScale'] as num?)?.toDouble() ?? 1.0,
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
    if ((tempoScale - 1.0).abs() > .004) {
      pieces.add('tempo ${(tempoScale * 100).round()}%');
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

class FingerprintEvaluation {
  static FingerprintEvaluationReport evaluate({
    required String appVersion,
    required String practiceName,
    required String practicePath,
    required String mastersPath,
    required List<FingerprintCorrection> corrections,
    required List<FingerprintMatch> matches,
    List<FingerprintDecision> acceptedDecisions = const <FingerprintDecision>[],
  }) {
    final latestCorrections = <String, FingerprintCorrection>{};
    for (final correction in corrections) {
      if (correction.practicePath != practicePath) continue;
      final existing = latestCorrections[correction.recordingId];
      if (existing == null ||
          correction.recordedAt.isAfter(existing.recordedAt)) {
        latestCorrections[correction.recordingId] = correction;
      }
    }
    final matchesByRecording = <String, List<FingerprintMatch>>{};
    for (final match in matches) {
      matchesByRecording.putIfAbsent(match.recordingId, () => []).add(match);
    }
    for (final recordingMatches in matchesByRecording.values) {
      recordingMatches.sort((a, b) => b.confidence.compareTo(a.confidence));
    }
    final acceptedByRecording = <String, FingerprintDecision>{
      for (final decision in acceptedDecisions) decision.recordingId: decision,
    };

    final rows = <FingerprintEvaluationRow>[];
    for (final correction in latestCorrections.values.toList()
      ..sort((a, b) => a.recordingFilename.compareTo(b.recordingFilename))) {
      final recordingMatches =
          matchesByRecording[correction.recordingId] ?? const [];
      final bestMatch = recordingMatches.firstOrNull;
      final acceptedDecision = acceptedByRecording[correction.recordingId];
      rows.add(FingerprintEvaluationRow.fromCorrection(
        correction: correction,
        bestMatch: bestMatch,
        acceptedDecision: acceptedDecision,
        candidateCount: recordingMatches.length,
        candidates: recordingMatches,
      ));
    }
    return FingerprintEvaluationReport(
      appVersion: appVersion,
      practiceName: practiceName,
      practicePath: practicePath,
      mastersPath: mastersPath,
      rows: rows,
    );
  }
}

class FingerprintEvaluationReport {
  const FingerprintEvaluationReport({
    required this.appVersion,
    required this.practiceName,
    required this.practicePath,
    required this.mastersPath,
    required this.rows,
  });

  final String appVersion;
  final String practiceName;
  final String practicePath;
  final String mastersPath;
  final List<FingerprintEvaluationRow> rows;

  int get total => rows.length;
  int get exactCorrect => rows
      .where((row) => row.outcome == FingerprintEvaluationOutcome.exactCorrect)
      .length;
  int get songCorrect => rows
      .where((row) => row.outcome == FingerprintEvaluationOutcome.songCorrect)
      .length;
  int get wrong => rows
      .where((row) => row.outcome == FingerprintEvaluationOutcome.wrong)
      .length;
  int get notSuggested => rows
      .where((row) => row.outcome == FingerprintEvaluationOutcome.notSuggested)
      .length;
  int get missed => rows
      .where((row) => row.outcome == FingerprintEvaluationOutcome.missed)
      .length;
  int get falsePositiveActionable => rows
      .where((row) => row.outcome == FingerprintEvaluationOutcome.falsePositive)
      .length;
  int get falsePositiveNonActionable => rows
      .where((row) =>
          row.outcome ==
          FingerprintEvaluationOutcome.falsePositiveNonActionable)
      .length;
  int get falsePositive => falsePositiveActionable + falsePositiveNonActionable;
  int get correctEnough => exactCorrect + songCorrect;

  double get exactAccuracy => total == 0 ? 0 : exactCorrect / total;
  double get songAccuracy => total == 0 ? 0 : correctEnough / total;

  String toText() {
    final buffer = StringBuffer()
      ..writeln('RiffNotes fingerprint evaluation report')
      ..writeln('Generated: ${DateTime.now().toIso8601String()}')
      ..writeln('App: $appVersion')
      ..writeln('Practice: $practiceName')
      ..writeln('Practice path: $practicePath')
      ..writeln('Masters path: $mastersPath')
      ..writeln('')
      ..writeln('Summary')
      ..writeln('  Corrections evaluated: $total')
      ..writeln('  Exact correct: $exactCorrect (${_percent(exactAccuracy)})')
      ..writeln(
          '  Right song / wrong or extra section: $songCorrect (${_percent(total == 0 ? 0 : songCorrect / total)})')
      ..writeln('  Wrong: $wrong')
      ..writeln('  Not suggested (non-actionable mismatch): $notSuggested')
      ..writeln('  Missed: $missed')
      ..writeln('  False positive on new/jam/unknown: $falsePositive')
      ..writeln('    actionable false positives: $falsePositiveActionable')
      ..writeln(
          '    non-actionable false positives: $falsePositiveNonActionable')
      ..writeln(
          '  Song-level useful: $correctEnough (${_percent(songAccuracy)})')
      ..writeln('');

    final confusionCounts = <String, int>{};
    for (final row in rows) {
      if (row.outcome == FingerprintEvaluationOutcome.exactCorrect ||
          row.outcome == FingerprintEvaluationOutcome.songCorrect) {
        continue;
      }
      final key = '${row.expectedDisplay} -> ${row.actualDisplay}';
      confusionCounts[key] = (confusionCounts[key] ?? 0) + 1;
    }
    if (confusionCounts.isNotEmpty) {
      buffer.writeln('Top confusions');
      final confusions = confusionCounts.entries.toList()
        ..sort((a, b) {
          final byCount = b.value.compareTo(a.value);
          return byCount != 0 ? byCount : a.key.compareTo(b.key);
        });
      for (final entry in confusions.take(12)) {
        buffer.writeln('  ${entry.value}× ${entry.key}');
      }
      buffer.writeln('');
    }

    buffer.writeln('Rows');
    for (final row in rows) {
      buffer
        ..writeln(
            '- ${row.recordingFilename}: ${row.outcome.label.toUpperCase()}')
        ..writeln('    expected: ${row.expectedDisplay}')
        ..writeln('    actual: ${row.actualDisplay}')
        ..writeln('    candidates: ${row.candidateCount}');
      if (row.bestScoreDetails != null) {
        buffer.writeln('    score: ${row.bestScoreDetails}');
      }
      if (row.bestActionable != null) {
        buffer.writeln('    actionable: ${row.bestActionable! ? 'yes' : 'no'}');
      }
      if (row.bestDiagnosticDetails != null &&
          row.bestDiagnosticDetails!.isNotEmpty) {
        buffer.writeln('    diagnostic: ${row.bestDiagnosticDetails}');
      }
      if (row.topCandidatesSummary != null &&
          row.topCandidatesSummary!.isNotEmpty) {
        buffer.writeln('    top candidates: ${row.topCandidatesSummary}');
      }
      if (row.notes.isNotEmpty) {
        buffer.writeln('    notes: ${row.notes}');
      }
    }
    return buffer.toString();
  }

  static String _percent(double value) =>
      '${(value * 100).toStringAsFixed(1)}%';
}

class FingerprintEvaluationRow {
  const FingerprintEvaluationRow({
    required this.recordingId,
    required this.recordingFilename,
    required this.expectedDisplay,
    required this.actualDisplay,
    required this.outcome,
    required this.candidateCount,
    required this.bestScoreDetails,
    required this.bestActionable,
    required this.bestDiagnosticDetails,
    required this.topCandidatesSummary,
    required this.notes,
  });

  final String recordingId;
  final String recordingFilename;
  final String expectedDisplay;
  final String actualDisplay;
  final FingerprintEvaluationOutcome outcome;
  final int candidateCount;
  final String? bestScoreDetails;
  final bool? bestActionable;
  final String? bestDiagnosticDetails;
  final String? topCandidatesSummary;
  final String notes;

  factory FingerprintEvaluationRow.fromCorrection({
    required FingerprintCorrection correction,
    required FingerprintMatch? bestMatch,
    required FingerprintDecision? acceptedDecision,
    required int candidateCount,
    required List<FingerprintMatch> candidates,
  }) {
    final expectsNoMaster = correction.correctType == 'new' ||
        correction.correctType == 'jam' ||
        correction.correctType == 'unknown';
    final expectedDisplay = expectsNoMaster
        ? correction.correctType
        : _expectedCorrectionDisplay(correction);
    final actualDisplay = acceptedDecision == null
        ? bestMatch?.displayName ?? 'no suggestion'
        : '${acceptedDecision.displayName} (accepted)';
    final bestActionable = acceptedDecision == null && bestMatch != null
        ? FingerprintRepository().isActionableSuggestion(bestMatch)
        : null;
    final outcome = _evaluateOutcome(
      correction: correction,
      bestMatch: bestMatch,
      acceptedDecision: acceptedDecision,
      expectsNoMaster: expectsNoMaster,
      bestActionable: bestActionable,
    );
    final topCandidates = acceptedDecision == null
        ? candidates
            .take(3)
            .map((candidate) =>
                '${candidate.displayName} (${candidate.scoreDetails})')
            .join(' | ')
        : null;
    return FingerprintEvaluationRow(
      recordingId: correction.recordingId,
      recordingFilename: correction.recordingFilename,
      expectedDisplay: expectedDisplay,
      actualDisplay: actualDisplay,
      outcome: outcome,
      candidateCount: candidateCount,
      bestScoreDetails: acceptedDecision == null
          ? bestMatch?.scoreDetails
          : 'accepted at ${(acceptedDecision.confidence * 100).round()}%',
      bestActionable: bestActionable,
      bestDiagnosticDetails:
          acceptedDecision == null ? bestMatch?.diagnosticDetails : null,
      topCandidatesSummary: topCandidates,
      notes: correction.notes,
    );
  }

  static String _expectedCorrectionDisplay(FingerprintCorrection correction) {
    final song = correction.correctMasterTitle ??
        correction.correctMasterFilename ??
        correction.correctMasterRecordingId ??
        'unknown master';
    final section = correction.correctSectionLabel;
    return section == null || section.trim().isEmpty
        ? song
        : '$song / $section';
  }

  static FingerprintEvaluationOutcome _evaluateOutcome({
    required FingerprintCorrection correction,
    required FingerprintMatch? bestMatch,
    required FingerprintDecision? acceptedDecision,
    required bool expectsNoMaster,
    required bool? bestActionable,
  }) {
    if (expectsNoMaster) {
      if (acceptedDecision != null) {
        return FingerprintEvaluationOutcome.falsePositive;
      }
      if (bestMatch == null) {
        return FingerprintEvaluationOutcome.exactCorrect;
      }
      return bestActionable == true
          ? FingerprintEvaluationOutcome.falsePositive
          : FingerprintEvaluationOutcome.falsePositiveNonActionable;
    }
    if (acceptedDecision != null) {
      if (acceptedDecision.masterRecordingId !=
          correction.correctMasterRecordingId) {
        return FingerprintEvaluationOutcome.wrong;
      }
      final expectedSection = correction.correctSectionLabel?.trim();
      final expectedDisplay = _expectedCorrectionDisplay(correction);
      if (correction.correctType == 'section' &&
          expectedSection != null &&
          expectedSection.isNotEmpty) {
        return acceptedDecision.displayName == expectedDisplay
            ? FingerprintEvaluationOutcome.exactCorrect
            : FingerprintEvaluationOutcome.songCorrect;
      }
      return FingerprintEvaluationOutcome.exactCorrect;
    }
    if (bestMatch == null) return FingerprintEvaluationOutcome.missed;
    if (bestMatch.masterRecordingId != correction.correctMasterRecordingId) {
      return bestActionable == true
          ? FingerprintEvaluationOutcome.wrong
          : FingerprintEvaluationOutcome.notSuggested;
    }
    final expectedSection = correction.correctSectionLabel?.trim();
    final actualSection = bestMatch.sectionLabel?.trim();
    if (correction.correctType == 'section' &&
        expectedSection != null &&
        expectedSection.isNotEmpty) {
      return actualSection == expectedSection
          ? FingerprintEvaluationOutcome.exactCorrect
          : FingerprintEvaluationOutcome.songCorrect;
    }
    return actualSection == null || actualSection.isEmpty
        ? FingerprintEvaluationOutcome.exactCorrect
        : FingerprintEvaluationOutcome.songCorrect;
  }
}

enum FingerprintEvaluationOutcome {
  exactCorrect('correct'),
  songCorrect('song-correct'),
  wrong('wrong'),
  notSuggested('not-suggested'),
  missed('missed'),
  falsePositive('false-positive'),
  falsePositiveNonActionable('false-positive-non-actionable');

  const FingerprintEvaluationOutcome(this.label);
  final String label;
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

class _AlignmentPoint {
  const _AlignmentPoint({
    required this.queryWindow,
    required this.targetWindow,
  });

  final int queryWindow;
  final int targetWindow;
}

class _WindowRange {
  const _WindowRange({required this.start, required this.end});

  final int start;
  final int end;

  int get length => end - start;
}

class _SubsequenceAlignment {
  const _SubsequenceAlignment({
    required this.confidence,
    required this.tempoScale,
    required this.scaledTarget,
    required this.path,
    required this.featureScores,
  });

  final double confidence;
  final double tempoScale;
  final AudioFingerprint scaledTarget;
  final List<_AlignmentPoint> path;
  final Map<String, double> featureScores;

  int get targetStartWindow => path.first.targetWindow;
  int get targetEndWindow => path.last.targetWindow + 1;
}

class _SimilarityResult {
  const _SimilarityResult({
    required this.confidence,
    required this.offset,
    this.tempoScale = 1.0,
    this.featureScores = const <String, double>{},
  });

  final double confidence;
  final int? offset;
  final double tempoScale;
  final Map<String, double> featureScores;

  _SimilarityResult copyWith({
    double? confidence,
    int? offset,
    double? tempoScale,
    Map<String, double>? featureScores,
  }) =>
      _SimilarityResult(
        confidence: confidence ?? this.confidence,
        offset: offset ?? this.offset,
        tempoScale: tempoScale ?? this.tempoScale,
        featureScores: featureScores ?? this.featureScores,
      );
}
