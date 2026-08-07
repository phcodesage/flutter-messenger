import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Message;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:open_filex/open_filex.dart';
import '../models/lobby_user.dart';
import '../models/message.dart';
import '../models/common_phrase.dart';
import '../services/lobby_service.dart';
import '../services/common_phrases_api.dart';
import '../services/message_service.dart';
import '../services/socket_service.dart';
import '../services/tts_service.dart';
import '../services/storage_service.dart';
import '../services/chat_cache_service.dart';
import '../services/media_preload_service.dart';
import '../services/translation_service.dart';
import '../services/link_preview_service.dart';
import '../widgets/color_picker_modal.dart';
import '../widgets/common_phrase_bar.dart';
import '../services/active_chat_service.dart';
import '../services/draft_service.dart';
import '../services/pending_incoming_call_service.dart';
import '../utils/notification_handler.dart';
import '../widgets/call_setup_modal.dart';
import '../widgets/outgoing_call_modal.dart';
import '../widgets/incoming_call_setup_modal.dart';
import '../widgets/reaction_picker.dart';
import '../widgets/file_preview_modal_content.dart';
import '../services/call_service.dart';
import '../services/presence_service.dart';
import '../services/firebase_messaging_service.dart';
import '../config/api_config.dart';
import 'chat/chat_header.dart';
import 'chat/chat_composer_panel.dart';
import '../utils/chat_exporter.dart';
import '../utils/file_saver.dart';
import 'chat/chat_date_separator.dart';
import 'chat/chat_message_item.dart';
import 'chat/chat_message_bubble.dart';
import 'chat/chat_message_list.dart';
import 'chat/chat_typing_preview.dart';
import 'chat/swipeable_message.dart';
import 'connected_call_screen.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:video_player/video_player.dart';
import '../utils/contact_utils.dart';
import '../widgets/attachment_menu_sheet.dart';
import '../services/compression_service.dart';
import '../services/media_picker_service.dart';
import '../services/media_upload_retry_service.dart';
import '../services/text_message_retry_service.dart';
import '../services/socket_event_queue_service.dart';
import '../services/media_upload_service.dart';
import '../state/media_upload_state.dart';
import '../widgets/upload_progress_indicator.dart';
import 'media_preview_screen.dart';
import 'media_gallery_viewer.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import '../services/forward_service.dart';
import '../widgets/forward_recipient_picker.dart';
import '../services/excalidraw_rooms_service.dart';
import '../widgets/excalidraw_rooms_section.dart';
import '../widgets/excalidraw_room_picker.dart';
import 'excalidraw_board_screen.dart';

/// Chat screen for messaging with a specific user
class ChatScreen extends StatefulWidget {
  final LobbyUser otherUser;
  final bool initialCallInProgressOnOtherDevice;

  /// When true the screen is rendered inside the desktop two-pane layout
  /// (beside the conversation list) rather than as a pushed route. The back
  /// button is hidden in this mode since there is nothing to pop.
  final bool embedded;

  const ChatScreen({
    super.key,
    required this.otherUser,
    this.initialCallInProgressOnOtherDevice = false,
    this.embedded = false,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class LiveChatTimestampHeader extends StatefulWidget {
  final double scale;

  const LiveChatTimestampHeader({super.key, required this.scale});

  @override
  State<LiveChatTimestampHeader> createState() =>
      _LiveChatTimestampHeaderState();
}

class _LiveChatTimestampHeaderState extends State<LiveChatTimestampHeader> {
  late DateTime _currentDateTime;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _currentDateTime = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _currentDateTime = DateTime.now();
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _formattedTimestamp() {
    final now = _currentDateTime;
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

    final date =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final hour12 = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final minute = now.minute.toString().padLeft(2, '0');
    final second = now.second.toString().padLeft(2, '0');
    final period = now.hour >= 12 ? 'PM' : 'AM';
    final timezone = now.timeZoneName;
    final weekday = weekdays[now.weekday - 1];
    final month = months[now.month - 1];

    return '$date $hour12:$minute:$second $period $timezone - $weekday, $month ${now.day}, ${now.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: 16 * widget.scale,
        vertical: 8 * widget.scale,
      ),
      color: const Color(0xFF1F1F1F),
      child: Text(
        _formattedTimestamp(),
        style: TextStyle(
          color: Colors.grey[300],
          fontSize: 13 * widget.scale,
          fontWeight: FontWeight.w500,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const MethodChannel _fileOpsChannel = MethodChannel(
    'com.example.flutter_messenger_v2/file_ops',
  );

  final SocketService _socketService = SocketService();
  final MediaUploadState _mediaUploadState = MediaUploadState();
  StreamSubscription<RetryProgress>? _retryProgressSubscription;
  StreamSubscription<TextRetryProgress>? _textRetryProgressSubscription;
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _autoCorrectionWrongController =
      TextEditingController();
  final TextEditingController _autoCorrectionCorrectController =
      TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ScrollController _inputScrollController = ScrollController();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final FlutterLocalNotificationsPlugin _localNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  final FocusNode _inputFocusNode = FocusNode();
  final GlobalKey _bottomBarKey = GlobalKey();

  List<Message> _messages = [];
  List<Map<String, dynamic>> _pinnedExcalidrawLinks = [];

  /// Self-hosted whiteboards for this conversation. The count feeds the header
  /// badge so the other side knows a board was added or renamed.
  int _excalidrawRoomsUnread = 0;
  final GlobalKey<ExcalidrawRoomsSectionState> _excalRoomsSectionKey =
      GlobalKey<ExcalidrawRoomsSectionState>();
  bool _isLoading = true;
  bool _isLoadingMessages = false; // Guard against concurrent message loads
  bool _isLoadingMore = false; // Guard against concurrent "load more" calls
  bool _hasMoreMessages = true; // Whether older messages may exist on server
  bool _isTyping = false;
  bool _isKeyboardVisible = false;
  bool _isAppInForeground = true;
  bool _restoreInputFocusOnResume = false;
  bool _suppressRestoreOnNextResume = false;
  bool _isRestoringInputFocus = false;
  TextSelection? _savedInputSelection;
  bool _isSwitchingInputMode = false;
  double _lockedInputPanelHeight = 0;
  Timer? _inputModeSwitchTimer;
  // True while switching from the emoji panel back to the keyboard: the bottom
  // inset is held constant (composer/list don't move) and the emoji grid stays
  // visible until the keyboard has risen to the held height.
  bool _emojiKeyboardSwitching = false;
  Timer? _emojiSwitchTimer;
  // Drives the keyboard inset back to 0 when the emoji panel is dismissed
  // outright (system Back) — there's no IME animating down to collapse it.
  Timer? _emojiCollapseTimer;
  double _lastKnownKeyboardInset = 0;
  // App-wide cache of the keyboard height so the FIRST open in a freshly opened
  // chat can snap instantly too (per-screen state resets, this doesn't).
  static double _lastKnownKeyboardInsetGlobal = 0;
  // Live keyboard inset (logical px), updated from didChangeMetrics. The bottom
  // composer subscribes to this via a ValueListenableBuilder so the keyboard
  // animation slides only the composer — the message list never rebuilds.
  final ValueNotifier<double> _keyboardInsetNotifier = ValueNotifier<double>(0);
  bool _otherUserTyping = false;
  String _typingPreview = '';
  int? _currentUserId;
  Timer? _typingTimer;
  Timer? _autoCorrectionPreviewTimer;
  Timer?
  _typingHideTimer; // auto-clears the partner's typing indicator if stop event is missed
  Timer? _typingUpdateThrottle;
  Timer? _lastSeenRefreshTimer;
  DateTime? _lastTypingUpdate;
  Color _headerColor = const Color(0xFF121212); // Default chat surface color
  bool _showResetButton = false;
  bool _callInProgressOnOtherDevice = false;
  Timer? _callInProgressOnOtherDeviceTimer;
  String? _crossDeviceActiveCallRoomId;
  int? _crossDeviceActivePeerId;
  Route<dynamic>? _activeIncomingCallRoute;
  int? _activeIncomingCallId;
  String? _activeIncomingCallRoomId;

  // Pending media files (minimized from preview screen)
  List<AssetEntity>? _pendingMediaItems;
  String _pendingMediaCaption = '';

  // Active file upload state (for single-file preview modal with progress)
  File? _activeUploadFile;
  String? _activeUploadFileName;
  String? _activeUploadDisplayName;
  String? _activeUploadMimeType;
  final ValueNotifier<double> _activeUploadProgressNotifier = ValueNotifier(
    0.0,
  );
  double _activeUploadProgress = 0.0;
  bool _isActivelyUploading = false;
  bool _isFromCamera = false;

  // Pending file (minimized before sending from file preview)
  File? _pendingFile;
  String? _pendingFileName;
  String? _pendingFileMimeType;
  bool _pendingFileIsFromCamera = false;

  // Timestamp visibility toggle (hidden by default like web)
  bool _showTimestamps = false;

  // Auto-translate toggle
  bool _autoTranslate = false;

  // Auto-correction UI state (voice/input replacement dictionary)
  bool _autoCorrectionEnabled = true;
  bool _stampEnabled = false;
  final Map<String, String> _manualAutoCorrectionMappings = {
    'rush': 'rech',
    'rache': 'rech',
  };
  final Map<String, String> _learnedAutoCorrectionMappings = {'helo': 'hello'};

  static const String _autoCorrectionEnabledPrefKey = 'autoCorrectionEnabled';
  static const String _stampEnabledPrefKey = 'stampEnabled';
  static const String _autoCorrectionManualPrefKey =
      'autoCorrectionManualMappings';
  static const String _autoCorrectionLearnedPrefKey =
      'autoCorrectionLearnedMappings';

  // Scroll to bottom button state
  bool _isAtBottom = true;
  int _unreadCount = 0;
  bool _suppressNextSendAutoScroll = false;

  // Reply state
  Message? _replyingToMessage;

  // Edit state
  Message? _editingMessage;

  // Draft persistence (per-room unsent text — see DraftService)
  Timer? _draftSaveDebounce;
  String get _draftRoomKey => 'user:${widget.otherUser.id}';

  // Top SnackBar Overlay state
  OverlayEntry? _topSnackBarEntry;
  Timer? _topSnackBarTimer;

  // Reaction state: { messageId: { emoji: Set<userId> } }
  final Map<int, Map<String, Set<String>>> _messageReactions = {};

  static final RegExp _messageUrlRegex = RegExp(
    r'((?:https?:\/\/|www\.)[^\s]+)',
    caseSensitive: false,
  );
  static final RegExp _excalidrawUrlRegex = RegExp(
    r'((?:https?:\/\/)?(?:www\.)?excalidraw\.com[^\s]*)',
    caseSensitive: false,
  );

  // Translation state: { messageId: translatedText }
  final Map<int, String> _messageTranslations = {};

  // Common phrases state
  late CommonPhrasesApi _commonPhrasesApi;
  List<CommonPhrase> _commonPhrases = const [];
  bool _hideCommonPhrases = false;

  // Emoji picker state for chat input
  bool _showEmojiPicker = false;

  bool _isActionsPanelOpen = false;
  bool _actionsPanelFromKeyboard = false;
  double _actionsPanelInset = 0;
  bool _localNotificationsReady = false;
  bool _isHandlingClipboardImagePaste = false;
  DateTime? _lastClipboardPasteAttemptAt;
  double _lastMetricsViewInsetBottom = 0;
  double _lastMetricsViewPaddingBottom = 0;

  // Flag to suppress doorbell echo on the triggering device
  bool _localDoorbellPending = false;

  // Keep doorbell AudioPlayer references alive until playback completes (prevents GC mid-play)
  final List<AudioPlayer> _activeDoorbellPlayers = [];

  // Flag to suppress color reset echo on the triggering device
  bool _localColorResetPending = false;

  // Whether the currently logged-in user is an admin
  bool _currentUserIsAdmin = false;

  // Track optimistic messages awaiting server confirmation (dedup keys)
  final Set<String> _pendingMessageKeys = {};

  // One-tap composer mode: next message is auto-marked as a task.
  bool _markNextMessageAsTask = false;

  // Dedup-keyed task intents so repeated identical messages are handled safely.
  final Map<String, int> _pendingTaskIntentsByDedupKey = {};

  // Task events can arrive before the corresponding message payload.
  final Map<int, String?> _pendingLiveTaskCreatedAtByMessageId = {};
  final Map<int, String?> _pendingLiveTaskCompletedAtByMessageId = {};
  int?
  _bubbleFlashId; // transient flash highlight, auto-clears after short delay

  // Task filter: 'pending' or 'completed'
  String _taskFilter = 'pending';

  // Per-message GlobalKeys used by _jumpToTaskBubble for accurate scrolling.
  final Map<int, GlobalKey> _messageItemKeys = {};

  // All task-marked messages for this conversation, loaded independently of
  // the paginated _messages list so the full task count is always accurate.
  List<Message> _taskMessages = [];
  bool _isLoadingTasks = false;

  // Message IDs loaded from local cache/server history.
  // For these historical records, UI should always display status as "seen"
  // (they predate the current session and have already been read).
  final Set<int> _databaseLoadedMessageIds = {};

  // Animated task count badge
  late AnimationController _taskBadgeAnimController;

  // Rebuild open task modal on live task updates.
  final ValueNotifier<int> _taskModalVersion = ValueNotifier<int>(0);

  // _isHandlingIncomingCall is now global via PresenceService().isHandlingIncomingCall

  // Presence state for the chat partner
  bool _partnerIsOnline = false;
  String _partnerStatus = 'offline';
  String? _partnerLastSeen;

  bool get _isSelfChat {
    final currentUserId = _currentUserId;
    return currentUserId != null && widget.otherUser.id == currentUserId;
  }

  bool get _hasKnownConversationHistory =>
      widget.otherUser.unreadCount > 0 ||
      (widget.otherUser.lastMessage?.trim().isNotEmpty ?? false) ||
      (widget.otherUser.lastMessageTime?.trim().isNotEmpty ?? false);

  /// Return a short display name for use inside the chat area (prefer first name).
  String _chatDisplayNameFromSender(String? senderName) {
    if (senderName == null) return widget.otherUser.firstName;
    final s = senderName.trim();
    if (s.isEmpty) return widget.otherUser.firstName;
    if (s.toLowerCase() == 'you') return 'You';
    return s.split(RegExp(r"\\s+"))[0];
  }

  void _notifyTaskModalChanged() {
    _taskModalVersion.value = _taskModalVersion.value + 1;
  }

  void _loadDraftIntoComposer() {
    final roomKey = _draftRoomKey;
    DraftService().loadText(roomKey).then((draft) {
      if (!mounted || draft.isEmpty || _editingMessage != null) return;
      _messageController.text = draft;
      _messageController.selection = TextSelection.collapsed(
        offset: draft.length,
      );
    });
  }

  /// Saves composer text as a draft on every keystroke (debounced) — mirrors
  /// the web app's `input` listener. Emptying the text (including the clear()
  /// call `_sendMessage` makes on send) clears the draft immediately, which
  /// also undoes any prior "left with unsent text" bump.
  void _onComposerTextChangedForDraft() {
    if (_editingMessage != null) return; // don't persist in-progress edits as a draft
    final roomKey = _draftRoomKey;
    final text = _messageController.text;
    _draftSaveDebounce?.cancel();
    if (text.trim().isEmpty) {
      unawaited(DraftService().setText(roomKey, ''));
      return;
    }
    _draftSaveDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(DraftService().setText(roomKey, text));
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Lobby metadata already knows when a conversation has never had a
    // message. Show the honest empty state immediately in that case instead
    // of six fake bubbles that can only disappear into "No messages yet".
    _isLoading = _hasKnownConversationHistory;
    _seedMessagesFromWarmCache();
    // Seed from the app-wide cache so the first keyboard open snaps instantly.
    if (_lastKnownKeyboardInsetGlobal > 0) {
      _lastKnownKeyboardInset = _lastKnownKeyboardInsetGlobal;
    }
    _taskBadgeAnimController = AnimationController(
      vsync: this,
      // Instant (no badge bounce) — forward() jumps straight to the end state.
      duration: Duration.zero,
    );
    _inputFocusNode.addListener(_onFocusChange);
    _scrollController.addListener(_onScroll);
    _messageController.addListener(_syncCommonPhrasesVisibility);
    _messageController.addListener(_onComposerTextChangedForDraft);
    _loadDraftIntoComposer();
    _fileOpsChannel.setMethodCallHandler(_handleFileOpsMethodCall);

    // Set this user as active to prevent FCM notifications
    ActiveChatService().setActiveUser(widget.otherUser.id);

    // If an incoming call from this user was deferred while we were viewing a
    // different conversation, surface its modal now that we're in the caller's
    // room so the answer routes to the correct room.
    final deferredCall = PendingIncomingCallService().takeForCaller(
      widget.otherUser.id,
    );
    if (deferredCall != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _handleIncomingCallInChat(deferredCall, requestOffer: true);
      });
    }

    // An offer can age out while its modal is already on screen (the caller
    // hung up on another device and the cancel never arrived). Close it rather
    // than leaving the user staring at a call they can no longer answer.
    PendingIncomingCallService().expired.addListener(_onPendingCallExpired);

    _initialize();
    // Periodically refresh "last seen" relative label in header (like the web app does)
    _lastSeenRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted && _getEffectivePartnerStatus() != 'online') setState(() {});
    });

    // Listen to automatic retry progress from MediaUploadRetryService
    // so queued uploads show live progress while the user stays in chat.
    _retryProgressSubscription = MediaUploadRetryService().progressStream.listen((
      retryProgress,
    ) {
      _mediaUploadState.updateProgress(
        retryProgress.trackingId,
        retryProgress.progress,
      );
      if (retryProgress.progress.status == UploadStatus.success) {
        _mediaUploadState.removeUpload(retryProgress.trackingId);
        final serverMessage = retryProgress.message;
        final optimisticId =
            MediaUploadRetryService.getOptimisticIdFromTrackingId(
              retryProgress.trackingId,
            );

        if (mounted) {
          setState(() {
            final index = _messages.indexWhere((m) => m.id == optimisticId);
            if (index != -1) {
              final oldMessage = _messages[index];
              if (serverMessage != null) {
                // Replace with server message, but keep the local file path to avoid UI flicker
                _messages[index] = Message(
                  id: serverMessage.id,
                  senderId: serverMessage.senderId,
                  recipientId: serverMessage.recipientId,
                  content: serverMessage.content.isNotEmpty
                      ? serverMessage.content
                      : oldMessage.content,
                  messageType: oldMessage.messageType,
                  timestamp: serverMessage.timestamp,
                  timestampMs: serverMessage.timestampMs,
                  isRead: serverMessage.isRead,
                  status: 'sent', // Explicitly mark sent
                  threadId: serverMessage.threadId,
                  reactions: serverMessage.reactions.isNotEmpty
                      ? serverMessage.reactions
                      : oldMessage.reactions,
                  isDeleted: serverMessage.isDeleted,
                  fileUrl: (serverMessage.fileUrl?.isNotEmpty == true)
                      ? serverMessage.fileUrl
                      : oldMessage.fileUrl,
                  fileName: (serverMessage.fileName?.isNotEmpty == true)
                      ? serverMessage.fileName
                      : oldMessage.fileName,
                  fileType: (serverMessage.fileType?.isNotEmpty == true)
                      ? serverMessage.fileType
                      : oldMessage.fileType,
                  fileSize: serverMessage.fileSize ?? oldMessage.fileSize,
                  // Preserve the caption the user typed — the upload echo often
                  // omits it, and losing it here is why a photo's caption
                  // disappeared after an offline→online retry.
                  caption: (serverMessage.caption?.isNotEmpty == true)
                      ? serverMessage.caption
                      : oldMessage.caption,
                  localFilePath: oldMessage.localFilePath,
                );
              } else {
                // If the backend didn't return a fully parsed message, just mark optimistic as sent
                _messages[index] = Message(
                  id: oldMessage.id,
                  senderId: oldMessage.senderId,
                  recipientId: oldMessage.recipientId,
                  content: oldMessage.content,
                  messageType: oldMessage.messageType,
                  timestamp: oldMessage.timestamp,
                  timestampMs: oldMessage.timestampMs,
                  isRead: oldMessage.isRead,
                  status: 'sent', // Fix stuck pending indicator
                  threadId: oldMessage.threadId,
                  reactions: oldMessage.reactions,
                  isDeleted: oldMessage.isDeleted,
                  fileUrl: oldMessage.fileUrl,
                  fileName: oldMessage.fileName,
                  fileType: oldMessage.fileType,
                  fileSize: oldMessage.fileSize,
                  caption: oldMessage.caption,
                  localFilePath: oldMessage.localFilePath,
                );
              }
              debugPrint(
                '💬 Updated retry-succeeded message in active ChatScreen UI',
              );
            } else if (serverMessage != null &&
                !_messages.any((m) => m.id == serverMessage.id)) {
              _messages.insert(0, serverMessage);
            }
          });
          unawaited(_persistConversationCacheSnapshot());
        }
      } else if (retryProgress.progress.status == UploadStatus.failed) {
        _mediaUploadState.markFailed(
          retryProgress.trackingId,
          'Upload failed after retry',
        );
      }
    });

    // Listen to automatic retry progress from TextMessageRetryService so that a
    // text message queued while offline flips from the clock to ✓ once it is
    // re-sent over REST. (When the retry goes out over the socket instead, the
    // 'messageSent' echo handler reconciles it — no progress event is emitted.)
    _textRetryProgressSubscription = TextMessageRetryService().progressStream
        .listen((retryProgress) {
          if (!retryProgress.success || retryProgress.message == null) return;
          if (!mounted) return;
          final serverMessage = retryProgress.message!;
          setState(() {
            final index = _messages.indexWhere(
              (m) => m.id == retryProgress.optimisticId,
            );
            if (index != -1) {
              _messages[index] = serverMessage;
            } else if (!_messages.any((m) => m.id == serverMessage.id)) {
              _messages.insert(0, serverMessage);
            }
          });
          unawaited(_persistConversationCacheSnapshot());
          debugPrint(
            '💬 Reconciled retry-sent text message in active ChatScreen UI',
          );
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _isAppInForeground = false;
      ActiveChatService().clearActiveChat();
      if (_suppressRestoreOnNextResume) {
        _restoreInputFocusOnResume = false;
        return;
      }
      _restoreInputFocusOnResume =
          _inputFocusNode.hasFocus || _isKeyboardVisible;
      return;
    }

    if (state == AppLifecycleState.resumed && _suppressRestoreOnNextResume) {
      _isAppInForeground = true;
      ActiveChatService().setActiveUser(widget.otherUser.id);
      _suppressRestoreOnNextResume = false;
      _restoreInputFocusOnResume = false;
      _keepInputUnfocused();
      return;
    }

    if (state == AppLifecycleState.resumed) {
      _isAppInForeground = true;
      ActiveChatService().setActiveUser(widget.otherUser.id);
    }

    if (state == AppLifecycleState.resumed && _restoreInputFocusOnResume) {
      unawaited(_restoreInputFocusAfterResume());
    }
  }

  bool get _canAutoMarkConversationAsSeen {
    if (!mounted || _isSelfChat || !_isAppInForeground) {
      return false;
    }

    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      return false;
    }

    return true;
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (view == null) return;

    final devicePixelRatio = view.devicePixelRatio;
    final viewInsetBottom = view.viewInsets.bottom / devicePixelRatio;
    final viewPaddingBottom = view.viewPadding.bottom / devicePixelRatio;
    final metricsChanged =
        (viewInsetBottom - _lastMetricsViewInsetBottom).abs() > 0.5 ||
        (viewPaddingBottom - _lastMetricsViewPaddingBottom).abs() > 0.5;

    _lastMetricsViewInsetBottom = viewInsetBottom;
    _lastMetricsViewPaddingBottom = viewPaddingBottom;

    if (!metricsChanged || !mounted) return;

    // Suppress updates while restoring focus after app resume to prevent
    // the UI from jumping (keyboard inset briefly reports 0 then restores).
    if (_restoreInputFocusOnResume || _isRestoringInputFocus) return;

    if (viewInsetBottom > 0) {
      _lastKnownKeyboardInset = viewInsetBottom;
      _lastKnownKeyboardInsetGlobal = viewInsetBottom;
    }

    // The emoji panel deliberately hides the keyboard while keeping focus; its
    // height is driven separately, so don't react to the inset here.
    if (_showEmojiPicker) return;

    // Switching emoji → keyboard: hold the inset constant (composer/list stay
    // put, emoji grid stays visible) until the keyboard has risen to roughly the
    // held height, then release and follow it. This keeps the swap jump-free.
    if (_emojiKeyboardSwitching) {
      if (viewInsetBottom >= _keyboardInsetNotifier.value - 24) {
        _emojiSwitchTimer?.cancel();
        _emojiKeyboardSwitching = false;
        _setKeyboardInset(viewInsetBottom);
        if (mounted) setState(() {}); // hide the emoji overlay
      }
      return;
    }

    // Track the keyboard frame-by-frame (on Android 11+ viewInsets is already
    // synced to the IME animation). We do NOT relayout the screen: the message
    // list keeps its size and only the composer translates + the list scrolls,
    // so following every frame stays cheap and feels "attached" like WhatsApp.
    _setKeyboardInset(viewInsetBottom);
  }

  /// Publish a new keyboard inset. This drives two cheap, paint/layout-only
  /// reactions that both listen to [_keyboardInsetNotifier]:
  ///  • the composer translates up over the (un-resized) message list, and
  ///  • the list's reactive bottom spacer (item 0) grows by the same amount,
  ///    lifting the newest message just above the composer.
  /// The message list is never rebuilt or resized, so following the keyboard
  /// frame-by-frame stays smooth and "attached", WhatsApp-style.
  void _setKeyboardInset(double newInset) {
    // A real keyboard movement supersedes an in-flight emoji-dismiss collapse.
    _emojiCollapseTimer?.cancel();
    if ((newInset - _keyboardInsetNotifier.value).abs() < 0.5) return;
    _keyboardInsetNotifier.value = newInset;
  }

  /// Smoothly collapse the keyboard inset to 0 when the emoji panel is dismissed
  /// outright (e.g. system Back). The composer translate and the message list's
  /// bottom spacer both ride [_keyboardInsetNotifier]; since no IME is animating
  /// down to drive it, we ease it to 0 ourselves so the composer drops and the
  /// list shrinks instead of leaving a wide empty gap where the grid was.
  void _animateKeyboardInsetToZero() {
    _emojiCollapseTimer?.cancel();
    final start = _keyboardInsetNotifier.value;
    if (start <= 0.5) {
      _keyboardInsetNotifier.value = 0;
      return;
    }
    const totalMs = 200;
    final stopwatch = Stopwatch()..start();
    _emojiCollapseTimer = Timer.periodic(const Duration(milliseconds: 16), (
      timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final t = (stopwatch.elapsedMilliseconds / totalMs).clamp(0.0, 1.0);
      // easeOutCubic so it decelerates into place, matching the IME feel.
      final eased = 1 - math.pow(1 - t, 3).toDouble();
      _keyboardInsetNotifier.value = start * (1 - eased);
      if (t >= 1.0) {
        _keyboardInsetNotifier.value = 0;
        timer.cancel();
      }
    });
  }

  Future<void> _restoreInputFocusAfterResume() async {
    if (!mounted || !_restoreInputFocusOnResume) return;
    _isRestoringInputFocus = true;

    // Restore focus and keyboard, but suppress all rebuilds during the
    // transition so the UI doesn't jump while the keyboard animates in.
    for (final delay in const [0, 90, 200]) {
      if (delay > 0) {
        await Future<void>.delayed(Duration(milliseconds: delay));
      }
      if (!mounted || !_restoreInputFocusOnResume) return;
      _inputFocusNode.requestFocus();
      try {
        await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      } catch (_) {}
    }

    _restoreInputFocusOnResume = false;

    // Wait for the keyboard to fully appear before allowing rebuilds.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _isRestoringInputFocus = false;

    // Single rebuild now that the keyboard is stable.
    if (mounted) setState(() {});
  }

  double _effectiveKeyboardInset() {
    // During app resume, freeze at the last known keyboard height entirely so
    // the UI doesn't animate as the keyboard re-appears.
    if (_restoreInputFocusOnResume || _isRestoringInputFocus) {
      return _lastKnownKeyboardInset;
    }
    // Read the cached notifier value — NOT MediaQuery — so callers in build()
    // don't subscribe to viewInsets and rebuild every keyboard-animation frame.
    final currentInset = _keyboardInsetNotifier.value;
    if (currentInset > 0) {
      _lastKnownKeyboardInset = currentInset;
    }
    return currentInset;
  }

  double _emojiPanelHeight(double keyboardInset) {
    final target = keyboardInset > 0 ? keyboardInset : _lastKnownKeyboardInset;
    return target <= 0 ? 300 : target.clamp(260, 420).toDouble();
  }

  /// Stable emoji-panel content height. Single source of truth shared by the
  /// composer's translate (so it lifts over the grid) and the bottom overlay
  /// that actually renders the grid, so the two can never drift.
  double _currentEmojiPanelHeight() {
    if (_isSwitchingInputMode && _lockedInputPanelHeight > 0) {
      return _lockedInputPanelHeight;
    }
    return _emojiPanelHeight(_effectiveKeyboardInset());
  }

  void _startInputModeLock(double panelHeight) {
    _inputModeSwitchTimer?.cancel();
    setState(() {
      _isSwitchingInputMode = true;
      _lockedInputPanelHeight = panelHeight;
    });
    _inputModeSwitchTimer = Timer(const Duration(milliseconds: 260), () {
      if (!mounted) return;
      setState(() {
        _isSwitchingInputMode = false;
        _lockedInputPanelHeight = 0;
      });
    });
  }

  Widget _buildChatLoadingPlaceholder() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 6,
      itemBuilder: (_, index) {
        final isMe = index % 2 == 0;
        return Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Container(
              width: 180,
              height: 20,
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A4F),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Listen to scroll position to show/hide scroll-to-bottom button
  void _onScroll() {
    // Since list is reversed, offset 0 is the bottom (newest). The keyboard is
    // accounted for by the reactive bottom spacer inside the list (item 0), so
    // the bottom baseline stays 0.
    final isAtBottom = _scrollController.offset < 100;
    if (_isAtBottom != isAtBottom) {
      setState(() {
        _isAtBottom = isAtBottom;
        if (isAtBottom) {
          _unreadCount = 0;
          // Mark visible messages as read when scrolling to bottom
          _markVisibleMessagesAsRead();
        }
      });
    }
  }

  /// Mark visible messages as read
  void _markVisibleMessagesAsRead() {
    if (!_canAutoMarkConversationAsSeen) return;

    final unreadMessageIds = <int>[];

    // Find unread messages from the other user
    for (final message in _messages) {
      if (message.senderId == widget.otherUser.id && !message.isRead) {
        unreadMessageIds.add(message.id);
      }
    }

    if (unreadMessageIds.isNotEmpty) {
      // Mark messages as read/viewed so both web + lobby state clear their badges
      _socketService.markMessagesRead(widget.otherUser.id);
      _socketService.markMessagesViewed(widget.otherUser.id);
      unawaited(_clearConversationNotificationStateForCurrentChat());
      debugPrint(
        'ðŸ“§ Sent read confirmations for ${unreadMessageIds.length} messages to update web clients',
      );
    }
  }

  /// Sync delivery and read statuses for messages loaded from history.
  Future<void> _syncLoadedMessageStatuses(List<Message> loadedMessages) async {
    if (_isSelfChat) return;
    if (loadedMessages.isEmpty) return;

    final incomingMessages = loadedMessages.where((message) {
      return message.senderId == widget.otherUser.id && !message.isDeleted;
    }).toList();

    if (incomingMessages.isEmpty) return;

    final incomingMessageIds = incomingMessages
        .map((message) => message.id)
        .toSet()
        .toList();

    for (final messageId in incomingMessageIds) {
      _socketService.emit('message_delivered', {'message_id': messageId});
    }

    _socketService.markMessagesRead(widget.otherUser.id);
    _socketService.markMessagesViewed(widget.otherUser.id);
    unawaited(_clearConversationNotificationStateForCurrentChat());

    final latestIncomingMessageId = incomingMessageIds.reduce(math.max);
    await MessageService.markAsRead(
      senderId: widget.otherUser.id,
      lastMessageId: latestIncomingMessageId,
    );

    debugPrint(
      'ðŸ“§ Synced statuses for ${incomingMessageIds.length} loaded messages (including files)',
    );
  }

  void _onFocusChange() {
    // Only update if keyboard visibility actually changed
    final isVisible = _inputFocusNode.hasFocus;
    if (_isKeyboardVisible != isVisible) {
      // Don't trigger rebuilds during focus restoration after app resume
      if (_restoreInputFocusOnResume || _isRestoringInputFocus) {
        _isKeyboardVisible = isVisible;
        return;
      }
      setState(() {
        _isKeyboardVisible = isVisible;
      });
      // The composer follows the keyboard via didChangeMetrics (frame-by-frame),
      // so there's nothing to snap here. When the field loses focus the IME
      // closes and didChangeMetrics drives the inset back to 0.
    }

    if (isVisible) {
      _restoreSavedInputSelection();
    }
  }

  Future<void> _hideSystemKeyboardPreservingFocus() async {
    if (!mounted) return;

    _inputFocusNode.requestFocus();
    _restoreSavedInputSelection();

    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (!mounted) return;

    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } catch (_) {
      // Ignore transient platform timing issues while hiding the IME.
    }
  }

  void _saveCurrentInputSelection() {
    final selection = _messageController.selection;
    if (!selection.isValid) return;
    _savedInputSelection = selection;
  }

  void _restoreSavedInputSelection() {
    final selection = _savedInputSelection;
    if (selection == null) return;

    final textLength = _messageController.text.length;
    final restoredSelection = TextSelection(
      baseOffset: selection.baseOffset.clamp(0, textLength).toInt(),
      extentOffset: selection.extentOffset.clamp(0, textLength).toInt(),
    );

    if (_messageController.selection != restoredSelection) {
      _messageController.selection = restoredSelection;
    }
  }

  /// Paint the conversation on the very first frame when the lobby (or a
  /// previous visit) already warmed it. Everything else here runs behind an
  /// await — reading the user id, opening the room, reading Hive — so without
  /// this the room appears as a spinner and then visibly fills in. The async
  /// path in [_loadCachedMessages] still runs and supersedes this with the full
  /// history; this only removes the empty frames at the start.
  void _seedMessagesFromWarmCache() {
    final currentUserId = _socketService.currentUserId;
    if (currentUserId == null) return;

    final warm = ChatCacheService.peekConversationMessages(
      currentUserId,
      widget.otherUser.id,
    );
    if (warm == null || warm.isEmpty) return;

    _currentUserId = currentUserId;
    _messages = warm.reversed.toList();
    _databaseLoadedMessageIds
      ..clear()
      ..addAll(warm.where((m) => m.id > 0).map((m) => m.id));
    _hydrateReactionsForMessages(_messages);
    _isLoading = false;
    debugPrint(
      '[CHAT] Painted ${_messages.length} messages from warm cache on first frame',
    );
  }

  Future<void> _initialize() async {
    final initResults = await Future.wait<dynamic>([
      StorageService.getUserId(),
      StorageService.getIsAdmin(),
    ]);
    _currentUserId = initResults[0] as int?;
    _currentUserIsAdmin = initResults[1] as bool? ?? false;

    if (widget.initialCallInProgressOnOtherDevice) {
      _callInProgressOnOtherDevice = true;
      _crossDeviceActivePeerId = widget.otherUser.id;
    }

    unawaited(_clearIncomingCallNotificationsForCurrentChat());
    unawaited(
      FirebaseMessagingService.instance.clearConversationNotificationState(
        otherUserId: widget.otherUser.id,
        senderName: widget.otherUser.fullName,
      ),
    );

    // Initialize presence state from widget
    _partnerIsOnline = widget.otherUser.isOnline;
    _partnerStatus = widget.otherUser.status;
    _partnerLastSeen = widget.otherUser.lastSeen;

    // Initialize common phrases API
    _commonPhrasesApi = CommonPhrasesApi(baseUrl: ApiConfig.baseUrl);

    _joinChatRoom();
    _setupRealtimeListeners();

    await _loadCachedMessages();

    // Kick network refresh in background to make room switching feel instant.
    unawaited(_loadMessages());

    // Defer non-critical UI prefs and side data so first paint is fast.
    unawaited(_loadSavedChatColor());
    unawaited(_loadTimestampPreference());
    unawaited(_loadAutoCorrectionPreferences());
    unawaited(_loadStampPreference());
    unawaited(_loadPinnedExcalidrawLinks());
    unawaited(_refreshExcalidrawRoomsUnread());

    // Load common phrases in background
    unawaited(_loadCommonPhrases());
    // Fetch all task-marked messages for this conversation in the background
    // so the task modal shows the full count, not just the loaded page.
    unawaited(_loadConversationTasks());
  }

  Future<void> _clearIncomingCallNotificationsForCurrentChat() async {
    try {
      await _ensureLocalNotificationsReady();
      // Background incoming-call notification uses fixed ID 999.
      await _localNotificationsPlugin.cancel(999);

      // Foreground call notifications use direct-chat hash IDs.
      final directCallNotificationId =
          'direct:${widget.otherUser.id}'.hashCode & 0x7FFFFFFF;
      await _localNotificationsPlugin.cancel(directCallNotificationId);
    } catch (e) {
      debugPrint('Error clearing incoming call notifications: $e');
    }
  }

  Future<void> _clearConversationNotificationStateForCurrentChat() async {
    await FirebaseMessagingService.instance.clearConversationNotificationState(
      otherUserId: widget.otherUser.id,
      senderName: widget.otherUser.fullName,
    );
  }

  /// Load persisted chat color from SharedPreferences
  Future<void> _loadSavedChatColor() async {
    final prefs = await SharedPreferences.getInstance();
    final savedColorHex = prefs.getString('chat_color_${widget.otherUser.id}');
    if (savedColorHex != null && mounted) {
      try {
        final normalizedHex = savedColorHex.replaceAll('#', '').toUpperCase();
        final defaultColor = const Color(0xFF121212);
        const legacyDefaultHexes = {'4C1D95', '1E1E1E'};

        if (legacyDefaultHexes.contains(normalizedHex)) {
          setState(() {
            _headerColor = defaultColor;
            _showResetButton = false;
          });
          await _saveChatColor('#121212');
          return;
        }

        final color = Color(int.parse('FF$normalizedHex', radix: 16));
        setState(() {
          _headerColor = color;
          _showResetButton = color.toARGB32() != defaultColor.toARGB32();
        });
      } catch (e) {
        debugPrint('Error loading saved chat color: $e');
      }
    }
  }

  /// Persist chat color to SharedPreferences
  Future<void> _saveChatColor(String colorHex) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chat_color_${widget.otherUser.id}', colorHex);
  }

  /// Load timestamp visibility preference from SharedPreferences
  Future<void> _loadTimestampPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool('showTimestamps') ?? false;
    final autoTranslateSaved =
        prefs.getBool('autoTranslate_${widget.otherUser.id}') ?? false;
    if (mounted) {
      setState(() {
        _showTimestamps = saved;
        _autoTranslate = autoTranslateSaved;
      });
    }
  }

  /// Toggle timestamp visibility and save preference
  Future<void> _toggleTimestamps() async {
    final newValue = !_showTimestamps;
    setState(() {
      _showTimestamps = newValue;
    });

    // Save to SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showTimestamps', newValue);
  }

  /// Toggle auto-translate and save preference
  Future<void> _toggleAutoTranslate() async {
    final newValue = !_autoTranslate;
    setState(() {
      _autoTranslate = newValue;
    });

    // Save to SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoTranslate_${widget.otherUser.id}', newValue);

    // Emit socket event to notify other user
    _socketService.emit('toggle_translate', {
      'recipient_id': widget.otherUser.id,
      'enabled': newValue,
    });

    // Show feedback notification
    if (mounted) {
      _showTopBanner(
        newValue ? 'Auto-translate enabled' : 'Auto-translate disabled',
        backgroundColor: newValue
            ? const Color(0xFF059669)
            : Colors.grey[700] ?? const Color(0xFF4B5563),
        icon: Icons.translate,
        autoHideAfter: const Duration(seconds: 1),
      );
    }

    // If enabling, translate existing messages
    if (newValue) {
      await _translateExistingMessages();
    }
  }

  Future<void> _loadAutoCorrectionPreferences() async {
    final prefs = await SharedPreferences.getInstance();

    final enabled = prefs.getBool(_autoCorrectionEnabledPrefKey);
    final manualRaw = prefs.getString(_autoCorrectionManualPrefKey);
    final learnedRaw = prefs.getString(_autoCorrectionLearnedPrefKey);

    Map<String, String> parseMap(String? raw) {
      if (raw == null || raw.isEmpty) return {};
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return {};
        final result = <String, String>{};
        decoded.forEach((key, value) {
          final wrong = key.toString().trim().toLowerCase();
          final correct = value.toString().trim();
          if (wrong.isNotEmpty && correct.isNotEmpty) {
            result[wrong] = correct;
          }
        });
        return result;
      } catch (_) {
        return {};
      }
    }

    final manualMap = parseMap(manualRaw);
    final learnedMap = parseMap(learnedRaw);

    if (!mounted) return;

    setState(() {
      if (enabled != null) {
        _autoCorrectionEnabled = enabled;
      }
      if (manualMap.isNotEmpty) {
        _manualAutoCorrectionMappings
          ..clear()
          ..addAll(manualMap);
      }
      if (learnedMap.isNotEmpty) {
        _learnedAutoCorrectionMappings
          ..clear()
          ..addAll(learnedMap);
      }
    });

    debugPrint(
      '[AutoCorrect] Loaded prefs: enabled=$_autoCorrectionEnabled, manual=${_manualAutoCorrectionMappings.length}, learned=${_learnedAutoCorrectionMappings.length}',
    );
  }

  Future<void> _saveAutoCorrectionPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoCorrectionEnabledPrefKey, _autoCorrectionEnabled);
    await prefs.setString(
      _autoCorrectionManualPrefKey,
      jsonEncode(_manualAutoCorrectionMappings),
    );
    await prefs.setString(
      _autoCorrectionLearnedPrefKey,
      jsonEncode(_learnedAutoCorrectionMappings),
    );
  }

  Future<void> _loadStampPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(
      '${_stampEnabledPrefKey}_${widget.otherUser.id}',
    );
    if (!mounted || saved == null) return;

    setState(() {
      _stampEnabled = saved;
    });

    if (_stampEnabled) {
      _seedStampPrefixInInput();
    }
  }

  Future<void> _saveStampPreference() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
      '${_stampEnabledPrefKey}_${widget.otherUser.id}',
      _stampEnabled,
    );
  }

  String get _stampMentionTag {
    final username = widget.otherUser.username.trim();
    if (username.isEmpty) {
      return '@${widget.otherUser.fullName.trim().replaceAll(' ', '').toLowerCase()}';
    }
    return '@$username';
  }

  bool _hasStampPrefix(String text) {
    final trimmed = text.trim();
    final tag = _stampMentionTag.toLowerCase();
    final lower = trimmed.toLowerCase();
    if (lower == tag) return true;
    return RegExp(
      '(^|\\s)${RegExp.escape(tag)}(?=\\s|\\\\\$)',
      caseSensitive: false,
    ).hasMatch(lower);
  }

  bool _isStampOnlyDraft(String text) {
    if (!_stampEnabled) return false;
    return text.trim().toLowerCase() == _stampMentionTag.toLowerCase();
  }

  String _withStampPrefix(String text) {
    final trimmed = text.trim();
    if (!_stampEnabled) return trimmed;
    if (trimmed.isEmpty) return _stampMentionTag;
    if (_hasStampPrefix(trimmed)) return trimmed;
    return '$trimmed $_stampMentionTag';
  }

  String _removeStampTagFromText(String text) {
    final pattern = RegExp(
      '(^|\\s)${RegExp.escape(_stampMentionTag)}(?=\\s|\\\\\$)',
      caseSensitive: false,
    );

    final withoutFirst = text.replaceFirstMapped(pattern, (match) {
      return match.group(1) ?? '';
    });

    return withoutFirst.replaceAll(RegExp(r'\s{2,}'), ' ').trimLeft();
  }

  void _seedStampPrefixInInput() {
    if (!_stampEnabled || !mounted) return;

    final current = _messageController.text;
    if (_hasStampPrefix(current)) return;

    final stamped = current.trim().isEmpty
        ? '$_stampMentionTag '
        : '${current.trimRight()} $_stampMentionTag';
    final normalized = _normalizeTextForEmojiCompatibility(stamped);
    final selection = TextSelection.collapsed(offset: normalized.length);
    _messageController.value = TextEditingValue(
      text: normalized,
      selection: selection,
      composing: TextRange.empty,
    );
    _savedInputSelection = selection;
  }

  void _showTopBanner(
    String message, {
    Color backgroundColor = const Color(0xFF059669),
    IconData icon = Icons.check_circle_outline,
    Duration? autoHideAfter = const Duration(seconds: 2),
    bool showDismiss = true,
  }) {
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.hideCurrentMaterialBanner();
    messenger.showMaterialBanner(
      MaterialBanner(
        content: Text(message),
        leading: Icon(icon, color: Colors.white),
        backgroundColor: backgroundColor,
        contentTextStyle: const TextStyle(color: Colors.white),
        actions: [
          TextButton(
            onPressed: messenger.hideCurrentMaterialBanner,
            child: Text(
              showDismiss ? 'DISMISS' : 'HIDE',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (autoHideAfter != null) {
      Timer(autoHideAfter, () {
        if (mounted) {
          messenger.hideCurrentMaterialBanner();
        }
      });
    }
  }

  void _showTopSnackBar(SnackBar snackBar) {
    if (!mounted) return;

    _topSnackBarTimer?.cancel();
    _topSnackBarEntry?.remove();
    _topSnackBarEntry = null;

    final overlay = Overlay.of(context, rootOverlay: true);

    _topSnackBarEntry = OverlayEntry(
      builder: (overlayContext) {
        final topInset = MediaQuery.of(overlayContext).padding.top;

        return Positioned(
          top: topInset + 8,
          left: 14,
          right: 14,
          child: Material(
            color: Colors.transparent,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              builder: (context, value, child) {
                return Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, -16 * (1 - value)),
                    child: child,
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: snackBar.backgroundColor ?? const Color(0xFF323232),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black45,
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: DefaultTextStyle(
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        child: snackBar.content,
                      ),
                    ),
                    if (snackBar.action != null)
                      TextButton(
                        onPressed: () {
                          _topSnackBarEntry?.remove();
                          _topSnackBarEntry = null;
                          snackBar.action!.onPressed();
                        },
                        child: Text(
                          snackBar.action!.label,
                          style: TextStyle(
                            color: snackBar.action!.textColor ?? Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
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

    overlay.insert(_topSnackBarEntry!);

    final autoHide = snackBar.duration;
    if (autoHide > Duration.zero) {
      _topSnackBarTimer = Timer(autoHide, () {
        if (mounted) {
          _topSnackBarEntry?.remove();
          _topSnackBarEntry = null;
        }
      });
    }
  }

  void _hideTopBanner() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.hideCurrentMaterialBanner();
  }

  /// Translate all existing messages for this conversation
  Future<void> _translateExistingMessages() async {
    if (!mounted) return;

    final targetLang = await TranslationService.getUserLanguage();
    debugPrint('Translating messages to: $targetLang');

    // Get current messages from cache
    final currentUserId = await StorageService.getUserId();
    if (currentUserId == null) return;

    final messages = await ChatCacheService.loadConversationMessages(
      currentUserId,
      widget.otherUser.id,
    );

    if (messages.isEmpty) return;

    // Translate each message
    final translatedMessages = <Message>[];
    for (final message in messages) {
      if (message.content.isNotEmpty && !message.isDeleted) {
        final translated = await TranslationService.translateMessageObject(
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
    await ChatCacheService.saveConversationMessages(
      currentUserId,
      widget.otherUser.id,
      translatedMessages.reversed.toList(),
    );

    // Refresh the UI
    if (mounted) {
      setState(() {
        _messages = translatedMessages;
        _databaseLoadedMessageIds
          ..clear()
          ..addAll(
            translatedMessages
                .where((message) => message.id > 0)
                .map((message) => message.id),
          );
      });
    }
  }

  void _joinChatRoom() {
    // Test connection status first
    _socketService.testConnection();

    // Try to join chat room
    _socketService.joinChat(widget.otherUser.id);
  }

  void _setupRealtimeListeners() {
    const key = 'chat';

    // Auto-retry any queued media uploads when the socket reconnects
    // (covers both wifi-restored and app-resume scenarios).
    _socketService.addListener('reconnected', key, () {
      debugPrint('🔄 Socket reconnected — retrying queued uploads');
      unawaited(MediaUploadRetryService().retryAll());
    });

    // Persistent call-log entries (declined / missed / answered). Unlike normal
    // messages these must render in BOTH directions (the caller sees their own
    // outgoing "missed/declined" entry too), so we can't reuse the
    // messageReceived path which drops own-sender messages.
    _socketService.addListener('callLogMessage', key, (
      Map<String, dynamic> data,
    ) async {
      final Message callMsg;
      try {
        callMsg = Message.fromJson(data);
      } catch (e) {
        debugPrint('📞 Failed to parse call log message: $e');
        return;
      }

      final isForThisChat =
          callMsg.senderId == widget.otherUser.id ||
          callMsg.recipientId == widget.otherUser.id;
      if (!isForThisChat) return;

      final isSelfChat = widget.otherUser.id == _currentUserId;
      if (isSelfChat &&
          (callMsg.senderId != _currentUserId ||
              callMsg.recipientId != _currentUserId)) {
        return;
      }

      if (_messages.any((m) => m.id == callMsg.id)) return;

      setState(() {
        _messages.insert(0, callMsg);
        if (!_isSelfChat &&
            !_isAtBottom &&
            callMsg.senderId == widget.otherUser.id) {
          _unreadCount++;
        }
      });

      if (_currentUserId != null) {
        await ChatCacheService.addMessageToCache(
          _currentUserId!,
          widget.otherUser.id,
          callMsg,
        );
      }
    });

    // Listen for new messages (from other user)
    _socketService.addListener('messageReceived', key, (
      Map<String, dynamic> data,
    ) async {
      final incomingMessage = _applyPendingLiveTaskState(
        Message.fromJson(data),
      );

      // Self-chat guard: when chatting with yourself, only accept messages
      // where both sender AND recipient are the current user.
      final isSelfChat = widget.otherUser.id == _currentUserId;
      if (isSelfChat) {
        if (incomingMessage.senderId != _currentUserId ||
            incomingMessage.recipientId != _currentUserId) {
          return;
        }
      }

      // Only add if it's from the current conversation
      if (incomingMessage.senderId == widget.otherUser.id ||
          incomingMessage.recipientId == widget.otherUser.id) {
        // Skip if this is our own message (we already have it optimistically)
        if (incomingMessage.senderId == _currentUserId) return;

        // Skip duplicate messages (e.g. socket reconnect replays)
        if (_messages.any((m) => m.id == incomingMessage.id)) {
          debugPrint('💬 Skipping duplicate message: ${incomingMessage.id}');
          return;
        }

        // Always clear typing indicator when a real message arrives
        _typingHideTimer?.cancel();

        setState(() {
          _messages.insert(0, incomingMessage);
          // Clear typing preview whenever a message from partner arrives
          _otherUserTyping = false;
          _typingPreview = '';

          // Increment unread count if not at bottom (for incoming messages)
          if (!_isSelfChat &&
              !_isAtBottom &&
              incomingMessage.senderId == widget.otherUser.id) {
            _unreadCount++;
          }
        });

        // Auto-translate incoming message if enabled and it's a text message from the other user
        if (_autoTranslate &&
            incomingMessage.senderId == widget.otherUser.id &&
            incomingMessage.messageType == 'text' &&
            incomingMessage.content.isNotEmpty) {
          _autoTranslateMessage(incomingMessage);
        }

        // Save to cache for offline access
        if (_currentUserId != null) {
          await ChatCacheService.addMessageToCache(
            _currentUserId!,
            widget.otherUser.id,
            incomingMessage,
          );
          debugPrint('ðŸ’¾ Cached incoming message ${incomingMessage.id}');
          // Prefetch any media attached to the message so it plays
          // back offline later without needing the network.
          unawaited(
            MediaPreloadService.instance.prefetchMessages([incomingMessage]),
          );
        }

        // Play message sound for incoming messages
        if (incomingMessage.senderId == widget.otherUser.id) {
          try {
            _audioPlayer.play(AssetSource('sounds/splat2.m4a'));
          } catch (e) {
            debugPrint('Error playing message sound: $e');
          }
        }

        // Mark as read whenever chat is open and message is from partner.
        // Only auto-scroll if user is already at bottom to avoid interrupting reading
        if (incomingMessage.senderId == widget.otherUser.id) {
          if (_canAutoMarkConversationAsSeen) {
            _socketService.markMessagesRead(widget.otherUser.id);
            _socketService.markMessagesViewed(widget.otherUser.id);
            unawaited(_clearConversationNotificationStateForCurrentChat());
            debugPrint(
              'ðŸ“§ Marked message ${incomingMessage.id} as seen (chat is visible)',
            );
          } else {
            debugPrint(
              'ðŸ“§ Skipped auto-seen for ${incomingMessage.id} (app not foreground/active chat)',
            );
          }

          // Only auto-scroll if user is at bottom, otherwise just show unread badge
          if (_isAtBottom) {
            _scrollToBottom();
          }
        }
      }
    });

    // Listen for message_sent (echoes our own messages from other devices)
    _socketService.addListener('messageSent', key, (
      Map<String, dynamic> data,
    ) async {
      final recipientId = _toInt(data['recipient_id']);
      // Only process if this is for the current conversation
      if (recipientId == widget.otherUser.id) {
        final message = _applyPendingLiveTaskState(Message.fromJson(data));
        final dedupKey =
            '${message.senderId}:${message.recipientId}:${message.content}';
        final shouldMarkAsTask = _consumePendingTaskIntent(dedupKey);
        final uiMessage = shouldMarkAsTask
            ? _copyMessageWithTaskState(
                message,
                isTask: true,
                taskCreatedAt:
                    message.taskCreatedAt ?? DateTime.now().toIso8601String(),
                taskCompletedAt: null,
              )
            : message;

        if (_pendingMessageKeys.contains(dedupKey)) {
          // This is the server echo of our optimistic message â€” replace it with real data
          _pendingMessageKeys.remove(dedupKey);
          setState(() {
            final index = _messages.indexWhere(
              (m) =>
                  m.senderId == message.senderId &&
                  m.content == message.content &&
                  m.status == 'sending',
            );
            if (index != -1) {
              _messages[index] = uiMessage;
            }
          });
          debugPrint(
            'ðŸ“¤ Replaced optimistic message with server data (id: ${message.id})',
          );
          if (shouldMarkAsTask) {
            _socketService.addTask(message.id);
          }
          await _persistConversationCacheSnapshot();
        } else {
          // Check if message already exists (by ID)
          final alreadyExists = _messages.any((m) => m.id == message.id);
          if (!alreadyExists) {
            // Restart-safe reconciliation: a text queued offline then re-sent on
            // reconnect echoes back here, but after an app restart the in-memory
            // _pendingMessageKeys set is empty so the dedup branch above misses.
            // Replace any lingering optimistic bubble (same sender+content still
            // in 'sending') instead of inserting a duplicate.
            final pendingIndex = _messages.indexWhere(
              (m) =>
                  m.senderId == message.senderId &&
                  m.content == message.content &&
                  m.status == 'sending',
            );
            if (pendingIndex != -1) {
              setState(() {
                _messages[pendingIndex] = uiMessage;
              });
              debugPrint(
                'ðŸ“¤ Reconciled restart-pending text message via echo',
              );
            } else {
              setState(() {
                _messages.insert(0, uiMessage);
              });
              // Only auto-scroll if user is at bottom, otherwise just show unread badge
              if (_isAtBottom) {
                _scrollToBottom();
              }
              debugPrint('ðŸ“¤ Cross-device: added own sent message to chat');
            }
          }
          if (shouldMarkAsTask) {
            _socketService.addTask(message.id);
          }
          await _persistConversationCacheSnapshot();
        }
      }
    });

    // Listen for typing indicator (includes live typing preview)
    _socketService.addListener('userTyping', key, (Map<String, dynamic> data) {
      if (data['user_id'] == widget.otherUser.id) {
        if (_isSelfChat) return;
        setState(() {
          final isTyping = data['is_typing'] ?? false;
          final message = data['message'] as String? ?? '';

          if (isTyping) {
            _otherUserTyping = true;
            _hideCommonPhrases = true;
            if (message.isNotEmpty) {
              _typingPreview = message;
            }
            // Auto-hide after 6 s in case typing_stop is never received
            _typingHideTimer?.cancel();
            _typingHideTimer = Timer(const Duration(seconds: 6), () {
              if (mounted) {
                setState(() {
                  _otherUserTyping = false;
                  _typingPreview = '';
                  _syncCommonPhrasesVisibility();
                });
              }
            });
          } else {
            _typingHideTimer?.cancel();
            _otherUserTyping = false;
            _typingPreview = '';
            _syncCommonPhrasesVisibility();
          }
        });
      }
    });

    // Listen for live typing preview (separate event if used)
    _socketService.addListener('typingUpdate', key, (
      Map<String, dynamic> data,
    ) {
      if (data['user_id'] == widget.otherUser.id ||
          data['sender_id'] == widget.otherUser.id) {
        if (_isSelfChat) return;
        final preview = data['message'] ?? '';
        setState(() {
          _otherUserTyping = preview.isNotEmpty;
          _hideCommonPhrases = preview.isNotEmpty;
          _typingPreview = preview;
        });
        // Reset the auto-hide timer on every preview update
        _typingHideTimer?.cancel();
        if (preview.isNotEmpty) {
          _typingHideTimer = Timer(const Duration(seconds: 6), () {
            if (mounted) {
              setState(() {
                _otherUserTyping = false;
                _typingPreview = '';
                _syncCommonPhrasesVisibility();
              });
            }
          });
        }
      }
    });

    // Listen for joined chat confirmation
    _socketService.addListener('joinedChat', key, (Map<String, dynamic> data) {
      debugPrint('Successfully joined chat with ${widget.otherUser.fullName}');
    });

    // Listen for doorbell rings (from other user OR from self on another device)
    _socketService.addListener('doorbellRing', key, (
      Map<String, dynamic> data,
    ) {
      final senderId = data['sender_id'] as int?;
      final recipientId = data['recipient_id'] as int?;
      if (senderId == widget.otherUser.id) {
        _handleIncomingDoorbell(data);
      } else if (senderId == _currentUserId &&
          recipientId == widget.otherUser.id) {
        if (_localDoorbellPending) {
          // This is the echo from OUR ring â€” ignore, we already showed it optimistically
          _localDoorbellPending = false;
        } else {
          // Cross-device: our other device rang the doorbell â€” show outgoing system message
          _handleOutgoingDoorbellSync(data);
        }
      }
    });

    // Listen for color change events (from other user OR from self on another device)
    _socketService.addListener('colorChanged', key, (
      Map<String, dynamic> data,
    ) {
      final senderId = data['sender_id'] != null
          ? int.tryParse(data['sender_id'].toString())
          : null;
      final recipientId = data['recipient_id'] != null
          ? int.tryParse(data['recipient_id'].toString())
          : null;
      if (senderId == widget.otherUser.id) {
        _handleColorChange(data);
      } else if (senderId == _currentUserId &&
          recipientId == widget.otherUser.id) {
        _handleColorChange(data);
      }
    });

    // Listen for color reset events (from other user OR from self on another device)
    _socketService.addListener('colorReset', key, (Map<String, dynamic> data) {
      final senderId = data['sender_id'] != null
          ? int.tryParse(data['sender_id'].toString())
          : null;
      final recipientId = data['recipient_id'] != null
          ? int.tryParse(data['recipient_id'].toString())
          : null;
      if (senderId == widget.otherUser.id) {
        _handleColorReset(data);
      } else if (senderId == _currentUserId &&
          recipientId == widget.otherUser.id) {
        if (_localColorResetPending) {
          // This is the echo from OUR reset â€” ignore, we already showed it optimistically
          _localColorResetPending = false;
        } else {
          // Cross-device: our other device reset the color
          _handleColorReset(data);
        }
      }
    });

    // Listen for all messages deleted event
    _socketService.addListener('allMessagesDeleted', key, (
      Map<String, dynamic> data,
    ) {
      _handleAllMessagesDeleted(data);
    });

    // Listen for single message deleted event
    _socketService.addListener('messageDeleted', key, (
      Map<String, dynamic> data,
    ) {
      _handleMessageDeleted(data);
    });

    // Listen for message edited event
    _socketService.addListener('messageEdited', key, (
      Map<String, dynamic> data,
    ) {
      _handleMessageEdited(data);
    });

    // Listen for task added event
    _socketService.addListener('taskAdded', key, (Map<String, dynamic> data) {
      _handleTaskAdded(data);
    });

    // Listen for task completed event
    _socketService.addListener('taskCompleted', key, (
      Map<String, dynamic> data,
    ) {
      _handleTaskCompleted(data);
    });

    // Listen for task uncompleted event
    _socketService.addListener('taskUncompleted', key, (
      Map<String, dynamic> data,
    ) {
      _handleTaskUncompleted(data);
    });

    // Listen for excalidraw pinned event
    _socketService.addListener('excalidrawPinned', key, (
      Map<String, dynamic> data,
    ) {
      _handleExcalidrawPinned(data);
    });

    // A whiteboard was created, renamed or deleted by someone in this chat.
    _socketService.addListener('excalidrawRoomChanged', key, (
      Map<String, dynamic> data,
    ) {
      _handleExcalidrawRoomChanged(data);
    });

    // Listen for excalidraw unpinned event
    _socketService.addListener('excalidrawUnpinned', key, (
      Map<String, dynamic> data,
    ) {
      _handleExcalidrawUnpinned(data);
    });

    // Listen for message status updates (delivered/seen)
    _socketService.addListener('messageStatusUpdated', key, (
      Map<String, dynamic> data,
    ) {
      _handleMessageStatusUpdate(data);
    });

    // Listen for messages read notifications
    _socketService.addListener('messagesRead', key, (
      Map<String, dynamic> data,
    ) {
      _handleMessagesRead(data);
    });

    // This conversation was read (or replied to) on another device signed in as
    // us — the server already marked it read, so drop the local "new messages"
    // counter instead of leaving a badge for messages we've demonstrably seen.
    _socketService.addListener('unreadCleared', key, (
      Map<String, dynamic> data,
    ) {
      final peerId = _toInt(data['peer_id']);
      if (peerId != widget.otherUser.id || !mounted) return;
      if (_unreadCount == 0) return;
      setState(() => _unreadCount = 0);
      debugPrint(
        '[CHAT] Cleared in-chat unread counter for ${widget.otherUser.id} (read on another device)',
      );
    });

    // Listen for individual message delivery confirmations
    _socketService.addListener('messageDelivered', key, (
      Map<String, dynamic> data,
    ) {
      final messageId = _toInt(data['message_id']);
      if (messageId != null) {
        _handleMessageStatusUpdate({
          'message_id': messageId,
          'status': 'delivered',
          'delivered_at':
              data['delivered_at'] ?? DateTime.now().toIso8601String(),
        });
      }
    });

    // Listen for individual message read confirmations
    _socketService.addListener('messageRead', key, (Map<String, dynamic> data) {
      final messageId = _toInt(data['message_id']);
      if (messageId != null) {
        _handleMessageStatusUpdate({
          'message_id': messageId,
          'status': 'seen',
          'read_at': data['read_at'] ?? DateTime.now().toIso8601String(),
        });
      }
    });

    // Listen for file messages from web (handles single and batch media)
    _socketService.addListener('fileReceived', key, (
      Map<String, dynamic> data,
    ) {
      debugPrint('File message received in chat: $data');
      final senderId = data['sender_id'] as int?;
      final recipientId = data['recipient_id'] as int?;

      // Process if from conversation partner OR from current user (cross-device sync)
      final isFromPartner = senderId == widget.otherUser.id;
      final isFromSelfToPartner =
          senderId == _currentUserId && recipientId == widget.otherUser.id;

      if (isFromPartner || isFromSelfToPartner) {
        final now = DateTime.now();
        final timestampMs = data['timestamp_ms'] ?? now.millisecondsSinceEpoch;

        // Extract message ID — backend may send as 'id' or 'message_id'
        final messageId = data['id'] ?? data['message_id'];

        // Check for duplicates: prevents double-insertion when batch uploads
        // emit rapid file_received events or cross-device sync echoes arrive
        if (messageId != null && _messages.any((m) => m.id == messageId)) {
          debugPrint(' Skipping duplicate file message: $messageId');
          return;
        }

        // Detect audio files as voice messages
        final fileType = (data['file_type'] as String?) ?? '';
        final msgType = (data['message_type'] as String?) ?? '';
        String messageType;
        if (fileType.startsWith('audio/') ||
            msgType == 'voice' ||
            msgType == 'audio') {
          messageType = 'voice';
        } else if (fileType.startsWith('image/')) {
          messageType = 'image';
        } else if (fileType.startsWith('video/')) {
          messageType = 'video';
        } else {
          messageType = 'file';
        }
        // Build full URL if it's a relative path
        final rawFileUrl = data['file_url'] as String? ?? '';
        final fullFileUrl = rawFileUrl.startsWith('http')
            ? rawFileUrl
            : '${ApiConfig.baseUrl}$rawFileUrl';

        final content = (data['file_name'] as String?)?.isNotEmpty == true
            ? data['file_name'] as String
            : 'File';

        // Check if there's a pending optimistic message from this sender
        // that should be replaced with the server-confirmed message.
        // Use loose matching to handle type mismatches from the socket payload.
        final pendingIndex = _messages.indexWhere(
          (m) =>
              m.status == 'pending' &&
              m.messageType == messageType &&
              '${m.senderId}' == '${senderId ?? 0}' &&
              (now.millisecondsSinceEpoch - m.timestampMs).abs() < 60000,
        );

        // Resolve caption — priority order:
        //  1. Optimistic message caption (what the user typed locally)
        //  2. Explicit 'caption' field in socket payload
        //  3. Caption embedded in HTML content as <div class="file-caption">
        final pendingCaption = pendingIndex != -1
            ? _messages[pendingIndex].caption
            : null;
        final rawCaption = data['caption'] as String?;
        final rawContent = data['content'] as String? ?? '';
        String? htmlCaption;
        if (rawContent.contains('file-caption')) {
          final captionRegex = RegExp(
            '<div[^>]*class=[\'"]file-caption[\'"][^>]*>(.*?)</div>',
            caseSensitive: false,
            dotAll: true,
          );
          final cm = captionRegex.firstMatch(rawContent);
          if (cm != null) {
            String c = cm.group(1) ?? '';
            c = c.replaceAll(RegExp(r'<[^>]*>'), '').trim();
            c = c
                .replaceAll('&lt;', '<')
                .replaceAll('&gt;', '>')
                .replaceAll('&amp;', '&')
                .replaceAll('&quot;', '"')
                .replaceAll('&#39;', "'")
                .replaceAll('&nbsp;', ' ');
            if (c.isNotEmpty) htmlCaption = c;
          }
        }
        final resolvedCaption = pendingCaption?.isNotEmpty == true
            ? pendingCaption
            : (htmlCaption?.isNotEmpty == true
                  ? htmlCaption
                  : (rawCaption?.isNotEmpty == true ? rawCaption : null));

        // Create a message from the file data
        final message = Message(
          id: messageId ?? timestampMs,
          senderId: senderId ?? 0,
          recipientId: recipientId ?? _currentUserId ?? 0,
          content: content,
          messageType: messageType,
          timestamp: data['timestamp'] as String? ?? now.toIso8601String(),
          timestampMs: timestampMs,
          isRead: false,
          status: isFromPartner ? 'delivered' : 'sent',
          threadId: data['thread_id'] as String? ?? '',
          reactions: (data['reactions'] as Map<String, dynamic>?) ?? {},
          isDeleted: false,
          fileUrl: fullFileUrl,
          fileName: data['file_name'],
          fileType: data['file_type'],
          fileSize: data['file_size'],
          caption: resolvedCaption,
        );

        setState(() {
          if (pendingIndex != -1) {
            // Replace the pending optimistic message with the confirmed one
            debugPrint(
              ' Replacing pending optimistic message at index $pendingIndex with server-confirmed message',
            );
            _messages[pendingIndex] = message;
          } else {
            // Insert as new message
            _messages.insert(0, message);
          }
        });

        // Play message sound only for incoming messages from partner
        if (isFromPartner) {
          try {
            _audioPlayer.play(AssetSource('sounds/splat2.m4a'));
          } catch (e) {
            debugPrint('Error playing message sound: $e');
          }

          if (_canAutoMarkConversationAsSeen) {
            _socketService.markMessagesRead(widget.otherUser.id);
            _socketService.markMessagesViewed(widget.otherUser.id);
            unawaited(_clearConversationNotificationStateForCurrentChat());
            debugPrint(
              'ðŸ“§ Marked file message ${message.id} as delivered/seen (chat is visible)',
            );
          } else {
            debugPrint(
              'ðŸ“§ Skipped auto-seen for file ${message.id} (app not foreground/active chat)',
            );
          }
        } else {
          debugPrint(' Cross-device: added own sent file to chat');
        }

        // Only auto-scroll if user is at bottom, otherwise just show unread badge
        if (_isAtBottom) {
          _scrollToBottom();
        }
      }
    });

    // Listen for voice messages from web
    _socketService.addListener('voiceMessageReceived', key, (
      Map<String, dynamic> data,
    ) {
      debugPrint('ðŸŽ¤ Voice message received in chat: $data');
      final senderId = data['sender_id'] as int?;
      final recipientId = data['recipient_id'] as int?;

      // Process if from conversation partner OR from current user (cross-device sync)
      final isFromPartner = senderId == widget.otherUser.id;
      final isFromSelfToPartner =
          senderId == _currentUserId && recipientId == widget.otherUser.id;
      debugPrint(
        'ðŸŽ¤ Voice filter: senderId=$senderId, recipientId=$recipientId, _currentUserId=$_currentUserId, otherUserId=${widget.otherUser.id}, isFromPartner=$isFromPartner, isFromSelfToPartner=$isFromSelfToPartner',
      );

      if (isFromPartner || isFromSelfToPartner) {
        final now = DateTime.now();
        final timestampMs = data['timestamp_ms'] ?? now.millisecondsSinceEpoch;
        final audioUrl = data['audio_url'] as String?;
        if (audioUrl == null || audioUrl.isEmpty) {
          debugPrint('ðŸŽ¤ Voice message has no audio_url, ignoring');
          return;
        }

        // Check for duplicates (cross-device sync may send same message twice)
        final messageId = data['message_id'];
        if (messageId != null && _messages.any((m) => m.id == messageId)) {
          debugPrint('ðŸŽ¤ Skipping duplicate voice message: $messageId');
          return;
        }

        // Build full URL if it's a relative path
        final fullAudioUrl = audioUrl.startsWith('http')
            ? audioUrl
            : '${ApiConfig.baseUrl}$audioUrl';
        final message = Message(
          id: messageId ?? timestampMs,
          senderId: senderId ?? 0,
          recipientId: recipientId ?? _currentUserId ?? 0,
          content: 'Voice message',
          messageType: 'voice',
          timestamp: now.toIso8601String(),
          timestampMs: timestampMs,
          isRead: false,
          status: 'delivered',
          threadId: '',
          reactions: {},
          isDeleted: false,
          fileUrl: fullAudioUrl,
          fileName: 'voice_message.wav',
          fileType: 'audio/wav',
        );

        setState(() {
          _messages.insert(0, message);
        });

        // Play message sound only for incoming messages from partner
        if (isFromPartner) {
          try {
            _audioPlayer.play(AssetSource('sounds/splat2.m4a'));
          } catch (e) {
            debugPrint('Error playing message sound: $e');
          }

          if (_canAutoMarkConversationAsSeen) {
            _socketService.markMessagesRead(widget.otherUser.id);
            _socketService.markMessagesViewed(widget.otherUser.id);
            unawaited(_clearConversationNotificationStateForCurrentChat());
            debugPrint(
              'ðŸ“§ Marked voice message ${message.id} as delivered/seen (chat is visible)',
            );
          } else {
            debugPrint(
              'ðŸ“§ Skipped auto-seen for voice ${message.id} (app not foreground/active chat)',
            );
          }
        } else {
          debugPrint('ðŸŽ¤ Cross-device: added own sent voice message to chat');
        }

        // Only auto-scroll if user is at bottom, otherwise just show unread badge
        if (_isAtBottom) {
          _scrollToBottom();
        }
      }
    });

    // Listen for incoming calls (while in chat)
    // NOTE: We only listen to 'incomingCall' here (not 'crossRoomCallOffer') because the
    // server sends BOTH events to the callee for the same call. 'incomingCall' contains
    // full call data (call_id, call_room_id) and is sufficient for mobile clients.
    // Listening to both would open two modals for the same call.
    _socketService.addListener('incomingCall', key, (
      Map<String, dynamic> data,
    ) {
      _handleIncomingCallInChat(data);
    });

    // If this account answers on another device, suppress/close the local
    // incoming modal and show a short header indicator.
    _socketService.addListener('callAnswered', key, (
      Map<String, dynamic> data,
    ) {
      if (!_isCallAnsweredByCurrentUserForActiveChat(data)) return;
      if (PresenceService().isCallInProgress) return;

      final matchesActiveIncoming = _isCallAnsweredForActiveIncomingModal(data);
      if (!matchesActiveIncoming && !PresenceService().isHandlingIncomingCall) {
        return;
      }

      _dismissIncomingCallModalIfOpen();
      PresenceService().isHandlingIncomingCall = false;
      _showCallInProgressOnOtherDeviceIndicator();
      _clearIncomingCallNotificationsForPeer(
        callRoomId:
            data['call_room_id']?.toString() ?? data['room']?.toString(),
      );
    });

    // Canonical cross-device call state for persistent indicator syncing.
    _socketService.addListener('callSessionState', key, (
      Map<String, dynamic> data,
    ) {
      _handleCallSessionStateForChat(data);
    });

    // Primary cross-device offer sync: if this account accepted on another
    // session, close the local incoming modal immediately.
    _socketService.addListener('callOfferStateSync', key, (
      Map<String, dynamic> data,
    ) {
      if (!_isAcceptedOnOtherDeviceForActiveIncoming(data)) return;
      _dismissIncomingCallModalIfOpen();
      PresenceService().isHandlingIncomingCall = false;
      _showCallInProgressOnOtherDeviceIndicator();
      _clearIncomingCallNotificationsForPeer(
        callRoomId:
            data['call_room_id']?.toString() ?? data['room']?.toString(),
      );
    });

    // FALLBACK: Also listen for crossRoomCallOffer in case backend only sends this event
    // This handles cases where web clients call mobile and backend doesn't send 'incomingCall'
    _socketService.addListener('crossRoomCallOffer', key, (
      Map<String, dynamic> data,
    ) {
      debugPrint(
        'ðŸ“² Fallback: Received crossRoomCallOffer in chat, converting to incomingCall format',
      );
      debugPrint('ðŸ“² Original crossRoomCallOffer data: $data');

      // Convert crossRoomCallOffer format to incomingCall format
      // Note: crossRoomCallOffer uses 'caller_id' and 'caller_username', not 'callerId' and 'callerName'
      final convertedData = {
        'id': DateTime.now().millisecondsSinceEpoch, // Generate call ID
        'call_room_id': data['room'] as String?,
        'call_type': data['call_type'] as String? ?? 'video',
        'caller': {
          'id': data['caller_id'] as int?,
          'username': data['caller_username'] as String? ?? 'Unknown',
          'full_name': data['caller_username'] as String? ?? 'Unknown',
        },
      };

      debugPrint('ðŸ“² Converted to incomingCall format: $convertedData');
      _handleIncomingCallInChat(convertedData);
    });

    // Listen for reaction updates (multi-reaction: user can have multiple different emojis)
    _socketService.addListener('reactionUpdated', key, (
      Map<String, dynamic> data,
    ) {
      debugPrint('ðŸ‘ Reaction updated received: $data');
      final messageId = data['message_id'] as int?;
      final reactorId = data['user_id']?.toString() ?? '';
      final reaction = data['reaction'] as String?;

      if (messageId != null &&
          reaction != null &&
          reaction.isNotEmpty &&
          reactorId.isNotEmpty) {
        setState(() {
          _messageReactions.putIfAbsent(messageId, () => {});
          // Simply add user to the target reaction (don't remove from others)
          _messageReactions[messageId]!.putIfAbsent(reaction, () => {});
          _messageReactions[messageId]![reaction]!.add(reactorId);
        });
      }
    });

    _socketService.addListener('reactionCleared', key, (
      Map<String, dynamic> data,
    ) {
      debugPrint('âŒ Reaction cleared received: $data');
      final messageId = data['message_id'] as int?;
      final reactorId = data['user_id']?.toString() ?? '';
      final reaction = data['reaction'] as String?;

      if (messageId != null && reactorId.isNotEmpty) {
        setState(() {
          if (_messageReactions.containsKey(messageId)) {
            if (reaction != null && reaction.isNotEmpty) {
              // Remove user from only the specific reaction emoji
              _messageReactions[messageId]![reaction]?.remove(reactorId);
              if (_messageReactions[messageId]![reaction]?.isEmpty ?? false) {
                _messageReactions[messageId]!.remove(reaction);
              }
            } else {
              // Legacy: no specific reaction provided, remove from all
              _messageReactions[messageId]!.forEach((emoji, users) {
                users.remove(reactorId);
              });
              _messageReactions[messageId]!.removeWhere(
                (key, value) => value.isEmpty,
              );
            }

            if (_messageReactions[messageId]!.isEmpty) {
              _messageReactions.remove(messageId);
            }
          }
        });
      }
    });

    // Listen for presence updates (status changes)
    _socketService.addListener('presenceUpdate', key, (
      Map<String, dynamic> data,
    ) {
      debugPrint('ðŸ‘¤ Presence update in chat: $data');
      final userId = data['user_id'] as int?;
      final status = data['status'] as String?;
      final isOnline = data['is_online'] as bool?;
      final timestamp = data['timestamp'] as String?;

      // Only update if this is for our chat partner
      if (userId == widget.otherUser.id && status != null) {
        setState(() {
          _partnerIsOnline = isOnline ?? (status == 'online');
          _partnerStatus = _partnerIsOnline ? 'online' : status;
          if (timestamp != null) {
            _partnerLastSeen = timestamp;
          }
        });
      }
    });

    // â”€â”€ Call summary system messages â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // Show an in-chat pill when a call ends, is missed, or is declined.
    // Only insert if the event involves the person we are currently chatting with.
    _socketService.addListener('call_ended', key, (Map<String, dynamic> data) {
      final callerId = data['caller_id'] as int?;
      final calleeId = data['callee_id'] as int?;
      if (callerId == null || calleeId == null) return;
      if (callerId != widget.otherUser.id && calleeId != widget.otherUser.id) {
        return;
      }
      // Format duration if available (duration is stored in seconds by the server)
      final rawDuration = data['duration'];
      String durationStr = '';
      if (rawDuration != null) {
        final secs = (rawDuration is num
            ? rawDuration.toInt()
            : int.tryParse(rawDuration.toString()) ?? 0);
        final m = (secs ~/ 60).toString().padLeft(2, '0');
        final s = (secs % 60).toString().padLeft(2, '0');
        durationStr = ' Â· $m:$s';
      }
      final callType = data['call_type'] as String? ?? 'call';
      final icon = callType == 'video' ? 'ðŸ“¹' : 'ðŸ“ž';
      _insertCallSummaryMessage('$icon Call ended$durationStr');
    });

    _socketService.addListener('call_declined', key, (
      Map<String, dynamic> data,
    ) {
      final callerId = data['caller_id'] as int?;
      final calleeId = data['callee_id'] as int?;
      if (callerId == null || calleeId == null) return;
      if (callerId != widget.otherUser.id && calleeId != widget.otherUser.id) {
        return;
      }
      _insertCallSummaryMessage('ðŸ“ž Call declined');
    });

    _socketService.addListener('call_missed', key, (Map<String, dynamic> data) {
      final callerId = data['caller_id'] as int?;
      final calleeId = data['callee_id'] as int?;
      if (callerId == null || calleeId == null) return;
      if (callerId != widget.otherUser.id && calleeId != widget.otherUser.id) {
        return;
      }
      _insertCallSummaryMessage('ðŸ“ž Missed call');
    });
  }

  /// Insert an ephemeral system message pill for call events (not persisted)
  void _insertCallSummaryMessage(String text) {
    if (!mounted) return;
    final now = DateTime.now().toUtc();
    final synthetic = Message(
      id: -(now
          .millisecondsSinceEpoch), // negative id = synthetic, never collides with DB
      senderId: 0,
      recipientId: 0,
      content: text,
      messageType: 'system',
      timestamp: now.toIso8601String(),
      timestampMs: now.millisecondsSinceEpoch,
      isRead: true,
      status: 'read',
      threadId: '',
      reactions: {},
      isDeleted: false,
    );
    setState(() => _messages.insert(0, synthetic));
  }

  /// Handle cross-room call offer from web client while in chat
  // ignore: unused_element
  Future<void> _handleCrossRoomCallOfferInChat(
    Map<String, dynamic> data,
  ) async {
    if (!mounted) return;

    if (PresenceService().isHandlingIncomingCall) {
      debugPrint(
        'âš ï¸ Already handling an incoming call, ignoring cross-room duplicate',
      );
      return;
    }
    PresenceService().isHandlingIncomingCall = true;

    debugPrint('ðŸ“² Cross-room call offer received in chat: $data');

    final callerId = data['caller_id'] as int?;
    final callerUsername =
        data['caller_username'] as String? ?? widget.otherUser.fullName;
    final callType = data['call_type'] as String? ?? 'video';
    final room = data['room'] as String?;

    if (callerId == null || room == null) {
      debugPrint('âš ï¸ Invalid cross-room call offer data');
      PresenceService().isHandlingIncomingCall = false;
      return;
    }

    // Initialize call service FIRST
    final callService = CallService();
    await callService.initialize();

    if (!mounted) {
      PresenceService().isHandlingIncomingCall = false;
      return;
    }

    // Set up signal handler IMMEDIATELY - before handleIncomingCall
    // This ensures we capture any signals that arrive while setting up
    _socketService.onSignal = (signalData) {
      if (_isAcceptedOnOtherDeviceCancelSignalForActiveIncoming(signalData)) {
        debugPrint(
          '📴 Dismissing incoming call modal (accepted on other device via signal)',
        );
        _dismissIncomingCallModalIfOpen();
        PresenceService().isHandlingIncomingCall = false;
        _showCallInProgressOnOtherDeviceIndicator();
        return;
      }
      debugPrint('ðŸ“¡ Signal received for cross-room call: $signalData');
      callService.handleSignal(signalData);
    };

    // Create synthetic incoming call data for the call service
    final syntheticCallData = {
      'id': DateTime.now().millisecondsSinceEpoch,
      'call_room_id': room,
      'call_type': callType,
      'caller_id': callerId,
      'caller': {
        'id': callerId,
        'username': callerUsername,
        'full_name': callerUsername,
      },
    };
    callService.handleIncomingCall(syntheticCallData);

    // Use keyed listeners for call ended/declined handlers
    const crossRoomListenerKey = 'chat_cross_room_call';
    _socketService.addListener('callEnded', crossRoomListenerKey, (
      Map<String, dynamic> endData,
    ) {
      debugPrint('ðŸ“´ Call ended by remote user (chat cross-room)');
      _socketService.stopSignalBuffering();
      callService.handleCallEnded();
    });

    _socketService.addListener('callDeclined', crossRoomListenerKey, (
      Map<String, dynamic> declineData,
    ) {
      debugPrint('âŒ Call declined (chat cross-room)');
      _socketService.stopSignalBuffering();
      callService.handleCallDeclined();
    });

    // Show incoming call setup modal with device selection
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (context) => IncomingCallSetupModal(
              callerName: callerUsername,
              callerId: callerId,
              callType: callType,
              callService: callService,
              onDecline: () {
                debugPrint(' Call declined by user');
                _socketService.stopSignalBuffering();
                _socketService.removeListener(
                  'callEnded',
                  crossRoomListenerKey,
                );
                _socketService.removeListener(
                  'callDeclined',
                  crossRoomListenerKey,
                );
              },
            ),
          ),
        )
        .then((result) {
          // Clean up listeners when modal closes
          _socketService.removeListener('callEnded', crossRoomListenerKey);
          _socketService.removeListener('callDeclined', crossRoomListenerKey);

          if (!mounted) {
            PresenceService().isHandlingIncomingCall = false;
            return;
          }

          if (result is Map &&
              (result['result'] == 'accepted' ||
                  result['result'] == 'connected')) {
            final localStream = result['localStream'];
            Navigator.of(context).push(
              MaterialPageRoute(
                fullscreenDialog: true,
                builder: (context) => ConnectedCallScreen(
                  remoteName: callerUsername,
                  callType: callType,
                  callService: callService,
                  localStream: localStream ?? callService.localStream,
                  onChatPressed: () {
                    Navigator.of(context).pop();
                  },
                ),
              ),
            );
          }
          PresenceService().isHandlingIncomingCall = false;
        });
  }

  /// Show a non-intrusive in-chat banner when an incoming call from a DIFFERENT
  /// user arrives while this chat is open. Tapping "Answer" opens the caller's
  /// chat, where the deferred incoming-call modal is surfaced.
  void _showDeferredIncomingCallBanner(String callerName, int callerId) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 45),
        backgroundColor: const Color(0xFF1F2937),
        content: Row(
          children: [
            const Icon(Icons.phone_in_talk, color: Color(0xFFF59E0B)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '📞 Incoming call from $callerName',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'Answer',
          textColor: const Color(0xFFF59E0B),
          onPressed: () {
            messenger.hideCurrentSnackBar();
            NotificationHandler.openChatWithUser(callerId, callerName);
          },
        ),
      ),
    );
  }

  /// Handle incoming call while in chat screen.
  ///
  /// [requestOffer] is set when re-surfacing a previously deferred call (the
  /// original offer signal was dropped while deferred, so we re-request it).
  Future<void> _handleIncomingCallInChat(
    Map<String, dynamic> data, {
    bool requestOffer = false,
  }) async {
    if (!mounted) return;

    if (_callInProgressOnOtherDevice) {
      debugPrint(
        '⚠️ Ignoring incoming_call — already active on another device',
      );
      return;
    }

    // Guard: ignore if already in an active call
    if (PresenceService().isCallInProgress) {
      debugPrint(
        '\u26a0\ufe0f Ignoring incoming_call \u2014 call already in progress',
      );
      return;
    }

    // Guard against duplicate/rapid incoming call events (global flag shared with lobby)
    if (PresenceService().isHandlingIncomingCall) {
      debugPrint(
        '\u26a0\ufe0f Already handling an incoming call, ignoring duplicate',
      );
      return;
    }
    PresenceService().isHandlingIncomingCall = true;

    debugPrint('\ud83d\udcf2 Incoming call received in chat: $data');

    final callId = data['id'] as int?;
    final callRoomId = data['call_room_id'] as String?;
    final callType = data['call_type'] as String? ?? 'video';
    final callerData = data['caller'] as Map<String, dynamic>?;
    final callerId = callerData?['id'] as int? ?? data['caller_id'] as int?;
    final callerName =
        callerData?['full_name'] as String? ??
        callerData?['username'] as String? ??
        widget.otherUser.fullName;

    if (callId == null || callRoomId == null || callerId == null) {
      debugPrint('\u26a0\ufe0f Invalid incoming call data');
      PresenceService().isHandlingIncomingCall = false;
      return;
    }

    // Cross-room guard: if the caller is NOT the conversation we're viewing,
    // don't pop the modal over the wrong room (answering would route to this
    // chat's room, not the caller's, and break the call). Defer it - the lobby
    // shows a ringing indicator and we show an in-chat banner; the modal is
    // surfaced when the user opens the caller's chat (see initState). Skipped
    // when re-surfacing a deferred call (requestOffer), where caller == peer.
    if (!requestOffer && callerId != widget.otherUser.id) {
      debugPrint(
        '📲 Deferring incoming call from $callerId while viewing ${widget.otherUser.id}',
      );
      PendingIncomingCallService().setPending(data);
      PresenceService().isHandlingIncomingCall = false;
      _showDeferredIncomingCallBanner(callerName, callerId);
      return;
    }
    PendingIncomingCallService().clearIfMatches(callRoomId: callRoomId);

    // START buffering WebRTC signals immediately â€” before the async callService.initialize().
    _socketService.startSignalBuffering();

    // Initialize call service (fetches ICE servers) and set up the call state
    final callService = CallService();

    // Reset the singleton to ensure clean state for new call
    callService.reset();

    await callService.initialize();

    if (!mounted) {
      PresenceService().isHandlingIncomingCall = false;
      return;
    }

    callService.handleIncomingCall(data);

    // Set up signal handler for WebRTC
    _socketService.onSignal = (signalData) {
      if (_isAcceptedOnOtherDeviceCancelSignalForActiveIncoming(signalData)) {
        debugPrint(
          '📴 Dismissing incoming call modal (accepted on other device via signal)',
        );
        _dismissIncomingCallModalIfOpen();
        PresenceService().isHandlingIncomingCall = false;
        _showCallInProgressOnOtherDeviceIndicator();
        return;
      }
      debugPrint('ðŸ“¡ Signal received for incoming call: $signalData');
      callService.handleSignal(signalData);
    };

    // Re-surfacing a deferred call: the original offer signal was dropped while
    // deferred, so ask the server to resend it now that the handler is wired.
    if (requestOffer) {
      debugPrint('📞 Requesting pending offer for deferred call: $callRoomId');
      _socketService.emit('request_pending_offer', {'room': callRoomId});
    }

    // Use keyed listeners for call ended/declined handlers to avoid overwriting
    const callListenerKey = 'chat_incoming_call';
    _socketService.addListener('callEnded', callListenerKey, (
      Map<String, dynamic> endData,
    ) {
      debugPrint('ðŸ“´ Call ended by remote user (chat)');
      callService.handleCallEnded();
    });

    _socketService.addListener('callDeclined', callListenerKey, (
      Map<String, dynamic> declineData,
    ) {
      debugPrint('âŒ Call declined (chat)');
      callService.handleCallDeclined();
    });

    // Show incoming call setup modal with device selection
    if (_callInProgressOnOtherDevice) {
      debugPrint('⚠️ Skipping incoming call modal — active on another device');
      PresenceService().isHandlingIncomingCall = false;
      return;
    }

    final route = MaterialPageRoute(
      fullscreenDialog: true,
      builder: (context) => IncomingCallSetupModal(
        callerName: callerName,
        callerId: callerId,
        callType: callType,
        callService: callService,
        onDecline: () {
          debugPrint(' Call declined by user');
          // Clean up listeners
          _socketService.removeListener('callEnded', callListenerKey);
          _socketService.removeListener('callDeclined', callListenerKey);
        },
      ),
    );

    _activeIncomingCallRoute = route;
    _activeIncomingCallId = callId;
    _activeIncomingCallRoomId = callRoomId;

    Navigator.of(context).push(route).then((result) {
      // Clean up listeners when modal closes
      _socketService.removeListener('callEnded', callListenerKey);
      _socketService.removeListener('callDeclined', callListenerKey);

      if (identical(_activeIncomingCallRoute, route)) {
        _activeIncomingCallRoute = null;
        _activeIncomingCallId = null;
        _activeIncomingCallRoomId = null;
      }

      if (!mounted) {
        PresenceService().isHandlingIncomingCall = false;
        return;
      }

      if (result is Map &&
          (result['result'] == 'accepted' || result['result'] == 'connected')) {
        // Navigate to connected call screen with the local stream from setup
        final localStream = result['localStream'];
        Navigator.of(context).push(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (context) => ConnectedCallScreen(
              remoteName: callerName,
              callType: callType,
              callService: callService,
              localStream: localStream ?? callService.localStream,
              onChatPressed: () {
                Navigator.of(context).pop(); // Return to chat
              },
            ),
          ),
        );
      }
      PresenceService().isHandlingIncomingCall = false;
    });
  }

  void _handleColorChange(Map<String, dynamic> data) {
    final colorHex = data['color'] as String?;
    final rawSenderName = data['sender_name'] as String?;
    final senderName = _chatDisplayNameFromSender(
      rawSenderName ?? widget.otherUser.fullName,
    );
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
        // Dedup check - look for any existing color change message
        final alreadyExists = _messages.any(
          (msg) =>
              msg.messageType == 'system' &&
              (msg.content.contains('bg color') ||
                  msg.content.contains('Changed bg color')),
        );

        // If from self and message already exists locally, skip (same device echo)
        if (isFromSelf && alreadyExists) {
          debugPrint(
            'ðŸŽ¨ Skipping color change from self (already added locally)',
          );
          return;
        }

        // Parse hex color (e.g., "#FF5733" or "FF5733")
        final hexColor = colorHex.replaceAll('#', '');
        final color = Color(int.parse('FF$hexColor', radix: 16));

        // Always apply color change (incoming or cross-device)
        setState(() {
          _headerColor = color;
          _showResetButton = true;
        });

        // Persist the color so it survives app restarts / background
        _saveChatColor(colorHex);

        // Create system message
        final colorMessage = Message(
          id: timestampMs,
          senderId: isFromSelf ? _currentUserId! : widget.otherUser.id,
          recipientId: isFromSelf ? widget.otherUser.id : _currentUserId!,
          content: isFromSelf
              ? 'You changed the bg color of ${widget.otherUser.firstName}'
              : '$senderName changed your bg color to $colorHex',
          messageType: 'system',
          timestamp: DateTime.now().toIso8601String(),
          timestampMs: timestampMs,
          isRead: true,
          status: isFromSelf ? 'sent' : 'delivered',
          threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
          reactions: {},
          isDeleted: false,
        );

        if (!isFromSelf) {
          setState(() {
            _messages.insert(0, colorMessage);
          });
        }

        // Only auto-scroll if user is at bottom, otherwise just show unread badge
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_isAtBottom) {
            _scrollToBottom();
          }
        });

        debugPrint(
          'ðŸŽ¨ Color changed to: $colorHex (${isFromSelf ? "cross-device sync" : "incoming from $senderName"})',
        );
      } catch (e) {
        debugPrint('Error parsing color: $e');
      }
    }
  }

  void _handleColorReset(Map<String, dynamic> data) {
    final rawSenderName = data['sender_name'] as String?;
    final senderName = _chatDisplayNameFromSender(
      rawSenderName ?? widget.otherUser.fullName,
    );
    final senderId = data['sender_id'] != null
        ? int.tryParse(data['sender_id'].toString())
        : null;
    final isFromSelf = senderId == _currentUserId;
    final timestampMs = data['timestamp_ms'] != null
        ? int.tryParse(data['timestamp_ms'].toString()) ??
            DateTime.now().millisecondsSinceEpoch
        : DateTime.now().millisecondsSinceEpoch;

    // Dedup check
    final alreadyExists = _messages.any(
      (msg) =>
          msg.messageType == 'system' &&
          msg.timestampMs == timestampMs &&
          (msg.content.contains('reset') || msg.content.contains('Reset')),
    );
    if (alreadyExists) {
      debugPrint('ðŸ”„ Skipping duplicate color reset message');
      return;
    }

    // Always reset bg color â€” whether incoming (other user resets) or
    // cross-device (we reset from another device), our bg should update
    const defaultColor = Color(0xFF121212);
    setState(() {
      _headerColor = defaultColor;
      _showResetButton = false;
    });
    _saveChatColor('#121212');

    // Create system message
    final resetMessage = Message(
      id: timestampMs,
      senderId: isFromSelf ? _currentUserId! : widget.otherUser.id,
      recipientId: isFromSelf ? widget.otherUser.id : _currentUserId!,
      content: isFromSelf
          ? 'Reset bg color'
          : '$senderName reset their bg color',
      messageType: 'system',
      timestamp: DateTime.now().toIso8601String(),
      timestampMs: timestampMs,
      isRead: true,
      status: isFromSelf ? 'sent' : 'delivered',
      threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
      reactions: {},
      isDeleted: false,
    );

    setState(() {
      _messages.insert(0, resetMessage);
    });

    // Only auto-scroll if user is at bottom, otherwise just show unread badge
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isAtBottom) {
        _scrollToBottom();
      }
    });

    debugPrint(
      'ðŸ”„ Color ${isFromSelf ? "reset (cross-device sync)" : "reset by ${widget.otherUser.fullName}"}',
    );
  }

  void _handleIncomingDoorbell(Map<String, dynamic> data) {
    final rawSenderName = data['sender_name'] as String?;
    final senderName = _chatDisplayNameFromSender(
      rawSenderName ?? widget.otherUser.fullName,
    );
    final timestampMs = data['timestamp_ms'] as int;

    // Check if we already have this doorbell notification to prevent duplicates
    final alreadyExists = _messages.any(
      (msg) =>
          msg.messageType == 'system' &&
          msg.timestampMs == timestampMs &&
          msg.content.contains('sent a notification'),
    );

    if (alreadyExists) {
      debugPrint('Doorbell notification already exists, skipping duplicate');
      return;
    }

    // Play doorbell notification sound
    _playDoorbellSound();

    // Create incoming notification message
    final doorbellMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch,
      senderId: widget.otherUser.id,
      recipientId: _currentUserId!,
      content: '$senderName sent a notification',
      messageType: 'system',
      timestamp: DateTime.now().toIso8601String(),
      timestampMs: timestampMs,
      isRead: true,
      status: 'delivered',
      threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
      reactions: {},
      isDeleted: false,
    );

    setState(() {
      _messages.insert(0, doorbellMessage);
    });

    // Only auto-scroll if user is at bottom, otherwise just show unread badge
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isAtBottom) {
        _scrollToBottom();
      }
    });
  }

  /// Cross-device sync: show outgoing doorbell system message when we rang from another device
  void _handleOutgoingDoorbellSync(Map<String, dynamic> data) {
    final timestampMs =
        data['timestamp_ms'] as int? ?? DateTime.now().millisecondsSinceEpoch;

    // Check for duplicates
    final alreadyExists = _messages.any(
      (msg) =>
          msg.messageType == 'system' &&
          msg.timestampMs == timestampMs &&
          (msg.content.contains('sent a notification') ||
              msg.content.contains('Sent a notification')),
    );

    if (alreadyExists) {
      debugPrint(
        'ðŸ”” Cross-device doorbell already exists, skipping duplicate',
      );
      return;
    }

    debugPrint('ðŸ”” Cross-device: showing outgoing doorbell in chat');

    final doorbellMessage = Message(
      id: timestampMs,
      senderId: _currentUserId!,
      recipientId: widget.otherUser.id,
      content: 'Sent a notification',
      messageType: 'system',
      timestamp: DateTime.now().toIso8601String(),
      timestampMs: timestampMs,
      isRead: true,
      status: 'sent',
      threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
      reactions: {},
      isDeleted: false,
    );

    setState(() {
      _messages.insert(0, doorbellMessage);
    });

    // Only auto-scroll if user is at bottom, otherwise just show unread badge
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isAtBottom) {
        _scrollToBottom();
      }
    });
  }

  void _handleAllMessagesDeleted(Map<String, dynamic> data) {
    debugPrint('ðŸ—‘ï¸ Handling all messages deleted event: $data');

    final String deletedRoom = data['room'] ?? '';

    // Validate room ID
    if (deletedRoom.isEmpty) {
      debugPrint('âš ï¸ Warning: Received delete event with no room ID');
      return;
    }

    // Generate current room ID (same format as backend: chat_{userId1}_{userId2} sorted)
    if (_currentUserId == null) {
      debugPrint('âš ï¸ Warning: Current user ID is null');
      return;
    }

    final List<int> userIds = [_currentUserId!, widget.otherUser.id];
    userIds.sort();
    final currentRoomId = 'chat_${userIds[0]}_${userIds[1]}';

    // Only clear messages if the event is for the current room
    if (deletedRoom != currentRoomId) {
      debugPrint(
        'â„¹ï¸ Ignoring delete event for different room: $deletedRoom (current: $currentRoomId)',
      );
      return;
    }

    // Clear all messages
    setState(() {
      _messages.clear();
      _databaseLoadedMessageIds.clear();
    });

    // Clear the local cache so stale messages don't reload
    if (_currentUserId != null) {
      ChatCacheService.clearConversationCache(
        _currentUserId!,
        widget.otherUser.id,
      );
      debugPrint('🗑️ Conversation cache cleared for room: $currentRoomId');
    }

    // Show a snackbar notification
    if (mounted) {
      _showTopSnackBar(
        const SnackBar(
          content: Text('All messages have been deleted'),
          duration: Duration(seconds: 3),
          backgroundColor: Colors.orange,
        ),
      );
    }

    debugPrint('✅ Messages cleared for room: $currentRoomId');
  }

  void _syncColorFromMessages(List<Message> messages) {
    // Pick the LATEST color event by message id — callers pass lists in
    // different orders (cache oldest-first, server pages newest-first), and the
    // old first-match scan re-applied the OLDEST color in history on every
    // room open instead of the most recent change/reset.
    Message? latest;
    for (final msg in messages) {
      if (msg.messageType == 'color_change' ||
          msg.messageType == 'color_reset') {
        if (latest == null || msg.id > latest.id) {
          latest = msg;
        }
      }
    }
    if (latest == null) return;

    if (latest.messageType == 'color_change') {
      final colorHex = latest.content;
      try {
        final hexColor = colorHex.replaceAll('#', '');
        final color = Color(int.parse('FF$hexColor', radix: 16));
        if (mounted) {
          setState(() {
            _headerColor = color;
            _showResetButton = true;
          });
        }
        _saveChatColor(colorHex);
      } catch (e) {
        debugPrint('Error parsing color from history: $e');
      }
    } else {
      if (mounted) {
        setState(() {
          _headerColor = const Color(0xFF121212);
          _showResetButton = false;
        });
      }
      _saveChatColor('#121212');
    }
  }

  Future<void> _loadCachedMessages() async {
    final currentUserId = _currentUserId ?? await StorageService.getUserId();
    if (currentUserId == null) {
      debugPrint('⚠️ No user ID available for cache loading');
      return;
    }

    try {
      final cached = await ChatCacheService.loadConversationMessages(
        currentUserId,
        widget.otherUser.id,
      );

      if (cached.isNotEmpty && mounted) {
        debugPrint('📦 Loaded ${cached.length} messages from cache');
        _syncColorFromMessages(cached);
        setState(() {
          _messages = cached.reversed.toList();
          _databaseLoadedMessageIds
            ..clear()
            ..addAll(
              cached
                  .where((message) => message.id > 0)
                  .map((message) => message.id),
            );
          // Hydrate reactions from the cached messages too, so the fast
          // first paint already shows the peer's reactions (not just after
          // the server refresh lands).
          _messageReactions.clear();
          _hydrateReactionsForMessages(_messages);
          _isLoading = false; // Show cached messages immediately
        });
      } else {
        debugPrint(
          '📦 No cached messages available - this is expected on first open',
        );
        // Don't show empty state - let _loadMessages handle it
      }
    } catch (e) {
      debugPrint('Error loading cached messages: $e');
      // Don't modify loading state - let _loadMessages handle it
    }
  }

  Future<void> _persistConversationCacheSnapshot() async {
    final currentUserId = _currentUserId ?? await StorageService.getUserId();
    if (currentUserId == null) return;

    await ChatCacheService.saveConversationMessages(
      currentUserId,
      widget.otherUser.id,
      _messages.reversed.toList(),
    );
  }

  /// Conversation this chat's whiteboards belong to. Built from the sorted
  /// participant pair so both sides derive the same key and see the same
  /// boards — deriving it from anything else is how they went missing on web.
  String? get _excalidrawConversationKey {
    final me = _currentUserId;
    if (me == null) return null;
    return ExcalidrawRoomsService.dmKey(me, widget.otherUser.id);
  }

  /// Text and images only. Everything else (documents, voice notes, calls) has
  /// no sensible representation on a canvas.
  bool _canSendToExcalidrawRoom(Message message) {
    if (message.isDeleted) return false;
    if (message.messageType == 'image') {
      return (message.fileUrl ?? '').isNotEmpty;
    }
    return message.messageType == 'text' && message.content.trim().isNotEmpty;
  }

  /// Ask which board, then hand the content to it.
  Future<void> _sendMessageToExcalidrawRoom(Message message) async {
    final conversationKey = _excalidrawConversationKey;
    if (conversationKey == null) return;

    final room = await ExcalidrawRoomPicker.show(
      context,
      conversationKey: conversationKey,
    );
    if (room == null || !mounted) return;

    try {
      final isImage = message.messageType == 'image';
      final result = isImage
          ? await ExcalidrawRoomsService.sendPhoto(
              roomId: room.roomId,
              fileUrl: _absoluteFileUrl(message.fileUrl!),
              fileName: message.fileName,
            )
          : await ExcalidrawRoomsService.sendNote(
              roomId: room.roomId,
              text: message.content.trim(),
              // A message already marked as a task becomes a green task card,
              // matching what the web context menu sends.
              variant: message.isTask ? 'task' : 'note',
            );

      if (!mounted) return;
      // The server cannot draw into an encrypted scene, so with nobody in the
      // room there is no one to do it — say so rather than claiming success.
      if (result.listeners == 0) {
        _showTopSnackBar(
          SnackBar(
            content: Text(
              'Nobody has "${room.title}" open — open the board and send again.',
            ),
            backgroundColor: const Color(0xFFB45309),
          ),
        );
        return;
      }
      _showTopSnackBar(
        SnackBar(
          content: Text(
            isImage ? 'Photo sent to ${room.title}' : 'Sent to ${room.title}',
          ),
          backgroundColor: const Color(0xFF15803D),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showTopSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Chat file urls are stored relative; the board fetches them by URL.
  String _absoluteFileUrl(String rawUrl) {
    if (rawUrl.toLowerCase().startsWith('http')) return rawUrl;
    return '${ApiConfig.origin}/${rawUrl.replaceFirst(RegExp(r'^/+'), '')}';
  }

  /// A board in some conversation changed. Only this chat's own boards matter
  /// here; other chats are recounted when they are opened.
  void _handleExcalidrawRoomChanged(Map<String, dynamic> data) {
    final key = _excalidrawConversationKey;
    if (key == null || data['conversation_key'] != key) return;

    // If the modal is on screen, refresh it in place; either way the badge
    // has to be recounted.
    _excalRoomsSectionKey.currentState?.reload();

    final actorId = (data['actor_id'] as num?)?.toInt();
    if (actorId != null && actorId == _currentUserId) return;
    unawaited(_refreshExcalidrawRoomsUnread());
  }

  /// Recount boards changed since this chat's Excalidraw modal was last opened.
  Future<void> _refreshExcalidrawRoomsUnread() async {
    final key = _excalidrawConversationKey;
    if (key == null) return;
    final count = await ExcalidrawRoomsService.unreadCount(key);
    if (!mounted || key != _excalidrawConversationKey) return;
    if (count != _excalidrawRoomsUnread) {
      setState(() => _excalidrawRoomsUnread = count);
    }
  }

  Future<void> _loadPinnedExcalidrawLinks() async {
    try {
      final links = await MessageService.getConversationExcalidrawLinks(
        userId: widget.otherUser.id,
      );
      if (mounted) {
        setState(() => _pinnedExcalidrawLinks = links);
      }
    } catch (e) {
      debugPrint('Error loading pinned excalidraw links: $e');
    }
  }

  Future<void> _loadMessages() async {
    // Guard against concurrent calls
    if (_isLoadingMessages) {
      debugPrint(
        '⚠️ _loadMessages already in progress, skipping duplicate call',
      );
      return;
    }

    _isLoadingMessages = true;
    try {
      debugPrint('🔄 Loading messages for user ${widget.otherUser.id}...');
      final messages = await MessageService.getConversationMessages(
        userId: widget.otherUser.id,
        limit: 50,
        offlineFirst: false, // Cache was already shown by _loadCachedMessages
      );
      debugPrint('✅ Successfully loaded ${messages.length} messages');

      if (!mounted) {
        debugPrint('⚠️ Widget unmounted before setState, skipping update');
        _isLoadingMessages = false;
        return;
      }

      _syncColorFromMessages(messages);

      setState(() {
        _messages = messages.reversed
            .toList(); // Reverse to show newest at bottom
        _databaseLoadedMessageIds
          ..clear()
          ..addAll(
            _messages
                .where((message) => message.id > 0)
                .map((message) => message.id),
          );
        _hasMoreMessages = messages.length >= 50;
        _isLoading = false;

        // Populate reactions from the freshly loaded server messages (the
        // server is authoritative, so rebuild the whole map).
        _messageReactions.clear();
        _hydrateReactionsForMessages(_messages);
      });

      await _syncLoadedMessageStatuses(messages);

      // Pull every media attachment in this conversation into the
      // on-disk cache so the chat works fully offline (images, videos,
      // audio, files). Fire-and-forget; errors are swallowed per file.
      unawaited(MediaPreloadService.instance.prefetchMessages(messages));

      _scrollToBottom();
    } catch (e) {
      debugPrint('âŒ Error loading messages: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } finally {
      _isLoadingMessages = false;
      debugPrint('ðŸ Message loading process completed');
    }
  }

  /// Fetch ALL task-marked messages for this conversation in the background.
  /// This runs independently of the paginated _messages list so that the task
  /// modal always shows the correct total count (e.g. 43 tasks, not just the
  /// 14 that happen to be in the currently loaded page).
  Future<void> _loadConversationTasks() async {
    if (_isLoadingTasks) return;
    _isLoadingTasks = true;
    try {
      final rawTasks = await MessageService.getChatTasksForConversation(
        widget.otherUser.id,
      );
      if (!mounted) return;

      // Convert each task JSON back into a minimal Message that the existing
      // task modal / badge code can use directly from _taskMessages.
      final taskMessages = rawTasks.map((t) {
        // The endpoint returns message-shaped JSON with is_task=true.
        // Build a Message from it.  Fields that aren't relevant to task
        // display are filled with safe defaults.
        return Message.fromJson({
          'id': t['id'] ?? t['message_id'] ?? 0,
          'sender_id': t['created_by_user_id'] ?? 0,
          'recipient_id': t['assigned_to_user_id'] ?? widget.otherUser.id,
          'content': t['content'] ?? t['title'] ?? '',
          'message_type': t['message_type'] ?? 'text',
          'timestamp': t['created_at'] ?? DateTime.now().toIso8601String(),
          'timestamp_ms': 0,
          'is_read': true,
          'status': 'seen',
          'thread_id': '',
          'reactions': <String, dynamic>{},
          'is_deleted': false,
          'is_task': true,
          'task_created_at': t['task_created_at'] ?? t['created_at'],
          'task_completed_at': t['task_completed_at'] ?? t['completed_at'],
          'file_url': t['file_url'],
          'file_name': t['file_name'],
          'file_type': t['file_type'],
          'file_size': t['file_size'],
        });
      }).toList();

      setState(() {
        // Merge: keep any live-arrived tasks already in _taskMessages that
        // aren't yet in the server response (very recent marks), then add all
        // server tasks, deduplicating by id.
        final serverIds = taskMessages.map((m) => m.id).toSet();
        final liveOnly = _taskMessages
            .where((m) => !serverIds.contains(m.id))
            .toList();
        _taskMessages = [...taskMessages, ...liveOnly];
        // Also merge into _messages so task bubbles in the current page keep
        // their highlight / checkbox.
        _mergeTaskStatesIntoMessages(taskMessages);
      });
    } catch (e) {
      debugPrint('Error loading conversation tasks: $e');
    } finally {
      _isLoadingTasks = false;
    }
  }

  /// Apply task state from the full task list back onto any messages that are
  /// already in the visible _messages page so their bubble UI stays in sync.
  void _mergeTaskStatesIntoMessages(List<Message> taskMessages) {
    final taskById = {for (final t in taskMessages) t.id: t};
    for (int i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      if (taskById.containsKey(m.id)) {
        final t = taskById[m.id]!;
        if (m.isTask != t.isTask ||
            m.taskCreatedAt != t.taskCreatedAt ||
            m.taskCompletedAt != t.taskCompletedAt) {
          _messages[i] = _copyMessageWithTaskState(
            m,
            isTask: t.isTask,
            taskCreatedAt: t.taskCreatedAt,
            taskCompletedAt: t.taskCompletedAt,
          );
        }
      }
    }
  }

  /// Load common phrases from server
  /// Pinned phrases (server-side, max 2 on mobile) are shown first on the bar.
  Future<void> _loadCommonPhrases() async {
    try {
      final phrases = await _commonPhrasesApi.fetch(limit: 8);

      // Sort: mobile-pinned first (ascending pinOrderMobile), then by usage_count desc.
      final sorted = [...phrases]
        ..sort((a, b) {
          if (a.isPinnedMobile && b.isPinnedMobile) {
            return (a.pinOrderMobile ?? 99).compareTo(b.pinOrderMobile ?? 99);
          }
          if (a.isPinnedMobile) return -1;
          if (b.isPinnedMobile) return 1;
          return b.usageCount.compareTo(a.usageCount);
        });

      // Only show mobile-pinned phrases on the quick bar (max 2)
      final pinnedOnly = sorted
          .where((p) => p.isPinnedMobile)
          .take(_kMobileMaxPins)
          .toList(growable: false);
      if (mounted) {
        setState(() {
          _commonPhrases = pinnedOnly;
        });
      }
      debugPrint(
        '📝 Loaded ${sorted.length} phrases; ${pinnedOnly.length} pinned shown on bar',
      );
    } catch (e) {
      debugPrint('❌ Error loading common phrases: $e');
      // Silently fail - this is a non-critical feature
    }
  }

  /// Sync common phrases visibility based on input text
  void _syncCommonPhrasesVisibility() {
    final hasText =
        _messageController.text.trim().isNotEmpty &&
        !_isStampOnlyDraft(_messageController.text);
    final shouldHide = hasText || _otherUserTyping;

    if (_hideCommonPhrases != shouldHide && mounted) {
      setState(() {
        _hideCommonPhrases = shouldHide;
      });
    }
  }

  /// Handle tapping a common phrase chip
  Future<void> _onCommonPhraseChipTap(CommonPhrase phrase) async {
    final phraseText = phrase.phrase.trim();
    if (phraseText.isEmpty) return;

    final wasAtBottom = _isAtBottom;

    // Hide phrases and set input to phrase text
    setState(() {
      _hideCommonPhrases = true;
      _messageController.text = _withStampPrefix(phraseText);
    });

    // Preserve user position: only pin to bottom for chip sends when the user
    // was already at the bottom before tapping.
    _suppressNextSendAutoScroll = !wasAtBottom;

    // Send the phrase as a message
    await _sendMessage();

    // Track usage in background
    unawaited(_commonPhrasesApi.trackUse(phraseText));

    // If user was at bottom, keep scrolling to bottom after send
    if (wasAtBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
      Future<void>.delayed(const Duration(milliseconds: 80), () {
        if (mounted) {
          _scrollToBottom();
        }
      });
    }
  }

  /// Load older messages (pagination) when user taps "Load more"
  Future<void> _loadMoreMessages() async {
    if (_isLoadingMore || !_hasMoreMessages || _messages.isEmpty) return;

    try {
      // _messages is newest-first; the oldest is at the end
      final oldestId = _messages.last.id;

      final olderMessages = await MessageService.getConversationMessages(
        userId: widget.otherUser.id,
        limit: 50,
        beforeId: oldestId,
        offlineFirst: false,
      );

      if (!mounted) return;

      if (olderMessages.isEmpty) {
        setState(() {
          _hasMoreMessages = false;
          _isLoadingMore = false;
        });
        return;
      }

      // API returns oldest-first; reverse to newest-first before appending
      final newMessages = olderMessages.reversed.toList();

      // Deduplicate against messages already present
      final existingIds = _messages.map((m) => m.id).toSet();
      final uniqueNew = newMessages
          .where((m) => !existingIds.contains(m.id))
          .toList();

      setState(() {
        _messages.addAll(uniqueNew);
        _databaseLoadedMessageIds.addAll(
          uniqueNew.where((m) => m.id > 0).map((m) => m.id),
        );
        // Hydrate reactions for the newly paginated-in messages so older
        // history shows the peer's reactions too (append — don't clear).
        _hydrateReactionsForMessages(uniqueNew);
        _hasMoreMessages = olderMessages.length >= 50;
        _isLoadingMore = false;
      });
    } catch (e) {
      debugPrint('Error loading more messages: $e');
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      // Jump with no animation (WhatsApp-like, keeps the app snappy). For a
      // reverse list the bottom is offset 0; the keyboard's space is held by the
      // reactive bottom spacer (list item 0), so 0 is always the bottom.
      _scrollController.jumpTo(0);
    }
  }

  /// Scroll to a specific task bubble and flash-highlight it
  void _jumpToTaskBubble(Message task) {
    _doJumpToTaskBubble(task);
  }

  /// Keeps the keyboard closed while jumping to a bubble. Closing the tasks
  /// modal restores focus to the message input (which pops the keyboard open),
  /// and that restoration lands across the modal's close animation — so we drop
  /// focus now and again over the next few frames to override it.
  void _dismissKeyboardForJump() {
    void drop() {
      if (!mounted) return;
      _inputFocusNode.unfocus();
      FocusManager.instance.primaryFocus?.unfocus();
      try {
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      } catch (_) {}
    }

    drop();
    for (final ms in const [80, 200, 350]) {
      Future.delayed(Duration(milliseconds: ms), drop);
    }
  }

  /// Scroll to the original message that [replyToId] points to and flash it.
  void _jumpToRepliedMessage(int replyToId) {
    final existing = _messages.firstWhere(
      (m) => m.id == replyToId,
      orElse: () => Message(
        id: replyToId,
        senderId: 0,
        recipientId: 0,
        content: '',
        messageType: 'text',
        timestamp: DateTime.now().toIso8601String(),
        timestampMs: 0,
        isRead: false,
        status: 'sent',
        threadId: '',
        reactions: {},
        isDeleted: false,
      ),
    );
    _doJumpToTaskBubble(existing);
  }

  Future<void> _doJumpToTaskBubble(Message task) async {
    // Jumping should never pop the keyboard open.
    _dismissKeyboardForJump();
    setState(() {
      _bubbleFlashId = task.id;
    });

    try {
      if (!_scrollController.hasClients) return;

      // Check if the message is already built and fully visible in the viewport.
      if (_messageItemKeys[task.id]?.currentContext != null) {
        final BuildContext ctx = _messageItemKeys[task.id]!.currentContext!;
        final RenderObject? ro = ctx.findRenderObject();
        if (ro != null && ro.attached) {
          final RenderAbstractViewport? viewport = RenderAbstractViewport.of(ro);
          if (viewport != null) {
            final double offsetLeading = viewport.getOffsetToReveal(ro, 0.0).offset;
            final double offsetTrailing = viewport.getOffsetToReveal(ro, 1.0).offset;
            final double minOffset = offsetLeading < offsetTrailing ? offsetLeading : offsetTrailing;
            final double maxOffset = offsetLeading > offsetTrailing ? offsetLeading : offsetTrailing;
            final double currentOffset = _scrollController.offset;

            // Use a small safety margin of 5 pixels. If the item is larger than the viewport, 
            // minOffset will be less than or equal to maxOffset, but if the margin makes the 
            // range invalid, we fall back to a 0 margin.
            final double margin = (maxOffset - minOffset) > 10 ? 5.0 : 0.0;
            if (currentOffset >= minOffset + margin && currentOffset <= maxOffset - margin) {
              // Already fully visible! Just return and flash.
              return;
            }

            // If built but not fully visible, jump directly to the exact centered position.
            final double revealOffset = viewport
                .getOffsetToReveal(ro, 0.5)
                .offset
                .clamp(
                  _scrollController.position.minScrollExtent,
                  _scrollController.position.maxScrollExtent,
                );
            _scrollController.jumpTo(revealOffset);
            return;
          }
        }
      }

      // ── 1. Paginate until the message is in _messages ─────────────────────
      final bool alreadyLoaded = _messages.any((m) => m.id == task.id);
      while (!_messages.any((m) => m.id == task.id) &&
          _hasMoreMessages &&
          mounted) {
        await _loadMoreMessages();
        await Future<void>.delayed(Duration.zero);
      }

      final int index = _messages.indexWhere((m) => m.id == task.id);
      if (index == -1 || !mounted) return;

      // Wait for layout to settle after any new messages were inserted.
      await WidgetsBinding.instance.endOfFrame;

      final ScrollPosition pos = _scrollController.position;

      // Calculate fracOffset and jumpTarget in outer scope so they can be accessed in fallback sweep.
      final double fracOffset = _messages.length > 1
          ? (index / (_messages.length - 1)) * pos.maxScrollExtent
          : 0.0;
      final double jumpTarget = (fracOffset - pos.viewportDimension / 2 + 40)
          .clamp(0.0, pos.maxScrollExtent);

      // ── 2. Initial jump to bring the item into the render tree ────────────
      //
      // Case A – we had to paginate: the target was just appended at the END
      // of _messages (oldest = highest index = highest scroll offset).
      // Jump straight to maxScrollExtent so those items get built.
      //
      // Case B – item was already loaded: use a proportion estimate.
      // All initially-loaded messages are within the first fetch (~50 items)
      // so they live near scroll-offset-0 (bottom) and the estimate is tight.
      if (!alreadyLoaded) {
        _scrollController.jumpTo(pos.maxScrollExtent);
      } else {
        _scrollController.jumpTo(jumpTarget);
      }
      await WidgetsBinding.instance.endOfFrame;

      if (!mounted) return;

      // Check if it's built and visible now after the initial jump
      if (_messageItemKeys[task.id]?.currentContext != null) {
        final BuildContext ctx = _messageItemKeys[task.id]!.currentContext!;
        final RenderObject? ro = ctx.findRenderObject();
        if (ro != null && ro.attached) {
          final RenderAbstractViewport? viewport = RenderAbstractViewport.of(ro);
          if (viewport != null) {
            final double offsetLeading = viewport.getOffsetToReveal(ro, 0.0).offset;
            final double offsetTrailing = viewport.getOffsetToReveal(ro, 1.0).offset;
            final double minOffset = offsetLeading < offsetTrailing ? offsetLeading : offsetTrailing;
            final double maxOffset = offsetLeading > offsetTrailing ? offsetLeading : offsetTrailing;
            final double currentOffset = _scrollController.offset;

            // If already fully visible after the initial jump, we don't need a second adjustment jump!
            final double margin = (maxOffset - minOffset) > 10 ? 5.0 : 0.0;
            if (currentOffset >= minOffset + margin && currentOffset <= maxOffset - margin) {
              return;
            }

            // Otherwise, do the final exact jump
            final double revealOffset = viewport
                .getOffsetToReveal(ro, 0.5)
                .offset
                .clamp(
                  _scrollController.position.minScrollExtent,
                  _scrollController.position.maxScrollExtent,
                );
            _scrollController.jumpTo(revealOffset);
            return;
          }
        }
      }

      // ── 3. If item still not built, sweep the scroll range until it is ────
      // Each step is cacheExtent-sized (500 px) so we cover the whole content.
      if (_messageItemKeys[task.id]?.currentContext == null) {
        final double step = 400;
        final double maxScroll = pos.maxScrollExtent;
        final double baseOffset = !alreadyLoaded ? pos.maxScrollExtent : (fracOffset - pos.viewportDimension / 2 + 40).clamp(0.0, pos.maxScrollExtent);
        
        final List<double> sweepOffsets = [baseOffset];
        for (int i = 1; i <= 5; i++) {
          sweepOffsets.add(baseOffset + i * step);
          sweepOffsets.add(baseOffset - i * step);
        }
        
        for (final double sweep in sweepOffsets) {
          if (!mounted) break;
          final double clamped = sweep.clamp(0.0, maxScroll);
          _scrollController.jumpTo(clamped);
          await WidgetsBinding.instance.endOfFrame;
          if (_messageItemKeys[task.id]?.currentContext != null) break;
        }
        
        // Fallback: full sweep from 0 if still not found (highly unlikely)
        if (_messageItemKeys[task.id]?.currentContext == null && mounted) {
          double sweep = 0;
          while (sweep <= maxScroll && mounted) {
            _scrollController.jumpTo(sweep.clamp(0.0, maxScroll));
            await WidgetsBinding.instance.endOfFrame;
            if (_messageItemKeys[task.id]?.currentContext != null) break;
            sweep += step;
          }
        }
      }

      // ── 4. Pixel-perfect scroll using RenderAbstractViewport ─────────────
      // getOffsetToReveal(ro, 0.5) returns the exact scroll offset that places
      // the item's centre at the viewport's centre, handling reverse:true correctly.
      if (!mounted) return;
      final BuildContext? ctx = _messageItemKeys[task.id]?.currentContext;
      if (ctx == null) return;
      // ignore: use_build_context_synchronously
      final RenderObject? ro = ctx.findRenderObject();
      if (ro == null || !ro.attached) return;

      final double revealOffset = RenderAbstractViewport.of(ro)
          .getOffsetToReveal(ro, 0.5)
          .offset
          .clamp(
            _scrollController.position.minScrollExtent,
            _scrollController.position.maxScrollExtent,
          );

      // Jump (no animation) — the flash highlight already signals the target.
      _scrollController.jumpTo(revealOffset);
    } finally {
      Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _bubbleFlashId = null);
      });
    }
  }

  /// Export chat to a text file
  Future<void> _exportChat() async {
    try {
      final currentUserId = await StorageService.getUserId();
      final currentUserName = await StorageService.getUsername() ?? 'Someone';
      final peerName = widget.otherUser.fullName;
      
      final content = ChatExporter.formatChatExport(
        messages: _messages,
        currentUserId: currentUserId ?? 0,
        currentUserName: currentUserName,
        peerName: peerName,
      );
      
      final filename = 'chat_export_1to1_${widget.otherUser.id}_${DateTime.now().millisecondsSinceEpoch}.txt';
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Exporting chat...')),
      );

      final path = await FileSaver.saveFile(
        filename: filename,
        content: content,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(path == 'browser_download' 
                ? 'Chat exported successfully (check downloads)'
                : 'Chat exported and saved to downloads'),
            backgroundColor: Colors.green,
          ),
        );
      }

      // Send system message
      await MessageService.sendMessage(
        recipientId: widget.otherUser.id,
        content: '$currentUserName exported the chat',
        messageType: 'system',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export chat: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _normalizeTextFileName(String value) {
    final sanitized = value
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final fallback = sanitized.isEmpty ? 'chat_export' : sanitized;
    return fallback.toLowerCase().endsWith('.txt') ? fallback : '$fallback.txt';
  }

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

  Future<void> _ensureLocalNotificationsReady() async {
    if (_localNotificationsReady) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: iosSettings,
    );

    await _localNotificationsPlugin.initialize(
      settings,
      onDidReceiveNotificationResponse:
          _handleFileOperationNotificationResponse,
    );
    _localNotificationsReady = true;
  }

  Future<void> _handleFileOperationNotificationResponse(
    NotificationResponse response,
  ) async {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;

    try {
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      final target = decoded['target'] as String?;
      final mimeType = decoded['mimeType'] as String?;
      if (target == null || target.isEmpty) return;

      await _openDownloadedFileTarget(target: target, mimeType: mimeType);
    } catch (e) {
      debugPrint('Error handling file-operation notification tap: $e');
    }
  }

  Future<void> _showLocalFileOperationNotification({
    required String title,
    required String body,
    String? target,
    String? mimeType,
  }) async {
    try {
      await _ensureLocalNotificationsReady();
      const androidDetails = AndroidNotificationDetails(
        'chat_file_ops',
        'Chat File Operations',
        channelDescription: 'Notifications for exports and downloads',
        importance: Importance.high,
        priority: Priority.high,
      );
      const iosDetails = DarwinNotificationDetails();
      const details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      final payload = target == null
          ? null
          : jsonEncode({'target': target, 'mimeType': mimeType});

      await _localNotificationsPlugin.show(
        DateTime.now().millisecondsSinceEpoch % 100000,
        title,
        body,
        details,
        payload: payload,
      );
    } catch (e) {
      debugPrint('Error showing local file-operation notification: $e');
    }
  }

  Future<Directory> _resolveDownloadDirectory() async {
    if (Platform.isAndroid) {
      final sharedDownloads = Directory('/storage/emulated/0/Download');
      if (!await sharedDownloads.exists()) {
        await sharedDownloads.create(recursive: true);
      }
      return sharedDownloads;
    }

    final systemDownloads = await getDownloadsDirectory();
    if (systemDownloads != null) {
      return systemDownloads;
    }

    final appDocs = await getApplicationDocumentsDirectory();
    final fallbackDownloads = Directory(
      '${appDocs.path}${Platform.pathSeparator}Downloads',
    );
    if (!await fallbackDownloads.exists()) {
      await fallbackDownloads.create(recursive: true);
    }
    return fallbackDownloads;
  }

  Future<void> _downloadIncomingFile(Message message) async {
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
      final inferredName = message.fileName ?? uri.pathSegments.last;
      final outputName = _resolveOutgoingFileName(
        originalName: inferredName,
        mimeType: mimeType,
        isFromCamera: false,
      );

      String? savedTarget;
      if (Platform.isAndroid) {
        savedTarget = await _saveToAndroidDownloads(
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
        savedTarget = saveFile.path;
      }

      await _showLocalFileOperationNotification(
        title: 'File Downloaded',
        body: outputName,
        target: savedTarget,
        mimeType: mimeType,
      );

      if (mounted) {
        _showTopSnackBar(
          SnackBar(
            content: Text('Saved to Downloads: $outputName'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error downloading incoming file: $e');
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

  Future<String?> _saveToAndroidDownloads({
    required String fileName,
    required String mimeType,
    required List<int> bytes,
  }) async {
    return _fileOpsChannel.invokeMethod<String>('saveToDownloads', {
      'fileName': fileName,
      'mimeType': mimeType,
      'bytes': bytes,
    });
  }

  Future<void> _openDownloadedFileTarget({
    required String target,
    String? mimeType,
  }) async {
    if (Platform.isAndroid) {
      await _fileOpsChannel.invokeMethod('openDownloadedFile', {
        'target': target,
        'mimeType': mimeType ?? '*/*',
      });
      return;
    }

    await OpenFilex.open(target);
  }

  /// Admin-only: delete all messages in this conversation
  Future<void> _adminDeleteAllMessages() async {
    if (!_currentUserIsAdmin) return;

    // Build the room ID the same way the socket join uses it
    final ids = [_currentUserId!, widget.otherUser.id]..sort();
    final room = 'chat_${ids[0]}_${ids[1]}';

    // Confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2D2D2D),
        title: const Text(
          'Delete Messages',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'This will permanently delete ALL messages between you and '
          '${widget.otherUser.fullName}, including all uploaded files. '
          'This cannot be undone.',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete Messages'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Show progress
    if (mounted) {
      _showTopSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              SizedBox(width: 12),
              Text('Deleting all messages...'),
            ],
          ),
          duration: Duration(seconds: 30),
        ),
      );
    }

    try {
      final token = await StorageService.getToken();
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/mobile/admin/delete-all-messages'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: '{"room":"$room"}',
      );

      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (response.statusCode == 200) {
        // Clear the local messages list immediately
        setState(() {
          _messages.clear();
          _databaseLoadedMessageIds.clear();
        });
        if (mounted) {
          _showTopSnackBar(
            const SnackBar(
              content: Text('All messages deleted successfully'),
              backgroundColor: Color(0xFF10B981),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        if (mounted) {
          _showTopSnackBar(
            SnackBar(
              content: Text(
                'Failed to delete messages (${response.statusCode})',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        _showTopSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Format date for export separator
  String _formatExportDate(String timestamp) {
    try {
      final date = _parseUtcTimestamp(timestamp);
      final weekdays = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ];
      final months = [
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
      return '${weekdays[date.weekday - 1]}, ${months[date.month - 1]} ${date.day}, ${date.year}';
    } catch (e) {
      return timestamp;
    }
  }

  /// Format time for export message
  String _formatExportTime(String timestamp) {
    try {
      final date = _parseUtcTimestamp(timestamp);
      final hour = date.hour.toString().padLeft(2, '0');
      final minute = date.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } catch (e) {
      return '';
    }
  }

  String _matchReplacementCase(String sourceWord, String replacement) {
    if (sourceWord.isEmpty || replacement.isEmpty) return replacement;

    if (sourceWord == sourceWord.toUpperCase()) {
      return replacement.toUpperCase();
    }

    final first = sourceWord[0];
    if (first == first.toUpperCase()) {
      return replacement[0].toUpperCase() + replacement.substring(1);
    }

    return replacement;
  }

  String _applyAutoCorrection(
    String input, {
    bool learn = true,
    bool verboseLogs = true,
    String logPrefix = '[AutoCorrect]',
    bool trimInput = true,
  }) {
    if (!_autoCorrectionEnabled) {
      if (verboseLogs) debugPrint('$logPrefix Skipped: disabled');
      return input;
    }

    final normalizedInput = trimInput ? input.trim() : input;
    if (normalizedInput.trim().isEmpty) {
      if (verboseLogs) debugPrint('$logPrefix Skipped: empty input');
      return normalizedInput;
    }

    final dictionary = <String, String>{};

    void addEntries(Map<String, String> source) {
      for (final entry in source.entries) {
        final wrong = entry.key.trim().toLowerCase();
        final correct = entry.value.trim();
        if (wrong.isEmpty || correct.isEmpty) continue;
        dictionary[wrong] = correct;
      }
    }

    addEntries(_learnedAutoCorrectionMappings);
    addEntries(_manualAutoCorrectionMappings);

    if (dictionary.isEmpty) {
      if (verboseLogs) debugPrint('$logPrefix Skipped: no mappings');
      return normalizedInput;
    }

    if (verboseLogs) {
      debugPrint('$logPrefix Input: "$normalizedInput"');
      debugPrint('$logPrefix Mappings loaded: ${dictionary.length}');
    }

    var corrected = normalizedInput;
    var hasChanges = false;
    final appliedCorrections = <MapEntry<String, String>>[];

    final entries = dictionary.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));

    for (final entry in entries) {
      final wrong = entry.key.trim();
      final correct = entry.value.trim();
      if (wrong.isEmpty || correct.isEmpty) continue;

      final regex = RegExp(
        '\\b${RegExp.escape(wrong)}\\b',
        caseSensitive: false,
      );
      final matches = regex.allMatches(corrected).length;
      if (matches == 0) continue;

      if (verboseLogs) {
        debugPrint('$logPrefix Match "$wrong" -> "$correct" count=$matches');
      }

      corrected = corrected.replaceAllMapped(regex, (match) {
        hasChanges = true;
        return _matchReplacementCase(match.group(0) ?? wrong, correct);
      });

      appliedCorrections.add(MapEntry(wrong.toLowerCase(), correct));
    }

    if (hasChanges) {
      if (learn) {
        var learnedChanged = false;
        for (final correction in appliedCorrections) {
          if (_learnedAutoCorrectionMappings[correction.key] !=
              correction.value) {
            _learnedAutoCorrectionMappings[correction.key] = correction.value;
            learnedChanged = true;
          }
        }
        if (learnedChanged) {
          unawaited(_saveAutoCorrectionPreferences());
        }
      }
      if (verboseLogs) {
        debugPrint('$logPrefix Output: "$corrected"');
        debugPrint(
          '$logPrefix Applied mappings: ${appliedCorrections.map((e) => '"${e.key}"->"${e.value}"').join(', ')}',
        );
      }
    } else {
      if (verboseLogs) debugPrint('$logPrefix No mapping matched input');
    }

    return corrected;
  }

  String _applyAutoCorrectionOnSend(String input) {
    return _applyAutoCorrection(
      input,
      learn: true,
      verboseLogs: true,
      logPrefix: '[AutoCorrect:send]',
      trimInput: true,
    );
  }

  /// Detects YouTube URLs in the message and appends their titles.
  /// If a YouTube URL is found and title is fetched, appends: "YouTube Title"
  Future<String> _appendYouTubeTitle(String content) async {
    try {
      final linkService = LinkPreviewService();
      final url = linkService.extractFirstUrl(content);
      if (url == null) return content;

      final videoId = linkService.extractYouTubeId(url);
      if (videoId == null) return content;

      // Fetch YouTube title
      final title = await linkService.fetchYouTubeTitle(videoId);
      if (title == null || title.isEmpty) return content;

      // Append title to the message if not already present
      final contentWithTitle = '$content\n"$title"';
      debugPrint('[YouTubeTitle] Appended title: "$title"');
      return contentWithTitle;
    } catch (e) {
      debugPrint('[YouTubeTitle] Error fetching title: $e');
      // Return original content on error
      return content;
    }
  }

  Future<void> _sendMessage() async {
    // ── EDIT MODE ──────────────────────────────────────────────
    if (_editingMessage != null) {
      final editTarget = _editingMessage!;
      final newContent = _messageController.text.trim();
      if (newContent.isNotEmpty && newContent != editTarget.content) {
        _editMessage(editTarget, newContent);
      }
      _clearEdit();
      return;
    }
    // ── NORMAL SEND MODE (unchanged below) ────────────────────
    final rawContent = _withStampPrefix(_messageController.text);
    var content = _applyAutoCorrectionOnSend(rawContent);
    if (rawContent != content) {
      debugPrint(
        '[AutoCorrect:send] Corrected before send: "$rawContent" -> "$content"',
      );
    }

    // Fetch YouTube title if a YouTube URL is present
    content = await _appendYouTubeTitle(content);

    if (content.isEmpty || _isStampOnlyDraft(content)) return;
    final markAsTask = _markNextMessageAsTask;

    // Capture reply info before clearing
    final replyToId = _replyingToMessage?.id;
    String? replyPreviewContent;
    if (_replyingToMessage != null) {
      final msg = _replyingToMessage!;
      final senderName = msg.senderId == _currentUserId
          ? 'You'
          : widget.otherUser.firstName;
      String previewText;
      // Handle different message types
      if (msg.isDeleted) {
        previewText = 'Deleted message';
      } else if (msg.messageType == 'voice' || msg.messageType == 'audio') {
        previewText = '🎤 Voice message';
      } else if (msg.messageType == 'image') {
        previewText = '📷 Photo';
      } else if (msg.messageType == 'video') {
        previewText = '🎬 Video';
      } else if (msg.messageType == 'file' || msg.messageType == 'document') {
        previewText = '📎 ${msg.fileName ?? "File"}';
      } else if (msg.messageType == 'contact') {
        final contactName = ContactVCard.fromVCardString(msg.content)?.name;
        previewText = '[Contact] ${contactName ?? 'Contact'}';
      } else {
        // For text, truncate if too long
        previewText = msg.content.length > 60
            ? '${msg.content.substring(0, 60)}...'
            : msg.content;
      }
      replyPreviewContent = '$senderName: $previewText';
    }

    // Create optimistic message for immediate UI update
    final optimisticMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch, // Temporary ID
      senderId: _currentUserId!,
      recipientId: widget.otherUser.id,
      content: content,
      messageType: 'text',
      timestamp: DateTime.now().toIso8601String(),
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      isRead: false,
      status: 'sending',
      threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
      replyToId: replyToId,
      replyPreview: replyPreviewContent,
      reactions: {},
      isDeleted: false,
      isTask: markAsTask,
      taskCreatedAt: markAsTask ? DateTime.now().toIso8601String() : null,
    );

    // Track this optimistic message for dedup when server echoes back
    final dedupKey = '$_currentUserId:${widget.otherUser.id}:$content';
    _pendingMessageKeys.add(dedupKey);
    if (markAsTask) {
      _enqueuePendingTaskIntent(dedupKey);
    }

    setState(() {
      _messages.insert(0, optimisticMessage);
      _replyingToMessage = null; // Clear reply after sending
      _markNextMessageAsTask = false;
    });

    // Play message sound when sending
    try {
      _audioPlayer.play(AssetSource('sounds/splat2.m4a'));
    } catch (e) {
      debugPrint('Error playing message sound: $e');
    }

    _messageController.clear();
    _stopTyping();
    if (_stampEnabled) {
      _seedStampPrefixInInput();
    }

    // Scroll to bottom after sending unless explicitly suppressed.
    final shouldAutoScroll = !_suppressNextSendAutoScroll;
    _suppressNextSendAutoScroll = false;
    if (shouldAutoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }

    // Try to send message
    try {
      // Check if Socket.IO is connected
      if (_socketService.isConnected) {
        // Send via Socket.IO for real-time delivery
        debugPrint(
          'Sending message via Socket.IO${replyToId != null ? ' (replying to $replyToId)' : ''}',
        );
        _socketService.sendMessage(
          recipientId: widget.otherUser.id,
          content: content,
          messageType: 'text',
          replyToId: replyToId,
        );
      } else {
        // Fallback to REST API
        debugPrint('âš ï¸ Socket.IO not connected, using REST API fallback');
        final sentMessage = await MessageService.sendMessage(
          recipientId: widget.otherUser.id,
          content: content,
          messageType: 'text',
        );

        // Update optimistic message with real message data
        if (sentMessage != null && mounted) {
          final uiMessage = markAsTask
              ? _copyMessageWithTaskState(
                  sentMessage,
                  isTask: true,
                  taskCreatedAt:
                      sentMessage.taskCreatedAt ??
                      DateTime.now().toIso8601String(),
                  taskCompletedAt: null,
                )
              : sentMessage;

          setState(() {
            final index = _messages.indexWhere(
              (m) => m.id == optimisticMessage.id,
            );
            if (index != -1) {
              _messages[index] = uiMessage;
            }
          });

          if (markAsTask) {
            _consumePendingTaskIntent(dedupKey);
          }

          if (markAsTask && _socketService.isConnected) {
            _socketService.addTask(sentMessage.id);
          }
          await _persistConversationCacheSnapshot();
          debugPrint('Message sent via REST API');
        } else {
          // REST returned null (no connectivity / backend unreachable). Queue
          // for automatic retry and keep the clock indicator.
          await TextMessageRetryService().queueMessage(
            optimisticId: optimisticMessage.id,
            recipientId: widget.otherUser.id,
            content: content,
            replyToId: replyToId,
          );
          debugPrint(
            'REST send returned null — queued text message for retry '
            '(optimistic ${optimisticMessage.id})',
          );
        }
      }
    } catch (e) {
      debugPrint('âŒ Error sending message: $e');
      // The send failed (typically offline / backend unreachable). Instead of
      // marking it failed, queue it for automatic retry on reconnect and keep
      // the optimistic bubble in the 'sending' state (clock icon), WhatsApp
      // style. The dedup key and any task intent are intentionally left in
      // place so the eventual 'messageSent' socket echo reconciles the bubble.
      await TextMessageRetryService().queueMessage(
        optimisticId: optimisticMessage.id,
        recipientId: widget.otherUser.id,
        content: content,
        replyToId: replyToId,
      );
      debugPrint(
        'Queued text message for retry (optimistic ${optimisticMessage.id})',
      );
    }
  }

  // ── Contact Sending ────────────────────────────────────────────────────────

  Future<void> _pickContact() async {
    try {
      final granted = await FlutterContacts.requestPermission(readonly: true);
      if (!granted) {
        if (mounted) {
          _showTopSnackBar(
            const SnackBar(
              content: Text(
                'Contacts permission is required to share contacts',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final contact = await FlutterContacts.openExternalPick();
      if (contact == null || !mounted) return;

      // Fetch with full properties (phones, emails)
      final full = await FlutterContacts.getContact(
        contact.id,
        withProperties: true,
      );
      if (full == null || !mounted) return;

      _sendContactMessage(full);
    } catch (e) {
      debugPrint('Contact pick error: $e');
      if (mounted) {
        _showTopSnackBar(
          const SnackBar(content: Text('Could not open contact picker')),
        );
      }
    }
  }

  Future<void> _sendContactMessage(Contact contact) async {
    final name = contact.displayName.isNotEmpty
        ? contact.displayName
        : [
            contact.name.first,
            contact.name.last,
          ].where((s) => s.isNotEmpty).join(' ');
    final phone = contact.phones.isNotEmpty ? contact.phones.first.number : '';
    final email = contact.emails.isNotEmpty
        ? contact.emails.first.address
        : null;

    if (name.isEmpty || phone.isEmpty) {
      if (mounted) {
        _showTopSnackBar(
          const SnackBar(
            content: Text('This contact has no phone number to share'),
          ),
        );
      }
      return;
    }

    final vcard = ContactVCard(
      name: name,
      phone: phone,
      email: email,
    ).toVCardString();

    final optimisticMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch,
      senderId: _currentUserId!,
      recipientId: widget.otherUser.id,
      content: vcard,
      messageType: 'contact',
      timestamp: DateTime.now().toIso8601String(),
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      isRead: false,
      status: 'sending',
      threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
      reactions: {},
      isDeleted: false,
    );

    setState(() => _messages.insert(0, optimisticMessage));

    try {
      _audioPlayer.play(AssetSource('sounds/splat2.m4a'));
    } catch (_) {}

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    try {
      if (_socketService.isConnected) {
        _socketService.sendMessage(
          recipientId: widget.otherUser.id,
          content: vcard,
          messageType: 'contact',
        );
      } else {
        final sent = await MessageService.sendMessage(
          recipientId: widget.otherUser.id,
          content: vcard,
          messageType: 'contact',
        );
        if (sent != null && mounted) {
          setState(() {
            final idx = _messages.indexWhere(
              (m) => m.id == optimisticMessage.id,
            );
            if (idx != -1) _messages[idx] = sent;
          });
        }
      }
    } catch (e) {
      debugPrint('Send contact error: $e');
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m.id == optimisticMessage.id);
          if (idx != -1) {
            _messages[idx] = Message(
              id: _messages[idx].id,
              senderId: _messages[idx].senderId,
              recipientId: _messages[idx].recipientId,
              content: _messages[idx].content,
              messageType: _messages[idx].messageType,
              timestamp: _messages[idx].timestamp,
              timestampMs: _messages[idx].timestampMs,
              isRead: _messages[idx].isRead,
              status: 'failed',
              threadId: _messages[idx].threadId,
              reactions: _messages[idx].reactions,
              isDeleted: _messages[idx].isDeleted,
            );
          }
        });
      }
    }
  }

  void _enqueuePendingTaskIntent(String dedupKey) {
    final current = _pendingTaskIntentsByDedupKey[dedupKey] ?? 0;
    _pendingTaskIntentsByDedupKey[dedupKey] = current + 1;
  }

  bool _consumePendingTaskIntent(String dedupKey) {
    final current = _pendingTaskIntentsByDedupKey[dedupKey] ?? 0;
    if (current <= 0) {
      return false;
    }

    if (current == 1) {
      _pendingTaskIntentsByDedupKey.remove(dedupKey);
    } else {
      _pendingTaskIntentsByDedupKey[dedupKey] = current - 1;
    }

    return true;
  }

  Message _copyMessageWithTaskState(
    Message message, {
    required bool isTask,
    String? taskCreatedAt,
    String? taskCompletedAt,
  }) {
    return Message(
      id: message.id,
      senderId: message.senderId,
      recipientId: message.recipientId,
      content: message.content,
      messageType: message.messageType,
      timestamp: message.timestamp,
      timestampMs: message.timestampMs,
      isRead: message.isRead,
      readAt: message.readAt,
      readAtMs: message.readAtMs,
      deliveredAt: message.deliveredAt,
      deliveredAtMs: message.deliveredAtMs,
      status: message.status,
      threadId: message.threadId,
      replyToId: message.replyToId,
      replyPreview: message.replyPreview,
      reactions: message.reactions,
      fileUrl: message.fileUrl,
      fileName: message.fileName,
      fileSize: message.fileSize,
      fileType: message.fileType,
      isDeleted: message.isDeleted,
      isTask: isTask,
      taskCreatedAt: taskCreatedAt,
      taskCompletedAt: taskCompletedAt,
      isExcalidrawLink: message.isExcalidrawLink,
      excalidrawPinnedAt: message.excalidrawPinnedAt,
      isPinned: message.isPinned,
      pinnedAt: message.pinnedAt,
      pinnedByUserId: message.pinnedByUserId,
      caption: message.caption,
    );
  }

  Message _copyMessageWithExcalidrawState(
    Message message, {
    required bool isExcalidrawLink,
    String? excalidrawPinnedAt,
  }) {
    return Message(
      id: message.id,
      senderId: message.senderId,
      recipientId: message.recipientId,
      content: message.content,
      messageType: message.messageType,
      timestamp: message.timestamp,
      timestampMs: message.timestampMs,
      isRead: message.isRead,
      readAt: message.readAt,
      readAtMs: message.readAtMs,
      deliveredAt: message.deliveredAt,
      deliveredAtMs: message.deliveredAtMs,
      status: message.status,
      threadId: message.threadId,
      replyToId: message.replyToId,
      replyPreview: message.replyPreview,
      reactions: message.reactions,
      fileUrl: message.fileUrl,
      fileName: message.fileName,
      fileSize: message.fileSize,
      fileType: message.fileType,
      isDeleted: message.isDeleted,
      isTask: message.isTask,
      taskCreatedAt: message.taskCreatedAt,
      taskCompletedAt: message.taskCompletedAt,
      isExcalidrawLink: isExcalidrawLink,
      excalidrawPinnedAt: excalidrawPinnedAt,
      isPinned: excalidrawPinnedAt != null,
      pinnedAt: excalidrawPinnedAt,
      pinnedByUserId: excalidrawPinnedAt != null
          ? (_currentUserId ?? message.pinnedByUserId)
          : null,
    );
  }

  Message _applyPendingLiveTaskState(Message message) {
    final pendingCreatedAt = _pendingLiveTaskCreatedAtByMessageId.remove(
      message.id,
    );
    final pendingCompletedAt = _pendingLiveTaskCompletedAtByMessageId.remove(
      message.id,
    );

    if (!message.isTask &&
        pendingCreatedAt == null &&
        pendingCompletedAt == null) {
      return message;
    }

    return _copyMessageWithTaskState(
      message,
      isTask: true,
      taskCreatedAt:
          pendingCreatedAt ??
          message.taskCreatedAt ??
          DateTime.now().toIso8601String(),
      taskCompletedAt: pendingCompletedAt ?? message.taskCompletedAt,
    );
  }

  String _buildBulkBatchId() {
    final now = DateTime.now().toUtc();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return 'flutter-batch-${now.year}-${twoDigits(now.month)}-${twoDigits(now.day)}-${now.millisecondsSinceEpoch}';
  }

  Future<void> _showSendToManyDialog() async {
    final draftContent = _messageController.text.trim();
    if (draftContent.isEmpty) return;
    final correctedDraftContent = _applyAutoCorrectionOnSend(draftContent);

    final currentUserId = _currentUserId ?? await StorageService.getUserId();
    if (!mounted) return;

    final usersFuture = LobbyService.getLobbyUsers();
    final selectedRecipientIds = <int>{widget.otherUser.id};
    var searchQuery = '';

    final selectedIds = await showDialog<List<int>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setModalState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E1E2E),
              title: const Text(
                'Send to many',
                style: TextStyle(color: Colors.white),
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 380,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Select recipients for this message.',
                      style: TextStyle(color: Colors.grey[300], fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A3A),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: TextField(
                        onChanged: (value) {
                          setModalState(() => searchQuery = value);
                        },
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Search users',
                          hintStyle: TextStyle(color: Colors.grey[500]),
                          prefixIcon: Icon(
                            Icons.search,
                            color: Colors.grey[500],
                            size: 18,
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: FutureBuilder<List<LobbyUser>>(
                        future: usersFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }

                          if (snapshot.hasError) {
                            return Center(
                              child: Text(
                                'Failed to load users',
                                style: TextStyle(color: Colors.grey[400]),
                              ),
                            );
                          }

                          final users = snapshot.data ?? const <LobbyUser>[];
                          final selectableUsers = users.where((user) {
                            if (currentUserId != null &&
                                user.id == currentUserId) {
                              return false;
                            }
                            return true;
                          }).toList();

                          final selectedUsers = selectableUsers.where((user) {
                            return selectedRecipientIds.contains(user.id);
                          }).toList();

                          final normalizedSearch = searchQuery
                              .trim()
                              .toLowerCase();
                          final filteredUsers = selectableUsers.where((user) {
                            if (normalizedSearch.isEmpty) {
                              return true;
                            }
                            return user.fullName.toLowerCase().contains(
                                  normalizedSearch,
                                ) ||
                                user.username.toLowerCase().contains(
                                  normalizedSearch,
                                );
                          }).toList();

                          filteredUsers.sort((a, b) {
                            final aSelected = selectedRecipientIds.contains(
                              a.id,
                            );
                            final bSelected = selectedRecipientIds.contains(
                              b.id,
                            );
                            if (aSelected == bSelected) {
                              return a.fullName.toLowerCase().compareTo(
                                b.fullName.toLowerCase(),
                              );
                            }
                            return aSelected ? -1 : 1;
                          });

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${selectedRecipientIds.length} selected',
                                style: const TextStyle(
                                  color: Color(0xFF7C3AED),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                width: double.infinity,
                                constraints: const BoxConstraints(
                                  minHeight: 44,
                                  maxHeight: 110,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2A2A3A),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: const Color(0xFF3B3B4E),
                                  ),
                                ),
                                child: selectedUsers.isEmpty
                                    ? Center(
                                        child: Text(
                                          'No recipients selected',
                                          style: TextStyle(
                                            color: Colors.grey[500],
                                            fontSize: 12,
                                          ),
                                        ),
                                      )
                                    : SingleChildScrollView(
                                        child: Wrap(
                                          spacing: 6,
                                          runSpacing: 6,
                                          children: selectedUsers
                                              .map(
                                                (user) => InputChip(
                                                  label: Text(
                                                    user.fullName,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  labelStyle: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 12,
                                                  ),
                                                  backgroundColor: const Color(
                                                    0xFF4C1D95,
                                                  ),
                                                  deleteIconColor:
                                                      Colors.white70,
                                                  onDeleted: () {
                                                    setModalState(() {
                                                      selectedRecipientIds
                                                          .remove(user.id);
                                                    });
                                                  },
                                                  materialTapTargetSize:
                                                      MaterialTapTargetSize
                                                          .shrinkWrap,
                                                ),
                                              )
                                              .toList(),
                                        ),
                                      ),
                              ),
                              const SizedBox(height: 8),
                              Expanded(
                                child: filteredUsers.isEmpty
                                    ? Center(
                                        child: Text(
                                          'No users found',
                                          style: TextStyle(
                                            color: Colors.grey[400],
                                          ),
                                        ),
                                      )
                                    : ListView.builder(
                                        itemCount: filteredUsers.length,
                                        itemBuilder: (context, index) {
                                          final user = filteredUsers[index];
                                          final isSelected =
                                              selectedRecipientIds.contains(
                                                user.id,
                                              );
                                          return CheckboxListTile(
                                            dense: true,
                                            value: isSelected,
                                            onChanged: (value) {
                                              setModalState(() {
                                                if (value == true) {
                                                  selectedRecipientIds.add(
                                                    user.id,
                                                  );
                                                } else {
                                                  selectedRecipientIds.remove(
                                                    user.id,
                                                  );
                                                }
                                              });
                                            },
                                            controlAffinity:
                                                ListTileControlAffinity.leading,
                                            activeColor: const Color(
                                              0xFF7C3AED,
                                            ),
                                            checkColor: Colors.white,
                                            title: Text(
                                              user.fullName,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 14,
                                              ),
                                            ),
                                            subtitle: Text(
                                              '@${user.username}',
                                              style: TextStyle(
                                                color: Colors.grey[400],
                                                fontSize: 12,
                                              ),
                                            ),
                                            contentPadding: EdgeInsets.zero,
                                          );
                                        },
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
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: selectedRecipientIds.isEmpty
                      ? null
                      : () {
                          Navigator.pop(
                            dialogContext,
                            selectedRecipientIds.toList(),
                          );
                        },
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF7C3AED),
                  ),
                  child: const Text('Send'),
                ),
              ],
            );
          },
        );
      },
    );

    if (selectedIds == null || selectedIds.isEmpty || !mounted) {
      return;
    }

    final replyToId = _replyingToMessage?.id;
    try {
      final response = await MessageService.sendManyMessages(
        recipientIds: selectedIds,
        content: correctedDraftContent,
        messageType: 'text',
        replyToId: replyToId,
        bulkBatchId: _buildBulkBatchId(),
      );

      _messageController.clear();
      _stopTyping();
      if (mounted) {
        setState(() {
          _replyingToMessage = null;
        });
      }

      if (!mounted) return;

      final summaryText = response.failedCount > 0
          ? 'Sent to ${response.sentCount}/${response.requestedCount}. ${response.failedCount} failed.'
          : 'Sent to ${response.sentCount} recipients.';

      _showTopSnackBar(
        SnackBar(
          content: Text(summaryText),
          backgroundColor: response.failedCount > 0
              ? Colors.orange
              : Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showTopSnackBar(
        SnackBar(
          content: Text('Bulk send failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildSendToManyQuickAction() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _messageController,
      builder: (context, value, _) {
        if (value.text.trim().isEmpty || _isStampOnlyDraft(value.text)) {
          return const SizedBox.shrink();
        }

        final sendToManyButton = Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _showSendToManyDialog,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF2A1F45),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFF7C3AED).withValues(alpha: 0.8),
                  width: 1,
                ),
              ),
              child: const Text(
                'send to many',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        );

        final markAsTaskButton = Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              setState(() {
                _markNextMessageAsTask = !_markNextMessageAsTask;
              });
            },
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                color: _markNextMessageAsTask
                    ? const Color(0xFF7C2D12)
                    : const Color(0xFF2D2A1F),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: _markNextMessageAsTask
                      ? const Color(0xFFF59E0B)
                      : const Color(0xFFB45309).withValues(alpha: 0.75),
                  width: 1,
                ),
              ),
              child: const Text(
                'mark as task',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        );

        return Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: sendToManyButton,
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: markAsTaskButton,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _toggleStamp() {
    setState(() {
      _stampEnabled = !_stampEnabled;
    });
    unawaited(_saveStampPreference());

    if (_stampEnabled) {
      _seedStampPrefixInInput();
    } else if (_hasStampPrefix(_messageController.text)) {
      final withoutStamp = _removeStampTagFromText(_messageController.text);
      _replaceInputTextWithSanitized(withoutStamp);
    }
  }

  /// A full-size, web-style action pill used in the desktop composer (single
  /// line label, natural width). Mobile uses the compact two-row layout instead.
  Widget _buildDesktopActionPill({
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          HapticFeedback.selectionClick();
          onPressed();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  /// Desktop composer actions laid out as web-style colored pill rows that wrap,
  /// rather than the compact fitted two-row layout used on mobile.
  Widget _buildDesktopActionsBar() {
    // Ordered to mirror the web composer's pill rows. Send File is a normal
    // pill here (the upload progress still shows in the message area), not the
    // full-width mobile chip.
    final pills = <Widget>[
      _buildDesktopActionPill(
        label: widget.otherUser.firstName,
        color: const Color(0xFF0F766E),
        onPressed: _insertOtherUserFirstName,
      ),
      _buildDesktopActionPill(
        label: 'Paste',
        color: const Color(0xFF1D4ED8),
        onPressed: _pasteFromClipboard,
      ),
      _buildDesktopActionPill(
        label: 'Ring Doorbell',
        color: const Color(0xFF7C3AED),
        onPressed: _ringDoorbell,
      ),
      _buildDesktopActionPill(
        label: _stampEnabled ? 'Stamp On' : 'Stamp Off',
        color: const Color(0xFF0C95D4),
        onPressed: _toggleStamp,
      ),
      _buildDesktopActionPill(
        label: 'Change Color',
        color: const Color(0xFF9333EA),
        onPressed: _changeColor,
      ),
      if (_showResetButton)
        _buildDesktopActionPill(
          label: 'Reset Color',
          color: const Color(0xFF6B7280),
          onPressed: _resetColor,
        ),
      _buildDesktopActionPill(
        label: 'Send File',
        color: const Color(0xFF16A34A),
        onPressed: _showAttachmentMenu,
      ),
      _buildDesktopActionPill(
        label: 'Voice Message',
        color: const Color(0xFFEF4444),
        onPressed: _showVoiceRecordingModal,
      ),
      _buildDesktopActionPill(
        label: 'Auto Correction',
        color: const Color(0xFFF59E0B),
        onPressed: _showAutoCorrectionDictionaryModal,
      ),
      _buildDesktopActionPill(
        label: _autoTranslate ? 'Translate On' : 'Translate Off',
        color: const Color(0xFFC026D3),
        onPressed: _toggleAutoTranslate,
      ),
      _buildDesktopActionPill(
        label: _showTimestamps ? 'Hide Timestamps' : 'Show Timestamps',
        color: const Color(0xFF4F46E5),
        onPressed: _toggleTimestamps,
      ),
      _buildDesktopActionPill(
        label: 'Common Phrases',
        color: const Color(0xFFEC4899),
        onPressed: _showCommonPhrasesModal,
      ),
      _buildDesktopActionPill(
        label: 'Video Call',
        color: const Color(0xFF0D9488),
        onPressed: () => _showCallSetupModal(CallType.video),
      ),
      _buildDesktopActionPill(
        label: 'Audio Call',
        color: const Color(0xFFD97706),
        onPressed: () => _showCallSetupModal(CallType.audio),
      ),
      _buildDesktopActionPill(
        label: 'Export Chat',
        color: const Color(0xFF6B7280),
        onPressed: _exportChat,
      ),
      if (_currentUserIsAdmin)
        _buildDesktopActionPill(
          label: 'Delete Messages',
          color: const Color(0xFF6D28D9),
          onPressed: _adminDeleteAllMessages,
        ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(spacing: 8, runSpacing: 8, children: pills),
    );
  }

  Widget _buildUnifiedActionsBar() {
    // Desktop: web-style pill rows. Mobile keeps the compact two-row layout.
    if (widget.embedded) {
      return _buildDesktopActionsBar();
    }
    final allButtons = <Widget>[
      // Row 1: Send File, Voice Message, Auto Correction, Translate Off, Stamp Off
      _buildSendFileChip(),
      _buildCompressedActionChip(
        label: 'Voice Message',
        backgroundColor: const Color(0xFFEF4444),
        onPressed: _showVoiceRecordingModal,
      ),
      _buildCompressedActionChip(
        label: 'Auto Correction',
        backgroundColor: const Color(0xFFF59E0B),
        onPressed: _showAutoCorrectionDictionaryModal,
      ),
      _buildCompressedActionChip(
        label: _autoTranslate ? 'Translate On' : 'Translate Off',
        backgroundColor: const Color(
          0xFFC026D3,
        ), // web Auto-Translate (darkened for white text)
        onPressed: _toggleAutoTranslate,
      ),
      _buildCompressedActionChip(
        label: _stampEnabled ? 'Stamp On' : 'Stamp Off',
        backgroundColor: const Color(0xFF0C95D4), // web Stamp Name
        onPressed: _toggleStamp,
      ),
      // Row 2 extras (after username + paste): Change Color, [Reset Color], Export Chat, Show Timestamps, [Delete Messages]
      _buildCompressedActionChip(
        label: 'Change Color',
        backgroundColor: const Color(
          0xFF9333EA,
        ), // Change Color (darkened for white text)
        onPressed: _changeColor,
      ),
      if (_showResetButton)
        _buildCompressedActionChip(
          label: 'Reset Color',
          backgroundColor: const Color(0xFF6B7280),
          onPressed: _resetColor,
        ),
      _buildCompressedActionChip(
        label: 'Export Chat',
        backgroundColor: const Color(0xFF6B7280), // web Export Chat (gray-500)
        onPressed: _exportChat,
      ),
      _buildCompressedActionChip(
        label: _showTimestamps ? 'Hide\nTimestamps' : 'Show\nTimestamps',
        backgroundColor: const Color(
          0xFF4F46E5,
        ), // web Show Timestamps (darkened for white text)

        onPressed: _toggleTimestamps,
      ),
      if (_currentUserIsAdmin)
        _buildCompressedActionChip(
          label: 'Delete Messages',
          backgroundColor: const Color(0xFF6D28D9), // web Delete (violet-700)
          onPressed: _adminDeleteAllMessages,
        ),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Transform.translate(
        offset: const Offset(-2, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: _buildTwoRowActions(allButtons),
        ),
      ),
    );
  }

  void _insertOtherUserFirstName() {
    // Capitalize the first letter.
    final raw = widget.otherUser.firstName.trim();
    if (raw.isEmpty) return;
    final firstName = raw[0].toUpperCase() + raw.substring(1);

    final text = _messageController.text;
    final sel = _messageController.selection;
    // Insert at the caret (replacing any selected range); fall back to the end
    // when there's no valid selection.
    final int start = sel.isValid ? sel.start : text.length;
    final int end = sel.isValid ? sel.end : text.length;
    final before = text.substring(0, start);
    final after = text.substring(end);

    // Add exactly one separating space on each side, but never a double: skip
    // the space if one already exists there. (e.g. caret between "this" and
    // "is" → "this Amol is", reusing the existing space, adding one after.)
    final spaceBefore = (before.isEmpty || RegExp(r'\s$').hasMatch(before))
        ? ''
        : ' ';
    // Inserting into an empty input adds a single trailing space so the next
    // word is separated and the caret lands ready to type. Otherwise: no
    // trailing space at the very end, and don't double up when the following
    // text already starts with whitespace.
    final bool inputIsEmpty = before.isEmpty && after.isEmpty;
    final spaceAfter = inputIsEmpty
        ? ' '
        : (after.isEmpty || RegExp(r'^\s').hasMatch(after))
        ? ''
        : ' ';

    final inserted = '$spaceBefore$firstName$spaceAfter';
    final newText = '$before$inserted$after';
    final caret = (before + inserted).length;

    _messageController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: caret),
      composing: TextRange.empty,
    );
    _inputFocusNode.requestFocus();
  }

  Future<void> _pasteFromClipboard() async {
    // Try clipboard media first — a copied image/video file, then raw image
    // data (screenshots). Fall back to plain text if there's no media.
    if (await _tryPasteClipboardMedia()) {
      return;
    }

    // Fall back to plain text.
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      final current = _messageController.text;
      final newText = current.isEmpty ? text : '$current$text';
      _replaceInputTextWithSanitized(newText);
    } else if (mounted) {
      _showTopBanner(
        'Clipboard is empty.',
        backgroundColor: const Color(0xFF1F2937),
        icon: Icons.info_outline,
        autoHideAfter: const Duration(seconds: 2),
      );
    }
  }

  Widget _buildTwoRowActions(List<Widget> allButtons) {
    const int itemsPerRow = 6;
    final topRow = allButtons.take(itemsPerRow).toList();
    final bottomRow = <Widget>[
      _buildCompressedActionChip(
        label: widget.otherUser.firstName,
        backgroundColor: const Color(0xFF0F766E), // web partner-name button
        onPressed: _insertOtherUserFirstName,
      ),
      _buildCompressedActionChip(
        label: 'Paste',
        backgroundColor: const Color(0xFF1D4ED8), // web Paste (blue-700)
        onPressed: _pasteFromClipboard,
      ),
      _buildCompressedActionChip(
        label: 'Common\nPhrases',
        backgroundColor: const Color(
          0xFFEC4899,
        ), // web Common Phrases (pink-500)
        onPressed: _showCommonPhrasesModal,
      ),
      ...allButtons.skip(itemsPerRow),
    ];

    Widget buildFittedRow(List<Widget> rowButtons) {
      if (rowButtons.isEmpty) return const SizedBox.shrink();

      return LayoutBuilder(
        builder: (context, constraints) {
          const gap = 3.0;
          final totalGap = gap * (rowButtons.length - 1);
          final itemWidth = math.max(
            48.0,
            (constraints.maxWidth - totalGap) / rowButtons.length,
          );

          return Row(
            children: [
              for (int i = 0; i < rowButtons.length; i++) ...[
                SizedBox(width: itemWidth, child: rowButtons[i]),
                if (i < rowButtons.length - 1) const SizedBox(width: gap),
              ],
            ],
          );
        },
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildFittedRow(topRow),
        const SizedBox(height: 2),
        buildFittedRow(bottomRow),
      ],
    );
  }

  Future<void> _showAutoCorrectionDictionaryModal() async {
    _autoCorrectionWrongController.clear();
    _autoCorrectionCorrectController.clear();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      requestFocus: false,
      backgroundColor: const Color(0xFF161625),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            Widget buildMappingsTable(Map<String, String> mappings) {
              if (mappings.isEmpty) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF202036),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: const Text(
                    'No mappings yet',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                );
              }

              return Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF202036),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A47),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(11),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Wrong',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Correct',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ...mappings.entries.map(
                      (entry) => Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                entry.key,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                entry.value,
                                style: const TextStyle(
                                  color: Color(0xFF86EFAC),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 12,
                  bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Center(
                        child: Container(
                          width: 42,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      const Text(
                        'Auto Correction Dictionary',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: _autoCorrectionEnabled,
                        activeThumbColor: const Color(0xFFF59E0B),
                        title: const Text(
                          'Auto correction',
                          style: TextStyle(color: Colors.white),
                        ),
                        subtitle: const Text(
                          'Replace known wrong words in voice input',
                          style: TextStyle(color: Colors.white70),
                        ),
                        onChanged: (value) {
                          setState(() => _autoCorrectionEnabled = value);
                          unawaited(_saveAutoCorrectionPreferences());
                          setModalState(() {});
                        },
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Manual mappings',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _autoCorrectionWrongController,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'wrong',
                                hintStyle: const TextStyle(
                                  color: Colors.white54,
                                ),
                                filled: true,
                                fillColor: const Color(0xFF252542),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide.none,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 10,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _autoCorrectionCorrectController,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'correct',
                                hintStyle: const TextStyle(
                                  color: Colors.white54,
                                ),
                                filled: true,
                                fillColor: const Color(0xFF252542),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide.none,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 10,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () {
                            final wrong = _autoCorrectionWrongController.text
                                .trim()
                                .toLowerCase();
                            final correct = _autoCorrectionCorrectController
                                .text
                                .trim();
                            if (wrong.isEmpty || correct.isEmpty) return;

                            setState(() {
                              _manualAutoCorrectionMappings[wrong] = correct;
                            });
                            unawaited(_saveAutoCorrectionPreferences());
                            setModalState(() {});
                            _autoCorrectionWrongController.clear();
                            _autoCorrectionCorrectController.clear();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFF59E0B),
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Add mapping'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      buildMappingsTable(_manualAutoCorrectionMappings),
                      const SizedBox(height: 14),
                      const Text(
                        'Learned items',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      buildMappingsTable(_learnedAutoCorrectionMappings),
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

  static const int _kMobileMaxPins = 2;

  Future<void> _showCommonPhrasesModal() async {
    final TextEditingController phraseInputController = TextEditingController();
    List<CommonPhrase> allPhrases = [];
    bool isLoading = true;
    bool isSaving = false;
    bool isGenerating = false;
    bool isPinning = false;
    String? errorText;
    bool showPinnedTab = false; // false = All, true = Pinned

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      requestFocus: false,
      useSafeArea: true,
      backgroundColor: const Color(0xFF161625),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (modalContext) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            // ── data helpers ──────────────────────────────────────────────
            Future<void> loadPhrases() async {
              try {
                setModalState(() {
                  isLoading = true;
                  errorText = null;
                });
                final fetched = await _commonPhrasesApi.fetch(limit: 20);
                fetched.sort((a, b) {
                  if (a.isPinnedMobile && b.isPinnedMobile) {
                    return (a.pinOrderMobile ?? 99).compareTo(
                      b.pinOrderMobile ?? 99,
                    );
                  }
                  if (a.isPinnedMobile) return -1;
                  if (b.isPinnedMobile) return 1;
                  return b.usageCount.compareTo(a.usageCount);
                });
                if (ctx.mounted) {
                  setModalState(() {
                    allPhrases = fetched;
                    isLoading = false;
                  });
                }
              } catch (e) {
                if (ctx.mounted) {
                  setModalState(() {
                    isLoading = false;
                    errorText = 'Failed to load phrases';
                  });
                }
              }
            }

            if (isLoading && allPhrases.isEmpty) loadPhrases();

            final pinned = allPhrases.where((p) => p.isPinnedMobile).toList();
            final unpinned = allPhrases
                .where((p) => !p.isPinnedMobile)
                .toList();
            final displayed = showPinnedTab ? pinned : unpinned;

            // ── actions ───────────────────────────────────────────────────
            Future<void> addPhrase() async {
              final text = phraseInputController.text.trim();
              if (text.isEmpty) return;
              setModalState(() {
                isSaving = true;
                errorText = null;
              });
              try {
                final saved = await _commonPhrasesApi.savePhrase(text);
                phraseInputController.clear();
                // Insert at top of unpinned list optimistically, then refresh
                if (ctx.mounted) {
                  setModalState(() {
                    allPhrases = [saved, ...allPhrases];
                    isSaving = false;
                  });
                }
                await loadPhrases();
              } catch (e) {
                if (ctx.mounted)
                  setModalState(() {
                    errorText = 'Failed to save phrase';
                  });
              } finally {
                if (ctx.mounted) setModalState(() => isSaving = false);
              }
            }

            Future<void> deletePhrase(CommonPhrase phrase) async {
              int? id = phrase.id;
              if (id == null) {
                try {
                  final saved = await _commonPhrasesApi.savePhrase(
                    phrase.phrase,
                  );
                  id = saved.id;
                } catch (_) {}
              }
              if (id == null) return;
              try {
                await _commonPhrasesApi.deletePhrase(id);
                await loadPhrases();
                unawaited(_loadCommonPhrases());
              } catch (e) {
                if (ctx.mounted)
                  setModalState(() => errorText = 'Failed to delete phrase');
              }
            }

            Future<void> generateWithAi() async {
              setModalState(() {
                isGenerating = true;
                errorText = null;
              });
              try {
                final generated = await _commonPhrasesApi.generatePhrase();
                if (ctx.mounted) {
                  // Set text then force a rebuild so the field shows the value
                  phraseInputController.value = TextEditingValue(
                    text: generated,
                    selection: TextSelection.collapsed(
                      offset: generated.length,
                    ),
                  );
                  setModalState(() => isGenerating = false);
                }
              } catch (e) {
                if (ctx.mounted) {
                  setModalState(() {
                    isGenerating = false;
                    final msg = e.toString().replaceFirst('Exception: ', '');
                    errorText = 'AI error: $msg';
                  });
                }
              }
            }

            Future<void> togglePin(CommonPhrase phrase) async {
              int? id = phrase.id;
              if (id == null) {
                try {
                  setModalState(() => isPinning = true);
                  final saved = await _commonPhrasesApi.savePhrase(
                    phrase.phrase,
                  );
                  id = saved.id;
                } catch (e) {
                  if (ctx.mounted)
                    setModalState(() {
                      isPinning = false;
                      errorText = 'Could not save phrase';
                    });
                  return;
                }
              }
              if (id == null) return;
              setModalState(() {
                isPinning = true;
                errorText = null;
              });
              try {
                if (phrase.isPinnedMobile) {
                  await _commonPhrasesApi.unpinPhrase(id);
                } else {
                  if (pinned.length >= _kMobileMaxPins) {
                    setModalState(() {
                      isPinning = false;
                      errorText =
                          'Max $_kMobileMaxPins pins on mobile — unpin one first';
                    });
                    return;
                  }
                  await _commonPhrasesApi.pinPhrase(id);
                }
                await loadPhrases();
                unawaited(_loadCommonPhrases());
              } catch (e) {
                if (ctx.mounted) {
                  setModalState(
                    () => errorText = e.toString().replaceFirst(
                      'Exception: ',
                      '',
                    ),
                  );
                }
              } finally {
                if (ctx.mounted) setModalState(() => isPinning = false);
              }
            }

            // ── phrase row ────────────────────────────────────────────────
            Widget buildPhraseRow(CommonPhrase phrase) {
              final isPinnedMobile = phrase.isPinnedMobile;
              final isPinnedWeb = phrase.isPinnedWeb;
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF202036),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isPinnedMobile
                        ? const Color(0xFF6D28D9).withValues(alpha: 0.55)
                        : Colors.white.withValues(alpha: 0.07),
                  ),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 2,
                  ),
                  dense: true,
                  // Pin icon on the left (mobile pin toggle)
                  leading: GestureDetector(
                    onTap: isPinning ? null : () => togglePin(phrase),
                    child: AnimatedContainer(
                      duration: Duration.zero,
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: isPinnedMobile
                            ? const Color(0xFF6D28D9)
                            : const Color(0xFF2A2A47),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isPinnedMobile
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                        size: 16,
                        color: isPinnedMobile
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                  title: Text(
                    phrase.phrase,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        Text(
                          phrase.isDefault ? 'DEFAULT' : 'CUSTOM',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.35),
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                        if (isPinnedWeb) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF0E7490,
                              ).withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: const Color(
                                  0xFF0E7490,
                                ).withValues(alpha: 0.5),
                              ),
                            ),
                            child: const Text(
                              'WEB PIN',
                              style: TextStyle(
                                color: Color(0xFF67E8F9),
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  trailing: GestureDetector(
                    onTap: () => deletePhrase(phrase),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFDC2626).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: const Color(0xFFDC2626).withValues(alpha: 0.4),
                        ),
                      ),
                      child: const Text(
                        'Del',
                        style: TextStyle(
                          color: Color(0xFFF87171),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }

            // ── tab toggle ────────────────────────────────────────────────
            Widget buildTabToggle() {
              Widget tab(String label, bool active, {int? badge}) {
                return GestureDetector(
                  onTap: () =>
                      setModalState(() => showPinnedTab = label == 'Pinned'),
                  child: AnimatedContainer(
                    duration: Duration.zero,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF6D28D9)
                          : const Color(0xFF252542),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            color: active ? Colors.white : Colors.white54,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: active
                                  ? Colors.white.withValues(alpha: 0.25)
                                  : Colors.white.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$badge',
                              style: TextStyle(
                                color: active ? Colors.white : Colors.white54,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }

              return Row(
                children: [
                  tab('Unpinned', !showPinnedTab, badge: unpinned.length),
                  const SizedBox(width: 8),
                  tab('Pinned', showPinnedTab, badge: pinned.length),
                  const Spacer(),
                  if (pinned.length < _kMobileMaxPins)
                    Text(
                      '${_kMobileMaxPins - pinned.length} pin slot${_kMobileMaxPins - pinned.length == 1 ? '' : 's'} free',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.3),
                        fontSize: 11,
                      ),
                    )
                  else
                    Row(
                      children: [
                        Icon(
                          Icons.lock_outline,
                          size: 12,
                          color: Colors.white.withValues(alpha: 0.4),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Pins full',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                ],
              );
            }

            // ── root layout ───────────────────────────────────────────────
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 12,
                bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.85,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // drag handle
                    Center(
                      child: Container(
                        width: 42,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),

                    // title row
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Common Phrases',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                'Tap the pin icon to toggle pinned status',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.4),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () => Navigator.of(ctx).pop(),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
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
                    const SizedBox(height: 14),

                    // full-width input with animated gradient border while generating
                    _PhraseInputField(
                      controller: phraseInputController,
                      isGenerating: isGenerating,
                      onSubmitted: addPhrase,
                    ),
                    const SizedBox(height: 8),
                    // action buttons row
                    Row(
                      children: [
                        Expanded(
                          child: _buildModalTextButton(
                            label: 'Add Phrase',
                            icon: Icons.add,
                            color: const Color(0xFF6D28D9),
                            loading: isSaving,
                            onTap: isSaving ? null : addPhrase,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildModalTextButton(
                            label: 'Generate with AI',
                            icon: Icons.auto_awesome,
                            color: const Color(0xFF0F766E),
                            loading: isGenerating,
                            onTap: isGenerating ? null : generateWithAi,
                          ),
                        ),
                      ],
                    ),

                    // error text
                    if (errorText != null) ...[
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          const Icon(
                            Icons.error_outline,
                            color: Color(0xFFF87171),
                            size: 14,
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              errorText!,
                              style: const TextStyle(
                                color: Color(0xFFF87171),
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),

                    // tab toggle
                    if (!isLoading && allPhrases.isNotEmpty) ...[
                      buildTabToggle(),
                      const SizedBox(height: 10),
                    ],

                    // list
                    Expanded(
                      child: isLoading
                          ? const Center(
                              child: CircularProgressIndicator(
                                color: Color(0xFF6D28D9),
                              ),
                            )
                          : allPhrases.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.chat_bubble_outline,
                                    size: 40,
                                    color: Colors.white.withValues(alpha: 0.15),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'No phrases yet.\nType one above and tap +',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.35,
                                      ),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : displayed.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    showPinnedTab
                                        ? Icons.push_pin_outlined
                                        : Icons.chat_bubble_outline,
                                    size: 36,
                                    color: Colors.white.withValues(alpha: 0.15),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    showPinnedTab
                                        ? 'No pinned phrases yet.\nTap the pin icon on any phrase.'
                                        : 'All phrases are pinned!',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.35,
                                      ),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              itemCount: displayed.length,
                              itemBuilder: (_, i) =>
                                  buildPhraseRow(displayed[i]),
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
    phraseInputController.dispose();
    // Refresh bar after modal closes in case pins changed
    unawaited(_loadCommonPhrases());
  }

  Widget _buildModalTextButton({
    required String label,
    required IconData icon,
    required Color color,
    required bool loading,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Duration.zero,
        height: 40,
        decoration: BoxDecoration(
          color: onTap == null ? color.withValues(alpha: 0.35) : color,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: Colors.white, size: 15),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  /// Builds the Send File button with an upload progress border.
  /// When uploads are active, a green border fills around the chip
  /// proportional to the overall upload progress (0% to 100%).
  Widget _buildSendFileChip() {
    return ListenableBuilder(
      listenable: _mediaUploadState,
      builder: (context, _) {
        final progress = _mediaUploadState.overallProgress;
        final isUploading = _mediaUploadState.hasActiveUploads;

        return Stack(
          alignment: Alignment.center,
          children: [
            // Progress border (shown when uploading)
            if (isUploading && progress != null)
              SizedBox(
                width: 62,
                height: 40,
                child: CustomPaint(
                  painter: _ProgressBorderPainter(
                    progress: progress,
                    color: const Color(0xFF25D366),
                    borderRadius: 12,
                    strokeWidth: 2.5,
                  ),
                ),
              ),
            // The actual button
            Stack(
              clipBehavior: Clip.none,
              children: [
                _buildCompressedActionChip(
                  label: _isActivelyUploading
                      ? '${(_activeUploadProgress * 100).toInt()}%'
                      : isUploading && progress != null
                      ? '${(progress * 100).toInt()}%'
                      : 'Send File',
                  backgroundColor: _isActivelyUploading
                      ? const Color(0xFF7C3AED)
                      : isUploading
                      ? const Color(0xFF7C3AED)
                      : const Color(
                          0xFF16A34A,
                        ), // web Send File (darkened green-600 for white text)
                  onPressed: _isActivelyUploading || _pendingFile != null
                      ? _reopenFileUploadModal
                      : _pendingMediaItems != null &&
                            _pendingMediaItems!.isNotEmpty
                      ? _resumePendingMedia
                      : _showAttachmentMenu,
                ),
                // Badge showing pending file count (pending media or pending file)
                if (_pendingMediaItems != null &&
                    _pendingMediaItems!.isNotEmpty)
                  Positioned(
                    top: -4,
                    right: -4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      constraints: const BoxConstraints(
                        minWidth: 18,
                        minHeight: 18,
                      ),
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '${_pendingMediaItems!.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  )
                else if (_pendingFile != null && !_isActivelyUploading)
                  Positioned(
                    top: -4,
                    right: -4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      constraints: const BoxConstraints(
                        minWidth: 18,
                        minHeight: 18,
                      ),
                      decoration: const BoxDecoration(
                        color: Colors.orange,
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: Text(
                          '1',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildCompressedActionChip({
    required String label,
    required Color backgroundColor,
    required VoidCallback onPressed,
  }) {
    String formatLabel(String source) {
      final trimmed = source.trim();
      if (trimmed.isEmpty || trimmed.contains('\n')) return trimmed;

      final words = trimmed.split(RegExp(r'\s+'));
      if (words.length == 1) return trimmed;
      if (words.length == 2) return '${words.first}\n${words.last}';

      final splitIndex = (words.length / 2).ceil();
      return '${words.take(splitIndex).join(' ')}\n${words.skip(splitIndex).join(' ')}';
    }

    return _TapHighlightChip(
      onPressed: () {
        HapticFeedback.selectionClick();
        onPressed();
      },
      backgroundColor: backgroundColor,
      child: Text(
        formatLabel(label),
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
    );
  }

  void _onTextChanged(String text) {
    if (Platform.isAndroid && text.contains('\uFFFC')) {
      debugPrint(
        '[ClipboardPaste] detected Android rich-content marker (U+FFFC)',
      );
      final sanitized = text.replaceAll('\uFFFC', '');
      if (sanitized != text) {
        _replaceInputTextWithSanitized(sanitized);
      }
      unawaited(_tryHandleClipboardImagePaste(showNoImageBanner: true));
      return;
    }

    final normalizedText = _normalizeTextForEmojiCompatibility(text);
    if (normalizedText != text) {
      _replaceInputTextWithSanitized(normalizedText);
      return;
    }

    if (text.isEmpty || _isStampOnlyDraft(text)) {
      if (_isTyping) {
        _stopTyping();
      }
      // Re-seed stamp prefix when input is cleared while stamp mode is on
      if (text.isEmpty && _stampEnabled) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _seedStampPrefixInInput();
        });
      }
      return;
    }

    // Only update typing state if not already typing
    if (!_isTyping) {
      _startTyping();
    }

    // Apply local auto-correction with a tiny debounce so typing stays smooth.
    _autoCorrectionPreviewTimer?.cancel();
    _autoCorrectionPreviewTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      final currentText = _messageController.text;
      final corrected = _applyAutoCorrection(
        currentText,
        learn: false,
        verboseLogs: false,
        logPrefix: '[AutoCorrect:preview]',
        trimInput: false,
      );
      if (corrected != currentText) {
        debugPrint('[AutoCorrect:preview] "$currentText" -> "$corrected"');
        _replaceInputTextWithSanitized(corrected);
      }
    });

    // Send live preview (throttled) - no setState here
    _sendTypingUpdate(text);

    // Reset typing timer
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), () {
      if (_isTyping) {
        _stopTyping();
      }
    });
  }

  bool _isComposerMultiline(String text, TextStyle style, double maxWidth) {
    if (text.trim().isEmpty) return false;

    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 6,
    );

    painter.layout(maxWidth: math.max(1, maxWidth));
    return painter.computeLineMetrics().length > 1;
  }

  void _sendTypingUpdate(String text) {
    if (_isSelfChat) return;

    final typingPreview = _applyAutoCorrection(
      text,
      learn: false,
      verboseLogs: false,
      logPrefix: '[AutoCorrect:typing]',
      trimInput: false,
    );
    if (typingPreview != text) {
      debugPrint('[AutoCorrect:typing] "$text" -> "$typingPreview"');
    }

    // Throttle typing updates to avoid spamming
    final now = DateTime.now();
    if (_lastTypingUpdate != null) {
      final diff = now.difference(_lastTypingUpdate!);
      if (diff.inMilliseconds < 500) {
        // Too soon, schedule for later
        _typingUpdateThrottle?.cancel();
        _typingUpdateThrottle = Timer(const Duration(milliseconds: 500), () {
          _socketService.sendTypingUpdate(widget.otherUser.id, typingPreview);
          _lastTypingUpdate = DateTime.now();
        });
        return;
      }
    }

    // Send immediately
    _socketService.sendTypingUpdate(widget.otherUser.id, typingPreview);
    _lastTypingUpdate = now;
  }

  void _startTyping() {
    if (_isSelfChat) return;
    if (mounted) {
      setState(() => _isTyping = true);
    }
    _socketService.startTyping(widget.otherUser.id);
  }

  void _stopTyping() {
    if (mounted) {
      setState(() => _isTyping = false);
    }
    // Cancel any pending throttled typing update so it doesn't fire after stop
    _typingUpdateThrottle?.cancel();
    _typingUpdateThrottle = null;
    _autoCorrectionPreviewTimer?.cancel();
    // Send empty typing_update to explicitly clear live preview on receiver
    if (!_isSelfChat) {
      _socketService.sendTypingUpdate(widget.otherUser.id, '');
      _socketService.stopTyping(widget.otherUser.id);
    }
    _typingTimer?.cancel();
  }

  void _resetColor() {
    // Mark that we locally triggered the reset so we can suppress the echo
    _localColorResetPending = true;

    // Reset to default color
    const defaultColor = Color(0xFF121212);

    setState(() {
      _headerColor = defaultColor;
      _showResetButton = false;
    });

    // Persist the reset color
    _saveChatColor('#121212');

    // Emit reset color event (must be 'reset_color' so backend broadcasts to all devices)
    _socketService.emit('reset_color', {'recipient_id': widget.otherUser.id});

    // Add outgoing message about reset
    final resetMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch,
      senderId: _currentUserId!,
      recipientId: widget.otherUser.id,
      content: 'Reset bg color',
      messageType: 'system',
      timestamp: DateTime.now().toIso8601String(),
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      isRead: false,
      status: 'sent',
      threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
      reactions: {},
      isDeleted: false,
    );

    setState(() {
      _messages.insert(0, resetMessage);
    });

    // Only auto-scroll if user is at bottom, otherwise just show unread badge
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isAtBottom) {
        _scrollToBottom();
      }
    });

    debugPrint('ðŸŽ¨ Color reset to default');
  }

  void _changeColor() {
    _restoreInputFocusOnResume = false;
    _keepInputUnfocused();

    // Show full-screen color picker modal
    unawaited(
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => ColorPickerModal(
          onColorSelected: (selectedColor) {
            // Only send color to other user, don't change our own background
            final colorHex = selectedColor
                .toARGB32()
                .toRadixString(16)
                .substring(2)
                .toUpperCase();
            final colorPayload = {
              'recipient_id': widget.otherUser.id,
              'color': '#$colorHex',
              'sender_name': 'You',
            };
            if (_socketService.isConnected) {
              _socketService.emit('change_color', colorPayload);
            } else {
              // Offline — queue so it reaches the recipient once we reconnect.
              unawaited(
                SocketEventQueueService().queueEvent(
                  'change_color',
                  colorPayload,
                ),
              );
            }

            // Add outgoing system message to show we changed their color
            final colorMessage = Message(
              id: DateTime.now().millisecondsSinceEpoch,
              senderId: _currentUserId!,
              recipientId: widget.otherUser.id,
              content:
                  'You changed the bg color of ${widget.otherUser.firstName}',
              messageType: 'system',
              timestamp: DateTime.now().toIso8601String(),
              timestampMs: DateTime.now().millisecondsSinceEpoch,
              isRead: false,
              status: 'sent',
              threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
              reactions: {},
              isDeleted: false,
            );

            setState(() {
              _messages.insert(0, colorMessage);
            });

            // Only auto-scroll if user is at bottom, otherwise just show unread badge
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_isAtBottom) {
                _scrollToBottom();
              }
            });

            debugPrint(
              'ðŸŽ¨ Color sent to ${widget.otherUser.fullName}: #$colorHex',
            );

            _restoreInputFocusOnResume = false;
            _keepInputUnfocused();
          },
        ),
      ).whenComplete(() {
        if (!mounted) return;
        _restoreInputFocusOnResume = false;
        _keepInputUnfocused();
      }),
    );
  }

  /// Play doorbell sound, holding the AudioPlayer reference alive in a list
  /// so it isn't garbage-collected before playback completes.
  void _playDoorbellSound() {
    try {
      final player = AudioPlayer();
      _activeDoorbellPlayers.add(player);
      player.play(AssetSource('sounds/notif-sound.wav'));
      player.onPlayerComplete.listen((_) {
        _activeDoorbellPlayers.remove(player);
        player.dispose();
      });
    } catch (e) {
      debugPrint('Error playing doorbell sound: $e');
    }
  }

  void _ringDoorbell() {
    // Mark that we locally triggered the doorbell so we can suppress the echo
    _localDoorbellPending = true;

    // Send doorbell via Socket.IO, or queue it for replay if we're offline so
    // the notification still reaches the recipient once we reconnect.
    if (_socketService.isConnected) {
      _socketService.ringDoorbell(widget.otherUser.id);
    } else {
      unawaited(
        SocketEventQueueService().queueEvent('ring_doorbell', {
          'recipient_id': widget.otherUser.id,
        }),
      );
    }

    // Play doorbell notification sound (each tap gets its own player so rapid rings don't cancel each other)
    _playDoorbellSound();

    // Create a system message in chat to show doorbell was sent
    final doorbellMessage = Message(
      id: DateTime.now().millisecondsSinceEpoch,
      senderId: _currentUserId!,
      recipientId: widget.otherUser.id,
      content: 'Sent a notification',
      messageType: 'system',
      timestamp: DateTime.now().toIso8601String(),
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      isRead: false,
      status: 'sent',
      threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
      reactions: {},
      isDeleted: false,
    );

    setState(() {
      _messages.insert(0, doorbellMessage);
    });

    // Only auto-scroll if user is at bottom, otherwise just show unread badge
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isAtBottom) {
        _scrollToBottom();
      }
    });
  }

  /// Mirrors lobby's _getEffectiveStatus: corrects a stale 'online' flag by
  /// checking the lastSeen timestamp, so the chat header stays in sync with
  /// what the contact list shows.
  String _getEffectivePartnerStatus() {
    if (_partnerIsOnline) {
      return 'online';
    }

    if (_partnerStatus == 'online') {
      if (_partnerLastSeen != null) {
        try {
          final lastSeenTime = _parseUtcTimestamp(_partnerLastSeen!);
          final age = DateTime.now().difference(lastSeenTime);
          if (age.inMinutes <= 2) return 'online';
          return age.inHours < 24 ? 'away' : 'offline';
        } catch (_) {
          return 'online';
        }
      }
      return 'online';
    }

    if (_partnerStatus == 'away') {
      return 'away';
    }

    if (_partnerLastSeen != null) {
      try {
        final lastSeenTime = _parseUtcTimestamp(_partnerLastSeen!);
        final age = DateTime.now().difference(lastSeenTime);
        if (age.inHours < 24) {
          return 'away';
        }
      } catch (_) {}
    }

    return _partnerStatus;
  }

  /// Returns a UI scale factor that keeps large/high-DPI phones visually
  /// compact while preserving readability on smaller displays.
  double _uiScale(BuildContext context) {
    // Subscribe ONLY to the size/dpr aspects of MediaQuery — never viewInsets —
    // so opening/closing the keyboard does not rebuild the whole chat screen
    // (the message list in particular). The composer's slide is driven
    // separately via _keyboardInsetNotifier.
    final width = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    var scale = (width / 411.0).clamp(0.76, 1.0);

    if (width >= 480) {
      scale = scale * 0.88;
    } else if (width >= 430) {
      scale = scale * 0.91;
    } else if (width >= 390) {
      scale = scale * 0.95;
    }

    if (dpr >= 4.0) {
      scale = scale * 0.95;
    } else if (dpr >= 3.5) {
      scale = scale * 0.97;
    }

    return scale.clamp(0.74, 1.0);
  }

  void _clearIncomingCallNotificationsForPeer({String? callRoomId}) {
    unawaited(
      FirebaseMessagingService.instance.clearIncomingCallNotifications(
        otherUserId: widget.otherUser.id,
        callRoomId: callRoomId,
      ),
    );
  }

  bool _isCallAnsweredByCurrentUserForActiveChat(Map<String, dynamic> data) {
    final currentUserId = _currentUserId;
    if (currentUserId == null) return false;

    final callerId = _toInt(data['caller_id']);
    final calleeId = _toInt(data['callee_id']);

    return callerId == widget.otherUser.id && calleeId == currentUserId;
  }

  bool _isCallAnsweredForActiveIncomingModal(Map<String, dynamic> data) {
    final answeredCallId = _toInt(data['call_id'] ?? data['id']);
    final answeredRoomId =
        data['call_room_id']?.toString() ?? data['room']?.toString();

    if (_activeIncomingCallId != null && answeredCallId != null) {
      return _activeIncomingCallId == answeredCallId;
    }

    if (_activeIncomingCallRoomId != null &&
        answeredRoomId != null &&
        answeredRoomId.isNotEmpty) {
      return _activeIncomingCallRoomId == answeredRoomId;
    }

    return _activeIncomingCallRoute != null;
  }

  bool _isAcceptedOnOtherDeviceForActiveIncoming(Map<String, dynamic> data) {
    final currentUserId = _currentUserId;
    if (currentUserId == null) return false;
    if (PresenceService().isCallInProgress) return false;

    final state = (data['state']?.toString() ?? '').toLowerCase();
    if (state != 'accepted') return false;

    final actorUserId = _toInt(data['actor_user_id']);
    if (actorUserId != currentUserId) return false;

    return _isCallAnsweredForActiveIncomingModal(data);
  }

  bool _isAcceptedOnOtherDeviceCancelSignalForActiveIncoming(
    Map<String, dynamic> signalData,
  ) {
    if (PresenceService().isCallInProgress) return false;

    final nestedSignal = signalData['signal'];
    if (nestedSignal is! Map) return false;

    final type = (nestedSignal['type']?.toString() ?? '').toLowerCase();
    if (type != 'call-cancelled' && type != 'call_cancelled') return false;

    final acceptedOnOtherDevice =
        nestedSignal['accepted_on_other_device'] == true;
    final reason = (nestedSignal['reason']?.toString() ?? '').toLowerCase();
    if (!acceptedOnOtherDevice && reason != 'accepted_on_other_device') {
      return false;
    }

    final payload = <String, dynamic>{
      'call_room_id': nestedSignal['room'] ?? signalData['room'],
      'call_id': nestedSignal['call_id'] ?? signalData['call_id'],
      'id': nestedSignal['id'] ?? signalData['id'],
    };
    return _isCallAnsweredForActiveIncomingModal(payload);
  }

  /// The pending offer aged out — take down any incoming-call UI it opened.
  void _onPendingCallExpired() {
    if (!mounted) return;
    debugPrint('[ChatScreen] pending call expired — dismissing incoming call UI');
    _dismissIncomingCallModalIfOpen();
  }

  void _dismissIncomingCallModalIfOpen() {
    final route = _activeIncomingCallRoute;
    if (route == null || !mounted) return;

    final navigator = route.navigator;
    // Only pop when our tracked incoming modal is truly the top active route.
    // Force-removing stale/non-current routes can leave the UI on a black frame.
    if (navigator != null && route.isActive && route.isCurrent) {
      navigator.pop();
    }
    _activeIncomingCallRoute = null;
    _activeIncomingCallId = null;
    _activeIncomingCallRoomId = null;
  }

  void _showCallInProgressOnOtherDeviceIndicator() {
    _callInProgressOnOtherDeviceTimer?.cancel();
    if (!mounted) return;

    setState(() {
      _callInProgressOnOtherDevice = true;
    });

    // If canonical session state already marked this as active, do not auto-hide.
    if (_crossDeviceActiveCallRoomId != null) {
      return;
    }

    _callInProgressOnOtherDeviceTimer = Timer(const Duration(seconds: 12), () {
      if (!mounted) return;
      setState(() {
        _callInProgressOnOtherDevice = false;
      });
    });
  }

  void _handleCallSessionStateForChat(Map<String, dynamic> data) {
    if (!mounted) return;

    final currentUserId = _currentUserId;
    if (currentUserId == null) return;

    final state =
        (data['state']?.toString() ?? data['status']?.toString() ?? '')
            .toLowerCase();
    if (state.isEmpty) return;

    final roomId = data['call_room_id']?.toString() ?? data['room']?.toString();
    final actorUserId = _toInt(data['actor_user_id']);
    final otherUserId = _extractOtherParticipantIdFromSessionState(data);

    final isTerminal =
        state == 'ended' || state == 'declined' || state == 'cancelled';
    final isAcceptedByCurrentUserElsewhere =
        state == 'accepted' &&
        actorUserId == currentUserId &&
        otherUserId == widget.otherUser.id &&
        !PresenceService().isCallInProgress;

    if (isAcceptedByCurrentUserElsewhere) {
      _callInProgressOnOtherDeviceTimer?.cancel();
      setState(() {
        _crossDeviceActiveCallRoomId = roomId;
        _crossDeviceActivePeerId = otherUserId;
        _callInProgressOnOtherDevice = true;
      });
      _clearIncomingCallNotificationsForPeer(callRoomId: roomId);
      return;
    }

    if (isTerminal) {
      final matchesTrackedRoom =
          roomId != null &&
          _crossDeviceActiveCallRoomId != null &&
          roomId == _crossDeviceActiveCallRoomId;
      final matchesTrackedPeer =
          otherUserId != null &&
          _crossDeviceActivePeerId != null &&
          otherUserId == _crossDeviceActivePeerId;

      if (matchesTrackedRoom || matchesTrackedPeer || roomId == null || roomId.isEmpty) {
        _callInProgressOnOtherDeviceTimer?.cancel();
        setState(() {
          _crossDeviceActiveCallRoomId = null;
          _crossDeviceActivePeerId = null;
          _callInProgressOnOtherDevice = false;
        });
      }
    }
  }

  int? _extractOtherParticipantIdFromSessionState(Map<String, dynamic> data) {
    final currentUserId = _currentUserId;
    if (currentUserId == null) return null;

    final callerId = _toInt(data['caller_id']);
    final calleeId = _toInt(data['callee_id']);

    if (callerId == currentUserId && calleeId != null) return calleeId;
    if (calleeId == currentUserId && callerId != null) return callerId;

    final participantIds = data['participant_ids'];
    if (participantIds is List) {
      for (final pid in participantIds) {
        final parsed = _toInt(pid);
        if (parsed != null && parsed != currentUserId) {
          return parsed;
        }
      }
    }

    final room =
        data['call_room_id']?.toString() ?? data['room']?.toString() ?? '';
    if (room.isNotEmpty) {
      for (final part in room.split('_')) {
        final parsed = int.tryParse(part);
        if (parsed != null && parsed != currentUserId) {
          return parsed;
        }
      }
    }

    return null;
  }

  Future<void> _runActionSheetAction(FutureOr<void> Function() action) async {
    await _dismissActionsPanel();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    if (!mounted) {
      return;
    }

    _keepInputUnfocused();
    await action();
  }

  void _keepInputUnfocused() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_inputFocusNode.hasFocus) {
      _inputFocusNode.unfocus();
    }
  }

  Future<void> _dismissActionsPanel({bool restoreKeyboard = false}) async {
    if (!_isActionsPanelOpen) {
      if (restoreKeyboard) {
        await _restoreKeyboardAfterActionsPanelClose();
      } else {
        _keepInputUnfocused();
      }
      return;
    }

    final keyboardRestoreInset = _actionsPanelInset;
    if (restoreKeyboard && keyboardRestoreInset > 0) {
      _startInputModeLock(keyboardRestoreInset);
    }

    if (mounted) {
      setState(() {
        _isActionsPanelOpen = false;
        _actionsPanelFromKeyboard = false;
        _actionsPanelInset = 0;
      });
    }

    if (restoreKeyboard) {
      await _restoreKeyboardAfterActionsPanelClose();
    } else {
      _keepInputUnfocused();
    }
  }

  void _closeActionsPanel() {
    unawaited(_dismissActionsPanel());
  }

  Widget _buildActionSheetButton({
    required String label,
    required Color backgroundColor,
    required VoidCallback onPressed,
    Color foregroundColor = Colors.white,
  }) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        minimumSize: const Size(0, 46),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        elevation: 0,
      ),
      child: Text(
        label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
    );
  }

  Future<void> _restoreKeyboardAfterActionsPanelClose() async {
    if (!mounted) return;

    for (final delay in const [20, 90, 180]) {
      await Future<void>.delayed(Duration(milliseconds: delay));
      if (!mounted) return;

      _inputFocusNode.requestFocus();
      try {
        await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      } catch (_) {
        // Ignore transient platform timing issues while restoring the IME.
      }
    }
  }

  Widget _buildDoorbellComposerButton({
    required bool showLabel,
    required double iconSize,
    required EdgeInsetsGeometry padding,
  }) {
    const doorbellColor = Colors.white;
    // Use a fixed height so switching between label and icon doesn't cause layout jumps.
    final fixedHeight =
        iconSize + 12; // icon + vertical padding matches both states

    if (!showLabel) {
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
              padding: padding,
              decoration: const BoxDecoration(
                color: doorbellColor,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.notifications_active_outlined,
                color: Colors.black,
                size: iconSize,
              ),
            ),
          ),
        ),
      );
    }

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
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: doorbellColor,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Center(
              widthFactor: 1,
              child: const Text(
                'Ring Doorbell',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _currentBottomBarHeight() {
    final barBox =
        _bottomBarKey.currentContext?.findRenderObject() as RenderBox?;
    return barBox?.size.height ?? 82.0;
  }

  Widget _buildActionsPanelOverlay(BuildContext context) {
    final media = MediaQuery.of(context);
    final topInset = media.padding.top + kToolbarHeight + 8;
    final bottomBarHeight = _currentBottomBarHeight();
    final bottomInset = _actionsPanelFromKeyboard ? 0.0 : bottomBarHeight;
    final maxPanelHeight = _actionsPanelFromKeyboard
        ? _actionsPanelInset
        : math.min(
            math.max(
              150.0,
              media.size.height -
                  topInset -
                  (media.padding.bottom + bottomBarHeight),
            ),
            media.size.height * 0.56,
          );

    final actionButtons = <Widget>[
      _buildActionSheetButton(
        label: 'Change Color',
        backgroundColor: const Color(
          0xFF9333EA,
        ), // Change Color (darkened for white text)
        onPressed: () => _runActionSheetAction(() {
          _changeColor();
        }),
      ),
      if (_showResetButton)
        _buildActionSheetButton(
          label: 'Reset Color',
          backgroundColor: const Color(0xFF6B7280),
          onPressed: () => _runActionSheetAction(_resetColor),
        ),
      _buildActionSheetButton(
        label: 'Send Contact',
        backgroundColor: const Color(0xFF0EA5E9),
        onPressed: () => _runActionSheetAction(_pickContact),
      ),
      _buildActionSheetButton(
        label: 'Send File',
        backgroundColor: const Color(
          0xFF16A34A,
        ), // web Send File (darkened green-600 for white text)
        onPressed: () => _runActionSheetAction(_pickFile),
      ),
      if (Platform.isAndroid)
        _buildActionSheetButton(
          label: 'Paste Image',
          backgroundColor: const Color(0xFF2563EB),
          onPressed: () => _runActionSheetAction(
            () => _tryHandleClipboardImagePaste(showNoImageBanner: true),
          ),
        ),
      _buildActionSheetButton(
        label: 'Camera',
        backgroundColor: const Color(0xFF3B82F6),
        onPressed: () => _runActionSheetAction(_takePhoto),
      ),
      _buildActionSheetButton(
        label: 'Voice Message',
        backgroundColor: const Color(0xFFEF4444),
        onPressed: () => _runActionSheetAction(_showVoiceRecordingModal),
      ),
      _buildActionSheetButton(
        label: _autoTranslate ? 'Translate On' : 'Translate Off',
        backgroundColor: const Color(
          0xFFC026D3,
        ), // web Auto-Translate (darkened for white text)
        onPressed: () => _runActionSheetAction(_toggleAutoTranslate),
      ),
      _buildActionSheetButton(
        label: _showTimestamps ? 'Hide Timestamps' : 'Show Timestamps',
        backgroundColor: const Color(
          0xFF4F46E5,
        ), // web Show Timestamps (darkened for white text)

        onPressed: () {
          _toggleTimestamps();
        },
      ),
      _buildActionSheetButton(
        label: 'Export Chat',
        backgroundColor: const Color(0xFF6B7280), // web Export Chat (gray-500)
        onPressed: () => _runActionSheetAction(_exportChat),
      ),
      if (_currentUserIsAdmin)
        _buildActionSheetButton(
          label: 'Delete Messages',
          backgroundColor: const Color(0xFF6D28D9), // web Delete (violet-700)
          onPressed: () => _runActionSheetAction(_adminDeleteAllMessages),
        ),
    ];

    final panel = Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2B2F36),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const int columns = 5;
          const double hPad = 10.0; // horizontal padding inside scroll
          const double vPad = 12.0; // vertical padding inside scroll
          const double colSpacing = 8.0;
          const double rowSpacing = 8.0;
          const double rowHeight = 46.0; // matches button minimumSize height

          // Item width derived from available space so exactly 5 fit per row.
          final itemW =
              (constraints.maxWidth - hPad * 2 - colSpacing * (columns - 1)) /
              columns;
          final childAspectRatio = itemW / rowHeight;

          // Visible area: exactly 2 rows + spacing + padding.
          const double twoRowsH = vPad * 2 + rowHeight * 2 + rowSpacing;

          return SizedBox(
            height: math.min(twoRowsH, maxPanelHeight),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: hPad,
                vertical: vPad,
              ),
              child: GridView.count(
                crossAxisCount: columns,
                crossAxisSpacing: colSpacing,
                mainAxisSpacing: rowSpacing,
                childAspectRatio: childAspectRatio,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: actionButtons,
              ),
            ),
          );
        },
      ),
    );

    return Stack(
      children: [
        Positioned.fill(
          bottom: bottomBarHeight,
          child: GestureDetector(
            onTap: _closeActionsPanel,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: 8,
          right: 8,
          bottom: bottomInset,
          child: _actionsPanelFromKeyboard
              ? SizedBox(height: maxPanelHeight, child: panel)
              : ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxPanelHeight),
                  child: panel,
                ),
        ),
      ],
    );
  }


  /// Show user profile bottom sheet (Skype-style)
  void _showUserProfile() {
    final user = widget.otherUser;
    final avatarColor = _getAvatarColor();
    final effectiveStatus = _getEffectivePartnerStatus();
    final statusText = effectiveStatus == 'online'
        ? 'Online'
        : effectiveStatus == 'away'
        ? (_partnerLastSeen != null
              ? _formatLastSeen(_partnerLastSeen!)
              : 'Away')
        : (_partnerLastSeen != null
              ? _formatLastSeen(_partnerLastSeen!)
              : 'Offline');
    final statusColor = effectiveStatus == 'online'
        ? const Color(0xFF00E676)
        : effectiveStatus == 'away'
        ? const Color(0xFFFFC107)
        : Colors.grey;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final scale = _uiScale(context);
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1F1F1F),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(color: Colors.grey[800]!, width: 1),
          ),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20 * scale,
              20 * scale,
              20 * scale,
              20 * scale,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40 * scale,
                  height: 4 * scale,
                  decoration: BoxDecoration(
                    color: Colors.grey[600],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                SizedBox(height: 20 * scale),
                CircleAvatar(
                  radius: 48 * scale,
                  backgroundColor: avatarColor,
                  child: user.avatarUrl != null
                      ? ClipOval(
                          child: Image.network(
                            user.avatarUrl!,
                            width: 96 * scale,
                            height: 96 * scale,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => Text(
                              user.initials,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 36 * scale,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        )
                      : Text(
                          user.initials,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 36 * scale,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
                SizedBox(height: 16 * scale),
                Text(
                  user.fullName,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22 * scale,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  '@${user.username}',
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 14 * scale,
                  ),
                ),
                SizedBox(height: 8 * scale),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 12 * scale,
                    vertical: 4 * scale,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8 * scale,
                        height: 8 * scale,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      SizedBox(width: 6 * scale),
                      Text(
                        statusText,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 13 * scale,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 20 * scale),
                _buildProfileInfoRow(
                  Icons.email_outlined,
                  'Email',
                  user.email,
                  scale,
                ),
                if (user.bio != null && user.bio!.isNotEmpty)
                  _buildProfileInfoRow(
                    Icons.info_outline,
                    'Bio',
                    user.bio!,
                    scale,
                  ),
                _buildProfileInfoRow(
                  Icons.access_time,
                  'Timezone',
                  user.timezone,
                  scale,
                ),
                if (_partnerLastSeen != null &&
                    _getEffectivePartnerStatus() != 'online')
                  _buildProfileInfoRow(
                    Icons.visibility_outlined,
                    'Last seen',
                    _formatLastSeen(_partnerLastSeen!),
                    scale,
                  ),
                if (user.isAdmin || user.isAdminUser)
                  _buildProfileInfoRow(
                    Icons.shield_outlined,
                    'Role',
                    'Admin',
                    scale,
                  ),
                SizedBox(height: 16 * scale),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _showCallSetupModal(CallType.audio);
                        },
                        icon: Icon(Icons.call, size: 18 * scale),
                        label: Text(
                          'Call',
                          style: TextStyle(fontSize: 14 * scale),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF4CAF50),
                          side: const BorderSide(color: Color(0xFF4CAF50)),
                          padding: EdgeInsets.symmetric(vertical: 12 * scale),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: 12 * scale),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _showCallSetupModal(CallType.video);
                        },
                        icon: Icon(Icons.videocam, size: 18 * scale),
                        label: Text(
                          'Video',
                          style: TextStyle(fontSize: 14 * scale),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF3B82F6),
                          side: const BorderSide(color: Color(0xFF3B82F6)),
                          padding: EdgeInsets.symmetric(vertical: 12 * scale),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: MediaQuery.of(context).viewPadding.bottom + 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildProfileInfoRow(
    IconData icon,
    String label,
    String value, [
    double scale = 1.0,
  ]) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6 * scale),
      child: Row(
        children: [
          Icon(icon, color: Colors.grey[500], size: 20 * scale),
          SizedBox(width: 12 * scale),
          Text(
            '$label:',
            style: TextStyle(color: Colors.grey[500], fontSize: 13 * scale),
          ),
          SizedBox(width: 8 * scale),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: Colors.white, fontSize: 14 * scale),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Show call setup modal for video/audio calls
  void _showCallSetupModal(CallType callType) {
    // Outgoing call setup is presented full screen (like the incoming-call
    // setup, which already uses a fullscreenDialog route) so audio and video
    // device selection get the whole screen instead of a partial bottom sheet.
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (routeContext) => Scaffold(
          backgroundColor: const Color(0xFF1E293B),
          body: CallSetupModal(
            recipientName: widget.otherUser.fullName,
            callType: callType,
            onStartCall:
                (
                  localStream,
                  selectedMic,
                  selectedSpeaker,
                  selectedCamera,
                  videoEnabled,
                ) {
                  Navigator.pop(routeContext); // Close full-screen setup
                  _initiateCall(localStream, callType, videoEnabled);
                },
          ),
        ),
      ),
    );
  }

  /// Initiate call via CallService
  Future<void> _initiateCall(
    dynamic localStream,
    CallType callType,
    bool videoEnabled,
  ) async {
    final callService = CallService();

    // Reset the singleton to ensure clean state for new call
    callService.reset();

    final callTypeStr = callType == CallType.video ? 'video' : 'audio';

    // Set up socket signal handler
    _socketService.onSignal = (data) {
      callService.handleSignal(data);
    };

    // Use keyed listeners for proper event handling
    const callListenerKey = 'chat_outgoing_call';
    _socketService.addListener('callInitiated', callListenerKey, (
      Map<String, dynamic> data,
    ) {
      callService.handleCallInitiated(data);
    });

    _socketService.addListener('callEnded', callListenerKey, (
      Map<String, dynamic> data,
    ) {
      debugPrint('ðŸ“´ Call ended - cleaning up');
      callService.handleCallEnded();
    });

    _socketService.addListener('callDeclined', callListenerKey, (
      Map<String, dynamic> data,
    ) {
      debugPrint('âŒ Call declined by remote user');
      callService.handleCallDeclined();
    });

    // Set up error callback
    callService.onCallError = (error) {
      if (mounted) {
        _showTopSnackBar(
          SnackBar(
            content: Text('Call error: $error'),
            backgroundColor: Colors.red,
          ),
        );
      }
    };

    // Initialize and start the call (await to ensure ICE servers are fetched)
    await callService.initialize();
    await callService.initiateCall(
      calleeId: widget.otherUser.id,
      callType: callTypeStr,
      localStream: localStream,
    );

    if (!mounted) return;

    debugPrint(
      'ðŸŽ¥ Initiated ${callType.name} call with ${widget.otherUser.fullName}',
    );

    // Show outgoing call modal
    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => OutgoingCallModal(
          recipientName: widget.otherUser.fullName,
          callType: callTypeStr,
          callService: callService,
          onCancel: () {
            debugPrint(' Call cancelled by user');
            // Clean up listeners
            _socketService.removeListener('callInitiated', callListenerKey);
            _socketService.removeListener('callEnded', callListenerKey);
            _socketService.removeListener('callDeclined', callListenerKey);
          },
          onConnected: () {
            debugPrint(' Call connected!');
          },
        ),
      ),
    );

    // Clean up listeners when modal closes (if not already cleaned up)
    _socketService.removeListener('callInitiated', callListenerKey);
    _socketService.removeListener('callEnded', callListenerKey);
    _socketService.removeListener('callDeclined', callListenerKey);

    // Navigate to connected call screen if call connected
    // Trust the modal result 'connected' as authoritative â€” the call was connected.
    // Do NOT re-check callService.callState here because ICE renegotiation can
    // briefly set it to 'connecting' after initial connection, creating a race
    // condition that blocks navigation.
    if (result == 'connected' && mounted) {
      debugPrint(
        'ðŸ“ž Navigating to ConnectedCallScreen after modal returned: $result (callType: $callTypeStr)',
      );

      // Use post-frame callback to ensure widget tree is stable for release builds
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          debugPrint(
            'âŒ Widget unmounted - aborting navigation to ConnectedCallScreen',
          );
          return;
        }

        _performNavigation(callService, localStream, callTypeStr);
      });
    } else {
      debugPrint(
        'ðŸ“ž Modal result: $result, mounted: $mounted, callType: $callTypeStr - not navigating to ConnectedCallScreen',
      );
    }
  }

  /// Perform navigation to ConnectedCallScreen with proper error handling
  Future<void> _performNavigation(
    CallService callService,
    dynamic localStream,
    String callTypeStr,
  ) async {
    debugPrint(' _performNavigation called for $callTypeStr call');

    if (!mounted) {
      debugPrint('âŒ Widget unmounted in navigation method - aborting');
      return;
    }

    try {
      debugPrint(' About to push ConnectedCallScreen route');
      debugPrint(' Current call state: ${callService.callState}');

      // Use the safest possible navigation approach
      final navigator = Navigator.maybeOf(context);
      if (navigator == null) {
        debugPrint('âŒ Navigator is null - aborting navigation');
        return;
      }

      // Check localStream more thoroughly
      debugPrint(' localStream type: ${localStream.runtimeType}');
      debugPrint(
        'ðŸ“ž localStream is MediaStream: ${localStream is MediaStream}',
      );
      if (localStream != null && localStream is! MediaStream) {
        debugPrint(
          'âš ï¸ localStream is not a MediaStream: ${localStream.runtimeType}',
        );
      }

      // Check widget state
      debugPrint(' widget: available');
      debugPrint(' widget.otherUser: available');

      debugPrint(' Parameters validated - proceeding with navigation');
      debugPrint(' remoteName: ${widget.otherUser.fullName}');
      debugPrint(' callType: $callTypeStr');
      debugPrint(
        'ðŸ“ž localStream: ${localStream != null ? 'available' : 'null'}',
      );
      debugPrint(' callService.callState: ${callService.callState}');
      debugPrint(' callService.remoteUserId: ${callService.remoteUserId}');
      debugPrint(
        'ðŸ“ž callService.localStream: ${callService.localStream != null ? 'available' : 'null'}',
      );
      debugPrint(
        'ðŸ“ž callService.remoteStream: ${callService.remoteStream != null ? 'available' : 'null'}',
      );

      debugPrint(' Creating MaterialPageRoute...');
      final route = MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) {
          debugPrint(' Building ConnectedCallScreen widget');

          try {
            final remoteName = widget.otherUser.fullName;
            debugPrint(' Using remoteName: $remoteName');

            return ConnectedCallScreen(
              remoteName: remoteName,
              callType: callTypeStr,
              callService: callService,
              localStream: localStream,
              onChatPressed: () {
                Navigator.of(context).pop(); // Return to chat
              },
            );
          } catch (e) {
            debugPrint('âŒ Error creating ConnectedCallScreen: $e');
            // Return a fallback widget
            return Scaffold(
              appBar: AppBar(title: const Text('Call Error')),
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error, size: 64, color: Colors.red),
                    const SizedBox(height: 16),
                    const Text('Failed to initialize call screen'),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Go Back'),
                    ),
                  ],
                ),
              ),
            );
          }
        },
      );

      debugPrint(' MaterialPageRoute created, pushing...');
      final navigationResult = await navigator.push(route);

      debugPrint(
        'ðŸ“ž ConnectedCallScreen navigation completed for $callTypeStr call with result: $navigationResult',
      );
    } catch (e) {
      debugPrint(
        'âŒ Error navigating to ConnectedCallScreen for $callTypeStr call: $e',
      );
      debugPrint('âŒ Error type: ${e.runtimeType}');
      debugPrint('âŒ Stack trace: ${StackTrace.current}');

      // Try to show a user-friendly error
      if (mounted) {
        _showTopSnackBar(
          SnackBar(
            content: Text('Failed to open call screen: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  /// Handle incoming file message from web
  // ignore: unused_element
  void _handleIncomingFileMessage(Map<String, dynamic> data) {
    final now = DateTime.now();
    final fileUrl = data['file_url'] as String?;
    final fileName = data['file_name'] as String? ?? 'File';
    final fileType = data['file_type'] as String? ?? 'application/octet-stream';
    final fileSize = data['file_size'] as int? ?? 0;
    final messageType = fileType.startsWith('image/')
        ? 'image'
        : fileType.startsWith('video/')
        ? 'video'
        : 'file';

    final message = Message(
      id: data['message_id'] ?? now.millisecondsSinceEpoch,
      senderId: widget.otherUser.id,
      recipientId: _currentUserId!,
      content: fileName,
      messageType: messageType,
      timestamp: data['timestamp'] ?? now.toIso8601String(),
      timestampMs: data['timestamp_ms'] ?? now.millisecondsSinceEpoch,
      isRead: false,
      status: 'received',
      threadId: '',
      reactions: {},
      isDeleted: false,
      fileUrl: fileUrl,
      fileName: fileName,
      fileType: fileType,
      fileSize: fileSize,
    );

    setState(() {
      _messages.insert(0, message);
    });

    // Only auto-scroll if user is at bottom, otherwise just show unread badge
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isAtBottom) {
        _scrollToBottom();
      }
    });

    // Play notification sound
    try {
      _audioPlayer.play(AssetSource('sounds/notif-sound.wav'));
    } catch (e) {
      debugPrint('Error playing notification sound: $e');
    }
  }

  final ImagePicker _imagePicker = ImagePicker();

  Future<bool> _onComposerPasteShortcut() async {
    debugPrint('[ClipboardPaste] shortcut triggered');
    return await _tryPasteClipboardMedia();
  }

  /// Handles rich content inserted by the soft keyboard's image/GIF button
  /// (Android commitContent). Writes the bytes to a temp file and opens the
  /// existing media preview modal (which supports both images and video).
  Future<void> _onKeyboardContentInserted(
    KeyboardInsertedContent content,
  ) async {
    debugPrint(
      '[ClipboardPaste] keyboard inserted content: mime=${content.mimeType}, '
      'hasData=${content.hasData}, uri=${content.uri}',
    );

    final data = content.data;
    if (!content.hasData || data == null || data.isEmpty) {
      debugPrint('[ClipboardPaste] keyboard content has no usable bytes');
      if (mounted) {
        _showTopBanner(
          'Could not read the inserted media.',
          backgroundColor: const Color(0xFF1F2937),
          icon: Icons.info_outline,
          autoHideAfter: const Duration(seconds: 2),
        );
      }
      return;
    }

    try {
      final subtype = content.mimeType.split('/').last.trim();
      final ext = subtype.isNotEmpty ? subtype : 'bin';
      final tempDir = await getTemporaryDirectory();
      final fileName =
          'keyboard_media_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(data, flush: true);
      debugPrint(
        '[ClipboardPaste] wrote keyboard media: path=${file.path}, bytes=${data.length}',
      );

      if (!mounted) return;
      await _showFilePreviewModal(file, fileName, isFromCamera: false);
    } catch (e) {
      debugPrint('[ClipboardPaste] keyboard content paste failed: $e');
      if (mounted) {
        _showTopBanner(
          'Paste failed: $e',
          backgroundColor: const Color(0xFFB91C1C),
          icon: Icons.error_outline,
          autoHideAfter: const Duration(seconds: 3),
        );
      }
    }
  }

  void _onInputContextMenuOpened() {
    debugPrint('[ClipboardPaste] input context menu opened');
  }

  Future<void> _handleFileOpsMethodCall(MethodCall call) async {
    debugPrint('[ClipboardPaste] native callback: ${call.method}');
    if (call.method == 'onClipboardChanged') {
      final args = call.arguments;
      final hasImage = args is Map ? args['hasImage'] == true : false;
      debugPrint(
        '[ClipboardPaste] native onClipboardChanged hasImage=$hasImage',
      );
      if (hasImage &&
          Platform.isAndroid &&
          mounted &&
          _inputFocusNode.hasFocus) {
        unawaited(_tryHandleClipboardImagePaste());
      }
      return;
    }

    if (call.method != 'onClipboardImageAvailable') {
      return;
    }

    if (!Platform.isAndroid || !mounted || !_inputFocusNode.hasFocus) {
      debugPrint(
        '[ClipboardPaste] callback ignored: '
        'android=${Platform.isAndroid}, mounted=$mounted, hasFocus=${_inputFocusNode.hasFocus}',
      );
      return;
    }

    if (_isHandlingClipboardImagePaste) {
      debugPrint('[ClipboardPaste] callback ignored: already handling paste');
      return;
    }

    final now = DateTime.now();
    final lastAttempt = _lastClipboardPasteAttemptAt;
    if (lastAttempt != null &&
        now.difference(lastAttempt) < const Duration(milliseconds: 700)) {
      debugPrint('[ClipboardPaste] callback ignored: debounce');
      return;
    }
    _lastClipboardPasteAttemptAt = now;

    _isHandlingClipboardImagePaste = true;
    try {
      debugPrint('[ClipboardPaste] callback accepted, trying paste now');
      await _tryHandleClipboardImagePaste();
    } finally {
      _isHandlingClipboardImagePaste = false;
      debugPrint('[ClipboardPaste] callback handling finished');
    }
  }

  Future<void> _tryHandleClipboardImagePaste({
    bool showNoImageBanner = false,
  }) async {
    debugPrint(
      '[ClipboardPaste] tryHandle called: showNoImageBanner=$showNoImageBanner, '
      'platform='
      '${Platform.isAndroid
          ? 'android'
          : Platform.isMacOS
          ? 'macos'
          : Platform.isWindows
          ? 'windows'
          : Platform.isLinux
          ? 'linux'
          : 'other'}',
    );

    final handled = await _tryPasteClipboardMedia();
    if (!handled && showNoImageBanner && mounted) {
      _showTopBanner(
        'Clipboard has no image or video to paste.',
        backgroundColor: const Color(0xFF1F2937),
        icon: Icons.info_outline,
        autoHideAfter: const Duration(seconds: 2),
      );
    }
  }

  /// Tries to paste an image or video from the clipboard, opening the file
  /// preview modal when media is found. Returns `true` if a preview was opened
  /// (clipboard media handled), or `false` when the clipboard has no pasteable
  /// image/video so the caller can fall back to plain text.
  Future<bool> _tryPasteClipboardMedia() async {
    if (!(Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux ||
        Platform.isAndroid)) {
      debugPrint('[ClipboardPaste] unsupported platform, skipping');
      return false;
    }

    // 1) A real media file on the clipboard (image OR video copied from a file
    //    manager / gallery). Preserves the original format and extension.
    try {
      final media = await _fileOpsChannel.invokeMethod<Map<dynamic, dynamic>>(
        'getClipboardMediaFile',
      );
      final path = media?['path'] as String?;
      if (path != null && path.isNotEmpty) {
        final file = File(path);
        if (await file.exists() && await file.length() > 0) {
          final mediaName = media?['fileName'] as String?;
          final fileName = (mediaName != null && mediaName.isNotEmpty)
              ? mediaName
              : path.split('/').last;
          if (!mounted) return false;
          debugPrint(
            '[ClipboardPaste] opening preview for clipboard media file: $path',
          );
          await _showFilePreviewModal(file, fileName, isFromCamera: false);
          return true;
        }
      }
    } on MissingPluginException {
      // Older native build without media-file support — fall back to raw bytes.
      debugPrint(
        '[ClipboardPaste] getClipboardMediaFile missing; falling back',
      );
    } on PlatformException catch (e) {
      if (e.code != 'NO_IMAGE' && e.code != 'UNAVAILABLE') {
        debugPrint(
          '[ClipboardPaste] getClipboardMediaFile failed: ${e.code} ${e.message}',
        );
      }
    } catch (e) {
      debugPrint('[ClipboardPaste] getClipboardMediaFile error: $e');
    }

    // 2) Raw image data (e.g. screenshots copied as a bitmap).
    try {
      debugPrint('[ClipboardPaste] requesting getClipboardImagePngBytes');
      final bytes = await _fileOpsChannel.invokeMethod<Uint8List>(
        'getClipboardImagePngBytes',
      );
      if (bytes == null || bytes.isEmpty) {
        debugPrint('[ClipboardPaste] native returned no bytes');
        return false;
      }

      final tempDir = await getTemporaryDirectory();
      final fileName =
          'pasted_image_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      debugPrint(
        '[ClipboardPaste] wrote temp image file: path=${file.path}, bytes=${bytes.length}',
      );

      if (!mounted) return false;
      debugPrint('[ClipboardPaste] opening file preview modal');
      await _showFilePreviewModal(file, fileName, isFromCamera: false);
      debugPrint('[ClipboardPaste] preview modal opened');
      return true;
    } on PlatformException catch (e) {
      // Ignore unsupported platforms or empty clipboard image lookups.
      if (e.code == 'NO_IMAGE' || e.code == 'UNAVAILABLE') {
        debugPrint(
          '[ClipboardPaste] native says no image/unavailable: ${e.code}',
        );
        return false;
      }
      debugPrint('Clipboard image paste failed: ${e.code} ${e.message}');
      if (mounted) {
        _showTopBanner(
          'Paste failed: ${e.message ?? e.code}',
          backgroundColor: const Color(0xFFB91C1C),
          icon: Icons.error_outline,
          autoHideAfter: const Duration(seconds: 3),
        );
      }
      return false;
    } on MissingPluginException {
      debugPrint('Clipboard image paste failed: missing native plugin method');
      if (mounted) {
        _showTopBanner(
          'Paste not available yet. Please restart the app once.',
          backgroundColor: const Color(0xFFB91C1C),
          icon: Icons.error_outline,
          autoHideAfter: const Duration(seconds: 4),
        );
      }
      return false;
    } catch (e) {
      debugPrint('Clipboard image paste failed: $e');
      return false;
    }
  }

  /// Shows the WhatsApp-style attachment menu bottom sheet with
  /// Camera, Gallery, and Document options.
  Future<void> _showAttachmentMenu() async {
    _restoreInputFocusOnResume = false;
    _keepInputUnfocused();
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } catch (_) {
      // Ignore transient platform timing issues while hiding the IME.
    }

    if (!mounted) return;

    await AttachmentMenuSheet.show(
      context,
      onCameraTap: _handleAttachmentCamera,
      onGalleryTap: _handleAttachmentGallery,
      onDocumentTap: _pickFile,
    );
  }

  /// Handles the Camera option from the attachment menu.
  /// Shows a bottom sheet with Photo/Video capture options and recent media.
  Future<void> _handleAttachmentCamera() async {
    if (!mounted) return;

    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.white),
              title: const Text(
                'Take Photo',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam, color: Colors.white),
              title: const Text(
                'Record Video',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.white),
              title: const Text(
                'Recent Media',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(ctx, 'recent'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (result == null || !mounted) return;

    if (result == 'recent') {
      // Small delay to let the bottom sheet dismiss fully before opening picker
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      await _handleAttachmentGallery();
      return;
    }

    final preferVideo = result == 'video';
    final asset = await MediaPickerService.captureFromCamera(
      context,
      preferVideo: preferVideo,
    );
    if (asset == null || !mounted) return;

    // Navigate to the MediaPreviewScreen with the captured asset.
    // Result can be:
    //   - MediaSendResult: user sent — create optimistic messages and upload in background
    //   - MinimizedMediaResult: user minimized — store pending files for the badge
    final navResult = await Navigator.of(context).push<Object>(
      MaterialPageRoute(
        builder: (_) => MediaPreviewScreen(
          selectedAssets: [asset],
          recipientId: widget.otherUser.id,
          fromCamera: true,
          mediaUploadState: _mediaUploadState,
        ),
      ),
    );

    if (!mounted) return;

    if (navResult is MediaSendResult) {
      // User sent — create optimistic messages and upload in background (WhatsApp-style)
      await _handleMediaSendResult(navResult);
    } else if (navResult is MinimizedMediaResult) {
      setState(() {
        _pendingMediaItems = navResult.items;
        _pendingMediaCaption = navResult.caption;
      });
    }
  }

  /// Handles the Gallery option from the attachment menu.
  /// Opens the multi-select asset picker via MediaPickerService and
  /// navigates to the preview screen with selected assets.
  /// If the user presses back on the preview screen, re-opens the picker
  /// with the current selection preserved (Gallery → Preview → Back → Gallery).
  Future<void> _handleAttachmentGallery({
    List<AssetEntity>? preSelectedAssets,
  }) async {
    if (!mounted) return;

    final assets = await MediaPickerService.pickAssets(
      context,
      selectedAssets: preSelectedAssets,
    );
    if (assets == null || assets.isEmpty || !mounted) return;

    // Navigate to the MediaPreviewScreen with the selected assets.
    // Result can be:
    //   - MediaSendResult: user sent — create optimistic messages and upload in background
    //   - List<AssetEntity>: back navigation, re-open picker with these pre-selected
    //   - MinimizedMediaResult: user minimized, store pending files and show badge
    //   - null: cancelled
    final result = await Navigator.of(context).push<Object>(
      MaterialPageRoute(
        builder: (_) => MediaPreviewScreen(
          selectedAssets: assets,
          recipientId: widget.otherUser.id,
          fromCamera: false,
          mediaUploadState: _mediaUploadState,
        ),
      ),
    );

    if (!mounted) return;

    if (result is MediaSendResult) {
      // User sent — create optimistic messages and upload in background (WhatsApp-style)
      await _handleMediaSendResult(result);
    } else if (result is MinimizedMediaResult) {
      // User minimized — store pending files for the badge
      setState(() {
        _pendingMediaItems = result.items;
        _pendingMediaCaption = result.caption;
      });
    } else if (result is List<AssetEntity> && result.isNotEmpty) {
      // Back navigation — re-open the picker with selection preserved
      await _handleAttachmentGallery(preSelectedAssets: result);
    }
  }

  /// Resumes the pending media preview screen with previously minimized items.
  Future<void> _resumePendingMedia() async {
    final items = _pendingMediaItems;
    if (items == null || items.isEmpty || !mounted) return;

    // Clear pending state before navigating
    setState(() {
      _pendingMediaItems = null;
    });

    final result = await Navigator.of(context).push<Object>(
      MaterialPageRoute(
        builder: (_) => MediaPreviewScreen(
          selectedAssets: items,
          recipientId: widget.otherUser.id,
          fromCamera: false,
          mediaUploadState: _mediaUploadState,
        ),
      ),
    );

    if (!mounted) return;

    if (result is MediaSendResult) {
      // User sent — create optimistic messages and upload in background (WhatsApp-style)
      await _handleMediaSendResult(result);
    } else if (result is MinimizedMediaResult) {
      // Minimized again
      setState(() {
        _pendingMediaItems = result.items;
        _pendingMediaCaption = result.caption;
      });
    } else if (result is List<AssetEntity> && result.isNotEmpty) {
      await _handleAttachmentGallery(preSelectedAssets: result);
    }
  }

  /// Retries failed media uploads.
  ///
  /// For uploads that failed due to network errors and were queued in
  /// [MediaUploadRetryService], triggers an immediate retry attempt.
  /// For permanently failed uploads, clears them from tracking.
  void _retryFailedUploads() {
    final failedIds = _mediaUploadState.failedUploadIds;
    for (final id in failedIds) {
      _mediaUploadState.removeUpload(id);
    }
    // Also trigger any queued network-failed uploads to retry now
    MediaUploadRetryService().retryAll();
  }

  /// Handles [MediaSendResult] from the preview screen.
  /// Creates optimistic messages with pending status for immediate UI feedback,
  /// then uploads files in the background. This provides WhatsApp-style
  /// "instant send" UX where messages appear immediately while upload proceeds.
  Future<void> _handleMediaSendResult(MediaSendResult result) async {
    if (!mounted) return;

    final compressed = result.compressedFiles;
    final caption = result.caption;
    final fileIds = result.trackingIds;
    final uploadState = _mediaUploadState;

    // Create optimistic messages for immediate UI feedback
    final now = DateTime.now();
    final optimisticMessages = <Message>[];

    for (int i = 0; i < compressed.length; i++) {
      final file = compressed[i];
      final messageType = file.mimeType.startsWith('image/')
          ? 'image'
          : file.mimeType.startsWith('video/')
          ? 'video'
          : 'file';

      // Create optimistic message with pending status (clock icon)
      final message = Message(
        id:
            (int.tryParse(fileIds[i].split('_').first) ??
                now.millisecondsSinceEpoch) +
            i,
        senderId: _currentUserId!,
        recipientId: widget.otherUser.id,
        content: file.fileName,
        messageType: messageType,
        timestamp: now.toIso8601String(),
        timestampMs: now.millisecondsSinceEpoch + i,
        isRead: false,
        status: 'pending', // Pending until upload completes
        threadId: 'thread_${_currentUserId}_${widget.otherUser.id}',
        reactions: {},
        isDeleted: false,
        fileUrl: null, // Will be set after upload
        fileName: file.fileName,
        fileType: file.mimeType,
        fileSize: file.compressedSize,
        localFilePath: file.localFilePath,
        // Only attach caption to the first file
        caption: (i == 0 && caption.isNotEmpty) ? caption : null,
      );

      optimisticMessages.add(message);

      // Track this upload in the upload state
      if (uploadState != null) {
        uploadState.updateProgress(
          fileIds[i],
          UploadProgress(
            fileIndex: i,
            totalFiles: compressed.length,
            fileProgress: 0.0,
            status: UploadStatus.pending,
          ),
        );
      }
    }

    // Insert optimistic messages into chat UI immediately
    setState(() {
      _messages.insertAll(0, optimisticMessages.reversed);
    });

    _scrollToBottom();

    // Upload files in the background
    unawaited(
      _uploadMediaBatch(compressed, fileIds, caption, optimisticMessages),
    );
  }

  /// Uploads a batch of media files in the background.
  /// Updates message status and upload progress as uploads complete.
  Future<void> _uploadMediaBatch(
    List<CompressionResult> files,
    List<String> trackingIds,
    String caption,
    List<Message> optimisticMessages,
  ) async {
    try {
      final results = await MediaUploadService.uploadBatch(
        files: files,
        recipientId: widget.otherUser.id,
        caption: caption.isNotEmpty ? caption : null,
        onProgress: (progress) {
          // Update upload progress state
          if (progress.fileIndex < trackingIds.length) {
            _mediaUploadState.updateProgress(
              trackingIds[progress.fileIndex],
              progress,
            );
          }
        },
      );

      if (!mounted) return;

      await _processMediaBatchResults(
        results,
        files,
        trackingIds,
        caption,
        optimisticMessages,
      );
    } catch (e) {
      debugPrint('Error uploading media batch: $e');
    } finally {
      // Sweep any orphaned in-flight entries (e.g. uploadBatch threw, or a file
      // was confirmed via the socket echo rather than the REST result) so the
      // "Send File" chip doesn't stay stuck at 100%. Intentional failed/retrying
      // entries are preserved.
      for (final id in trackingIds) {
        _mediaUploadState.clearIfInFlight(id);
      }
    }
  }

  Future<void> _processMediaBatchResults(
    List<UploadResult> results,
    List<CompressionResult> files,
    List<String> trackingIds,
    String caption,
    List<Message> optimisticMessages,
  ) async {
    // Process upload results
    for (int i = 0; i < results.length; i++) {
      if (i >= optimisticMessages.length || i >= trackingIds.length) continue;

      final result = results[i];
      final message = optimisticMessages[i];
      final trackingId = trackingIds[i];

      if (result.success && result.message != null) {
        // Upload succeeded — update message with server data
        final serverMessage = result.message!;
        // Always use the caption from the original send — the server may not
        // echo it back, and the socket handler may have already replaced the
        // optimistic message before this path runs.
        final preservedCaption = (i == 0 && caption.isNotEmpty)
            ? caption
            : null;
        setState(() {
          final index = _messages.indexWhere((m) => m.id == message.id);
          if (index != -1) {
            _messages[index] = Message(
              id: serverMessage.id,
              senderId: serverMessage.senderId,
              recipientId: serverMessage.recipientId,
              content: serverMessage.content,
              messageType: serverMessage.messageType,
              timestamp: serverMessage.timestamp,
              timestampMs: serverMessage.timestampMs,
              isRead: serverMessage.isRead,
              status: 'sent',
              threadId: serverMessage.threadId,
              replyToId: serverMessage.replyToId,
              replyPreview: serverMessage.replyPreview,
              reactions: serverMessage.reactions,
              isDeleted: serverMessage.isDeleted,
              isTask: serverMessage.isTask,
              taskCreatedAt: serverMessage.taskCreatedAt,
              taskCompletedAt: serverMessage.taskCompletedAt,
              fileUrl: serverMessage.fileUrl,
              fileName: serverMessage.fileName ?? message.fileName,
              fileType: serverMessage.fileType ?? message.fileType,
              fileSize: serverMessage.fileSize ?? message.fileSize,
              caption: preservedCaption,
            );
          } else {
            // Socket already replaced the optimistic message — find the server
            // message by ID and patch its caption if it's missing.
            final serverIndex = _messages.indexWhere(
              (m) =>
                  m.id == serverMessage.id ||
                  // Also match by fileName+sender in case IDs differ between socket and REST
                  (m.senderId == serverMessage.senderId &&
                      m.fileName ==
                          (serverMessage.fileName ?? message.fileName) &&
                      m.status != 'pending'),
            );
            if (serverIndex != -1 && preservedCaption != null) {
              final existing = _messages[serverIndex];
              if (existing.caption == null || existing.caption!.isEmpty) {
                _messages[serverIndex] = Message(
                  id: existing.id,
                  senderId: existing.senderId,
                  recipientId: existing.recipientId,
                  content: existing.content,
                  messageType: existing.messageType,
                  timestamp: existing.timestamp,
                  timestampMs: existing.timestampMs,
                  isRead: existing.isRead,
                  status: existing.status,
                  threadId: existing.threadId,
                  replyToId: existing.replyToId,
                  replyPreview: existing.replyPreview,
                  reactions: existing.reactions,
                  isDeleted: existing.isDeleted,
                  isTask: existing.isTask,
                  taskCreatedAt: existing.taskCreatedAt,
                  taskCompletedAt: existing.taskCompletedAt,
                  fileUrl: existing.fileUrl,
                  fileName: existing.fileName,
                  fileType: existing.fileType,
                  fileSize: existing.fileSize,
                  caption: preservedCaption,
                );
              }
            }
          }
        });
        _mediaUploadState.removeUpload(trackingId);
      } else if (result.isNetworkError) {
        // Network failure — queue for retry and keep message as pending
        MediaUploadRetryService().queueUpload(
          bytes: files[i].bytes,
          fileName: files[i].fileName,
          mimeType: files[i].mimeType,
          recipientId: widget.otherUser.id,
          caption: i == 0 && caption.isNotEmpty ? caption : null,
          trackingId: trackingId,
        );
        _mediaUploadState.updateProgress(
          trackingId,
          UploadProgress(
            fileIndex: i,
            totalFiles: files.length,
            fileProgress: 0.0,
            status: UploadStatus.retrying,
          ),
        );
        // Message stays in pending state, will be updated by retry progress listener
      } else {
        // Permanent failure — mark message as failed
        setState(() {
          final index = _messages.indexWhere((m) => m.id == message.id);
          if (index != -1) {
            // Rebuild message with failed status
            _messages[index] = Message(
              id: message.id,
              senderId: message.senderId,
              recipientId: message.recipientId,
              content: message.content,
              messageType: message.messageType,
              timestamp: message.timestamp,
              timestampMs: message.timestampMs,
              isRead: message.isRead,
              status: 'failed',
              threadId: message.threadId,
              replyToId: message.replyToId,
              replyPreview: message.replyPreview,
              reactions: message.reactions,
              isDeleted: message.isDeleted,
              isTask: message.isTask,
              taskCreatedAt: message.taskCreatedAt,
              taskCompletedAt: message.taskCompletedAt,
              fileUrl: message.fileUrl,
              fileName: message.fileName,
              fileType: message.fileType,
              fileSize: message.fileSize,
            );
          }
        });
        _mediaUploadState.markFailed(
          trackingId,
          result.errorMessage ?? 'Upload failed',
        );
      }
    }

    // Persist the updated conversation
    await _persistConversationCacheSnapshot();
  }

  /// Shows a WhatsApp-style document selection menu with options:
  /// Browse documents, Choose from gallery, Scan document, Browse audio.
  Future<void> _pickFile() async {
    _restoreInputFocusOnResume = false;
    _keepInputUnfocused();
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } catch (_) {}

    if (!mounted) return;

    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Title
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Files',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            _buildDocMenuOption(
              ctx,
              icon: Icons.description_outlined,
              iconColor: const Color(0xFF7C3AED),
              title: 'Browse documents',
              subtitle: 'Select files up to 2 GB in size',
              value: 'documents',
            ),
            _buildDocMenuOption(
              ctx,
              icon: Icons.photo_library_outlined,
              iconColor: const Color(0xFF7C3AED),
              title: 'Choose from gallery',
              subtitle: 'Select original quality photos or videos',
              value: 'gallery',
            ),
            _buildDocMenuOption(
              ctx,
              icon: Icons.document_scanner_outlined,
              iconColor: const Color(0xFF7C3AED),
              title: 'Scan document',
              subtitle: 'Take photos of a document',
              value: 'scan',
            ),
            _buildDocMenuOption(
              ctx,
              icon: Icons.headphones_outlined,
              iconColor: const Color(0xFF7C3AED),
              title: 'Browse audio',
              subtitle: 'Select audio or music files',
              value: 'audio',
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );

    if (result == null || !mounted) return;

    switch (result) {
      case 'documents':
        await _browseDocuments();
        break;
      case 'gallery':
        await _handleAttachmentGallery();
        break;
      case 'scan':
        // Use camera to scan a document (photo mode)
        final asset = await MediaPickerService.captureFromCamera(context);
        if (asset != null && mounted) {
          final navResult = await Navigator.of(context).push<Object>(
            MaterialPageRoute(
              builder: (_) => MediaPreviewScreen(
                selectedAssets: [asset],
                recipientId: widget.otherUser.id,
                fromCamera: true,
                mediaUploadState: _mediaUploadState,
              ),
            ),
          );
          if (!mounted) break;
          if (navResult is MediaSendResult) {
            // User sent — create optimistic messages and upload in background (WhatsApp-style)
            await _handleMediaSendResult(navResult);
          } else if (navResult is MinimizedMediaResult) {
            setState(() {
              _pendingMediaItems = navResult.items;
              _pendingMediaCaption = navResult.caption;
            });
          }
        }
        break;
      case 'audio':
        await _browseAudio();
        break;
    }
  }

  Widget _buildDocMenuOption(
    BuildContext ctx, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required String value,
  }) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(color: Colors.grey[400], fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Browse documents using the system file picker (multi-select).
  Future<void> _browseDocuments() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        if (result.files.length == 1) {
          final file = result.files.first;
          if (file.path != null) {
            await _showFilePreviewModal(
              File(file.path!),
              file.name,
              isFromCamera: false,
            );
          }
        } else {
          final files = result.files
              .where((f) => f.path != null)
              .map((f) => File(f.path!))
              .toList();
          final names = result.files
              .where((f) => f.path != null)
              .map((f) => f.name)
              .toList();
          if (files.isNotEmpty) {
            await _showMultiFilePreviewModal(files, names);
          }
        }
      }
    } catch (e) {
      debugPrint('Error picking file: $e');
      if (mounted) {
        _showTopBanner(
          'Error picking file: $e',
          backgroundColor: const Color(0xFFB91C1C),
          icon: Icons.error_outline,
          autoHideAfter: const Duration(seconds: 3),
        );
      }
    }
  }

  /// Browse audio files using the system file picker (multi-select).
  Future<void> _browseAudio() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        if (result.files.length == 1) {
          final file = result.files.first;
          if (file.path != null) {
            await _showFilePreviewModal(
              File(file.path!),
              file.name,
              isFromCamera: false,
            );
          }
        } else {
          final files = result.files
              .where((f) => f.path != null)
              .map((f) => File(f.path!))
              .toList();
          final names = result.files
              .where((f) => f.path != null)
              .map((f) => f.name)
              .toList();
          if (files.isNotEmpty) {
            await _showMultiFilePreviewModal(files, names);
          }
        }
      }
    } catch (e) {
      debugPrint('Error picking audio: $e');
      if (mounted) {
        _showTopBanner(
          'Error picking audio: $e',
          backgroundColor: const Color(0xFFB91C1C),
          icon: Icons.error_outline,
          autoHideAfter: const Duration(seconds: 3),
        );
      }
    }
  }

  /// Shows a multi-file preview modal for sending multiple documents at once.
  Future<void> _showMultiFilePreviewModal(
    List<File> files,
    List<String> names,
  ) async {
    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (modalContext) {
        final media = MediaQuery.of(modalContext);
        final bottomInset = math.max(
          media.viewInsets.bottom,
          media.viewPadding.bottom,
        );

        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Container(
              height: media.size.height * 0.86,
              decoration: const BoxDecoration(
                color: Color(0xFF121733),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 14,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Column(
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 6),
                    width: 52,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.28),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 6, 10, 14),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF7C3AED,
                            ).withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.insert_drive_file,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Send ${files.length} Files',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                'Preview before sending',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.62),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white70),
                          onPressed: () => Navigator.pop(modalContext),
                          splashRadius: 22,
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: Colors.white10, height: 1, thickness: 1),
                  // File list
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      itemCount: files.length,
                      itemBuilder: (context, index) {
                        final file = files[index];
                        final name = names[index];
                        final mimeType =
                            lookupMimeType(file.path) ??
                            'application/octet-stream';
                        final fileSize = file.lengthSync();
                        final isImage = mimeType.startsWith('image/');

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF373B43),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              // Thumbnail or icon
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: isImage
                                      ? Image.file(file, fit: BoxFit.cover)
                                      : Icon(
                                          _getFileIcon(mimeType),
                                          color: Colors.white,
                                          size: 24,
                                        ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _truncateMiddle(name, maxChars: 36),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _formatFileSize(fileSize),
                                      style: TextStyle(
                                        color: Colors.grey[400],
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  // Send button
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.02),
                      border: Border(
                        top: BorderSide(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                    ),
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomInset),
                    child: Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 54,
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.pop(modalContext);
                                _pickFile();
                              },
                              icon: const Icon(Icons.refresh),
                              label: const Text(
                                'Replace',
                                style: TextStyle(fontSize: 15),
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.24),
                                  width: 1.4,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SizedBox(
                            height: 54,
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.pop(modalContext);
                                // Send all files through the same pipeline as
                                // single-file sends so each gets an optimistic
                                // pending message and, crucially, is queued to
                                // MediaUploadRetryService when offline — earlier
                                // this used _uploadAndSendFile, which silently
                                // dropped files on a network error instead of
                                // retrying them after reconnect.
                                for (int i = 0; i < files.length; i++) {
                                  final mimeType =
                                      lookupMimeType(files[i].path) ??
                                      'application/octet-stream';
                                  final uploadName = _resolveOutgoingFileName(
                                    originalName: names[i],
                                    mimeType: mimeType,
                                    isFromCamera: false,
                                  );
                                  _startFileUpload(
                                    files[i],
                                    uploadName,
                                    names[i],
                                    mimeType,
                                    idOffset: i,
                                  );
                                }
                              },
                              icon: const Icon(Icons.send_rounded),
                              label: Text(
                                'Send ${files.length}',
                                style: const TextStyle(fontSize: 15),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF7C3AED),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                elevation: 0,
                                padding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  bool _useFrontCamera = false;
  bool _isLaunchingCamera = false;

  Future<void> _retakePhotoFromPreview({bool toggleCamera = false}) async {
    if (!mounted) return;

    if (toggleCamera) {
      setState(() {
        _useFrontCamera = !_useFrontCamera;
      });
    }

    _restoreInputFocusOnResume = false;
    _keepInputUnfocused();

    // Let the preview sheet dismissal animation finish before relaunching camera.
    await Future<void>.delayed(const Duration(milliseconds: 160));
    if (!mounted) return;
    await _takePhoto();
  }

  /// Take a photo with camera
  Future<void> _takePhoto() async {
    if (_isLaunchingCamera) return;
    _isLaunchingCamera = true;

    _suppressRestoreOnNextResume = true;
    _restoreInputFocusOnResume = false;
    _keepInputUnfocused();
    try {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } catch (_) {
      // Ignore transient platform timing issues while hiding the IME.
    }

    try {
      final XFile? photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        preferredCameraDevice: _useFrontCamera
            ? CameraDevice.front
            : CameraDevice.rear,
      );

      if (photo != null) {
        await _showFilePreviewModal(
          File(photo.path),
          photo.name,
          isFromCamera: true,
        );
      }
    } catch (e) {
      debugPrint('Error taking photo: $e');
      if (mounted) {
        _showTopBanner(
          'Error accessing camera: $e',
          backgroundColor: const Color(0xFFB91C1C),
          icon: Icons.error_outline,
          autoHideAfter: const Duration(seconds: 3),
        );
      }
    } finally {
      _isLaunchingCamera = false;
      _suppressRestoreOnNextResume = false;
      _restoreInputFocusOnResume = false;
      _keepInputUnfocused();
    }
  }

  /// Show file preview modal before sending.
  /// Modal stays open during upload to show progress.
  /// Has a minimize button to close modal while upload continues in background.
  Future<void> _showFilePreviewModal(
    File file,
    String fileName, {
    bool isFromCamera = false,
  }) async {
    _restoreInputFocusOnResume = false;
    _keepInputUnfocused();
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
            // If not uploading, store as pending file
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
            // Only allow close if not uploading
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
              unawaited(_retakePhotoFromPreview());
            } else {
              _pickFile();
            }
          },
          onSend: () {
            // Start upload in the chat screen state (survives modal dismiss)
            _startFileUpload(file, uploadFileName, displayFileName, mimeType);
          },
          getFileIcon: _getFileIcon,
        );
      },
    );
  }

  /// Starts the file upload in the chat screen state so it survives modal minimize.
  /// Inserts an optimistic pending message immediately for instant UI feedback,
  /// then uploads in the background and replaces it with the server message on success.
  void _startFileUpload(
    File file,
    String uploadFileName,
    String displayName,
    String mimeType, {
    int idOffset = 0,
  }) {
    final now = DateTime.now();
    // [idOffset] keeps optimistic IDs unique when several files are started in
    // the same millisecond (batch sends), mirroring _uploadMediaBatch's `+ i`.
    // Without it, two files could share an ID and one would overwrite the other
    // during retry reconciliation.
    final optimisticId = now.millisecondsSinceEpoch + idOffset;
    final trackingId = '${optimisticId}_$uploadFileName';

    final messageType = mimeType.startsWith('image/')
        ? 'image'
        : mimeType.startsWith('video/')
        ? 'video'
        : 'file';

    // Insert optimistic message immediately so the user sees it right away
    final optimisticMessage = Message(
      id: optimisticId,
      senderId: _currentUserId!,
      recipientId: widget.otherUser.id,
      content: uploadFileName,
      messageType: messageType,
      timestamp: now.toIso8601String(),
      timestampMs: optimisticId,
      isRead: false,
      status: 'pending',
      threadId: '',
      reactions: {},
      isDeleted: false,
      fileUrl: null,
      fileName: uploadFileName,
      fileType: mimeType,
      fileSize: file.lengthSync(),
      localFilePath: file.path,
    );

    setState(() {
      _messages.insert(0, optimisticMessage);
      _activeUploadFile = file;
      _activeUploadFileName = uploadFileName;
      _activeUploadDisplayName = displayName;
      _activeUploadMimeType = mimeType;
      _activeUploadProgress = 0.0;
      _activeUploadProgressNotifier.value = 0.0;
      _isActivelyUploading = true;
      _pendingFile = null;
      _pendingFileName = null;
      _pendingFileMimeType = null;
    });

    _scrollToBottom();

    // Track in upload state for progress indicator
    _mediaUploadState.updateProgress(
      trackingId,
      UploadProgress(
        fileIndex: 0,
        totalFiles: 1,
        fileProgress: 0.0,
        status: UploadStatus.pending,
      ),
    );

    double _lastReportedProgress = 0.0;

    _uploadAndSendFileWithProgress(
      file,
      uploadFileName,
      mimeType,
      optimisticId: optimisticId,
      trackingId: trackingId,
      onProgress: (progress) {
        if (mounted &&
            ((progress - _lastReportedProgress) >= 0.01 || progress >= 1.0)) {
          _lastReportedProgress = progress;
          _activeUploadProgressNotifier.value = progress;
          _mediaUploadState.updateProgress(
            trackingId,
            UploadProgress(
              fileIndex: 0,
              totalFiles: 1,
              fileProgress: progress,
              status: UploadStatus.uploading,
            ),
          );
          scheduleMicrotask(() {
            if (mounted) {
              setState(() {
                _activeUploadProgress = progress;
              });
            }
          });
        }
      },
    ).whenComplete(() {
      // Sweep an orphaned in-flight entry (e.g. the message was confirmed via
      // the socket echo rather than the REST success branch) so the chip
      // doesn't stay at 100%. Preserves intentional failed/retrying entries.
      _mediaUploadState.clearIfInFlight(trackingId);
      if (mounted) {
        setState(() {
          _isActivelyUploading = false;
          _activeUploadFile = null;
          _activeUploadFileName = null;
          _activeUploadDisplayName = null;
          _activeUploadMimeType = null;
          _activeUploadProgress = 0.0;
        });
        _activeUploadProgressNotifier.value = 0.0;
      }
    });
  }

  /// Uploads a file with progress tracking (used by the file preview modal).
  /// Replaces the optimistic message on success, queues for retry on network failure.
  Future<void> _uploadAndSendFileWithProgress(
    File file,
    String fileName,
    String mimeType, {
    required int optimisticId,
    required String trackingId,
    required void Function(double progress) onProgress,
  }) async {
    if (!mounted) return;

    try {
      onProgress(0.01);

      final result = await MessageService.uploadFileWithProgress(
        filePath: file.path,
        fileName: fileName,
        mimeType: mimeType,
        recipientId: widget.otherUser.id,
        onProgress: (sent, total) {
          if (total > 0) onProgress(sent / total);
        },
      );

      if (!mounted) return;

      if (result != null && result['success'] == true) {
        onProgress(1.0);
        final fileData = result['file'] ?? result;
        final serverId = fileData['message_id'] ?? fileData['id'];

        // Replace optimistic message with server-confirmed one
        final serverMessage = Message(
          id: serverId ?? optimisticId,
          senderId: _currentUserId!,
          recipientId: widget.otherUser.id,
          content: fileName,
          messageType: mimeType.startsWith('image/')
              ? 'image'
              : mimeType.startsWith('video/')
              ? 'video'
              : 'file',
          timestamp: DateTime.now().toIso8601String(),
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          isRead: false,
          status: 'sent',
          threadId: '',
          reactions: {},
          isDeleted: false,
          fileUrl: fileData['file_url'] ?? fileData['url'],
          fileName: fileName,
          fileType: mimeType,
          fileSize: file.lengthSync(),
          localFilePath: file.path, // Preserve local file path
        );

        if (mounted) {
          setState(() {
            final index = _messages.indexWhere((m) => m.id == optimisticId);
            if (index != -1) {
              // Replace optimistic with confirmed (only if socket didn't already do it)
              if (!_messages.any(
                (m) => m.id == serverMessage.id && m.id != optimisticId,
              )) {
                _messages[index] = serverMessage;
              } else {
                _messages.removeAt(index);
              }
            } else if (!_messages.any((m) => m.id == serverMessage.id)) {
              _messages.insert(0, serverMessage);
            }
          });
        }
        _mediaUploadState.removeUpload(trackingId);
        _scrollToBottom();
      } else {
        throw Exception(result?['error'] ?? 'Upload failed');
      }
    } catch (e) {
      debugPrint('Error uploading file: $e');
      if (!mounted) return;

      // Check if it's a network error — queue for retry
      final isNetworkError =
          e.toString().contains('SocketException') ||
          e.toString().contains('TimeoutException') ||
          e.toString().contains('Connection') ||
          e.toString().contains('network');

      if (isNetworkError) {
        // Queue for automatic retry when connectivity is restored
        final bytes = await file.readAsBytes();
        await MediaUploadRetryService().queueUpload(
          bytes: bytes,
          fileName: fileName,
          mimeType: mimeType,
          recipientId: widget.otherUser.id,
          trackingId: trackingId,
        );
        _mediaUploadState.updateProgress(
          trackingId,
          UploadProgress(
            fileIndex: 0,
            totalFiles: 1,
            fileProgress: 0.0,
            status: UploadStatus.retrying,
          ),
        );
        // Message stays as 'pending' — will be updated when retry succeeds
      } else {
        // Permanent failure — mark message as failed
        setState(() {
          final index = _messages.indexWhere((m) => m.id == optimisticId);
          if (index != -1) {
            final m = _messages[index];
            _messages[index] = Message(
              id: m.id,
              senderId: m.senderId,
              recipientId: m.recipientId,
              content: m.content,
              messageType: m.messageType,
              timestamp: m.timestamp,
              timestampMs: m.timestampMs,
              isRead: m.isRead,
              status: 'failed',
              threadId: m.threadId,
              reactions: m.reactions,
              isDeleted: m.isDeleted,
              fileUrl: m.fileUrl,
              fileName: m.fileName,
              fileType: m.fileType,
              fileSize: m.fileSize,
            );
          }
        });
        _mediaUploadState.markFailed(trackingId, e.toString());
        _showTopBanner(
          'Failed to send file',
          backgroundColor: const Color(0xFFB91C1C),
          icon: Icons.error_outline,
          autoHideAfter: const Duration(seconds: 3),
        );
      }
    }
  }

  /// Re-opens the file preview modal showing current upload progress or pending file.
  Future<void> _reopenFileUploadModal() async {
    if (_activeUploadFile != null) {
      await _showFilePreviewModal(
        _activeUploadFile!,
        _activeUploadFileName ?? 'file',
        isFromCamera: false,
      );
    } else if (_pendingFile != null) {
      final file = _pendingFile!;
      final name = _pendingFileName ?? 'file';
      final isCamera = _pendingFileIsFromCamera;
      // Clear pending state since we're re-opening
      setState(() {
        _pendingFile = null;
        _pendingFileName = null;
        _pendingFileMimeType = null;
      });
      await _showFilePreviewModal(file, name, isFromCamera: isCamera);
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

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Show voice recording modal
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
      builder: (context) => _VoiceRecordingModal(
        onSend: (path, duration) async {
          Navigator.pop(context);
          await _uploadAndSendVoiceMessage(path, duration);
        },
        onCancel: () {
          // Recording lifecycle is managed inside _VoiceRecordingModal.
          Navigator.pop(context);
        },
      ),
    );
  }

  /// Toggle emoji picker visibility (inline below input)
  /// Behaves like FB Messenger: emoji picker replaces the keyboard.
  void _showEmojiPickerModal(BuildContext context) {
    final currentKeyboardInset = _effectiveKeyboardInset();
    final stablePanelHeight = _emojiPanelHeight(currentKeyboardInset);
    _saveCurrentInputSelection();

    if (_showEmojiPicker) {
      // Closing emoji picker â†’ bring keyboard back.
      // As the IME re-appears its inset animates 0 → full height. If the message
      // list's bottom spacer (driven by _keyboardInsetNotifier) followed that raw
      // inset it would collapse to ~0 and snap back up — the "chat area jumping
      // bottom→top". Instead hold the inset constant at the panel height and let
      // didChangeMetrics resume tracking only once the keyboard has risen back to
      // (roughly) that height, so the list/composer stay put. WhatsApp-smooth.
      _startInputModeLock(stablePanelHeight);
      final heldInset = _keyboardInsetNotifier.value > 0
          ? _keyboardInsetNotifier.value
          : (_lastKnownKeyboardInset > 0
                ? _lastKnownKeyboardInset
                : stablePanelHeight);
      _keyboardInsetNotifier.value = heldInset;
      _emojiKeyboardSwitching = true;
      _emojiSwitchTimer?.cancel();
      // Safety release: if the keyboard never reaches the held height (e.g. a
      // shorter IME), stop holding so tracking can't get stuck.
      _emojiSwitchTimer = Timer(const Duration(milliseconds: 450), () {
        if (!mounted) return;
        _emojiKeyboardSwitching = false;
      });
      setState(() {
        _showEmojiPicker = false;
      });
      _inputFocusNode.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // The field kept focus while the emoji panel was open, so requestFocus
        // alone won't re-open the IME (it was explicitly hidden via
        // TextInput.hide). Force the keyboard to show again.
        _inputFocusNode.requestFocus();
        try {
          SystemChannels.textInput.invokeMethod<void>('TextInput.show');
        } catch (_) {}
        _restoreSavedInputSelection();
      });
    } else {
      // Opening emoji picker â†’ hide keyboard but keep input focus/caret
      _startInputModeLock(stablePanelHeight);
      setState(() {
        _showEmojiPicker = true;
      });
      unawaited(_hideSystemKeyboardPreservingFocus());
    }
  }

  // Emoji category tab index
  int _emojiCategoryIndex = 0;

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

  /// Build inline emoji picker widget with category tabs
  /// Emoji grid rendered as a bottom OVERLAY (in the outer Stack) so it never
  /// resizes the message list. Its total height equals the composer's emoji
  /// translate (grid height + bottom safe area), so the lifted composer's
  /// bottom edge meets this overlay's top edge with no gap or overlap.
  Widget _buildEmojiPanelOverlay(BuildContext context) {
    final panelHeight = _currentEmojiPanelHeight();
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        color: _headerColor,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomSafe),
          child: _buildInlineEmojiPicker(panelHeight),
        ),
      ),
    );
  }

  /// Deletes the character before the cursor (or the active selection) from the
  /// message input. Used by the emoji panel's backspace button since the system
  /// keyboard is hidden while the panel is open. Grapheme-aware so a multi-code-
  /// unit emoji is removed in one tap rather than leaving a broken half.
  void _emojiBackspace() {
    final text = _messageController.text;
    if (text.isEmpty) return;

    final sel = _messageController.selection.isValid
        ? _messageController.selection
        : _savedInputSelection;

    int start;
    int end;
    if (sel != null && sel.isValid && !sel.isCollapsed) {
      start = sel.start;
      end = sel.end;
    } else {
      final cursor = (sel != null && sel.baseOffset >= 0)
          ? sel.baseOffset.clamp(0, text.length).toInt()
          : text.length;
      if (cursor <= 0) return;
      final before = text.substring(0, cursor);
      final lastChar = before.characters.isEmpty
          ? before
          : before.characters.last;
      start = cursor - lastChar.length;
      end = cursor;
    }

    final newText = text.substring(0, start) + text.substring(end);
    final newSelection = TextSelection.collapsed(offset: start);
    _messageController.text = newText;
    _messageController.selection = newSelection;
    _savedInputSelection = newSelection;

    _onTextChanged(newText);
    setState(() {});
  }

  Widget _buildInlineEmojiPicker(double panelHeight) {
    final category = _emojiCategories[_emojiCategoryIndex];
    final emojis = _normalizedEmojiList(category['emojis'] as List<String>);

    return Container(
      height: panelHeight,
      margin: EdgeInsets.zero,
      decoration: BoxDecoration(
        color: const Color(0xFF3D3D3D),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // Category tabs + backspace. The system keyboard (with its own
          // backspace) is hidden while the emoji panel is open, so we provide a
          // backspace here to delete the previous character/emoji.
          SizedBox(
            height: 44,
            child: Row(
              children: [
                Expanded(
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    itemCount: _emojiCategories.length,
                    itemBuilder: (context, index) {
                      final cat = _emojiCategories[index];
                      final icon = _normalizeEmojiForCompatibility(
                        cat['icon'] as String,
                      );
                      final isSelected = index == _emojiCategoryIndex;
                      return GestureDetector(
                        onTap: () =>
                            setState(() => _emojiCategoryIndex = index),
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
                // Backspace: delete the previous grapheme (handles multi-code-
                // unit emoji), or the current selection if there is one.
                GestureDetector(
                  onTap: _emojiBackspace,
                  onLongPress: _emojiBackspace,
                  child: Container(
                    width: 44,
                    height: 44,
                    margin: const EdgeInsets.only(left: 2, right: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF4A4A4A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.backspace_outlined,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ],
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
                    final selection = _messageController.selection.isValid
                        ? _messageController.selection
                        : _savedInputSelection;
                    final cursorPos =
                        selection != null && selection.baseOffset >= 0
                        ? selection.baseOffset
                        : text.length;

                    final newText =
                        text.substring(0, cursorPos) +
                        emojis[index] +
                        text.substring(cursorPos);

                    _messageController.text = newText;
                    final newSelection = TextSelection.collapsed(
                      offset: cursorPos + emojis[index].length,
                    );
                    _messageController.selection = newSelection;
                    _savedInputSelection = newSelection;

                    // Trigger text changed and rebuild UI
                    _onTextChanged(newText);
                    setState(
                      () {},
                    ); // Force rebuild to update button visibility
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

  /// Upload and send voice message
  Future<void> _uploadAndSendVoiceMessage(
    String path,
    Duration duration,
  ) async {
    if (!mounted) return;

    try {
      _showTopBanner(
        'Sending voice message...',
        backgroundColor: const Color(0xFF1F2937),
        icon: Icons.mic,
        autoHideAfter: null,
        showDismiss: false,
      );

      final file = File(path);
      final ext = path.split('.').last.toLowerCase();
      final fileName = 'voice_${DateTime.now().millisecondsSinceEpoch}.$ext';

      // Determine correct MIME type for voice files
      // MultipartFile.fromPath doesn't detect .aac/.m4a properly (sends application/octet-stream)
      String mimeType = lookupMimeType(path) ?? 'application/octet-stream';
      if (mimeType == 'application/octet-stream') {
        // Fallback based on extension
        const audioMimeMap = {
          'aac': 'audio/aac',
          'm4a': 'audio/mp4',
          'mp3': 'audio/mpeg',
          'wav': 'audio/wav',
          'ogg': 'audio/ogg',
          'opus': 'audio/opus',
          'flac': 'audio/flac',
        };
        mimeType = audioMimeMap[ext] ?? mimeType;
      }

      // Create MultipartFile with explicit content type
      final multipartFile = await http.MultipartFile.fromPath(
        'file',
        path,
        filename: fileName,
        contentType: MediaType.parse(mimeType),
      );

      // Upload file using MessageService
      final result = await MessageService.uploadFile(
        file: multipartFile,
        recipientId: widget.otherUser.id,
      );

      if (!mounted) return;

      // Hide uploading indicator
      _hideTopBanner();

      if (result != null && result['success'] == true) {
        final fileData = result['file'] ?? result;

        // NOTE: The REST API upload already emits file_message to the recipient,
        // so we do NOT emit send_file here to avoid duplicate messages on the web.

        // Check if the fileReceived socket handler already added this message
        // (race condition: socket event can arrive before REST response)
        final serverId = fileData['message_id'] ?? fileData['id'];
        if (serverId != null && _messages.any((m) => m.id == serverId)) {
          debugPrint(
            'ðŸŽ¤ Voice message already added by socket handler, skipping local insert',
          );
        } else {
          // Create local message to show in chat
          final now = DateTime.now();
          final message = Message(
            id: serverId ?? DateTime.now().millisecondsSinceEpoch,
            senderId: _currentUserId!,
            recipientId: widget.otherUser.id,
            content: fileName,
            messageType: 'voice',
            timestamp: now.toIso8601String(),
            timestampMs: now.millisecondsSinceEpoch,
            isRead: false,
            status: 'sent',
            threadId: '',
            reactions: {},
            isDeleted: false,
            fileUrl: fileData['file_url'] ?? fileData['url'],
            fileName: fileName,
            fileType: 'audio/mp4',
            fileSize: file.lengthSync(),
          );

          if (!mounted) return;
          setState(() {
            _messages.insert(0, message);
          });
        }

        // Scroll to bottom
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom();
        });

        _showTopBanner(
          'Voice message sent!',
          backgroundColor: const Color(0xFF059669),
          icon: Icons.check_circle_outline,
          autoHideAfter: const Duration(seconds: 2),
        );

        // Refocus the text input field after sending voice message
        unawaited(_hideSystemKeyboardPreservingFocus());

        // Clean up recording file
        try {
          await file.delete();
        } catch (_) {}
      } else {
        _showTopBanner(
          'Failed to send voice message',
          backgroundColor: const Color(0xFFB91C1C),
          icon: Icons.error_outline,
          autoHideAfter: const Duration(seconds: 3),
        );
      }
    } catch (e) {
      debugPrint('Error uploading voice message: $e');
      if (!mounted) return;
      _hideTopBanner();
      _showTopBanner(
        'Error sending voice message: $e',
        backgroundColor: const Color(0xFFB91C1C),
        icon: Icons.error_outline,
        autoHideAfter: const Duration(seconds: 3),
      );
    }
  }

  /// Upload file to server and send via socket.
  ///
  /// Kept for reference: superseded by [_startFileUpload], which inserts an
  /// optimistic message, reports progress, and (critically) queues the upload to
  /// [MediaUploadRetryService] when offline. This variant silently dropped files
  /// on a network error, so multi-file sends made while offline never reached
  /// the socket after reconnect.
  // ignore: unused_element
  Future<void> _uploadAndSendFile(
    File file,
    String fileName,
    String mimeType,
  ) async {
    if (!mounted) return;

    try {
      _showTopBanner(
        'Uploading file...',
        backgroundColor: const Color(0xFF1F2937),
        icon: Icons.upload_file,
        autoHideAfter: null,
        showDismiss: false,
      );

      // Create MultipartFile with explicit content type so server knows the MIME type
      final multipartFile = await http.MultipartFile.fromPath(
        'file',
        file.path,
        filename: fileName,
        contentType: MediaType.parse(mimeType),
      );

      // Upload file using MessageService
      final result = await MessageService.uploadFile(
        file: multipartFile,
        recipientId: widget.otherUser.id,
      );

      if (!mounted) return;

      // Hide uploading indicator
      _hideTopBanner();

      if (result != null && result['success'] == true) {
        final fileData = result['file'] ?? result;

        // NOTE: The REST API upload already creates the DB message and emits
        // file_message to the recipient, so we do NOT emit send_file here to
        // avoid duplicate messages. Cross-device sync is handled by the REST
        // endpoint emitting to the sender's room as well.

        // Check if the fileReceived socket handler already added this message
        // (race condition: socket event can arrive before REST response)
        final serverId = fileData['message_id'] ?? fileData['id'];
        if (serverId != null && _messages.any((m) => m.id == serverId)) {
          debugPrint(
            'ðŸ“Ž File message already added by socket handler, skipping local insert',
          );
        } else {
          // Create local message to show in chat
          // Use server message_id so the fileReceived dedup check catches the echo
          final now = DateTime.now();
          final message = Message(
            id: serverId ?? DateTime.now().millisecondsSinceEpoch,
            senderId: _currentUserId!,
            recipientId: widget.otherUser.id,
            content: fileName,
            messageType: mimeType.startsWith('image/')
                ? 'image'
                : mimeType.startsWith('video/')
                ? 'video'
                : 'file',
            timestamp: now.toIso8601String(),
            timestampMs: now.millisecondsSinceEpoch,
            isRead: false,
            status: 'sent',
            threadId: '',
            reactions: {},
            isDeleted: false,
            fileUrl: fileData['file_url'] ?? fileData['url'],
            fileName: fileName,
            fileType: mimeType,
            fileSize: file.lengthSync(),
          );

          if (!mounted) return;
          setState(() {
            _messages.insert(0, message);
          });
        }
        _scrollToBottom();

        _showTopBanner(
          'File sent!',
          backgroundColor: const Color(0xFF059669),
          icon: Icons.check_circle_outline,
          autoHideAfter: const Duration(seconds: 2),
        );

        // Refocus the text input field after sending image
        unawaited(_hideSystemKeyboardPreservingFocus());
      } else {
        throw Exception(result?['error'] ?? 'Upload failed');
      }
    } catch (e) {
      debugPrint('Error uploading file: $e');
      if (!mounted) return;
      _hideTopBanner();
      _showTopBanner(
        'Failed to send file: $e',
        backgroundColor: const Color(0xFFB91C1C),
        icon: Icons.error_outline,
        autoHideAfter: const Duration(seconds: 3),
      );
    }
  }

  @override
  void dispose() {
    unawaited(_persistConversationCacheSnapshot());
    _draftSaveDebounce?.cancel();
    if (_editingMessage == null) {
      // Leaving the room — persist whatever text is left (in case the
      // debounce above hadn't fired yet) and bump it if it's non-empty.
      final roomKey = _draftRoomKey;
      final text = _messageController.text;
      unawaited(
        DraftService().setText(roomKey, text).then((_) {
          if (text.trim().isNotEmpty) {
            unawaited(DraftService().markLeftWithDraft(roomKey));
          }
        }),
      );
    }
    _fileOpsChannel.setMethodCallHandler(null);
    _inputModeSwitchTimer?.cancel();
    _emojiSwitchTimer?.cancel();
    _emojiCollapseTimer?.cancel();
    _keyboardInsetNotifier.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _retryProgressSubscription?.cancel();
    _textRetryProgressSubscription?.cancel();
    _mediaUploadState.dispose();
    _taskBadgeAnimController.dispose();
    _taskModalVersion.dispose();
    _messageController.removeListener(_syncCommonPhrasesVisibility);
    _messageController.removeListener(_onComposerTextChangedForDraft);
    _messageController.dispose();
    _autoCorrectionWrongController.dispose();
    _autoCorrectionCorrectController.dispose();
    _scrollController.dispose();
    _inputScrollController.dispose();
    _audioPlayer.dispose();
    for (final p in _activeDoorbellPlayers) {
      p.dispose();
    }
    _activeDoorbellPlayers.clear();
    _inputFocusNode.dispose();
    _typingTimer?.cancel();
    _autoCorrectionPreviewTimer?.cancel();
    _typingHideTimer?.cancel();
    _typingUpdateThrottle?.cancel();
    PendingIncomingCallService().expired.removeListener(_onPendingCallExpired);
    _lastSeenRefreshTimer?.cancel();
    _callInProgressOnOtherDeviceTimer?.cancel();
    _topSnackBarTimer?.cancel();
    _topSnackBarEntry?.remove();
    _topSnackBarEntry = null;

    // Send typing stop without setState (widget is being disposed)
    _socketService.stopTyping(widget.otherUser.id);

    // Leave chat room
    _socketService.leaveChat(widget.otherUser.id);

    // Clear active chat so FCM notifications resume for this user
    ActiveChatService().clearActiveChat();

    // Clear all chat socket listeners (does NOT affect lobby listeners)
    _socketService.removeListenersForKey('chat');

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = _uiScale(context);
    // NOTE: the keyboard inset is intentionally NOT read here. It is consumed
    // only inside the bottom composer's ValueListenableBuilder (keyed on
    // _keyboardInsetNotifier) so the keyboard animation slides the composer
    // without rebuilding the message list.
    return PopScope(
      // System Back should close the emoji panel / keyboard first, not leave the
      // room. (The header back arrow uses Navigator.pop directly, which bypasses
      // PopScope, so it still leaves immediately.)
      canPop: !(_showEmojiPicker || _isKeyboardVisible),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_showEmojiPicker) {
          setState(() => _showEmojiPicker = false);
          _inputFocusNode.unfocus();
          // No IME is coming back, so collapse the held inset ourselves;
          // otherwise the composer stays lifted over an empty gap.
          _animateKeyboardInsetToZero();
        } else if (_isKeyboardVisible) {
          _inputFocusNode.unfocus();
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: const Color(0xFF2C2C2C),
        appBar: ChatHeader(
          otherUser: widget.otherUser,
          // Fixed violet header to match the web (bg-violet-900), independent of
          // the chat color-change feature (which still themes the composer below).
          headerColor: const Color(0xFF4C1D95),
          isSelfChat: _isSelfChat,
          callInProgressOnOtherDevice: _callInProgressOnOtherDevice,
          partnerStatus: _getEffectivePartnerStatus(),
          partnerLastSeen: _formattedPartnerLastSeen(),
          taskCount: _taskMessages.where((m) => m.isTask).length,
          // Pinned links and unread board changes share one badge because they
          // share one modal — the number is "things waiting in here".
          excalidrawCount:
              _pinnedExcalidrawLinks.length + _excalidrawRoomsUnread,
          scale: scale,
          onBack: widget.embedded ? null : () => Navigator.pop(context),
          onUserProfile: _showUserProfile,
          onShowTasks: _showTasksModal,
          onShowExcalidraw: _showExcalidrawModal,
          onCallAudio: () => _showCallSetupModal(CallType.audio),
          onCallVideo: () => _showCallSetupModal(CallType.video),
          onExportChat: _exportChat,
        ),
        body: GestureDetector(
          // Tap outside the modal to dismiss it
          behavior: HitTestBehavior.translucent,
          child: Stack(
            children: [
              Column(
                children: [
                  LiveChatTimestampHeader(scale: scale),
                  // Messages list
                  Expanded(
                    child: Stack(
                      children: [
                        ChatMessageList(
                          scale: scale,
                          controller: _scrollController,
                          isLoading: _isLoading,
                          messages: _messages,
                          hasMoreMessages: _hasMoreMessages,
                          isLoadingMore: _isLoadingMore,
                          onLoadMoreMessages: _loadMoreMessages,
                          // Reactive bottom spacer rides the keyboard so the newest
                          // message lifts above the overlaying composer without the
                          // list ever resizing/rebuilding.
                          bottomSpacer: _keyboardInsetNotifier,
                          loadingWidgetBuilder: (_) =>
                              _buildChatLoadingPlaceholder(),
                          itemBuilder: (context, index) {
                            // "Load more" button is handled inside ChatMessageList.
                            final message = _messages[index];

                            if (message.isDeleted) {
                              return const SizedBox.shrink();
                            }

                            final isSentByMe =
                                message.senderId == _currentUserId;
                            Widget? dateSeparator;
                            if (index < _messages.length - 1) {
                              final nextMessage = _messages[index + 1];
                              if (!_isSameDay(
                                message.timestamp,
                                nextMessage.timestamp,
                              )) {
                                dateSeparator = ChatDateSeparator(
                                  timestamp: message.timestamp,
                                  scale: scale,
                                );
                              }
                            } else {
                              dateSeparator = ChatDateSeparator(
                                timestamp: message.timestamp,
                                scale: scale,
                              );
                            }

                            final Widget msgContent =
                                message.messageType == 'system'
                                ? Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 6,
                                    ),
                                    child: Center(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.08,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                        ),
                                        child: Text(
                                          message.content,
                                          style: TextStyle(
                                            color: Colors.grey[400],
                                            fontSize: 12,
                                            fontStyle: FontStyle.italic,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                : SwipeableMessage(
                                    isSentByMe: isSentByMe,
                                    onReply: () => _setReplyTo(message),
                                    child: _buildMessageBubble(
                                      message,
                                      isSentByMe,
                                    ),
                                  );

                            return ChatMessageItem(
                              messageKey: _messageItemKeys.putIfAbsent(
                                message.id,
                                () => GlobalKey(),
                              ),
                              dateSeparator: dateSeparator,
                              content: msgContent,
                            );
                          },
                          emptyStateBuilder: (context) => Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.chat_bubble_outline,
                                  size: 64 * scale,
                                  color: Colors.grey[700],
                                ),
                                SizedBox(height: 16 * scale),
                                Text(
                                  'No messages yet',
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 16 * scale,
                                  ),
                                ),
                                SizedBox(height: 8 * scale),
                                Text(
                                  'Send a message to start the conversation',
                                  style: TextStyle(
                                    color: Colors.grey[700],
                                    fontSize: 14 * scale,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (!_isAtBottom)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 16,
                            // Ride above the composer when the keyboard is up so
                            // the button isn't hidden behind the overlay. Only the
                            // translate rebuilds on inset change, not the button.
                            child: ValueListenableBuilder<double>(
                              valueListenable: _keyboardInsetNotifier,
                              builder: (context, inset, child) =>
                                  Transform.translate(
                                    offset: Offset(0, -inset),
                                    child: child,
                                  ),
                              child: Center(
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _unreadCount = 0;
                                    });
                                    _scrollToBottom();
                                    _markVisibleMessagesAsRead();
                                  },
                                  child: Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF7C3AED),
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.3,
                                          ),
                                          blurRadius: 6,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        const Icon(
                                          Icons.keyboard_arrow_down,
                                          color: Colors.white,
                                          size: 20,
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
                          ),
                      ],
                    ),
                  ),
                  // Bottom bar: typing preview + message input (keyed for modal
                  // positioning). Only this composer subtree rebuilds as the
                  // keyboard slides — the message list above stays untouched.
                  ValueListenableBuilder<double>(
                    valueListenable: _keyboardInsetNotifier,
                    builder: (context, _, __) {
                      final keyboardInset = _effectiveKeyboardInset();
                      // Emoji-panel content height (only used when the picker
                      // shows). Shared with the bottom overlay below so the
                      // composer lifts by exactly the grid's height.
                      final stablePanelHeight = _currentEmojiPanelHeight();
                      final actionPanelInset =
                          (_isActionsPanelOpen && _actionsPanelFromKeyboard)
                          ? _actionsPanelInset
                          : 0.0;
                      // The keyboard is handled as an OVERLAY: we translate the
                      // composer up over the (un-resized) message list instead of
                      // reserving layout space for it, so the list never relayouts.
                      // composerInset only reserves real space for the emoji /
                      // actions panels, which replace the keyboard.
                      final composerInset = _showEmojiPicker
                          ? 0.0
                          : actionPanelInset;
                      // While switching between the emoji panel and the keyboard
                      // (260ms lock), the keyboard inset is briefly 0 before the
                      // IME animates in. Hold the composer at the locked panel
                      // height as a floor so it doesn't drop to the bottom and
                      // snap back up — it stays put until the keyboard catches up.
                      // Note: the floor has no +bottomSafe because once the emoji
                      // panel closes the composer regains its own bottom safe-area
                      // padding, which keeps the input row visually stationary.
                      final lockedFloor =
                          (_isSwitchingInputMode && _lockedInputPanelHeight > 0)
                          ? _lockedInputPanelHeight
                          : 0.0;
                      // Emoji open: lift the composer up by the grid's full
                      // height (incl. bottom safe area) so it sits flush above
                      // the bottom overlay, mirroring the keyboard-overlay path.
                      final translateY = _showEmojiPicker
                          ? stablePanelHeight +
                                MediaQuery.of(context).padding.bottom
                          : math.max(keyboardInset, lockedFloor);
                      return Transform.translate(
                        offset: Offset(0, -translateY),
                        child: Column(
                          key: _bottomBarKey,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Typing preview - pinned at bottom, always visible
                            Container(
                              height:
                                  (_otherUserTyping &&
                                      _typingPreview.isNotEmpty)
                                  ? null
                                  : 0,
                              padding:
                                  (_otherUserTyping &&
                                      _typingPreview.isNotEmpty)
                                  ? const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    )
                                  : EdgeInsets.zero,
                              decoration: BoxDecoration(
                                color: _headerColor,
                                border: const Border(
                                  top: BorderSide(
                                    color: Color(0xFF3D3D3D),
                                    width: 1,
                                  ),
                                ),
                              ),
                              child:
                                  (_otherUserTyping &&
                                      _typingPreview.isNotEmpty)
                                  ? RepaintBoundary(
                                      child: ChatTypingPreviewBubble(
                                        scale: scale,
                                        otherUserName:
                                            widget.otherUser.fullName,
                                        typingPreview: _typingPreview,
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                            // Common phrases bar (outside action buttons background, single row)
                            CommonPhraseBar(
                              phrases: _commonPhrases,
                              hidden: _hideCommonPhrases,
                              onChipTap: _onCommonPhraseChipTap,
                              scale: scale,
                            ),
                            ChatComposerPanel(
                              scale: scale,
                              backgroundColor: _headerColor,
                              composerInset: composerInset,
                              showEmojiPicker: _showEmojiPicker,
                              isEditing: _editingMessage != null,
                              onShowEmojiPickerModal: () =>
                                  _showEmojiPickerModal(context),
                              onClipboardPasteShortcut:
                                  _onComposerPasteShortcut,
                              onInputContextMenuOpened:
                                  _onInputContextMenuOpened,
                              onContentInserted: _onKeyboardContentInserted,
                              onTextChanged: _onTextChanged,
                              onSend: _sendMessage,
                              messageController: _messageController,
                              inputFocusNode: _inputFocusNode,
                              inputScrollController: _inputScrollController,
                              buildDoorbellComposerButton:
                                  ({
                                    required bool showLabel,
                                    required double iconSize,
                                    required EdgeInsets padding,
                                  }) => _buildDoorbellComposerButton(
                                    showLabel: showLabel,
                                    iconSize: iconSize,
                                    padding: padding,
                                  ),
                              isComposerMultiline: _isComposerMultiline,
                              editPreview: _buildEditPreview(),
                              replyPreview: _buildReplyPreview(),
                              sendToManyQuickAction:
                                  _buildSendToManyQuickAction(),
                              unifiedActionsBar: _buildUnifiedActionsBar(),
                              actionsBelowInput: widget.embedded,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
              if (_isActionsPanelOpen) _buildActionsPanelOverlay(context),
              if (_showEmojiPicker) _buildEmojiPanelOverlay(context),
            ],
          ),
        ),
      ),
    );
  }

  /// Clear reply state
  void _clearReply() {
    setState(() {
      _replyingToMessage = null;
    });
  }

  /// Set reply target
  void _setReplyTo(Message message) {
    setState(() {
      _replyingToMessage = message;
    });
    // Give haptic feedback
    _inputFocusNode.requestFocus();
  }

  /// Clear edit state
  void _clearEdit() {
    setState(() {
      _editingMessage = null;
    });
    _messageController.clear();
  }

  /// Start inline edit mode for a message
  void _startInlineEdit(Message message) {
    // Draft protection: if composer has unsent text, prompt before overwriting
    if (_messageController.text.trim().isNotEmpty) {
      _confirmDiscardDraftThenEdit(message);
      return;
    }
    setState(() {
      _editingMessage = message;
      _replyingToMessage = null; // edit and reply modes are mutually exclusive
    });
    _messageController.text = message.content;
    // Place cursor at end
    _messageController.selection = TextSelection.collapsed(
      offset: message.content.length,
    );
    _inputFocusNode.requestFocus();
  }

  /// Show confirmation dialog before discarding a draft to start an edit
  void _confirmDiscardDraftThenEdit(Message message) {
    showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        title: const Text(
          'Discard draft?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'You have unsent text. Discard it and edit this message instead?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text(
              'Keep draft',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF420796),
            ),
            child: const Text('Discard'),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true && mounted) {
        _messageController.clear();
        _startInlineEdit(message);
      }
    });
  }

  /// Build swipeable message wrapper with slide animation
  bool _canQuickToggleTaskAction(Message message) {
    return message.messageType == 'text' && !message.isDeleted;
  }

  /// Whether a message can be marked as a task. Mirrors web behaviour: any real
  /// message (text, image, video, file, voice, contact) can become a task, but
  /// system / call / doorbell / colour-change events cannot.
  bool _canMarkAsTask(Message message) {
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

  bool _isExcalidrawMessage(Message message) {
    if (message.isDeleted) return false;
    return _extractExcalidrawUrl(message.content) != null;
  }

  bool _canQuickToggleExcalidrawPin(Message message) {
    return _isExcalidrawMessage(message);
  }

  void _toggleTaskActionForMessage(Message message, Offset tapPosition) {
    if (!_canQuickToggleTaskAction(message)) {
      return;
    }

    _showTaskActionModal(message, tapPosition);
  }

  void _showTaskActionModal(Message message, Offset tapPosition) {
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final overlaySize = overlayBox.size;
    const verticalOffset = 44.0;
    const menuWidth = 200.0;
    const menuMargin = 8.0;

    // Clamp vertical position
    final menuTop = (tapPosition.dy - verticalOffset).clamp(
      menuMargin,
      overlaySize.height - menuMargin,
    );

    // Clamp horizontal position to keep menu within screen bounds
    // Center the menu on the tap position if possible
    final menuLeft = (tapPosition.dx - menuWidth / 2).clamp(
      menuMargin,
      overlaySize.width - menuWidth - menuMargin,
    );

    // Create instant overlay menu without animation
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
                                // Delay slightly to allow overlay to close before action
                                Future.microtask(() {
                                  (item as PopupMenuItem<void>).onTap?.call();
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

  List<PopupMenuEntry<void>> _buildTaskActionMenuItems(Message message) {
    final items = <PopupMenuEntry<void>>[];

    if (message.replyToId != null) {
      items.add(
        PopupMenuItem<void>(
          onTap: () => _jumpToRepliedMessage(message.replyToId!),
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

    if (_canQuickToggleExcalidrawPin(message)) {
      items.add(
        PopupMenuItem<void>(
          onTap: () => _toggleExcalidrawPin(message),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bookmark, color: Color(0xFFB794F6), size: 18),
              const SizedBox(width: 8),
              Text(
                message.excalidrawPinnedAt != null
                    ? 'Unpin Excalidraw'
                    : 'Pin Excalidraw',
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
    }

    items.add(
      PopupMenuItem<void>(
        onTap: () {
          if (message.isTask) {
            _unmarkMessageTask(message);
          } else {
            _addMessageToTask(message);
          }
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              message.isTask
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              color: const Color(0xFF0D9488), // teal — matches the task accent
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              message.isTask ? 'Unmark task' : 'Mark as task',
              style: const TextStyle(
                color: Color(0xFF0D9488), // teal — matches the task accent
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

  /// Show context menu for message
  Future<void> _showMessageContextMenu(Message message, bool isSentByMe) async {
    _keepInputUnfocused();

    var actionInvoked = false;

    void closeWithAction(BuildContext sheetContext, VoidCallback action) {
      actionInvoked = true;
      Navigator.pop(sheetContext);
      action();
    }

    await showModalBottomSheet(
      context: context,
      requestFocus: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E2E),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFF7C3AED).withValues(alpha: 0.28),
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF420796).withValues(alpha: 0.28),
                blurRadius: 24,
                spreadRadius: 0.2,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 5,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Row(
                children: [
                  const Icon(
                    Icons.tune_rounded,
                    color: Color(0xFFB794F6),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Message Actions',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  if (message.isTask)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D9488).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: const Color(
                            0xFF0D9488,
                          ).withValues(alpha: 0.55),
                        ),
                      ),
                      child: const Text(
                        'Task',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              _buildContextMenuActionTile(
                icon: Icons.reply_rounded,
                label: 'Reply',
                onTap: () {
                  closeWithAction(sheetContext, () => _setReplyTo(message));
                },
              ),
              if (message.replyToId != null)
                _buildContextMenuActionTile(
                  icon: Icons.arrow_upward_rounded,
                  label: 'View replied message',
                  iconColor: const Color(0xFF60A5FA),
                  onTap: () {
                    closeWithAction(
                      sheetContext,
                      () => _jumpToRepliedMessage(message.replyToId!),
                    );
                  },
                ),
              if (message.messageType == 'text' &&
                  !message.isDeleted &&
                  message.content.isNotEmpty)
                ValueListenableBuilder<String?>(
                  valueListenable: TtsService().readingMessageId,
                  builder: (context, readingId, child) {
                    final isReadingThis = readingId == message.id.toString();
                    return _buildContextMenuActionTile(
                      icon: isReadingThis
                          ? Icons.stop_circle_outlined
                          : Icons.volume_up_outlined,
                      label: isReadingThis ? 'Stop Reading' : 'Read Aloud',
                      iconColor: isReadingThis
                          ? const Color(0xFFF87171)
                          : const Color(0xFF60A5FA),
                      onTap: () {
                        // Don't close the menu, just start/stop
                        if (isReadingThis) {
                          TtsService().stop();
                        } else {
                          TtsService().speak(
                            message.id.toString(),
                            message.content,
                          );
                        }
                      },
                    );
                  },
                ),
              if (_canMarkAsTask(message))
                _buildContextMenuActionTile(
                  icon: message.isTask
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  label: message.isTask ? 'Unmark task' : 'Mark as task',
                  iconColor: const Color(0xFF0D9488), // teal — task accent
                  onTap: () {
                    closeWithAction(
                      sheetContext,
                      () => message.isTask
                          ? _unmarkMessageTask(message)
                          : _addMessageToTask(message),
                    );
                  },
                ),
              if (_canQuickToggleExcalidrawPin(message))
                _buildContextMenuActionTile(
                  icon: Icons.bookmark,
                  label: message.excalidrawPinnedAt != null
                      ? 'Unpin Excalidraw'
                      : 'Pin Excalidraw',
                  iconColor: const Color(0xFFB794F6),
                  onTap: () {
                    closeWithAction(
                      sheetContext,
                      () => _toggleExcalidrawPin(message),
                    );
                  },
                ),
              if (_canSendToExcalidrawRoom(message))
                _buildContextMenuActionTile(
                  icon: Icons.draw_outlined,
                  label: 'Send to Excalidraw room',
                  iconColor: const Color(0xFFF97316),
                  onTap: () {
                    closeWithAction(
                      sheetContext,
                      () => _sendMessageToExcalidrawRoom(message),
                    );
                  },
                ),
              if (message.messageType == 'text' && !message.isDeleted)
                _buildContextMenuActionTile(
                  icon: Icons.copy_rounded,
                  label: 'Copy',
                  onTap: () {
                    closeWithAction(
                      sheetContext,
                      () => _copyMessageToClipboard(message),
                    );
                  },
                ),
              if (!isSentByMe &&
                  message.messageType == 'text' &&
                  !message.isDeleted &&
                  message.content.isNotEmpty)
                _buildContextMenuActionTile(
                  icon: _messageTranslations.containsKey(message.id)
                      ? Icons.translate_outlined
                      : Icons.translate,
                  label: _messageTranslations.containsKey(message.id)
                      ? 'Hide Translation'
                      : 'Translate',
                  iconColor: const Color(0xFF60A5FA),
                  onTap: () {
                    closeWithAction(
                      sheetContext,
                      () => _translateMessage(message),
                    );
                  },
                ),
              if (isSentByMe &&
                  message.messageType == 'text' &&
                  !message.isDeleted)
                _buildContextMenuActionTile(
                  icon: Icons.edit_rounded,
                  label: 'Edit',
                  onTap: () {
                    closeWithAction(
                      sheetContext,
                      () => _startInlineEdit(message),
                    );
                  },
                ),
              if (!message.isDeleted && message.messageType != 'system')
                _buildContextMenuActionTile(
                  icon: Icons.shortcut_rounded,
                  label: 'Forward',
                  iconColor: const Color(0xFF34D399),
                  onTap: () {
                    closeWithAction(
                      sheetContext,
                      () => _openForwardPicker(message),
                    );
                  },
                ),
              if (isSentByMe && !message.isDeleted)
                _buildContextMenuActionTile(
                  icon: Icons.delete_outline,
                  label: 'Delete',
                  iconColor: const Color(0xFFF87171),
                  textColor: const Color(0xFFFCA5A5),
                  tileColor: const Color(0xFF341E2A),
                  onTap: () {
                    closeWithAction(
                      sheetContext,
                      () => _showDeleteConfirmation(message),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );

    if (!actionInvoked && mounted) {
      _keepInputUnfocused();
    }
  }

  Widget _buildContextMenuActionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color iconColor = Colors.white,
    Color textColor = Colors.white,
    Color tileColor = const Color(0xFF252542),
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              color: tileColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  Icon(icon, color: iconColor, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white.withValues(alpha: 0.35),
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Add message to tasks
  void _addMessageToTask(Message message) {
    _socketService.addTask(message.id);

    // Optimistically update the message locally
    setState(() {
      final updated = _copyMessageWithTaskState(
        message,
        isTask: true,
        taskCreatedAt: DateTime.now().toIso8601String(),
        taskCompletedAt: null,
      );
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index != -1) {
        _messages[index] = updated;
      }
      // Surface in the tasks modal immediately; the socket echo (task_added)
      // upserts the same entry, so this stays idempotent.
      _upsertTaskMessage(updated);
    });
    _taskBadgeAnimController.forward(from: 0);
    _notifyTaskModalChanged();
  }

  /// Unmark message as task
  void _unmarkMessageTask(Message message) {
    _socketService.unmarkTask(message.id);

    setState(() {
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index != -1) {
        final currentMessage = _messages[index];
        _messages[index] = _copyMessageWithTaskState(
          currentMessage,
          isTask: false,
          taskCreatedAt: null,
          taskCompletedAt: null,
        );
      }

      _pendingLiveTaskCreatedAtByMessageId.remove(message.id);
      _pendingLiveTaskCompletedAtByMessageId.remove(message.id);
    });
    _taskBadgeAnimController.forward(from: 0);
    _notifyTaskModalChanged();
  }

  /// Toggle excalidraw pin status
  Future<void> _toggleExcalidrawPin(Message message) async {
    final initialIndex = _messages.indexWhere((m) => m.id == message.id);
    if (initialIndex == -1) return;

    final originalMessage = _messages[initialIndex];
    final wasPinned = originalMessage.excalidrawPinnedAt != null;
    final hasExcalidrawUrl =
        _extractExcalidrawUrl(originalMessage.content) != null;

    // Optimistically update before the API response arrives.
    setState(() {
      _messages[initialIndex] = _copyMessageWithExcalidrawState(
        originalMessage,
        isExcalidrawLink: hasExcalidrawUrl,
        excalidrawPinnedAt: wasPinned ? null : DateTime.now().toIso8601String(),
      );
    });

    final success = wasPinned
        ? await MessageService.unpinExcalidrawLink(messageId: message.id)
        : await MessageService.pinExcalidrawLink(messageId: message.id);

    if (!mounted) return;

    if (!success) {
      setState(() {
        final currentIndex = _messages.indexWhere((m) => m.id == message.id);
        if (currentIndex != -1) {
          _messages[currentIndex] = originalMessage;
        }
      });

      _showTopSnackBar(
        SnackBar(
          content: Text(
            wasPinned
                ? 'Failed to unpin Excalidraw'
                : 'Failed to pin Excalidraw',
            style: const TextStyle(color: Colors.white),
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: const Color(0xFFD32F2F),
        ),
      );
      return;
    }

    await _refreshMessages();

    if (!mounted) return;

    await _loadPinnedExcalidrawLinks();

    if (!mounted) return;

    _showTopSnackBar(
      SnackBar(
        content: Text(
          wasPinned ? 'Excalidraw unpinned' : 'Excalidraw pinned',
          style: const TextStyle(color: Colors.white),
        ),
        duration: const Duration(seconds: 2),
        backgroundColor: const Color(0xFF420796),
      ),
    );
  }

  /// Unpin Excalidraw from modal list with realtime socket event.
  Future<void> _unpinExcalidrawFromModal(Map<String, dynamic> link) async {
    final messageId = _toInt(link['id']);
    if (messageId == null) return;

    final messageIndex = _messages.indexWhere((m) => m.id == messageId);
    Message? originalMessage;

    setState(() {
      if (messageIndex != -1) {
        originalMessage = _messages[messageIndex];
        final hasExcalidrawUrl =
            _extractExcalidrawUrl(originalMessage!.content) != null;
        _messages[messageIndex] = _copyMessageWithExcalidrawState(
          originalMessage!,
          isExcalidrawLink: hasExcalidrawUrl,
          excalidrawPinnedAt: null,
        );
      }

      _pinnedExcalidrawLinks.removeWhere(
        (item) => _toInt(item['id']) == messageId,
      );
    });

    // Emit realtime socket event so other active clients update immediately.
    _socketService.unpinExcalidraw(messageId);

    final success = await MessageService.unpinExcalidrawLink(
      messageId: messageId,
    );

    if (!mounted) return;

    if (!success) {
      if (originalMessage != null) {
        setState(() {
          final index = _messages.indexWhere((m) => m.id == messageId);
          if (index != -1) {
            _messages[index] = originalMessage!;
          }
        });
      }

      await _loadPinnedExcalidrawLinks();
      if (!mounted) return;

      _showTopSnackBar(
        const SnackBar(
          content: Text(
            'Failed to unpin Excalidraw',
            style: TextStyle(color: Colors.white),
          ),
          duration: Duration(seconds: 2),
          backgroundColor: Color(0xFFD32F2F),
        ),
      );
      return;
    }

    await _loadPinnedExcalidrawLinks();
  }

  /// Copy message content to clipboard
  void _copyMessageToClipboard(Message message) {
    Clipboard.setData(ClipboardData(text: message.content));
    _showTopSnackBar(
      const SnackBar(
        content: Text('Message copied to clipboard'),
        duration: Duration(seconds: 2),
        backgroundColor: Color(0xFF4CAF50),
      ),
    );
  }

  /// Open the forward recipient picker for a message.
  void _openForwardPicker(Message message) {
    ForwardRecipientPicker.show(
      context,
      currentUserId: _currentUserId ?? 0,
      onConfirm: (selectedUserIds) async {
        if (selectedUserIds.isEmpty) return;

        final result = await ForwardService.forwardToUsers(
          message: message,
          recipientIds: selectedUserIds,
        );

        if (!mounted) return;

        if (result.allSucceeded) {
          _showTopBanner(
            'Forwarded to ${result.successCount} recipient${result.successCount > 1 ? "s" : ""}',
            backgroundColor: const Color(0xFF059669),
            icon: Icons.check_circle_outline,
            autoHideAfter: const Duration(seconds: 2),
          );
        } else if (result.allFailed) {
          _showTopBanner(
            'Failed to forward message',
            backgroundColor: const Color(0xFFB91C1C),
            icon: Icons.error_outline,
            autoHideAfter: const Duration(seconds: 3),
          );
        } else {
          _showTopBanner(
            'Forwarded to ${result.successCount}, failed for ${result.failureCount}',
            backgroundColor: const Color(0xFFD97706),
            icon: Icons.warning_amber_rounded,
            autoHideAfter: const Duration(seconds: 3),
          );
        }
      },
    );
  }

  /// Edit message via socket
  void _editMessage(Message message, String newContent) {
    _socketService.editMessage(message.id, newContent);

    // Optimistically update the message locally
    setState(() {
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index != -1) {
        final updatedMessage = Message(
          id: message.id,
          senderId: message.senderId,
          recipientId: message.recipientId,
          content: newContent,
          messageType: message.messageType,
          timestamp: message.timestamp,
          timestampMs: message.timestampMs,
          isRead: message.isRead,
          readAt: message.readAt,
          readAtMs: message.readAtMs,
          deliveredAt: message.deliveredAt,
          deliveredAtMs: message.deliveredAtMs,
          status: message.status,
          threadId: message.threadId,
          replyToId: message.replyToId,
          replyPreview: message.replyPreview,
          reactions: message.reactions,
          fileUrl: message.fileUrl,
          fileName: message.fileName,
          fileSize: message.fileSize,
          fileType: message.fileType,
          isDeleted: message.isDeleted,
        );
        _messages[index] = updatedMessage;
      }
    });

    _showTopSnackBar(
      const SnackBar(
        content: Text('Message edited'),
        duration: Duration(seconds: 2),
        backgroundColor: Color(0xFF4CAF50),
      ),
    );
  }

  /// Auto-translate incoming message (silent, no loading indicators)
  Future<void> _autoTranslateMessage(Message message) async {
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
          'ðŸŒ Auto-translated message ${message.id}: "${message.content}" â†’ "$translatedText"',
        );
      }
    } catch (e) {
      debugPrint('Auto-translation failed for message ${message.id}: $e');
      // Fail silently for auto-translation
    }
  }

  /// Translate a message manually
  Future<void> _translateMessage(Message message) async {
    if (!mounted) return;

    try {
      // Check if already translated - toggle off if so
      if (_messageTranslations.containsKey(message.id)) {
        setState(() {
          _messageTranslations.remove(message.id);
        });
        _showTopBanner(
          'Translation hidden',
          backgroundColor: const Color(0xFF6B7280),
          icon: Icons.translate,
          autoHideAfter: const Duration(seconds: 1),
        );
        return;
      }

      // Show loading indicator
      _showTopBanner(
        'Translating...',
        backgroundColor: const Color(0xFF4F46E5),
        icon: Icons.translate,
        autoHideAfter: null,
        showDismiss: false,
      );

      final targetLang = await TranslationService.getUserLanguage();
      final translatedText = await TranslationService.translateMessage(
        text: message.content,
        targetLang: targetLang,
      );

      if (!mounted) return;

      // Hide loading indicator
      _hideTopBanner();

      if (translatedText != null && translatedText != message.content) {
        // Store translation and update UI
        setState(() {
          _messageTranslations[message.id] = translatedText;
        });

        _showTopBanner(
          'Message translated',
          backgroundColor: const Color(0xFF4CAF50),
          icon: Icons.check_circle_outline,
          autoHideAfter: const Duration(seconds: 1),
        );
      } else if (translatedText == message.content) {
        // Same text, no translation needed
        _showTopBanner(
          'Message is already in your language',
          backgroundColor: const Color(0xFF6B7280),
          icon: Icons.info_outline,
          autoHideAfter: const Duration(seconds: 2),
        );
      } else {
        // Translation failed
        _showTopBanner(
          'Translation failed. Please try again.',
          backgroundColor: const Color(0xFFEF4444),
          icon: Icons.error_outline,
          autoHideAfter: const Duration(seconds: 3),
        );
      }
    } catch (e) {
      // Hide loading indicator
      if (!mounted) return;
      _hideTopBanner();

      debugPrint('Translation error: $e');
      _showTopBanner(
        'Translation failed. Please try again.',
        backgroundColor: const Color(0xFFEF4444),
        icon: Icons.error_outline,
        autoHideAfter: const Duration(seconds: 3),
      );
    }
  }

  /// Show delete confirmation dialog
  void _showDeleteConfirmation(Message message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        title: const Text(
          'Delete Message',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Are you sure you want to delete this message? This action cannot be undone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteMessage(message);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// Delete message via socket
  void _deleteMessage(Message message) {
    _socketService.deleteMessage(message.id);

    // Admins leave no trace; regular users see a deleted placeholder
    setState(() {
      final index = _messages.indexWhere((m) => m.id == message.id);
      if (index != -1) {
        if (_currentUserIsAdmin) {
          _messages.removeAt(index);
        } else {
          final updatedMessage = Message(
            id: message.id,
            senderId: message.senderId,
            recipientId: message.recipientId,
            content: 'This message was deleted',
            messageType: message.messageType,
            timestamp: message.timestamp,
            timestampMs: message.timestampMs,
            isRead: message.isRead,
            readAt: message.readAt,
            readAtMs: message.readAtMs,
            deliveredAt: message.deliveredAt,
            deliveredAtMs: message.deliveredAtMs,
            status: message.status,
            threadId: message.threadId,
            replyToId: message.replyToId,
            replyPreview: message.replyPreview,
            reactions: message.reactions,
            fileUrl: message.fileUrl,
            fileName: message.fileName,
            fileSize: message.fileSize,
            fileType: message.fileType,
            isDeleted: true,
          );
          _messages[index] = updatedMessage;
        }
      }
    });

    _showTopSnackBar(
      const SnackBar(
        content: Text('Message deleted'),
        duration: Duration(seconds: 2),
        backgroundColor: Color(0xFF4CAF50),
      ),
    );
  }

  /// Handle message deleted event from socket (when other user deletes)
  void _handleMessageDeleted(Map<String, dynamic> data) {
    final messageId = data['message_id'] as int?;
    if (messageId == null) return;

    setState(() {
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index != -1) {
        if (_currentUserIsAdmin) {
          _messages.removeAt(index);
        } else {
          final message = _messages[index];
          final updatedMessage = Message(
            id: message.id,
            senderId: message.senderId,
            recipientId: message.recipientId,
            content: 'This message was deleted',
            messageType: message.messageType,
            timestamp: message.timestamp,
            timestampMs: message.timestampMs,
            isRead: message.isRead,
            readAt: message.readAt,
            readAtMs: message.readAtMs,
            deliveredAt: message.deliveredAt,
            deliveredAtMs: message.deliveredAtMs,
            status: message.status,
            threadId: message.threadId,
            replyToId: message.replyToId,
            replyPreview: message.replyPreview,
            reactions: message.reactions,
            fileUrl: null,
            fileName: null,
            fileSize: null,
            fileType: null,
            isDeleted: true,
          );
          _messages[index] = updatedMessage;
        }
      }
    });
  }

  /// Handle message edited event from socket (when other user edits)
  void _handleMessageEdited(Map<String, dynamic> data) {
    final messageId = _extractTaskMessageId(data);
    if (messageId == null) return;

    final payload = _extractTaskPayloadMap(data);

    setState(() {
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index == -1) {
        final createdAt = _extractTaskCreatedAt(data);
        final completedAt = _extractTaskCompletedAt(data);
        final payloadIsTask =
            (payload?['is_task'] as bool?) ??
            (data['is_task'] as bool?) ??
            createdAt != null || completedAt != null;
        if (payloadIsTask) {
          _pendingLiveTaskCreatedAtByMessageId[messageId] =
              _pendingLiveTaskCreatedAtByMessageId[messageId] ??
              createdAt ??
              DateTime.now().toIso8601String();
          if (completedAt != null) {
            _pendingLiveTaskCompletedAtByMessageId[messageId] = completedAt;
          }
        }
        return;
      }

      final message = _messages[index];

      if (payload != null) {
        final mergedPayload = <String, dynamic>{
          ...payload,
          'id':
              _toInt(payload['id']) ??
              _toInt(payload['message_id']) ??
              message.id,
          'sender_id': _toInt(payload['sender_id']) ?? message.senderId,
          'recipient_id':
              _toInt(payload['recipient_id']) ?? message.recipientId,
          'content': payload['content'] ?? message.content,
          'message_type': payload['message_type'] ?? message.messageType,
          'timestamp': payload['timestamp'] ?? message.timestamp,
          'timestamp_ms':
              _toInt(payload['timestamp_ms']) ?? message.timestampMs,
          'is_read': payload['is_read'] ?? message.isRead,
          'status': payload['status'] ?? message.status,
          'thread_id': payload['thread_id'] ?? message.threadId,
          'reply_to_id': payload['reply_to_id'] ?? message.replyToId,
          'reply_preview': payload['reply_preview'] ?? message.replyPreview,
          'reactions': payload['reactions'] ?? message.reactions,
          'file_url': payload['file_url'] ?? message.fileUrl,
          'file_name': payload['file_name'] ?? message.fileName,
          'file_size': payload['file_size'] ?? message.fileSize,
          'file_type': payload['file_type'] ?? message.fileType,
          'is_deleted': payload['is_deleted'] ?? message.isDeleted,
          'read_at': payload['read_at'] ?? message.readAt,
          'read_at_ms': payload['read_at_ms'] ?? message.readAtMs,
          'delivered_at': payload['delivered_at'] ?? message.deliveredAt,
          'delivered_at_ms':
              payload['delivered_at_ms'] ?? message.deliveredAtMs,
          'is_task':
              payload['is_task'] ??
              (data['is_task'] as bool?) ??
              message.isTask,
          'task_created_at':
              payload['task_created_at'] ??
              data['task_created_at'] ??
              data['created_at'] ??
              message.taskCreatedAt,
          'task_completed_at':
              payload['task_completed_at'] ??
              data['task_completed_at'] ??
              data['completed_at'] ??
              message.taskCompletedAt,
          'is_excalidraw_link':
              payload['is_excalidraw_link'] ?? message.isExcalidrawLink,
          'excalidraw_pinned_at':
              payload['excalidraw_pinned_at'] ?? message.excalidrawPinnedAt,
          'is_pinned': payload['is_pinned'] ?? message.isPinned,
          'pinned_at': payload['pinned_at'] ?? message.pinnedAt,
          'pinned_by_user_id':
              _toInt(payload['pinned_by_user_id']) ?? message.pinnedByUserId,
        };

        _messages[index] = _applyPendingLiveTaskState(
          Message.fromJson(mergedPayload),
        );
        return;
      }

      final newContent = data['content'] as String?;
      final hasTaskCompletedField =
          data.containsKey('task_completed_at') ||
          data.containsKey('completed_at');
      final updatedMessage = Message(
        id: message.id,
        senderId: message.senderId,
        recipientId: message.recipientId,
        content: newContent ?? message.content,
        messageType: (data['message_type'] as String?) ?? message.messageType,
        timestamp: message.timestamp,
        timestampMs: message.timestampMs,
        isRead: message.isRead,
        readAt: message.readAt,
        readAtMs: message.readAtMs,
        deliveredAt: message.deliveredAt,
        deliveredAtMs: message.deliveredAtMs,
        status: message.status,
        threadId: message.threadId,
        replyToId: message.replyToId,
        replyPreview: message.replyPreview,
        reactions: message.reactions,
        fileUrl: message.fileUrl,
        fileName: message.fileName,
        fileSize: message.fileSize,
        fileType: message.fileType,
        isDeleted: message.isDeleted,
        isTask: (data['is_task'] as bool?) ?? message.isTask,
        taskCreatedAt: _extractTaskCreatedAt(data) ?? message.taskCreatedAt,
        taskCompletedAt: hasTaskCompletedField
            ? _extractTaskCompletedAt(data)
            : message.taskCompletedAt,
        isExcalidrawLink: message.isExcalidrawLink,
        excalidrawPinnedAt: message.excalidrawPinnedAt,
        isPinned: message.isPinned,
        pinnedAt: message.pinnedAt,
        pinnedByUserId: message.pinnedByUserId,
        caption: message.caption,
      );
      _messages[index] = updatedMessage;
    });
    _notifyTaskModalChanged();
  }

  /// Handle task added event from socket
  void _handleTaskAdded(Map<String, dynamic> data) {
    final messageId = _extractTaskMessageId(data);
    if (messageId == null) return;

    final createdAt =
        _extractTaskCreatedAt(data) ?? DateTime.now().toIso8601String();

    setState(() {
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index != -1) {
        final message = _messages[index];
        final updatedMessage = _copyMessageWithTaskState(
          message,
          isTask: true,
          taskCreatedAt: createdAt,
          taskCompletedAt: null,
        );
        _messages[index] = updatedMessage;
        // Keep _taskMessages in sync with the visible page version
        _upsertTaskMessage(updatedMessage);
      } else {
        _pendingLiveTaskCreatedAtByMessageId[messageId] = createdAt;
        _pendingLiveTaskCompletedAtByMessageId.remove(messageId);
        // If this message isn't on the visible page yet, add a stub so the
        // badge / modal count is immediately correct.
        if (!_taskMessages.any((m) => m.id == messageId)) {
          _upsertTaskMessageFromData(
            messageId,
            data,
            isTask: true,
            taskCreatedAt: createdAt,
            taskCompletedAt: null,
          );
        }
      }
    });
    if (mounted) _taskBadgeAnimController.forward(from: 0);
    _notifyTaskModalChanged();
  }

  /// Handle task completed event from socket
  void _handleTaskCompleted(Map<String, dynamic> data) {
    final messageId = _extractTaskMessageId(data);
    if (messageId == null) return;

    final createdAt =
        _extractTaskCreatedAt(data) ?? DateTime.now().toIso8601String();
    final completedAt =
        _extractTaskCompletedAt(data) ?? DateTime.now().toIso8601String();

    setState(() {
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index != -1) {
        final message = _messages[index];
        final updatedMessage = _copyMessageWithTaskState(
          message,
          isTask: true,
          taskCreatedAt: message.taskCreatedAt ?? createdAt,
          taskCompletedAt: completedAt,
        );
        _messages[index] = updatedMessage;
        _upsertTaskMessage(updatedMessage);
      } else {
        _pendingLiveTaskCreatedAtByMessageId[messageId] =
            _pendingLiveTaskCreatedAtByMessageId[messageId] ?? createdAt;
        _pendingLiveTaskCompletedAtByMessageId[messageId] = completedAt;
        _upsertTaskMessageFromData(
          messageId,
          data,
          isTask: true,
          taskCreatedAt: createdAt,
          taskCompletedAt: completedAt,
        );
      }
    });
    _notifyTaskModalChanged();
  }

  /// Handle task uncompleted event from socket
  void _handleTaskUncompleted(Map<String, dynamic> data) {
    final messageId = _extractTaskMessageId(data);
    if (messageId == null) return;

    final payload = _extractTaskPayloadMap(data);
    final explicitTaskState =
        (payload?['is_task'] as bool?) ?? (data['is_task'] as bool?);
    final shouldRemainTask = explicitTaskState ?? true;
    final createdAt =
        _extractTaskCreatedAt(data) ?? DateTime.now().toIso8601String();

    setState(() {
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index != -1) {
        final message = _messages[index];
        final updated = _copyMessageWithTaskState(
          message,
          isTask: shouldRemainTask,
          taskCreatedAt: shouldRemainTask
              ? (message.taskCreatedAt ?? createdAt)
              : null,
          taskCompletedAt: null,
        );
        _messages[index] = updated;
        if (shouldRemainTask) {
          _upsertTaskMessage(updated);
        } else {
          _taskMessages.removeWhere((m) => m.id == messageId);
        }
      } else {
        if (shouldRemainTask) {
          _pendingLiveTaskCreatedAtByMessageId[messageId] =
              _pendingLiveTaskCreatedAtByMessageId[messageId] ?? createdAt;
          _upsertTaskMessageFromData(
            messageId,
            data,
            isTask: true,
            taskCreatedAt: createdAt,
            taskCompletedAt: null,
          );
        } else {
          _pendingLiveTaskCreatedAtByMessageId.remove(messageId);
          _taskMessages.removeWhere((m) => m.id == messageId);
        }
        _pendingLiveTaskCompletedAtByMessageId.remove(messageId);
      }
    });
    if (mounted) _taskBadgeAnimController.forward(from: 0);
    _notifyTaskModalChanged();
  }

  /// Insert or update a message in _taskMessages by id.
  void _upsertTaskMessage(Message updated) {
    final idx = _taskMessages.indexWhere((m) => m.id == updated.id);
    if (idx != -1) {
      _taskMessages[idx] = updated;
    } else {
      _taskMessages.add(updated);
    }
  }

  /// Build a minimal Message stub from socket event data and upsert it into
  /// _taskMessages. Used when the real message object isn't on the visible page.
  void _upsertTaskMessageFromData(
    int messageId,
    Map<String, dynamic> data, {
    required bool isTask,
    required String? taskCreatedAt,
    required String? taskCompletedAt,
  }) {
    final payload = _extractTaskPayloadMap(data);
    final content =
        (payload?['content'] as String?) ?? (data['content'] as String?) ?? '';
    final senderId =
        _toInt(payload?['sender_id']) ?? _toInt(data['sender_id']) ?? 0;
    final timestamp = taskCreatedAt ?? DateTime.now().toIso8601String();
    final stub = Message.fromJson({
      'id': messageId,
      'sender_id': senderId,
      'recipient_id': widget.otherUser.id,
      'content': content,
      'message_type': 'text',
      'timestamp': timestamp,
      'timestamp_ms': 0,
      'is_read': true,
      'status': 'seen',
      'thread_id': '',
      'reactions': <String, dynamic>{},
      'is_deleted': false,
      'is_task': isTask,
      'task_created_at': taskCreatedAt,
      'task_completed_at': taskCompletedAt,
    });
    _upsertTaskMessage(stub);
  }

  String? _extractExcalidrawPinnedAtFromEvent(Map<String, dynamic> data) {
    final directPinnedAt = _asNonEmptyString(data['pinned_at']);
    if (directPinnedAt != null) {
      return directPinnedAt;
    }

    final payload = data['message_data'];
    if (payload is Map<String, dynamic>) {
      return _asNonEmptyString(payload['excalidraw_pinned_at']) ??
          _asNonEmptyString(payload['pinned_at']);
    }
    if (payload is Map) {
      final mapped = Map<String, dynamic>.from(payload);
      return _asNonEmptyString(mapped['excalidraw_pinned_at']) ??
          _asNonEmptyString(mapped['pinned_at']);
    }

    return null;
  }

  /// Handle excalidraw pinned event from socket
  void _handleExcalidrawPinned(Map<String, dynamic> data) {
    final messageId = _toInt(data['message_id']);
    final pinnedAt =
        _extractExcalidrawPinnedAtFromEvent(data) ??
        DateTime.now().toIso8601String();

    if (messageId != null) {
      setState(() {
        final index = _messages.indexWhere((m) => m.id == messageId);
        if (index != -1) {
          final message = _messages[index];
          final hasExcalidrawUrl =
              _extractExcalidrawUrl(message.content) != null;
          _messages[index] = _copyMessageWithExcalidrawState(
            message,
            isExcalidrawLink: hasExcalidrawUrl,
            excalidrawPinnedAt: pinnedAt,
          );
        }
      });
    }

    // Reconcile the pinned-links section from the server so the badge/modal
    // update live. Previously this only updated when the message was already
    // loaded AND its id matched the event's server message_id — so a freshly
    // pasted/sent link (whose local optimistic copy has a temporary id) never
    // appeared until leaving and re-entering the room.
    unawaited(_loadPinnedExcalidrawLinks());
  }

  /// Handle excalidraw unpinned event from socket
  void _handleExcalidrawUnpinned(Map<String, dynamic> data) {
    final messageId = _toInt(data['message_id']);

    if (messageId != null) {
      setState(() {
        final index = _messages.indexWhere((m) => m.id == messageId);
        if (index != -1) {
          final message = _messages[index];
          final hasExcalidrawUrl =
              _extractExcalidrawUrl(message.content) != null;
          _messages[index] = _copyMessageWithExcalidrawState(
            message,
            isExcalidrawLink: hasExcalidrawUrl,
            excalidrawPinnedAt: null,
          );
        }
        // Optimistically drop it locally for instant feedback.
        _pinnedExcalidrawLinks.removeWhere(
          (l) => (l['id'] as int?) == messageId,
        );
      });
    }

    // Reconcile the pinned-links section from the server (see _handleExcalidrawPinned).
    unawaited(_loadPinnedExcalidrawLinks());
  }

  /// Safely parse any numeric type (int, double, String) to int.
  /// Socket.IO JSON may deliver numbers as double on some platforms.
  int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  String? _asNonEmptyString(dynamic value) {
    if (value == null) return null;
    final stringValue = value.toString();
    return stringValue.isEmpty ? null : stringValue;
  }

  Map<String, dynamic>? _extractTaskPayloadMap(Map<String, dynamic> data) {
    final payload = data['message_data'] ?? data['message'];
    if (payload is Map<String, dynamic>) {
      return payload;
    }
    if (payload is Map) {
      return Map<String, dynamic>.from(payload);
    }
    return null;
  }

  int? _extractTaskMessageId(Map<String, dynamic> data) {
    final directId =
        _toInt(data['message_id']) ??
        _toInt(data['messageId']) ??
        _toInt(data['id']);
    if (directId != null) {
      return directId;
    }

    final nestedMessage = _extractTaskPayloadMap(data);
    if (nestedMessage != null) {
      return _toInt(nestedMessage['message_id']) ??
          _toInt(nestedMessage['messageId']) ??
          _toInt(nestedMessage['id']);
    }

    return null;
  }

  String? _extractTaskCreatedAt(Map<String, dynamic> data) {
    final direct =
        _asNonEmptyString(data['task_created_at']) ??
        _asNonEmptyString(data['created_at']);
    if (direct != null && direct.isNotEmpty) {
      return direct;
    }

    final nestedMessage = _extractTaskPayloadMap(data);
    if (nestedMessage != null) {
      final nested =
          _asNonEmptyString(nestedMessage['task_created_at']) ??
          _asNonEmptyString(nestedMessage['created_at']);
      if (nested != null && nested.isNotEmpty) {
        return nested;
      }
    }

    return null;
  }

  String? _extractTaskCompletedAt(Map<String, dynamic> data) {
    final direct =
        _asNonEmptyString(data['task_completed_at']) ??
        _asNonEmptyString(data['completed_at']);
    if (direct != null && direct.isNotEmpty) {
      return direct;
    }

    final nestedMessage = _extractTaskPayloadMap(data);
    if (nestedMessage != null) {
      final nested =
          _asNonEmptyString(nestedMessage['task_completed_at']) ??
          _asNonEmptyString(nestedMessage['completed_at']);
      if (nested != null && nested.isNotEmpty) {
        return nested;
      }
    }

    return null;
  }

  /// Handle message status updates (delivered/seen)
  void _handleMessageStatusUpdate(Map<String, dynamic> data) {
    final messageId = _toInt(data['message_id']);
    final status = data['status'] as String?;
    final deliveredAt = data['delivered_at'] as String?;
    final readAt = data['read_at'] as String?;

    if (messageId == null || status == null) return;

    // Status priority â€” never downgrade (server may send 'seen' then 'delivered' out of order)
    const statusRank = {'sending': 0, 'sent': 1, 'delivered': 2, 'seen': 3};

    setState(() {
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index != -1) {
        final message = _messages[index];
        // Skip if incoming status is lower priority than current
        final currentRank = statusRank[message.status] ?? 0;
        final incomingRank = statusRank[status] ?? 0;
        if (incomingRank < currentRank) {
          debugPrint(
            'âš ï¸ Ignoring status downgrade for $messageId: ${message.status} â†’ $status',
          );
          return;
        }
        final updatedMessage = Message(
          id: message.id,
          senderId: message.senderId,
          recipientId: message.recipientId,
          content: message.content,
          messageType: message.messageType,
          timestamp: message.timestamp,
          timestampMs: message.timestampMs,
          isRead: status == 'seen',
          readAt: readAt,
          readAtMs: readAt != null
              ? DateTime.parse(readAt).millisecondsSinceEpoch
              : null,
          deliveredAt: deliveredAt ?? message.deliveredAt,
          deliveredAtMs: deliveredAt != null
              ? DateTime.parse(deliveredAt).millisecondsSinceEpoch
              : message.deliveredAtMs,
          status: status,
          threadId: message.threadId,
          replyToId: message.replyToId,
          replyPreview: message.replyPreview,
          reactions: message.reactions,
          fileUrl: message.fileUrl,
          fileName: message.fileName,
          fileSize: message.fileSize,
          fileType: message.fileType,
          isDeleted: message.isDeleted,
          isTask: message.isTask,
          taskCreatedAt: message.taskCreatedAt,
          taskCompletedAt: message.taskCompletedAt,
          isExcalidrawLink: message.isExcalidrawLink,
          excalidrawPinnedAt: message.excalidrawPinnedAt,
          isPinned: message.isPinned,
          pinnedAt: message.pinnedAt,
          pinnedByUserId: message.pinnedByUserId,
          caption: message.caption,
        );
        _messages[index] = updatedMessage;
      }
    });

    debugPrint('ðŸ“Š Message $messageId status updated to: $status');
  }

  /// Handle messages read notifications
  void _handleMessagesRead(Map<String, dynamic> data) {
    final readerId = _toInt(data['reader_id']);
    final messageCount = _toInt(data['message_count']);

    if (readerId == widget.otherUser.id &&
        messageCount != null &&
        messageCount > 0) {
      debugPrint(
        'âœ“âœ“ ${widget.otherUser.fullName} read $messageCount messages',
      );

      // Update status of sent messages to 'seen'
      setState(() {
        for (int i = 0; i < _messages.length; i++) {
          final message = _messages[i];
          if (message.senderId == _currentUserId &&
              message.recipientId == widget.otherUser.id &&
              message.status != 'seen') {
            final updatedMessage = Message(
              id: message.id,
              senderId: message.senderId,
              recipientId: message.recipientId,
              content: message.content,
              messageType: message.messageType,
              timestamp: message.timestamp,
              timestampMs: message.timestampMs,
              isRead: true,
              readAt: DateTime.now().toIso8601String(),
              readAtMs: DateTime.now().millisecondsSinceEpoch,
              deliveredAt: message.deliveredAt,
              deliveredAtMs: message.deliveredAtMs,
              status: 'seen',
              threadId: message.threadId,
              replyToId: message.replyToId,
              replyPreview: message.replyPreview,
              reactions: message.reactions,
              fileUrl: message.fileUrl,
              fileName: message.fileName,
              fileSize: message.fileSize,
              fileType: message.fileType,
              isDeleted: message.isDeleted,
              isTask: message.isTask,
              taskCreatedAt: message.taskCreatedAt,
              taskCompletedAt: message.taskCompletedAt,
              isExcalidrawLink: message.isExcalidrawLink,
              excalidrawPinnedAt: message.excalidrawPinnedAt,
              isPinned: message.isPinned,
              pinnedAt: message.pinnedAt,
              pinnedByUserId: message.pinnedByUserId,
              caption: message.caption,
            );
            _messages[i] = updatedMessage;
          }
        }
      });
    }
  }

  /// Show tasks modal
  int _getCrossAxisCount(double width) {
    if (width > 900) return 4; // tablet / web
    if (width > 600) return 3; // large phone
    return 2; // normal phone
  }

  void _showTasksModal() {
    _showTasksCenteredModal();
  }

  void _showTasksCenteredModal() {
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
            final allTasks = _taskMessages.where((m) => m.isTask).toList();
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
                        color: const Color(0xFF0D9488).withValues(alpha: 0.8),
                        width: 1.4,
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
                                    0xFF0D9488,
                                  ).withValues(alpha: 0.22),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(
                                      0xFF0D9488,
                                    ).withValues(alpha: 0.7),
                                  ),
                                ),
                                child: const Icon(
                                  Icons.check_circle_outline,
                                  color: Color(0xFF2DD4BF),
                                  size: 16,
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'Tasks',
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
                                    0xFF0D9488,
                                  ).withValues(alpha: 0.22),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: const Color(
                                      0xFF0D9488,
                                    ).withValues(alpha: 0.55),
                                  ),
                                ),
                                child: Text(
                                  '${completedTasks.length}/${allTasks.length}',
                                  style: const TextStyle(
                                    color: Color(0xFF5EEAD4),
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
                                              0xFF0D9488,
                                            ).withValues(alpha: 0.16),
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                            Icons.task_alt,
                                            color: Color(0xFF2DD4BF),
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
                                  builder: (context, setState) {
                                    final displayTasks =
                                        _taskFilter == 'pending'
                                        ? pendingTasks
                                        : completedTasks;
                                    final otherText = _taskFilter == 'pending'
                                        ? 'Completed'
                                        : 'Pending';

                                    return Column(
                                      children: [
                                        // ── Sticky filter header ─────────────
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
                                                  setState(() {
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
                                        // ── Scrollable grid ───────────────────────────────────
                                        Expanded(
                                          child: Padding(
                                            padding: const EdgeInsets.all(8),
                                            child: GridView.builder(
                                              padding: EdgeInsets.zero,
                                              gridDelegate:
                                                  SliverGridDelegateWithFixedCrossAxisCount(
                                                    crossAxisCount:
                                                        _getCrossAxisCount(
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
                                                return _buildTaskCard(
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

  /// Show full detail sheet for a task with jump-to-bubble button
  void _showTaskDetail(Message task, bool isCompleted) {
    final isSentByMe = task.senderId == _currentUserId;
    final senderLabel = isSentByMe ? 'You' : widget.otherUser.fullName;

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
                    color: const Color(0xFF0D9488).withValues(alpha: 0.5),
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
                    // Drag handle + header
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF0D9488,
                            ).withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.task_alt,
                            color: Color(0xFF2DD4BF),
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'Task Detail',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        if (localCompleted)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF22C55E,
                              ).withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: const Color(
                                  0xFF22C55E,
                                ).withValues(alpha: 0.5),
                              ),
                            ),
                            child: const Text(
                              'Completed',
                              style: TextStyle(
                                color: Color(0xFF4ADE80),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // Sender + timestamp row
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: isSentByMe
                              ? const Color(0xFF7C3AED)
                              : const Color(0xFF3944BC),
                          child: Text(
                            senderLabel[0].toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          senderLabel,
                          style: TextStyle(
                            color: Colors.grey[300],
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text('·', style: TextStyle(color: Colors.grey[600])),
                        const SizedBox(width: 6),
                        Text(
                          task.formattedTimestampFull,
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Full message content
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Text(
                        task.content,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Action buttons row
                    Row(
                      children: [
                        // Toggle complete button
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              if (localCompleted) {
                                _socketService.uncompleteTask(task.id);
                                // Optimistic update — no full message reload needed
                                _handleTaskUncompleted({'message_id': task.id});
                              } else {
                                _socketService.completeTask(task.id);
                                _handleTaskCompleted({
                                  'message_id': task.id,
                                  'task_completed_at': DateTime.now()
                                      .toIso8601String(),
                                });
                              }
                              setSheetState(
                                () => localCompleted = !localCompleted,
                              );
                            },
                            icon: Icon(
                              localCompleted
                                  ? Icons.undo
                                  : Icons.check_circle_outline,
                              size: 16,
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
                        // Jump to bubble button
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              Navigator.pop(sheetCtx); // close detail sheet
                              Navigator.pop(context); // close task modal
                              _jumpToTaskBubble(task);
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

  Widget _buildTaskCard(Message task, bool isCompleted, int taskNumber) {
    // Cycling accent colours matching the web UI
    const accentColors = [
      Color(0xFF8B5CF6), // purple
      Color(0xFF3B82F6), // blue
      Color(0xFF10B981), // green
      Color(0xFF0D9488), // teal
      Color(0xFFEF4444), // red
      Color(0xFF06B6D4), // cyan
      Color(0xFFEC4899), // pink
      Color(0xFFF97316), // orange
    ];
    final accent = accentColors[(taskNumber - 1) % accentColors.length];
    final labelColor = isCompleted ? const Color(0xFF22C55E) : accent;

    // Image tasks show a thumbnail so the task is visually identifiable.
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
      onTap: () => _showTaskDetail(task, isCompleted),
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
                // Coloured top accent bar + Task #N label row
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
                      // Task #N label
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
                              backgroundColor: Color(0xFF22C55E),
                            ),
                          );
                        },
                        child: Icon(
                          Icons.copy,
                          color: Colors.grey[600],
                          size: 14,
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => _removeTask(task),
                        child: Icon(
                          Icons.close,
                          color: Colors.grey[600],
                          size: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                // Checkbox + content
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 4, 8, 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: () {
                            if (isCompleted) {
                              _socketService.uncompleteTask(task.id);
                              _handleTaskUncompleted({'message_id': task.id});
                            } else {
                              _socketService.completeTask(task.id);
                              _handleTaskCompleted({
                                'message_id': task.id,
                                'task_completed_at': DateTime.now()
                                    .toIso8601String(),
                              });
                            }
                          },
                          borderRadius: BorderRadius.circular(999),
                          child: Padding(
                            padding: const EdgeInsets.only(top: 1, right: 6),
                            child: Icon(
                              isCompleted
                                  ? Icons.check_circle
                                  : Icons.circle_outlined,
                              color: isCompleted
                                  ? const Color(0xFF22C55E)
                                  : Colors.grey[600],
                              size: 18,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: showThumb
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: Image.network(
                                                thumbUrl,
                                                fit: BoxFit.cover,
                                                width: double.infinity,
                                                errorBuilder: (_, __, ___) =>
                                                    Container(
                                                      color: const Color(
                                                        0xFF1E1E2E,
                                                      ),
                                                      alignment:
                                                          Alignment.center,
                                                      child: Icon(
                                                        Icons.broken_image,
                                                        color: Colors.grey[600],
                                                        size: 20,
                                                      ),
                                                    ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            contentLabel,
                                            style: TextStyle(
                                              color: Colors.grey[300],
                                              fontSize: 10,
                                              decoration: isCompleted
                                                  ? TextDecoration.lineThrough
                                                  : null,
                                              decorationColor: Colors.grey[600],
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      )
                                    : Text(
                                        contentLabel,
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          decoration: isCompleted
                                              ? TextDecoration.lineThrough
                                              : null,
                                          decorationColor: Colors.grey[600],
                                          height: 1.3,
                                        ),
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                task.formattedTime,
                                style: TextStyle(
                                  color: Colors.grey[500],
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (isCompleted)
              Positioned(
                bottom: 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    color: Color(0xFF22C55E),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 10),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _removeTask(Message message) {
    _unmarkMessageTask(message);
  }

  /// Show excalidraw modal
  void _showExcalidrawModal() {
    final excalidrawLinks = List<Map<String, dynamic>>.from(
      _pinnedExcalidrawLinks,
    );

    // Opening is the read receipt for board changes.
    final conversationKey = _excalidrawConversationKey;
    if (conversationKey != null) {
      unawaited(ExcalidrawRoomsService.markSeen(conversationKey));
      if (_excalidrawRoomsUnread != 0) {
        setState(() => _excalidrawRoomsUnread = 0);
      }
    }
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
                          // Orange gradient to match the web Excalidraw modal.
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
                                  color: Colors.white.withValues(alpha: 0.5),
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
                                  color: Colors.white.withValues(alpha: 0.5),
                                ),
                              ),
                              child: Text(
                                '${excalidrawLinks.length} pinned',
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
                                  color: Colors.white.withValues(alpha: 0.08),
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
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Boards hosted by us, scoped to this chat.
                              ExcalidrawRoomsSection(
                                key: _excalRoomsSectionKey,
                                conversationKey: _excalidrawConversationKey,
                                myUserId: _currentUserId,
                                onCountChanged: _refreshExcalidrawRoomsUnread,
                              ),
                              Divider(
                                color: Colors.white.withValues(alpha: 0.08),
                                height: 1,
                              ),
                              const Padding(
                                padding: EdgeInsets.fromLTRB(14, 14, 14, 0),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.push_pin_outlined,
                                      color: Color(0xFFF97316),
                                      size: 17,
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      'Pinned links',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              excalidrawLinks.isEmpty
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
                                // Nested inside the modal's scroll view now
                                // that boards share the space above it.
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: excalidrawLinks.length,
                                itemBuilder: (context, index) {
                                  final link = excalidrawLinks[index];
                                  final content =
                                      (link['content'] as String?) ?? '';
                                  // Prefer the server-provided order number so
                                  // mobile + web show the same sequence.
                                  final orderNumber =
                                      (link['order_number'] as num?)?.toInt() ??
                                      (index + 1);
                                  final rawTitle =
                                      (link['excalidraw_title'] as String?)
                                          ?.trim() ??
                                      '';
                                  final cardTitle = rawTitle.isNotEmpty
                                      ? rawTitle
                                      : 'Link #$orderNumber';
                                  final extractedUrl = _extractExcalidrawUrl(
                                    content,
                                  );
                                  final displayText =
                                      (extractedUrl ?? content).trim().isEmpty
                                      ? 'Excalidraw link'
                                      : (extractedUrl ?? content).trim();
                                  final openLink = () {
                                    Navigator.pop(context);
                                    if (extractedUrl != null) {
                                      _openExcalidrawUrl(extractedUrl);
                                    } else {
                                      _openExcalidrawLink(content);
                                    }
                                  };
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF252542),
                                      borderRadius: BorderRadius.circular(12),
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
                                          // Title row
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
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          // Full URL (tap to open, wraps)
                                          GestureDetector(
                                            onTap: openLink,
                                            child: Text(
                                              displayText,
                                              style: const TextStyle(
                                                color: Color(0xFF93C5FD),
                                                fontSize: 14,
                                                height: 1.4,
                                                decoration:
                                                    TextDecoration.underline,
                                                decorationColor: Color(
                                                  0xFF93C5FD,
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          // Colored full timestamp (wraps)
                                          Text(
                                            _formatPinnedAt(
                                              link['excalidraw_pinned_at']
                                                  as String?,
                                            ),
                                            style: const TextStyle(
                                              color: Color(0xFFFBBF24),
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              height: 1.3,
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          // Action buttons
                                          Row(
                                            children: [
                                              Expanded(
                                                child: InkWell(
                                                  onTap: openLink,
                                                  borderRadius:
                                                      BorderRadius.circular(8),
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
                                                          color: Colors.white,
                                                          size: 16,
                                                        ),
                                                        SizedBox(width: 6),
                                                        Text(
                                                          'Open',
                                                          style: TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 14,
                                                            fontWeight:
                                                                FontWeight.w600,
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
                                                    Navigator.pop(context);
                                                    await _unpinExcalidrawFromModal(
                                                      link,
                                                    );
                                                  },
                                                  borderRadius:
                                                      BorderRadius.circular(8),
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
                                                          color: Colors.white,
                                                          size: 16,
                                                        ),
                                                        SizedBox(width: 6),
                                                        Text(
                                                          'Unpin',
                                                          style: TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 14,
                                                            fontWeight:
                                                                FontWeight.w600,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          // Big bold centered order number
                                          const SizedBox(height: 10),
                                          Center(
                                            child: Text(
                                              '$orderNumber',
                                              style: const TextStyle(
                                                color: Color(0xFFFB923C),
                                                fontSize: 30,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
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
  }

  /// Full timestamp matching the web Excalidraw modal, e.g.
  /// "2026-06-12 23:46:50 GMT+8 - Friday, June 12, 2026".
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

  String? _extractExcalidrawUrl(String content) {
    for (final match in _excalidrawUrlRegex.allMatches(content)) {
      final rawUrl = match.group(0);
      if (rawUrl == null || rawUrl.isEmpty) continue;

      final cleanedUrl = _trimTrailingUrlCharacters(rawUrl);
      if (cleanedUrl.isEmpty) continue;

      final normalizedUrl = cleanedUrl.toLowerCase().startsWith('http')
          ? cleanedUrl
          : 'https://$cleanedUrl';

      final uri = Uri.tryParse(normalizedUrl);
      if (uri != null && uri.host.toLowerCase().contains('excalidraw.com')) {
        return normalizedUrl;
      }
    }

    return null;
  }

  /// Open excalidraw link in browser
  void _openExcalidrawLink(String content) {
    final extractedUrl = _extractExcalidrawUrl(content);
    if (extractedUrl == null) {
      return;
    }

    _openExcalidrawUrl(extractedUrl);
  }

  /// Open a drawing in the in-app board screen rather than the system browser.
  ///
  /// Only for boards on our own backend: those are login-gated, and the WebView
  /// is the only place the app's JWT can establish a session. A link to
  /// excalidraw.com is somebody else's site, so it goes out as a normal link.
  void _openExcalidrawUrl(String rawUrl) {
    final normalized = rawUrl.toLowerCase().startsWith('http')
        ? rawUrl
        : 'https://$rawUrl';

    if (!normalized.startsWith(ApiConfig.origin)) {
      unawaited(_openMessageUrl(rawUrl));
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExcalidrawBoardScreen(url: normalized),
      ),
    );
  }

  String _trimTrailingUrlCharacters(String url) {
    const trailingPunctuation = '.,!?;:';
    var trimmed = url;

    while (trimmed.isNotEmpty &&
        trailingPunctuation.contains(trimmed[trimmed.length - 1])) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }

    while (trimmed.endsWith(')')) {
      final openParens = '('.allMatches(trimmed).length;
      final closeParens = ')'.allMatches(trimmed).length;
      if (closeParens <= openParens) {
        break;
      }
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }

    return trimmed;
  }

  Future<void> _openMessageUrl(String rawUrl) async {
    final normalizedUrl = rawUrl.toLowerCase().startsWith('http')
        ? rawUrl
        : 'https://$rawUrl';
    final uri = Uri.tryParse(normalizedUrl);

    if (uri == null) {
      if (!mounted) return;
      _showTopSnackBar(
        const SnackBar(
          content: Text('Invalid link'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    var opened = false;

    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Failed to open URL externally: $e');
    }

    if (!opened) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.platformDefault);
      } catch (e) {
        debugPrint('Failed to open URL with platform default mode: $e');
      }
    }

    if (opened) {
      return;
    }

    if (!mounted) return;
    _showTopSnackBar(
      SnackBar(
        content: Text('Could not open: $normalizedUrl'),
        backgroundColor: Colors.red,
      ),
    );
  }

  List<InlineSpan> _buildLinkifiedTextSpans(String text, TextStyle baseStyle) {
    final linkStyle = baseStyle.copyWith(
      color: const Color(0xFF93C5FD),
      decoration: TextDecoration.underline,
      decorationColor: const Color(0xFF93C5FD),
    );
    final mentionStyle = baseStyle.copyWith(
      color: const Color(0xFF7DD3FC),
      fontWeight: FontWeight.w600,
    );
    final mentionRegex = RegExp(r'(^|\s)(@[A-Za-z0-9._-]+)');

    void appendMentionAwareText(List<InlineSpan> target, String segment) {
      if (segment.isEmpty) return;

      var localCursor = 0;
      for (final mention in mentionRegex.allMatches(segment)) {
        final prefix = mention.group(1) ?? '';
        final token = mention.group(2) ?? '';
        final mentionStart = mention.start + prefix.length;
        final mentionEnd = mentionStart + token.length;

        if (mentionStart > localCursor) {
          target.add(
            TextSpan(
              text: segment.substring(localCursor, mentionStart),
              style: baseStyle,
            ),
          );
        }

        target.add(TextSpan(text: token, style: mentionStyle));
        localCursor = mentionEnd;
      }

      if (localCursor < segment.length) {
        target.add(
          TextSpan(text: segment.substring(localCursor), style: baseStyle),
        );
      }
    }

    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in _messageUrlRegex.allMatches(text)) {
      if (match.start > cursor) {
        appendMentionAwareText(spans, text.substring(cursor, match.start));
      }

      final matchedText = match.group(0) ?? '';
      final cleanedUrl = _trimTrailingUrlCharacters(matchedText);
      final trailing = matchedText.substring(cleanedUrl.length);

      if (cleanedUrl.isNotEmpty) {
        spans.add(
          TextSpan(
            text: cleanedUrl,
            style: linkStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () {
                _openMessageUrl(cleanedUrl);
              },
          ),
        );
      }

      if (trailing.isNotEmpty) {
        appendMentionAwareText(spans, trailing);
      }

      cursor = match.end;
    }

    if (cursor < text.length) {
      appendMentionAwareText(spans, text.substring(cursor));
    }

    if (spans.isEmpty) {
      appendMentionAwareText(spans, text);
    }

    return spans;
  }

  Widget _buildLinkifiedMessageText({
    required String text,
    required bool isTaskMessage,
    required Color taskAccentColor,
  }) {
    final scale = _uiScale(context);
    final baseStyle = TextStyle(color: Colors.white, fontSize: 15 * scale);
    final spans = _buildLinkifiedTextSpans(text, baseStyle);

    if (isTaskMessage) {
      return Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Container(
                width: 18 * scale,
                height: 18 * scale,
                margin: EdgeInsets.only(right: 6 * scale),
                decoration: BoxDecoration(
                  color: taskAccentColor.withValues(alpha: 0.25),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: taskAccentColor.withValues(alpha: 0.75),
                    width: 1.2,
                  ),
                ),
                child: Center(
                  child: Text(
                    'T',
                    style: TextStyle(
                      // The 'T' takes the task accent color (teal #0D9488 for an
                      // active task, green when completed) — matching the web.
                      color: taskAccentColor,
                      fontSize: 9 * scale,
                      fontWeight: FontWeight.w800,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ),
            ...spans,
          ],
        ),
      );
    }

    return Text.rich(TextSpan(children: spans));
  }

  /// Refresh messages from server
  Future<void> _refreshMessages() async {
    try {
      final messages = await MessageService.getConversationMessages(
        userId: widget.otherUser.id,
        limit: 50,
        offlineFirst: false,
      );
      setState(() {
        _messages = messages.reversed.toList();
        _databaseLoadedMessageIds
          ..clear()
          ..addAll(
            _messages
                .where((message) => message.id > 0)
                .map((message) => message.id),
          );
      });
      _notifyTaskModalChanged();
    } catch (e) {
      debugPrint('Error refreshing messages: $e');
    }
  }

  /// Build reply preview widget (shown above input)
  Widget _buildReplyPreview() {
    if (_replyingToMessage == null) return const SizedBox.shrink();

    final message = _replyingToMessage!;
    final isSentByMe = message.senderId == _currentUserId;
    final senderName = isSentByMe ? 'You' : widget.otherUser.fullName;

    // Get preview content
    String content;
    if (message.isDeleted) {
      content = 'Deleted message';
    } else if (message.messageType == 'voice' ||
        message.messageType == 'audio') {
      content = '🎤 Voice message';
    } else if (message.messageType == 'image') {
      content = '📷 Photo';
    } else if (message.messageType == 'video') {
      content = '🎬 Video';
    } else if (message.messageType == 'file' ||
        message.messageType == 'document') {
      content = '📎 ${message.fileName ?? "File"}';
    } else {
      content = message.content.length > 50
          ? '${message.content.substring(0, 50)}...'
          : message.content;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF2D2D44),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: const Color(0xFF7C3AED), width: 4),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.reply, color: Color(0xFF7C3AED), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying to $senderName',
                  style: const TextStyle(
                    color: Color(0xFF7C3AED),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  content,
                  style: TextStyle(color: Colors.grey[400], fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: _clearReply,
            child: Container(
              padding: const EdgeInsets.all(4),
              child: const Icon(Icons.close, color: Colors.grey, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  /// Build edit preview widget (shown above input when editing a message)
  Widget _buildEditPreview() {
    if (_editingMessage == null) return const SizedBox.shrink();

    final message = _editingMessage!;
    final content = message.content.length > 50
        ? '${message.content.substring(0, 50)}...'
        : message.content;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF2D2D44),
        borderRadius: BorderRadius.circular(8),
        border: const Border(
          left: BorderSide(color: Color(0xFF7C3AED), width: 4),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.edit_rounded, color: Color(0xFF7C3AED), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Editing message',
                  style: TextStyle(
                    color: Color(0xFF7C3AED),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  content,
                  style: TextStyle(color: Colors.grey[400], fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: _clearEdit,
            child: Container(
              padding: const EdgeInsets.all(4),
              child: const Icon(Icons.close, color: Colors.grey, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  /// Check if two timestamps are on the same day
  bool _isSameDay(String timestamp1, String timestamp2) {
    try {
      final date1 = _parseUtcTimestamp(timestamp1);
      final date2 = _parseUtcTimestamp(timestamp2);
      return date1.year == date2.year &&
          date1.month == date2.month &&
          date1.day == date2.day;
    } catch (e) {
      return true; // Assume same day if parsing fails
    }
  }

  /// Ensure emoji uses color presentation (appends U+FE0F if needed)
  /// Characters like â¤ (U+2764) render as black text on Android without this.
  String _ensureColorEmoji(String emoji) {
    const variationSelector = '\uFE0F';
    // Characters that need the variation selector for color rendering
    const needsSelector = <int>{
      0x2764, // â¤
      0x2602, // â˜‚
      0x2614, // â˜”
      0x263A, // â˜º
      0x2B50, // â­
      0x2600, // â˜€
      0x2601, // â˜
      0x260E, // â˜Ž
      0x2709, // âœ‰
      0x270F, // âœ
      0x2744, // â„
      0x2728, // âœ¨
      0x2702, // âœ‚
      0x26A1, // âš¡
      0x2615, // â˜•
    };
    if (emoji.isNotEmpty &&
        needsSelector.contains(emoji.runes.first) &&
        !emoji.contains(variationSelector)) {
      return emoji + variationSelector;
    }
    return emoji;
  }

  /// Parse each message's server-provided reactions ({counts, by_user}) into
  /// the screen's messageId → emoji → {reactorUserId} map. Must run on EVERY
  /// load path (initial fetch, cache-first, pagination) so reactions on
  /// loaded/history messages — including the other peer's — render, matching
  /// the web app. (Previously only the initial server fetch hydrated these, so
  /// cached and older-loaded messages showed no reaction.)
  void _hydrateReactionsForMessages(Iterable<Message> msgs) {
    for (final msg in msgs) {
      if (msg.reactions.isEmpty) continue;
      final parsed = <String, Set<String>>{};

      // Current backend format: { "counts": {...}, "by_user": [{user_id, reaction}] }
      final byUser = msg.reactions['by_user'];
      if (byUser is List && byUser.isNotEmpty) {
        for (final entry in byUser) {
          if (entry is Map) {
            final emoji = entry['reaction']?.toString();
            final userId = entry['user_id']?.toString();
            if (emoji != null && emoji.isNotEmpty && userId != null) {
              parsed.putIfAbsent(emoji, () => <String>{}).add(userId);
            }
          }
        }
      } else {
        // Legacy formats: { "emoji": { "by_user": [...] } } or { "emoji": [users] }
        msg.reactions.forEach((key, value) {
          if (key == 'counts' || key == 'by_user') return;
          if (value is Map) {
            final users = value['by_user'];
            if (users is List && users.isNotEmpty) {
              parsed[key.toString()] = Set<String>.from(
                users.map((u) => u.toString()),
              );
            }
          } else if (value is List) {
            parsed[key.toString()] = Set<String>.from(
              value.map((u) => u.toString()),
            );
          }
        });
      }

      if (parsed.isNotEmpty) {
        _messageReactions[msg.id] = parsed;
      }
    }
  }

  /// Build reaction pills for a message
  Widget _buildReactionPills(int messageId) {
    final reactions = _messageReactions[messageId];
    if (reactions == null || reactions.isEmpty) {
      return const SizedBox.shrink();
    }

    final currentUserStr = _currentUserId?.toString() ?? '';
    final pills = <Widget>[];
    reactions.forEach((emoji, users) {
      if (users.isNotEmpty) {
        final iReacted = users.contains(currentUserStr);
        final displayEmoji = _ensureColorEmoji(emoji);
        pills.add(
          GestureDetector(
            onTap: () => _showReactorsSheet(messageId),
            child: Container(
              margin: const EdgeInsets.only(right: 2),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: iReacted
                    ? const Color(0xFF3A3A5C) // Highlighted if you reacted
                    : const Color(0xFF2C2C2E),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: iReacted
                      ? const Color(0xFF6D28D9).withValues(alpha: 0.5)
                      : Colors.white.withValues(alpha: 0.15),
                  width: iReacted ? 1.0 : 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    displayEmoji,
                    style: const TextStyle(
                      fontSize: 16,
                      fontFamilyFallback: [
                        'Apple Color Emoji',
                        'Android Emoji',
                        'Noto Color Emoji',
                      ],
                    ),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    '${users.length}',
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    });

    if (pills.isEmpty) return const SizedBox.shrink();

    return Wrap(spacing: 2, runSpacing: 2, children: pills);
  }

  /// Toggle reaction (add or remove specific emoji, supports multiple reactions per user)
  void _toggleReaction(int messageId, String emoji) {
    // Backend set_reaction now handles toggle: if user has this emoji it removes it,
    // if not it adds it. User can have multiple different emojis on same message.
    final ids = [_currentUserId ?? 0, widget.otherUser.id]..sort();
    final roomId = 'chat_${ids[0]}_${ids[1]}';
    _socketService.setReaction(
      messageId,
      emoji,
      chatUserId: widget.otherUser.id,
      roomId: roomId,
    );
    debugPrint('ðŸ‘† Toggling reaction $emoji on message $messageId');
  }

  /// Resolve a user ID string to a display name for the reactions sheet.
  String _resolveReactorName(String odorIdStr) {
    final currentUserStr = _currentUserId?.toString() ?? '';
    if (odorIdStr == currentUserStr) return 'You';
    if (odorIdStr == widget.otherUser.id.toString()) {
      return widget.otherUser.fullName;
    }
    return 'User $odorIdStr';
  }

  /// Show bottom sheet listing who reacted to a message (WhatsApp-style)
  /// Tapping your own reaction row removes it.
  void _showReactorsSheet(int messageId) {
    final reactions = _messageReactions[messageId];
    if (reactions == null || reactions.isEmpty) return;

    final currentUserStr = _currentUserId?.toString() ?? '';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Text(
                  'Reactions',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                ...reactions.entries.where((e) => e.value.isNotEmpty).map((
                  entry,
                ) {
                  final emoji = entry.key;
                  final users = entry.value;
                  final iReacted = users.contains(currentUserStr);
                  // Resolve user IDs to display names
                  final displayNames = users
                      .map((id) => _resolveReactorName(id))
                      .toList();
                  return GestureDetector(
                    onTap: iReacted
                        ? () {
                            // Remove your reaction and close sheet
                            _toggleReaction(messageId, emoji);
                            Navigator.of(ctx).pop();
                          }
                        : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 8,
                      ),
                      margin: const EdgeInsets.only(bottom: 4),
                      decoration: BoxDecoration(
                        color: iReacted
                            ? const Color(0xFF2A2A3E)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Text(
                            _ensureColorEmoji(emoji),
                            style: const TextStyle(
                              fontSize: 24,
                              fontFamilyFallback: [
                                'Apple Color Emoji',
                                'Android Emoji',
                                'Noto Color Emoji',
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  displayNames.join(', '),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 2,
                                ),
                                if (iReacted)
                                  const Text(
                                    'Tap to remove',
                                    style: TextStyle(
                                      color: Color(0xFF9B59B6),
                                      fontSize: 11,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Text(
                            '${users.length}',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Show reaction picker for a message
  void _showReactionPicker(
    BuildContext context,
    int messageId,
    Offset position,
  ) {
    ReactionPicker.show(
      context: context,
      position: position,
      onReactionSelected: (emoji) {
        final ids = [_currentUserId ?? 0, widget.otherUser.id]..sort();
        final roomId = 'chat_${ids[0]}_${ids[1]}';
        _socketService.setReaction(
          messageId,
          emoji,
          chatUserId: widget.otherUser.id,
          roomId: roomId,
        );
      },
    );
  }

  Widget _buildMessageBubble(Message message, bool isSentByMe) {
    final scale = _uiScale(context);
    final canDoubleTapEdit =
        isSentByMe && message.messageType == 'text' && !message.isDeleted;

    return ChatMessageBubble(
      message: message,
      isSentByMe: isSentByMe,
      scale: scale,
      showTimestamps: _showTimestamps,
      isSelected: _bubbleFlashId == message.id,
      messageReactions: _messageReactions,
      messageTranslations: _messageTranslations,
      onTapUp: (details) {
        // Only show task menu for non-link messages
        // If message contains a URL, the link recognizer will handle the tap
        final hasUrl = _messageUrlRegex.hasMatch(message.content);
        if (!hasUrl) {
          _toggleTaskActionForMessage(message, details.globalPosition);
        }
      },
      onDoubleTap: canDoubleTapEdit ? () => _startInlineEdit(message) : null,
      onLongPress: () => _showMessageContextMenu(message, isSentByMe),
      onShowReactionPicker: _showReactionPicker,
      onOpenMediaViewer: _openMediaViewer,
      onDownloadIncomingFile: _downloadIncomingFile,
      onOpenMessageUrl: _openMessageUrl,
      statusForUi: _statusForUi,
      isOnlyFilename: _isOnlyFilename,
      canQuickToggleExcalidrawPin: _canQuickToggleExcalidrawPin,
      formatFileSize: _formatFileSize,
      buildReactionPills: _buildReactionPills,
      buildLinkifiedMessageText:
          ({
            required String text,
            required bool isTaskMessage,
            required Color taskAccentColor,
          }) => _buildLinkifiedMessageText(
            text: text,
            isTaskMessage: isTaskMessage,
            taskAccentColor: taskAccentColor,
          ),
      buildStatusIndicator: _buildStatusIndicator,
    );
  }

  String _statusForUi(Message message) {
    if (_isSelfChat && message.senderId == _currentUserId) {
      return 'seen';
    }
    // History/loaded messages reflect their real state instead of always
    // showing "seen": isRead is authoritative for "seen" (legacy read messages
    // may have is_read=true with no read_at), otherwise fall back to the
    // server-computed status (sent -> delivered -> seen). Fixes outgoing
    // bubbles showing green double-ticks on reload despite being only
    // delivered/sent. Mirrors the web chat.js fix.
    if (_databaseLoadedMessageIds.contains(message.id)) {
      if (message.isRead) return 'seen';
      return message.status.isEmpty ? 'sent' : message.status;
    }
    return message.status;
  }

  /// Check if content is just a filename (for media messages)
  bool _isOnlyFilename(String content) {
    if (content.isEmpty) return true;
    // Check if it looks like a filename with extension
    final filenamePattern = RegExp(r'^[\w\-\.\s]+\.\w{2,5}$');
    return filenamePattern.hasMatch(content.trim());
  }

  /// Build message status indicator widget.
  /// Colors mirror the web exactly (chat-global.js getStatusHtml): sent and
  /// delivered are grey #999, seen is green #22c55e (single ✓ = sent, double
  /// ✓✓ = delivered/seen).
  Widget _buildStatusIndicator(String status, [double scale = 1.0]) {
    const statusGrey = Color(0xFF999999); // web #999
    const seenGreen = Color(0xFF22C55E); // web #22c55e
    switch (status) {
      case 'sent':
        return Icon(Icons.check, size: 16 * scale, color: statusGrey);
      case 'delivered':
        return Icon(Icons.done_all, size: 16 * scale, color: statusGrey);
      case 'seen':
        return Icon(Icons.done_all, size: 16 * scale, color: seenGreen);
      case 'failed':
        return Icon(
          Icons.error_outline,
          size: 16 * scale,
          color: const Color(0xFFEF4444),
        );
      default:
        // queued / sending / pending — web shows a clock here.
        return Icon(Icons.schedule, size: 16 * scale, color: statusGrey);
    }
  }

  /// Open full screen media viewer
  void _openMediaViewer(Message message) {
    if (message.fileUrl == null) return;

    // Collect all media messages from the conversation (image or video)
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
    }).toList();

    if (mediaMessages.isEmpty) return;

    // Sort chronologically by timestampMs (oldest first)
    mediaMessages.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));

    // Find the index of the tapped message in the sorted list
    final initialIndex = mediaMessages.indexWhere((m) => m.id == message.id);
    if (initialIndex == -1) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => MediaGalleryViewer(
          mediaMessages: mediaMessages,
          initialIndex: initialIndex,
          currentUserId: _currentUserId ?? 0,
          otherUserName: widget.otherUser.fullName,
        ),
      ),
    );
  }

  Color _getAvatarColor() {
    const colors = [
      Color(0xFF1F77B4),
      Color(0xFFFF7F0E),
      Color(0xFF2CA02C),
      Color(0xFFD62728),
      Color(0xFF9467BD),
      Color(0xFF8C564B),
      Color(0xFFE377C2),
      Color(0xFF7F7F7F),
      Color(0xFFBCBD22),
      Color(0xFF17BECF),
    ];
    return colors[widget.otherUser.avatarColorIndex % colors.length];
  }

  /// Parse a timestamp string, treating it as UTC if no timezone info is present
  /// (matches the web app's parseTs() behavior)
  DateTime _parseUtcTimestamp(String timestamp) {
    final hasTimezone = RegExp(r'[zZ]|[+-]\d{2}:?\d{2}$').hasMatch(timestamp);
    final parsed = DateTime.parse(hasTimezone ? timestamp : '${timestamp}Z');
    return parsed.toLocal();
  }

  /// Format last seen timestamp as relative time for header/profile labels.
  /// Examples: today, 8 hours ago, yesterday, 3 days ago
  String _formatLastSeen(String timestamp) {
    try {
      final DateTime lastSeen = _parseUtcTimestamp(timestamp);
      final DateTime now = DateTime.now();
      final Duration difference = now.difference(lastSeen);
      final DateTime todayStart = DateTime(now.year, now.month, now.day);
      final DateTime yesterdayStart = todayStart.subtract(
        const Duration(days: 1),
      );

      if (!lastSeen.isBefore(todayStart)) {
        if (difference.inHours >= 1) {
          final hours = difference.inHours;
          return '$hours ${hours == 1 ? "hour" : "hours"} ago';
        }
        return 'today';
      }

      if (!lastSeen.isBefore(yesterdayStart)) {
        final hour = lastSeen.hour;
        final min = lastSeen.minute.toString().padLeft(2, '0');
        final period = hour >= 12 ? 'PM' : 'AM';
        final h = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
        return 'yesterday at $h:$min $period';
      }

      if (difference.inDays < 7) {
        final days = difference.inDays;
        return '$days ${days == 1 ? "day" : "days"} ago';
      }

      if (difference.inDays < 30) {
        final weeks = (difference.inDays / 7).floor();
        return '$weeks ${weeks == 1 ? "week" : "weeks"} ago';
      }

      if (difference.inDays < 365) {
        final months = (difference.inDays / 30).floor();
        return '$months ${months == 1 ? "month" : "months"} ago';
      }

      final years = (difference.inDays / 365).floor();
      return '$years ${years == 1 ? "year" : "years"} ago';
    } catch (e) {
      debugPrint('Error parsing last seen: $e');
      return 'recently';
    }
  }

  String? _formattedPartnerLastSeen() {
    final raw = _partnerLastSeen;
    if (raw == null || raw.isEmpty) return null;
    return _formatLastSeen(raw);
  }
}

class _VoiceRecordingModal extends StatefulWidget {
  final Function(String path, Duration duration) onSend;
  final VoidCallback onCancel;

  const _VoiceRecordingModal({required this.onSend, required this.onCancel});

  @override
  State<_VoiceRecordingModal> createState() => _VoiceRecordingModalState();
}

class _VoiceRecordingModalState extends State<_VoiceRecordingModal> {
  // Native channel â€” backed by Android MediaRecorder
  static const _ch = MethodChannel(
    'com.example.flutter_messenger_v2/audio_recorder',
  );

  // Keep FlutterSoundPlayer for pre-send playback preview
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  bool _isRecorderInitialized = false;
  bool _isPlayerInitialized = false;
  bool _isRecording = false;
  bool _isPaused = false;
  bool _hasRecording = false;
  String? _recordingPath;
  Duration _duration = Duration.zero;
  Timer? _timer;
  List<double> _waveformData = [];
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _initRecorder();
  }

  Future<void> _initRecorder() async {
    try {
      // Only open the player â€” recording goes through the native channel
      await _player.openPlayer();
      setState(() {
        _isRecorderInitialized = true; // native channel is always ready
        _isPlayerInitialized = true;
      });
    } catch (e) {
      debugPrint('Error initializing player: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Stop any in-progress recording when modal is dismissed
    if (_isRecording) {
      _ch.invokeMethod('stopRecording').catchError((_) {});
    }
    _player.closePlayer();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  Future<void> _startRecording() async {
    if (!_isRecorderInitialized) return;

    try {
      final directory = await getTemporaryDirectory();
      final path =
          '${directory.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

      setState(() {
        _isRecording = true;
        _isPaused = false;
        _recordingPath = path;
        _duration = Duration.zero;
        _waveformData = [];
      });

      // Start the native MediaRecorder
      await _ch.invokeMethod('startRecording', {'path': path});

      // Poll amplitude every 100 ms via MediaRecorder.getMaxAmplitude()
      _startWaveformTimer();
    } catch (e) {
      debugPrint('Native startRecording error: $e');
      if (mounted) {
        setState(() => _isRecording = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error starting recording: $e')));
      }
    }
  }

  void _startWaveformTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (t) async {
      if (!mounted || !_isRecording || _isPaused) return;
      try {
        // getMaxAmplitude returns 0-32767; it resets each call (peak-hold)
        final raw = await _ch.invokeMethod<int>('getAmplitude') ?? 0;
        // Normalise: apply sqrt so quiet sounds are more visible
        final normalized = raw > 0
            ? math.sqrt(raw / 32767.0).clamp(0.05, 1.0)
            : 0.05;
        if (mounted && _isRecording && !_isPaused) {
          setState(() {
            _duration += const Duration(milliseconds: 100);
            _waveformData.add(normalized);
            if (_waveformData.length > 50) _waveformData.removeAt(0);
          });
        }
      } catch (_) {
        // Channel error â€” just increment duration silently
        if (mounted && _isRecording && !_isPaused) {
          setState(() => _duration += const Duration(milliseconds: 100));
        }
      }
    });
  }

  Future<void> _pauseRecording() async {
    try {
      await _ch.invokeMethod('pauseRecording');
      _timer?.cancel();
      setState(() => _isPaused = true);
    } catch (e) {
      debugPrint('Pause error: $e');
    }
  }

  Future<void> _resumeRecording() async {
    try {
      await _ch.invokeMethod('resumeRecording');
      setState(() => _isPaused = false);
      _startWaveformTimer();
    } catch (e) {
      debugPrint('Resume error: $e');
    }
  }

  Future<void> _stopRecording() async {
    try {
      _timer?.cancel();
      await _ch.invokeMethod('stopRecording');
      setState(() {
        _isRecording = false;
        _isPaused = false;
        _hasRecording = true;
      });
    } catch (e) {
      debugPrint('Stop recording error: $e');
    }
  }

  Future<void> _playRecording() async {
    if (_recordingPath == null || !_isPlayerInitialized) return;
    try {
      await _player.startPlayer(
        fromURI: _recordingPath!,
        whenFinished: () {
          if (mounted) setState(() => _isPlaying = false);
        },
      );
      setState(() => _isPlaying = true);
    } catch (e) {
      debugPrint('Error playing recording: $e');
    }
  }

  Future<void> _stopPlaying() async {
    try {
      await _player.stopPlayer();
      setState(() => _isPlaying = false);
    } catch (e) {
      debugPrint('Error stopping playback: $e');
    }
  }

  void _discardRecording() {
    setState(() {
      _hasRecording = false;
      _waveformData = [];
      _duration = Duration.zero;
    });
    // Delete the file
    if (_recordingPath != null) {
      try {
        File(_recordingPath!).delete();
      } catch (_) {}
    }
    _recordingPath = null;
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Tight vertical budget: keeps waveform, timer, controls and cancel all visible
    final isCompact = mq.size.height < 600;

    return SafeArea(
      top: false, // bottom sheet â€” only apply bottom safe area
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF2D2D2D),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[600],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),

                // Title
                const Text(
                  'Voice Message',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: isCompact ? 12 : 20),

                // Duration display
                Text(
                  _formatDuration(_duration),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 44,
                    fontWeight: FontWeight.w300,
                    fontFamily: 'monospace',
                  ),
                ),
                SizedBox(height: isCompact ? 10 : 16),

                // Waveform visualization
                SizedBox(
                  height: isCompact ? 40 : 56,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (int i = 0; i < 50; i++)
                        Container(
                          width: 4,
                          height:
                              (i < _waveformData.length
                                  ? _waveformData[i]
                                  : 0.1) *
                              (isCompact ? 36 : 48),
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            color: _isRecording && !_isPaused
                                ? const Color(0xFFEF4444)
                                : (_hasRecording
                                      ? const Color(0xFF10B981)
                                      : Colors.grey[600]),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: isCompact ? 16 : 24),

                // Controls
                if (!_isRecording && !_hasRecording) ...[
                  // Initial state â€” Start button
                  ElevatedButton.icon(
                    onPressed: _isRecorderInitialized ? _startRecording : null,
                    icon: const Icon(Icons.mic, size: 24),
                    label: Text(
                      _isRecorderInitialized
                          ? 'Start Recording'
                          : 'Initializing...',
                      style: const TextStyle(fontSize: 16),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFEF4444),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                  ),
                ] else if (_isRecording) ...[
                  // Recording state â€” Pause/Resume + Stop
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        onPressed: _isPaused
                            ? _resumeRecording
                            : _pauseRecording,
                        icon: Icon(
                          _isPaused ? Icons.play_arrow : Icons.pause,
                          size: 32,
                          color: Colors.white,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.grey[700],
                          padding: const EdgeInsets.all(14),
                        ),
                      ),
                      const SizedBox(width: 20),
                      IconButton(
                        onPressed: _stopRecording,
                        icon: const Icon(
                          Icons.stop,
                          size: 32,
                          color: Colors.white,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFFEF4444),
                          padding: const EdgeInsets.all(14),
                        ),
                      ),
                    ],
                  ),
                ] else if (_hasRecording) ...[
                  // Has recording â€” Discard / Play / Send
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        onPressed: _discardRecording,
                        icon: const Icon(
                          Icons.delete,
                          size: 26,
                          color: Colors.white,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.grey[700],
                          padding: const EdgeInsets.all(12),
                        ),
                      ),
                      IconButton(
                        onPressed: _isPlaying ? _stopPlaying : _playRecording,
                        icon: Icon(
                          _isPlaying ? Icons.stop : Icons.play_arrow,
                          size: 32,
                          color: Colors.white,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFF3B82F6),
                          padding: const EdgeInsets.all(14),
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          if (_recordingPath != null) {
                            widget.onSend(_recordingPath!, _duration);
                          }
                        },
                        icon: const Icon(
                          Icons.send,
                          size: 26,
                          color: Colors.white,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          padding: const EdgeInsets.all(12),
                        ),
                      ),
                    ],
                  ),
                ],

                SizedBox(height: isCompact ? 12 : 20),

                // Cancel button
                TextButton(
                  onPressed: () async {
                    if (_isRecording) {
                      await _ch
                          .invokeMethod('stopRecording')
                          .catchError((_) {});
                    }
                    widget.onCancel();
                  },
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.grey, fontSize: 15),
                  ),
                ),

                // Bottom safe-area padding (accounts for home indicator etc.)
                SizedBox(height: mq.padding.bottom > 0 ? mq.padding.bottom : 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-width phrase input field with an animated gradient border
/// that appears while AI generation is in progress.
class _PhraseInputField extends StatefulWidget {
  final TextEditingController controller;
  final bool isGenerating;
  final VoidCallback onSubmitted;

  const _PhraseInputField({
    required this.controller,
    required this.isGenerating,
    required this.onSubmitted,
  });

  @override
  State<_PhraseInputField> createState() => _PhraseInputFieldState();
}

class _PhraseInputFieldState extends State<_PhraseInputField>
    with SingleTickerProviderStateMixin {
  late AnimationController _gradientCtrl;

  @override
  void initState() {
    super.initState();
    _gradientCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.isGenerating) _gradientCtrl.repeat();
  }

  @override
  void didUpdateWidget(_PhraseInputField old) {
    super.didUpdateWidget(old);
    if (widget.isGenerating && !_gradientCtrl.isAnimating) {
      _gradientCtrl.repeat();
    } else if (!widget.isGenerating && _gradientCtrl.isAnimating) {
      _gradientCtrl.stop();
      _gradientCtrl.reset();
    }
  }

  @override
  void dispose() {
    _gradientCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: widget.controller,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      maxLength: 200,
      maxLines: 1,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => widget.onSubmitted(),
      decoration: InputDecoration(
        hintText: 'Type a new phrase…',
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
        counterStyle: const TextStyle(color: Colors.white24, fontSize: 10),
        filled: true,
        fillColor: const Color(0xFF252542),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
      ),
    );

    if (!widget.isGenerating) return field;

    return AnimatedBuilder(
      animation: _gradientCtrl,
      builder: (context, child) {
        return CustomPaint(
          painter: _GradientBorderPainter(progress: _gradientCtrl.value),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: field,
            ),
          ),
        );
      },
    );
  }
}

/// Paints a sweeping gradient border (teal → purple → teal) around
/// the phrase input while AI generation is running.
class _GradientBorderPainter extends CustomPainter {
  final double progress;
  static const _radius = 10.0;
  static const _stroke = 2.0;

  const _GradientBorderPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rRect = RRect.fromRectAndRadius(rect, const Radius.circular(_radius));

    // Rotate the gradient so it sweeps around the border
    final angle = progress * 2 * 3.141592653589793;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..shader = SweepGradient(
        startAngle: angle,
        endAngle: angle + 3.141592653589793 * 2,
        colors: const [
          Color(0xFF0F766E),
          Color(0xFF6D28D9),
          Color(0xFFa78bfa),
          Color(0xFF0F766E),
        ],
      ).createShader(rect);

    canvas.drawRRect(rRect, paint);
  }

  @override
  bool shouldRepaint(_GradientBorderPainter old) => old.progress != progress;
}

/// Custom painter that draws a rounded-rectangle progress border
/// around the Send File button. The border fills clockwise from the
/// top-left corner proportional to [progress] (0.0 to 1.0).
class _ProgressBorderPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double borderRadius;
  final double strokeWidth;

  _ProgressBorderPainter({
    required this.progress,
    required this.color,
    required this.borderRadius,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(borderRadius));

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    // Draw the progress as an arc around the rounded rectangle path
    // We use a path metric to draw only a portion of the full border
    final path = Path()..addRRect(rrect);
    final pathMetrics = path.computeMetrics();

    for (final metric in pathMetrics) {
      final extractLength = metric.length * progress.clamp(0.0, 1.0);
      final extractPath = metric.extractPath(0, extractLength);
      canvas.drawPath(extractPath, paint);
    }
  }

  @override
  bool shouldRepaint(_ProgressBorderPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

/// A chip button with a background color darken/lighten on press for tactile feedback.
class _TapHighlightChip extends StatefulWidget {
  final VoidCallback onPressed;
  final Color backgroundColor;
  final Widget child;

  const _TapHighlightChip({
    required this.onPressed,
    required this.backgroundColor,
    required this.child,
  });

  @override
  State<_TapHighlightChip> createState() => _TapHighlightChipState();
}

class _TapHighlightChipState extends State<_TapHighlightChip> {
  bool _pressed = false;

  void _onTapDown(TapDownDetails _) {
    setState(() => _pressed = true);
  }

  void _onTapUp(TapUpDetails _) {
    setState(() => _pressed = false);
    widget.onPressed();
  }

  void _onTapCancel() {
    setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final bg = _pressed
        ? Color.lerp(widget.backgroundColor, Colors.white, 0.25)!
        : widget.backgroundColor;

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: AnimatedContainer(
        duration: Duration.zero,
        curve: Curves.easeOut,
        constraints: const BoxConstraints(minHeight: 30, minWidth: 58),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withValues(alpha: _pressed ? 0.35 : 0.15),
            width: 1,
          ),
        ),
        child: Center(child: widget.child),
      ),
    );
  }
}
