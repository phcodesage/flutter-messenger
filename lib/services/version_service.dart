import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/api_config.dart';
import 'background_update_service.dart';
import 'storage_service.dart';

class AppVersionInfo {
  final String version;
  final int buildNumber;
  final String downloadUrl;
  final bool forceUpdate;
  final String releaseNotes;

  const AppVersionInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    required this.forceUpdate,
    required this.releaseNotes,
  });

  factory AppVersionInfo.fromJson(Map<String, dynamic> json) {
    final dynamic rawBuild = json['build_number'];
    final int build = rawBuild is int
        ? rawBuild
        : int.tryParse(rawBuild?.toString() ?? '') ?? 0;

    final dynamic rawForceUpdate = json['force_update'];
    final bool forceUpdate = rawForceUpdate is bool
        ? rawForceUpdate
        : (rawForceUpdate?.toString().toLowerCase() == 'true');

    return AppVersionInfo(
      version: (json['version'] as String? ?? '').trim(),
      buildNumber: build,
      downloadUrl: (json['download_url'] as String? ?? '').trim(),
      forceUpdate: forceUpdate,
      releaseNotes: (json['release_notes'] as String? ?? '').trim(),
    );
  }
}

class ApkDownloader {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
      sendTimeout: const Duration(seconds: 30),
    ),
  );

  Future<String> downloadApk({
    required String url,
    required String version,
    required int buildNumber,
    String? authToken,
    void Function(String message)? onLog,
    required void Function(int received, int total) onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw Exception('Auto-install is only supported on Android.');
    }

    await _ensureInstallPermission();

    final tempDir = await getTemporaryDirectory();
    final safeVersion = version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    final buildSuffix = buildNumber > 0 ? '_build$buildNumber' : '';
    final outputPath =
        '${tempDir.path}/flask_call_app_$safeVersion$buildSuffix.apk';

    final headers = <String, String>{
      'Accept':
          'application/vnd.android.package-archive,application/octet-stream,*/*',
    };
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }

    onLog?.call('Downloading APK from: $url');
    final response = await _dio.get<List<int>>(
      url,
      onReceiveProgress: onProgress,
      options: Options(
        responseType: ResponseType.bytes,
        headers: headers,
        followRedirects: true,
        maxRedirects: 5,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 400,
      ),
    );

    final bytes = response.data ?? const <int>[];
    final contentType =
        response.headers.value(Headers.contentTypeHeader) ?? 'unknown';
    onLog?.call(
      'Download response: status=${response.statusCode}, content-type=$contentType, bytes=${bytes.length}',
    );

    if (bytes.length < 4 ||
        bytes[0] != 0x50 ||
        bytes[1] != 0x4B ||
        bytes[2] != 0x03 ||
        bytes[3] != 0x04) {
      throw Exception(
        'Downloaded file is not a valid APK payload (zip signature missing). Check backend app-download response.',
      );
    }

    final file = File(outputPath);
    await file.writeAsBytes(bytes, flush: true);
    onLog?.call('APK saved to: $outputPath');

    return outputPath;
  }

  Future<OpenResult> launchInstaller(String apkPath) {
    final apkFile = File(apkPath);
    if (!apkFile.existsSync()) {
      throw Exception('APK file not found at path: $apkPath');
    }

    return OpenFilex.open(
      apkPath,
      type: 'application/vnd.android.package-archive',
    );
  }

  Future<void> _ensureInstallPermission() async {
    if (!Platform.isAndroid) return;
    final status = await Permission.requestInstallPackages.status;
    if (status.isGranted) return;

    final requested = await Permission.requestInstallPackages.request();
    if (!requested.isGranted) {
      throw Exception('Install unknown apps permission is required.');
    }
  }
}

class VersionService {
  static final VersionService _instance = VersionService._internal();
  factory VersionService() => _instance;
  VersionService._internal();

  static final ValueNotifier<int> deferredUpdateSignal = ValueNotifier<int>(0);

  static const String _deferredUpdatePayloadKey = 'deferred_app_update_payload';

  bool _isChecking = false;
  bool _dialogVisible = false;
  DateTime? _lastVersionCheckTime;
  // Throttle for the passive path (heartbeat / periodic). Kept short so a new
  // release is picked up within a few minutes while the app stays open.
  static const Duration _minVersionCheckInterval = Duration(minutes: 5);
  // Minimal debounce for forced checks (app open / "Check now" button) so rapid
  // foreground/background cycling can't hammer the version endpoint.
  static const Duration _minForcedCheckInterval = Duration(seconds: 15);
  String? _lastPromptedVersion;

