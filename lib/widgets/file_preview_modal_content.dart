import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Stateful modal content for file preview with upload progress.
class FilePreviewModalContent extends StatefulWidget {
  final File file;
  final String fileName;
  final String displayFileName;
  final String mimeType;
  final bool isImage;
  final bool isVideo;
  final int fileSize;
  final bool isFromCamera;
  final bool isUploading;
  final ValueNotifier<double> uploadProgressNotifier;
  final VoidCallback onMinimize;
  final VoidCallback onClose;
  final VoidCallback onReplace;
  final VoidCallback onSend;
  final IconData Function(String mimeType) getFileIcon;

  const FilePreviewModalContent({
    super.key,
    required this.file,
    required this.fileName,
    required this.displayFileName,
    required this.mimeType,
    required this.isImage,
    required this.isVideo,
    required this.fileSize,
    required this.isFromCamera,
    required this.isUploading,
    required this.uploadProgressNotifier,
    required this.onMinimize,
    required this.onClose,
    required this.onReplace,
    required this.onSend,
    required this.getFileIcon,
  });

  @override
  State<FilePreviewModalContent> createState() =>
      _FilePreviewModalContentState();
}

class _FilePreviewModalContentState extends State<FilePreviewModalContent> {
  bool _isSending = false;
  double _lastProgress = 0.0;
  bool _didAutoDismiss = false;

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  void initState() {
    super.initState();
    _isSending = widget.isUploading;
    widget.uploadProgressNotifier.addListener(_onProgressChanged);
  }

  @override
  void dispose() {
    widget.uploadProgressNotifier.removeListener(_onProgressChanged);
    super.dispose();
  }

