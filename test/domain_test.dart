import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riffnotes/annotations.dart';
import 'package:riffnotes/app_preferences.dart';
import 'package:riffnotes/domain.dart';
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
}
