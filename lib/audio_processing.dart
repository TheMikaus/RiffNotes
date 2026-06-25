import 'dart:io';

import 'package:path/path.dart' as path;

import 'domain.dart';

enum PlaybackChannelMode {
  stereo('stereo', 'Stereo'),
  muteLeft('mute-left', 'Mute left'),
  muteRight('mute-right', 'Mute right'),
  mono('mono', 'Mono');

  const PlaybackChannelMode(this.storageValue, this.label);

  final String storageValue;
  final String label;

  static PlaybackChannelMode fromStorageValue(String? value) =>
      PlaybackChannelMode.values.firstWhere(
        (mode) => mode.storageValue == value,
        orElse: () => PlaybackChannelMode.stereo,
      );
}

class AudioProcessingRepository {
  Future<File> createPlaybackFile(
    PracticeFolder practice,
    Recording recording, {
    required double decibels,
    required PlaybackChannelMode channelMode,
  }) async {
    if (decibels <= 0 && channelMode == PlaybackChannelMode.stereo) {
      return recording.file;
    }
    final output = File(path.join(practice.directory.path, '.riffnotes-cache',
        '${recording.id}-${channelMode.storageValue}-gain-${decibels.toStringAsFixed(0)}.wav'));
    if (await output.exists()) return output;
    await output.parent.create(recursive: true);
    final filters = <String>[
      if (channelMode != PlaybackChannelMode.stereo)
        _channelFilter(channelMode),
      if (decibels > 0) 'volume=${decibels.toStringAsFixed(1)}dB',
    ];
    final result = await Process.run(
        'ffmpeg',
        <String>[
          '-y',
          '-v',
          'error',
          '-i',
          recording.file.path,
          if (filters.isNotEmpty) ...['-af', filters.join(',')],
          '-c:a',
          'pcm_s16le',
          output.path,
        ],
        stdoutEncoding: null,
        stderrEncoding: null);
    if (result.exitCode != 0 || !await output.exists()) {
      throw StateError('FFmpeg could not create the processed playback file.');
    }
    return output;
  }

  String _channelFilter(PlaybackChannelMode channelMode) {
    switch (channelMode) {
      case PlaybackChannelMode.stereo:
        return 'anull';
      case PlaybackChannelMode.muteLeft:
        return 'pan=stereo|c0=0*c0|c1=c1';
      case PlaybackChannelMode.muteRight:
        return 'pan=stereo|c0=c0|c1=0*c1';
      case PlaybackChannelMode.mono:
        return 'pan=mono|c0=0.5*c0+0.5*c1';
    }
  }
}
