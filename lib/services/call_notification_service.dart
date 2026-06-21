import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';

/// Service for showing an ongoing call notification in the status bar
/// Similar to Facebook Messenger / Skype behavior
class CallNotificationService {
  static final CallNotificationService _instance =
      CallNotificationService._internal();
  factory CallNotificationService() => _instance;
  CallNotificationService._internal();

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  // Fixed notification ID for the ongoing call
  static const int _callNotificationId = 9999;
  static const String _channelId = 'ongoing_call';
  static const String _channelName = 'Ongoing Call';

  // Call duration tracking
  Timer? _durationTimer;
  int _callDurationSeconds = 0;
  String? _remoteName;
  String? _callType;
  bool _isShowing = false;

  // Callback for end call action from notification
  VoidCallback? onEndCallFromNotification;

  bool get isShowing => _isShowing;

  /// Initialize the notification channel
  Future<void> initialize() async {
    // Create the ongoing call notification channel
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: 'Shows when a call is in progress',
      importance: Importance.low, // Low so it doesn't make sound
      playSound: false,
      enableVibration: false,
      showBadge: false,
    );

    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);

    // Initialize with action handling
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings();

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: iosSettings,
    );

    await _localNotifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _handleNotificationAction,
    );
  }

  /// Handle notification action button taps
  void _handleNotificationAction(NotificationResponse response) {
    debugPrint('📞 Notification action: ${response.actionId}');
    if (response.actionId == 'end_call') {
      debugPrint('📞 End call pressed from notification');
      onEndCallFromNotification?.call();
      dismiss();
    } else if (response.payload == 'ongoing_call') {
      // Tapped the notification body - could navigate back to call screen
      debugPrint('📞 Ongoing call notification tapped');
    }
  }

  /// Show the ongoing call notification
  Future<void> show({
    required String remoteName,
    required String callType,
  }) async {
    _remoteName = remoteName;
    _callType = callType;
    _callDurationSeconds = 0;
    _isShowing = true;

    // Show initial notification
    await _updateNotification();

    // Start duration timer to update the notification every second
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _callDurationSeconds++;
      _updateNotification();
    });

    debugPrint(
      '📞 Ongoing call notification shown for $remoteName ($callType)',
    );
  }

  /// Update the notification with current duration
  Future<void> _updateNotification() async {
    if (!_isShowing) return;

    final duration = _formatDuration(_callDurationSeconds);
    final isVideo = _callType == 'video';
    final title = '${isVideo ? 'Video' : 'Audio'} call with $_remoteName';
    final body = 'In progress · $duration';

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Shows when a call is in progress',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true, // Makes it persistent (can't swipe away)
          autoCancel: false,
          showWhen: false,
          usesChronometer: true,
          chronometerCountDown: false,
          icon: '@mipmap/ic_launcher',
          category: AndroidNotificationCategory.call,
          visibility: NotificationVisibility.public,
          actions: <AndroidNotificationAction>[
            const AndroidNotificationAction(
              'end_call',
              'End Call',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
        );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: false,
      presentBadge: false,
      presentSound: false,
    );

    final NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _localNotifications.show(
      _callNotificationId,
      title,
      body,
      details,
      payload: 'ongoing_call',
    );
  }

  /// Update notification to show "Call Ended"
  Future<void> showCallEnded() async {
    _durationTimer?.cancel();

    final duration = _formatDuration(_callDurationSeconds);
    final title = 'Call ended';
    final body = 'Duration: $duration';

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Shows when a call is in progress',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: false, // Allow swipe to dismiss
          autoCancel: true,
          showWhen: true,
          icon: '@mipmap/ic_launcher',
        );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: false,
    );

    final NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _localNotifications.show(_callNotificationId, title, body, details);

    _isShowing = false;

    // Auto-dismiss after 5 seconds
    Future.delayed(const Duration(seconds: 5), () {
      _localNotifications.cancel(_callNotificationId);
    });

    debugPrint('📞 Call ended notification shown (duration: $duration)');
  }

  /// Dismiss the ongoing call notification
  Future<void> dismiss() async {
    _durationTimer?.cancel();
    _durationTimer = null;
    _callDurationSeconds = 0;
    _isShowing = false;
    _remoteName = null;
    _callType = null;
    onEndCallFromNotification = null;

    await _localNotifications.cancel(_callNotificationId);
    debugPrint('📞 Ongoing call notification dismissed');
  }

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }
}
