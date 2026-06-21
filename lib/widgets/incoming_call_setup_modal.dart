import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/call_service.dart';
import '../services/socket_service.dart';

/// Incoming call setup modal with device selection
/// Shows camera/mic/speaker selection before answering a call
class IncomingCallSetupModal extends StatefulWidget {
  final String callerName;
  final int callerId;
  final String callType;
  final CallService callService;
  final VoidCallback? onDecline;

  const IncomingCallSetupModal({
    super.key,
    required this.callerName,
    required this.callerId,
    required this.callType,
    required this.callService,
    this.onDecline,
  });

  @override
  State<IncomingCallSetupModal> createState() => _IncomingCallSetupModalState();
}

class _IncomingCallSetupModalState extends State<IncomingCallSetupModal> {
  // Device lists
  List<MediaDeviceInfo> _microphones = [];
  List<MediaDeviceInfo> _speakers = [];
  List<MediaDeviceInfo> _cameras = [];

  // Selected devices
  String? _selectedMicId;
  String? _selectedSpeakerId;
  String? _selectedCameraId;

  // Video toggle state
  bool _videoEnabled = true;

  // Local media stream
  MediaStream? _localStream;

  // Video renderer for preview
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();

  // Loading state
  bool _isLoading = true;
  bool _hasPermissions = false;
  String? _errorMessage;
  bool _isAnswering = false;
  bool _isClosing = false;
  bool _isDisposed = false;
  bool _streamHandedOff = false;

  // Socket service for listening to call events
  final SocketService _socketService = SocketService();
  static const String _listenerKey = 'incoming_call_setup_modal';

  /// Determine if the currently selected camera is front-facing
  bool get _isFrontCamera {
    if (_selectedCameraId == null || _cameras.isEmpty) return true;

    final selectedCamera = _cameras.firstWhere(
      (camera) => camera.deviceId == _selectedCameraId,
      orElse: () => _cameras.first,
    );

    // Check if the camera label indicates it's a front camera
    final label = selectedCamera.label.toLowerCase();
    return label.contains('front') ||
        label.contains('user') ||
        label.contains('selfie') ||
        !label.contains('back') && !label.contains('rear');
  }

  @override
  void initState() {
    super.initState();
    _videoEnabled = widget.callType == 'video';

    _initializeDevices();

    // Listen for call state changes (caller might cancel)
    widget.callService.onCallStateChanged = _handleCallStateChanged;

    // Also listen directly for socket events to ensure modal closes
    _socketService.addListener(
      'callEnded',
      _listenerKey,
      _handleSocketCallEnded,
    );
    _socketService.addListener(
      'callDeclined',
      _listenerKey,
      _handleSocketCallEnded,
    );
  }

  void _handleSocketCallEnded(Map<String, dynamic> data) {
    debugPrint('📴 IncomingCallSetupModal received call end event: $data');
    _closeOnce('ended');
  }

  void _handleCallStateChanged(CallState state) {
    if (!mounted) return;

    if (state == CallState.ended || state == CallState.failed) {
      _closeOnce('ended');
    }
  }

