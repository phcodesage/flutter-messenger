/// Message model for chat messages
import '../services/storage_service.dart';

class Message {
  final int id;
  final int senderId;
  final int recipientId;
  final String content;
  final String messageType;
  final String timestamp;
  final int timestampMs;
  final bool isRead;
  final String? readAt;
  final int? readAtMs;
  final String? deliveredAt;
  final int? deliveredAtMs;
  final String status;
  final String threadId;
  final int? replyToId;
  final String? replyPreview;
  final Map<String, dynamic> reactions;
  final String? fileUrl;
  final String? fileName;
  final int? fileSize;
  final String? fileType;
  final bool isDeleted;
  final bool isTask;
  final String? taskCreatedAt;
  final String? taskCompletedAt;
  final bool isExcalidrawLink;
  final String? excalidrawPinnedAt;
  final bool isPinned;
  final String? pinnedAt;
  final int? pinnedByUserId;
  final String? caption;
  final double? duration;

  /// Local file path for optimistic media messages (before upload completes).
  /// Used to display the image/video from disk while the upload is in progress.
  /// Never persisted to JSON — only set on in-memory optimistic messages.
  final String? localFilePath;

  Message({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.content,
    required this.messageType,
    required this.timestamp,
    required this.timestampMs,
    required this.isRead,
    this.readAt,
    this.readAtMs,
    this.deliveredAt,
    this.deliveredAtMs,
    required this.status,
    required this.threadId,
    this.replyToId,
    this.replyPreview,
    required this.reactions,
    this.fileUrl,
    this.fileName,
    this.fileSize,
    this.fileType,
    required this.isDeleted,
    this.isTask = false,
    this.taskCreatedAt,
    this.taskCompletedAt,
    this.isExcalidrawLink = false,
    this.excalidrawPinnedAt,
    this.isPinned = false,
    this.pinnedAt,
    this.pinnedByUserId,
    this.caption,
    this.duration,
    this.localFilePath,
  });

  /// Returns a copy of this message with the given fields replaced.
  /// Only non-null arguments override the existing value, so this cannot be
  /// used to clear a field back to null (no use case needs that today).
  Message copyWith({
    int? id,
    int? senderId,
    int? recipientId,
    String? content,
    String? messageType,
    String? timestamp,
    int? timestampMs,
    bool? isRead,
    String? readAt,
    int? readAtMs,
    String? deliveredAt,
    int? deliveredAtMs,
    String? status,
    String? threadId,
    int? replyToId,
    String? replyPreview,
    Map<String, dynamic>? reactions,
    String? fileUrl,
    String? fileName,
    int? fileSize,
    String? fileType,
    bool? isDeleted,
    bool? isTask,
    String? taskCreatedAt,
    String? taskCompletedAt,
    bool? isExcalidrawLink,
    String? excalidrawPinnedAt,
    bool? isPinned,
    String? pinnedAt,
    int? pinnedByUserId,
    String? caption,
    String? localFilePath,
  }) {
    return Message(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      recipientId: recipientId ?? this.recipientId,
      content: content ?? this.content,
      messageType: messageType ?? this.messageType,
      timestamp: timestamp ?? this.timestamp,
      timestampMs: timestampMs ?? this.timestampMs,
      isRead: isRead ?? this.isRead,
      readAt: readAt ?? this.readAt,
      readAtMs: readAtMs ?? this.readAtMs,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      deliveredAtMs: deliveredAtMs ?? this.deliveredAtMs,
      status: status ?? this.status,
      threadId: threadId ?? this.threadId,
      replyToId: replyToId ?? this.replyToId,
      replyPreview: replyPreview ?? this.replyPreview,
      reactions: reactions ?? this.reactions,
      fileUrl: fileUrl ?? this.fileUrl,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      fileType: fileType ?? this.fileType,
      isDeleted: isDeleted ?? this.isDeleted,
      isTask: isTask ?? this.isTask,
      taskCreatedAt: taskCreatedAt ?? this.taskCreatedAt,
      taskCompletedAt: taskCompletedAt ?? this.taskCompletedAt,
      isExcalidrawLink: isExcalidrawLink ?? this.isExcalidrawLink,
      excalidrawPinnedAt: excalidrawPinnedAt ?? this.excalidrawPinnedAt,
      isPinned: isPinned ?? this.isPinned,
      pinnedAt: pinnedAt ?? this.pinnedAt,
      pinnedByUserId: pinnedByUserId ?? this.pinnedByUserId,
      caption: caption ?? this.caption,
      localFilePath: localFilePath ?? this.localFilePath,
    );
  }

