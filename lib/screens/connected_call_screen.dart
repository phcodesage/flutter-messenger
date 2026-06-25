import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'dart:async';
import 'dart:convert';
import '../services/call_service.dart';
import '../services/storage_service.dart';
import '../services/call_overlay_manager.dart';
import '../services/socket_service.dart';
import '../services/call_notification_service.dart';
import '../services/pip_service.dart';
import '../services/presence_service.dart';

/// Connected call screen that shows during an active call
/// Displays: Remote video (fullscreen), Local video (PiP), Controls bar
class ConnectedCallScreen extends StatefulWidget {
  final String remoteName;
  final String callType; // 'video' or 'audio'
  final CallService callService;
  final MediaStream? localStream;
  final VoidCallback? onChatPressed;

  ConnectedCallScreen({
    super.key,
    required this.remoteName,
    required this.callType,
    required this.callService,
    this.localStream,
    this.onChatPressed,
  }) {
    debugPrint(
      '📞 ConnectedCallScreen constructor called for $callType call with $remoteName',
    );

    // Validate required parameters
    if (remoteName.isEmpty) {
      debugPrint('⚠️ ConnectedCallScreen: remoteName is empty');
    }
    if (callType.isEmpty) {
      debugPrint('⚠️ ConnectedCallScreen: callType is empty');
    }

    debugPrint('📞 ConnectedCallScreen constructor completed successfully');
  }

  @override
  State<ConnectedCallScreen> createState() => _ConnectedCallScreenState();
}

