import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../models/link_preview.dart';
import '../../models/message.dart';
import '../../services/link_preview_service.dart';
import '../../widgets/cached_image.dart';
import '../../widgets/file_type_icon.dart';
import '../../widgets/link_preview_card.dart';
import '../../widgets/youtube_preview_card.dart';
import 'audio_message_player.dart';
import 'contact_card_widget.dart';

class ChatMessageBubble extends StatefulWidget {
  const ChatMessageBubble({
    super.key,
    required this.message,
    required this.isSentByMe,
    required this.scale,
    required this.showTimestamps,
    required this.isSelected,
    required this.messageReactions,
    required this.messageTranslations,
    required this.onTapUp,
    this.onDoubleTap,
    required this.onLongPress,
    required this.onShowReactionPicker,
    required this.onOpenMediaViewer,
    required this.onDownloadIncomingFile,
    required this.onOpenMessageUrl,
    required this.statusForUi,
    required this.isOnlyFilename,
    required this.canQuickToggleExcalidrawPin,
    required this.formatFileSize,
    required this.buildReactionPills,
    required this.buildLinkifiedMessageText,
    required this.buildStatusIndicator,
    this.senderName,
    this.senderColor,
    this.seenByNames,
    this.deliveredToNames,
  });

  final Message message;
  final bool isSentByMe;
  final double scale;

  /// Group chat only: seen by and delivered to tracking lists
  final List<String>? seenByNames;
  final List<String>? deliveredToNames;

  /// Group chat only: name of the sender shown as a colored label at the top of
  /// incoming bubbles (WhatsApp-style). Null/empty in 1:1 chat, where it is
  /// never rendered so the layout is identical to before.
  final String? senderName;
  final Color? senderColor;
  final bool showTimestamps;
  final bool isSelected;
  final Map<int, Map<String, Set<String>>> messageReactions;
  final Map<int, String> messageTranslations;
  final void Function(TapUpDetails details) onTapUp;
  final VoidCallback? onDoubleTap;
  final VoidCallback onLongPress;
  final void Function(BuildContext context, int messageId, Offset position)
  onShowReactionPicker;
  final void Function(Message message) onOpenMediaViewer;
  final void Function(Message message) onDownloadIncomingFile;
  final void Function(String url) onOpenMessageUrl;
  final String Function(Message message) statusForUi;
  final bool Function(String content) isOnlyFilename;
  final bool Function(Message message) canQuickToggleExcalidrawPin;
  final String Function(int fileSize) formatFileSize;
  final Widget Function(int messageId) buildReactionPills;
  final Widget Function({
    required String text,
    required bool isTaskMessage,
    required Color taskAccentColor,
  })
  buildLinkifiedMessageText;
  final Widget Function(String status, double scale) buildStatusIndicator;

  @override
  State<ChatMessageBubble> createState() => _ChatMessageBubbleState();
}

class _ChatMessageBubbleState extends State<ChatMessageBubble> {
  LinkPreview? _linkPreview;
  bool _previewLoaded = false;

  @override
  void initState() {
    super.initState();
    // Only fetch previews for non-deleted text messages that actually
    // contain a URL. Without the URL guard every plain-text bubble fired an
    // async pass + an extra setState as it scrolled into view — wasted work
    // on the scroll hot path for the common (no-link) case.
    if (widget.message.messageType == 'text' &&
        !widget.message.isDeleted &&
        LinkPreviewService().extractFirstUrl(widget.message.content) != null) {
      _fetchPreview();
    }
  }

  Future<void> _fetchPreview() async {
    final preview = await LinkPreviewService().getPreview(
      widget.message.content,
    );
    if (mounted) {
      setState(() {
        _linkPreview = preview;
        _previewLoaded = true;
      });
    }
  }

