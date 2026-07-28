import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'dart:async';
import '../config/api_config.dart';
import 'auth_error_handler.dart';
import 'socket_event_queue_service.dart';

/// Service for handling Socket.IO real-time communication.
/// Uses a multi-listener broadcast pattern so multiple screens
/// (and multiple devices logged into the same account) can all
/// receive the same events without overwriting each other.
class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  io.Socket? _socket;
  io.Socket? get socket => _socket;
  String? _authToken;
  int? _currentUserId;

  // ---------------------------------------------------------------------------
  // Multi-listener maps: each event type -> { listenerKey: callback }
  // ---------------------------------------------------------------------------
  final Map<String, Function(Map<String, dynamic>)> _messageReceivedListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)> _messageSentListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _doorbellRingListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _userTypingListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _typingUpdateListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _presenceUpdateListeners =
      {};
  final Map<String, Function(List<dynamic>)> _presenceSnapshotListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _joinedChatListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _leftChatListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _messageDeliveredListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)> _messageReadListeners = {};
  final Map<String, Function(Map<String, dynamic>)>
  _messageStatusUpdatedListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _messagesReadListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _unreadClearedListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _colorChangedListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _colorResetListeners = {};
  final Map<String, Function(Map<String, dynamic>)>
  _groupColorChangedListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _groupColorResetListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)>
  _allMessagesDeletedListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _fileReceivedListeners = {};
  final Map<String, Function(Map<String, dynamic>)>
  _voiceMessageReceivedListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _messageDeletedListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)> _messageEditedListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)> _taskAddedListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _taskCompletedListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)> _taskUncompletedListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)> _excalidrawPinnedListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)>
  _excalidrawUnpinnedListeners = {};

  /// Whiteboard directory changes (created / renamed / deleted). One channel
  /// for all three: every listener re-reads the list anyway.
  final Map<String, Function(Map<String, dynamic>)>
  _excalidrawRoomChangedListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _reactionUpdatedListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)> _reactionClearedListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)> _incomingCallListeners = {};
  final Map<String, Function(Map<String, dynamic>)>
  _crossRoomCallOfferListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _callInitiatedListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)> _callAnsweredListeners = {};
  final Map<String, Function(Map<String, dynamic>)>
  _callSessionStateListeners = {};
  final Map<String, Function(Map<String, dynamic>)>
  _callOfferStateSyncListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _callDeclinedListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _callEndedListeners = {};
  // Persistent call-log entries (declined / missed / answered) pushed by the
  // server as message_type='call' rows, for both DB and signaling calls.
  final Map<String, Function(Map<String, dynamic>)> _callLogMessageListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)>
  _connectionChangedListeners = {};
  final Map<String, Function()> _reconnectedListeners = {};
  final Map<String, Function(Map<String, dynamic>)>
  _screenShareStartedListeners = {};
  final Map<String, Function(Map<String, dynamic>)>
  _screenShareStoppedListeners = {};

  // Group chat listeners
  final Map<String, Function(Map<String, dynamic>)> _groupNewMessageListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)> _groupMessageSentListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)> _groupFileMessageListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)> _groupDoorbellListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)>
  _groupMessageDeletedListeners = {};
  final Map<String, Function(Map<String, dynamic>)>
  _groupMessageEditedListeners = {};
  final Map<String, Function(Map<String, dynamic>)>
  _groupReactionUpdatedListeners = {};
  final Map<String, Function(Map<String, dynamic>)>
  _groupReactionClearedListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _groupMemberLeftListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)>
  _groupMessageStatusUpdatedListeners = {};

  // Missing group management listeners
  final Map<String, Function(Map<String, dynamic>)> _groupCreatedListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _groupUpdatedListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _groupDeletedListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _groupMemberAddedListeners =
      {};
  final Map<String, Function(Map<String, dynamic>)> _groupTypingListeners = {};

  // AI chat realtime sync
  final Map<String, Function(Map<String, dynamic>)> _aiChatSyncListeners = {};

  // Group call listeners
  final Map<String, Function(Map<String, dynamic>)> _groupCallInvitationListeners = {};
  final Map<String, Function(Map<String, dynamic>)> _groupCallCancelledListeners = {};
  // Raw event listeners — used by GroupCallService for mesh events
  final Map<String, Map<String, Function(dynamic)>> _rawEventListeners = {};

  // ---------------------------------------------------------------------------
  // Keyed listener registration / removal helpers
  // ---------------------------------------------------------------------------

  void addRawListener(String event, String key, Function(dynamic) callback) {
    _rawEventListeners.putIfAbsent(event, () => {})[key] = callback;
  }

  void removeRawListener(String event, String key) {
    _rawEventListeners[event]?.remove(key);
  }

  void addListener(String event, String key, Function callback) {
    switch (event) {
      case 'messageReceived':
        _messageReceivedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'callLogMessage':
        _callLogMessageListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'messageSent':
        _messageSentListeners[key] = callback as Function(Map<String, dynamic>);
        break;
      case 'doorbellRing':
        _doorbellRingListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'userTyping':
        _userTypingListeners[key] = callback as Function(Map<String, dynamic>);
        break;
      case 'typingUpdate':
        _typingUpdateListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'presenceUpdate':
        _presenceUpdateListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'presenceSnapshot':
        _presenceSnapshotListeners[key] = callback as Function(List<dynamic>);
        break;
      case 'joinedChat':
        _joinedChatListeners[key] = callback as Function(Map<String, dynamic>);
        break;
      case 'leftChat':
        _leftChatListeners[key] = callback as Function(Map<String, dynamic>);
        break;
      case 'messageDelivered':
        _messageDeliveredListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'messageRead':
        _messageReadListeners[key] = callback as Function(Map<String, dynamic>);
        break;
      case 'messageStatusUpdated':
        _messageStatusUpdatedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'messagesRead':
        _messagesReadListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'unreadCleared':
        _unreadClearedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'colorChanged':
        _colorChangedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'colorReset':
        _colorResetListeners[key] = callback as Function(Map<String, dynamic>);
        break;
      case 'groupColorChanged':
        _groupColorChangedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupColorReset':
        _groupColorResetListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'allMessagesDeleted':
        _allMessagesDeletedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'fileReceived':
        _fileReceivedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'voiceMessageReceived':
        _voiceMessageReceivedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'messageDeleted':
        _messageDeletedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'messageEdited':
        _messageEditedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'taskAdded':
        _taskAddedListeners[key] = callback as Function(Map<String, dynamic>);
        break;
      case 'taskMarked':
        _taskAddedListeners[key] = callback as Function(Map<String, dynamic>);
        break;
      case 'taskCompleted':
        _taskCompletedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'taskUncompleted':
        _taskUncompletedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'excalidrawPinned':
        _excalidrawPinnedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'excalidrawUnpinned':
        _excalidrawUnpinnedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'excalidrawRoomChanged':
        _excalidrawRoomChangedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'reactionUpdated':
        _reactionUpdatedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'reactionCleared':
        _reactionClearedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'incomingCall':
        _incomingCallListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'crossRoomCallOffer':
        _crossRoomCallOfferListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'callInitiated':
        _callInitiatedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'callAnswered':
        _callAnsweredListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'callSessionState':
        _callSessionStateListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'callOfferStateSync':
        _callOfferStateSyncListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'callDeclined':
        _callDeclinedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'callEnded':
        _callEndedListeners[key] = callback as Function(Map<String, dynamic>);
        break;
      case 'connectionChanged':
        _connectionChangedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'reconnected':
        _reconnectedListeners[key] = callback as Function();
        break;
      case 'screenShareStarted':
        _screenShareStartedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'screenShareStopped':
        _screenShareStoppedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      // Group chat events
      case 'groupNewMessage':
        _groupNewMessageListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupMessageSent':
        _groupMessageSentListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupFileMessage':
        _groupFileMessageListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupDoorbell':
        _groupDoorbellListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupMessageDeleted':
        _groupMessageDeletedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupMessageEdited':
        _groupMessageEditedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupReactionUpdated':
        _groupReactionUpdatedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupReactionCleared':
        _groupReactionClearedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupMemberLeft':
        _groupMemberLeftListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupMessageStatusUpdated':
        _groupMessageStatusUpdatedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      // Group management events
      case 'groupCreated':
        _groupCreatedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupUpdated':
        _groupUpdatedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupDeleted':
        _groupDeletedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupMemberAdded':
        _groupMemberAddedListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupTyping':
        _groupTypingListeners[key] = callback as Function(Map<String, dynamic>);
        break;
      case 'aiChatSync':
        _aiChatSyncListeners[key] = callback as Function(Map<String, dynamic>);
        break;
      case 'test_response':
        // Add test_response listeners to group new message listeners for now
        _groupNewMessageListeners[key] =
            callback as Function(Map<String, dynamic>);
        break;
      case 'groupCallInvitation':
        _groupCallInvitationListeners[key] = callback as Function(Map<String, dynamic>);
        break;
      case 'groupCallCancelled':
        _groupCallCancelledListeners[key] = callback as Function(Map<String, dynamic>);
        break;
    }
  }

  void removeListener(String event, String key) {
    switch (event) {
      case 'messageReceived':
        _messageReceivedListeners.remove(key);
        break;
      case 'callLogMessage':
        _callLogMessageListeners.remove(key);
        break;
      case 'messageSent':
        _messageSentListeners.remove(key);
        break;
      case 'doorbellRing':
        _doorbellRingListeners.remove(key);
        break;
      case 'userTyping':
        _userTypingListeners.remove(key);
        break;
      case 'typingUpdate':
        _typingUpdateListeners.remove(key);
        break;
      case 'presenceUpdate':
        _presenceUpdateListeners.remove(key);
        break;
      case 'presenceSnapshot':
        _presenceSnapshotListeners.remove(key);
        break;
      case 'joinedChat':
        _joinedChatListeners.remove(key);
        break;
      case 'leftChat':
        _leftChatListeners.remove(key);
        break;
      case 'messageDelivered':
        _messageDeliveredListeners.remove(key);
        break;
      case 'messageRead':
        _messageReadListeners.remove(key);
        break;
      case 'messageStatusUpdated':
        _messageStatusUpdatedListeners.remove(key);
        break;
      case 'messagesRead':
        _messagesReadListeners.remove(key);
        break;
      case 'unreadCleared':
        _unreadClearedListeners.remove(key);
        break;
      case 'colorChanged':
        _colorChangedListeners.remove(key);
        break;
      case 'colorReset':
        _colorResetListeners.remove(key);
        break;
      case 'groupColorChanged':
        _groupColorChangedListeners.remove(key);
        break;
      case 'groupColorReset':
        _groupColorResetListeners.remove(key);
        break;
      case 'allMessagesDeleted':
        _allMessagesDeletedListeners.remove(key);
        break;
      case 'fileReceived':
        _fileReceivedListeners.remove(key);
        break;
      case 'voiceMessageReceived':
        _voiceMessageReceivedListeners.remove(key);
        break;
      case 'messageDeleted':
        _messageDeletedListeners.remove(key);
        break;
      case 'messageEdited':
        _messageEditedListeners.remove(key);
        break;
      case 'taskAdded':
        _taskAddedListeners.remove(key);
        break;
      case 'taskMarked':
        _taskAddedListeners.remove(key);
        break;
      case 'taskCompleted':
        _taskCompletedListeners.remove(key);
        break;
      case 'taskUncompleted':
        _taskUncompletedListeners.remove(key);
        break;
      case 'excalidrawPinned':
        _excalidrawPinnedListeners.remove(key);
        break;
      case 'excalidrawUnpinned':
        _excalidrawUnpinnedListeners.remove(key);
        break;
      case 'excalidrawRoomChanged':
        _excalidrawRoomChangedListeners.remove(key);
        break;
      case 'reactionUpdated':
        _reactionUpdatedListeners.remove(key);
        break;
      case 'reactionCleared':
        _reactionClearedListeners.remove(key);
        break;
      case 'incomingCall':
        _incomingCallListeners.remove(key);
        break;
      case 'crossRoomCallOffer':
        _crossRoomCallOfferListeners.remove(key);
        break;
      case 'callInitiated':
        _callInitiatedListeners.remove(key);
        break;
      case 'callAnswered':
        _callAnsweredListeners.remove(key);
        break;
      case 'callSessionState':
        _callSessionStateListeners.remove(key);
        break;
      case 'callOfferStateSync':
        _callOfferStateSyncListeners.remove(key);
        break;
      case 'callDeclined':
        _callDeclinedListeners.remove(key);
        break;
      case 'callEnded':
        _callEndedListeners.remove(key);
        break;
      case 'connectionChanged':
        _connectionChangedListeners.remove(key);
        break;
      case 'reconnected':
        _reconnectedListeners.remove(key);
        break;
      case 'screenShareStarted':
        _screenShareStartedListeners.remove(key);
        break;
      case 'screenShareStopped':
        _screenShareStoppedListeners.remove(key);
        break;
      // Group chat events
      case 'groupNewMessage':
        _groupNewMessageListeners.remove(key);
        break;
      case 'groupMessageSent':
        _groupMessageSentListeners.remove(key);
        break;
      case 'groupFileMessage':
        _groupFileMessageListeners.remove(key);
        break;
      case 'groupDoorbell':
        _groupDoorbellListeners.remove(key);
        break;
      case 'groupMessageDeleted':
        _groupMessageDeletedListeners.remove(key);
        break;
      case 'groupMessageEdited':
        _groupMessageEditedListeners.remove(key);
        break;
      case 'groupReactionUpdated':
        _groupReactionUpdatedListeners.remove(key);
        break;
      case 'groupReactionCleared':
        _groupReactionClearedListeners.remove(key);
        break;
      case 'groupMemberLeft':
        _groupMemberLeftListeners.remove(key);
        break;
      case 'groupMessageStatusUpdated':
        _groupMessageStatusUpdatedListeners.remove(key);
        break;
      // Group management events
      case 'groupCreated':
        _groupCreatedListeners.remove(key);
        break;
      case 'groupUpdated':
        _groupUpdatedListeners.remove(key);
        break;
      case 'groupDeleted':
        _groupDeletedListeners.remove(key);
        break;
      case 'groupMemberAdded':
        _groupMemberAddedListeners.remove(key);
        break;
      case 'groupTyping':
        _groupTypingListeners.remove(key);
        break;
      case 'aiChatSync':
        _aiChatSyncListeners.remove(key);
        break;
      case 'test_response':
        // Remove from group new message listeners
        _groupNewMessageListeners.remove(key);
        break;
      case 'groupCallInvitation':
        _groupCallInvitationListeners.remove(key);
        break;
      case 'groupCallCancelled':
        _groupCallCancelledListeners.remove(key);
        break;
    }
  }

  /// Remove all listeners registered under a given key (e.g. 'lobby', 'chat')
  void removeListenersForKey(String key) {
    _messageReceivedListeners.remove(key);
    _messageSentListeners.remove(key);
    _doorbellRingListeners.remove(key);
    _userTypingListeners.remove(key);
    _typingUpdateListeners.remove(key);
    _presenceUpdateListeners.remove(key);
    _presenceSnapshotListeners.remove(key);
    _joinedChatListeners.remove(key);
    _leftChatListeners.remove(key);
    _messageDeliveredListeners.remove(key);
    _messageReadListeners.remove(key);
    _messageStatusUpdatedListeners.remove(key);
    _messagesReadListeners.remove(key);
    _unreadClearedListeners.remove(key);
    _colorChangedListeners.remove(key);
    _colorResetListeners.remove(key);
    _groupColorChangedListeners.remove(key);
    _groupColorResetListeners.remove(key);
    _allMessagesDeletedListeners.remove(key);
    _fileReceivedListeners.remove(key);
    _voiceMessageReceivedListeners.remove(key);
    _messageDeletedListeners.remove(key);
    _messageEditedListeners.remove(key);
    _taskAddedListeners.remove(key);
    _taskCompletedListeners.remove(key);
    _taskUncompletedListeners.remove(key);
    _excalidrawPinnedListeners.remove(key);
    _excalidrawUnpinnedListeners.remove(key);
    _excalidrawRoomChangedListeners.remove(key);
    _reactionUpdatedListeners.remove(key);
    _reactionClearedListeners.remove(key);
    _incomingCallListeners.remove(key);
    _crossRoomCallOfferListeners.remove(key);
    _callInitiatedListeners.remove(key);
    _callAnsweredListeners.remove(key);
    _callSessionStateListeners.remove(key);
    _callOfferStateSyncListeners.remove(key);
    _callDeclinedListeners.remove(key);
    _callEndedListeners.remove(key);
    _connectionChangedListeners.remove(key);
    _reconnectedListeners.remove(key);
    _screenShareStartedListeners.remove(key);
    _screenShareStoppedListeners.remove(key);
    // Group chat listeners
    _groupNewMessageListeners.remove(key);
    _groupMessageSentListeners.remove(key);
    _groupFileMessageListeners.remove(key);
    _groupDoorbellListeners.remove(key);
    _groupMessageDeletedListeners.remove(key);
    _groupMessageEditedListeners.remove(key);
    _groupReactionUpdatedListeners.remove(key);
    _groupReactionClearedListeners.remove(key);
    _groupMemberLeftListeners.remove(key);
    _groupMessageStatusUpdatedListeners.remove(key);
    // Group management listeners
    _groupCreatedListeners.remove(key);
    _groupUpdatedListeners.remove(key);
    _groupDeletedListeners.remove(key);
    _groupMemberAddedListeners.remove(key);
    _groupTypingListeners.remove(key);
    // AI chat sync
    _aiChatSyncListeners.remove(key);
    // Group call listeners
    _groupCallInvitationListeners.remove(key);
    _groupCallCancelledListeners.remove(key);
    // Raw event listeners
    for (final eventMap in _rawEventListeners.values) {
      eventMap.remove(key);
    }
  }

  // Broadcast helpers
  void _broadcast(
    Map<String, Function(Map<String, dynamic>)> listeners,
    Map<String, dynamic> data,
  ) {
    if (kDebugMode) {
      debugPrint(
        '🔍 [BROADCAST DEBUG] Broadcasting to ${listeners.length} listeners',
      );
      debugPrint('🔍 [BROADCAST DEBUG] Listener keys: ${listeners.keys}');
      debugPrint('🔍 [BROADCAST DEBUG] Data: $data');
    }
    for (final cb in listeners.values.toList()) {
      try {
        cb(data);
        if (kDebugMode) {
          debugPrint('🔍 [BROADCAST DEBUG] Successfully called listener');
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('🔍 [BROADCAST DEBUG] Error calling listener: $e');
        }
      }
    }
  }

  void _broadcastList(
    Map<String, Function(List<dynamic>)> listeners,
    List<dynamic> data,
  ) {
    for (final cb in listeners.values.toList()) {
      cb(data);
    }
  }

  int? _extractMessageId(Map<String, dynamic> messageData) {
    final dynamic idValue = messageData['id'] ?? messageData['message_id'];
    if (idValue is int) return idValue;
    if (idValue is String) return int.tryParse(idValue);
    return null;
  }

  void _autoAcknowledgeDelivery(
    Map<String, dynamic> messageData, {
    required String source,
  }) {
    final messageId = _extractMessageId(messageData);
    if (messageId == null) return;

    emit('message_delivered', {'message_id': messageId});
    debugPrint(
      '📧 Auto-sent delivery confirmation for $source message $messageId',
    );
  }

  // ---------------------------------------------------------------------------
  // Legacy single-callback setters (backward compat – register under '_default' key)
  // Setting to null removes the '_default' listener.
  // ---------------------------------------------------------------------------
  static const _dk = '_default';

  set onMessageReceived(Function(Map<String, dynamic>)? cb) => cb != null
      ? _messageReceivedListeners[_dk] = cb
      : _messageReceivedListeners.remove(_dk);
  set onMessageSent(Function(Map<String, dynamic>)? cb) => cb != null
      ? _messageSentListeners[_dk] = cb
      : _messageSentListeners.remove(_dk);
  set onDoorbellRing(Function(Map<String, dynamic>)? cb) => cb != null
      ? _doorbellRingListeners[_dk] = cb
      : _doorbellRingListeners.remove(_dk);
  set onUserTyping(Function(Map<String, dynamic>)? cb) => cb != null
      ? _userTypingListeners[_dk] = cb
      : _userTypingListeners.remove(_dk);
  set onTypingUpdate(Function(Map<String, dynamic>)? cb) => cb != null
      ? _typingUpdateListeners[_dk] = cb
      : _typingUpdateListeners.remove(_dk);
  set onPresenceUpdate(Function(Map<String, dynamic>)? cb) => cb != null
      ? _presenceUpdateListeners[_dk] = cb
      : _presenceUpdateListeners.remove(_dk);
  set onPresenceSnapshot(Function(List<dynamic>)? cb) => cb != null
      ? _presenceSnapshotListeners[_dk] = cb
      : _presenceSnapshotListeners.remove(_dk);
  set onJoinedChat(Function(Map<String, dynamic>)? cb) => cb != null
      ? _joinedChatListeners[_dk] = cb
      : _joinedChatListeners.remove(_dk);
  set onLeftChat(Function(Map<String, dynamic>)? cb) => cb != null
      ? _leftChatListeners[_dk] = cb
      : _leftChatListeners.remove(_dk);
  set onMessageDelivered(Function(Map<String, dynamic>)? cb) => cb != null
      ? _messageDeliveredListeners[_dk] = cb
      : _messageDeliveredListeners.remove(_dk);
  set onMessageRead(Function(Map<String, dynamic>)? cb) => cb != null
      ? _messageReadListeners[_dk] = cb
      : _messageReadListeners.remove(_dk);
  set onMessageStatusUpdated(Function(Map<String, dynamic>)? cb) => cb != null
      ? _messageStatusUpdatedListeners[_dk] = cb
      : _messageStatusUpdatedListeners.remove(_dk);
  set onMessagesRead(Function(Map<String, dynamic>)? cb) => cb != null
      ? _messagesReadListeners[_dk] = cb
      : _messagesReadListeners.remove(_dk);
  set onUnreadCleared(Function(Map<String, dynamic>)? cb) => cb != null
      ? _unreadClearedListeners[_dk] = cb
      : _unreadClearedListeners.remove(_dk);
  set onColorChanged(Function(Map<String, dynamic>)? cb) => cb != null
      ? _colorChangedListeners[_dk] = cb
      : _colorChangedListeners.remove(_dk);
  set onColorReset(Function(Map<String, dynamic>)? cb) => cb != null
      ? _colorResetListeners[_dk] = cb
      : _colorResetListeners.remove(_dk);
  set onAllMessagesDeleted(Function(Map<String, dynamic>)? cb) => cb != null
      ? _allMessagesDeletedListeners[_dk] = cb
      : _allMessagesDeletedListeners.remove(_dk);
  set onFileReceived(Function(Map<String, dynamic>)? cb) => cb != null
      ? _fileReceivedListeners[_dk] = cb
      : _fileReceivedListeners.remove(_dk);
  set onVoiceMessageReceived(Function(Map<String, dynamic>)? cb) => cb != null
      ? _voiceMessageReceivedListeners[_dk] = cb
      : _voiceMessageReceivedListeners.remove(_dk);
  set onMessageDeleted(Function(Map<String, dynamic>)? cb) => cb != null
      ? _messageDeletedListeners[_dk] = cb
      : _messageDeletedListeners.remove(_dk);
  set onMessageEdited(Function(Map<String, dynamic>)? cb) => cb != null
      ? _messageEditedListeners[_dk] = cb
      : _messageEditedListeners.remove(_dk);
  set onTaskAdded(Function(Map<String, dynamic>)? cb) => cb != null
      ? _taskAddedListeners[_dk] = cb
      : _taskAddedListeners.remove(_dk);
  set onTaskCompleted(Function(Map<String, dynamic>)? cb) => cb != null
      ? _taskCompletedListeners[_dk] = cb
      : _taskCompletedListeners.remove(_dk);
  set onTaskUncompleted(Function(Map<String, dynamic>)? cb) => cb != null
      ? _taskUncompletedListeners[_dk] = cb
      : _taskUncompletedListeners.remove(_dk);
  set onExcalidrawPinned(Function(Map<String, dynamic>)? cb) => cb != null
      ? _excalidrawPinnedListeners[_dk] = cb
      : _excalidrawPinnedListeners.remove(_dk);
  set onExcalidrawUnpinned(Function(Map<String, dynamic>)? cb) => cb != null
      ? _excalidrawUnpinnedListeners[_dk] = cb
      : _excalidrawUnpinnedListeners.remove(_dk);
  set onReactionUpdated(Function(Map<String, dynamic>)? cb) => cb != null
      ? _reactionUpdatedListeners[_dk] = cb
      : _reactionUpdatedListeners.remove(_dk);
  set onReactionCleared(Function(Map<String, dynamic>)? cb) => cb != null
      ? _reactionClearedListeners[_dk] = cb
      : _reactionClearedListeners.remove(_dk);
  set onIncomingCall(Function(Map<String, dynamic>)? cb) => cb != null
      ? _incomingCallListeners[_dk] = cb
      : _incomingCallListeners.remove(_dk);
  set onCrossRoomCallOffer(Function(Map<String, dynamic>)? cb) => cb != null
      ? _crossRoomCallOfferListeners[_dk] = cb
      : _crossRoomCallOfferListeners.remove(_dk);
  set onCallInitiated(Function(Map<String, dynamic>)? cb) => cb != null
      ? _callInitiatedListeners[_dk] = cb
      : _callInitiatedListeners.remove(_dk);
  set onCallAnswered(Function(Map<String, dynamic>)? cb) => cb != null
      ? _callAnsweredListeners[_dk] = cb
      : _callAnsweredListeners.remove(_dk);
    set onCallSessionState(Function(Map<String, dynamic>)? cb) => cb != null
      ? _callSessionStateListeners[_dk] = cb
      : _callSessionStateListeners.remove(_dk);
    set onCallOfferStateSync(Function(Map<String, dynamic>)? cb) => cb != null
      ? _callOfferStateSyncListeners[_dk] = cb
      : _callOfferStateSyncListeners.remove(_dk);
  set onCallDeclined(Function(Map<String, dynamic>)? cb) => cb != null
      ? _callDeclinedListeners[_dk] = cb
      : _callDeclinedListeners.remove(_dk);
  set onCallEnded(Function(Map<String, dynamic>)? cb) => cb != null
      ? _callEndedListeners[_dk] = cb
      : _callEndedListeners.remove(_dk);
  set onConnectionChanged(Function(bool isConnected)? cb) {
    if (cb != null) {
      _connectionChangedListeners[_dk] = (data) =>
          cb(data['connected'] as bool);
    } else {
      _connectionChangedListeners.remove(_dk);
    }
  }

  set onReconnected(Function()? cb) => cb != null
      ? _reconnectedListeners[_dk] = cb
      : _reconnectedListeners.remove(_dk);
  set onScreenShareStarted(Function(Map<String, dynamic>)? cb) => cb != null
      ? _screenShareStartedListeners[_dk] = cb
      : _screenShareStartedListeners.remove(_dk);
  set onScreenShareStopped(Function(Map<String, dynamic>)? cb) => cb != null
      ? _screenShareStoppedListeners[_dk] = cb
      : _screenShareStoppedListeners.remove(_dk);

  Function(Map<String, dynamic>)? _onSignal;

  // Signal buffering for cross-room calls
  final List<Map<String, dynamic>> _signalBuffer = [];
  bool _bufferSignals = false;

  // Getter/setter for onSignal with buffer replay
  Function(Map<String, dynamic>)? get onSignal => _onSignal;
  set onSignal(Function(Map<String, dynamic>)? handler) {
    _onSignal = handler;
    // Replay buffered signals when handler is set
    if (handler != null && _signalBuffer.isNotEmpty) {
      debugPrint('📡 Replaying ${_signalBuffer.length} buffered signals');
      for (final signal in _signalBuffer) {
        handler(signal);
      }
      _signalBuffer.clear();
    }
  }

  /// Start buffering signals (call before expecting cross-room call).
  /// If auto-buffering already kicked in (signals arrived before handler was
  /// set) the existing buffer is PRESERVED so no ICE candidates are lost.
  void startSignalBuffering() {
    if (_bufferSignals) {
      // Auto-buffer already running — don't wipe any pre-buffered signals.
      debugPrint(
        '📡 Signal buffering already active (${_signalBuffer.length} signals preserved)',
      );
      return;
    }
    _bufferSignals = true;
    // Only clear when we're starting fresh (no pre-buffered signals).
    _signalBuffer.clear();
    debugPrint('📡 Started signal buffering');
  }

  /// Stop buffering signals
  void stopSignalBuffering() {
    _bufferSignals = false;
    _signalBuffer.clear();
    debugPrint('📡 Stopped signal buffering');
  }

  bool get isConnected => _socket?.connected ?? false;
  int? get currentUserId => _currentUserId;

  /// Proactively (re)connect the socket if it's not currently connected. Used
  /// when returning from background (e.g. answering a call from an FCM tap),
  /// where the connection may have dropped. Safe no-op if already connected.
  void ensureConnected() {
    if (_socket == null) return;
    if (_socket!.connected) return;
    debugPrint('🔌 ensureConnected: socket down, triggering connect()');
    _socket!.connect();
  }

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

    // Use the same base URL as the API from centralized config
    final serverUrl = ApiConfig.baseUrl;

    debugPrint('=== Attempting Socket.IO Connection ===');
    debugPrint('Server URL: $serverUrl');
    debugPrint('Token length: ${_authToken?.length ?? 0}');
    debugPrint('User ID: $_currentUserId');

    try {
      // Use simple configuration that should work with most servers
      _socket = io.io(serverUrl, <String, dynamic>{
        'transports': ['websocket', 'polling'],
        'autoConnect': false,
        'query': {'token': _authToken},
        'extraHeaders': {'Authorization': 'Bearer $_authToken'},
        'forceNew': true,
        'reconnection': true,
        'timeout': 20000,
      });

      debugPrint('Socket.IO client created with simple config');
      _setupEventListeners();

      // Connect manually
      debugPrint('Manually connecting socket...');
      _socket?.connect();

      // Test connection after a delay
      Future.delayed(const Duration(seconds: 3), () {
        testConnection();
      });
    } catch (e) {
      debugPrint('❌ Error creating socket: $e');
    }
  }

  void _setupEventListeners() {
    if (_socket == null) return;

    // Add a catch-all event listener for debugging
    _socket!.onAny((event, data) {
      // Log AI sync and color-related events
      if (event.toString().contains('ai_chat_sync')) {
        debugPrint('🔍 [SOCKET onAny] ai_chat_sync event arrived! data type: ${data.runtimeType}, data: $data');
      } else if (event.toString().contains('color') ||
          event.toString().contains('group_color')) {
        debugPrint('🔍 [SOCKET DEBUG] Received event: $event with data: $data');
      }
      // Dispatch to raw event listeners (used by GroupCallService for mesh events)
      final rawListeners = _rawEventListeners[event.toString()];
      if (rawListeners != null && rawListeners.isNotEmpty) {
        final payload = (data is Map) ? Map<String, dynamic>.from(data as Map) : <String, dynamic>{};
        for (final cb in rawListeners.values.toList()) {
          cb(payload);
        }
      }
    });

    // Connection events
    _socket!.on('connect', (_) {
      debugPrint('✅ Socket connected - ID: ${_socket!.id}');
      debugPrint('🔍 [SOCKET DEBUG] Connect event received');
      // Notify all connection listeners that connection is restored
      _broadcast(_connectionChangedListeners, {'connected': true});
      for (final cb in _reconnectedListeners.values.toList()) {
        cb();
      }
      // Join user's personal room for direct notifications
      if (_currentUserId != null) {
        debugPrint('Joining personal room: user_$_currentUserId');
        _socket!.emit('join_room', {'room': 'user_$_currentUserId'});
      }
      // Join global users room for presence broadcasts
      debugPrint('Joining global room: users_all');
      _socket!.emit('join_room', {'room': 'users_all'});
      // Request initial presence snapshot (like web client does)
      debugPrint('📡 Requesting presence snapshot');
      _socket!.emit('request_presence_snapshot');
    });

    _socket!.on('disconnect', (reason) {
      debugPrint('❌ Socket disconnected - Reason: $reason');
      // Notify all connection listeners that connection is lost
      _broadcast(_connectionChangedListeners, {'connected': false});
      // If the server explicitly disconnected us (e.g., due to expired token)
      // trigger the auth error handler
      if (reason == 'io server disconnect') {
        debugPrint('🔐 Server disconnected us - likely expired token');
        AuthErrorHandler().handleAuthError(
          message: 'Connection lost. Please sign in again.',
        );
      }
    });

    _socket!.on('connect_error', (error) {
      debugPrint('⚠️ Connection error: $error');
      // Notify all connection listeners that connection failed
      _broadcast(_connectionChangedListeners, {'connected': false});
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
      _broadcast(_joinedChatListeners, data as Map<String, dynamic>);
    });

    _socket!.on('left_chat', (data) {
      debugPrint('📤 Left chat: $data');
      _broadcast(_leftChatListeners, data as Map<String, dynamic>);
    });

    // Message events
    _socket!.on('new_message', (data) {
      debugPrint('💬 New message: $data');
      final messageData = data as Map<String, dynamic>;
      _broadcast(_messageReceivedListeners, messageData);
      _autoAcknowledgeDelivery(messageData, source: 'chat');
    });

    _socket!.on('message_sent', (data) {
      debugPrint('📤 Message sent: $data');
      _broadcast(_messageSentListeners, data as Map<String, dynamic>);
    });

    // Persistent call-log entry (declined / missed / answered) — server pushes
    // this to both parties so the call shows in chat history + the conversation
    // list. Carries a full message_type='call' payload (sender/recipient/content).
    _socket!.on('call_log_message', (data) {
      debugPrint('📞 Call log message: $data');
      _broadcast(_callLogMessageListeners, data as Map<String, dynamic>);
    });

    // Doorbell event
    _socket!.on('doorbell', (data) {
      debugPrint('🔔 Doorbell ring: $data');
      _broadcast(_doorbellRingListeners, data as Map<String, dynamic>);
    });

    // Typing events
    _socket!.on('user_typing', (data) {
      debugPrint('⌨️ User typing: $data');
      _broadcast(_userTypingListeners, data as Map<String, dynamic>);
    });

    _socket!.on('typing_update', (data) {
      debugPrint('📝 Typing update: $data');
      _broadcast(_typingUpdateListeners, data as Map<String, dynamic>);
    });

    // Presence events
    _socket!.on('user_status_change', (data) {
      debugPrint('👤 Presence update: $data');
      _broadcast(_presenceUpdateListeners, data as Map<String, dynamic>);
    });

    // Presence snapshot (initial state on connect)
    _socket!.on('presence_snapshot', (data) {
      debugPrint('👥 Presence snapshot received');
      final contacts = data['contacts'] as List<dynamic>?;
      if (contacts != null) {
        _broadcastList(_presenceSnapshotListeners, contacts);
      }
    });

    // Color change event
    _socket!.on('color_changed', (data) {
      debugPrint('🎨 Color changed: $data');
      _broadcast(_colorChangedListeners, data as Map<String, dynamic>);
    });

    // Color reset event
    _socket!.on('color_reset', (data) {
      debugPrint('🔄 Color reset: $data');
      _broadcast(_colorResetListeners, data as Map<String, dynamic>);
    });

    // Group color change event
    _socket!.on('group_color_changed', (data) {
      debugPrint('🎨 [SOCKET SERVICE] Group color changed received: $data');
      debugPrint(
        '🎨 [SOCKET SERVICE] Broadcasting to ${_groupColorChangedListeners.length} listeners',
      );
      debugPrint(
        '🎨 [SOCKET SERVICE] Listener keys: ${_groupColorChangedListeners.keys.toList()}',
      );
      _broadcast(_groupColorChangedListeners, data as Map<String, dynamic>);
      debugPrint('🎨 [SOCKET SERVICE] Broadcast completed');
    });

    // Group color reset event
    _socket!.on('group_color_reset', (data) {
      debugPrint('🔄 [SOCKET SERVICE] Group color reset received: $data');
      debugPrint(
        '🔄 [SOCKET SERVICE] Broadcasting to ${_groupColorResetListeners.length} listeners',
      );
      debugPrint(
        '🔄 [SOCKET SERVICE] Listener keys: ${_groupColorResetListeners.keys.toList()}',
      );
      _broadcast(_groupColorResetListeners, data as Map<String, dynamic>);
      debugPrint('🔄 [SOCKET SERVICE] Reset broadcast completed');
    });

    // Message delivery confirmation
    _socket!.on('message_delivered', (data) {
      debugPrint('✓ Message delivered: $data');
      _broadcast(_messageDeliveredListeners, data as Map<String, dynamic>);
    });

    // Message read confirmation
    _socket!.on('message_read', (data) {
      debugPrint('✓✓ Message read: $data');
      _broadcast(_messageReadListeners, data as Map<String, dynamic>);
    });

    // Message status updated event
    _socket!.on('message_status_updated', (data) {
      debugPrint('✓ Status updated: $data');
      _broadcast(_messageStatusUpdatedListeners, data as Map<String, dynamic>);
    });

    // Multiple messages read event
    _socket!.on('messages_read', (data) {
      debugPrint('✓✓ Messages read: $data');
      _broadcast(_messagesReadListeners, data as Map<String, dynamic>);
    });

    // Cross-device read sync: this account read a conversation on another
    // device (e.g. the web app) — clear the local unread badge for that peer.
    _socket!.on('unread_cleared', (data) {
      debugPrint('🔄 Unread cleared on another device: $data');
      _broadcast(_unreadClearedListeners, data as Map<String, dynamic>);
    });

    // All messages deleted event
    _socket!.on('all_messages_deleted', (data) {
      debugPrint('📭 All messages deleted: $data');
      _broadcast(_allMessagesDeletedListeners, data as Map<String, dynamic>);
    });

    // File message event (receiving files from web)
    _socket!.on('file_message', (data) {
      debugPrint('📎 File received: $data');
      final messageData = data as Map<String, dynamic>;
      _broadcast(_fileReceivedListeners, messageData);
      _autoAcknowledgeDelivery(messageData, source: 'file');
    });

    // Voice message event (receiving voice messages from web)
    _socket!.on('voice_message', (data) {
      debugPrint(
        '🎤 Voice message received (${_voiceMessageReceivedListeners.length} listeners): $data',
      );
      final messageData = data as Map<String, dynamic>;
      _broadcast(_voiceMessageReceivedListeners, messageData);
      _autoAcknowledgeDelivery(messageData, source: 'voice');
    });

    // Message deleted event
    _socket!.on('message_deleted', (data) {
      debugPrint('🗑️ Message deleted: $data');
      _broadcast(_messageDeletedListeners, data as Map<String, dynamic>);
    });

    // Reaction events
    _socket!.on('reaction_updated', (data) {
      debugPrint('👍 Reaction updated: $data');
      _broadcast(_reactionUpdatedListeners, data as Map<String, dynamic>);
    });

    _socket!.on('reaction_cleared', (data) {
      debugPrint('❌ Reaction cleared: $data');
      _broadcast(_reactionClearedListeners, data as Map<String, dynamic>);
    });

    // Message edited event
    _socket!.on('message_edited', (data) {
      debugPrint('✏️ Message edited: $data');
      _broadcast(_messageEditedListeners, data as Map<String, dynamic>);
    });

    _socket!.on('messageEdited', (data) {
      debugPrint('✏️ Message edited (messageEdited): $data');
      _broadcast(_messageEditedListeners, data as Map<String, dynamic>);
    });

    void broadcastTaskAdded(dynamic data, String eventName) {
      if (data is! Map) return;
      final payload = Map<String, dynamic>.from(data as Map);
      debugPrint('📋 Task added ($eventName): $payload');
      _broadcast(_taskAddedListeners, payload);
    }

    void broadcastTaskCompleted(dynamic data, String eventName) {
      if (data is! Map) return;
      final payload = Map<String, dynamic>.from(data as Map);
      debugPrint('✅ Task completed ($eventName): $payload');
      _broadcast(_taskCompletedListeners, payload);
    }

    void broadcastTaskUncompleted(dynamic data, String eventName) {
      if (data is! Map) return;
      final payload = Map<String, dynamic>.from(data as Map);
      debugPrint('⬜ Task uncompleted ($eventName): $payload');
      _broadcast(_taskUncompletedListeners, payload);
    }

    // Task events (support snake_case and camelCase aliases)
    _socket!.on('task_added', (data) => broadcastTaskAdded(data, 'task_added'));
    _socket!.on('taskAdded', (data) => broadcastTaskAdded(data, 'taskAdded'));
    _socket!.on(
      'task_marked',
      (data) => broadcastTaskAdded(data, 'task_marked'),
    );
    _socket!.on('taskMarked', (data) => broadcastTaskAdded(data, 'taskMarked'));
    _socket!.on(
      'task_updated',
      (data) => broadcastTaskAdded(data, 'task_updated'),
    );

    _socket!.on(
      'task_completed',
      (data) => broadcastTaskCompleted(data, 'task_completed'),
    );
    _socket!.on(
      'taskCompleted',
      (data) => broadcastTaskCompleted(data, 'taskCompleted'),
    );

    _socket!.on(
      'task_uncompleted',
      (data) => broadcastTaskUncompleted(data, 'task_uncompleted'),
    );
    _socket!.on(
      'taskUncompleted',
      (data) => broadcastTaskUncompleted(data, 'taskUncompleted'),
    );
    _socket!.on('task_removed', (data) {
      if (data is! Map) return;
      final payload = Map<String, dynamic>.from(data as Map);
      payload['is_task'] = false;
      broadcastTaskUncompleted(payload, 'task_removed');
    });
    _socket!.on('task_unmarked', (data) {
      if (data is! Map) return;
      final payload = Map<String, dynamic>.from(data as Map);
      payload['is_task'] = false;
      broadcastTaskUncompleted(payload, 'task_unmarked');
    });
    _socket!.on('taskUnmarked', (data) {
      if (data is! Map) return;
      final payload = Map<String, dynamic>.from(data as Map);
      payload['is_task'] = false;
      broadcastTaskUncompleted(payload, 'taskUnmarked');
    });

    // Excalidraw pinned event
    _socket!.on('excalidraw_pinned', (data) {
      debugPrint('📌 Excalidraw pinned: $data');
      _broadcast(_excalidrawPinnedListeners, data as Map<String, dynamic>);
    });
    _socket!.on('excalidraw_link_pinned', (data) {
      debugPrint('📌 Excalidraw link pinned: $data');
      _broadcast(_excalidrawPinnedListeners, data as Map<String, dynamic>);
    });

    // Excalidraw unpinned event
    _socket!.on('excalidraw_unpinned', (data) {
      debugPrint('📌 Excalidraw unpinned: $data');
      _broadcast(_excalidrawUnpinnedListeners, data as Map<String, dynamic>);
    });
    _socket!.on('excalidraw_link_unpinned', (data) {
      debugPrint('📌 Excalidraw link unpinned: $data');
      _broadcast(_excalidrawUnpinnedListeners, data as Map<String, dynamic>);
    });

    // Self-hosted whiteboard directory changed somewhere in a conversation we
    // belong to. Payload carries conversation_key, actor_id and the room row.
    for (final event in const [
      'excalidraw_room_created',
      'excalidraw_room_updated',
      'excalidraw_room_deleted',
    ]) {
      _socket!.on(event, (data) {
        if (data is! Map) return;
        debugPrint('🖊️ $event: $data');
        final payload = Map<String, dynamic>.from(data);
        payload['event'] = event;
        _broadcast(_excalidrawRoomChangedListeners, payload);
      });
    }

    // === Call-related events ===

    // Incoming call notification (from initiate_call event)
    _socket!.on('incoming_call', (data) {
      debugPrint('📲 Incoming call: $data');
      _broadcast(_incomingCallListeners, data as Map<String, dynamic>);
    });

    // Cross-room call offer (from web client signaling)
    _socket!.on('cross_room_call_offer', (data) {
      debugPrint('📲 Cross-room call offer: $data');
      // Start buffering signals immediately - they may arrive before handler is set
      startSignalBuffering();
      _broadcast(_crossRoomCallOfferListeners, data as Map<String, dynamic>);
    });

    // Call initiated confirmation
    _socket!.on('call_initiated', (data) {
      debugPrint('📞 Call initiated: $data');
      _broadcast(_callInitiatedListeners, data as Map<String, dynamic>);
    });

    // Call answered
    _socket!.on('call_answered', (data) {
      debugPrint('✅ Call answered: $data');
      _broadcast(_callAnsweredListeners, data as Map<String, dynamic>);
    });

    // Canonical call session state (pending/accepted/ended/declined/cancelled)
    _socket!.on('call_session_state', (data) {
      debugPrint('📡 Call session state: $data');
      _broadcast(_callSessionStateListeners, data as Map<String, dynamic>);
    });

    // Cross-device call offer state sync (accepted/declined/ended)
    _socket!.on('call_offer_state_sync', (data) {
      debugPrint('🔁 Call offer state sync: $data');
      _broadcast(_callOfferStateSyncListeners, data as Map<String, dynamic>);
    });

    // Call declined
    _socket!.on('call_declined', (data) {
      debugPrint('❌ Call declined: $data');
      _broadcast(_callDeclinedListeners, data as Map<String, dynamic>);
    });

    // Call ended
    _socket!.on('call_ended', (data) {
      debugPrint('📴 Call ended: $data');
      _broadcast(_callEndedListeners, data as Map<String, dynamic>);
    });

    // Screen share started/stopped (web client sends these via dedicated socket events)
    _socket!.on('screen_share_started', (data) {
      debugPrint('🖥️ Screen share started: $data');
      _broadcast(_screenShareStartedListeners, data as Map<String, dynamic>);
    });

    _socket!.on('screen_share_stopped', (data) {
      debugPrint('🖥️ Screen share stopped: $data');
      _broadcast(_screenShareStoppedListeners, data as Map<String, dynamic>);
    });

    // === Group chat events ===

    // New group message from another member
    _socket!.on('group_new_message', (data) {
      debugPrint('💬 Group new message: $data');
      _broadcast(_groupNewMessageListeners, data as Map<String, dynamic>);

      // Auto-acknowledge delivery
      final messageData = data;
      if (messageData['message_id'] != null &&
          messageData['group_id'] != null) {
        emit('group_message_delivered', {
          'message_id': messageData['message_id'],
          'group_id': messageData['group_id'],
        });
        debugPrint(
          '📧 Auto-sent group delivery confirmation for message ${messageData['message_id']}',
        );
      }
    });

    // Group message sent confirmation (your own message)
    _socket!.on('group_message_sent', (data) {
      debugPrint('📤 Group message sent: $data');
      _broadcast(_groupMessageSentListeners, data as Map<String, dynamic>);
    });

    // Group file message received
    _socket!.on('group_file_message', (data) {
      debugPrint('📎 Group file received: $data');
      _broadcast(_groupFileMessageListeners, data as Map<String, dynamic>);
    });

    // Group doorbell notification
    _socket!.on('group_doorbell', (data) {
      debugPrint('🔔 Group doorbell: $data');
      _broadcast(_groupDoorbellListeners, data as Map<String, dynamic>);
    });

    // Group message deleted
    _socket!.on('group_message_deleted', (data) {
      debugPrint('🗑️ Group message deleted: $data');
      _broadcast(_groupMessageDeletedListeners, data as Map<String, dynamic>);
    });

    // Group message edited
    _socket!.on('group_message_edited', (data) {
      debugPrint('✏️ Group message edited: $data');
      _broadcast(_groupMessageEditedListeners, data as Map<String, dynamic>);
    });

    // Group reaction updated
    _socket!.on('group_reaction_updated', (data) {
      debugPrint('👍 Group reaction updated: $data');
      _broadcast(_groupReactionUpdatedListeners, data as Map<String, dynamic>);
    });

    // Group reaction cleared
    _socket!.on('group_reaction_cleared', (data) {
      debugPrint('❌ Group reaction cleared: $data');
      _broadcast(_groupReactionClearedListeners, data as Map<String, dynamic>);
    });

    // Group member left
    _socket!.on('group_member_left', (data) {
      debugPrint('👋 [SOCKET] Group member left event received: $data');
      debugPrint(
        '👋 [SOCKET] Broadcasting to ${_groupMemberLeftListeners.length} listeners',
      );
      debugPrint(
        '👋 [SOCKET] Listener keys: ${_groupMemberLeftListeners.keys}',
      );
      _broadcast(_groupMemberLeftListeners, data as Map<String, dynamic>);
    });

    // Group member removed (alternative event name for member removal)
    _socket!.on('group_member_removed', (data) {
      debugPrint('👋 [SOCKET] Group member removed event received: $data');
      debugPrint(
        '👋 [SOCKET] Broadcasting to ${_groupMemberLeftListeners.length} listeners',
      );
      _broadcast(_groupMemberLeftListeners, data as Map<String, dynamic>);
    });

    // Group message status updated (delivered/seen)
    _socket!.on('message_status_updated', (data) {
      debugPrint('✓ Group message status updated: $data');
      _broadcast(
        _groupMessageStatusUpdatedListeners,
        data as Map<String, dynamic>,
      );
    });

    // === Group management events ===

    // Group created - when a new group is created
    _socket!.on('group_created', (data) {
      debugPrint('🎉 Group created: $data');
      _broadcast(_groupCreatedListeners, data as Map<String, dynamic>);
    });

    // Group updated - when group info is updated
    _socket!.on('group_updated', (data) {
      debugPrint('🔄 Group updated: $data');
      _broadcast(_groupUpdatedListeners, data as Map<String, dynamic>);
    });

    // Group deleted - when a group is deleted
    _socket!.on('group_deleted', (data) {
      debugPrint('🗑️ Group deleted: $data');
      _broadcast(_groupDeletedListeners, data as Map<String, dynamic>);
    });

    // Group member added - when members are added to a group
    _socket!.on('group_member_added', (data) {
      debugPrint('👥 Group member added: $data');
      _broadcast(_groupMemberAddedListeners, data as Map<String, dynamic>);
    });

    // Group typing - typing indicators in groups
    _socket!.on('group_user_typing', (data) {
      debugPrint('⌨️ Group user typing: $data');
      _broadcast(_groupTypingListeners, data as Map<String, dynamic>);
    });

    // AI chat realtime sync
    _socket!.on('ai_chat_sync', (data) {
      debugPrint('\u{1f916} [AI SYNC] ai_chat_sync RAW data type: ${data.runtimeType}, data: $data');
      Map<String, dynamic>? payload;
      if (data is Map) {
        payload = Map<String, dynamic>.from(data);
      } else if (data is List && data.isNotEmpty && data[0] is Map) {
        payload = Map<String, dynamic>.from(data[0] as Map);
      } else {
        debugPrint('\u{1f916} [AI SYNC] Unexpected data type, skipping');
        return;
      }
      debugPrint('\u{1f916} [AI SYNC] ai_chat_sync received: action=${payload['action']}, session_id=${payload['session_id']}');
      _broadcast(_aiChatSyncListeners, payload);
    });

    // Debug: Test response event - handle it properly
    _socket!.on('test_response', (data) {
      debugPrint(
        '🧪 [SOCKET DEBUG] Test response received in socket service: $data',
      );
      debugPrint(
        '🧪 [SOCKET DEBUG] Group new message listeners count: ${_groupNewMessageListeners.length}',
      );
      debugPrint(
        '🧪 [SOCKET DEBUG] Group new message listener keys: ${_groupNewMessageListeners.keys}',
      );
      // Broadcast to group new message listeners since that's where test_response listeners are registered
      _broadcast(_groupNewMessageListeners, data as Map<String, dynamic>);
      debugPrint('🧪 [SOCKET DEBUG] Test response broadcast completed');
    });

    // === Group call events ===

    _socket!.on('group_call_invitation', (data) {
      debugPrint('📞 Group call invitation: $data');
      _broadcast(_groupCallInvitationListeners, data as Map<String, dynamic>);
    });

    _socket!.on('group_call_cancelled', (data) {
      debugPrint('📴 Group call cancelled: $data');
      _broadcast(_groupCallCancelledListeners, data as Map<String, dynamic>);
    });

    // Debug: Catch-all listener for color-related events
    _socket!.onAny((event, data) {
      if (event.toString().toLowerCase().contains('color')) {
        debugPrint('🎨 [CATCH-ALL] Color-related event received: $event');
        debugPrint('🎨 [CATCH-ALL] Event data: $data');
      }
      if (event.toString().toLowerCase().contains('reset')) {
        debugPrint('🔄 [CATCH-ALL] Reset-related event received: $event');
        debugPrint('🔄 [CATCH-ALL] Event data: $data');
      }
    });

    // WebRTC signaling (offer/answer/ICE candidates)
    _socket!.on('signal', (data) {
      debugPrint('📡 Signal received: $data');
      final signalData = data as Map<String, dynamic>;
      if (_onSignal != null) {
        // Handler is ready — deliver immediately (normal case during active call)
        _onSignal!.call(signalData);
      } else {
        // No handler set yet. Auto-start buffering to capture trickle-ICE candidates
        // that arrive before cross_room_call_offer or before the call is answered.
        // Without this, pre-offer ICE candidates (sent by trickle ICE before the SDP
        // offer) are silently dropped, leaving the callee with zero remote ICE pairs
        // → ICE negotiation fails → PeerConnectionFailed.
        if (!_bufferSignals) {
          _bufferSignals = true;
          debugPrint(
            '📡 Auto-started signal buffering (pre-offer trickle ICE)',
          );
        }
        _signalBuffer.add(signalData);
        debugPrint('📡 Buffered signal (total: ${_signalBuffer.length})');
      }
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
  /// Fire-and-forget events that must survive being sent while offline: they have
  /// no REST fallback and no ack, so if dropped they're lost forever. They are
  /// persisted by [SocketEventQueueService] and replayed on reconnect.
  static const Set<String> _replayableEvents = {
    'ring_doorbell',
    'change_color',
    'reset_color',
  };

  void emit(String event, dynamic data) {
    if (_socket?.connected ?? false) {
      if (kDebugMode) {
        debugPrint('📤 Emitting $event: $data');
      }
      _socket!.emit(event, data);

      // Add extra debugging for color change events
      if (kDebugMode && event.contains('color')) {
        debugPrint('🎨 [SOCKET DEBUG] Color event emitted successfully');
        debugPrint('🎨 [SOCKET DEBUG] Socket connected: ${_socket?.connected}');
        debugPrint('🎨 [SOCKET DEBUG] Socket ID: ${_socket?.id}');
      }
    } else {
      // Offline: persist replayable events so a doorbell / color change sent while
      // disconnected isn't silently lost — it's replayed once we reconnect.
      if (_replayableEvents.contains(event) && data is Map) {
        SocketEventQueueService().queueEvent(
          event,
          Map<String, dynamic>.from(data),
        );
        if (kDebugMode) {
          debugPrint('🔔 Queued offline event $event for replay on reconnect');
        }
      } else if (kDebugMode) {
        debugPrint('⚠️ Cannot emit $event - socket not connected');
        debugPrint(
          '⚠️ Socket state: connected=${_socket?.connected}, socket=${_socket != null}',
        );
      }
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
      'reply_to_id': ?replyToId,
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
    emit('typing_update', {'recipient_id': recipientId, 'message': preview});
  }

  /// Confirm message delivery
  void confirmDelivery(int messageId) {
    emit('confirm_delivery', {'message_id': messageId});
  }

  /// Confirm message read
  void confirmRead(int messageId) {
    emit('confirm_read', {'message_id': messageId});
  }

  /// Mark messages as viewed
  void markMessagesViewed(int recipientId) {
    emit('messages_viewed', {'recipient_id': recipientId});
  }

  /// Mark messages as read
  void markMessagesRead(int recipientId) {
    emit('mark_messages_read', {'recipient_id': recipientId});
  }

  /// Delete a message
  void deleteMessage(int messageId) {
    emit('delete_message', {'message_id': messageId});
  }

  /// Edit a message
  void editMessage(int messageId, String newContent) {
    emit('edit_message', {'message_id': messageId, 'content': newContent});
  }

  /// Add message as task
  void addTask(int messageId) {
    emit('add_task', {'message_id': messageId});
  }

  /// Remove message from task list
  void unmarkTask(int messageId) {
    emit('unmark_task', {'message_id': messageId});
    // Compatibility alias used in some backend paths.
    emit('remove_task', {'message_id': messageId});
  }

  /// Set a reaction on a message
  void setReaction(
    int messageId,
    String emoji, {
    int? chatUserId,
    String? roomId,
  }) {
    final normalizedEmoji = emoji.replaceAll('\uFE0F', '');
    final payload = <String, dynamic>{
      'message_id': messageId,
      // Keep both keys for backend compatibility across deployments.
      'reaction': emoji,
      'emoji': emoji,
      'emoji_plain': normalizedEmoji,
      if (chatUserId != null) 'user_id': chatUserId,
      if (roomId != null && roomId.isNotEmpty) 'room': roomId,
    };
    emit('set_reaction', payload);
    debugPrint(
      '👍 Sending reaction: emoji=$emoji, emoji_plain=$normalizedEmoji, messageId=$messageId, chatUserId=$chatUserId, room=$roomId',
    );
  }

  /// Clear reaction from a message
  void clearReaction(int messageId) {
    emit('clear_reaction', {'message_id': messageId});
    debugPrint('❌ Clearing reaction for messageId=$messageId');
  }

  /// Complete a task
  void completeTask(int messageId) {
    emit('complete_task', {'message_id': messageId});
  }

  /// Uncomplete a task
  void uncompleteTask(int messageId) {
    emit('uncomplete_task', {'message_id': messageId});
  }

  /// Pin excalidraw link
  void pinExcalidraw(int messageId) {
    emit('pin_excalidraw', {'message_id': messageId});
  }

  /// Unpin excalidraw link
  void unpinExcalidraw(int messageId) {
    emit('unpin_excalidraw', {'message_id': messageId});
  }

  // === Group chat methods ===

  /// Join a group chat room
  void joinGroupChat(int groupId) {
    debugPrint('📱 [SOCKET] Joining group chat: $groupId');
    emit('join_group_chat', {'group_id': groupId});
  }

  /// Leave a group chat room
  void leaveGroupChat(int groupId) {
    debugPrint('📱 [SOCKET] Leaving group chat: $groupId');
    emit('leave_group_chat', {'group_id': groupId});
  }

  /// Send a message to a group via Socket.IO
  void sendGroupMessage({
    required int groupId,
    required String content,
    String messageType = 'text',
    int? replyToId,
  }) {
    emit('send_group_message', {
      'group_id': groupId,
      'content': content,
      'message_type': messageType,
      'reply_to_id': ?replyToId,
    });
  }

  /// Ring doorbell in a group
  void ringGroupDoorbell(int groupId) {
    emit('ring_group_doorbell', {'group_id': groupId});
  }

  /// Send typing indicator in a group
  void sendGroupTyping(int groupId, String message) {
    final preview = message.length > 120 ? message.substring(0, 120) : message;
    debugPrint(
      '⌨️ Sending group typing: group_id=$groupId, message="$preview"',
    );
    emit('group_typing', {'group_id': groupId, 'message': preview});
  }

  /// Stop typing indicator in a group
  void stopGroupTyping(int groupId) {
    debugPrint('⌨️ Stopping group typing: group_id=$groupId');
    emit('group_typing', {'group_id': groupId, 'message': ''});
  }

  /// Confirm group message delivery
  void confirmGroupDelivery(int messageId, int groupId) {
    emit('group_message_delivered', {
      'message_id': messageId,
      'group_id': groupId,
    });
  }

  /// Mark group messages as viewed
  void markGroupMessagesViewed(
    int groupId,
    List<int> messageIds,
    int senderId,
  ) {
    emit('group_messages_viewed', {
      'group_id': groupId,
      'message_ids': messageIds,
      'sender_id': senderId,
    });
  }

  /// Delete a group message
  void deleteGroupMessage(int messageId, int groupId) {
    emit('delete_group_message', {
      'message_id': messageId,
      'group_id': groupId,
    });
  }

  /// Edit a group message
  void editGroupMessage(int messageId, int groupId, String newContent) {
    emit('edit_group_message', {
      'message_id': messageId,
      'group_id': groupId,
      'content': newContent,
    });
  }

  /// Set a reaction on a group message
  void setGroupReaction(int messageId, int groupId, String emoji) {
    final normalizedEmoji = emoji.replaceAll('\uFE0F', '');
    emit('set_group_reaction', {
      'message_id': messageId,
      'group_id': groupId,
      'reaction': emoji,
      'emoji': emoji,
      'emoji_plain': normalizedEmoji,
    });
    debugPrint(
      '👍 Sending group reaction: emoji=$emoji, emoji_plain=$normalizedEmoji, messageId=$messageId, groupId=$groupId',
    );
  }

  /// Clear reaction from a group message
  void clearGroupReaction(int messageId, int groupId, String emoji) {
    emit('clear_group_reaction', {
      'message_id': messageId,
      'group_id': groupId,
      'emoji': emoji,
    });
    debugPrint(
      '❌ Clearing group reaction for messageId=$messageId, groupId=$groupId',
    );
  }

  /// Clear all callbacks
  void clearCallbacks() {
    _messageReceivedListeners.clear();
    _messageSentListeners.clear();
    _doorbellRingListeners.clear();
    _userTypingListeners.clear();
    _typingUpdateListeners.clear();
    _presenceUpdateListeners.clear();
    _presenceSnapshotListeners.clear();
    _joinedChatListeners.clear();
    _leftChatListeners.clear();
    _messageDeliveredListeners.clear();
    _messageReadListeners.clear();
    _messageStatusUpdatedListeners.clear();
    _messagesReadListeners.clear();
    _colorChangedListeners.clear();
    _colorResetListeners.clear();
    _groupColorChangedListeners.clear();
    _groupColorResetListeners.clear();
    _allMessagesDeletedListeners.clear();
    _fileReceivedListeners.clear();
    _voiceMessageReceivedListeners.clear();
    _messageDeletedListeners.clear();
    _messageEditedListeners.clear();
    _taskAddedListeners.clear();
    _taskCompletedListeners.clear();
    _taskUncompletedListeners.clear();
    _excalidrawPinnedListeners.clear();
    _excalidrawUnpinnedListeners.clear();
    _reactionUpdatedListeners.clear();
    _reactionClearedListeners.clear();
    _incomingCallListeners.clear();
    _crossRoomCallOfferListeners.clear();
    _callInitiatedListeners.clear();
    _callAnsweredListeners.clear();
    _callDeclinedListeners.clear();
    _callEndedListeners.clear();
    _callLogMessageListeners.clear();
    _connectionChangedListeners.clear();
    _reconnectedListeners.clear();
    // Group chat listeners
    _groupNewMessageListeners.clear();
    _groupMessageSentListeners.clear();
    _groupFileMessageListeners.clear();
    _groupDoorbellListeners.clear();
    _groupMessageDeletedListeners.clear();
    _groupMessageEditedListeners.clear();
    _groupReactionUpdatedListeners.clear();
    _groupReactionClearedListeners.clear();
    _groupMemberLeftListeners.clear();
    _groupMessageStatusUpdatedListeners.clear();
    _groupCallInvitationListeners.clear();
    _groupCallCancelledListeners.clear();
    _rawEventListeners.clear();
    onSignal = null;
  }

  // === Group call methods ===

  void joinGroupCall(String roomId, String username) {
    emit('join_group_call', {'room_id': roomId, 'username': username});
  }

  void leaveGroupCall(String roomId, String username) {
    emit('leave_group_call', {'room_id': roomId, 'username': username});
  }

  void inviteToGroupCall(String roomId, List<int> inviteeIds, List<String> inviteeUsernames) {
    emit('invite_to_group_call', {
      'room_id': roomId,
      'invitees': inviteeIds,
      'invitee_usernames': inviteeUsernames,
    });
  }

  void respondToGroupCallInvitation(String roomId, int inviterId, String response) {
    emit('group_call_invitation_response', {
      'room_id': roomId,
      'inviter_id': inviterId,
      'response': response,
    });
  }

  void meshJoin(String roomId, String peerId) {
    emit('mesh_join', {'roomId': roomId, 'peerId': peerId});
  }

  void meshLeave(String roomId, String peerId) {
    emit('mesh_leave', {'roomId': roomId, 'peerId': peerId});
  }

  void meshOffer(String roomId, String from, String to, Map<String, dynamic> sdp) {
    emit('mesh_offer', {'roomId': roomId, 'from': from, 'to': to, 'sdp': sdp});
  }

  void meshAnswer(String roomId, String from, String to, Map<String, dynamic> sdp) {
    emit('mesh_answer', {'roomId': roomId, 'from': from, 'to': to, 'sdp': sdp});
  }

  void meshIce(String roomId, String from, String to, Map<String, dynamic> candidate) {
    emit('mesh_ice', {'roomId': roomId, 'from': from, 'to': to, 'candidate': candidate});
  }
}
