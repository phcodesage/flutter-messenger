import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../models/common_phrase.dart';
import 'storage_service.dart';

/// Service for managing common phrases API calls
class CommonPhrasesApi {
  static void _trace(String message) {
    if (kDebugMode) {
      debugPrint(message);
    }
  }

  CommonPhrasesApi({
    required this.baseUrl,
    this.recipientId,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final int? recipientId;
  final http.Client _client;

  Uri _roomUri(String path, [Map<String, String> query = const {}]) {
    final peerId = recipientId;
    if (peerId == null || peerId <= 0) {
      throw StateError('A direct-message recipient is required');
    }
    return Uri.parse('$baseUrl${ApiConfig.mobilePrefix}$path').replace(
      queryParameters: <String, String>{
        ...query,
        'recipient_id': peerId.toString(),
      },
    );
  }

  Future<String?> _cacheKey() async {
    final userId = await StorageService.getUserId();
    final peerId = recipientId;
    if (userId == null || peerId == null) return null;
    return 'common_phrases:$userId:$peerId';
  }

  Future<List<CommonPhrase>> loadCached() async {
    try {
      final key = await _cacheKey();
      if (key == null) return const <CommonPhrase>[];
      final raw = (await StorageService.getPreferences()).getString(key);
      if (raw == null || raw.isEmpty) return const <CommonPhrase>[];
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.whereType<Map<String, dynamic>>()
          .map(CommonPhrase.fromJson).toList(growable: false);
    } catch (_) {
      return const <CommonPhrase>[];
    }
  }

  Future<void> _saveCached(List<CommonPhrase> phrases) async {
    try {
      final key = await _cacheKey();
      if (key == null) return;
      await (await StorageService.getPreferences()).setString(
        key,
        jsonEncode(phrases.map((phrase) => phrase.toJson()).toList()),
      );
    } catch (_) {
      // Cache failures must never block the live API result.
    }
  }

  Future<Map<String, String>> _headers() async {
    final token = await StorageService.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  /// Fetch common phrases from server
  /// Default limit is 8, but user can override
  Future<List<CommonPhrase>> fetch({int limit = 8}) async {
    try {
      _trace('🔍 Fetching common phrases with limit: $limit');
      final uri = _roomUri('/messages/common-phrases', {
        'limit': '${limit < 3 ? 3 : limit}',
      });
      final res = await _client.get(uri, headers: await _headers());

      if (res.statusCode < 200 || res.statusCode >= 300) {
        _trace(
          '❌ Failed to fetch common phrases (${res.statusCode}): ${res.body}',
        );
        throw Exception(
          'Failed to fetch common phrases (${res.statusCode})',
        );
      }

      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (decoded['phrases'] as List<dynamic>? ?? <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(CommonPhrase.fromJson)
          .toList();

      await _saveCached(list);

      _trace('📦 Fetched ${list.length} common phrases');
      return list;
    } catch (e) {
      _trace('❌ Error fetching common phrases: $e');
      rethrow;
    }
  }

  /// Track usage of a phrase
  Future<void> trackUse(String phrase) async {
    try {
      _trace('📝 Tracking phrase usage: $phrase');
      final uri = _roomUri('/messages/common-phrases/use');
      final res = await _client.post(
        uri,
        headers: await _headers(),
        body: jsonEncode({'phrase': phrase, 'recipient_id': recipientId}),
      );

      if (res.statusCode < 200 || res.statusCode >= 300) {
        _trace(
          '❌ Failed to track phrase usage (${res.statusCode}): ${res.body}',
        );
        throw Exception(
          'Failed to track phrase usage (${res.statusCode})',
        );
      }

      _trace('✅ Phrase usage tracked');
    } catch (e) {
      _trace('❌ Error tracking phrase usage: $e');
      // Don't rethrow - this is a background operation
    }
  }

  /// Save a custom phrase — returns the created/updated [CommonPhrase]
  Future<CommonPhrase> savePhrase(String phrase) async {
    try {
      _trace('📝 Saving custom phrase: $phrase');
      final uri = _roomUri('/messages/common-phrases');
      final res = await _client.post(
        uri,
        headers: await _headers(),
        body: jsonEncode({'phrase': phrase, 'recipient_id': recipientId}),
      );

      if (res.statusCode < 200 || res.statusCode >= 300) {
        _trace(
          '❌ Failed to save phrase (${res.statusCode}): ${res.body}',
        );
        throw Exception('Failed to save phrase (${res.statusCode})');
      }

      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      _trace('✅ Phrase saved');
      return CommonPhrase.fromJson(
        decoded['phrase'] as Map<String, dynamic>,
      );
    } catch (e) {
      _trace('❌ Error saving phrase: $e');
      rethrow;
    }
  }

  /// Generate a phrase using AI (Ollama) via the mobile Bearer-token endpoint
  Future<String> generatePhrase() async {
    try {
      final url = ApiConfig.aiGeneratePhraseUrl;
      _trace('🤖 AI generate phrase → POST $url');

      final headers = await _headers();
      _trace('🔑 Auth header present: ${headers.containsKey('Authorization')}');

      final res = await _client.post(
        Uri.parse(url),
        headers: headers,
        body: jsonEncode({}),
      );

      _trace('📡 AI response status: ${res.statusCode}');
      _trace('📡 AI response body:   ${res.body}');

      if (res.statusCode == 401) {
        throw Exception('Unauthorized — token may be expired (401)');
      }
      if (res.statusCode == 502) {
        throw Exception('Ollama AI service unreachable (502)');
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('AI generate failed (${res.statusCode}): ${res.body}');
      }

      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final phrase = (decoded['phrase'] ?? '').toString().trim();
      if (phrase.isEmpty) {
        throw Exception('AI returned an empty phrase');
      }
      _trace('✅ AI generated phrase: $phrase');
      return phrase;
    } catch (e) {
      _trace('❌ Error generating AI phrase: $e');
      rethrow;
    }
  }

  /// Pin a phrase server-side (mobile max: 3)
  Future<CommonPhrase> pinPhrase(int phraseId) async {
    try {
      _trace('📌 Pinning phrase $phraseId');
      final uri = _roomUri('/messages/common-phrases/$phraseId/pin');
      final res = await _client.post(uri, headers: await _headers());

      if (res.statusCode == 400) {
        final decoded = jsonDecode(res.body) as Map<String, dynamic>;
        throw Exception(decoded['error'] ?? 'Max pins reached');
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('Failed to pin phrase (${res.statusCode})');
      }

      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      _trace('✅ Phrase pinned');
      return CommonPhrase.fromJson(
        decoded['phrase'] as Map<String, dynamic>,
      );
    } catch (e) {
      _trace('❌ Error pinning phrase: $e');
      rethrow;
    }
  }

  /// Unpin a phrase server-side
  Future<CommonPhrase> unpinPhrase(int phraseId) async {
    try {
      _trace('📌 Unpinning phrase $phraseId');
      final uri = _roomUri('/messages/common-phrases/$phraseId/unpin');
      final res = await _client.post(uri, headers: await _headers());

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('Failed to unpin phrase (${res.statusCode})');
      }

      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      _trace('✅ Phrase unpinned');
      return CommonPhrase.fromJson(
        decoded['phrase'] as Map<String, dynamic>,
      );
    } catch (e) {
      _trace('❌ Error unpinning phrase: $e');
      rethrow;
    }
  }

  /// Reorder pinned phrases by passing phrase IDs in desired sequence
  Future<void> reorderPins(List<int> phraseIds) async {
    try {
      _trace('🔀 Reordering pins: $phraseIds');
      final uri = _roomUri('/messages/common-phrases/pins/reorder');
      final res = await _client.post(
        uri,
        headers: await _headers(),
        body: jsonEncode({
          'phrase_ids': phraseIds,
          'recipient_id': recipientId,
        }),
      );

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('Failed to reorder pins (${res.statusCode})');
      }
      _trace('✅ Pins reordered');
    } catch (e) {
      _trace('❌ Error reordering pins: $e');
      rethrow;
    }
  }

  /// Delete a custom phrase by ID
  Future<void> deletePhrase(int phraseId) async {
    try {
      _trace('🗑️ Deleting phrase with ID: $phraseId');
      final uri = _roomUri('/messages/common-phrases/$phraseId');
      final res = await _client.delete(uri, headers: await _headers());

      if (res.statusCode < 200 || res.statusCode >= 300) {
        _trace(
          '❌ Failed to delete phrase (${res.statusCode}): ${res.body}',
        );
        throw Exception('Failed to delete phrase (${res.statusCode})');
      }

      _trace('✅ Phrase deleted');
    } catch (e) {
      _trace('❌ Error deleting phrase: $e');
      rethrow;
    }
  }
}
