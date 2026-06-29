import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:mime/mime.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../models/group.dart';
import '../models/common_phrase.dart';
import '../models/message.dart';
import '../models/lobby_user.dart';
import '../config/api_config.dart';
import '../services/group_service.dart';
import '../services/common_phrases_api.dart';
import '../services/forward_service.dart';
import '../services/lobby_service.dart';
import '../services/socket_service.dart';
import '../services/storage_service.dart';
import 'group_call_screen.dart';
import '../services/chat_cache_service.dart';
import '../services/media_preload_service.dart';
import '../services/translation_service.dart';
import '../services/active_chat_service.dart';
import '../services/firebase_messaging_service.dart';
import '../widgets/reaction_picker.dart';
import '../widgets/color_picker_modal.dart';
import '../widgets/voice_recording_modal.dart';
import '../widgets/common_phrase_bar.dart';
import '../widgets/common_phrases_sheet.dart';
import '../widgets/forward_recipient_picker.dart';
import '../widgets/cached_image.dart';
import '../widgets/file_type_icon.dart';
import '../widgets/file_preview_modal_content.dart';
import 'chat/chat_date_separator.dart';
import 'chat/swipeable_message.dart';
import 'chat/chat_header.dart';
import 'chat/chat_message_bubble.dart';
import 'chat/chat_composer_panel.dart';
import 'media_gallery_viewer.dart';

/// Group chat screen for messaging in a group
class GroupChatScreen extends StatefulWidget {
  final Group group;

  const GroupChatScreen({super.key, required this.group});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  static const MethodChannel _fileOpsChannel = MethodChannel(
    'com.example.flutter_messenger_v2/file_ops',
  );

  final SocketService _socketService = SocketService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _inputScrollController = ScrollController();

  /// Tap recognizers created for linkified message URLs; disposed in dispose().
  final List<TapGestureRecognizer> _linkRecognizers = [];

  List<GroupMessage> _messages = [];
  bool _isLoading = true;
  bool _isLoadingMessages = false;
  int? _currentUserId;

  // Scroll to bottom button state
  bool _isAtBottom = true;
  int _unreadCount = 0;
  bool _userHasScrolledManually = false;

  // Reply state
  GroupMessage? _replyingToMessage;

  // Reaction state
  final Map<int, Map<String, Set<String>>> _messageReactions = {};

  // Action buttons state
  bool _showActionButtons = false;

  // Emoji picker state for chat input
  bool _showEmojiPicker = false;
  int _emojiCategoryIndex = 0;

  // Keyboard visibility state
  bool _isKeyboardVisible = false;

  // Timestamp visibility toggle
  bool _showTimestamps = false;

  // Auto-translate toggle
  bool _autoTranslate = false;

  // Common phrases quick-bar (mobile-pinned phrases) state
  late final CommonPhrasesApi _commonPhrasesApi = CommonPhrasesApi(
    baseUrl: ApiConfig.baseUrl,
  );
  List<CommonPhrase> _commonPhrases = const [];
  bool _hideCommonPhrases = false;

  // Translation state: { messageId: translatedText }
  final Map<int, String> _messageTranslations = {};

  // Task modal version and state
  final ValueNotifier<int> _taskModalVersion = ValueNotifier<int>(0);
  String _taskFilter = 'pending';
  final Map<int, GlobalKey> _messageItemKeys = {};
  int? _bubbleFlashId;

  void _notifyTaskModalChanged() {
    _taskModalVersion.value = _taskModalVersion.value + 1;
  }

  // File upload state for preview modal
  bool _isActivelyUploading = false;
  final ValueNotifier<double> _activeUploadProgressNotifier =
      ValueNotifier<double>(0.0);
  File? _pendingFile;
  String? _pendingFileName;
  String? _pendingFileMimeType;
  bool _pendingFileIsFromCamera = false;

  // Color customization (for group chat theme)
  Color _headerColor = const Color(0xFF4C1D95); // Default purple color
  bool _showResetButton = false;

  // Admin status
  bool _currentUserIsAdmin = false;

  // Mutable group header info (kept in sync when edited/members change)
  late String _groupName = widget.group.name;
  late String _groupDescription = widget.group.description ?? '';
  late int _memberCount = widget.group.memberCount;

  // Typing indicator state
  String _typingUserName = '';
  String _typingMessage = '';
  Timer? _typingHideTimer;
  Timer? _typingEmitTimer;

  @override
  void initState() {
    super.initState();
    _inputFocusNode.addListener(_onFocusChange);
    _scrollController.addListener(_onScroll);
    _messageController.addListener(_syncCommonPhrasesVisibility);

    _initialize();

    // Set this group as active to prevent FCM notifications
    ActiveChatService().setActiveGroup(widget.group.id);

    // Debug: Periodic connection check (commented out to reduce noise)
    /*
    Timer.periodic(const Duration(seconds: 10), (timer) {
      if (mounted) {
        debugPrint(
          '🔌 [GROUP CHAT] Socket connected: ${_socketService.isConnected}',
        );
      } else {
        timer.cancel();
      }
    });
    */
  }

  Future<void> _initialize() async {
    debugPrint(
      '🎨 [INIT] Starting initialization for group ${widget.group.id}',
    );
    _currentUserId = await StorageService.getUserId();
    _currentUserIsAdmin = await StorageService.getIsAdmin();
    debugPrint('🎨 [INIT] Current user ID: $_currentUserId');
    unawaited(
      FirebaseMessagingService.instance.clearConversationNotificationState(
        groupId: widget.group.id,
        senderName: widget.group.name,
      ),
    );

    // Cache-first: render any locally stored messages immediately so the
    // screen never sits on a shimmer while the network round-trip happens.
    await _loadCachedGroupMessages();

    // Refresh from network in the background. _loadMessages will only flip
    // _isLoading on if the cache was empty (true cold open).
    unawaited(_loadMessages());

    await _loadSavedGroupChatColor(); // Load saved color
    debugPrint('🎨 [INIT] Setting up realtime listeners...');
    _setupRealtimeListeners();
    debugPrint('🎨 [INIT] Joining group chat...');
    _socketService.joinGroupChat(widget.group.id);

    unawaited(_loadCommonPhrases());
  }

  /// Load mobile-pinned common phrases for the quick bar above the composer.
  Future<void> _loadCommonPhrases() async {
    try {
      final phrases = await _commonPhrasesApi.fetch(limit: 8);
      final pinnedOnly = phrases.where((p) => p.isPinnedMobile).toList()
        ..sort(
          (a, b) => (a.pinOrderMobile ?? 99).compareTo(b.pinOrderMobile ?? 99),
        );
      if (mounted) {
        setState(() {
          _commonPhrases = pinnedOnly.take(kMobileMaxPins).toList();
        });
      }
    } catch (e) {
      // Non-critical feature — fail silently.
      debugPrint('Error loading group common phrases: $e');
    }
  }

  /// Hide the phrase bar while the user is composing text.
  void _syncCommonPhrasesVisibility() {
    final shouldHide = _messageController.text.trim().isNotEmpty;
    if (_hideCommonPhrases != shouldHide && mounted) {
      setState(() => _hideCommonPhrases = shouldHide);
    }
  }

  /// Tapping a phrase chip sends it immediately.
  Future<void> _onCommonPhraseChipTap(CommonPhrase phrase) async {
    final phraseText = phrase.phrase.trim();
    if (phraseText.isEmpty) return;
    _messageController.text = phraseText;
    await _sendMessage();
    unawaited(_commonPhrasesApi.trackUse(phraseText));
  }

  void _showCommonPhrasesModal() {
    showCommonPhrasesSheet(
      context,
      api: _commonPhrasesApi,
      onChanged: _loadCommonPhrases,
    );
  }

  void _syncGroupColorFromMessages(List<GroupMessage> messages) {
    final themeColorHex = widget.group.themeColor;
    if (themeColorHex == null || themeColorHex.isEmpty) {
      if (mounted) {
        setState(() {
          _headerColor = const Color(0xFF4C1D95);
          _showResetButton = false;
        });
      }
      _clearGroupChatColor();
      return;
    }

    GroupMessage? latestColorMsg;
    // Scan messages list from the end (newest) to the beginning (oldest) since it is chronological
    for (int i = messages.length - 1; i >= 0; i--) {
      final msg = messages[i];
      if (msg.messageType == 'system' &&
          (msg.content.contains('Changed background color') ||
              msg.content.contains('Reset background color') ||
              msg.content.contains('changed the group chat color') ||
              msg.content.contains('reset the group chat color'))) {
        latestColorMsg = msg;
        break;
      }
    }

    if (latestColorMsg != null) {
      final isResetMsg =
          latestColorMsg.content.contains('Reset') ||
          latestColorMsg.content.contains('reset');
      if (isResetMsg) {
        // Unconditionally reset to default color
        if (mounted) {
          setState(() {
            _headerColor = const Color(0xFF4C1D95);
            _showResetButton = false;
          });
        }
        _clearGroupChatColor();
      } else {
        // Color change message
        final isFromSelf = latestColorMsg.senderId == _currentUserId;
        if (isFromSelf) {
          // We set it! Do not apply, keep/reset to default color
          if (mounted) {
            setState(() {
              _headerColor = const Color(0xFF4C1D95);
              _showResetButton = false;
            });
          }
          _clearGroupChatColor();
        } else {
          // Someone else set it! Apply it
          try {
            final hexColor = themeColorHex.replaceAll('#', '');
            final color = Color(int.parse('FF$hexColor', radix: 16));
            if (mounted) {
              setState(() {
                _headerColor = color;
                _showResetButton = true;
              });
            }
            _saveGroupChatColor(themeColorHex);
          } catch (e) {
            debugPrint('Error parsing group theme color from history: $e');
          }
        }
      }
    } else {
      // No system message found in the list, apply theme color by default
      try {
        final hexColor = themeColorHex.replaceAll('#', '');
        final color = Color(int.parse('FF$hexColor', radix: 16));
        if (mounted) {
          setState(() {
            _headerColor = color;
            _showResetButton = true;
          });
        }
        _saveGroupChatColor(themeColorHex);
      } catch (e) {
        debugPrint('Error parsing group theme color from history: $e');
      }
    }
  }

  /// Mirrors the 1:1 chat's `_loadCachedMessages` so reopening a group feels
  /// instant even before the network refresh resolves.
  Future<void> _loadCachedGroupMessages() async {
    try {
      final cached = await ChatCacheService.loadGroupMessages(widget.group.id);
      if (!mounted) return;
      if (cached.isEmpty) {
        // Leave _isLoading = true so the shimmer is shown on true cold open.
        return;
      }
      _syncGroupColorFromMessages(cached);
      setState(() {
        _messages = cached;
        _isLoading = false;
      });
      // Jump to bottom and schedule checks as dynamic items/files render.
      _scrollEntryToBottom();
    } catch (e) {
      debugPrint('Error loading cached group messages: $e');
    }
  }

  void _onFocusChange() {
    // Only update if keyboard visibility actually changed
    final isVisible = _inputFocusNode.hasFocus;
    if (_isKeyboardVisible != isVisible) {
      setState(() {
        _isKeyboardVisible = isVisible;
        // Auto-close emoji picker when keyboard opens (user tapped text field)
        if (isVisible && _showEmojiPicker) {
          _showEmojiPicker = false;
        }
      });
      if (isVisible && _isAtBottom) {
        _scrollToBottomWithRetry();
      }
    }
  }

  void _showTopSnackBar(SnackBar snackBar) {
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.hideCurrentMaterialBanner();

    final actions = <Widget>[];
    if (snackBar.action != null) {
      actions.add(
        TextButton(
          onPressed: () {
            messenger.hideCurrentMaterialBanner();
            snackBar.action!.onPressed();
          },
          child: Text(
            snackBar.action!.label,
            style: TextStyle(color: snackBar.action!.textColor ?? Colors.white),
          ),
        ),
      );
    }

    actions.add(
      TextButton(
        onPressed: messenger.hideCurrentMaterialBanner,
        child: const Text('DISMISS', style: TextStyle(color: Colors.white)),
      ),
    );

    messenger.showMaterialBanner(
      MaterialBanner(
        content: snackBar.content,
        backgroundColor: snackBar.backgroundColor ?? const Color(0xFF323232),
        contentTextStyle: const TextStyle(color: Colors.white),
        actions: actions,
      ),
    );

    final autoHide = snackBar.duration;
    if (autoHide > Duration.zero) {
      Timer(autoHide, () {
        if (mounted) {
          messenger.hideCurrentMaterialBanner();
        }
      });
    }
  }

