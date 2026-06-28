import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';

/// Voice-message recording bottom sheet shared by 1-on-1 and group chats.
///
/// Recording is driven by the native Android MediaRecorder via the
/// `com.example.flutter_messenger_v2/audio_recorder` MethodChannel; playback
/// preview uses FlutterSoundPlayer. When the user taps send, [onSend] is called
/// with the recorded file path and its duration. [onCancel] dismisses.
class VoiceRecordingModal extends StatefulWidget {
  final void Function(String path, Duration duration) onSend;
  final VoidCallback onCancel;

  const VoiceRecordingModal({
    super.key,
    required this.onSend,
    required this.onCancel,
  });

  @override
  State<VoiceRecordingModal> createState() => _VoiceRecordingModalState();
}

class _VoiceRecordingModalState extends State<VoiceRecordingModal> {
  // Native channel — backed by Android MediaRecorder
  static const _ch = MethodChannel(
    'com.example.flutter_messenger_v2/audio_recorder',
  );

  // Keep FlutterSoundPlayer for pre-send playback preview
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  bool _isRecorderInitialized = false;
  bool _isPlayerInitialized = false;
  bool _isRecording = false;
  bool _isPaused = false;
  bool _hasRecording = false;
  String? _recordingPath;
  Duration _duration = Duration.zero;
  Timer? _timer;
  List<double> _waveformData = [];
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _initRecorder();
  }

  Future<void> _initRecorder() async {
    try {
      // Only open the player — recording goes through the native channel
      await _player.openPlayer();
      setState(() {
        _isRecorderInitialized = true; // native channel is always ready
        _isPlayerInitialized = true;
      });
    } catch (e) {
      debugPrint('Error initializing player: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Stop any in-progress recording when modal is dismissed
    if (_isRecording) {
      _ch.invokeMethod('stopRecording').catchError((_) {});
    }
    _player.closePlayer();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  Future<void> _startRecording() async {
    if (!_isRecorderInitialized) return;

    try {
      final directory = await getTemporaryDirectory();
      final path =
          '${directory.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

      setState(() {
        _isRecording = true;
        _isPaused = false;
        _recordingPath = path;
        _duration = Duration.zero;
        _waveformData = [];
      });

      // Start the native MediaRecorder
      await _ch.invokeMethod('startRecording', {'path': path});

      // Poll amplitude every 100 ms via MediaRecorder.getMaxAmplitude()
      _startWaveformTimer();
    } catch (e) {
      debugPrint('Native startRecording error: $e');
      if (mounted) {
        setState(() => _isRecording = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error starting recording: $e')));
      }
    }
  }

  void _startWaveformTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (t) async {
      if (!mounted || !_isRecording || _isPaused) return;
      try {
        // getMaxAmplitude returns 0-32767; it resets each call (peak-hold)
        final raw = await _ch.invokeMethod<int>('getAmplitude') ?? 0;
        // Normalise: apply sqrt so quiet sounds are more visible
        final normalized = raw > 0
            ? math.sqrt(raw / 32767.0).clamp(0.05, 1.0)
            : 0.05;
        if (mounted && _isRecording && !_isPaused) {
          setState(() {
            _duration += const Duration(milliseconds: 100);
            _waveformData.add(normalized);
            if (_waveformData.length > 50) _waveformData.removeAt(0);
          });
        }
      } catch (_) {
        // Channel error — just increment duration silently
        if (mounted && _isRecording && !_isPaused) {
          setState(() => _duration += const Duration(milliseconds: 100));
        }
      }
    });
  }

  Future<void> _pauseRecording() async {
    try {
      await _ch.invokeMethod('pauseRecording');
      _timer?.cancel();
      setState(() => _isPaused = true);
    } catch (e) {
      debugPrint('Pause error: $e');
    }
  }

  Future<void> _resumeRecording() async {
    try {
      await _ch.invokeMethod('resumeRecording');
      setState(() => _isPaused = false);
      _startWaveformTimer();
    } catch (e) {
      debugPrint('Resume error: $e');
    }
  }

  Future<void> _stopRecording() async {
    try {
      _timer?.cancel();
      await _ch.invokeMethod('stopRecording');
      setState(() {
        _isRecording = false;
        _isPaused = false;
        _hasRecording = true;
      });
    } catch (e) {
      debugPrint('Stop recording error: $e');
    }
  }

  Future<void> _playRecording() async {
    if (_recordingPath == null || !_isPlayerInitialized) return;
    try {
      await _player.startPlayer(
        fromURI: _recordingPath!,
        whenFinished: () {
          if (mounted) setState(() => _isPlaying = false);
        },
      );
      setState(() => _isPlaying = true);
    } catch (e) {
      debugPrint('Error playing recording: $e');
    }
  }

  Future<void> _stopPlaying() async {
    try {
      await _player.stopPlayer();
      setState(() => _isPlaying = false);
    } catch (e) {
      debugPrint('Error stopping playback: $e');
    }
  }

  void _discardRecording() {
    setState(() {
      _hasRecording = false;
      _waveformData = [];
      _duration = Duration.zero;
    });
    // Delete the file
    if (_recordingPath != null) {
      try {
        File(_recordingPath!).delete();
      } catch (_) {}
    }
    _recordingPath = null;
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Tight vertical budget: keeps waveform, timer, controls and cancel all visible
    final isCompact = mq.size.height < 600;

    return SafeArea(
      top: false, // bottom sheet — only apply bottom safe area
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF2D2D2D),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[600],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),

                // Title
                const Text(
                  'Voice Message',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: isCompact ? 12 : 20),

                // Duration display
                Text(
                  _formatDuration(_duration),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 44,
                    fontWeight: FontWeight.w300,
                    fontFamily: 'monospace',
                  ),
                ),
                SizedBox(height: isCompact ? 10 : 16),

                // Waveform visualization
                SizedBox(
                  height: isCompact ? 40 : 56,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (int i = 0; i < 50; i++)
                        Container(
                          width: 4,
                          height:
                              (i < _waveformData.length
                                  ? _waveformData[i]
                                  : 0.1) *
                              (isCompact ? 36 : 48),
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            color: _isRecording && !_isPaused
                                ? const Color(0xFFEF4444)
                                : (_hasRecording
                                      ? const Color(0xFF10B981)
                                      : Colors.grey[600]),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: isCompact ? 16 : 24),

                // Controls
                if (!_isRecording && !_hasRecording) ...[
                  // Initial state — Start button
                  ElevatedButton.icon(
                    onPressed: _isRecorderInitialized ? _startRecording : null,
                    icon: const Icon(Icons.mic, size: 24),
                    label: Text(
                      _isRecorderInitialized
                          ? 'Start Recording'
                          : 'Initializing...',
                      style: const TextStyle(fontSize: 16),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFEF4444),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                  ),
                ] else if (_isRecording) ...[
                  // Recording state — Pause/Resume + Stop
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        onPressed: _isPaused
                            ? _resumeRecording
                            : _pauseRecording,
                        icon: Icon(
                          _isPaused ? Icons.play_arrow : Icons.pause,
                          size: 32,
                          color: Colors.white,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.grey[700],
                          padding: const EdgeInsets.all(14),
                        ),
                      ),
                      const SizedBox(width: 20),
                      IconButton(
                        onPressed: _stopRecording,
                        icon: const Icon(
                          Icons.stop,
                          size: 32,
                          color: Colors.white,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFFEF4444),
                          padding: const EdgeInsets.all(14),
                        ),
                      ),
                    ],
                  ),
                ] else if (_hasRecording) ...[
                  // Has recording — Discard / Play / Send
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        onPressed: _discardRecording,
                        icon: const Icon(
                          Icons.delete,
                          size: 26,
                          color: Colors.white,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.grey[700],
                          padding: const EdgeInsets.all(12),
                        ),
                      ),
                      IconButton(
                        onPressed: _isPlaying ? _stopPlaying : _playRecording,
                        icon: Icon(
                          _isPlaying ? Icons.stop : Icons.play_arrow,
                          size: 32,
                          color: Colors.white,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFF3B82F6),
                          padding: const EdgeInsets.all(14),
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          if (_recordingPath != null) {
                            widget.onSend(_recordingPath!, _duration);
                          }
                        },
                        icon: const Icon(
                          Icons.send,
                          size: 26,
                          color: Colors.white,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          padding: const EdgeInsets.all(12),
                        ),
                      ),
                    ],
                  ),
                ],

                SizedBox(height: isCompact ? 12 : 20),

                // Cancel button
                TextButton(
                  onPressed: () async {
                    if (_isRecording) {
                      await _ch
                          .invokeMethod('stopRecording')
                          .catchError((_) {});
                    }
                    widget.onCancel();
                  },
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.grey, fontSize: 15),
                  ),
                ),

                // Bottom safe-area padding (accounts for home indicator etc.)
                SizedBox(height: mq.padding.bottom > 0 ? mq.padding.bottom : 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
