import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../config/api_config.dart';
import '../models/bulk_send_response.dart';
import '../models/message.dart';
import 'storage_service.dart';
import 'auth_error_handler.dart';
import 'chat_cache_service.dart';

/// Service for handling message API calls
/// Enhanced with offline-first capabilities
class MessageService {
  static void _trace(String message) {
    if (kDebugMode) {
      debugPrint(message);
    }
  }

  /// Get conversation messages with offline-first approach
  /// Returns cached messages immediately, then syncs with server
  static Future<List<Message>> getConversationMessages({
    required int userId,
    int limit = 50,
    int? beforeId,
    bool offlineFirst = true,
  }) async {
    _trace(
      '🔍 getConversationMessages called for userId: $userId, offlineFirst: $offlineFirst',
    );

    // Get current user ID for cache
    final currentUserId = await StorageService.getUserId();
    _trace('🔍 Current user ID: $currentUserId');

    // Load from cache first for instant display
    if (offlineFirst && currentUserId != null) {
      _trace('🔍 Attempting to load from cache...');
      final cachedMessages = await ChatCacheService.loadConversationMessages(
        currentUserId,
        userId,
      );
      _trace('🔍 Cache returned ${cachedMessages.length} messages');

      // Return cached messages immediately if available
      if (cachedMessages.isNotEmpty) {
        _trace('📦 Loaded ${cachedMessages.length} messages from cache');

        // Fetch fresh data in background (don't await)
        _syncMessagesInBackground(userId, currentUserId, limit, beforeId);

        return cachedMessages;
      } else {
        _trace('📦 Cache is empty, will try server');
      }
    } else {
      _trace(
        '🔍 Skipping cache: offlineFirst=$offlineFirst, currentUserId=$currentUserId',
      );
    }

    // No cache or offline mode disabled - fetch from server
    _trace('🔍 Fetching from server...');
    return await _fetchMessagesFromServer(
      userId: userId,
      currentUserId: currentUserId,
      limit: limit,
      beforeId: beforeId,
    );
  }

  /// Fetch messages from server and update cache
  static Future<List<Message>> _fetchMessagesFromServer({
    required int userId,
    required int? currentUserId,
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

      final uri = Uri.parse(
        '${ApiConfig.baseUrl}${ApiConfig.mobilePrefix}/messages/conversation/$userId',
      ).replace(queryParameters: queryParams);

      final response = await http
          .get(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final messages = <Message>[];
        for (final raw in data['messages'] as List) {
          messages.add(Message.fromJson(Map<String, dynamic>.from(raw as Map)));
        }

        // Sync cache with server response
        if (currentUserId != null) {
          if (messages.isNotEmpty) {
            await ChatCacheService.saveConversationMessages(
              currentUserId,
              userId,
              messages,
            );
            _trace('💾 Cached ${messages.length} messages');
          } else {
            // Server returned 0 messages — clear stale cache
            await ChatCacheService.clearConversationCache(
              currentUserId,
              userId,
            );
            _trace('🗑️ Server returned 0 messages — cache cleared');
          }
        }

        return messages;
      } else if (response.statusCode == 401) {
        debugPrint('🔐 Token expired - redirecting to sign in');
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Session expired');
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to load messages');
      }
    } catch (e) {
      _trace('Get conversation messages error: $e');

      // If network error and we have currentUserId, try returning cached data
      if (currentUserId != null) {
        final cachedMessages = await ChatCacheService.loadConversationMessages(
          currentUserId,
          userId,
        );
        if (cachedMessages.isNotEmpty) {
          _trace(
            '📦 Network error - returning ${cachedMessages.length} cached messages',
          );
          return cachedMessages;
        }
      }

      rethrow;
    }
  }

