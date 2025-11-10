import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../models/message.dart';
import 'storage_service.dart';

/// Service for handling message API calls
class MessageService {
  /// Get conversation messages with a specific user
  static Future<List<Message>> getConversationMessages({
    required int userId,
    int limit = 50,
    int? beforeId,
  }) async {
    try {
      final token = await StorageService.getToken();
      
      if (token == null) {
        throw Exception('No authentication token found');
      }

      final queryParams = {
        'limit': limit.toString(),
        if (beforeId != null) 'before_id': beforeId.toString(),
      };

      final uri = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.mobilePrefix}/messages/conversation/$userId')
          .replace(queryParameters: queryParams);

      final response = await http.get(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ).timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final messages = data['messages'] as List;
        return messages.map((json) => Message.fromJson(json)).toList();
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to load messages');
      }
    } catch (e) {
      debugPrint('Get conversation messages error: $e');
      rethrow;
    }
  }

  /// Send a message via REST API (alternative to Socket.IO)
  static Future<Message?> sendMessage({
    required int recipientId,
    required String content,
    String messageType = 'text',
    int? replyToId,
  }) async {
    try {
      final token = await StorageService.getToken();
      
      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http.post(
        Uri.parse(ApiConfig.sendMessageUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'recipient_id': recipientId,
          'content': content,
          'message_type': messageType,
          if (replyToId != null) 'reply_to_id': replyToId,
        }),
      ).timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return Message.fromJson(data['data']);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to send message');
      }
    } catch (e) {
      debugPrint('Send message error: $e');
      rethrow;
    }
  }

  /// Mark messages as read
  static Future<void> markAsRead({
    required int senderId,
    required int lastMessageId,
  }) async {
    try {
      final token = await StorageService.getToken();
      
      if (token == null) return;

      await http.post(
        Uri.parse('${ApiConfig.baseUrl}${ApiConfig.mobilePrefix}/messages/mark-read'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'sender_id': senderId,
          'last_message_id': lastMessageId,
        }),
      ).timeout(ApiConfig.connectionTimeout);
    } catch (e) {
      debugPrint('Mark as read error: $e');
    }
  }
}
