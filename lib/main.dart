import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_fonts/google_fonts.dart';
import 'firebase_options.dart';
import 'models/lobby_user.dart';
import 'screens/sign_in_page.dart';
import 'screens/register_page.dart';
import 'screens/forgot_password_page.dart';
import 'screens/reset_password_page.dart';
import 'screens/home_page.dart';
import 'screens/lobby_screen.dart';
import 'screens/share_target_screen.dart';
import 'screens/chat_screen.dart';
import 'services/background_update_service.dart';
import 'services/firebase_messaging_service.dart';
import 'services/fcm_service.dart';
import 'services/auth_error_handler.dart';
import 'services/chat_cache_service.dart';
import 'services/lobby_service.dart';
import 'services/media_preload_service.dart';
import 'services/storage_service.dart';
import 'services/share_intent_service.dart';
import 'services/shortcut_service.dart';
import 'services/socket_service.dart';
import 'services/presence_service.dart';
import 'services/media_upload_retry_service.dart';
import 'services/text_message_retry_service.dart';
import 'services/socket_event_queue_service.dart';
import 'services/version_service.dart';
import 'utils/notification_handler.dart';

import 'services/alarm_notification_service.dart';

final Completer<void> _bootstrapReadyCompleter = Completer<void>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (kDebugMode) {
    debugPrintRebuildDirtyWidgets = false;
    debugProfileBuildsEnabled = false;
  }

  // Set auth error navigation immediately; this does not require async setup.
  AuthErrorHandler.navigatorKey = NotificationHandler.navigatorKey;

  // Keep Android OS launch window visible until we know the first real screen.
  await StorageService.init();
  await ChatCacheService.init();
  await MediaUploadRetryService().initialize();
  await TextMessageRetryService().initialize();
  await SocketEventQueueService().initialize();
  await ShareIntentService.instance.initialize();
  await ShortcutService.instance.initialize();
  await AlarmNotificationService().initialize();

  final initialHome = await _resolveInitialHome();

  runApp(MessengerApp(initialHome: initialHome));

  // Warm up non-critical services in background so startup stays snappy.
  unawaited(_bootstrapAppServices());
}

Future<Widget> _resolveInitialHome() async {
  final token = await StorageService.getToken();
  final userId = await StorageService.getUserId();

  if (token == null || token.isEmpty || userId == null) {
    return const SignInPage();
  }

  // Restore realtime services for authenticated sessions.
  SocketService().initialize(token, userId);
  PresenceService().startHeartbeat();
  unawaited(PresenceService.updateStatus('online'));

  // Start the offline preload pump. It hydrates the message cache for
  // every conversation in the background and downloads media into the
  // shared on-disk cache (subject to the user's auto-download policy)
  // so chats can be opened — and viewed with images/videos — offline.
  unawaited(MediaPreloadService.instance.start());

  // Prime Android Direct Share shortcuts from local cache so top-row
  // conversation targets are available even before lobby fully loads.
  final cachedUsers = await ChatCacheService.loadLobbyUsers(userId);
  if (cachedUsers.isNotEmpty) {
    unawaited(ShortcutService.publishShareTargets(cachedUsers));
  }

  final sharedItems = await ShareIntentService.instance
      .takePendingSharedItems();
  if (sharedItems.isNotEmpty) {
    final directShareUserId =
        sharedItems
            .map((item) => item.directShareUserId)
            .firstWhere((id) => id != null, orElse: () => null) ??
        await ShareIntentService.instance.takePendingDirectShareUserId();

    return ShareTargetScreen(
      sharedItems: sharedItems,
      users: cachedUsers,
      openLobbyOnExit: true,
      directShareUserId: directShareUserId,
    );
  }

  final shortcutUserId = await ShortcutService.instance
      .takePendingShortcutUserId();
  if (shortcutUserId != null) {
    final shortcutUser = await _resolveLobbyUser(shortcutUserId, userId);
    if (shortcutUser != null) {
      return ChatScreen(otherUser: shortcutUser);
    }
  }

  return const LobbyScreen();
}

