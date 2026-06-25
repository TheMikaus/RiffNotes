import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'domain.dart';

class WaveformData {
  const WaveformData({required this.peaks, required this.fromCache});

  final List<double> peaks;
  final bool fromCache;
}

class WaveformRepository {
  static const _cacheFolder = '.riffnotes-cache';
  static const _cacheVersion = 2;

  Future<WaveformData> loadOrGenerate(
      PracticeFolder practice, Recording recording) async {
    final sourceStat = await recording.file.stat();
    final cache = File(path.join(practice.directory.path, _cacheFolder,
        '${recording.id}.waveform.json'));
    final cached = await _readCache(cache, sourceStat);
    if (cached != null) {
      return WaveformData(peaks: cached, fromCache: true);
    }

    final result = await Process.run(
      'ffmpeg',
      <String>[
        '-v',
        'error',
        '-i',
        recording.file.path,
        '-vn',
        '-ac',
        '1',
        '-ar',
        '8000',
        '-f',
        's16le',
        'pipe:1',
      ],
      stdoutEncoding: null,
      stderrEncoding: null,
    );
    if (result.exitCode != 0) {
      final error = _decodeOutput(result.stderr);
      throw StateError(error.isEmpty
          ? 'FFmpeg could not read this audio file.'
          : error.trim());
    }
    final output = result.stdout;
    if (output is! List<int> || output.length < 2) {
      throw StateError('FFmpeg produced no usable audio samples.');
    }

    final peaks = calculatePeaks(output);
    await cache.parent.create(recursive: true);
    await cache.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'version': _cacheVersion,
        'sourceBytes': sourceStat.size,
        'sourceModifiedMs': sourceStat.modified.millisecondsSinceEpoch,
        'peaks': peaks,
      }),
      flush: true,
    );
    return WaveformData(peaks: peaks, fromCache: false);
  }

  Future<List<double>?> _readCache(File cache, FileStat sourceStat) async {
    if (!await cache.exists()) return null;
    try {
      final decoded =
          jsonDecode(await cache.readAsString()) as Map<String, dynamic>;
      if (decoded['version'] != _cacheVersion ||
          decoded['sourceBytes'] != sourceStat.size ||
          decoded['sourceModifiedMs'] !=
              sourceStat.modified.millisecondsSinceEpoch) {
        return null;
      }
      final values = decoded['peaks'];
      if (values is! List || values.isEmpty) return null;
      return values
          .map((value) => (value as num).toDouble())
          .toList(growable: false);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  String _decodeOutput(Object? output) {
    if (output is List<int>) return utf8.decode(output, allowMalformed: true);
    return output?.toString() ?? '';
  }

  @visibleForTesting
  static List<double> calculatePeaks(List<int> pcmBytes, {int buckets = 900}) {
    final sampleCount = pcmBytes.length ~/ 2;
    if (sampleCount == 0) return const <double>[];
    final count = sampleCount < buckets ? sampleCount : buckets;
    final peaks = List<double>.filled(count, 0);
    for (var sample = 0; sample < sampleCount; sample += 1) {
      final low = pcmBytes[sample * 2];
      final high = pcmBytes[sample * 2 + 1];
      var value = low | (high << 8);
      if (value >= 0x8000) value -= 0x10000;
      final magnitude = value.abs() / 32768;
      final bucket = sample * count ~/ sampleCount;
      if (magnitude > peaks[bucket]) peaks[bucket] = magnitude;
    }
    final maximum =
        peaks.reduce((largest, value) => value > largest ? value : largest);
    if (maximum == 0) return peaks;
    return peaks.map((value) => value / maximum).toList(growable: false);
  }
}

class WaveformController extends ChangeNotifier {
  WaveformController({WaveformRepository? repository})
      : _repository = repository ?? WaveformRepository();

  final WaveformRepository _repository;
  int _request = 0;
  WaveformData? _data;
  bool _isLoading = false;
  String? _error;

  WaveformData? get data => _data;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> load(PracticeFolder practice, Recording recording) async {
    final request = ++_request;
    _data = null;
    _error = null;
    _isLoading = true;
    notifyListeners();
    try {
      final data = await _repository.loadOrGenerate(practice, recording);
      if (request == _request) _data = data;
    } on ProcessException {
      if (request == _request)
        _error =
            'FFmpeg was not found. Install FFmpeg, then restart RiffNotes.';
    } on FileSystemException {
      if (request == _request)
        _error = 'Could not create the waveform cache for this practice.';
    } on StateError catch (error) {
      if (request == _request)
        _error = 'Waveform unavailable: ${error.message}';
    } catch (_) {
      if (request == _request) _error = 'Waveform unavailable for this file.';
    } finally {
      if (request == _request) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  void clear() {
    _request += 1;
    _data = null;
    _isLoading = false;
    _error = null;
    notifyListeners();
  }
}
