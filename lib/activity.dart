import 'dart:async';

import 'package:flutter/foundation.dart';

enum ActivityState { running, completed, failed, cancelled }

class ActivityCancelledException implements Exception {
  const ActivityCancelledException([this.message = 'Sync cancelled.']);

  final String message;

  @override
  String toString() => message;
}

class Activity {
  Activity(
      {required this.label,
      this.detail = '',
      this.progress,
      this.state = ActivityState.running,
      this.cancellable = false});

  final String label;
  String detail;
  double? progress;
  ActivityState state;
  final bool cancellable;
  bool cancelRequested = false;
}

class ActivityQueue extends ChangeNotifier {
  final List<Activity> _activities = [];
  List<Activity> get activities => List.unmodifiable(_activities);

  void cancel(Activity activity) {
    if (!activity.cancellable ||
        activity.state != ActivityState.running ||
        activity.cancelRequested) {
      return;
    }
    activity.cancelRequested = true;
    activity.detail = activity.detail.trim().isEmpty
        ? 'Cancelling...'
        : '${activity.detail} (cancelling...)';
    notifyListeners();
  }

  void cancelFirstRunning() {
    for (final activity in _activities) {
      if (activity.state == ActivityState.running &&
          activity.cancellable &&
          !activity.cancelRequested) {
        cancel(activity);
        return;
      }
    }
  }

  Future<T> run<T>(String label,
      Future<T> Function(void Function(double?, String)) work) async {
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

  Future<T> runCancellable<T>(
    String label,
    Future<T> Function(void Function(double?, String), bool Function()) work,
  ) async {
    final activity = Activity(label: label, cancellable: true);
    _activities.insert(0, activity);
    notifyListeners();
    try {
      final result = await work(
        (progress, detail) {
          activity.progress = progress;
          activity.detail = detail;
          notifyListeners();
        },
        () => activity.cancelRequested,
      );
      if (activity.cancelRequested) {
        activity.state = ActivityState.cancelled;
        notifyListeners();
        throw const ActivityCancelledException();
      }
      activity.state = ActivityState.completed;
      activity.progress = 1;
      notifyListeners();
      return result;
    } on ActivityCancelledException {
      activity.state = ActivityState.cancelled;
      notifyListeners();
      rethrow;
    } catch (_) {
      activity.state = activity.cancelRequested
          ? ActivityState.cancelled
          : ActivityState.failed;
      notifyListeners();
      rethrow;
    }
  }
}
