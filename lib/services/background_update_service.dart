import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'storage_service.dart';
import 'version_service.dart';

// ─── State ───────────────────────────────────────────────────────────────────

enum BackgroundUpdateStatus { idle, downloading, readyToInstall, failed }

class BackgroundUpdateState {
  final BackgroundUpdateStatus status;
  final double progress; // 0.0–1.0
  final String? apkPath;
  final String? errorMessage;
  final AppVersionInfo? versionInfo;

  const BackgroundUpdateState.idle()
    : status = BackgroundUpdateStatus.idle,
      progress = 0,
      apkPath = null,
      errorMessage = null,
      versionInfo = null;

  const BackgroundUpdateState.downloading({
    required this.progress,
    required this.versionInfo,
  }) : status = BackgroundUpdateStatus.downloading,
       apkPath = null,
       errorMessage = null;

  const BackgroundUpdateState.readyToInstall({
    required this.apkPath,
    required this.versionInfo,
  }) : status = BackgroundUpdateStatus.readyToInstall,
       progress = 1.0,
       errorMessage = null;

  const BackgroundUpdateState.failed({required this.errorMessage})
    : status = BackgroundUpdateStatus.failed,
      progress = 0,
      apkPath = null,
      versionInfo = null;
}

/// Payload for the in-app "Update available" prompt (SnackBar).
class InAppUpdatePrompt {
  final AppVersionInfo info;
  final String downloadUrl;
  InAppUpdatePrompt({required this.info, required this.downloadUrl});
}

// ─── Service ──────────────────────────────────────────────────────────────────

const int _downloadProgressNotificationId = 9002;
const int _readyToInstallNotificationId = 9003;
const String _updateDownloadChannelId = 'app_update_download';
const String _updateDownloadChannelName = 'App Update Download';

const String _prefApkPath = 'bg_update_apk_path';
const String _prefApkVersion = 'bg_update_apk_version';
const String _prefApkBuild = 'bg_update_apk_build';
// Set when the user taps the "ready to install" notification. Consumed on the
// next foreground so the installer launches from an Activity context even when
// the tap was handled by a background isolate.
const String _prefInstallRequested = 'bg_update_install_requested';

/// WhatsApp-style background download service for app updates.
///
/// Usage:
///   // Step 1: notify user (HTTP poll path)
///   BackgroundUpdateService().notifyUpdateAvailable(info, downloadUrl);
///
///   // Step 2: start download only after user taps [Download Now]
///   //         (handled automatically by _onNotificationTapped)
///
///   BackgroundUpdateService().state.addListener(...);
///   BackgroundUpdateService().launchInstaller();
class BackgroundUpdateService {
  static final BackgroundUpdateService _instance =
      BackgroundUpdateService._internal();
  factory BackgroundUpdateService() => _instance;
  BackgroundUpdateService._internal();

  // ── Public state notifiers ─────────────────────────────────────────────────

  final ValueNotifier<BackgroundUpdateState> state = ValueNotifier(
    const BackgroundUpdateState.idle(),
  );

  /// Fires when an in-app "Update available" SnackBar should be shown.
  /// The lobby screen listens to this and renders the SnackBar with
  /// [Download Now] / [Later] buttons.
  final ValueNotifier<InAppUpdatePrompt?> pendingInAppPrompt = ValueNotifier(
    null,
  );

