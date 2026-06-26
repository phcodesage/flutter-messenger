import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import 'storage_service.dart';
import 'auth_error_handler.dart';
import 'active_chat_service.dart';
import 'version_service.dart';
import '../utils/notification_handler.dart';

/// Service for managing user presence and heartbeat.
///
/// Implements Skype/Teams-like presence behavior:
///   - **Foreground** (app open & active) → `online` (green dot)
///   - **Background** (app minimized/switched) → `away` (yellow dot)
///   - **Closed / killed** → `offline` (backend grace period handles this)
///   - **Logout** → `offline` (explicit)
class PresenceService with WidgetsBindingObserver {
  static final PresenceService _instance = PresenceService._internal();
  factory PresenceService() => _instance;
  PresenceService._internal();

  Timer? _heartbeatTimer;
  bool _isActive = false;
  bool _observerRegistered = false;

  /// Current status as last sent to the backend
  String _currentStatus = 'offline';

  /// Whether a call is in progress (skip marking away during calls)
  bool isCallInProgress = false;

  /// Global guard: prevents multiple screens (lobby + chat) from handling
  /// the same incoming call event simultaneously. Both screens share this
  /// singleton flag so the first handler wins and the second is skipped.
  bool isHandlingIncomingCall = false;

  /// Handle app lifecycle changes (Skype-like behavior)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!_isActive) return;

    debugPrint(
      '📱 App lifecycle: $state (call=$isCallInProgress, status=$_currentStatus)',
    );

    switch (state) {
      case AppLifecycleState.resumed:
        // App came to foreground → online
        _setStatusIfChanged('online');
        _restartHeartbeatTimer(const Duration(seconds: 30));
        // Notify active chat service that app is in foreground
        ActiveChatService().setAppForegroundState(true);
        break;
      case AppLifecycleState.inactive:
        // Transitional (app switcher, phone call overlay) — ignore
        break;
      case AppLifecycleState.paused:
        // App went to background → away (unless in a call)
        if (!isCallInProgress) {
          _setStatusIfChanged('away');
        }
        // Slow heartbeat in background
        _restartHeartbeatTimer(const Duration(seconds: 60));
        // Notify active chat service that app is in background
        ActiveChatService().setAppForegroundState(false);
        break;
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // App closing / fully hidden → offline
        if (!isCallInProgress) {
          _setStatusIfChanged('offline');
        }
        _stopHeartbeatTimer();
        // Notify active chat service that app is in background
        ActiveChatService().setAppForegroundState(false);
        break;
    }
  }

  /// Send status update only if it changed
  void _setStatusIfChanged(String status) {
    if (_currentStatus == status) return;
    _currentStatus = status;
    updateStatus(status);
  }

  /// Start sending heartbeat and register lifecycle observer
  void startHeartbeat() {
    if (_isActive) return;

    _isActive = true;
    _currentStatus = 'online';
    debugPrint('Starting heartbeat...');

    // Register lifecycle observer for foreground/background detection
    if (!_observerRegistered) {
      WidgetsBinding.instance.addObserver(this);
      _observerRegistered = true;
      debugPrint('📱 PresenceService lifecycle observer registered');
    }

    // Send initial heartbeat
    _sendHeartbeat();

    // Start heartbeat timer
    _restartHeartbeatTimer(const Duration(seconds: 30));
  }

  /// Stop sending heartbeat and unregister lifecycle observer
  void stopHeartbeat() {
    _isActive = false;
    _currentStatus = 'offline';
    debugPrint('Stopping heartbeat...');
    _stopHeartbeatTimer();

    // Unregister lifecycle observer
    if (_observerRegistered) {
      WidgetsBinding.instance.removeObserver(this);
      _observerRegistered = false;
      debugPrint('📱 PresenceService lifecycle observer unregistered');
    }
  }

  void _restartHeartbeatTimer(Duration interval) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(interval, (_) {
      _sendHeartbeat();
    });
  }

  void _stopHeartbeatTimer() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _sendHeartbeat() async {
    try {
      final token = await StorageService.getToken();
      if (token == null) return;

      final response = await http
          .post(
            Uri.parse(ApiConfig.heartbeatUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 401) {
        // Token expired - stop heartbeat and trigger auth error
        debugPrint('🔐 Heartbeat - Token expired');
        stopHeartbeat();
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        return;
      }

      debugPrint('💓 Heartbeat sent');

      // Piggyback a (throttled) app-version check on the heartbeat so a new
      // release is picked up while the app stays open, not only on next launch.
      unawaited(
        VersionService().checkAndPromptUpdate(
          NotificationHandler.navigatorKey.currentContext,
        ),
      );
    } catch (e) {
      debugPrint('Heartbeat error: $e');
    }
  }

  /// Update user status
  static Future<void> updateStatus(
    String status, {
    String? statusMessage,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) return;

      final response = await http
          .post(
            Uri.parse(ApiConfig.presenceStatusUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'status': status,
              if (statusMessage != null) 'status_message': statusMessage,
            }),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 401) {
        // Token expired - trigger auth error
        debugPrint('🔐 Status update - Token expired');
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        return;
      }

      debugPrint('Status updated to: $status');
    } catch (e) {
      debugPrint('Update status error: $e');
    }
  }

  void dispose() {
    stopHeartbeat();
    if (_observerRegistered) {
      WidgetsBinding.instance.removeObserver(this);
      _observerRegistered = false;
    }
  }
}
