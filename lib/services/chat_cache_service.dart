import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/lobby_user.dart';
import '../models/message.dart';
import '../models/group.dart';

/// Local cache service for conversations and lobby snapshots.
/// Enhanced for offline-first messaging like WhatsApp.
class ChatCacheService {
  static const _chatBoxName = 'chat_cache';
  static const _lobbyBoxName = 'lobby_cache';
  static const _groupChatBoxName = 'group_chat_cache';
  static const _aiChatBoxName = 'ai_chat_cache';
  static const _maxMessagesPerThread = 1000; // Increased from 200
  static const _maxLobbyEntries = 100;

  /// How many conversations keep a decoded copy in memory, and how many of
  /// their newest messages. Hive reads are synchronous, but the JSON→Message
  /// decode is not free and every caller still has to `await` — which pushes
  /// the first paint past the frame the route appears on, so you see a spinner
  /// before the messages land. Memoising the decoded tail lets a warmed
  /// conversation be read synchronously, so the chat opens already populated.
  /// The tail is only what fills a screen; the full history still arrives from
  /// [loadConversationMessages] a moment later.
  static const _maxMemoConversations = 12;
  static const _maxMemoMessages = 80;
  static final Map<String, List<Message>> _conversationMemo = {};
  static final List<String> _memoOrder = [];

  static void _rememberConversation(String key, List<Message> messages) {
    _conversationMemo[key] = messages.length > _maxMemoMessages
        ? messages.sublist(messages.length - _maxMemoMessages)
        : List<Message>.from(messages);
    _memoOrder.remove(key);
    _memoOrder.add(key);
    while (_memoOrder.length > _maxMemoConversations) {
      _conversationMemo.remove(_memoOrder.removeAt(0));
    }
  }

  /// Serialises writes per conversation key.
  ///
  /// Every write here is read-modify-write (load the thread, insert, save it
  /// back). Two of them overlapping on the same thread both read the same base
  /// list and the second save discards the first message. That used to need two
  /// screens racing, but now the app-wide MessageCacheSyncService can write to a
  /// thread whose screen is also mounted (backgrounding clears ActiveChatService
  /// without unmounting the chat), so the window is real. Chaining each key's
  /// writes makes the sequence deterministic.
  static final Map<String, Future<void>> _writeChains = {};

  static Future<void> _serializeWrite(String key, Future<void> Function() work) {
    final previous = _writeChains[key] ?? Future<void>.value();
    final next = previous.then((_) => work());
    _writeChains[key] = next;
    // Drop the chain once it drains, but only if nothing queued behind us.
    next.whenComplete(() {
      if (identical(_writeChains[key], next)) _writeChains.remove(key);
    });
    return next;
  }

  static bool _initialized = false;
  static late Box _chatBox;
  static late Box _lobbyBox;
  static late Box _groupChatBox;
  static late Box _aiChatBox;

