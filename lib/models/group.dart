/// Group model for group chats
import 'package:flutter/foundation.dart';
import '../config/api_config.dart';
import '../services/storage_service.dart';
import 'message.dart';

Map<String, dynamic> _normalizeGroupReactionsMap(dynamic value) {
  if (value == null) return {};
  if (value is! Map) return {};

  final raw = Map<String, dynamic>.from(
    value.map((key, entryValue) => MapEntry(key.toString(), entryValue)),
  );
  final normalized = <String, List<String>>{};

  void addUser(String emoji, String userId) {
    final trimmedEmoji = emoji.trim();
    final trimmedUserId = userId.trim();
    if (trimmedEmoji.isEmpty || trimmedUserId.isEmpty) {
      return;
    }

    final users = normalized.putIfAbsent(trimmedEmoji, () => <String>[]);
    if (!users.contains(trimmedUserId)) {
      users.add(trimmedUserId);
    }
  }

  String? normalizeUserId(dynamic userValue) {
    if (userValue == null) return null;
    if (userValue is Map) {
      final userMap = Map<String, dynamic>.from(
        userValue.map((key, entryValue) => MapEntry(key.toString(), entryValue)),
      );
      final candidate =
          userMap['user_id'] ??
          userMap['id'] ??
          userMap['username'] ??
          userMap['user_name'] ??
          userMap['name'];
      final normalizedValue = candidate?.toString().trim();
      if (normalizedValue == null || normalizedValue.isEmpty) {
        return null;
      }
      return normalizedValue;
    }

    final normalizedValue = userValue.toString().trim();
    if (normalizedValue.isEmpty) {
      return null;
    }
    return normalizedValue;
  }

  void addUsers(String emoji, List<dynamic> users) {
    for (final user in users) {
      final userId = normalizeUserId(user);
      if (userId != null) {
        addUser(emoji, userId);
      }
    }
  }

  final byUser = raw['by_user'];
  if (byUser is List) {
    for (final entry in byUser) {
      if (entry is! Map) continue;
      final entryMap = Map<String, dynamic>.from(
        entry.map((key, entryValue) => MapEntry(key.toString(), entryValue)),
      );
      final emoji =
          entryMap['reaction']?.toString() ?? entryMap['emoji']?.toString();
      final userId = normalizeUserId(entryMap);
      if (emoji != null && userId != null) {
        addUser(emoji, userId);
      }
    }
  }

  raw.forEach((emoji, entryValue) {
    if (emoji == 'counts' || emoji == 'by_user') {
      return;
    }

    if (entryValue is List) {
      addUsers(emoji, entryValue);
      return;
    }

    if (entryValue is! Map) {
      return;
    }

    final nested = Map<String, dynamic>.from(
      entryValue.map((key, nestedValue) => MapEntry(key.toString(), nestedValue)),
    );
    final nestedUsers = nested['by_user'] ?? nested['users'];
    if (nestedUsers is List) {
      addUsers(emoji, nestedUsers);
    }
  });

  if (normalized.isNotEmpty) {
    return normalized;
  }

  final counts = raw['counts'];
  if (counts is Map) {
    final countMap = Map<String, dynamic>.from(
      counts.map((key, entryValue) => MapEntry(key.toString(), entryValue)),
    );
    countMap.forEach((emoji, countValue) {
      final count = countValue is num ? countValue.toInt() : int.tryParse('$countValue');
      if (count == null || count <= 0) {
        return;
      }
      normalized[emoji] = List<String>.generate(
        count,
        (index) => '__count_placeholder_${emoji}_$index',
      );
    });
  }

  return normalized;
}

class Group {
  final int id;
  final String name;
  final String? description;
  final int createdBy;
  final String? avatarUrl;
  final int memberCount;
  final bool isActive;
  final String createdAt;
  final String myRole; // 'admin' or 'member'
  final bool isMuted;
  final GroupMessage? lastMessage;