  void _log(String message) {
    debugPrint('[VersionService] $message');
  }

  Future<void> deferUpdatePayload(Map<String, dynamic> payload) async {
    try {
      final info = AppVersionInfo.fromJson(payload);
      if (info.version.isEmpty) {
        _log('Skipping deferred update save: payload has no version.');
        return;
      }

      final resolvedDownloadUrl = _resolveDownloadUrl(info.downloadUrl);
      if (resolvedDownloadUrl.isEmpty) {
        _log('Skipping deferred update save: invalid download URL.');
        return;
      }

      final normalizedPayload = <String, dynamic>{
        'type': 'app_update',
        'version': info.version,
        'build_number': info.buildNumber,
        'download_url': resolvedDownloadUrl,
        'force_update': info.forceUpdate,
        'release_notes': info.releaseNotes,
      };

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _deferredUpdatePayloadKey,
        jsonEncode(normalizedPayload),
      );
      deferredUpdateSignal.value++;
      _log('Deferred update saved for contacts screen entry point.');
    } catch (e) {
      _log('Failed to save deferred update payload: $e');
    }
  }

  Future<void> clearDeferredUpdatePayload() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_deferredUpdatePayloadKey);
      deferredUpdateSignal.value++;
    } catch (e) {
      _log('Failed to clear deferred update payload: $e');
    }
  }

  Future<Map<String, dynamic>?> getDeferredUpdatePayloadIfRelevant() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_deferredUpdatePayloadKey);
      if (raw == null || raw.isEmpty) {
        return null;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await clearDeferredUpdatePayload();
        return null;
      }

      final isStillRelevant = await _isPayloadRelevant(decoded);
      if (!isStillRelevant) {
        await clearDeferredUpdatePayload();
        return null;
      }

      return decoded;
    } catch (e) {
      _log('Failed to read deferred update payload: $e');
      return null;
    }
  }

  Future<bool> _isPayloadRelevant(Map<String, dynamic> payload) async {
    final info = AppVersionInfo.fromJson(payload);
    if (info.version.isEmpty) {
      return false;
    }

    final resolvedDownloadUrl = _resolveDownloadUrl(info.downloadUrl);
    if (resolvedDownloadUrl.isEmpty) {
      return false;
    }

    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = packageInfo.version;
    final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

    final shouldUpdate = _isUpdateRequired(
      currentVersion: currentVersion,
      currentBuild: currentBuild,
      serverVersion: info.version,
      serverBuild: info.buildNumber,
    );

    return shouldUpdate || info.forceUpdate;
  }

  /// Handle an app_update push payload.
  ///
  /// - If [force_update] is true: shows the blocking [UpdateDialog] as before.
  /// - Otherwise: silently starts a background download via [BackgroundUpdateService].
  Future<void> promptUpdateFromPush(
    BuildContext? context,
    Map<String, dynamic> payload,
  ) async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

      final info = AppVersionInfo.fromJson(payload);
      if (info.version.isEmpty) {
        _log('Skipped push prompt: version is missing in payload.');
        return;
      }

      final resolvedDownloadUrl = _resolveDownloadUrl(info.downloadUrl);
      if (resolvedDownloadUrl.isEmpty) {
        _log('Skipped push prompt: could not resolve download URL.');
        return;
      }

      final shouldUpdate = _isUpdateRequired(
        currentVersion: currentVersion,
        currentBuild: currentBuild,
        serverVersion: info.version,
        serverBuild: info.buildNumber,
      );

      if (!shouldUpdate && !info.forceUpdate) {
        _log('Skipped push prompt: payload does not require an update.');
        return;
      }

      // Force update: show blocking dialog as before
      if (info.forceUpdate) {
        if (context == null || !context.mounted) return;
        if (_dialogVisible) return;
        _dialogVisible = true;
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) {
            return UpdateDialog(
              info: info,
              currentVersion: currentVersion,
              currentBuild: currentBuild,
              downloadUrl: resolvedDownloadUrl,
              downloader: ApkDownloader(),
            );
          },
        );
        _lastPromptedVersion = info.version;
        return;
      }

      // Non-forced: always download silently in the background.
      _log('Starting silent background download for v${info.version}.');
      await BackgroundUpdateService().startBackgroundDownload(
        info,
        resolvedDownloadUrl,
      );
      _lastPromptedVersion = info.version;
    } catch (e) {
      _log('Push update prompt failed: $e');
    } finally {
      _dialogVisible = false;
    }
  }

  /// Polls the version API and, if a newer version is available:
  /// - **force_update = true** → shows the blocking [UpdateDialog] (context required).
  /// - **force_update = false** → silently starts a background download via
  ///   [BackgroundUpdateService]; no dialog is shown.
  ///
  /// Pass [force] = true for user-driven checks (app open / "Check now") to
  /// bypass the passive throttle; it still applies a short debounce.
  Future<void> checkAndPromptUpdate(
    BuildContext? context, {
    bool force = false,
  }) async {
    if (_isChecking) {
      _log('Skipped check: another check is already running.');
      return;
    }
    if (_dialogVisible) {
      _log('Skipped check: update dialog is already visible.');
      return;
    }
    final interval = force ? _minForcedCheckInterval : _minVersionCheckInterval;
    if (_lastVersionCheckTime != null &&
        DateTime.now().difference(_lastVersionCheckTime!) < interval) {
      _log(
        force
            ? 'Skipped forced check: a check ran moments ago.'
            : 'Skipped check: version check was performed recently.',
      );
      return;
    }

    _isChecking = true;
    _lastVersionCheckTime = DateTime.now();
    _log('Starting version check. Endpoint: ${ApiConfig.appVersionUrl}');
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;
      final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
      _log('Installed version: $currentVersion (build: $currentBuild)');

      final response = await http
          .get(Uri.parse(ApiConfig.appVersionUrl))
          .timeout(const Duration(seconds: 12));
      _log('Version API response status: ${response.statusCode}');

      if (response.statusCode != 200) {
        _log('Stopping check: non-200 response from version API.');
        return;
      }

      final payload = json.decode(response.body);
      if (payload is! Map<String, dynamic>) {
        _log('Stopping check: invalid version payload format.');
        return;
      }

      final info = AppVersionInfo.fromJson(payload);
      _log(
        'Server version payload: version=${info.version}, build=${info.buildNumber}, forceUpdate=${info.forceUpdate}',
      );
      if (info.version.isEmpty) {
        _log('Stopping check: server version is empty.');
        return;
      }

      final resolvedDownloadUrl = _resolveDownloadUrl(info.downloadUrl);
      if (resolvedDownloadUrl.isEmpty) {
        _log('Stopping check: could not resolve download URL.');
        return;
      }
      _log('Resolved download URL: $resolvedDownloadUrl');

      final shouldUpdate = _isUpdateRequired(
        currentVersion: currentVersion,
        currentBuild: currentBuild,
        serverVersion: info.version,
        serverBuild: info.buildNumber,
      );

      if (!shouldUpdate) {
        _log('No update available.');
        // If an update is currently downloading or already downloaded, keep it.
        // Otherwise we may erase a pending APK that is still waiting for install.
        if (BackgroundUpdateService().state.value.status ==
            BackgroundUpdateStatus.idle) {
          await BackgroundUpdateService().clearStaleState();
          await clearDeferredUpdatePayload();
        } else {
          _log(
            'Keeping existing background update state while install is pending.',
          );
        }
        return;
      }
      if (_lastPromptedVersion == info.version && !info.forceUpdate) {
        _log('Skipping: same version already handled in this session.');
        return;
      }

      // ── Force update: show blocking dialog ──────────────────────────────
      if (info.forceUpdate) {
        final ctx = context;
        if (ctx == null || !ctx.mounted) {
          _log('Skipped force-update dialog: no valid context.');
          return;
        }
        _dialogVisible = true;
        _log('Showing FORCE update dialog for v${info.version}.');
        await showDialog<void>(
          context: ctx,
          barrierDismissible: false,
          builder: (dialogContext) {
            return UpdateDialog(
              info: info,
              currentVersion: currentVersion,
              currentBuild: currentBuild,
              downloadUrl: resolvedDownloadUrl,
              downloader: ApkDownloader(),
            );
          },
        );
        _lastPromptedVersion = info.version;
        return;
      }

      // ── Normal update: always download silently in the background ─────────
      // The user is never prompted — they only see the install badge + a
      // "ready to install" notification once the download finishes.
      _log('Starting silent background download for v${info.version}.');
      await BackgroundUpdateService().startBackgroundDownload(
        info,
        resolvedDownloadUrl,
      );
      _lastPromptedVersion = info.version;
    } catch (e) {
      _log('Version check failed: $e');
    } finally {
      _isChecking = false;
      _dialogVisible = false;
      _log('Version check finished.');
    }
  }

  bool _isUpdateRequired({
    required String currentVersion,
    required int currentBuild,
    required String serverVersion,
    required int serverBuild,
  }) {
    final versionCmp = _compareSemver(serverVersion, currentVersion);

    // Android installs require higher versionCode for updates.
    // If backend provides build numbers, enforce monotonic increase.
    if (serverBuild > 0 && currentBuild > 0) {
      if (serverBuild <= currentBuild) {
        _log(
          'Not installable as update: server build ($serverBuild) <= installed build ($currentBuild).',
        );
        return false;
      }
      return versionCmp >= 0;
    }

    // Fallback when build numbers are unavailable.
    return versionCmp > 0;
  }

  int _compareSemver(String a, String b) {
    final aParts = _extractVersionParts(a);
    final bParts = _extractVersionParts(b);
    final len = aParts.length > bParts.length ? aParts.length : bParts.length;

    for (var i = 0; i < len; i++) {
      final av = i < aParts.length ? aParts[i] : 0;
      final bv = i < bParts.length ? bParts[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }

    return 0;
  }

  List<int> _extractVersionParts(String version) {
    final matches = RegExp(r'\d+').allMatches(version);
    final parts = matches
        .map((m) => int.tryParse(m.group(0) ?? '0') ?? 0)
        .toList();
    if (parts.isEmpty) return <int>[0];
    return parts;
  }

  String _resolveDownloadUrl(String rawDownloadUrl) {
    if (rawDownloadUrl.trim().isEmpty) {
      return ApiConfig.appDownloadUrl;
    }

    final uri = Uri.tryParse(rawDownloadUrl.trim());
    if (uri == null) return '';

    if (uri.hasScheme) {
      return uri.toString();
    }

    final baseUri = Uri.parse(ApiConfig.baseUrl);
    return baseUri.resolveUri(uri).toString();
  }
}

