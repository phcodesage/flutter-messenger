import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import 'storage_service.dart';

/// Service for managing user presence and heartbeat
class PresenceService {
  Timer? _heartbeatTimer;
  bool _isActive = false;

  /// Start sending heartbeat every 30 seconds
  void startHeartbeat() {
    if (_isActive) return;
    
    _isActive = true;
    debugPrint('Starting heartbeat...');
    
    // Send initial heartbeat
    _sendHeartbeat();
    
    // Send heartbeat every 30 seconds
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _sendHeartbeat();
    });
  }

  /// Stop sending heartbeat
  void stopHeartbeat() {
    _isActive = false;
    debugPrint('Stopping heartbeat...');
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _sendHeartbeat() async {
    try {
      final token = await StorageService.getToken();
      if (token == null) return;

      await http.post(
        Uri.parse(ApiConfig.heartbeatUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 10));
      
      debugPrint('💓 Heartbeat sent');
    } catch (e) {
      debugPrint('Heartbeat error: $e');
    }
  }

  /// Update user status
  static Future<void> updateStatus(String status, {String? statusMessage}) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) return;

      await http.post(
        Uri.parse(ApiConfig.presenceStatusUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'status': status,
          if (statusMessage != null) 'status_message': statusMessage,
        }),
      ).timeout(ApiConfig.connectionTimeout);
      
      debugPrint('Status updated to: $status');
    } catch (e) {
      debugPrint('Update status error: $e');
    }
  }

  void dispose() {
    stopHeartbeat();
  }
}
