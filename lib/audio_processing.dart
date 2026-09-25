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

/// The libavfilter graph that implements a boost and channel mode, or null
/// when neither is set.
///
/// One definition feeds both consumers so what you hear is what you export:
/// FFmpeg receives it as `-af <graph>` for exports, and mpv receives the same
/// graph as `af=lavfi=[<graph>]` for live playback. A limiter follows any
/// boost so a loud passage in an otherwise quiet take cannot clip.
String? playbackFilterGraph({
  required double decibels,
  required PlaybackChannelMode channelMode,
}) {
  final filters = <String>[
    if (channelMode != PlaybackChannelMode.stereo)
      _channelFilter(channelMode),
    if (decibels > 0) ...[
      'volume=${decibels.toStringAsFixed(1)}dB',
      'alimiter=limit=0.95',
    ],
  ];
  return filters.isEmpty ? null : filters.join(',');
}

String _channelFilter(PlaybackChannelMode channelMode) {
  switch (channelMode) {
    case PlaybackChannelMode.stereo:
      return 'anull';
    case PlaybackChannelMode.muteLeft:
      return 'aformat=channel_layouts=stereo,pan=stereo|c0=0*c0|c1=c1';
    case PlaybackChannelMode.muteRight:
      return 'aformat=channel_layouts=stereo,pan=stereo|c0=c0|c1=0*c1';
    case PlaybackChannelMode.mono:
      return 'aformat=channel_layouts=stereo,pan=mono|c0=0.5*c0+0.5*c1';
  }
}

class AudioProcessingRepository {
  Future<File> exportAudio({
    required Recording recording,
    required File output,
    required double decibels,
    required PlaybackChannelMode channelMode,
    int? startMs,
    int? endMs,
  }) async {
    await output.parent.create(recursive: true);
    final graph =
        playbackFilterGraph(decibels: decibels, channelMode: channelMode);
    final durationMs = startMs != null && endMs != null && endMs > startMs
        ? endMs - startMs
        : null;
    final extension = path.extension(output.path).toLowerCase();
    final codecArgs = switch (extension) {
      '.mp3' => <String>['-codec:a', 'libmp3lame', '-q:a', '2'],
      _ => <String>['-c:a', 'pcm_s16le'],
    };
    final result = await Process.run(
        'ffmpeg',
        <String>[
          '-y',
          '-v',
          'error',
          if (startMs != null) ...[
            '-ss',
            _seconds(startMs),
          ],
          '-i',
          recording.file.path,
          if (durationMs != null) ...[
            '-t',
            _seconds(durationMs),
          ],
          if (graph != null) ...['-af', graph],
          ...codecArgs,
          output.path,
        ],
        stdoutEncoding: null,
        stderrEncoding: null);
    if (result.exitCode != 0 || !await output.exists()) {
      throw StateError('FFmpeg could not export the audio file.');
    }
    return output;
  }

  Future<File> convertRecordingToMp3(Recording recording, File output) async {
    await output.parent.create(recursive: true);
    final result = await Process.run(
        'ffmpeg',
        <String>[
          '-y',
          '-v',
          'error',
          '-i',
          recording.file.path,
          '-codec:a',
          'libmp3lame',
          '-q:a',
          '2',
          output.path,
        ],
        stdoutEncoding: null,
        stderrEncoding: null);
    if (result.exitCode != 0 ||
        !await output.exists() ||
        await output.length() == 0) {
      throw StateError('FFmpeg could not convert the recording to MP3.');
    }
    return output;
  }

  Future<File> mixDownTracksToStereo({
    required List<File> inputTracks,
    required File output,
  }) async {
    if (inputTracks.length < 2) {
      throw StateError('At least two input tracks are required for mixdown.');
    }
    await output.parent.create(recursive: true);
    final labels = List<String>.generate(
      inputTracks.length,
      (index) => '[$index:a]',
      growable: false,
    ).join();
    final filter =
        '${labels}amix=inputs=${inputTracks.length}:duration=longest:normalize=0,alimiter=limit=0.95';
    final extension = path.extension(output.path).toLowerCase();
    final codecArgs = switch (extension) {
      '.mp3' => <String>['-codec:a', 'libmp3lame', '-q:a', '2'],
      _ => <String>['-c:a', 'pcm_s16le'],
    };
    final args = <String>[
      '-y',
      '-v',
      'error',
      for (final track in inputTracks) ...['-i', track.path],
      '-filter_complex',
      filter,
      ...codecArgs,
      output.path,
    ];
    final result = await Process.run('ffmpeg', args,
        stdoutEncoding: null, stderrEncoding: null);
    if (result.exitCode != 0 ||
        !await output.exists() ||
        await output.length() == 0) {
      throw StateError('FFmpeg could not create the stereo mixdown.');
    }
    return output;
  }

  String _seconds(int milliseconds) => (milliseconds / 1000).toStringAsFixed(3);
}
