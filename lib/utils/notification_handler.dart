import 'dart:async';

import 'package:flutter/material.dart';
import '../screens/chat_screen.dart' show ChatScreen;
import '../screens/connected_call_screen.dart';
import '../screens/group_chat_screen.dart';
import '../widgets/incoming_call_setup_modal.dart';
import '../models/group.dart';
import '../models/lobby_user.dart';
import '../services/active_chat_service.dart';
import '../services/call_service.dart';
import '../services/group_service.dart';
import '../services/socket_service.dart';
import '../services/presence_service.dart';
import '../services/version_service.dart';

/// Helper class to handle notification taps and navigate to appropriate screens
class NotificationHandler {
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  // Store pending navigation data for when app opens from terminated state
  static Map<String, dynamic>? _pendingNotificationData;

  // Callback for incoming call from FCM (set by lobby/chat screens)
  static Function(Map<String, dynamic>)? onIncomingCallFromFCM;

  /// Check if there's a pending notification waiting for lobby
  static bool get hasPendingNavigation => _pendingNotificationData != null;

  /// Open the 1-on-1 chat with [userId]. Public entry point used to answer a
  /// deferred incoming call by navigating into the caller's conversation (the
  /// chat screen then surfaces the deferred incoming-call modal).
  static void openChatWithUser(int userId, String userName) {
    _navigateToChat(userId, userName);
  }

  /// Get and clear pending notification data
  static Map<String, dynamic>? getPendingNotificationData() {
    debugPrint('🔍 getPendingNotificationData called');
    debugPrint('🔍 Current pending data: $_pendingNotificationData');
    final data = _pendingNotificationData;
    _pendingNotificationData = null;
    return data;
  }

  /// Handle notification tap and navigate to the appropriate screen
  static void handleNotificationTap(
    Map<String, dynamic> data, {
    bool fromPending = false,
  }) {
    debugPrint(
      '🔔 NotificationHandler.handleNotificationTap called with: $data (fromPending: $fromPending)',
    );
    debugPrint('🔔 Data type: ${data['type']}');
    debugPrint('🔔 Sender ID: ${data['sender_id']}');
    debugPrint('🔔 Sender Name: ${data['sender_name']}');
    debugPrint('🔔 All keys: ${data.keys.toList()}');

    final type = data['type']?.toString();
    final senderId = _parseInt(data['sender_id']);
    final senderName = data['sender_name']?.toString();
    final groupId = _parseInt(data['group_id']);
    final groupName = data['group_name']?.toString();

    debugPrint(
      '✅ Parsed senderId: $senderId, senderName: $senderName, groupId: $groupId, groupName: $groupName, type: $type',
    );

    // Check if navigator is ready
    if (navigatorKey.currentState == null) {
      debugPrint('⏳ Navigator not ready, storing pending notification');
      _pendingNotificationData = data;
      return;
    }

    debugPrint(
      '✅ Navigator ready, proceeding with notification handling (fromPending: $fromPending)',
    );

    switch (type) {
      case 'app_update':
        _handleAppUpdateNotification(data);
        break;
      case 'message':
        if (groupId != null) {
          _navigateToGroupChat(groupId, groupName ?? 'Group');
        } else if (senderId != null) {
          _navigateToChat(senderId, senderName ?? 'User');
        } else {
          debugPrint(
            '❌ Invalid message notification data - missing sender_id/group_id: $data',
          );
        }
        break;
      case 'doorbell':
        if (groupId != null) {
          _navigateToGroupChat(groupId, groupName ?? 'Group');
        } else if (senderId != null) {
          _navigateToChat(senderId, senderName ?? 'User');
        } else {
          debugPrint(
            '❌ Invalid doorbell notification data - missing sender_id/group_id: $data',
          );
        }
        break;
      case 'call':
        if (senderId == null) {
          debugPrint('❌ Invalid sender_id for call notification: $data');
          return;
        }
        debugPrint('📞 FCM notification tapped - handling incoming call');
        _handleIncomingCallNotification(data);
        break;
      case 'color_change':
        if (groupId != null) {
          _navigateToGroupChat(groupId, groupName ?? 'Group');
        } else if (senderId != null) {
          _navigateToChat(senderId, senderName ?? 'User');
        } else {
          debugPrint(
            '❌ Invalid color_change notification data - missing sender_id/group_id: $data',
          );
        }
        break;
      default:
        debugPrint('⚠️ Unknown notification type: $type');
        if (groupId != null) {
          _navigateToGroupChat(groupId, groupName ?? 'Group');
        } else if (senderId != null) {
          _navigateToChat(senderId, senderName ?? 'User');
        } else {
          debugPrint(
            '❌ Unknown notification type but no routing identifiers found: $data',
          );
        }
    }
  }