  /// Initialize Hive and open cache boxes.
  static Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter();
    _chatBox = await Hive.openBox(_chatBoxName);
    _lobbyBox = await Hive.openBox(_lobbyBoxName);
    _groupChatBox = await Hive.openBox(_groupChatBoxName);
    _aiChatBox = await Hive.openBox(_aiChatBoxName);
    _initialized = true;
  }

  static String _conversationKey(int currentUserId, int otherUserId) {
    final pair = <int>[currentUserId, otherUserId]..sort();
    return 'conversation_${pair[0]}_${pair[1]}';
  }

  static String _groupConversationKey(int groupId) => 'group_$groupId';

  static String _lobbyKey(int currentUserId) => 'lobby_$currentUserId';
  static String _groupsKey(int currentUserId) => 'groups_$currentUserId';

  static String _aiSessionKey(int currentUserId, int sessionId) =>
      'ai_${currentUserId}_$sessionId';

  /// Persist the latest messages for a conversation (capped).
  /// Stores the full message rows (including file URLs) so reopening a chat
  /// offline can still render media via the on-disk image cache.
  static Future<void> saveConversationMessages(
    int currentUserId,
    int otherUserId,
    List<Message> messages,
  ) {
    return _serializeWrite(
      _conversationKey(currentUserId, otherUserId),
      () => _saveConversationUnlocked(currentUserId, otherUserId, messages),
    );
  }

  /// The body of [saveConversationMessages] without taking the per-key write
  /// chain — for callers that already hold it (see [addMessageToCache]).
  /// Taking it twice on one key would wait on a future that cannot complete.
  static Future<void> _saveConversationUnlocked(
    int currentUserId,
    int otherUserId,
    List<Message> messages,
  ) async {
    if (!_initialized) {
      debugPrint('⚠️ ChatCacheService not initialized, cannot save!');
      return;
    }

    final key = _conversationKey(currentUserId, otherUserId);
    final capped = messages.take(_maxMessagesPerThread).toList();

    debugPrint('💾 Saving ${capped.length} messages to cache with key: $key');

    final cachedMessages = capped.map((m) => _stripFileData(m)).toList();

    // Keep the in-memory tail in step with disk so leaving and re-entering a
    // chat paints the messages you just saw, not a stale snapshot.
    _rememberConversation(key, cachedMessages);

    await _chatBox.put(key, {
      'messages': cachedMessages.map((m) => m.toJson()).toList(),
      'updated_at': DateTime.now().toIso8601String(),
      'message_count': cachedMessages.length,
    });

    debugPrint(
      '✅ Successfully saved ${cachedMessages.length} messages to cache',
    );
  }

  /// Returns the message unchanged. We previously stripped file URLs to
  /// shrink Hive entries, but that broke offline media viewing — reopening
  /// a chat without internet showed every image as a broken icon. Disk is
  /// cheap; persisting full message rows lets `CachedNetworkImage` (and the
  /// audio/video players) serve cached media without a network round-trip.
  static Message _stripFileData(Message message) {
    return message;
  }

  /// Add a single message to the cache (for real-time updates).
  static Future<void> addMessageToCache(
    int currentUserId,
    int otherUserId,
    Message message,
  ) {
    if (!_initialized) return Future<void>.value();
    // Load and save inside one critical section — the read and the write have
    // to be atomic with respect to other writers on this thread.
    return _serializeWrite(_conversationKey(currentUserId, otherUserId), () async {
      final existing = await loadConversationMessages(
        currentUserId,
        otherUserId,
      );

      // Check if message already exists (by ID)
      final messageExists = existing.any((m) => m.id == message.id);
      final updated = messageExists
          ? existing.map((m) => m.id == message.id ? message : m).toList()
          : [message, ...existing];
      await _saveConversationUnlocked(currentUserId, otherUserId, updated);
    });
  }

  /// Synchronously read the decoded tail of a conversation, if it has been
  /// warmed by a previous load/save or by [preloadConversation].
  ///
  /// Returns null on a miss — callers must fall back to the async
  /// [loadConversationMessages]. The point of this is the first frame: a chat
  /// screen can seed its list in initState and paint messages immediately
  /// instead of showing a spinner while an await resolves.
  ///
  /// Ordered oldest → newest, matching [loadConversationMessages].
  static List<Message>? peekConversationMessages(
    int currentUserId,
    int otherUserId,
  ) {
    final cached = _conversationMemo[_conversationKey(
      currentUserId,
      otherUserId,
    )];
    if (cached == null || cached.isEmpty) return null;
    return List<Message>.unmodifiable(cached);
  }

  /// Which conversation holds [messageId], as a peer id — or null if no warm
  /// conversation contains it.
  ///
  /// Several socket events (message_deleted, message_edited, task/excalidraw
  /// updates, message_status_updated) identify only the message, never the
  /// thread. Without this they cannot be routed to a room at all. Searching the
  /// decoded tails is a bounded in-memory scan (at most
  /// [_maxMemoConversations] × [_maxMemoMessages]) and covers exactly the rooms
  /// that matter: the recently used ones a user is likely to return to.
  static int? findConversationPeerForMessage(int currentUserId, dynamic messageId) {
    if (messageId == null) return null;
    final target = messageId.toString();
    for (final entry in _conversationMemo.entries) {
      if (!entry.value.any((m) => m.id.toString() == target)) continue;
      // Key shape: conversation_<lowId>_<highId>
      final parts = entry.key.split('_');
      if (parts.length < 3) continue;
      final a = int.tryParse(parts[1]);
      final b = int.tryParse(parts[2]);
      if (a == null || b == null) continue;
      // Self-chat has both ends equal, and its "peer" is ourselves.
      return a == currentUserId ? b : a;
    }
    return null;
  }

  /// Group counterpart of [findConversationPeerForMessage].
  static int? findGroupForMessage(dynamic messageId) {
    if (messageId == null) return null;
    final target = messageId.toString();
    for (final entry in _groupMemo.entries) {
      if (entry.value.any((m) => m.id.toString() == target)) return entry.key;
    }
    return null;
  }

  /// Warm the in-memory tail for a conversation without needing its screen.
  /// Called from the lobby so the conversations a user is most likely to open
  /// are already decoded by the time they tap one.
  static Future<void> preloadConversation(
    int currentUserId,
    int otherUserId,
  ) async {
    if (!_initialized) return;
    if (_conversationMemo.containsKey(
      _conversationKey(currentUserId, otherUserId),
    )) {
      return;
    }
    await loadConversationMessages(currentUserId, otherUserId);
  }

  /// Retrieve cached messages for a conversation.
  /// Returns messages immediately for offline access.
  static Future<List<Message>> loadConversationMessages(
    int currentUserId,
    int otherUserId,
  ) async {
    if (!_initialized) {
      debugPrint('⚠️ ChatCacheService not initialized!');
      return [];
    }

    final key = _conversationKey(currentUserId, otherUserId);
    debugPrint('🔍 Loading cache for key: $key');

    final data = _chatBox.get(key);
    if (data == null) {
      debugPrint('📦 No cache found for key: $key');
      return [];
    }

    debugPrint('📦 Cache data found: ${data.keys}');
    final rawList = (data['messages'] as List?) ?? const [];
    debugPrint('📦 Cache has ${rawList.length} messages');

    final decoded = rawList
        .map((item) => Message.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList();
    _rememberConversation(key, decoded);
    return decoded;
  }

  /// Decoded tails for groups, same purpose and bounds as [_conversationMemo].
  static final Map<int, List<GroupMessage>> _groupMemo = {};
  static final List<int> _groupMemoOrder = [];

  static void _rememberGroup(int groupId, List<GroupMessage> messages) {
    _groupMemo[groupId] = messages.length > _maxMemoMessages
        ? messages.sublist(messages.length - _maxMemoMessages)
        : List<GroupMessage>.from(messages);
    _groupMemoOrder.remove(groupId);
    _groupMemoOrder.add(groupId);
    while (_groupMemoOrder.length > _maxMemoConversations) {
      _groupMemo.remove(_groupMemoOrder.removeAt(0));
    }
  }

  /// Synchronously read a group's warmed message tail, or null on a miss.
  /// See [peekConversationMessages] for why this exists.
  static List<GroupMessage>? peekGroupMessages(int groupId) {
    final cached = _groupMemo[groupId];
    if (cached == null || cached.isEmpty) return null;
    return List<GroupMessage>.unmodifiable(cached);
  }

  /// Warm a group's in-memory tail ahead of the user opening it.
  static Future<void> preloadGroup(int groupId) async {
    if (!_initialized) return;
    if (_groupMemo.containsKey(groupId)) return;
    await loadGroupMessages(groupId);
  }

  /// Save group messages to cache.
  /// Preserves all message data including file URLs for proper display.
  static Future<void> saveGroupMessages(
    int groupId,
    List<GroupMessage> messages,
  ) {
    return _serializeWrite(
      _groupConversationKey(groupId),
      () => _saveGroupUnlocked(groupId, messages),
    );
  }

  /// [saveGroupMessages] without taking the write chain — for callers already
  /// inside it.
  static Future<void> _saveGroupUnlocked(
    int groupId,
    List<GroupMessage> messages,
  ) async {
    if (!_initialized) return;
    final capped = messages.take(_maxMessagesPerThread).toList();

    // Don't strip file URLs anymore - preserve all data for proper display
    final cachedMessages = capped.map((m) => _stripGroupFileData(m)).toList();

    _rememberGroup(groupId, cachedMessages);

    await _groupChatBox.put(_groupConversationKey(groupId), {
      'messages': cachedMessages.map((m) => m.toJson()).toList(),
      'updated_at': DateTime.now().toIso8601String(),
      'message_count': cachedMessages.length,
    });
  }

  /// Strip file URLs from group message to save storage space
  static GroupMessage _stripGroupFileData(GroupMessage message) {
    // Don't strip file data anymore - we need it for proper display
    // The storage savings aren't worth the broken file message display
    return message;
  }

  /// Load cached group messages.
  static Future<List<GroupMessage>> loadGroupMessages(int groupId) async {
    if (!_initialized) return [];
    final data = _groupChatBox.get(_groupConversationKey(groupId));
    if (data == null) return [];
    final rawList = (data['messages'] as List?) ?? const [];
    final decoded = rawList
        .map(
          (item) =>
              GroupMessage.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
    _rememberGroup(groupId, decoded);
    return decoded;
  }

  /// Add a single group message to the cache.
  static Future<void> addGroupMessageToCache(
    int groupId,
    GroupMessage message,
  ) {
    if (!_initialized) return Future<void>.value();
    return _serializeWrite(_groupConversationKey(groupId), () async {
      final existing = await loadGroupMessages(groupId);

      // Check if message already exists
      final messageExists = existing.any((m) => m.id == message.id);
      final updated = messageExists
          ? existing.map((m) => m.id == message.id ? message : m).toList()
          : [message, ...existing];
      await _saveGroupUnlocked(groupId, updated);
    });
  }

  /// Save lobby users snapshot for offline mode.
  static Future<void> saveLobbyUsers(
    int currentUserId,
    List<LobbyUser> users,
  ) async {
    if (!_initialized) return;
    final trimmed = users.take(_maxLobbyEntries).toList();
    await _lobbyBox.put(_lobbyKey(currentUserId), {
      'users': trimmed.map((u) => u.toJson()).toList(),
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  /// Load cached lobby users snapshot.
  static Future<List<LobbyUser>> loadLobbyUsers(int currentUserId) async {
    if (!_initialized) return [];
    final data = _lobbyBox.get(_lobbyKey(currentUserId));
    if (data == null) return [];
    final rawList = (data['users'] as List?) ?? const [];
    return rawList
        .map(
          (item) => LobbyUser.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
  }

  /// Save group list snapshot for offline mode.
  static Future<void> saveGroups(
    int currentUserId,
    List<Group> groups,
  ) async {
    if (!_initialized) return;
    await _lobbyBox.put(_groupsKey(currentUserId), {
      'groups': groups.map((g) => g.toJson()).toList(),
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  /// Load cached group list snapshot.
  static Future<List<Group>> loadGroups(int currentUserId) async {
    if (!_initialized) return [];
    final data = _lobbyBox.get(_groupsKey(currentUserId));
    if (data == null) return [];
    final rawList = (data['groups'] as List?) ?? const [];
    return rawList
        .map(
          (item) => Group.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
  }

  /// Optional helper to clear cache for a user (e.g., on logout).
  static Future<void> clearUserCache(int currentUserId) async {
    if (!_initialized) return;
    // Drop every in-memory copy too, or a logout would leave the next account
    // able to peek the previous user's conversations.
    _conversationMemo.clear();
    _memoOrder.clear();
    _aiMemoUserId = null;
    _aiMemoSessionId = null;
    _aiMemoMessages = null;
    final keysToDelete = _chatBox.keys
        .where((key) => key is String && key.contains('conversation_'))
        .where(
          (key) =>
              key.toString().contains('_$currentUserId') ||
              key.toString().contains('${currentUserId}_'),
        )
        .toList();
    await _chatBox.deleteAll(keysToDelete);
    await _lobbyBox.delete(_lobbyKey(currentUserId));

    // Drop AI session caches for this user too.
    final aiKeys = _aiChatBox.keys
        .where((key) =>
            key is String && key.startsWith('ai_${currentUserId}_'))
        .toList();
    if (aiKeys.isNotEmpty) {
      await _aiChatBox.deleteAll(aiKeys);
    }
  }

  /// Clear all group message caches.
  static Future<void> clearAllGroupCaches() async {
    if (!_initialized) return;
    _groupMemo.clear();
    _groupMemoOrder.clear();
    await _groupChatBox.clear();
  }

  /// Clear cache for a specific 1-on-1 conversation.
  static Future<void> clearConversationCache(
    int currentUserId,
    int otherUserId,
  ) async {
    if (!_initialized) return;
    final key = _conversationKey(currentUserId, otherUserId);
    debugPrint('🗑️ Clearing conversation cache for key: $key');
    _conversationMemo.remove(key);
    _memoOrder.remove(key);
    await _chatBox.delete(key);
  }

  /// Clear cache for a specific group.
  static Future<void> clearGroupCache(int groupId) async {
    if (!_initialized) return;
    _groupMemo.remove(groupId);
    _groupMemoOrder.remove(groupId);
    await _groupChatBox.delete(_groupConversationKey(groupId));
  }

  /// Utility to trim caches if boxes grow beyond limits.
  static Future<void> pruneCaches() async {
    if (!_initialized) return;
    if (_chatBox.length > 200) {
      final keys = _chatBox.keys.toList()
        ..sort((a, b) => a.toString().compareTo(b.toString()));
      final excess = max(0, keys.length - 200);
      if (excess > 0) {
        await _chatBox.deleteAll(keys.sublist(0, excess));
      }
    }
    if (_lobbyBox.length > 50) {
      final keys = _lobbyBox.keys.toList();
      final excess = max(0, keys.length - 50);
      if (excess > 0) {
        await _lobbyBox.deleteAll(keys.sublist(0, excess));
      }
    }
  }

  // ─── AI chat cache ─────────────────────────────────────────────────
  // The AI chat keeps its own Hive box because messages are plain
  // role/content/timestamp maps rather than the full Message model.

  /// Decoded copy of the AI session most recently loaded or saved. There is
  /// effectively one active AI session per user, so a single slot is enough to
  /// let the AI screen paint on its first frame — the session id itself lives
  /// in SharedPreferences behind an await, so there is nothing to key on
  /// synchronously anyway.
  static int? _aiMemoUserId;
  static int? _aiMemoSessionId;
  static List<Map<String, String>>? _aiMemoMessages;

  static void _rememberAiSession(
    int currentUserId,
    int sessionId,
    List<Map<String, String>> messages,
  ) {
    _aiMemoUserId = currentUserId;
    _aiMemoSessionId = sessionId;
    _aiMemoMessages = messages
        .map((m) => Map<String, String>.from(m))
        .toList(growable: false);
  }

  /// Synchronously read the last-known AI conversation, or null on a miss.
  /// The session id is returned alongside so the caller can tell whether the
  /// session it eventually resolves matches what it painted.
  static ({int sessionId, List<Map<String, String>> messages})?
      peekLastAiSession(int currentUserId) {
    final messages = _aiMemoMessages;
    final sessionId = _aiMemoSessionId;
    if (messages == null || sessionId == null) return null;
    if (_aiMemoUserId != currentUserId) return null;
    if (messages.isEmpty) return null;
    return (sessionId: sessionId, messages: messages);
  }

  /// Warm the AI session memo so opening the AI chat paints immediately.
  static Future<void> preloadAiSession(int currentUserId, int sessionId) async {
    if (!_initialized) return;
    if (_aiMemoUserId == currentUserId && _aiMemoSessionId == sessionId) return;
    await loadAiSessionMessages(currentUserId, sessionId);
  }

  /// Persist the message list for an AI session, capped to keep storage
  /// bounded. Messages are stored verbatim (the AI chat does not attach
  /// remote files like the 1:1 / group chats do).
  static Future<void> saveAiSessionMessages(
    int currentUserId,
    int sessionId,
    List<Map<String, String>> messages,
  ) async {
    if (!_initialized) return;
    final capped = messages.length > _maxMessagesPerThread
        ? messages.sublist(messages.length - _maxMessagesPerThread)
        : messages;
    _rememberAiSession(currentUserId, sessionId, capped);
    await _aiChatBox.put(_aiSessionKey(currentUserId, sessionId), {
      'messages': capped.map(Map<String, String>.from).toList(),
      'updated_at': DateTime.now().toIso8601String(),
      'message_count': capped.length,
    });
  }

  /// Retrieve cached messages for an AI session. Returns an empty list
  /// when nothing has been cached yet (first open).
  static Future<List<Map<String, String>>> loadAiSessionMessages(
    int currentUserId,
    int sessionId,
  ) async {
    if (!_initialized) return const <Map<String, String>>[];
    final data = _aiChatBox.get(_aiSessionKey(currentUserId, sessionId));
    if (data == null) return const <Map<String, String>>[];
    final raw = (data['messages'] as List?) ?? const [];
    final decoded = raw
        .map<Map<String, String>>(
          (item) => Map<String, String>.from(
            (item as Map).map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')),
          ),
        )
        .toList();
    _rememberAiSession(currentUserId, sessionId, decoded);
    return decoded;
  }

  /// Drop the cached message list for an AI session (e.g. when the user
  /// clears the conversation server-side).
  static Future<void> clearAiSessionCache(
    int currentUserId,
    int sessionId,
  ) async {
    if (!_initialized) return;
    if (_aiMemoUserId == currentUserId && _aiMemoSessionId == sessionId) {
      _aiMemoUserId = null;
      _aiMemoSessionId = null;
      _aiMemoMessages = null;
    }
    await _aiChatBox.delete(_aiSessionKey(currentUserId, sessionId));
  }
}
