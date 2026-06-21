import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

/// Call type enum
enum CallType { video, audio }

/// Call setup modal for device selection before initiating a call
class CallSetupModal extends StatefulWidget {
  final String recipientName;
  final CallType callType;
  final ScrollController? scrollController;
  final Function(
    MediaStream localStream,
    String? selectedMic,
    String? selectedSpeaker,
    String? selectedCamera,
    bool videoEnabled,
  )
  onStartCall;

  const CallSetupModal({
    super.key,
    required this.recipientName,
    required this.callType,
    this.scrollController,
    required this.onStartCall,
  });

  @override
  State<CallSetupModal> createState() => _CallSetupModalState();
}

class _CallSetupModalState extends State<CallSetupModal> {
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

  // Audio level
  double _audioLevel = 0.0;

  // Loading state
  bool _isLoading = true;
  bool _hasPermissions = false;
  String? _errorMessage;

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
    _videoEnabled = widget.callType == CallType.video;
    _initializeDevices();
  }

  Future<void> _initializeDevices() async {
    try {
      // Request permissions first
      await _requestPermissions();

      if (!_hasPermissions) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Camera and microphone permissions are required';
        });
        return;
      }

      // Initialize renderer
      await _localRenderer.initialize();

      // Get available devices
      final devices = await navigator.mediaDevices.enumerateDevices();

      setState(() {
        _microphones = devices.where((d) => d.kind == 'audioinput').toList();
        _speakers = devices.where((d) => d.kind == 'audiooutput').toList();
        _cameras = devices.where((d) => d.kind == 'videoinput').toList();

        // Set defaults
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

      // Get initial media stream
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
      // Stop existing stream
      await _stopMediaStream();

      final dynamic audioConstraint =
          _selectedMicId != null ? {'deviceId': _selectedMicId} : true;

      // Don't combine an exact `deviceId` with `facingMode` — that pair is
      // over-constrained on many Android devices and makes getUserMedia throw,
      // which previously left the call with no stream (video call "not working"
      // while audio-only calls were fine).
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
          debugPrint('⚠️ Video getUserMedia failed ($e) — retrying with relaxed constraints');
          try {
            stream = await navigator.mediaDevices.getUserMedia({
              'audio': audioConstraint,
              'video': true,
            });
          } catch (e2) {
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

  // Track if disposed
  bool _isDisposed = false;

  Future<void> _stopMediaStream() async {
    if (_localStream != null) {
      for (var track in _localStream!.getTracks()) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }
    // Only set srcObject if not disposed
    if (!_isDisposed) {
      _localRenderer.srcObject = null;
    }
  }

  Future<void> _switchCamera() async {
    if (_localStream != null && _cameras.length > 1) {
      final currentIndex = _cameras.indexWhere(
        (c) => c.deviceId == _selectedCameraId,
      );
      final nextIndex = (currentIndex + 1) % _cameras.length;
      _selectedCameraId = _cameras[nextIndex].deviceId;
      await _getMediaStream();
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

    // Get new stream with/without video
    _getMediaStream();
  }

  void _onStartCall() {
    if (_localStream != null) {
      // Mark that we're handing off the stream - don't dispose it
      _streamHandedOff = true;
      widget.onStartCall(
        _localStream!,
        _selectedMicId,
        _selectedSpeakerId,
        _selectedCameraId,
        _videoEnabled,
      );
    }
  }

  // Flag to track if stream was handed off to call service
  bool _streamHandedOff = false;

  @override
  void dispose() {
    _isDisposed = true;
    // Only stop stream if it wasn't handed off to the call service
    if (!_streamHandedOff) {
      _stopMediaStream();
    }
    _localRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B), // Dark blue-gray background
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: _isLoading
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(48.0),
                  child: CircularProgressIndicator(color: Color(0xFF8B5CF6)),
                ),
              )
            : _errorMessage != null
            ? _buildErrorView()
            : _buildSetupView(),
      ),
    );
  }

  Widget _buildErrorView() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 48),
          const SizedBox(height: 16),
          Text(
            _errorMessage!,
            style: const TextStyle(color: Colors.white, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey[700],
              foregroundColor: Colors.white,
            ),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildSetupView() {
    final isVideoCall = widget.callType == CallType.video;
    final callTypeLabel = isVideoCall ? 'Video Call' : 'Audio Call';

    return SingleChildScrollView(
      controller: widget.scrollController,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Title
            Center(
              child: Column(
                children: [
                  Text(
                    '$callTypeLabel Setup',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Calling ${widget.recipientName}',
                    style: TextStyle(color: Colors.grey[300], fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Drag down to cancel',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
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
            // Audio level indicator
            const SizedBox(height: 8),
            _buildAudioLevelIndicator(),
            const SizedBox(height: 20),

            // Speaker selector
            _buildSectionLabel('Speaker'),
            const SizedBox(height: 8),
            _buildDeviceDropdown(
              devices: _speakers,
              selectedId: _selectedSpeakerId,
              onChanged: (id) => setState(() => _selectedSpeakerId = id),
            ),
            // Volume slider (visual representation)
            const SizedBox(height: 8),
            _buildVolumeSlider(),
            const SizedBox(height: 20),

            // Camera section - only show for video calls
            if (widget.callType == CallType.video) ...[
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

              // Camera dropdown (only if video enabled)
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
                height: 280,
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
                // Cancel button
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[700],
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('Cancel', style: TextStyle(fontSize: 16)),
                  ),
                ),
                const SizedBox(width: 16),
                // Start Call button
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: _onStartCall,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF8B5CF6),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Start Call',
                      style: TextStyle(fontSize: 16),
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

  Widget _buildAudioLevelIndicator() {
    return Container(
      height: 4,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        color: const Color(0xFF334155),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: 0.6, // Simulated audio level
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            color: const Color(0xFF8B5CF6),
          ),
        ),
      ),
    );
  }

  Widget _buildVolumeSlider() {
    return Row(
      children: [
        Expanded(
          flex: 6,
          child: Container(
            height: 4,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              color: const Color(0xFF8B5CF6),
            ),
          ),
        ),
        Container(
          width: 16,
          height: 16,
          decoration: const BoxDecoration(
            color: Color(0xFF8B5CF6),
            shape: BoxShape.circle,
          ),
        ),
        Expanded(
          flex: 4,
          child: Container(
            height: 4,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              color: Colors.grey[600],
            ),
          ),
        ),
      ],
    );
  }
}
