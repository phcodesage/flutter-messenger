import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/group.dart';
import '../models/message.dart';
import 'active_chat_service.dart';
import 'chat_cache_service.dart';
import 'group_service.dart';
import 'media_preload_service.dart';
import 'message_service.dart';
import 'socket_service.dart';

/// Keeps the local message cache current for conversations that are **not** on
/// screen.
///
/// Every real-time cache write used to live inside ChatScreen /
/// GroupChatScreen, so a room only reached Hive if you happened to be looking
/// at it when the event arrived. Anything that landed while you were in the
/// lobby, on the contacts screen, in a different room — or a message you sent
/// from the web client on the same account — left that room's cache stale.
/// Opening it then painted the stale tail instantly (the point of the cache)
/// and the missing message appeared a second later when the network refresh
/// returned. That read as "the preload isn't working".
///
/// This listens once, for the whole app session, and keeps every room current
/// in two layers:
///
///  1. **Apply directly.** Events that carry a whole message (new/sent/call
///     log, group new/sent) are decoded and written straight into the cache —
///     no network, correct immediately.
///  2. **Mark dirty, refresh in the background.** *Every* message-affecting
///     event — files, voice notes, doorbells, colour changes, edits, deletes,
///     reactions, task marks, read receipts — marks its room dirty and a
///     debounced background fetch re-syncs that thread from the server.
///
/// Layer 2 is deliberately not "apply each event by hand". Those payloads are
/// all shaped differently (a delete carries only a message id; a reaction
/// carries the participants; a file carries upload metadata), and
/// reimplementing ~20 mutations here would duplicate the screens' logic and
/// drift from it. Re-reading the thread the server already knows about is one
/// code path that is correct for all of them, and it happens before the user
/// opens the room, which is what "preload in the background" means.
///
/// Rooms that ARE on screen are skipped: their screen already maintains itself,
/// and a second writer would only add contention.
class MessageCacheSyncService {
  MessageCacheSyncService._internal();
  static final MessageCacheSyncService _instance =
      MessageCacheSyncService._internal();
  factory MessageCacheSyncService() => _instance;

  static const String _key = 'message_cache_sync';

  /// Wait this long after an event before refreshing, so a burst of events for
  /// one room (a file upload emits several) costs a single fetch.
  static const Duration _debounce = Duration(milliseconds: 600);

  /// Ceiling on rooms refreshed per flush; the rest stay dirty for the next
  /// tick rather than firing a dozen parallel requests.
  static const int _maxRoomsPerFlush = 6;

  /// How many of a refreshed thread's newest messages get their attachments
  /// pulled down. A caught-up room only has a handful of new ones, and
  /// MediaPreloadService skips anything already on disk, so this is a bound on
  /// the pathological case (first sight of a long thread), not the normal one.
  static const int _mediaPrefetchWindow = 20;

  /// Events that hand us a complete message we can apply without the network.
  static const List<String> _directMessageEvents = [
    'messageReceived',
    'messageSent',
    'callLogMessage',
  ];

  /// Every other 1:1 event that changes what the thread should look like.
  static const List<String> _directTouchEvents = [
    'fileReceived',
    'voiceMessageReceived',
    'doorbellRing',
    'colorChanged',
    'colorReset',
    'messageDeleted',
    'messageEdited',
    'reactionUpdated',
    'reactionCleared',
    'messageStatusUpdated',
    'messageDelivered',
    'messageRead',
    'messagesRead',
    'unreadCleared',
    'allMessagesDeleted',
    'taskAdded',
    'taskMarked',
    'taskCompleted',
    'taskUncompleted',
    'excalidrawPinned',
    'excalidrawUnpinned',
  ];

  static const List<String> _groupMessageEvents = [
    'groupNewMessage',
    'groupMessageSent',
  ];

  static const List<String> _groupTouchEvents = [
    'groupFileMessage',
    'groupDoorbell',
    'groupMessageDeleted',
    'groupMessageEdited',
    'groupReactionUpdated',
    'groupReactionCleared',
    'groupMessageStatusUpdated',
    'groupColorChanged',
    'groupColorReset',
  ];

  final SocketService _socket = SocketService();
  bool _started = false;
  int? _currentUserId;

  final Set<int> _dirtyPeers = {};
  final Set<int> _dirtyGroups = {};
  Timer? _flushTimer;
  bool _flushing = false;

  bool get isRunning => _started;

