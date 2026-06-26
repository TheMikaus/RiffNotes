import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'domain.dart';

class AudioController extends ChangeNotifier {
  AudioController({Player? player}) : _player = player ?? Player() {
    final activePlayer = _player!;
    _positionSubscription = activePlayer.stream.position.listen((position) {
      _position = position;
      notifyListeners();
    });
    _durationSubscription = activePlayer.stream.duration.listen((duration) {
      _duration = duration == Duration.zero ? null : duration;
      notifyListeners();
    });
    _playingSubscription = activePlayer.stream.playing.listen((playing) {
      _isPlaying = playing;
      notifyListeners();
    });
    _completedSubscription = activePlayer.stream.completed.listen((completed) {
      if (completed) {
        _isPlaying = false;
        notifyListeners();
      }
    });
    _audioDevicesSubscription =
        activePlayer.stream.audioDevices.listen((devices) {
      _audioDevices = _normalizeAudioDevices(devices);
      notifyListeners();
    });
    _audioDeviceSubscription = activePlayer.stream.audioDevice.listen((device) {
      _audioDevice = device;
      notifyListeners();
    });
    _errorSubscription = activePlayer.stream.error.listen((error) {
      _error = error;
      _isLoading = false;
      notifyListeners();
    });
    _audioDevices = _normalizeAudioDevices(activePlayer.state.audioDevices);
    _audioDevice = activePlayer.state.audioDevice;
  }

  AudioController.inert() : _player = null;

  final Player? _player;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<List<AudioDevice>>? _audioDevicesSubscription;
  StreamSubscription<AudioDevice>? _audioDeviceSubscription;
  StreamSubscription<String>? _errorSubscription;

  Recording? _recording;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _isPlaying = false;
  bool _isLoading = false;
  String? _error;
  int _loadRequest = 0;
  Timer? _rangeTimer;
  bool _isLoopingRange = false;
  List<AudioDevice> _audioDevices = const [AudioDevice('auto', '')];
  AudioDevice _audioDevice = AudioDevice.auto();

  Recording? get recording => _recording;
  Duration get position => _position;
  Duration? get duration => _duration;
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isLoopingRange => _isLoopingRange;
  List<AudioDevice> get audioDevices => _audioDevices;
  AudioDevice get audioDevice => _audioDevice;

  Future<void> load(Recording recording,
      {bool autoPlay = false, File? playbackFile}) async {
    final player = _player;
    if (player == null) {
      _recording = recording;
      _position = Duration.zero;
      _duration = null;
      _error = null;
      _isLoading = false;
      notifyListeners();
      return;
    }
    final request = ++_loadRequest;
    _recording = recording;
    _position = Duration.zero;
    _duration = null;
    _error = null;
    _isLoading = true;
    notifyListeners();
    try {
      await player.stop();
      await player.open(
        Media((playbackFile ?? recording.file).uri.toString()),
        play: autoPlay,
      );
      if (request != _loadRequest) {
        return;
      }
      _duration =
          player.state.duration == Duration.zero ? null : player.state.duration;
    } catch (_) {
      if (request == _loadRequest) {
        _error =
            'Unable to load ${recording.filename}. Check that the file is a valid WAV or MP3.';
      }
    } finally {
      if (request == _loadRequest) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> togglePlayback() async {
    final player = _player;
    if (player == null || _recording == null || _isLoading || _error != null) {
      return;
    }
    await player.playOrPause();
  }

  Future<void> stop() async {
    final player = _player;
    if (player == null) return;
    _rangeTimer?.cancel();
    _isLoopingRange = false;
    await player.pause();
    await player.seek(Duration.zero);
  }

  Future<void> playFromNote(int startMs, {int? endMs}) async {
    await playRange(startMs, endMs: endMs);
  }

  Future<void> playRange(int startMs, {int? endMs, bool loop = false}) async {
    _rangeTimer?.cancel();
    _isLoopingRange = loop && endMs != null && endMs > startMs;
    await seek(Duration(milliseconds: startMs));
    final player = _player;
    if (player == null) return;
    await player.play();
    if (endMs != null && endMs > startMs) {
      final end = Duration(milliseconds: endMs);
      _rangeTimer =
          Timer.periodic(const Duration(milliseconds: 80), (timer) async {
        if (player.state.position >= end) {
          if (_isLoopingRange) {
            await player.seek(Duration(milliseconds: startMs));
            await player.play();
          } else {
            timer.cancel();
            await player.pause();
            await player.seek(Duration(milliseconds: startMs));
          }
        }
      });
    }
    notifyListeners();
  }

  void stopRangeLoop() {
    _rangeTimer?.cancel();
    _rangeTimer = null;
    _isLoopingRange = false;
    notifyListeners();
  }

  Future<void> seek(Duration target) async {
    final maximum = _duration ?? Duration.zero;
    final clamped = target < Duration.zero
        ? Duration.zero
        : maximum > Duration.zero && target > maximum
            ? maximum
            : target;
    await _player?.seek(clamped);
  }

  Future<void> setAudioDevice(AudioDevice device) async {
    final player = _player;
    if (player == null) return;
    await player.setAudioDevice(device);
    _audioDevice = device;
    notifyListeners();
  }

  List<AudioDevice> _normalizeAudioDevices(List<AudioDevice> devices) {
    final result = <AudioDevice>[AudioDevice.auto()];
    for (final device in devices) {
      if (device.name == 'auto') continue;
      if (!result.any((item) => item.name == device.name)) {
        result.add(device);
      }
    }
    return result;
  }

  @override
  void dispose() {
    final positionSubscription = _positionSubscription;
    final durationSubscription = _durationSubscription;
    final playingSubscription = _playingSubscription;
    final completedSubscription = _completedSubscription;
    final audioDevicesSubscription = _audioDevicesSubscription;
    final audioDeviceSubscription = _audioDeviceSubscription;
    final errorSubscription = _errorSubscription;
    if (positionSubscription != null) unawaited(positionSubscription.cancel());
    if (durationSubscription != null) unawaited(durationSubscription.cancel());
    if (playingSubscription != null) unawaited(playingSubscription.cancel());
    if (completedSubscription != null) {
      unawaited(completedSubscription.cancel());
    }
    if (audioDevicesSubscription != null) {
      unawaited(audioDevicesSubscription.cancel());
    }
    if (audioDeviceSubscription != null) {
      unawaited(audioDeviceSubscription.cancel());
    }
    if (errorSubscription != null) unawaited(errorSubscription.cancel());
    final player = _player;
    if (player != null) unawaited(player.dispose());
    _rangeTimer?.cancel();
    super.dispose();
  }
}
