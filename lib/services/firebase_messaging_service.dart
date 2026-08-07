import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:convert';
import 'background_update_service.dart';
import 'fcm_service.dart';
import 'active_chat_service.dart';
// Aliased: flutter_local_notifications also exports a `Message`
// (MessagingStyle), and this file uses both.
import '../models/message.dart' as chat_models;
import 'chat_cache_service.dart';
import 'message_cache_sync_service.dart';
import 'pending_incoming_call_service.dart';
import 'storage_service.dart';
import 'version_service.dart';
import '../config/api_config.dart';
import '../utils/notification_handler.dart';
import 'message_service.dart';
import 'group_service.dart';
import 'media_preload_service.dart';

const String _chatQuickReplyInputActionId = 'chat_reply_input';
const int _appUpdateNotificationId = 9001;
const String _appUpdateChannelId = 'app_update';
const String _appUpdateChannelName = 'App Updates';
const MethodChannel _quickReplyNativeChannel = MethodChannel(
  'com.example.flutter_messenger_v2/quick_reply',
);
const MethodChannel _nativeNotificationPayloadChannel = MethodChannel(
  'com.example.flutter_messenger_v2/notification_payload',
);
const Map<String, String> _chatQuickReplyActionMap = <String, String>{
  'chat_quick_ok': 'OK',
  'chat_quick_on_my_way': 'On my way',
  'chat_quick_thanks': 'Thanks',
};

@pragma('vm:entry-point')
Future<void> notificationTapBackgroundHandler(
  NotificationResponse response,
) async {
  await FirebaseMessagingService.instance._processNotificationResponse(
    response,
  );
}

bool _isChatQuickReplyEligible(Map<String, dynamic> data) {
  final type = data['type']?.toString().toLowerCase();
  if (type == 'color_change' || type == 'call') {
    return false;
  }

  if (type != null && type != 'message' && type != 'chat') {
    return false;
  }

  return data['sender_id'] != null ||
      data['group_id'] != null ||
      data['room_id'] != null;
}

bool _isConversationNotificationEligible(Map<String, dynamic> data) {
  final type = data['type']?.toString().toLowerCase();
  if (type == 'call') {
    return false;
  }

  // If backend marks this as a chat/message event, always treat it as a
  // conversation notification even when sender metadata is sparse.
  if (type == 'message' || type == 'chat') {
    return true;
  }

  final title = data['title']?.toString().trim();
  final body = data['body']?.toString().trim();
  final content = data['content']?.toString().trim();
  if ((title?.isNotEmpty ?? false) ||
      (body?.isNotEmpty ?? false) ||
      (content?.isNotEmpty ?? false)) {
    return true;
  }

  return data['sender_id'] != null ||
      data['group_id'] != null ||
      data['room_id'] != null ||
      (data['sender_name']?.toString().trim().isNotEmpty ?? false);
}

bool _isChatQuickReplyActionId(String? actionId) {
  if (actionId == null || actionId.isEmpty) {
    return false;
  }

  return actionId == _chatQuickReplyInputActionId ||
      _chatQuickReplyActionMap.containsKey(actionId);
}

bool _isAppUpdateType(Map<String, dynamic> data) {
  return data['type']?.toString().toLowerCase() == 'app_update';
}

String _readActionId(Map<String, dynamic> data, String key, String fallback) {
  final value = data[key]?.toString().trim();
  if (value == null || value.isEmpty) return fallback;
  return value;
}

int _buildChatNotificationId(Map<String, dynamic> data) {
  final groupId = data['group_id']?.toString();
  if (groupId != null && groupId.isNotEmpty) {
    return 'group:$groupId'.hashCode & 0x7FFFFFFF;
  }

  final senderId = data['sender_id']?.toString();
  if (senderId != null && senderId.isNotEmpty) {
    return 'direct:$senderId'.hashCode & 0x7FFFFFFF;
  }

  final roomId = data['room_id']?.toString();
  if (roomId != null && roomId.isNotEmpty) {
    return roomId.hashCode & 0x7FFFFFFF;
  }

  final senderName = data['sender_name']?.toString().trim();
  if (senderName != null && senderName.isNotEmpty) {
    return 'sender:$senderName'.hashCode & 0x7FFFFFFF;
  }

  final messageId = data['message_id']?.toString();
  if (messageId != null && messageId.isNotEmpty) {
    return 'msg:$messageId'.hashCode & 0x7FFFFFFF;
  }

  return DateTime.now().millisecondsSinceEpoch ~/ 1000;
}

String _buildChatConversationKey(Map<String, dynamic> data) {
  final groupId = data['group_id']?.toString();
  if (groupId != null && groupId.isNotEmpty) {
    return 'group:$groupId';
  }

  final senderId = data['sender_id']?.toString();
  if (senderId != null && senderId.isNotEmpty) {
    return 'direct:$senderId';
  }

  final recipientId = data['reply_recipient_id']?.toString();
  if (recipientId != null && recipientId.isNotEmpty) {
    return 'direct:$recipientId';
  }

  final roomId = data['room_id']?.toString();
  if (roomId != null && roomId.isNotEmpty) {
    return 'room:$roomId';
  }

  final senderName = data['sender_name']?.toString().trim();
  if (senderName != null && senderName.isNotEmpty) {
    return 'sender:$senderName';
  }

  final messageId = data['message_id']?.toString();
  if (messageId != null && messageId.isNotEmpty) {
    return 'msg:$messageId';
  }

  return 'ts:${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
}

