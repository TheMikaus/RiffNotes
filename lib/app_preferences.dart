import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_processing.dart';

class AppPreferences extends ChangeNotifier {
  static const _bandFolderKey = 'band_folder';
  static const _syncFolderKey = 'sync_folder';
  static const _mastersFolderKey = 'masters_folder';
  static const _autoPlayTakeKey = 'auto_play_on_take_selection';
  static const _autoPlayPracticeKey = 'auto_play_on_practice_selection';
  static const _displayNameKey = 'display_name';
  static const _lastPracticeKey = 'last_practice';
  static const _lastRecordingKey = 'last_recording';
  static const _lastRecordingsByPracticeKey = 'last_recordings_by_practice';
  static const _boostsKey = 'playback_boosts';
  static const _channelModesKey = 'playback_channel_modes';
  static const _audioOutputDeviceKey = 'audio_output_device';
  static const _googleClientIdKey = 'google_client_id';
  static const _googleClientSecretKey = 'google_client_secret';
  static const _googleDriveCredentialsKey = 'google_drive_credentials';
  static const _googleDriveRootFolderIdKey = 'google_drive_root_folder_id';
  static const _googleDriveRootFolderNameKey = 'google_drive_root_folder_name';
  static const _playerPanelCollapsedKey = 'player_panel_collapsed';
  static const _fingerprintFeatureWeightsKey = 'fingerprint_feature_weights';
  static const _fingerprintSongTitlesByPracticeKey =
      'fingerprint_song_titles_by_practice';

  String? _bandFolder;
  String? _syncFolder;
  String? _mastersFolder;
  bool _autoPlayOnTakeSelection = false;
  bool _autoPlayOnPracticeSelection = false;
  String _displayName = 'Bandmate';
  String? _lastPractice;
  String? _lastRecording;
  Map<String, String> _lastRecordingsByPractice = <String, String>{};
  Map<String, double> _boostsByRecording = <String, double>{};
  Map<String, PlaybackChannelMode> _channelModesByRecording =
      <String, PlaybackChannelMode>{};
  String? _audioOutputDevice;
  String? _googleClientId;
  String? _googleClientSecret;
  String? _googleDriveCredentials;
  String? _googleDriveRootFolderId;
  String? _googleDriveRootFolderName;
  bool _playerPanelCollapsed = false;
  Map<String, double> _fingerprintFeatureWeights = <String, double>{};
  Map<String, List<String>> _fingerprintSongTitlesByPractice =
      <String, List<String>>{};

  String? get bandFolder => _bandFolder;
  String? get syncFolder => _syncFolder;
  String? get mastersFolder => _mastersFolder;
  bool get autoPlayOnTakeSelection => _autoPlayOnTakeSelection;
  bool get autoPlayOnPracticeSelection => _autoPlayOnPracticeSelection;
  String get displayName => _displayName;
  String? get lastPractice => _lastPractice;
  String? get lastRecording => _lastRecording;
  String? lastRecordingForPractice(String practice) =>
      _lastRecordingsByPractice[practice] ??
      (practice == _lastPractice ? _lastRecording : null);
  double boostFor(String recordingId) => _boostsByRecording[recordingId] ?? 0;
  PlaybackChannelMode channelModeFor(String recordingId) =>
      _channelModesByRecording[recordingId] ?? PlaybackChannelMode.stereo;
  String? get audioOutputDevice => _audioOutputDevice;
  String? get googleClientId => _googleClientId;
  String? get googleClientSecret => _googleClientSecret;
  String? get googleDriveCredentials => _googleDriveCredentials;
  String? get googleDriveRootFolderId => _googleDriveRootFolderId;
  String? get googleDriveRootFolderName => _googleDriveRootFolderName;
  bool get playerPanelCollapsed => _playerPanelCollapsed;
  Map<String, double> get fingerprintFeatureWeights =>
      Map<String, double>.from(_fingerprintFeatureWeights);
  List<String> fingerprintSongTitlesForPractice(String practicePath) =>
      List<String>.unmodifiable(
          _fingerprintSongTitlesByPractice[practicePath] ?? const <String>[]);
  bool get hasGoogleClientConfig => _googleClientId?.trim().isNotEmpty ?? false;
  bool get hasGoogleDriveConnection =>
      _googleDriveCredentials != null && _googleDriveRootFolderId != null;

