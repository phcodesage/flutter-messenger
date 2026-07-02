import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'socket_service.dart';

/// Room key for the AI assistant — there's only one AI room per account, so
/// unlike 1:1/group rooms it needs no id suffix.
const String kAiDraftRoomKey = 'ai';

class _DraftEntry {
  final String text;
  // Set once when the room is left with unsent text ("bumped" to the top of
  // the lobby, like a recent action). Null means "not currently bumped".
  final int? bumpAtMs;

  const _DraftEntry(this.text, this.bumpAtMs);

  Map<String, dynamic> toJson() => {
    'text': text,
    if (bumpAtMs != null) 'bump': bumpAtMs,
  };

  static _DraftEntry fromJson(Map<String, dynamic> json) =>
      _DraftEntry(json['text'] as String? ?? '', json['bump'] as int?);
}

/// Per-conversation "unsent message" drafts — the mobile counterpart of the
/// web app's `chat-drafts.js`. Room keys follow the same convention:
/// `user:<id>` for 1:1 (self-chat is just `user:<currentUserId>`, no special
/// case needed), `group:<id>` for groups, and the fixed key `ai` for the AI
/// assistant (there's only one AI room per account).
///
/// Behavior mirrors the web version by design:
///  - Composer text is saved live (debounced) as the user types.
///  - Leaving a room with unsent text "bumps" it — [markLeftWithDraft] records
///    a timestamp that the lobby's sort treats as a recent action.
///  - Clearing the draft (text emptied, or the message is sent) removes the
///    bump too, so the conversation falls back to its real last-message time
///    with no separate "undo" bookkeeping needed — unlike the web version,
///    there's no persisted DOM order to restore; the list is re-sorted from
///    data every time, so removing the bump timestamp *is* the undo.
class DraftService {
  static final DraftService _instance = DraftService._internal();
  factory DraftService() => _instance;
  DraftService._internal();

  static const String _prefsKeyPrefix = 'chat_drafts_v1_';

  Map<String, _DraftEntry> _drafts = {};
  bool _loaded = false;
  int? _loadedForUserId;

  /// Bumps whenever any draft changes — screens showing conversation previews
  /// should listen to this (like `PendingIncomingCallService().pending`) and
  /// call `setState` on change.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  String _prefsKey(int userId) => '$_prefsKeyPrefix$userId';

  Future<void> _ensureLoaded() async {
    final userId = SocketService().currentUserId;
    if (userId == null) return;
    if (_loaded && _loadedForUserId == userId) return;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey(userId));
    final loadedDrafts = <String, _DraftEntry>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((key, value) {
          if (value is Map<String, dynamic>) {
            loadedDrafts[key] = _DraftEntry.fromJson(value);
          }
        });
      } catch (_) {
        // Corrupt/old-format value — start clean rather than throw.
      }
    }
    _drafts = loadedDrafts;
    _loaded = true;
    _loadedForUserId = userId;
  }

  Future<void> _persist() async {
    final userId = SocketService().currentUserId;
    if (userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
      _drafts.map((key, entry) => MapEntry(key, entry.toJson())),
    );
    await prefs.setString(_prefsKey(userId), encoded);
  }

  /// Loads persisted drafts for the current user. Call once early (e.g. lobby
  /// `initState`) so the synchronous getters below reflect real data; safe to
  /// call repeatedly.
  Future<void> load() async {
    final hadData = _loaded;
    await _ensureLoaded();
    if (!hadData) revision.value++; // let listeners refresh once data lands
  }

  /// Draft text for a room, seeded into a composer. Awaits load, so it's safe
  /// to call from a chat screen's `initState` even before the lobby has run.
  Future<String> loadText(String roomKey) async {
    await _ensureLoaded();
    return _drafts[roomKey]?.text ?? '';
  }

  /// Synchronous read for UI code (lobby tiles/sorting) — assumes [load] or
  /// [loadText] has already resolved at least once this session.
  String getText(String roomKey) => _drafts[roomKey]?.text ?? '';

  /// The moment this room was left with unsent text, or null if it was never
  /// bumped (or has since been cleared/sent).
  DateTime? getBumpTime(String roomKey) {
    final ms = _drafts[roomKey]?.bumpAtMs;
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Persists composer text for a room. Emptying the text removes the entry
  /// entirely (text + bump) — this is what makes clearing a draft undo a
  /// prior bump automatically.
  Future<void> setText(String roomKey, String text) async {
    await _ensureLoaded();
    if (text.trim().isEmpty) {
      if (!_drafts.containsKey(roomKey)) return;
      _drafts.remove(roomKey);
    } else {
      final existing = _drafts[roomKey];
      if (existing?.text == text) return;
      _drafts[roomKey] = _DraftEntry(text, existing?.bumpAtMs);
    }
    await _persist();
    revision.value++;
  }

  /// Called when a chat screen is disposed (the user left the room) while it
  /// still holds unsent text — marks the room as a recent action so the
  /// lobby's sort brings it to the top, like a real message would.
  Future<void> markLeftWithDraft(String roomKey) async {
    await _ensureLoaded();
    final existing = _drafts[roomKey];
    if (existing == null || existing.text.trim().isEmpty) return;
    if (existing.bumpAtMs != null) return; // already bumped — keep the original moment
    _drafts[roomKey] = _DraftEntry(
      existing.text,
      DateTime.now().millisecondsSinceEpoch,
    );
    await _persist();
    revision.value++;
  }

  /// Drops a draft entirely — used when the message is actually sent.
  Future<void> clear(String roomKey) async {
    await _ensureLoaded();
    if (!_drafts.containsKey(roomKey)) return;
    _drafts.remove(roomKey);
    await _persist();
    revision.value++;
  }
}