  /// Begin mirroring socket events into the cache. Safe to call more than once
  /// (login, app start, account switch) — later calls just refresh the user id
  /// the writes are keyed against.
  void start(int currentUserId) {
    _currentUserId = currentUserId;
    if (_started) return;
    _started = true;

    for (final event in _directMessageEvents) {
      _socket.addListener(event, _key, _onDirectMessage);
    }
    for (final event in _directTouchEvents) {
      _socket.addListener(event, _key, _onDirectTouch);
    }
    for (final event in _groupMessageEvents) {
      _socket.addListener(event, _key, _onGroupMessage);
    }
    for (final event in _groupTouchEvents) {
      _socket.addListener(event, _key, _onGroupTouch);
    }

    debugPrint(
      '💾 MessageCacheSync: mirroring '
      '${_directMessageEvents.length + _directTouchEvents.length + _groupMessageEvents.length + _groupTouchEvents.length}'
      ' socket events for user $currentUserId',
    );
  }

  /// Stop mirroring (logout). Leaves the cache itself alone — clearing it is
  /// [ChatCacheService.clearUserCache]'s job.
  void stop() {
    if (!_started) return;
    // One call rather than unsubscribing event by event — it drops this key
    // from every listener map, so it cannot fall out of step with the lists
    // above when an event is added to them.
    _socket.removeListenersForKey(_key);
    _flushTimer?.cancel();
    _flushTimer = null;
    _dirtyPeers.clear();
    _dirtyGroups.clear();
    _started = false;
    _currentUserId = null;
    debugPrint('💾 MessageCacheSync: stopped');
  }

  // ── 1:1 ────────────────────────────────────────────────────────────────────

  Future<void> _onDirectMessage(Map<String, dynamic> data) async {
    final userId = _userId;
    if (userId == null) return;

    Message? message;
    try {
      message = Message.fromJson(data);
    } catch (e) {
      debugPrint('💾 MessageCacheSync: unparseable direct message: $e');
    }

    final peerId = message != null
        ? (message.senderId == userId ? message.recipientId : message.senderId)
        : _resolvePeer(data, userId);
    if (peerId == null || peerId == 0) return;
    if (_isOnScreenDirect(peerId)) return;

    if (message != null) {
      try {
        await ChatCacheService.addMessageToCache(userId, peerId, message);
        debugPrint(
          '💾 MessageCacheSync: cached ${message.senderId == userId ? "outgoing" : "incoming"} '
          'message ${message.id} for conversation $peerId',
        );
        // Pull the attachment down too. Caching the message row alone leaves an
        // image or voice note still streaming when the room is opened, which
        // looks exactly like the room not being preloaded.
        unawaited(MediaPreloadService.instance.prefetchMessages([message]));
      } catch (e) {
        debugPrint('💾 MessageCacheSync: cache write failed: $e');
      }
    }
    // Refresh anyway: reactions, task state and read status ride along with the
    // server copy and are not all present on the socket payload.
    _markPeerDirty(peerId);
  }

  void _onDirectTouch(Map<String, dynamic> data) {
    final userId = _userId;
    if (userId == null) return;
    final peerId = _resolvePeer(data, userId);
    if (peerId == null || peerId == 0) return;
    _markPeerDirty(peerId);
  }

  /// Work out which 1:1 thread an arbitrary event payload belongs to.
  ///
  /// The events are not consistent about this — some carry both participants,
  /// some only a reader and a sender, some only the message id — so try each
  /// shape in turn and fall back to looking the message up in the warm caches.
  int? _resolvePeer(Map<String, dynamic> data, int me) {
    final sender = _toInt(data['sender_id']);
    final recipient = _toInt(data['recipient_id']);
    if (sender != null && recipient != null) {
      return sender == me ? recipient : sender;
    }

    // Reactions name the message's participants rather than their own.
    final msgSender = _toInt(data['message_sender_id']);
    final msgRecipient = _toInt(data['message_recipient_id']);
    if (msgSender != null && msgRecipient != null) {
      return msgSender == me ? msgRecipient : msgSender;
    }

    // Read receipts: {reader_id, sender_id}.
    final reader = _toInt(data['reader_id']);
    if (reader != null && sender != null) return reader == me ? sender : reader;

    final peer = _toInt(data['peer_id']) ?? _toInt(data['other_user_id']);
    if (peer != null) return peer;

    // One-sided payloads.
    if (sender != null && sender != me) return sender;
    if (recipient != null && recipient != me) return recipient;

    // Identifies only the message (delete, edit, task mark, status) — find the
    // thread that holds it.
    return ChatCacheService.findConversationPeerForMessage(
      me,
      data['message_id'] ?? data['id'],
    );
  }

  // ── Groups ─────────────────────────────────────────────────────────────────

