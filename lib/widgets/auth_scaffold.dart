import 'package:flutter/material.dart';
import 'app_version_text.dart';
import 'offline_banner.dart';

/// Shared scaffold widget for authentication screens.
///
/// Layout tiers:
///   ≥ 900 px wide  → desktop: two-column split (branding left, form right)
///   ≥ 600 px wide  → medium: centered card, no branding panel
///   < 600 px wide  → mobile: compact scaling (original behaviour)
///
/// Desktop and medium layouts never scroll — content compresses to fit 100vh.
class AuthScaffold extends StatelessWidget {
  final String title;
  final Widget child;
  const AuthScaffold({super.key, required this.title, required this.child});

  static const Color blue900 = Color(0xFF1E3A8A);
  static const Color card = Color(0xFF344256);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            const Positioned.fill(
              child: RepaintBoundary(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [blue900, Color(0xFF172554)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  final h = constraints.maxHeight;

                  if (w >= 900) {
                    return _DesktopLayout(
                      title: title,
                      child: child,
                      availableHeight: h,
                    );
                  } else if (w >= 600) {
                    return _MediumLayout(
                      title: title,
                      child: child,
                      availableHeight: h,
                      availableWidth: w,
                    );
                  } else {
                    return _MobileLayout(
                      title: title,
                      child: child,
                      constraints: constraints,
                      width: w,
                      height: h,
                    );
                  }
                },
              ),
            ),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(child: OfflineBanner()),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Desktop layout  (≥ 900 px)
// Fills 100% height — no scroll. Content scales via padding/gap compression.
// ─────────────────────────────────────────────────────────────────────────────
class _DesktopLayout extends StatelessWidget {
  final String title;
  final Widget child;
  final double availableHeight;

  const _DesktopLayout({
    required this.title,
    required this.child,
    required this.availableHeight,
  });

