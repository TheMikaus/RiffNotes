import 'dart:async';

import 'package:flutter/foundation.dart';

enum ActivityState { running, completed, failed, cancelled }

class Activity {
  Activity({required this.label, this.detail = '', this.progress, this.state = ActivityState.running});

  final String label;
  String detail;
  double? progress;
  ActivityState state;
}

class ActivityQueue extends ChangeNotifier {
  final List<Activity> _activities = [];
  List<Activity> get activities => List.unmodifiable(_activities);

  Future<T> run<T>(String label, Future<T> Function(void Function(double?, String)) work) async {
    final activity = Activity(label: label);
    _activities.insert(0, activity);
    notifyListeners();
    try {
      final result = await work((progress, detail) {
        activity.progress = progress;
        activity.detail = detail;
        notifyListeners();
      });
      activity.state = ActivityState.completed;
      activity.progress = 1;
      notifyListeners();
      return result;
    } catch (_) {
      activity.state = ActivityState.failed;
      notifyListeners();
      rethrow;
    }
  }
}

