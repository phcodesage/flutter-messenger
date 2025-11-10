import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../models/auth_response.dart';
import '../models/user.dart';
import 'storage_service.dart';
import 'socket_service.dart';
import 'presence_service.dart';

/// Service for handling authentication API calls
class AuthService {
  /// Register a new user
  static Future<AuthResponse> register({
    required String username,
    required String email,
    required String password,
    required String firstName,
    String? lastName,
  }) async {
    try {
      final response = await http.post(
        Uri.parse(ApiConfig.registerUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'email': email,
          'password': password,
          'first_name': firstName,
          if (lastName != null && lastName.isNotEmpty) 'last_name': lastName,
        }),
      ).timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 201) {
        final authResponse = AuthResponse.fromJson(jsonDecode(response.body));
        
        // Save token and user info
        await StorageService.saveToken(authResponse.token);
        await StorageService.saveUserId(authResponse.user.id);
        await StorageService.saveUsername(authResponse.user.username);
        
        // Initialize Socket.IO connection
        SocketService().initialize(authResponse.token, authResponse.user.id);
        
        // Start heartbeat to maintain online status
        PresenceService().startHeartbeat();
        
        // Set status to online
        await PresenceService.updateStatus('online');
        
        return authResponse;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Registration failed');
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
      final response = await http.post(
        Uri.parse(ApiConfig.loginUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
        }),
      ).timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final authResponse = AuthResponse.fromJson(jsonDecode(response.body));
        
        // Save token and user info
        await StorageService.saveToken(authResponse.token);
        await StorageService.saveUserId(authResponse.user.id);
        await StorageService.saveUsername(authResponse.user.username);
        
        // Initialize Socket.IO connection
        SocketService().initialize(authResponse.token, authResponse.user.id);
        
        // Start heartbeat to maintain online status
        PresenceService().startHeartbeat();
        
        // Set status to online
        await PresenceService.updateStatus('online');
        
        return authResponse;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Login failed');
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
      
      final token = await StorageService.getToken();
      
      if (token != null) {
        await http.post(
          Uri.parse(ApiConfig.logoutUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        ).timeout(ApiConfig.connectionTimeout);
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

      final response = await http.get(
        Uri.parse(ApiConfig.meUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ).timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return User.fromJson(data['user']);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to get user info');
      }
    } catch (e) {
      debugPrint('Get current user error: $e');
      rethrow;
    }
  }

  /// Request password reset
  static Future<String> forgotPassword({
    required String emailOrUsername,
  }) async {
    try {
      final response = await http.post(
        Uri.parse(ApiConfig.forgotPasswordUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email_or_username': emailOrUsername,
        }),
      ).timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['message'] ?? 'Password reset link sent';
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to send reset link');
      }
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
      final response = await http.post(
        Uri.parse(ApiConfig.resetPasswordUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': token,
          'new_password': newPassword,
        }),
      ).timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['message'] ?? 'Password reset successful';
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to reset password');
      }
    } catch (e) {
      debugPrint('Reset password error: $e');
      rethrow;
    }
  }
}