Future<LobbyUser?> _resolveLobbyUser(
  int targetUserId,
  int currentUserId,
) async {
  final cachedUsers = await ChatCacheService.loadLobbyUsers(currentUserId);
  for (final user in cachedUsers) {
    if (user.id == targetUserId) {
      return user;
    }
  }

  try {
    final freshUsers = await LobbyService.getLobbyUsers();
    await ChatCacheService.saveLobbyUsers(currentUserId, freshUsers);
    for (final user in freshUsers) {
      if (user.id == targetUserId) {
        return user;
      }
    }
  } catch (e) {
    debugPrint('Failed to resolve launcher shortcut user: $e');
  }

  return null;
}

Future<void> _bootstrapAppServices() async {
  try {
    final firebaseOptions = DefaultFirebaseOptions.currentPlatform;
    // The iOS Firebase app hasn't been registered yet, so firebase_options.dart
    // still carries a placeholder appId. Passing it to the native FIRApp would
    // throw an uncaught NSException ("invalid GOOGLE_APP_ID") that crashes the
    // process before Dart can catch it. Skip Firebase/FCM until a real config is
    // generated via `flutterfire configure`; this re-enables itself once appId
    // becomes real.
    if (firebaseOptions.appId.contains('YOUR_')) {
      debugPrint(
        'Skipping Firebase init: placeholder appId. '
        'Run `flutterfire configure` to enable push notifications.',
      );
      return;
    }

    await Firebase.initializeApp(options: firebaseOptions);

    // Register FCM background message handler
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Initialize Firebase Cloud Messaging
    await FirebaseMessagingService.instance.initialize();

    // Set up notification tap handler
    FirebaseMessagingService.instance.onNotificationTapped = (data) {
      NotificationHandler.handleNotificationTap(data);
    };

    final isLoggedIn = await StorageService.isLoggedIn();
    if (isLoggedIn) {
      final fcmToken = await FirebaseMessagingService.instance
          .getSavedFCMToken();
      if (fcmToken != null) {
        await FCMService.updateFCMToken(fcmToken);
      }
    }

    // Restore any APK that was fully downloaded in a previous session, then
    // honour a pending "Install Now" tap that arrived while the app was closed.
    unawaited(
      BackgroundUpdateService().restorePersistedState().then(
        (_) => BackgroundUpdateService().consumePendingInstall(),
      ),
    );

    unawaited(FirebaseMessagingService.instance.checkInitialMessage());
  } catch (e) {
    debugPrint('Firebase bootstrap failed: $e');
  } finally {
    if (!_bootstrapReadyCompleter.isCompleted) {
      _bootstrapReadyCompleter.complete();
    }
  }
}

class MessengerApp extends StatefulWidget {
  final Widget initialHome;

  const MessengerApp({super.key, required this.initialHome});

  static const Color blue900 = Color(0xFF1E3A8A); // rgb(30,58,138)
  static const Color card = Color(0xFF344256); // slate-ish dark card
  static const Color primaryBtn = Color(0xFF2E2A8B); // deep indigo button

  @override
  State<MessengerApp> createState() => _MessengerAppState();
}

