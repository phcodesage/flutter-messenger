import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'dart:async';

/// Service for handling Socket.IO real-time communication
class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  IO.Socket? _socket;
  String? _authToken;
  int? _currentUserId;

  // Callbacks for events
  Function(Map<String, dynamic>)? onMessageReceived;
  Function(Map<String, dynamic>)? onDoorbellRing;
  Function(Map<String, dynamic>)? onUserTyping;
  Function(Map<String, dynamic>)? onTypingUpdate;
  Function(Map<String, dynamic>)? onPresenceUpdate;
  Function(Map<String, dynamic>)? onJoinedChat;
  Function(Map<String, dynamic>)? onLeftChat;
  Function(Map<String, dynamic>)? onMessageDelivered;
  Function(Map<String, dynamic>)? onMessageRead;
  Function(Map<String, dynamic>)? onColorChanged;
  Function(Map<String, dynamic>)? onColorReset;

  bool get isConnected => _socket?.connected ?? false;
  int? get currentUserId => _currentUserId;
  
  /// Test connection status
  void testConnection() {
    debugPrint('=== Socket Connection Test ===');
    debugPrint('Socket exists: ${_socket != null}');
    debugPrint('Socket connected: ${_socket?.connected ?? false}');
    debugPrint('Socket ID: ${_socket?.id ?? "null"}');
    debugPrint('Auth token exists: ${_authToken != null}');
    debugPrint('Current user ID: $_currentUserId');
    debugPrint('============================');
  }

  /// Initialize and connect to Socket.IO server
  void initialize(String token, int userId) {
    _authToken = token;
    _currentUserId = userId;
    _connect();
  }

  void _connect() {
    if (_socket != null && _socket!.connected) {
      debugPrint('Socket already connected');
      return;
    }

    // Use the same base URL as the API
    const serverUrl = 'https://dev.flask-meet.site';

    debugPrint('=== Attempting Socket.IO Connection ===');
    debugPrint('Server URL: $serverUrl');
    debugPrint('Token length: ${_authToken?.length ?? 0}');
    debugPrint('User ID: $_currentUserId');

    try {
      // Use older configuration style for better compatibility
      _socket = IO.io(
        serverUrl,
        <String, dynamic>{
          'transports': ['websocket', 'polling'],
          'autoConnect': true,
          'query': {
            'token': _authToken,
          },
          'extraHeaders': {
            'Authorization': 'Bearer $_authToken',
          },
        },
      );

      debugPrint('Socket.IO client created');
      _setupEventListeners();
      
      // Manually connect if not auto-connecting
      if (!(_socket?.connected ?? false)) {
        debugPrint('Manually connecting socket...');
        _socket?.connect();
      }
      
      // Test connection after a short delay
      Future.delayed(const Duration(seconds: 2), () {
        testConnection();
      });
    } catch (e) {
      debugPrint('❌ Error creating socket: $e');
    }
  }

  void _setupEventListeners() {
    if (_socket == null) return;

    // Connection events
    _socket!.on('connect', (_) {
      debugPrint('✅ Socket connected - ID: ${_socket!.id}');
      // Join user's personal room for direct notifications
      if (_currentUserId != null) {
        debugPrint('Joining personal room: user_$_currentUserId');
        _socket!.emit('join_room', {'room': 'user_$_currentUserId'});
      }
    });

    _socket!.on('disconnect', (reason) {
      debugPrint('❌ Socket disconnected - Reason: $reason');
    });

    _socket!.on('connect_error', (error) {
      debugPrint('⚠️ Connection error: $error');
    });

    _socket!.on('error', (error) {
      debugPrint('⚠️ Socket error: $error');
    });

    _socket!.on('reconnect', (attemptNumber) {
      debugPrint('🔄 Socket reconnected after $attemptNumber attempts');
    });

    _socket!.on('reconnect_attempt', (attemptNumber) {
      debugPrint('🔄 Reconnection attempt #$attemptNumber');
    });

    _socket!.on('reconnect_error', (error) {
      debugPrint('⚠️ Reconnection error: $error');
    });

    _socket!.on('reconnect_failed', (_) {
      debugPrint('❌ Reconnection failed');
    });

    // Chat room events
    _socket!.on('joined_chat', (data) {
      debugPrint('📥 Joined chat: $data');
      onJoinedChat?.call(data as Map<String, dynamic>);
    });

    _socket!.on('left_chat', (data) {
      debugPrint('📤 Left chat: $data');
      onLeftChat?.call(data as Map<String, dynamic>);
    });

    // Message events
    _socket!.on('new_message', (data) {
      debugPrint('💬 New message: $data');
      onMessageReceived?.call(data as Map<String, dynamic>);
    });

    // Doorbell event
    _socket!.on('doorbell', (data) {
      debugPrint('🔔 Doorbell ring: $data');
      onDoorbellRing?.call(data as Map<String, dynamic>);
    });

    // Typing events
    _socket!.on('user_typing', (data) {
      debugPrint('⌨️ User typing: $data');
      onUserTyping?.call(data as Map<String, dynamic>);
    });

    _socket!.on('typing_update', (data) {
      debugPrint('📝 Typing update: $data');
      onTypingUpdate?.call(data as Map<String, dynamic>);
    });

    // Presence events
    _socket!.on('presence_update', (data) {
      debugPrint('👤 Presence update: $data');
      onPresenceUpdate?.call(data as Map<String, dynamic>);
    });

    // Color change event
    _socket!.on('color_changed', (data) {
      debugPrint('🎨 Color changed: $data');
      onColorChanged?.call(data as Map<String, dynamic>);
    });

    // Color reset event
    _socket!.on('color_reset', (data) {
      debugPrint('🔄 Color reset: $data');
      onColorReset?.call(data as Map<String, dynamic>);
    });

    // Message delivery confirmation
    _socket!.on('message_delivered', (data) {
      debugPrint('✓ Message delivered: $data');
      onMessageDelivered?.call(data as Map<String, dynamic>);
    });

    // Message read confirmation
    _socket!.on('message_read', (data) {
      debugPrint('✓✓ Message read: $data');
      onMessageRead?.call(data as Map<String, dynamic>);
    });
  }

  /// Disconnect from Socket.IO server
  void disconnect() {
    debugPrint('Disconnecting socket...');
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _authToken = null;
    _currentUserId = null;
  }

  /// Emit an event to the server
  void emit(String event, dynamic data) {
    if (_socket?.connected ?? false) {
      debugPrint('📤 Emitting $event: $data');
      _socket!.emit(event, data);
    } else {
      debugPrint('⚠️ Cannot emit $event - socket not connected');
    }
  }

  /// Join a chat room with another user
  void joinChat(int userId) {
    emit('join_chat', {'user_id': userId});
  }

  /// Leave a chat room with another user
  void leaveChat(int userId) {
    emit('leave_chat', {'user_id': userId});
  }

  /// Send a message via Socket.IO
  void sendMessage({
    required int recipientId,
    required String content,
    String messageType = 'text',
    int? replyToId,
  }) {
    emit('send_message', {
      'recipient_id': recipientId,
      'content': content,
      'message_type': messageType,
      if (replyToId != null) 'reply_to_id': replyToId,
    });
  }

  /// Ring doorbell to get someone's attention
  void ringDoorbell(int recipientId) {
    emit('ring_doorbell', {'recipient_id': recipientId});
  }

  /// Start typing indicator
  void startTyping(int recipientId) {
    emit('typing_start', {'recipient_id': recipientId});
  }

  /// Stop typing indicator
  void stopTyping(int recipientId) {
    emit('typing_stop', {'recipient_id': recipientId});
  }

  /// Send typing update with message preview
  void sendTypingUpdate(int recipientId, String message) {
    final preview = message.length > 120 ? message.substring(0, 120) : message;
    emit('typing_update', {
      'recipient_id': recipientId,
      'message': preview,
    });
  }

  /// Confirm message delivery
  void confirmDelivery(int messageId) {
    emit('confirm_delivery', {'message_id': messageId});
  }

  /// Confirm message read
  void confirmRead(int messageId) {
    emit('confirm_read', {'message_id': messageId});
  }

  /// Clear all callbacks
  void clearCallbacks() {
    onMessageReceived = null;
    onDoorbellRing = null;
    onUserTyping = null;
    onTypingUpdate = null;
    onPresenceUpdate = null;
    onJoinedChat = null;
    onLeftChat = null;
    onMessageDelivered = null;
    onMessageRead = null;
    onColorChanged = null;
  }
}