  // ── Private fields ─────────────────────────────────────────────────────────

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 10),
      sendTimeout: const Duration(seconds: 30),
    ),
  );

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  /// Bridge to the native foreground service that keeps the process alive (and
  /// the download running) while the app is backgrounded.
  static const MethodChannel _downloadServiceChannel = MethodChannel(
    'com.example.flutter_messenger_v2/update_download',
  );

  bool _notificationsInitialized = false;
  CancelToken? _cancelToken;

  void _log(String msg) => debugPrint('[BackgroundUpdateService] $msg');

  // ── Initializer ────────────────────────────────────────────────────────────

  Future<void> _ensureNotificationsInitialized() async {
    if (_notificationsInitialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _localNotifications.initialize(
      const InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
        macOS: iosSettings,
      ),
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Create the download-progress notification channel (Android)
    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _updateDownloadChannelId,
            _updateDownloadChannelName,
            description: 'Shows download progress for app updates',
            importance: Importance.low,
            playSound: false,
            enableVibration: false,
            showBadge: false,
          ),
        );

    _notificationsInitialized = true;
  }

  // ── Restore persisted ready-APK on app restart ─────────────────────────────

  /// Call this once on app startup to restore a previously completed download.
  /// Validates that the persisted APK is still newer than the installed version.
  Future<void> restorePersistedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final apkPath = prefs.getString(_prefApkPath);
      final version = prefs.getString(_prefApkVersion);
      final build = prefs.getInt(_prefApkBuild);

      if (apkPath == null || apkPath.isEmpty) return;

      // Check the cached APK build is actually newer than the installed app
      final packageInfo = await PackageInfo.fromPlatform();
      final installedBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
      final apkBuild = build ?? 0;

      if (apkBuild > 0 && installedBuild > 0 && apkBuild <= installedBuild) {
        _log(
          'Persisted APK (build $apkBuild) is not newer than installed (build $installedBuild) — clearing.',
        );
        await _clearPersistedApk();
        return;
      }

      final file = File(apkPath);
      if (!file.existsSync()) {
        await _clearPersistedApk();
        return;
      }

      // Verify it's still a valid APK (ZIP magic bytes)
      final bytes = await file.openRead(0, 4).expand((b) => b).toList();
      if (bytes.length < 4 ||
          bytes[0] != 0x50 ||
          bytes[1] != 0x4B ||
          bytes[2] != 0x03 ||
          bytes[3] != 0x04) {
        _log('Persisted APK is corrupt — clearing.');
        await _clearPersistedApk();
        return;
      }

      final info = AppVersionInfo(
        version: version ?? '',
        buildNumber: apkBuild,
        downloadUrl: '',
        forceUpdate: false,
        releaseNotes: '',
      );

      _log(
        'Restored ready-to-install APK: $apkPath (v${info.version}+${info.buildNumber})',
      );
      state.value = BackgroundUpdateState.readyToInstall(
        apkPath: apkPath,
        versionInfo: info,
      );
    } catch (e) {
      _log('Failed to restore persisted state: $e');
    }
  }

  /// Clears all persisted and in-memory update state.
  /// Call this when the version check confirms no update is needed.
  Future<void> clearStaleState() async {
    if (state.value.status != BackgroundUpdateStatus.idle) {
      _log('Clearing stale update state.');
      state.value = const BackgroundUpdateState.idle();
    }
    pendingInAppPrompt.value = null;
    await _clearPersistedApk();
  }

  // ── Primary API ────────────────────────────────────────────────────────────

  /// Start a background download for [info] from [downloadUrl].
  ///
  /// - If a download is already in progress, this is a no-op.
  /// - If a valid APK for the same (or newer) version is already on disk,
  ///   the download is skipped and state transitions to [readyToInstall].
  /// - On Android only; on other platforms this is a no-op (link opens externally).
  Future<void> startBackgroundDownload(
    AppVersionInfo info,
    String downloadUrl,
  ) async {
    if (!Platform.isAndroid) {
      _log(
        'Background download is Android-only. Skipping on ${Platform.operatingSystem}.',
      );
      return;
    }

    if (state.value.status == BackgroundUpdateStatus.downloading) {
      _log('Download already in progress — ignoring duplicate request.');
      return;
    }

    if (downloadUrl.isEmpty) {
      _log('Cannot start download: downloadUrl is empty.');
      return;
    }

    // Check if we already have a valid APK for this version on disk
    final existingApk = await _findExistingApk(info);
    if (existingApk != null) {
      _log(
        'Reusing existing APK for v${info.version}+${info.buildNumber}: $existingApk',
      );
      await _persistApkState(existingApk, info);
      state.value = BackgroundUpdateState.readyToInstall(
        apkPath: existingApk,
        versionInfo: info,
      );
      await _showReadyToInstallNotification(info);
      return;
    }

    _log(
      'Starting background download of v${info.version}+${info.buildNumber} from $downloadUrl',
    );
    await _ensureNotificationsInitialized();

    state.value = BackgroundUpdateState.downloading(
      progress: 0,
      versionInfo: info,
    );
    // Promote to a foreground service so the OS keeps the process (and this
    // download) alive while the app is backgrounded. The service owns the
    // progress notification, so we don't post a separate local one.
    await _startDownloadService(info, 0);

    _cancelToken = CancelToken();

    // Run download asynchronously — don't await so caller returns immediately
    unawaited(_runDownload(info, downloadUrl));
  }

  /// Cancel an in-progress download.
  void cancelDownload() {
    _cancelToken?.cancel('User cancelled');
    _cancelToken = null;
    state.value = const BackgroundUpdateState.idle();
    _cancelDownloadNotification();
    _log('Download cancelled by user.');
  }

  /// Launch the Android package installer for the downloaded APK.
  ///
  /// Resolves the APK from the live state or, if that's empty (e.g. a fresh
  /// isolate), from the persisted path. Ensures the "install unknown apps"
  /// permission is granted first — without it Android silently refuses to open
  /// the package installer.
  Future<void> launchInstaller() async {
    String? apkPath = state.value.apkPath;
    if (apkPath == null || apkPath.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      apkPath = prefs.getString(_prefApkPath);
    }

    if (apkPath == null || apkPath.isEmpty || !File(apkPath).existsSync()) {
      _log('launchInstaller called but no APK is available.');
      return;
    }

    if (Platform.isAndroid && !await _ensureInstallPermission()) {
      _log('Install permission not granted — keeping request pending.');
      return;
    }

    _log('Launching installer for $apkPath');
    final result = await OpenFilex.open(
      apkPath,
      type: 'application/vnd.android.package-archive',
    );

    if (result.type == ResultType.done) {
      await _clearInstallRequested();
    } else {
      _log('Installer launch failed: ${result.message}');
    }
  }

  /// Record that the user asked to install (e.g. tapped the notification) and
  /// attempt the launch immediately. The launch only succeeds from a foreground
  /// Activity, so the persisted flag lets [consumePendingInstall] retry on the
  /// next foreground if this was handled in a background isolate.
  Future<void> requestInstall() async {
    await _markInstallRequested();
    await launchInstaller();
  }

  /// Called on app foreground/startup: if an install was requested from a
  /// notification, launch the installer now that an Activity context exists.
  Future<void> consumePendingInstall() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_prefInstallRequested) != true) return;
      _log('Consuming pending install request.');
      await launchInstaller();
    } catch (e) {
      _log('consumePendingInstall failed: $e');
    }
  }

  Future<bool> _ensureInstallPermission() async {
    try {
      final status = await Permission.requestInstallPackages.status;
      if (status.isGranted) return true;
      final requested = await Permission.requestInstallPackages.request();
      return requested.isGranted;
    } catch (e) {
      _log('Install permission check failed: $e');
      return false;
    }
  }

  Future<void> _markInstallRequested() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefInstallRequested, true);
    } catch (_) {}
  }

  Future<void> _clearInstallRequested() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefInstallRequested);
    } catch (_) {}
  }

  // ── Update-available notification (WhatsApp-style prompt) ──────────────────

  /// Manual-mode entry point: surfaces an "Update available" prompt **inside the
  /// app only** (no "Download Now / Later" system notification).
  ///
  /// Used when the user has turned Automatic Updates off — they choose to
  /// download from the in-app dialog every time the app is opened. In auto mode
  /// callers use [startBackgroundDownload] instead and this is never invoked.
  Future<void> notifyUpdateAvailable(
    AppVersionInfo info,
    String downloadUrl,
  ) async {
    // Fire the in-app prompt so the lobby screen can show its update dialog.
    pendingInAppPrompt.value = InAppUpdatePrompt(
      info: info,
      downloadUrl: downloadUrl,
    );
    _log('Surfaced in-app update prompt for v${info.version}.');
  }

  // ── Internal download logic ────────────────────────────────────────────────

  /// Clear the ready-to-install state (e.g. after user dismisses).
  Future<void> clearReadyState() async {
    await _clearPersistedApk();
    state.value = const BackgroundUpdateState.idle();
    await _localNotifications.cancel(_readyToInstallNotificationId);
  }

  // ── Internal download logic ────────────────────────────────────────────────

  Future<void> _runDownload(AppVersionInfo info, String downloadUrl) async {
    try {
      final authToken = await StorageService.getToken();
      final tempDir = await getTemporaryDirectory();
      final safeVersion = info.version.replaceAll(
        RegExp(r'[^0-9A-Za-z._-]'),
        '_',
      );
      final buildSuffix = info.buildNumber > 0 ? '_b${info.buildNumber}' : '';
      final apkPath = '${tempDir.path}/app_update_$safeVersion$buildSuffix.apk';

      final headers = <String, String>{
        'Accept': 'application/vnd.android.package-archive,*/*',
      };
      if (authToken != null && authToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer $authToken';
      }

      int lastNotifPercent = -1;

      final response = await _dio.get<List<int>>(
        downloadUrl,
        cancelToken: _cancelToken,
        options: Options(
          responseType: ResponseType.bytes,
          headers: headers,
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (s) => s != null && s >= 200 && s < 400,
        ),
        onReceiveProgress: (received, total) {
          final progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
          state.value = BackgroundUpdateState.downloading(
            progress: progress,
            versionInfo: info,
          );

          // Throttle foreground-service notification updates to every 5%
          final percent = (progress * 100).truncate();
          if (percent != lastNotifPercent && percent % 5 == 0) {
            lastNotifPercent = percent;
            unawaited(_startDownloadService(info, percent));
          }
        },
      );

      final bytes = response.data ?? const <int>[];
      _log('Download complete: ${bytes.length} bytes');

      // Validate APK ZIP magic bytes
      if (bytes.length < 4 ||
          bytes[0] != 0x50 ||
          bytes[1] != 0x4B ||
          bytes[2] != 0x03 ||
          bytes[3] != 0x04) {
        throw Exception(
          'Downloaded file is not a valid APK (bad magic bytes).',
        );
      }

      final file = File(apkPath);
      await file.writeAsBytes(bytes, flush: true);
      _log('APK saved to: $apkPath');

      await _persistApkState(apkPath, info);
      state.value = BackgroundUpdateState.readyToInstall(
        apkPath: apkPath,
        versionInfo: info,
      );

      await _showReadyToInstallNotification(info);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        _log('Download was cancelled.');
        return;
      }
      _log('Download failed (Dio): $e');
      state.value = BackgroundUpdateState.failed(
        errorMessage: 'Download failed: ${e.message}',
      );
    } catch (e) {
      _log('Download failed: $e');
      state.value = BackgroundUpdateState.failed(
        errorMessage: 'Download failed: $e',
      );
    } finally {
      // Always tear down the foreground service when the download ends.
      await _stopDownloadService();
    }
  }

  // ── Foreground-service bridge ──────────────────────────────────────────────

  Future<void> _startDownloadService(AppVersionInfo info, int percent) async {
    if (!Platform.isAndroid) return;
    try {
      await _downloadServiceChannel.invokeMethod<void>('start', {
        'title': 'Downloading update v${info.version}',
        'text': percent > 0 ? '$percent%' : 'Starting…',
        'progress': percent,
      });
    } catch (e) {
      _log('Failed to start download foreground service: $e');
    }
  }

  Future<void> _stopDownloadService() async {
    if (!Platform.isAndroid) return;
    try {
      await _downloadServiceChannel.invokeMethod<void>('stop');
    } catch (e) {
      _log('Failed to stop download foreground service: $e');
    }
  }

  // ── Persisted APK helpers ──────────────────────────────────────────────────

  Future<String?> _findExistingApk(AppVersionInfo info) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPath = prefs.getString(_prefApkPath);
      final savedBuild = prefs.getInt(_prefApkBuild) ?? 0;

      if (savedPath == null || savedPath.isEmpty) return null;
      if (savedBuild < info.buildNumber) return null;

      final file = File(savedPath);
      if (!file.existsSync()) return null;

      // Quick magic byte check
      final bytes = await file.openRead(0, 4).expand((b) => b).toList();
      if (bytes.length < 4 ||
          bytes[0] != 0x50 ||
          bytes[1] != 0x4B ||
          bytes[2] != 0x03 ||
          bytes[3] != 0x04) {
        return null;
      }

      return savedPath;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistApkState(String apkPath, AppVersionInfo info) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefApkPath, apkPath);
      await prefs.setString(_prefApkVersion, info.version);
      await prefs.setInt(_prefApkBuild, info.buildNumber);
    } catch (e) {
      _log('Failed to persist APK state: $e');
    }
  }

  Future<void> _clearPersistedApk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefApkPath);
      await prefs.remove(_prefApkVersion);
      await prefs.remove(_prefApkBuild);
      await prefs.remove(_prefInstallRequested);
    } catch (e) {
      _log('Failed to clear persisted APK: $e');
    }
  }

  // ── Notification helpers ───────────────────────────────────────────────────

  Future<void> _cancelDownloadNotification() async {
    try {
      await _ensureNotificationsInitialized();
      await _localNotifications.cancel(_downloadProgressNotificationId);
    } catch (_) {}
  }

  Future<void> _showReadyToInstallNotification(AppVersionInfo info) async {
    await _ensureNotificationsInitialized();

    final androidDetails = AndroidNotificationDetails(
      'app_update', // existing channel
      'App Updates',
      channelDescription: 'Notifications for app version updates',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: false,
      autoCancel: true,
      icon: '@mipmap/ic_launcher',
      actions: const <AndroidNotificationAction>[
        AndroidNotificationAction(
          'install_now',
          'Install Now',
          showsUserInterface: true,
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          'update_later',
          'Later',
          showsUserInterface: false,
          cancelNotification: true,
        ),
      ],
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final payload = jsonEncode(<String, dynamic>{
      'type': 'app_update_ready',
      'version': info.version,
      'build_number': info.buildNumber,
    });

    await _localNotifications.show(
      _readyToInstallNotificationId,
      'Update ready to install',
      'v${info.version} downloaded — tap to install',
      NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: payload,
    );
  }

  void _onNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;

    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final type = data['type']?.toString();
      final actionId = response.actionId;

      // ── "Update available" notification (HTTP-poll path) ────────────────────
      if (type == 'app_update') {
        if (actionId == 'update_later') {
          // User chose Later → persist payload so the lobby badge stays visible
          _log('User tapped Later — deferring update.');
          unawaited(VersionService().deferUpdatePayload(data));
          return;
        }

        // "Download Now" or body tap → start background download
        final downloadUrl = data['download_url']?.toString().trim() ?? '';
        if (downloadUrl.isNotEmpty) {
          final info = AppVersionInfo.fromJson(data);
          _log('User tapped Download Now — starting background download.');
          unawaited(startBackgroundDownload(info, downloadUrl));
        }
        return;
      }

      // ── "Ready to install" notification ────────────────────────────────────
      if (type == 'app_update_ready') {
        if (actionId == 'update_later') {
          // Keep APK ready but don't install yet
          return;
        }
        // 'install_now' or body tap → launch installer (with foreground retry)
        unawaited(requestInstall());
      }
    } catch (e) {
      debugPrint(
        '[BackgroundUpdateService] Error handling notification tap: $e',
      );
    }
  }
}
