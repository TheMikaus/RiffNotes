import 'package:flutter_test/flutter_test.dart';
import 'package:riffnotes/app_preferences.dart';
import 'package:riffnotes/audio_controller.dart';
import 'package:riffnotes/audio_processing.dart';
import 'package:riffnotes/domain.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

/// Boost and channel mode are one filter graph shared by live playback (mpv)
/// and export (FFmpeg), so what is heard is what is written.
void main() {
  group('playbackFilterGraph', () {
    test('is null when nothing is applied', () {
      expect(
        playbackFilterGraph(
            decibels: 0, channelMode: PlaybackChannelMode.stereo),
        isNull,
      );
    });

    test('a boost always carries a limiter behind it', () {
      expect(
        playbackFilterGraph(
            decibels: 6, channelMode: PlaybackChannelMode.stereo),
        'volume=6.0dB,alimiter=limit=0.95',
      );
    });

    test('channel mode precedes the boost', () {
      expect(
        playbackFilterGraph(
            decibels: 9, channelMode: PlaybackChannelMode.muteLeft),
        'aformat=channel_layouts=stereo,pan=stereo|c0=0*c0|c1=c1,'
        'volume=9.0dB,alimiter=limit=0.95',
      );
    });

    test('a channel mode alone has no limiter', () {
      expect(
        playbackFilterGraph(decibels: 0, channelMode: PlaybackChannelMode.mono),
        'aformat=channel_layouts=stereo,pan=mono|c0=0.5*c0+0.5*c1',
      );
    });
  });

  group('AudioController.setProcessing', () {
    test('records the settings on an inert controller', () async {
      final controller = AudioController.inert();

      await controller.setProcessing(
          decibels: 12, channelMode: PlaybackChannelMode.muteRight);

      expect(controller.decibels, 12);
      expect(controller.channelMode, PlaybackChannelMode.muteRight);
    });

    test('load with startAt reports that position on an inert controller',
        () async {
      final controller = AudioController.inert();
      final recording = Recording(
          id: 'take-1',
          file: File('take.wav'),
          title: null,
          isBestTake: false);

      await controller.load(recording,
          startAt: const Duration(seconds: 42));

      expect(controller.position, const Duration(seconds: 42));
    });
  });

  group('practice default boost', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a take without its own boost falls back to the practice default',
        () async {
      final preferences = AppPreferences();
      await preferences.load();

      await preferences.setPracticeBoost('C:/Band/2026-09-23', 6);

      expect(preferences.hasBoostFor('take-1'), isFalse);
      expect(preferences.practiceBoostFor('C:/Band/2026-09-23'), 6);
      expect(preferences.practiceBoostFor('C:/Band/other'), 0);
    });

    test('a take with its own boost is distinguishable from the default',
        () async {
      final preferences = AppPreferences();
      await preferences.load();

      await preferences.setBoost('take-1', 3);

      expect(preferences.hasBoostFor('take-1'), isTrue);
      expect(preferences.boostFor('take-1'), 3);
    });

    test('practice defaults survive a reload', () async {
      final first = AppPreferences();
      await first.load();
      await first.setPracticeBoost('C:/Band/quiet', 9);

      final second = AppPreferences();
      await second.load();

      expect(second.practiceBoostFor('C:/Band/quiet'), 9);
    });

    test('setting a practice default to 0 removes it', () async {
      final preferences = AppPreferences();
      await preferences.load();
      await preferences.setPracticeBoost('C:/Band/quiet', 9);

      await preferences.setPracticeBoost('C:/Band/quiet', 0);

      expect(preferences.practiceBoostFor('C:/Band/quiet'), 0);
    });
  });
}
