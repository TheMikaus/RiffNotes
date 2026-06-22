import 'package:flutter_test/flutter_test.dart';
import 'package:riffnotes/domain.dart';

void main() {
  test('recognizes only supported audio extensions', () {
    expect(supportedAudioExtensions.contains('.wav'), isTrue);
    expect(supportedAudioExtensions.contains('.mp3'), isTrue);
    expect(supportedAudioExtensions.contains('.flac'), isFalse);
  });
}
