import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riffnotes/annotations.dart';
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
    expect(supportedAudioExtensions.contains('.mp3'), isTrue);
    expect(supportedAudioExtensions.contains('.flac'), isFalse);
  });

  test('excludes metadata and cache folders from practice discovery', () {
    expect(isPracticeDirectory(Directory(r'C:\Band\.backup')), isFalse);
    expect(
        isPracticeDirectory(Directory(r'C:\Band\.riffnotes-cache')), isFalse);
    expect(isPracticeDirectory(Directory(r'C:\Band\cache')), isFalse);
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
    final repository = PracticeRepository();
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
    final repository = PracticeRepository();
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
    final repository = SongSectionRepository();
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
  });
}