class _ConnectedCallScreenState extends State<ConnectedCallScreen>
    with WidgetsBindingObserver {
  // Video renderers
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  // Local video position for draggable PiP
  Offset _localVideoPosition = const Offset(16, 100);

  // Control states
  bool _isMicMuted = false;
  bool _isVideoHidden = false;
  bool _showControls = true;
  bool _isSpeakerOn = true;
  bool _isScreenSharing = false;
  bool _isRemoteScreenSharing = false;
  bool _isScreenShareTransitioning = false;
  bool _remoteCameraEnabled = true;
  bool _isNoiseFilterEnabled = false;

  // Call duration
  Timer? _durationTimer;
  int _callDuration = 0;
  DateTime? _connectedAtUtc;
  late DateTime _durationFallbackStartUtc;

  // Prevent multiple pops
  bool _isEnding = false;

  // Track when call screen was initialized to prevent premature ending
  late DateTime _initTime;
  bool _isFullyInitialized = false; // Track if async initialization completed

  // Device lists
  List<MediaDeviceInfo> _microphones = [];
  List<MediaDeviceInfo> _cameras = [];
  List<MediaDeviceInfo> _speakers = [];

  // Selected devices
  String? _selectedMicId;
  String? _selectedCameraId;
  String? _selectedSpeakerId;

  // Services for ongoing call notification and PiP
  final CallNotificationService _callNotificationService =
      CallNotificationService();
  final PipService _pipService = PipService();
  bool _isInPipMode = false;

  // Local user's display name (for data channel 'from' field)
  String _localUserName = '';

  // Listener key for socket events
  static const String _listenerKey = 'connected_call_screen';

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
    _initTime = DateTime.now();
    _durationFallbackStartUtc = DateTime.now().toUtc();
    _connectedAtUtc = widget.callService.connectedAt?.toUtc();
    debugPrint(
      '📞 ConnectedCallScreen: initState called for ${widget.callType} call with ${widget.remoteName}',
    );
    debugPrint('📞 ConnectedCallScreen: Widget mounted: $mounted');
    debugPrint(
      '📞 ConnectedCallScreen: Current call state: ${widget.callService.callState}',
    );
    debugPrint('📞 ConnectedCallScreen: Init time: $_initTime');

    WidgetsBinding.instance.addObserver(this);
    // Mark call in progress so PresenceService keeps status 'online' when backgrounded
    PresenceService().isCallInProgress = true;

    // Initialize synchronously first
    _setupCallListeners();
    _startCallDurationTimer();

    debugPrint(
      '📞 ConnectedCallScreen: Sync initialization completed, starting async init',
    );

    // Then initialize async components
    _initializeAsync();

    debugPrint(
      '📞 ConnectedCallScreen: initState completed for ${widget.callType} call',
    );
  }

  /// Initialize async components after sync setup
  Future<void> _initializeAsync() async {
    try {
      debugPrint(
        '📞 ConnectedCallScreen: Starting async initialization for ${widget.callType} call',
      );

      // ALWAYS initialize renderers, even for audio calls, so that we can
      // display a screen share if the remote peer starts one mid-call.
      try {
        await _initializeRenderers();
        debugPrint(
          '📞 ConnectedCallScreen: Video renderers initialized successfully (for ${widget.callType} call)',
        );
      } catch (e) {
        debugPrint(
          '⚠️ ConnectedCallScreen: Video renderer initialization failed: $e',
        );
        // Continue without video renderers - audio will still work
      }

      // Load devices (but don't fail if this errors)
      try {
        await _loadDevices();
        debugPrint('📞 ConnectedCallScreen: Devices loaded successfully');
      } catch (e) {
        debugPrint(
          '⚠️ ConnectedCallScreen: Device loading failed, continuing anyway: $e',
        );
      }

      // Load local username for data channel messages
      try {
        _localUserName = await StorageService.getUsername() ?? '';
      } catch (e) {
        debugPrint('⚠️ ConnectedCallScreen: Could not load local username: $e');
      }

      // Initialize call services last
      try {
        await _initCallServices();
        debugPrint(
          '📞 ConnectedCallScreen: Call services initialized successfully',
        );
      } catch (e) {
        debugPrint(
          '⚠️ ConnectedCallScreen: Call services initialization failed: $e',
        );
        // Continue without PiP/notification if they fail
      }

      debugPrint(
        '📞 ConnectedCallScreen: Async initialization completed for ${widget.callType} call',
      );

      // Mark as fully initialized
      _isFullyInitialized = true;
    } catch (e) {
      debugPrint(
        '❌ ConnectedCallScreen: Async initialization failed for ${widget.callType} call: $e',
      );
      // Don't rethrow - continue with call even if some initialization fails
      // The widget should remain visible even if some features don't work

      // Still mark as initialized even if some parts failed
      _isFullyInitialized = true;
    }
  }

  /// Initialize ongoing call notification and PiP
  Future<void> _initCallServices() async {
    try {
      debugPrint(
        '📞 ConnectedCallScreen: Initializing call services for ${widget.callType} call',
      );

      // Show ongoing call notification in status bar
      await _callNotificationService.initialize();
      await _callNotificationService.show(
        remoteName: widget.remoteName,
        callType: widget.callType,
      );
      _callNotificationService.onEndCallFromNotification = () {
        debugPrint(
          '📞 ConnectedCallScreen: End call requested from notification',
        );
        _endCall();
      };

      // Initialize PiP and mark as in-call (await so native flag is set)
      await _pipService.initialize();
      await _pipService.setInCall(true);
      _pipService.onPipModeChanged = (isInPip) {
        if (mounted) {
          setState(() {
            _isInPipMode = isInPip;
          });
        }
      };
      // Handle PiP action buttons (mute/end call from PiP overlay)
      _pipService.onToggleMic = () {
        _toggleMic();
        _pipService.updateMuteState(_isMicMuted);
      };
      _pipService.onEndCall = () {
        debugPrint('📞 ConnectedCallScreen: End call requested from PiP');
        _endCall();
      };

      debugPrint(
        '📞 ConnectedCallScreen: Call services initialized successfully for ${widget.callType} call',
      );
    } catch (e) {
      debugPrint(
        '❌ ConnectedCallScreen: Error initializing call services for ${widget.callType} call: $e',
      );
      // Continue without PiP/notification if they fail
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    debugPrint('📱 App lifecycle state: $state (isEnding: $_isEnding)');
    // PiP is handled natively via onUserLeaveHint in MainActivity
    // We just track the mode change here via the callback
  }

  Future<void> _initializeRenderers() async {
    try {
      debugPrint(
        '📞 ConnectedCallScreen: Initializing renderers for ${widget.callType} call',
      );

      // Initialize renderers with timeout protection
      await Future.wait([
        _localRenderer.initialize(),
        _remoteRenderer.initialize(),
      ]).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint(
            '⚠️ ConnectedCallScreen: Renderer initialization timed out',
          );
          throw TimeoutException('Renderer initialization timed out');
        },
      );

      debugPrint('📞 ConnectedCallScreen: Renderers initialized successfully');

      // Set local stream - handle gracefully if not available
      try {
        final isLocalScreenShare = widget.callService.isScreenSharing;
        debugPrint(
          '📞 ConnectedCallScreen: Renderer local stream status: isLocalShare=$isLocalScreenShare, localStream=${widget.localStream?.id}, callService.localStream=${widget.callService.localStream?.id}, screenStream=${widget.callService.screenStream?.id}',
        );
        if (isLocalScreenShare && widget.callService.screenStream != null) {
          debugPrint(
            '📞 ConnectedCallScreen: Setting local screen share stream',
          );
          _localRenderer.srcObject = widget.callService.screenStream;
          _isScreenSharing = true;
        } else if (widget.localStream != null) {
          debugPrint(
            '📞 ConnectedCallScreen: Setting local stream from widget',
          );
          _localRenderer.srcObject = widget.localStream;
        } else if (widget.callService.localStream != null) {
          debugPrint(
            '📞 ConnectedCallScreen: Setting local stream from call service',
          );
          _localRenderer.srcObject = widget.callService.localStream;
        } else {
          debugPrint(
            '⚠️ ConnectedCallScreen: No local stream available for ${widget.callType} call - will set later',
          );
        }
      } catch (e) {
        debugPrint('⚠️ Error setting local stream: $e - continuing anyway');
      }

      // Set remote stream - handle gracefully if not available
      try {
        if (widget.callService.remoteStream != null) {
          debugPrint('📞 ConnectedCallScreen: Setting remote stream');
          _remoteRenderer.srcObject = widget.callService.remoteStream;
        } else {
          debugPrint(
            '📞 ConnectedCallScreen: No remote stream available yet - will set when received',
          );
        }
      } catch (e) {
        debugPrint('⚠️ Error setting remote stream: $e - continuing anyway');
      }

      debugPrint(
        '📞 ConnectedCallScreen: Renderer initialization completed for ${widget.callType} call',
      );
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint(
        '❌ ConnectedCallScreen: Error initializing renderers for ${widget.callType} call: $e',
      );
      // Don't rethrow - continue with call even if video fails
      // Audio calls can still work without video renderers

      // For video calls, we still want to show the UI even if renderers fail
      if (mounted) {
        setState(() {});
      }
    }
  }

  void _setupCallListeners() {
    final socketService = SocketService();

    // Listen for remote stream
    widget.callService.onRemoteStream = (stream) {
      debugPrint(
        '🎥 Connected call screen received remote stream (callType: ${widget.callType})',
      );
      debugPrint('🎥 Remote stream id: ${stream.id}, tracks: ${stream.getTracks().map((t) => '${t.kind}:${t.id}').join(', ')}');
      if (mounted) {
        try {
          final remoteVideoTracks = stream.getVideoTracks();
          _remoteRenderer.srcObject = stream;

          // Keep UI in sync when remote video is toggled off/on.
          for (final track in remoteVideoTracks) {
            track.onMute = () {
              if (!mounted || _isRemoteScreenSharing) return;
              setState(() => _remoteCameraEnabled = false);
              debugPrint('🎥 Remote video muted (track event)');
            };
            track.onUnMute = () {
              if (!mounted) return;
              setState(() => _remoteCameraEnabled = true);
              debugPrint('🎥 Remote video unmuted (track event)');
            };
          }

          setState(() {
            if (widget.callType == 'video' && !_isRemoteScreenSharing) {
              _remoteCameraEnabled = remoteVideoTracks.any(
                (track) => track.enabled,
              );
            }
          });
          debugPrint('✅ Remote stream set successfully');
        } catch (e) {
          debugPrint('❌ Error setting remote stream: $e');
          // Continue anyway - the call can still work without video
        }
      } else {
        debugPrint(
          '⚠️ ConnectedCallScreen not mounted when remote stream received',
        );
      }
    };

    // Listen for call state changes
    widget.callService.onCallStateChanged = (state) {
      debugPrint(
        '📞 ConnectedCallScreen: Call state changed to: $state (callType: ${widget.callType})',
      );

      if (state == CallState.ended || state == CallState.failed) {
        // Add protection against premature call ending ONLY during initialization
        final timeSinceInit = DateTime.now().difference(_initTime);
        debugPrint(
          '📞 ConnectedCallScreen: Time since init: ${timeSinceInit.inMilliseconds}ms, fully initialized: $_isFullyInitialized',
        );

        // Only protect during the first 3 seconds OR if not fully initialized
        // This prevents premature closing during connection setup but allows legitimate endings
        final minProtectionTime = 3000; // Reduced from 10000/8000

        if (timeSinceInit.inMilliseconds < minProtectionTime &&
            !_isFullyInitialized) {
          debugPrint(
            '📞 ConnectedCallScreen: IGNORING premature call end (${timeSinceInit.inMilliseconds}ms since init, initialized: $_isFullyInitialized) - call state: $state',
          );
          debugPrint(
            '📞 ConnectedCallScreen: Protection active for ${minProtectionTime - timeSinceInit.inMilliseconds}ms more',
          );
          return;
        }

        debugPrint('📞 ConnectedCallScreen: Call ended/failed, ending call UI');
        _endCall();
      } else if (state == CallState.connected) {
        debugPrint(
          '📞 ConnectedCallScreen: Call state is connected - screen should stay visible',
        );
        if (_connectedAtUtc == null) {
          final fromService = widget.callService.connectedAt?.toUtc();
          if (fromService != null && mounted) {
            setState(() {
              _connectedAtUtc = fromService;
            });
          }
        }
      } else {
        debugPrint(
          '📞 ConnectedCallScreen: Call state changed to $state - monitoring',
        );
      }
    };

    widget.callService.onConnectedAtChanged = (connectedAt) {
      final utc = connectedAt?.toUtc();
      if (!mounted || utc == null) return;
      setState(() {
        _connectedAtUtc = utc;
      });
    };

    // Listen for screen share changes (local or remote)
    widget.callService.onScreenShareChanged = (isSharing) {
      debugPrint(
        '🖥️ Screen share changed: $isSharing (callType: ${widget.callType})',
      );
      if (!mounted) return;

      setState(() {
        final isLocalShare = widget.callService.isScreenSharing;
        if (isLocalShare) {
          _isScreenSharing = true;
          _isRemoteScreenSharing = false;
          _localRenderer.srcObject = widget.callService.screenStream ??
              widget.callService.localStream;
          debugPrint('🖥️ Local screen sharing started');
        } else {
          _isScreenSharing = false;
          _isRemoteScreenSharing = isSharing;
          _localRenderer.srcObject = widget.localStream ??
              widget.callService.localStream;
          debugPrint('🖥️ Remote screen sharing: $_isRemoteScreenSharing');
        }
      });
    };

    // Parse remote data-channel payloads (from web/mobile peer) to keep UI state in sync.
    widget.callService.onDataChannelMessage = _handleIncomingDataChannelMessage;

    // Listen for call ended from socket using keyed listener (remote user ended call)
    socketService.addListener('callEnded', _listenerKey, (data) {
      debugPrint('📴 ConnectedCallScreen received callEnded event: $data');
      if (!_isEnding) {
        widget.callService.handleCallEnded();
        _endCall();
      }
    });

    // Also listen for call declined
    socketService.addListener('callDeclined', _listenerKey, (data) {
      debugPrint('📴 ConnectedCallScreen received callDeclined event: $data');
      if (!_isEnding) {
        widget.callService.handleCallDeclined();
        _endCall();
      }
    });

    // Listen for signals during the call
    // Also directly detect termination signals here as a safety net in case
    // onCallStateChanged is temporarily null during navigation transitions.
    socketService.onSignal = (data) {
      final signal = data['signal'];
      final signalType = signal is Map ? signal['type'] : null;

      // Directly handle call termination signals from remote user
      if (signalType == 'call-ended' || signalType == 'call-declined') {
        debugPrint(
          '📴 ConnectedCallScreen: Termination signal detected: $signalType',
        );
        if (!_isEnding) {
          widget.callService.handleCallEnded();
          _endCall();
        }
        return; // Don't route further — call is over
      }

      widget.callService.handleSignal(data);
    };
  }

  void _handleIncomingDataChannelMessage(String rawMessage) {
    Map<String, dynamic>? payload;

    try {
      final decoded = jsonDecode(rawMessage);
      if (decoded is Map) {
        payload = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // Fallback for legacy plain-text markers.
      if (rawMessage.contains('screen-share-started')) {
        if (mounted) {
          setState(() {
            if (!_isScreenSharing) {
              _isRemoteScreenSharing = true;
              _remoteCameraEnabled = true;
            }
          });
        }
      } else if (rawMessage.contains('screen-share-stopped')) {
        if (mounted) {
          setState(() {
            _isRemoteScreenSharing = false;
          });
        }
      }
      return;
    }

    if (payload == null) return;

    final type = payload['type']?.toString();
    switch (type) {
      case 'cam-state':
        final enabled = _coerceBool(payload['enabled']);
        if (enabled != null && mounted && !_isRemoteScreenSharing) {
          setState(() => _remoteCameraEnabled = enabled);
        }
        break;
      case 'screen-share':
        final phase = payload['phase']?.toString().toLowerCase();
        if (phase == 'planning' || phase == 'started' || phase == 'start') {
          if (mounted) {
            setState(() {
              if (!_isScreenSharing) {
                _isRemoteScreenSharing = true;
                _remoteCameraEnabled = true;
              }
            });
          }
        } else if (phase == 'ended' || phase == 'stopped' || phase == 'stop') {
          if (mounted) {
            setState(() {
              _isRemoteScreenSharing = false;
            });
          }
        }
        break;
      default:
        // Other payload types (mic/speaker/noise-filter) are informational for now.
        break;
    }
  }

  bool? _coerceBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.toLowerCase();
      if (normalized == 'true' || normalized == '1' || normalized == 'on') {
        return true;
      }
      if (normalized == 'false' || normalized == '0' || normalized == 'off') {
        return false;
      }
    }
    return null;
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      if (mounted) {
        setState(() {
          _microphones = devices.where((d) => d.kind == 'audioinput').toList();
          _cameras = devices.where((d) => d.kind == 'videoinput').toList();
          _speakers = devices.where((d) => d.kind == 'audiooutput').toList();

          if (_microphones.isNotEmpty) {
            _selectedMicId = _microphones.first.deviceId;
          }
          if (_cameras.isNotEmpty) {
            _selectedCameraId = _cameras.first.deviceId;
          }
          if (_speakers.isNotEmpty) {
            _selectedSpeakerId = _speakers.first.deviceId;
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading devices: $e');
      // Continue without device enumeration - use defaults
      if (mounted) {
        setState(() {
          _microphones = [];
          _cameras = [];
          _speakers = [];
        });
      }
    }
  }

  void _startCallDurationTimer() {
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        final baseline = _connectedAtUtc ?? widget.callService.connectedAt?.toUtc();
        final start = baseline ?? _durationFallbackStartUtc;
        final elapsedSeconds = DateTime.now().toUtc().difference(start).inSeconds;
        setState(() {
          _callDuration = elapsedSeconds < 0 ? 0 : elapsedSeconds;
        });
      }
    });
  }

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  void _toggleMic() {
    final stream = widget.localStream ?? widget.callService.localStream;
    if (stream != null) {
      for (var track in stream.getAudioTracks()) {
        track.enabled = _isMicMuted;
      }
    }
    final newMicState = !_isMicMuted;
    setState(() {
      _isMicMuted = newMicState;
    });
    // Send data channel message to remote peer
    // newMicState = _isMicMuted (true = muted), so enabled is the inverse
    _sendDataChannelMessage({
      'type': 'mic-state',
      'enabled': !newMicState,
      if (_localUserName.isNotEmpty) 'from': _localUserName,
    });
  }

  void _toggleVideo() {
    final stream = widget.localStream ?? widget.callService.localStream;
    if (stream != null) {
      for (var track in stream.getVideoTracks()) {
        track.enabled = _isVideoHidden;
      }
    }
    final newVideoState = !_isVideoHidden;
    setState(() {
      _isVideoHidden = newVideoState;
    });
    // Send data channel message to remote peer
    // newVideoState = _isVideoHidden (true = hidden), so enabled is the inverse
    _sendDataChannelMessage({
      'type': 'cam-state',
      'enabled': !newVideoState,
      if (_localUserName.isNotEmpty) 'from': _localUserName,
    });
  }

  Future<void> _switchCamera() async {
    final stream = widget.localStream ?? widget.callService.localStream;
    if (stream != null && _cameras.length > 1) {
      final currentIndex = _cameras.indexWhere(
        (c) => c.deviceId == _selectedCameraId,
      );
      final nextIndex = (currentIndex + 1) % _cameras.length;
      _selectedCameraId = _cameras[nextIndex].deviceId;

      // Switch camera using Helper
      await Helper.switchCamera(stream.getVideoTracks().first);
      setState(() {});
    }
  }

  void _toggleSpeaker() {
    setState(() {
      _isSpeakerOn = !_isSpeakerOn;
    });
    // On mobile, toggle between earpiece and speaker
    Helper.setSpeakerphoneOn(_isSpeakerOn);
    // Send data channel message to remote peer
    _sendDataChannelMessage({
      'type': 'speaker-state',
      'enabled': _isSpeakerOn,
      if (_localUserName.isNotEmpty) 'from': _localUserName,
    });
  }

  Future<void> _toggleScreenShare() async {
    if (_isScreenShareTransitioning) {
      debugPrint('🖥️ Screen share toggle already in progress, ignoring duplicate request');
      return;
    }

    debugPrint(
      '🖥️ Toggling screen share (current localShare=$_isScreenSharing, remoteShare=$_isRemoteScreenSharing, transitioning=$_isScreenShareTransitioning)',
    );
    setState(() {
      _isScreenShareTransitioning = true;
    });

    try {
      // Send planning phase before starting
      if (!_isScreenSharing) {
        _sendDataChannelMessage({
          'type': 'screen-share',
          'phase': 'planning',
          if (_localUserName.isNotEmpty) 'from': _localUserName,
        });
      }

      final result = await widget.callService.toggleScreenShare();
      debugPrint('🖥️ toggleScreenShare result: $result');
      if (!mounted) {
        debugPrint('🖥️ toggleScreenShare returning after unmounted');
        return;
      }

      setState(() {
        _isScreenSharing = result;
        _isRemoteScreenSharing = false;
        // Clear remote screen sharing indicator when we start sharing
        if (_isScreenSharing) {
          _isRemoteScreenSharing = false;
        }
      });

      // Send appropriate phase message
      _sendDataChannelMessage({
        'type': 'screen-share',
        'phase': result ? 'started' : 'ended',
        if (_localUserName.isNotEmpty) 'from': _localUserName,
      });
    } catch (e, stack) {
      debugPrint('❌ ConnectedCallScreen: _toggleScreenShare failed: $e');
      debugPrint(stack.toString().split('\n').take(5).join('\n'));
      rethrow;
    } finally {
      if (mounted) {
        setState(() {
          _isScreenShareTransitioning = false;
        });
      }
    }
  }

  void _sendDataChannelMessage(Map<String, dynamic> message) {
    try {
      final jsonMessage = jsonEncode(message);
      widget.callService.sendDataChannelMessage(jsonMessage);
      debugPrint('📤 Sent data channel message: ${message['type']}');
    } catch (e) {
      debugPrint('❌ Error sending data channel message: $e');
    }
  }

  void _endCall() {
    if (_isEnding) return; // Prevent multiple calls
    _isEnding = true;

    // Get stack trace to see what's calling _endCall
    final stackTrace = StackTrace.current;
    debugPrint('📞 ConnectedCallScreen: _endCall called from:');
    debugPrint(stackTrace.toString().split('\n').take(5).join('\n'));

    debugPrint('📞 Ending call from connected screen');

    // Clear call-in-progress flag so presence resumes normal behavior
    PresenceService().isCallInProgress = false;

    // Show "Call Ended" notification and disable PiP
    _callNotificationService.showCallEnded();
    _pipService.setInCall(false); // fire-and-forget is fine on cleanup

    widget.callService.endCall();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
  }

  Future<void> _toggleNoiseFilter() async {
    final newState = await widget.callService.toggleNoiseFilter();
    setState(() {
      _isNoiseFilterEnabled = newState;
    });
    // Send data channel message to remote peer (matches web 'noise-filter' handler)
    _sendDataChannelMessage({
      'type': 'noise-filter',
      'enabled': _isNoiseFilterEnabled,
      if (_localUserName.isNotEmpty) 'from': _localUserName,
    });
    // Show brief toast so user knows it took effect
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isNoiseFilterEnabled
                ? '🎙️ Noise filter ON — background noise suppressed'
                : '🎙️ Noise filter OFF — raw audio',
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: _isNoiseFilterEnabled
              ? const Color(0xFF166534)
              : const Color(0xFF374151),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    }
  }

  void _minimizeToOverlay() {
    // Show the floating mini call widget with all call info
    CallOverlayManager().show(
      context: context,
      callService: widget.callService,
      remoteName: widget.remoteName,
      callType: widget.callType,
      localStream: widget.localStream,
      onChatPressed: widget.onChatPressed,
      onEndCall: () {
        widget.callService.endCall();
      },
    );

    // Only pop the call screen - the overlay manager handles navigation back
    Navigator.of(context).pop();
  }

  void _showDeviceSelector(String type) {
    List<MediaDeviceInfo> devices;
    String? selectedId;
    String title;

    switch (type) {
      case 'mic':
        devices = _microphones;
        selectedId = _selectedMicId;
        title = 'Select Microphone';
        break;
      case 'camera':
        devices = _cameras;
        selectedId = _selectedCameraId;
        title = 'Select Camera';
        break;
      case 'speaker':
        devices = _speakers;
        selectedId = _selectedSpeakerId;
        title = 'Select Speaker';
        break;
      default:
        return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) =>
          _buildDeviceSelector(title, devices, selectedId, type),
    );
  }

  Widget _buildDeviceSelector(
    String title,
    List<MediaDeviceInfo> devices,
    String? selectedId,
    String type,
  ) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          ...devices.map(
            (device) => ListTile(
              leading: Icon(
                type == 'mic'
                    ? Icons.mic
                    : type == 'camera'
                    ? Icons.videocam
                    : Icons.speaker,
                color: device.deviceId == selectedId
                    ? const Color(0xFF8B5CF6)
                    : Colors.grey,
              ),
              title: Text(
                device.label.isNotEmpty
                    ? device.label
                    : 'Device ${device.deviceId.substring(0, 8)}',
                style: TextStyle(
                  color: device.deviceId == selectedId
                      ? const Color(0xFF8B5CF6)
                      : Colors.white,
                ),
              ),
              trailing: device.deviceId == selectedId
                  ? const Icon(Icons.check, color: Color(0xFF8B5CF6))
                  : null,
              onTap: () {
                setState(() {
                  switch (type) {
                    case 'mic':
                      _selectedMicId = device.deviceId;
                      break;
                    case 'camera':
                      _selectedCameraId = device.deviceId;
                      break;
                    case 'speaker':
                      _selectedSpeakerId = device.deviceId;
                      break;
                  }
                });
                Navigator.pop(context);
              },
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  @override
  void dispose() {
    debugPrint(
      '📞 ConnectedCallScreen: dispose() called - screen is being removed',
    );
    debugPrint('📞 ConnectedCallScreen: _isEnding: $_isEnding');
    debugPrint(
      '📞 ConnectedCallScreen: Time alive: ${DateTime.now().difference(_initTime).inMilliseconds}ms',
    );

    WidgetsBinding.instance.removeObserver(this);
    _durationTimer?.cancel();

    // Remove socket listeners
    final socketService = SocketService();
    socketService.removeListener('callEnded', _listenerKey);
    socketService.removeListener('callDeclined', _listenerKey);
    widget.callService.onDataChannelMessage = null;
    widget.callService.onConnectedAtChanged = null;

    _localRenderer.dispose();
    _remoteRenderer.dispose();

    // Clean up notification and PiP if not already ended
    if (!_isEnding) {
      _callNotificationService.showCallEnded();
    }
    _pipService.setInCall(false);

    // Ensure call flag is cleared even if _endCall wasn't called
    PresenceService().isCallInProgress = false;

    debugPrint('📞 ConnectedCallScreen: dispose() completed');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    debugPrint(
      '📞 ConnectedCallScreen: build() called for ${widget.callType} call (mounted: $mounted, showControls: $_showControls, inPip: $_isInPipMode, localShare: $_isScreenSharing, remoteShare: $_isRemoteScreenSharing, remoteCameraEnabled: $_remoteCameraEnabled)',
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _minimizeToOverlay();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Column(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: _toggleControls,
                child: Stack(
                  children: [
                    // Remote video (fullscreen background)
                    _buildRemoteVideo(),

                    // Local video (PiP, draggable) - hide in PiP mode
                    if (!_isInPipMode) _buildLocalVideoPiP(),

                    // Top bar with call info - hide in PiP mode
                    if (_showControls && !_isInPipMode) _buildTopBar(),

                    // Quick minimize control centered at the top.
                    if (_showControls && !_isInPipMode)
                      _buildTopCenterMinimizeButton(),
                  ],
                ),
              ),
            ),

            // Bottom controls are outside the video area to avoid overlap.
            if (_showControls && !_isInPipMode) _buildBottomControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildRemoteVideo() {
    Widget content;

    // Show avatar view when there is no remote video feed to display.
    final shouldShowAvatar =
        (widget.callType == 'audio' && !_isRemoteScreenSharing) ||
        (widget.callType == 'video' &&
            !_isRemoteScreenSharing &&
            !_remoteCameraEnabled);

    if (shouldShowAvatar) {
      content = Container(
        color: const Color(0xFF1A1A2E),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Avatar
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [const Color(0xFF8B5CF6), const Color(0xFF6D28D9)],
                  ),
                ),
                child: Center(
                  child: Text(
                    widget.remoteName.isNotEmpty
                        ? widget.remoteName[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                widget.remoteName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.callType == 'video'
                    ? 'Camera is off'
                    : _formatDuration(_callDuration),
                style: TextStyle(color: Colors.grey[400], fontSize: 16),
              ),
            ],
          ),
        ),
      );
    } else {
      // Use RTCVideoViewObjectFitContain to show full width video without cropping
      content = Stack(
        children: [
          Container(
            color: Colors.black,
            width: double.infinity,
            height: double.infinity,
            child: RTCVideoView(
              _remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
            ),
          ),
          // Screen share indicator
          if (_isRemoteScreenSharing)
            Positioned(
              top: MediaQuery.of(context).padding.top + 60,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8B5CF6).withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.screen_share, color: Colors.white, size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Screen is being shared',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return content;
  }

  Widget _buildLocalVideoPiP() {
    final hasLocalStream = _localRenderer.srcObject != null && !_isVideoHidden;

    if (!hasLocalStream || widget.callType == 'audio') {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: _localVideoPosition.dx,
      top: _localVideoPosition.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _localVideoPosition += details.delta;
            // Keep within screen bounds
            final size = MediaQuery.of(context).size;
            _localVideoPosition = Offset(
              _localVideoPosition.dx.clamp(0, size.width - 120),
              _localVideoPosition.dy.clamp(0, size.height - 180),
            );
          });
        },
        onDoubleTap: _switchCamera,
        child: Container(
          width: 120,
          height: 160,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white30, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 10,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: RTCVideoView(
              _localRenderer,
              mirror: _isFrontCamera, // Mirror only for front cameras
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),
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
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 8,
          left: 16,
          right: 16,
          bottom: 16,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.7), Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            // Call type icon
            Icon(
              widget.callType == 'video' ? Icons.videocam : Icons.phone,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            // Name
            Expanded(
              child: Text(
                widget.remoteName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Duration
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color.fromRGBO(0, 0, 0, 0.4),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                _formatDuration(_callDuration),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopCenterMinimizeButton() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 4,
      left: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          onTap: _minimizeToOverlay,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.52),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
                width: 1,
              ),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white),
                SizedBox(width: 4),
                Text(
                  'Minimize',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    final controls = <Widget>[
      _buildControlButton(
        label: _isMicMuted ? 'Unmute mic' : 'Mute mic',
        backgroundColor: _isMicMuted
            ? const Color(0xFF64748B)
            : const Color(0xFF22C55E),
        onTap: _toggleMic,
        onLongPress: () => _showDeviceSelector('mic'),
      ),
      if (widget.callType == 'video')
        _buildControlButton(
          label: _isVideoHidden ? 'Show video' : 'Hide video',
          backgroundColor: _isVideoHidden
              ? const Color(0xFF64748B)
              : const Color(0xFF3B82F6),
          onTap: _toggleVideo,
          onLongPress: () => _showDeviceSelector('camera'),
        ),
      if (widget.callType == 'video' && _cameras.length > 1)
        _buildControlButton(
          label: 'Switch cam',
          backgroundColor: const Color(0xFF06B6D4),
          onTap: _switchCamera,
        ),
      _buildControlButton(
        label: _isSpeakerOn ? 'Speakers' : 'Earpiece',
        backgroundColor: const Color(0xFFF97316),
        onTap: _toggleSpeaker,
        onLongPress: () => _showDeviceSelector('speaker'),
      ),
      _buildControlButton(
        label: _isScreenSharing ? 'Stop sharing' : 'Share screen',
        backgroundColor: const Color(0xFF8B5CF6),
        onTap: _toggleScreenShare,
        enabled: !_isScreenShareTransitioning,
      ),
      _buildControlButton(
        label: _isNoiseFilterEnabled ? 'Noise filter ON' : 'Noise reduction',
        backgroundColor: _isNoiseFilterEnabled
            ? const Color(0xFF16A34A)
            : const Color(0xFF14B8A6),
        onTap: _toggleNoiseFilter,
      ),
      if (widget.onChatPressed != null)
        _buildControlButton(
          label: 'Open my chat',
          backgroundColor: const Color(0xFFEC4899),
          onTap: _minimizeToOverlay,
        ),
      _buildControlButton(
        label: 'End Call',
        backgroundColor: const Color(0xFFEF4444),
        onTap: _endCall,
      ),
    ];

    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = width >= 760
        ? 6
        : width >= 620
        ? 5
        : width >= 500
        ? 4
        : width >= 380
        ? 3
        : 2;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.only(
        top: 8,
        left: 10,
        right: 10,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF0B1530),
        border: Border(top: BorderSide(color: Color(0xFF2D3748), width: 1)),
      ),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: controls.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 2.6,
        ),
        itemBuilder: (context, index) => controls[index],
      ),
    );
  }

  Widget _buildControlButton({
    required String label,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    Color backgroundColor = const Color(0xFF22C55E),
    Color textColor = Colors.white,
    bool enabled = true,
  }) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        onLongPress: enabled ? onLongPress : null,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: enabled ? backgroundColor : Colors.grey.shade700,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: textColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.1,
            ),
          ),
        ),
      ),
    );
  }
}