  Future<void> load() async {
    final store = await SharedPreferences.getInstance();
    _bandFolder = store.getString(_bandFolderKey);
    _syncFolder = store.getString(_syncFolderKey);
    _mastersFolder = store.getString(_mastersFolderKey);
    _autoPlayOnTakeSelection = store.getBool(_autoPlayTakeKey) ?? false;
    _autoPlayOnPracticeSelection = store.getBool(_autoPlayPracticeKey) ?? false;
    _displayName = store.getString(_displayNameKey) ?? 'Bandmate';
    _audioOutputDevice = store.getString(_audioOutputDeviceKey);
    _googleClientId = store.getString(_googleClientIdKey);
    _googleClientSecret = store.getString(_googleClientSecretKey);
    _googleDriveCredentials = store.getString(_googleDriveCredentialsKey);
    _googleDriveRootFolderId = store.getString(_googleDriveRootFolderIdKey);
    _googleDriveRootFolderName = store.getString(_googleDriveRootFolderNameKey);
    _playerPanelCollapsed = store.getBool(_playerPanelCollapsedKey) ?? false;
    final fingerprintWeights = store.getString(_fingerprintFeatureWeightsKey);
    if (fingerprintWeights != null) {
      try {
        final decoded = jsonDecode(fingerprintWeights) as Map<String, dynamic>;
        _fingerprintFeatureWeights = decoded
            .map((key, value) => MapEntry(key, (value as num).toDouble()));
      } on FormatException {
        _fingerprintFeatureWeights = <String, double>{};
      } on TypeError {
        _fingerprintFeatureWeights = <String, double>{};
      }
    }
    final fingerprintSongTitles =
        store.getString(_fingerprintSongTitlesByPracticeKey);
    if (fingerprintSongTitles != null) {
      try {
        final decoded = jsonDecode(fingerprintSongTitles) as Map<String, dynamic>;
        _fingerprintSongTitlesByPractice = decoded.map((key, value) => MapEntry(
            key,
            (value as List<dynamic>)
                .map((item) => item as String)
                .toList(growable: false)));
      } on FormatException {
        _fingerprintSongTitlesByPractice = <String, List<String>>{};
      } on TypeError {
        _fingerprintSongTitlesByPractice = <String, List<String>>{};
      }
    }
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
    final channelModes = store.getString(_channelModesKey);
    if (channelModes != null) {
      try {
        final decoded = jsonDecode(channelModes) as Map<String, dynamic>;
        _channelModesByRecording = decoded.map((key, value) => MapEntry(
            key, PlaybackChannelMode.fromStorageValue(value as String?)));
      } on FormatException {
        _channelModesByRecording = <String, PlaybackChannelMode>{};
      } on TypeError {
        _channelModesByRecording = <String, PlaybackChannelMode>{};
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

  Future<void> setSyncFolder(String? path) async {
    _syncFolder = path;
    final store = await SharedPreferences.getInstance();
    if (path == null) {
      await store.remove(_syncFolderKey);
    } else {
      await store.setString(_syncFolderKey, path);
    }
    notifyListeners();
  }

  Future<void> setMastersFolder(String? path) async {
    _mastersFolder = path;
    final store = await SharedPreferences.getInstance();
    if (path == null) {
      await store.remove(_mastersFolderKey);
    } else {
      await store.setString(_mastersFolderKey, path);
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

  Future<void> setAudioOutputDevice(String? value) async {
    _audioOutputDevice = value;
    final store = await SharedPreferences.getInstance();
    if (value == null || value == 'auto') {
      _audioOutputDevice = null;
      await store.remove(_audioOutputDeviceKey);
    } else {
      await store.setString(_audioOutputDeviceKey, value);
    }
    notifyListeners();
  }

  Future<void> setGoogleClientConfig({
    required String clientId,
    String? clientSecret,
  }) async {
    _googleClientId = clientId.trim();
    _googleClientSecret = clientSecret?.trim();
    final store = await SharedPreferences.getInstance();
    if (_googleClientId!.isEmpty) {
      _googleClientId = null;
      _googleClientSecret = null;
      await store.remove(_googleClientIdKey);
      await store.remove(_googleClientSecretKey);
    } else {
      await store.setString(_googleClientIdKey, _googleClientId!);
      if (_googleClientSecret == null || _googleClientSecret!.isEmpty) {
        _googleClientSecret = null;
        await store.remove(_googleClientSecretKey);
      } else {
        await store.setString(_googleClientSecretKey, _googleClientSecret!);
      }
    }
    notifyListeners();
  }

  Future<void> setGoogleDriveCredentials(String? credentialsJson) async {
    _googleDriveCredentials = credentialsJson;
    final store = await SharedPreferences.getInstance();
    if (credentialsJson == null) {
      await store.remove(_googleDriveCredentialsKey);
    } else {
      await store.setString(_googleDriveCredentialsKey, credentialsJson);
    }
    notifyListeners();
  }

  Future<void> setGoogleDriveRootFolder({
    required String? id,
    required String? name,
  }) async {
    _googleDriveRootFolderId = id;
    _googleDriveRootFolderName = name;
    final store = await SharedPreferences.getInstance();
    if (id == null) {
      await store.remove(_googleDriveRootFolderIdKey);
    } else {
      await store.setString(_googleDriveRootFolderIdKey, id);
    }
    if (name == null) {
      await store.remove(_googleDriveRootFolderNameKey);
    } else {
      await store.setString(_googleDriveRootFolderNameKey, name);
    }
    notifyListeners();
  }

  Future<void> clearGoogleDriveConnection() async {
    _googleDriveCredentials = null;
    _googleDriveRootFolderId = null;
    _googleDriveRootFolderName = null;
    final store = await SharedPreferences.getInstance();
    await store.remove(_googleDriveCredentialsKey);
    await store.remove(_googleDriveRootFolderIdKey);
    await store.remove(_googleDriveRootFolderNameKey);
    notifyListeners();
  }

  Future<void> setPlayerPanelCollapsed(bool value) async {
    _playerPanelCollapsed = value;
    final store = await SharedPreferences.getInstance();
    await store.setBool(_playerPanelCollapsedKey, value);
    notifyListeners();
  }

  Future<void> setFingerprintFeatureWeights(
      Map<String, double> weights) async {
    _fingerprintFeatureWeights = Map<String, double>.from(weights);
    final store = await SharedPreferences.getInstance();
    if (_fingerprintFeatureWeights.isEmpty) {
      await store.remove(_fingerprintFeatureWeightsKey);
    } else {
      await store.setString(
          _fingerprintFeatureWeightsKey, jsonEncode(_fingerprintFeatureWeights));
    }
    notifyListeners();
  }

  Future<void> rememberFingerprintSongTitle(
    String practicePath,
    String title,
  ) async {
    final cleaned = title.trim();
    if (cleaned.isEmpty) return;
    final existing = <String>{
      ...(_fingerprintSongTitlesByPractice[practicePath] ?? const <String>[]),
    };
    existing.removeWhere((item) => item.toLowerCase() == cleaned.toLowerCase());
    final next = <String>[cleaned, ...existing].take(12).toList(growable: false);
    _fingerprintSongTitlesByPractice[practicePath] = next;
    final store = await SharedPreferences.getInstance();
    await store.setString(_fingerprintSongTitlesByPracticeKey,
        jsonEncode(_fingerprintSongTitlesByPractice));
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

  Future<void> setChannelMode(
      String recordingId, PlaybackChannelMode channelMode) async {
    if (channelMode == PlaybackChannelMode.stereo) {
      _channelModesByRecording.remove(recordingId);
    } else {
      _channelModesByRecording[recordingId] = channelMode;
    }
    final store = await SharedPreferences.getInstance();
    await store.setString(
        _channelModesKey,
        jsonEncode(_channelModesByRecording
            .map((key, value) => MapEntry(key, value.storageValue))));
  }
}
