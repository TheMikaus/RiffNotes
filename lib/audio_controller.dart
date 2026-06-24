import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'domain.dart';

class AudioController extends ChangeNotifier {
  AudioController({AudioPlayer? player}) : _player = player ?? AudioPlayer() {
    _positionSubscription = _player.positionStream.listen((position) {
      _position = position;
      notifyListeners();
    });
    _durationSubscription = _player.durationStream.listen((duration) {
      _duration = duration;
      notifyListeners();
    });
    _stateSubscription = _player.playerStateStream.listen((state) {
      _isPlaying = state.playing;
      if (state.processingState == ProcessingState.completed) {
        _isPlaying = false;
      }
      notifyListeners();
    });
  }

  final AudioPlayer _player;
  late final StreamSubscription<Duration> _positionSubscription;
  late final StreamSubscription<Duration?> _durationSubscription;
  late final StreamSubscription<PlayerState> _stateSubscription;

  Recording? _recording;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _isPlaying = false;
  bool _isLoading = false;
  String? _error;
  int _loadRequest = 0;
  Timer? _rangeTimer;

  Recording? get recording => _recording;
  Duration get position => _position;
  Duration? get duration => _duration;
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> load(Recording recording, {bool autoPlay = false, File? playbackFile}) async {
    final request = ++_loadRequest;
    _recording = recording;
    _position = Duration.zero;
    _duration = null;
    _error = null;
    _isLoading = true;
    notifyListeners();
    try {
      await _player.stop();
      final duration = await _player.setFilePath((playbackFile ?? recording.file).path);
      if (request != _loadRequest) {
        return;
      }
      _duration = duration ?? _player.duration;
      if (autoPlay) {
        await _player.play();
      }
    } on PlayerException catch (error) {
      if (request == _loadRequest) {
        _error = 'Unable to load ${recording.filename}: ${error.message}';
      }
    } catch (_) {
      if (request == _loadRequest) {
        _error = 'Unable to load ${recording.filename}. Check that the file is a valid WAV or MP3.';
      }
    } finally {
      if (request == _loadRequest) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> togglePlayback() async {
    if (_recording == null || _isLoading || _error != null) {
      return;
    }
    if (_isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> stop() async {
    _rangeTimer?.cancel();
    await _player.pause();
    await _player.seek(Duration.zero);
  }

  Future<void> playFromNote(int startMs, {int? endMs}) async {
    _rangeTimer?.cancel();
    await seek(Duration(milliseconds: startMs));
    await _player.play();
    if (endMs != null && endMs > startMs) {
      final end = Duration(milliseconds: endMs);
      _rangeTimer = Timer.periodic(const Duration(milliseconds: 80), (timer) async {
        if (_player.position >= end) {
          timer.cancel();
          await _player.pause();
          await _player.seek(Duration(milliseconds: startMs));
        }
      });
    }
  }

  Future<void> seek(Duration target) async {
    final maximum = _duration ?? Duration.zero;
    final clamped = target < Duration.zero
        ? Duration.zero
        : target > maximum
            ? maximum
            : target;
    await _player.seek(clamped);
  }

  @override
  void dispose() {
    unawaited(_positionSubscription.cancel());
    unawaited(_durationSubscription.cancel());
    unawaited(_stateSubscription.cancel());
    unawaited(_player.dispose());
    _rangeTimer?.cancel();
    super.dispose();
  }
}