  void _closeOnce(dynamic result) {
    if (!mounted || _isClosing) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent || !route.isActive) {
      debugPrint(
        '📴 IncomingCallSetupModal skip close: route current=${route?.isCurrent}, active=${route?.isActive}',
      );
      return;
    }
    _isClosing = true;
    debugPrint('📴 IncomingCallSetupModal closing with result: $result');
    Navigator.of(context).pop(result);
  }

  Future<void> _initializeDevices() async {
    try {
      await _requestPermissions();

      if (!_hasPermissions) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Camera and microphone permissions are required';
        });
        return;
      }

      await _localRenderer.initialize();

      final devices = await navigator.mediaDevices.enumerateDevices();

      setState(() {
        _microphones = devices.where((d) => d.kind == 'audioinput').toList();
        _speakers = devices.where((d) => d.kind == 'audiooutput').toList();
        _cameras = devices.where((d) => d.kind == 'videoinput').toList();

        if (_microphones.isNotEmpty) {
          _selectedMicId = _microphones.first.deviceId;
        }
        if (_speakers.isNotEmpty) {
          _selectedSpeakerId = _speakers.first.deviceId;
        }
        if (_cameras.isNotEmpty) {
          _selectedCameraId = _cameras.first.deviceId;
        }
      });

      await _getMediaStream();

      setState(() => _isLoading = false);
    } catch (e) {
      debugPrint('Error initializing devices: $e');
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to initialize devices: $e';
      });
    }
  }

  Future<void> _requestPermissions() async {
    // Batch both permissions in a single request to avoid
    // "A request for permissions is already running" PlatformException
    final statuses = await [Permission.camera, Permission.microphone].request();

    setState(() {
      _hasPermissions =
          (statuses[Permission.camera]?.isGranted ?? false) &&
          (statuses[Permission.microphone]?.isGranted ?? false);
    });
  }

  Future<void> _getMediaStream() async {
    try {
      await _stopMediaStream();

      final dynamic audioConstraint =
          _selectedMicId != null ? {'deviceId': _selectedMicId} : true;

      // NOTE: do NOT combine an exact `deviceId` with `facingMode` — that pair is
      // over-constrained on many Android devices and makes getUserMedia throw,
      // which previously left the call with no stream (video call "not working"
      // while audio-only calls were fine). Prefer the selected camera by id; only
      // fall back to facingMode when no specific camera was picked.
      final Map<String, dynamic> videoConstraint = _selectedCameraId != null
          ? {
              'deviceId': _selectedCameraId,
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
              'frameRate': {'ideal': 30, 'max': 30},
            }
          : {
              'facingMode': 'user',
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
            };

      MediaStream? stream;
      if (_videoEnabled) {
        try {
          stream = await navigator.mediaDevices.getUserMedia({
            'audio': audioConstraint,
            'video': videoConstraint,
          });
        } catch (e) {
          // Retry with relaxed video constraints (just `true`) before giving up.
          debugPrint('⚠️ Video getUserMedia failed ($e) — retrying with relaxed constraints');
          try {
            stream = await navigator.mediaDevices.getUserMedia({
              'audio': audioConstraint,
              'video': true,
            });
          } catch (e2) {
            // Last resort: connect audio-only so the call still works, and reflect
            // that the camera is unavailable instead of silently breaking.
            debugPrint('⚠️ Video unavailable ($e2) — falling back to audio-only');
            stream = await navigator.mediaDevices.getUserMedia({
              'audio': audioConstraint,
              'video': false,
            });
            if (mounted) {
              setState(() => _videoEnabled = false);
            } else {
              _videoEnabled = false;
            }
          }
        }
      } else {
        stream = await navigator.mediaDevices.getUserMedia({
          'audio': audioConstraint,
          'video': false,
        });
      }

      _localStream = stream;

      if (_videoEnabled && _localStream != null) {
        _localRenderer.srcObject = _localStream;
      }

      setState(() {});
    } catch (e) {
      debugPrint('Error getting media stream: $e');
    }
  }

  Future<void> _stopMediaStream() async {
    if (_localStream != null) {
      for (var track in _localStream!.getTracks()) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }
    if (!_isDisposed) {
      _localRenderer.srcObject = null;
    }
  }

  void _toggleVideo() {
    setState(() {
      _videoEnabled = !_videoEnabled;
    });

    if (_localStream != null) {
      final videoTracks = _localStream!.getVideoTracks();
      for (var track in videoTracks) {
        track.enabled = _videoEnabled;
      }
    }

    _getMediaStream();
  }

  Future<void> _handleAnswer() async {
    if (_isAnswering || _localStream == null) return;

    setState(() {
      _isAnswering = true;
    });

    try {
      _streamHandedOff = true;
      await widget.callService.answerCall(localStream: _localStream!);

      if (mounted) {
        _closeOnce({'result': 'accepted', 'localStream': _localStream});
      }
    } catch (e) {
      debugPrint('❌ Error answering call: $e');
      _streamHandedOff = false;
      setState(() {
        _isAnswering = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to answer call: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _handleDecline() {
    if (_isClosing) return;
    widget.callService.declineCall();
    widget.onDecline?.call();

    if (mounted) {
      _closeOnce({'result': 'declined'});
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    widget.callService.onCallStateChanged = null;
    // Remove socket listeners
    _socketService.removeListener('callEnded', _listenerKey);
    _socketService.removeListener('callDeclined', _listenerKey);
    if (!_streamHandedOff) {
      _stopMediaStream();
    }
    _localRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _handleDecline();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF1E293B),
        body: SafeArea(
          child: _isLoading
              ? _buildLoadingView()
              : _errorMessage != null
              ? _buildErrorView()
              : _buildSetupView(),
        ),
      ),
    );
  }

  Widget _buildLoadingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildCallerInfo(),
          const SizedBox(height: 32),
          const CircularProgressIndicator(color: Color(0xFF8B5CF6)),
          const SizedBox(height: 16),
          const Text(
            'Preparing call...',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildCallerInfo() {
    return Column(
      children: [
        // Static avatar (no size-changing animation to avoid layout shifts)
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color.fromRGBO(76, 175, 80, 0.25),
          ),
          child: Center(
            child: Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF4CAF50), Color(0xFF2E7D32)],
                ),
              ),
              child: Center(
                child: Text(
                  widget.callerName.isNotEmpty
                      ? widget.callerName[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          widget.callerName,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              widget.callType == 'video' ? Icons.videocam : Icons.phone,
              color: Colors.green,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              'Incoming ${widget.callType == 'video' ? 'Video' : 'Audio'} Call',
              style: const TextStyle(color: Colors.green, fontSize: 16),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildErrorView() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildCallerInfo(),
          const SizedBox(height: 32),
          const Icon(Icons.error_outline, color: Colors.red, size: 48),
          const SizedBox(height: 16),
          Text(
            _errorMessage!,
            style: const TextStyle(color: Colors.white, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _handleDecline,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Decline'),
          ),
        ],
      ),
    );
  }

  Widget _buildSetupView() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Caller info at top
            _buildCallerInfo(),
            const SizedBox(height: 24),

            // Microphone selector
            _buildSectionLabel('Microphone'),
            const SizedBox(height: 8),
            _buildDeviceDropdown(
              devices: _microphones,
              selectedId: _selectedMicId,
              onChanged: (id) {
                setState(() => _selectedMicId = id);
                _getMediaStream();
              },
            ),
            const SizedBox(height: 16),

            // Speaker selector
            _buildSectionLabel('Speaker'),
            const SizedBox(height: 8),
            _buildDeviceDropdown(
              devices: _speakers,
              selectedId: _selectedSpeakerId,
              onChanged: (id) => setState(() => _selectedSpeakerId = id),
            ),
            const SizedBox(height: 16),

            // Camera section - only show for video calls
            if (widget.callType == 'video') ...[
              // Camera toggle and selector
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildSectionLabel('Camera'),
                  Row(
                    children: [
                      Switch(
                        value: _videoEnabled,
                        onChanged: (value) => _toggleVideo(),
                        activeColor: const Color(0xFF8B5CF6),
                      ),
                      const Text(
                        'Video',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),

              if (_videoEnabled) ...[
                _buildDeviceDropdown(
                  devices: _cameras,
                  selectedId: _selectedCameraId,
                  onChanged: (id) {
                    setState(() => _selectedCameraId = id);
                    _getMediaStream();
                  },
                ),
                const SizedBox(height: 16),
              ],

              // Video preview
              Container(
                width: double.infinity,
                height: 200,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _videoEnabled && _localStream != null
                      ? RTCVideoView(
                          _localRenderer,
                          mirror:
                              _isFrontCamera, // Mirror only for front cameras
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        )
                      : const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.videocam_off,
                                color: Colors.grey,
                                size: 48,
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Video is off',
                                style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 24),
            ] else ...[
              // Add spacing for audio-only calls
              const SizedBox(height: 24),
            ],

            // Action buttons
            Row(
              children: [
                // Decline button
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _handleDecline,
                    icon: const Icon(Icons.call_end),
                    label: const Text('Decline'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                // Answer button
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: _isAnswering ? null : _handleAnswer,
                    icon: _isAnswering
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.call),
                    label: Text(_isAnswering ? 'Connecting...' : 'Answer'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.grey[400],
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _buildDeviceDropdown({
    required List<MediaDeviceInfo> devices,
    required String? selectedId,
    required Function(String?) onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF334155),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: devices.any((d) => d.deviceId == selectedId)
              ? selectedId
              : null,
          isExpanded: true,
          dropdownColor: const Color(0xFF334155),
          style: const TextStyle(color: Colors.white, fontSize: 14),
          hint: const Text(
            'Select device',
            style: TextStyle(color: Colors.grey),
          ),
          icon: const Icon(Icons.keyboard_arrow_down, color: Colors.grey),
          items: devices.map((device) {
            return DropdownMenuItem<String>(
              value: device.deviceId,
              child: Text(
                device.label.isNotEmpty
                    ? device.label
                    : 'Device ${device.deviceId.substring(0, 8)}',
                overflow: TextOverflow.ellipsis,
              ),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}
