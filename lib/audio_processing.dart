import 'dart:io';

import 'package:path/path.dart' as path;

import 'domain.dart';

class AudioProcessingRepository {
  Future<File> createBoostedPlaybackFile(PracticeFolder practice, Recording recording, double decibels) async {
    if (decibels <= 0) return recording.file;
    final output = File(path.join(practice.directory.path, '.riffnotes-cache', '${recording.id}-gain-${decibels.toStringAsFixed(0)}.wav'));
    if (await output.exists()) return output;
    await output.parent.create(recursive: true);
    final result = await Process.run('ffmpeg', <String>[
      '-y',
      '-v',
      'error',
      '-i',
      recording.file.path,
      '-af',
      'volume=${decibels.toStringAsFixed(1)}dB',
      '-c:a',
      'pcm_s16le',
      output.path,
    ], stdoutEncoding: null, stderrEncoding: null);
    if (result.exitCode != 0 || !await output.exists()) {
      throw StateError('FFmpeg could not create the boosted playback file.');
    }
    return output;
  }
}
