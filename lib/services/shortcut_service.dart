import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:async';

import '../models/lobby_user.dart';

/// Publishes Android Sharing Shortcuts so the app's contacts appear in the
/// "Direct Share" top row of the Android share sheet (API 25+).
///
/// Call [publishShareTargets] whenever the contact list changes.
class ShortcutService {
  ShortcutService._();

  static final ShortcutService instance = ShortcutService._();

  static const _channel = MethodChannel(
    'com.example.flutter_messenger_v2/shortcuts',
  );

  final StreamController<int> _shortcutTargetController =
      StreamController<int>.broadcast();
  bool _initialized = false;
  int? _pendingShortcutUserId;

  Stream<int> get shortcutTargetStream => _shortcutTargetController.stream;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_onMethodCall);

    try {
      final result = await _channel.invokeMethod<dynamic>(
        'consumeInitialShortcutTarget',
      );
      final userId = _parseUserId(result);
      if (userId != null) {
        _pendingShortcutUserId = userId;
        _shortcutTargetController.add(userId);
      }
    } catch (e) {
      debugPrint('ShortcutService.initialize: $e');
    }
  }

  Future<int?> takePendingShortcutUserId() async {
    final current = _pendingShortcutUserId;
    _pendingShortcutUserId = null;
    return current;
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method != 'onShortcutTarget') {
      return null;
    }

    final userId = _parseUserId(call.arguments);
    if (userId == null) {
      return null;
    }

    _pendingShortcutUserId = userId;
    _shortcutTargetController.add(userId);
    return null;
  }

  int? _parseUserId(dynamic raw) {
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static Future<void> publishShareTargets(
    List<LobbyUser> users, {
    int? selfUserId,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      // Always surface the self-chat ("yourself") as a Direct Share target —
      // like WhatsApp's "You" — regardless of how recently it was used. Pin it
      // to the front, then fill with the most-recent contacts, dedup, cap at 4.
      // (Stay within Android's guaranteed max of 5 dynamic shortcuts/activity;
      // exceeding it makes addDynamicShortcuts drop them all.)
      final ordered = <LobbyUser>[];
      final seen = <int>{};
      if (selfUserId != null) {
        final selfIdx = users.indexWhere((u) => u.id == selfUserId);
        if (selfIdx != -1) {
          ordered.add(users[selfIdx]);
          seen.add(selfUserId);
        }
      }
      for (final u in users) {
        if (seen.add(u.id)) ordered.add(u);
      }

      await _channel.invokeMethod<void>(
        'pushShareTargets',
        ordered
            .take(4)
            .map(
              (u) => <String, Object>{
                'id': u.id,
                'name': u.id == selfUserId
                    ? (u.fullName.trim().isEmpty ? 'You' : '${u.fullName} (You)')
                    : u.fullName,
                'avatarColorIndex': u.avatarColorIndex,
              },
            )
            .toList(),
      );
    } catch (e) {
      debugPrint('ShortcutService.publishShareTargets: $e');
    }
  }

  static Future<void> reportShareUsed(int userId) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('reportShareUsed', {
        'userId': userId.toString(),
      });
    } catch (e) {
      debugPrint('ShortcutService.reportShareUsed: $e');
    }
  }
}
