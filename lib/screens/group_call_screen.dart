import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/group_call_service.dart';

/// Group video/audio call screen (full-mesh WebRTC).
///
/// Caller passes [roomId], [myPeerId], [callType] ('video'|'audio'),
/// [groupName], and optionally the [inviterName] (for display when joining
/// an existing call).
class GroupCallScreen extends StatefulWidget {
  final String roomId;
  final String myPeerId;
  final String callType;
  final String groupName;

  const GroupCallScreen({
    super.key,
    required this.roomId,
    required this.myPeerId,
    required this.callType,
    required this.groupName,
  });

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  final GroupCallService _callService = GroupCallService();
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();

  // Map peerId → renderer (populated via onParticipantJoined callback)
  final Map<String, RTCVideoRenderer> _participantRenderers = {};
  final List<String> _participantOrder = [];

  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _showControls = true;
  Timer? _controlsTimer;
  Duration _callDuration = Duration.zero;
  Timer? _durationTimer;

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _initCall();
    _startDurationTimer();
  }

  Future<void> _initCall() async {
    _callService.onLocalStream = (stream) {
      if (mounted) {
        setState(() {
          _localRenderer.srcObject = stream;
        });
      }
    };

    _callService.onParticipantJoined = (peerId, renderer) {
      if (mounted) {
        setState(() {
          if (!_participantOrder.contains(peerId)) {
            _participantOrder.add(peerId);
          }
          _participantRenderers[peerId] = renderer;
        });
      }
    };

    _callService.onParticipantLeft = (peerId) {
      if (mounted) {
        setState(() {
          _participantOrder.remove(peerId);
          _participantRenderers.remove(peerId);
        });
      }
    };

    _callService.onCallEnded = () {
      if (mounted) Navigator.of(context).pop();
    };

    await _callService.initialize(
      roomId: widget.roomId,
      myPeerId: widget.myPeerId,
      callType: widget.callType,
    );
  }

  void _startDurationTimer() {
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _callDuration += const Duration(seconds: 1));
    });
  }

  void _resetControlsTimer() {
    _controlsTimer?.cancel();
    if (!_showControls) setState(() => _showControls = true);
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  void _toggleMute() {
    _callService.toggleMute();
    setState(() => _isMuted = _callService.isMuted);
  }

  void _toggleCamera() {
    _callService.toggleCamera();
    setState(() => _isCameraOff = _callService.isCameraOff);
  }

  Future<void> _endCall() async {
    await _callService.dispose();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _durationTimer?.cancel();
    _localRenderer.dispose();
    _callService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _endCall();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: _resetControlsTimer,
          child: Stack(
            children: [
              _buildParticipantGrid(),
              _buildLocalVideoOverlay(),
              if (_showControls) _buildTopBar(),
              if (_showControls) _buildBottomControls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildParticipantGrid() {
    if (_participantOrder.isEmpty) {
      return Container(
        color: const Color(0xFF1A1A2E),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.group, color: Colors.white54, size: 72),
              const SizedBox(height: 16),
              Text(
                'Waiting for others to join...',
                style: TextStyle(color: Colors.grey[400], fontSize: 18),
              ),
              const SizedBox(height: 8),
              Text(
                widget.groupName,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      );
    }

    final count = _participantOrder.length;
    final crossAxisCount = count == 1 ? 1 : 2;

    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
        childAspectRatio: count == 1 ? (MediaQuery.of(context).size.width / MediaQuery.of(context).size.height) : 1.0,
      ),
      itemCount: count,
      itemBuilder: (context, i) {
        final peerId = _participantOrder[i];
        final renderer = _participantRenderers[peerId];
        return _buildParticipantTile(peerId, renderer);
      },
    );
  }

  Widget _buildParticipantTile(String peerId, RTCVideoRenderer? renderer) {
    final hasVideo = widget.callType == 'video' && renderer != null;
    return Stack(
      children: [
        Container(
          color: const Color(0xFF1E1E2E),
          child: hasVideo
              ? RTCVideoView(renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
              : Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircleAvatar(
                        radius: 36,
                        backgroundColor: const Color(0xFF8B5CF6),
                        child: Text(
                          peerId.isNotEmpty ? peerId[0].toUpperCase() : '?',
                          style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        Positioned(
          bottom: 6,
          left: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
            child: Text(peerId, style: const TextStyle(color: Colors.white, fontSize: 11)),
          ),
        ),
      ],
    );
  }

  Widget _buildLocalVideoOverlay() {
    return Positioned(
      top: 80,
      right: 12,
      child: Container(
        width: 90,
        height: 120,
        decoration: BoxDecoration(
          color: const Color(0xFF2D2D2D),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white24),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: widget.callType == 'video' && !_isCameraOff
              ? RTCVideoView(_localRenderer, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
              : const Center(child: Icon(Icons.person, color: Colors.white54, size: 40)),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 8, left: 16, right: 16, bottom: 8),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.groupName, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  Text(
                    '${_participantOrder.length + 1} participants · ${_formatDuration(_callDuration)}',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 20, top: 20, left: 32, right: 32),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildControlButton(
              icon: _isMuted ? Icons.mic_off : Icons.mic,
              label: _isMuted ? 'Unmute' : 'Mute',
              color: _isMuted ? Colors.red : Colors.white,
              background: const Color(0xFF3A3A3A),
              onTap: _toggleMute,
            ),
            if (widget.callType == 'video')
              _buildControlButton(
                icon: _isCameraOff ? Icons.videocam_off : Icons.videocam,
                label: _isCameraOff ? 'Start Cam' : 'Stop Cam',
                color: _isCameraOff ? Colors.red : Colors.white,
                background: const Color(0xFF3A3A3A),
                onTap: _toggleCamera,
              ),
            _buildControlButton(
              icon: Icons.call_end,
              label: 'End',
              color: Colors.white,
              background: Colors.red,
              onTap: _endCall,
              size: 60,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    required Color color,
    required Color background,
    required VoidCallback onTap,
    double size = 52,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: background, shape: BoxShape.circle),
            child: Icon(icon, color: color, size: size * 0.45),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }
}