Map<String, String> _extractNotificationText(Map<String, dynamic> data) {
  final title = (data['title'] ?? '').toString().trim();
  final body = (data['body'] ?? '').toString().trim();
  final content = (data['content'] ?? '').toString().trim();
  final messageType = (data['message_type'] ?? data['messageType'])
      ?.toString()
      .toLowerCase();
  final fileName = (data['file_name'] ?? data['fileName'] ?? '')
      .toString()
      .trim();
  final fallbackBody = switch (messageType) {
    'audio' || 'voice' => '🎤 Voice message',
    'image' => fileName.isNotEmpty ? '🖼️ Image: $fileName' : '🖼️ Image',
    'video' => fileName.isNotEmpty ? '🎬 Video: $fileName' : '🎬 Video',
    'file' => fileName.isNotEmpty ? '📎 File: $fileName' : '📎 File',
    'contact' => '👤 Contact card',
    _ => fileName.isNotEmpty ? '📎 $fileName' : '',
  };

  return {
    'title': title.isNotEmpty ? title : 'New message',
    'body': body.isNotEmpty
        ? body
        : (content.isNotEmpty ? content : fallbackBody),
  };
}

String? _resolveNotificationTitle(Map<String, dynamic> data) {
  return _extractNotificationText(data)['title'];
}

String? _resolveNotificationBody(Map<String, dynamic> data) {
  return _extractNotificationText(data)['body'];
}

StyleInformation? _buildMessagingStyle(Map<String, dynamic> data, String body) {
  if (!_isConversationNotificationEligible(data)) {
    return null;
  }

  final senderName = data['sender_name']?.toString().trim();
  final groupName = data['group_name']?.toString().trim();
  final isGroup =
      data['conversation_type']?.toString().toLowerCase() == 'group' ||
      data['group_id'] != null;

  final senderPerson = Person(name: senderName ?? 'Someone', important: true);

  return MessagingStyleInformation(
    Person(name: 'You'),
    conversationTitle: isGroup && groupName != null && groupName.isNotEmpty
        ? groupName
        : null,
    groupConversation: isGroup,
    messages: <Message>[Message(body, DateTime.now(), senderPerson)],
  );
}

String _resolveQuickReplyEndpoint(Map<String, dynamic> data) {
  final explicitEndpoint = data['reply_endpoint']?.toString().trim();
  if (explicitEndpoint != null && explicitEndpoint.isNotEmpty) {
    return explicitEndpoint;
  }

  final conversationType = data['conversation_type']?.toString().toLowerCase();
  final groupId = data['group_id']?.toString();

  if ((conversationType == 'group' || groupId != null) &&
      groupId != null &&
      groupId.isNotEmpty) {
    return '${ApiConfig.mobilePrefix}/groups/$groupId/messages/quick-reply';
  }

  return '${ApiConfig.mobilePrefix}/messages/quick-reply';
}

Uri _buildQuickReplyUri(String endpoint) {
  final normalized = endpoint.trim();
  if (normalized.startsWith('http://') || normalized.startsWith('https://')) {
    return Uri.parse(normalized);
  }

  final path = normalized.startsWith('/') ? normalized : '/$normalized';
  return Uri.parse('${ApiConfig.baseUrl}$path');
}

Future<bool> _showNativeQuickReplyNotification({
  required Map<String, dynamic> data,
  required String title,
  required String body,
  bool allowFromBackgroundIsolate = true,
}) async {
  if (defaultTargetPlatform != TargetPlatform.android ||
      !_isConversationNotificationEligible(data)) {
    return false;
  }

  if (!allowFromBackgroundIsolate) {
    return false;
  }

  final conversationType = data['conversation_type']?.toString().toLowerCase();
  final isGroup = conversationType == 'group' || data['group_id'] != null;

  try {
    await _quickReplyNativeChannel.invokeMethod(
      'showChatQuickReplyNotification',
      <String, dynamic>{
        'notificationId': _buildChatNotificationId(data),
        'channelId': 'chat_messages',
        'channelName': 'Chat Messages',
        'title': title,
        'body': body,
        'senderName': data['sender_name']?.toString() ?? 'Someone',
        'groupName': data['group_name']?.toString(),
        'isGroup': isGroup,
        'replyEndpoint': _resolveQuickReplyEndpoint(data),
        'replyRecipientId':
            data['reply_recipient_id']?.toString() ??
            data['sender_id']?.toString(),
        'conversationType': conversationType ?? (isGroup ? 'group' : 'direct'),
        'enableQuickReply': _isChatQuickReplyEligible(data),
        'groupId': data['group_id']?.toString(),
        'conversationKey': _buildChatConversationKey(data),
        'baseUrl': ApiConfig.baseUrl,
        'payloadJson': jsonEncode(data),
      },
    );

    return true;
  } catch (e) {
    debugPrint('⚠️ Native quick-reply notification fallback: $e');
    return false;
  }
}

String? _resolveQuickReplyText(NotificationResponse response) {
  if (response.actionId == _chatQuickReplyInputActionId) {
    final input = response.input?.trim();
    return (input == null || input.isEmpty) ? null : input;
  }

  return _chatQuickReplyActionMap[response.actionId];
}

List<AndroidNotificationAction> _buildChatQuickReplyActions(
  Map<String, dynamic> data,
) {
  if (!_isChatQuickReplyEligible(data)) {
    return const <AndroidNotificationAction>[];
  }

  return const <AndroidNotificationAction>[
    AndroidNotificationAction(
      _chatQuickReplyInputActionId,
      'Reply',
      showsUserInterface: false,
      cancelNotification: false,
      allowGeneratedReplies: true,
      inputs: <AndroidNotificationActionInput>[
        AndroidNotificationActionInput(label: 'Type a reply'),
      ],
    ),
    AndroidNotificationAction(
      'chat_quick_ok',
      'OK',
      showsUserInterface: false,
      cancelNotification: false,
    ),
    AndroidNotificationAction(
      'chat_quick_on_my_way',
      'On my way',
      showsUserInterface: false,
      cancelNotification: false,
    ),
    AndroidNotificationAction(
      'chat_quick_thanks',
      'Thanks',
      showsUserInterface: false,
      cancelNotification: false,
    ),
  ];
}

