import 'dart:async';

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
///
/// Pending calls expire on their own. Clearing used to depend entirely on
/// receiving a terminal signal (`call-cancelled` / `call-ended`), so if that
/// signal was missed — phone asleep, socket dropped, app backgrounded while the
/// call ended on another device — the offer stayed on screen indefinitely. A
/// user signed in on web and mobile could finish a call on web and still find
/// the phone showing the offer minutes later.
class PendingIncomingCallService {
  static final PendingIncomingCallService _instance =
      PendingIncomingCallService._internal();
  factory PendingIncomingCallService() => _instance;
  PendingIncomingCallService._internal();

  /// How long an unanswered offer stays valid. Matches
  /// CALL_RING_TIMEOUT_SECONDS in app/utils/socket_events.py — past this the
  /// server has already abandoned the call, so the offer cannot be answered.
  static const Duration ringTtl = Duration(seconds: 60);

  /// The deferred `incoming_call` payload, or null when nothing is pending.
  /// Exposed as a [ValueNotifier] so the lobby list can reactively show/clear
  /// its ringing indicator.
  final ValueNotifier<Map<String, dynamic>?> pending =
      ValueNotifier<Map<String, dynamic>?>(null);

  /// Bumped whenever an offer is dropped because it aged out rather than being
  /// answered, declined or cancelled — lets a screen close a modal it opened.
  final ValueNotifier<int> expired = ValueNotifier<int>(0);

  DateTime? _setAt;
  Timer? _expiryTimer;

  /// The user id of the caller whose call is currently deferred, or null.
  int? get pendingCallerId {
    final p = pending.value;
    if (p == null) return null;
    final caller = p['caller'];
    if (caller is Map && caller['id'] is int) return caller['id'] as int;
    final id = p['caller_id'];
    return id is int ? id : null;
  }

  /// How long the current offer has been pending, or null if there isn't one.
  Duration? get age =>
      _setAt == null ? null : DateTime.now().difference(_setAt!);

  /// Store [data] as the deferred incoming call.
  void setPending(Map<String, dynamic> data) {
    pending.value = Map<String, dynamic>.from(data);
    _setAt = DateTime.now();
    _expiryTimer?.cancel();
    _expiryTimer = Timer(ringTtl, _expire);
  }

  void _expire() {
    if (pending.value == null) return;
    debugPrint('[PendingCall] offer expired after ${ringTtl.inSeconds}s — clearing');
    _reset();
    expired.value++;
  }

  /// Drop the offer if it has already outlived [ringTtl].
  ///
  /// Call this when the app returns to the foreground or the socket reconnects.
  /// A [Timer] does not reliably fire while the process is suspended, so on
  /// resume the age has to be checked explicitly — which is exactly the case
  /// where a stale offer is still sitting on screen.
  bool expireIfStale() {
    final a = age;
    if (pending.value == null || a == null || a < ringTtl) return false;
    debugPrint('[PendingCall] stale offer on resume (${a.inSeconds}s old) — clearing');
    _reset();
    expired.value++;
    return true;
  }

  /// Return and clear the deferred call if it is from [callerId]; else null.
  ///
  /// Returns null for an offer that has already aged out, so opening the
  /// caller's conversation can never pop a modal for a call that ended minutes
  /// ago — it just clears the stale entry instead.
  Map<String, dynamic>? takeForCaller(int callerId) {
    if (pendingCallerId != callerId) return null;
    if (expireIfStale()) return null;
    final data = pending.value;
    _reset();
    return data;
  }

  /// Clear unconditionally (no-op if nothing pending).
  void clear() {
    if (pending.value != null) _reset();
  }

  void _reset() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _setAt = null;
    pending.value = null;
  }

  /// Clear the deferred call when a terminal event matches it (caller hung up,
  /// declined, accepted elsewhere, etc.).
  void clearIfMatches({String? callRoomId, int? callerId}) {
    final p = pending.value;
    if (p == null) return;
    if (callRoomId != null && p['call_room_id']?.toString() == callRoomId) {
      _reset();
      return;
    }
    if (callerId != null && pendingCallerId == callerId) {
      _reset();
    }
  }
}