class _MessengerAppState extends State<MessengerApp>
    with WidgetsBindingObserver {
  DateTime? _lastResumeUpdateCheck;
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _hasInternetConnection = true;
  bool _showBackOnlineBanner = false;
  bool _showOfflineBanner = false;
  bool _didReceiveConnectivityUpdate = false;
  Timer? _backOnlineBannerTimer;

  Future<void> _initializeConnectivityMonitoring() async {
    final currentResults = await _connectivity.checkConnectivity();
    _updateConnectivity(currentResults);

    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
      _updateConnectivity,
    );
  }

  void _updateConnectivity(List<ConnectivityResult> results) {
    final hasConnection =
        results.isNotEmpty && !results.contains(ConnectivityResult.none);
    if (!mounted) return;

    if (!_didReceiveConnectivityUpdate) {
      _didReceiveConnectivityUpdate = true;
      setState(() {
        _hasInternetConnection = hasConnection;
        // Show the offline banner on first launch only if we boot up
        // already disconnected, so the user gets a clear cue. The
        // 2-second auto-hide below still applies.
        _showOfflineBanner = !hasConnection;
      });
      _scheduleBannerAutoHide();
      return;
    }

    if (_hasInternetConnection == hasConnection) return;

    setState(() {
      _hasInternetConnection = hasConnection;
      // Both transitions surface a banner: green "back online" when we
      // gain connection, red "no internet" when we lose it. Each banner
      // hides itself after 2s; the red bottom border below stays visible
      // for the entire offline window so the user keeps seeing the cue
      // without the banner covering app chrome (e.g. the version label).
      if (hasConnection) {
        _showBackOnlineBanner = true;
        _showOfflineBanner = false;
      } else {
        _showOfflineBanner = true;
        _showBackOnlineBanner = false;
      }
    });

    _scheduleBannerAutoHide();

    // When connectivity is restored, retry any queued media uploads
    // that failed due to temporary network issues.
    if (hasConnection) {
      MediaUploadRetryService().retryAll();
    }
  }

  void _scheduleBannerAutoHide() {
    _backOnlineBannerTimer?.cancel();
    _backOnlineBannerTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _showBackOnlineBanner = false;
        _showOfflineBanner = false;
      });
    });
  }

  void _scheduleUpdateCheck({int retryCount = 0}) {
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_bootstrapReadyCompleter.isCompleted) {
        debugPrint(
          '[VersionService] Waiting for Firebase bootstrap before first version check.',
        );
        _bootstrapReadyCompleter.future.then((_) {
          if (!mounted) return;
          _scheduleUpdateCheck(retryCount: retryCount);
        });
        return;
      }

      // Pass context only for the force-update dialog path; non-forced updates
      // no longer need a context (background download is context-free).
      final checkContext = NotificationHandler.navigatorKey.currentContext;
      VersionService().checkAndPromptUpdate(checkContext);

      if (retryCount < 3) {
        Future<void>.delayed(const Duration(milliseconds: 450), () {
          _scheduleUpdateCheck(retryCount: retryCount + 1);
        });
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _scheduleUpdateCheck();
    unawaited(_initializeConnectivityMonitoring());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;

    final now = DateTime.now();
    if (_lastResumeUpdateCheck != null &&
        now.difference(_lastResumeUpdateCheck!) < const Duration(seconds: 5)) {
      return;
    }

    _lastResumeUpdateCheck = now;
    _scheduleUpdateCheck();
    // Re-hydrate offline caches in the background so freshly received
    // messages and media on the server are mirrored locally.
    unawaited(MediaPreloadService.instance.triggerSync());
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _backOnlineBannerTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: MessengerApp.blue900,
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: Colors.transparent,
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: Color(0xFFCB6CFF),
        selectionColor: Color(0x668B5CF6),
        selectionHandleColor: Color(0xFFCB6CFF),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFFEFF6FF),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide.none,
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      textTheme: GoogleFonts.interTextTheme(
        const TextTheme(
          bodyLarge: TextStyle(color: Colors.black),
          bodyMedium: TextStyle(color: Colors.black),
        ),
      ),
    );

    return MaterialApp(
      title: 'Flutter Messenger',
      debugShowCheckedModeBanner: false,
      navigatorKey: NotificationHandler.navigatorKey,
      navigatorObservers: [PerformanceRouteObserver()],
      builder: (context, child) {
        final mediaQueryData = MediaQuery.of(context);
        final double screenWidth = mediaQueryData.size.width;
        // ignore: deprecated_member_use
        final double systemScale = mediaQueryData.textScaleFactor;

        // Calculate a responsive text scale factor that scales down
        // on smaller screens (high DPI / large display scale) to prevent cutoffs.
        double factor = systemScale;
        if (screenWidth < 360) {
          factor = factor * 0.82;
        } else if (screenWidth < 400) {
          factor = factor * 0.90;
        }

        // Compensate if the system font size is set excessively large
        if (systemScale > 1.15) {
          factor = factor * (1.15 / systemScale);
        }

        // Clamp to a safe range (0.70 to 1.05) to keep UI compact and responsive
        factor = factor.clamp(0.70, 1.05);

        final clampedMediaQueryData = mediaQueryData.copyWith(
          // ignore: deprecated_member_use
          textScaleFactor: factor,
        );

        final appContent = MediaQuery(
          data: clampedMediaQueryData,
          child: child ?? const SizedBox.shrink(),
        );
        // Top banner is shown only briefly: green "back online" right
        // after reconnecting, or red "no internet" right after dropping
        // the connection. Both auto-hide after 2 seconds.
        final showStatusBanner = _showOfflineBanner || _showBackOnlineBanner;
        // Persistent ambient cue: while we are offline, paint a thin
        // red border around the screen so the user keeps seeing the
        // status without the banner covering the version label or
        // other footer content.
        final showOfflineBorder = !_hasInternetConnection;
        return Stack(
          children: [
            appContent,
            if (showOfflineBorder)
              const Positioned.fill(
                child: IgnorePointer(child: _OfflineBorderOverlay()),
              ),
            if (showStatusBanner)
              AnimatedSwitcher(
                duration: Duration.zero,
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) {
                  final offsetAnimation = Tween<Offset>(
                    begin: const Offset(0, -0.25),
                    end: Offset.zero,
                  ).animate(animation);
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: offsetAnimation,
                      child: child,
                    ),
                  );
                },
                child: _ConnectionStatusBanner(
                  key: ValueKey<String>(
                    _hasInternetConnection ? 'online' : 'offline',
                  ),
                  isOnline: _hasInternetConnection,
                ),
              ),
          ],
        );
      },
      theme: baseTheme.copyWith(
        // Kill all page-route transitions globally
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: _NoTransitionBuilder(),
            TargetPlatform.iOS: _NoTransitionBuilder(),
            TargetPlatform.windows: _NoTransitionBuilder(),
            TargetPlatform.linux: _NoTransitionBuilder(),
            TargetPlatform.macOS: _NoTransitionBuilder(),
          },
        ),
        // Remove ink splash / ripple animations
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
      ),
      home: widget.initialHome,
      routes: {
        SignInPage.route: (_) => const SignInPage(),
        RegisterPage.route: (_) => const RegisterPage(),
        ForgotPasswordPage.route: (_) => const ForgotPasswordPage(),
        ResetPasswordPage.route: (_) => const ResetPasswordPage(),
        HomePage.route: (_) => const HomePage(),
        LobbyScreen.route: (_) => const LobbyScreen(),
      },
    );
  }
}