class UpdateDialog extends StatefulWidget {
  final AppVersionInfo info;
  final String currentVersion;
  final int currentBuild;
  final String downloadUrl;
  final ApkDownloader downloader;

  const UpdateDialog({
    super.key,
    required this.info,
    required this.currentVersion,
    required this.currentBuild,
    required this.downloadUrl,
    required this.downloader,
  });

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _isDownloading = false;
  double _progress = 0;
  String _status = '';

  Map<String, dynamic> _toDeferredPayload() {
    return <String, dynamic>{
      'type': 'app_update',
      'version': widget.info.version,
      'build_number': widget.info.buildNumber,
      'download_url': widget.downloadUrl,
      'force_update': widget.info.forceUpdate,
      'release_notes': widget.info.releaseNotes,
    };
  }

  Future<void> _downloadAndInstall() async {
    setState(() {
      _isDownloading = true;
      _progress = 0;
      _status = 'Starting download...';
    });

    try {
      final authToken = await StorageService.getToken();
      debugPrint(
        '[VersionService] Download starting. Auth token present: ${authToken != null && authToken.isNotEmpty}',
      );
      if (kDebugMode) {
        debugPrint(
          '[VersionService] Debug build detected. Installing a release APK over a debug app usually fails due to signing mismatch.',
        );
      }

      final apkPath = await widget.downloader.downloadApk(
        url: widget.downloadUrl,
        version: widget.info.version,
        buildNumber: widget.info.buildNumber,
        authToken: authToken,
        onLog: (message) => debugPrint('[VersionService] $message'),
        onProgress: (received, total) {
          if (!mounted) return;

          final value = total <= 0 ? 0.0 : (received / total).clamp(0.0, 1.0);
          final receivedMb = (received / 1024 / 1024).toStringAsFixed(1);
          final totalMb = total <= 0
              ? '--'
              : (total / 1024 / 1024).toStringAsFixed(1);

          setState(() {
            _progress = value;
            _status = 'Downloading $receivedMb / $totalMb MB';
          });
        },
      );

      if (!mounted) return;

      setState(() {
        _progress = 1;
        _status = 'Launching installer...';
      });

      final result = await widget.downloader.launchInstaller(apkPath);
      if (!mounted) return;

      if (result.type == ResultType.done) {
        setState(() {
          _isDownloading = false;
          _status =
              'Installer opened. If you see "App not installed" or a conflict error, '
              'uninstall the current version first (Settings → Apps → this app → Uninstall), '
              'then tap "Download & Install" again.';
        });
      } else {
        final fallbackOpened = await _openDownloadInBrowser(widget.downloadUrl);
        final guidance = _buildInstallFailureGuidance(result.message);
        setState(() {
          _isDownloading = false;
          _status = fallbackOpened
              ? 'Could not open installer (${result.message}). Opened download page in browser. $guidance'
              : 'Could not open installer: ${result.message}. $guidance';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _status = 'Update failed: $e';
      });
    }
  }

  Future<bool> _openDownloadInBrowser(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  String _buildInstallFailureGuidance(String? rawMessage) {
    final message = (rawMessage ?? '').toLowerCase();

    if (message.contains('incompatible') ||
        message.contains('update_incompatible') ||
        message.contains('conflict')) {
      return 'The installed app appears to use a different signing key. Uninstall the current app first, then install the new APK.';
    }

    if (message.contains('downgrade')) {
      return 'The downloaded APK has an older build number than the installed app. Install a newer APK.';
    }

    if (message.contains('permission')) {
      return 'Allow "Install unknown apps" for this app in Android settings and try again.';
    }

    return 'If Android shows "App not installed", uninstall the current app and install the downloaded APK manually.';
  }

  @override
  Widget build(BuildContext context) {
    final canDismiss = !widget.info.forceUpdate;
    const appBlue = Color(0xFF1E3A8A);
    const appCard = Color(0xFF344256);
    const appPrimary = Color(0xFF2E2A8B);
    const appSurface = Color(0xFF223246);
    const appText = Color(0xFFE6ECF4);
    const appMutedText = Color(0xFF9FB0C4);

    return PopScope(
      canPop: canDismiss,
      child: AlertDialog(
        backgroundColor: appCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: appBlue.withValues(alpha: 0.55), width: 1),
        ),
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: const LinearGradient(
                  colors: [appBlue, appPrimary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: const Icon(
                Icons.system_update_alt_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Update Available',
                style: TextStyle(
                  color: appText,
                  fontWeight: FontWeight.w700,
                  fontSize: 19,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _VersionBadge(
                  label: 'Current',
                  value: _formatVersionLabel(
                    widget.currentVersion,
                    widget.currentBuild,
                  ),
                ),
                _VersionBadge(
                  label: 'Latest',
                  value: _formatVersionLabel(
                    widget.info.version,
                    widget.info.buildNumber,
                  ),
                ),
              ],
            ),
            if (widget.info.releaseNotes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                widget.info.releaseNotes,
                style: const TextStyle(
                  fontSize: 13,
                  color: appText,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              'Update source: ${_formatSourceLabel(widget.downloadUrl)}',
              style: const TextStyle(fontSize: 12, color: appMutedText),
            ),
            if (_isDownloading || _status.isNotEmpty) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: _isDownloading ? _progress : null,
                  minHeight: 7,
                  backgroundColor: appSurface,
                  valueColor: const AlwaysStoppedAnimation<Color>(appBlue),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: appSurface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: appBlue.withValues(alpha: 0.35)),
                ),
                child: Text(
                  _status,
                  style: const TextStyle(fontSize: 12, color: appText),
                ),
              ),
            ],
            if (widget.info.forceUpdate) ...[
              const SizedBox(height: 10),
              const Text(
                'This update is required to continue using the app.',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: appText,
                ),
              ),
            ],
          ],
        ),
        actions: _isDownloading
            ? null
            : [
                if (!widget.info.forceUpdate)
                  TextButton(
                    onPressed: () async {
                      await VersionService().deferUpdatePayload(
                        _toDeferredPayload(),
                      );
                      if (!mounted) return;
                      Navigator.of(this.context).pop();
                    },
                    child: const Text(
                      'Later',
                      style: TextStyle(color: appMutedText),
                    ),
                  ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: appPrimary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _downloadAndInstall,
                  child: const Text('Download & Install'),
                ),
              ],
      ),
    );
  }

  String _formatSourceLabel(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return ApiConfig.appDownloadUrl;
    final host = uri.host.isEmpty ? ApiConfig.baseUrl : uri.host;
    final path = uri.path.isEmpty ? '/api/mobile/app-download' : uri.path;
    return '$host$path';
  }

  String _formatVersionLabel(String version, int buildNumber) {
    if (buildNumber <= 0) {
      return version;
    }
    return '$version+$buildNumber';
  }
}

class _VersionBadge extends StatelessWidget {
  final String label;
  final String value;

  const _VersionBadge({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    const appBlue = Color(0xFF1E3A8A);
    const appSurface = Color(0xFF223246);
    const appText = Color(0xFFE6ECF4);
    const appMutedText = Color(0xFF9FB0C4);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: appSurface,
        border: Border.all(color: appBlue.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(color: appText, fontSize: 12),
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: appMutedText,
              ),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}
