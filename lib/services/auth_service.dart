import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../models/auth_response.dart';
import '../models/user.dart';
import '../utils/notification_handler.dart';
import 'storage_service.dart';
import 'socket_service.dart';
import 'message_cache_sync_service.dart';
import 'presence_service.dart';
import 'fcm_service.dart';
import 'firebase_messaging_service.dart';
import 'media_preload_service.dart';

/// Service for handling authentication API calls
class AuthService {
  /// Safely extract error message from a response body (handles both JSON and plain text)
  static String _extractErrorMessage(String body, String fallback) {
    try {
      final error = jsonDecode(body);
      return error['error'] ?? fallback;
    } on FormatException {
      // Server returned non-JSON (e.g. plain text error)
      return body.isNotEmpty ? body : fallback;
    }
  }

  /// Register a new user
  static Future<AuthResponse> register({
    required String username,
    required String email,
    required String password,
    required String firstName,
    String? lastName,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse(ApiConfig.registerUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'username': username,
              'email': email,
              'password': password,
              'first_name': firstName,
              if (lastName != null && lastName.isNotEmpty)
                'last_name': lastName,
            }),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 201) {
        final authResponse = AuthResponse.fromJson(jsonDecode(response.body));

        // Save token and user info
        await StorageService.saveToken(authResponse.token);
        await StorageService.saveUserId(authResponse.user.id);
        await StorageService.saveUsername(authResponse.user.username);
        await StorageService.saveIsAdmin(authResponse.user.isAdmin);

        // Initialize Socket.IO connection
        SocketService().initialize(authResponse.token, authResponse.user.id);

        // Keep every room's cached tail current for the whole session, not just
        // while its screen happens to be mounted.
        MessageCacheSyncService().start(authResponse.user.id);

        // Start heartbeat to maintain online status
        PresenceService().startHeartbeat();

        // Set status to online
        await PresenceService.updateStatus('online');

        // Send FCM token to backend for push notifications
        final fcmToken = await FirebaseMessagingService.instance
            .getSavedFCMToken();
        if (fcmToken != null) {
          await FCMService.updateFCMToken(fcmToken);
        }

        // Process any pending notification after registration
        Future.delayed(const Duration(milliseconds: 500), () {
          NotificationHandler.processPendingNotification();
        });

        // Check if app was opened from terminated state via notification
        // Use longer delay to ensure navigation is complete
        Future.delayed(const Duration(milliseconds: 1000), () {
          FirebaseMessagingService.instance.checkInitialMessage();
        });

        // Hydrate offline caches in the background.
        unawaited(MediaPreloadService.instance.start());

        return authResponse;
      } else {
        throw Exception(
          _extractErrorMessage(response.body, 'Registration failed'),
        );
      }
    } catch (e) {
      debugPrint('Registration error: $e');
      rethrow;
    }
  }

  /// Login user
  static Future<AuthResponse> login({
    required String username,
    required String password,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse(ApiConfig.loginUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': username, 'password': password}),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final authResponse = AuthResponse.fromJson(jsonDecode(response.body));

        // Save token and user info
        await StorageService.saveToken(authResponse.token);
        await StorageService.saveUserId(authResponse.user.id);
        await StorageService.saveUsername(authResponse.user.username);
        await StorageService.saveIsAdmin(authResponse.user.isAdmin);

        // Initialize Socket.IO connection
        SocketService().initialize(authResponse.token, authResponse.user.id);

        // Keep every room's cached tail current for the whole session, not just
        // while its screen happens to be mounted.
        MessageCacheSyncService().start(authResponse.user.id);

        // Start heartbeat to maintain online status
        PresenceService().startHeartbeat();

        // Set status to online
        await PresenceService.updateStatus('online');

        // Send FCM token to backend for push notifications
        final fcmToken = await FirebaseMessagingService.instance
            .getSavedFCMToken();
        if (fcmToken != null) {
          await FCMService.updateFCMToken(fcmToken);
        }

        // Process any pending notification after login
        Future.delayed(const Duration(milliseconds: 500), () {
          NotificationHandler.processPendingNotification();
        });

        // Check if app was opened from terminated state via notification
        // Use longer delay to ensure navigation is complete
        Future.delayed(const Duration(milliseconds: 1000), () {
          FirebaseMessagingService.instance.checkInitialMessage();
        });

        // Hydrate offline caches in the background.
        unawaited(MediaPreloadService.instance.start());

        return authResponse;
      } else {
        throw Exception(_extractErrorMessage(response.body, 'Login failed'));
      }
    } catch (e) {
      debugPrint('Login error: $e');
      rethrow;
    }
  }

  /// Logout user
  static Future<void> logout() async {
    try {
      // Set status to offline before logout
      await PresenceService.updateStatus('offline');

      // Stop heartbeat
      PresenceService().stopHeartbeat();

      // Disconnect Socket.IO
      SocketService().disconnect();

      // Stop mirroring messages into the cache for the account we just left.
      MessageCacheSyncService().stop();

      // Stop the offline preload service so it doesn't keep running
      // against the now-invalid token.
      await MediaPreloadService.instance.stop();

      // Remove FCM token from backend to stop receiving push notifications
      await FCMService.removeFCMToken();

      final token = await StorageService.getToken();

      if (token != null) {
        await http
            .post(
              Uri.parse(ApiConfig.logoutUrl),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
            )
            .timeout(ApiConfig.connectionTimeout);
      }
    } catch (e) {
      debugPrint('Logout error: $e');
    } finally {
      // Clear local storage regardless of API call result
      await StorageService.clearAll();
    }
  }

  /// Get current user info
  static Future<User> getCurrentUser() async {
    try {
      final token = await StorageService.getToken();

      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http
          .get(
            Uri.parse(ApiConfig.meUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return User.fromJson(data['user']);
      } else {
        throw Exception(
          _extractErrorMessage(response.body, 'Failed to get user info'),
        );
      }
    } catch (e) {
      debugPrint('Get current user error: $e');
      rethrow;
    }
  }

  /// Re-fetch the current user from the server and update locally-cached flags
  /// (currently `is_admin`) so changes such as being granted/revoked admin take
  /// effect without requiring a re-login. The cached flag is otherwise only
  /// written at login/register, leaving long-lived sessions stale.
  ///
  /// Returns the fresh admin status, or `null` if the refresh failed
  /// (offline / expired token) so callers can keep the cached value.
  static Future<bool?> refreshCachedAdminStatus() async {
    try {
      final user = await getCurrentUser();
      await StorageService.saveIsAdmin(user.isAdmin);
      return user.isAdmin;
    } catch (e) {
      debugPrint('Admin status refresh failed: $e');
      return null;
    }
  }

  /// Request password reset
  static Future<String> forgotPassword({
    required String emailOrUsername,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse(ApiConfig.forgotPasswordUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email_or_username': emailOrUsername}),
          )
          .timeout(ApiConfig.forgotPasswordTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['message'] ?? 'Password reset link sent';
      } else {
        throw Exception(
          _extractErrorMessage(response.body, 'Failed to send reset link'),
        );
      }
    } on TimeoutException {
      throw Exception(
        'The reset request timed out. Please try again in a moment. '
        'If the email arrives later, you can still use the token to reset your password.',
      );
    } on http.ClientException {
      throw Exception(
        'Could not reach the server. Please check your internet connection and try again.',
      );
    } catch (e) {
      debugPrint('Forgot password error: $e');
      rethrow;
    }
  }

  /// Reset password with token
  static Future<String> resetPassword({
    required String token,
    required String newPassword,
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse(ApiConfig.resetPasswordUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'token': token, 'new_password': newPassword}),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['message'] ?? 'Password reset successful';
      } else {
        throw Exception(
          _extractErrorMessage(response.body, 'Failed to reset password'),
        );
      }
    } on TimeoutException {
      throw Exception('The reset request timed out. Please try again.');
    } on http.ClientException {
      throw Exception(
        'Could not reach the server. Please check your internet connection and try again.',
      );
    } catch (e) {
      debugPrint('Reset password error: $e');
      rethrow;
    }
  }
}
