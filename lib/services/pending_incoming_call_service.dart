import 'package:flutter/foundation.dart';

/// Holds an incoming call that arrived while the user was viewing a DIFFERENT
/// conversation than the caller.
///
/// Mirrors the web client: instead of popping the full-screen incoming-call
/// modal over the wrong room (which makes the user answer from the wrong chat),
/// the modal is deferred. The lobby shows a "📞 Incoming call…" indicator on the
/// caller's tile and the chat screen shows an in-chat banner. When the user opens
/// the caller's conversation, the modal is surfaced and the call is answered from
/// the caller's room.
class PendingIncomingCallService {
  static final PendingIncomingCallService _instance =
      PendingIncomingCallService._internal();
  factory PendingIncomingCallService() => _instance;
  PendingIncomingCallService._internal();

  /// The deferred `incoming_call` payload, or null when nothing is pending.
  /// Exposed as a [ValueNotifier] so the lobby list can reactively show/clear
  /// its ringing indicator.
  final ValueNotifier<Map<String, dynamic>?> pending =
      ValueNotifier<Map<String, dynamic>?>(null);

  /// The user id of the caller whose call is currently deferred, or null.
  int? get pendingCallerId {
    final p = pending.value;
    if (p == null) return null;
    final caller = p['caller'];
    if (caller is Map && caller['id'] is int) return caller['id'] as int;
    final id = p['caller_id'];
    return id is int ? id : null;
  }

  /// Store [data] as the deferred incoming call.
  void setPending(Map<String, dynamic> data) {
    pending.value = Map<String, dynamic>.from(data);
  }

  /// Return and clear the deferred call if it is from [callerId]; else null.
  Map<String, dynamic>? takeForCaller(int callerId) {
    if (pendingCallerId == callerId) {
      final data = pending.value;
      pending.value = null;
      return data;
    }
    return null;
  }

  /// Clear unconditionally (no-op if nothing pending).
  void clear() {
    if (pending.value != null) pending.value = null;
  }

  /// Clear the deferred call when a terminal event matches it (caller hung up,
  /// declined, accepted elsewhere, etc.).
  void clearIfMatches({String? callRoomId, int? callerId}) {
    final p = pending.value;
    if (p == null) return;
    if (callRoomId != null && p['call_room_id']?.toString() == callRoomId) {
      pending.value = null;
      return;
    }
    if (callerId != null && pendingCallerId == callerId) {
      pending.value = null;
    }
  }
}
