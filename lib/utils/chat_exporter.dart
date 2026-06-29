class ChatExporter {
  static String formatChatExport({
    required List<dynamic> messages,
    required int currentUserId,
    required String currentUserName,
    String? peerName,
  }) {
    final buffer = StringBuffer();
    // Header info
    buffer.writeln('========================================');
    buffer.writeln('Chat Export');
    buffer.writeln('Date: ${DateTime.now().toLocal().toString()}');
    if (peerName != null) {
      buffer.writeln('Conversation with: $peerName');
    }
    buffer.writeln('========================================\n');

    for (final msg in messages) {
      if (msg.isDeleted == true) continue;
      
      final timestamp = msg.timestamp ?? '';
      final senderId = msg.senderId ?? 0;
      
      // Resolve sender name
      String senderName = 'Unknown';
      if (senderId == 0 || msg.messageType == 'system') {
        senderName = 'System';
      } else if (senderId == currentUserId) {
        senderName = currentUserName;
      } else {
        if (peerName != null) {
          senderName = peerName;
        } else {
          // Dynamic inspection for group messages (where msg.sender is GroupMessageSender)
          dynamic dynamicMsg = msg;
          try {
            if (dynamicMsg.sender != null) {
              senderName = dynamicMsg.sender.fullName;
            } else {
              senderName = 'User #$senderId';
            }
          } catch (_) {
            senderName = 'User #$senderId';
          }
        }
      }
      
      final content = msg.content ?? '';
      
      String formattedTime = timestamp;
      try {
        final parsed = DateTime.parse(timestamp).toLocal();
        formattedTime = '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')} ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}:${parsed.second.toString().padLeft(2, '0')}';
      } catch (_) {}
      
      buffer.writeln('[$formattedTime] $senderName: $content');
      
      // If there's an attachment/file:
      if (msg.fileUrl != null && msg.fileUrl!.isNotEmpty) {
        buffer.writeln('    [Attachment] Name: ${msg.fileName ?? 'Unnamed'}, Type: ${msg.fileType ?? 'Unknown'}, URL: ${msg.fileUrl}');
      }
    }
    return buffer.toString();
  }
}
