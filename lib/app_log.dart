import 'package:flutter/foundation.dart';

enum AppLogLevel { info, warning, error }

class AppLogEntry {
  AppLogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
  });

  final DateTime timestamp;
  final AppLogLevel level;
  final String source;
  final String message;

  String get line {
    final time = '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}.'
        '${timestamp.millisecond.toString().padLeft(3, '0')}';
    return '[$time] ${level.name.toUpperCase()} $source: $message';
  }
}

class AppLog extends ChangeNotifier {
  final List<AppLogEntry> _entries = <AppLogEntry>[];

  List<AppLogEntry> get entries => List.unmodifiable(_entries);

  void info(String source, String message) =>
      _add(AppLogLevel.info, source, message);

  void warning(String source, String message) =>
      _add(AppLogLevel.warning, source, message);

  void error(String source, String message) =>
      _add(AppLogLevel.error, source, message);

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  void _add(AppLogLevel level, String source, String message) {
    final entry = AppLogEntry(
      timestamp: DateTime.now(),
      level: level,
      source: source,
      message: message,
    );
    _entries.add(entry);
    if (_entries.length > 500) {
      _entries.removeRange(0, _entries.length - 500);
    }
    debugPrint(entry.line);
    notifyListeners();
  }
}
