import 'package:http/http.dart' as http;
import 'dart:convert';
import 'storage_service.dart';
import 'package:flutter/foundation.dart';

/// Service for managing FCM token with backend
class FCMService {
  static const String baseUrl = 'https://dev.flask-meet.site';

  /// Send FCM token to backend
  static Future<bool> updateFCMToken(String fcmToken) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) {
        debugPrint('❌ No auth token found, cannot update FCM token');
        return false;
      }

      debugPrint('🔑 Auth token retrieved: ${token.substring(0, 20)}...');
      debugPrint('📱 Sending FCM token to: $baseUrl/api/user/fcm-token');

      final response = await http.post(
        Uri.parse('$baseUrl/api/user/fcm-token'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'fcm_token': fcmToken}),
      );

      if (response.statusCode == 200) {
        debugPrint('✅ FCM token sent to backend successfully');
        return true;
      } else {
        debugPrint('❌ Failed to send FCM token: ${response.statusCode}');
        debugPrint('Response: ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Error sending FCM token to backend: $e');
      return false;
    }
  }

  /// Remove FCM token from backend (on logout)
  static Future<bool> removeFCMToken() async {
    try {
      final token = await StorageService.getToken();
      if (token == null) {
        debugPrint('❌ No auth token found, cannot remove FCM token');
        return false;
      }

      final response = await http.delete(
        Uri.parse('$baseUrl/api/user/fcm-token'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        debugPrint('✅ FCM token removed from backend successfully');
        return true;
      } else {
        debugPrint('❌ Failed to remove FCM token: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Error removing FCM token from backend: $e');
      return false;
    }
  }
}