  void _onProgressChanged() {
    final progress = widget.uploadProgressNotifier.value;
    if (_isSending && !_didAutoDismiss && progress >= 1.0) {
      _didAutoDismiss = true;
      Future.delayed(const Duration(milliseconds: 350), () {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
    } else if (_isSending &&
        !_didAutoDismiss &&
        _lastProgress > 0.05 &&
        progress == 0.0) {
      _didAutoDismiss = true;
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
    _lastProgress = progress;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottomInset = math.max(
      media.viewInsets.bottom,
      media.viewPadding.bottom,
    );

    return ValueListenableBuilder<double>(
      valueListenable: widget.uploadProgressNotifier,
      builder: (context, uploadProgress, _) {
        final isUploading = _isSending || widget.isUploading;

        return Container(
          height: media.size.height * 0.86,
          decoration: const BoxDecoration(
            color: Color(0xFF121733),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(color: Colors.black54, blurRadius: 14, spreadRadius: 2),
            ],
          ),
          child: Column(
            children: [
              // Drag handle
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 52,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              // Header with minimize and close buttons
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 6, 6, 14),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFF7C3AED).withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        widget.isImage
                            ? Icons.image_outlined
                            : widget.isVideo
                            ? Icons.videocam_outlined
                            : widget.getFileIcon(widget.mimeType),
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
                            isUploading ? 'Sending...' : 'Send File',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            isUploading
                                ? '${(uploadProgress * 100).toInt()}% uploaded'
                                : 'Preview before sending',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.62),
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Minimize button
                    IconButton(
                      icon: const Icon(Icons.minimize, color: Colors.white70),
                      onPressed: widget.onMinimize,
                      tooltip: 'Minimize',
                      splashRadius: 22,
                    ),
                    // Close button (disabled during upload)
                    IconButton(
                      icon: Icon(
                        Icons.close,
                        color: isUploading ? Colors.white24 : Colors.white70,
                      ),
                      onPressed: isUploading ? null : widget.onClose,
                      splashRadius: 22,
                    ),
                  ],
                ),
              ),
              // Upload progress bar
              if (isUploading)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: uploadProgress > 0 ? uploadProgress : null,
                          backgroundColor: Colors.white10,
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Color(0xFF7C3AED),
                          ),
                          minHeight: 6,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            uploadProgress > 0
                                ? '${_formatFileSize((widget.fileSize * uploadProgress).toInt())} / ${_formatFileSize(widget.fileSize)}'
                                : 'Starting upload...',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            '${(uploadProgress * 100).toInt()}%',
                            style: const TextStyle(
                              color: Color(0xFF7C3AED),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                )
              else
                const Divider(color: Colors.white10, height: 1, thickness: 1),
              // Preview area
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        constraints: BoxConstraints(
                          minHeight: 220,
                          maxHeight: media.size.height * 0.46,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F1326),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                            width: 1,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(15),
                          child: widget.isImage
                              ? InteractiveViewer(
                                  maxScale: 4,
                                  minScale: 1,
                                  child: Center(
                                    child: Image.file(
                                      widget.file,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                )
                              : widget.isVideo
                              ? VideoPreviewWidget(filePath: widget.file.path)
                              : Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        widget.getFileIcon(widget.mimeType),
                                        color: Colors.white,
                                        size: 68,
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        widget.displayFileName,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Bottom section
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // File info
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF373B43),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              widget.getFileIcon(widget.mimeType),
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.displayFileName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${_formatFileSize(widget.fileSize)} | ${widget.mimeType}',
                                  style: TextStyle(
                                    color: Colors.grey[300],
                                    fontSize: 12,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Action buttons
                    Row(
                      children: [
                        if (!isUploading)
                          Expanded(
                            child: SizedBox(
                              height: 54,
                              child: OutlinedButton.icon(
                                onPressed: widget.onReplace,
                                icon: Icon(
                                  widget.isFromCamera
                                      ? Icons.camera_alt_outlined
                                      : Icons.refresh,
                                ),
                                label: Text(
                                  widget.isFromCamera
                                      ? 'Take Another'
                                      : 'Replace',
                                  style: const TextStyle(fontSize: 15),
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
                        if (!isUploading) const SizedBox(width: 10),
                        Expanded(
                          child: SizedBox(
                            height: 54,
                            child: ElevatedButton.icon(
                              onPressed: isUploading
                                  ? null
                                  : () {
                                      setState(() {
                                        _isSending = true;
                                      });
                                      widget.onSend();
                                    },
                              icon: isUploading
                                  ? SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                        value: uploadProgress > 0
                                            ? uploadProgress
                                            : null,
                                      ),
                                    )
                                  : const Icon(Icons.send_rounded),
                              label: Text(
                                isUploading
                                    ? '${(uploadProgress * 100).toInt()}%'
                                    : 'Send',
                                style: const TextStyle(fontSize: 15),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isUploading
                                    ? const Color(0xFF5B21B6)
                                    : const Color(0xFF7C3AED),
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
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A stateful widget that plays a video file for preview in the file send modal.
class VideoPreviewWidget extends StatefulWidget {
  final String filePath;

  const VideoPreviewWidget({super.key, required this.filePath});

  @override
  State<VideoPreviewWidget> createState() => _VideoPreviewWidgetState();
}

class _VideoPreviewWidgetState extends State<VideoPreviewWidget> {
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.filePath))
      ..initialize()
          .then((_) {
            if (mounted) {
              setState(() => _initialized = true);
            }
          })
          .catchError((e) {
            if (mounted) {
              setState(() => _hasError = true);
            }
          });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _togglePlayback() {
    setState(() {
      if (_controller.value.isPlaying) {
        _controller.pause();
      } else {
        _controller.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: Colors.white54, size: 48),
            SizedBox(height: 8),
            Text(
              'Failed to load video',
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (!_initialized) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF25D366)),
      );
    }

    return GestureDetector(
      onTap: _togglePlayback,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: _controller.value.aspectRatio > 0
                  ? _controller.value.aspectRatio
                  : 16 / 9,
              child: VideoPlayer(_controller),
            ),
          ),
          // Play/pause overlay
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: _controller,
            builder: (context, value, child) {
              if (!value.isPlaying) {
                return const DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(14),
                    child: Icon(
                      Icons.play_arrow,
                      color: Colors.white,
                      size: 40,
                    ),
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          // Progress bar at bottom
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: VideoProgressIndicator(
              _controller,
              allowScrubbing: true,
              colors: const VideoProgressColors(
                playedColor: Color(0xFF25D366),
                bufferedColor: Colors.white24,
                backgroundColor: Colors.white10,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
