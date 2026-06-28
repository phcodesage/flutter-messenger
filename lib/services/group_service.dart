import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import '../config/api_config.dart';
import '../models/group.dart';
import 'storage_service.dart';
import 'auth_error_handler.dart';
import 'chat_cache_service.dart';

/// Service for group chat API calls
/// Enhanced with offline-first capabilities
class GroupService {
  /// Get all groups the current user belongs to
  static Future<List<Group>> getGroups() async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final url = ApiConfig.groupsUrl;
      debugPrint('🔍 Fetching groups from: $url');
      debugPrint('🔑 Token length: ${token.length}');

      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      debugPrint('📡 Groups API response status: ${response.statusCode}');
      debugPrint('📡 Groups API response body: ${response.body}');

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final groupsList = data['groups'] as List;
        debugPrint('✅ Loaded ${groupsList.length} groups');
        if (groupsList.isNotEmpty) {
          debugPrint('📋 First group: ${groupsList[0]}');
        }
        return groupsList.map((json) => Group.fromJson(json)).toList();
      } else {
        debugPrint(
          '❌ Failed to load groups: ${response.statusCode} - ${response.body}',
        );
        throw Exception('Failed to load groups: ${response.body}');
      }
    } catch (e) {
      debugPrint('❌ Get groups error: $e');
      rethrow;
    }
  }

  /// Create a new group
  static Future<Group> createGroup({
    required String name,
    String? description,
    required List<int> memberIds,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final response = await http
          .post(
            Uri.parse(ApiConfig.groupsUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'name': name,
              if (description != null && description.isNotEmpty)
                'description': description,
              'member_ids': memberIds,
            }),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        debugPrint('📡 Create group response: $data');

        // Handle both response formats: {data: {...}} or direct group object
        final groupData = data['data'] ?? data;
        return Group.fromJson(groupData as Map<String, dynamic>);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to create group');
      }
    } catch (e) {
      debugPrint('Create group error: $e');
      rethrow;
    }
  }

  /// Get group details with members
  static Future<Map<String, dynamic>> getGroupDetails(int groupId) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final response = await http
          .get(
            Uri.parse(ApiConfig.getGroupUrl(groupId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final groupData = data['group'];
        return {
          'group': Group.fromJson(groupData),
          'members': (groupData['members'] as List)
              .map((json) => GroupMember.fromJson(json))
              .toList(),
        };
      } else {
        throw Exception('Failed to load group details: ${response.body}');
      }
    } catch (e) {
      debugPrint('Get group details error: $e');
      rethrow;
    }
  }

  /// Edit group (admin only)
  static Future<void> editGroup({
    required int groupId,
    String? name,
    String? description,
    String? avatarUrl,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final body = <String, dynamic>{};
      if (name != null) body['name'] = name;
      if (description != null) body['description'] = description;
      if (avatarUrl != null) body['avatar_url'] = avatarUrl;

      final response = await http
          .put(
            Uri.parse(ApiConfig.getGroupUrl(groupId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(body),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode != 200) {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to edit group');
      }
    } catch (e) {
      debugPrint('Edit group error: $e');
      rethrow;
    }
  }

  /// Add members to group
  static Future<void> addMembers({
    required int groupId,
    required List<int> userIds,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final response = await http
          .post(
            Uri.parse(ApiConfig.getGroupMembersUrl(groupId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'user_ids': userIds}),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode != 200) {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to add members');
      }
    } catch (e) {
      debugPrint('Add members error: $e');
      rethrow;
    }
  }

  /// Remove member from group (admin only) or leave group (if removing self)
  static Future<void> removeMember({
    required int groupId,
    required int userId,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final response = await http
          .delete(
            Uri.parse(ApiConfig.getGroupMemberUrl(groupId, userId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode != 200) {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to remove member');
      }
    } catch (e) {
      debugPrint('Remove member error: $e');
      rethrow;
    }
  }

  /// Leave group
  static Future<void> leaveGroup(int groupId) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final response = await http
          .post(
            Uri.parse(ApiConfig.getGroupLeaveUrl(groupId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode != 200) {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to leave group');
      }
    } catch (e) {
      debugPrint('Leave group error: $e');
      rethrow;
    }
  }

  /// Get messages for a group with offline-first approach
  static Future<List<GroupMessage>> getMessages({
    required int groupId,
    int limit = 50,
    int? beforeId,
    bool offlineFirst = true,
    Function(List<GroupMessage>)? onBackgroundUpdate,
  }) async {
    // Load from cache first for instant display
    if (offlineFirst) {
      final cachedMessages = await ChatCacheService.loadGroupMessages(groupId);

      if (cachedMessages.isNotEmpty) {
        debugPrint(
          '📦 Loaded ${cachedMessages.length} group messages from cache',
        );

        // Fetch fresh data in background and notify UI when complete
        _syncGroupMessagesInBackground(
          groupId,
          limit,
          beforeId,
          onBackgroundUpdate,
        );

        return cachedMessages;
      }
    }

    // No cache - fetch from server
    return await _fetchGroupMessagesFromServer(
      groupId: groupId,
      limit: limit,
      beforeId: beforeId,
    );
  }

  /// Fetch group messages from server and update cache
  static Future<List<GroupMessage>> _fetchGroupMessagesFromServer({
    required int groupId,
    int limit = 50,
    int? beforeId,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final queryParams = <String, String>{
        'limit': limit.toString(),
        if (beforeId != null) 'before_id': beforeId.toString(),
      };

      final uri = Uri.parse(
        ApiConfig.getGroupMessagesUrl(groupId),
      ).replace(queryParameters: queryParams);

      debugPrint('💬 Fetching messages from: $uri');

      final response = await http
          .get(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      debugPrint('📡 Messages API response status: ${response.statusCode}');

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final messagesList = data['messages'] as List;
        final messages = messagesList
            .map((json) => GroupMessage.fromJson(json))
            .toList();

        debugPrint('✅ Loaded ${messages.length} messages for group $groupId');

        // Cache the messages for offline access
        if (messages.isNotEmpty) {
          await ChatCacheService.saveGroupMessages(groupId, messages);
          debugPrint('💾 Cached ${messages.length} group messages');
        }

        return messages;
      } else {
        debugPrint('❌ Failed to load messages: ${response.statusCode}');
        throw Exception('Failed to load messages: ${response.body}');
      }
    } catch (e) {
      debugPrint('❌ Get group messages error: $e');

      // If network error, try returning cached data
      final cachedMessages = await ChatCacheService.loadGroupMessages(groupId);
      if (cachedMessages.isNotEmpty) {
        debugPrint(
          '📦 Network error - returning ${cachedMessages.length} cached group messages',
        );
        return cachedMessages;
      }

      rethrow;
    }
  }

  /// Background sync without blocking UI
  static Future<void> _syncGroupMessagesInBackground(
    int groupId,
    int limit,
    int? beforeId,
    Function(List<GroupMessage>)? onBackgroundUpdate,
  ) async {
    try {
      final freshMessages = await _fetchGroupMessagesFromServer(
        groupId: groupId,
        limit: limit,
        beforeId: beforeId,
      );

      // Notify UI with fresh messages that have file URLs
      if (onBackgroundUpdate != null && freshMessages.isNotEmpty) {
        debugPrint(
          '🔄 Background sync complete - notifying UI with ${freshMessages.length} fresh messages',
        );
        onBackgroundUpdate(freshMessages);
      }
    } catch (e) {
      debugPrint('Background group sync failed: $e');
      // Silently fail - user already has cached data
    }
  }

  /// Send a text message to the group
  static Future<GroupMessage> sendMessage({
    required int groupId,
    required String content,
    String messageType = 'text',
    int? replyToId,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final response = await http
          .post(
            Uri.parse(ApiConfig.getGroupMessagesUrl(groupId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'content': content,
              'message_type': messageType,
              if (replyToId != null) 'reply_to_id': replyToId,
            }),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return GroupMessage.fromJson(data['data']);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to send message');
      }
    } catch (e) {
      debugPrint('Send group message error: $e');
      rethrow;
    }
  }

  /// Upload a file to the group
  static Future<GroupMessage> uploadFile({
    required int groupId,
    required File file,
    String? caption,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(ApiConfig.getGroupUploadUrl(groupId)),
      );

      request.headers['Authorization'] = 'Bearer $token';

      final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
      final mimeTypeParts = mimeType.split('/');

      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          file.path,
          contentType: MediaType(mimeTypeParts[0], mimeTypeParts[1]),
        ),
      );

      if (caption != null && caption.isNotEmpty) {
        request.fields['caption'] = caption;
      }

      final streamedResponse = await request.send().timeout(
        const Duration(minutes: 5),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return GroupMessage.fromJson(data['data']);
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to upload file');
      }
    } catch (e) {
      debugPrint('Upload group file error: $e');
      rethrow;
    }
  }

  /// Delete a message (sender or admin only)
  static Future<void> deleteMessage({
    required int groupId,
    required int messageId,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final response = await http
          .delete(
            Uri.parse(ApiConfig.getGroupMessageUrl(groupId, messageId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode != 200) {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to delete message');
      }
    } catch (e) {
      debugPrint('Delete group message error: $e');
      rethrow;
    }
  }

  /// Delete all messages in a group (group admin or creator only)
  static Future<int> deleteAllMessages(int groupId) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final response = await http
          .delete(
            Uri.parse(ApiConfig.getGroupMessagesUrl(groupId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode != 200) {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to delete all messages');
      }

      final data = jsonDecode(response.body);
      return (data['deleted_messages'] as int?) ?? 0;
    } catch (e) {
      debugPrint('Delete all group messages error: $e');
      rethrow;
    }
  }

  /// Edit a message (sender only)
  static Future<void> editMessage({
    required int groupId,
    required int messageId,
    required String content,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final response = await http
          .put(
            Uri.parse(ApiConfig.getGroupMessageUrl(groupId, messageId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'content': content}),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode != 200) {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to edit message');
      }
    } catch (e) {
      debugPrint('Edit group message error: $e');
      rethrow;
    }
  }

  /// Mark message as delivered
  static Future<void> markMessageDelivered({
    required int groupId,
    required int messageId,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) return;

      await http
          .post(
            Uri.parse(
              ApiConfig.getGroupMessageDeliveredUrl(groupId, messageId),
            ),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);
    } catch (e) {
      debugPrint('Mark group message delivered error: $e');
    }
  }

  /// Mark messages as viewed
  static Future<void> markMessagesViewed({
    required int groupId,
    required List<int> messageIds,
    required int senderId,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) return;

      await http
          .post(
            Uri.parse(ApiConfig.getGroupMessagesViewedUrl(groupId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'message_ids': messageIds,
              'sender_id': senderId,
            }),
          )
          .timeout(ApiConfig.connectionTimeout);
    } catch (e) {
      debugPrint('Mark group messages viewed error: $e');
    }
  }

  /// Add reaction to a message
  static Future<Map<String, dynamic>> addReaction({
    required int groupId,
    required int messageId,
    required String emoji,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final response = await http
          .post(
            Uri.parse(
              ApiConfig.getGroupMessageReactionsUrl(groupId, messageId),
            ),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'emoji': emoji}),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['reactions'] as Map<String, dynamic>;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to add reaction');
      }
    } catch (e) {
      debugPrint('Add group reaction error: $e');
      rethrow;
    }
  }

  /// Remove reaction from a message
  static Future<Map<String, dynamic>> removeReaction({
    required int groupId,
    required int messageId,
    required String emoji,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final response = await http
          .delete(
            Uri.parse(
              ApiConfig.getGroupMessageReactionsUrl(groupId, messageId),
            ),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'emoji': emoji}),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['reactions'] as Map<String, dynamic>;
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to remove reaction');
      }
    } catch (e) {
      debugPrint('Remove group reaction error: $e');
      rethrow;
    }
  }

  /// Ring doorbell (send notification to all group members)
  static Future<void> ringDoorbell(int groupId) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token');

      final response = await http
          .post(
            Uri.parse(ApiConfig.getGroupDoorbellUrl(groupId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Authentication failed');
      }

      if (response.statusCode != 200) {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to ring doorbell');
      }
    } catch (e) {
      debugPrint('Ring group doorbell error: $e');
      rethrow;
    }
  }
}