/// Background sync logic to pre-fetch conversations and media on FCM push receipt
Future<void> _performBackgroundSync(Map<String, dynamic> data) async {
  try {
    debugPrint('💾 FCM Background Sync: Initializing storage and cache...');
    await StorageService.init();
    await ChatCacheService.init();

    final userId = await StorageService.getUserId();
    final token = await StorageService.getToken();

    if (userId == null || token == null || token.isEmpty) {
      debugPrint('💾 FCM Background Sync: No authenticated user found. Skipping.');
      return;
    }

    // Initialize media preloader so we can pre-download files/media
    await MediaPreloadService.instance.start();

    // Check conversation type
    final isGroup = data['conversation_type'] == 'group';
    if (isGroup) {
      final groupId = int.tryParse(data['group_id']?.toString() ?? '');
      if (groupId != null) {
        debugPrint('💾 FCM Background Sync: Syncing group $groupId...');
        final messages = await GroupService.getMessages(
          groupId: groupId,
          offlineFirst: false,
        ).timeout(const Duration(seconds: 10));

        debugPrint('💾 FCM Background Sync: Prefetching media for group $groupId...');
        await MediaPreloadService.instance.prefetchGroupMessages(
          messages.take(20),
        ).timeout(const Duration(seconds: 8));
      }
    } else {
      final senderId = int.tryParse(data['sender_id']?.toString() ?? '');
      if (senderId != null) {
        debugPrint('💾 FCM Background Sync: Syncing conversation $senderId...');
        final messages = await MessageService.getConversationMessages(
          userId: senderId,
          offlineFirst: false,
        ).timeout(const Duration(seconds: 10));

        debugPrint('💾 FCM Background Sync: Prefetching media for conversation $senderId...');
        await MediaPreloadService.instance.prefetchMessages(
          messages.take(20),
        ).timeout(const Duration(seconds: 8));
      }
    }
    debugPrint('💾 FCM Background Sync: Complete.');
  } catch (e) {
    debugPrint('💾 FCM Background Sync: Failed with error: $e');
  }
}

/// Top-level function for background message handling
/// This runs in a separate isolate when app is terminated/background
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('📱 Background message received: ${message.messageId}');
  debugPrint('Data: ${message.data}');

  // Initialize local notifications for background/terminated state
  final FlutterLocalNotificationsPlugin localNotifications =
      FlutterLocalNotificationsPlugin();

  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  );

  const InitializationSettings settings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
    macOS: iosSettings,
  );

  await localNotifications.initialize(
    settings,
    onDidReceiveBackgroundNotificationResponse:
        notificationTapBackgroundHandler,
  );

  // Persist color change to SharedPreferences so ChatScreen picks it up on open
  final data = message.data;
  if (data['type'] == 'color_change') {
    try {
      final prefs = await SharedPreferences.getInstance();
      final senderId = data['sender_id']?.toString();
      final color = data['color'] as String?;
      if (senderId != null && color != null) {
        await prefs.setString('chat_color_$senderId', color);
        debugPrint(
          '🎨 Background: persisted chat color $color for user $senderId',
        );
      }
    } catch (e) {
      debugPrint('Error persisting background color change: $e');
    }
  }

  if (_isAppUpdateType(data)) {
    // No "Download Now / Later" notification. We can't reliably download a large
    // APK from a short-lived background isolate, so do nothing here — the next
    // app open / heartbeat version check downloads it silently (auto mode) or
    // surfaces the in-app prompt (manual mode).
    debugPrint(
      '📲 Background app_update received — deferring to next foreground version check.',
    );
    return;
  }

  // Handle incoming call notifications specifically
  if (data['type'] == 'call') {
    debugPrint('📞 Background: Incoming call notification received');
    await _showIncomingCallNotification(localNotifications, data);
    return; // Don't show generic notification for calls
  }

  // On Android, chat notifications are rendered natively by ChatFirebaseMessagingReceiver
  // so inline reply works when app is backgrounded/terminated without MethodChannel.
  if (defaultTargetPlatform == TargetPlatform.android &&
      _isConversationNotificationEligible(data)) {
    debugPrint(
      '📨 Android background chat notification delegated to native receiver',
    );
    await _performBackgroundSync(data);
    return;
  }

  // Show the notification from data payload (data-only FCM messages)
  final String? title = _resolveNotificationTitle(data);
  final String? body = _resolveNotificationBody(data);

  if (title != null && body != null) {
    final showedNatively = await _showNativeQuickReplyNotification(
      data: data,
      title: title,
      body: body,
      // Background FCM isolate does not have MainActivity MethodChannel handlers.
      allowFromBackgroundIsolate: false,
    );
    if (showedNatively) {
      return;
    }

    String channelId = 'chat_messages';
    String channelName = 'Chat Messages';

    if (data['type'] == 'doorbell') {
      channelId = 'doorbell';
      channelName = 'Doorbell Notifications';
    } else if (data['type'] == 'call') {
      channelId = 'calls';
      channelName = 'Incoming Calls';
    }

    final quickReplyActions = _buildChatQuickReplyActions(data);
    final styleInformation = _buildMessagingStyle(data, body);

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: body,
          importance: Importance.max,
          priority: Priority.high,
          showWhen: true,
          enableVibration: true,
          playSound: true,
          icon: '@mipmap/ic_launcher',
          category: _isChatQuickReplyEligible(data)
              ? AndroidNotificationCategory.message
              : null,
          styleInformation: styleInformation,
          actions: quickReplyActions,
        );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await localNotifications.show(
      _buildChatNotificationId(data),
      title,
      body,
      details,
      payload: jsonEncode(data),
    );
  }

  if (_isConversationNotificationEligible(data)) {
    await _performBackgroundSync(data);
  }
}