  String _extractYouTubeIdFromThumbnail(String thumbnailUrl) {
    // URL format: https://img.youtube.com/vi/{videoId}/hqdefault.jpg
    final uri = Uri.tryParse(thumbnailUrl);
    if (uri == null) return '';
    final segments = uri.pathSegments;
    // pathSegments for /vi/{videoId}/hqdefault.jpg → ['vi', '{videoId}', 'hqdefault.jpg']
    if (segments.length >= 2 && segments[0] == 'vi') {
      return segments[1];
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    // Cap the bubble width so messages stay readable in the wide desktop
    // two-pane layout (where MediaQuery reports the full window width) instead
    // of stretching across the whole chat pane. Mobile widths fall well under
    // the cap, so phone layout is unchanged.
    final maxBubbleWidth = math.min(
      MediaQuery.of(context).size.width * (widget.scale < 0.9 ? 0.82 : 0.70),
      560.0,
    );
    final int imageCacheWidth =
        ((maxBubbleWidth * MediaQuery.of(context).devicePixelRatio)
                .round()
                .clamp(320, 2048))
            as int;
    final bool isImage =
        widget.message.messageType == 'image' ||
        (widget.message.fileType?.startsWith('image/') ?? false);
    final bool isVideo =
        widget.message.messageType == 'video' ||
        (widget.message.fileType?.startsWith('video/') ?? false);
    final bool isAudio =
        widget.message.messageType == 'voice' ||
        widget.message.messageType == 'audio' ||
        (widget.message.fileType?.startsWith('audio/') ?? false);
    final bool isMedia = isImage || isVideo;
    final bool isContact = widget.message.messageType == 'contact';
    final bool isGenericFile =
        (!isMedia && !isAudio && !isContact) &&
        ((widget.message.messageType == 'file' ||
                widget.message.messageType == 'document') ||
            (widget.message.fileUrl != null &&
                widget.message.fileUrl!.isNotEmpty));
    final bool canSaveAttachment =
        widget.message.fileUrl != null &&
        widget.message.fileUrl!.isNotEmpty &&
        (isMedia || isAudio || isGenericFile);

    final hasReactions =
        widget.messageReactions[widget.message.id] != null &&
        widget.messageReactions[widget.message.id]!.isNotEmpty;
    final isTaskMessage = widget.message.isTask;
    final bool isTaskCompleted = widget.message.taskCompletedAt != null;
    final bool isPinnedExcalidraw =
        widget.canQuickToggleExcalidrawPin(widget.message) &&
        widget.message.excalidrawPinnedAt != null;
    const excalidrawAccentColor = Color(0xFFB794F6);
    final taskAccentColor = isTaskCompleted
        ? const Color(0xFF22C55E)
        : const Color(0xFFF59E0B);
    final bubbleAccentColor = isTaskMessage
        ? taskAccentColor
        : (isPinnedExcalidraw ? excalidrawAccentColor : null);

    final bubbleWidget = GestureDetector(
      onTapUp: (details) {
        widget.onTapUp(details);
      },
      onDoubleTap: widget.onDoubleTap,
      onLongPress: widget.onLongPress,
      child: Container(
        margin: EdgeInsets.only(bottom: hasReactions ? 2 : 12),
        constraints: BoxConstraints(maxWidth: maxBubbleWidth),
        decoration: BoxDecoration(
          color: widget.isSentByMe
              ? const Color(0xFF420796)
              : const Color(0xFF3944BC),
          border: bubbleAccentColor != null
              ? Border.all(
                  color: bubbleAccentColor.withValues(alpha: 0.85),
                  width: 1.4,
                )
              : null,
          boxShadow: bubbleAccentColor != null
              ? [
                  BoxShadow(
                    color: bubbleAccentColor.withValues(alpha: 0.45),
                    blurRadius: 14,
                    spreadRadius: 0.2,
                  ),
                ]
              : null,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(widget.isSentByMe ? 16 : 4),
            bottomRight: Radius.circular(widget.isSentByMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!widget.isSentByMe &&
                widget.senderName != null &&
                widget.senderName!.isNotEmpty)
              _buildSenderHeader(
                widget.senderName!,
                widget.senderColor,
                widget.scale,
              ),
            if (isPinnedExcalidraw)
              _buildPinnedExcalidrawLabel(widget.scale, excalidrawAccentColor),
            if (widget.message.replyToId != null ||
                widget.message.replyPreview != null)
              _buildReplyPreview(widget.message, widget.scale),
            if (isMedia &&
                (widget.message.fileUrl != null ||
                    widget.message.localFilePath != null))
              _buildMediaContent(
                isImage,
                isVideo,
                widget.message,
                imageCacheWidth,
              ),
            // _buildMediaFileInfo removed to prevent duplicate/redundant file info bar below media
            if (isAudio && widget.message.fileUrl != null)
              AudioMessagePlayer(
                audioUrl: widget.message.fileUrl!,
                fileSize: widget.message.fileSize,
                initialDuration: widget.message.duration,
              ),
            if (isContact)
              ContactCardWidget(
                vcard: widget.message.content,
                isSentByMe: widget.isSentByMe,
              ),
            if (isGenericFile)
              _buildGenericFileContent(
                widget.message,
                taskAccentColor,
                widget.scale,
              ),
            if (!isContact &&
                ((!isMedia && !isAudio && !isGenericFile) ||
                    (widget.message.content.isNotEmpty &&
                        !widget.isOnlyFilename(widget.message.content) &&
                        !isAudio &&
                        !isGenericFile) ||
                    (widget.message.caption != null &&
                        widget.message.caption!.isNotEmpty)))
              _buildTextContent(
                widget.message,
                isTaskMessage,
                taskAccentColor,
                widget.scale,
              )
            else if (isMedia || isAudio)
              const SizedBox(height: 8),
            // Link preview card — rendered inside the bubble, above the status row
            if (_previewLoaded && _linkPreview != null)
              _buildInlineLinkPreview(_linkPreview!),
            if (widget.isSentByMe)
              _buildSentStatusRow(
                widget.message,
                widget.scale,
                canSaveAttachment: canSaveAttachment,
              )
            else
              _buildIncomingTimeRow(
                widget.message,
                widget.scale,
                canSaveAttachment: canSaveAttachment,
              ),
            if (widget.showTimestamps)
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 16 * widget.scale,
                  vertical: 6 * widget.scale,
                ),
                child: Text(
                  widget.message.formattedTimestampFull,
                  style: TextStyle(
                    color: const Color(0xFFFF69B4),
                    fontSize: 12 * widget.scale,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return AnimatedContainer(
      duration: Duration.zero,
      curve: Curves.easeOut,
      color: widget.isSelected
          ? Colors.white.withValues(alpha: 0.07)
          : Colors.transparent,
      child: Align(
        alignment: widget.isSentByMe
            ? Alignment.centerRight
            : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: widget.isSentByMe
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
                    // Flexible so a max-width bubble can shrink to leave room
                    // for the reaction icon instead of overflowing (notably in
                    // the wider desktop chat pane).
                    Flexible(child: bubbleWidget),
                    if (!widget.isSentByMe)
                      GestureDetector(
                        onTap: () {
                          final renderBox =
                              rowContext.findRenderObject() as RenderBox?;
                          if (renderBox != null) {
                            final position = renderBox.localToGlobal(
                              Offset.zero,
                            );
                            widget.onShowReactionPicker(
                              context,
                              widget.message.id,
                              position,
                            );
                          }
                        },
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 4 * widget.scale,
                          ),
                          child: Icon(
                            Icons.sentiment_satisfied_alt_outlined,
                            color: Colors.white.withValues(alpha: 0.6),
                            size: 22 * widget.scale,
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
                  left: widget.isSentByMe ? 0 : 8,
                  right: widget.isSentByMe ? 8 : 0,
                  top: 0,
                  bottom: 6,
                ),
                child: widget.buildReactionPills(widget.message.id),
              ),
          ],
        ),
      ),
    );
  }

  /// Group chat sender label at the top of an incoming bubble.
  Widget _buildSenderHeader(String name, Color? color, double scale) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12 * scale, 6 * scale, 12 * scale, 0),
      child: Text(
        name,
        style: TextStyle(
          color: color ?? const Color(0xFFB794F6),
          fontSize: 12.5 * scale,
          fontWeight: FontWeight.w700,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildPinnedExcalidrawLabel(
    double scale,
    Color excalidrawAccentColor,
  ) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12 * scale, 8 * scale, 12 * scale, 2),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 9 * scale,
          vertical: 3 * scale,
        ),
        decoration: BoxDecoration(
          color: excalidrawAccentColor.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: excalidrawAccentColor.withValues(alpha: 0.55),
          ),
        ),
        child: Text(
          'Pinned Excalidraw',
          style: TextStyle(
            color: Colors.white,
            fontSize: 11 * scale,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildReplyPreview(Message message, double scale) {
    final preview = message.replyPreview ?? '';
    final colonIndex = preview.indexOf(':');
    final senderName = colonIndex > 0
        ? preview.substring(0, colonIndex)
        : 'Reply';
    var contentText = colonIndex > 0
        ? preview.substring(colonIndex + 1).trim()
        : preview;

    // Safety net only for legacy/raw HTML that wasn't already cleaned upstream
    // (the model parser + backend normally provide a clean label or filename).
    // We intentionally do NOT collapse filenames like "report.pdf" into a generic
    // "File" anymore — the real name is shown instead.
    if (contentText.contains('<') && contentText.contains('>')) {
      if (contentText.contains('<audio')) {
        contentText = '🎤 Voice message';
      } else if (contentText.contains('<img')) {
        contentText = '🖼️ Photo';
      } else if (contentText.contains('<video')) {
        contentText = '🎥 Video';
      } else {
        contentText = contentText.replaceAll(RegExp(r'<[^>]*>'), '').trim();
        if (contentText.isEmpty) contentText = '📎 File';
      }
    }

    return Opacity(
      opacity: 0.85,
      child: Container(
        margin: EdgeInsets.only(
          left: 8 * scale,
          right: 8 * scale,
          top: 8 * scale,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: 10 * scale,
          vertical: 6 * scale,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: const Border(
            left: BorderSide(color: Color(0xFFB794F6), width: 3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              senderName,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 11 * scale,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 2 * scale),
            Text(
              contentText,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 12 * scale,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaContent(
    bool isImage,
    bool isVideo,
    Message message,
    int imageCacheWidth,
  ) {
    final hasText =
        (message.content.isNotEmpty &&
            !widget.isOnlyFilename(message.content)) ||
        (message.caption != null && message.caption!.isNotEmpty);

    final borderRadius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(hasText ? 0 : (widget.isSentByMe ? 16 : 4)),
      bottomRight: Radius.circular(hasText ? 0 : (widget.isSentByMe ? 4 : 16)),
    );

    final showLocal =
        message.localFilePath != null &&
        message.localFilePath!.isNotEmpty &&
        File(message.localFilePath!).existsSync();

    // Fixed media box: the bubble reserves the same space whether the image/
    // video is still loading, loaded, or failed. This eliminates the layout
    // "jump" that happened when the placeholder (no intrinsic size) was
    // replaced by an aspect-ratio-sized image. A stable box + BoxFit.cover
    // means zero relayout on load. The full, uncropped media is shown in the
    // media viewer on tap.
    final mediaWidth = math.min(
      MediaQuery.of(context).size.width * (widget.scale < 0.9 ? 0.82 : 0.70),
      560.0,
    );
    final mediaHeight = (mediaWidth * 0.75).clamp(180.0, 300.0);

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: borderRadius,
        child: GestureDetector(
          onTap: () => widget.onOpenMediaViewer(message),
          child: SizedBox(
            width: mediaWidth,
            height: mediaHeight,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(child: Container(color: Colors.grey[850])),
                if (isImage)
                  Positioned.fill(
                    child: showLocal
                        ? Image.file(
                            File(message.localFilePath!),
                            fit: BoxFit.cover,
                          )
                        : CachedImage(
                            url: message.fileUrl ?? '',
                            fit: BoxFit.cover,
                            cacheWidth: imageCacheWidth,
                            filterQuality: FilterQuality.low,
                            placeholderColor: const Color(0xFF1F2937),
                            errorWidget: Container(
                              color: Colors.grey[800],
                              child: const Center(
                                child: Icon(
                                  Icons.broken_image,
                                  color: Colors.white54,
                                  size: 40,
                                ),
                              ),
                            ),
                          ),
                  )
                else if (isVideo)
                  Positioned.fill(
                    child: showLocal
                        ? _VideoThumbnailWidget(
                            localFilePath: message.localFilePath,
                            cacheWidth: imageCacheWidth,
                          )
                        : _VideoThumbnailWidget(
                            videoUrl: message.fileUrl ?? '',
                            cacheWidth: imageCacheWidth,
                          ),
                  ),

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

                // Loader overlay inside the bubble when pending (waiting/uploading/retrying)
                if (message.status == 'pending')
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(10),
                    child: const CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Builds a compact file info row below media content showing filename and size.
  Widget _buildMediaFileInfo(Message message, double scale) {
    final fileName = message.fileName ?? '';
    final fileSize = message.fileSize;

    // Don't show if no useful info available
    if (fileName.isEmpty && fileSize == null) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 12 * scale,
        vertical: 6 * scale,
      ),
      child: Row(
        children: [
          Icon(
            message.messageType == 'video' ||
                    (message.fileType?.startsWith('video/') ?? false)
                ? Icons.videocam_outlined
                : Icons.image_outlined,
            color: Colors.white54,
            size: 14 * scale,
          ),
          SizedBox(width: 6 * scale),
          Expanded(
            child: Text(
              fileName.isNotEmpty ? fileName : 'Media',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11 * scale,
                fontWeight: FontWeight.w400,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (fileSize != null && fileSize > 0) ...[
            SizedBox(width: 8 * scale),
            Text(
              _formatMediaFileSize(fileSize),
              style: TextStyle(color: Colors.white38, fontSize: 11 * scale),
            ),
          ],
        ],
      ),
    );
  }

  /// Formats bytes into a human-readable file size string.
  String _formatMediaFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Widget _buildGenericFileContent(
    Message message,
    Color taskAccentColor,
    double scale,
  ) {
    final String fileName = (message.fileName?.isNotEmpty ?? false)
        ? message.fileName!
        : (message.fileUrl != null
              ? (Uri.tryParse(
                      message.fileUrl!,
                    )?.pathSegments.last.replaceAll('%20', ' ') ??
                    'File')
              : 'File');
    final String ext = FileTypeIcon.extensionOf(fileName);
    final String sizeStr = (message.fileSize != null && message.fileSize! > 0)
        ? widget.formatFileSize(message.fileSize!)
        : (message.fileUrl != null ? 'Unknown size' : 'File not available');
    final String subtitle = ext.isNotEmpty
        ? '${ext.toUpperCase()} · $sizeStr'
        : sizeStr;

    return Container(
      padding: EdgeInsets.all(14 * scale),
      child: Row(
        children: [
          // Web-matching document icon with the extension baked in.
          FileTypeIcon(fileName: fileName, scale: scale),
          SizedBox(width: 12 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13 * scale,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: 3 * scale),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12 * scale,
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

  Widget _buildTextContent(
    Message message,
    bool isTaskMessage,
    Color taskAccentColor,
    double scale,
  ) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 16 * scale,
        vertical: 10 * scale,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          widget.buildLinkifiedMessageText(
            text: isMediaDescription(message, isMedia: false),
            isTaskMessage: isTaskMessage,
            taskAccentColor: taskAccentColor,
          ),
          if (widget.messageTranslations.containsKey(message.id)) ...[
            const SizedBox(height: 8),
            Container(
              height: 1,
              color: Colors.white.withValues(alpha: 0.3),
              margin: const EdgeInsets.symmetric(vertical: 4),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.language,
                  size: 14,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 4),
                Text(
                  'auto → en',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.messageTranslations[message.id]!,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 14,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String isMediaDescription(Message message, {required bool isMedia}) {
    if (message.caption != null && message.caption!.isNotEmpty) {
      return message.caption!;
    }
    return message.content;
  }

  /// Renders the link preview content inline inside the bubble container.
  /// No separate card background — the bubble itself is the container.
  Widget _buildInlineLinkPreview(LinkPreview preview) {
    final scale = widget.scale;
    if (preview.isYouTube) {
      final videoId = _extractYouTubeIdFromThumbnail(preview.imageUrl ?? '');
      if (videoId.isEmpty) return const SizedBox.shrink();
      return _buildInlineYouTubePreview(videoId, preview.title, scale);
    }
    return _buildInlineOgPreview(preview, scale);
  }

  Widget _buildInlineYouTubePreview(
    String videoId,
    String? title,
    double scale,
  ) {
    final thumbUrl = 'https://img.youtube.com/vi/$videoId/hqdefault.jpg';
    final fallbackUrl = 'https://img.youtube.com/vi/$videoId/mqdefault.jpg';
    final watchUrl = 'https://www.youtube.com/watch?v=$videoId';

    return GestureDetector(
      onTap: () async {
        try {
          final uri = Uri.parse(watchUrl);
          // ignore: deprecated_member_use
          if (await canLaunchUrl(uri))
            await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {}
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Thumbnail with play overlay — flush to bubble edges
          ClipRRect(
            borderRadius: BorderRadius.zero,
            child: AspectRatio(
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
                      width: 48 * scale,
                      height: 48 * scale,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.play_arrow,
                        color: Colors.white,
                        size: 30 * scale,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // YouTube branding + title
          Padding(
            padding: EdgeInsets.fromLTRB(
              12 * scale,
              6 * scale,
              12 * scale,
              4 * scale,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.play_circle_fill,
                      color: const Color(0xFFFF0000),
                      size: 12 * scale,
                    ),
                    SizedBox(width: 4 * scale),
                    Text(
                      'YouTube',
                      style: TextStyle(
                        color: const Color(0xFFFF0000),
                        fontSize: 10 * scale,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
                if (title != null && title.isNotEmpty) ...[
                  SizedBox(height: 2 * scale),
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12 * scale,
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

  Widget _buildInlineOgPreview(LinkPreview preview, double scale) {
    final domain = (Uri.tryParse(preview.url)?.host ?? preview.url)
        .replaceFirst('www.', '')
        .toUpperCase();

    return GestureDetector(
      onTap: () async {
        try {
          final uri = Uri.parse(preview.url);
          // ignore: deprecated_member_use
          if (await canLaunchUrl(uri))
            await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {}
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // OG image — flush to bubble edges
          if (preview.imageUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.zero,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.network(
                  preview.imageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          // Domain + title + description
          Padding(
            padding: EdgeInsets.fromLTRB(
              12 * scale,
              6 * scale,
              12 * scale,
              4 * scale,
            ),
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
                        width: 12 * scale,
                        height: 12 * scale,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                      SizedBox(width: 4 * scale),
                    ],
                    Flexible(
                      child: Text(
                        domain,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: const Color(0xFFa78bfa),
                          fontSize: 10 * scale,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (preview.title != null && preview.title!.isNotEmpty) ...[
                  SizedBox(height: 3 * scale),
                  Text(
                    preview.title!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12 * scale,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
                if (preview.description != null &&
                    preview.description!.isNotEmpty) ...[
                  SizedBox(height: 2 * scale),
                  Text(
                    preview.description!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 11 * scale,
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

  Widget _buildSentStatusRow(
    Message message,
    double scale, {
    required bool canSaveAttachment,
  }) {
    final hasSeenNames = widget.seenByNames != null && widget.seenByNames!.isNotEmpty;
    final hasDeliveredNames = widget.deliveredToNames != null && widget.deliveredToNames!.isNotEmpty;

    Widget statusRow;
    if (!canSaveAttachment) {
      statusRow = Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 16 * scale,
          vertical: 4 * scale,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              '${message.isEdited ? '(edited) ' : ''}${message.formattedTime}',
              style: TextStyle(color: Colors.white70, fontSize: 11 * scale),
            ),
            SizedBox(width: 4 * scale),
            widget.buildStatusIndicator(widget.statusForUi(message), scale),
          ],
        ),
      );
    } else {
      statusRow = Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 16 * scale,
          vertical: 4 * scale,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            Text(
              '${message.isEdited ? '(edited) ' : ''}${message.formattedTime}',
              style: TextStyle(color: Colors.white70, fontSize: 11 * scale),
            ),
            SizedBox(width: 4 * scale),
            widget.buildStatusIndicator(widget.statusForUi(message), scale),
            const Spacer(),
            _buildFooterSaveAction(message, scale),
          ],
        ),
      );
    }

    if (!hasSeenNames && !hasDeliveredNames) {
      return statusRow;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        statusRow,
        Padding(
          padding: EdgeInsets.only(
            left: 16 * scale,
            right: 16 * scale,
            bottom: 6 * scale,
          ),
          child: Text(
            hasSeenNames
                ? 'Seen by: ${widget.seenByNames!.join(', ')}'
                : 'Delivered to: ${widget.deliveredToNames!.join(', ')}',
            style: TextStyle(
              color: Colors.white60,
              fontSize: 9.5 * scale,
              fontStyle: FontStyle.italic,
            ),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }

  Widget _buildIncomingTimeRow(
    Message message,
    double scale, {
    required bool canSaveAttachment,
  }) {
    if (!canSaveAttachment) {
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 16 * scale,
          vertical: 6 * scale,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${message.isEdited ? '(edited) ' : ''}${message.formattedTime}',
              style: TextStyle(color: Colors.white70, fontSize: 11 * scale),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 16 * scale,
        vertical: 6 * scale,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          Text(
            '${message.isEdited ? '(edited) ' : ''}${message.formattedTime}',
            style: TextStyle(color: Colors.white70, fontSize: 11 * scale),
          ),
          const Spacer(),
          _buildFooterSaveAction(message, scale),
        ],
      ),
    );
  }

  Widget _buildFooterSaveAction(Message message, double scale) {
    return TextButton(
      onPressed: () => widget.onDownloadIncomingFile(message),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.symmetric(horizontal: 8 * scale, vertical: 0),
        visualDensity: const VisualDensity(horizontal: -3, vertical: -3),
      ),
      child: Text(
        'Save',
        style: TextStyle(
          fontSize: 11 * scale,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }
}

/// Lightweight video thumbnail widget that initializes a VideoPlayerController
/// to display the first frame of a video as a preview in chat bubbles.
/// Disposes the controller when scrolled off-screen.
class _VideoThumbnailWidget extends StatefulWidget {
  final String? videoUrl;
  final String? localFilePath;
  final int cacheWidth;

  const _VideoThumbnailWidget({
    this.videoUrl,
    this.localFilePath,
    required this.cacheWidth,
  });

  @override
  State<_VideoThumbnailWidget> createState() => _VideoThumbnailWidgetState();
}

class _VideoThumbnailWidgetState extends State<_VideoThumbnailWidget> {
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
      // Prefer the local file path if present, otherwise network/cached URL.
      VideoPlayerController controller;
      if (widget.localFilePath != null &&
          widget.localFilePath!.isNotEmpty &&
          File(widget.localFilePath!).existsSync()) {
        controller = VideoPlayerController.file(File(widget.localFilePath!));
      } else if (widget.videoUrl != null && widget.videoUrl!.isNotEmpty) {
        final cached = await DefaultCacheManager().getFileFromCache(
          widget.videoUrl!,
        );
        if (cached != null) {
          controller = VideoPlayerController.file(cached.file);
        } else {
          controller = VideoPlayerController.networkUrl(
            Uri.parse(widget.videoUrl!),
          );
          // Fire-and-forget: warm the cache so subsequent opens (and
          // offline reopens) play instantly from disk. Errors are
          // expected on flaky networks; just swallow them here.
          unawaited(() async {
            try {
              await DefaultCacheManager().downloadFile(widget.videoUrl!);
            } catch (_) {}
          }());
        }
      } else {
        throw Exception('No video source provided');
      }
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      // Pause immediately — we only want the first frame
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
