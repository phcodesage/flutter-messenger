import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../models/excalidraw_room.dart';
import 'auth_error_handler.dart';
import 'storage_service.dart';

/// Self-hosted Excalidraw whiteboards, scoped per conversation.
///
/// Mirrors the web client (app/static/js/excalidraw-rooms-manager.js): the same
/// endpoints, the same conversation keys, and the same unread rule, so a board
/// created on either platform shows up on the other.
class ExcalidrawRoomsService {
  ExcalidrawRoomsService._();

  static final Random _random = Random.secure();

  /// Key identifying the conversation a board belongs to.
  ///
  /// Built from the sorted participant pair rather than "who I am talking to",
  /// so both sides of a DM derive the same key and therefore see the same
  /// boards. Getting this wrong is exactly how boards went missing on web.
  static String dmKey(int myUserId, int peerUserId) {
    final lo = myUserId < peerUserId ? myUserId : peerUserId;
    final hi = myUserId < peerUserId ? peerUserId : myUserId;
    return 'dm:$lo-$hi';
  }

  static String groupKey(int groupId) => 'group:$groupId';

  /// Conversation key for a 1:1 chat, or null if the user id is unavailable.
  static Future<String?> dmKeyForPeer(int peerUserId) async {
    final me = await StorageService.getUserId();
    if (me == null) return null;
    return dmKey(me, peerUserId);
  }

  // ---------------------------------------------------------------------
  // room id / key generation
  //
  // Must match what Excalidraw's own "Start session" produces, or the board
  // will not open: a 10-byte random hex id, and the JWK `k` of a 128-bit
  // AES-GCM key (base64url, unpadded, always 22 chars).
  // ---------------------------------------------------------------------

  static String generateRoomId() {
    final bytes = List<int>.generate(10, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String generateRoomKey() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static Future<Map<String, String>> _headers() async {
    final token = await StorageService.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static Future<bool> _handledAuthFailure(http.Response response) async {
    if (response.statusCode != 401) return false;
    await AuthErrorHandler().handleAuthError(
      message: 'Your session has expired. Please sign in again.',
    );
    return true;
  }

  /// Boards in one conversation, newest first. Never throws.
  static Future<List<ExcalidrawRoom>> list(String conversationKey) async {
    try {
      final response = await http
          .get(
            Uri.parse(ApiConfig.getExcalidrawRoomsUrl(conversationKey)),
            headers: await _headers(),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final rooms = (data['rooms'] as List?) ?? const [];
        return rooms
            .whereType<Map<String, dynamic>>()
            .map(ExcalidrawRoom.fromJson)
            .toList();
      }
      if (await _handledAuthFailure(response)) return [];
      debugPrint('[ExcalidrawRooms] list failed: ${response.statusCode}');
      return [];
    } catch (e) {
      debugPrint('[ExcalidrawRooms] list error: $e');
      return [];
    }
  }

  /// Create a board in this conversation. Throws with a readable message so
  /// the modal can surface it.
  static Future<ExcalidrawRoom> create({
    required String title,
    required String conversationKey,
  }) async {
    final response = await http
        .post(
          Uri.parse(ApiConfig.excalidrawRoomsBaseUrl),
          headers: await _headers(),
          body: jsonEncode({
            'title': title,
            'room_id': generateRoomId(),
            'room_key': generateRoomKey(),
            'conversation': conversationKey,
          }),
        )
        .timeout(ApiConfig.connectionTimeout);

    if (response.statusCode == 201) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ExcalidrawRoom.fromJson(data['room'] as Map<String, dynamic>);
    }
    await _handledAuthFailure(response);
    throw Exception(_errorFrom(response, 'Could not create the board'));
  }

  static Future<ExcalidrawRoom> rename(int entryId, String title) async {
    final response = await http
        .patch(
          Uri.parse(ApiConfig.getExcalidrawRoomEntryUrl(entryId)),
          headers: await _headers(),
          body: jsonEncode({'title': title}),
        )
        .timeout(ApiConfig.connectionTimeout);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ExcalidrawRoom.fromJson(data['room'] as Map<String, dynamic>);
    }
    await _handledAuthFailure(response);
    throw Exception(_errorFrom(response, 'Could not rename the board'));
  }

  static Future<void> delete(int entryId) async {
    final response = await http
        .delete(
          Uri.parse(ApiConfig.getExcalidrawRoomEntryUrl(entryId)),
          headers: await _headers(),
        )
        .timeout(ApiConfig.connectionTimeout);

    if (response.statusCode == 200) return;
    await _handledAuthFailure(response);
    throw Exception(_errorFrom(response, 'Could not delete the board'));
  }

  static String _errorFrom(http.Response response, String fallback) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['error'] is String) return body['error'] as String;
    } catch (_) {
      // Non-JSON error body; fall through.
    }
    return fallback;
  }

  static String boardUrl(ExcalidrawRoom room) =>
      ApiConfig.getExcalidrawBoardLink(room.roomId, room.roomKey);

  // ---------------------------------------------------------------------
  // unread bookkeeping
  //
  // A board change stays unread until the Excalidraw modal is opened for that
  // conversation. Stored as a timestamp rather than a set of ids so a rename
  // counts as new too — same rule as the web client.
  // ---------------------------------------------------------------------

  static const String _seenPrefix = 'excal_rooms_seen_v1:';

  static Future<DateTime?> seenAt(String conversationKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_seenPrefix$conversationKey');
      return raw == null ? null : DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<void> markSeen(String conversationKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_seenPrefix$conversationKey',
        DateTime.now().toUtc().toIso8601String(),
      );
    } catch (_) {
      // Storage unavailable; the badge just stays noisy.
    }
  }

  /// How many boards changed since this conversation's modal was last opened.
  static int countUnread({
    required List<ExcalidrawRoom> rooms,
    required DateTime? since,
    required int? myUserId,
  }) {
    var count = 0;
    for (final room in rooms) {
      final changed = room.changedAt;
      if (changed == null) continue;

      // A board you made that nobody has touched since is not news to you,
      // even on a device that has never opened the modal.
      final untouched =
          room.updatedAt == null || room.updatedAt == room.createdAt;
      if (myUserId != null && room.createdByUserId == myUserId && untouched) {
        continue;
      }
      if (since == null || changed.isAfter(since)) count++;
    }
    return count;
  }

  static Future<int> unreadCount(String conversationKey) async {
    final rooms = await list(conversationKey);
    return countUnread(
      rooms: rooms,
      since: await seenAt(conversationKey),
      myUserId: await StorageService.getUserId(),
    );
  }
}