  void _setupRealtimeListeners() {
    final key = 'group_chat_${widget.group.id}';

    debugPrint('🎨 [SETUP] Setting up listeners with key: $key');

    // Debug: Check socket connection status (commented out to reduce noise)
    /*
    debugPrint(
      '🔌 [GROUP CHAT] Setting up listeners, socket connected: ${_socketService.isConnected}',
    );
    */

    // Debug: Test response listener (commented out to reduce noise)
    /*
    _socketService.addListener('test_response', key, (data) {
      debugPrint('🧪 [TEST RESPONSE] Received in group chat screen: $data');
      debugPrint(
        '🧪 [TEST RESPONSE] This confirms mobile can receive Socket.IO events!',
      );
    });
    */

    // Debug: Connection change listener (commented out to reduce noise)
    /*
    _socketService.addListener('connectionChanged', key, (data) {
      debugPrint('🔌 [GROUP CHAT] Connection changed: $data');
    });
    */

    // New message from another member
    _socketService.addListener('groupNewMessage', key, (data) {
      debugPrint(
        '💬 [GROUP NEW MESSAGE] Event received for group ${widget.group.id}',
      );
      debugPrint('💬 [GROUP NEW MESSAGE] Full data: $data');
      debugPrint('💬 [GROUP NEW MESSAGE] Data type: ${data.runtimeType}');
      debugPrint(
        '💬 [GROUP NEW MESSAGE] Group ID in data: ${data['group_id']}',
      );
      debugPrint('💬 [GROUP NEW MESSAGE] Current group ID: ${widget.group.id}');

      if (data['group_id'] == widget.group.id) {
        debugPrint(
          '💬 [GROUP NEW MESSAGE] Processing message for current group',
        );
        _handleNewMessage(data);
      } else {
        debugPrint(
          '💬 [GROUP NEW MESSAGE] Ignoring message for different group: ${data['group_id']}',
        );
      }
    });

    // Message sent confirmation
    _socketService.addListener('groupMessageSent', key, (data) {
      debugPrint('📤 [GROUP MESSAGE SENT] Event received: $data');
      if (data['group_id'] == widget.group.id) {
        debugPrint('📤 [GROUP MESSAGE SENT] Processing for current group');
        _handleMessageSent(data);
      }
    });

    // File message (also comes through groupNewMessage)
    _socketService.addListener('groupFileMessage', key, (data) {
      // debugPrint('📎 [GROUP FILE MESSAGE] Event received: $data');
      if (data['group_id'] == widget.group.id) {
        // debugPrint('📎 [GROUP FILE MESSAGE] Processing for current group');
        _handleNewMessage(data);
      }
    });

    // Message deleted
    _socketService.addListener('groupMessageDeleted', key, (data) {
      debugPrint('🗑️ [GROUP MESSAGE DELETED] Event received: $data');
      if (data['group_id'] == widget.group.id) {
        debugPrint('🗑️ [GROUP MESSAGE DELETED] Processing for current group');
        _handleMessageDeleted(data);
      }
    });

    // Message edited
    _socketService.addListener('groupMessageEdited', key, (data) {
      debugPrint('✏️ [GROUP MESSAGE EDITED] Event received: $data');
      if (data['group_id'] == widget.group.id) {
        debugPrint('✏️ [GROUP MESSAGE EDITED] Processing for current group');
        _handleMessageEdited(data);
      }
    });

    // Reaction updated
    _socketService.addListener('groupReactionUpdated', key, (data) {
      debugPrint('👍 [GROUP REACTION UPDATED] Event received: $data');
      if (data['group_id'] == widget.group.id) {
        debugPrint('👍 [GROUP REACTION UPDATED] Processing for current group');
        _handleReactionUpdated(data);
      }
    });

    // Reaction cleared
    _socketService.addListener('groupReactionCleared', key, (data) {
      debugPrint('❌ [GROUP REACTION CLEARED] Event received: $data');
      if (data['group_id'] == widget.group.id) {
        debugPrint('❌ [GROUP REACTION CLEARED] Processing for current group');
        _handleReactionCleared(data);
      }
    });

    // Doorbell notification
    _socketService.addListener('groupDoorbell', key, (data) {
      debugPrint('🔔 [GROUP DOORBELL] Event received: $data');
      if (data['group_id'] == widget.group.id) {
        debugPrint('🔔 [GROUP DOORBELL] Processing for current group');
        _handleGroupDoorbell(data);
      }
    });

    // Typing indicator
    _socketService.addListener('groupTyping', key, (data) {
      debugPrint('⌨️ [GROUP TYPING] Event received: $data');
      if (data['group_id'] == widget.group.id) {
        debugPrint('⌨️ [GROUP TYPING] Processing for current group');
        _handleGroupUserTyping(data);
      } else {
        debugPrint(
          '⌨️ [GROUP TYPING] Ignoring - different group: ${data['group_id']} vs ${widget.group.id}',
        );
      }
    });

    // Group color change events
    debugPrint('🎨 [SETUP] Adding groupColorChanged listener with key: $key');
    _socketService.addListener('groupColorChanged', key, (data) {
      debugPrint('🎨 [GROUP COLOR CHANGED] Event received: $data');
      debugPrint(
        '🎨 [GROUP COLOR CHANGED] Current group ID: ${widget.group.id}',
      );
      debugPrint(
        '🎨 [GROUP COLOR CHANGED] Event group ID: ${data['group_id']}',
      );
      debugPrint('🎨 [GROUP COLOR CHANGED] Listener key: $key');
      final eventGroupId = data['group_id'] != null
          ? int.tryParse(data['group_id'].toString())
          : null;
      if (eventGroupId == widget.group.id) {
        debugPrint('🎨 [GROUP COLOR CHANGED] Processing for current group');
        _handleGroupColorChange(data);
      } else {
        debugPrint('🎨 [GROUP COLOR CHANGED] Ignoring - different group');
      }
    });

    // Group color reset events
    _socketService.addListener('groupColorReset', key, (data) {
      debugPrint('🔄 [GROUP COLOR RESET] Event received: $data');
      debugPrint('🔄 [GROUP COLOR RESET] Current group ID: ${widget.group.id}');
      debugPrint('🔄 [GROUP COLOR RESET] Event group ID: ${data['group_id']}');
      debugPrint('🔄 [GROUP COLOR RESET] Event data type: ${data.runtimeType}');
      debugPrint('🔄 [GROUP COLOR RESET] Full event data: $data');
      final eventGroupId = data['group_id'] != null
          ? int.tryParse(data['group_id'].toString())
          : null;
      if (eventGroupId == widget.group.id) {
        debugPrint('🔄 [GROUP COLOR RESET] Processing for current group');
        _handleGroupColorReset(data);
      } else {
        debugPrint('🔄 [GROUP COLOR RESET] Ignoring - different group');
      }
    });

    // All messages deleted event (admin delete all)
    debugPrint('📭 [SETUP] Adding allMessagesDeleted listener with key: $key');
    _socketService.addListener('allMessagesDeleted', key, (data) {
      debugPrint('📭 [ALL MESSAGES DELETED] Event received: $data');
      debugPrint(
        '📭 [ALL MESSAGES DELETED] Current group ID: ${widget.group.id}',
      );
      debugPrint(
        '📭 [ALL MESSAGES DELETED] Event group ID: ${data['group_id']}',
      );
      if (data['group_id'] == widget.group.id) {
        debugPrint('📭 [ALL MESSAGES DELETED] Processing for current group');
        _handleAllMessagesDeleted(data);
      } else {
        debugPrint('📭 [ALL MESSAGES DELETED] Ignoring - different group');
      }
    });

    // Member added → show a "X was added to the group" system notice.
    _socketService.addListener('groupMemberAdded', key, (data) {
      if (_eventGroupId(data) != widget.group.id) return;
      _handleMemberAdded(data);
    });

    // Member left / removed (both route to this bucket on the socket service).
    _socketService.addListener('groupMemberLeft', key, (data) {
      if (_eventGroupId(data) != widget.group.id) return;
      _handleMemberLeftOrRemoved(data);
    });

    // Group disbanded/deleted (e.g. the creator left) → close the chat.
    _socketService.addListener('groupDeleted', key, (data) {
      if (_eventGroupId(data) != widget.group.id) return;
      if (!mounted) return;

      final currentUserId = _socketService.currentUserId;
      final deletedById = data['deleted_by_id'] as int?;
      if (deletedById == null || deletedById != currentUserId) {
        final by = (data['deleted_by'] as String?)?.trim();
        _showTopSnackBar(
          SnackBar(
            content: Text(
              by != null && by.isNotEmpty
                  ? 'This group was disbanded by $by'
                  : 'This group was disbanded',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
      Navigator.of(context).pop();
    });

    // Task events (mark/add, complete, uncomplete/unmark) for this group.
    _socketService.addListener('taskAdded', key, _handleGroupMessageDataEvent);
    _socketService.addListener(
      'taskCompleted',
      key,
      _handleGroupMessageDataEvent,
    );
    _socketService.addListener(
      'taskUncompleted',
      key,
      _handleGroupMessageDataEvent,
    );
    // Excalidraw pin/unpin events for this group.
    _socketService.addListener(
      'excalidrawPinned',
      key,
      _handleGroupMessageDataEvent,
    );
    _socketService.addListener(
      'excalidrawUnpinned',
      key,
      _handleGroupMessageDataEvent,
    );

    debugPrint('🎨 [SETUP] All listeners registered for key: $key');
  }

  /// Resolve the group id from a member event payload (handles both the
  /// top-level `group_id` and the nested `group.id` shapes the server sends).
  int? _eventGroupId(Map<String, dynamic> data) {
    final gid = data['group_id'];
    if (gid is int) return gid;
    final group = data['group'];
    if (group is Map && group['id'] is int) return group['id'] as int;
    return null;
  }

  /// Append an ephemeral system message bubble (e.g. "X left the group").
  /// add/remove/leave are also persisted server-side, so the canonical copy
  /// replaces this on the next message reload — no lasting duplicates.
  void _appendSystemMessage(String text) {
    final now = DateTime.now();
    final tempId = now.millisecondsSinceEpoch;
    final sys = GroupMessage(
      id: tempId,
      messageId: tempId,
      groupId: widget.group.id,
      senderId: 0,
      content: text,
      messageType: 'system',
      timestamp: now.toUtc().toIso8601String(),
      timestampMs: tempId,
    );
    if (!mounted) return;
    setState(() {
      // Guard against an identical consecutive notice (e.g. the event arriving
      // twice) so we don't stack the same bubble.
      if (_messages.isNotEmpty &&
          _messages.last.messageType == 'system' &&
          _messages.last.content == text) {
        return;
      }
      _messages.add(sys);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _isAtBottom) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _handleMemberAdded(Map<String, dynamic> data) {
    final group = data['group'];
    if (group is Map && group['member_count'] is int) {
      setState(() => _memberCount = group['member_count'] as int);
    }
    // Prefer the server-provided name; fall back to resolving the added ids
    // against the group's member list.
    String? name = (data['added_user_name'] as String?)?.trim();
    if ((name == null || name.isEmpty) && group is Map) {
      final ids = (data['added_user_ids'] as List?) ?? const [];
      final members = (group['members'] as List?) ?? const [];
      final names = <String>[];
      for (final id in ids) {
        for (final m in members) {
          if (m is Map && (m['user_id'] == id || m['id'] == id)) {
            final user = m['user'] is Map ? m['user'] as Map : m;
            final full =
                ('${user['first_name'] ?? ''} ${user['last_name'] ?? ''}')
                    .trim();
            names.add(full.isNotEmpty ? full : (user['username'] ?? 'Someone'));
          }
        }
      }
      if (names.isNotEmpty) name = names.join(', ');
    }
    _appendSystemMessage('${name ?? 'Someone'} was added to the group');
  }

  void _handleMemberLeftOrRemoved(Map<String, dynamic> data) {
    final removedUserId = data['removed_user_id'];
    if (removedUserId != null) {
      // group_member_removed
      if (removedUserId == _currentUserId) {
        // The current user was removed by an admin — exit the chat.
        if (mounted) {
          _showTopSnackBar(
            const SnackBar(content: Text('You were removed from this group')),
          );
          Navigator.of(context).pop();
        }
        return;
      }
      final group = data['group'];
      if (group is Map && group['member_count'] is int) {
        setState(() => _memberCount = group['member_count'] as int);
      }
      final name = (data['removed_user_name'] as String?)?.trim();
      _appendSystemMessage(
        '${name?.isNotEmpty == true ? name : 'A member'} left the group',
      );
    } else {
      // group_member_left (not carried with a group payload)
      final name = (data['user_name'] as String?)?.trim();
      _appendSystemMessage(
        '${name?.isNotEmpty == true ? name : 'A member'} left the group',
      );
      setState(() {
        if (_memberCount > 0) _memberCount--;
      });
    }
  }

  Future<void> _loadMessages() async {
    if (_isLoadingMessages) return;
    // Only show the shimmer if the cache hasn't already painted something.
    // On a warm open we keep _isLoading = false so the cached list stays
    // visible while the network refresh resolves.
    final hasCachedMessages = _messages.isNotEmpty;
    setState(() {
      _isLoadingMessages = true;
      if (!hasCachedMessages) {
        _isLoading = true;
      }
    });

    try {
      final messages = await GroupService.getMessages(
        groupId: widget.group.id,
        limit: 50,
      );

      if (mounted) {
        _syncGroupColorFromMessages(messages);
        setState(() {
          _messages = messages; // Don't reverse - ListView will handle it
          _isLoading = false;
          _isLoadingMessages = false;
        });

        // Persist the freshly fetched snapshot so the next cold open
        // hydrates instantly from cache.
        unawaited(
          ChatCacheService.saveGroupMessages(widget.group.id, messages),
        );

        // Pull every media file referenced by these messages into the
        // on-disk cache so the chat works fully offline.
        unawaited(MediaPreloadService.instance.prefetchGroupMessages(messages));

        // Mark messages as viewed
        _markMessagesAsViewed();

        // Scroll to bottom if this is the first paint (cold open) or if the user has not manually scrolled yet.
        // Don't yank the scroll position from under the user on a warm refresh if they scrolled up.
        if (!hasCachedMessages || !_userHasScrolledManually) {
          _scrollEntryToBottom();
        }
      }
    } catch (e) {
      debugPrint('Error loading group messages: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isLoadingMessages = false;
        });
      }
    }
  }

  void _handleNewMessage(Map<String, dynamic> data) async {
    debugPrint('📨 [GROUP NEW MESSAGE] Received: data=$data');
    debugPrint('📨 [GROUP NEW MESSAGE] Attempting to parse message...');

    try {
      final message = GroupMessage.fromJson(data);
      debugPrint(
        '📨 [GROUP NEW MESSAGE] Successfully parsed message: ${message.id}',
      );
      debugPrint('📨 [GROUP NEW MESSAGE] Message content: ${message.content}');
      debugPrint('📨 [GROUP NEW MESSAGE] Message type: ${message.messageType}');
      debugPrint('📨 [GROUP NEW MESSAGE] File URL: ${message.fileUrl}');
      debugPrint('📨 [GROUP NEW MESSAGE] File name: ${message.fileName}');
      debugPrint('📨 [GROUP NEW MESSAGE] File type: ${message.fileType}');
      debugPrint('📨 [GROUP NEW MESSAGE] Sender ID: ${message.senderId}');
      debugPrint('📨 [GROUP NEW MESSAGE] Current user ID: $_currentUserId');

      if (mounted) {
        debugPrint(
          '📨 [GROUP NEW MESSAGE] Widget is mounted, updating messages list',
        );
        setState(() {
          final existingIndex = _messages.indexWhere((m) => m.id == message.id);
          if (existingIndex != -1) {
            _messages[existingIndex] = message;
            return;
          }

          if (message.senderId == _currentUserId) {
            final optimisticIndex = _messages.indexWhere(
              (m) =>
                  m.id > 1000000000000 &&
                  m.senderId == _currentUserId &&
                  (m.content == message.content ||
                      (message.messageType != 'text' &&
                          m.messageType == message.messageType)),
            );
            if (optimisticIndex != -1) {
              _messages[optimisticIndex] = message;
              return;
            }
          }

          _messages.add(message);
          debugPrint(
            '📨 [GROUP NEW MESSAGE] Messages count: ${_messages.length}',
          );
        });

        // Auto-translate incoming message if enabled and it's a text message from another user
        if (_autoTranslate &&
            message.senderId != _currentUserId &&
            message.messageType == 'text' &&
            message.content.isNotEmpty) {
          _autoTranslateGroupMessage(message);
        }

        // Save to cache for offline access
        await ChatCacheService.addGroupMessageToCache(widget.group.id, message);
        debugPrint('💾 Cached group message ${message.id}');
        // Prefetch any media attached so it plays back offline later.
        unawaited(
          MediaPreloadService.instance.prefetchGroupMessages([message]),
        );

        // Play notification sound if not from current user
        if (message.senderId != _currentUserId) {
          debugPrint(
            '🔊 Playing notification sound for message from other user',
          );
          _playNotificationSound();

          // Increment unread count if not at bottom (for incoming messages)
          if (!_isAtBottom) {
            setState(() {
              _unreadCount++;
            });
          }
        }

        // Mark as viewed if at bottom
        if (_isAtBottom) {
          debugPrint(
            '📨 [GROUP NEW MESSAGE] At bottom, marking messages as viewed',
          );
          _markMessagesAsViewed();
        }

        // Only auto-scroll if user is at bottom or message is from current user
        if (_isAtBottom || message.senderId == _currentUserId) {
          debugPrint('📨 [GROUP NEW MESSAGE] Scrolling to bottom');
          _scrollToBottomWithRetry();
        }
      } else {
        debugPrint(
          '📨 [GROUP NEW MESSAGE] Widget not mounted, ignoring message',
        );
      }
    } catch (e, stackTrace) {
      debugPrint('❌ [GROUP NEW MESSAGE] Error parsing message: $e');
      debugPrint('❌ [GROUP NEW MESSAGE] Stack trace: $stackTrace');
      debugPrint('❌ [GROUP NEW MESSAGE] Raw data: $data');
    }
  }

  void _handleMessageSent(Map<String, dynamic> data) {
    // Message sent confirmation - replace optimistic message with real message
    final messageId = data['message_id'] as int?;
    final senderId = data['sender_id'] as int?;
    final messageType = data['message_type'] as String? ?? 'text';

    debugPrint(
      '📨 [GROUP MESSAGE SENT] Received: messageId=$messageId, senderId=$senderId, type=$messageType, currentUserId=$_currentUserId',
    );

    if (messageId == null) return;

    if (mounted) {
      setState(() {
        // If this is from the current user, replace optimistic message
        if (senderId == _currentUserId) {
          // Find optimistic message (temporary ID > 1000000000000 - timestamp range)
          final optimisticIndex = _messages.indexWhere(
            (m) =>
                m.id > 1000000000000 && // Temporary ID range
                m.senderId == _currentUserId &&
                (m.content == data['content'] || // For text messages
                    (messageType != 'text' &&
                        m.messageType ==
                            messageType)), // For file messages, match by type
          );

          if (optimisticIndex != -1) {
            debugPrint(
              '📨 [GROUP MESSAGE SENT] Replacing optimistic message at index $optimisticIndex',
            );
            _messages[optimisticIndex] = GroupMessage.fromJson(data);
          } else {
            debugPrint(
              '📨 [GROUP MESSAGE SENT] No optimistic message found, adding new message',
            );
            // Fallback: add message if no optimistic message found
            final message = GroupMessage.fromJson(data);
            _messages.add(message);
          }
        } else {
          // Message from another user - this shouldn't happen in groupMessageSent
          debugPrint(
            '📨 [GROUP MESSAGE SENT] Ignoring message from other user: $senderId',
          );
        }
      });
    }
  }

  void _handleMessageDeleted(Map<String, dynamic> data) {
    final messageId = data['message_id'] as int?;
    if (messageId == null) return;

    if (mounted) {
      setState(() {
        if (_currentUserIsAdmin) {
          _messages.removeWhere((m) => m.id == messageId);
        } else {
          final index = _messages.indexWhere((m) => m.id == messageId);
          if (index != -1) {
            _messages[index] = GroupMessage.fromJson({
              ..._messages[index].toJson(),
              'is_deleted': true,
              'content': 'This message was deleted',
              'file_url': null,
              'file_name': null,
            });
          }
        }
      });
    }
  }

  void _handleMessageEdited(Map<String, dynamic> data) {
    final messageId = data['message_id'] as int?;
    final newContent = data['content'] as String?;
    if (messageId == null || newContent == null) return;

    if (mounted) {
      setState(() {
        final index = _messages.indexWhere((m) => m.id == messageId);
        if (index != -1) {
          _messages[index] = GroupMessage.fromJson({
            ..._messages[index].toJson(),
            'content': newContent,
          });
        }
      });
    }
  }

  void _handleReactionUpdated(Map<String, dynamic> data) {
    final messageId = data['message_id'] as int?;
    final reactions = data['reactions'] as Map<String, dynamic>?;
    if (messageId == null || reactions == null) return;

    if (mounted) {
      setState(() {
        final index = _messages.indexWhere((m) => m.id == messageId);
        if (index != -1) {
          _messages[index] = GroupMessage.fromJson({
            ..._messages[index].toJson(),
            'reactions': reactions,
          });
        }
      });
    }
  }

  void _handleReactionCleared(Map<String, dynamic> data) {
    _handleReactionUpdated(data);
  }

  void _handleGroupDoorbell(Map<String, dynamic> data) {
    final senderName = data['sender_name'] as String?;
    final senderId = data['sender_id'] as int?;
    final timestampMs =
        data['timestamp_ms'] as int? ?? DateTime.now().millisecondsSinceEpoch;

    // Don't show incoming notification if we sent it (we already have outgoing message)
    if (senderId == _currentUserId) {
      debugPrint(
        'Ignoring own doorbell notification - sender sees outgoing message',
      );
      return;
    }

    // Check if we already have this doorbell notification to prevent duplicates
    final alreadyExists = _messages.any(
      (msg) =>
          msg.messageType == 'system' &&
          msg.timestampMs == timestampMs &&
          msg.content.contains('rang the doorbell'),
    );

    if (alreadyExists) {
      debugPrint('Doorbell notification already exists, skipping duplicate');
      return;
    }

    // Play doorbell notification sound (create new player so rapid rings overlap)
    try {
      final player = AudioPlayer();
      player.play(AssetSource('sounds/notif-sound.wav'));
      player.onPlayerComplete.listen((_) => player.dispose());
    } catch (e) {
      debugPrint('Error playing doorbell sound: $e');
    }

    // Create doorbell system message for incoming notifications
    final doorbellMessage = GroupMessage(
      id: timestampMs,
      messageId: timestampMs,
      groupId: widget.group.id,
      senderId: senderId ?? 0,
      sender: GroupMessageSender(
        id: senderId ?? 0,
        username: senderName ?? 'Someone',
        firstName: senderName ?? 'Someone',
        lastName: '',
        fullName: senderName ?? 'Someone',
      ),
      content: '${senderName ?? "Someone"} rang the doorbell 🔔',
      messageType: 'system',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        timestampMs,
      ).toIso8601String(),
      timestampMs: timestampMs,
      reactions: {},
    );

    setState(() {
      _messages.add(doorbellMessage);
      if (!_isAtBottom) {
        _unreadCount++;
      }
    });

    // Only auto-scroll if user is at bottom, otherwise just show unread badge
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _isAtBottom) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    // Show snackbar notification
    if (mounted) {
      _showTopSnackBar(
        SnackBar(
          content: Text('🔔 ${senderName ?? "Someone"} rang the doorbell'),
          duration: const Duration(seconds: 3),
          backgroundColor: const Color(0xFF4C1D95),
        ),
      );
    }
  }

  void _handleGroupUserTyping(Map<String, dynamic> data) {
    debugPrint('⌨️ [GROUP TYPING HANDLER] Processing data: $data');

    final userId = data['user_id'] as int?;
    final username = data['username'] as String?;
    final fullName = data['full_name'] as String?;
    final message = data['message'] as String? ?? '';

    debugPrint(
      '⌨️ [GROUP TYPING HANDLER] userId: $userId, currentUserId: $_currentUserId',
    );
    debugPrint(
      '⌨️ [GROUP TYPING HANDLER] username: $username, fullName: $fullName',
    );
    debugPrint('⌨️ [GROUP TYPING HANDLER] message: "$message"');

    // Don't show typing indicator for own messages
    if (userId == _currentUserId) {
      debugPrint('⌨️ [GROUP TYPING HANDLER] Ignoring own typing indicator');
      return;
    }

    final displayName = fullName ?? username ?? 'Someone';
    debugPrint('⌨️ [GROUP TYPING HANDLER] Display name: $displayName');

    // Cancel previous hide timer
    _typingHideTimer?.cancel();

    if (mounted) {
      setState(() {
        _typingUserName = displayName;
        _typingMessage = message;
      });

      debugPrint(
        '⌨️ [GROUP TYPING HANDLER] Updated UI - typingUserName: $_typingUserName, typingMessage: $_typingMessage',
      );

      // Auto-hide after 3 seconds
      _typingHideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          debugPrint('⌨️ [GROUP TYPING HANDLER] Auto-hiding typing indicator');
          setState(() {
            _typingUserName = '';
            _typingMessage = '';
          });
        }
      });
    }
  }

  void _handleGroupColorChange(Map<String, dynamic> data) {
    final colorHex = data['color'] as String?;
    final senderName = data['sender_name'] as String?;
    final senderId = data['sender_id'] != null
        ? int.tryParse(data['sender_id'].toString())
        : null;
    final isFromSelf = senderId == _currentUserId;
    final timestampMs = data['timestamp_ms'] != null
        ? int.tryParse(data['timestamp_ms'].toString()) ??
              DateTime.now().millisecondsSinceEpoch
        : DateTime.now().millisecondsSinceEpoch;

    if (colorHex != null) {
      try {
        // Parse hex color (e.g., "#FF5733" or "FF5733")
        final hexColor = colorHex.replaceAll('#', '');
        final color = Color(int.parse('FF$hexColor', radix: 16));

        // Only apply color change if we are NOT the sender (matches 1-on-1 behavior)
        if (!isFromSelf) {
          setState(() {
            _headerColor = color;
            _showResetButton = true;
          });

          // Persist the color so it survives app restarts
          _saveGroupChatColor(colorHex);
        }

        // Create system message
        final colorMessage = GroupMessage(
          id: timestampMs,
          messageId: timestampMs,
          groupId: widget.group.id,
          senderId: senderId ?? 0,
          sender: GroupMessageSender(
            id: senderId ?? 0,
            username: senderName ?? 'Someone',
            firstName: senderName ?? 'Someone',
            lastName: '',
            fullName: senderName ?? 'Someone',
          ),
          content: isFromSelf
              ? 'You changed the group chat color'
              : '${senderName ?? "Someone"} changed your chat color to $colorHex',
          messageType: 'system',
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            timestampMs,
          ).toIso8601String(),
          timestampMs: timestampMs,
          reactions: {},
        );

        if (!isFromSelf) {
          setState(() {
            _messages.add(colorMessage);
          });
        }

        // Only auto-scroll if user is at bottom, otherwise just show unread badge
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients && _isAtBottom) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });

        debugPrint('🎨 [GROUP COLOR CHANGE] Applied color: $colorHex');
      } catch (e) {
        debugPrint('❌ [GROUP COLOR CHANGE] Error parsing color: $e');
      }
    }
  }

  void _handleGroupColorReset(Map<String, dynamic> data) {
    final senderName = data['sender_name'] as String?;
    final senderId = data['sender_id'] != null
        ? int.tryParse(data['sender_id'].toString())
        : null;
    final isFromSelf = senderId == _currentUserId;
    final timestampMs = data['timestamp_ms'] != null
        ? int.tryParse(data['timestamp_ms'].toString()) ??
              DateTime.now().millisecondsSinceEpoch
        : DateTime.now().millisecondsSinceEpoch;

    // Always apply color reset (incoming or cross-device sync)
    setState(() {
      _headerColor = const Color(0xFF4C1D95); // Reset to default
      _showResetButton = false;
    });

    // Clear saved color
    _clearGroupChatColor();

    // Create system message
    final resetMessage = GroupMessage(
      id: timestampMs,
      messageId: timestampMs,
      groupId: widget.group.id,
      senderId: senderId ?? 0,
      sender: GroupMessageSender(
        id: senderId ?? 0,
        username: senderName ?? 'Someone',
        firstName: senderName ?? 'Someone',
        lastName: '',
        fullName: senderName ?? 'Someone',
      ),
      content: isFromSelf
          ? 'You reset the group chat color'
          : '${senderName ?? "Someone"} reset your chat color',
      messageType: 'system',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        timestampMs,
      ).toIso8601String(),
      timestampMs: timestampMs,
      reactions: {},
    );

    if (!isFromSelf) {
      setState(() {
        _messages.add(resetMessage);
      });
    }

    // Scroll to bottom to show the message
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    debugPrint(
      '🔄 [GROUP COLOR RESET] Color reset by ${senderName ?? "Someone"}',
    );
  }

  void _handleAllMessagesDeleted(Map<String, dynamic> data) {
    final adminName = data['admin_name'] as String?;
    final adminId = data['admin_id'] as int?;
    final isFromSelf = adminId == _currentUserId;
    final timestampMs =
        data['timestamp_ms'] as int? ?? DateTime.now().millisecondsSinceEpoch;

    debugPrint('📭 [ALL MESSAGES DELETED] Admin: ${adminName ?? "Someone"}');
    debugPrint('📭 [ALL MESSAGES DELETED] Is from self: $isFromSelf');
    debugPrint(
      '📭 [ALL MESSAGES DELETED] Current messages count: ${_messages.length}',
    );

    // Clear all messages from the UI
    setState(() {
      _messages.clear();
    });

    // Clear cached messages
    ChatCacheService.clearGroupCache(widget.group.id);

    // Create system message about deletion
    final deleteMessage = GroupMessage(
      id: timestampMs,
      messageId: timestampMs,
      groupId: widget.group.id,
      senderId: adminId ?? 0,
      sender: GroupMessageSender(
        id: adminId ?? 0,
        username: adminName ?? 'Admin',
        firstName: adminName ?? 'Admin',
        lastName: '',
        fullName: adminName ?? 'Admin',
      ),
      content: isFromSelf
          ? 'You deleted all messages'
          : '${adminName ?? "Admin"} deleted all messages',
      messageType: 'system',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        timestampMs,
      ).toIso8601String(),
      timestampMs: timestampMs,
      reactions: {},
    );

    setState(() {
      _messages.add(deleteMessage);
    });

    // Only auto-scroll if user is at bottom, otherwise just show unread badge
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _isAtBottom) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    debugPrint(
      '📭 [ALL MESSAGES DELETED] Messages cleared and system message added',
    );
  }

  void _markMessagesAsViewed() {
    if (_messages.isEmpty || _currentUserId == null) return;

    // Get unread messages from others
    final unreadMessages = _messages
        .where((m) => m.senderId != _currentUserId)
        .map((m) => m.id)
        .toList();

    if (unreadMessages.isEmpty) return;

    // Group by sender
    final bySender = <int, List<int>>{};
    for (final msg in _messages.where((m) => m.senderId != _currentUserId)) {
      bySender.putIfAbsent(msg.senderId, () => []).add(msg.id);
    }

    // Mark as viewed for each sender
    for (final entry in bySender.entries) {
      GroupService.markMessagesViewed(
        groupId: widget.group.id,
        messageIds: entry.value,
        senderId: entry.key,
      );
    }

    unawaited(
      FirebaseMessagingService.instance.clearConversationNotificationState(
        groupId: widget.group.id,
        senderName: widget.group.name,
      ),
    );
  }

  /// Load persisted group chat color from SharedPreferences
  Future<void> _loadSavedGroupChatColor() async {
    final prefs = await SharedPreferences.getInstance();
    final savedColorHex = prefs.getString(
      'group_chat_color_${widget.group.id}',
    );
    if (savedColorHex != null && mounted) {
      try {
        final hexColor = savedColorHex.replaceAll('#', '');
        final color = Color(int.parse('FF$hexColor', radix: 16));
        final defaultColor = const Color(0xFF4C1D95);

        setState(() {
          _headerColor = color;
          _showResetButton = color.value != defaultColor.value;
        });
      } catch (e) {
        debugPrint('Error loading saved group chat color: $e');
      }
    }
  }

  /// Persist group chat color to SharedPreferences
  Future<void> _saveGroupChatColor(String colorHex) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('group_chat_color_${widget.group.id}', colorHex);
  }

  /// Clear saved group chat color
  Future<void> _clearGroupChatColor() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('group_chat_color_${widget.group.id}');
  }

  Future<void> _playNotificationSound() async {
    try {
      final player = AudioPlayer();
      await player.play(AssetSource('sounds/notif-sound.wav'));
      player.onPlayerComplete.listen((_) => player.dispose());
    } catch (e) {
      debugPrint('Error playing notification sound: $e');
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final isAtBottom =
        _scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 100;

    if (isAtBottom != _isAtBottom) {
      setState(() {
        _isAtBottom = isAtBottom;
        // Reset unread count when at bottom
        if (isAtBottom) {
          _unreadCount = 0;
        }
      });

      if (isAtBottom) {
        _markMessagesAsViewed();
      }
    }
  }

  void _scrollToBottom({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (animate) {
      _scrollController.animateTo(
        maxScroll,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(maxScroll);
    }
  }

  void _scrollToBottomWithRetry({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(animate: animate);
    });
    final delays = [100, 250, 400, 600];
    for (final delay in delays) {
      Future.delayed(Duration(milliseconds: delay), () {
        if (mounted && _scrollController.hasClients) {
          _scrollToBottom(animate: false);
        }
      });
    }
  }

  void _scrollEntryToBottom() {
    _userHasScrolledManually = false;

    // Use addPostFrameCallback so the ListView is guaranteed to be built
    // before we attempt to scroll — the controller has no clients yet when
    // this is called synchronously right after setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollToBottom(animate: false);
    });

    // Schedule a series of checks/jumps as items/files load and build
    final delays = [50, 150, 300, 600, 1000, 1500];
    for (final delay in delays) {
      Future.delayed(Duration(milliseconds: delay), () {
        if (!mounted ||
            !_scrollController.hasClients ||
            _userHasScrolledManually)
          return;
        _scrollToBottom(animate: false);
      });
    }
  }

  /// Scroll to bottom and mark all messages as read
  Future<void> _scrollToBottomAndMarkRead() async {
    _userHasScrolledManually = false;
    _scrollToBottomWithRetry(animate: true);

    // Reset unread count
    setState(() {
      _unreadCount = 0;
    });

    // Mark messages as viewed
    _markMessagesAsViewed();
  }

  /// Stop group typing indicator
  void _stopGroupTyping() {
    // Cancel any pending typing emit timer
    _typingEmitTimer?.cancel();

    // Send empty message to stop typing indicator
    _socketService.stopGroupTyping(widget.group.id);
  }

  Future<void> _sendMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;

    // Capture reply info before clearing
    final replyToId = _replyingToMessage?.id;

    // Generate a temporary ID for optimistic update
    final tempId = DateTime.now().millisecondsSinceEpoch;
    final now = DateTime.now();

    // Create optimistic message
    final optimisticMessage = GroupMessage(
      id: tempId, // Temporary ID
      messageId: tempId, // Use same temp ID for messageId
      groupId: widget.group.id,
      senderId: _currentUserId!,
      sender: null, // Will be updated with real data
      content: content,
      messageType: 'text',
      timestamp: now.toIso8601String(),
      timestampMs: now.millisecondsSinceEpoch,
      replyToId: replyToId,
    );

    // Clear input and reply state immediately for better UX
    _messageController.clear();
    _stopGroupTyping(); // Stop typing indicator immediately when sending
    setState(() {
      _replyingToMessage = null;
      _showActionButtons = false; // Hide action buttons after sending
      // Add optimistic message immediately
      _messages.add(optimisticMessage);
    });

    // Scroll to bottom after adding optimistic message
    _scrollToBottomWithRetry();

    try {
      // Send message via API (this will trigger groupMessageSent event)
      await GroupService.sendMessage(
        groupId: widget.group.id,
        content: content,
        replyToId: replyToId,
      );

      // Don't add message here - wait for socket confirmation
      debugPrint(
        '📤 Message sent successfully, waiting for socket confirmation',
      );
    } catch (e) {
      debugPrint('Error sending message: $e');

      // Remove optimistic message on error
      if (mounted) {
        setState(() {
          _messages.removeWhere((m) => m.id == tempId);
        });
        _showTopSnackBar(SnackBar(content: Text('Failed to send message: $e')));
      }
    }
  }

  Future<void> _pickAndSendImage() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery);

    if (image == null) return;

    await _showFilePreviewModal(File(image.path), image.name);
  }

  Future<void> _pickAndSendFile() async {
    final result = await FilePicker.platform.pickFiles();

    if (result == null || result.files.isEmpty) return;

    final file = File(result.files.first.path!);
    await _showFilePreviewModal(file, result.files.first.name);
  }

  Future<void> _uploadFile(File file) async {
    // Generate a temporary ID for optimistic update
    final tempId = DateTime.now().millisecondsSinceEpoch;
    final now = DateTime.now();

    // Determine file type and create appropriate optimistic message
    final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
    final fileName = file.path.split('/').last;
    final fileSize = await file.length();

    String messageType = 'file';
    String content = fileName;

    if (mimeType.startsWith('image/')) {
      messageType = 'image';
      content = 'Image: $fileName';
    } else if (mimeType.startsWith('video/')) {
      messageType = 'video';
      content = 'Video: $fileName';
    } else if (mimeType.startsWith('audio/')) {
      messageType = 'audio';
      content = 'Audio: $fileName';
    }

    // Create optimistic message
    final optimisticMessage = GroupMessage(
      id: tempId, // Temporary ID
      messageId: tempId, // Use same temp ID for messageId
      groupId: widget.group.id,
      senderId: _currentUserId!,
      sender: null, // Will be updated with real data
      content: content,
      messageType: messageType,
      timestamp: now.toIso8601String(),
      timestampMs: now.millisecondsSinceEpoch,
      fileName: fileName,
      fileSize: fileSize,
      fileType: mimeType,
    );

    // Add optimistic message immediately for responsive UI
    if (mounted) {
      setState(() {
        _messages.add(optimisticMessage);
      });

      // Scroll to bottom after adding optimistic message
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }

    try {
      // Upload file via API (this will trigger socket events)
      await GroupService.uploadFile(groupId: widget.group.id, file: file);

      // Don't add message here - wait for socket confirmation
      // debugPrint(
      //   '📎 File uploaded successfully, waiting for socket confirmation',
      // );
    } catch (e) {
      debugPrint('Error uploading file: $e');

      // Remove optimistic message on error
      if (mounted) {
        setState(() {
          _messages.removeWhere((m) => m.id == tempId);
        });
        _showTopSnackBar(SnackBar(content: Text('Failed to upload file: $e')));
      }
    }
  }

  String _resolveOutgoingFileName({
    required String originalName,
    required String mimeType,
    required bool isFromCamera,
  }) {
    final raw = originalName.split(RegExp(r'[\\/]')).last.trim();
    final ext = _fileExtension(raw, mimeType);
    final looksTemporary = RegExp(
      r'^(scaled_)?[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}',
      caseSensitive: false,
    ).hasMatch(raw);

    if (isFromCamera || looksTemporary || raw.isEmpty) {
      return 'Photo_${_fileTimestamp(DateTime.now())}.$ext';
    }

    return raw;
  }

  String _fileExtension(String fileName, String mimeType) {
    final dot = fileName.lastIndexOf('.');
    if (dot > -1 && dot < fileName.length - 1) {
      return fileName.substring(dot + 1).toLowerCase();
    }
    return _extensionFromMime(mimeType);
  }

  String _extensionFromMime(String mimeType) {
    if (mimeType.startsWith('image/')) return mimeType.split('/').last;
    if (mimeType.startsWith('video/')) return mimeType.split('/').last;
    if (mimeType == 'application/pdf') return 'pdf';
    return 'bin';
  }

  String _fileTimestamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$y$m${d}_$hh$mm$ss';
  }

  String _truncateMiddle(String value, {int maxChars = 44}) {
    if (value.length <= maxChars) return value;
    final keep = (maxChars - 3) ~/ 2;
    final start = value.substring(0, keep);
    final end = value.substring(value.length - keep);
    return '$start...$end';
  }

  IconData _getFileIcon(String mimeType) {
    if (mimeType.startsWith('image/')) return Icons.image;
    if (mimeType.startsWith('video/')) return Icons.videocam;
    if (mimeType.startsWith('audio/')) return Icons.audiotrack;
    if (mimeType.contains('pdf')) return Icons.picture_as_pdf;
    if (mimeType.contains('word') || mimeType.contains('document')) {
      return Icons.description;
    }
    if (mimeType.contains('excel') || mimeType.contains('spreadsheet')) {
      return Icons.table_chart;
    }
    if (mimeType.contains('zip') || mimeType.contains('archive')) {
      return Icons.folder_zip;
    }
    return Icons.insert_drive_file;
  }

  Future<void> _showFilePreviewModal(
    File file,
    String fileName, {
    bool isFromCamera = false,
  }) async {
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } catch (_) {}

    final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
    final isImage = mimeType.startsWith('image/');
    final isVideo = mimeType.startsWith('video/');
    final fileSize = file.lengthSync();
    final uploadFileName = _resolveOutgoingFileName(
      originalName: fileName,
      mimeType: mimeType,
      isFromCamera: isFromCamera,
    );
    final displayFileName = _truncateMiddle(uploadFileName, maxChars: 44);
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: !_isActivelyUploading,
      enableDrag: !_isActivelyUploading,
      backgroundColor: Colors.transparent,
      builder: (modalContext) {
        return FilePreviewModalContent(
          file: file,
          fileName: uploadFileName,
          displayFileName: displayFileName,
          mimeType: mimeType,
          isImage: isImage,
          isVideo: isVideo,
          fileSize: fileSize,
          isFromCamera: isFromCamera,
          isUploading: _isActivelyUploading,
          uploadProgressNotifier: _activeUploadProgressNotifier,
          onMinimize: () {
            if (!_isActivelyUploading) {
              setState(() {
                _pendingFile = file;
                _pendingFileName = uploadFileName;
                _pendingFileMimeType = mimeType;
                _pendingFileIsFromCamera = isFromCamera;
              });
            }
            Navigator.pop(modalContext);
          },
          onClose: () {
            if (!_isActivelyUploading) {
              setState(() {
                _pendingFile = null;
                _pendingFileName = null;
                _pendingFileMimeType = null;
              });
            }
            Navigator.pop(modalContext);
          },
          onReplace: () {
            setState(() {
              _pendingFile = null;
              _pendingFileName = null;
              _pendingFileMimeType = null;
            });
            Navigator.pop(modalContext);
            if (isFromCamera) {
              _takePhoto();
            } else {
              _pickFile();
            }
          },
          onSend: () {
            Navigator.pop(modalContext);
            _startFileUpload(file, uploadFileName, displayFileName, mimeType);
          },
          getFileIcon: _getFileIcon,
        );
      },
    );
  }

  Future<void> _startFileUpload(
    File file,
    String uploadFileName,
    String displayFileName,
    String mimeType,
  ) async {
    setState(() {
      _isActivelyUploading = true;
      _activeUploadProgressNotifier.value = 0.05;
    });

    final tempId = DateTime.now().millisecondsSinceEpoch;
    final now = DateTime.now();
    final fileSize = file.lengthSync();

    String messageType = 'file';
    String content = uploadFileName;
    if (mimeType.startsWith('image/')) {
      messageType = 'image';
      content = 'Image: $uploadFileName';
    } else if (mimeType.startsWith('video/')) {
      messageType = 'video';
      content = 'Video: $uploadFileName';
    } else if (mimeType.startsWith('audio/')) {
      messageType = 'audio';
      content = 'Audio: $uploadFileName';
    }

    final optimisticMessage = GroupMessage(
      id: tempId,
      messageId: tempId,
      groupId: widget.group.id,
      senderId: _currentUserId!,
      sender: null,
      content: content,
      messageType: messageType,
      timestamp: now.toIso8601String(),
      timestampMs: now.millisecondsSinceEpoch,
      status: 'pending',
      fileName: uploadFileName,
      fileSize: fileSize,
      fileType: mimeType,
      localFilePath: file.path,
    );

    if (mounted) {
      setState(() {
        _messages.add(optimisticMessage);
      });
      _scrollToBottomWithRetry();
    }

    try {
      _activeUploadProgressNotifier.value = 0.3;
      await GroupService.uploadFile(groupId: widget.group.id, file: file);
      _activeUploadProgressNotifier.value = 1.0;
    } catch (e) {
      debugPrint('Error uploading file: $e');
      if (mounted) {
        setState(() {
          _messages.removeWhere((m) => m.id == tempId);
        });
        _showTopSnackBar(SnackBar(content: Text('Failed to upload file: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isActivelyUploading = false;
          _pendingFile = null;
          _pendingFileName = null;
          _pendingFileMimeType = null;
        });
      }
    }
  }

  Future<void> _deleteMessage(GroupMessage message) async {
    try {
      await GroupService.deleteMessage(
        groupId: widget.group.id,
        messageId: message.id,
      );

      if (mounted) {
        setState(() {
          if (_currentUserIsAdmin) {
            _messages.removeWhere((m) => m.id == message.id);
          } else {
            final index = _messages.indexWhere((m) => m.id == message.id);
            if (index != -1) {
              _messages[index] = GroupMessage.fromJson({
                ..._messages[index].toJson(),
                'is_deleted': true,
                'content': 'This message was deleted',
                'file_url': null,
                'file_name': null,
              });
            }
          }
        });
      }
    } catch (e) {
      debugPrint('Error deleting message: $e');
      if (mounted) {
        _showTopSnackBar(
          SnackBar(content: Text('Failed to delete message: $e')),
        );
      }
    }
  }

  Future<void> _addReaction(GroupMessage message, String emoji) async {
    try {
      final reactions = await GroupService.addReaction(
        groupId: widget.group.id,
        messageId: message.id,
        emoji: emoji,
      );

      if (mounted) {
        setState(() {
          final index = _messages.indexWhere((m) => m.id == message.id);
          if (index != -1) {
            _messages[index] = GroupMessage.fromJson({
              ..._messages[index].toJson(),
              'reactions': reactions,
            });
          }
        });
      }
    } catch (e) {
      debugPrint('Error adding reaction: $e');
    }
  }

  @override
  void dispose() {
    // Clear active chat when leaving group chat screen
    ActiveChatService().clearActiveChat();

    // Persist the latest in-memory snapshot so the next open paints
    // immediately from cache. Fire-and-forget; safe across teardown.
    if (_messages.isNotEmpty) {
      unawaited(ChatCacheService.saveGroupMessages(widget.group.id, _messages));
    }

    // Stop typing indicator when leaving the screen
    _stopGroupTyping();

    _socketService.removeListenersForKey('group_chat_${widget.group.id}');
    _socketService.leaveGroupChat(widget.group.id);
    _messageController.removeListener(_syncCommonPhrasesVisibility);
    _messageController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    _inputFocusNode.dispose();
    _inputScrollController.dispose();
    _typingHideTimer?.cancel();
    _typingEmitTimer?.cancel();
    _taskModalVersion.dispose();
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    _linkRecognizers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    // Rebuild the per-message reaction map once per frame for the shared bubble.
    final reactionsForUi = _groupReactionsForUi();
    final taskCount = _messages.where((m) => m.isTask && !m.isDeleted).length;
    final excalidrawCount = _messages
        .where((m) => m.excalidrawPinnedAt != null && !m.isDeleted)
        .length;
    // Recreate URL tap recognizers fresh each frame; dispose the previous set
    // (their TextSpans are discarded by this rebuild, so this is safe).
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    _linkRecognizers.clear();
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF2C2C2C),
      appBar: ChatHeader(
        scale: 1.0,
        headerColor: _headerColor,
        onBack: () => Navigator.pop(context),
        groupName: _groupName,
        groupAvatarUrl: widget.group.avatarUrl,
        memberCount: _memberCount,
        onCallVideo: () => _startGroupCall('video'),
        onCallAudio: () => _startGroupCall('audio'),
        taskCount: taskCount,
        onShowTasks: _showGroupTasksModal,
        excalidrawCount: excalidrawCount,
        onShowExcalidraw: _showGroupExcalidrawModal,
        onShowMembers: _showGroupMembersSheet,
        onShowSettings: _showGroupSettingsSheet,
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: Column(
          children: [
            // Messages list
            Expanded(
              child: _isLoading
                  ? _buildLoadingShimmer()
                  : _messages.isEmpty
                  ? const Center(
                      child: Text(
                        'No messages yet\nBe the first to send a message!',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 16),
                      ),
                    )
                  : Stack(
                      children: [
                        NotificationListener<ScrollNotification>(
                          onNotification: (notification) {
                            if (notification is ScrollStartNotification &&
                                notification.dragDetails != null) {
                              _userHasScrolledManually = true;
                            }
                            return false;
                          },
                          child: ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(16),
                            cacheExtent: 500,
                            addAutomaticKeepAlives: false,
                            addRepaintBoundaries: true,
                            itemCount: _messages.length,
                            itemBuilder: (context, index) {
                              final message = _messages[index];
                              final isSentByMe =
                                  message.senderId == _currentUserId;

                              // Date separator between days
                              Widget? dateSeparator;
                              if (index < _messages.length - 1) {
                                final next = _messages[index + 1];
                                if (!_isSameDay(
                                  message.timestamp,
                                  next.timestamp,
                                )) {
                                  dateSeparator = ChatDateSeparator(
                                    timestamp: message.timestamp,
                                    scale: 1.0,
                                  );
                                }
                              } else {
                                dateSeparator = ChatDateSeparator(
                                  timestamp: message.timestamp,
                                  scale: 1.0,
                                );
                              }

                              final bubble =
                                  message.isDeleted ||
                                      message.messageType == 'system'
                                  ? _buildMessageBubble(message)
                                  : SwipeableMessage(
                                      isSentByMe: isSentByMe,
                                      onReply: () {
                                        setState(
                                          () => _replyingToMessage = message,
                                        );
                                        _inputFocusNode.requestFocus();
                                      },
                                      child: _buildSharedGroupBubble(
                                        message,
                                        isSentByMe,
                                        reactionsForUi,
                                      ),
                                    );

                              return Column(
                                children: [
                                  bubble,
                                  if (dateSeparator != null) dateSeparator,
                                ],
                              );
                            },
                          ),
                        ),
                        // Scroll to bottom button - positioned inside messages area
                        if (!_isAtBottom)
                          Positioned(
                            bottom: 16,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: GestureDetector(
                                onTap: _scrollToBottomAndMarkRead,
                                child: SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    alignment: Alignment.center,
                                    children: [
                                      Container(
                                        width: 32,
                                        height: 32,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF7C3AED),
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(0.3),
                                              blurRadius: 6,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: const Icon(
                                          Icons.keyboard_arrow_down,
                                          color: Colors.white,
                                          size: 20,
                                        ),
                                      ),
                                      if (_unreadCount > 0)
                                        Positioned(
                                          top: -2,
                                          right: -2,
                                          child: Container(
                                            padding: const EdgeInsets.all(3),
                                            decoration: const BoxDecoration(
                                              color: Colors.red,
                                              shape: BoxShape.circle,
                                            ),
                                            constraints: const BoxConstraints(
                                              minWidth: 14,
                                              minHeight: 14,
                                            ),
                                            child: Text(
                                              _unreadCount > 99
                                                  ? '99+'
                                                  : _unreadCount.toString(),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 8,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              textAlign: TextAlign.center,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),

            // Typing indicator
            Container(
              height: _typingUserName.isNotEmpty ? null : 0,
              child: _typingUserName.isNotEmpty
                  ? _buildTypingIndicator()
                  : const SizedBox.shrink(),
            ),

            // Reply preview is rendered inside ChatComposerPanel below.

            // Common phrases quick bar (mobile-pinned phrases)
            CommonPhraseBar(
              phrases: _commonPhrases,
              hidden: _hideCommonPhrases || _showEmojiPicker,
              onChipTap: _onCommonPhraseChipTap,
            ),

            // Input area — only this section moves with the keyboard.
            // The rest of the screen stays stable (no full relayout).
            AnimatedPadding(
              duration: Duration.zero,
              curve: Curves.easeOut,
              padding: EdgeInsets.only(bottom: keyboardInset),
              child: _buildInputArea(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingShimmer() {
    return ListView.builder(
      itemCount: 10,
      itemBuilder: (context, index) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: index % 2 == 0
                ? MainAxisAlignment.start
                : MainAxisAlignment.end,
            children: [
              Container(
                width: 200,
                height: 60,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // === Shared bubble adapter (mirrors the 1:1 chat UI) ===

  /// Palette used to color each sender's name label in group bubbles.
  static const List<Color> _senderColors = [
    Color(0xFF60A5FA),
    Color(0xFF34D399),
    Color(0xFFF472B6),
    Color(0xFFFBBF24),
    Color(0xFFA78BFA),
    Color(0xFF22D3EE),
    Color(0xFFF87171),
    Color(0xFF4ADE80),
    Color(0xFFE879F9),
    Color(0xFFFB923C),
  ];

  Color _senderColorForId(int senderId) =>
      _senderColors[senderId.abs() % _senderColors.length];

  /// Build the reaction map the shared [ChatMessageBubble] expects:
  /// { messageId: { emoji: {userId, ...} } }. Computed once per frame.
  Map<int, Map<String, Set<String>>> _groupReactionsForUi() {
    final result = <int, Map<String, Set<String>>>{};
    for (final m in _messages) {
      if (m.reactions.isEmpty) continue;
      final byEmoji = <String, Set<String>>{};
      m.reactions.forEach((emoji, users) {
        if (users is List) {
          byEmoji[emoji] = users.map((u) => u.toString()).toSet();
        }
      });
      if (byEmoji.isNotEmpty) result[m.id] = byEmoji;
    }
    return result;
  }

  /// Reaction pills shown below a bubble (same chip style as before).
  Widget _buildGroupReactionPills(int messageId) {
    GroupMessage? gm;
    for (final m in _messages) {
      if (m.id == messageId) {
        gm = m;
        break;
      }
    }
    if (gm == null || gm.reactions.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 4,
      children: gm.reactions.entries.map((entry) {
        final emoji = entry.key;
        final users = entry.value as List;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF420796), width: 1),
          ),
          child: Text(
            '$emoji ${users.length}',
            style: const TextStyle(fontSize: 12, color: Colors.white),
          ),
        );
      }).toList(),
    );
  }

  void _showGroupReactionPicker(
    BuildContext context,
    int messageId,
    Offset position,
  ) {
    GroupMessage? gm;
    for (final m in _messages) {
      if (m.id == messageId) {
        gm = m;
        break;
      }
    }
    if (gm == null) return;
    final target = gm;
    ReactionPicker.show(
      context: context,
      position: position,
      onReactionSelected: (emoji) => _addReaction(target, emoji),
    );
  }

  /// Map the group status to the indicator vocabulary used by the 1:1 chat.
  String _statusForUi(Message message) {
    final s = message.status;
    if (s == 'read') return 'seen';
    return s;
  }

  /// Message delivery status icon (matches the 1:1 chat).
  Widget _buildStatusIndicator(String status, [double scale = 1.0]) {
    switch (status) {
      case 'sent':
        return Icon(Icons.check, size: 16 * scale, color: Colors.white70);
      case 'delivered':
        return Icon(Icons.done_all, size: 16 * scale, color: Colors.white70);
      case 'seen':
        return Icon(
          Icons.done_all,
          size: 16 * scale,
          color: const Color(0xFF00BCD4),
        );
      case 'failed':
        return Icon(
          Icons.error_outline,
          size: 16 * scale,
          color: const Color(0xFFEF4444),
        );
      default:
        return Icon(Icons.schedule, size: 16 * scale, color: Colors.white54);
    }
  }

  static final RegExp _messageUrlRegex = RegExp(
    r'((?:https?:\/\/|www\.)[^\s]+)',
    caseSensitive: false,
  );

  String _trimTrailingUrlCharacters(String url) {
    var end = url.length;
    const trailing = '.,!?;:)]}\'"';
    while (end > 0 && trailing.contains(url[end - 1])) {
      end--;
    }
    return url.substring(0, end);
  }

  Future<void> _openMessageUrl(String url) async {
    var normalized = url;
    if (!normalized.startsWith('http')) normalized = 'https://$normalized';
    try {
      final uri = Uri.parse(normalized);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  /// Linkified message text with tappable URLs (matches the 1:1 chat).
  Widget _buildGroupLinkifiedText(String text) {
    final baseStyle = const TextStyle(color: Colors.white, fontSize: 15);
    final linkStyle = baseStyle.copyWith(
      color: const Color(0xFF93C5FD),
      decoration: TextDecoration.underline,
      decorationColor: const Color(0xFF93C5FD),
    );

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in _messageUrlRegex.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(
          TextSpan(text: text.substring(cursor, match.start), style: baseStyle),
        );
      }
      final matchedText = match.group(0) ?? '';
      final cleanedUrl = _trimTrailingUrlCharacters(matchedText);
      final trailing = matchedText.substring(cleanedUrl.length);
      if (cleanedUrl.isNotEmpty) {
        final recognizer = TapGestureRecognizer()
          ..onTap = () => _openMessageUrl(cleanedUrl);
        _linkRecognizers.add(recognizer);
        spans.add(
          TextSpan(text: cleanedUrl, style: linkStyle, recognizer: recognizer),
        );
      }
      if (trailing.isNotEmpty) {
        spans.add(TextSpan(text: trailing, style: baseStyle));
      }
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: baseStyle));
    }
    if (spans.isEmpty) {
      spans.add(TextSpan(text: text, style: baseStyle));
    }
    return Text.rich(TextSpan(children: spans));
  }

  /// Builds a group message using the shared [ChatMessageBubble] so the UI is
  /// identical to the 1:1 chat. Group-only bits (sender name/color, per-member
  /// reactions) are passed through the bubble's optional hooks.
  Widget _buildSharedGroupBubble(
    GroupMessage message,
    bool isSentByMe,
    Map<int, Map<String, Set<String>>> reactionsForUi,
  ) {
    return ChatMessageBubble(
      message: message.toMessage(),
      isSentByMe: isSentByMe,
      scale: 1.0,
      showTimestamps: _showTimestamps,
      isSelected: _bubbleFlashId == message.id,
      messageReactions: reactionsForUi,
      messageTranslations: _messageTranslations,
      onTapUp: (details) {
        final hasUrl = _messageUrlRegex.hasMatch(message.content);
        if (!hasUrl) {
          _toggleTaskActionForMessage(message, details.globalPosition);
        }
      },
      onLongPress: () => _showGroupMessageContextMenu(message, isSentByMe),
      onShowReactionPicker: _showGroupReactionPicker,
      onOpenMediaViewer: (_) => _openMediaViewer(message),
      onDownloadIncomingFile: (_) => _downloadGroupIncomingFile(message),
      onOpenMessageUrl: _openMessageUrl,
      statusForUi: _statusForUi,
      isOnlyFilename: _isOnlyFilename,
      canQuickToggleExcalidrawPin: (m) => _isExcalidrawContent(m.content),
      formatFileSize: _formatFileSize,
      buildReactionPills: _buildGroupReactionPills,
      buildLinkifiedMessageText:
          ({
            required String text,
            required bool isTaskMessage,
            required Color taskAccentColor,
          }) => _buildGroupLinkifiedText(text),
      buildStatusIndicator: _buildStatusIndicator,
      senderName: isSentByMe ? null : message.sender?.fullName,
      senderColor: _senderColorForId(message.senderId),
    );
  }

  Widget _buildMessageBubble(GroupMessage message) {
    // Deleted messages: admins see nothing, normal users see a placeholder
    if (message.isDeleted) {
      if (_currentUserIsAdmin) {
        return const SizedBox.shrink();
      }
      final isSentByMe = message.senderId == _currentUserId;
      return Align(
        alignment: isSentByMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isSentByMe ? 16 : 4),
              bottomRight: Radius.circular(isSentByMe ? 4 : 16),
            ),
          ),
          child: const Text(
            'This message was deleted',
            style: TextStyle(
              color: Colors.white54,
              fontStyle: FontStyle.italic,
              fontSize: 13,
            ),
          ),
        ),
      );
    }

    // Handle system messages (doorbell notifications from others, etc.)
    if (message.messageType == 'system') {
      String displayContent = message.content;
      final isFromCreator =
          message.senderId == _currentUserId ||
          widget.group.createdBy == _currentUserId;
      if (isFromCreator &&
          (displayContent.contains('created the group') ||
              displayContent.contains('created this group') ||
              displayContent == 'You created this group')) {
        displayContent = 'You created this group';
      }
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF4C1D95).withOpacity(0.3),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            displayContent,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontStyle: FontStyle.italic,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Handle doorbell messages as regular outgoing messages
    if (message.messageType == 'doorbell') {
      // Treat doorbell messages as regular messages (they'll show as outgoing for sender)
      // The message content is already set to "You sent a notification! 🔔"
    }

    final isSentByMe = message.senderId == _currentUserId;
    final bool isImage =
        message.messageType == 'image' ||
        (message.fileType?.startsWith('image/') ?? false);
    final bool isVideo =
        message.messageType == 'video' ||
        (message.fileType?.startsWith('video/') ?? false);
    final bool isAudio =
        message.messageType == 'voice' ||
        message.messageType == 'audio' ||
        (message.fileType?.startsWith('audio/') ?? false);
    final bool isMedia = isImage || isVideo;
    final bool isGenericFile =
        (!isMedia && !isAudio) &&
        ((message.messageType == 'file' || message.messageType == 'document') ||
            (message.fileUrl != null && message.fileUrl!.isNotEmpty));

    // Debug logging for file message display
    if (message.messageType != 'text' && message.messageType != 'system') {
      // Commented out to reduce log noise - uncomment if needed for file debugging
      /*
      debugPrint('🎨 [MESSAGE DISPLAY] Rendering file message:');
      debugPrint('🎨 [MESSAGE DISPLAY] - ID: ${message.id}');
      debugPrint('🎨 [MESSAGE DISPLAY] - Type: ${message.messageType}');
      debugPrint('🎨 [MESSAGE DISPLAY] - isImage: $isImage');
      debugPrint('🎨 [MESSAGE DISPLAY] - isVideo: $isVideo');
      debugPrint('🎨 [MESSAGE DISPLAY] - isAudio: $isAudio');
      debugPrint('🎨 [MESSAGE DISPLAY] - isMedia: $isMedia');
      debugPrint('🎨 [MESSAGE DISPLAY] - fileUrl: ${message.fileUrl}');
      debugPrint('🎨 [MESSAGE DISPLAY] - fileName: ${message.fileName}');
      debugPrint('🎨 [MESSAGE DISPLAY] - fileType: ${message.fileType}');
      debugPrint('🎨 [MESSAGE DISPLAY] - content: ${message.content}');
      */
    }

    // Check if this message has reactions to adjust bottom margin
    final hasReactions = message.reactions.isNotEmpty;

    // Build the main bubble widget
    final bubbleWidget = Container(
      margin: EdgeInsets.only(bottom: hasReactions ? 2 : 12),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.70,
      ),
      decoration: BoxDecoration(
        color: isSentByMe ? const Color(0xFF420796) : const Color(0xFF3944BC),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isSentByMe ? 16 : 4),
          bottomRight: Radius.circular(isSentByMe ? 4 : 16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Quoted reply (if this is a reply to another message)
          if (message.replyToId != null || message.replyPreview != null)
            Opacity(
              opacity: 0.85,
              child: Container(
                margin: const EdgeInsets.only(left: 8, right: 8, top: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(38),
                  borderRadius: BorderRadius.circular(6),
                  border: const Border(
                    left: BorderSide(color: Color(0xFFB794F6), width: 3),
                  ),
                ),
                child: Builder(
                  builder: (context) {
                    // Parse reply preview
                    final preview = message.replyPreview ?? '';
                    final colonIndex = preview.indexOf(':');
                    final senderName = colonIndex > 0
                        ? preview.substring(0, colonIndex)
                        : 'Reply';
                    var contentText = colonIndex > 0
                        ? preview.substring(colonIndex + 1).trim()
                        : preview;

                    // Improve display for file messages
                    if (contentText.contains('<audio') ||
                        contentText.contains('audio/')) {
                      contentText = '🎤 Voice message';
                    } else if (contentText.contains('<img') ||
                        contentText.contains('image/')) {
                      contentText = '📷 Photo';
                    } else if (contentText.contains('<video') ||
                        contentText.contains('video/')) {
                      contentText = '🎬 Video';
                    } else if (contentText.contains('file/') ||
                        contentText.endsWith('.pdf') ||
                        contentText.endsWith('.doc')) {
                      contentText = '📎 File';
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          senderName,
                          style: TextStyle(
                            color: Colors.white.withAlpha(230),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          contentText,
                          style: TextStyle(
                            color: Colors.white.withAlpha(179),
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          // Image/Video content
          if (isMedia && message.fileUrl != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(
                  (message.content.isNotEmpty &&
                              !_isOnlyFilename(message.content)) ||
                          (message.caption != null &&
                              message.caption!.isNotEmpty)
                      ? 0
                      : (isSentByMe ? 16 : 4),
                ),
                bottomRight: Radius.circular(
                  (message.content.isNotEmpty &&
                              !_isOnlyFilename(message.content)) ||
                          (message.caption != null &&
                              message.caption!.isNotEmpty)
                      ? 0
                      : (isSentByMe ? 4 : 16),
                ),
              ),
              child: GestureDetector(
                onTap: () => _openMediaViewer(message),
                child: Builder(
                  builder: (context) {
                    // Fixed media box so the bubble never resizes (no layout
                    // jump) between placeholder, loaded, and error states.
                    final mediaWidth = MediaQuery.of(context).size.width * 0.70;
                    final mediaHeight = (mediaWidth * 0.75).clamp(180.0, 300.0);
                    return SizedBox(
                      width: mediaWidth,
                      height: mediaHeight,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Positioned.fill(
                            child: Container(color: Colors.grey[850]),
                          ),
                          if (isImage)
                            Positioned.fill(
                              child: CachedImage(
                                url: message.fileUrl!,
                                fit: BoxFit.cover,
                                placeholderColor: Colors.grey.shade800,
                                errorWidget: Container(
                                  color: Colors.grey[800],
                                  child: const Center(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.broken_image,
                                          color: Colors.white54,
                                          size: 40,
                                        ),
                                        SizedBox(height: 8),
                                        Text(
                                          'Image failed to load',
                                          style: TextStyle(
                                            color: Colors.white54,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            )
                          else if (isVideo)
                            Positioned.fill(
                              child: _GroupVideoThumbnailWidget(
                                videoUrl: message.fileUrl!,
                              ),
                            ),
                          // Play button overlay for video
                          if (isVideo)
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: const BoxDecoration(
                                color: Colors.black45,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.play_arrow,
                                color: Colors.white,
                                size: 36,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            // File info row (filename + size)
            if (message.fileName != null || message.fileSize != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Icon(
                      isVideo ? Icons.videocam_outlined : Icons.image_outlined,
                      color: Colors.white54,
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        message.fileName ?? 'Media',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (message.fileSize != null && message.fileSize! > 0) ...[
                      const SizedBox(width: 8),
                      Text(
                        _formatFileSize(message.fileSize!),
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ] else if (isMedia && message.fileUrl == null) ...[
            // Fallback for media messages without fileUrl
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    isImage ? Icons.image : Icons.videocam,
                    color: Colors.white70,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.fileName ?? (isImage ? 'Image' : 'Video'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'File not available',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          // Audio/Voice message content
          if (isAudio && message.fileUrl != null) ...[
            _buildAudioPlayer(message.fileUrl!, duration: message.duration),
          ] else if (isAudio && message.fileUrl == null) ...[
            // Fallback for audio messages without fileUrl
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.audiotrack, color: Colors.white70, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.fileName ?? 'Audio',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Audio file not available',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          // Generic file message (not image, video, or audio)
          if (isGenericFile) _buildGroupGenericFile(message),
          // Text content (if not just filename and not audio)
          if ((!isMedia &&
                  !isAudio &&
                  message.messageType != 'file' &&
                  message.messageType != 'document') ||
              (message.content.isNotEmpty &&
                  !_isOnlyFilename(message.content) &&
                  !isAudio &&
                  message.messageType != 'file' &&
                  message.messageType != 'document') ||
              (message.caption != null && message.caption!.isNotEmpty))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Original message text
                  Text(
                    message.caption ??
                        (isMedia
                            ? (message.fileName ?? message.content)
                            : message.content),
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                  // Translation (if available)
                  if (_messageTranslations.containsKey(message.id)) ...[
                    const SizedBox(height: 8),
                    // Separator line
                    Container(
                      height: 1,
                      color: Colors.white.withOpacity(0.3),
                      margin: const EdgeInsets.symmetric(vertical: 4),
                    ),
                    // Translated text with language indicator
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Globe icon
                        Icon(
                          Icons.language,
                          size: 14,
                          color: Colors.white.withOpacity(0.7),
                        ),
                        const SizedBox(width: 4),
                        // Language indicator (placeholder for now)
                        Text(
                          'auto → en',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Translated text in italic
                    Text(
                      _messageTranslations[message.id]!,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            )
          else if (isMedia || isAudio)
            const SizedBox(height: 8),
          // Message status indicator and timestamp for sent messages
          if (isSentByMe)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child:
                  (message.fileUrl != null &&
                      message.fileUrl!.isNotEmpty &&
                      (isMedia || isAudio || isGenericFile))
                  ? Row(
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        Text(
                          message.formattedTime,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.done_all,
                          size: 16,
                          color: Colors.white70,
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => _downloadGroupIncomingFile(message),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 0,
                            ),
                            visualDensity: const VisualDensity(
                              horizontal: -3,
                              vertical: -3,
                            ),
                          ),
                          child: const Text(
                            'Save',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              height: 1,
                            ),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          message.formattedTime,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.done_all,
                          size: 16,
                          color: Colors.white70,
                        ),
                      ],
                    ),
            ),
          // Full timestamp - only visible when _showTimestamps is true
          if (_showTimestamps)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                message.formattedTimestampFull,
                style: const TextStyle(
                  color: Color(0xFFFF69B4), // Hot pink
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );

    // Wrap bubble with Column for reactions below
    return Align(
      alignment: isSentByMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isSentByMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Show sender name for group messages (except own messages)
          if (!isSentByMe && message.sender != null)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 4),
              child: Text(
                message.sender!.fullName,
                style: TextStyle(
                  color: Colors.grey[400],
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          // The bubble
          GestureDetector(
            onLongPress: () =>
                _showGroupMessageContextMenu(message, isSentByMe),
            child: bubbleWidget,
          ),
          // Reaction pills below bubble
          if (hasReactions)
            Padding(
              padding: EdgeInsets.only(
                left: isSentByMe ? 0 : 8,
                right: isSentByMe ? 8 : 0,
                top: 0,
                bottom: 6,
              ),
              child: Wrap(
                spacing: 4,
                children: message.reactions.entries.map((entry) {
                  final emoji = entry.key;
                  final users = entry.value as List;
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFF420796),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      '$emoji ${users.length}',
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  /// Check if content is just a filename (for media messages)
  bool _isOnlyFilename(String content) {
    if (content.isEmpty) return true;
    // Check if it looks like a filename with extension
    final filenamePattern = RegExp(r'^[\w\-\.\s]+\.\w{2,5}$');
    return filenamePattern.hasMatch(content.trim());
  }

  /// Format file size in human readable format
  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  // Generic (non-media) file bubble content: web-matching document icon, name,
  // "EXT · size". The open-on-web button was intentionally removed (Save remains).
  Widget _buildGroupGenericFile(GroupMessage message) {
    final String fileName =
        (message.fileName != null && message.fileName!.isNotEmpty)
        ? message.fileName!
        : (message.fileUrl != null
              ? (Uri.tryParse(
                      message.fileUrl!,
                    )?.pathSegments.last.replaceAll('%20', ' ') ??
                    'File')
              : 'File');
    final String ext = FileTypeIcon.extensionOf(fileName);
    final String sizeStr = (message.fileSize != null && message.fileSize! > 0)
        ? _formatFileSize(message.fileSize!)
        : (message.fileUrl != null ? 'Unknown size' : 'File not available');
    final String subtitle = ext.isNotEmpty
        ? '${ext.toUpperCase()} · $sizeStr'
        : sizeStr;

    return Container(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          FileTypeIcon(fileName: fileName),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Resolve a directory to save downloaded files
  Future<Directory> _resolveDownloadDirectory() async {
    if (Platform.isAndroid) {
      final sharedDownloads = Directory('/storage/emulated/0/Download');
      if (!await sharedDownloads.exists()) {
        await sharedDownloads.create(recursive: true);
      }
      return sharedDownloads;
    }

    final systemDownloads = await getDownloadsDirectory();
    if (systemDownloads != null) return systemDownloads;

    final appDocs = await getApplicationDocumentsDirectory();
    final fallbackDownloads = Directory(
      '${appDocs.path}${Platform.pathSeparator}Downloads',
    );
    if (!await fallbackDownloads.exists()) {
      await fallbackDownloads.create(recursive: true);
    }
    return fallbackDownloads;
  }

  /// Request storage permission for downloads
  Future<bool> _requestStorageAccessForFileOps() async {
    final storageStatus = await Permission.storage.request();
    if (storageStatus.isGranted) return true;

    final manageStatus = await Permission.manageExternalStorage.request();
    if (manageStatus.isGranted) return true;

    if (mounted) {
      _showTopSnackBar(
        const SnackBar(
          content: Text('Storage permission required to save files'),
          backgroundColor: Colors.orange,
        ),
      );
    }
    return false;
  }

  /// Download incoming file message in group chat
  Future<void> _downloadGroupIncomingFile(GroupMessage message) async {
    final fileUrl = message.fileUrl;
    if (fileUrl == null || fileUrl.isEmpty) {
      if (!mounted) return;
      _showTopSnackBar(const SnackBar(content: Text('File URL not available')));
      return;
    }

    if (mounted) {
      _showTopSnackBar(const SnackBar(content: Text('Downloading file...')));
    }

    try {
      final uri = Uri.parse(fileUrl);
      final response = await http.get(uri).timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode > 299) {
        throw Exception('Download failed with status ${response.statusCode}');
      }

      final mimeType =
          message.fileType ??
          lookupMimeType(uri.path) ??
          'application/octet-stream';
      final outputName = message.fileName ?? uri.pathSegments.last;

      if (Platform.isAndroid) {
        await _saveToAndroidDownloads(
          fileName: outputName,
          mimeType: mimeType,
          bytes: response.bodyBytes,
        );
      } else {
        final downloadDir = await _resolveDownloadDirectory();
        final saveFile = File(
          '${downloadDir.path}${Platform.pathSeparator}$outputName',
        );
        await saveFile.writeAsBytes(response.bodyBytes, flush: true);
      }

      if (mounted) {
        _showTopSnackBar(
          SnackBar(
            content: Text('Saved to Downloads: $outputName'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error downloading group file: $e');
      if (mounted) {
        _showTopSnackBar(
          SnackBar(
            content: Text('Failed to download file: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _saveToAndroidDownloads({
    required String fileName,
    required String mimeType,
    required List<int> bytes,
  }) async {
    await _fileOpsChannel.invokeMethod('saveToDownloads', {
      'fileName': fileName,
      'mimeType': mimeType,
      'bytes': bytes,
    });
  }

  /// Open the full-screen swipeable media gallery (mirrors the 1:1 chat).
  /// Collects all image/video messages in the group so the user can swipe
  /// between them, starting at the tapped message.
  void _openMediaViewer(GroupMessage message) {
    if (message.fileUrl == null) return;

    final mediaMessages = _messages.where((m) {
      if (m.isDeleted) return false;
      if (m.fileUrl == null || m.fileUrl!.isEmpty) return false;
      final isImage =
          m.messageType == 'image' ||
          (m.fileType?.startsWith('image/') ?? false);
      final isVideo =
          m.messageType == 'video' ||
          (m.fileType?.startsWith('video/') ?? false);
      return isImage || isVideo;
    }).toList()..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));

    if (mediaMessages.isEmpty) return;

    final initialIndex = mediaMessages.indexWhere((m) => m.id == message.id);
    if (initialIndex == -1) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => MediaGalleryViewer(
          mediaMessages: mediaMessages.map((m) => m.toMessage()).toList(),
          initialIndex: initialIndex,
          currentUserId: _currentUserId ?? 0,
          otherUserName: _groupName,
        ),
      ),
    );
  }

  /// Build audio player widget
  Widget _buildAudioPlayer(String audioUrl, {double? duration}) {
    return _AudioMessagePlayer(
      audioUrl: audioUrl,
      initialDuration: duration,
    );
  }

  Widget _buildTypingIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: _headerColor,
        border: const Border(
          top: BorderSide(color: Color(0xFF3D3D3D), width: 1),
        ),
      ),
      child: RepaintBoundary(child: _buildTypingPreviewBubble()),
    );
  }

  Widget _buildTypingPreviewBubble() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFFA32CC4), // Same purple color as 1-on-1 chat
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          _typingMessage.isEmpty
              ? '$_typingUserName is typing...'
              : '$_typingUserName: $_typingMessage',
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
      ),
    );
  }

  Widget _buildReplyPreview() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: const Color(0xFF1E293B),
      child: Row(
        children: [
          Container(width: 4, height: 40, color: const Color(0xFF8B5CF6)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _replyingToMessage!.sender?.firstName ?? 'Someone',
                  style: const TextStyle(
                    color: Color(0xFF8B5CF6),
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _replyingToMessage!.content,
                  style: const TextStyle(color: Colors.grey, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.grey),
            onPressed: () {
              setState(() {
                _replyingToMessage = null;
              });
            },
          ),
        ],
      ),
    );
  }

  // Emoji categories with icons and data
  static const List<Map<String, dynamic>> _emojiCategories = [
    {
      'icon': '😀',
      'label': 'Smileys',
      'emojis': [
        '😀',
        '😃',
        '😄',
        '😁',
        '😆',
        '😅',
        '😂',
        '🤣',
        '🥲',
        '😊',
        '😇',
        '🙂',
        '🙃',
        '😉',
        '😌',
        '😍',
        '🥰',
        '😘',
        '😗',
        '😙',
        '😚',
        '😋',
        '😛',
        '😝',
        '😜',
        '🤪',
        '🤨',
        '🧐',
        '🤓',
        '😎',
        '🥸',
        '🤩',
        '🥳',
        '😏',
        '😒',
        '😞',
        '😔',
        '😟',
        '😕',
        '🙁',
        '😣',
        '😖',
        '😫',
        '😩',
        '🥺',
        '😢',
        '😭',
        '😤',
        '😠',
        '😡',
        '🤬',
        '🤯',
        '😳',
        '🥵',
        '🥶',
        '😱',
        '😨',
        '😰',
        '😥',
        '😓',
        '🤗',
        '🤔',
        '🫣',
        '🤭',
        '🫢',
        '🫡',
        '🤫',
        '🫠',
        '🤥',
        '😶',
        '😐',
        '😑',
        '😬',
        '🫨',
        '🙄',
        '😯',
        '😦',
        '😧',
        '😮',
        '😲',
        '🥱',
        '😴',
        '🤤',
        '😪',
        '😵',
        '😵‍💫',
        '🫥',
        '🤐',
        '🥴',
        '🤢',
        '🤮',
        '🤧',
        '😷',
        '🤒',
        '🤕',
        '🤑',
        '🤠',
        '😈',
        '👿',
        '👹',
        '👺',
        '🤡',
        '💩',
        '👻',
        '💀',
        '☠️',
        '👽',
        '👾',
        '🤖',
        '🎃',
        '😺',
        '😸',
        '😹',
        '😻',
        '😼',
        '😽',
        '🙀',
        '😿',
        '😾',
      ],
    },
    {
      'icon': '👋',
      'label': 'Gestures',
      'emojis': [
        '👋',
        '🤚',
        '🖐️',
        '✋',
        '🖖',
        '🫱',
        '🫲',
        '🫳',
        '🫴',
        '👌',
        '🤌',
        '🤏',
        '✌️',
        '🤞',
        '🫰',
        '🤟',
        '🤘',
        '🤙',
        '👈',
        '👉',
        '👆',
        '🖕',
        '👇',
        '☝️',
        '🫵',
        '👍',
        '👎',
        '✊',
        '👊',
        '🤛',
        '🤜',
        '👏',
        '🙌',
        '🫶',
        '👐',
        '🤲',
        '🤝',
        '🙏',
        '✍️',
        '💅',
        '🤳',
        '💪',
        '🦾',
        '🦿',
        '🦵',
        '🦶',
        '👂',
        '🦻',
        '👃',
        '🧠',
        '🫀',
        '🫁',
        '🦷',
        '🦴',
        '👀',
        '👁️',
        '👅',
        '👄',
        '🫦',
        '💋',
      ],
    },
    {
      'icon': '❤️',
      'label': 'Hearts',
      'emojis': [
        '❤️',
        '🧡',
        '💛',
        '💚',
        '💙',
        '💜',
        '🖤',
        '🤍',
        '🤎',
        '❤️‍🔥',
        '❤️‍🩹',
        '💔',
        '❣️',
        '💕',
        '💞',
        '💓',
        '💗',
        '💖',
        '💘',
        '💝',
        '💟',
        '♥️',
        '🩷',
        '🩵',
        '🩶',
        '💌',
        '💐',
        '🌹',
        '🥀',
        '🌺',
        '🌸',
        '🌷',
        '🌻',
        '💑',
        '👩‍❤️‍👨',
        '👨‍❤️‍👨',
        '👩‍❤️‍👩',
        '💏',
        '😍',
        '🥰',
        '😘',
        '😻',
        '💒',
        '🏩',
      ],
    },
    {
      'icon': '🐱',
      'label': 'Animals',
      'emojis': [
        '🐶',
        '🐱',
        '🐭',
        '🐹',
        '🐰',
        '🦊',
        '🐻',
        '🐼',
        '🐻‍❄️',
        '🐨',
        '🐯',
        '🦁',
        '🐮',
        '🐷',
        '🐸',
        '🐵',
        '🙈',
        '🙉',
        '🙊',
        '🐒',
        '🐔',
        '🐧',
        '🐦',
        '🐤',
        '🐣',
        '🐥',
        '🦆',
        '🦅',
        '🦉',
        '🦇',
        '🐺',
        '🐗',
        '🐴',
        '🦄',
        '🐝',
        '🪱',
        '🐛',
        '🦋',
        '🐌',
        '🐞',
        '🐜',
        '🪰',
        '🪲',
        '🪳',
        '🦟',
        '🦗',
        '🕷️',
        '🦂',
        '🐢',
        '🐍',
        '🦎',
        '🦖',
        '🦕',
        '🐙',
        '🦑',
        '🦐',
        '🦞',
        '🦀',
        '🐡',
        '🐠',
        '🐟',
        '🐬',
        '🐳',
        '🐋',
        '🦈',
        '🦭',
        '🐊',
        '🐅',
        '🐆',
        '🦓',
        '🦍',
        '🦧',
        '🐘',
        '🦛',
        '🦏',
        '🐪',
        '🐫',
        '🦒',
        '🦘',
        '🦬',
      ],
    },
    {
      'icon': '🍕',
      'label': 'Food',
      'emojis': [
        '🍏',
        '🍎',
        '🍐',
        '🍊',
        '🍋',
        '🍌',
        '🍉',
        '🍇',
        '🍓',
        '🫐',
        '🍈',
        '🍒',
        '🍑',
        '🥭',
        '🍍',
        '🥥',
        '🥝',
        '🍅',
        '🍆',
        '🥑',
        '🥦',
        '🥬',
        '🥒',
        '🌶️',
        '🫑',
        '🌽',
        '🥕',
        '🫒',
        '🧄',
        '🧅',
        '🥔',
        '🍠',
        '🥐',
        '🥯',
        '🍞',
        '🥖',
        '🥨',
        '🧀',
        '🥚',
        '🍳',
        '🧈',
        '🥞',
        '🧇',
        '🥓',
        '🥩',
        '🍗',
        '🍖',
        '🌭',
        '🍔',
        '🍟',
        '🍕',
        '🫓',
        '🥪',
        '🥙',
        '🧆',
        '🌮',
        '🌯',
        '🫔',
        '🥗',
        '🥘',
        '🫕',
        '🍝',
        '🍜',
        '🍲',
        '🍛',
        '🍣',
        '🍱',
        '🥟',
        '🦪',
        '🍤',
        '🍙',
        '🍚',
        '🍘',
        '🍥',
        '🥠',
        '🥮',
        '🍢',
        '🍡',
        '🍧',
        '🍨',
        '🍦',
        '🥧',
        '🧁',
        '🍰',
        '🎂',
        '🍮',
        '🍭',
        '🍬',
        '🍫',
        '🍩',
        '🍪',
        '🌰',
        '🥜',
        '🍯',
        '🥛',
        '🍼',
        '☕',
        '🍵',
        '🧃',
        '🥤',
        '🧋',
        '🍶',
        '🍺',
        '🍻',
        '🥂',
        '🍷',
        '🥃',
        '🍸',
        '🍹',
        '🧉',
      ],
    },
    {
      'icon': '⚽',
      'label': 'Activities',
      'emojis': [
        '⚽',
        '🏀',
        '🏈',
        '⚾',
        '🥎',
        '🎾',
        '🏐',
        '🏉',
        '🥏',
        '🎱',
        '🪀',
        '🏓',
        '🏸',
        '🏒',
        '🏑',
        '🥍',
        '🏏',
        '🪃',
        '🥅',
        '⛳',
        '🪁',
        '🏹',
        '🎣',
        '🤿',
        '🥊',
        '🥋',
        '🎽',
        '🛹',
        '🛼',
        '🛷',
        '⛸️',
        '🥌',
        '🎿',
        '⛷️',
        '🏂',
        '🪂',
        '🏋️',
        '🤼',
        '🤸',
        '🤺',
        '⛹️',
        '🤾',
        '🏌️',
        '🏇',
        '🧘',
        '🏄',
        '🏊',
        '🤽',
        '🚣',
        '🧗',
        '🚵',
        '🚴',
        '🏆',
        '🥇',
        '🥈',
        '🥉',
        '🏅',
        '🎖️',
        '🏵️',
        '🎗️',
        '🎪',
        '🤹',
        '🎭',
        '🩰',
        '🎨',
        '🎬',
        '🎤',
        '🎧',
        '🎼',
        '🎹',
        '🥁',
        '🪘',
        '🎷',
        '🎺',
        '🪗',
        '🎸',
        '🪕',
        '🎻',
        '🎲',
        '♟️',
        '🎯',
        '🎳',
        '🎮',
        '🕹️',
        '🧩',
      ],
    },
    {
      'icon': '🚗',
      'label': 'Travel',
      'emojis': [
        '🚗',
        '🚕',
        '🚙',
        '🚌',
        '🚎',
        '🏎️',
        '🚓',
        '🚑',
        '🚒',
        '🚐',
        '🛻',
        '🚚',
        '🚛',
        '🚜',
        '🏍️',
        '🛵',
        '🚲',
        '🛴',
        '🛺',
        '🚔',
        '🚍',
        '🚘',
        '🚖',
        '🛞',
        '🚡',
        '🚠',
        '🚟',
        '🚃',
        '🚋',
        '🚞',
        '🚝',
        '🚄',
        '🚅',
        '🚈',
        '🚂',
        '🚆',
        '🚇',
        '🚊',
        '🚉',
        '✈️',
        '🛫',
        '🛬',
        '🛩️',
        '💺',
        '🛰️',
        '🚀',
        '🛸',
        '🚁',
        '🛶',
        '⛵',
        '🚤',
        '🛥️',
        '🛳️',
        '⛴️',
        '🚢',
        '🗼',
        '🏰',
        '🏯',
        '🏟️',
        '🎡',
        '🎢',
        '🎠',
        '⛲',
        '⛱️',
        '🏖️',
        '🏝️',
        '🏜️',
        '🌋',
        '⛰️',
        '🏔️',
        '🗻',
        '🏕️',
        '🛖',
        '🏠',
        '🏡',
        '🏢',
        '🏬',
        '🏣',
        '🏤',
        '🏥',
      ],
    },
    {
      'icon': '💡',
      'label': 'Objects',
      'emojis': [
        '🔥',
        '💧',
        '🌟',
        '⭐',
        '✨',
        '💫',
        '🌈',
        '☀️',
        '🌤️',
        '⛅',
        '🎉',
        '🎊',
        '🎈',
        '🎁',
        '🎀',
        '🎄',
        '🪅',
        '🎆',
        '🎇',
        '🧨',
        '💡',
        '🔦',
        '🕯️',
        '🪔',
        '💎',
        '🔮',
        '🧿',
        '🪬',
        '💰',
        '💴',
        '💵',
        '💶',
        '💷',
        '🪙',
        '💳',
        '💸',
        '🧲',
        '🔧',
        '🪛',
        '🔩',
        '⚙️',
        '🧰',
        '🪜',
        '🧱',
        '🪨',
        '🪵',
        '🔗',
        '🧬',
        '🔬',
        '🔭',
        '📡',
        '💉',
        '🩸',
        '💊',
        '🩹',
        '🩼',
        '🩺',
        '🩻',
        '🚪',
        '🛗',
        '🪞',
        '🪟',
        '🛏️',
        '🛋️',
        '🪑',
        '🚽',
        '🪠',
        '🚿',
        '🛁',
        '🪤',
        '📱',
        '💻',
        '⌨️',
        '🖥️',
        '🖨️',
        '🖱️',
        '💾',
        '💿',
        '📀',
        '📷',
        '📸',
        '📹',
        '🎥',
        '📽️',
        '🎞️',
        '📞',
        '☎️',
        '📟',
        '📠',
        '📺',
        '📻',
        '🎙️',
        '🎚️',
        '🎛️',
        '🧭',
        '⏱️',
        '⏲️',
        '⏰',
        '🕰️',
        '📡',
      ],
    },
    {
      'icon': '🏁',
      'label': 'Symbols',
      'emojis': [
        '🏳️',
        '🏴',
        '🏁',
        '🚩',
        '🏳️‍🌈',
        '🏳️‍⚧️',
        '🏴‍☠️',
        '✅',
        '❌',
        '❓',
        '❗',
        '‼️',
        '⁉️',
        '💯',
        '🔴',
        '🟠',
        '🟡',
        '🟢',
        '🔵',
        '🟣',
        '⚫',
        '⚪',
        '🟤',
        '🔶',
        '🔷',
        '🔸',
        '🔹',
        '🔺',
        '🔻',
        '💠',
        '🔘',
        '🔳',
        '🔲',
        '▪️',
        '▫️',
        '◾',
        '◽',
        '◼️',
        '◻️',
        '🟥',
        '🟧',
        '🟨',
        '🟩',
        '🟦',
        '🟪',
        '⬛',
        '⬜',
        '🟫',
        '♈',
        '♉',
        '♊',
        '♋',
        '♌',
        '♍',
        '♎',
        '♏',
        '♐',
        '♑',
        '♒',
        '♓',
        '⛎',
        '🔀',
        '🔁',
        '🔂',
        '▶️',
        '⏩',
        '⏭️',
        '⏯️',
        '◀️',
        '⏪',
        '⏮️',
        '🔼',
        '⏫',
        '🔽',
        '⏬',
        '⏸️',
        '⏹️',
        '⏺️',
        '⏏️',
        '🎦',
        '♾️',
        '♻️',
        '⚜️',
        '🔱',
        '📛',
        '🔰',
        '⭕',
        '✅',
        '☑️',
        '✔️',
        '❌',
        '❎',
        '➕',
        '➖',
        '➗',
        '✖️',
        '💲',
        '💱',
        '™️',
        '©️',
        '®️',
        '〰️',
        '➰',
        '➿',
        '🔚',
        '🔙',
        '🔛',
        '🔝',
        '🔜',
        '🆕',
      ],
    },
  ];

  // Some newer emoji code points are not available on older Android emoji fonts.
  // Normalize them to broadly supported alternatives for consistent rendering.
  static const Map<String, String> _emojiCompatibilityFallbacks = {
    '🩷': '💗',
    '🩵': '💙',
    '🩶': '🤍',
    '🫶': '🤝',
    '🫵': '👉',
    '🫱': '👈',
    '🫲': '👉',
    '🫳': '👇',
    '🫴': '🖐️',
    '🫰': '👌',
    '🫠': '🙂',
    '🫡': '👍',
    '🫣': '🙈',
    '🫢': '🤐',
    '🫥': '😶',
    '🫨': '😲',
    '🫦': '💋',
    '🫀': '❤️',
    '🫁': '💨',
    '🩻': '🦴',
    '🩼': '🦯',
  };

  bool _isPotentiallyUnsupportedEmoji(String emoji) {
    for (final rune in emoji.runes) {
      if (rune >= 0x1FA70 && rune <= 0x1FAFF) {
        return true;
      }
    }
    return false;
  }

  String _normalizeEmojiForCompatibility(String emoji) {
    final mapped = _emojiCompatibilityFallbacks[emoji];
    if (mapped != null) {
      return mapped;
    }

    // Skip unmapped symbols in newer emoji blocks to avoid tofu squares.
    if (_isPotentiallyUnsupportedEmoji(emoji)) {
      return '';
    }

    return emoji;
  }

  List<String> _normalizedEmojiList(List<String> emojis) {
    final normalized = <String>[];
    final seen = <String>{};

    for (final emoji in emojis) {
      final safeEmoji = _normalizeEmojiForCompatibility(emoji);
      if (safeEmoji.isEmpty) {
        continue;
      }

      if (seen.add(safeEmoji)) {
        normalized.add(safeEmoji);
      }
    }

    return normalized;
  }

  String _normalizeTextForEmojiCompatibility(String text) {
    var normalized = text;

    for (final entry in _emojiCompatibilityFallbacks.entries) {
      normalized = normalized.replaceAll(entry.key, entry.value);
    }

    final buffer = StringBuffer();
    for (final rune in normalized.runes) {
      if (rune >= 0x1FA70 && rune <= 0x1FAFF) {
        continue;
      }
      buffer.writeCharCode(rune);
    }

    return buffer.toString();
  }

  void _replaceInputTextWithSanitized(String sanitizedText) {
    final selection = _messageController.selection;
    final rawOffset = selection.baseOffset;
    final safeOffset = rawOffset < 0
        ? sanitizedText.length
        : rawOffset.clamp(0, sanitizedText.length).toInt();

    _messageController.value = TextEditingValue(
      text: sanitizedText,
      selection: TextSelection.collapsed(offset: safeOffset),
      composing: TextRange.empty,
    );
  }

  /// Paste from clipboard: a copied media file or screenshot is uploaded
  /// directly to the group; otherwise plain text is inserted into the composer.
  Future<void> _pasteFromClipboard() async {
    if (await _tryPasteClipboardMedia()) return;

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      final current = _messageController.text;
      _replaceInputTextWithSanitized(current.isEmpty ? text : '$current$text');
      _inputFocusNode.requestFocus();
    } else if (mounted) {
      _showTopSnackBar(
        const SnackBar(
          content: Text('Clipboard is empty'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  /// Tries to upload an image/video from the clipboard. Returns true when
  /// clipboard media was handled, false when there is nothing to paste.
  Future<bool> _tryPasteClipboardMedia() async {
    if (!(Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux ||
        Platform.isAndroid)) {
      return false;
    }

    // 1) A real media file on the clipboard (copied from a gallery/file manager).
    try {
      final media = await _fileOpsChannel.invokeMethod<Map<dynamic, dynamic>>(
        'getClipboardMediaFile',
      );
      final path = media?['path'] as String?;
      if (path != null && path.isNotEmpty) {
        final file = File(path);
        if (await file.exists() && await file.length() > 0) {
          await _uploadFile(file);
          return true;
        }
      }
    } on MissingPluginException {
      // Older native build — fall back to raw bytes / text.
    } on PlatformException catch (e) {
      if (e.code != 'NO_IMAGE' && e.code != 'UNAVAILABLE') {
        debugPrint('[GroupPaste] getClipboardMediaFile failed: ${e.code}');
      }
    } catch (e) {
      debugPrint('[GroupPaste] getClipboardMediaFile error: $e');
    }

    // 2) Raw image data (e.g. screenshots copied as a bitmap).
    try {
      final bytes = await _fileOpsChannel.invokeMethod<Uint8List>(
        'getClipboardImagePngBytes',
      );
      if (bytes == null || bytes.isEmpty) return false;

      final tempDir = await getTemporaryDirectory();
      final fileName =
          'pasted_image_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      await _uploadFile(file);
      return true;
    } on PlatformException catch (e) {
      if (e.code == 'NO_IMAGE' || e.code == 'UNAVAILABLE') return false;
      debugPrint('[GroupPaste] clipboard image paste failed: ${e.code}');
    } catch (e) {
      debugPrint('[GroupPaste] clipboard image paste error: $e');
    }
    return false;
  }

  /// Toggle emoji picker visibility (inline below input)
  void _showEmojiPickerModal(BuildContext context) {
    if (_showEmojiPicker) {
      // Closing emoji picker → bring keyboard back
      setState(() {
        _showEmojiPicker = false;
      });
      _inputFocusNode.requestFocus();
    } else {
      // Opening emoji picker → dismiss keyboard first
      _inputFocusNode.unfocus();
      setState(() {
        _showEmojiPicker = true;
      });
    }
  }

  /// Build inline emoji picker widget with category tabs
  Widget _buildInlineEmojiPicker() {
    final category = _emojiCategories[_emojiCategoryIndex];
    final emojis = _normalizedEmojiList(category['emojis'] as List<String>);

    return Container(
      height: 260,
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF3D3D3D),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // Category tabs
          SizedBox(
            height: 44,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              itemCount: _emojiCategories.length,
              itemBuilder: (context, index) {
                final cat = _emojiCategories[index];
                final icon = _normalizeEmojiForCompatibility(
                  cat['icon'] as String,
                );
                final isSelected = index == _emojiCategoryIndex;
                return GestureDetector(
                  onTap: () => setState(() => _emojiCategoryIndex = index),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF6D28D9)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        icon.isEmpty ? '🙂' : icon,
                        style: const TextStyle(fontSize: 20),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // Emoji grid
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 8,
                childAspectRatio: 1,
              ),
              itemCount: emojis.length,
              itemBuilder: (context, index) {
                return GestureDetector(
                  onTap: () {
                    // Insert emoji at cursor position
                    final text = _messageController.text;
                    final selection = _messageController.selection;
                    final cursorPos = selection.baseOffset >= 0
                        ? selection.baseOffset
                        : text.length;

                    final newText =
                        text.substring(0, cursorPos) +
                        emojis[index] +
                        text.substring(cursorPos);

                    _messageController.text = newText;
                    _messageController.selection = TextSelection.collapsed(
                      offset: cursorPos + emojis[index].length,
                    );

                    // Manually trigger typing indicator since onChanged won't fire
                    _typingEmitTimer?.cancel();
                    _typingEmitTimer = Timer(const Duration(milliseconds: 150), () {
                      debugPrint(
                        '🔍 [EMOJI TYPING DEBUG] Socket connected: ${_socketService.isConnected}',
                      );
                      debugPrint(
                        '🔍 [EMOJI TYPING DEBUG] Emitting typing for group ${widget.group.id} with text: "$newText"',
                      );
                      _socketService.sendGroupTyping(widget.group.id, newText);
                    });

                    setState(() {
                      // Hide action buttons when typing
                      if (newText.isNotEmpty && _showActionButtons) {
                        _showActionButtons = false;
                      }
                    }); // Force rebuild to update button visibility
                  },
                  child: Center(
                    child: Text(
                      emojis[index],
                      style: const TextStyle(fontSize: 24),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Ring doorbell for group (notify all members)
  void _ringDoorbell() async {
    try {
      // Create outgoing doorbell message immediately
      final now = DateTime.now();
      final tempId = now.millisecondsSinceEpoch;

      final doorbellMessage = GroupMessage(
        id: tempId,
        messageId: tempId,
        groupId: widget.group.id,
        senderId: _currentUserId!,
        sender: null, // Will be populated by server response
        content: 'You sent a notification! 🔔',
        messageType: 'doorbell',
        timestamp: now.toIso8601String(),
        timestampMs: tempId,
        reactions: {},
      );

      // Add outgoing message to UI immediately
      setState(() {
        _messages.add(doorbellMessage);
      });

      // Scroll to bottom to show the message
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });

      // Send doorbell via Socket.IO
      _socketService.ringGroupDoorbell(widget.group.id);

      debugPrint('🔔 Doorbell sent successfully');
    } catch (e) {
      debugPrint('Error ringing doorbell: $e');

      if (mounted) {
        _showTopSnackBar(
          SnackBar(content: Text('Failed to ring doorbell: $e')),
        );
      }
    }
  }

  /// Change group chat color for all members
  void _changeGroupColor() {
    // Show full-screen color picker modal
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ColorPickerModal(
        onColorSelected: (selectedColor) {
          // Only send color to other group members, don't change our own background
          final colorHex = selectedColor.value
              .toRadixString(16)
              .substring(2)
              .toUpperCase();

          // Emit group color change event
          debugPrint(
            '🎨 [MOBILE] Emitting group_color_changed for group ${widget.group.id} with color #$colorHex',
          );
          _socketService.emit('group_color_changed', {
            'group_id': widget.group.id,
            'color': '#$colorHex',
            'sender_name': 'You',
          });

          // Add outgoing system message to show we changed the group color
          final now = DateTime.now();
          final colorMessage = GroupMessage(
            id: now.millisecondsSinceEpoch,
            messageId: now.millisecondsSinceEpoch,
            groupId: widget.group.id,
            senderId: _currentUserId!,
            sender: null,
            content: 'You changed the group chat color',
            messageType: 'system',
            timestamp: now.toIso8601String(),
            timestampMs: now.millisecondsSinceEpoch,
            reactions: {},
          );

          setState(() {
            _messages.add(colorMessage);
          });

          // Scroll to bottom to show the message
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController.animateTo(
                _scrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            }
          });

          debugPrint('🎨 Group color sent: #$colorHex');
        },
      ),
    );
  }

  /// Reset group chat color locally (only for current user)
  void _resetGroupColorLocally() {
    debugPrint('🔄 [LOCAL RESET] Resetting group chat color locally');

    setState(() {
      _headerColor = const Color(0xFF4C1D95); // Reset to default
      _showResetButton = false;
    });

    // Clear saved color
    _clearGroupChatColor();

    debugPrint('🔄 [LOCAL RESET] Group chat color reset locally');
  }

  /// Reset group chat color for all members
  void _resetGroupColor() {
    _resetGroupColorLocally();

    // Emit group color reset event
    debugPrint(
      '🔄 [MOBILE] Emitting group_color_reset for group ${widget.group.id}',
    );
    _socketService.emit('group_color_reset', {
      'group_id': widget.group.id,
      'sender_name': 'You',
    });

    // Add outgoing system message
    final now = DateTime.now();
    final resetMessage = GroupMessage(
      id: now.millisecondsSinceEpoch,
      messageId: now.millisecondsSinceEpoch,
      groupId: widget.group.id,
      senderId: _currentUserId!,
      sender: null,
      content: 'You reset the group chat color',
      messageType: 'system',
      timestamp: now.toIso8601String(),
      timestampMs: now.millisecondsSinceEpoch,
      reactions: {},
    );

    setState(() {
      _messages.add(resetMessage);
    });

    // Scroll to bottom to show the message
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    debugPrint('🔄 Group color reset sent');
  }

  /// Pick a file from device storage
  Future<void> _pickFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles();
      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        await _showFilePreviewModal(file, result.files.single.name);
      }
    } catch (e) {
      debugPrint('Error picking file: $e');
      if (mounted) {
        _showTopSnackBar(SnackBar(content: Text('Failed to pick file: $e')));
      }
    }
  }

  /// Take a photo with camera
  Future<void> _takePhoto() async {
    try {
      final picker = ImagePicker();
      final XFile? photo = await picker.pickImage(source: ImageSource.camera);
      if (photo != null) {
        final file = File(photo.path);
        await _showFilePreviewModal(file, photo.name, isFromCamera: true);
      }
    } catch (e) {
      debugPrint('Error taking photo: $e');
      if (mounted) {
        _showTopSnackBar(SnackBar(content: Text('Failed to take photo: $e')));
      }
    }
  }

  /// Start a group video or audio call.
  Future<void> _startGroupCall(String callType) async {
    final myUserId = await StorageService.getUserId();
    if (myUserId == null || !mounted) return;
    final myPeerId = myUserId.toString();

    // Generate a unique room ID for this group call
    final roomId =
        'group_${widget.group.id}_${DateTime.now().millisecondsSinceEpoch}';

    // Fetch member list for invitations
    List<int> memberIds = [];
    List<String> memberUsernames = [];
    try {
      final details = await GroupService.getGroupDetails(widget.group.id);
      final members = details['members'] as List? ?? [];
      for (final m in members) {
        if (m is GroupMember) {
          if (m.userId != myUserId) {
            memberIds.add(m.userId);
            memberUsernames.add(m.user.username);
          }
        }
      }
    } catch (e) {
      debugPrint('[GroupChat] Failed to fetch members for call: $e');
    }

    // Join call room and invite all members
    _socketService.joinGroupCall(roomId, myPeerId);
    if (memberIds.isNotEmpty) {
      _socketService.inviteToGroupCall(roomId, memberIds, memberUsernames);
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupCallScreen(
          roomId: roomId,
          myPeerId: myPeerId,
          callType: callType,
          groupName: _groupName,
        ),
      ),
    );
  }

  /// Show voice recording modal (placeholder - to be implemented)
  Future<void> _showVoiceRecordingModal() async {
    // Request microphone permission
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      if (mounted) {
        _showTopSnackBar(
          SnackBar(
            content: const Text(
              'Microphone permission is required to record voice messages',
            ),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: () => openAppSettings(),
            ),
          ),
        );
      }
      return;
    }

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: false,
      enableDrag: false,
      builder: (sheetContext) => VoiceRecordingModal(
        onSend: (path, duration) async {
          Navigator.pop(sheetContext);
          // Reuse the standard file-upload path; the backend classifies an
          // audio/* upload as a 'voice' message.
          await _uploadFile(File(path));
        },
        onCancel: () => Navigator.pop(sheetContext),
      ),
    );
  }

  /// Toggle timestamp visibility
  void _toggleTimestamps() {
    setState(() {
      _showTimestamps = !_showTimestamps;
    });
  }

  /// Toggle auto-translate
  Future<void> _toggleAutoTranslate() async {
    final newValue = !_autoTranslate;
    setState(() {
      _autoTranslate = newValue;
    });

    // Save to SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoTranslate_group_${widget.group.id}', newValue);

    // Show feedback snackbar
    _showTopSnackBar(
      SnackBar(
        content: Text(
          newValue ? 'Auto-translate enabled' : 'Auto-translate disabled',
        ),
        duration: const Duration(seconds: 2),
      ),
    );

    // If enabling, translate existing messages
    if (newValue) {
      await _translateExistingMessages();
    }
  }

  /// Translate all existing messages for this group
  Future<void> _translateExistingMessages() async {
    if (!mounted) return;

    final targetLang = await TranslationService.getUserLanguage();
    debugPrint('Translating group messages to: $targetLang');

    // Get current messages from cache
    final currentUserId = await StorageService.getUserId();
    if (currentUserId == null) return;

    final messages = await ChatCacheService.loadGroupMessages(widget.group.id);

    if (messages.isEmpty) return;

    // Translate each message
    final translatedMessages = <GroupMessage>[];
    for (final message in messages) {
      if (message.content.isNotEmpty && !message.isDeleted) {
        final translated = await TranslationService.translateGroupMessageObject(
          message: message,
          targetLang: targetLang,
        );
        if (translated != null) {
          translatedMessages.add(translated);
        } else {
          // Keep original if translation fails
          translatedMessages.add(message);
        }
      } else {
        translatedMessages.add(message);
      }
    }

    // Update cache with translated messages
    await ChatCacheService.saveGroupMessages(
      widget.group.id,
      translatedMessages,
    );

    // Refresh the UI
    if (mounted) {
      setState(() {
        _messages = translatedMessages;
      });
    }
  }

  /// Show context menu for group message
  // === Group tasks ===

  /// Whether a message can be marked as a task (mirrors the 1:1 chat's rules).
  bool _canMarkGroupTask(GroupMessage message) {
    if (message.isDeleted) return false;
    const blocked = {
      'system',
      'call',
      'doorbell',
      'color_change',
      'color_reset',
    };
    return !blocked.contains(message.messageType);
  }

  /// Replace a message in the list with an updated copy (e.g. after a task op).
  void _replaceGroupMessage(GroupMessage updated) {
    final idx = _messages.indexWhere((m) => m.id == updated.id);
    if (idx == -1 || !mounted) return;
    setState(() => _messages[idx] = updated);
  }

  Future<void> _toggleGroupTask(GroupMessage message) async {
    try {
      final updated = message.isTask
          ? await GroupService.unmarkAsTask(widget.group.id, message.id)
          : await GroupService.markAsTask(widget.group.id, message.id);
      _replaceGroupMessage(updated);
      _notifyTaskModalChanged();
    } catch (e) {
      if (mounted) {
        _showTopSnackBar(SnackBar(content: Text('Failed to update task: $e')));
      }
    }
  }

  Future<void> _toggleGroupTaskComplete(GroupMessage message) async {
    try {
      final updated = await GroupService.toggleTaskComplete(
        widget.group.id,
        message.id,
      );
      _replaceGroupMessage(updated);
      _notifyTaskModalChanged();
    } catch (e) {
      if (mounted) {
        _showTopSnackBar(SnackBar(content: Text('Failed to update task: $e')));
      }
    }
  }

  /// Apply a realtime event that carries updated message state (task mark/complete/unmark + excalidraw pin/unpin).
  void _handleGroupMessageDataEvent(Map<String, dynamic> data) {
    final gid = _eventGroupId(data);
    if (gid != null && gid != widget.group.id) return;
    final mid = data['message_id'] ?? data['id'];
    if (mid == null) return;
    final idx = _messages.indexWhere((m) => m.id == mid);
    if (idx == -1) return;
    final md = data['message_data'];
    if (md is Map) {
      try {
        _replaceGroupMessage(
          GroupMessage.fromJson(Map<String, dynamic>.from(md)),
        );
        _notifyTaskModalChanged();
      } catch (e) {
        debugPrint('Error applying group data event: $e');
      }
    } else {
      final existing = _messages[idx];
      final isExcalPinned =
          data['is_excalidraw_link'] == true ||
          data['excalidraw_pinned_at'] != null;
      final isTaskCompleted = data['task_completed_at'] != null;
      final isTask = data['is_task'] == true;
      final updated = existing.copyWith(
        isExcalidrawLink: isExcalPinned,
        clearExcalidrawPinnedAt: !isExcalPinned,
        excalidrawPinnedAt: data['excalidraw_pinned_at'] as String?,
        isTask: isTask,
        taskCompletedAt: data['task_completed_at'] as String?,
        clearTaskCompletedAt: !isTaskCompleted,
      );
      _replaceGroupMessage(updated);
      _notifyTaskModalChanged();
    }
  }

  bool _canQuickToggleTaskAction(GroupMessage message) {
    return message.messageType == 'text' && !message.isDeleted;
  }

  void _toggleTaskActionForMessage(GroupMessage message, Offset tapPosition) {
    if (!_canQuickToggleTaskAction(message)) {
      return;
    }
    _showTaskActionModal(message, tapPosition);
  }

  void _showTaskActionModal(GroupMessage message, Offset tapPosition) {
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final overlaySize = overlayBox.size;
    const verticalOffset = 44.0;
    const menuWidth = 200.0;
    const menuMargin = 8.0;

    final menuTop = (tapPosition.dy - verticalOffset).clamp(
      menuMargin,
      overlaySize.height - menuMargin,
    );

    final menuLeft = (tapPosition.dx - menuWidth / 2).clamp(
      menuMargin,
      overlaySize.width - menuWidth - menuMargin,
    );

    final menuItems = _buildTaskActionMenuItems(message);
    OverlayEntry? overlayEntry;

    overlayEntry = OverlayEntry(
      builder: (context) => GestureDetector(
        onTap: () => overlayEntry?.remove(),
        behavior: HitTestBehavior.translucent,
        child: Container(
          color: Colors.transparent,
          child: Stack(
            children: [
              Positioned(
                left: menuLeft,
                top: menuTop,
                child: Material(
                  color: const Color(0xFF4C356A),
                  elevation: 8,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: menuWidth,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: IntrinsicWidth(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: menuItems.map((item) {
                          if (item is PopupMenuItem<void>) {
                            return InkWell(
                              onTap: () {
                                overlayEntry?.remove();
                                Future.microtask(() {
                                  item.onTap?.call();
                                });
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                child: item.child ?? const SizedBox.shrink(),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        }).toList(),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    Overlay.of(context).insert(overlayEntry);
  }

  List<PopupMenuEntry<void>> _buildTaskActionMenuItems(GroupMessage message) {
    final items = <PopupMenuEntry<void>>[];

    if (message.replyToId != null) {
      items.add(
        PopupMenuItem<void>(
          onTap: () => _jumpToRepliedGroupMessage(message.replyToId!),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_upward_rounded,
                color: Color(0xFF60A5FA),
                size: 18,
              ),
              SizedBox(width: 8),
              Text(
                'View replied message',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );
    }

    items.add(
      PopupMenuItem<void>(
        onTap: () => _toggleGroupTask(message),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              message.isTask
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              color: const Color(0xFFF59E0B),
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              message.isTask ? 'Unmark task' : 'Mark as task',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );

    return items;
  }

  void _jumpToRepliedGroupMessage(int replyToId) {
    final existing = _messages.firstWhere(
      (m) => m.id == replyToId,
      orElse: () => GroupMessage(
        id: replyToId,
        messageId: replyToId,
        groupId: widget.group.id,
        senderId: 0,
        content: '',
        messageType: 'text',
        timestamp: DateTime.now().toIso8601String(),
        timestampMs: 0,
      ),
    );
    _doJumpToGroupTaskBubble(existing);
  }

  Future<void> _doJumpToGroupTaskBubble(GroupMessage task) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _bubbleFlashId = task.id;
    });

    try {
      final int index = _messages.indexWhere((m) => m.id == task.id);
      if (index == -1 || !mounted || !_scrollController.hasClients) return;

      await WidgetsBinding.instance.endOfFrame;
      final ScrollPosition pos = _scrollController.position;

      final double fracOffset = _messages.length > 1
          ? (index / (_messages.length - 1)) * pos.maxScrollExtent
          : 0.0;
      final double jumpTarget = (fracOffset - pos.viewportDimension / 2 + 40)
          .clamp(0.0, pos.maxScrollExtent);
      _scrollController.jumpTo(jumpTarget);
      await WidgetsBinding.instance.endOfFrame;

      if (_messageItemKeys[task.id]?.currentContext == null) {
        final double step = 400;
        double sweep = 0;
        while (sweep <= pos.maxScrollExtent && mounted) {
          _scrollController.jumpTo(sweep.clamp(0.0, pos.maxScrollExtent));
          await WidgetsBinding.instance.endOfFrame;
          if (_messageItemKeys[task.id]?.currentContext != null) break;
          sweep += step;
        }
      }

      if (!mounted) return;
      final BuildContext? ctx = _messageItemKeys[task.id]?.currentContext;
      if (ctx == null) return;
      final RenderObject? ro = ctx.findRenderObject();
      if (ro == null || !ro.attached) return;

      final double revealOffset = RenderAbstractViewport.of(ro)
          .getOffsetToReveal(ro, 0.5)
          .offset
          .clamp(
            _scrollController.position.minScrollExtent,
            _scrollController.position.maxScrollExtent,
          );

      _scrollController.jumpTo(revealOffset);
    } finally {
      Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _bubbleFlashId = null);
      });
    }
  }

  int _getGroupCrossAxisCount(double width) {
    if (width > 900) return 4;
    if (width > 600) return 3;
    return 2;
  }

  void _showGroupTasksModal() {
    final mediaQuery = MediaQuery.of(context);
    final topOffset = mediaQuery.padding.top + kToolbarHeight + 4;
    final bottomOffset = 80.0;
    final availableHeight = mediaQuery.size.height - topOffset - bottomOffset;
    final maxDialogHeight = availableHeight > 200 ? availableHeight : 200.0;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Tasks',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: Duration.zero,
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.08),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
      pageBuilder: (context, animation, secondaryAnimation) {
        return ValueListenableBuilder<int>(
          valueListenable: _taskModalVersion,
          builder: (context, _, child) {
            final allTasks = _messages
                .where((m) => m.isTask && !m.isDeleted)
                .toList();
            final pendingTasks = allTasks
                .where((t) => t.taskCompletedAt == null)
                .toList();
            final completedTasks = allTasks
                .where((t) => t.taskCompletedAt != null)
                .toList();
            return Padding(
              padding: EdgeInsets.fromLTRB(10, topOffset, 10, 10),
              child: Align(
                alignment: Alignment.topCenter,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    constraints: BoxConstraints(maxHeight: maxDialogHeight),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A2B),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFFFBBF24).withValues(alpha: 0.65),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 24,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Color(0xFF2B2B48), Color(0xFF1F1F34)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(20),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFFF59E0B,
                                  ).withValues(alpha: 0.2),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(
                                      0xFFF59E0B,
                                    ).withValues(alpha: 0.6),
                                  ),
                                ),
                                child: const Icon(
                                  Icons.check_circle_outline,
                                  color: Color(0xFFFBBF24),
                                  size: 16,
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'Group Tasks',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.2,
                                ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFFF59E0B,
                                  ).withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: const Color(
                                      0xFFF59E0B,
                                    ).withValues(alpha: 0.5),
                                  ),
                                ),
                                child: Text(
                                  '${completedTasks.length}/${allTasks.length}',
                                  style: const TextStyle(
                                    color: Color(0xFFFCD34D),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              InkWell(
                                onTap: () => Navigator.pop(context),
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  width: 26,
                                  height: 26,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.08),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.close,
                                    color: Colors.white70,
                                    size: 16,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(
                          color: Colors.white.withValues(alpha: 0.08),
                          height: 1,
                        ),
                        Flexible(
                          child: allTasks.isEmpty
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 50,
                                          height: 50,
                                          decoration: BoxDecoration(
                                            color: const Color(
                                              0xFFF59E0B,
                                            ).withValues(alpha: 0.14),
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                            Icons.task_alt,
                                            color: Color(0xFFFBBF24),
                                            size: 26,
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          'No tasks yet',
                                          style: TextStyle(
                                            color: Colors.grey[300],
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Tap a message bubble, then tap "Mark as task"',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: Colors.grey[500],
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : StatefulBuilder(
                                  builder: (context, setModalState) {
                                    final displayTasks =
                                        _taskFilter == 'pending'
                                        ? pendingTasks
                                        : completedTasks;
                                    final otherText = _taskFilter == 'pending'
                                        ? 'Completed'
                                        : 'Pending';

                                    return Column(
                                      children: [
                                        Container(
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF1A1A2B),
                                            border: Border(
                                              bottom: BorderSide(
                                                color: Colors.white.withValues(
                                                  alpha: 0.08,
                                                ),
                                              ),
                                            ),
                                          ),
                                          padding: const EdgeInsets.fromLTRB(
                                            12,
                                            8,
                                            12,
                                            8,
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(
                                                _taskFilter == 'pending'
                                                    ? Icons.circle_outlined
                                                    : Icons.check_circle,
                                                color: _taskFilter == 'pending'
                                                    ? Colors.grey[600]
                                                    : const Color(0xFF22C55E),
                                                size: 14,
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                _taskFilter == 'pending'
                                                    ? 'Pending'
                                                    : 'Completed',
                                                style: TextStyle(
                                                  color: Colors.grey[300],
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                  letterSpacing: 0.2,
                                                ),
                                              ),
                                              const Spacer(),
                                              InkWell(
                                                onTap: () {
                                                  setModalState(() {
                                                    _taskFilter =
                                                        _taskFilter == 'pending'
                                                        ? 'completed'
                                                        : 'pending';
                                                  });
                                                },
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 10,
                                                        vertical: 5,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.white
                                                        .withValues(
                                                          alpha: 0.08,
                                                        ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          999,
                                                        ),
                                                    border: Border.all(
                                                      color: Colors.white
                                                          .withValues(
                                                            alpha: 0.15,
                                                          ),
                                                    ),
                                                  ),
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        _taskFilter == 'pending'
                                                            ? Icons.check_circle
                                                            : Icons
                                                                  .circle_outlined,
                                                        color:
                                                            _taskFilter ==
                                                                'pending'
                                                            ? const Color(
                                                                0xFF22C55E,
                                                              )
                                                            : Colors.grey[600],
                                                        size: 12,
                                                      ),
                                                      const SizedBox(width: 5),
                                                      Text(
                                                        otherText,
                                                        style: TextStyle(
                                                          color:
                                                              Colors.grey[300],
                                                          fontSize: 10,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 7,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.grey.withValues(
                                                    alpha: 0.15,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        999,
                                                      ),
                                                ),
                                                child: Text(
                                                  '${displayTasks.length}',
                                                  style: TextStyle(
                                                    color: Colors.grey[400],
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Expanded(
                                          child: Padding(
                                            padding: const EdgeInsets.all(8),
                                            child: GridView.builder(
                                              padding: EdgeInsets.zero,
                                              gridDelegate:
                                                  SliverGridDelegateWithFixedCrossAxisCount(
                                                    crossAxisCount:
                                                        _getGroupCrossAxisCount(
                                                          MediaQuery.of(
                                                            context,
                                                          ).size.width,
                                                        ),
                                                    crossAxisSpacing: 8,
                                                    mainAxisSpacing: 8,
                                                    childAspectRatio: 1.3,
                                                  ),
                                              itemCount: displayTasks.length,
                                              itemBuilder: (context, index) {
                                                final isCompleted =
                                                    _taskFilter == 'completed';
                                                final taskNumber =
                                                    allTasks.indexOf(
                                                      displayTasks[index],
                                                    ) +
                                                    1;
                                                return _buildGroupTaskCard(
                                                  displayTasks[index],
                                                  isCompleted,
                                                  taskNumber,
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showGroupTaskDetail(GroupMessage task, bool isCompleted) {
    final isSentByMe = task.senderId == _currentUserId;
    final senderLabel = isSentByMe
        ? 'You'
        : (task.sender?.fullName ?? 'Member');

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) {
        bool localCompleted = isCompleted;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A2B),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0xFFFBBF24).withValues(alpha: 0.45),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 24,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.grey[600],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: localCompleted
                                ? const Color(
                                    0xFF22C55E,
                                  ).withValues(alpha: 0.15)
                                : const Color(
                                    0xFFF59E0B,
                                  ).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: localCompleted
                                  ? const Color(
                                      0xFF22C55E,
                                    ).withValues(alpha: 0.5)
                                  : const Color(
                                      0xFFF59E0B,
                                    ).withValues(alpha: 0.5),
                            ),
                          ),
                          child: Text(
                            localCompleted ? 'Completed' : 'Pending Task',
                            style: TextStyle(
                              color: localCompleted
                                  ? const Color(0xFF22C55E)
                                  : const Color(0xFFFBBF24),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const Spacer(),
                        InkWell(
                          onTap: () => Navigator.pop(sheetCtx),
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close,
                              color: Colors.white70,
                              size: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      task.content.trim().isNotEmpty
                          ? task.content.trim()
                          : (task.fileName ?? 'Attachment Task'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(
                          Icons.person_outline,
                          size: 14,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Created by $senderLabel',
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              setSheetState(
                                () => localCompleted = !localCompleted,
                              );
                              await _toggleGroupTaskComplete(task);
                            },
                            icon: Icon(
                              localCompleted
                                  ? Icons.radio_button_unchecked
                                  : Icons.check_circle,
                              color: localCompleted
                                  ? Colors.grey[400]
                                  : const Color(0xFF22C55E),
                            ),
                            label: Text(
                              localCompleted ? 'Unmark' : 'Complete',
                              style: TextStyle(
                                color: localCompleted
                                    ? Colors.grey[400]
                                    : const Color(0xFF22C55E),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: localCompleted
                                    ? Colors.grey.withValues(alpha: 0.3)
                                    : const Color(
                                        0xFF22C55E,
                                      ).withValues(alpha: 0.5),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              Navigator.pop(sheetCtx);
                              Navigator.pop(context);
                              _doJumpToGroupTaskBubble(task);
                            },
                            icon: const Icon(
                              Icons.my_location,
                              size: 16,
                              color: Colors.white,
                            ),
                            label: const Text(
                              'Jump to bubble',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF7C3AED),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 0,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildGroupTaskCard(
    GroupMessage task,
    bool isCompleted,
    int taskNumber,
  ) {
    const accentColors = [
      Color(0xFF8B5CF6),
      Color(0xFF3B82F6),
      Color(0xFF10B981),
      Color(0xFFF59E0B),
      Color(0xFFEF4444),
      Color(0xFF06B6D4),
      Color(0xFFEC4899),
      Color(0xFFF97316),
    ];
    final accent = accentColors[(taskNumber - 1) % accentColors.length];
    final labelColor = isCompleted ? const Color(0xFF22C55E) : accent;

    final bool isImageTask =
        task.messageType == 'image' ||
        (task.fileType?.startsWith('image/') ?? false);
    final String? thumbUrl = (task.fileUrl != null && task.fileUrl!.isNotEmpty)
        ? (task.fileUrl!.startsWith('http')
              ? task.fileUrl!
              : '${ApiConfig.baseUrl}${task.fileUrl!}')
        : null;
    final bool showThumb = isImageTask && thumbUrl != null;
    final String contentLabel = task.content.isNotEmpty
        ? task.content
        : (task.fileName ?? (isImageTask ? 'Image' : 'File'));

    return GestureDetector(
      onTap: () => _showGroupTaskDetail(task, isCompleted),
      child: AnimatedContainer(
        duration: Duration.zero,
        decoration: BoxDecoration(
          color: const Color(0xFF2C2C2E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isCompleted
                ? const Color(0xFF22C55E).withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: labelColor,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(12),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 5, 8, 0),
                  child: Row(
                    children: [
                      Text(
                        'Task #$taskNumber',
                        style: TextStyle(
                          color: labelColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const Spacer(),
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: contentLabel));
                          _showTopSnackBar(
                            const SnackBar(
                              content: Text('Copied to clipboard'),
                              duration: Duration(milliseconds: 1200),
                            ),
                          );
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.copy_rounded,
                            size: 11,
                            color: Colors.white.withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                    child: showThumb
                        ? Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.network(
                                  thumbUrl,
                                  width: 44,
                                  height: 44,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    width: 44,
                                    height: 44,
                                    color: Colors.grey[800],
                                    child: const Icon(
                                      Icons.image_not_supported,
                                      size: 18,
                                      color: Colors.white38,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  contentLabel,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isCompleted
                                        ? Colors.white54
                                        : Colors.grey[200],
                                    fontSize: 11,
                                    height: 1.3,
                                    decoration: isCompleted
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                              ),
                            ],
                          )
                        : Text(
                            contentLabel,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isCompleted
                                  ? Colors.white54
                                  : Colors.grey[200],
                              fontSize: 11,
                              height: 1.3,
                              decoration: isCompleted
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // === Group Excalidraw ===

  static final RegExp _excalidrawUrlRegex = RegExp(
    r'((?:https?:\/\/)?(?:www\.)?excalidraw\.com[^\s]*)',
    caseSensitive: false,
  );

  /// Extract the first excalidraw.com URL from message content, if any.
  String? _extractExcalidrawUrl(String content) {
    for (final match in _excalidrawUrlRegex.allMatches(content)) {
      final raw = match.group(0);
      if (raw == null || raw.isEmpty) continue;
      final cleaned = _trimTrailingUrlCharacters(raw);
      if (cleaned.isEmpty) continue;
      final normalized = cleaned.toLowerCase().startsWith('http')
          ? cleaned
          : 'https://$cleaned';
      final uri = Uri.tryParse(normalized);
      if (uri != null && uri.host.toLowerCase().contains('excalidraw.com')) {
        return normalized;
      }
    }
    return null;
  }

  bool _isExcalidrawContent(String content) =>
      _extractExcalidrawUrl(content) != null;

  Future<void> _toggleGroupExcalidrawPin(GroupMessage message) async {
    try {
      final updated = message.excalidrawPinnedAt != null
          ? await GroupService.unpinExcalidraw(widget.group.id, message.id)
          : await GroupService.pinExcalidraw(widget.group.id, message.id);
      _replaceGroupMessage(updated);
      _notifyTaskModalChanged();
    } catch (e) {
      if (mounted) {
        _showTopSnackBar(
          SnackBar(content: Text('Failed to update Excalidraw pin: $e')),
        );
      }
    }
  }

  String _formatPinnedAt(String? pinnedAt) {
    if (pinnedAt == null) return '';
    try {
      final dt = DateTime.parse(pinnedAt).toLocal();
      String two(int n) => n.toString().padLeft(2, '0');

      final dateStr = '${dt.year}-${two(dt.month)}-${two(dt.day)}';
      final timeStr = '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';

      final off = dt.timeZoneOffset;
      final sign = off.isNegative ? '-' : '+';
      final offH = off.inHours.abs();
      final offM = off.inMinutes.abs() % 60;
      final gmt = 'GMT$sign$offH${offM != 0 ? ':${two(offM)}' : ''}';

      const weekdays = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ];
      const months = [
        'January',
        'February',
        'March',
        'April',
        'May',
        'June',
        'July',
        'August',
        'September',
        'October',
        'November',
        'December',
      ];
      final longStr =
          '${weekdays[dt.weekday - 1]}, ${months[dt.month - 1]} ${dt.day}, ${dt.year}';

      return '$dateStr $timeStr $gmt - $longStr';
    } catch (_) {
      return '';
    }
  }

  /// Centered dialog listing pinned Excalidraw links in this group matching 1on1 chat.
  void _showGroupExcalidrawModal() {
    final mediaQuery = MediaQuery.of(context);
    final topOffset = mediaQuery.padding.top + kToolbarHeight + 6;
    final availableHeight = mediaQuery.size.height - topOffset - 10;
    final maxDialogHeight = availableHeight > 240 ? availableHeight : 240.0;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Excalidraw',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: Duration.zero,
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.08),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
      pageBuilder: (context, animation, secondaryAnimation) {
        return ValueListenableBuilder<int>(
          valueListenable: _taskModalVersion,
          builder: (context, _, child) {
            final pinned =
                _messages
                    .where((m) => m.excalidrawPinnedAt != null && !m.isDeleted)
                    .toList()
                  ..sort((a, b) => b.timestampMs.compareTo(a.timestampMs));

            return Padding(
              padding: EdgeInsets.fromLTRB(10, topOffset, 10, 10),
              child: Align(
                alignment: Alignment.topCenter,
                child: Material(
                  color: Colors.transparent,
                  child: SizedBox(
                    height: maxDialogHeight,
                    child: Container(
                      clipBehavior: Clip.hardEdge,
                      decoration: BoxDecoration(
                        color: const Color(0xFF191729),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 24,
                            offset: const Offset(0, 12),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.fromLTRB(14, 14, 12, 12),
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                colors: [Color(0xFFF97316), Color(0xFFEA580C)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.vertical(
                                top: Radius.circular(20),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.2),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.5,
                                      ),
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.draw_outlined,
                                    color: Colors.white,
                                    size: 19,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                const Text(
                                  'Excalidraw',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                                const Spacer(),
                                Container(
                                  margin: const EdgeInsets.only(right: 8),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.5,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    '${pinned.length} pinned',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                InkWell(
                                  onTap: () => Navigator.pop(context),
                                  borderRadius: BorderRadius.circular(16),
                                  child: Container(
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.08,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.close,
                                      color: Colors.white70,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Divider(
                            color: Colors.white.withValues(alpha: 0.08),
                            height: 1,
                          ),
                          Flexible(
                            child: pinned.isEmpty
                                ? Center(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            width: 70,
                                            height: 70,
                                            decoration: BoxDecoration(
                                              color: const Color(
                                                0xFFF97316,
                                              ).withValues(alpha: 0.16),
                                              shape: BoxShape.circle,
                                            ),
                                            child: const Icon(
                                              Icons.draw,
                                              color: Color(0xFFFB923C),
                                              size: 34,
                                            ),
                                          ),
                                          const SizedBox(height: 16),
                                          Text(
                                            'No pinned Excalidraw links',
                                            style: TextStyle(
                                              color: Colors.grey[300],
                                              fontSize: 17,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            'Pin an Excalidraw link in chat to see it here',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: Colors.grey[500],
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    padding: const EdgeInsets.all(10),
                                    itemCount: pinned.length,
                                    itemBuilder: (context, index) {
                                      final m = pinned[index];
                                      final content = m.content;
                                      final orderNumber = index + 1;
                                      final rawTitle =
                                          (m.excalidrawTitle != null &&
                                              m.excalidrawTitle!
                                                  .trim()
                                                  .isNotEmpty)
                                          ? m.excalidrawTitle!.trim()
                                          : '';
                                      final cardTitle = rawTitle.isNotEmpty
                                          ? rawTitle
                                          : 'Link #$orderNumber';
                                      final extractedUrl =
                                          _extractExcalidrawUrl(content);
                                      final displayText =
                                          (extractedUrl ?? content)
                                              .trim()
                                              .isEmpty
                                          ? 'Excalidraw link'
                                          : (extractedUrl ?? content).trim();
                                      final openLink = () {
                                        Navigator.pop(context);
                                        if (extractedUrl != null) {
                                          _openMessageUrl(extractedUrl);
                                        }
                                      };
                                      return Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 10,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF252542),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: const Color(
                                              0xFFF97316,
                                            ).withValues(alpha: 0.45),
                                          ),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  const Icon(
                                                    Icons.draw_outlined,
                                                    color: Color(0xFFFB923C),
                                                    size: 18,
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Expanded(
                                                    child: Text(
                                                      cardTitle,
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 15,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 8),
                                              GestureDetector(
                                                onTap: openLink,
                                                child: Text(
                                                  displayText,
                                                  style: const TextStyle(
                                                    color: Color(0xFF93C5FD),
                                                    fontSize: 14,
                                                    height: 1.4,
                                                    decoration: TextDecoration
                                                        .underline,
                                                    decorationColor: Color(
                                                      0xFF93C5FD,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                _formatPinnedAt(
                                                  m.excalidrawPinnedAt,
                                                ),
                                                style: const TextStyle(
                                                  color: Color(0xFFFBBF24),
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                  height: 1.3,
                                                ),
                                              ),
                                              const SizedBox(height: 12),
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: InkWell(
                                                      onTap: openLink,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                      child: Container(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              vertical: 9,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color: const Color(
                                                            0xFF2563EB,
                                                          ),
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                8,
                                                              ),
                                                        ),
                                                        child: const Row(
                                                          mainAxisAlignment:
                                                              MainAxisAlignment
                                                                  .center,
                                                          children: [
                                                            Icon(
                                                              Icons.open_in_new,
                                                              color:
                                                                  Colors.white,
                                                              size: 16,
                                                            ),
                                                            SizedBox(width: 6),
                                                            Text(
                                                              'Open',
                                                              style: TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 14,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: InkWell(
                                                      onTap: () async {
                                                        await _toggleGroupExcalidrawPin(
                                                          m,
                                                        );
                                                      },
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                      child: Container(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              vertical: 9,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color: const Color(
                                                            0xFFDC2626,
                                                          ),
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                8,
                                                              ),
                                                        ),
                                                        child: const Row(
                                                          mainAxisAlignment:
                                                              MainAxisAlignment
                                                                  .center,
                                                          children: [
                                                            Icon(
                                                              Icons
                                                                  .push_pin_outlined,
                                                              color:
                                                                  Colors.white,
                                                              size: 16,
                                                            ),
                                                            SizedBox(width: 6),
                                                            Text(
                                                              'Unpin',
                                                              style: TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 14,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 10),
                                              Center(
                                                child: Text(
                                                  '$orderNumber',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 22,
                                                    fontWeight: FontWeight.w900,
                                                    letterSpacing: 0.5,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showGroupMessageContextMenu(GroupMessage message, bool isSentByMe) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Copy option (for text messages)
              if (message.messageType == 'text' && !message.isDeleted)
                ListTile(
                  leading: const Icon(Icons.copy, color: Colors.white),
                  title: const Text(
                    'Copy',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _copyGroupMessageToClipboard(message);
                  },
                ),
              // Forward option (any non-deleted message)
              if (!message.isDeleted)
                ListTile(
                  leading: const Icon(Icons.forward, color: Colors.white),
                  title: const Text(
                    'Forward',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _openForwardPicker(message);
                  },
                ),
              // Mark / Unmark as Task
              if (_canMarkGroupTask(message))
                ListTile(
                  leading: Icon(
                    message.isTask ? Icons.remove_done : Icons.task_alt,
                    color: const Color(0xFF14B8A6),
                  ),
                  title: Text(
                    message.isTask ? 'Unmark Task' : 'Mark as Task',
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _toggleGroupTask(message);
                  },
                ),
              // Complete / Reopen a task
              if (!message.isDeleted && message.isTask)
                ListTile(
                  leading: Icon(
                    message.taskCompletedAt != null
                        ? Icons.undo
                        : Icons.check_circle_outline,
                    color: const Color(0xFF22C55E),
                  ),
                  title: Text(
                    message.taskCompletedAt != null
                        ? 'Mark Incomplete'
                        : 'Mark Complete',
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _toggleGroupTaskComplete(message);
                  },
                ),
              // Pin / Unpin Excalidraw (for messages containing an excalidraw link)
              if (!message.isDeleted && _isExcalidrawContent(message.content))
                ListTile(
                  leading: Icon(
                    message.excalidrawPinnedAt != null
                        ? Icons.push_pin_outlined
                        : Icons.push_pin,
                    color: const Color(0xFFF97316),
                  ),
                  title: Text(
                    message.excalidrawPinnedAt != null
                        ? 'Unpin Excalidraw'
                        : 'Pin Excalidraw',
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _toggleGroupExcalidrawPin(message);
                  },
                ),
              // Translate option (for incoming text messages)
              if (!isSentByMe &&
                  message.messageType == 'text' &&
                  !message.isDeleted &&
                  message.content.isNotEmpty)
                ListTile(
                  leading: Icon(
                    _messageTranslations.containsKey(message.id)
                        ? Icons.translate_outlined
                        : Icons.translate,
                    color: Colors.blue,
                  ),
                  title: Text(
                    _messageTranslations.containsKey(message.id)
                        ? 'Hide Translation'
                        : 'Translate',
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _translateGroupMessage(message);
                  },
                ),
              // Delete option (for own messages)
              if (isSentByMe && !message.isDeleted)
                ListTile(
                  leading: const Icon(Icons.delete, color: Colors.red),
                  title: const Text(
                    'Delete',
                    style: TextStyle(color: Colors.red),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _showGroupDeleteConfirmation(message);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Forward a group message to one or more 1-on-1 recipients.
  void _openForwardPicker(GroupMessage message) {
    // Adapt the GroupMessage to the 1-on-1 Message model that ForwardService
    // consumes. Only content/type/file fields are read when building the
    // forward payload; the rest are placeholders.
    final adapted = Message(
      id: message.id,
      senderId: message.senderId,
      recipientId: 0,
      content: message.content,
      messageType: message.messageType,
      timestamp: message.timestamp,
      timestampMs: message.timestampMs,
      isRead: true,
      status: 'sent',
      threadId: '',
      reactions: const {},
      isDeleted: message.isDeleted,
      fileUrl: message.fileUrl,
      fileName: message.fileName,
      fileSize: message.fileSize,
      fileType: message.fileType,
      caption: message.caption,
    );

    ForwardRecipientPicker.show(
      context,
      currentUserId: _currentUserId ?? 0,
      onConfirm: (selectedUserIds) async {
        if (selectedUserIds.isEmpty) return;

        final result = await ForwardService.forwardToUsers(
          message: adapted,
          recipientIds: selectedUserIds,
        );

        if (!mounted) return;

        if (result.allSucceeded) {
          _showTopSnackBar(
            SnackBar(
              content: Text(
                'Forwarded to ${result.successCount} recipient${result.successCount > 1 ? "s" : ""}',
              ),
              backgroundColor: const Color(0xFF059669),
              duration: const Duration(seconds: 2),
            ),
          );
        } else if (result.allFailed) {
          _showTopSnackBar(
            const SnackBar(
              content: Text('Failed to forward message'),
              backgroundColor: Color(0xFFB91C1C),
            ),
          );
        } else {
          _showTopSnackBar(
            SnackBar(
              content: Text(
                'Forwarded to ${result.successCount}, failed for ${result.failureCount}',
              ),
              backgroundColor: const Color(0xFFD97706),
            ),
          );
        }
      },
    );
  }

  // ============================================================
  // GROUP MEMBERS / SETTINGS
  // ============================================================

  Color _accent() => const Color(0xFF8B5CF6);

  /// Members list sheet. Admins can remove members or add new ones.
  void _showGroupMembersSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        List<GroupMember> members = [];
        bool loading = true;
        String? error;

        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            Future<void> load() async {
              try {
                final details = await GroupService.getGroupDetails(
                  widget.group.id,
                );
                if (!ctx.mounted) return;
                setSheetState(() {
                  members = (details['members'] as List).cast<GroupMember>();
                  loading = false;
                  error = null;
                });
                if (mounted) setState(() => _memberCount = members.length);
              } catch (e) {
                if (!ctx.mounted) return;
                setSheetState(() {
                  loading = false;
                  error = 'Failed to load members';
                });
              }
            }

            if (loading && members.isEmpty && error == null) load();

            Future<void> removeMember(GroupMember m) async {
              final confirmed = await showDialog<bool>(
                context: ctx,
                builder: (dctx) => AlertDialog(
                  backgroundColor: const Color(0xFF1E1E2E),
                  title: const Text(
                    'Remove member',
                    style: TextStyle(color: Colors.white),
                  ),
                  content: Text(
                    'Remove ${m.user.fullName} from the group?',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dctx, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(dctx, true),
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('Remove'),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
              try {
                await GroupService.removeMember(
                  groupId: widget.group.id,
                  userId: m.userId,
                );
                await load();
              } catch (e) {
                if (mounted) {
                  _showTopSnackBar(
                    SnackBar(content: Text('Failed to remove member: $e')),
                  );
                }
              }
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SizedBox(
                  height: MediaQuery.of(ctx).size.height * 0.7,
                  child: Column(
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.grey[600],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            const Icon(Icons.people, color: Colors.white),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Members (${members.length})',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (_currentUserIsAdmin)
                              TextButton.icon(
                                onPressed: () async {
                                  await _showAddMembersSheet(
                                    members.map((m) => m.userId).toSet(),
                                  );
                                  await load();
                                },
                                icon: Icon(
                                  Icons.person_add,
                                  size: 18,
                                  color: _accent(),
                                ),
                                label: Text(
                                  'Add',
                                  style: TextStyle(color: _accent()),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: loading
                            ? Center(
                                child: CircularProgressIndicator(
                                  color: _accent(),
                                ),
                              )
                            : error != null
                            ? Center(
                                child: Text(
                                  error!,
                                  style: const TextStyle(color: Colors.white54),
                                ),
                              )
                            : ListView.builder(
                                itemCount: members.length,
                                itemBuilder: (_, i) {
                                  final m = members[i];
                                  final isSelf = m.userId == _currentUserId;
                                  final isAdmin = m.role == 'admin';
                                  final name = m.user.fullName.isNotEmpty
                                      ? m.user.fullName
                                      : m.user.username;
                                  return ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: _accent(),
                                      child:
                                          m.user.avatarUrl != null &&
                                              m.user.avatarUrl!.isNotEmpty
                                          ? ClipOval(
                                              child: CachedImage(
                                                url: m.user.avatarUrl!,
                                                width: 40,
                                                height: 40,
                                                fit: BoxFit.cover,
                                                placeholderColor: _accent(),
                                                errorWidget: Text(
                                                  name.isNotEmpty
                                                      ? name[0].toUpperCase()
                                                      : '?',
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ),
                                            )
                                          : Text(
                                              name.isNotEmpty
                                                  ? name[0].toUpperCase()
                                                  : '?',
                                              style: const TextStyle(
                                                color: Colors.white,
                                              ),
                                            ),
                                    ),
                                    title: Text(
                                      isSelf ? '$name (You)' : name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                      ),
                                    ),
                                    subtitle: Text(
                                      isAdmin ? 'Admin' : 'Member',
                                      style: TextStyle(
                                        color: isAdmin
                                            ? _accent()
                                            : Colors.grey[400],
                                        fontSize: 12,
                                      ),
                                    ),
                                    trailing: (_currentUserIsAdmin && !isSelf)
                                        ? IconButton(
                                            icon: const Icon(
                                              Icons.remove_circle_outline,
                                              color: Colors.red,
                                            ),
                                            onPressed: () => removeMember(m),
                                          )
                                        : null,
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Add-members picker (admin). Lists users not already in the group.
  Future<void> _showAddMembersSheet(Set<int> existingMemberIds) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        List<LobbyUser> users = [];
        final Set<int> selected = {};
        bool loading = true;
        bool saving = false;
        String? error;

        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            Future<void> load() async {
              try {
                final all = await LobbyService.getLobbyUsers();
                if (!ctx.mounted) return;
                setSheetState(() {
                  users = all
                      .where((u) => !existingMemberIds.contains(u.id))
                      .toList();
                  loading = false;
                });
              } catch (e) {
                if (!ctx.mounted) return;
                setSheetState(() {
                  loading = false;
                  error = 'Failed to load users';
                });
              }
            }

            if (loading && users.isEmpty && error == null) load();

            Future<void> confirmAdd() async {
              if (selected.isEmpty) return;
              setSheetState(() => saving = true);
              try {
                await GroupService.addMembers(
                  groupId: widget.group.id,
                  userIds: selected.toList(),
                );
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  _showTopSnackBar(
                    SnackBar(
                      content: Text('Added ${selected.length} member(s)'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } catch (e) {
                if (ctx.mounted) {
                  setSheetState(() {
                    saving = false;
                    error = 'Failed to add members: $e';
                  });
                }
              }
            }

            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.7,
                child: Column(
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.grey[600],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Add Members',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          ElevatedButton(
                            onPressed: (selected.isEmpty || saving)
                                ? null
                                : confirmAdd,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _accent(),
                              foregroundColor: Colors.white,
                            ),
                            child: saving
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Text('Add (${selected.length})'),
                          ),
                        ],
                      ),
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    Expanded(
                      child: loading
                          ? Center(
                              child: CircularProgressIndicator(
                                color: _accent(),
                              ),
                            )
                          : users.isEmpty
                          ? const Center(
                              child: Text(
                                'No users to add',
                                style: TextStyle(color: Colors.white54),
                              ),
                            )
                          : ListView.builder(
                              itemCount: users.length,
                              itemBuilder: (_, i) {
                                final u = users[i];
                                final name = u.fullName.isNotEmpty
                                    ? u.fullName
                                    : u.username;
                                final isSelected = selected.contains(u.id);
                                return CheckboxListTile(
                                  value: isSelected,
                                  activeColor: _accent(),
                                  checkColor: Colors.white,
                                  onChanged: (v) => setSheetState(() {
                                    if (v == true) {
                                      selected.add(u.id);
                                    } else {
                                      selected.remove(u.id);
                                    }
                                  }),
                                  secondary: SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: Stack(
                                      children: [
                                        CircleAvatar(
                                          backgroundColor: _getAvatarColor(
                                            u.avatarColorIndex,
                                          ),
                                          radius: 20,
                                          child:
                                              u.avatarUrl != null &&
                                                  u.avatarUrl!.isNotEmpty
                                              ? ClipOval(
                                                  child: CachedImage(
                                                    url: u.avatarUrl!,
                                                    width: 40,
                                                    height: 40,
                                                    fit: BoxFit.cover,
                                                    placeholderColor:
                                                        _getAvatarColor(
                                                          u.avatarColorIndex,
                                                        ),
                                                    errorWidget: Text(
                                                      u.initials,
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                )
                                              : Text(
                                                  u.initials,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                        ),
                                        Positioned(
                                          right: 2,
                                          bottom: 2,
                                          child: Container(
                                            width: 12,
                                            height: 12,
                                            decoration: BoxDecoration(
                                              color: u.isOnline
                                                  ? const Color(0xFF00E676)
                                                  : (u.status == 'away'
                                                        ? const Color(
                                                            0xFFFFC107,
                                                          )
                                                        : Colors.grey[600]!),
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: const Color(0xFF1E1E2E),
                                                width: 2,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  title: Text(
                                    name,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                  subtitle: Row(
                                    children: [
                                      Text(
                                        '@${u.username}',
                                        style: TextStyle(
                                          color: Colors.grey[400],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '•',
                                        style: TextStyle(
                                          color: Colors.grey[500],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          u.isOnline
                                              ? 'online'
                                              : _formatRelativeTime(u.lastSeen),
                                          style: TextStyle(
                                            color: u.isOnline
                                                ? const Color(0xFF00E676)
                                                : Colors.grey[400],
                                            fontSize: 12,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  DateTime _parseUtcTimestamp(String timestamp) {
    final hasTimezone = RegExp(r'[zZ]|[+-]\d{2}:?\d{2}$').hasMatch(timestamp);
    final parsed = DateTime.parse(hasTimezone ? timestamp : '${timestamp}Z');
    return parsed.toLocal();
  }

  String _formatRelativeTime(String? lastSeen) {
    if (lastSeen == null || lastSeen.isEmpty) return 'offline';
    try {
      final dateTime = _parseUtcTimestamp(lastSeen);
      final now = DateTime.now();
      final difference = now.difference(dateTime);

      if (difference.inMinutes < 1) return 'last seen just now';
      if (difference.inMinutes < 60) {
        final mins = difference.inMinutes;
        return 'last seen ${mins}m ago';
      }
      if (difference.inHours < 24) {
        final hours = difference.inHours;
        return 'last seen ${hours}h ago';
      }
      if (difference.inDays == 1) return 'last seen yesterday';
      if (difference.inDays < 7) return 'last seen ${difference.inDays}d ago';
      return 'last seen ${dateTime.month}/${dateTime.day}';
    } catch (e) {
      return 'offline';
    }
  }

  static const List<Color> _avatarColors = [
    Color(0xFF1F77B4), // Blue
    Color(0xFFFF7F0E), // Orange
    Color(0xFF2CA02C), // Green
    Color(0xFFD62728), // Red
    Color(0xFF9467BD), // Purple
    Color(0xFF8C564B), // Brown
    Color(0xFFE377C2), // Pink
    Color(0xFF7F7F7F), // Gray
    Color(0xFFBCBD22), // Olive
    Color(0xFF17BECF), // Cyan
  ];

  Color _getAvatarColor(int index) {
    return _avatarColors[index % _avatarColors.length];
  }

  /// Group settings sheet: edit info (admin), add members (admin), leave group.
  void _showGroupSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: Icon(Icons.group, color: _accent()),
                title: Text(
                  _groupName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  _groupDescription.isEmpty
                      ? 'No description'
                      : _groupDescription,
                  style: TextStyle(color: Colors.grey[400]),
                ),
              ),
              const Divider(color: Colors.white12),
              if (_currentUserIsAdmin)
                ListTile(
                  leading: const Icon(Icons.edit, color: Colors.white),
                  title: const Text(
                    'Edit Group Info',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _editGroupInfoDialog();
                  },
                ),
              if (_currentUserIsAdmin)
                ListTile(
                  leading: const Icon(Icons.person_add, color: Colors.white),
                  title: const Text(
                    'Add Members',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    try {
                      final details = await GroupService.getGroupDetails(
                        widget.group.id,
                      );
                      final existing = (details['members'] as List)
                          .cast<GroupMember>();
                      await _showAddMembersSheet(
                        existing.map((m) => m.userId).toSet(),
                      );
                    } catch (e) {
                      if (mounted) {
                        _showTopSnackBar(
                          SnackBar(content: Text('Failed to load members: $e')),
                        );
                      }
                    }
                  },
                ),
              ListTile(
                leading: const Icon(Icons.people, color: Colors.white),
                title: const Text(
                  'View Members',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showGroupMembersSheet();
                },
              ),
              ListTile(
                leading: const Icon(Icons.exit_to_app, color: Colors.red),
                title: const Text(
                  'Leave Group',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _confirmLeaveGroup();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Dialog to edit the group name + description (admin only).
  Future<void> _editGroupInfoDialog() async {
    final nameController = TextEditingController(text: _groupName);
    final descController = TextEditingController(text: _groupDescription);

    final saved = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F33),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: Colors.white.withValues(alpha: 0.12),
            width: 1.2,
          ),
        ),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF00D9FF).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.edit_note_rounded,
                color: Color(0xFF00D9FF),
                size: 24,
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              'Edit Group Info',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'GROUP NAME',
                style: TextStyle(
                  color: Color(0xFF00D9FF),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Enter group name',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF141424),
                  prefixIcon: const Icon(
                    Icons.group_outlined,
                    color: Colors.white70,
                    size: 20,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: Color(0xFF00D9FF),
                      width: 1.5,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'DESCRIPTION',
                style: TextStyle(
                  color: Color(0xFF00D9FF),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: descController,
                maxLines: 3,
                minLines: 1,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Add group description',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF141424),
                  prefixIcon: const Icon(
                    Icons.description_outlined,
                    color: Colors.white70,
                    size: 20,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: Color(0xFF00D9FF),
                      width: 1.5,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            child: const Text('Cancel', style: TextStyle(fontSize: 15)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4C1D95),
              foregroundColor: Colors.white,
              elevation: 2,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text(
              'Save',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    if (saved != true) return;
    final newName = nameController.text.trim();
    if (newName.isEmpty) {
      if (mounted) {
        _showTopSnackBar(
          const SnackBar(content: Text('Group name cannot be empty')),
        );
      }
      return;
    }

    try {
      await GroupService.editGroup(
        groupId: widget.group.id,
        name: newName,
        description: descController.text.trim(),
      );
      if (mounted) {
        setState(() {
          _groupName = newName;
          _groupDescription = descController.text.trim();
        });
        _showTopSnackBar(
          const SnackBar(
            content: Text('Group updated'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        _showTopSnackBar(SnackBar(content: Text('Failed to update group: $e')));
      }
    }
  }

  /// Confirm + leave the group, then return to the previous screen.
  Future<void> _confirmLeaveGroup() async {
    // The creator can't just leave — leaving disbands the group for everyone.
    final isCreator = widget.group.createdBy == _currentUserId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        title: Text(
          isCreator ? 'Disband Group' : 'Leave Group',
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          isCreator
              ? 'You created this group, so leaving will disband it and delete '
                    'it for everyone. Continue?'
              : 'Are you sure you want to leave this group?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(isCreator ? 'Disband' : 'Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      // The backend disbands the group when the creator calls leave.
      await GroupService.leaveGroup(widget.group.id);
      if (mounted) {
        _showTopSnackBar(
          SnackBar(
            content: Text(isCreator ? 'Group disbanded' : 'You left the group'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        _showTopSnackBar(
          SnackBar(
            content: Text(
              'Failed to ${isCreator ? 'disband' : 'leave'} group: $e',
            ),
          ),
        );
      }
    }
  }

  /// Copy group message to clipboard
  void _copyGroupMessageToClipboard(GroupMessage message) {
    Clipboard.setData(ClipboardData(text: message.content));
    _showTopSnackBar(
      const SnackBar(
        content: Text('Message copied to clipboard'),
        duration: Duration(seconds: 2),
        backgroundColor: Color(0xFF4CAF50),
      ),
    );
  }

  /// Auto-translate incoming group message (silent, no loading indicators)
  Future<void> _autoTranslateGroupMessage(GroupMessage message) async {
    try {
      final targetLang = await TranslationService.getUserLanguage();
      final translatedText = await TranslationService.translateMessage(
        text: message.content,
        targetLang: targetLang,
      );

      if (translatedText != null &&
          translatedText != message.content &&
          mounted) {
        setState(() {
          _messageTranslations[message.id] = translatedText;
        });
        debugPrint(
          '🌐 Auto-translated group message ${message.id}: "${message.content}" → "$translatedText"',
        );
      }
    } catch (e) {
      debugPrint('Auto-translation failed for group message ${message.id}: $e');
      // Fail silently for auto-translation
    }
  }

  /// Translate a group message manually
  Future<void> _translateGroupMessage(GroupMessage message) async {
    try {
      // Check if already translated - toggle off if so
      if (_messageTranslations.containsKey(message.id)) {
        setState(() {
          _messageTranslations.remove(message.id);
        });
        _showTopSnackBar(
          const SnackBar(
            content: Text('Translation hidden'),
            duration: Duration(seconds: 2),
            backgroundColor: Color(0xFF6B7280),
          ),
        );
        return;
      }

      // Show loading indicator
      _showTopSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              SizedBox(width: 12),
              Text('Translating...'),
            ],
          ),
          duration: Duration(seconds: 30),
          backgroundColor: Color(0xFF4F46E5),
        ),
      );

      final targetLang = await TranslationService.getUserLanguage();
      final translatedText = await TranslationService.translateMessage(
        text: message.content,
        targetLang: targetLang,
      );

      // Hide loading indicator
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (translatedText != null && translatedText != message.content) {
        // Store translation and update UI
        setState(() {
          _messageTranslations[message.id] = translatedText;
        });

        _showTopSnackBar(
          const SnackBar(
            content: Text('Message translated'),
            duration: Duration(seconds: 2),
            backgroundColor: Color(0xFF4CAF50),
          ),
        );
      } else if (translatedText == message.content) {
        // Same text, no translation needed
        _showTopSnackBar(
          const SnackBar(
            content: Text('Message is already in your language'),
            duration: Duration(seconds: 2),
            backgroundColor: Color(0xFF6B7280),
          ),
        );
      } else {
        // Translation failed
        _showTopSnackBar(
          const SnackBar(
            content: Text('Translation failed. Please try again.'),
            duration: Duration(seconds: 3),
            backgroundColor: Color(0xFFEF4444),
          ),
        );
      }
    } catch (e) {
      // Hide loading indicator
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      debugPrint('Translation error: $e');
      _showTopSnackBar(
        const SnackBar(
          content: Text('Translation failed. Please try again.'),
          duration: Duration(seconds: 3),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
    }
  }

  /// Show delete confirmation for group message
  void _showGroupDeleteConfirmation(GroupMessage message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        title: const Text(
          'Delete Message',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Are you sure you want to delete this message?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteGroupMessage(message);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  /// Delete group message (placeholder)
  void _deleteGroupMessage(GroupMessage message) {
    // TODO: Implement group message deletion
    _showTopSnackBar(
      const SnackBar(
        content: Text('Message deletion coming soon for group chats'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Change group chat color (placeholder)
  void _changeColor() {
    _changeGroupColor();
  }

  /// Reset group chat color for all members
  void _resetColor() {
    _resetGroupColor();
  }

  /// Export chat history to a .txt file in Downloads
  Future<void> _exportChat() async {
    try {
      final hasStorageAccess = await _requestStorageAccessForFileOps();
      if (!hasStorageAccess) return;

      if (mounted) {
        _showTopSnackBar(
          const SnackBar(
            content: Text('Preparing chat export...'),
            duration: Duration(seconds: 1),
          ),
        );
      }

      final buffer = StringBuffer();
      buffer.writeln('Group Chat Export');
      buffer.writeln('Group: ${widget.group.name}');
      buffer.writeln('Exported on: ${DateTime.now()}');
      buffer.writeln('=' * 50);
      buffer.writeln();

      // _messages is in chronological order (oldest first).
      String? lastDate;
      for (final message in _messages) {
        final messageDate = _formatExportDate(message.timestamp);
        if (messageDate != lastDate) {
          buffer.writeln();
          buffer.writeln('--- $messageDate ---');
          buffer.writeln();
          lastDate = messageDate;
        }

        final senderName = message.senderId == _currentUserId
            ? 'Me'
            : (message.sender?.fullName ?? 'User ${message.senderId}');
        final time = _formatExportTime(message.timestamp);

        String messageContent;
        if (message.isDeleted) {
          messageContent = '[Message deleted]';
        } else if (message.messageType == 'voice' ||
            message.messageType == 'audio') {
          messageContent = '[Voice message]';
        } else if (message.messageType == 'image') {
          messageContent = '[Image: ${message.fileName ?? "image"}]';
        } else if (message.messageType == 'video') {
          messageContent = '[Video: ${message.fileName ?? "video"}]';
        } else if (message.messageType == 'file') {
          messageContent = '[File: ${message.fileName ?? "file"}]';
        } else {
          messageContent = message.content;
        }

        buffer.writeln('[$time] $senderName: $messageContent');
      }

      buffer.writeln();
      buffer.writeln('=' * 50);
      buffer.writeln('End of export - ${_messages.length} messages');

      final exportContent = buffer.toString();
      final now = DateTime.now();
      final fileName = _normalizeTextFileName(
        'group_${widget.group.name.replaceAll(' ', '_')}_${now.day}-${now.month}-${now.year}.txt',
      );

      String savedLocation;
      if (Platform.isAndroid) {
        await _saveToAndroidDownloads(
          fileName: fileName,
          mimeType: 'text/plain',
          bytes: utf8.encode(exportContent),
        );
        savedLocation = 'Downloads';
      } else {
        final downloadDir = await _resolveDownloadDirectory();
        final savePath =
            '${downloadDir.path}${Platform.pathSeparator}$fileName';
        await File(savePath).writeAsString(exportContent, flush: true);
        savedLocation = savePath;
      }

      if (mounted) {
        _showTopSnackBar(
          SnackBar(
            content: Text('Chat saved to $savedLocation: $fileName'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error exporting group chat: $e');
      if (mounted) {
        _showTopSnackBar(
          SnackBar(
            content: Text('Failed to export chat: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  bool _isSameDay(String a, String b) {
    try {
      final da = DateTime.parse(a).toLocal();
      final db = DateTime.parse(b).toLocal();
      return da.year == db.year && da.month == db.month && da.day == db.day;
    } catch (_) {
      return true;
    }
  }

  String _formatExportDate(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      return '${dt.month}/${dt.day}/${dt.year}';
    } catch (_) {
      return 'Unknown date';
    }
  }

  String _formatExportTime(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      final hour = dt.hour;
      final minute = dt.minute.toString().padLeft(2, '0');
      final period = hour >= 12 ? 'PM' : 'AM';
      final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
      return '$displayHour:$minute $period';
    } catch (_) {
      return '';
    }
  }

  String _normalizeTextFileName(String value) {
    final sanitized = value
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final fallback = sanitized.isEmpty ? 'group_chat_export' : sanitized;
    return fallback.toLowerCase().endsWith('.txt') ? fallback : '$fallback.txt';
  }

  /// Admin: Delete all messages in group
  Future<void> _adminDeleteAllMessages() async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete All Messages'),
        content: const Text(
          'Are you sure you want to delete all messages in this group? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final deletedCount = await GroupService.deleteAllMessages(
        widget.group.id,
      );

      // Clear locally as well — the server also emits `all_messages_deleted`
      // to every member, but socket delivery is not guaranteed.
      if (mounted) {
        setState(() {
          _messages.clear();
          _messageReactions.clear();
          _messageTranslations.clear();
        });
      }
      await ChatCacheService.clearGroupCache(widget.group.id);

      if (mounted) {
        _showTopSnackBar(
          SnackBar(
            content: Text('Deleted $deletedCount message(s)'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error deleting all messages: $e');
      if (mounted) {
        _showTopSnackBar(
          SnackBar(
            content: Text('Failed to delete messages: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // === Shared composer (mirrors the 1:1 chat input area) ===

  /// Estimate whether the composed text wraps onto more than one line so the
  /// composer can expand (matches the 1:1 chat).
  bool _isComposerMultiline(String text, TextStyle style, double maxWidth) {
    if (text.trim().isEmpty) return false;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 6,
    );
    painter.layout(maxWidth: maxWidth < 1 ? 1 : maxWidth);
    return painter.computeLineMetrics().length > 1;
  }

  /// Composer text changed: sanitize emoji + emit throttled typing indicator.
  void _onGroupComposerTextChanged(String text) {
    final normalizedText = _normalizeTextForEmojiCompatibility(text);
    if (normalizedText != text) {
      _replaceInputTextWithSanitized(normalizedText);
      return;
    }
    _typingEmitTimer?.cancel();
    _typingEmitTimer = Timer(const Duration(milliseconds: 150), () {
      _socketService.sendGroupTyping(widget.group.id, text);
    });
  }

  /// Handle rich content inserted by the soft keyboard (image/GIF paste).
  Future<void> _onGroupContentInserted(KeyboardInsertedContent content) async {
    final data = content.data;
    if (data == null || data.isEmpty) return;
    try {
      final ext = content.mimeType.split('/').last;
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/pasted_${DateTime.now().millisecondsSinceEpoch}.$ext',
      );
      await file.writeAsBytes(data);
      await _uploadFile(file);
    } catch (e) {
      debugPrint('Error handling inserted content: $e');
    }
  }

  /// Doorbell button shown inside the composer (matches the 1:1 chat).
  Widget _buildGroupDoorbellComposerButton({
    required bool showLabel,
    required double iconSize,
    required EdgeInsetsGeometry padding,
  }) {
    final fixedHeight = iconSize + 12;
    return Tooltip(
      message: 'Ring Doorbell',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _ringDoorbell,
          borderRadius: BorderRadius.circular(999),
          splashColor: Colors.white.withValues(alpha: 0.20),
          highlightColor: Colors.white.withValues(alpha: 0.10),
          child: Container(
            height: fixedHeight,
            padding: showLabel
                ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
                : padding,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: showLabel ? BoxShape.rectangle : BoxShape.circle,
              borderRadius: showLabel ? BorderRadius.circular(999) : null,
            ),
            child: showLabel
                ? const Center(
                    widthFactor: 1,
                    child: Text(
                      'Ring Doorbell',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                : Icon(
                    Icons.notifications_active_outlined,
                    color: Colors.black,
                    size: iconSize,
                  ),
          ),
        ),
      ),
    );
  }

  /// Compact colored action chip (same style as the 1:1 chat action bar).
  Widget _groupActionChip({
    required String label,
    required Color backgroundColor,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onPressed();
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 40,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              height: 1.1,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.visible,
            softWrap: true,
          ),
        ),
      ),
    );
  }

  void _insertGroupName() {
    final raw = _groupName.trim();
    if (raw.isEmpty) return;
    final text = _messageController.text;
    final sel = _messageController.selection;
    final int start = sel.isValid ? sel.start : text.length;
    final int end = sel.isValid ? sel.end : text.length;
    final before = text.substring(0, start);
    final after = text.substring(end);
    final spaceBefore = (before.isEmpty || RegExp(r'\s$').hasMatch(before))
        ? ''
        : ' ';
    final bool inputIsEmpty = before.isEmpty && after.isEmpty;
    final spaceAfter = inputIsEmpty
        ? ' '
        : ((after.isEmpty || RegExp(r'^\s').hasMatch(after)) ? '' : ' ');
    final inserted = '$spaceBefore$raw$spaceAfter';
    final newText = '$before$inserted$after';
    final newCaret = start + inserted.length;
    _messageController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCaret),
    );
  }

  void _showAutoCorrectionModal() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Auto Correction is active'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Two-row group action bar shown above the composer (mirrors 1:1 / self chat).
  Widget _buildGroupUnifiedActionsBar() {
    final nameParts = _groupName.trim().split(' ');
    final nameLabel = nameParts.first;

    final topRow = <Widget>[
      _groupActionChip(
        label: 'Send\nFile',
        backgroundColor: const Color(0xFF16A34A),
        onPressed: _pickFile,
      ),
      _groupActionChip(
        label: 'Voice\nMessage',
        backgroundColor: const Color(0xFFEF4444),
        onPressed: _showVoiceRecordingModal,
      ),
      _groupActionChip(
        label: 'Auto\nCorrection',
        backgroundColor: const Color(0xFFF59E0B),
        onPressed: _showAutoCorrectionModal,
      ),
      _groupActionChip(
        label: 'Common\nPhrases',
        backgroundColor: const Color(0xFFEC4899),
        onPressed: _showCommonPhrasesModal,
      ),
      _groupActionChip(
        label: _autoTranslate ? 'Translate\nOn' : 'Translate\nOff',
        backgroundColor: const Color(0xFFC026D3),
        onPressed: _toggleAutoTranslate,
      ),
    ];
    final bottomRow = <Widget>[
      _groupActionChip(
        label: nameLabel.isEmpty ? 'Group' : nameLabel,
        backgroundColor: const Color(0xFF0F766E),
        onPressed: _insertGroupName,
      ),
      _groupActionChip(
        label: 'Paste',
        backgroundColor: const Color(0xFF1D4ED8),
        onPressed: _pasteFromClipboard,
      ),
      _groupActionChip(
        label: 'Export\nChat',
        backgroundColor: const Color(0xFF6B7280),
        onPressed: _exportChat,
      ),
      _groupActionChip(
        label: 'Change\nColor',
        backgroundColor: const Color(0xFF9333EA),
        onPressed: _changeColor,
      ),
      if (_showResetButton)
        _groupActionChip(
          label: 'Reset\nColor',
          backgroundColor: const Color(0xFF6B7280),
          onPressed: _resetColor,
        ),
      _groupActionChip(
        label: _showTimestamps ? 'Hide\nTimestamps' : 'Show\nTimestamps',
        backgroundColor: const Color(0xFF4F46E5),
        onPressed: _toggleTimestamps,
      ),
      if (_currentUserIsAdmin)
        _groupActionChip(
          label: 'Delete\nMessages',
          backgroundColor: const Color(0xFF6D28D9),
          onPressed: _adminDeleteAllMessages,
        ),
    ];

    Widget fittedRow(List<Widget> buttons) {
      if (buttons.isEmpty) return const SizedBox.shrink();
      return LayoutBuilder(
        builder: (context, constraints) {
          const gap = 3.0;
          final totalGap = gap * (buttons.length - 1);
          var itemWidth = (constraints.maxWidth - totalGap) / buttons.length;
          if (itemWidth < 48.0) {
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (int i = 0; i < buttons.length; i++) ...[
                    SizedBox(width: 48.0, child: buttons[i]),
                    if (i < buttons.length - 1) const SizedBox(width: gap),
                  ],
                ],
              ),
            );
          }
          return Row(
            children: [
              for (int i = 0; i < buttons.length; i++) ...[
                SizedBox(width: itemWidth, child: buttons[i]),
                if (i < buttons.length - 1) const SizedBox(width: gap),
              ],
            ],
          );
        },
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          fittedRow(topRow),
          const SizedBox(height: 2),
          fittedRow(bottomRow),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ChatComposerPanel(
          scale: 1.0,
          backgroundColor: const Color(0xFF161625),
          composerInset: 0,
          showEmojiPicker: _showEmojiPicker,
          isEditing: false,
          onShowEmojiPickerModal: () => _showEmojiPickerModal(context),
          onClipboardPasteShortcut: _pasteFromClipboard,
          onInputContextMenuOpened: () {},
          onContentInserted: _onGroupContentInserted,
          onTextChanged: _onGroupComposerTextChanged,
          onSend: _sendMessage,
          messageController: _messageController,
          inputFocusNode: _inputFocusNode,
          inputScrollController: _inputScrollController,
          buildDoorbellComposerButton:
              ({
                required bool showLabel,
                required double iconSize,
                required EdgeInsets padding,
              }) => _buildGroupDoorbellComposerButton(
                showLabel: showLabel,
                iconSize: iconSize,
                padding: padding,
              ),
          isComposerMultiline: _isComposerMultiline,
          editPreview: const SizedBox.shrink(),
          replyPreview: _replyingToMessage != null
              ? _buildReplyPreview()
              : const SizedBox.shrink(),
          sendToManyQuickAction: const SizedBox.shrink(),
          unifiedActionsBar: _buildGroupUnifiedActionsBar(),
        ),
        // Inline emoji picker rendered below the composer when toggled.
        if (_showEmojiPicker)
          Container(
            color: const Color(0xFF161625),
            child: _buildInlineEmojiPicker(),
          ),
      ],
    );
  }
}

/// Audio Message Player Widget for playing voice messages in group chat
class _AudioMessagePlayer extends StatefulWidget {
  final String audioUrl;
  final int? fileSize;
  final double? initialDuration;

  const _AudioMessagePlayer({
    required this.audioUrl,
    this.fileSize,
    this.initialDuration,
  });

  @override
  State<_AudioMessagePlayer> createState() => _AudioMessagePlayerState();
}

class _AudioMessagePlayerState extends State<_AudioMessagePlayer> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _completeSubscription;

  @override
  void initState() {
    super.initState();
    if (widget.initialDuration != null && widget.initialDuration! > 0) {
      _duration = Duration(milliseconds: (widget.initialDuration! * 1000).round());
    }
    _setupAudioPlayer();
  }

  void _setupAudioPlayer() {
    _durationSubscription = _audioPlayer.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });

    _positionSubscription = _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });

    _completeSubscription = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
      }
    });

    if (_duration == Duration.zero) {
      _probeAudioSource();
    }
  }

  Future<void> _probeAudioSource() async {
    try {
      Source source;
      final cached = await DefaultCacheManager().getFileFromCache(widget.audioUrl);
      if (cached != null) {
        source = DeviceFileSource(cached.file.path);
      } else {
        source = UrlSource(widget.audioUrl);
      }
      if (mounted && !_isPlaying) {
        await _audioPlayer.setSource(source);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _durationSubscription?.cancel();
    _positionSubscription?.cancel();
    _completeSubscription?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _togglePlayPause() async {
    try {
      if (_isPlaying) {
        await _audioPlayer.pause();
        setState(() => _isPlaying = false);
      } else {
        // Stop any current playback first
        await _audioPlayer.stop();

        // Small delay to ensure player is ready
        await Future.delayed(const Duration(milliseconds: 100));

        // Prefer the on-disk cached file when available so audio plays
        // offline; otherwise stream and warm the cache for next time.
        Source source;
        try {
          final cached = await DefaultCacheManager().getFileFromCache(
            widget.audioUrl,
          );
          if (cached != null) {
            source = DeviceFileSource(cached.file.path);
          } else {
            source = UrlSource(widget.audioUrl);
            unawaited(() async {
              try {
                await DefaultCacheManager().downloadFile(widget.audioUrl);
              } catch (_) {}
            }());
          }
        } catch (_) {
          source = UrlSource(widget.audioUrl);
        }
        await _audioPlayer.play(source);
        setState(() => _isPlaying = true);
      }
    } catch (e) {
      debugPrint('AudioPlayers Exception: $e');
      if (mounted) {
        setState(() => _isPlaying = false);
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.hideCurrentMaterialBanner();
        messenger.showMaterialBanner(
          MaterialBanner(
            content: Text(
              'Error playing audio: ${e.toString().split(':').last.trim()}',
            ),
            backgroundColor: Colors.red,
            contentTextStyle: const TextStyle(color: Colors.white),
            actions: [
              TextButton(
                onPressed: messenger.hideCurrentMaterialBanner,
                child: const Text(
                  'DISMISS',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        );
        Timer(const Duration(seconds: 2), () {
          if (mounted) messenger.hideCurrentMaterialBanner();
        });
      }
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Play/Pause button
          GestureDetector(
            onTap: _togglePlayPause,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(51),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 28,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Waveform and progress
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Waveform visualization (static bars)
                Row(
                  children: List.generate(20, (index) {
                    final barHeight = [
                      8.0,
                      14.0,
                      10.0,
                      18.0,
                      12.0,
                      20.0,
                      16.0,
                      22.0,
                      14.0,
                      18.0,
                      12.0,
                      16.0,
                      20.0,
                      14.0,
                      10.0,
                      18.0,
                      12.0,
                      8.0,
                      14.0,
                      10.0,
                    ][index];
                    final isPlayed = progress > (index / 20);
                    return Container(
                      width: 3,
                      height: barHeight,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: isPlayed ? Colors.white : Colors.white38,
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 4),
                // Duration text
                Text(
                  _isPlaying || _position > Duration.zero
                      ? '${_formatDuration(_position)} / ${_formatDuration(_duration)}'
                      : _formatDuration(_duration),
                  style: TextStyle(
                    color: Colors.white.withAlpha(179),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Lightweight video thumbnail widget for group chat bubbles.
/// Initializes a VideoPlayerController to display the first frame.
class _GroupVideoThumbnailWidget extends StatefulWidget {
  final String videoUrl;

  const _GroupVideoThumbnailWidget({required this.videoUrl});

  @override
  State<_GroupVideoThumbnailWidget> createState() =>
      _GroupVideoThumbnailWidgetState();
}

class _GroupVideoThumbnailWidgetState
    extends State<_GroupVideoThumbnailWidget> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  Future<void> _initController() async {
    try {
      VideoPlayerController controller;
      final cached = await DefaultCacheManager().getFileFromCache(
        widget.videoUrl,
      );
      if (cached != null) {
        controller = VideoPlayerController.file(cached.file);
      } else {
        controller = VideoPlayerController.networkUrl(
          Uri.parse(widget.videoUrl),
        );
        unawaited(() async {
          try {
            await DefaultCacheManager().downloadFile(widget.videoUrl);
          } catch (_) {}
        }());
      }
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      await controller.pause();
      await controller.seekTo(Duration.zero);
      setState(() {
        _controller = controller;
        _initialized = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Every state fills the parent's fixed media box so the bubble never
    // resizes (no layout jump) as the controller initialises.
    if (_hasError || (!_initialized && _controller == null)) {
      return Container(
        color: Colors.grey[900],
        child: const Center(
          child: Icon(Icons.videocam, color: Colors.white38, size: 48),
        ),
      );
    }

    if (!_initialized) {
      return Container(
        color: Colors.grey[900],
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white38,
            ),
          ),
        ),
      );
    }

    final controller = _controller!;
    final size = controller.value.size;
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: size.width <= 0 ? 16 : size.width,
          height: size.height <= 0 ? 9 : size.height,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}