  static void _handleAppUpdateNotification(Map<String, dynamic> data) {
    final context = navigatorKey.currentContext;
    if (context == null) {
      debugPrint('⏳ No context for app update tap, storing pending data');
      _pendingNotificationData = data;
      return;
    }

    unawaited(VersionService().promptUpdateFromPush(context, data));
  }

  /// Handle incoming call notification tap - show incoming call modal
  static Future<void> _handleIncomingCallNotification(
    Map<String, dynamic> data,
  ) async {
    debugPrint('📞 Handling incoming call notification: $data');

    // Guard against duplicate call setups (same as lobby/chat screens)
    // This prevents conflicts when both socket events and FCM notifications arrive
    if (PresenceService().isHandlingIncomingCall) {
      debugPrint(
        '⚠️ Already handling an incoming call, ignoring FCM duplicate',
      );
      return;
    }
    PresenceService().isHandlingIncomingCall = true;

    final senderId = int.tryParse(data['sender_id']?.toString() ?? '');
    final senderName = data['sender_name'] as String? ?? 'Unknown';
    final callType = data['call_type'] as String? ?? 'video';
    final callId = int.tryParse(data['call_id']?.toString() ?? '');
    final callRoomId = data['call_room_id'] as String?;

    if (senderId == null) {
      debugPrint('❌ Invalid sender_id for call notification');
      PresenceService().isHandlingIncomingCall = false;
      return;
    }

    final context = navigatorKey.currentContext;
    if (context == null) {
      debugPrint('❌ No context available for showing call modal');
      PresenceService().isHandlingIncomingCall = false;
      return;
    }

    debugPrint('✅ Context available, proceeding with call setup');
    debugPrint(
      '📞 Call details: senderId=$senderId, senderName=$senderName, callType=$callType, callId=$callId, callRoomId=$callRoomId',
    );

    // Initialize call service
    final callService = CallService();
    await callService.initialize();
    debugPrint('✅ Call service initialized');

    // Set up socket service and start signal buffering BEFORE handling incoming call
    final socketService = SocketService();
    socketService.startSignalBuffering();
    debugPrint('📡 Started signal buffering for FCM call');

    // Set up socket signal handler
    socketService.onSignal = (signalData) {
      debugPrint('📡 Signal received for FCM call: $signalData');
      callService.handleSignal(signalData);
    };

    // For FCM notifications, request pending offer since the original offer
    // may have been sent while the app was in background
    if (callRoomId != null) {
      debugPrint('📞 Requesting pending offer for FCM call: $callRoomId');
      // Add a small delay to ensure socket connection is stable
      Future.delayed(const Duration(milliseconds: 500), () {
        socketService.emit('request_pending_offer', {'room': callRoomId});
        debugPrint('📞 Pending offer request sent for room: $callRoomId');
      });

      // Also request a fresh offer as backup
      Future.delayed(const Duration(milliseconds: 800), () {
        debugPrint('📡 Requesting fresh WebRTC offer for FCM call (backup)');
        socketService.emit('request_call_offer', {
          'call_room_id': callRoomId,
          'caller_id': senderId,
        });
      });
    }

    // Create call data for the call service
    final callData = {
      'id': callId ?? DateTime.now().millisecondsSinceEpoch,
      'call_room_id':
          callRoomId ??
          '${senderId}_call_${DateTime.now().millisecondsSinceEpoch}',
      'call_type': callType,
      'caller_id': senderId,
      'caller': {
        'id': senderId,
        'username': senderName,
        'full_name': senderName,
      },
    };
    debugPrint('📞 Created call data: $callData');
    callService.handleIncomingCall(callData);

    // Use addListener with unique key for proper event handling
    const listenerKey = 'fcm_call_handler';
    socketService.addListener('callEnded', listenerKey, (
      Map<String, dynamic> endData,
    ) {
      debugPrint('📴 Call ended by remote user (FCM handler)');
      callService.handleCallEnded();
    });

    socketService.addListener('callDeclined', listenerKey, (
      Map<String, dynamic> declineData,
    ) {
      debugPrint('❌ Call declined (FCM handler)');
      callService.handleCallDeclined();
    });

    // Show incoming call setup modal
    debugPrint('📞 Attempting to show IncomingCallSetupModal');
    navigatorKey.currentState
        ?.push(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (context) => IncomingCallSetupModal(
              callerName: senderName,
              callerId: senderId,
              callType: callType,
              callService: callService,
              onDecline: () {
                debugPrint('📞 Call declined by user from FCM notification');
                // Clean up listeners
                socketService.removeListener('callEnded', listenerKey);
                socketService.removeListener('callDeclined', listenerKey);
                // Reset the handling flag
                PresenceService().isHandlingIncomingCall = false;

                // Navigate to chat with the caller when call is declined
                // This provides better UX - user can see the chat context
                debugPrint('📱 Navigating to chat with caller after decline');
                _navigateToChat(senderId, senderName);
              },
            ),
          ),
        )
        .then((result) {
          debugPrint('📞 IncomingCallSetupModal closed with result: $result');
          // Clean up listeners when modal closes
          socketService.removeListener('callEnded', listenerKey);
          socketService.removeListener('callDeclined', listenerKey);
          // Reset the handling flag
          PresenceService().isHandlingIncomingCall = false;

          if (result is Map &&
              (result['result'] == 'accepted' ||
                  result['result'] == 'connected')) {
            final localStream = result['localStream'];
            debugPrint('📞 Call accepted, showing ConnectedCallScreen');
            navigatorKey.currentState?.push(
              MaterialPageRoute(
                fullscreenDialog: true,
                builder: (context) => ConnectedCallScreen(
                  remoteName: senderName,
                  callType: callType,
                  callService: callService,
                  localStream: localStream ?? callService.localStream,
                ),
              ),
            );
          } else {
            // Call was declined or modal closed without accepting
            // Navigate to chat with the caller for better UX
            debugPrint(
              '📱 Call declined/dismissed, navigating to chat with caller',
            );
            _navigateToChat(senderId, senderName);
          }
        });
  }

  /// Store notification data for later processing
  /// Used when the app is starting from terminated state and the
  /// navigation stack isn't ready yet (LobbyScreen hasn't mounted)
  static void storePendingNotification(Map<String, dynamic> data) {
    debugPrint('📌 Storing pending notification for later processing: $data');
    _pendingNotificationData = data;
  }

  /// Check and process any pending notification navigation
  /// Call this after the app is fully initialized
  static void processPendingNotification() {
    if (_pendingNotificationData != null) {
      debugPrint(
        '🔔 Processing pending notification: $_pendingNotificationData',
      );
      final data = _pendingNotificationData!;
      _pendingNotificationData = null;

      // Delay slightly to ensure navigation stack is ready
      Future.delayed(const Duration(milliseconds: 500), () {
        handleNotificationTap(data, fromPending: true);
      });
    }
  }

  static int? _parseInt(dynamic value) {
    return int.tryParse(value?.toString() ?? '');
  }

  /// Leaves any currently active room before opening the target one.
  /// Returns true when navigation should replace the current top route.
  static bool _prepareRoomTransition({
    int? targetUserId,
    int? targetGroupId,
  }) {
    final activeChatService = ActiveChatService();
    final socketService = SocketService();

    final activeUserId = activeChatService.activeUserId;
    final activeGroupId = activeChatService.activeGroupId;

    final shouldLeaveUserRoom =
        activeUserId != null && activeUserId != targetUserId;
    final shouldLeaveGroupRoom =
        activeGroupId != null && activeGroupId != targetGroupId;

    if (shouldLeaveUserRoom) {
      debugPrint('🔄 Leaving active direct chat room: $activeUserId');
      socketService.leaveChat(activeUserId);
    }

    if (shouldLeaveGroupRoom) {
      debugPrint('🔄 Leaving active group chat room: $activeGroupId');
      socketService.leaveGroupChat(activeGroupId);
    }

    if (shouldLeaveUserRoom || shouldLeaveGroupRoom) {
      activeChatService.clearActiveChat();
    }

    return shouldLeaveUserRoom || shouldLeaveGroupRoom;
  }

  static void _pushRoute({
    required WidgetBuilder builder,
    required bool replaceCurrentRoute,
  }) {
    final navigatorState = navigatorKey.currentState;
    if (navigatorState == null) {
      debugPrint('❌ Navigator not ready while trying to push route');
      return;
    }

    final route = MaterialPageRoute(builder: builder);
    if (replaceCurrentRoute && navigatorState.canPop()) {
      navigatorState.pushReplacement(route);
      return;
    }

    navigatorState.push(route);
  }

  /// Navigate to group chat screen with the specified group id.
  static Future<void> _navigateToGroupChat(int groupId, String groupName) async {
    debugPrint('🚀 Navigating to group chat: $groupId ($groupName)');

    if (navigatorKey.currentState == null) {
      debugPrint('❌ Navigator unavailable, storing group notification pending');
      _pendingNotificationData = {
        'type': 'message',
        'group_id': groupId.toString(),
        'group_name': groupName,
      };
      return;
    }

    final replaceCurrentRoute = _prepareRoomTransition(targetGroupId: groupId);

    Group targetGroup;
    try {
      final groupDetails = await GroupService.getGroupDetails(groupId);
      final group = groupDetails['group'];
      if (group is! Group) {
        throw Exception('Invalid group payload');
      }
      targetGroup = group;
    } catch (e) {
      debugPrint('⚠️ Failed to fetch group details for $groupId: $e');
      targetGroup = Group(
        id: groupId,
        name: groupName,
        createdBy: 0,
        memberCount: 0,
        isActive: true,
        createdAt: DateTime.now().toIso8601String(),
        myRole: 'member',
      );
    }

    _pushRoute(
      builder: (context) => GroupChatScreen(group: targetGroup),
      replaceCurrentRoute: replaceCurrentRoute,
    );
  }

  /// Navigate to chat screen with the specified user
  static void _navigateToChat(int userId, String userName) {
    debugPrint('🚀 Navigating to chat with user: $userId ($userName)');

    // Check if navigator is ready
    if (navigatorKey.currentState == null) {
      debugPrint('❌ No context available, storing as pending notification');
      _pendingNotificationData = {
        'type': 'message',
        'sender_id': userId.toString(),
        'sender_name': userName,
      };
      return;
    }

    final replaceCurrentRoute = _prepareRoomTransition(targetUserId: userId);

    // Create a LobbyUser object with minimal information
    final user = LobbyUser(
      id: userId,
      username: userName,
      email: '',
      firstName: userName.split(' ').first,
      lastName: userName.split(' ').length > 1 ? userName.split(' ').last : '',
      fullName: userName,
      avatarUrl: null,
      bio: null,
      status: 'online',
      statusMessage: null,
      lastSeen: DateTime.now().toIso8601String(),
      isOnline: true,
      isAdmin: false,
      timezone: 'UTC',
      unreadCount: 0,
      isContact: false,
      isAdminUser: false,
    );

    _pushRoute(
      builder: (context) => ChatScreen(otherUser: user),
      replaceCurrentRoute: replaceCurrentRoute,
    );
  }
}
