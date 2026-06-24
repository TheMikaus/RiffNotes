import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppPreferences extends ChangeNotifier {
  static const _bandFolderKey = 'band_folder';
  static const _autoPlayTakeKey = 'auto_play_on_take_selection';
  static const _autoPlayPracticeKey = 'auto_play_on_practice_selection';
  static const _displayNameKey = 'display_name';

  String? _bandFolder;
  bool _autoPlayOnTakeSelection = false;
  bool _autoPlayOnPracticeSelection = false;
  String _displayName = 'Bandmate';

  String? get bandFolder => _bandFolder;
  bool get autoPlayOnTakeSelection => _autoPlayOnTakeSelection;
  bool get autoPlayOnPracticeSelection => _autoPlayOnPracticeSelection;
  String get displayName => _displayName;

  Future<void> load() async {
    final store = await SharedPreferences.getInstance();
    _bandFolder = store.getString(_bandFolderKey);
    _autoPlayOnTakeSelection = store.getBool(_autoPlayTakeKey) ?? false;
    _autoPlayOnPracticeSelection = store.getBool(_autoPlayPracticeKey) ?? false;
    _displayName = store.getString(_displayNameKey) ?? 'Bandmate';
    notifyListeners();
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
}
