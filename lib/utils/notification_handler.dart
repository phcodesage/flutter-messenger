import 'dart:async';

import 'package:flutter/material.dart';
import '../screens/chat_screen.dart' show ChatScreen;
import '../screens/group_chat_screen.dart';
import '../models/group.dart';
import '../models/lobby_user.dart';
import '../services/active_chat_service.dart';
import '../services/group_service.dart';
import '../services/socket_service.dart';
import '../services/pending_incoming_call_service.dart';
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
  /// Wait for the socket to (re)connect after returning from background, then
  /// join the call room and request the pending offer + buffered ICE. Answering
  /// from a notification tap fails if we fire these before the socket is up.
  static Future<void> _requestPendingOfferWhenConnected(
    SocketService socketService,
    String callRoomId,
    int senderId,
  ) async {
    const stepMs = 200;
    const maxWaitMs = 10000;
    var waited = 0;
    // Kick a reconnect in case the socket dropped while backgrounded.
    socketService.ensureConnected();
    while (!socketService.isConnected && waited < maxWaitMs) {
      await Future.delayed(const Duration(milliseconds: stepMs));
      waited += stepMs;
      if (waited % 1000 == 0) socketService.ensureConnected();
    }
    if (!socketService.isConnected) {
      debugPrint(
        '❌ Socket still not connected after ${waited}ms — cannot fetch pending offer',
      );
      return;
    }
    debugPrint(
      '📞 Socket connected after ${waited}ms — joining room + requesting pending offer for $callRoomId',
    );
    // Join the chat/call room so the caller's offer/ICE and our answer flow
    // through it (backend allows participants to join chat_<a>_<b>).
    socketService.emit('join_room', {'room': callRoomId});
    socketService.emit('request_pending_offer', {'room': callRoomId});
    // Backup: also request a fresh offer directly from the caller.
    socketService.emit('request_call_offer', {
      'call_room_id': callRoomId,
      'caller_id': senderId,
    });
  }

  static Future<void> _handleIncomingCallNotification(
    Map<String, dynamic> data,
  ) async {
    debugPrint('📞 Handling incoming call notification (tap): $data');

    final senderId = int.tryParse(data['sender_id']?.toString() ?? '');
    final senderName = data['sender_name'] as String? ?? 'Unknown';
    final callType = data['call_type'] as String? ?? 'video';
    final callId = int.tryParse(data['call_id']?.toString() ?? '');
    final callRoomId = data['call_room_id'] as String?;

    if (senderId == null) {
      debugPrint('❌ Invalid sender_id for call notification');
      return;
    }

    debugPrint(
      '📞 Call tap: senderId=$senderId, senderName=$senderName, callType=$callType, callId=$callId, callRoomId=$callRoomId',
    );

    // Stash the incoming call so the caller's chat screen surfaces a SINGLE
    // modal when we navigate into it. Previously this handler pushed its own
    // modal AND the chat screen's deferred re-surface pushed another → the
    // duplicate the user saw. Now the chat screen is the single owner.
    if (callRoomId != null && callRoomId.isNotEmpty) {
      PendingIncomingCallService().setPending({
        'id': callId ?? DateTime.now().millisecondsSinceEpoch,
        'call_room_id': callRoomId,
        'call_type': callType,
        'caller_id': senderId,
        'caller': {
          'id': senderId,
          'username': senderName,
          'full_name': senderName,
        },
      });
    }

    // Open the caller's chat FIRST: it joins the call room (via join_chat) and
    // surfaces the single incoming-call modal through the deferred re-surface
    // path in ChatScreen.initState.
    openChatWithUser(senderId, senderName);

    // Ensure the socket is back up (we're returning from background) and pull
    // the pending offer + buffered ICE so answering actually connects. The chat
    // screen also requests these; duplicate requests are de-duped.
    if (callRoomId != null && callRoomId.isNotEmpty) {
      unawaited(
        _requestPendingOfferWhenConnected(SocketService(), callRoomId, senderId),
      );
    }
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
