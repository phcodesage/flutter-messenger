import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/lobby_user.dart';
import '../models/group.dart';
import '../models/message.dart';
import '../services/background_update_service.dart';
import '../services/lobby_service.dart';
import '../services/group_service.dart';
import '../services/auth_service.dart';
import '../services/socket_service.dart';
import '../services/firebase_messaging_service.dart';
import '../widgets/app_version_text.dart';
import '../widgets/cached_image.dart';
import '../widgets/settings_modal.dart';
import '../services/call_service.dart';
import '../widgets/incoming_call_setup_modal.dart';
import 'chat_screen.dart' show ChatScreen;
import 'connected_call_screen.dart';
import 'group_chat_screen.dart';
import 'create_group_screen.dart';
import 'sign_in_page.dart';
import '../services/storage_service.dart';
import '../config/api_config.dart';
import '../services/presence_service.dart';
import '../services/active_chat_service.dart';
import '../services/pending_incoming_call_service.dart';
import '../services/chat_cache_service.dart';
import '../services/share_intent_service.dart';
import '../services/shortcut_service.dart';
import '../services/version_service.dart';
import '../utils/notification_handler.dart';
import '../utils/chat_scroll_physics.dart';
import 'share_target_screen.dart';
import 'ai_chat_screen.dart';
import 'pomodoro/pomodoro_view.dart';
import '../services/pomodoro_service.dart';

/// Lobby/Chat list screen
class LobbyScreen extends StatefulWidget {
  static const route = '/lobby';
  const LobbyScreen({super.key});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

enum LobbyQuickFilter { all, online, groups, alarmX }

/// Minimum window width at which the lobby switches to the desktop two-pane
/// layout (conversation list on the left, open chat on the right).
const double _kDesktopTwoPaneBreakpoint = 900;

/// Fixed width of the conversation-list sidebar in the desktop two-pane layout.
const double _kDesktopSidebarWidth = 380;

class _LobbyScreenState extends State<LobbyScreen> with WidgetsBindingObserver {
  List<LobbyUser> _lobbyUsers = [];
  List<LobbyUser> _filteredUsers = [];
  List<Group> _groups = []; // Group chats
  List<Group> _filteredGroups = []; // Filtered group chats
  bool _isLoading = false;
  bool _isCurrentUserAdmin = false;
  LobbyQuickFilter _activeFilter = LobbyQuickFilter.all;
  final TextEditingController _searchController = TextEditingController();
  final SocketService _socketService = SocketService();
  Timer? _lastSeenRefreshTimer;
  Timer? _searchDebounceTimer;
  // Throttles automatic lobby re-syncs (app resume / socket reconnect) so a
  // resume that also triggers a reconnect doesn't fire two back-to-back fetches.
  DateTime? _lastAutoResyncAt;
  StreamSubscription<List<SharedMediaItem>>? _shareIntentSubscription;
  StreamSubscription<int>? _shortcutLaunchSubscription;
  StreamSubscription<RemoteMessage>? _fcmForegroundSubscription;
  Timer? _pendingNotificationRetryTimer;
  Future<int?> _currentUserId = StorageService.getUserId();
  bool _isSharePickerOpen = false;
  String? _aiLastMessageTime;
  String? _aiLastMessagePreview;
  Map<String, dynamic>? _deferredUpdatePayload;
  final Map<String, DateTime> _recentRealtimeEventKeys = {};
  // _isHandlingIncomingCall is now global via PresenceService().isHandlingIncomingCall
  Route<dynamic>? _activeIncomingCallRoute;
  int? _activeIncomingCallId;

  /// The user ID of the chat currently open on top of the lobby.
  /// Used to suppress unread badge increments while viewing that conversation.
  int? _currentlyViewingChatUserId;

  /// Whether the current window is wide enough for the desktop two-pane layout.
  /// Updated from `build` and read by tap handlers to decide between selecting
  /// the chat in the detail pane vs. pushing a full-screen route.
  bool _isTwoPaneLayout = false;

  /// The conversation shown in the detail pane in two-pane mode (null = none).
  LobbyUser? _selectedChatUser;
  String? _activeIncomingCallRoomId;
  final Map<int, String> _crossDeviceActiveCallRoomByUserId = {};

  // Typing indicator: maps userId → auto-clear timer
  final Map<int, Timer> _typingUsers = {};

