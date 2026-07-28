import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/storage_service.dart';

/// Opens an Excalidraw board inside the app instead of bouncing out to the
/// system browser.
///
/// Two things make this more than a plain WebView:
///
///  * **Auth.** The board is login-gated, and the app holds a JWT rather than a
///    web session cookie. The first page request carries an `Authorization`
///    header; the backend upgrades that to a session cookie, which the WebView
///    then sends on every asset and API request the drawing makes. Headers
///    alone would not be enough — they apply to the main frame only.
///  * **The room key.** It lives in the URL fragment (`#room=<id>,<key>`) and
///    is never sent to the server. Keeping the board in-app keeps that fragment
///    out of an external browser's history and sync.
class ExcalidrawBoardScreen extends StatefulWidget {
  const ExcalidrawBoardScreen({
    super.key,
    required this.url,
    this.title = 'Excalidraw',
  });

  final String url;
  final String title;

  @override
  State<ExcalidrawBoardScreen> createState() => _ExcalidrawBoardScreenState();
}

class _ExcalidrawBoardScreenState extends State<ExcalidrawBoardScreen> {
  static const Color _orange = Color(0xFFF97316);

  WebViewController? _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    final token = await StorageService.getToken();
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF121212))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            // Subresource failures are noisy and mostly harmless (the board
            // pulls optional fonts from a CDN); only the main frame matters.
            if (!error.isForMainFrame!) return;
            if (mounted) {
              setState(() {
                _loading = false;
                _error = error.description;
              });
            }
          },
        ),
      );

    await controller.loadRequest(
      Uri.parse(widget.url),
      headers: {if (token != null) 'Authorization': 'Bearer $token'},
    );

    if (mounted) setState(() => _controller = controller);
  }

  Future<void> _openExternally() async {
    await launchUrl(
      Uri.parse(widget.url),
      mode: LaunchMode.externalApplication,
    );
  }

  /// Let the board's own history absorb the back gesture before leaving.
  Future<bool> _handleBack() async {
    final controller = _controller;
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _handleBack() && mounted) {
          if (!context.mounted) return;
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          backgroundColor: const Color(0xFFEA580C),
          foregroundColor: Colors.white,
          title: Text(
            widget.title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          actions: [
            IconButton(
              tooltip: 'Reload',
              onPressed: controller == null
                  ? null
                  : () {
                      setState(() => _error = null);
                      controller.reload();
                    },
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'Open in browser',
              onPressed: _openExternally,
              icon: const Icon(Icons.open_in_browser),
            ),
          ],
        ),
        body: Stack(
          children: [
            if (controller != null) WebViewWidget(controller: controller),
            if (_error != null) _errorPanel(),
            if (_loading && _error == null)
              const LinearProgressIndicator(
                minHeight: 2.5,
                color: _orange,
                backgroundColor: Colors.transparent,
              ),
          ],
        ),
      ),
    );
  }

  Widget _errorPanel() {
    return Container(
      color: const Color(0xFF121212),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, color: Colors.white38, size: 44),
          const SizedBox(height: 14),
          const Text(
            'Could not load the board',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _error ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 12.5),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            children: [
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _error = null;
                    _loading = true;
                  });
                  _controller?.reload();
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: _orange),
                ),
                child: const Text('Try again'),
              ),
              TextButton(
                onPressed: _openExternally,
                child: const Text(
                  'Open in browser',
                  style: TextStyle(color: _orange),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