  Future<void> _onGroupMessage(Map<String, dynamic> data) async {
    final groupId = _resolveGroup(data);
    if (groupId == null) return;
    if (ActiveChatService().activeGroupId == groupId) return;

    try {
      final message = GroupMessage.fromJson(data);
      await ChatCacheService.addGroupMessageToCache(groupId, message);
      unawaited(MediaPreloadService.instance.prefetchGroupMessages([message]));
    } catch (e) {
      debugPrint('💾 MessageCacheSync: unparseable group message: $e');
    }
    _markGroupDirty(groupId);
  }

  void _onGroupTouch(Map<String, dynamic> data) {
    final groupId = _resolveGroup(data);
    if (groupId == null) return;
    _markGroupDirty(groupId);
  }

  int? _resolveGroup(Map<String, dynamic> data) {
    return _toInt(data['group_id']) ??
        ChatCacheService.findGroupForMessage(data['message_id'] ?? data['id']);
  }

  // ── Dirty tracking + debounced refresh ────────────────────────────────────

  /// Queue a conversation for background re-sync from outside the socket layer.
  ///
  /// Incoming messages have a delivery path our own echoes never take: a push
  /// notification. When the socket is down (reconnecting, doze, a flaky
  /// network) FCM is the only thing that knows a message exists, and its data
  /// payload deliberately carries no content — see send_message_notification in
  /// fcm_service.py, which puts only ids in `data` and the text in the
  /// notification body. So there is nothing to write directly; marking the room
  /// dirty makes the refresh fetch the real thing.
  void markConversationDirty(int peerId) => _markPeerDirty(peerId);

  /// Group counterpart of [markConversationDirty].
  void markGroupConversationDirty(int groupId) => _markGroupDirty(groupId);

  bool _isOnScreenDirect(int peerId) =>
      ActiveChatService().activeUserId == peerId;

  void _markPeerDirty(int peerId) {
    if (peerId <= 0) return;
    if (_isOnScreenDirect(peerId)) return;
    _dirtyPeers.add(peerId);
    _scheduleFlush();
  }

  void _markGroupDirty(int groupId) {
    if (ActiveChatService().activeGroupId == groupId) return;
    _dirtyGroups.add(groupId);
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(_debounce, () {
      unawaited(_flush());
    });
  }

  /// Re-sync dirty rooms from the server, one at a time so a busy minute never
  /// turns into a burst of parallel requests. Both fetches write the cache as a
  /// side effect, which is the whole point of calling them here.
  Future<void> _flush() async {
    if (_flushing) {
      // A refresh is mid-flight; come back for whatever arrived meanwhile.
      _scheduleFlush();
      return;
    }
    if (_dirtyPeers.isEmpty && _dirtyGroups.isEmpty) return;

    _flushing = true;
    try {
      final peers = _dirtyPeers.take(_maxRoomsPerFlush).toList();
      _dirtyPeers.removeAll(peers);
      for (final peerId in peers) {
        if (_isOnScreenDirect(peerId)) continue;
        try {
          final messages = await MessageService.getConversationMessages(
            userId: peerId,
            offlineFirst: false,
          );
          debugPrint('💾 MessageCacheSync: refreshed conversation $peerId');
          // This is the path every file, image and voice message takes — their
          // socket payloads only mark the room dirty — so it is the one that
          // has to fetch attachments, not just the message rows.
          unawaited(
            MediaPreloadService.instance.prefetchMessages(
              messages.take(_mediaPrefetchWindow),
            ),
          );
        } catch (e) {
          debugPrint('💾 MessageCacheSync: refresh failed for $peerId: $e');
        }
      }

      final groups = _dirtyGroups.take(_maxRoomsPerFlush).toList();
      _dirtyGroups.removeAll(groups);
      for (final groupId in groups) {
        if (ActiveChatService().activeGroupId == groupId) continue;
        try {
          final messages = await GroupService.getMessages(
            groupId: groupId,
            offlineFirst: false,
          );
          debugPrint('💾 MessageCacheSync: refreshed group $groupId');
          unawaited(
            MediaPreloadService.instance.prefetchGroupMessages(
              messages.take(_mediaPrefetchWindow),
            ),
          );
        } catch (e) {
          debugPrint('💾 MessageCacheSync: refresh failed for group $groupId: $e');
        }
      }
    } finally {
      _flushing = false;
      // Anything left over (or newly dirtied) gets the next tick.
      if (_dirtyPeers.isNotEmpty || _dirtyGroups.isNotEmpty) _scheduleFlush();
    }
  }

  int? get _userId => _currentUserId ?? _socket.currentUserId;

  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }
}
