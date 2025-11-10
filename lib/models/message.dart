/// Message model for chat messages
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
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] as int,
      senderId: json['sender_id'] as int,
      recipientId: json['recipient_id'] as int,
      content: json['content'] as String,
      messageType: json['message_type'] as String,
      timestamp: json['timestamp'] as String,
      timestampMs: json['timestamp_ms'] as int,
      isRead: json['is_read'] as bool,
      readAt: json['read_at'] as String?,
      readAtMs: json['read_at_ms'] as int?,
      deliveredAt: json['delivered_at'] as String?,
      deliveredAtMs: json['delivered_at_ms'] as int?,
      status: json['status'] as String,
      threadId: json['thread_id'] as String,
      replyToId: json['reply_to_id'] as int?,
      replyPreview: json['reply_preview'] as String?,
      reactions: json['reactions'] as Map<String, dynamic>? ?? {},
      fileUrl: json['file_url'] as String?,
      fileName: json['file_name'] as String?,
      fileSize: json['file_size'] as int?,
      fileType: json['file_type'] as String?,
      isDeleted: json['is_deleted'] as bool? ?? false,
    );
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
    };
  }

  /// Format timestamp for display
  String get formattedTime {
    try {
      final dateTime = DateTime.parse(timestamp);
      final now = DateTime.now();
      final difference = now.difference(dateTime);

      if (difference.inDays == 0) {
        // Today - show time
        final hour = dateTime.hour;
        final minute = dateTime.minute.toString().padLeft(2, '0');
        final period = hour >= 12 ? 'PM' : 'AM';
        final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
        return '$displayHour:$minute $period';
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

  /// Check if message is sent by current user
  bool isSentByMe(int currentUserId) {
    return senderId == currentUserId;
  }
}
