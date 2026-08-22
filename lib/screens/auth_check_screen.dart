import 'dart:async';

import 'package:flutter/material.dart';
import '../services/chat_cache_service.dart';
import '../services/storage_service.dart';
import '../services/socket_service.dart';
import '../services/message_cache_sync_service.dart';
import '../services/presence_service.dart';
import '../services/fcm_service.dart';
import '../services/firebase_messaging_service.dart';
import '../services/share_intent_service.dart';
import 'sign_in_page.dart';
import 'lobby_screen.dart';
import 'share_target_screen.dart';

/// Screen that checks authentication status on app start
class AuthCheckScreen extends StatefulWidget {
  const AuthCheckScreen({super.key});

  @override
  State<AuthCheckScreen> createState() => _AuthCheckScreenState();
}

class _AuthCheckScreenState extends State<AuthCheckScreen> {
  @override
  void initState() {
    super.initState();
    _checkAuthStatus();
  }

  Future<void> _checkAuthStatus() async {
    final isLoggedIn = await StorageService.isLoggedIn();

    if (!mounted) return;

    if (isLoggedIn) {
      // User has a saved token, restore session
      final token = await StorageService.getToken();
      final userId = await StorageService.getUserId();

      if (token != null && userId != null) {
        // Re-initialize Socket.IO connection
        SocketService().initialize(token, userId);

        // Keep every room's cached tail current for the whole session, not just
        // while its screen happens to be mounted.
        MessageCacheSyncService().start(userId);

        // Start heartbeat to maintain online status
        PresenceService().startHeartbeat();

        // Run these without blocking first navigation frame.
        unawaited(PresenceService.updateStatus('online'));
        unawaited(_restoreFcmTokenInBackground());
        unawaited(_syncInitialNotificationInBackground());

        final sharedItems = await ShareIntentService.instance
            .takePendingSharedItems();
        if (!mounted) return;

        if (sharedItems.isNotEmpty) {
          final directShareUserId =
              sharedItems
                  .map((item) => item.directShareUserId)
                  .firstWhere((id) => id != null, orElse: () => null) ??
              await ShareIntentService.instance.takePendingDirectShareUserId();
          final cachedUsers = await ChatCacheService.loadLobbyUsers(userId);
          if (!mounted) return;

          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => ShareTargetScreen(
                sharedItems: sharedItems,
                users: cachedUsers,
                openLobbyOnExit: true,
                directShareUserId: directShareUserId,
              ),
            ),
          );
          return;
        }

        Navigator.of(context).pushReplacementNamed(LobbyScreen.route);
      } else {
        // Token or userId is missing, go to sign in
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const SignInPage()),
          );
        }
      }
    } else {
      // No saved token, go to sign in
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const SignInPage()),
        );
      }
    }
  }

  Future<void> _restoreFcmTokenInBackground() async {
    try {
      final fcmToken = await FirebaseMessagingService.instance
          .getSavedFCMToken();
      if (fcmToken != null) {
        await FCMService.updateFCMToken(fcmToken);
      }
    } catch (e) {
      debugPrint('AuthCheck: FCM token restore skipped: $e');
    }
  }

  Future<void> _syncInitialNotificationInBackground() async {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await FirebaseMessagingService.instance.checkInitialMessage();
    } catch (e) {
      debugPrint('AuthCheck: initial notification sync skipped: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF1E3A8A), // blue-900
              Color(0xFF312E81), // indigo-900
            ],
          ),
        ),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.message_rounded, size: 80, color: Colors.white),
              SizedBox(height: 24),
              Text(
                'Flutter Messenger',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: 18),
            ],
          ),
        ),
      ),
    );
  }
}