/// Show incoming call notification in background/terminated state
Future<void> _showIncomingCallNotification(
  FlutterLocalNotificationsPlugin localNotifications,
  Map<String, dynamic> data,
) async {
  debugPrint('📞 Showing incoming call notification: $data');

  final senderName = data['sender_name'] as String? ?? 'Unknown';
  final callType = data['call_type'] as String? ?? 'video';

  // Create high-priority call notification
  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'incoming_calls',
    'Incoming Calls',
    channelDescription: 'Notifications for incoming calls',
    importance: Importance.max,
    priority: Priority.high,
    category: AndroidNotificationCategory.call,
    fullScreenIntent: true, // Shows as full-screen notification
    ongoing: false,
    autoCancel: true,
    showWhen: true,
    enableVibration: true,
    playSound: true,
    icon: '@mipmap/ic_launcher',
    largeIcon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
    styleInformation: BigTextStyleInformation(
      'Tap to answer the call',
      contentTitle: '📞 Incoming Call',
      summaryText: 'Tap to answer',
    ),
  );

  const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
    categoryIdentifier: 'CALL_CATEGORY',
  );

  const NotificationDetails details = NotificationDetails(
    android: androidDetails,
    iOS: iosDetails,
  );

  // Show the call notification
  await localNotifications.show(
    999, // Use fixed ID for call notifications so they replace each other
    '📞 $senderName',
    'Incoming $callType call - Tap to answer',
    details,
    payload: jsonEncode(data),
  );

  debugPrint('📞 Call notification displayed for $senderName');
}

/// Service for handling Firebase Cloud Messaging (FCM) push notifications
class FirebaseMessagingService {
  static final FirebaseMessagingService instance =
      FirebaseMessagingService._internal();
  factory FirebaseMessagingService() => instance;
  FirebaseMessagingService._internal();

  // Lazily resolved so merely *constructing* this singleton never touches
  // Firebase. `FirebaseMessaging.instance` throws `[core/no-app]` when no
  // Firebase app is initialized (e.g. macOS desktop, where the placeholder
  // firebase_options fail to init). Eagerly initializing this field as before
  // made every access to FirebaseMessagingService.instance throw synchronously,
  // which aborted callers mid-flow (e.g. ChatScreen._initialize → no messages).
  FirebaseMessaging? _firebaseMessagingCache;
  FirebaseMessaging get _firebaseMessaging =>
      _firebaseMessagingCache ??= FirebaseMessaging.instance;

  /// True only when a Firebase app has actually been initialized. On platforms
  /// without Firebase configured this is false and all FCM operations are
  /// skipped instead of throwing.
  bool get _firebaseReady => Firebase.apps.isNotEmpty;

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  bool _localNotificationsInitialized = false;

  String? _fcmToken;
  String? get fcmToken => _fcmToken;

  // Callback for when notification is tapped
  Function(Map<String, dynamic>)? onNotificationTapped;

  /// Initialize Firebase Messaging and request permissions
  Future<void> initialize() async {
    if (!_firebaseReady) {
      debugPrint(
        'ℹ️ Firebase not initialized — skipping FCM setup (push notifications '
        'unavailable on this platform).',
      );
      return;
    }
    try {
      // Request permission for notifications
      NotificationSettings settings = await _firebaseMessaging
          .requestPermission(
            alert: true,
            badge: true,
            sound: true,
            provisional: false,
            announcement: false,
            carPlay: false,
            criticalAlert: false,
          );

      if (settings.authorizationStatus == AuthorizationStatus.authorized) {
        debugPrint('✅ User granted notification permission');
      } else if (settings.authorizationStatus ==
          AuthorizationStatus.provisional) {
        debugPrint('⚠️ User granted provisional notification permission');
      } else {
        debugPrint('❌ User declined notification permission');
        return;
      }

      // Initialize local notifications for foreground display
      await _initializeLocalNotifications();

      // Get FCM token
      _fcmToken = await _firebaseMessaging.getToken();
      debugPrint('📱 FCM Token: $_fcmToken');

      // Save token locally and send to backend
      if (_fcmToken != null) {
        await _saveFCMToken(_fcmToken!);
        // Send FCM token to backend so server can send push notifications
        await _updateBackendToken(_fcmToken!);
      }

      // Listen for token refresh and update backend
      _firebaseMessaging.onTokenRefresh.listen((newToken) async {
        debugPrint('📱 FCM Token refreshed: $newToken');
        _fcmToken = newToken;
        await _saveFCMToken(newToken);
        // Also update backend with new token
        await _updateBackendToken(newToken);
      });

      // Set up background message handler
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      // Handle foreground messages
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint(
          '📨 Foreground message received: ${message.notification?.title}',
        );

        // For call notifications in foreground, trigger the call handler AND show
        // a heads-up notification so the user sees a banner even when the app is open.
        final data = message.data;

        // A push for an incoming message means that thread has moved on. The
        // socket normally tells us first and the message is cached before we
        // get here, but when the socket is down or reconnecting this push is
        // the only notice we get — and its payload has no message content, so
        // the room is queued for a background re-sync instead. Without this the
        // room would still be stale when opened, which is the one way incoming
        // messages differ from our own cross-device echoes.
        if (data['type'] == 'message') {
          _queueConversationRefreshFromPush(data);
        }

        if (data['type'] == 'call') {
          final senderId = int.tryParse(data['sender_id']?.toString() ?? '');
          final activeUserId = ActiveChatService().activeUserId;
          // Only pop the modal when the caller's own chat is open; otherwise
          // (lobby, group, or a different chat) defer it.
          final inCallerChat =
              activeUserId != null &&
              senderId != null &&
              activeUserId == senderId;
          if (!inCallerChat) {
            // Cross-room guard: don't pop the full-screen call modal over a
            // DIFFERENT conversation than the caller. Defer it — the socket
            // 'incomingCall' path shows the in-chat banner, and the lobby tile
            // shows a ringing indicator (we stash the offer here too in case the
            // socket isn't connected). The modal is surfaced when the user opens
            // the caller's chat. The heads-up notification still shows below.
            debugPrint(
              '📲 Foreground call from $senderId while viewing $activeUserId — deferring modal',
            );
            // Only stash if the FCM payload carries a room; otherwise rely on the
            // socket 'incomingCall' path (which has the authoritative room) so we
            // don't clobber a good pending entry with a null room.
            final callRoom = data['call_room_id'];
            if (callRoom is String && callRoom.isNotEmpty) {
              PendingIncomingCallService().setPending({
                'id':
                    int.tryParse(data['call_id']?.toString() ?? '') ??
                    DateTime.now().millisecondsSinceEpoch,
                'call_room_id': callRoom,
                'call_type': data['call_type'] ?? 'video',
                'caller_id': senderId,
                'caller': {
                  'id': senderId,
                  'username': data['sender_name'] ?? 'Unknown',
                  'full_name': data['sender_name'] ?? 'Unknown',
                },
              });
            }
          } else {
            debugPrint(
              '📞 Foreground call notification - triggering call handler + showing banner',
            );
            _handleNotificationTap(data);
          }
          // Fall through to showNotification so a banner is displayed
        }

        showNotification(message);
      });

