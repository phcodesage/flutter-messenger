import 'package:flutter/material.dart';
import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import '../models/lobby_user.dart';
import '../models/message.dart';
import '../services/message_service.dart';
import '../services/socket_service.dart';
import '../services/storage_service.dart';
import '../widgets/color_picker_modal.dart';

/// Chat screen for messaging with a specific user
class ChatScreen extends StatefulWidget {
  final LobbyUser otherUser;
  
  const ChatScreen({super.key, required this.otherUser});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final SocketService _socketService = SocketService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final FocusNode _inputFocusNode = FocusNode();
  
  List<Message> _messages = [];
  bool _isLoading = true;
  bool _isTyping = false;
  bool _isKeyboardVisible = false;
  bool _otherUserTyping = false;
  String _typingPreview = '';
  int? _currentUserId;
  Timer? _typingTimer;
  Timer? _typingUpdateThrottle;
  DateTime? _lastTypingUpdate;
  Color _headerColor = const Color(0xFF1E1E1E); // Default dark color
  bool _showResetButton = false;

  @override
  void initState() {
    super.initState();
    _inputFocusNode.addListener(_onFocusChange);
    _initialize();
  }

  void _onFocusChange() {
    // Only update if keyboard visibility actually changed
    final isVisible = _inputFocusNode.hasFocus;
    if (_isKeyboardVisible != isVisible) {
      setState(() {
        _isKeyboardVisible = isVisible;
      });
    }
  }

  Future<void> _initialize() async {
    _currentUserId = await StorageService.getUserId();
    await _loadMessages();
    _joinChatRoom();
    _setupRealtimeListeners();
  }

  void _joinChatRoom() {
    // Test connection status first
    _socketService.testConnection();
    
    // Try to join chat room
    _socketService.joinChat(widget.otherUser.id);
  }

  void _setupRealtimeListeners() {
    // Listen for new messages
    _socketService.onMessageReceived = (data) {
      final message = Message.fromJson(data);
      
      // Only add if it's from the current conversation
      if (message.senderId == widget.otherUser.id || 
          message.recipientId == widget.otherUser.id) {
        setState(() {
          _messages.insert(0, message);
          // Clear typing preview when message is received
          _otherUserTyping = false;
          _typingPreview = '';
        });
        
        // Play message sound for incoming messages
        if (message.senderId == widget.otherUser.id) {
          try {
            _audioPlayer.play(AssetSource('sounds/splat2.m4a'));
          } catch (e) {
            debugPrint('Error playing message sound: $e');
          }
        }
        
        // Confirm delivery and read
        _socketService.confirmDelivery(message.id);
        _socketService.confirmRead(message.id);
        
        // Mark as read via API
        MessageService.markAsRead(
          senderId: widget.otherUser.id,
          lastMessageId: message.id,
        );
        
        // Scroll to bottom
        _scrollToBottom();
      }
    };

    // Listen for typing indicator
    _socketService.onUserTyping = (data) {
      if (data['user_id'] == widget.otherUser.id) {
        setState(() {
          _otherUserTyping = data['is_typing'] ?? false;
          if (!_otherUserTyping) {
            _typingPreview = '';
          }
        });
      }
    };

    // Listen for live typing preview
    _socketService.onTypingUpdate = (data) {
      if (data['user_id'] == widget.otherUser.id || 
          data['sender_id'] == widget.otherUser.id) {
        final preview = data['message'] ?? '';
        setState(() {
          _otherUserTyping = preview.isNotEmpty;
          _typingPreview = preview;
        });
      }
    };

    // Listen for joined chat confirmation
    _socketService.onJoinedChat = (data) {
      debugPrint('Successfully joined chat with ${widget.otherUser.fullName}');
    };

    // Listen for doorbell rings
    _socketService.onDoorbellRing = (data) {
      if (data['sender_id'] == widget.otherUser.id) {
        _handleIncomingDoorbell(data);
      }
    };

    // Listen for color change events
    _socketService.onColorChanged = (data) {
      if (data['sender_id'] == widget.otherUser.id) {
        _handleColorChange(data);
      }
    };

    // Listen for color reset events
    _socketService.onColorReset = (data) {
      if (data['sender_id'] == widget.otherUser.id) {
        _handleColorReset(data);
      }
    };

    // Listen for all messages deleted event
    _socketService.onAllMessagesDeleted = (data) {
      _handleAllMessagesDeleted(data);
    };
  }

