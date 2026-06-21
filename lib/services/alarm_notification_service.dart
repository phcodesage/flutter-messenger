import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import '../models/alarm.dart';

class AlarmNotificationService {
  static final AlarmNotificationService _instance =
      AlarmNotificationService._internal();
  factory AlarmNotificationService() => _instance;
  AlarmNotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    tz.initializeTimeZones();

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings darwinSettings =
        DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
        );

    // Darwin settings cover both iOS and macOS. Passing `macOS` is required when
    // running on macOS desktop, otherwise `initialize` throws "macOS settings
    // must be set" and aborts app startup (black screen).
    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
    );

    await _notifications.initialize(settings);

    // Create alarm channel for Android
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'alarms_channel',
      'Alarms',
      description: 'Scheduled alarms for Not Pomodoro',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
  }

  Future<void> scheduleAlarms(List<Alarm> alarms) async {
    // We avoid cancelAll() because it would kill the active Pomodoro notification (ID 5555).
    // Instead, we can rely on the fact that zonedSchedule with the same ID will overwrite
    // the previous one. However, if an alarm was deleted or deactivated, we need to handle it.
    // For this implementation, we'll assume that any active alarm in the list should be scheduled,
    // and we'll trust the overwrite behavior for existing IDs.
    // To truly "clear" old ones, we'd need to track which IDs we've used.

    for (final alarm in alarms) {
      final int baseId = (alarm.id ?? 0) * 10;
      // IDs baseId+1..baseId+7 are the seven weekday schedules; baseId+8 is
      // reserved for a non-repeating (one-time) schedule.
      const int oneTimeOffset = 8;

      if (!alarm.isActive) {
        // Cancel every possible schedule for this alarm if it's deactivated.
        for (int day = 1; day <= 7; day++) {
          await _notifications.cancel(baseId + day);
        }
        await _notifications.cancel(baseId + oneTimeOffset);
        continue;
      }

      final parts = alarm.time24h.split(':');
      final hour = int.parse(parts[0]);
      final minute = int.parse(parts[1]);

      final days = _parseDays(alarm.days);

      if (days.isEmpty) {
        // One-time alarm (no repeat days): schedule a single notification for
        // the next occurrence of this time so it still fires when the app is
        // terminated. Clear any stale weekly schedules for this alarm id.
        for (int day = 1; day <= 7; day++) {
          await _notifications.cancel(baseId + day);
        }
        await _scheduleOneTimeAlarm(
          alarm,
          hour,
          minute,
          baseId + oneTimeOffset,
        );
        continue;
      }

      // Repeating alarm: clear any stale one-time schedule, then schedule the
      // selected weekdays and cancel the days that are no longer selected.
      await _notifications.cancel(baseId + oneTimeOffset);
      for (int day = 1; day <= 7; day++) {
        if (!days.contains(day)) {
          await _notifications.cancel(baseId + day);
        }
      }

      for (final day in days) {
        await _scheduleWeeklyAlarm(alarm, day, hour, minute);
      }
    }
  }

  Future<void> schedulePomodoro(
    String title,
    String body,
    Duration delay,
  ) async {
    final scheduledDate = tz.TZDateTime.now(tz.local).add(delay);

    await _notifications.zonedSchedule(
      5555,
      title,
      body,
      scheduledDate,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'pomodoro_channel',
          'Pomodoro Timer',
          channelDescription: 'Notifications for Pomodoro sessions',
          importance: Importance.max,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  Future<void> cancelPomodoro() async {
    await _notifications.cancel(5555);
  }

  List<int> _parseDays(String daysStr) {
    final List<int> days = [];
    final parts = daysStr.split(',').map((e) => e.trim()).toList();

    if (parts.contains('Mon')) days.add(DateTime.monday);
    if (parts.contains('Tue')) days.add(DateTime.tuesday);
    if (parts.contains('Wed')) days.add(DateTime.wednesday);
    if (parts.contains('Thu')) days.add(DateTime.thursday);
    if (parts.contains('Fri')) days.add(DateTime.friday);
    if (parts.contains('Sat')) days.add(DateTime.saturday);
    if (parts.contains('Sun')) days.add(DateTime.sunday);

    return days;
  }

  Future<void> _scheduleOneTimeAlarm(
    Alarm alarm,
    int hour,
    int minute,
    int notificationId,
  ) async {
    final now = tz.TZDateTime.now(tz.local);
    var scheduledDate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );

    // If the time has already passed today, fire tomorrow instead.
    if (!scheduledDate.isAfter(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }

    await _notifications.zonedSchedule(
      notificationId,
      'Alarm: ${alarm.name}',
      'It is ${alarm.time24h}!',
      scheduledDate,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'alarms_channel',
          'Alarms',
          channelDescription: 'Scheduled alarms for Not Pomodoro',
          importance: Importance.max,
          priority: Priority.high,
          fullScreenIntent: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      // No matchDateTimeComponents → this notification fires exactly once.
    );
  }

  Future<void> _scheduleWeeklyAlarm(
    Alarm alarm,
    int day,
    int hour,
    int minute,
  ) async {
    final now = tz.TZDateTime.now(tz.local);
    var scheduledDate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );

    // Adjust to the correct day of the week
    while (scheduledDate.weekday != day) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }

    // If it's today but already passed, move to next week
    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 7));
    }

    // Unique ID per alarm and day combination
    final int notificationId = (alarm.id ?? 0) * 10 + day;

    await _notifications.zonedSchedule(
      notificationId,
      'Alarm: ${alarm.name}',
      'It is ${alarm.time24h}!',
      scheduledDate,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'alarms_channel',
          'Alarms',
          channelDescription: 'Scheduled alarms for Not Pomodoro',
          importance: Importance.max,
          priority: Priority.high,
          fullScreenIntent: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
    );

    // debugPrint('Scheduled alarm "${alarm.name}" for day $day at $hour:$minute (ID: $notificationId)');
  }
}