  Group({
    required this.id,
    required this.name,
    this.description,
    required this.createdBy,
    this.avatarUrl,
    required this.memberCount,
    required this.isActive,
    required this.createdAt,
    required this.myRole,
    this.isMuted = false,
    this.lastMessage,
  });

  factory Group.fromJson(Map<String, dynamic> json) {
    try {
      // Try to extract my_role from the root level first
      String myRole = json['my_role'] as String? ?? 'member';

      // If my_role is not at root level, try to extract it from members array
      // This handles the case where the backend returns members with user_id matching current user
      if (json['my_role'] == null && json['members'] != null) {
        // We'll default to 'member' if we can't determine the role
        // The role will be updated when the group details are fetched
        myRole = 'member';
      }

      return Group(
        id: json['id'] as int,
        name: json['name'] as String,
        description: json['description'] as String?,
        createdBy: json['created_by'] as int,
        avatarUrl: json['avatar_url'] as String?,
        memberCount: json['member_count'] as int,
        isActive: json['is_active'] as bool? ?? true,
        createdAt: json['created_at'] as String,
        myRole: myRole,
        isMuted: json['is_muted'] as bool? ?? false,
        lastMessage: json['last_message'] != null
            ? GroupMessage.fromJson(
                json['last_message'] as Map<String, dynamic>,
              )
            : null,
      );
    } catch (e, stackTrace) {
      debugPrint('❌ Error parsing Group: $e');
      debugPrint('📋 JSON data: $json');
      debugPrint('📋 Stack trace: $stackTrace');
      rethrow;
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'created_by': createdBy,
      'avatar_url': avatarUrl,
      'member_count': memberCount,
      'is_active': isActive,
      'created_at': createdAt,
      'my_role': myRole,
      'is_muted': isMuted,
      'last_message': lastMessage?.toJson(),
    };
  }

  bool get isAdmin => myRole == 'admin';
}

/// Group member model
class GroupMember {
  final int userId;
  final String role;
  final String joinedAt;
  final bool isMuted;
  final GroupMemberUser user;

  GroupMember({
    required this.userId,
    required this.role,
    required this.joinedAt,
    this.isMuted = false,
    required this.user,
  });

  factory GroupMember.fromJson(Map<String, dynamic> json) {
    return GroupMember(
      userId: json['user_id'] as int,
      role: json['role'] as String,
      joinedAt: json['joined_at'] as String,
      isMuted: json['is_muted'] as bool? ?? false,
      user: GroupMemberUser.fromJson(json['user'] as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'user_id': userId,
      'role': role,
      'joined_at': joinedAt,
      'is_muted': isMuted,
      'user': user.toJson(),
    };
  }
}

/// Simplified user model for group members
class GroupMemberUser {
  final int id;
  final String username;
  final String firstName;
  final String lastName;
  final String email;
  final String? avatarUrl;

  GroupMemberUser({
    required this.id,
    required this.username,
    required this.firstName,
    required this.lastName,
    required this.email,
    this.avatarUrl,
  });

  String get fullName => '$firstName $lastName'.trim();

  factory GroupMemberUser.fromJson(Map<String, dynamic> json) {
    return GroupMemberUser(
      id: json['id'] as int,
      username: json['username'] as String,
      firstName: json['first_name'] as String,
      lastName: json['last_name'] as String? ?? '',
      email: json['email'] as String,
      avatarUrl: json['avatar_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'first_name': firstName,
      'last_name': lastName,
      'email': email,
      'avatar_url': avatarUrl,
    };
  }
}

/// Group message model
class GroupMessage {
  final int id;
  final int messageId;
  final int groupId;
  final int senderId;
  final GroupMessageSender? sender;
  final String content;
  final String messageType;
  final String timestamp;
  final int timestampMs;
  final bool isDeleted;
  final String? fileUrl;
  final String? fileName;
  final int? fileSize;
  final String? fileType;
  final int? replyToId;
  final String? replyPreview;
  final Map<String, dynamic> reactions;
  final String? caption;

