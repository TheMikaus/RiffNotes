import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riffnotes/domain.dart';

void main() {
  test('recognizes only supported audio extensions', () {
    expect(supportedAudioExtensions.contains('.wav'), isTrue);
    expect(supportedAudioExtensions.contains('.mp3'), isTrue);
    expect(supportedAudioExtensions.contains('.flac'), isFalse);
  });

  test('excludes metadata and cache folders from practice discovery', () {
    expect(isPracticeDirectory(Directory(r'C:\Band\.backup')), isFalse);
    expect(isPracticeDirectory(Directory(r'C:\Band\.riffnotes-cache')), isFalse);
    expect(isPracticeDirectory(Directory(r'C:\Band\cache')), isFalse);
    expect(isPracticeDirectory(Directory(r'C:\Band\2026-06-21 Practice')), isTrue);
  });

  test('persists title and Best Take metadata in the practice folder', () async {
    final folder = await Directory.systemTemp.createTemp('riffnotes-practice-');
    addTearDown(() => folder.delete(recursive: true));
    await File('${folder.path}${Platform.pathSeparator}take.wav').writeAsBytes([1, 2, 3]);
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
    expect(File('${folder.path}${Platform.pathSeparator}library.riffnotes.json').existsSync(), isTrue);
  });
}