  void _handleColorChange(Map<String, dynamic> data) {
    final colorHex = data['color'] as String?;
    final senderName = data['sender_name'] ?? widget.otherUser.fullName;
    
    if (colorHex != null) {
      try {
        // Parse hex color (e.g., "#FF5733" or "FF5733")
        final hexColor = colorHex.replaceAll('#', '');
        final color = Color(int.parse('FF$hexColor', radix: 16));
        
        setState(() {
          _headerColor = color;
          _showResetButton = true;
        });
        
        // Create incoming system message about color change
        final colorMessage = Message(
          id: DateTime.now().millisecondsSinceEpoch,
          senderId: widget.otherUser.id,
          recipientId: _currentUserId!,
          content: '$senderName changed your bg color to $colorHex',
          messageType: 'system',
          timestamp: DateTime.now().toIso8601String(),
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          isRead: true,
          status: 'delivered',
          threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
          reactions: {},
          isDeleted: false,
        );

        setState(() {
          _messages.insert(0, colorMessage);
        });

        // Scroll to bottom to show the message
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom();
        });
        
        debugPrint('🎨 Color changed to: $colorHex');
      } catch (e) {
        debugPrint('Error parsing color: $e');
      }
    }
  }

  void _handleColorReset(Map<String, dynamic> data) {
    final senderName = data['sender_name'] ?? widget.otherUser.fullName;
    
    // Reset header color to default
    const defaultColor = Color(0xFF1E1E1E);
    
    setState(() {
      _headerColor = defaultColor;
      _showResetButton = false;
    });
    
    // Create incoming system message about color reset
    final resetMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch,
      senderId: widget.otherUser.id,
      recipientId: _currentUserId!,
      content: '$senderName reset your bg color',
      messageType: 'system',
      timestamp: DateTime.now().toIso8601String(),
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      isRead: true,
      status: 'delivered',
      threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
      reactions: {},
      isDeleted: false,
    );

    setState(() {
      _messages.insert(0, resetMessage);
    });

    // Scroll to bottom to show the notification
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
    
    debugPrint('🔄 Color reset by ${widget.otherUser.fullName}');
  }

  void _handleIncomingDoorbell(Map<String, dynamic> data) {
    final senderName = data['sender_name'] ?? widget.otherUser.fullName;
    final timestampMs = data['timestamp_ms'] as int;
    
    // Check if we already have this doorbell notification to prevent duplicates
    final alreadyExists = _messages.any((msg) => 
      msg.messageType == 'system' && 
      msg.timestampMs == timestampMs &&
      msg.content.contains('sent a notification')
    );
    
    if (alreadyExists) {
      debugPrint('Doorbell notification already exists, skipping duplicate');
      return;
    }
    
    // Play doorbell notification sound
    try {
      _audioPlayer.play(AssetSource('sounds/notif-sound.wav'));
    } catch (e) {
      debugPrint('Error playing doorbell sound: $e');
    }
    
    // Create incoming notification message
    final doorbellMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch,
      senderId: widget.otherUser.id,
      recipientId: _currentUserId!,
      content: '$senderName sent a notification',
      messageType: 'system',
      timestamp: DateTime.now().toIso8601String(),
      timestampMs: timestampMs,
      isRead: true,
      status: 'delivered',
      threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
      reactions: {},
      isDeleted: false,
    );

    setState(() {
      _messages.insert(0, doorbellMessage);
    });

    // Scroll to bottom to show the notification
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  void _handleAllMessagesDeleted(Map<String, dynamic> data) {
    debugPrint('🗑️ Handling all messages deleted event: $data');
    
    final String deletedRoom = data['room'] ?? '';
    
    // Validate room ID
    if (deletedRoom.isEmpty) {
      debugPrint('⚠️ Warning: Received delete event with no room ID');
      return;
    }
    
    // Generate current room ID (same format as backend: chat_{userId1}_{userId2} sorted)
    if (_currentUserId == null) {
      debugPrint('⚠️ Warning: Current user ID is null');
      return;
    }
    
    final List<int> userIds = [_currentUserId!, widget.otherUser.id];
    userIds.sort();
    final currentRoomId = 'chat_${userIds[0]}_${userIds[1]}';
    
    // Only clear messages if the event is for the current room
    if (deletedRoom != currentRoomId) {
      debugPrint('ℹ️ Ignoring delete event for different room: $deletedRoom (current: $currentRoomId)');
      return;
    }
    
    // Clear all messages
    setState(() {
      _messages.clear();
    });

    // Show a snackbar notification
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All messages have been deleted'),
          duration: Duration(seconds: 3),
          backgroundColor: Colors.orange,
        ),
      );
    }

    debugPrint('✅ Messages cleared for room: $currentRoomId');
  }

  Future<void> _loadMessages() async {
    setState(() => _isLoading = true);
    try {
      final messages = await MessageService.getConversationMessages(
        userId: widget.otherUser.id,
        limit: 50,
      );
      setState(() {
        _messages = messages.reversed.toList(); // Reverse to show newest at bottom
        _isLoading = false;
      });
      
      // Mark all as read
      if (messages.isNotEmpty) {
        await MessageService.markAsRead(
          senderId: widget.otherUser.id,
          lastMessageId: messages.first.id,
        );
      }
      
      _scrollToBottom();
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading messages: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      // For reverse list, scroll to 0 (which is the bottom)
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _sendMessage() {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;

    // Send via Socket.IO for real-time delivery
    _socketService.sendMessage(
      recipientId: widget.otherUser.id,
      content: content,
      messageType: 'text',
    );

    // Create optimistic message for immediate UI update
    final optimisticMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch, // Temporary ID
      senderId: _currentUserId!,
      recipientId: widget.otherUser.id,
      content: content,
      messageType: 'text',
      timestamp: DateTime.now().toIso8601String(),
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      isRead: false,
      status: 'sending',
      threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
      reactions: {},
      isDeleted: false,
    );

    setState(() {
      _messages.insert(0, optimisticMessage);
    });

    // Play message sound when sending
    try {
      _audioPlayer.play(AssetSource('sounds/splat2.m4a'));
    } catch (e) {
      debugPrint('Error playing message sound: $e');
    }

    _messageController.clear();
    _stopTyping();
    
    // Scroll to bottom immediately after sending
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  void _onTextChanged(String text) {
    if (text.isEmpty) {
      if (_isTyping) {
        _stopTyping();
      }
      return;
    }

    // Only update typing state if not already typing
    if (!_isTyping) {
      _startTyping();
    }
    
    // Send live preview (throttled) - no setState here
    _sendTypingUpdate(text);
    
    // Reset typing timer
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), () {
      if (_isTyping) {
        _stopTyping();
      }
    });
  }

  void _sendTypingUpdate(String text) {
    // Throttle typing updates to avoid spamming
    final now = DateTime.now();
    if (_lastTypingUpdate != null) {
      final diff = now.difference(_lastTypingUpdate!);
      if (diff.inMilliseconds < 500) {
        // Too soon, schedule for later
        _typingUpdateThrottle?.cancel();
        _typingUpdateThrottle = Timer(const Duration(milliseconds: 500), () {
          _socketService.sendTypingUpdate(widget.otherUser.id, text);
          _lastTypingUpdate = DateTime.now();
        });
        return;
      }
    }

    // Send immediately
    _socketService.sendTypingUpdate(widget.otherUser.id, text);
    _lastTypingUpdate = now;
  }

  void _startTyping() {
    if (mounted) {
      setState(() => _isTyping = true);
    }
    _socketService.startTyping(widget.otherUser.id);
  }

  void _stopTyping() {
    if (mounted) {
      setState(() => _isTyping = false);
    }
    _socketService.stopTyping(widget.otherUser.id);
    _typingTimer?.cancel();
  }

  void _resetColor() {
    // Reset to default color
    const defaultColor = Color(0xFF1E1E1E);
    
    setState(() {
      _headerColor = defaultColor;
      _showResetButton = false;
    });
    
    // Emit reset color event
    _socketService.emit('change_color', {
      'recipient_id': widget.otherUser.id,
      'color': '#1E1E1E',
      'sender_name': 'You',
    });
    
    // Add outgoing message about reset
    final resetMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch,
      senderId: _currentUserId!,
      recipientId: widget.otherUser.id,
      content: 'Reset bg color',
      messageType: 'system',
      timestamp: DateTime.now().toIso8601String(),
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      isRead: false,
      status: 'sent',
      threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
      reactions: {},
      isDeleted: false,
    );

    setState(() {
      _messages.insert(0, resetMessage);
    });

    // Scroll to bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
    
    debugPrint('🎨 Color reset to default');
  }

  void _changeColor() {
    // Show full-screen color picker modal
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ColorPickerModal(
        onColorSelected: (selectedColor) {
          // Only send color to other user, don't change our own background
          final colorHex = selectedColor.value.toRadixString(16).substring(2).toUpperCase();
          _socketService.emit('change_color', {
            'recipient_id': widget.otherUser.id,
            'color': '#$colorHex',
            'sender_name': 'You',
          });
          
          // Add outgoing system message to show we changed their color
          final colorMessage = Message(
            id: DateTime.now().millisecondsSinceEpoch,
            senderId: _currentUserId!,
            recipientId: widget.otherUser.id,
            content: 'Changed bg color',
            messageType: 'system',
            timestamp: DateTime.now().toIso8601String(),
            timestampMs: DateTime.now().millisecondsSinceEpoch,
            isRead: false,
            status: 'sent',
            threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
            reactions: {},
            isDeleted: false,
          );

          setState(() {
            _messages.insert(0, colorMessage);
          });

          // Scroll to bottom to show the message
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToBottom();
          });
          
          debugPrint('🎨 Color sent to ${widget.otherUser.fullName}: #$colorHex');
        },
      ),
    );
  }

  void _ringDoorbell() {
    // Send doorbell via Socket.IO
    _socketService.ringDoorbell(widget.otherUser.id);
    
    // Play doorbell notification sound
    try {
      _audioPlayer.play(AssetSource('sounds/notif-sound.wav'));
    } catch (e) {
      debugPrint('Error playing doorbell sound: $e');
    }
    
    // Create a system message in chat to show doorbell was sent
    final doorbellMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch,
      senderId: _currentUserId!,
      recipientId: widget.otherUser.id,
      content: 'Sent a notification',
      messageType: 'system',
      timestamp: DateTime.now().toIso8601String(),
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      isRead: false,
      status: 'sent',
      threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
      reactions: {},
      isDeleted: false,
    );

    setState(() {
      _messages.insert(0, doorbellMessage);
    });

    // Scroll to bottom to show the notification message
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    _inputFocusNode.dispose();
    _typingTimer?.cancel();
    _typingUpdateThrottle?.cancel();
    
    // Send typing stop without setState (widget is being disposed)
    _socketService.stopTyping(widget.otherUser.id);
    
    // Leave chat room
    _socketService.leaveChat(widget.otherUser.id);
    
    // Clear callbacks
    _socketService.onMessageReceived = null;
    _socketService.onUserTyping = null;
    _socketService.onTypingUpdate = null;
    _socketService.onJoinedChat = null;
    _socketService.onDoorbellRing = null;
    _socketService.onColorChanged = null;
    
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: _headerColor,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: _getAvatarColor(),
              child: Text(
                widget.otherUser.initials,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.otherUser.fullName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _otherUserTyping
                        ? 'typing...'
                        : (widget.otherUser.isOnline ? 'online' : 'offline'),
                    style: TextStyle(
                      color: _otherUserTyping
                          ? const Color(0xFF4CAF50)
                          : (widget.otherUser.isOnline
                              ? const Color(0xFF4CAF50)
                              : Colors.grey[600]),
                      fontSize: 12,
                      fontStyle: _otherUserTyping ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: const [],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // Messages list
              Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey[700]),
                            const SizedBox(height: 16),
                            Text(
                              'No messages yet',
                              style: TextStyle(color: Colors.grey[600], fontSize: 16),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Send a message to start the conversation',
                              style: TextStyle(color: Colors.grey[700], fontSize: 14),
                            ),
                          ],
                        ),
                      )
                    : RepaintBoundary(
                        child: ListView.builder(
                          controller: _scrollController,
                          reverse: true,
                          padding: const EdgeInsets.all(16),
                          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                          cacheExtent: 500,
                          itemCount: _messages.length,
                          addAutomaticKeepAlives: true,
                          addRepaintBoundaries: true,
                          itemBuilder: (context, index) {
                            final message = _messages[index];
                            final isSentByMe = message.senderId == _currentUserId;
                            return _buildMessageBubble(message, isSentByMe);
                          },
                        ),
                      ),
          ),
          // Typing preview - pinned at bottom, always visible
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            height: (_otherUserTyping && _typingPreview.isNotEmpty) ? null : 0,
            padding: (_otherUserTyping && _typingPreview.isNotEmpty)
                ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
                : EdgeInsets.zero,
            decoration: const BoxDecoration(
              color: Color(0xFF1A1A1A),
              border: Border(
                top: BorderSide(color: Color(0xFF3D3D3D), width: 1),
              ),
            ),
            child: (_otherUserTyping && _typingPreview.isNotEmpty)
                ? RepaintBoundary(child: _buildTypingPreviewBubble())
                : const SizedBox.shrink(),
          ),
          // Message input
          RepaintBoundary(
            child: Container(
              padding: EdgeInsets.only(
                left: 12,
                right: 12,
                top: 12,
                bottom: 12 + MediaQuery.of(context).viewInsets.bottom,
              ),
              decoration: const BoxDecoration(
                color: Color(0xFF2D2D2D),
                border: Border(
                  top: BorderSide(color: Color(0xFF3D3D3D), width: 1),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                // Text input field - full width, max 3 lines
                RepaintBoundary(
                  child: TextField(
                    key: const ValueKey('message_input'),
                    controller: _messageController,
                    focusNode: _inputFocusNode,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Type a message...',
                      hintStyle: TextStyle(color: Colors.grey[600]),
                      filled: true,
                      fillColor: const Color(0xFF1A1A1A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                    ),
                    onChanged: _onTextChanged,
                    onSubmitted: (_) => _sendMessage(),
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.send,
                    keyboardType: TextInputType.text,
                    textCapitalization: TextCapitalization.sentences,
                    enableInteractiveSelection: true,
                    autocorrect: true,
                    enableSuggestions: true,
                    scribbleEnabled: false,
                  ),
                ),
                const SizedBox(height: 8),
                // Primary buttons row - aligned to the right
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // Clear button
                    ElevatedButton(
                      onPressed: () {
                        _messageController.clear();
                        _stopTyping();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFEF4444), // rgb(239 68 68)
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text('Clear'),
                    ),
                    const SizedBox(width: 8),
                    // Send button
                    ElevatedButton(
                      onPressed: _sendMessage,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6D28D9), // rgb(109 40 217)
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text('Send'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Action buttons - Grid layout (hidden when typing)
                if (_messageController.text.isEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                    // Ring Doorbell
                    ElevatedButton(
                      onPressed: _ringDoorbell,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8B5CF6), // Violet
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      child: const Text('Ring Doorbell'),
                    ),
                    // Change Color
                    ElevatedButton(
                      onPressed: _changeColor,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFA855F7), // Purple
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      child: const Text('Change Color'),
                    ),
                    // Reset Color button (only show when color has been changed)
                    if (_showResetButton)
                      ElevatedButton(
                        onPressed: _resetColor,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black87,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                        child: const Text('Reset Color'),
                      ),
                    // Send File
                    ElevatedButton(
                      onPressed: () {
                        // TODO: Implement send file
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Send File - Coming soon!')),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981), // Green
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      child: const Text('Send File'),
                    ),
                    // Record Voice Message
                    ElevatedButton(
                      onPressed: () {
                        // TODO: Implement record voice
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Record Voice Message - Coming soon!')),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFEF4444), // Red
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      child: const Text('Record Voice Message'),
                    ),
                    // Show Timestamps
                    ElevatedButton(
                      onPressed: () {
                        // TODO: Implement show timestamps
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Show Timestamps - Coming soon!')),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8B5CF6), // Purple
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      child: const Text('Show Timestamps'),
                    ),
                    // Export Chat
                    ElevatedButton(
                      onPressed: () {
                        // TODO: Implement export chat
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Export Chat - Coming soon!')),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6B7280), // Gray
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      child: const Text('Export Chat'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTypingPreviewBubble() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFFA32CC4), // Purple color for typing preview
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _typingPreview,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(Message message, bool isSentByMe) {
    return Align(
      alignment: isSentByMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: isSentByMe ? const Color(0xFF420796) : const Color(0xFF3944BC),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isSentByMe ? 16 : 4),
            bottomRight: Radius.circular(isSentByMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.content,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message.formattedTime,
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 11,
                  ),
                ),
                if (isSentByMe) ...[
                  const SizedBox(width: 4),
                  Icon(
                    message.isRead
                        ? Icons.done_all
                        : (message.status == 'delivered'
                            ? Icons.done_all
                            : Icons.done),
                    size: 14,
                    color: message.isRead ? const Color(0xFF4CAF50) : Colors.grey[400],
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _getAvatarColor() {
    const colors = [
      Color(0xFFE91E63),
      Color(0xFF9C27B0),
      Color(0xFF673AB7),
      Color(0xFF3F51B5),
      Color(0xFF2196F3),
      Color(0xFF00BCD4),
      Color(0xFF009688),
      Color(0xFF4CAF50),
      Color(0xFFFF9800),
      Color(0xFFFF5722),
    ];
    return colors[widget.otherUser.avatarColorIndex % colors.length];
  }
}
