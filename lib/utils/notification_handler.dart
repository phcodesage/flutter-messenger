import 'package:flutter/material.dart';
import '../screens/chat_screen.dart';
import '../models/lobby_user.dart';

/// Helper class to handle notification taps and navigate to appropriate screens
class NotificationHandler {
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// Handle notification tap and navigate to the appropriate screen
  static void handleNotificationTap(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    final senderId = int.tryParse(data['sender_id'] ?? '');
    final senderName = data['sender_name'] as String?;

    if (senderId == null) {
      debugPrint('❌ Invalid sender_id in notification data');
      return;
    }

    switch (type) {
      case 'message':
        _navigateToChat(senderId, senderName ?? 'User');
        break;
      case 'doorbell':
        _navigateToChat(senderId, senderName ?? 'User');
        break;
      case 'call':
        // TODO: Navigate to call screen when implemented
        _navigateToChat(senderId, senderName ?? 'User');
        break;
      case 'color_change':
        _navigateToChat(senderId, senderName ?? 'User');
        break;
      default:
        debugPrint('⚠️ Unknown notification type: $type');
    }
  }

  /// Navigate to chat screen with the specified user
  static void _navigateToChat(int userId, String userName) {
    // Create a LobbyUser object with minimal information
    // In a real app, you might want to fetch full user details from the backend
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

    // Navigate to chat screen
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (context) => ChatScreen(otherUser: user),
      ),
    );
  }
}
