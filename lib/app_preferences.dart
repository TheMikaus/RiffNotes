import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppPreferences extends ChangeNotifier {
  static const _bandFolderKey = 'band_folder';
  static const _autoPlayTakeKey = 'auto_play_on_take_selection';
  static const _autoPlayPracticeKey = 'auto_play_on_practice_selection';
  static const _displayNameKey = 'display_name';
  static const _lastPracticeKey = 'last_practice';
  static const _lastRecordingKey = 'last_recording';
  static const _lastRecordingsByPracticeKey = 'last_recordings_by_practice';
  static const _boostsKey = 'playback_boosts';

  String? _bandFolder;
  bool _autoPlayOnTakeSelection = false;
  bool _autoPlayOnPracticeSelection = false;
  String _displayName = 'Bandmate';
  String? _lastPractice;
  String? _lastRecording;
  Map<String, String> _lastRecordingsByPractice = <String, String>{};
  Map<String, double> _boostsByRecording = <String, double>{};

  String? get bandFolder => _bandFolder;
  bool get autoPlayOnTakeSelection => _autoPlayOnTakeSelection;
  bool get autoPlayOnPracticeSelection => _autoPlayOnPracticeSelection;
  String get displayName => _displayName;
  String? get lastPractice => _lastPractice;
  String? get lastRecording => _lastRecording;
  String? lastRecordingForPractice(String practice) =>
      _lastRecordingsByPractice[practice] ??
      (practice == _lastPractice ? _lastRecording : null);
  double boostFor(String recordingId) => _boostsByRecording[recordingId] ?? 0;

  Future<void> load() async {
    final store = await SharedPreferences.getInstance();
    _bandFolder = store.getString(_bandFolderKey);
    _autoPlayOnTakeSelection = store.getBool(_autoPlayTakeKey) ?? false;
    _autoPlayOnPracticeSelection = store.getBool(_autoPlayPracticeKey) ?? false;
    _displayName = store.getString(_displayNameKey) ?? 'Bandmate';
    _lastPractice = store.getString(_lastPracticeKey);
    _lastRecording = store.getString(_lastRecordingKey);
    final lastRecordingsByPractice =
        store.getString(_lastRecordingsByPracticeKey);
    if (lastRecordingsByPractice != null) {
      try {
        final decoded =
            jsonDecode(lastRecordingsByPractice) as Map<String, dynamic>;
        _lastRecordingsByPractice =
            decoded.map((key, value) => MapEntry(key, value as String));
      } on FormatException {
        _lastRecordingsByPractice = <String, String>{};
      } on TypeError {
        _lastRecordingsByPractice = <String, String>{};
      }
    }
    final boosts = store.getString(_boostsKey);
    if (boosts != null) {
      try {
        final decoded = jsonDecode(boosts) as Map<String, dynamic>;
        _boostsByRecording = decoded
            .map((key, value) => MapEntry(key, (value as num).toDouble()));
      } on FormatException {
        _boostsByRecording = <String, double>{};
      }
    }
    notifyListeners();
  }

  Future<void> rememberPractice(String practice) async {
    _lastPractice = practice;
    final store = await SharedPreferences.getInstance();
    await store.setString(_lastPracticeKey, practice);
  }

  Future<void> rememberSelection(String practice, String? recording) async {
    _lastPractice = practice;
    _lastRecording = recording;
    if (recording == null) {
      _lastRecordingsByPractice.remove(practice);
    } else {
      _lastRecordingsByPractice[practice] = recording;
    }
    final store = await SharedPreferences.getInstance();
    await store.setString(_lastPracticeKey, practice);
    if (recording == null) {
      await store.remove(_lastRecordingKey);
    } else {
      await store.setString(_lastRecordingKey, recording);
    }
    await store.setString(
        _lastRecordingsByPracticeKey, jsonEncode(_lastRecordingsByPractice));
  }

  Future<void> setBandFolder(String? path) async {
    _bandFolder = path;
    final store = await SharedPreferences.getInstance();
    if (path == null) {
      await store.remove(_bandFolderKey);
    } else {
      await store.setString(_bandFolderKey, path);
    }
    notifyListeners();
  }

  Future<void> setAutoPlayOnTakeSelection(bool value) async {
    _autoPlayOnTakeSelection = value;
    final store = await SharedPreferences.getInstance();
    await store.setBool(_autoPlayTakeKey, value);
    notifyListeners();
  }

  Future<void> setAutoPlayOnPracticeSelection(bool value) async {
    _autoPlayOnPracticeSelection = value;
    final store = await SharedPreferences.getInstance();
    await store.setBool(_autoPlayPracticeKey, value);
    notifyListeners();
  }

  Future<void> setDisplayName(String value) async {
    _displayName = value.trim().isEmpty ? 'Bandmate' : value.trim();
    final store = await SharedPreferences.getInstance();
    await store.setString(_displayNameKey, _displayName);
    notifyListeners();
  }

  Future<void> setBoost(String recordingId, double decibels) async {
    if (decibels == 0) {
      _boostsByRecording.remove(recordingId);
    } else {
      _boostsByRecording[recordingId] = decibels;
    }
    final store = await SharedPreferences.getInstance();
    await store.setString(_boostsKey, jsonEncode(_boostsByRecording));
  }
}