/// Zero-duration page transition — replaces slides/fades with instant swap.
class PerformanceRouteObserver extends NavigatorObserver {
  static String currentRoute = 'unknown';

  void _logRoute(String action, Route<dynamic>? route) {
    if (route == null) return;
    currentRoute = route.settings.name ?? route.runtimeType.toString();
    debugPrint('🧭 Route $action: $currentRoute');
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    _logRoute('pushed', route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _logRoute('replaced', newRoute);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    _logRoute('popped', route);
    if (previousRoute != null) {
      _logRoute('restored', previousRoute);
    }
  }
}

class _NoTransitionBuilder extends PageTransitionsBuilder {
  const _NoTransitionBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

class _ConnectionStatusBanner extends StatelessWidget {
  const _ConnectionStatusBanner({super.key, required this.isOnline});

  final bool isOnline;

  @override
  Widget build(BuildContext context) {
    final backgroundColor = isOnline
        ? const Color(0xFF2E7D32)
        : const Color(0xFFC62828);
    final icon = isOnline ? Icons.wifi_rounded : Icons.wifi_off_rounded;
    final text = isOnline ? 'Back online' : 'No internet connection';

    return SafeArea(
      bottom: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 26),
            ],
          ),
        ),
      ),
    );
  }
}

/// Persistent ambient cue painted around the entire screen while offline.
/// Drawn in the [MessengerApp] builder above the app's content so it sits
/// over scaffolds without intercepting touches (parent uses
/// [IgnorePointer]). The bottom edge is intentionally thicker so the cue
/// is visible without covering the version label or other footer chrome.
class _OfflineBorderOverlay extends StatelessWidget {
  const _OfflineBorderOverlay();

  @override
  Widget build(BuildContext context) {
    const Color edgeColor = Color(0xFFC62828);
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: edgeColor, width: 3.0)),
      ),
    );
  }
}