  // Avatar colors palette — matches the web app (generate_avatar_url) exactly
  // so the same user shows the same avatar background color on both platforms.
  static const List<Color> avatarColors = [
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

  bool get _showAiSuggestion => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Rebuild the conversation list when a cross-room incoming call is deferred
    // or cleared, so the ringing indicator on the caller's tile appears/clears.
    PendingIncomingCallService().pending.addListener(
      _onPendingIncomingCallChanged,
    );
    _loadLobby();
    _loadAiSessionPresence();
    _loadAdminStatus();
    _searchController.addListener(_onSearchQueryChanged);
    _setupRealtimeListeners();
    _setupFcmForegroundListener();
    _setupShareIntentListener();
    _setupShortcutLaunchListener();
    unawaited(_loadDeferredUpdateEntry());
    VersionService.deferredUpdateSignal.addListener(
      _handleDeferredUpdateSignal,
    );
    // Listen for background download state changes (downloading / ready)
    BackgroundUpdateService().state.addListener(_handleBgUpdateStateChange);
    // Listen for in-app "Update available" prompt
    BackgroundUpdateService().pendingInAppPrompt.addListener(
      _handleInAppPrompt,
    );
    // Handle any existing background update state (e.g. restored from persistence)
    _handleBgUpdateStateChange();
    // Periodically refresh "last seen" relative labels (like the web app does)
    _lastSeenRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) setState(() {});
    });

    // Check for pending notification navigation after lobby is ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingNotification();
    });

    _startPendingNotificationRetryWindow();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // When the app returns to the foreground, messages may have arrived via FCM
    // while we were backgrounded (no live socket events). Re-fetch so the
    // contact list reflects the latest-message order without a manual refresh,
    // matching the web app.
    if (state == AppLifecycleState.resumed) {
      _resyncLobbyOrder('app resumed');
      // Check for a new app version on every foreground/open (forced past the
      // passive throttle). Auto-update preference decides what happens next.
      unawaited(
        VersionService().checkAndPromptUpdate(
          NotificationHandler.navigatorKey.currentContext,
          force: true,
        ),
      );
      // If the user tapped "Install Now" while we were backgrounded, launch the
      // installer now that an Activity context is available.
      unawaited(BackgroundUpdateService().consumePendingInstall());
    }
  }

  /// Re-fetches the lobby from the server so tiles re-sort by most recent
  /// activity. Throttled so a foreground resume that also triggers a socket
  /// reconnect doesn't fire two fetches in quick succession.
  void _resyncLobbyOrder(String reason) {
    if (!mounted) return;
    final now = DateTime.now();
    if (_lastAutoResyncAt != null &&
        now.difference(_lastAutoResyncAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastAutoResyncAt = now;
    debugPrint('🔄 Re-syncing lobby order ($reason)');
    _loadLobby(useCacheFirst: false);
  }

  void _handleBgUpdateStateChange() {
    if (mounted) setState(() {});
  }

  /// Fires when BackgroundUpdateService emits a pending in-app prompt.
  void _handleInAppPrompt() {
    final prompt = BackgroundUpdateService().pendingInAppPrompt.value;
    if (prompt == null || !mounted) return;
    // Clear it immediately so it only shows once
    BackgroundUpdateService().pendingInAppPrompt.value = null;
    _showUpdateDialog(prompt);
  }

  /// Shows a modal dialog with [Download Now] and [Later] buttons.
  /// The dialog cannot be dismissed by tapping outside — the user must choose.
  Future<void> _showUpdateDialog(InAppUpdatePrompt prompt) async {
    final version = prompt.info.version;
    final releaseNotes = prompt.info.releaseNotes;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E2E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              const Icon(
                Icons.system_update_alt_rounded,
                color: Color(0xFF00D9FF),
                size: 28,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Update v$version Available',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'A new version of the app is ready.',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              if (releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  "What's new:",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: SingleChildScrollView(
                    child: Text(
                      releaseNotes,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                // Defer the update — save payload so the lobby badge stays visible
                VersionService().deferUpdatePayload({
                  'version': prompt.info.version,
                  'build_number': prompt.info.buildNumber,
                  'download_url': prompt.downloadUrl,
                  'force_update': prompt.info.forceUpdate,
                  'release_notes': prompt.info.releaseNotes,
                });
                unawaited(_loadDeferredUpdateEntry());
              },
              child: const Text(
                'Later',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await BackgroundUpdateService().startBackgroundDownload(
                  prompt.info,
                  prompt.downloadUrl,
                );
                // Clear the deferred payload — download is now managed by BackgroundUpdateService
                await VersionService().clearDeferredUpdatePayload();
                await _loadDeferredUpdateEntry();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00D9FF),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                'Download Now',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _loadDeferredUpdateEntry() async {
    final payload = await VersionService().getDeferredUpdatePayloadIfRelevant();
    if (!mounted) return;
    setState(() {
      _deferredUpdatePayload = payload;
    });
  }

  /// Called when the user taps the update icon in the idle ("update available") state.
  /// Brings up the modal dialog so the user can choose to update or defer.
  Future<void> _openDeferredUpdatePrompt() async {
    final payload = _deferredUpdatePayload;
    if (payload == null) return;

    try {
      final info = AppVersionInfo.fromJson(payload);
      final resolvedUrl = payload['download_url']?.toString().trim() ?? '';
      if (info.version.isNotEmpty && resolvedUrl.isNotEmpty) {
        // Bring up the modal again instead of starting download immediately
        _showUpdateDialog(
          InAppUpdatePrompt(info: info, downloadUrl: resolvedUrl),
        );
        return;
      }
    } catch (e) {
      debugPrint('Failed to show update dialog from deferred payload: $e');
    }

    // Fallback: show the dialog if we couldn't start the background download
    await VersionService().promptUpdateFromPush(context, payload);
    await _loadDeferredUpdateEntry();
  }

  void _handleDeferredUpdateSignal() {
    unawaited(_loadDeferredUpdateEntry());
  }

  /// Builds the update icon in the AppBar — one of three states:
  ///   idle (deferred payload)  → cyan icon + red dot
  ///   downloading              → spinning progress ring around icon
  ///   readyToInstall           → pulsing green icon + green dot
  Widget _buildDeferredUpdateIndicator() {
    final bgState = BackgroundUpdateService().state.value;

    // ── Downloading state ──────────────────────────────────────────────────
    if (bgState.status == BackgroundUpdateStatus.downloading) {
      final progress = bgState.progress;
      return SizedBox(
        width: 40,
        height: 40,
        child: Tooltip(
          message: 'Downloading update… ${(progress * 100).truncate()}%',
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  value: progress > 0 ? progress : null,
                  strokeWidth: 2.5,
                  color: const Color(0xFF00D9FF),
                  backgroundColor: Colors.white12,
                ),
              ),
              const Icon(
                Icons.download_rounded,
                color: Color(0xFF00D9FF),
                size: 15,
              ),
            ],
          ),
        ),
      );
    }

    // ── Ready to install state ─────────────────────────────────────────────
    if (bgState.status == BackgroundUpdateStatus.readyToInstall) {
      final version = bgState.versionInfo?.version ?? '';
      return _PulsingUpdateButton(
        tooltip: version.isEmpty
            ? 'Update ready — tap to install'
            : 'v$version ready — tap to install',
        onPressed: () => BackgroundUpdateService().launchInstaller(),
      );
    }

    // ── Idle: deferred payload available ──────────────────────────────────
    final payload = _deferredUpdatePayload;
    if (payload == null) {
      return const SizedBox(width: 40);
    }

    final version = (payload['version'] ?? '').toString().trim();
    final tooltip = version.isEmpty
        ? 'Update available — tap to download'
        : 'v$version available — tap to download';

    return IconButton(
      tooltip: tooltip,
      onPressed: _openDeferredUpdatePrompt,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(
            Icons.system_update_alt_rounded,
            color: Color(0xFF00D9FF),
            size: 24,
          ),
          Positioned(
            right: -1,
            top: -1,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: const Color(0xFFFF4D6D),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: const Color(0xFF1A1A2E), width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _startPendingNotificationRetryWindow() {
    _pendingNotificationRetryTimer?.cancel();
    _pendingNotificationRetryTimer = Timer.periodic(
      const Duration(milliseconds: 700),
      (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }

        if (NotificationHandler.hasPendingNavigation) {
          _checkPendingNotification();
        }

        // Retry only for a short boot window to catch delayed cold-start payload sync.
        if (timer.tick >= 10) {
          timer.cancel();
        }
      },
    );
  }

  /// Check if there's a pending notification to handle
  void _checkPendingNotification() {
    debugPrint('📱 LobbyScreen: Checking for pending notifications...');
    final pendingData = NotificationHandler.getPendingNotificationData();
    if (pendingData != null) {
      debugPrint(
        '📱 LobbyScreen: Processing pending notification: $pendingData',
      );
      // Wait a bit to ensure lobby is fully rendered
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          NotificationHandler.handleNotificationTap(
            pendingData,
            fromPending: true,
          );
        }
      });
    } else {
      debugPrint('📱 LobbyScreen: No pending notifications found');
    }
  }

  Future<void> _loadAdminStatus() async {
    final isAdmin = await StorageService.getIsAdmin();
    if (mounted) {
      setState(() => _isCurrentUserAdmin = isAdmin);
    }
  }

  void _setupRealtimeListeners() {
    const key = 'lobby';

    // Listen for doorbell rings. The backend echoes the event to the sender's
    // room too, so self-sent notifications update the recipient's tile as an
    // outgoing "You sent a notification" — matching the web app.
    _socketService.addListener('doorbellRing', key, (
      Map<String, dynamic> data,
    ) {
      _handleDoorbellRing(data);
    });

    // Listen for new messages (incoming)
    _socketService.addListener('messageReceived', key, (
      Map<String, dynamic> data,
    ) {
      _handleNewMessage(data);
    });

    // Persistent call-log entries (declined / missed / answered) — update the
    // conversation-list preview for both directions: an outgoing log (we were
    // the caller) goes through the sent-message path, an incoming one through
    // the new-message path (which also bumps unread, matching the web app).
    _socketService.addListener('callLogMessage', key, (
      Map<String, dynamic> data,
    ) {
      final senderId = _toInt(data['sender_id']);
      final currentUserId = _socketService.currentUserId;
      if (senderId != null &&
          currentUserId != null &&
          senderId == currentUserId) {
        _handleSentMessage(data);
      } else {
        _handleNewMessage(data);
      }
    });

    // Listen for sent messages (outgoing from current user)
    _socketService.addListener('messageSent', key, (Map<String, dynamic> data) {
      _handleSentMessage(data);
    });

    // Listen for file messages (incoming files from web)
    _socketService.addListener('fileReceived', key, (
      Map<String, dynamic> data,
    ) {
      _handleFileMessage(data);
    });

    // Listen for voice messages (incoming voice from web)
    _socketService.addListener('voiceMessageReceived', key, (
      Map<String, dynamic> data,
    ) {
      _handleVoiceMessage(data);
    });

    // Listen for presence updates
    _socketService.addListener('presenceUpdate', key, (
      Map<String, dynamic> data,
    ) {
      _updateUserPresence(data);
    });

    // Listen for presence snapshot (initial state on connect)
    _socketService.addListener('presenceSnapshot', key, (
      List<dynamic> contacts,
    ) {
      _handlePresenceSnapshot(contacts);
    });

    // Listen for incoming calls (global handler)
    // NOTE: We only listen to 'incomingCall' here (not 'crossRoomCallOffer') because the
    // server sends BOTH events to the callee for the same call. 'incomingCall' contains
    // full call data (call_id, call_room_id) and is sufficient for mobile clients.
    // Listening to both would open two modals for the same call.
    _socketService.addListener('incomingCall', key, (
      Map<String, dynamic> data,
    ) {
      _handleIncomingCall(data);
    });

    // If this account answers on another device/session, close incoming modal.
    _socketService.addListener('callAnswered', key, (
      Map<String, dynamic> data,
    ) {
      if (!_isAcceptedOnOtherDeviceForActiveIncoming(data)) return;
      _dismissIncomingCallModalIfOpen();
      PresenceService().isHandlingIncomingCall = false;
      _clearIncomingCallNotificationsForEvent(data);
    });

    // Primary cross-device sync event for offer dismissal.
    _socketService.addListener('callOfferStateSync', key, (
      Map<String, dynamic> data,
    ) {
      if (!_isAcceptedOnOtherDeviceForActiveIncoming(data)) return;
      _dismissIncomingCallModalIfOpen();
      PresenceService().isHandlingIncomingCall = false;
      _clearIncomingCallNotificationsForEvent(data);
    });

    _socketService.addListener('callSessionState', key, (
      Map<String, dynamic> data,
    ) {
      _handleCallSessionStateForLobby(data);
    });

    // FALLBACK: Also listen for crossRoomCallOffer in case backend only sends this event
    // This handles cases where web clients call mobile and backend doesn't send 'incomingCall'
    _socketService.addListener('crossRoomCallOffer', key, (
      Map<String, dynamic> data,
    ) {
      debugPrint(
        '📲 Fallback: Received crossRoomCallOffer, converting to incomingCall format',
      );
      debugPrint('📲 Original crossRoomCallOffer data: $data');

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

      debugPrint('📲 Converted to incomingCall format: $convertedData');
      _handleIncomingCall(convertedData);
    });

    // Backend reconnected - presence snapshot will follow automatically
    // from the server, so we don't need to force a full reload here.
    // This prevents UI flickering and allows smooth presence updates.
    _socketService.addListener('reconnected', key, () {
      debugPrint('🔄 Backend reconnected - waiting for presence snapshot');
      // Messages may have arrived while the socket was down; re-fetch so the
      // contact list re-sorts by most recent activity automatically.
      _resyncLobbyOrder('socket reconnected');
    });

    // Listen for group events
    // Group management events using standardized socket service listeners
    _socketService.addListener('groupCreated', key, (dynamic data) {
      debugPrint('🎉 Group created event received: $data');
      if (data is Map<String, dynamic>) {
        try {
          final group = Group.fromJson(data);
          if (mounted) {
            setState(() {
              _groups.insert(0, group);
            });
            _filterUsers(); // Refresh filtered lists
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('New group: ${group.name}'),
                backgroundColor: Colors.green,
              ),
            );
          }
        } catch (e) {
          debugPrint('❌ Error parsing group_created event: $e');
        }
      }
    });

    _socketService.addListener('groupUpdated', key, (dynamic data) {
      debugPrint('🔄 Group updated event received: $data');
      if (data is Map<String, dynamic>) {
        try {
          final updatedGroup = Group.fromJson(data);
          if (mounted) {
            setState(() {
              final index = _groups.indexWhere((g) => g.id == updatedGroup.id);
              if (index != -1) {
                _groups[index] = updatedGroup;
              }
            });
            _filterUsers(); // Refresh filtered lists
          }
        } catch (e) {
          debugPrint('❌ Error parsing group_updated event: $e');
        }
      }
    });

    _socketService.addListener('groupMemberAdded', key, (dynamic data) {
      debugPrint('👥 Group member added event received: $data');
      if (data is Map<String, dynamic>) {
        final groupData = data['group'] as Map<String, dynamic>?;
        final addedUserIds = List<int>.from(data['added_user_ids'] ?? []);

        if (groupData != null && mounted) {
          _currentUserId.then((userId) {
            if (userId != null && addedUserIds.contains(userId)) {
              // Current user was added to the group
              try {
                final newGroup = Group.fromJson(groupData);
                setState(() {
                  // Check if group already exists (shouldn't happen, but safety check)
                  final existingIndex = _groups.indexWhere(
                    (g) => g.id == newGroup.id,
                  );
                  if (existingIndex == -1) {
                    _groups.insert(0, newGroup);
                  } else {
                    _groups[existingIndex] = newGroup;
                  }
                });
                _filterUsers();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Added to group: ${newGroup.name}'),
                    backgroundColor: Colors.green,
                  ),
                );
              } catch (e) {
                debugPrint('❌ Error parsing group_member_added event: $e');
              }
            } else {
              // Another member was added, update existing group if we have it
              try {
                final updatedGroup = Group.fromJson(groupData);
                final index = _groups.indexWhere(
                  (g) => g.id == updatedGroup.id,
                );
                if (index != -1) {
                  setState(() {
                    _groups[index] = updatedGroup;
                  });
                  _filterUsers();
                }
              } catch (e) {
                debugPrint('❌ Error updating group after member added: $e');
              }
            }
          });
        }
      }
    });

    _socketService.addListener('groupDeleted', key, (dynamic data) {
      debugPrint('🗑️ Group deleted event received: $data');
      if (data is Map<String, dynamic>) {
        final groupId = data['group_id'] as int?;
        final groupName = data['group_name'] as String?;

        if (groupId != null && mounted) {
          setState(() {
            _groups.removeWhere((g) => g.id == groupId);
          });
          _filterUsers();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Group deleted: ${groupName ?? 'Unknown'}'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    });

    _socketService.addListener('groupMemberLeft', key, (dynamic data) {
      debugPrint('👋 Group member removed event received: $data');
      debugPrint('👋 Event data type: ${data.runtimeType}');
      if (data is Map<String, dynamic>) {
        int? groupId;
        int? removedUserId;

        // Handle different event data structures
        if (data.containsKey('group_id') && data.containsKey('user_id')) {
          // Structure: {group_id: 6, user_id: 16} - from group_member_left
          groupId = data['group_id'] as int?;
          removedUserId = data['user_id'] as int?;
          debugPrint('👋 Using group_member_left structure');
        } else if (data.containsKey('group')) {
          // Structure: {group: {...}} - from group_member_removed
          final groupData = data['group'] as Map<String, dynamic>?;
          if (groupData != null) {
            groupId = groupData['id'] as int?;
            // For group_member_removed, we need to determine which user was removed
            // by comparing the current member list with our stored list
            // For now, we'll check if current user is still in the members list
            final members = groupData['members'] as List?;
            if (members != null) {
              _currentUserId.then((userId) {
                if (userId != null) {
                  final isCurrentUserInGroup = members.any((member) {
                    final memberData = member as Map<String, dynamic>;
                    final memberUserId = memberData['user_id'] as int?;
                    return memberUserId == userId;
                  });

                  debugPrint(
                    '👋 Current user ($userId) in group: $isCurrentUserInGroup',
                  );

                  if (!isCurrentUserInGroup) {
                    // Current user was removed
                    debugPrint(
                      '👋 Current user ($userId) not found in member list, was removed from group $groupId',
                    );
                    setState(() {
                      final initialCount = _groups.length;
                      _groups.removeWhere((g) => g.id == groupId);
                      final finalCount = _groups.length;
                      debugPrint(
                        '👋 Groups count: $initialCount → $finalCount',
                      );
                    });
                    _filterUsers();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('You were removed from a group'),
                        backgroundColor: Colors.orange,
                      ),
                    );
                  } else {
                    debugPrint(
                      '👋 Current user still in group, another member was removed',
                    );
                    // Another member was removed, reload group details
                    _loadLobby(useCacheFirst: false);
                  }
                }
              });
            }
          }
          debugPrint('👋 Using group_member_removed structure');
          return; // Exit early for this structure as we handle it above
        }

        debugPrint(
          '👋 Parsed groupId: $groupId, removedUserId: $removedUserId',
        );

        if (groupId != null && removedUserId != null && mounted) {
          _currentUserId.then((userId) {
            debugPrint(
              '👋 Current userId: $userId, comparing with removedUserId: $removedUserId',
            );
            if (userId == removedUserId) {
              debugPrint(
                '👋 Current user was removed from group $groupId, removing from list',
              );
              // Current user was removed, remove group from list
              setState(() {
                final initialCount = _groups.length;
                _groups.removeWhere((g) => g.id == groupId);
                final finalCount = _groups.length;
                debugPrint('👋 Groups count: $initialCount → $finalCount');
              });
              _filterUsers();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('You were removed from a group'),
                  backgroundColor: Colors.orange,
                ),
              );
            } else {
              debugPrint('👋 Another member was removed, reloading lobby');
              // Another member was removed, reload group details
              _loadLobby(useCacheFirst: false);
            }
          });
        } else {
          debugPrint(
            '👋 Missing required data: groupId=$groupId, removedUserId=$removedUserId, mounted=$mounted',
          );
        }
      } else {
        debugPrint('👋 Event data is not a Map: $data');
      }
    });

    // Listen for typing events from peers
    _socketService.addListener('userTyping', key, (Map<String, dynamic> data) {
      final userId = data['user_id'] as int?;
      final isTyping = data['is_typing'] as bool? ?? false;
      if (userId == null) return;
      if (!mounted) return;
      setState(() {
        if (isTyping) {
          _typingUsers[userId]?.cancel();
          _typingUsers[userId] = Timer(const Duration(seconds: 5), () {
            if (mounted) setState(() => _typingUsers.remove(userId));
          });
        } else {
          _typingUsers[userId]?.cancel();
          _typingUsers.remove(userId);
        }
      });
    });

    _socketService.addListener('typingUpdate', key, (
      Map<String, dynamic> data,
    ) {
      final userId = (data['user_id'] ?? data['sender_id']) as int?;
      if (userId == null) return;
      if (!mounted) return;
      setState(() {
        _typingUsers[userId]?.cancel();
        _typingUsers[userId] = Timer(const Duration(seconds: 5), () {
          if (mounted) setState(() => _typingUsers.remove(userId));
        });
      });
    });
  }

  void _setupFcmForegroundListener() {
    _fcmForegroundSubscription?.cancel();
    _fcmForegroundSubscription = FirebaseMessaging.onMessage.listen((
      RemoteMessage message,
    ) {
      if (!mounted) return;

      final data = message.data;
      if (data.isEmpty) return;

      final type = data['type']?.toString().toLowerCase();
      if (type == 'call' || type == 'color_change') {
        return;
      }

      if (type == 'doorbell') {
        _handleDoorbellRing(data);
        return;
      }

      if (data['file_name'] != null || type == 'file') {
        _handleFileMessage(data);
        return;
      }

      if (data['duration'] != null || type == 'voice') {
        _handleVoiceMessage(data);
        return;
      }

      _handleNewMessage(data);
    });
  }

  void _setupShareIntentListener() {
    _shareIntentSubscription?.cancel();
    _shareIntentSubscription = ShareIntentService.instance.sharedItemsStream
        .listen((_) {
          _openSharePickerIfNeeded();
        });
  }

  void _setupShortcutLaunchListener() {
    _shortcutLaunchSubscription?.cancel();
    _shortcutLaunchSubscription = ShortcutService.instance.shortcutTargetStream
        .listen((userId) {
          _openShortcutChatIfNeeded(userId);
        });
  }

  Future<void> _openShortcutChatIfNeeded(int userId) async {
    if (!mounted) return;

    LobbyUser? targetUser;
    for (final user in _lobbyUsers) {
      if (user.id == userId) {
        targetUser = user;
        break;
      }
    }

    if (targetUser == null) {
      try {
        final refreshedUsers = await LobbyService.getLobbyUsers();
        if (!mounted) return;
        setState(() {
          _lobbyUsers = _sortUsersByRecentActivity(refreshedUsers);
        });
        _filterUsers();
        for (final user in _lobbyUsers) {
          if (user.id == userId) {
            targetUser = user;
            break;
          }
        }
      } catch (e) {
        debugPrint('Failed to refresh users for shortcut launch: $e');
      }
    }

    if (!mounted || targetUser == null) return;

    final hasCrossDeviceCall = _crossDeviceActiveCallRoomByUserId.containsKey(
      targetUser.id,
    );

    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              otherUser: targetUser!,
              initialCallInProgressOnOtherDevice: hasCrossDeviceCall,
            ),
          ),
        )
        .then((_) {
          _currentlyViewingChatUserId = null;
        });
    _currentlyViewingChatUserId = targetUser.id;
  }

  Future<void> _openSharePickerIfNeeded() async {
    if (!mounted || _isSharePickerOpen) {
      return;
    }

    if (!ShareIntentService.instance.hasPendingItems) {
      return;
    }

    final sharedItems = await ShareIntentService.instance
        .takePendingSharedItems();
    if (!mounted || sharedItems.isEmpty) {
      return;
    }

    _isSharePickerOpen = true;
    try {
      // If the items arrived via a Direct Share shortcut tap, grab the target user id
      // so ShareTargetScreen can pre-select and auto-send without user interaction.
      final directShareUserId =
          sharedItems
              .map((i) => i.directShareUserId)
              .firstWhere((id) => id != null, orElse: () => null) ??
          await ShareIntentService.instance.takePendingDirectShareUserId();

      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ShareTargetScreen(
            sharedItems: sharedItems,
            users: _lobbyUsers,
            directShareUserId: directShareUserId,
          ),
        ),
      );

      if (!mounted || result is! Map<String, dynamic>) {
        return;
      }

      final sentCount = result['sentCount'] as int? ?? 0;
      final failedCount = result['failedCount'] as int? ?? 0;

      if (sentCount > 0) {
        final message = failedCount > 0
            ? 'Sent to $sentCount chats, failed for $failedCount.'
            : 'Sent to $sentCount chats.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: failedCount > 0 ? Colors.orange : Colors.green,
          ),
        );
        _loadLobby(useCacheFirst: false);
      }
    } finally {
      _isSharePickerOpen = false;
    }
  }

  /// Handle cross-room call offer from web client
  Future<void> _handleCrossRoomCallOffer(Map<String, dynamic> data) async {
    if (!mounted) return;

    // Guard against duplicate/rapid incoming call events (global flag shared with chat screen)
    if (PresenceService().isHandlingIncomingCall) {
      debugPrint(
        '⚠️ Already handling an incoming call, ignoring cross-room duplicate',
      );
      return;
    }
    PresenceService().isHandlingIncomingCall = true;

    debugPrint('📲 Cross-room call offer received in lobby: $data');

    final callerId = data['caller_id'] as int?;
    final callerUsername = data['caller_username'] as String? ?? 'Unknown';
    final callType = data['call_type'] as String? ?? 'video';
    final room = data['room'] as String?;

    if (callerId == null || room == null) {
      debugPrint('⚠️ Invalid cross-room call offer data');
      PresenceService().isHandlingIncomingCall = false;
      return;
    }

    // Initialize call service FIRST
    final callService = CallService();
    await callService.initialize();

    // Set up signal handler IMMEDIATELY - before handleIncomingCall
    // This ensures we capture any signals that arrive while setting up
    _socketService.onSignal = (signalData) {
      if (_isAcceptedOnOtherDeviceCancelSignalForActiveIncoming(signalData)) {
        debugPrint(
          '📴 Dismissing incoming call modal (accepted on other device via signal)',
        );
        _dismissIncomingCallModalIfOpen();
        PresenceService().isHandlingIncomingCall = false;
        return;
      }
      debugPrint('📡 Signal received for cross-room call: $signalData');
      callService.handleSignal(signalData);
    };

    // Create synthetic incoming call data for the call service
    final syntheticCallData = {
      'id': DateTime.now().millisecondsSinceEpoch, // Temporary ID
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
    const crossRoomListenerKey = 'lobby_cross_room_call';
    _socketService.addListener('callEnded', crossRoomListenerKey, (
      Map<String, dynamic> endData,
    ) {
      debugPrint('📴 Call ended by remote user (lobby cross-room)');
      _socketService.stopSignalBuffering();
      callService.handleCallEnded();
    });

    _socketService.addListener('callDeclined', crossRoomListenerKey, (
      Map<String, dynamic> declineData,
    ) {
      debugPrint('❌ Call declined (lobby cross-room)');
      _socketService.stopSignalBuffering();
      callService.handleCallDeclined();
    });

    // Show incoming call setup modal with device selection
    final route = MaterialPageRoute(
      fullscreenDialog: true,
      builder: (context) => IncomingCallSetupModal(
        callerName: callerUsername,
        callerId: callerId,
        callType: callType,
        callService: callService,
        onDecline: () {
          debugPrint('📞 Call declined by user');
          // Dismiss the incoming-call FCM/local notification immediately on
          // self-decline (don't wait for the server's terminal echo).
          unawaited(
            FirebaseMessagingService.instance.clearIncomingCallNotifications(
              otherUserId: callerId,
              callRoomId: room,
            ),
          );
          _socketService.stopSignalBuffering();
          _socketService.removeListener('callEnded', crossRoomListenerKey);
          _socketService.removeListener('callDeclined', crossRoomListenerKey);
        },
      ),
    );

    _activeIncomingCallRoute = route;
    _activeIncomingCallId = syntheticCallData['id'] as int?;
    _activeIncomingCallRoomId = room;

    Navigator.of(context).push(route).then((result) {
      // Clean up listeners when modal closes
      _socketService.removeListener('callEnded', crossRoomListenerKey);
      _socketService.removeListener('callDeclined', crossRoomListenerKey);

      if (identical(_activeIncomingCallRoute, route)) {
        _activeIncomingCallRoute = null;
        _activeIncomingCallId = null;
        _activeIncomingCallRoomId = null;
      }

      if (result is Map &&
          (result['result'] == 'accepted' || result['result'] == 'connected')) {
        final localStream = result['localStream'];
        final callerUser = _lobbyUsers.firstWhere(
          (u) => u.id == callerId,
          orElse: () => LobbyUser(
            id: callerId,
            username: callerUsername,
            email: '',
            firstName: callerUsername,
            lastName: '',
            fullName: callerUsername,
            status: 'online',
            isOnline: true,
            isAdmin: false,
            timezone: '',
          ),
        );
        Navigator.of(context)
            .push(
              MaterialPageRoute(
                fullscreenDialog: true,
                builder: (context) => ConnectedCallScreen(
                  remoteName: callerUsername,
                  callType: callType,
                  callService: callService,
                  localStream: localStream ?? callService.localStream,
                  onChatPressed: () {
                    Navigator.of(context).pop();
                    _currentlyViewingChatUserId = callerUser.id;
                    Navigator.of(context)
                        .push(
                          MaterialPageRoute(
                            builder: (_) => ChatScreen(
                              otherUser: callerUser,
                              initialCallInProgressOnOtherDevice:
                                  _crossDeviceActiveCallRoomByUserId
                                      .containsKey(callerUser.id),
                            ),
                          ),
                        )
                        .then((_) {
                          _currentlyViewingChatUserId = null;
                        });
                  },
                ),
              ),
            )
            .then((_) {
              _setupRealtimeListeners();
            });
      }
      PresenceService().isHandlingIncomingCall = false;
      _setupRealtimeListeners();
    });
  }

  /// Handle incoming call from another user
  void _onPendingIncomingCallChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _handleIncomingCall(Map<String, dynamic> data) async {
    if (!mounted) return;

    // Guard: ignore if already in an active call (e.g. screen-share renegotiation
    // sends a new incoming_call event while ConnectedCallScreen is open)
    if (PresenceService().isCallInProgress) {
      debugPrint(
        '⚠️ Ignoring incoming_call — call already in progress (screen share or renegotiation?)',
      );
      return;
    }

    // Guard against duplicate/rapid incoming call events (global flag shared with chat screen)
    if (PresenceService().isHandlingIncomingCall) {
      debugPrint(
        '⚠️ Already handling an incoming call, ignoring duplicate event',
      );
      return;
    }
    PresenceService().isHandlingIncomingCall = true;

    debugPrint('📲 Incoming call received in lobby: $data');

    final callId = data['id'] as int?;
    final callRoomId = data['call_room_id'] as String?;
    final callType = data['call_type'] as String? ?? 'video';
    final callerData = data['caller'] as Map<String, dynamic>?;
    final callerId = callerData?['id'] as int? ?? data['caller_id'] as int?;
    final callerName =
        callerData?['full_name'] as String? ??
        callerData?['username'] as String? ??
        'Unknown';

    if (callId == null || callRoomId == null || callerId == null) {
      debugPrint('⚠️ Invalid incoming call data');
      PresenceService().isHandlingIncomingCall = false;
      return;
    }

    // Cross-room guard: only pop the modal when the caller's own chat is open.
    // Otherwise (on the lobby, in a group, or in a different 1-on-1 chat) defer
    // it — the caller's tile glows with a ringing indicator and the modal is
    // surfaced when the user opens that chat.
    final activeUserId = ActiveChatService().activeUserId;
    if (activeUserId != callerId) {
      debugPrint(
        '📲 Deferring incoming call from $callerId (active chat: $activeUserId)',
      );
      PendingIncomingCallService().setPending(data);
      PresenceService().isHandlingIncomingCall = false;
      return;
    }
    PendingIncomingCallService().clearIfMatches(callRoomId: callRoomId);

    // START buffering WebRTC signals immediately — before the async callService.initialize().
    // Previously this was triggered by the crossRoomCallOffer socket event, but we no longer
    // listen for that in the lobby. Without buffering, any offer signal that arrives during
    // the async gap would be silently dropped (_bufferSignals=false, _onSignal=null → noop).
    _socketService.startSignalBuffering();

    // Initialize call service (fetches ICE servers)
    final callService = CallService();
    await callService.initialize();

    // CRITICAL: Set call state BEFORE setting up signal handler
    // This ensures that when buffered signals are processed, the call state is already set
    callService.handleIncomingCall(data);
    debugPrint('📲 Call state set to ringing, now setting up signal handler');

    // Set up signal handler for WebRTC — buffered signals are replayed immediately
    _socketService.onSignal = (signalData) {
      if (_isAcceptedOnOtherDeviceCancelSignalForActiveIncoming(signalData)) {
        debugPrint(
          '📴 Dismissing incoming call modal (accepted on other device via signal)',
        );
        _dismissIncomingCallModalIfOpen();
        PresenceService().isHandlingIncomingCall = false;
        return;
      }
      debugPrint('📡 Signal received for incoming call: $signalData');
      callService.handleSignal(signalData);
    };

    // Use keyed listeners for call ended/declined handlers to avoid overwriting
    const callListenerKey = 'lobby_incoming_call';
    _socketService.addListener('callEnded', callListenerKey, (
      Map<String, dynamic> endData,
    ) {
      debugPrint('📴 Call ended by remote user (lobby)');
      callService.handleCallEnded();
    });

    _socketService.addListener('callDeclined', callListenerKey, (
      Map<String, dynamic> declineData,
    ) {
      debugPrint('❌ Call declined (lobby)');
      callService.handleCallDeclined();
    });

    // Show incoming call setup modal with device selection
    final route = MaterialPageRoute(
      fullscreenDialog: true,
      builder: (context) => IncomingCallSetupModal(
        callerName: callerName,
        callerId: callerId,
        callType: callType,
        callService: callService,
        onDecline: () {
          debugPrint('📞 Call declined by user');
          // Dismiss the incoming-call FCM/local notification immediately on
          // self-decline (don't wait for the server's terminal echo).
          unawaited(
            FirebaseMessagingService.instance.clearIncomingCallNotifications(
              otherUserId: callerId,
              callRoomId: callRoomId,
            ),
          );
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

      if (result is Map &&
          (result['result'] == 'accepted' || result['result'] == 'connected')) {
        // Navigate to connected call screen with the local stream from setup
        final localStream = result['localStream'];
        final callerUser = _lobbyUsers.firstWhere(
          (u) => u.id == callerId,
          orElse: () => LobbyUser(
            id: callerId,
            username: callerName,
            email: '',
            firstName: callerName,
            lastName: '',
            fullName: callerName,
            status: 'online',
            isOnline: true,
            isAdmin: false,
            timezone: '',
          ),
        );
        Navigator.of(context)
            .push(
              MaterialPageRoute(
                fullscreenDialog: true,
                builder: (context) => ConnectedCallScreen(
                  remoteName: callerName,
                  callType: callType,
                  callService: callService,
                  localStream: localStream ?? callService.localStream,
                  onChatPressed: () {
                    Navigator.of(context).pop();
                    _currentlyViewingChatUserId = callerUser.id;
                    Navigator.of(context)
                        .push(
                          MaterialPageRoute(
                            builder: (_) => ChatScreen(
                              otherUser: callerUser,
                              initialCallInProgressOnOtherDevice:
                                  _crossDeviceActiveCallRoomByUserId
                                      .containsKey(callerUser.id),
                            ),
                          ),
                        )
                        .then((_) {
                          _currentlyViewingChatUserId = null;
                        });
                  },
                ),
              ),
            )
            .then((_) {
              _setupRealtimeListeners();
            });
      }
      PresenceService().isHandlingIncomingCall = false;
      _setupRealtimeListeners();
    });
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
    final currentUserId = _socketService.currentUserId;
    if (currentUserId == null) return false;
    if (PresenceService().isCallInProgress) return false;

    final state = (data['state']?.toString() ?? '').toLowerCase();
    if (state.isNotEmpty && state != 'accepted') return false;

    final actorUserId = _toInt(data['actor_user_id']);
    if (actorUserId != null && actorUserId != currentUserId) return false;

    final calleeId = _toInt(data['callee_id']);
    if (calleeId != null && calleeId != currentUserId) return false;

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

  void _clearIncomingCallNotificationsForEvent(Map<String, dynamic> data) {
    final otherUserId =
        _extractOtherParticipantIdFromSessionState(data) ??
        _toInt(data['caller_id']) ??
        _toInt(data['sender_id']);
    final roomId = data['call_room_id']?.toString() ?? data['room']?.toString();

    unawaited(
      FirebaseMessagingService.instance.clearIncomingCallNotifications(
        otherUserId: otherUserId,
        callRoomId: roomId,
      ),
    );
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

  /// Applies a 1:1 realtime conversation event (message / file / voice /
  /// doorbell) to the contact list: updates the partner tile's preview +
  /// timestamp and bumps it to the top — for BOTH incoming and outgoing
  /// directions, mirroring the web app.
  ///
  /// The backend echoes these events to the sender's own room for cross-device
  /// sync, so an event where `sender_id == me` is an OUTGOING action and must
  /// update the recipient's tile (not our own), shown as "You: …".
  void _applyConversationActivity(
    Map<String, dynamic> data, {
    required String preview,
  }) {
    final senderId = _toInt(data['sender_id']);
    if (senderId == null) return;

    final myId = _socketService.currentUserId;
    final isFromMe = myId != null && senderId == myId;
    final targetId = isFromMe
        ? (_toInt(data['recipient_id']) ?? _toInt(data['receiver_id']))
        : senderId;
    if (targetId == null) return;

    final createdAt =
        _extractEventTimestamp(data) ?? DateTime.now().toIso8601String();
    // Only incoming activity affects the unread badge, and not while we're
    // already viewing that conversation.
    final isViewingThisChat = _currentlyViewingChatUserId == targetId;

    setState(() {
      final userIndex = _lobbyUsers.indexWhere((u) => u.id == targetId);
      if (userIndex == -1) return;

      final user = _lobbyUsers[userIndex];
      final updatedUser = user.copyWith(
        unreadCount: isFromMe
            ? user.unreadCount
            : (isViewingThisChat ? 0 : user.unreadCount + 1),
        lastMessage: preview,
        lastMessageTime: createdAt,
        lastMessageIsFromMe: isFromMe,
      );

      _lobbyUsers[userIndex] = updatedUser;
      _lobbyUsers.removeAt(userIndex);
      _lobbyUsers.insert(0, updatedUser);
      _updateFilteredLists();
    });
  }

  void _handleDoorbellRing(Map<String, dynamic> data) {
    // Doorbell ring sound is already played via the socket service
    // No modal needed - the notification sound is sufficient
    if (_isDuplicateRealtimeEvent(data)) return;

    // Matches the persisted doorbell message content so realtime and a server
    // refresh show the same preview text.
    _applyConversationActivity(data, preview: 'Sent a Notification!');

    debugPrint('Doorbell ring from ${data['sender_name']}');
  }

  bool _isDuplicateRealtimeEvent(Map<String, dynamic> data) {
    final now = DateTime.now();
    _recentRealtimeEventKeys.removeWhere(
      (_, seenAt) => now.difference(seenAt) > const Duration(seconds: 30),
    );

    final key = _buildRealtimeEventKey(data);
    if (key == null) {
      return false;
    }

    if (_recentRealtimeEventKeys.containsKey(key)) {
      return true;
    }

    _recentRealtimeEventKeys[key] = now;
    return false;
  }

  String? _buildRealtimeEventKey(Map<String, dynamic> data) {
    final explicitId =
        data['message_id'] ??
        data['id'] ??
        data['event_id'] ??
        data['notification_id'];
    final normalizedType = _normalizedRealtimeType(data);

    if (explicitId != null) {
      return '$normalizedType:$explicitId';
    }

    final senderId =
        data['sender_id']?.toString() ?? data['user_id']?.toString() ?? '';
    final groupId = data['group_id']?.toString() ?? '';
    final timestamp = _extractEventTimestamp(data) ?? '';
    final content =
        data['content']?.toString() ??
        data['file_name']?.toString() ??
        data['duration']?.toString() ??
        '';

    if (senderId.isEmpty &&
        groupId.isEmpty &&
        timestamp.isEmpty &&
        content.isEmpty) {
      return null;
    }

    return '$normalizedType:$senderId:$groupId:$timestamp:$content';
  }

  String _normalizedRealtimeType(Map<String, dynamic> data) {
    final type = data['type']?.toString().toLowerCase();
    if (type != null && type.isNotEmpty) {
      return type;
    }
    if (data['file_name'] != null) return 'file';
    if (data['duration'] != null) return 'voice';
    return 'message';
  }

  int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  String? _extractEventTimestamp(Map<String, dynamic> data) {
    final createdAt = data['created_at'];
    if (createdAt is String && createdAt.trim().isNotEmpty) {
      return createdAt.trim();
    }

    final timestamp = data['timestamp'];
    if (timestamp is String && timestamp.trim().isNotEmpty) {
      return timestamp.trim();
    }

    final timestampMs = _toInt(data['timestamp_ms']);
    if (timestampMs != null && timestampMs > 0) {
      return DateTime.fromMillisecondsSinceEpoch(
        timestampMs,
        isUtc: true,
      ).toIso8601String();
    }

    final nestedMessage = data['message'];
    if (nestedMessage is Map<String, dynamic>) {
      final nestedCreatedAt = nestedMessage['created_at'];
      if (nestedCreatedAt is String && nestedCreatedAt.trim().isNotEmpty) {
        return nestedCreatedAt.trim();
      }

      final nestedTimestamp = nestedMessage['timestamp'];
      if (nestedTimestamp is String && nestedTimestamp.trim().isNotEmpty) {
        return nestedTimestamp.trim();
      }

      final nestedTimestampMs = _toInt(nestedMessage['timestamp_ms']);
      if (nestedTimestampMs != null && nestedTimestampMs > 0) {
        return DateTime.fromMillisecondsSinceEpoch(
          nestedTimestampMs,
          isUtc: true,
        ).toIso8601String();
      }
    }

    return null;
  }

  void _handleNewMessage(Map<String, dynamic> data) {
    if (_isDuplicateRealtimeEvent(data)) return;

    final senderId = _toInt(data['sender_id']);
    if (senderId == null) return;
    final content = data['content'] as String?;
    final createdAt = _extractEventTimestamp(data);

    // Don't increment unread if user is currently viewing this conversation
    final isViewingThisChat = _currentlyViewingChatUserId == senderId;

    // Update unread count and last message info for sender
    setState(() {
      final userIndex = _lobbyUsers.indexWhere((u) => u.id == senderId);
      if (userIndex != -1) {
        // Create updated user with incremented unread count and new last message
        final user = _lobbyUsers[userIndex];
        final updatedUser = LobbyUser(
          id: user.id,
          username: user.username,
          email: user.email,
          firstName: user.firstName,
          lastName: user.lastName,
          fullName: user.fullName,
          avatarUrl: user.avatarUrl,
          bio: user.bio,
          status: user.status,
          statusMessage: user.statusMessage,
          lastSeen: user.lastSeen,
          isOnline: user.isOnline,
          isAdmin: user.isAdmin,
          timezone: user.timezone,
          unreadCount: isViewingThisChat ? 0 : user.unreadCount + 1,
          isContact: user.isContact,
          isAdminUser: user.isAdminUser,
          // 🆕 NEW: Update last message info
          lastMessage: content ?? user.lastMessage,
          lastMessageTime: createdAt ?? user.lastMessageTime,
          lastMessageIsFromMe:
              false, // Message is from the sender, not from current user
        );

        _lobbyUsers[userIndex] = updatedUser;

        // Move to top of list (most recent message first)
        _lobbyUsers.removeAt(userIndex);
        _lobbyUsers.insert(0, updatedUser);

        // Update filtered list
        _updateFilteredLists();
      }
    });
  }

  void _handleSentMessage(Map<String, dynamic> data) {
    if (_isDuplicateRealtimeEvent(data)) return;

    final senderId = _toInt(data['sender_id']);
    final currentUserId = _socketService.currentUserId;
    final recipientId =
        _toInt(data['recipient_id']) ??
        _toInt(data['receiver_id']) ??
        ((senderId != null && senderId == currentUserId)
            ? currentUserId
            : null);
    if (recipientId == null) return;
    final content = data['content'] as String?;
    final createdAt = _extractEventTimestamp(data);

    // Update last message info for recipient (showing our sent message)
    setState(() {
      final userIndex = _lobbyUsers.indexWhere((u) => u.id == recipientId);
      if (userIndex != -1) {
        // Create updated user with new last message from current user
        final user = _lobbyUsers[userIndex];
        final updatedUser = LobbyUser(
          id: user.id,
          username: user.username,
          email: user.email,
          firstName: user.firstName,
          lastName: user.lastName,
          fullName: user.fullName,
          avatarUrl: user.avatarUrl,
          bio: user.bio,
          status: user.status,
          statusMessage: user.statusMessage,
          lastSeen: user.lastSeen,
          isOnline: user.isOnline,
          isAdmin: user.isAdmin,
          timezone: user.timezone,
          // Keep unread count unchanged; read state should only change via
          // explicit read sync (socket/API), not local UI assumptions.
          unreadCount: user.unreadCount,
          isContact: user.isContact,
          isAdminUser: user.isAdminUser,
          // 🆕 NEW: Update last message info (sent by current user)
          lastMessage: content ?? user.lastMessage,
          lastMessageTime: createdAt ?? user.lastMessageTime,
          lastMessageIsFromMe: true, // Message is from current user
        );

        _lobbyUsers[userIndex] = updatedUser;

        // Move to top of list (most recent message first)
        _lobbyUsers.removeAt(userIndex);
        _lobbyUsers.insert(0, updatedUser);

        // Update filtered list
        _updateFilteredLists();
      }
    });
  }

  void _handleFileMessage(Map<String, dynamic> data) {
    if (_isDuplicateRealtimeEvent(data)) return;

    final fileName = data['file_name'] as String?;
    final filePreview = fileName != null ? "📎 $fileName" : "📎 File";
    _applyConversationActivity(data, preview: filePreview);
  }

  void _handleVoiceMessage(Map<String, dynamic> data) {
    if (_isDuplicateRealtimeEvent(data)) return;

    final duration = data['duration'] as int?;
    final voicePreview = duration != null
        ? "🎤 Voice ${duration}s"
        : "🎤 Voice message";
    _applyConversationActivity(data, preview: voicePreview);
  }

  void _updateUserPresence(Map<String, dynamic> data) {
    final userId = data['user_id'] as int;
    final status = data['status'] as String;
    final isOnline = data['is_online'] as bool? ?? (status == 'online');
    final timestamp = data['timestamp'] as String?;

    setState(() {
      final userIndex = _lobbyUsers.indexWhere((u) => u.id == userId);
      if (userIndex != -1) {
        final user = _lobbyUsers[userIndex];
        final updatedUser = LobbyUser(
          id: user.id,
          username: user.username,
          email: user.email,
          firstName: user.firstName,
          lastName: user.lastName,
          fullName: user.fullName,
          avatarUrl: user.avatarUrl,
          bio: user.bio,
          status: status,
          statusMessage: user.statusMessage,
          lastSeen: timestamp ?? user.lastSeen,
          isOnline: isOnline,
          isAdmin: user.isAdmin,
          timezone: user.timezone,
          unreadCount: user.unreadCount,
          isContact: user.isContact,
          isAdminUser: user.isAdminUser,
          // ✅ IMPORTANT: Preserve message info from in-memory state
          lastMessage: user.lastMessage,
          lastMessageTime: user.lastMessageTime,
          lastMessageIsFromMe: user.lastMessageIsFromMe,
        );

        _lobbyUsers[userIndex] = updatedUser;
        _updateFilteredLists();
      }
    });
  }

  /// Handle presence snapshot from socket (initial state on connect)
  void _handlePresenceSnapshot(List<dynamic> contacts) {
    setState(() {
      for (final contact in contacts) {
        if (contact is Map<String, dynamic>) {
          final userId = contact['user_id'] as int?;
          final status = contact['status'] as String?;
          final timestamp = contact['timestamp'] as String?;

          if (userId != null && status != null) {
            final userIndex = _lobbyUsers.indexWhere((u) => u.id == userId);
            if (userIndex != -1) {
              final user = _lobbyUsers[userIndex];
              final isOnline = status == 'online';
              _lobbyUsers[userIndex] = LobbyUser(
                id: user.id,
                username: user.username,
                email: user.email,
                firstName: user.firstName,
                lastName: user.lastName,
                fullName: user.fullName,
                avatarUrl: user.avatarUrl,
                bio: user.bio,
                status: status,
                statusMessage: user.statusMessage,
                lastSeen: timestamp ?? user.lastSeen,
                isOnline: isOnline,
                isAdmin: user.isAdmin,
                timezone: user.timezone,
                unreadCount: user.unreadCount,
                isContact: user.isContact,
                isAdminUser: user.isAdminUser,
                // ✅ IMPORTANT: Preserve message info from in-memory state
                // This prevents messages received via socket from being wiped out
                lastMessage: user.lastMessage,
                lastMessageTime: user.lastMessageTime,
                lastMessageIsFromMe: user.lastMessageIsFromMe,
              );
            }
          }
        }
      }
      _updateFilteredLists();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PendingIncomingCallService().pending.removeListener(
      _onPendingIncomingCallChanged,
    );
    _searchController.removeListener(_onSearchQueryChanged);
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    _lastSeenRefreshTimer?.cancel();
    _pendingNotificationRetryTimer?.cancel();
    // Cancel all active typing timers
    for (final timer in _typingUsers.values) {
      timer.cancel();
    }
    _typingUsers.clear();
    _shareIntentSubscription?.cancel();
    _shortcutLaunchSubscription?.cancel();
    _fcmForegroundSubscription?.cancel();
    VersionService.deferredUpdateSignal.removeListener(
      _handleDeferredUpdateSignal,
    );
    BackgroundUpdateService().state.removeListener(_handleBgUpdateStateChange);
    BackgroundUpdateService().pendingInAppPrompt.removeListener(
      _handleInAppPrompt,
    );
    // Clear all lobby socket listeners to prevent memory leaks
    _socketService.removeListenersForKey('lobby');
    super.dispose();
  }

  void _onSearchQueryChanged() {
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      _filterUsers();
    });
  }

  Future<void> _loadLobby({bool useCacheFirst = true}) async {
    if (_isLoading && useCacheFirst) return;
    setState(() => _isLoading = true);
    final userId = await StorageService.getUserId();
    if (useCacheFirst && userId != null) {
      final cached = await ChatCacheService.loadLobbyUsers(userId);
      if (cached.isNotEmpty && mounted) {
        final username = await StorageService.getUsername();
        final usersWithSelf = await _ensureSelfUserInLobby(
          users: cached,
          currentUserId: userId,
          currentUsername: username,
        );
        final sortedCachedUsers = _sortUsersByRecentActivity(usersWithSelf);
        setState(() {
          _lobbyUsers = sortedCachedUsers;
          _filteredUsers = List.from(sortedCachedUsers);
        });
        _filterUsers();
      }
    }
    try {
      // Load both users and groups in parallel
      final results = await Future.wait([
        LobbyService.getLobbyUsers(),
        GroupService.getGroups().catchError((e) {
          debugPrint('Groups not available yet: $e');
          return <Group>[];
        }),
      ]);

      final fetchedUsers = results[0] as List<LobbyUser>;
      final username = await StorageService.getUsername();
      final usersWithSelf = await _ensureSelfUserInLobby(
        users: fetchedUsers,
        currentUserId: userId,
        currentUsername: username,
      );
      final users = _sortUsersByRecentActivity(usersWithSelf);
      final groups = _sortGroupsByRecentActivity(results[1] as List<Group>);

      if (mounted) {
        setState(() {
          _lobbyUsers = users;
          _groups = groups;
          _isLoading = false;
        });
        _filterUsers();
        _openSharePickerIfNeeded();
        // Publish direct-share shortcuts so contacts appear in top row of share sheet
        ShortcutService.publishShareTargets(users);
      }
      if (userId != null) {
        await ChatCacheService.saveLobbyUsers(userId, users);
      }
      // Refresh AI chat presence so its tile sorts correctly with fresh server data
      _loadAiSessionPresence();
    } catch (e) {
      final friendly = _mapConnectivityError(
        e,
        offlineLabel: 'No internet connection. Showing cached contacts.',
        backendLabel:
            'Server unreachable. Showing cached contacts if available.',
      );
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _openSharePickerIfNeeded();
      }
      debugPrint('Error loading lobby: $e');
    }
  }

  Future<void> _loadAiSessionPresence() async {
    final userId = await StorageService.getUserId();
    if (userId == null) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final String? aiLastMessageTime = prefs.getString(
      'ai_last_message_time_$userId',
    );
    final String? aiLastMessagePreview = prefs.getString(
      'ai_last_message_preview_$userId',
    );

    if (!mounted) return;
    setState(() {
      _aiLastMessageTime = aiLastMessageTime;
      _aiLastMessagePreview = aiLastMessagePreview;
    });
  }

  Future<List<LobbyUser>> _ensureSelfUserInLobby({
    required List<LobbyUser> users,
    required int? currentUserId,
    required String? currentUsername,
  }) async {
    if (currentUserId == null) return users;

    final exists = users.any((user) => user.id == currentUserId);
    if (exists) {
      return _hydrateSelfUserFromCache(
        users: users,
        currentUserId: currentUserId,
      );
    }

    final syntheticSelfUser = LobbyUser(
      id: currentUserId,
      username: (currentUsername?.trim().isNotEmpty ?? false)
          ? currentUsername!.trim()
          : 'you',
      email: '',
      firstName: 'You',
      lastName: '',
      fullName: 'You',
      avatarUrl: null,
      bio: null,
      status: 'online',
      statusMessage: null,
      lastSeen: null,
      isOnline: true,
      isAdmin: false,
      timezone: 'UTC',
      unreadCount: 0,
      isContact: true,
      isAdminUser: false,
      lastMessage: null,
      lastMessageTime: null,
      lastMessageIsFromMe: null,
    );

    final withSelf = List<LobbyUser>.from(users)..add(syntheticSelfUser);
    return _hydrateSelfUserFromCache(
      users: withSelf,
      currentUserId: currentUserId,
    );
  }

  Future<List<LobbyUser>> _hydrateSelfUserFromCache({
    required List<LobbyUser> users,
    required int currentUserId,
  }) async {
    final selfIndex = users.indexWhere((user) => user.id == currentUserId);
    if (selfIndex == -1) return users;

    final selfUser = users[selfIndex];
    final cachedMessages = await ChatCacheService.loadConversationMessages(
      currentUserId,
      currentUserId,
    );
    if (cachedMessages.isEmpty) return users;

    Message latestMessage = cachedMessages.first;
    for (final candidate in cachedMessages.skip(1)) {
      final candidateTime = candidate.timestampMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(candidate.timestampMs)
          : _parseMessageTime(candidate.timestamp);
      final latestTime = latestMessage.timestampMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(latestMessage.timestampMs)
          : _parseMessageTime(latestMessage.timestamp);
      if (candidateTime.isAfter(latestTime)) {
        latestMessage = candidate;
      }
    }

    final cachedTimestamp = latestMessage.timestamp.trim();
    final hasCurrentPreview = selfUser.lastMessage?.trim().isNotEmpty ?? false;
    final hasCurrentTime = selfUser.lastMessageTime?.trim().isNotEmpty ?? false;
    final shouldUseCachedMessage =
        !hasCurrentPreview ||
        !hasCurrentTime ||
        _parseMessageTime(
          cachedTimestamp,
        ).isAfter(_parseMessageTime(selfUser.lastMessageTime));
    if (!shouldUseCachedMessage) {
      return users;
    }

    final hydratedUsers = List<LobbyUser>.from(users);
    hydratedUsers[selfIndex] = LobbyUser(
      id: selfUser.id,
      username: selfUser.username,
      email: selfUser.email,
      firstName: selfUser.firstName,
      lastName: selfUser.lastName,
      fullName: selfUser.fullName,
      avatarUrl: selfUser.avatarUrl,
      bio: selfUser.bio,
      status: selfUser.status,
      statusMessage: selfUser.statusMessage,
      lastSeen: selfUser.lastSeen,
      isOnline: selfUser.isOnline,
      isAdmin: selfUser.isAdmin,
      timezone: selfUser.timezone,
      unreadCount: 0,
      isContact: selfUser.isContact,
      isAdminUser: selfUser.isAdminUser,
      lastMessage: _previewTextForMessage(latestMessage),
      lastMessageTime: cachedTimestamp,
      lastMessageIsFromMe: true,
    );
    return hydratedUsers;
  }

  String _previewTextForMessage(Message message) {
    switch (message.messageType.toLowerCase()) {
      case 'image':
        return message.fileName?.trim().isNotEmpty == true
            ? '📷 ${message.fileName!.trim()}'
            : '📷 Photo';
      case 'video':
        return message.fileName?.trim().isNotEmpty == true
            ? '🎬 ${message.fileName!.trim()}'
            : '🎬 Video';
      case 'audio':
      case 'voice':
        return '🎤 Voice message';
      case 'file':
      case 'document':
        return message.fileName?.trim().isNotEmpty == true
            ? '📎 ${message.fileName!.trim()}'
            : '📎 File';
      default:
        final trimmedContent = message.content.trim();
        return trimmedContent.isNotEmpty ? trimmedContent : 'No messages yet';
    }
  }

  String _mapConnectivityError(
    Object error, {
    required String offlineLabel,
    required String backendLabel,
  }) {
    final message = error.toString();
    if (error is SocketException ||
        message.contains('SocketException') ||
        message.contains('Failed host lookup')) {
      return offlineLabel;
    }
    if (error is TimeoutException ||
        message.contains('TimeoutException') ||
        message.contains('Connection timed out')) {
      return backendLabel;
    }
    return 'Something went wrong. Please try again in a bit.';
  }

  /// Get the effective status tier: 0=online, 1=away/lastSeen, 2=offline
  int _getStatusTier(LobbyUser user) {
    // Trust explicit online presence first to avoid false "last seen" labels.
    if (user.isOnline) {
      return 0;
    }
    if (user.status == 'online') {
      if (user.lastSeen != null) {
        try {
          final lastSeenTime = _parseUtcTimestamp(user.lastSeen!);
          final age = DateTime.now().difference(lastSeenTime);
          if (age.inMinutes <= 2) return 0;
          return age.inHours < 24 ? 1 : 2;
        } catch (_) {
          return 0;
        }
      }
      return 0;
    }
    if (user.status == 'away') return 1;
    // Recently seen (within 24h) counts as "last seen" tier
    if (user.lastSeen != null) {
      try {
        final lastSeenTime = _parseUtcTimestamp(user.lastSeen!);
        final age = DateTime.now().difference(lastSeenTime);
        if (age.inHours < 24) return 1;
      } catch (_) {}
    }
    return 2;
  }

  DateTime _parseMessageTime(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    try {
      return _parseUtcTimestamp(timestamp);
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  List<LobbyUser> _sortUsersByRecentActivity(List<LobbyUser> users) {
    final sortedUsers = List<LobbyUser>.from(users);
    sortedUsers.sort((a, b) {
      final timeCompare = _parseMessageTime(
        b.lastMessageTime,
      ).compareTo(_parseMessageTime(a.lastMessageTime));
      if (timeCompare != 0) return timeCompare;
      return a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase());
    });
    return sortedUsers;
  }

  /// Builds a time-sorted list of user tiles interleaved with the AI tile,
  /// so the most recently active conversation always rises to the top.
  List<Widget Function()> _buildSortedUserAndAiTileBuilders(
    List<LobbyUser> users, {
    bool includeAi = false,
    bool isOnlineSection = false,
  }) {
    final builders = <Widget Function()>[];

    if (!includeAi) {
      builders.addAll(
        users.map(
          (user) =>
              () => _buildUserTile(user, isOnlineSection: isOnlineSection),
        ),
      );
      return builders;
    }

    final aiTime = _parseMessageTime(_aiLastMessageTime);
    var aiInserted = false;

    for (final user in users) {
      final userTime = _parseMessageTime(user.lastMessageTime);
      if (!aiInserted && aiTime.compareTo(userTime) >= 0) {
        builders.add(_buildAiChatTile);
        aiInserted = true;
      }
      builders.add(
        () => _buildUserTile(user, isOnlineSection: isOnlineSection),
      );
    }

    if (!aiInserted) {
      builders.add(_buildAiChatTile);
    }

    return builders;
  }

  List<Widget Function()> _buildLobbyListItemBuilders(
    List<LobbyUser> selectedUsers,
    String selectedSectionTitle,
    Color selectedSectionColor,
    bool showAiChatTile,
  ) {
    final items = <Widget Function()>[];

    if (_activeFilter == LobbyQuickFilter.groups) {
      if (_filteredGroups.isNotEmpty) {
        items.add(_buildGroupsSectionHeader);
        items.addAll(
          _filteredGroups.map(
            (group) =>
                () => _buildGroupTile(group),
          ),
        );
      }
      return items;
    }

    if (_activeFilter != LobbyQuickFilter.all &&
        _activeFilter != LobbyQuickFilter.groups) {
      items.add(
        () => _buildSectionHeader(
          selectedSectionTitle,
          selectedUsers.length,
          selectedSectionColor,
        ),
      );
    }

    if (_activeFilter == LobbyQuickFilter.all) {
      if (_filteredGroups.isNotEmpty) {
        items.add(_buildGroupsSectionHeader);
        items.addAll(
          _filteredGroups.map(
            (group) =>
                () => _buildGroupTile(group),
          ),
        );
      }
      items.addAll(
        _buildSortedUserAndAiTileBuilders(
          selectedUsers,
          includeAi: showAiChatTile,
        ),
      );
    } else {
      items.addAll(
        _buildSortedUserAndAiTileBuilders(
          selectedUsers,
          includeAi: showAiChatTile,
          isOnlineSection: _activeFilter == LobbyQuickFilter.online,
        ),
      );
    }

    return items;
  }

  List<Group> _sortGroupsByRecentActivity(List<Group> groups) {
    final sortedGroups = List<Group>.from(groups);
    sortedGroups.sort((a, b) {
      final timeCompare = (b.lastMessage?.timestampMs ?? 0).compareTo(
        a.lastMessage?.timestampMs ?? 0,
      );
      if (timeCompare != 0) return timeCompare;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return sortedGroups;
  }

  void _updateFilteredLists() {
    final query = _searchController.text.toLowerCase();

    // Filter users
    final filteredUsers = query.isEmpty
        ? List<LobbyUser>.from(_lobbyUsers)
        : _lobbyUsers.where((user) {
            return user.fullName.toLowerCase().contains(query) ||
                user.username.toLowerCase().contains(query) ||
                user.email.toLowerCase().contains(query) ||
                (user.lastMessage?.toLowerCase().contains(query) ?? false);
          }).toList();

    // Filter groups
    final filteredGroups = query.isEmpty
        ? List<Group>.from(_groups)
        : _groups.where((group) {
            return group.name.toLowerCase().contains(query) ||
                (group.description?.toLowerCase().contains(query) ?? false) ||
                (group.lastMessage?.content.toLowerCase().contains(query) ??
                    false);
          }).toList();

    _filteredUsers = _sortUsersByRecentActivity(filteredUsers);
    _filteredGroups = _sortGroupsByRecentActivity(filteredGroups);
  }

  void _filterUsers() {
    if (!mounted) return;
    setState(_updateFilteredLists);
  }

  Color _getAvatarColor(int index) {
    return avatarColors[index % avatarColors.length];
  }

  /// The current user's own entry in the lobby (the self/note-to-self chat),
  /// if it has already been loaded. Used to render the self FAB avatar.
  LobbyUser? get _selfUser {
    final id = _socketService.currentUserId;
    if (id == null) return null;
    for (final user in _lobbyUsers) {
      if (user.id == id) return user;
    }
    return null;
  }

  /// Floating button for AI Chat, styled to match the gradient bot avatar used
  /// in the lobby list (teal -> purple), rather than a flat fill.
  Widget _buildAiFab() {
    return SizedBox(
      width: 40,
      height: 40,
      child: Material(
        elevation: 4,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        color: Colors.transparent,
        child: Ink(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF00C9A7), Color(0xFF845EC2)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
          ),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AiChatScreen()),
              ).then((_) {
                _loadAiSessionPresence();
                _loadLobby(useCacheFirst: false);
              });
            },
            child: const Icon(
              Icons.smart_toy_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }

  /// Floating button that jumps straight into the chat with yourself, styled
  /// with your own avatar initials/color (same avatar as in the chat list).
  Widget _buildSelfFab() {
    final self = _selfUser;
    final initials = (self != null && self.initials.isNotEmpty)
        ? self.initials
        : 'You';
    const color = Color(0xFF475569); // slate gray
    return FloatingActionButton.small(
      heroTag: 'fab_self',
      tooltip: 'Message yourself',
      onPressed: _openSelfChat,
      backgroundColor: color,
      foregroundColor: Colors.white,
      elevation: 4,
      shape: const CircleBorder(),
      child: Text(
        initials,
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 12,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  /// Open the chat with yourself, ensuring the self user exists in the lobby
  /// first (so it works even before the list has hydrated it).
  Future<void> _openSelfChat() async {
    final id = _socketService.currentUserId ?? await _currentUserId;
    if (id == null || !mounted) return;

    LobbyUser? selfUser;
    for (final user in _lobbyUsers) {
      if (user.id == id) {
        selfUser = user;
        break;
      }
    }

    if (selfUser == null) {
      final username = await StorageService.getUsername();
      final withSelf = await _ensureSelfUserInLobby(
        users: _lobbyUsers,
        currentUserId: id,
        currentUsername: username,
      );
      for (final user in withSelf) {
        if (user.id == id) {
          selfUser = user;
          break;
        }
      }
    }

    if (selfUser == null || !mounted) return;
    final target = selfUser;

    _openChat(
      target,
      callInProgress: false,
      onReturn: () async => _loadLobby(useCacheFirst: false),
    );
  }

  /// Parse a timestamp string, treating it as UTC if no timezone info is present
  /// (matches the web app's parseTs() behavior)
  DateTime _parseUtcTimestamp(String timestamp) {
    final hasTimezone = RegExp(r'[zZ]|[+-]\d{2}:?\d{2}$').hasMatch(timestamp);
    final parsed = DateTime.parse(hasTimezone ? timestamp : '${timestamp}Z');
    return parsed.toLocal();
  }

  String _weekdayShort(int weekday) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[(weekday - 1).clamp(0, 6)];
  }

  String _formatTime(String? lastSeen) {
    if (lastSeen == null) return '';
    try {
      final dateTime = _parseUtcTimestamp(lastSeen);
      final now = DateTime.now();
      final difference = now.difference(dateTime);

      final hour = dateTime.hour;
      final minute = dateTime.minute.toString().padLeft(2, '0');
      final period = hour >= 12 ? 'PM' : 'AM';
      final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
      final timeStr = '$displayHour:$minute $period';

      if (difference.inMinutes < 1) return 'Just now';
      if (difference.inHours < 1) return '${difference.inMinutes}m ago';

      final todayStart = DateTime(now.year, now.month, now.day);
      final yesterdayStart = todayStart.subtract(const Duration(days: 1));

      if (!dateTime.isBefore(todayStart)) return timeStr;
      if (!dateTime.isBefore(yesterdayStart)) return 'Yesterday $timeStr';
      if (difference.inDays < 7)
        return '${_weekdayShort(dateTime.weekday)} $timeStr';
      return '${dateTime.month}/${dateTime.day}';
    } catch (e) {
      return '';
    }
  }

  /// Format last seen as relative time for status display (e.g., "Last seen 5m ago")
  String _formatRelativeTime(String? lastSeen) {
    if (lastSeen == null) return 'Offline';
    try {
      final dateTime = _parseUtcTimestamp(lastSeen);
      final now = DateTime.now();
      final difference = now.difference(dateTime);

      if (difference.inMinutes < 1) return 'Last seen just now';
      if (difference.inMinutes < 60) {
        final mins = difference.inMinutes;
        return 'Last seen ${mins}m ago';
      }
      if (difference.inHours < 24) {
        final hours = difference.inHours;
        return 'Last seen ${hours}h ago';
      }
      if (difference.inDays == 1) return 'Last seen yesterday';
      if (difference.inDays < 7) return 'Last seen ${difference.inDays}d ago';
      return 'Last seen ${dateTime.month}/${dateTime.day}';
    } catch (e) {
      return 'Offline';
    }
  }

  void _openNewChatPicker() {
    final currentId = _socketService.currentUserId;
    // Show all known contacts except current user (they can "message yourself" via the tile)
    final contacts = _lobbyUsers.where((u) => u.id != currentId).toList();

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, scrollController) {
            return Column(
              children: [
                // Handle bar
                Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[600],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      Text(
                        'New Chat',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Color(0xFF2D2D4E), height: 1),
                Expanded(
                  child: contacts.isEmpty
                      ? Center(
                          child: Text(
                            'No contacts yet',
                            style: TextStyle(color: Colors.grey[500]),
                          ),
                        )
                      : ListView.builder(
                          controller: scrollController,
                          physics: const ChatScrollPhysics(
                            parent: AlwaysScrollableScrollPhysics(),
                          ),
                          cacheExtent: 900,
                          addAutomaticKeepAlives: false,
                          addRepaintBoundaries: true,
                          itemCount: contacts.length,
                          itemBuilder: (_, index) {
                            final user = contacts[index];
                            final avatarColor = _getAvatarColor(
                              user.avatarColorIndex,
                            );
                            final s = _compactScale(context);
                            return ListTile(
                              dense: true,
                              visualDensity: const VisualDensity(
                                horizontal: -1,
                                vertical: -2,
                              ),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: _cs(context, 20),
                                vertical: _cs(context, 2),
                              ),
                              leading: CircleAvatar(
                                radius: _cs(context, 22),
                                backgroundColor: avatarColor,
                                child: user.avatarUrl != null
                                    ? ClipOval(
                                        child: CachedImage(
                                          url: user.avatarUrl!,
                                          width: _cs(context, 44),
                                          height: _cs(context, 44),
                                          fit: BoxFit.cover,
                                          placeholderColor: avatarColor,
                                          errorWidget: Text(
                                            user.initials,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 13 * s,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      )
                                    : Text(
                                        user.initials,
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 13 * s,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                              ),
                              title: Text(
                                user.fullName,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14 * s,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              subtitle: Text(
                                user.isOnline ? 'Online' : 'Offline',
                                style: TextStyle(
                                  color: user.isOnline
                                      ? const Color(0xFF00E676)
                                      : Colors.grey[500],
                                  fontSize: 11 * s,
                                ),
                              ),
                              trailing: user.isOnline
                                  ? Icon(
                                      Icons.circle,
                                      color: Color(0xFF00E676),
                                      size: _cs(context, 10),
                                    )
                                  : null,
                              onTap: () {
                                Navigator.pop(ctx);
                                _openChat(
                                  user,
                                  onReturn: () async {
                                    _loadLobby(useCacheFirst: false);
                                    _setupRealtimeListeners();
                                  },
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2D2D2D),
        title: const Text('Logout', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to logout?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Logout', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      await AuthService.logout();
      if (mounted) {
        Navigator.pushReplacementNamed(context, SignInPage.route);
      }
    }
  }

  int _activeFilterIndex() {
    switch (_activeFilter) {
      case LobbyQuickFilter.all:
        return 0;
      case LobbyQuickFilter.online:
        return 1;
      case LobbyQuickFilter.groups:
        return 2;
      case LobbyQuickFilter.alarmX:
        return 3;
    }
  }

  double _compactScale(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = media.size.width;
    final dpr = media.devicePixelRatio;

    var scale = 1.0;
    if (width >= 480) {
      scale *= 0.82;
    } else if (width >= 430) {
      scale *= 0.86;
    } else if (width >= 390) {
      scale *= 0.90;
    } else if (width >= 360) {
      scale *= 0.95;
    }

    if (dpr >= 4.0) {
      scale *= 0.94;
    } else if (dpr >= 3.5) {
      scale *= 0.96;
    }

    return scale.clamp(0.80, 1.0);
  }

  double _cs(BuildContext context, double value) {
    return value * _compactScale(context);
  }

  void _setActiveFilter(int index) {
    setState(() {
      switch (index) {
        case 0:
          _activeFilter = LobbyQuickFilter.all;
          break;
        case 1:
          _activeFilter = LobbyQuickFilter.online;
          break;
        case 2:
          _activeFilter = LobbyQuickFilter.groups;
          break;
        case 3:
          _activeFilter = LobbyQuickFilter.alarmX;
          final pomService = PomodoroService();
          pomService.addLog('Opened Not Pomodoro Suite', 'navigation');
          break;
      }
    });
  }

  Widget _buildSectionHeader(String title, int count, Color color) {
    final s = _compactScale(context);
    return Padding(
      padding: EdgeInsets.only(
        left: _cs(context, 16),
        right: _cs(context, 16),
        top: _cs(context, 16),
        bottom: _cs(context, 6),
      ),
      child: Row(
        children: [
          Container(
            width: _cs(context, 8),
            height: _cs(context, 8),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          SizedBox(width: _cs(context, 8)),
          Text(
            title,
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 12 * s,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          SizedBox(width: _cs(context, 6)),
          Text(
            '($count)',
            style: TextStyle(color: Colors.grey[600], fontSize: 11 * s),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupsSectionHeader() {
    final s = _compactScale(context);
    return Padding(
      padding: EdgeInsets.only(
        left: _cs(context, 16),
        right: _cs(context, 16),
        top: _cs(context, 16),
        bottom: _cs(context, 6),
      ),
      child: Row(
        children: [
          Container(
            width: _cs(context, 8),
            height: _cs(context, 8),
            decoration: const BoxDecoration(
              color: Color(0xFF00D9FF),
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: _cs(context, 8)),
          Text(
            'GROUPS',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 12 * s,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          SizedBox(width: _cs(context, 6)),
          Text(
            '(${_filteredGroups.length})',
            style: TextStyle(color: Colors.grey[600], fontSize: 11 * s),
          ),
          const Spacer(),
          // Create group button (only for admin users)
          if (_isCurrentUserAdmin)
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () async {
                  final result = await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const CreateGroupScreen(),
                    ),
                  );
                  if (result == true) {
                    _loadLobby(useCacheFirst: false);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00D9FF).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFF00D9FF).withOpacity(0.3),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.add, color: Color(0xFF00D9FF), size: 16),
                      const SizedBox(width: 4),
                      Text(
                        'Create',
                        style: const TextStyle(
                          color: Color(0xFF00D9FF),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            // Show admin-only indicator for non-admin users
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.admin_panel_settings,
                    color: Colors.grey[500],
                    size: 12,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Admin only',
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildShimmerTile() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF252542),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          // Avatar placeholder
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.grey[800],
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 120,
                  height: 14,
                  decoration: BoxDecoration(
                    color: Colors.grey[800],
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 80,
                  height: 10,
                  decoration: BoxDecoration(
                    color: Colors.grey[850],
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 160,
                  height: 10,
                  decoration: BoxDecoration(
                    color: Colors.grey[850],
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingPlaceholder() {
    return ListView.builder(
      itemCount: 8,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      physics: const ChatScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      itemBuilder: (_, __) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: _buildShimmerTile(),
        );
      },
    );
  }

  /// Opens a 1:1 conversation. In the desktop two-pane layout this selects the
  /// chat in the detail pane; otherwise it pushes a full-screen route (the
  /// historical mobile behavior). [onReturn] runs after the pushed route is
  /// popped; it is ignored in two-pane mode where there is nothing to pop.
  void _openChat(
    LobbyUser user, {
    bool? callInProgress,
    Future<void> Function()? onReturn,
  }) {
    final inCall =
        callInProgress ??
        _crossDeviceActiveCallRoomByUserId.containsKey(user.id);
    _currentlyViewingChatUserId = user.id;

    if (_isTwoPaneLayout) {
      setState(() => _selectedChatUser = user);
      // The conversation is now visible beside the list, so run the "opened"
      // side-effects (clear unread badge, mark messages read) immediately
      // instead of waiting for a route to pop.
      if (onReturn != null) unawaited(onReturn());
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          otherUser: user,
          initialCallInProgressOnOtherDevice: inCall,
        ),
      ),
    ).then((_) async {
      _currentlyViewingChatUserId = null;
      if (onReturn != null) {
        await onReturn();
      } else {
        _loadLobby(useCacheFirst: false);
      }
    });
  }

  /// The right-hand detail pane in the desktop two-pane layout.
  Widget _buildChatDetailPane() {
    final user = _selectedChatUser;
    if (user == null) {
      return Container(
        color: const Color(0xFF15152A),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.forum_outlined,
                size: 72,
                color: Colors.white.withValues(alpha: 0.15),
              ),
              const SizedBox(height: 16),
              Text(
                'Select a conversation',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Pick someone from the list to start chatting',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ChatScreen(
      // Rebuild the chat state when the selected conversation changes.
      key: ValueKey('desktop-chat-${user.id}'),
      otherUser: user,
      embedded: true,
      initialCallInProgressOnOtherDevice: _crossDeviceActiveCallRoomByUserId
          .containsKey(user.id),
    );
  }

  /// A single rounded pill button for the desktop top bar (web-style chrome).
  Widget _topBarPill({
    required Widget child,
    required Color color,
    VoidCallback? onTap,
    double? width,
    bool expand = false,
  }) {
    Widget content = Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: child,
    );
    if (onTap != null) {
      content = Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: content,
        ),
      );
    }
    return expand ? Expanded(child: content) : content;
  }

  /// The web-style top bar shown only on desktop: CHATX title plus the
  /// Alarm / Client URL / Version / Settings / Logout pills.
  Widget _buildDesktopTopBar() {
    const labelStyle = TextStyle(
      color: Colors.white,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    );
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Color(0xFF121212),
        border: Border(bottom: BorderSide(color: Color(0xFF374151))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          _topBarPill(
            width: 170,
            color: const Color(0xFF0F172A),
            child: const Text(
              'CHATX',
              style: TextStyle(
                color: Color(0xFFF1F5F9),
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 10),
          _topBarPill(
            color: const Color(0xFF7C3AED),
            onTap: () => _setActiveFilter(3),
            child: const Text('Alarm', style: labelStyle),
          ),
          const SizedBox(width: 10),
          _topBarPill(
            expand: true,
            color: const Color(0xFF3730A3),
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: ApiConfig.baseUrl));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Client URL copied')),
              );
            },
            child: Text(
              'Client: ${ApiConfig.baseUrl}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          ),
          const SizedBox(width: 10),
          _topBarPill(
            color: const Color(0xFF065F46),
            child: FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) => Text(
                snapshot.hasData
                    ? 'App Version: ${snapshot.data!.version}'
                    : 'App Version: …',
                style: labelStyle,
              ),
            ),
          ),
          const SizedBox(width: 10),
          _topBarPill(
            color: const Color(0xFFB45309),
            onTap: () async {
              final result = await showDialog<bool>(
                context: context,
                builder: (context) => const SettingsModal(),
              );
              if (result == true && mounted) setState(() {});
            },
            child: const Text('Settings', style: labelStyle),
          ),
          const SizedBox(width: 10),
          _topBarPill(
            color: const Color(0xFFDC2626),
            onTap: _handleLogout,
            child: const Text('Logout', style: labelStyle),
          ),
        ],
      ),
    );
  }

  /// Compact filter chips for the desktop sidebar, replacing the bottom nav
  /// (which is hidden on desktop). Alarm X lives in the top bar instead.
  Widget _buildDesktopFilterChips() {
    Widget chip(String label, LobbyQuickFilter filter, Color color, int index) {
      final selected = _activeFilter == filter;
      return Expanded(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _setActiveFilter(index),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? color.withValues(alpha: 0.18)
                    : const Color(0xFF1F1F33),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? color : Colors.transparent,
                  width: 1.4,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? color : Colors.white70,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          chip('Chats', LobbyQuickFilter.all, const Color(0xFF00D9FF), 0),
          const SizedBox(width: 8),
          chip('Online', LobbyQuickFilter.online, const Color(0xFF00E676), 1),
          const SizedBox(width: 8),
          chip('Groups', LobbyQuickFilter.groups, const Color(0xFF00D9FF), 2),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Split users into status tiers for quick filter tabs.
    final onlineUsers = _filteredUsers
        .where((u) => _getStatusTier(u) == 0)
        .toList();
    final offlineUsers = _filteredUsers
        .where((u) => _getStatusTier(u) != 0)
        .toList();

    final selectedUsers = switch (_activeFilter) {
      LobbyQuickFilter.all => _filteredUsers,
      LobbyQuickFilter.online => onlineUsers,
      LobbyQuickFilter.groups => const <LobbyUser>[],
      LobbyQuickFilter.alarmX => const <LobbyUser>[],
    };

    final selectedSectionTitle = switch (_activeFilter) {
      LobbyQuickFilter.all => 'CHATS',
      LobbyQuickFilter.online => 'ONLINE',
      LobbyQuickFilter.groups => 'GROUPS',
      LobbyQuickFilter.alarmX => 'ALARM X',
    };

    final selectedSectionColor = switch (_activeFilter) {
      LobbyQuickFilter.all => const Color(0xFF00D9FF),
      LobbyQuickFilter.online => const Color(0xFF00E676),
      LobbyQuickFilter.groups => const Color(0xFF00D9FF),
      LobbyQuickFilter.alarmX => Colors.orange,
    };

    final isFilterEmpty = _activeFilter == LobbyQuickFilter.all
        ? _filteredUsers.isEmpty && _filteredGroups.isEmpty
        : _activeFilter == LobbyQuickFilter.groups
        ? _filteredGroups.isEmpty
        : selectedUsers.isEmpty;

    final query = _searchController.text.trim().toLowerCase();
    final aiKeywords = <String>['ask ai', 'ai', 'assistant', 'ai chat'];
    final aiMatchesQuery =
        query.isEmpty || aiKeywords.any((keyword) => keyword.contains(query));
    final showAiChatTile =
        (_activeFilter == LobbyQuickFilter.all ||
            _activeFilter == LobbyQuickFilter.online) &&
        aiMatchesQuery;
    final hasVisibleResults = !isFilterEmpty || showAiChatTile;
    final lobbyItemBuilders = _buildLobbyListItemBuilders(
      selectedUsers,
      selectedSectionTitle,
      selectedSectionColor,
      showAiChatTile,
    );

    // On desktop the web-style top bar (built in the LayoutBuilder below)
    // replaces the mobile app bar + bottom navigation, so suppress those here.
    final bool isDesktop =
        MediaQuery.sizeOf(context).width >= _kDesktopTwoPaneBreakpoint;

    final Widget lobbyPane = Scaffold(
      // Web sidebar uses a near-black background (#121212); mobile keeps navy.
      backgroundColor: isDesktop
          ? const Color(0xFF121212)
          : const Color(0xFF1A1A2E),
      appBar: isDesktop
          ? null
          : AppBar(
              backgroundColor: const Color(0xFF1A1A2E),
              elevation: 0,
              centerTitle: true,
              leading: _buildDeferredUpdateIndicator(),
              title: const AppVersionText(),
              actions: [
                PopupMenuButton<String>(
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16.0),
                    child: Center(
                      child: Text(
                        'Settings',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  color: const Color(0xFF252542),
                  onSelected: (value) async {
                    if (value == 'settings') {
                      final result = await showDialog<bool>(
                        context: context,
                        builder: (context) => const SettingsModal(),
                      );
                      if (result == true && mounted) {
                        setState(() {});
                      }
                    } else if (value == 'logout') {
                      _handleLogout();
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem<String>(
                      value: 'settings',
                      child: Text(
                        'Settings',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'logout',
                      child: Text(
                        'Logout',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ],
            ),
      body: Column(
        children: [
          // Desktop filter chips (the bottom nav is hidden on desktop).
          if (isDesktop && _activeFilter != LobbyQuickFilter.alarmX)
            _buildDesktopFilterChips(),
          // Search bar
          if (_activeFilter != LobbyQuickFilter.alarmX)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 8.0,
              ),
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search conversations or Ask AI',
                  hintStyle: TextStyle(color: Colors.grey[500]),
                  prefixIcon: Icon(Icons.search, color: Colors.grey[500]),
                  suffixIcon: _showAiSuggestion
                      ? Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: TextButton.icon(
                            onPressed: () {
                              final query = _searchController.text.trim();
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      AiChatScreen(initialPrompt: query),
                                ),
                              ).then((_) {
                                _loadAiSessionPresence();
                                _loadLobby(useCacheFirst: false);
                              });
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF00D9FF),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: const Icon(Icons.auto_awesome, size: 16),
                            label: const Text(
                              'Ask AI',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                        )
                      : null,
                  suffixIconConstraints: const BoxConstraints(
                    minWidth: 0,
                    minHeight: 0,
                  ),
                  filled: true,
                  fillColor: const Color(0xFF252542),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
              ),
            ),
          Expanded(
            child: _activeFilter == LobbyQuickFilter.alarmX
                ? const PomodoroView()
                : (_isLoading && _lobbyUsers.isEmpty && _groups.isEmpty)
                ? _buildLoadingPlaceholder()
                : !hasVisibleResults
                ? Center(
                    child: Text(
                      _searchController.text.isEmpty
                          ? _activeFilter == LobbyQuickFilter.all
                                ? 'No chats yet'
                                : 'No ${selectedSectionTitle.toLowerCase()} yet'
                          : 'No results found',
                      style: TextStyle(color: Colors.grey[500], fontSize: 16),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: () => _loadLobby(useCacheFirst: false),
                    color: const Color(0xFF00D9FF),
                    backgroundColor: const Color(0xFF252542),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      physics: const ChatScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      cacheExtent: MediaQuery.sizeOf(context).height * 2,
                      addAutomaticKeepAlives: false,
                      addRepaintBoundaries: true,
                      itemCount: lobbyItemBuilders.length,
                      itemBuilder: (context, index) {
                        return lobbyItemBuilders[index]();
                      },
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: (_activeFilter == LobbyQuickFilter.alarmX)
          ? null
          : (_activeFilter != LobbyQuickFilter.groups)
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Self (message yourself) mini FAB
                _buildSelfFab(),
                const SizedBox(height: 12),
                // AI Chat mini FAB (matches the lobby list's gradient bot avatar)
                _buildAiFab(),
                const SizedBox(height: 12),
                // New Chat main FAB
                FloatingActionButton(
                  heroTag: 'fab_chat',
                  onPressed: _openNewChatPicker,
                  backgroundColor: const Color(0xFF4C1D95),
                  foregroundColor: Colors.white,
                  elevation: 6,
                  shape: const CircleBorder(),
                  child: const Icon(Icons.chat_rounded, size: 26),
                ),
              ],
            )
          : (_isCurrentUserAdmin
                ? FloatingActionButton(
                    heroTag: 'fab_group',
                    onPressed: () async {
                      final result = await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const CreateGroupScreen(),
                        ),
                      );
                      if (result == true) {
                        _loadLobby(useCacheFirst: false);
                      }
                    },
                    backgroundColor: const Color(0xFF4C1D95),
                    foregroundColor: Colors.white,
                    elevation: 6,
                    shape: const CircleBorder(),
                    child: const Icon(Icons.group_add_rounded, size: 26),
                  )
                : null),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: isDesktop
          ? null
          : NavigationBar(
              backgroundColor: const Color(0xFF1A1A2E),
              indicatorColor: const Color(0xFF252542),
              selectedIndex: _activeFilterIndex(),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              onDestinationSelected: _setActiveFilter,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard, color: Color(0xFF00D9FF)),
                  label: 'Chats',
                ),
                NavigationDestination(
                  icon: Icon(Icons.circle_outlined),
                  selectedIcon: Icon(Icons.circle, color: Color(0xFF00E676)),
                  label: 'Online',
                ),
                NavigationDestination(
                  icon: Icon(Icons.groups_outlined),
                  selectedIcon: Icon(Icons.groups, color: Color(0xFF00D9FF)),
                  label: 'Groups',
                ),
                NavigationDestination(
                  icon: Icon(Icons.alarm_outlined),
                  selectedIcon: Icon(Icons.alarm, color: Colors.orange),
                  label: 'Alarm X',
                ),
              ],
            ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= _kDesktopTwoPaneBreakpoint;
        // The Alarm X (Not Pomodoro) suite needs the full width — don't squeeze
        // it into the narrow sidebar, so only show the chat detail pane when not
        // on the Alarm X tab.
        final twoPane = desktop && _activeFilter != LobbyQuickFilter.alarmX;
        // Keep tap handlers in sync with the active layout. Safe to set here
        // (no rebuild needed) because the layout below already uses `twoPane`.
        _isTwoPaneLayout = twoPane;

        // Mobile keeps its app bar + bottom navigation inside lobbyPane.
        if (!desktop) {
          return lobbyPane;
        }

        // Desktop: web-style top bar above the content. When a 1:1 chat tab is
        // active we show the conversation list beside the chat detail pane;
        // Alarm X takes the full width.
        final Widget content = twoPane
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: _kDesktopSidebarWidth, child: lobbyPane),
                  // Web sidebar's purple right border (2px #420796).
                  const VerticalDivider(
                    width: 2,
                    thickness: 2,
                    color: Color(0xFF420796),
                  ),
                  Expanded(child: _buildChatDetailPane()),
                ],
              )
            : lobbyPane;

        return Scaffold(
          backgroundColor: const Color(0xFF121212),
          body: Column(
            children: [
              _buildDesktopTopBar(),
              Expanded(child: content),
            ],
          ),
        );
      },
    );
  }

  /// Determine effective display status: online, away, or offline
  /// Matches the web app's recently-seen logic (yellow dot for offline users
  /// who were active within the last 24 hours)
  /// Also validates 'online' status against last_seen to detect stale DB entries
  String _getEffectiveStatus(LobbyUser user) {
    // Trust explicit online presence first to stay consistent with in-chat header.
    if (user.isOnline) {
      return 'online';
    }
    if (user.status == 'online') {
      if (user.lastSeen != null) {
        try {
          final lastSeenTime = _parseUtcTimestamp(user.lastSeen!);
          final age = DateTime.now().difference(lastSeenTime);
          if (age.inMinutes <= 2) return 'online';
          return age.inHours < 24 ? 'away' : 'offline';
        } catch (_) {
          return 'online';
        }
      }
      return 'online';
    }
    if (user.status == 'away') return 'away';
    // Check if recently seen (within 24 hours) → show as away
    if (user.lastSeen != null) {
      try {
        final lastSeenTime = _parseUtcTimestamp(user.lastSeen!);
        final age = DateTime.now().difference(lastSeenTime);
        if (age.inHours < 24) return 'away';
      } catch (_) {}
    }
    return 'offline';
  }

  /// Get status dot color: green=online, yellow=away, grey=offline
  Color _getStatusDotColor(String effectiveStatus) {
    switch (effectiveStatus) {
      case 'online':
        return const Color(0xFF00E676); // neon green
      case 'away':
        return const Color(0xFFFFC107); // yellow/amber
      default:
        return Colors.grey[600]!; // grey
    }
  }

  void _handleCallSessionStateForLobby(Map<String, dynamic> data) {
    final currentUserId = _socketService.currentUserId;
    if (currentUserId == null || !mounted) return;

    final state =
        (data['state']?.toString() ?? data['status']?.toString() ?? '')
            .toLowerCase();
    if (state.isEmpty) return;

    final roomId =
        data['call_room_id']?.toString() ?? data['room']?.toString() ?? '';
    final actorUserId = _toInt(data['actor_user_id']);
    final otherUserId = _extractOtherParticipantIdFromSessionState(data);

    final isTerminal =
        state == 'ended' || state == 'declined' || state == 'cancelled';

    // The current user is in an accepted call on ANOTHER device whenever this
    // device isn't the one in the call. The actor of 'accepted' is whoever
    // answered, which is the OTHER party when the current user is the caller —
    // so requiring actorUserId == currentUserId only covered "answered on my
    // other device" and missed "I called from my other device (e.g. web)".
    final participantIds = data['participant_ids'];
    final currentUserIsParticipant =
        actorUserId == currentUserId ||
        _toInt(data['caller_id']) == currentUserId ||
        _toInt(data['callee_id']) == currentUserId ||
        (participantIds is List &&
            participantIds.map((e) => _toInt(e)).contains(currentUserId));

    final isAcceptedForCurrentUserElsewhere =
        state == 'accepted' &&
        currentUserIsParticipant &&
        otherUserId != null &&
        !PresenceService().isCallInProgress;

    // A deferred cross-room incoming call is no longer answerable once it ends,
    // is declined, or is accepted elsewhere — clear its ringing indicator.
    if (isTerminal || isAcceptedForCurrentUserElsewhere) {
      PendingIncomingCallService().clearIfMatches(
        callRoomId: roomId.isEmpty ? null : roomId,
        callerId: otherUserId,
      );
    }

    if (isAcceptedForCurrentUserElsewhere) {
      setState(() {
        _crossDeviceActiveCallRoomByUserId[otherUserId] = roomId;
      });
      _clearIncomingCallNotificationsForEvent(data);
      return;
    }

    if (isTerminal) {
      // A declined/ended/cancelled call must dismiss the incoming-call FCM/local
      // notification too. The server echoes the terminal call_session_state to
      // BOTH participants' personal rooms, so this clears the notification whether
      // the call was declined on web or on this mobile (and on call end).
      _clearIncomingCallNotificationsForEvent(data);

      if (roomId.isEmpty) {
        setState(() {
          _crossDeviceActiveCallRoomByUserId.clear();
        });
        return;
      }

      if (otherUserId != null &&
          _crossDeviceActiveCallRoomByUserId.containsKey(otherUserId)) {
        final trackedRoom = _crossDeviceActiveCallRoomByUserId[otherUserId];
        if (trackedRoom == null || trackedRoom == roomId) {
          setState(() {
            _crossDeviceActiveCallRoomByUserId.remove(otherUserId);
          });
          return;
        }
      }

      if (roomId.isNotEmpty) {
        final toRemove = <int>[];
        _crossDeviceActiveCallRoomByUserId.forEach((uid, trackedRoom) {
          if (trackedRoom == roomId) {
            toRemove.add(uid);
          }
        });
        if (toRemove.isNotEmpty) {
          setState(() {
            for (final uid in toRemove) {
              _crossDeviceActiveCallRoomByUserId.remove(uid);
            }
          });
        }
      }
    }
  }

  int? _extractOtherParticipantIdFromSessionState(Map<String, dynamic> data) {
    final currentUserId = _socketService.currentUserId;
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

  Widget _buildGroupTile(Group group) {
    final s = _compactScale(context);
    final lastMessageText = group.lastMessage?.content ?? 'No messages yet';
    final lastMessageTime = group.lastMessage?.formattedTime ?? '';

    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: _cs(context, 12),
        vertical: _cs(context, 4),
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF252542),
        borderRadius: BorderRadius.circular(_cs(context, 12)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(_cs(context, 12)),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => GroupChatScreen(group: group),
              ),
            );
          },
          child: Padding(
            padding: EdgeInsets.all(_cs(context, 12)),
            child: Row(
              children: [
                // Group avatar
                CircleAvatar(
                  radius: _cs(context, 26),
                  backgroundColor: const Color(0xFF00D9FF),
                  child: group.avatarUrl != null
                      ? ClipOval(
                          child: CachedImage(
                            url: group.avatarUrl!,
                            width: _cs(context, 52),
                            height: _cs(context, 52),
                            fit: BoxFit.cover,
                            placeholderColor: const Color(0xFF00D9FF),
                            errorWidget: Icon(
                              Icons.group,
                              color: Colors.white,
                              size: _cs(context, 26),
                            ),
                          ),
                        )
                      : Icon(
                          Icons.group,
                          color: Colors.white,
                          size: _cs(context, 26),
                        ),
                ),
                SizedBox(width: _cs(context, 12)),
                // Group info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Group name
                      Text(
                        group.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: _cs(context, 2)),
                      // Member count
                      Text(
                        '${group.memberCount} members',
                        style: TextStyle(
                          color: Colors.grey[500],
                          fontSize: 13 * s,
                        ),
                      ),
                      SizedBox(height: _cs(context, 2)),
                      // Last message preview
                      Text(
                        lastMessageText,
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 12 * s,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // Time + Unread badge column
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Last message time
                    if (lastMessageTime.isNotEmpty)
                      Text(
                        lastMessageTime,
                        style: TextStyle(
                          color: Colors.grey[500],
                          fontSize: 11 * s,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUserTile(LobbyUser user, {bool isOnlineSection = false}) {
    final s = _compactScale(context);
    final avatarColor = _getAvatarColor(user.avatarColorIndex);
    final effectiveStatus = _getEffectiveStatus(user);
    final hasCrossDeviceCall = _crossDeviceActiveCallRoomByUserId.containsKey(
      user.id,
    );
    // A cross-room incoming call from this user was deferred (it arrived while we
    // were viewing another chat). Show a ringing indicator; tapping the tile
    // opens the chat and surfaces the incoming-call modal.
    final hasPendingIncomingCall =
        PendingIncomingCallService().pendingCallerId == user.id;
    final isSelfChatTile = user.id == _socketService.currentUserId;
    final displayUnreadCount = isSelfChatTile ? 0 : user.unreadCount;
    // Highlight the conversation currently open in the desktop detail pane so the
    // two-pane layout makes clear which chat the right side is showing.
    final isSelected = _isTwoPaneLayout && _selectedChatUser?.id == user.id;

    // Get last message preview
    String _getLastMessagePreview() {
      if (user.lastMessage != null && user.lastMessage!.isNotEmpty) {
        final prefix = user.lastMessageIsFromMe == true ? 'You: ' : '';
        final message = user.lastMessage!.length > 25
            ? '${user.lastMessage!.substring(0, 25)}...'
            : user.lastMessage!;
        final checkmark = user.lastMessageIsFromMe == true ? ' ✓' : '';
        return '$prefix$message$checkmark';
      }
      return 'No messages yet';
    }

    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: _cs(context, 12),
        vertical: _cs(context, 4),
      ),
      decoration: BoxDecoration(
        color: hasPendingIncomingCall
            ? const Color(0xFF3A2E1A)
            : isSelected
            ? const Color(0xFF2E2E5C)
            : const Color(0xFF252542),
        borderRadius: BorderRadius.circular(_cs(context, 12)),
        border: hasPendingIncomingCall
            ? Border.all(color: const Color(0xFFF59E0B), width: 2)
            : isSelected
            ? Border.all(color: const Color(0xFF00D9FF), width: 1.5)
            : null,
        // Amber glow while an incoming call from this user is deferred.
        boxShadow: hasPendingIncomingCall
            ? [
                BoxShadow(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.55),
                  blurRadius: 14,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(_cs(context, 12)),
          onTap: () {
            // Open the chat (detail pane on desktop, full-screen on mobile).
            _openChat(
              user,
              onReturn: () async {
                // Immediately clear unread badge for this user in local state
                // so it doesn't flash briefly while the server reload is in progress
                setState(() {
                  final userIndex = _lobbyUsers.indexWhere(
                    (u) => u.id == user.id,
                  );
                  if (userIndex != -1) {
                    final u = _lobbyUsers[userIndex];
                    _lobbyUsers[userIndex] = LobbyUser(
                      id: u.id,
                      username: u.username,
                      email: u.email,
                      firstName: u.firstName,
                      lastName: u.lastName,
                      fullName: u.fullName,
                      avatarUrl: u.avatarUrl,
                      bio: u.bio,
                      status: u.status,
                      statusMessage: u.statusMessage,
                      lastSeen: u.lastSeen,
                      isOnline: u.isOnline,
                      isAdmin: u.isAdmin,
                      timezone: u.timezone,
                      unreadCount: 0,
                      isContact: u.isContact,
                      isAdminUser: u.isAdminUser,
                      lastMessage: u.lastMessage,
                      lastMessageTime: u.lastMessageTime,
                      lastMessageIsFromMe: u.lastMessageIsFromMe,
                    );
                  }
                });

                // Mark messages from this user as read via REST (fallback for any
                // messages the socket handler may have missed while offline)
                try {
                  final token = await StorageService.getToken();
                  if (token != null) {
                    // Find the most recent message ID (use a large int as sentinel)
                    await http.post(
                      Uri.parse(ApiConfig.markReadUrl),
                      headers: {
                        'Content-Type': 'application/json',
                        'Authorization': 'Bearer $token',
                      },
                      body: jsonEncode({
                        'sender_id': user.id,
                        'last_message_id':
                            2147483647, // INT_MAX — marks ALL messages
                      }),
                    );
                  }
                } catch (e) {
                  debugPrint('[LOBBY] mark-read REST fallback failed: $e');
                }
                // Reload lobby and restore socket listeners when returning from chat
                _loadLobby(useCacheFirst: false);
                _setupRealtimeListeners();
              },
            );
          },
          child: Padding(
            padding: EdgeInsets.all(_cs(context, 12)),
            child: Row(
              children: [
                // Avatar with online indicator
                Stack(
                  children: [
                    CircleAvatar(
                      radius: _cs(context, 26),
                      backgroundColor: avatarColor,
                      child: user.avatarUrl != null
                          ? ClipOval(
                              child: CachedImage(
                                url: user.avatarUrl!,
                                width: _cs(context, 52),
                                height: _cs(context, 52),
                                fit: BoxFit.cover,
                                placeholderColor: avatarColor,
                                errorWidget: Text(
                                  user.initials,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18 * s,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            )
                          : Text(
                              user.initials,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18 * s,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                    // Status indicator dot (green=online, yellow=away, grey=offline)
                    Positioned(
                      right: 2,
                      bottom: 2,
                      child: Container(
                        width: _cs(context, 12),
                        height: _cs(context, 12),
                        decoration: BoxDecoration(
                          color: hasCrossDeviceCall
                              ? const Color(0xFFF59E0B)
                              : _getStatusDotColor(effectiveStatus),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFF252542),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(width: _cs(context, 12)),
                // User info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Name
                      Text(
                        isSelfChatTile
                            ? '${user.fullName} (You)'
                            : user.fullName,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16 * s,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      // Email (admin-only view)
                      if (_isCurrentUserAdmin && user.email.isNotEmpty)
                        Text(
                          user.email,
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 11 * s,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      SizedBox(height: _cs(context, 2)),
                      // Online/Away/Offline status with relative time
                      Text(
                        hasPendingIncomingCall
                            ? '📞 Incoming call…'
                            : hasCrossDeviceCall
                            ? 'In call on another device'
                            : effectiveStatus == 'online'
                            ? 'Online'
                            : _formatRelativeTime(user.lastSeen),
                        style: TextStyle(
                          color: hasPendingIncomingCall
                              ? const Color(0xFFF59E0B)
                              : hasCrossDeviceCall
                              ? const Color(0xFFF59E0B)
                              : effectiveStatus == 'online'
                              ? const Color(0xFF00E676)
                              : effectiveStatus == 'away'
                              ? const Color(0xFFFFC107)
                              : Colors.grey[500],
                          fontSize: 13 * s,
                          fontWeight: hasPendingIncomingCall
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      SizedBox(height: _cs(context, 2)),
                      // Last message preview OR typing indicator
                      _typingUsers.containsKey(user.id)
                          ? const _TypingIndicator()
                          : Text(
                              _getLastMessagePreview(),
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 12 * s,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                    ],
                  ),
                ),
                // Time + Unread badge column (WhatsApp style)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Last message time
                    if (user.lastMessageTime != null)
                      Text(
                        _formatTime(user.lastMessageTime),
                        style: TextStyle(
                          color: displayUnreadCount > 0
                              ? const Color(0xFF00D9FF)
                              : Colors.grey[500],
                          fontSize: 11 * s,
                          fontWeight: displayUnreadCount > 0
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    if (displayUnreadCount > 0) ...[
                      SizedBox(height: _cs(context, 6)),
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: _cs(context, 8),
                          vertical: _cs(context, 4),
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE91E63),
                          borderRadius: BorderRadius.circular(_cs(context, 12)),
                        ),
                        child: Text(
                          displayUnreadCount > 99
                              ? '99+'
                              : '$displayUnreadCount',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12 * s,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAiChatTile() {
    final s = _compactScale(context);
    final preview = _aiLastMessagePreview ?? 'Start a conversation';
    final timeLabel = _aiLastMessageTime != null
        ? _formatTime(_aiLastMessageTime!)
        : '';

    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: _cs(context, 12),
        vertical: _cs(context, 4),
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF252542),
        borderRadius: BorderRadius.circular(_cs(context, 12)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(_cs(context, 12)),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AiChatScreen()),
            ).then((_) {
              _loadAiSessionPresence();
              _loadLobby(useCacheFirst: false);
            });
          },
          child: Padding(
            padding: EdgeInsets.all(_cs(context, 12)),
            child: Row(
              children: [
                // Bot avatar — gradient circle with smart_toy icon
                Container(
                  width: _cs(context, 52),
                  height: _cs(context, 52),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF00C9A7), Color(0xFF845EC2)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(_cs(context, 26)),
                  ),
                  child: Icon(
                    Icons.smart_toy_rounded,
                    color: Colors.white,
                    size: _cs(context, 28),
                  ),
                ),
                SizedBox(width: _cs(context, 12)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'AI Chat',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15 * s,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(width: _cs(context, 6)),
                          Container(
                            width: _cs(context, 8),
                            height: _cs(context, 8),
                            decoration: const BoxDecoration(
                              color: Color(0xFF00E676),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: _cs(context, 2)),
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 12 * s,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      timeLabel,
                      style: TextStyle(
                        color: Colors.grey[500],
                        fontSize: 11 * s,
                      ),
                    ),
                    SizedBox(height: _cs(context, 4)),
                    Text(
                      'Always on',
                      style: TextStyle(
                        color: const Color(0xFF00E676),
                        fontSize: 10 * s,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Static typing indicator label
class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'typing...',
      style: TextStyle(
        color: Color(0xFF00D9FF),
        fontSize: 12,
        fontStyle: FontStyle.italic,
      ),
    );
  }
}

/// Pulsing green icon button shown when an update APK is downloaded and ready.
class _PulsingUpdateButton extends StatefulWidget {
  final String tooltip;
  final VoidCallback onPressed;

  const _PulsingUpdateButton({required this.tooltip, required this.onPressed});

  @override
  State<_PulsingUpdateButton> createState() => _PulsingUpdateButtonState();
}

class _PulsingUpdateButtonState extends State<_PulsingUpdateButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _opacity = Tween<double>(
      begin: 0.55,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: IconButton(
        onPressed: widget.onPressed,
        icon: FadeTransition(
          opacity: _opacity,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(
                Icons.system_update_alt_rounded,
                color: Color(0xFF00E676),
                size: 24,
              ),
              Positioned(
                right: -1,
                top: -1,
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E676),
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(
                      color: const Color(0xFF1A1A2E),
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