  @override
  Widget build(BuildContext context) {
    // Scale card padding and gaps down when the window is short.
    final vScale = (availableHeight / 800).clamp(0.6, 1.0);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 5, child: _BrandingPanel(vScale: vScale)),
        Expanded(
          flex: 6,
          child: Container(
            color: const Color(0xFF172554),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 48 * vScale),
                  child: _FormCard(title: title, child: child, vScale: vScale),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Medium layout  (600 – 899 px)
// Fills 100% height — no scroll.
// ─────────────────────────────────────────────────────────────────────────────
class _MediumLayout extends StatelessWidget {
  final String title;
  final Widget child;
  final double availableHeight;
  final double availableWidth;

  const _MediumLayout({
    required this.title,
    required this.child,
    required this.availableHeight,
    required this.availableWidth,
  });

  @override
  Widget build(BuildContext context) {
    final vScale = (availableHeight / 800).clamp(0.6, 1.0);
    final hPad = (availableWidth * 0.08).clamp(24.0, 60.0);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          child: _FormCard(
            title: title,
            child: child,
            vScale: vScale,
            showVersion: true,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mobile layout  (< 600 px) — original compact-scaling behaviour, kept as-is
// ─────────────────────────────────────────────────────────────────────────────
class _MobileLayout extends StatelessWidget {
  final String title;
  final Widget child;
  final BoxConstraints constraints;
  final double width;
  final double height;

  const _MobileLayout({
    required this.title,
    required this.child,
    required this.constraints,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    final isCompactHeight = height < 720;
    final isCompactWidth = width < 380;
    final scale = width < 360 || height < 680
        ? 0.88
        : (isCompactWidth || isCompactHeight)
        ? 0.94
        : 1.0;
    final horizontalPadding = (isCompactWidth ? 14.0 : 20.0) * scale;
    final verticalPadding = (isCompactHeight ? 14.0 : 24.0) * scale;
    final cardPadding = EdgeInsets.symmetric(
      horizontal: (isCompactWidth ? 18.0 : 24.0) * scale,
      vertical: (isCompactWidth ? 20.0 : 28.0) * scale,
    );
    final baseTheme = Theme.of(context);
    final scaledTheme = baseTheme.copyWith(
      visualDensity: scale < 1
          ? const VisualDensity(horizontal: -1, vertical: -1)
          : baseTheme.visualDensity,
      materialTapTargetSize: scale < 1
          ? MaterialTapTargetSize.shrinkWrap
          : MaterialTapTargetSize.padded,
      iconTheme: baseTheme.iconTheme.copyWith(
        size: (baseTheme.iconTheme.size ?? 24) * scale,
      ),
      inputDecorationTheme: baseTheme.inputDecorationTheme.copyWith(
        contentPadding: EdgeInsets.symmetric(
          horizontal: 16 * scale,
          vertical: 14 * scale,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: EdgeInsets.symmetric(
            horizontal: 10 * scale,
            vertical: 8 * scale,
          ),
          minimumSize: Size(0, 36 * scale),
          tapTargetSize: scale < 1
              ? MaterialTapTargetSize.shrinkWrap
              : MaterialTapTargetSize.padded,
        ),
      ),
    );

    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        verticalPadding,
        horizontalPadding,
        12,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: constraints.maxHeight - verticalPadding * 2,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Theme(
                data: scaledTheme,
                child: MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: Builder(
                    builder: (context) => Card(
                      color: AuthScaffold.card,
                      elevation: 0,
                      clipBehavior: Clip.antiAlias,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16 * scale),
                      ),
                      child: Padding(
                        padding: cardPadding,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: Theme.of(context).textTheme.headlineMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                            ),
                            SizedBox(
                              height: (isCompactHeight ? 18 : 24) * scale,
                            ),
                            child,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: 16 * scale),
            const AppVersionText(),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Form card — used by desktop and medium layouts.
// vScale compresses vertical padding and gaps to fit the available height.
// ─────────────────────────────────────────────────────────────────────────────
class _FormCard extends StatelessWidget {
  final String title;
  final Widget child;

  /// 0.6 – 1.0: compresses vertical rhythm when the window is short.
  final double vScale;
  final bool showVersion;

  const _FormCard({
    required this.title,
    required this.child,
    required this.vScale,
    this.showVersion = false,
  });

  @override
  Widget build(BuildContext context) {
    final vPad = 36.0 * vScale;
    final titleGap = 24.0 * vScale;

    return Card(
      color: AuthScaffold.card,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32, vertical: vPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: Colors.white,
                // Slightly smaller title when very compressed
                fontSize: vScale < 0.75 ? 22 : null,
              ),
            ),
            SizedBox(height: titleGap),
            // Pass vScale down so the child can compress its own gaps.
            AuthVScale(vScale: vScale, child: child),
            if (showVersion) ...[
              SizedBox(height: 8 * vScale),
              const AppVersionText(),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Public InheritedWidget that carries vScale down to form content widgets
// so they can compress their own spacing.
// Usage: AuthVScale.of(context)  →  double between 0.6 and 1.0
// ─────────────────────────────────────────────────────────────────────────────
class AuthVScale extends InheritedWidget {
  final double vScale;
  const AuthVScale({required this.vScale, required super.child});

  /// Returns the current vertical scale factor (0.6–1.0).
  /// Falls back to 1.0 when not inside a desktop/medium layout (e.g. mobile).
  static double of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AuthVScale>()?.vScale ??
        1.0;
  }

  @override
  bool updateShouldNotify(AuthVScale old) => old.vScale != vScale;
}

// ─────────────────────────────────────────────────────────────────────────────
// Branding panel — left side of desktop layout.
// vScale compresses vertical spacing when the window is short.
// ─────────────────────────────────────────────────────────────────────────────
class _BrandingPanel extends StatelessWidget {
  final double vScale;
  const _BrandingPanel({required this.vScale});

  static const Color _accent = Color(0xFF00E5FF);

  @override
  Widget build(BuildContext context) {
    final iconSize = 72.0 * vScale;
    final gap1 = 32.0 * vScale;
    final gap2 = 12.0 * vScale;
    final gap3 = 40.0 * vScale;
    final bulletGap = 14.0 * vScale;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1E3A8A), Color(0xFF1e2d6b)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(48 * vScale),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: iconSize,
                height: iconSize,
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20 * vScale),
                  border: Border.all(
                    color: _accent.withValues(alpha: 0.4),
                    width: 1.5,
                  ),
                ),
                child: Icon(
                  Icons.chat_bubble_rounded,
                  color: _accent,
                  size: 36 * vScale,
                ),
              ),
              SizedBox(height: gap1),
              Text(
                'Messenger',
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  fontSize: vScale < 0.75 ? 28 : null,
                ),
              ),
              SizedBox(height: gap2),
              Text(
                'Stay connected with the\npeople who matter most.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Colors.white.withValues(alpha: 0.65),
                  height: 1.6,
                ),
              ),
              SizedBox(height: gap3),
              ..._features.map(
                (f) => Padding(
                  padding: EdgeInsets.only(bottom: bulletGap),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: _accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(f.icon, color: _accent, size: 16),
                      ),
                      const SizedBox(width: 14),
                      Text(
                        f.label,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const _features = [
    _Feature(Icons.lock_rounded, 'End-to-end encrypted'),
    _Feature(Icons.bolt_rounded, 'Real-time messaging'),
    _Feature(Icons.group_rounded, 'Group conversations'),
    _Feature(Icons.mic_rounded, 'Voice messages'),
  ];
}

class _Feature {
  final IconData icon;
  final String label;
  const _Feature(this.icon, this.label);
}