  /// Background sync without blocking UI
  static Future<void> _syncMessagesInBackground(
    int userId,
    int currentUserId,
    int limit,
    int? beforeId,
  ) async {
    try {
      await _fetchMessagesFromServer(
        userId: userId,
        currentUserId: currentUserId,
        limit: limit,
        beforeId: beforeId,
      );
    } catch (e) {
      _trace('Background sync failed: $e');
      // Silently fail - user already has cached data
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

      final response = await http
          .post(
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
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return Message.fromJson(Map<String, dynamic>.from(data['data'] as Map));
      } else if (response.statusCode == 401) {
        // Token expired - trigger auth error handler
        debugPrint('🔐 Token expired - redirecting to sign in');
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Session expired');
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Failed to send message');
      }
    } catch (e) {
      debugPrint('Send message error: $e');
      rethrow;
    }
  }

  /// Send the same message to multiple recipients in a single request.
  /// The backend can return partial success, surfaced in [BulkSendResponse.results].
  static Future<BulkSendResponse> sendManyMessages({
    required List<int> recipientIds,
    required String content,
    String messageType = 'text',
    int? replyToId,
    String? bulkBatchId,
  }) async {
    try {
      if (recipientIds.isEmpty) {
        throw Exception('recipientIds cannot be empty');
      }

      final trimmedContent = content.trim();
      if (trimmedContent.isEmpty) {
        throw Exception('content cannot be empty');
      }

      final token = await StorageService.getToken();
      if (token == null) {
        throw Exception('No authentication token found');
      }

      // Keep recipient order stable while removing accidental duplicates.
      final normalizedRecipientIds = recipientIds.toSet().toList();

      final payload = <String, dynamic>{
        'recipient_ids': normalizedRecipientIds,
        'content': trimmedContent,
        'message_type': messageType,
        if (replyToId != null) 'reply_to_id': replyToId,
        if (bulkBatchId != null && bulkBatchId.trim().isNotEmpty)
          'bulk_batch_id': bulkBatchId.trim(),
      };

      final response = await http
          .post(
            Uri.parse(ApiConfig.sendManyMessagesUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(payload),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200 ||
          response.statusCode == 201 ||
          response.statusCode == 207) {
        final body = jsonDecode(response.body);
        if (body is Map<String, dynamic>) {
          return BulkSendResponse.fromJson(body);
        }
        throw Exception('Invalid bulk send response format');
      } else if (response.statusCode == 401) {
        debugPrint('🔐 Token expired - redirecting to sign in');
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Session expired');
      } else {
        String errorMessage = 'Failed to send bulk message';
        try {
          final errorBody = jsonDecode(response.body);
          if (errorBody is Map<String, dynamic>) {
            errorMessage =
                (errorBody['error'] ?? errorBody['message'])?.toString() ??
                errorMessage;
          }
        } catch (_) {
          // Keep default message when response body is not JSON.
        }
        throw Exception(errorMessage);
      }
    } catch (e) {
      debugPrint('Send many messages error: $e');
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

      await http
          .post(
            Uri.parse(
              '${ApiConfig.baseUrl}${ApiConfig.mobilePrefix}/messages/mark-read',
            ),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'sender_id': senderId,
              'last_message_id': lastMessageId,
            }),
          )
          .timeout(ApiConfig.connectionTimeout);
    } catch (e) {
      debugPrint('Mark as read error: $e');
    }
  }

  /// Upload a file to the server
  static Future<Map<String, dynamic>?> uploadFile({
    required dynamic file,
    required int recipientId,
  }) async {
    try {
      final token = await StorageService.getToken();

      if (token == null) {
        throw Exception('No authentication token found');
      }

      final uri = Uri.parse(
        '${ApiConfig.baseUrl}${ApiConfig.mobilePrefix}/messages/upload',
      );

      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer $token';
      request.fields['recipient_id'] = recipientId.toString();

      // Add file to request
      if (file is http.MultipartFile) {
        request.files.add(file);
      } else {
        // Assume it's a dart:io File
        request.files.add(await http.MultipartFile.fromPath('file', file.path));
      }

      final streamedResponse = await request.send().timeout(
        const Duration(minutes: 5),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return {
          'success': true,
          'file_url': data['file_url'] ?? data['url'],
          'file_id': data['file_id'] ?? data['id'],
          ...data,
        };
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Upload failed');
      }
    } catch (e) {
      debugPrint('Upload file error: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Upload a file with progress tracking.
  /// [onProgress] receives (bytesSent, totalBytes) for real-time progress.
  static Future<Map<String, dynamic>?> uploadFileWithProgress({
    required String filePath,
    required String fileName,
    required String mimeType,
    required int recipientId,
    void Function(int sent, int total)? onProgress,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) {
        throw Exception('No authentication token found');
      }

      final uri = Uri.parse(
        '${ApiConfig.baseUrl}${ApiConfig.mobilePrefix}/messages/upload',
      );

      final fileToUpload = File(filePath);
      final fileLength = await fileToUpload.length();

      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bearer $token';
      request.fields['recipient_id'] = recipientId.toString();

      // Use stream-based file reading to avoid loading entire file into memory
      final multipartFile = http.MultipartFile(
        'file',
        fileToUpload.openRead(),
        fileLength,
        filename: fileName,
        contentType: MediaType.parse(mimeType),
      );
      request.files.add(multipartFile);

      // Get the byte stream and track progress
      final byteStream = request.finalize();
      final totalBytes = request.contentLength;

      int bytesSent = 0;
      // Throttle: only report progress every 256KB to avoid flooding the UI
      const reportInterval = 256 * 1024;
      int lastReported = 0;

      final progressStream = byteStream.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (data, sink) {
            bytesSent += data.length;
            if (bytesSent - lastReported >= reportInterval ||
                bytesSent >= totalBytes) {
              lastReported = bytesSent;
              onProgress?.call(bytesSent, totalBytes);
            }
            sink.add(data);
          },
        ),
      );

      final streamedRequest = http.StreamedRequest('POST', uri);
      streamedRequest.headers.addAll(request.headers);
      streamedRequest.contentLength = totalBytes;

      // Pipe the progress-tracked stream into the request
      progressStream.listen(
        streamedRequest.sink.add,
        onDone: streamedRequest.sink.close,
        onError: streamedRequest.sink.addError,
      );

      final streamedResponse = await streamedRequest.send().timeout(
        const Duration(minutes: 10),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return {
          'success': true,
          'file_url': data['file_url'] ?? data['url'],
          'file_id': data['file_id'] ?? data['id'],
          ...data,
        };
      } else {
        final error = jsonDecode(response.body);
        throw Exception(error['error'] ?? 'Upload failed');
      }
    } catch (e) {
      debugPrint('Upload file with progress error: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Get all tasks for the current user
  static Future<List<Map<String, dynamic>>> getAllTasks() async {
    try {
      final token = await StorageService.getToken();

      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http
          .get(
            Uri.parse(ApiConfig.tasksUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final tasks = data['tasks'] as List?;
        return tasks?.cast<Map<String, dynamic>>() ?? [];
      } else if (response.statusCode == 401) {
        debugPrint('🔐 Token expired - redirecting to sign in');
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Session expired');
      } else {
        debugPrint('Get tasks error - Status: ${response.statusCode}');
        return []; // Return empty list if endpoint doesn't exist yet
      }
    } catch (e) {
      debugPrint('Get all tasks error: $e');
      return []; // Return empty list on error
    }
  }

  /// Get all chat-based tasks (messages marked as tasks) for the current user
  static Future<List<Map<String, dynamic>>> getChatTasks() async {
    try {
      final token = await StorageService.getToken();

      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http
          .get(
            Uri.parse(ApiConfig.chatTasksUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final tasks = data['tasks'] as List?;
        return tasks?.cast<Map<String, dynamic>>() ?? [];
      } else if (response.statusCode == 401) {
        debugPrint('🔐 Token expired - redirecting to sign in');
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Session expired');
      } else {
        debugPrint('Get chat tasks error - Status: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      debugPrint('Get chat tasks error: $e');
      return [];
    }
  }

  /// Get all chat-based tasks for a specific 1-on-1 conversation.
  /// Returns messages that have is_task=True between current user and [otherUserId].
  static Future<List<Map<String, dynamic>>> getChatTasksForConversation(
    int otherUserId,
  ) async {
    try {
      final token = await StorageService.getToken();

      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http
          .get(
            Uri.parse(ApiConfig.getChatTasksForUserUrl(otherUserId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final tasks = data['tasks'] as List?;
        return tasks?.cast<Map<String, dynamic>>() ?? [];
      } else if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Session expired');
      } else {
        debugPrint(
          'Get conversation tasks error - Status: ${response.statusCode}',
        );
        return [];
      }
    } catch (e) {
      debugPrint('Get conversation tasks error: $e');
      return [];
    }
  }

  /// Create a new task
  static Future<Map<String, dynamic>?> createTask({
    required String title,
    String? description,
    int? assignedToUserId,
  }) async {
    try {
      final token = await StorageService.getToken();

      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http
          .post(
            Uri.parse(ApiConfig.tasksUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'title': title,
              if (description != null) 'description': description,
              if (assignedToUserId != null)
                'assigned_to_user_id': assignedToUserId,
            }),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return data['task'] as Map<String, dynamic>?;
      } else if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Session expired');
      } else {
        debugPrint('Create task error - Status: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('Create task error: $e');
      return null;
    }
  }

  /// Complete a task
  static Future<bool> completeTask(int taskId) async {
    try {
      final token = await StorageService.getToken();

      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http
          .post(
            Uri.parse(ApiConfig.getTaskCompleteUrl(taskId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Complete task error: $e');
      return false;
    }
  }

  /// Delete a task
  static Future<bool> deleteTask(int taskId) async {
    try {
      final token = await StorageService.getToken();

      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http
          .delete(
            Uri.parse(ApiConfig.getTaskUrl(taskId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Delete task error: $e');
      return false;
    }
  }

  /// Get all excalidraw boards
  static Future<List<Map<String, dynamic>>> getAllExcalidrawBoards() async {
    try {
      final token = await StorageService.getToken();

      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http
          .get(
            Uri.parse(ApiConfig.excalidrawBoardsUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final boards = data['boards'] as List?;
        return boards?.cast<Map<String, dynamic>>() ?? [];
      } else if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        throw Exception('Session expired');
      } else {
        debugPrint(
          'Get excalidraw boards error - Status: ${response.statusCode}',
        );
        return [];
      }
    } catch (e) {
      debugPrint('Get all excalidraw boards error: $e');
      return [];
    }
  }

  /// Pin an Excalidraw message link
  static Future<bool> pinExcalidrawLink({required int messageId}) async {
    try {
      final token = await StorageService.getToken();

      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http
          .post(
            Uri.parse(ApiConfig.getExcalidrawPinUrl(messageId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        return true;
      } else if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        return false;
      } else {
        debugPrint(
          'Pin excalidraw error - Status: ${response.statusCode}, Body: ${response.body}',
        );
        return false;
      }
    } catch (e) {
      debugPrint('Pin excalidraw error: $e');
      return false;
    }
  }

  /// Get pinned Excalidraw links for a conversation
  static Future<List<Map<String, dynamic>>> getConversationExcalidrawLinks({
    required int userId,
  }) async {
    try {
      final token = await StorageService.getToken();
      if (token == null) throw Exception('No authentication token found');

      final response = await http
          .get(
            Uri.parse(ApiConfig.getExcalidrawConversationUrl(userId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final links = data['excalidraw_links'] as List?;
        return links?.cast<Map<String, dynamic>>() ?? [];
      } else if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        return [];
      } else {
        debugPrint(
          'Get excalidraw links error - Status: ${response.statusCode}',
        );
        return [];
      }
    } catch (e) {
      debugPrint('Get excalidraw links error: $e');
      return [];
    }
  }

  /// Unpin an Excalidraw message link
  static Future<bool> unpinExcalidrawLink({required int messageId}) async {
    try {
      final token = await StorageService.getToken();

      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http
          .post(
            Uri.parse(ApiConfig.getExcalidrawUnpinUrl(messageId)),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        return true;
      } else if (response.statusCode == 401) {
        await AuthErrorHandler().handleAuthError(
          message: 'Your session has expired. Please sign in again.',
        );
        return false;
      } else {
        debugPrint(
          'Unpin excalidraw error - Status: ${response.statusCode}, Body: ${response.body}',
        );
        return false;
      }
    } catch (e) {
      debugPrint('Unpin excalidraw error: $e');
      return false;
    }
  }
}
