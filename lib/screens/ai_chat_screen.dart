import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../models/link_preview.dart';
import '../services/chat_cache_service.dart';
import '../services/link_preview_service.dart';
import '../services/socket_service.dart';
import '../services/storage_service.dart';
import '../services/tts_service.dart';
import '../utils/chat_scroll_physics.dart';
import '../widgets/reaction_picker.dart';
import '../widgets/chat_composer_shell.dart';
import '../widgets/youtube_preview_card.dart';
import '../widgets/link_preview_card.dart';
import 'package:url_launcher/url_launcher.dart';

enum _LoadResult { success, sessionNotFound, networkError }

class AiChatScreen extends StatefulWidget {
  final String? initialPrompt;

  const AiChatScreen({super.key, this.initialPrompt});

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen>
    with WidgetsBindingObserver {
  final List<Map<String, String>> _messages = <Map<String, String>>[];
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  final Map<int, Map<String, Set<String>>> _messageReactions =
      <int, Map<String, Set<String>>>{};
  OverlayEntry? _topActionBannerEntry;
  Timer? _topActionBannerTimer;

  /// IDs already received via SSE stream — used to skip duplicates from socket sync.
  final Set<int> _sseConfirmedIds = <int>{};

  final SocketService _socketService = SocketService();
  static const String _socketListenerKey = 'ai_chat_screen';

  /// Periodic timer to poll for new AI messages from other devices.
  Timer? _crossDeviceSyncTimer;

  bool _isLoading = true;
  bool _isSending = false;
  bool _showEmojiPicker = false;
  bool _showTimestamps = false;
  bool _autoCorrectionEnabled = true;
  bool _isAtBottom = true;
  bool _hasStreamingAssistant = false;
  bool _isInitialLoadComplete = false;
  bool _isSettlingScroll = false;

  int? _sessionId;
  int? _currentUserId;
  int _nextLocalMessageId = 1;

  static const String _showTimestampsKey = 'ai_show_timestamps';
  static const String _autoCorrectionEnabledKey = 'ai_auto_correction_enabled';

  int _emojiCategoryIndex = 0;

  static const Map<String, String> _autoCorrectionDictionary = <String, String>{
    'u': 'you',
    'ur': 'your',
    'pls': 'please',
    'thx': 'thanks',
    'im': "I'm",
  };

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

  String get _baseUrl {
    final raw = ApiConfig.baseUrl.trim();
    if (raw.endsWith('/')) {
      return raw.substring(0, raw.length - 1);
    }
    return raw;
  }

  Uri _aiUri(String path) => Uri.parse('$_baseUrl/api/ai$path');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScrollPosition);
    _initialize();
  }

  @override
  void dispose() {
    _crossDeviceSyncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _socketService.removeListener('aiChatSync', _socketListenerKey);
    _dismissTopActionBanner();
    _scrollController.removeListener(_handleScrollPosition);
    // Persist a final snapshot so the next open hydrates instantly,
    // including any messages that arrived right before close.
    _persistAiSnapshot();
    _messageController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App came back to foreground — sync messages from server
      _syncMessagesFromServer();
    }
  }

  void _handleScrollPosition() {
    if (!_scrollController.hasClients) return;
    // While the settling loop is actively scrolling to bottom, don't let
    // intermediate layout changes flip _isAtBottom back to false.
    if (_isSettlingScroll) return;
    const bottomThreshold = 24.0;
    final distanceFromBottom =
        _scrollController.position.maxScrollExtent - _scrollController.offset;
    final atBottom = distanceFromBottom <= bottomThreshold;
    if (_isAtBottom != atBottom && mounted) {
      setState(() {
        _isAtBottom = atBottom;
      });
    }
  }

  Future<void> _initialize() async {
    _currentUserId = await StorageService.getUserId();
    await _loadUiPreferences();
    await _initializeAiSession();
    _setupAiChatSync();
    _startCrossDeviceSync();
  }

  /// Start periodic polling for new messages from other devices (web, etc.)
  /// This compensates for cases where the socket ai_chat_sync event is not
  /// delivered (e.g., server doesn't emit for web-originated messages).
  void _startCrossDeviceSync() {
    _crossDeviceSyncTimer?.cancel();
    _crossDeviceSyncTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _syncMessagesFromServer(),
    );
  }

  /// Fetch latest messages from the server and merge any new ones into the list.
  Future<void> _syncMessagesFromServer() async {
    if (!mounted || _isSending || _sessionId == null) {
      debugPrint(
        '[AI SYNC POLL] Skipped: mounted=$mounted, isSending=$_isSending, sessionId=$_sessionId',
      );
      return;
    }

    try {
      final token = await StorageService.getToken();
      if (token == null) return;

      final response = await http
          .get(
            _aiUri('/sessions/$_sessionId/messages'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200 || !mounted) return;

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final rawMessages =
          (payload['messages'] as List<dynamic>? ?? <dynamic>[]);

      final serverMessages = rawMessages
          .map((m) => m as Map<String, dynamic>)
          .where(
            (m) =>
                (m['role'] == 'user' || m['role'] == 'assistant') &&
                (m['content']?.toString().trim().isNotEmpty ?? false),
          )
          .map(
            (m) => <String, String>{
              'id': (m['id'] ?? m['message_id'] ?? '').toString(),
              'role': m['role'].toString(),
              'content': m['content'].toString(),
              'timestamp': (m['created_at'] ?? m['timestamp'] ?? '').toString(),
            },
          )
          .toList();

      if (!mounted) return;

      // Check if there are new messages not in our local list
      final localIds = _messages.map((m) => m['id']).toSet();
      final newMessages = serverMessages
          .where(
            (m) =>
                m['id'] != null &&
                m['id']!.isNotEmpty &&
                !localIds.contains(m['id']),
          )
          .toList();

      if (newMessages.isEmpty) return;

      debugPrint(
        '[AI SYNC POLL] Found ${newMessages.length} new messages from server, updating UI',
      );
      setState(() {
        _messages
          ..clear()
          ..addAll(serverMessages);
      });
      _persistAiSnapshot();

      // Auto-scroll if at bottom
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        if (_isAtBottom) {
          _scrollToBottom();
        }
      });
    } catch (e) {
      // Silent failure — this is background sync
      debugPrint('[AI SYNC] Cross-device sync failed: $e');
    }
  }

  void _setupAiChatSync() {
    _socketService.addListener('aiChatSync', _socketListenerKey, (
      Map<String, dynamic> payload,
    ) {
      if (!mounted) return;
      final action = payload['action']?.toString() ?? '';
      final payloadSessionId = payload['session_id'] as int?;

      debugPrint(
        '🤖 [AI CHAT SCREEN] Received ai_chat_sync: action=$action, '
        'payloadSessionId=$payloadSessionId, mySessionId=$_sessionId, '
        'isSending=$_isSending, hasStreaming=$_hasStreamingAssistant',
      );

      // If the event is for a different session, switch to it (cross-device sync).
      // This handles the case where the web started using a newer session.
      if (payloadSessionId != null && payloadSessionId != _sessionId) {
        debugPrint(
          '🤖 [AI CHAT SCREEN] Session mismatch: payload=$payloadSessionId vs mine=$_sessionId - switching to new session',
        );
        _sessionId = payloadSessionId;
        // Reload messages from the new session
        _reloadCurrentSession();
        return;
      }

      switch (action) {
        case 'message_created':
          // While we are sending, the SSE stream owns all new bubbles for this
          // session (user message + streaming assistant tokens). Suppress socket
          // sync additions for the entire send window to avoid duplicates caused
          // by the race between socket delivery and SSE ID confirmation.
          if (_isSending || _hasStreamingAssistant) break;

          final raw = payload['message'];
          if (raw is! Map) return;
          final msg = Map<String, dynamic>.from(raw as Map);
          final msgId = msg['id'] as int?;

          // Skip if SSE stream confirmed this ID (sent from this device).
          if (msgId != null && _sseConfirmedIds.contains(msgId)) break;

          // Skip if the real ID is already in the local list.
          if (_messages.any((m) => m['id'] == msgId?.toString())) break;

          // Content-based dedup: guard against the narrow window where _isSending
          // just flipped to false but the local bubble still has a negative ID.
          final incomingContent = msg['content']?.toString().trim() ?? '';
          final incomingRole = msg['role']?.toString() ?? '';
          if (incomingContent.isNotEmpty &&
              _messages.any(
                (m) =>
                    m['id'] != null &&
                    m['id']!.startsWith('-') &&
                    m['role'] == incomingRole &&
                    (m['content'] ?? '').trim() == incomingContent,
              )) {
            break;
          }

          setState(() {
            _messages.add(_normalizeSocketMessage(msg));
          });
          _persistAiSnapshot();
          // Auto-scroll during initial load, or if user is near bottom
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_scrollController.hasClients) return;
            final distanceFromBottom =
                _scrollController.position.maxScrollExtent -
                _scrollController.offset;
            // Always scroll during initial load, or if user is near bottom
            if (!_isInitialLoadComplete || distanceFromBottom < 100) {
              _scrollToBottom();
            }
          });
          break;

        case 'message_updated':
          final raw = payload['message'];
          if (raw is! Map) return;
          final msg = Map<String, dynamic>.from(raw as Map);
          final msgId = msg['id']?.toString();
          if (msgId == null) break;
          setState(() {
            final i = _messages.indexWhere((m) => m['id'] == msgId);
            if (i != -1) {
              _messages[i] = _normalizeSocketMessage(msg);
            }
          });
          _persistAiSnapshot();
          break;

        case 'message_deleted':
          final raw = payload['deleted_message'];
          if (raw is! Map) return;
          final deleted = Map<String, dynamic>.from(raw);
          final deletedId = deleted['id']?.toString();
          if (deletedId == null) break;
          setState(() {
            _messages.removeWhere((m) => m['id'] == deletedId);
          });
          _persistAiSnapshot();
          break;

        case 'messages_cleared':
          setState(() => _messages.clear());
          _persistAiSnapshot();
          break;

        default:
          break;
      }
    });
  }

  Map<String, String> _normalizeSocketMessage(Map<String, dynamic> msg) {
    return <String, String>{
      'id': (msg['id'] ?? '').toString(),
      'role': (msg['role'] ?? '').toString(),
      'content': (msg['content'] ?? '').toString(),
      'timestamp': (msg['created_at'] ?? msg['timestamp'] ?? '').toString(),
    };
  }

  /// Persist the in-memory message list to the AI cache. Called after
  /// every mutation (realtime add/update/delete, send, dispose) so the
  /// next open paints from disk without a network round-trip.
  void _persistAiSnapshot() {
    final userId = _currentUserId;
    final sessionId = _sessionId;
    if (userId == null || sessionId == null) return;
    unawaited(
      ChatCacheService.saveAiSessionMessages(
        userId,
        sessionId,
        List<Map<String, String>>.from(_messages),
      ),
    );

    // Persist last AI message time + preview so lobby can sort/display correctly
    if (_messages.isNotEmpty) {
      final lastMsg = _messages.last;
      final role = lastMsg['role'] ?? '';
      final content = (lastMsg['content'] ?? '').trim();
      final timestamp = lastMsg['timestamp'] ?? '';

      if (content.isNotEmpty) {
        final preview = role == 'user'
            ? 'You: ${content.length > 50 ? '${content.substring(0, 50)}...' : content}'
            : (content.length > 60 ? '${content.substring(0, 60)}...' : content);

        unawaited(
          SharedPreferences.getInstance().then((prefs) {
            prefs.setString('ai_last_message_preview_$userId', preview);
            if (timestamp.isNotEmpty) {
              prefs.setString('ai_last_message_time_$userId', timestamp);
            } else {
              prefs.setString(
                'ai_last_message_time_$userId',
                DateTime.now().toUtc().toIso8601String(),
              );
            }
          }),
        );
      }
    }
  }

  Future<void> _loadUiPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _showTimestamps = prefs.getBool(_showTimestampsKey) ?? false;
      _autoCorrectionEnabled = prefs.getBool(_autoCorrectionEnabledKey) ?? true;
    });
  }

  Future<void> _initializeAiSession() async {
    try {
      final token = await StorageService.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('No auth token found');
      }

      final userId = await StorageService.getUserId() ?? 0;
      final savedSessionId = await StorageService.getAiSessionId(userId);

      debugPrint(
        '[AiChatScreen] User ID: $userId, Saved session ID: $savedSessionId',
      );

      // Cache-first hydration: load locally saved session and its cached messages immediately
      // before making any network calls so the screen populates instantly.
      if (savedSessionId != null) {
        _sessionId = savedSessionId;
        final cached = await ChatCacheService.loadAiSessionMessages(
          userId,
          savedSessionId,
        );
        if (cached.isNotEmpty && mounted) {
          setState(() {
            _messages
              ..clear()
              ..addAll(cached);
            _isLoading = false; // Turn off spinner immediately since we have cached messages!
          });
          _jumpToBottomWhenSettled();
        }
      }

      // Always fetch the current (most recently updated) session from the server
      // to stay in sync with other devices (web, etc.). The locally saved ID may
      // be stale if the user chatted on another device.
      final serverSessionId = await _fetchCurrentSession(token);
      debugPrint('[AiChatScreen] Server current session ID: $serverSessionId');

      if (serverSessionId != null && serverSessionId != savedSessionId) {
        // Server has a different (newer) session — switch to it.
        _log(
          'Server session $serverSessionId differs from local $savedSessionId, switching',
        );
        _sessionId = serverSessionId;
        await StorageService.saveAiSessionId(userId, serverSessionId);
        // If we switched sessions, show loader while fetching new messages
        if (mounted) {
          setState(() {
            _isLoading = true;
          });
        }
        await _loadMessages(token, serverSessionId);
      } else if (serverSessionId != null) {
        // Same session. Sync messages.
        await _loadMessages(token, serverSessionId);
      } else if (savedSessionId != null) {
        // Server fetch failed, but we had a savedSessionId. Load messages for it.
        await _loadMessages(token, savedSessionId);
      }

      // If still no valid session (network error on both paths), try server again
      if (_sessionId == null) {
        _log(
          'Recovering current session from server (local ID lost or absent)',
        );
        _sessionId = await _fetchCurrentSession(token);
        if (_sessionId != null) {
          _log('Recovered session from server: $_sessionId');
          await StorageService.saveAiSessionId(userId, _sessionId!);
          // Load the messages for the recovered session
          await _loadMessages(token, _sessionId!);
        } else {
          // No session found on server, create one
          final newId = await _createSession(token);
          if (newId != null) {
            _sessionId = newId;
            await StorageService.saveAiSessionId(userId, newId);
            await _loadMessages(token, newId);
          } else {
            _log('Failed to recover or create session from server');
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });

      // Scroll to bottom after the list has had time to lay out all items.
      if (_messages.isNotEmpty) {
        _jumpToBottomWhenSettled();
      }

      final initialPrompt = widget.initialPrompt?.trim();
      if (initialPrompt != null && initialPrompt.isNotEmpty) {
        _messageController.text = initialPrompt;
        await _sendMessage();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      _showError('Failed to initialize AI chat: $e');
    }
  }

  /// Reload messages for the current session from the server.
  /// Called when a cross-device sync event indicates a session change.
  Future<void> _reloadCurrentSession() async {
    final token = await StorageService.getToken();
    if (token == null || _sessionId == null || !mounted) return;
    final userId = await StorageService.getUserId() ?? 0;
    await StorageService.saveAiSessionId(userId, _sessionId!);
    await _loadMessages(token, _sessionId!);
  }

  Future<_LoadResult> _loadMessages(String token, int sessionId) async {
    _log('Loading messages for session ID: $sessionId');

    // Cache-first: paint anything we already have on disk so the screen
    // never sits on a spinner waiting for the network. The network
    // refresh below will overwrite the list once it returns.
    if (_currentUserId != null) {
      final cached = await ChatCacheService.loadAiSessionMessages(
        _currentUserId!,
        sessionId,
      );
      if (cached.isNotEmpty && mounted) {
        setState(() {
          _messages
            ..clear()
            ..addAll(cached);
          _isLoading = false;
        });
      }
    }

    try {
      final response = await http
          .get(
            _aiUri('/sessions/$sessionId/messages'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      _log(
        'Load messages response status: ${response.statusCode} for session $sessionId',
      );

      if (response.statusCode == 404) {
        _log('Session $sessionId not found (404) - will create new session');
        return _LoadResult.sessionNotFound;
      }

      if (response.statusCode != 200) {
        _log(
          'Failed to load messages for session $sessionId - status: ${response.statusCode}',
        );
        // Cache stays painted on a network error so the user keeps
        // seeing previously fetched messages.
        return _LoadResult.networkError;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final rawMessages =
          (payload['messages'] as List<dynamic>? ?? <dynamic>[]);

      final parsed = rawMessages
          .map((m) => m as Map<String, dynamic>)
          .where(
            (m) =>
                (m['role'] == 'user' || m['role'] == 'assistant') &&
                (m['content']?.toString().trim().isNotEmpty ?? false),
          )
          .map(
            (m) => <String, String>{
              'id': (m['id'] ?? m['message_id'] ?? '').toString(),
              'role': m['role'].toString(),
              'content': m['content'].toString(),
              'timestamp': (m['created_at'] ?? m['timestamp'] ?? '').toString(),
            },
          )
          .toList();

      if (!mounted) return _LoadResult.networkError;
      setState(() {
        _messages
          ..clear()
          ..addAll(parsed);
      });

      _persistAiSnapshot();
      return _LoadResult.success;
    } catch (_) {
      return _LoadResult.networkError;
    }
  }

  Future<int?> _createSession(String token) async {
    _log('Creating new AI session');
    try {
      final response = await http
          .post(
            _aiUri('/sessions'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(<String, dynamic>{'title': 'AI Chat'}),
          )
          .timeout(ApiConfig.connectionTimeout);

      _log('Create session response status: ${response.statusCode}');

      if (response.statusCode != 200 && response.statusCode != 201) {
        _log('Failed to create session - status: ${response.statusCode}');
        return null;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final session = payload['session'] as Map<String, dynamic>?;
      final id = session?['id'] ?? payload['id'];
      final sessionId = id is int ? id : int.tryParse(id?.toString() ?? '');
      _log('Created session with ID: $sessionId');
      return sessionId;
    } catch (e) {
      _log('Error creating session: $e');
      return null;
    }
  }

  /// Fetch the user's most recent AI session from the server, or let the
  /// server create one if none exist. This is used to recover the active
  /// session after an app update wipes local storage.
  Future<int?> _fetchCurrentSession(String token) async {
    _log('Fetching current session from server');
    try {
      final response = await http
          .get(
            _aiUri('/sessions/current'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      _log('Fetch current session response status: ${response.statusCode}');

      if (response.statusCode != 200 && response.statusCode != 201) {
        _log(
          'Failed to fetch current session - status: ${response.statusCode}',
        );
        // Fall back to creating a new session the old way
        return _createSession(token);
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final session = payload['session'] as Map<String, dynamic>?;
      final id = session?['id'] ?? payload['id'];
      final sessionId = id is int ? id : int.tryParse(id?.toString() ?? '');
      final wasCreated = payload['created'] == true;
      _log('Fetched current session: $sessionId (created: $wasCreated)');
      return sessionId;
    } catch (e) {
      _log('Error fetching current session: $e');
      // Fall back to creating a new session the old way
      return _createSession(token);
    }
  }

  String _applyAutoCorrection(String input) {
    if (!_autoCorrectionEnabled) {
      return input;
    }

    final words = input.split(RegExp(r'\s+'));
    return words
        .map((word) {
          final lowered = word.toLowerCase();
          final corrected = _autoCorrectionDictionary[lowered];
          return corrected ?? word;
        })
        .join(' ');
  }

  Future<void> _sendMessage() async {
    final rawContent = _messageController.text.trim();
    await _sendRawMessage(rawContent);
  }

  Future<void> _sendRawMessage(String rawContent) async {
    if (_isSending) return;

    if (rawContent.isEmpty) return;
    final content = _applyAutoCorrection(rawContent);

    final token = await StorageService.getToken();
    if (token == null || token.isEmpty) {
      _showError('You are not authenticated. Please sign in again.');
      return;
    }

    final sessionId = _sessionId;
    if (sessionId == null) {
      _showError('AI session not ready yet. Please try again.');
      return;
    }

    if (_showEmojiPicker) {
      setState(() {
        _showEmojiPicker = false;
      });
    }

    final userLocalId = '-${_nextLocalMessageId++}';

    setState(() {
      _isSending = true;
      _hasStreamingAssistant = false;
      _messages.add(<String, String>{
        'id': userLocalId,
        'role': 'user',
        'content': content,
        'timestamp': DateTime.now().toIso8601String(),
      });
      _messageController.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToBottom();
    });

    // Persist last AI message time + preview so lobby can sort/display correctly
    if (_currentUserId != null) {
      SharedPreferences.getInstance().then((prefs) {
        prefs.setString(
          'ai_last_message_time_$_currentUserId',
          DateTime.now().toUtc().toIso8601String(),
        );
        prefs.setString(
          'ai_last_message_preview_$_currentUserId',
          'You: $content',
        );
      });
    }

    try {
      final reply = await _sendMessageViaStream(
        token: token,
        sessionId: sessionId,
        content: content,
        userLocalId: userLocalId,
      );

      if (reply != null && reply.isNotEmpty && _currentUserId != null) {
        SharedPreferences.getInstance().then((prefs) {
          prefs.setString(
            'ai_last_message_preview_$_currentUserId',
            reply.length > 60 ? '${reply.substring(0, 60)}...' : reply,
          );
          prefs.setString(
            'ai_last_message_time_$_currentUserId',
            DateTime.now().toUtc().toIso8601String(),
          );
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add(<String, String>{
          'id': '-${_nextLocalMessageId++}',
          'role': 'assistant',
          'content':
              'Sorry, I encountered an error while connecting to the AI. Please try again.',
          'timestamp': DateTime.now().toIso8601String(),
        });
      });
      _scrollToBottom();
    } finally {
      if (!mounted) return;
      setState(() {
        _isSending = false;
        _hasStreamingAssistant = false;
      });
      // Send round-trip is done (success or error). Snapshot the
      // updated message list so the AI chat is viewable offline next
      // time even mid-stream errors leave the UI in a coherent state.
      _persistAiSnapshot();
    }
  }

  Future<String?> _sendMessageViaStream({
    required String token,
    required int sessionId,
    required String content,
    required String userLocalId,
  }) async {
    final client = http.Client();
    String? assistantLocalId;
    String assistantContent = '';

    try {
      final request = http.Request(
        'POST',
        _aiUri('/sessions/$sessionId/chat/stream'),
      );
      request.headers.addAll(<String, String>{
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
        'Authorization': 'Bearer $token',
      });
      request.body = jsonEncode(<String, dynamic>{
        'content': content,
        'model': 'llama3.2:3b',
      });

      final response = await client.send(request);
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw Exception('HTTP ${response.statusCode}');
      }

      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (!mounted) {
          break;
        }
        if (!line.startsWith('data:')) {
          continue;
        }

        final data = line.substring(5).trim();
        if (data.isEmpty || data == '[DONE]') {
          continue;
        }

        final payload = jsonDecode(data) as Map<String, dynamic>;
        final type = payload['type']?.toString();

        switch (type) {
          case 'user_message_saved':
            final userMessageId = payload['id'] as int?;
            if (userMessageId != null) {
              _sseConfirmedIds.add(userMessageId);
              _replaceMessageId(userLocalId, userMessageId.toString());
            }
            break;
          case 'token':
            final tokenChunk = payload['content']?.toString() ?? '';
            if (tokenChunk.isEmpty) {
              break;
            }

            if (assistantLocalId == null) {
              assistantLocalId = '-${_nextLocalMessageId++}';
              setState(() {
                _hasStreamingAssistant = true;
                _messages.add(<String, String>{
                  'id': assistantLocalId!,
                  'role': 'assistant',
                  'content': tokenChunk,
                  'timestamp': DateTime.now().toIso8601String(),
                });
              });
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _scrollToBottom();
              });
              assistantContent = tokenChunk;
            } else {
              assistantContent += tokenChunk;
              final idx = _messages.indexWhere(
                (message) => message['id'] == assistantLocalId,
              );
              if (idx != -1) {
                setState(() {
                  _messages[idx] = <String, String>{
                    ..._messages[idx],
                    'content': assistantContent,
                  };
                });
                // Auto-scroll as the response grows, but only if near bottom.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted || !_scrollController.hasClients) return;
                  final distance =
                      _scrollController.position.maxScrollExtent -
                      _scrollController.offset;
                  if (distance < 150) {
                    _scrollToBottom();
                  }
                });
              }
            }
            break;
          case 'done':
            final userMessageId = payload['user_message_id'] as int?;
            final assistantMessageId = payload['assistant_message_id'] as int?;

            if (userMessageId != null) {
              _sseConfirmedIds.add(userMessageId);
              _replaceMessageId(userLocalId, userMessageId.toString());
            }
            if (assistantLocalId != null && assistantMessageId != null) {
              _sseConfirmedIds.add(assistantMessageId);
              _replaceMessageId(
                assistantLocalId!,
                assistantMessageId.toString(),
              );
            }
            break;
          case 'error':
            final err = payload['error']?.toString() ?? 'Unknown stream error';
            throw Exception(err);
          default:
            break;
        }
      }

      return assistantContent.trim().isEmpty ? null : assistantContent.trim();
    } finally {
      client.close();
    }
  }

  Future<void> _sendMessageViaLegacy({
    required String token,
    required int sessionId,
    required String content,
  }) async {
    try {
      final response = await http
          .post(
            _aiUri('/sessions/$sessionId/chat'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(<String, dynamic>{'content': content}),
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode != 200 && response.statusCode != 201) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final reply = payload['response']?.toString().trim();
      if (!mounted || reply == null || reply.isEmpty) {
        return;
      }

      setState(() {
        _messages.add(<String, String>{
          'id': '-${_nextLocalMessageId++}',
          'role': 'assistant',
          'content': reply,
          'timestamp': DateTime.now().toIso8601String(),
        });
      });
      _scrollToBottom();

      if (_currentUserId != null) {
        SharedPreferences.getInstance().then((prefs) {
          prefs.setString(
            'ai_last_message_preview_$_currentUserId',
            reply.length > 60 ? '${reply.substring(0, 60)}...' : reply,
          );
          prefs.setString(
            'ai_last_message_time_$_currentUserId',
            DateTime.now().toUtc().toIso8601String(),
          );
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add(<String, String>{
          'id': '-${_nextLocalMessageId++}',
          'role': 'assistant',
          'content': 'Sorry, I could not respond right now. ($e)',
          'timestamp': DateTime.now().toIso8601String(),
        });
      });
      _scrollToBottom();
    }
  }

  Future<void> _toggleTimestamps() async {
    final next = !_showTimestamps;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showTimestampsKey, next);
    if (!mounted) return;
    setState(() {
      _showTimestamps = next;
    });
  }

  Future<void> _toggleAutoCorrection() async {
    final next = !_autoCorrectionEnabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoCorrectionEnabledKey, next);
    if (!mounted) return;
    setState(() {
      _autoCorrectionEnabled = next;
    });
    _showInfo(
      next
          ? 'Auto-correction enabled for AI input'
          : 'Auto-correction disabled for AI input',
    );
  }

  final FlutterLocalNotificationsPlugin _localNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  bool _localNotificationsReady = false;

  Future<void> _exportChat() async {
    if (_messages.isEmpty) {
      _showInfo('No AI messages to export yet.');
      return;
    }

    try {
      final hasStorageAccess = await _requestStorageAccessForFileOps();
      if (!hasStorageAccess) return;

      // Show loading indicator
      _showInfo('Preparing AI chat export...');

      // Build the export content
      final buffer = StringBuffer();

      buffer.writeln('AI Chat Export');
      buffer.writeln('Exported on: ${DateTime.now().toString()}');
      buffer.writeln('=' * 50);
      buffer.writeln();

      String? lastDate;
      for (final message in _messages) {
        // Add date separator if day changed
        final messageDate = _formatExportDate(message['timestamp'] ?? '');
        if (messageDate != lastDate && messageDate.isNotEmpty) {
          buffer.writeln();
          buffer.writeln('--- $messageDate ---');
          buffer.writeln();
          lastDate = messageDate;
        }

        final role = message['role'] == 'user' ? 'You' : 'AI';
        final time = _formatExportTime(message['timestamp'] ?? '');
        final content = message['content'] ?? '';

        buffer.writeln('[$time] $role: $content');
      }

      buffer.writeln();
      buffer.writeln('=' * 50);
      buffer.writeln('End of export - ${_messages.length} messages');

      // Choose folder first, then filename.
      final defaultFileName =
          'ai_chat_${DateTime.now().day}-${DateTime.now().month}-${DateTime.now().year}.txt';
      final selectedDirectory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select folder for AI chat export',
      );

      if (selectedDirectory == null || selectedDirectory.isEmpty) {
        _showInfo('Export cancelled');
        return;
      }

      final normalizedFileName = _normalizeTextFileName(defaultFileName);
      final savePath =
          '$selectedDirectory${Platform.pathSeparator}$normalizedFileName';

      final exportContent = buffer.toString();
      String savedFileName = normalizedFileName;

      try {
        final exportFile = File(savePath);
        await exportFile.writeAsString(exportContent, flush: true);
      } on FileSystemException catch (e) {
        debugPrint(
          'Direct export write failed, using save dialog fallback: $e',
        );

        final fallbackPath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save AI Chat Export',
          fileName: normalizedFileName,
          type: FileType.custom,
          allowedExtensions: ['txt'],
          bytes: Uint8List.fromList(exportContent.codeUnits),
        );

        if (fallbackPath == null) {
          _showInfo('Export cancelled');
          return;
        }

        final fallbackName = fallbackPath.split(Platform.pathSeparator).last;
        if (fallbackName.isNotEmpty) {
          savedFileName = fallbackName;
        }
      }

      await _showLocalFileOperationNotification(
        title: 'AI Chat Export Saved',
        body: savedFileName,
      );

      if (mounted) {
        _showTopSnackBar(
          SnackBar(
            content: Text('Chat saved to: $savedFileName'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(
              top: 10,
              left: 16,
              right: 16,
              bottom: MediaQuery.of(context).size.height - 150,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error exporting AI chat: $e');
      _showError('Failed to export chat: $e');
    }
  }

  String _normalizeTextFileName(String value) {
    final sanitized = value
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final fallback = sanitized.isEmpty ? 'ai_chat_export' : sanitized;
    return fallback.toLowerCase().endsWith('.txt') ? fallback : '$fallback.txt';
  }

  Future<bool> _requestStorageAccessForFileOps() async {
    final storageStatus = await Permission.storage.request();
    if (storageStatus.isGranted) return true;

    final manageStatus = await Permission.manageExternalStorage.request();
    if (manageStatus.isGranted) return true;

    if (mounted) {
      _showTopSnackBar(
        SnackBar(
          content: const Text('Storage permission required to save files'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(
            top: 10,
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).size.height - 150,
          ),
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

    await _localNotificationsPlugin.initialize(settings);
    _localNotificationsReady = true;
  }

  Future<void> _showLocalFileOperationNotification({
    required String title,
    required String body,
  }) async {
    try {
      await _ensureLocalNotificationsReady();
      const androidDetails = AndroidNotificationDetails(
        'ai_chat_file_ops',
        'AI Chat File Operations',
        channelDescription: 'Notifications for AI chat exports',
        importance: Importance.high,
        priority: Priority.high,
      );
      const iosDetails = DarwinNotificationDetails();
      const details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _localNotificationsPlugin.show(
        DateTime.now().millisecondsSinceEpoch % 100000,
        title,
        body,
        details,
      );
    } catch (e) {
      debugPrint('Error showing local file-operation notification: $e');
    }
  }

  /// Format date for export separator
  String _formatExportDate(String raw) {
    if (raw.isEmpty) return '';
    try {
      final date = DateTime.parse(raw).toLocal();
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
      return '${weekdays[date.weekday - 1]}, ${months[date.month - 1]} ${date.day}, ${date.year}';
    } catch (_) {
      return '';
    }
  }

  /// Format time for export message
  String _formatExportTime(String raw) {
    if (raw.isEmpty) return '';
    try {
      final date = DateTime.parse(raw).toLocal();
      final hour = date.hour.toString().padLeft(2, '0');
      final minute = date.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } catch (_) {
      return '';
    }
  }

  Future<void> _deleteMessages() async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete AI chat messages?'),
          content: const Text(
            'This will clear your AI conversation history for this session.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true) return;

    final token = await StorageService.getToken();
    final sessionId = _sessionId;
    if (token == null || token.isEmpty || sessionId == null) {
      setState(() {
        _messages.clear();
      });
      return;
    }

    try {
      final response = await http
          .delete(
            _aiUri('/sessions/$sessionId/messages'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.connectionTimeout);

      if (response.statusCode == 404) {
        final newSessionId = await _createSession(token);
        final userId = await StorageService.getUserId() ?? 0;
        if (newSessionId != null) {
          await StorageService.saveAiSessionId(userId, newSessionId);
        }
        if (!mounted) return;
        setState(() {
          _sessionId = newSessionId;
          _messages.clear();
        });
        _showInfo('Session expired. Started a new AI chat session.');
        return;
      }

      if (response.statusCode != 200 && response.statusCode != 204) {
        throw Exception('HTTP ${response.statusCode}');
      }

      if (!mounted) return;
      setState(() {
        _messages.clear();
      });
      _showInfo('AI chat cleared.');
    } catch (e) {
      _showError('Failed to clear AI chat: $e');
    }
  }

  void _insertEmoji(String emoji) {
    final current = _messageController.text;
    final selection = _messageController.selection;
    final start = selection.start < 0 ? current.length : selection.start;
    final end = selection.end < 0 ? current.length : selection.end;
    final updated = current.replaceRange(start, end, emoji);

    _messageController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
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

  void _log(String message) {
    debugPrint('[AiChatScreen] $message');
  }

  void _showError(String message) {
    if (!mounted) return;
    _showTopSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(
          top: 10,
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).size.height - 150,
        ),
      ),
    );
  }

  void _showInfo(String message) {
    if (!mounted) return;
    _showTopSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF252542),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(
          top: 10,
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).size.height - 150,
        ),
      ),
    );
  }

  void _dismissTopActionBanner() {
    _topActionBannerTimer?.cancel();
    _topActionBannerTimer = null;
    _topActionBannerEntry?.remove();
    _topActionBannerEntry = null;
  }

  void _showTopActionBanner({
    required String message,
    required IconData icon,
    Color startColor = const Color(0xFF2563EB),
    Color endColor = const Color(0xFF1D4ED8),
    Duration duration = const Duration(milliseconds: 1900),
  }) {
    if (!mounted) return;

    _dismissTopActionBanner();

    final overlay = Overlay.of(context, rootOverlay: true);

    final entry = OverlayEntry(
      builder: (overlayContext) {
        final topInset = MediaQuery.of(overlayContext).padding.top;

        return Positioned(
          top: topInset + 10,
          left: 14,
          right: 14,
          child: IgnorePointer(
            child: Material(
              color: Colors.transparent,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: 1),
                duration: Duration.zero,
                curve: Curves.easeOutCubic,
                builder: (context, value, child) {
                  return Opacity(
                    opacity: value,
                    child: Transform.translate(
                      offset: Offset(0, -18 * (1 - value)),
                      child: child,
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [startColor, endColor],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.25),
                      width: 0.8,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: endColor.withValues(alpha: 0.35),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: Colors.white, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
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

    overlay.insert(entry);
    _topActionBannerEntry = entry;
    _topActionBannerTimer = Timer(duration, _dismissTopActionBanner);
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    final maxExtent = _scrollController.position.maxScrollExtent;
    _scrollController.jumpTo(maxExtent);
    if (mounted) {
      setState(() {
        _isAtBottom = true;
      });
    }
  }

  /// Polls across frames until [maxScrollExtent] stabilises, then jumps.
  /// This is essential because [ListView.builder] lazily lays out items, so
  /// the extent grows as more off-screen children get built when we scroll down.
  void _jumpToBottomWhenSettled([double? previousExtent, int attempts = 12]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) {
        if (attempts > 1) {
          _jumpToBottomWhenSettled(previousExtent, attempts - 1);
        }
        return;
      }

      // Jump to current max first — this forces the ListView to build the
      // children that are now in the viewport, which may increase maxExtent.
      final maxExtent = _scrollController.position.maxScrollExtent;
      _scrollController.jumpTo(maxExtent);

      // If the extent didn't change since last frame, layout is stable.
      if (previousExtent != null && (maxExtent - previousExtent).abs() < 1.0) {
        if (mounted) {
          setState(() {
            _isAtBottom = true;
            _isInitialLoadComplete = true;
          });
        }
        return;
      }

      if (attempts > 1) {
        _jumpToBottomWhenSettled(maxExtent, attempts - 1);
      } else {
        // Final attempt — force jump to whatever the extent is now.
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        if (mounted) {
          setState(() {
            _isAtBottom = true;
            _isInitialLoadComplete = true;
          });
        }
      }
    });
  }

  void _scrollToBottomButtonTap() {
    if (!_scrollController.hasClients) return;
    // Immediate jump for instant visual feedback.
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    setState(() => _isAtBottom = true);
    // Then settle via timer to handle lazy-built items that grow maxExtent.
    _settleScrollToBottom();
  }

  /// Timer-based rapid settle loop for the scroll-to-bottom button.
  /// Unlike [_jumpToBottomWhenSettled] (post-frame based, for initial load),
  /// this uses [Future.delayed] so it fires reliably regardless of frame
  /// scheduling and finishes in ~50-100ms.
  void _settleScrollToBottom([double? prev, int attempts = 8]) {
    _isSettlingScroll = true;
    Future.delayed(const Duration(milliseconds: 16), () {
      if (!mounted || !_scrollController.hasClients) {
        _isSettlingScroll = false;
        return;
      }
      final max = _scrollController.position.maxScrollExtent;
      _scrollController.jumpTo(max);

      if (prev != null && (max - prev).abs() < 1.0 || attempts <= 1) {
        // Settled — layout is stable.
        _isSettlingScroll = false;
        if (mounted) {
          setState(() => _isAtBottom = true);
        }
        return;
      }
      _settleScrollToBottom(max, attempts - 1);
    });
  }

  String _formatTimestamp(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    try {
      final dt = DateTime.parse(raw).toLocal();
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '$h:$m';
    } catch (_) {
      return '';
    }
  }

  String _formatTimestampFull(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    try {
      final dt = DateTime.parse(raw).toLocal();
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} $h:$m';
    } catch (_) {
      return raw;
    }
  }

  int _messageId(Map<String, String> message) {
    final fromPayload = int.tryParse(message['id'] ?? '');
    if (fromPayload != null) return fromPayload;
    return (message['timestamp'] ?? message['content'] ?? '').hashCode;
  }

  String _ensureColorEmoji(String emoji) {
    const variationSelector = '\uFE0F';
    const needsSelector = <int>{
      0x2764,
      0x2602,
      0x2614,
      0x263A,
      0x2B50,
      0x2600,
      0x2601,
      0x260E,
      0x2709,
      0x270F,
      0x2744,
      0x2728,
      0x2702,
      0x26A1,
      0x2615,
    };
    if (emoji.isNotEmpty &&
        needsSelector.contains(emoji.runes.first) &&
        !emoji.contains(variationSelector)) {
      return emoji + variationSelector;
    }
    return emoji;
  }

  Widget _buildReactionPills(int messageId) {
    final reactions = _messageReactions[messageId];
    if (reactions == null || reactions.isEmpty) {
      return const SizedBox.shrink();
    }

    final currentUserStr = _currentUserId?.toString() ?? '';
    final pills = <Widget>[];

    reactions.forEach((emoji, users) {
      if (users.isEmpty) return;
      final iReacted = users.contains(currentUserStr);
      pills.add(
        Container(
          margin: const EdgeInsets.only(right: 2),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: iReacted ? const Color(0xFF3A3A5C) : const Color(0xFF2C2C2E),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: iReacted
                  ? const Color(0xFF6D28D9).withOpacity(0.5)
                  : Colors.white.withOpacity(0.15),
              width: iReacted ? 1.0 : 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _ensureColorEmoji(emoji),
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(width: 2),
              Text(
                '${users.length}',
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    });

    if (pills.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 2, runSpacing: 2, children: pills);
  }

  void _toggleReaction(int messageId, String emoji) {
    final currentUserStr = _currentUserId?.toString() ?? 'me';
    setState(() {
      _messageReactions.putIfAbsent(messageId, () => <String, Set<String>>{});
      _messageReactions[messageId]!.putIfAbsent(emoji, () => <String>{});
      final users = _messageReactions[messageId]![emoji]!;

      if (users.contains(currentUserStr)) {
        users.remove(currentUserStr);
        if (users.isEmpty) {
          _messageReactions[messageId]!.remove(emoji);
        }
      } else {
        users.add(currentUserStr);
      }

      if (_messageReactions[messageId]!.isEmpty) {
        _messageReactions.remove(messageId);
      }
    });
  }

  void _showReactionPicker(
    BuildContext context,
    int messageId,
    Offset position,
  ) {
    ReactionPicker.show(
      context: context,
      position: position,
      onReactionSelected: (emoji) => _toggleReaction(messageId, emoji),
    );
  }

  Future<void> _showMessageContextMenu(
    Map<String, String> message,
    bool isUser,
  ) async {
    var actionInvoked = false;

    void closeWithAction(BuildContext sheetContext, VoidCallback action) {
      actionInvoked = true;
      Navigator.pop(sheetContext);
      action();
    }

    await showModalBottomSheet(
      context: context,
      requestFocus: false,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E2E),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFF7C3AED).withOpacity(0.28),
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF420796).withOpacity(0.28),
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
                children: const [
                  Icon(Icons.tune_rounded, color: Color(0xFFB794F6), size: 18),
                  SizedBox(width: 8),
                  Text(
                    'Message Actions',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (message['content']?.isNotEmpty ?? false)
                ValueListenableBuilder<String?>(
                  valueListenable: TtsService().readingMessageId,
                  builder: (context, readingId, child) {
                    final isReadingThis = readingId == message['id'];
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
                            message['id'] ?? '',
                            message['content'] ?? '',
                          );
                        }
                      },
                    );
                  },
                ),
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
              if (isUser)
                _buildContextMenuActionTile(
                  icon: Icons.edit_rounded,
                  label: 'Edit',
                  onTap: () {
                    closeWithAction(
                      sheetContext,
                      () => _showEditMessageDialog(message),
                    );
                  },
                ),
              if (isUser)
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
      FocusScope.of(context).unfocus();
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
                  Text(
                    label,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  int _findMessageIndex(Map<String, String> targetMessage) {
    final indexByIdentity = _messages.indexWhere(
      (message) => identical(message, targetMessage),
    );
    if (indexByIdentity != -1) {
      return indexByIdentity;
    }

    final targetId = targetMessage['id'];
    if (targetId != null && targetId.isNotEmpty) {
      final indexById = _messages.indexWhere(
        (message) => message['id'] == targetId,
      );
      if (indexById != -1) {
        return indexById;
      }
    }

    return -1;
  }

  int? _backendMessageId(Map<String, String> message) {
    final id = int.tryParse(message['id'] ?? '');
    if (id == null || id <= 0) {
      return null;
    }
    return id;
  }

  void _replaceMessageId(String oldId, String newId) {
    if (!mounted) return;
    final idx = _messages.indexWhere((message) => message['id'] == oldId);
    if (idx == -1) return;

    setState(() {
      _messages[idx] = <String, String>{..._messages[idx], 'id': newId};
    });
  }

  void _copyMessageToClipboard(Map<String, String> message) {
    final content = (message['content'] ?? '').trim();
    if (content.isEmpty) {
      _showInfo('Nothing to copy.');
      return;
    }

    Clipboard.setData(ClipboardData(text: content));
    _showTopActionBanner(
      message: 'Copied to clipboard',
      icon: Icons.copy_rounded,
      startColor: const Color(0xFF0891B2),
      endColor: const Color(0xFF0E7490),
    );
  }

  void _showEditMessageDialog(Map<String, String> message) {
    final editController = TextEditingController(
      text: message['content'] ?? '',
    );

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        title: const Text(
          'Edit Message',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: editController,
          style: const TextStyle(color: Colors.white),
          maxLines: 5,
          minLines: 1,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Edit your message...',
            hintStyle: TextStyle(color: Colors.grey[500]),
            filled: true,
            fillColor: const Color(0xFF252542),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              final newContent = editController.text.trim();
              final oldContent = (message['content'] ?? '').trim();

              Navigator.pop(dialogContext);

              if (newContent.isNotEmpty && newContent != oldContent) {
                await _editMessage(message, newContent);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF420796),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    ).then((_) {
      editController.dispose();
    });
  }

  Future<void> _editMessage(
    Map<String, String> message,
    String newContent,
  ) async {
    final index = _findMessageIndex(message);
    if (index == -1) {
      return;
    }

    final sessionId = _sessionId;
    final token = await StorageService.getToken();
    final messageId = _backendMessageId(_messages[index]);

    if (sessionId == null || token == null || token.isEmpty) {
      _showError('Session is not ready. Please try again.');
      return;
    }

    if (messageId == null) {
      _showError('Message is still syncing. Try again in a moment.');
      return;
    }

    final response = await http
        .patch(
          _aiUri('/sessions/$sessionId/messages/$messageId'),
          headers: <String, String>{
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(<String, dynamic>{'content': newContent}),
        )
        .timeout(ApiConfig.connectionTimeout);

    if (response.statusCode == 404) {
      if (!mounted) return;
      setState(() {
        _messages.removeAt(index);
      });
      _persistAiSnapshot();
      _showInfo('Message no longer exists and was removed.');
      return;
    }

    if (response.statusCode == 400) {
      _showError('Message content is required.');
      return;
    }

    if (response.statusCode != 200) {
      _showError('Failed to edit message (HTTP ${response.statusCode}).');
      return;
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final updatedContent = (payload['content'] ?? newContent).toString();

    setState(() {
      _messages[index] = <String, String>{
        ..._messages[index],
        'content': updatedContent,
      };
    });
    _persistAiSnapshot();

    _showTopActionBanner(
      message: 'Message edited',
      icon: Icons.edit_rounded,
      startColor: const Color(0xFF7C3AED),
      endColor: const Color(0xFF5B21B6),
    );
  }

  void _showDeleteConfirmation(Map<String, String> message) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
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
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await _deleteMessage(message);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteMessage(Map<String, String> message) async {
    final index = _findMessageIndex(message);
    if (index == -1) {
      return;
    }

    final sessionId = _sessionId;
    final token = await StorageService.getToken();
    final messageId = _backendMessageId(_messages[index]);

    if (sessionId == null || token == null || token.isEmpty) {
      _showError('Session is not ready. Please try again.');
      return;
    }

    if (messageId == null) {
      _showError('Message is still syncing. Try again in a moment.');
      return;
    }

    final response = await http
        .delete(
          _aiUri('/sessions/$sessionId/messages/$messageId'),
          headers: <String, String>{
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(ApiConfig.connectionTimeout);

    if (response.statusCode != 200 &&
        response.statusCode != 204 &&
        response.statusCode != 404) {
      _showError('Failed to delete message (HTTP ${response.statusCode}).');
      return;
    }

    setState(() {
      _messages.removeAt(index);
    });
    _persistAiSnapshot();

    _showTopActionBanner(
      message: 'Message deleted',
      icon: Icons.delete_outline,
      startColor: const Color(0xFFDC2626),
      endColor: const Color(0xFF991B1B),
    );
  }

  // ── Lightweight inline-markdown → RichText ──────────────────────────────

  Widget _buildFormattedContent(String text, {bool isUser = false}) {
    final spans = _parseMarkdownSpans(text);
    return RichText(
      text: TextSpan(
        style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.35),
        children: spans,
      ),
    );
  }

  /// Parses basic markdown patterns into [InlineSpan] children.
  /// Supported: **bold**, *italic*, `code`, ~~strikethrough~~, __underline__.
  List<InlineSpan> _parseMarkdownSpans(String text) {
    // Regex captures these groups in order:
    //  1) `code`
    //  2) **bold**
    //  3) ~~strikethrough~~
    //  4) __underline__
    //  5) *italic* (single asterisk, but not inside **)
    final pattern = RegExp(
      r'`([^`]+)`' // group 1: inline code
      r'|\*\*(.+?)\*\*' // group 2: bold
      r'|~~(.+?)~~' // group 3: strikethrough
      r'|__(.+?)__' // group 4: underline
      r'|\*(.+?)\*', // group 5: italic
    );

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in pattern.allMatches(text)) {
      // Add plain text before this match.
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }

      if (match.group(1) != null) {
        // Inline code
        spans.add(
          TextSpan(
            text: match.group(1),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              backgroundColor: Colors.white.withValues(alpha: 0.12),
              color: const Color(0xFF7DD3FC),
            ),
          ),
        );
      } else if (match.group(2) != null) {
        // Bold
        spans.add(
          TextSpan(
            text: match.group(2),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        );
      } else if (match.group(3) != null) {
        // Strikethrough
        spans.add(
          TextSpan(
            text: match.group(3),
            style: const TextStyle(decoration: TextDecoration.lineThrough),
          ),
        );
      } else if (match.group(4) != null) {
        // Underline
        spans.add(
          TextSpan(
            text: match.group(4),
            style: const TextStyle(decoration: TextDecoration.underline),
          ),
        );
      } else if (match.group(5) != null) {
        // Italic
        spans.add(
          TextSpan(
            text: match.group(5),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      }

      lastEnd = match.end;
    }

    // Remaining plain text after the last match.
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    // If nothing matched, return the raw text.
    if (spans.isEmpty) {
      spans.add(TextSpan(text: text));
    }

    return spans;
  }

  Widget _buildMessageBubble(Map<String, String> message) {
    final isUser = message['role'] == 'user';
    final timestamp = _formatTimestamp(message['timestamp']);
    final fullTimestamp = _formatTimestampFull(message['timestamp']);
    final messageId = _messageId(message);
    final hasReactions =
        _messageReactions[messageId] != null &&
        _messageReactions[messageId]!.isNotEmpty;

    return _AiMessageBubble(
      message: message,
      showTimestamps: _showTimestamps,
      buildBubbleContent: (LinkPreview? linkPreview) => Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Builder(
              builder: (rowContext) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    GestureDetector(
                      onLongPress: () =>
                          _showMessageContextMenu(message, isUser),
                      child: Container(
                        margin: EdgeInsets.only(bottom: hasReactions ? 2 : 12),
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.70,
                        ),
                        decoration: BoxDecoration(
                          color: isUser
                              ? const Color(0xFF420796)
                              : const Color(0xFF3944BC),
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(16),
                            topRight: const Radius.circular(16),
                            bottomLeft: Radius.circular(isUser ? 16 : 4),
                            bottomRight: Radius.circular(isUser ? 4 : 16),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              child: _buildFormattedContent(
                                message['content'] ?? '',
                                isUser: isUser,
                              ),
                            ),
                            // Link preview — inside the bubble
                            if (linkPreview != null)
                              _buildInlineLinkPreview(linkPreview, isUser),
                            if (isUser)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 6,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Text(
                                      timestamp,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 11,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    const Icon(
                                      Icons.done_all,
                                      size: 16,
                                      color: Color(0xFF00BCD4),
                                    ),
                                  ],
                                ),
                              ),
                            if (_showTimestamps)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 6,
                                ),
                                child: Text(
                                  fullTimestamp,
                                  style: const TextStyle(
                                    color: Color(0xFFFF69B4),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (!isUser)
                      GestureDetector(
                        onTapDown: (details) {
                          _showReactionPicker(
                            context,
                            messageId,
                            details.globalPosition,
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(
                            Icons.sentiment_satisfied_alt_outlined,
                            color: Colors.white.withValues(alpha: 0.6),
                            size: 22,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            if (hasReactions)
              Padding(
                padding: EdgeInsets.only(
                  left: isUser ? 0 : 8,
                  right: isUser ? 8 : 0,
                  bottom: 6,
                ),
                child: _buildReactionPills(messageId),
              ),
          ],
        ),
      ),
    );
  }

  /// Renders link preview content inline inside the AI bubble container.
  Widget _buildInlineLinkPreview(LinkPreview preview, bool isUser) {
    if (preview.isYouTube) {
      final uri = Uri.tryParse(preview.imageUrl ?? '');
      final segments = uri?.pathSegments ?? [];
      final videoId = (segments.length >= 2 && segments[0] == 'vi')
          ? segments[1]
          : '';
      if (videoId.isEmpty) return const SizedBox.shrink();

      final watchUrl = 'https://www.youtube.com/watch?v=$videoId';
      final thumbUrl = 'https://img.youtube.com/vi/$videoId/hqdefault.jpg';
      final fallbackUrl = 'https://img.youtube.com/vi/$videoId/mqdefault.jpg';

      return GestureDetector(
        onTap: () async {
          try {
            final u = Uri.parse(watchUrl);
            // ignore: deprecated_member_use
            if (await canLaunchUrl(u))
              await launchUrl(u, mode: LaunchMode.externalApplication);
          } catch (_) {}
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.network(
                    thumbUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Image.network(
                      fallbackUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          Container(color: Colors.grey[850]),
                    ),
                  ),
                  Center(
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow,
                        color: Colors.white,
                        size: 30,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.play_circle_fill,
                        color: Color(0xFFFF0000),
                        size: 12,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'YouTube',
                        style: TextStyle(
                          color: Color(0xFFFF0000),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  if (preview.title != null && preview.title!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      preview.title!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    // General OG preview
    final domain = (Uri.tryParse(preview.url)?.host ?? preview.url)
        .replaceFirst('www.', '')
        .toUpperCase();
    return GestureDetector(
      onTap: () async {
        try {
          final u = Uri.parse(preview.url);
          // ignore: deprecated_member_use
          if (await canLaunchUrl(u))
            await launchUrl(u, mode: LaunchMode.externalApplication);
        } catch (_) {}
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (preview.imageUrl != null)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(
                preview.imageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (preview.faviconUrl != null) ...[
                      Image.network(
                        preview.faviconUrl!,
                        width: 12,
                        height: 12,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        domain,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFa78bfa),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (preview.title != null && preview.title!.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    preview.title!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
                if (preview.description != null &&
                    preview.description!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    preview.description!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThinkingBubble() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF252542),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _ThinkingDots(),
            SizedBox(width: 8),
            Text(
              'AI is thinking...',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposerIconButton({
    required VoidCallback onPressed,
    required IconData icon,
    required double iconSize,
    required EdgeInsetsGeometry padding,
    required String tooltip,
    Color color = Colors.white70,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkResponse(
          onTap: onPressed,
          containedInkWell: true,
          highlightShape: BoxShape.circle,
          radius: iconSize * 0.9,
          splashColor: Colors.white.withValues(alpha: 0.22),
          highlightColor: Colors.white.withValues(alpha: 0.14),
          child: Padding(
            padding: padding,
            child: Icon(icon, color: color, size: iconSize),
          ),
        ),
      ),
    );
  }

  Widget _buildCompressedActionChip({
    required String label,
    required Color backgroundColor,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          alignment: Alignment.center,
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.05,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTwoRowActions(List<Widget> allButtons) {
    final splitIndex = (allButtons.length / 2).ceil();
    final topRow = allButtons.take(splitIndex).toList();
    final bottomRow = allButtons.skip(splitIndex).toList();

    Widget buildFittedRow(List<Widget> rowButtons) {
      if (rowButtons.isEmpty) return const SizedBox.shrink();

      return LayoutBuilder(
        builder: (context, constraints) {
          const gap = 4.0;
          final totalGap = gap * (rowButtons.length - 1);
          final itemWidth = math.max(
            58.0,
            (constraints.maxWidth - totalGap) / rowButtons.length,
          );

          return Wrap(
            spacing: gap,
            runSpacing: 0,
            children: rowButtons
                .map((button) => SizedBox(width: itemWidth, child: button))
                .toList(),
          );
        },
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildFittedRow(topRow),
        if (bottomRow.isNotEmpty) const SizedBox(height: 4),
        if (bottomRow.isNotEmpty) buildFittedRow(bottomRow),
      ],
    );
  }

  Widget _buildUnifiedActionsBar() {
    final allButtons = <Widget>[
      _buildCompressedActionChip(
        label: 'Auto Correction',
        backgroundColor: const Color(0xFFF59E0B),
        onPressed: _toggleAutoCorrection,
      ),
      _buildCompressedActionChip(
        label: 'Export Chat',
        backgroundColor: const Color(0xFF475569),
        onPressed: _exportChat,
      ),
      _buildCompressedActionChip(
        label: _showTimestamps ? 'Hide\nTimestamps' : 'Show\nTimestamps',
        backgroundColor: _showTimestamps
            ? const Color(0xFF4338CA)
            : const Color(0xFF6366F1),
        onPressed: _toggleTimestamps,
      ),
      _buildCompressedActionChip(
        label: 'Delete Messages',
        backgroundColor: const Color(0xFFDC2626),
        onPressed: _deleteMessages,
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

  Widget _buildEmojiPanel() {
    final category = _emojiCategories[_emojiCategoryIndex];
    final emojis = _normalizedEmojiList(category['emojis'] as List<String>);

    return Container(
      height: 230,
      decoration: BoxDecoration(
        color: const Color(0xFF3D3D3D),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
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
                  onTap: () => _insertEmoji(emojis[index]),
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

  Widget _buildComposer() {
    const sendButtonColor = Color(0xFF6D28D9);

    return ChatComposerShell(
      composerInset: 0,
      backgroundColor: const Color(0xFF1A1A2E),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (!_showEmojiPicker) _buildUnifiedActionsBar(),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _messageController,
            builder: (context, value, _) {
              final textStyle = const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontFamily: 'Roboto',
                height: 1.12,
              );

              return LayoutBuilder(
                builder: (context, constraints) {
                  const iconSlotWidth = 40.0;
                  const sendButtonReserve = 88.0;
                  final estimatedTextMaxWidth = math.max(
                    120.0,
                    constraints.maxWidth -
                        sendButtonReserve -
                        iconSlotWidth -
                        28.0,
                  );

                  final isComposerExpanded = _isComposerMultiline(
                    value.text,
                    textStyle,
                    estimatedTextMaxWidth,
                  );

                  return Row(
                    crossAxisAlignment: isComposerExpanded
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.center,
                    children: <Widget>[
                      Expanded(
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 44),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4D4D4D),
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Row(
                            crossAxisAlignment: isComposerExpanded
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.center,
                            children: [
                              Padding(
                                padding: EdgeInsets.only(
                                  bottom: isComposerExpanded ? 10 : 0,
                                ),
                                child: _buildComposerIconButton(
                                  onPressed: () {
                                    setState(() {
                                      _showEmojiPicker = !_showEmojiPicker;
                                    });
                                    if (_showEmojiPicker) {
                                      _inputFocusNode.unfocus();
                                    } else {
                                      _inputFocusNode.requestFocus();
                                    }
                                  },
                                  icon: _showEmojiPicker
                                      ? Icons.keyboard_outlined
                                      : Icons.sentiment_satisfied_alt_outlined,
                                  iconSize: 24,
                                  padding: const EdgeInsets.all(6),
                                  tooltip: _showEmojiPicker
                                      ? 'Keyboard'
                                      : 'Emoji',
                                ),
                              ),
                              Expanded(
                                child: TextField(
                                  controller: _messageController,
                                  focusNode: _inputFocusNode,
                                  enabled: !_isLoading && !_isSending,
                                  style: textStyle,
                                  minLines: 1,
                                  maxLines: 6,
                                  textInputAction: TextInputAction.newline,
                                  keyboardType: TextInputType.multiline,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  autocorrect: true,
                                  enableSuggestions: true,
                                  decoration: InputDecoration(
                                    hintText: 'Type a message...',
                                    hintStyle: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 17,
                                      fontFamily: 'Roboto',
                                      height: 1.12,
                                    ),
                                    border: InputBorder.none,
                                    filled: false,
                                    contentPadding: const EdgeInsets.only(
                                      left: 0,
                                      right: 4,
                                      top: 10,
                                      bottom: 10,
                                    ),
                                    isDense: true,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Container(
                        margin: EdgeInsets.only(
                          left: 6,
                          bottom: isComposerExpanded ? 10 : 0,
                        ),
                        child: ElevatedButton(
                          onPressed: (_isLoading || _isSending)
                              ? null
                              : _sendMessage,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: sendButtonColor,
                            foregroundColor: Colors.white,
                            overlayColor: Colors.white.withValues(alpha: 0.22),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            minimumSize: const Size(0, 0),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          child: _isSending
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  'Send',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
          if (_showEmojiPicker) _buildEmojiPanel(),
        ],
      ),
    );
  }

  bool _isComposerMultiline(String text, TextStyle style, double maxWidth) {
    if (text.isEmpty) return false;

    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 6,
    )..layout(maxWidth: maxWidth);

    return painter.computeLineMetrics().length > 1;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A2E),
        elevation: 0,
        title: Row(
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00C9A7), Color(0xFF845EC2)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(
                Icons.smart_toy_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'AI Chat',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  'Always on',
                  style: TextStyle(fontSize: 11, color: Color(0xFF00E676)),
                ),
              ],
            ),
          ],
        ),
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF00D9FF)),
                  )
                : _messages.isEmpty
                ? Center(
                    child: Text(
                      'Start a conversation with AI',
                      style: TextStyle(color: Colors.grey[400]),
                    ),
                  )
                : Stack(
                    children: [
                      ListView.builder(
                        controller: _scrollController,
                        itemCount:
                            _messages.length +
                            ((_isSending && !_hasStreamingAssistant) ? 1 : 0),
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        physics: const ChatScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        ),
                        cacheExtent: 1200,
                        addAutomaticKeepAlives: false,
                        addRepaintBoundaries: true,
                        itemBuilder: (context, index) {
                          if (_isSending && index == _messages.length) {
                            return _buildThinkingBubble();
                          }
                          return _buildMessageBubble(_messages[index]);
                        },
                      ),
                      if (!_isAtBottom)
                        Positioned(
                          bottom: 16,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: GestureDetector(
                              onTap: _scrollToBottomButtonTap,
                              child: Container(
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
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          AnimatedPadding(
            duration: Duration.zero,
            curve: Curves.easeOut,
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: _buildComposer(),
          ),
        ],
      ),
    );
  }
}

class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;

        double opacityFor(int index) {
          final shifted = (t - (index * 0.18)) % 1.0;
          final pulse = 1.0 - ((shifted - 0.5).abs() * 2);
          return 0.25 + (pulse.clamp(0.0, 1.0) * 0.75);
        }

        Widget dot(int index) {
          return Opacity(
            opacity: opacityFor(index),
            child: Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Color(0xFF00D9FF),
                shape: BoxShape.circle,
              ),
            ),
          );
        }

        return Row(
          children: <Widget>[
            dot(0),
            const SizedBox(width: 4),
            dot(1),
            const SizedBox(width: 4),
            dot(2),
          ],
        );
      },
    );
  }
}

/// Wraps an AI chat bubble with async link preview fetching.
class _AiMessageBubble extends StatefulWidget {
  final Map<String, String> message;
  final bool showTimestamps;
  final Widget Function(LinkPreview? linkPreview) buildBubbleContent;

  const _AiMessageBubble({
    required this.message,
    required this.showTimestamps,
    required this.buildBubbleContent,
  });

  @override
  State<_AiMessageBubble> createState() => _AiMessageBubbleState();
}

class _AiMessageBubbleState extends State<_AiMessageBubble> {
  LinkPreview? _linkPreview;
  bool _previewLoaded = false;

  @override
  void initState() {
    super.initState();
    _fetchPreview();
  }

  Future<void> _fetchPreview() async {
    final content = widget.message['content'] ?? '';
    final preview = await LinkPreviewService().getPreview(content);
    if (mounted) {
      setState(() {
        _linkPreview = preview;
        _previewLoaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Pass the preview (or null while loading) into the bubble builder so it
    // renders inside the bubble container rather than as a separate card.
    return widget.buildBubbleContent(_previewLoaded ? _linkPreview : null);
  }
}
