import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/message.dart';
import 'message_service.dart';
import 'socket_service.dart';

/// Progress update emitted by [TextMessageRetryService] for a specific text message.
class TextRetryProgress {
  /// The optimistic ID of the message.
  final int optimisticId;

  /// The created message on successful upload.
  final Message? message;

  /// Whether the retry was successful.
  final bool success;

  const TextRetryProgress({
    required this.optimisticId,
    this.message,
    required this.success,
  });
}

/// A pending text message that failed due to network issues
/// and is queued for automatic retry when connectivity is restored.
class _PendingTextMessage {
  /// The original optimistic ID.
  final int optimisticId;

  /// Recipient user ID.
  final int recipientId;

  /// The text content.
  final String content;

  /// Optional reply ID.
  final int? replyToId;

  /// Number of retry attempts already made.
  int retryCount;

  _PendingTextMessage({
    required this.optimisticId,
    required this.recipientId,
    required this.content,
    this.replyToId,
    this.retryCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'optimisticId': optimisticId,
        'recipientId': recipientId,
        'content': content,
        'replyToId': replyToId,
        'retryCount': retryCount,
      };

  factory _PendingTextMessage.fromJson(Map<String, dynamic> json) =>
      _PendingTextMessage(
        optimisticId: json['optimisticId'] as int,
        recipientId: json['recipientId'] as int,
        content: json['content'] as String,
        replyToId: json['replyToId'] as int?,
        retryCount: json['retryCount'] as int? ?? 0,
      );
}

/// Global singleton that manages text messages which failed due to
/// temporary network issues and automatically retries them when
/// the device comes back online.
class TextMessageRetryService {
  static final TextMessageRetryService _instance =
      TextMessageRetryService._internal();
  factory TextMessageRetryService() => _instance;
  TextMessageRetryService._internal();

  final List<_PendingTextMessage> _queue = [];
  static late Box _retryBox;

  final StreamController<TextRetryProgress> _progressController =
      StreamController<TextRetryProgress>.broadcast();

  /// Emits progress updates for queued messages while they are being retried.
  Stream<TextRetryProgress> get progressStream => _progressController.stream;

  /// Whether there are messages currently waiting for connectivity.
  bool get hasPendingMessages => _queue.isNotEmpty;

  /// Initialize the retry box and load any persisted queue items.
  Future<void> initialize() async {
    _retryBox = await Hive.openBox('text_message_retry_cache');
    final data = _retryBox.get('queue') as List?;
    if (data != null) {
      _queue.clear();
      for (final item in data) {
        if (item is Map) {
          final job =
              _PendingTextMessage.fromJson(Map<String, dynamic>.from(item));
          _queue.add(job);
        }
      }
      debugPrint('✉️ Loaded ${_queue.length} pending text messages from cache');
    }

    // Listen for connectivity changes to automatically retry
    Connectivity().onConnectivityChanged.listen((results) {
      if (results.isNotEmpty && results.first != ConnectivityResult.none) {
        if (_queue.isNotEmpty) {
          debugPrint('📡 Connectivity restored, retrying text messages...');
          retryAll();
        }
      }
    });

    // Also listen for socket reconnection to retry immediately via WebSockets
    SocketService().addListener('reconnected', 'TextMessageRetryService', () {
      if (_queue.isNotEmpty) {
        debugPrint('🔌 Socket reconnected, retrying text messages...');
        retryAll();
      }
    });
  }

  /// Persists the current queue state.
  Future<void> _persistQueue() async {
    final list = _queue.map((job) => job.toJson()).toList();
    await _retryBox.put('queue', list);
  }

  /// Queues a failed text message for automatic retry.
  Future<void> queueMessage({
    required int optimisticId,
    required int recipientId,
    required String content,
    int? replyToId,
  }) async {
    // Avoid duplicate queuing
    if (_queue.any((job) => job.optimisticId == optimisticId)) return;

    _queue.add(
      _PendingTextMessage(
        optimisticId: optimisticId,
        recipientId: recipientId,
        content: content,
        replyToId: replyToId,
      ),
    );

    await _persistQueue();

    debugPrint(
      '✉️ Queued text message for retry (queue size: ${_queue.length})',
    );
  }

  bool _isRetrying = false;

  /// Retries all pending messages sequentially.
  Future<void> retryAll() async {
    if (_queue.isEmpty) {
      debugPrint('✉️ No pending text messages to retry');
      return;
    }

    if (_isRetrying) {
      debugPrint('✉️ Retry already in progress, skipping');
      return;
    }
    _isRetrying = true;

    try {
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none)) {
        debugPrint('✉️ Device is offline, skipping retry');
        return;
      }

      final toRetry = List<_PendingTextMessage>.from(_queue);
      debugPrint('🔄 Retrying ${toRetry.length} pending text messages...');

      final socketService = SocketService();

      // If the socket is not connected yet, wait up to 2 seconds (10 x 200ms)
      // for the connection handshake to complete, so we can send via socket instead of REST fallback.
      if (!socketService.isConnected) {
        debugPrint('✉️ Socket is disconnected. Waiting up to 2s for connection...');
        for (int i = 0; i < 10; i++) {
          await Future.delayed(const Duration(milliseconds: 200));
          if (socketService.isConnected) {
            debugPrint('✉️ Socket connected after waiting ${ (i + 1) * 200 }ms');
            break;
          }
        }
      }

      for (final job in toRetry) {
        try {
          job.retryCount++;
          
          if (socketService.isConnected) {
            debugPrint('✉️ Socket is connected, sending via socket for real-time delivery');
            await socketService.sendMessage(
              recipientId: job.recipientId,
              content: job.content,
              messageType: 'text',
              replyToId: job.replyToId,
            );
            
            // Encryption completes before the socket emission. The chat screen
            // handles the eventual messageSent echo.
            _queue.removeWhere((q) => q.optimisticId == job.optimisticId);
            await _persistQueue();
            debugPrint('✅ Successfully retried text message via socket ${job.optimisticId}');
            continue;
          }

          final sentMessage = await MessageService.sendMessage(
            recipientId: job.recipientId,
            content: job.content,
            messageType: 'text',
            replyToId: job.replyToId,
          );

        if (sentMessage != null) {
          _queue.removeWhere((q) => q.optimisticId == job.optimisticId);
          await _persistQueue();

          _progressController.add(
            TextRetryProgress(
              optimisticId: job.optimisticId,
              message: sentMessage,
              success: true,
            ),
          );

          debugPrint('✅ Successfully retried text message ${job.optimisticId}');
        }
      } catch (e) {
        debugPrint('❌ Failed to retry text message ${job.optimisticId}: $e');
        await _persistQueue();
        
        // Wait briefly before trying the next one if network is flaky
        }
      }
    } finally {
      _isRetrying = false;
    }
  }
}