  /// Parse reply_preview which can be String or Map from backend
  /// Also handles HTML content for file messages
  static String? _parseReplyPreview(dynamic value) {
    if (value == null) return null;

    String? rawContent;
    String? sender;

    if (value is String) {
      rawContent = value;
    } else if (value is Map) {
      sender = value['sender']?.toString() ?? value['sender_id']?.toString();
      rawContent =
          value['content']?.toString() ?? value['message']?.toString() ?? '';
      // For file/document replies, prefer the original filename so the preview
      // shows e.g. "report.gp" instead of an empty/generic "File".
      final messageType = value['message_type']?.toString() ?? '';
      final fileName = value['file_name']?.toString();
      if ((messageType == 'file' || messageType == 'document') &&
          fileName != null &&
          fileName.isNotEmpty) {
        rawContent = fileName;
      }
    }

    if (rawContent == null || rawContent.isEmpty) return null;

    // Detect file type from HTML and replace with emoji
    String cleanContent = rawContent;
    if (rawContent.contains('<audio') || rawContent.contains('audio/')) {
      cleanContent = '🎤 Voice message';
    } else if (rawContent.contains('<img') || rawContent.contains('image/')) {
      cleanContent = '📷 Photo';
    } else if (rawContent.contains('<video') || rawContent.contains('video/')) {
      cleanContent = '🎬 Video';
    } else if (rawContent.contains('<') && rawContent.contains('>')) {
      // Strip any other HTML tags
      cleanContent = rawContent.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      if (cleanContent.isEmpty) cleanContent = '📎 File';
    }

    // Only add sender prefix if we had a Map with sender info
    if (sender != null && sender.isNotEmpty) {
      return '$sender: $cleanContent';
    }
    return cleanContent;
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    // Helper to safely convert Map<dynamic, dynamic> to Map<String, dynamic>
    Map<String, dynamic> _safeReactionsMap(dynamic value) {
      if (value == null) return {};
      if (value is Map<String, dynamic>) return value;
      if (value is Map) {
        return Map<String, dynamic>.from(
          value.map((k, v) => MapEntry(k.toString(), v)),
        );
      }
      return {};
    }

    // Parse HTML content to extract file information
    String content = json['content'] as String;
    String messageType = (json['message_type'] as String?) ?? 'text';
    String? fileUrl = json['file_url'] as String?;
    String? fileName = json['file_name'] as String?;
    String? fileType = json['file_type'] as String?;
    int? fileSize = json['file_size'] as int?;
    String? caption = json['caption'] as String?;

    final rawTaskFlag = json['is_task'] as bool? ?? false;
    final inferredTaskFromType =
        messageType.toLowerCase() == 'task' ||
        messageType.toLowerCase() == 'todo';
    final isTaskMessage = rawTaskFlag || inferredTaskFromType;

    // Keep task messages on the text render path while preserving task state.
    if (inferredTaskFromType) {
      messageType = 'text';
    }

    final timestamp = json['timestamp'] as String;

    // If content contains HTML, parse it for file info and strip the raw HTML
    if (content.contains('<') && content.contains('>')) {
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
          String raw = captionMatch.group(1) ?? '';
          // Strip any nested tags and decode common HTML entities
          raw = raw.replaceAll(RegExp(r'<[^>]*>'), '').trim();
          raw = raw
              .replaceAll('&lt;', '<')
              .replaceAll('&gt;', '>')
              .replaceAll('&amp;', '&')
              .replaceAll('&quot;', '"')
              .replaceAll('&#39;', "'")
              .replaceAll('&nbsp;', ' ');
          if (raw.isNotEmpty) caption = raw;
        }
      }
      // Always replace raw HTML content with just the filename so it isn't rendered as text
      content = fileName ?? '';
    }

    return Message(
      id: json['id'] as int,
      senderId: json['sender_id'] as int,
      recipientId: json['recipient_id'] as int,
      content: content,
      messageType: messageType,
      timestamp: timestamp,
      timestampMs: json['timestamp_ms'] as int,
      isRead: json['is_read'] as bool,
      readAt: json['read_at'] as String?,
      readAtMs: json['read_at_ms'] as int?,
      deliveredAt: json['delivered_at'] as String?,
      deliveredAtMs: json['delivered_at_ms'] as int?,
      status: json['status'] as String,
      threadId: json['thread_id'] as String,
      replyToId: json['reply_to_id'] as int?,
      replyPreview: _parseReplyPreview(json['reply_preview']),
      reactions: _safeReactionsMap(json['reactions']),
      fileUrl: fileUrl,
      fileName: fileName,
      fileSize: fileSize,
      fileType: fileType,
      isDeleted: json['is_deleted'] as bool? ?? false,
      isTask: isTaskMessage,
      taskCreatedAt:
          json['task_created_at'] as String? ??
          (isTaskMessage ? timestamp : null),
      taskCompletedAt:
          json['task_completed_at'] as String? ??
          json['completed_at'] as String?,
      isExcalidrawLink: json['is_excalidraw_link'] as bool? ?? false,
      excalidrawPinnedAt: json['excalidraw_pinned_at'] as String?,
      isPinned: json['is_pinned'] as bool? ?? false,
      pinnedAt: json['pinned_at'] as String?,
      pinnedByUserId: json['pinned_by_user_id'] as int?,
      caption: caption,
      duration: (json['duration'] as num?)?.toDouble(),
    );
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

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender_id': senderId,
      'recipient_id': recipientId,
      'content': content,
      'message_type': messageType,
      'timestamp': timestamp,
      'timestamp_ms': timestampMs,
      'is_read': isRead,
      'read_at': readAt,
      'read_at_ms': readAtMs,
      'delivered_at': deliveredAt,
      'delivered_at_ms': deliveredAtMs,
      'status': status,
      'thread_id': threadId,
      'reply_to_id': replyToId,
      'reply_preview': replyPreview,
      'reactions': reactions,
      'file_url': fileUrl,
      'file_name': fileName,
      'file_size': fileSize,
      'file_type': fileType,
      'is_deleted': isDeleted,
      'is_task': isTask,
      'task_created_at': taskCreatedAt,
      'task_completed_at': taskCompletedAt,
      'is_excalidraw_link': isExcalidrawLink,
      'excalidraw_pinned_at': excalidrawPinnedAt,
      'is_pinned': isPinned,
      'pinned_at': pinnedAt,
      'pinned_by_user_id': pinnedByUserId,
      'caption': caption,
    };
  }

  /// Parse a timestamp string, treating it as UTC if no timezone info is present
  static DateTime _parseUtcTimestamp(String ts) {
    final hasTimezone = RegExp(r'[zZ]|[+-]\d{2}:?\d{2}$').hasMatch(ts);
    final parsed = DateTime.parse(hasTimezone ? ts : '${ts}Z');
    return parsed.toLocal();
  }

  /// Format timestamp for display (short format for message bubbles)
  String get formattedTime {
    try {
      final dateTime = _parseUtcTimestamp(timestamp);
      final now = DateTime.now();
      final difference = now.difference(dateTime);

      if (difference.inDays == 0) {
        // Today - show time
        if (StorageService.useMilitaryTime) {
          final hour = dateTime.hour.toString().padLeft(2, '0');
          final minute = dateTime.minute.toString().padLeft(2, '0');
          return '$hour:$minute';
        } else {
          final hour = dateTime.hour;
          final minute = dateTime.minute.toString().padLeft(2, '0');
          final period = hour >= 12 ? 'PM' : 'AM';
          final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
          return '$displayHour:$minute $period';
        }
      } else if (difference.inDays == 1) {
        return 'Yesterday';
      } else if (difference.inDays < 7) {
        return '${difference.inDays} days ago';
      } else {
        return '${dateTime.month}/${dateTime.day}/${dateTime.year}';
      }
    } catch (e) {
      return '';
    }
  }

  /// Format timestamp for full display with square brackets and timezone
  /// Format: [MM/DD/YYYY, HH:MM:SS GMT+offset]
  String get formattedTimestampFull {
    try {
      final dateTime = _parseUtcTimestamp(timestamp);

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
      return '';
    }
  }

  /// Check if message is sent by current user
  bool isSentByMe(int currentUserId) {
    return senderId == currentUserId;
  }
}
