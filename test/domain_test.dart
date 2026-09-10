import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:riffnotes/annotations.dart';
import 'package:riffnotes/atomic_file.dart';
import 'package:riffnotes/app_preferences.dart';
import 'package:riffnotes/audio_processing.dart';
import 'package:riffnotes/domain.dart';
import 'package:riffnotes/fingerprints.dart';
import 'package:riffnotes/sections.dart';
import 'package:riffnotes/sync.dart';
import 'package:riffnotes/waveform.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('recognizes only supported audio extensions', () {
    expect(supportedAudioExtensions.contains('.wav'), isTrue);
    expect(supportedAudioExtensions.contains('.wave'), isTrue);
    expect(supportedAudioExtensions.contains('.mp3'), isTrue);
    expect(supportedAudioExtensions.contains('.flac'), isTrue);
  });

  test('excludes metadata and cache folders from practice discovery', () {
    expect(isPracticeDirectory(Directory(r'C:\Band\.backup')), isFalse);
    expect(
        isPracticeDirectory(Directory(r'C:\Band\.riffnotes-cache')), isFalse);
    expect(isPracticeDirectory(Directory(r'C:\Band\cache')), isFalse);
    expect(isPracticeDirectory(Directory(r'C:\Band\mixed_Down')), isFalse);
    expect(isPracticeDirectory(Directory(r'C:\Band\Masters')), isFalse);
    expect(
        isPracticeDirectory(Directory(r'C:\Band\2026-06-21 Practice')), isTrue);
  });

  test('persists title and Best Take metadata in the practice folder',
      () async {
    final folder = await Directory.systemTemp.createTemp('riffnotes-practice-');
    addTearDown(() => folder.delete(recursive: true));
    await File('${folder.path}${Platform.pathSeparator}take.wav')
        .writeAsBytes([1, 2, 3]);
    final repository = PracticeRepository(currentUser: () => 'Alex');
    final initial = await repository.openPractice(folder);

    final updated = await repository.updateRecording(
      initial,
      initial.recordings.single,
      title: 'New Song Idea',
      isBestTake: true,
    );
    final reloaded = await repository.openPractice(folder);

    expect(updated.recordings.single.title, 'New Song Idea');
    expect(reloaded.recordings.single.title, 'New Song Idea');
    expect(reloaded.recordings.single.isBestTake, isTrue);
    expect(reloaded.recordings.single.id, initial.recordings.single.id);
    expect(
        File('${folder.path}${Platform.pathSeparator}library.riffnotes.json')
            .existsSync(),
        isTrue);
  });

  test('renames titled takes and keeps metadata attached', () async {
    final folder = await Directory.systemTemp.createTemp('riffnotes-rename-');
    addTearDown(() => folder.delete(recursive: true));
    await File('${folder.path}${Platform.pathSeparator}first.wav')
        .writeAsBytes([1]);
    await File('${folder.path}${Platform.pathSeparator}second.mp3')
        .writeAsBytes([2]);
    final repository = PracticeRepository(currentUser: () => 'Alex');
    var practice = await repository.openPractice(folder);
    practice = await repository.updateRecording(
        practice, practice.recordings[0],
        title: 'My Song', isBestTake: true);
    practice = await repository.updateRecording(
        practice, practice.recordings[1],
        title: 'My Song', isBestTake: false);

    final plan = repository.planRename(practice);
    expect(plan.map((proposal) => proposal.targetFilename),
        ['01_My_Song_Take1.wav', '02_My_Song_Take2.mp3']);
    final renamed = await repository.applyRename(practice, plan);

    expect(
        File('${folder.path}${Platform.pathSeparator}01_My_Song_Take1.wav')
            .existsSync(),
        isTrue);
    expect(
        File('${folder.path}${Platform.pathSeparator}02_My_Song_Take2.mp3')
            .existsSync(),
        isTrue);
    expect(renamed.recordings[0].isBestTake, isTrue);
    expect(renamed.recordings[0].title, 'My Song');
  });

  test('hides absent audio files but retains their catalogue entries',
      () async {
    // Behaviour change: this folder used to be pruned to match local disk
    // contents. On a partially synced machine that silently destroyed the
    // titles of takes whose audio had not arrived yet, so absent entries are
    // now retained and only deleteRecording removes them.
    final folder = await Directory.systemTemp.createTemp('riffnotes-stale-');
    addTearDown(() => folder.delete(recursive: true));
    final first = File('${folder.path}${Platform.pathSeparator}first.wav');
    final second = File('${folder.path}${Platform.pathSeparator}second.mp3');
    await first.writeAsBytes([1]);
    await second.writeAsBytes([2]);
    final repository = PracticeRepository(currentUser: () => 'Alex');
    var practice = await repository.openPractice(folder);
    expect(practice.recordings, hasLength(2));

    await second.delete();
    practice = await repository.openPractice(folder);

    expect(practice.recordings, hasLength(1),
        reason: 'the take list still reflects what is actually on disk');
    expect(practice.recordings.single.filename, 'first.wav');
    final catalogue = await File(
            '${folder.path}${Platform.pathSeparator}library.riffnotes.json')
        .readAsString();
    expect(catalogue, contains('first.wav'));
    expect(catalogue, contains('second.mp3'));
  });

  test('keeps recording metadata when an audio file is renamed outside the app',
      () async {
    final folder =
        await Directory.systemTemp.createTemp('riffnotes-external-rename-');
    addTearDown(() => folder.delete(recursive: true));
    final original = File('${folder.path}${Platform.pathSeparator}rough.wav');
    await original.writeAsBytes([1, 2, 3, 4]);
    final repository = PracticeRepository(currentUser: () => 'Alex');
    var practice = await repository.openPractice(folder);
    practice = await repository.updateRecording(
      practice,
      practice.recordings.single,
      title: 'Renamed Song',
      isBestTake: true,
    );
    final originalId = practice.recordings.single.id;

    await original.rename('${folder.path}${Platform.pathSeparator}clean.wav');
    final refreshed = await repository.openPractice(folder);

    expect(refreshed.recordings, hasLength(1));
    expect(refreshed.recordings.single.filename, 'clean.wav');
    expect(refreshed.recordings.single.id, originalId);
    expect(refreshed.recordings.single.title, 'Renamed Song');
    expect(refreshed.recordings.single.isBestTake, isTrue);
  });

  test('stores point and range annotations in a user file', () async {
    final folder = await Directory.systemTemp.createTemp('riffnotes-notes-');
    addTearDown(() => folder.delete(recursive: true));
    final recording = Recording(
        id: 'take-1',
        file: File('${folder.path}${Platform.pathSeparator}take.wav'),
        title: null,
        isBestTake: false);
    final repository = AnnotationRepository();
    await repository.add(
        practiceFolder: folder.path,
        user: 'Alex',
        recording: recording,
        startMs: 1200,
        text: 'Point note');
    await repository.add(
        practiceFolder: folder.path,
        user: 'Alex',
        recording: recording,
        startMs: 3000,
        endMs: 5400,
        text: 'Range note');
    final notes = await repository.loadForUser(folder.path, 'Alex');
    expect(notes, hasLength(2));
    expect(notes[0].isRange, isFalse);
    expect(notes[1].isRange, isTrue);
  });

  test('updates song sections even after their edge has moved', () async {
    final folder = await Directory.systemTemp.createTemp('riffnotes-sections-');
    addTearDown(() async {
      if (await folder.exists()) await folder.delete(recursive: true);
    });
    final repository = SongSectionRepository(currentUser: () => 'Alex');
    const original = SongSection(
        recordingId: 'take-1', startMs: 0, endMs: 10000, label: 'Intro');
    await repository.add(folder.path, original);

    await repository.replace(
        folder.path,
        original,
        const SongSection(
            recordingId: 'take-1', startMs: 0, endMs: 12000, label: 'Intro'));
    await repository.replace(
        folder.path,
        original,
        const SongSection(
            recordingId: 'take-1', startMs: 500, endMs: 12000, label: 'Intro'));

    final sections = await repository.load(folder.path, 'take-1');
    expect(sections, hasLength(1));
    expect(sections.single.startMs, 500);
    expect(sections.single.endMs, 12000);
  });

  test('uploads practice files while skipping cache folders', () async {
    final local = await Directory.systemTemp.createTemp('riffnotes-local-');
    final sync = await Directory.systemTemp.createTemp('riffnotes-sync-');
    addTearDown(() async {
      if (await local.exists()) await local.delete(recursive: true);
      if (await sync.exists()) await sync.delete(recursive: true);
    });
    final practice =
        Directory('${local.path}${Platform.pathSeparator}Practice A');
    await practice.create();
    await File('${practice.path}${Platform.pathSeparator}take.mp3')
        .writeAsBytes([1, 2, 3]);
    await Directory('${practice.path}${Platform.pathSeparator}.riffnotes-cache')
        .create();
    await File(
            '${practice.path}${Platform.pathSeparator}.riffnotes-cache${Platform.pathSeparator}take.waveform.json')
        .writeAsString('{}');

    final result = await PracticeSyncRepository()
        .uploadPractice(practiceFolder: practice, syncRoot: sync);

    expect(result.copiedFiles, 1);
    expect(
        File('${sync.path}${Platform.pathSeparator}Practice A${Platform.pathSeparator}take.mp3')
            .existsSync(),
        isTrue);
    expect(
        File('${sync.path}${Platform.pathSeparator}Practice A${Platform.pathSeparator}.riffnotes-cache${Platform.pathSeparator}take.waveform.json')
            .existsSync(),
        isFalse);
  });

  test('remembers the last selected recording separately per practice',
      () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = AppPreferences();
    await preferences.load();

    await preferences.rememberSelection('2026-06-01', 'take-a');
    await preferences.rememberSelection('2026-06-08', 'take-b');
    await preferences.rememberPractice('2026-06-01');

    expect(preferences.lastPractice, '2026-06-01');
    expect(preferences.lastRecordingForPractice('2026-06-01'), 'take-a');
    expect(preferences.lastRecordingForPractice('2026-06-08'), 'take-b');
  });

  test('remembers playback boost and channel mode per recording', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = AppPreferences();
    await preferences.load();

    await preferences.setBoost('take-a', 9);
    await preferences.setChannelMode('take-a', PlaybackChannelMode.muteLeft);

    expect(preferences.boostFor('take-a'), 9);
    expect(preferences.channelModeFor('take-a'), PlaybackChannelMode.muteLeft);
    expect(preferences.channelModeFor('take-b'), PlaybackChannelMode.stereo);
  });

  test('remembers whether the player panel is collapsed', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = AppPreferences();
    await preferences.load();

    expect(preferences.playerPanelCollapsed, isFalse);

    await preferences.setPlayerPanelCollapsed(true);

    final reloaded = AppPreferences();
    await reloaded.load();
    expect(reloaded.playerPanelCollapsed, isTrue);
  });

  test('reduces signed PCM samples to normalized waveform peaks', () {
    final peaks = WaveformRepository.calculatePeaks(<int>[
      0, 0, // silence
      0xff, 0x7f, // positive peak
      0, 0x80, // negative peak
      0, 0x40, // half amplitude
    ], buckets: 2);

    expect(peaks, hasLength(2));
    expect(peaks[0], closeTo(1, 0.001));
    expect(peaks[1], closeTo(1, 0.001));
  });

  test('calculates normalized audio fingerprints from PCM samples', () {
    final pcm = <int>[];
    for (var i = 0; i < 1600; i += 1) {
      final value = i.isEven ? 12000 : -12000;
      pcm
        ..add(value & 0xff)
        ..add((value >> 8) & 0xff);
    }

    final fingerprint =
        FingerprintRepository.calculateFingerprint(pcm, windowSamples: 800);

    expect(fingerprint, hasLength(2));
    expect(fingerprint.every((value) => value >= 0 && value <= 1), isTrue);
    expect(fingerprint.reduce((a, b) => a > b ? a : b), closeTo(1, .001));
  });

  test('calculates chroma pitch-class features from PCM samples', () {
    List<int> sinePcm(double frequency) {
      final pcm = <int>[];
      const sampleRate = 4000;
      for (var i = 0; i < 1600; i += 1) {
        final sample =
            (sin(2 * pi * frequency * i / sampleRate) * 12000).round();
        pcm
          ..add(sample & 0xff)
          ..add((sample >> 8) & 0xff);
      }
      return pcm;
    }

    final aFingerprint = FingerprintRepository.calculateAudioFingerprint(
        sinePcm(440),
        windowSamples: 800);
    final cFingerprint = FingerprintRepository.calculateAudioFingerprint(
        sinePcm(523.25),
        windowSamples: 800);

    expect(aFingerprint.features.keys.where((key) => key.startsWith('chroma')),
        hasLength(12));
    expect(aFingerprint.features['chroma9']!.reduce(max),
        greaterThan(aFingerprint.features['chroma0']!.reduce(max)));
    expect(cFingerprint.features['chroma0']!.reduce(max),
        greaterThan(cFingerprint.features['chroma9']!.reduce(max)));
  });

  group('fingerprint suggestion actionability', () {
    // Each gate is asserted independently: start from a match that clears every
    // threshold, then trip exactly one gate per case. This keeps the test
    // meaningful when thresholds are re-tuned -- only the constants below move.
    Map<String, double> chromaScores(double agreement) => <String, double>{
          for (var index = 0; index < 12; index += 1)
            'chroma$index': agreement,
        };

    FingerprintMatch songMatch({
      double confidence = .90,
      double confidenceMargin = .10,
      double rawConfidence = .90,
      double chromaAgreement = .80,
      double tempoScale = 1.0,
    }) =>
        FingerprintMatch(
          recordingId: 'take-1',
          recordingFilename: 'take.mp3',
          masterRecordingId: 'master-1',
          masterFilename: 'song.wav',
          masterTitle: 'Song',
          sectionLabel: null,
          confidence: confidence,
          confidenceMargin: confidenceMargin,
          rawConfidence: rawConfidence,
          tempoScale: tempoScale,
          featureScores: chromaScores(chromaAgreement),
        );

    FingerprintMatch sectionMatch({
      double confidence = .90,
      double confidenceMargin = .10,
      double songConfidence = .90,
      double chromaAgreement = .80,
    }) =>
        FingerprintMatch(
          recordingId: 'take-1',
          recordingFilename: 'take.mp3',
          masterRecordingId: 'master-1',
          masterFilename: 'song.wav',
          masterTitle: 'Song',
          sectionLabel: 'Verse',
          confidence: confidence,
          confidenceMargin: confidenceMargin,
          songConfidence: songConfidence,
          targetType: FingerprintTargetType.section,
          featureScores: chromaScores(chromaAgreement),
        );

    test('accepts a song match that clears every gate', () {
      expect(
          FingerprintRepository().isActionableSuggestion(songMatch()), isTrue);
    });

    test('rejects a song match on each individual gate', () {
      final repository = FingerprintRepository();
      expect(repository.isActionableSuggestion(songMatch(confidence: .83)),
          isFalse,
          reason: 'confidence below .84');
      expect(
          repository.isActionableSuggestion(songMatch(confidenceMargin: .02)),
          isFalse,
          reason: 'margin below .03');
      expect(repository.isActionableSuggestion(songMatch(rawConfidence: .81)),
          isFalse,
          reason: 'raw confidence below .82');
      expect(
          repository.isActionableSuggestion(songMatch(chromaAgreement: .49)),
          isFalse,
          reason: 'chroma agreement below .50');
      expect(
          repository.isActionableSuggestion(
              songMatch(tempoScale: 1.09, confidenceMargin: .05)),
          isFalse,
          reason: 'tempo drift above .07 without a margin above .06');
    });

    test('allows large tempo drift when the margin is decisive', () {
      expect(
        FingerprintRepository().isActionableSuggestion(
            songMatch(tempoScale: 1.09, confidenceMargin: .07)),
        isTrue,
      );
    });

    test('treats a match with no feature scores as unproven', () {
      // featureScores defaults to empty, so chroma agreement is 0 and the gate
      // must reject regardless of how high the headline confidence looks.
      expect(
        FingerprintRepository().isActionableSuggestion(const FingerprintMatch(
          recordingId: 'take-1',
          recordingFilename: 'take.mp3',
          masterRecordingId: 'master-1',
          masterFilename: 'song.wav',
          masterTitle: 'Song',
          sectionLabel: null,
          confidence: .99,
          confidenceMargin: .99,
          rawConfidence: .99,
        )),
        isFalse,
      );
    });

    test('accepts a section match that clears every gate', () {
      expect(FingerprintRepository().isActionableSuggestion(sectionMatch()),
          isTrue);
    });

    test('rejects a section match on each individual gate', () {
      final repository = FingerprintRepository();
      expect(repository.isActionableSuggestion(sectionMatch(confidence: .83)),
          isFalse,
          reason: 'confidence below .84');
      expect(
          repository
              .isActionableSuggestion(sectionMatch(confidenceMargin: .02)),
          isFalse,
          reason: 'margin below .03');
      expect(
          repository.isActionableSuggestion(sectionMatch(songConfidence: .79)),
          isFalse,
          reason: 'parent song confidence below .80');
      expect(
          repository
              .isActionableSuggestion(sectionMatch(chromaAgreement: .44)),
          isFalse,
          reason: 'chroma agreement below .45');
    });
  });

  test('persists accepted and ignored fingerprint decisions', () async {
    final folder = await Directory.systemTemp.createTemp('riffnotes-fp-');
    addTearDown(() async {
      if (await folder.exists()) await folder.delete(recursive: true);
    });
    const match = FingerprintMatch(
      recordingId: 'practice-1',
      recordingFilename: 'practice.mp3',
      masterRecordingId: 'master-1',
      masterFilename: 'song.mp3',
      masterTitle: 'The Song',
      sectionLabel: 'Chorus',
      confidence: .82,
    );
    final repository = FingerprintDecisionRepository();

    await repository.ignore(folder.path, match);
    var decisions = await repository.load(folder.path);
    expect(decisions.ignoredKeys, contains(match.key));

    await repository.accept(folder.path, match);
    decisions = await repository.load(folder.path);
    expect(decisions.ignoredKeys, isNot(contains(match.key)));
    expect(decisions.accepted.single.displayName, 'The Song / Chorus');

    await repository.clear(folder.path);
    decisions = await repository.load(folder.path);
    expect(decisions.accepted, isEmpty);
    expect(decisions.ignoredKeys, isEmpty);
  });

  test('clears persisted fingerprint suggestions', () async {
    final folder =
        await Directory.systemTemp.createTemp('riffnotes-fp-suggestions-');
    addTearDown(() async {
      if (await folder.exists()) await folder.delete(recursive: true);
    });
    const match = FingerprintMatch(
      recordingId: 'practice-1',
      recordingFilename: 'practice.mp3',
      masterRecordingId: 'master-1',
      masterFilename: 'song.mp3',
      masterTitle: 'The Song',
      sectionLabel: null,
      confidence: .74,
    );
    final repository = FingerprintSuggestionRepository();

    await repository.save(folder.path, const [match]);
    expect(await repository.load(folder.path), hasLength(1));

    await repository.clear(folder.path);
    expect(await repository.load(folder.path), isEmpty);
  });

  test('persists rich fingerprint match diagnostics', () async {
    final folder =
        await Directory.systemTemp.createTemp('riffnotes-fp-diagnostics-');
    addTearDown(() async {
      if (await folder.exists()) await folder.delete(recursive: true);
    });
    const match = FingerprintMatch(
      recordingId: 'practice-1',
      recordingFilename: 'practice.mp3',
      masterRecordingId: 'master-1',
      masterFilename: 'song.mp3',
      masterTitle: 'The Song',
      sectionLabel: 'Chorus',
      confidence: .74,
      rawConfidence: .71,
      confidenceMargin: .09,
      learningAdjustment: .03,
      sectionSongPenalty: .01,
      songConfidence: .81,
      matchOffsetMs: 42000,
      tempoScale: .96,
      targetType: FingerprintTargetType.section,
      featureScores: {'energy': .8, 'attack': .63},
    );
    final repository = FingerprintSuggestionRepository();

    await repository.save(folder.path, const [match]);
    final loaded = (await repository.load(folder.path)).single;

    expect(loaded.targetType, FingerprintTargetType.section);
    expect(loaded.featureScores['energy'], closeTo(.8, .001));
    expect(loaded.scoreDetails, contains('section'));
    expect(loaded.scoreDetails, contains('song 81%'));
    expect(loaded.scoreDetails, contains('tempo 96%'));
    expect(loaded.diagnosticDetails, contains('energy 80%'));
  });

  test('persists fingerprint correction reports', () async {
    final folder =
        await Directory.systemTemp.createTemp('riffnotes-fp-corrections-');
    addTearDown(() async {
      if (await folder.exists()) await folder.delete(recursive: true);
    });
    final repository = FingerprintCorrectionRepository();
    final correction = FingerprintCorrection(
      recordingId: 'practice-1',
      recordingFilename: 'take.mp3',
      recordingTitle: 'Rough Take',
      practiceName: 'Practice',
      practicePath: folder.path,
      correctType: 'section',
      correctMasterRecordingId: 'master-1',
      correctMasterFilename: 'song.mp3',
      correctMasterTitle: 'The Song',
      correctSectionLabel: 'Chorus',
      notes: 'Guessed verse, should be chorus.',
      report: 'debug report',
      recordedAt: DateTime.utc(2026, 1, 1),
    );

    await repository.add(folder.path, correction);
    final loaded = await repository.load(folder.path);

    expect(loaded, hasLength(1));
    expect(loaded.single.correctType, 'section');
    expect(loaded.single.correctSectionLabel, 'Chorus');
    expect(loaded.single.report, 'debug report');
  });

  test('evaluates fingerprint corrections against current suggestions', () {
    final corrections = [
      FingerprintCorrection(
        recordingId: 'take-1',
        recordingFilename: 'take1.mp3',
        recordingTitle: 'Rough',
        practiceName: 'Practice',
        practicePath: r'C:\Band\Practice',
        correctType: 'whole',
        correctMasterRecordingId: 'master-a',
        correctMasterFilename: 'song-a.wav',
        correctMasterTitle: 'Song A',
        correctSectionLabel: null,
        notes: '',
        report: '',
        recordedAt: DateTime.utc(2026, 1, 1),
      ),
      FingerprintCorrection(
        recordingId: 'take-2',
        recordingFilename: 'take2.mp3',
        recordingTitle: 'Jam',
        practiceName: 'Practice',
        practicePath: r'C:\Band\Practice',
        correctType: 'new',
        correctMasterRecordingId: null,
        correctMasterFilename: null,
        correctMasterTitle: null,
        correctSectionLabel: null,
        notes: '',
        report: '',
        recordedAt: DateTime.utc(2026, 1, 1),
      ),
      FingerprintCorrection(
        recordingId: 'take-3',
        recordingFilename: 'take3.mp3',
        recordingTitle: 'Section',
        practiceName: 'Practice',
        practicePath: r'C:\Band\Practice',
        correctType: 'section',
        correctMasterRecordingId: 'master-b',
        correctMasterFilename: 'song-b.wav',
        correctMasterTitle: 'Song B',
        correctSectionLabel: 'Chorus',
        notes: '',
        report: '',
        recordedAt: DateTime.utc(2026, 1, 1),
      ),
    ];
    const matches = [
      FingerprintMatch(
        recordingId: 'take-1',
        recordingFilename: 'take1.mp3',
        masterRecordingId: 'master-a',
        masterFilename: 'song-a.wav',
        masterTitle: 'Song A',
        sectionLabel: null,
        confidence: .9,
      ),
      FingerprintMatch(
        recordingId: 'take-2',
        recordingFilename: 'take2.mp3',
        masterRecordingId: 'master-a',
        masterFilename: 'song-a.wav',
        masterTitle: 'Song A',
        sectionLabel: null,
        confidence: .8,
      ),
      FingerprintMatch(
        recordingId: 'take-3',
        recordingFilename: 'take3.mp3',
        masterRecordingId: 'master-b',
        masterFilename: 'song-b.wav',
        masterTitle: 'Song B',
        sectionLabel: 'Verse',
        confidence: .7,
      ),
    ];

    final report = FingerprintEvaluation.evaluate(
      appVersion: 'Version test',
      practiceName: 'Practice',
      practicePath: r'C:\Band\Practice',
      mastersPath: r'C:\Band\Masters',
      corrections: corrections,
      matches: matches,
    );

    expect(report.total, 3);
    expect(report.exactCorrect, 1);
    expect(report.songCorrect, 1);
    expect(report.falsePositive, 1);
    expect(report.toText(), contains('Song-level useful: 2'));
    expect(report.toText(), contains('new -> Song A'));
  });

  test('evaluates accepted fingerprint decisions as current answers', () {
    final corrections = [
      FingerprintCorrection(
        recordingId: 'take-1',
        recordingFilename: 'take1.mp3',
        recordingTitle: 'Gone',
        practiceName: 'Practice',
        practicePath: r'C:\Band\Practice',
        correctType: 'whole',
        correctMasterRecordingId: 'master-gone',
        correctMasterFilename: 'gone.wav',
        correctMasterTitle: 'Gone',
        correctSectionLabel: null,
        notes: '',
        report: '',
        recordedAt: DateTime.utc(2026, 1, 1),
      ),
    ];
    final report = FingerprintEvaluation.evaluate(
      appVersion: 'Version test',
      practiceName: 'Practice',
      practicePath: r'C:\Band\Practice',
      mastersPath: r'C:\Band\Masters',
      corrections: corrections,
      matches: const [],
      acceptedDecisions: [
        FingerprintDecision(
          recordingId: 'take-1',
          masterRecordingId: 'master-gone',
          displayName: 'Gone',
          confidence: .88,
          decidedAt: DateTime.utc(2026, 1, 1),
        ),
      ],
    );

    expect(report.exactCorrect, 1);
    expect(report.missed, 0);
    expect(report.toText(), contains('Gone (accepted)'));
  });

  test(
      'records fingerprint learning examples from accepted and ignored matches',
      () async {
    final folder =
        await Directory.systemTemp.createTemp('riffnotes-fp-learning-');
    addTearDown(() async {
      if (await folder.exists()) await folder.delete(recursive: true);
    });
    const match = FingerprintMatch(
      recordingId: 'practice-1',
      recordingFilename: 'practice.mp3',
      masterRecordingId: 'master-1',
      masterFilename: 'song.mp3',
      masterTitle: 'The Song',
      sectionLabel: 'Chorus',
      confidence: .82,
    );
    final repository = FingerprintLearningRepository();

    await repository.recordAccepted(folder.path, match);
    var learning = await repository.load(folder.path);
    expect(learning.examples, hasLength(1));
    expect(
      learning.adjustmentFor(
        masterRecordingId: 'master-1',
        sectionLabel: 'Chorus',
      ),
      greaterThan(0),
    );

    await repository.recordIgnored(folder.path, match);
    learning = await repository.load(folder.path);
    expect(learning.examples, hasLength(2));
    expect(
      learning.adjustmentFor(
        masterRecordingId: 'missing',
        sectionLabel: 'Chorus',
      ),
      0,
    );
  });

  test('keeps fingerprint learning scoped to the exact target', () {
    final learning = FingerprintLearning(examples: [
      FingerprintLearningExample(
        masterRecordingId: 'song-1',
        sectionLabel: null,
        accepted: true,
        confidence: 1,
        recordedAt: DateTime.utc(2026, 1, 1),
      ),
      FingerprintLearningExample(
        masterRecordingId: 'song-1',
        sectionLabel: 'Empty Start',
        accepted: true,
        confidence: 1,
        recordedAt: DateTime.utc(2026, 1, 1),
      ),
      FingerprintLearningExample(
        masterRecordingId: 'song-1',
        sectionLabel: 'Verse',
        accepted: false,
        confidence: .9,
        recordedAt: DateTime.utc(2026, 1, 1),
      ),
    ]);

    expect(
      learning.adjustmentFor(masterRecordingId: 'song-1', sectionLabel: null),
      greaterThan(0),
    );
    expect(
      learning.adjustmentFor(
          masterRecordingId: 'song-1', sectionLabel: 'Chorus'),
      0,
    );
    expect(
      learning.adjustmentFor(
          masterRecordingId: 'song-1', sectionLabel: 'Empty Start'),
      0,
    );
    expect(
      learning.adjustmentFor(
          masterRecordingId: 'song-1', sectionLabel: 'Verse'),
      lessThan(0),
    );
  });


  group('catalogue durability', () {
    Future<Directory> practiceWithTake() async {
      final folder = await Directory.systemTemp.createTemp('riffnotes-cat-');
      addTearDown(() async {
        if (await folder.exists()) await folder.delete(recursive: true);
      });
      await File('${folder.path}${Platform.pathSeparator}take.wav')
          .writeAsBytes([1, 2, 3]);
      return folder;
    }

    File catalogueIn(Directory folder) => File(
        '${folder.path}${Platform.pathSeparator}library.riffnotes.json');

    test('refuses to open a practice whose catalogue is malformed', () async {
      final folder = await practiceWithTake();
      final repository = PracticeRepository(currentUser: () => 'Alex');
      final original = await repository.openPractice(folder);
      final id = original.recordings.single.id;

      await catalogueIn(folder).writeAsString('{"recordings": {"take.wav"');

      await expectLater(
        repository.openPractice(folder),
        throwsA(isA<CatalogueUnreadableException>()),
      );
      // The damaged bytes must survive so the user can still recover them.
      expect(await catalogueIn(folder).readAsString(),
          '{"recordings": {"take.wav"');

      // And once restored, the original id is intact -- notes stay attached.
      await catalogueIn(folder).writeAsString(
          '{"version":1,"recordings":{"take.wav":{"id":"$id"}}}');
      final recovered = await repository.openPractice(folder);
      expect(recovered.recordings.single.id, id);
    });

    test('refuses to open a practice whose catalogue is empty', () async {
      final folder = await practiceWithTake();
      final repository = PracticeRepository(currentUser: () => 'Alex');
      await repository.openPractice(folder);
      await catalogueIn(folder).writeAsString('');

      await expectLater(
        repository.openPractice(folder),
        throwsA(isA<CatalogueUnreadableException>()),
      );
    });

    test('reports an unreadable practice without failing the band folder',
        () async {
      final band = await Directory.systemTemp.createTemp('riffnotes-band-');
      addTearDown(() async {
        if (await band.exists()) await band.delete(recursive: true);
      });
      final good = Directory('${band.path}${Platform.pathSeparator}2026-01-01');
      final bad = Directory('${band.path}${Platform.pathSeparator}2026-02-02');
      await good.create();
      await bad.create();
      await File('${good.path}${Platform.pathSeparator}take.wav')
          .writeAsBytes([1, 2, 3]);
      await File('${bad.path}${Platform.pathSeparator}take.wav')
          .writeAsBytes([1, 2, 3]);
      await catalogueIn(bad).writeAsString('not json at all');

      final practices =
          await PracticeRepository(currentUser: () => 'Alex').discoverBandFolder(band);

      expect(practices, hasLength(2));
      final broken =
          practices.firstWhere((item) => item.name == '2026-02-02');
      final healthy =
          practices.firstWhere((item) => item.name == '2026-01-01');
      expect(broken.isReadable, isFalse);
      expect(broken.loadError, isNotNull);
      expect(healthy.isReadable, isTrue);
      expect(healthy.recordings, hasLength(1));
    });

    test('keeps catalogue entries for takes that are not present locally',
        () async {
      final folder = await practiceWithTake();
      final repository = PracticeRepository(currentUser: () => 'Alex');
      final practice = await repository.openPractice(folder);
      await repository.updateRecording(
        practice,
        practice.recordings.single,
        title: 'Dead Reckoning',
        isBestTake: true,
      );

      // Simulate a partially synced machine: the audio is absent but the
      // catalogue still describes it.
      await File('${folder.path}${Platform.pathSeparator}take.wav').delete();
      final reopened = await repository.openPractice(folder);
      expect(reopened.recordings, isEmpty);

      final persisted = jsonDecode(await catalogueIn(folder).readAsString())
          as Map<String, dynamic>;
      final entries = persisted['recordings'] as Map<String, dynamic>;
      expect(entries.containsKey('take.wav'), isTrue,
          reason: 'pruning here would drop the id mapping on the next upload');
      expect((entries['take.wav'] as Map<String, dynamic>)['id'], isNotNull);

      // When the file arrives, it reattaches to the same id and title.
      await File('${folder.path}${Platform.pathSeparator}take.wav')
          .writeAsBytes([1, 2, 3]);
      final restored = await repository.openPractice(folder);
      expect(restored.recordings.single.title, 'Dead Reckoning');
      expect(restored.recordings.single.isBestTake, isTrue);
    });

    test('deleting a take does remove its catalogue entry', () async {
      final folder = await practiceWithTake();
      final repository = PracticeRepository(currentUser: () => 'Alex');
      final practice = await repository.openPractice(folder);

      await repository.deleteRecording(practice, practice.recordings.single);

      final persisted = jsonDecode(await catalogueIn(folder).readAsString())
          as Map<String, dynamic>;
      expect((persisted['recordings'] as Map<String, dynamic>), isEmpty,
          reason: 'explicit deletion is the one path that may prune');
    });
  });

  group('atomic writes', () {
    test('replaces the target in one step and leaves no temp file', () async {
      final folder = await Directory.systemTemp.createTemp('riffnotes-atomic-');
      addTearDown(() async {
        if (await folder.exists()) await folder.delete(recursive: true);
      });
      final target = File('${folder.path}${Platform.pathSeparator}data.json');
      await target.writeAsString('{"old": true}');

      await writeFileAtomic(target, '{"new": true}');

      expect(await target.readAsString(), '{"new": true}');
      expect(await File('${target.path}.tmp').exists(), isFalse);
    });

    test('creates missing parent directories', () async {
      final folder = await Directory.systemTemp.createTemp('riffnotes-atomic-');
      addTearDown(() async {
        if (await folder.exists()) await folder.delete(recursive: true);
      });
      final sep = Platform.pathSeparator;
      final target = File('${folder.path}${sep}nested${sep}data.json');

      await writeFileAtomic(target, 'ok');

      expect(await target.readAsString(), 'ok');
    });
  });
}
