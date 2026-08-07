import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Thin wrapper around [CachedNetworkImage] used everywhere chat content
/// renders remote images. Centralising it here means we can tune disk
/// caching, placeholders, and error fallbacks in one place.
///
/// Behaviour vs `Image.network`:
///   - Persists each fetched image to disk (`flutter_cache_manager`), so
///     reopening the chat offline still shows previously seen media.
///   - Keeps the same `cacheWidth`/`fit`/`width`/`height` knobs we used
///     before so layout is unchanged.
///   - Uses the same neutral placeholder everywhere to avoid layout shifts
///     while the disk/network read resolves.
class CachedImage extends StatelessWidget {
  const CachedImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.cacheHeight,
    this.placeholderColor = const Color(0xFF1F2937),
    this.errorWidget,
    this.fadeInDuration = const Duration(milliseconds: 120),
    this.filterQuality = FilterQuality.low,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// Optional decode-time downscaling; mirrors `Image.network`'s `cacheWidth`.
  final int? cacheWidth;
  final int? cacheHeight;

  final Color placeholderColor;
  final Widget? errorWidget;
  final Duration fadeInDuration;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      imageUrl: url,
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: cacheWidth,
      memCacheHeight: cacheHeight,
      filterQuality: filterQuality,
      fadeInDuration: fadeInDuration,
      placeholder: (context, _) => Container(color: placeholderColor),
      errorWidget: (context, _, __) =>
          errorWidget ?? _defaultErrorWidget(),
    );
  }

  /// Precache an image into memory so that it displays instantly when the widget is mounted.
  static void precache(BuildContext context, String url, {int? cacheWidth}) {
    if (url.isEmpty) return;
    final ImageProvider provider = CachedNetworkImageProvider(url);
    final ImageProvider finalProvider = cacheWidth != null
        ? ResizeImage(provider, width: cacheWidth)
        : provider;
    precacheImage(finalProvider, context).catchError((_) => null);
  }

  Widget _defaultErrorWidget() {
    return Container(
      color: const Color(0xFF1F2937),
      alignment: Alignment.center,
      child: const Icon(
        Icons.broken_image_outlined,
        color: Colors.white54,
        size: 32,
      ),
    );
  }
}
