import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/message.dart';
import '../models/group.dart';
import 'chat_cache_service.dart';
import 'storage_service.dart';

/// Warms the local caches for *every* conversation in one request.
///
/// Without this, a thread only lands in Hive once the user has opened it, so on
/// a fresh install every room — and the AI chat — shows a spinner the first
/// time it is visited. [ChatCacheService.preloadConversation] cannot help there:
/// it only decodes what Hive already holds, and on a new install Hive is empty.
///
/// One `GET /api/mobile/prefetch_all` returns the recent tail of all 1:1
/// threads, all group threads and the newest AI session, which is then written
/// straight into the same caches the screens read from. After the first run the
/// call is incremental — it passes the highest message id already stored and
/// gets back only what is newer.
class PrefetchService {
  PrefetchService._();

  /// Messages pulled per conversation. Enough to fill a screen and scroll a
  /// little; full history still loads from the server when a chat is opened.
  static const int _perConversation = 30;

  /// Guards against two launches/resumes overlapping.
  static bool _running = false;

  /// Set once a run has completed in this process, so app-resume can skip the
  /// full sweep and do a cheap incremental instead.
  static bool _warmedThisSession = false;

  static bool get hasWarmed => _warmedThisSession;

  /// Fetch and cache everything. Safe to call on launch and on resume.
  ///
  /// [full] forces a complete refetch instead of an incremental one — used on
  /// first install and after login, where nothing local can be trusted.
  /// Returns the number of conversations written.
  static Future<int> warmAll({bool full = false}) async {
    if (_running) return 0;
    _running = true;
    try {
      final token = await StorageService.getToken();
      final userId = await StorageService.getUserId();
      if (token == null || userId == null) return 0;

      final since = full ? 0 : await StorageService.getPrefetchCursor(userId);

      final uri = Uri.parse(
        '${ApiConfig.baseUrl}${ApiConfig.mobilePrefix}/prefetch_all',
      ).replace(queryParameters: {
        'per_conv': '$_perConversation',
        if (since > 0) 'after_id': '$since',
      });

      final res = await http.get(uri, headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      }).timeout(ApiConfig.connectionTimeout);

      if (res.statusCode != 200) {
        debugPrint('[Prefetch] HTTP ${res.statusCode}');
        return 0;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      var written = 0;

      written += await _cacheDirectMessages(data['conversations'], userId);
      written += await _cacheGroupMessages(data['groups']);
      await _cacheAiSession(data['ai'], userId);

      // Only advance the cursor once everything above is safely stored, so a
      // failure part-way through is retried rather than skipped next launch.
      final newest = data['newest_id'];
      if (newest is int && newest > 0) {
        await StorageService.savePrefetchCursor(userId, newest);
      }

      _warmedThisSession = true;
      debugPrint('[Prefetch] warmed $written conversation(s), cursor=$newest');
      return written;
    } catch (e) {
      // Never fatal: the screens still load from the network on their own.
      debugPrint('[Prefetch] failed: $e');
      return 0;
    } finally {
      _running = false;
    }
  }

  static Future<int> _cacheDirectMessages(dynamic raw, int userId) async {
    if (raw is! Map) return 0;
    var n = 0;
    for (final entry in raw.entries) {
      final otherId = int.tryParse('${entry.key}');
      final list = entry.value;
      if (otherId == null || list is! List || list.isEmpty) continue;
      try {
        final messages = list
            .map((j) => Message.fromJson(j as Map<String, dynamic>))
            .toList();
        await ChatCacheService.saveConversationMessages(
          userId,
          otherId,
          messages,
        );
        n++;
      } catch (e) {
        debugPrint('[Prefetch] skipped DM $otherId: $e');
      }
    }
    return n;
  }

  static Future<int> _cacheGroupMessages(dynamic raw) async {
    if (raw is! Map) return 0;
    var n = 0;
    for (final entry in raw.entries) {
      final groupId = int.tryParse('${entry.key}');
      final list = entry.value;
      if (groupId == null || list is! List || list.isEmpty) continue;
      try {
        final messages = list
            .map((j) => GroupMessage.fromJson(j as Map<String, dynamic>))
            .toList();
        await ChatCacheService.saveGroupMessages(groupId, messages);
        n++;
      } catch (e) {
        debugPrint('[Prefetch] skipped group $groupId: $e');
      }
    }
    return n;
  }

  /// The AI transcript is a flat list of {role, content}, and its session id
  /// lives in SharedPreferences — store both so the AI screen can paint on its
  /// first frame instead of waiting on `/api/ai/...`.
  static Future<void> _cacheAiSession(dynamic raw, int userId) async {
    if (raw is! Map) return;
    final sessionId = raw['session_id'];
    final list = raw['messages'];
    if (sessionId is! int || list is! List || list.isEmpty) return;
    try {
      final messages = <Map<String, String>>[
        for (final m in list)
          if (m is Map)
            {
              'role': '${m['role'] ?? 'user'}',
              'content': '${m['content'] ?? ''}',
            }
      ];
      // saveAiSessionMessages also fills the in-memory slot that
      // peekLastAiSession reads, so the AI screen can paint on its first frame
      // without a further preload call.
      await ChatCacheService.saveAiSessionMessages(userId, sessionId, messages);
      await StorageService.saveAiSessionId(userId, sessionId);
    } catch (e) {
      debugPrint('[Prefetch] skipped AI session: $e');
    }
  }
}