  /// Delivery status for the shared chat bubble UI.
  /// 'pending' | 'sent' | 'delivered' | 'read' | 'failed'. Groups don't track
  /// per-recipient receipts the way 1:1 does, so server messages default to
  /// 'sent'; optimistic messages start at 'pending' until confirmed.
  final String status;

  /// Local file path for optimistic media messages (before upload completes).
  /// Lets the bubble show the picked image/video from disk during upload.
  /// In-memory only — never persisted to JSON.
  final String? localFilePath;

  GroupMessage({
    required this.id,
    required this.messageId,
    required this.groupId,
    required this.senderId,
    this.sender,
    required this.content,
    required this.messageType,
    required this.timestamp,
    required this.timestampMs,
    this.isDeleted = false,
    this.fileUrl,
    this.fileName,
    this.fileSize,
    this.fileType,
    this.replyToId,
    this.replyPreview,
    this.reactions = const {},
    this.caption,
    this.status = 'sent',
    this.localFilePath,
  });

  /// Returns a copy with the given fields replaced. Only non-null arguments
  /// override existing values (cannot clear a field back to null).
  GroupMessage copyWith({
    int? id,
    int? messageId,
    int? groupId,
    int? senderId,
    GroupMessageSender? sender,
    String? content,
    String? messageType,
    String? timestamp,
    int? timestampMs,
    bool? isDeleted,
    String? fileUrl,
    String? fileName,
    int? fileSize,
    String? fileType,
    int? replyToId,
    String? replyPreview,
    Map<String, dynamic>? reactions,
    String? caption,
    String? status,
    String? localFilePath,
  }) {
    return GroupMessage(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      groupId: groupId ?? this.groupId,
      senderId: senderId ?? this.senderId,
      sender: sender ?? this.sender,
      content: content ?? this.content,
      messageType: messageType ?? this.messageType,
      timestamp: timestamp ?? this.timestamp,
      timestampMs: timestampMs ?? this.timestampMs,
      isDeleted: isDeleted ?? this.isDeleted,
      fileUrl: fileUrl ?? this.fileUrl,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      fileType: fileType ?? this.fileType,
      replyToId: replyToId ?? this.replyToId,
      replyPreview: replyPreview ?? this.replyPreview,
      reactions: reactions ?? this.reactions,
      caption: caption ?? this.caption,
      status: status ?? this.status,
      localFilePath: localFilePath ?? this.localFilePath,
    );
  }

  /// Adapts this group message into the shared [Message] model so the 1:1
  /// chat widgets (ChatMessageBubble, ChatMessageList, SwipeableMessage, …)
  /// can render group messages unchanged. Group-only concepts (sender name,
  /// per-member reactions) are surfaced separately by the group screen.
  Message toMessage() {
    return Message(
      id: id,
      senderId: senderId,
      recipientId: groupId,
      content: content,
      messageType: messageType,
      timestamp: timestamp,
      timestampMs: timestampMs,
      isRead: true,
      status: status,
      threadId: 'group_$groupId',
      replyToId: replyToId,
      replyPreview: replyPreview,
      reactions: reactions,
      fileUrl: fileUrl,
      fileName: fileName,
      fileSize: fileSize,
      fileType: fileType,
      isDeleted: isDeleted,
      caption: caption,
      localFilePath: localFilePath,
    );
  }

