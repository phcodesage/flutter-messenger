import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/message.dart';
import 'storage_service.dart';

/// Result of a forward operation.
class ForwardResult {
  final Map<int, bool> results;

  const ForwardResult({required this.results});

  factory ForwardResult.empty() => const ForwardResult(results: {});

  int get successCount => results.values.where((v) => v).length;
  int get failureCount => results.values.where((v) => !v).length;
  bool get allSucceeded => results.isNotEmpty && results.values.every((v) => v);
  bool get allFailed => results.isNotEmpty && results.values.every((v) => !v);
}

/// Service for forwarding messages to other DM contacts.
class ForwardService {
  /// In-memory cache of forward preferences — populated on prewarm so
  /// the forward picker renders instantly without a network round-trip.
  static Map<String, dynamic>? _cachedPreferences;

  /// Warm up the forward preferences cache in the background.
  /// Call this once on app startup (e.g. from _loadLobby).
  static Future<void> prewarm() async {
    try {
      _cachedPreferences = await getForwardPreferences();
    } catch (e) {
      debugPrint('[ForwardService] prewarm failed: $e');
    }
  }

  /// Returns the cached preferences synchronously if available, null otherwise.
  static Map<String, dynamic>? get cachedPreferences => _cachedPreferences;

  /// Invalidate the in-memory cache (e.g. after a star toggle).
  static void invalidateCache() => _cachedPreferences = null;

  /// Forward a message to one or more DM recipients.
  static Future<ForwardResult> forwardToUsers({
    required Message message,
    required List<int> recipientIds,
  }) async {
    if (recipientIds.isEmpty) return ForwardResult.empty();

    try {
      final token = await StorageService.getToken();
      if (token == null) {
        return ForwardResult(
          results: {for (final id in recipientIds) id: false},
        );
      }

      final payload = _buildPayload(message);

      if (recipientIds.length == 1) {
        final response = await http
            .post(
              Uri.parse(ApiConfig.sendMessageUrl),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode({
                'recipient_id': recipientIds.first,
                ...payload,
              }),
            )
            .timeout(const Duration(seconds: 10));

        final success =
            response.statusCode == 200 || response.statusCode == 201;
        if (success) {
          await incrementForwardFrequency(recipientIds.first);
        }
        return ForwardResult(results: {recipientIds.first: success});
      } else {
        final response = await http
            .post(
              Uri.parse(ApiConfig.sendManyMessagesUrl),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: jsonEncode({
                'recipient_ids': recipientIds,
                ...payload,
              }),
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode == 200 || response.statusCode == 201) {
          for (final id in recipientIds) {
            await incrementForwardFrequency(id);
          }
          return ForwardResult(
            results: {for (final id in recipientIds) id: true},
          );
        }
        return ForwardResult(
          results: {for (final id in recipientIds) id: false},
        );
      }
    } catch (e) {
      debugPrint('Forward to users error: $e');
      return ForwardResult(
        results: {for (final id in recipientIds) id: false},
      );
    }
  }

  /// Build the request payload for forwarding.
  /// For text messages: sends content + message_type.
  /// For media/file messages: also includes file_url, file_name, file_size, file_type
  /// so the backend creates a proper file message without re-upload.
  static Map<String, dynamic> _buildPayload(Message message) {
    final isMedia = message.messageType != 'text' &&
        message.messageType != 'system' &&
        message.fileUrl != null;

    if (isMedia) {
      return {
        'content': (message.caption != null && message.caption!.isNotEmpty)
            ? message.caption
            : (message.fileName ?? message.content),
        'message_type': message.messageType,
        'file_url': message.fileUrl,
        if (message.fileName != null) 'file_name': message.fileName,
        if (message.fileSize != null) 'file_size': message.fileSize,
        if (message.fileType != null) 'file_type': message.fileType,
      };
    }

    return {
      'content': message.content,
      'message_type': 'text',
    };
  }

  /// Get all forwarding preferences (starred user IDs + forward frequencies).
  /// Falls back to local storage if API call fails or user is offline.
  static Future<Map<String, dynamic>> getForwardPreferences() async {
    try {
      final token = await StorageService.getToken();
      final currentUserId = await StorageService.getUserId();
      if (token == null || currentUserId == null) {
        return {
          'starred': <int>{},
          'frequencies': <int, int>{},
        };
      }

      final response = await http.get(
        Uri.parse(ApiConfig.forwardPreferencesUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final prefs = data['preferences'] as List? ?? [];
        final starred = <int>{};
        final frequencies = <int, int>{};
        
        for (final p in prefs) {
          final contactId = p['contact_id'] as int;
          if (p['is_starred'] as bool? ?? false) {
            starred.add(contactId);
          }
          final count = p['forward_count'] as int? ?? 0;
          if (count > 0) {
            frequencies[contactId] = count;
          }
        }
        
        // Cache to local storage
        await StorageService.saveStarredUserIds(currentUserId, starred);
        await StorageService.saveForwardFrequencies(currentUserId, frequencies);
        
        return {
          'starred': starred,
          'frequencies': frequencies,
        };
      }
    } catch (e) {
      debugPrint('Error fetching forward preferences from database: $e');
    }

    // Offline fallback: load from local storage
    final currentUserId = await StorageService.getUserId();
    if (currentUserId != null) {
      final starred = await StorageService.getStarredUserIds(currentUserId);
      final frequencies = await StorageService.getForwardFrequencies(currentUserId);
      return {
        'starred': starred,
        'frequencies': frequencies,
      };
    }

    return {
      'starred': <int>{},
      'frequencies': <int, int>{},
    };
  }

  /// Toggle starred state of a user in the database and local storage.
  static Future<bool> toggleStarredUserId(int userId) async {
    final currentUserId = await StorageService.getUserId();
    if (currentUserId == null) return false;
    
    // Optimistically toggle locally first
    final isStarredNow = await StorageService.toggleStarredUserId(currentUserId, userId);
    // Invalidate in-memory cache so the picker reloads fresh state next open
    invalidateCache();
    
    try {
      final token = await StorageService.getToken();
      if (token != null) {
        final response = await http.post(
          Uri.parse(ApiConfig.forwardToggleStarUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'contact_id': userId}),
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final serverStarred = data['is_starred'] as bool? ?? isStarredNow;
          
          // Re-sync local storage to match server reality
          final currentStarred = await StorageService.getStarredUserIds(currentUserId);
          if (serverStarred) {
            currentStarred.add(userId);
          } else {
            currentStarred.remove(userId);
          }
          await StorageService.saveStarredUserIds(currentUserId, currentStarred);
          return serverStarred;
        }
      }
    } catch (e) {
      debugPrint('Error toggling starred state on database: $e');
    }

    return isStarredNow;
  }

  /// Increment forwarding frequency for a contact in the database and local storage.
  static Future<void> incrementForwardFrequency(int userId) async {
    final currentUserId = await StorageService.getUserId();
    if (currentUserId == null) return;

    // Optimistically update locally first
    await StorageService.incrementForwardFrequency(currentUserId, userId);

    try {
      final token = await StorageService.getToken();
      if (token != null) {
        final response = await http.post(
          Uri.parse(ApiConfig.forwardIncrementFrequencyUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'contact_id': userId}),
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final serverCount = data['forward_count'] as int? ?? 1;
          
          // Re-sync local storage
          final frequencies = await StorageService.getForwardFrequencies(currentUserId);
          frequencies[userId] = serverCount;
          await StorageService.saveForwardFrequencies(currentUserId, frequencies);
        }
      }
    } catch (e) {
      debugPrint('Error incrementing forward frequency in database: $e');
    }
  }
}
