import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class AudioMessagePlayer extends StatefulWidget {
  const AudioMessagePlayer({
    super.key,
    required this.audioUrl,
    this.fileSize,
    this.initialDuration,
  });

  final String audioUrl;
  final int? fileSize;
  final double? initialDuration;

  @override
  State<AudioMessagePlayer> createState() => _AudioMessagePlayerState();
}

class _AudioMessagePlayerState extends State<AudioMessagePlayer> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _completeSubscription;

  @override
  void initState() {
    super.initState();
    if (widget.initialDuration != null && widget.initialDuration! > 0) {
      _duration = Duration(milliseconds: (widget.initialDuration! * 1000).round());
    }
    _setupAudioPlayer();
  }

  void _setupAudioPlayer() {
    _durationSubscription = _audioPlayer.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });

    _positionSubscription = _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });

    _completeSubscription = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
      }
    });

    if (_duration == Duration.zero) {
      _probeAudioSource();
    }
  }

  Future<void> _probeAudioSource() async {
    try {
      final source = await _resolveSource();
      if (mounted && !_isPlaying) {
        await _audioPlayer.setSource(source);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _durationSubscription?.cancel();
    _positionSubscription?.cancel();
    _completeSubscription?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _togglePlayPause() async {
    try {
      if (_isPlaying) {
        await _audioPlayer.pause();
        setState(() => _isPlaying = false);
      } else {
        await _audioPlayer.stop();
        await Future.delayed(const Duration(milliseconds: 100));
        await _audioPlayer.play(await _resolveSource());
        setState(() => _isPlaying = true);
      }
    } catch (e) {
      debugPrint('AudioPlayers Exception: $e');
      if (mounted) {
        setState(() => _isPlaying = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error playing audio: ${e.toString().split(":").last.trim()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// Prefer the on-disk cached file (works offline) and fall back to
  /// streaming the URL. The first network play also warms the cache so
  /// subsequent plays don't need the network at all.
  Future<Source> _resolveSource() async {
    try {
      final cached = await DefaultCacheManager().getFileFromCache(
        widget.audioUrl,
      );
      if (cached != null) {
        return DeviceFileSource(cached.file.path);
      }
    } catch (_) {
      // Cache lookup failed for some reason; fall through to streaming.
    }
    unawaited(
      () async {
        try {
          await DefaultCacheManager().downloadFile(widget.audioUrl);
        } catch (_) {}
      }(),
    );
    return UrlSource(widget.audioUrl);
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: _togglePlayPause,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 28,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: List.generate(20, (index) {
                    final barHeight = [
                      8.0,
                      14.0,
                      10.0,
                      18.0,
                      12.0,
                      20.0,
                      16.0,
                      22.0,
                      14.0,
                      18.0,
                      12.0,
                      16.0,
                      20.0,
                      14.0,
                      10.0,
                      18.0,
                      12.0,
                      8.0,
                      14.0,
                      10.0,
                    ][index];
                    final isPlayed = progress > (index / 20);
                    return Container(
                      width: 3,
                      height: barHeight,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: isPlayed ? Colors.white : Colors.white38,
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 4),
                Text(
                  _isPlaying || _position > Duration.zero
                      ? '${_formatDuration(_position)} / ${_formatDuration(_duration)}'
                      : _formatDuration(_duration),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