  factory GroupMessage.fromJson(Map<String, dynamic> json) {
    try {
      // Handle reply_preview which can be either a String or a Map
      String? replyPreviewText;
      final replyPreviewData = json['reply_preview'];
      if (replyPreviewData != null) {
        if (replyPreviewData is String) {
          replyPreviewText = replyPreviewData;
        } else if (replyPreviewData is Map) {
          // If it's a map, extract the content field
          replyPreviewText = replyPreviewData['content'] as String?;
        }
      }

      // Parse HTML content to extract file information
      String content = json['content'] as String? ?? '';
      String messageType = json['message_type'] as String? ?? 'text';
      String? fileUrl = json['file_url'] as String?;
      String? fileName = json['file_name'] as String?;
      String? fileType = json['file_type'] as String?;
      int? fileSize = json['file_size'] as int?;
      String? caption = json['caption'] as String?;

      // Debug logging for file messages (commented out to reduce noise)
      /*
      if (messageType != 'text' && messageType != 'system') {
        debugPrint('📎 [GROUP MESSAGE PARSE] File message detected:');
        debugPrint('📎 [GROUP MESSAGE PARSE] - Type: $messageType');
        debugPrint('📎 [GROUP MESSAGE PARSE] - Content: $content');
        debugPrint('📎 [GROUP MESSAGE PARSE] - File URL: $fileUrl');
        debugPrint('📎 [GROUP MESSAGE PARSE] - File Name: $fileName');
        debugPrint('📎 [GROUP MESSAGE PARSE] - File Type: $fileType');
        debugPrint('📎 [GROUP MESSAGE PARSE] - File Size: $fileSize');
        debugPrint('📎 [GROUP MESSAGE PARSE] - Raw JSON: $json');
      }
      */

      // If content contains HTML, parse it for file info and strip the raw HTML
      if (content.contains('<') && content.contains('>')) {
        // Check if this is a color change message first
        if (content.contains('Changed background color to') ||
            content.contains('Reset background color')) {
          // Clean up color change HTML content
          content = _cleanColorChangeContent(content);
        } else {
          if (fileUrl == null) {
            // Server didn't provide file_url — extract everything from HTML
            final htmlParseResult = _parseHtmlContent(content);
            if (htmlParseResult != null) {
              messageType = htmlParseResult['messageType'] ?? messageType;
              fileUrl = htmlParseResult['fileUrl'];
              fileName = htmlParseResult['fileName'];
              fileType = htmlParseResult['fileType'];
              fileSize = htmlParseResult['fileSize'];
            }
          }
          // Extract caption from HTML if present and not already provided
          if (caption == null || caption.isEmpty) {
            final captionRegex = RegExp(
              '<div[^>]*class=[\'"]file-caption[\'"][^>]*>(.*?)</div>',
              caseSensitive: false,
              dotAll: true,
            );
            final captionMatch = captionRegex.firstMatch(content);
            if (captionMatch != null) {
              caption = captionMatch.group(1)?.replaceAll(RegExp(r'<[^>]*>'), '').trim();
            }
          }
          // Always replace raw HTML content with just the filename so it isn't rendered as text
          content = fileName ?? '';
        }
      }

      // Process file URL to convert relative paths to full URLs (like 1-on-1 chat)
      if (fileUrl != null && fileUrl.isNotEmpty) {
        final fullFileUrl = fileUrl.startsWith('http')
            ? fileUrl
            : '${ApiConfig.baseUrl}$fileUrl';
        // debugPrint(
        //   '📎 [GROUP MESSAGE PARSE] Converting URL: $fileUrl -> $fullFileUrl',
        // );
        fileUrl = fullFileUrl;
      }

      return GroupMessage(
        id: json['id'] as int? ?? json['message_id'] as int,
        messageId: json['message_id'] as int? ?? json['id'] as int,
        groupId: json['group_id'] as int,
        senderId: json['sender_id'] as int,
        sender: json['sender'] != null
            ? GroupMessageSender.fromJson(
                Map<String, dynamic>.from(json['sender'] as Map),
              )
            : null,
        content: content,
        messageType: messageType,
        timestamp: json['timestamp'] as String,
        timestampMs: json['timestamp_ms'] as int? ?? 0,
        isDeleted: json['is_deleted'] as bool? ?? false,
        fileUrl: fileUrl,
        fileName: fileName,
        fileSize: fileSize,
        fileType: fileType,
        replyToId: json['reply_to_id'] as int?,
        replyPreview: replyPreviewText,
        reactions: _normalizeGroupReactionsMap(json['reactions']),
        caption: caption,
        status: json['status'] as String? ?? 'sent',
      );
    } catch (e, stackTrace) {
      debugPrint('❌ Error parsing GroupMessage: $e');
      debugPrint('📋 JSON data: $json');
      debugPrint('📋 Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Parse HTML content to extract file information
  static Map<String, dynamic>? _parseHtmlContent(String htmlContent) {
    // Image pattern: <img src="..." alt="..." data-filename="..." data-filesize="...">
    final imgRegex = RegExp(
      r'<img[^>]*src="([^"]*)"[^>]*>',
      caseSensitive: false,
    );
    final imgMatch = imgRegex.firstMatch(htmlContent);

    if (imgMatch != null) {
      final src = imgMatch.group(1);
      final fileName =
          _extractAttributeFromHtml(htmlContent, 'data-filename') ??
          _extractAttributeFromHtml(htmlContent, 'alt') ??
          'image.jpg';
      final fileSize = int.tryParse(
        _extractAttributeFromHtml(htmlContent, 'data-filesize') ?? '0',
      );

      return {
        'messageType': 'image',
        'fileUrl': src,
        'fileName': fileName,
        'fileType': 'image/jpeg',
        'fileSize': fileSize,
      };
    }

    // Video pattern: <video src="..." controls>...</video>
    final videoRegex = RegExp(
      r'<video[^>]*src="([^"]*)"[^>]*>',
      caseSensitive: false,
    );
    final videoMatch = videoRegex.firstMatch(htmlContent);

    if (videoMatch != null) {
      final src = videoMatch.group(1);
      final fileName =
          _extractAttributeFromHtml(htmlContent, 'data-filename') ??
          'video.mp4';
      final fileSize = int.tryParse(
        _extractAttributeFromHtml(htmlContent, 'data-filesize') ?? '0',
      );

      return {
        'messageType': 'video',
        'fileUrl': src,
        'fileName': fileName,
        'fileType': 'video/mp4',
        'fileSize': fileSize,
      };
    }

    // Audio pattern: <audio src="..." controls>...</audio>
    final audioRegex = RegExp(
      r'<audio[^>]*src="([^"]*)"[^>]*>',
      caseSensitive: false,
    );
    final audioMatch = audioRegex.firstMatch(htmlContent);

    if (audioMatch != null) {
      final src = audioMatch.group(1);
      final fileName =
          _extractAttributeFromHtml(htmlContent, 'data-filename') ??
          'audio.mp3';
      final fileSize = int.tryParse(
        _extractAttributeFromHtml(htmlContent, 'data-filesize') ?? '0',
      );

      return {
        'messageType': 'audio',
        'fileUrl': src,
        'fileName': fileName,
        'fileType': 'audio/mpeg',
        'fileSize': fileSize,
      };
    }

    // Generic file link pattern: <a href="..." download="...">...</a>
    final linkRegex = RegExp(
      r'<a[^>]*href="([^"]*)"[^>]*download[^>]*>([^<]*)</a>',
      caseSensitive: false,
    );
    final linkMatch = linkRegex.firstMatch(htmlContent);

    if (linkMatch != null) {
      final src = linkMatch.group(1);
      final fileName = linkMatch.group(2) ?? 'file';
      final fileSize = int.tryParse(
        _extractAttributeFromHtml(htmlContent, 'data-filesize') ?? '0',
      );

      return {
        'messageType': 'file',
        'fileUrl': src,
        'fileName': fileName,
        'fileType': 'application/octet-stream',
        'fileSize': fileSize,
      };
    }

    if (_looksLikeFileHtml(htmlContent)) {
      final fileName =
          _extractTaggedTextFromHtml(htmlContent, 'file-name') ??
          _extractAttributeFromHtml(htmlContent, 'data-filename') ??
          _extractAttributeFromHtml(htmlContent, 'download') ??
          _extractAttributeFromHtml(htmlContent, 'title') ??
          'file';
      final fileSize = _extractFileSizeFromHtml(htmlContent);

      return {
        'messageType': 'file',
        'fileUrl': _extractOptionalHrefFromHtml(htmlContent),
        'fileName': fileName,
        'fileType': 'application/octet-stream',
        'fileSize': fileSize,
      };
    }

    return null;
  }

  /// Extract attribute value from HTML string
  static String? _extractAttributeFromHtml(String html, String attribute) {
    final regex = RegExp('$attribute="([^"]*)"', caseSensitive: false);
    final match = regex.firstMatch(html);
    return match?.group(1);
  }

  static bool _looksLikeFileHtml(String html) {
    final normalized = html.toLowerCase();
    return normalized.contains('file-message') ||
        normalized.contains('file-info') ||
        normalized.contains('file-name') ||
        normalized.contains('file-size') ||
        normalized.contains('download-link') ||
        normalized.contains(' download=');
  }

  static String? _extractTaggedTextFromHtml(String html, String className) {
    final regex = RegExp(
      'class="[^"]*${RegExp.escape(className)}[^"]*"[^>]*>([^<]*)<',
      caseSensitive: false,
    );
    final match = regex.firstMatch(html);
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  static int? _extractFileSizeFromHtml(String html) {
    final rawSize =
        _extractAttributeFromHtml(html, 'data-filesize') ??
        _extractTaggedTextFromHtml(html, 'file-size');
    if (rawSize == null || rawSize.isEmpty) {
      return null;
    }

    final bytesMatch = RegExp(r'(\d+)').firstMatch(rawSize);
    return int.tryParse(bytesMatch?.group(1) ?? '');
  }

  static String? _extractOptionalHrefFromHtml(String html) {
    final href = _extractAttributeFromHtml(html, 'href');
    if (href == null || href.trim().isEmpty) {
      return null;
    }
    return href;
  }

  /// Clean up color change HTML content to display clean text
  static String _cleanColorChangeContent(String htmlContent) {
    // Handle "Changed background color to <span...>" messages
    if (htmlContent.contains('Changed background color to')) {
      // Extract the color from the span's background style
      final colorRegex = RegExp(r'background:#([a-fA-F0-9]{6})');
      final colorMatch = colorRegex.firstMatch(htmlContent);

      if (colorMatch != null) {
        final colorHex = colorMatch.group(1)?.toUpperCase();
        return 'Changed background color to #$colorHex';
      } else {
        return 'Changed background color';
      }
    }

    // Handle "Reset background color" messages
    if (htmlContent.contains('Reset background color')) {
      return 'Reset background color';
    }

    // Fallback: strip all HTML tags
    return htmlContent.replaceAll(RegExp(r'<[^>]*>'), '');
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'message_id': messageId,
      'group_id': groupId,
      'sender_id': senderId,
      'sender': sender?.toJson(),
      'content': content,
      'message_type': messageType,
      'timestamp': timestamp,
      'timestamp_ms': timestampMs,
      'is_deleted': isDeleted,
      'file_url': fileUrl,
      'file_name': fileName,
      'file_size': fileSize,
      'file_type': fileType,
      'reply_to_id': replyToId,
      'reply_preview': replyPreview,
      'reactions': reactions,
      'caption': caption,
      'status': status,
    };
  }

  /// Format timestamp for display
  String get formattedTime {
    try {
      // debugPrint('🕐 [TIMESTAMP DEBUG] Raw timestamp: "$timestamp"');
      final dateTime = DateTime.parse(timestamp).toLocal();
      // debugPrint('🕐 [TIMESTAMP DEBUG] Parsed dateTime: $dateTime');
      final now = DateTime.now();
      // debugPrint('🕐 [TIMESTAMP DEBUG] Current time: $now');
      final difference = now.difference(dateTime);

      if (difference.inDays == 0) {
        if (StorageService.useMilitaryTime) {
          final hour = dateTime.hour.toString().padLeft(2, '0');
          final minute = dateTime.minute.toString().padLeft(2, '0');
          final result = '$hour:$minute';
          // debugPrint('🕐 [TIMESTAMP DEBUG] Formatted result: "$result"');
          return result;
        } else {
          final hour = dateTime.hour;
          final minute = dateTime.minute.toString().padLeft(2, '0');
          final period = hour >= 12 ? 'PM' : 'AM';
          final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
          final result = '$displayHour:$minute $period';
          // debugPrint('🕐 [TIMESTAMP DEBUG] Formatted result: "$result"');
          return result;
        }
      } else if (difference.inDays == 1) {
        return 'Yesterday';
      } else if (difference.inDays < 7) {
        return '${difference.inDays} days ago';
      } else {
        return '${dateTime.month}/${dateTime.day}/${dateTime.year}';
      }
    } catch (e) {
      // debugPrint(
      //   '🕐 [TIMESTAMP DEBUG] Error parsing timestamp "$timestamp": $e',
      // );
      return '';
    }
  }

  /// Format timestamp for full display with square brackets and timezone
  /// Format: [MM/DD/YYYY, HH:MM:SS GMT+offset]
  String get formattedTimestampFull {
    try {
      final dateTime = DateTime.parse(timestamp).toLocal();

      // Format date parts
      final month = dateTime.month.toString().padLeft(2, '0');
      final day = dateTime.day.toString().padLeft(2, '0');
      final year = dateTime.year;

      // Get timezone offset
      final offset = dateTime.timeZoneOffset;
      final offsetHours = offset.inHours.abs();
      final offsetSign = offset.isNegative ? '-' : '+';
      final second = dateTime.second.toString().padLeft(2, '0');

      if (StorageService.useMilitaryTime) {
        final hour = dateTime.hour.toString().padLeft(2, '0');
        final minute = dateTime.minute.toString().padLeft(2, '0');
        return '[$month/$day/$year, $hour:$minute:$second GMT$offsetSign$offsetHours]';
      } else {
        final hour = dateTime.hour;
        final minute = dateTime.minute.toString().padLeft(2, '0');
        final period = hour >= 12 ? 'PM' : 'AM';
        final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
        return '[$month/$day/$year, $displayHour:$minute:$second $period GMT$offsetSign$offsetHours]';
      }
    } catch (e) {
      debugPrint(
        '🕐 [GROUP TIMESTAMP DEBUG] Error parsing timestamp "$timestamp": $e',
      );
      return '';
    }
  }

  bool isSentByMe(int currentUserId) => senderId == currentUserId;
}

/// Simplified sender model for group messages
class GroupMessageSender {
  final int id;
  final String username;
  final String firstName;
  final String lastName;
  final String fullName;

  GroupMessageSender({
    required this.id,
    required this.username,
    required this.firstName,
    required this.lastName,
    required this.fullName,
  });

  factory GroupMessageSender.fromJson(Map<String, dynamic> json) {
    final firstName = json['first_name'] as String? ?? '';
    final lastName = json['last_name'] as String? ?? '';
    final username = json['username'] as String;

    // Build full name from first and last name, fallback to username
    String fullName;
    if (firstName.isNotEmpty && lastName.isNotEmpty) {
      fullName = '$firstName $lastName';
    } else if (firstName.isNotEmpty) {
      fullName = firstName;
    } else {
      fullName = username;
    }

    return GroupMessageSender(
      id: json['id'] as int,
      username: username,
      firstName: firstName.isNotEmpty ? firstName : username,
      lastName: lastName,
      fullName: json['full_name'] as String? ?? fullName,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'first_name': firstName,
      'last_name': lastName,
      'full_name': fullName,
    };
  }
}
