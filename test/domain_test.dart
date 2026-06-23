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
}