      // Handle notification tap when app is in background
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('🔔 Notification tapped (app in background)');
        _handleNotificationTap(message.data);
      });

      // Handle foreground notification tap from native Android quick-reply
      // notification (background → foreground case via onNewIntent)
      if (defaultTargetPlatform == TargetPlatform.android) {
        _nativeNotificationPayloadChannel.setMethodCallHandler((call) async {
          if (call.method == 'onNotificationTap') {
            final payload = call.arguments as String?;
            if (payload != null) {
              try {
                final data = jsonDecode(payload) as Map<String, dynamic>;
                _handleNotificationTap(data);
              } catch (e) {
                debugPrint('Error parsing native notification payload: $e');
              }
            }
          }
        });
      }

      debugPrint('✅ Firebase Messaging initialized successfully');
    } catch (e) {
      debugPrint('❌ Error initializing Firebase Messaging: $e');
    }
  }

  /// Initialize local notifications plugin
  Future<void> _initializeLocalNotifications() async {
    if (_localNotificationsInitialized) return;

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
        );

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: iosSettings,
    );

    await _localNotifications.initialize(
      settings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        _handleNotificationResponse(response);
      },
      onDidReceiveBackgroundNotificationResponse:
          notificationTapBackgroundHandler,
    );

    // Create notification channels for Android
    const AndroidNotificationChannel messagesChannel =
        AndroidNotificationChannel(
          'chat_messages',
          'Chat Messages',
          description: 'Notifications for new chat messages',
          importance: Importance.high,
          playSound: true,
          enableVibration: true,
        );

    const AndroidNotificationChannel doorbellChannel =
        AndroidNotificationChannel(
          'doorbell',
          'Doorbell Notifications',
          description: 'Notifications for doorbell rings',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        );

    const AndroidNotificationChannel callsChannel = AndroidNotificationChannel(
      'calls',
      'Incoming Calls',
      description: 'Notifications for incoming calls',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );

    const AndroidNotificationChannel
    incomingCallsChannel = AndroidNotificationChannel(
      'incoming_calls',
      'Incoming Calls (Background)',
      description:
          'High-priority notifications for incoming calls when app is in background',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );

    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(messagesChannel);

    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(doorbellChannel);

    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(callsChannel);

    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(incomingCallsChannel);

    const AndroidNotificationChannel appUpdateChannel =
        AndroidNotificationChannel(
          _appUpdateChannelId,
          _appUpdateChannelName,
          description: 'Notifications for app version updates',
          importance: Importance.high,
          playSound: true,
          enableVibration: true,
        );

    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(appUpdateChannel);

    _localNotificationsInitialized = true;
  }

  Future<void> clearIncomingCallNotifications({
    int? otherUserId,
    String? callRoomId,
  }) async {
    try {
      await _initializeLocalNotifications();

      // Background incoming-call notification uses fixed ID.
      await _localNotifications.cancel(999);

      // Foreground direct-call notification uses sender hash.
      if (otherUserId != null) {
        final directCallNotificationId =
            'direct:$otherUserId'.hashCode & 0x7FFFFFFF;
        await _localNotifications.cancel(directCallNotificationId);
      }

      // Some payloads may use room-scoped IDs.
      if (callRoomId != null && callRoomId.isNotEmpty) {
        final roomCallNotificationId = callRoomId.hashCode & 0x7FFFFFFF;
        await _localNotifications.cancel(roomCallNotificationId);
      }
    } catch (e) {
      debugPrint('❌ Error clearing incoming call notifications: $e');
    }
  }

  Future<void> clearConversationNotificationState({
    int? otherUserId,
    int? groupId,
    String? roomId,
    String? senderName,
  }) async {
    try {
      await _initializeLocalNotifications();

      final senderNameTrimmed = senderName?.trim();
      final keyCandidates = <Map<String, dynamic>>[
        if (roomId != null && roomId.isNotEmpty) {'room_id': roomId},
        if (groupId != null) {'group_id': groupId},
        if (otherUserId != null) {'sender_id': otherUserId},
        if (senderNameTrimmed != null && senderNameTrimmed.isNotEmpty)
          {'sender_name': senderNameTrimmed},
      ];

      final clearedNotificationIds = <int>{};
      final clearedConversationKeys = <String>{};

      for (final keyData in keyCandidates) {
        final notificationId = _buildChatNotificationId(keyData);
        if (clearedNotificationIds.add(notificationId)) {
          await _localNotifications.cancel(notificationId);
        }

        if (defaultTargetPlatform == TargetPlatform.android) {
          final conversationKey = _buildChatConversationKey(keyData);
          if (clearedConversationKeys.add(conversationKey)) {
            await _quickReplyNativeChannel.invokeMethod(
              'clearConversationNotificationState',
              <String, dynamic>{
                'notificationId': notificationId,
                'conversationKey': conversationKey,
              },
            );
          }
        }
      }
    } catch (e) {
      debugPrint('❌ Error clearing conversation notification state: $e');
    }
  }

  /// Queue the thread a message push belongs to for a background cache refresh,
  /// so it is already up to date if the user opens it.
  ///
  /// Only runs in the foreground isolate. The background handler deliberately
  /// does not do this: it runs in its own isolate where the Hive boxes are held
  /// open by the main one, and the app-resume prefetch covers that case.
  void _queueConversationRefreshFromPush(Map<String, dynamic> data) {
    try {
      final sync = MessageCacheSyncService();
      if (!sync.isRunning) return;

      if (data['conversation_type'] == 'group') {
        final groupId = int.tryParse(data['group_id']?.toString() ?? '');
        if (groupId != null) sync.markGroupConversationDirty(groupId);
        return;
      }

      // Direct message: the push is addressed to us, so its sender is the peer.
      final senderId = int.tryParse(data['sender_id']?.toString() ?? '');
      if (senderId == null) return;

      // The server inlines plain-text messages in the payload. When it does,
      // cache the message itself — no network at all. Anything else (files,
      // voice, HTML bodies, or text too long to inline) only marks the room
      // dirty, and the background refresh fetches the server's parsed copy.
      unawaited(_cacheMessageFromPush(data, senderId, sync));
    } catch (e) {
      debugPrint('📨 Could not queue cache refresh from push: $e');
    }
  }

  Future<void> _cacheMessageFromPush(
    Map<String, dynamic> data,
    int senderId,
    MessageCacheSyncService sync,
  ) async {
    try {
      final content = data['content']?.toString();
      final messageId = int.tryParse(data['message_id']?.toString() ?? '');
      final recipientId = int.tryParse(data['recipient_id']?.toString() ?? '');
      final timestamp = data['timestamp']?.toString();
      // messageType is the key the server sends — `message_type` is reserved by
      // FCM and gets the whole push rejected. Old key kept as a fallback.
      final messageType =
          (data['messageType'] ?? data['message_type'])?.toString() ?? 'text';

      final canBuild = content != null &&
          content.isNotEmpty &&
          messageId != null &&
          recipientId != null &&
          timestamp != null &&
          timestamp.isNotEmpty &&
          messageType == 'text';

      if (!canBuild) {
        sync.markConversationDirty(senderId);
        return;
      }

      // Never cache over the copy the open room is maintaining.
      if (ActiveChatService().activeUserId == senderId) return;

      final message = chat_models.Message.fromJson({
        'id': messageId,
        'sender_id': senderId,
        'recipient_id': recipientId,
        'content': content,
        'message_type': 'text',
        'timestamp': timestamp,
        'is_read': false,
        'status': 'delivered',
      });

      await ChatCacheService.addMessageToCache(recipientId, senderId, message);
      debugPrint('📨 Cached pushed message $messageId for conversation $senderId');
    } catch (e) {
      // Anything unexpected in the payload: fall back to the refetch, which is
      // always correct.
      debugPrint('📨 Could not cache pushed message ($e) — refetching instead');
      sync.markConversationDirty(senderId);
    }
  }

  /// Show notification using local notifications plugin
  Future<void> showNotification(RemoteMessage message) async {
    Map<String, dynamic> data = message.data;

    if (_isAppUpdateType(data)) {
      // No "Download Now / Later" notification. Hand off to VersionService,
      // which downloads silently in the background when Automatic Updates are
      // on, or surfaces the in-app prompt when the user has them off.
      await VersionService().promptUpdateFromPush(
        NotificationHandler.navigatorKey.currentContext,
        data,
      );
      return;
    }

    // Smart notification filtering using ActiveChatService
    final activeChat = ActiveChatService();

    // Check if this is a group message
    final groupId = int.tryParse(data['group_id']?.toString() ?? '');
    if (groupId != null) {
      if (!activeChat.shouldShowGroupNotification(groupId)) {
        debugPrint(
          '🔕 Suppressing group notification — user is viewing group $groupId',
        );
        return;
      }
    }

    // Check if this is a 1-on-1 message
    final senderId = int.tryParse(data['sender_id']?.toString() ?? '');
    if (senderId != null && groupId == null) {
      // Only for 1-on-1 chats, not group messages
      if (!activeChat.shouldShowUserNotification(senderId)) {
        debugPrint(
          '🔕 Suppressing user notification — user is viewing chat with $senderId',
        );
        return;
      }
    }

    // Persist color change to SharedPreferences so ChatScreen picks it up
    if (data['type'] == 'color_change') {
      try {
        final prefs = await SharedPreferences.getInstance();
        final senderIdStr = data['sender_id']?.toString();
        final color = data['color'] as String?;
        if (senderIdStr != null && color != null) {
          await prefs.setString('chat_color_$senderIdStr', color);
          debugPrint(
            'Foreground: persisted chat color $color for user $senderIdStr',
          );
        }
      } catch (e) {
        debugPrint('Error persisting foreground color change: $e');
      }
    }

    // Get title/body from data payload (data-only FCM messages)
    final String? title = _resolveNotificationTitle(data);
    final String? body = _resolveNotificationBody(data);

    if (title != null && body != null) {
      final showedNatively = await _showNativeQuickReplyNotification(
        data: data,
        title: title,
        body: body,
      );
      if (showedNatively) {
        return;
      }

      // Determine notification channel based on type
      String channelId = 'chat_messages';
      String channelName = 'Chat Messages';

      if (data['type'] == 'doorbell') {
        channelId = 'doorbell';
        channelName = 'Doorbell Notifications';
      } else if (data['type'] == 'call') {
        channelId = 'calls';
        channelName = 'Incoming Calls';
      }

      final quickReplyActions = _buildChatQuickReplyActions(data);
      final styleInformation = _buildMessagingStyle(data, body);

      final AndroidNotificationDetails
      androidDetails = AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: body,
        importance: data['type'] == 'call' ? Importance.max : Importance.high,
        priority: data['type'] == 'call' ? Priority.max : Priority.high,
        showWhen: true,
        enableVibration: true,
        playSound: true,
        icon: '@mipmap/ic_launcher',
        // For incoming calls: request full-screen intent so the notification
        // appears as a heads-up alert even when the screen is off / locked
        fullScreenIntent: data['type'] == 'call',
        ticker: data['type'] == 'call' ? 'Incoming call' : null,
        category: _isChatQuickReplyEligible(data)
            ? AndroidNotificationCategory.message
            : null,
        styleInformation: styleInformation,
        actions: quickReplyActions,
      );

      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final NotificationDetails details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _localNotifications.show(
        _buildChatNotificationId(data),
        title,
        body,
        details,
        payload: jsonEncode(data),
      );
    }
  }

  /// Handle notification tap
  void _handleNotificationTap(Map<String, dynamic> data) {
    debugPrint('Notification tapped with data: $data');

    // Call the callback if set
    onNotificationTapped?.call(data);
  }

  void _handleNotificationResponse(NotificationResponse response) {
    _processNotificationResponse(response);
  }

  Future<void> _processNotificationResponse(
    NotificationResponse response,
  ) async {
    final payload = response.payload;
    if (payload == null) {
      return;
    }

    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;

      // "Ready to install" notification tap / "Install Now" action. This is the
      // handler that actually receives the tap (foreground and background), so
      // launching the installer from here is what makes install work.
      if (data['type']?.toString() == 'app_update_ready') {
        await BackgroundUpdateService().requestInstall();
        return;
      }

      if (_isAppUpdateType(data)) {
        await _handleAppUpdateResponse(data, response.actionId);
        return;
      }

      if (_isChatQuickReplyActionId(response.actionId)) {
        await _handleQuickReplyAction(data, response);
        return;
      }

      _handleNotificationTap(data);
    } catch (e) {
      debugPrint('Error parsing notification payload: $e');
    }
  }

  Future<void> _handleAppUpdateResponse(
    Map<String, dynamic> data,
    String? actionId,
  ) async {
    final updateNowActionId = _readActionId(
      data,
      'action_update_now',
      'update_now',
    );
    final updateLaterActionId = _readActionId(
      data,
      'action_update_later',
      'update_later',
    );

    final normalizedAction = actionId?.trim();

    if (normalizedAction == updateLaterActionId) {
      // User swiped/tapped "Later" — defer but keep the icon badge
      await VersionService().deferUpdatePayload(data);
      await _localNotifications.cancel(_appUpdateNotificationId);
      return;
    }

    // "Download Now" or body tap — start background download
    await _localNotifications.cancel(_appUpdateNotificationId);

    if (normalizedAction == null ||
        normalizedAction.isEmpty ||
        normalizedAction == updateNowActionId) {
      try {
        final info = AppVersionInfo.fromJson(data);
        final resolvedUrl = data['download_url']?.toString().trim() ?? '';
        if (info.version.isNotEmpty && resolvedUrl.isNotEmpty) {
          await BackgroundUpdateService().startBackgroundDownload(
            info,
            resolvedUrl,
          );
          return;
        }
      } catch (e) {
        debugPrint(
          '[FCM] Failed to start background download from notification: $e',
        );
      }
      // Fallback: open the update dialog via nav
      _handleNotificationTap(data);
    }
  }

  Future<void> _handleQuickReplyAction(
    Map<String, dynamic> data,
    NotificationResponse response,
  ) async {
    if (!_isChatQuickReplyEligible(data)) {
      _handleNotificationTap(data);
      return;
    }

    final quickReplyText = _resolveQuickReplyText(response);
    if (quickReplyText == null || quickReplyText.trim().isEmpty) {
      debugPrint('⚠️ Quick reply action received without reply text');
      return;
    }

    final sent = await _sendQuickReplyMessage(data, quickReplyText);
    if (!sent) {
      debugPrint('⚠️ Quick reply failed to send, opening the chat instead');
      _handleNotificationTap(data);
    }
  }

  Future<bool> _sendQuickReplyMessage(
    Map<String, dynamic> data,
    String replyText,
  ) async {
    final token = await StorageService.getToken();
    if (token == null || token.isEmpty) {
      debugPrint('⚠️ Cannot send quick reply without an auth token');
      return false;
    }

    final trimmedReply = replyText.trim();
    if (trimmedReply.isEmpty) {
      return false;
    }

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };

    try {
      final conversationType = data['conversation_type']
          ?.toString()
          .toLowerCase();
      final groupId = int.tryParse(data['group_id']?.toString() ?? '');
      final endpoint = _resolveQuickReplyEndpoint(data);
      final uri = _buildQuickReplyUri(endpoint);
      final isGroup =
          conversationType == 'group' ||
          groupId != null ||
          endpoint.contains('/groups/');

      final body = <String, dynamic>{'content': trimmedReply};
      if (!isGroup) {
        final recipientId = int.tryParse(
          data['reply_recipient_id']?.toString() ??
              data['sender_id']?.toString() ??
              '',
        );
        if (recipientId == null) {
          debugPrint(
            '❌ Quick reply payload missing reply_recipient_id/sender_id',
          );
          return false;
        }
        body['recipient_id'] = recipientId;
      }

      final response = await http
          .post(uri, headers: headers, body: jsonEncode(body))
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200 || response.statusCode == 201) {
        debugPrint('✅ Quick reply sent successfully to $uri');
        return true;
      }

      debugPrint(
        '❌ Failed quick reply request: ${response.statusCode} ${response.body}',
      );
      return false;
    } catch (e) {
      debugPrint('❌ Error sending quick reply: $e');
      return false;
    }
  }

  /// Save FCM token to local storage
  Future<void> _saveFCMToken(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcm_token', token);
      debugPrint('✅ FCM token saved locally');
    } catch (e) {
      debugPrint('❌ Error saving FCM token: $e');
    }
  }

  /// Update FCM token on backend (called when token refreshes)
  Future<void> _updateBackendToken(String token) async {
    try {
      await FCMService.updateFCMToken(token);
      debugPrint('✅ FCM token updated on backend after refresh');
    } catch (e) {
      debugPrint('❌ Error updating FCM token on backend: $e');
    }
  }

  /// Get saved FCM token from local storage
  Future<String?> getSavedFCMToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('fcm_token');
    } catch (e) {
      debugPrint('❌ Error getting saved FCM token: $e');
      return null;
    }
  }

  /// Clear FCM token (e.g., on logout)
  Future<void> clearFCMToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('fcm_token');
      if (!_firebaseReady) {
        _fcmToken = null;
        return;
      }
      await _firebaseMessaging.deleteToken();
      _fcmToken = null;
      debugPrint('✅ FCM token cleared');
    } catch (e) {
      debugPrint('❌ Error clearing FCM token: $e');
    }
  }

  /// Check if app was opened from a terminated state via notification
  /// Call this after the navigator is ready (e.g., after login/auth check)
  Future<void> checkInitialMessage() async {
    if (!_firebaseReady) return;
    try {
      // First check FCM initial message
      RemoteMessage? initialMessage = await _firebaseMessaging
          .getInitialMessage();
      if (initialMessage != null) {
        debugPrint('🔔 App opened from terminated state via FCM notification');
        debugPrint(
          'Initial message notification: ${initialMessage.notification?.toMap()}',
        );
        debugPrint('Initial message data: ${initialMessage.data}');
        debugPrint('Data keys: ${initialMessage.data.keys.toList()}');
        debugPrint('Data values: ${initialMessage.data.values.toList()}');
        // Store as pending — don't navigate now because the auth flow
        // will pushReplacement(HomePage) which destroys any pushed route.
        // LobbyScreen will pick this up via _checkPendingNotification().
        _storePendingForLobby(initialMessage.data);
        return;
      }

      // Also check local notification launch details
      // This handles cases where background handler showed the notification
      final notificationAppLaunchDetails = await _localNotifications
          .getNotificationAppLaunchDetails();

      if (notificationAppLaunchDetails?.didNotificationLaunchApp ?? false) {
        debugPrint(
          '🔔 App opened from terminated state via LOCAL notification',
        );
        final response = notificationAppLaunchDetails?.notificationResponse;
        final payload = response?.payload;

        if (response != null && payload != null) {
          debugPrint('Local notification payload: $payload');

          // For quick-reply actions, send immediately and skip navigation.
          if (_isChatQuickReplyActionId(response.actionId)) {
            await _processNotificationResponse(response);
            return;
          }

          // Regular notification tap: store as pending until lobby is mounted.
          try {
            final data = jsonDecode(payload) as Map<String, dynamic>;

            // App opened by tapping "Install Now" on the ready-to-install
            // notification from a terminated state — launch the installer.
            if (data['type']?.toString() == 'app_update_ready') {
              await BackgroundUpdateService().requestInstall();
              return;
            }

            // Preserve app-update action semantics on cold start.
            // In particular, "update later" should not open the update prompt.
            if (_isAppUpdateType(data)) {
              final updateNowActionId = _readActionId(
                data,
                'action_update_now',
                'update_now',
              );
              final updateLaterActionId = _readActionId(
                data,
                'action_update_later',
                'update_later',
              );
              final normalizedAction = response.actionId?.trim();

              if (normalizedAction == updateLaterActionId) {
                await VersionService().deferUpdatePayload(data);
                await _localNotifications.cancel(_appUpdateNotificationId);
                return;
              }

              if (normalizedAction == null ||
                  normalizedAction.isEmpty ||
                  normalizedAction == updateNowActionId) {
                await _localNotifications.cancel(_appUpdateNotificationId);
              }
            }

            _storePendingForLobby(data);
          } catch (e) {
            debugPrint('Error parsing notification payload: $e');
          }
          return;
        }
      }

      // Check native Android notification payload — this handles taps on
      // notifications created by the native ChatFirebaseMessagingReceiver
      // (which bypasses FlutterLocalNotificationsPlugin entirely).
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          final nativePayload = await _nativeNotificationPayloadChannel
              .invokeMethod<String?>('consumeInitialNotificationPayload');
          if (nativePayload != null) {
            debugPrint('🔔 App opened from native Android chat notification');
            final data = jsonDecode(nativePayload) as Map<String, dynamic>;
            _storePendingForLobby(data);
            return;
          }
        } catch (e) {
          debugPrint('Error checking native notification payload: $e');
        }
      }

      debugPrint('ℹ️ No initial message found');
    } catch (e) {
      debugPrint('❌ Error checking initial message: $e');
    }
  }

  /// Store notification data as pending for LobbyScreen to process
  /// This is used when the app launches from terminated state — we can't
  /// navigate immediately because the auth flow will pushReplacement and
  /// destroy any route we push now.
  void _storePendingForLobby(Map<String, dynamic> data) {
    debugPrint(
      '📌 Storing terminated-state notification as pending for LobbyScreen',
    );
    NotificationHandler.storePendingNotification(data);
  }
}
