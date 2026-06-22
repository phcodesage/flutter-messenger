import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'dart:async';
import 'socket_service.dart';
import '../config/api_config.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'storage_service.dart';

/// Call state enum
enum CallState {
  idle,
  initiating,
  ringing,
  connecting,
  connected,
  ended,
  failed,
}

/// Call direction
enum CallDirection { outgoing, incoming }

/// Service for managing WebRTC calls
class CallService {
  static final CallService _instance = CallService._internal();
  factory CallService() => _instance;
  CallService._internal();

  static const String _screenShareListenerKey = 'call_service_screen_share';
  static const String _primaryDataChannelLabel = 'chat';
  static const String _controlDataChannelLabel = 'control';
  static const String _audioLevelDataChannelLabel = 'audio_level';

  final SocketService _socketService = SocketService();

  // WebRTC components
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  MediaStream? _primaryRemoteStream; // Track the first (camera) stream
  MediaStream? _screenStream;
  RTCDataChannel? _dataChannel;

  // Screen sharing state
  bool _isScreenSharing = false;
  MediaStreamTrack? _originalVideoTrack;
  String? _cameraStreamId; // Track camera stream ID
  String? _screenShareStreamId; // Track screen share stream ID
  bool _remoteIsScreenSharing = false; // Track remote screen share state

  // Call state
  CallState _callState = CallState.idle;
  CallDirection? _callDirection;
  int? _callId;
  int? _remoteUserId;
  String? _callRoomId;
  String? _callType; // 'video' or 'audio'
  DateTime? _connectedAt;
  int? _connectedAtMs;

  // Callbacks
  Function(CallState state)? onCallStateChanged;
  Function(MediaStream stream)? onLocalStream;
  Function(MediaStream stream)? onRemoteStream;
  Function(Map<String, dynamic> data)? onIncomingCall;
  Function(String error)? onCallError;
  Function(bool isSharing)? onScreenShareChanged;
  Function(MediaStream stream)? onRemoteScreenShare;
  Function(String message)? onDataChannelMessage;
  Function(DateTime? connectedAt)? onConnectedAtChanged;

  // Keepalive heartbeat: while a call is connected we emit `call_keepalive`
  // every ~10s so the backend can expire calls that die without a hangup and
  // stop the cross-device "in call on another device" indicator from sticking.
  Timer? _keepaliveTimer;
  static const Duration _keepaliveInterval = Duration(seconds: 10);

  // ICE servers
  List<Map<String, dynamic>> _iceServers = [];

  // ICE candidate queuing (for candidates that arrive before PC or remote description is set)
  final List<RTCIceCandidate> _earlyIceCandidates = []; // Before PC exists
  final List<RTCIceCandidate> _candidateQueue =
      []; // Before remote description is set
  bool _remoteDescriptionSet = false;

  // Pending offer for incoming calls (wait for user to answer before creating WebRTC answer)
  Map<String, dynamic>? _pendingOffer;

  // Getters
  CallState get callState => _callState;
  int? get callId => _callId;
  int? get remoteUserId => _remoteUserId;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;
  bool get isScreenSharing => _isScreenSharing;
  MediaStream? get screenStream => _screenStream;
  DateTime? get connectedAt => _connectedAt;
  int? get connectedAtMs => _connectedAtMs;

  /// Initialize the call service and set up socket listeners
  Future<void> initialize() async {
    _setupSocketListeners();
    await _fetchIceServers();
  }

  /// Reset call state (for cleaning up stale state)
  void reset() {
    debugPrint('🔄 Resetting CallService state');

    // Clear all callbacks first
    onCallStateChanged = null;
    onLocalStream = null;
    onRemoteStream = null;
    onIncomingCall = null;
    onCallError = null;
    onScreenShareChanged = null;
    onRemoteScreenShare = null;
    onDataChannelMessage = null;

    // Then do full cleanup
    _cleanup();
  }

  /// Fetch ICE servers from backend
  Future<void> _fetchIceServers() async {
    try {
      // Get auth token from storage
      final token = await StorageService.getToken();

      final headers = <String, String>{'Content-Type': 'application/json'};
      if (token != null) {
        headers['Authorization'] = 'Bearer $token';
      }

      debugPrint(
        '📡 Fetching ICE servers from ${ApiConfig.baseUrl}/get-ice-servers',
      );

      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/get-ice-servers'),
        headers: headers,
      );

      debugPrint('📡 ICE servers response status: ${response.statusCode}');
      debugPrint('📡 ICE servers response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        // Backend may return 'iceServers' (camelCase) or 'ice_servers' (snake_case)
        final servers = data['iceServers'] ?? data['ice_servers'];
        debugPrint('📡 Raw iceServers value: $servers');
        debugPrint('📡 iceServers type: ${servers.runtimeType}');

        if (servers != null && servers is List) {
          _iceServers = List<Map<String, dynamic>>.from(servers);
          debugPrint('📡 ICE servers parsed: ${_iceServers.length} servers');

          for (var i = 0; i < _iceServers.length; i++) {
            final server = _iceServers[i];
            debugPrint('📡 Server $i:');
            debugPrint('   urls: ${server['urls']}');
            debugPrint(
              '   username: ${server['username'] != null ? '(set)' : '(not set)'}',
            );
            debugPrint(
              '   credential: ${server['credential'] != null ? '(set)' : '(not set)'}',
            );
          }
        } else {
          debugPrint('⚠️ iceServers is null or not a list');
          _iceServers = [];
        }

        // If we got 0 servers, fall back to default
        if (_iceServers.isEmpty) {
          debugPrint('⚠️ Backend returned empty ICE servers, using defaults');
          _iceServers = [
            {'urls': 'stun:stun.l.google.com:19302'},
            {'urls': 'stun:stun1.l.google.com:19302'},
          ];
        }
      } else {
        debugPrint('⚠️ ICE servers API returned ${response.statusCode}');
        // Use default STUN servers
        _iceServers = [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun1.l.google.com:19302'},
        ];
        debugPrint('⚠️ Using default STUN servers');
      }
    } catch (e, stack) {
      debugPrint('❌ Error fetching ICE servers: $e');
      debugPrint('❌ Stack trace: $stack');
      _iceServers = [
        {'urls': 'stun:stun.l.google.com:19302'},
      ];
    }
  }

  /// Set up socket event listeners for call signaling
  void _setupSocketListeners() {
    final socket = _socketService;

    // Listen for incoming call
    socket.emit('subscribe_calls', {});

    // Listen for dedicated screen share events from the remote peer.
    // Some web clients rely on these events for UI/state even when using signal messages.
    socket.addListener('screenShareStarted', _screenShareListenerKey, (
      Map<String, dynamic> data,
    ) {
      if (!_isScreenShareEventForCurrentCall(data)) {
        return;
      }

      debugPrint('🖥️ Remote screen share started (socket event): $data');
      _remoteIsScreenSharing = true;
      onScreenShareChanged?.call(true);
    });

    socket.addListener('screenShareStopped', _screenShareListenerKey, (
      Map<String, dynamic> data,
    ) {
      if (!_isScreenShareEventForCurrentCall(data)) {
        return;
      }

      debugPrint('🎥 Remote screen share stopped (socket event): $data');
      _remoteIsScreenSharing = false;
      _screenShareStreamId = null;
      if (_primaryRemoteStream != null) {
        _remoteStream = _primaryRemoteStream;
        onRemoteStream?.call(_remoteStream!);
      }
      onScreenShareChanged?.call(false);
    });

    socket.addListener('callAnswered', 'call_service_call_answered', (
      Map<String, dynamic> data,
    ) {
      if (!_isEventForCurrentCall(data)) return;
      _consumeConnectedTimestamp(data, source: 'callAnswered');
    });

    socket.addListener('callSessionState', 'call_service_call_session_state', (
      Map<String, dynamic> data,
    ) {
      if (!_isEventForCurrentCall(data)) return;

      final state =
          (data['state']?.toString() ?? data['status']?.toString() ?? '')
              .toLowerCase();
      if (state == 'accepted' || state == 'connected') {
        _consumeConnectedTimestamp(data, source: 'callSessionState:$state');
      } else if (state == 'declined') {
        debugPrint('❌ Received callSessionState: $state');
        handleCallDeclined();
      } else if (state == 'ended' || state == 'cancelled') {
        debugPrint('📴 Received callSessionState: $state');
        handleCallEnded();
      }
    });
  }

  bool _isEventForCurrentCall(Map<String, dynamic> data) {
    final eventCallId = _toInt(data['call_id'] ?? data['id']);
    if (_callId != null && eventCallId != null) {
      return _callId == eventCallId;
    }

    final eventRoom =
        data['call_room_id']?.toString() ?? data['room']?.toString();
    if (_callRoomId != null &&
        _callRoomId!.isNotEmpty &&
        eventRoom != null &&
        eventRoom.isNotEmpty) {
      return _callRoomId == eventRoom;
    }

    // If neither call_id nor room is present, accept while this service owns an active call.
    return _callState == CallState.connecting ||
        _callState == CallState.connected;
  }

  int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  DateTime? _parseConnectedIso(dynamic value) {
    final raw = value?.toString().trim();
    if (raw == null || raw.isEmpty || raw.toLowerCase() == 'null') {
      return null;
    }
    return DateTime.tryParse(raw)?.toUtc();
  }

  void _setConnectedAt(DateTime connectedAtUtc, {required String source}) {
    final ms = connectedAtUtc.millisecondsSinceEpoch;
    final didChange =
        _connectedAtMs == null || (_connectedAtMs! - ms).abs() > 999;

    _connectedAt = connectedAtUtc;
    _connectedAtMs = ms;

    if (didChange) {
      debugPrint('⏱️ Central call connectedAt set from $source: $_connectedAt');
      onConnectedAtChanged?.call(_connectedAt);
    }
  }

  void _consumeConnectedTimestamp(
    Map<String, dynamic> data, {
    required String source,
  }) {
    final connectedAtMs = _toInt(
      data['connected_at_ms'] ??
          data['connectedAtMs'] ??
          data['call_start_time'],
    );
    if (connectedAtMs != null && connectedAtMs > 0) {
      _setConnectedAt(
        DateTime.fromMillisecondsSinceEpoch(connectedAtMs, isUtc: true),
        source: '$source(ms)',
      );
      return;
    }

    final connectedAtIso = _parseConnectedIso(
      data['connected_at'] ?? data['connectedAt'] ?? data['call_connected_at'],
    );
    if (connectedAtIso != null) {
      _setConnectedAt(connectedAtIso, source: '$source(iso)');
    }
  }

  bool _isScreenShareEventForCurrentCall(Map<String, dynamic> data) {
    if (_callRoomId == null || _callRoomId!.isEmpty) {
      return false;
    }

    final eventRoom =
        data['room']?.toString() ?? data['call_room_id']?.toString();

    // If the backend does not include room metadata, assume the event belongs
    // to the active call service instance.
    return eventRoom == null || eventRoom.isEmpty || eventRoom == _callRoomId;
  }

  /// Initiate a call to another user
  Future<void> initiateCall({
    required int calleeId,
    required String callType,
    required MediaStream localStream,
  }) async {
    // Reset if in a stale state (not actively connected)
    if (_callState != CallState.idle && _callState != CallState.connected) {
      debugPrint('⚠️ Resetting stale call state: $_callState');
      _cleanup();
    }

    if (_callState != CallState.idle) {
      debugPrint('⚠️ Cannot initiate call - already in a call');
      return;
    }

    try {
      _callState = CallState.initiating;
      _callDirection = CallDirection.outgoing;
      _remoteUserId = calleeId;
      _callType = callType;
      _localStream = localStream;
      onCallStateChanged?.call(_callState);

      debugPrint('📞 Initiating $callType call to user $calleeId');

      // Create a completer to wait for call_initiated response
      final callInitiatedCompleter = Completer<Map<String, dynamic>>();

      // Register a temporary keyed listener for call_initiated
      _socketService.addListener('callInitiated', '_call_initiate', (
        Map<String, dynamic> data,
      ) {
        debugPrint('✅ Received call_initiated response: $data');
        if (!callInitiatedCompleter.isCompleted) {
          _callId = data['id'] as int?;
          _callRoomId = data['call_room_id'] as String?;
          callInitiatedCompleter.complete(data);
        }
        // Remove the temporary listener after use
        _socketService.removeListener('callInitiated', '_call_initiate');
      });

      // Emit initiate_call event
      _socketService.emit('initiate_call', {
        'callee_id': calleeId,
        'call_type': callType,
      });

      // Wait for the call_initiated response (with timeout)
      try {
        await callInitiatedCompleter.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            throw TimeoutException('Server did not respond to call initiation');
          },
        );
      } on TimeoutException catch (e) {
        debugPrint('❌ Call initiation timed out: $e');
        // Remove the listener since we timed out
        _socketService.removeListener('callInitiated', '_call_initiate');
        // Clean up call state
        _cleanup();
        _callState = CallState.failed;
        onCallStateChanged?.call(_callState);
        onCallError?.call('Call initiation timed out');
        return;
      }

      // Now we have the call room, proceed with WebRTC
      debugPrint('📞 Call room assigned: $_callRoomId');

      // Set up peer connection
      await _createPeerConnection();
      await _ensurePrimaryDataChannel();

      // Add local stream tracks to peer connection
      for (var track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }

      // Create and send offer with enhanced audio SDP
      final rawOffer = await _peerConnection!.createOffer();
      final enhancedOfferSdp = _enhanceAudioInSdp(rawOffer.sdp ?? '');
      final offer = RTCSessionDescription(enhancedOfferSdp, 'offer');
      await _peerConnection!.setLocalDescription(offer);

      debugPrint('📤 Sending WebRTC offer to room: $_callRoomId');
      _socketService.emit('signal', {
        'room': _callRoomId,
        'signal': {
          'type': 'offer',
          'sdp': enhancedOfferSdp,
          'callType': callType,
        },
      });

      _callState = CallState.ringing;
      onCallStateChanged?.call(_callState);
    } catch (e) {
      debugPrint('❌ Error initiating call: $e');
      _callState = CallState.failed;
      onCallStateChanged?.call(_callState);
      onCallError?.call('Failed to initiate call: $e');
    }
  }

  /// Create WebRTC peer connection
  Future<void> _createPeerConnection() async {
    // The first call after launch can race the one-shot ICE fetch in
    // initialize(). Without it we'd build the PC with STUN only (no TURN relay),
    // so the call fails on restrictive NATs and only "works on retry" once the
    // servers are cached. Make sure they're loaded before we create the PC.
    if (_iceServers.isEmpty) {
      debugPrint('🔧 ICE servers not loaded yet — fetching before peer connection');
      await _fetchIceServers();
    }

    final config = {
      'iceServers': _iceServers.isNotEmpty
          ? _iceServers
          : [
              {'urls': 'stun:stun.l.google.com:19302'},
            ],
      'sdpSemantics': 'unified-plan',
    };

    debugPrint('🔧 Creating RTCPeerConnection with config:');
    debugPrint('🔧 iceServers count: ${(config['iceServers'] as List).length}');
    debugPrint('🔧 Full config: $config');

    _peerConnection = await createPeerConnection(config);

    // Handle ICE candidates
    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        debugPrint('🧊 Sending ICE candidate to room: $_callRoomId');
        _socketService.emit('signal', {
          'room': _callRoomId,
          'signal': {
            'type': 'ice-candidate',
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        });
      }
    };

    // Handle ICE connection state
    _peerConnection!.onIceConnectionState = (state) {
      debugPrint('🧊 ICE connection state: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        _callState = CallState.connected;
        onCallStateChanged?.call(_callState);
        if (_connectedAt == null) {
          _setConnectedAt(
            DateTime.now().toUtc(),
            source: 'ice-connected-fallback',
          );
        }
        _startKeepalive();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        debugPrint('❌ ICE connection failed — ending call');
        _callState = CallState.failed;
        onCallStateChanged?.call(_callState);
        endCall();
      } else if (state ==
          RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        debugPrint(
          '⚠️ ICE connection disconnected — waiting 5s before ending call',
        );
        // Give 5 seconds for ICE to self-recover before ending
        Future.delayed(const Duration(seconds: 5), () {
          if (_callState == CallState.connected ||
              _callState == CallState.connecting) {
            debugPrint('❌ ICE still disconnected after 5s — ending call');
            _callState = CallState.failed;
            onCallStateChanged?.call(_callState);
            endCall();
          }
        });
      }
    };

    // Handle remote tracks
    _peerConnection!.onTrack = (event) {
      debugPrint(
        '🎥 Received remote track: ${event.track.kind}, streams: ${event.streams.length}',
      );
      debugPrint(
        '🎥 Track ID: ${event.track.id}, enabled: ${event.track.enabled}',
      );

      if (event.streams.isNotEmpty) {
        // Check if this is a new stream (could be screen share)
        final stream = event.streams[0];
        debugPrint('🎥 Stream ID: ${stream.id}');

        // Track camera stream ID on first reception
        if (_cameraStreamId == null) {
          _cameraStreamId = stream.id;
          _primaryRemoteStream = stream;
          debugPrint('🎥 Set camera stream ID: $_cameraStreamId');
        }

        // Detect screen share by different stream ID or track replacement
        if (_cameraStreamId != null && stream.id != _cameraStreamId) {
          _screenShareStreamId = stream.id;
          _remoteIsScreenSharing = true;
          debugPrint('🖥️ Detected remote screen share stream: ${stream.id}');
          onScreenShareChanged?.call(true);
        } else if (stream.id == _cameraStreamId && _remoteIsScreenSharing) {
          // Back to camera stream
          _remoteIsScreenSharing = false;
          _screenShareStreamId = null;
          debugPrint('🎥 Back to camera stream: ${stream.id}');
          onScreenShareChanged?.call(false);
        }

        // Always update remote stream - this handles both initial stream and screen share
        _remoteStream = stream;
        onRemoteStream?.call(_remoteStream!);

        // Listen for track ended (e.g., when screen share stops)
        event.track.onEnded = () {
          debugPrint('🎥 Remote track ended: ${event.track.kind}');
          if (_remoteIsScreenSharing && event.track.kind == 'video') {
            _remoteIsScreenSharing = false;
            _screenShareStreamId = null;
            if (_primaryRemoteStream != null) {
              debugPrint('🖥️ Reverting to primary camera stream (onEnded)');
              _remoteStream = _primaryRemoteStream;
              onRemoteStream?.call(_remoteStream!);
            }
            onScreenShareChanged?.call(false);
          }
        };

        // Listen for track mute/unmute (can indicate screen share changes)
        event.track.onMute = () {
          debugPrint('🎥 Remote track muted: ${event.track.kind}');
        };
        event.track.onUnMute = () {
          debugPrint('🎥 Remote track unmuted: ${event.track.kind}');
        };
      }
    };

    // Handle when a remote track is explicitly removed via renegotiation
    _peerConnection!.onRemoveTrack = (stream, track) {
      debugPrint(
        '🎥 Remote track removed: ${track.kind}, stream: ${stream.id}',
      );
      if (_remoteIsScreenSharing && track.kind == 'video') {
        _remoteIsScreenSharing = false;
        _screenShareStreamId = null;
        if (_primaryRemoteStream != null) {
          debugPrint('🖥️ Reverting to primary camera stream (onRemoveTrack)');
          _remoteStream = _primaryRemoteStream;
          onRemoteStream?.call(_remoteStream!);
        }
        onScreenShareChanged?.call(false);
      }
    };

    // Handle renegotiation needed (when tracks are added/removed)
    _peerConnection!.onRenegotiationNeeded = () {
      debugPrint('🔄 Renegotiation needed - tracks may have changed');
    };

    // Handle data channel from remote peer
    _peerConnection!.onDataChannel = (channel) {
      debugPrint('📨 Data channel received: ${channel.label}');
      final label = channel.label;

      if (label == _audioLevelDataChannelLabel) {
        debugPrint('📨 Ignoring auxiliary data channel: $label');
        return;
      }

      final shouldUseAsPrimary =
          label == _primaryDataChannelLabel ||
          (label != _controlDataChannelLabel && _dataChannel == null);

      _setupDataChannelListeners(channel, setAsPrimary: shouldUseAsPrimary);
    };

    // Handle connection state
    _peerConnection!.onConnectionState = (state) {
      debugPrint('🔗 Connection state: $state');
    };
  }

  Future<void> _ensurePrimaryDataChannel() async {
    if (_peerConnection == null) {
      return;
    }

    if (_dataChannel != null &&
        _dataChannel!.label == _primaryDataChannelLabel) {
      return;
    }

    try {
      final dataChannelConfig = RTCDataChannelInit()..ordered = true;
      final channel = await _peerConnection!.createDataChannel(
        _primaryDataChannelLabel,
        dataChannelConfig,
      );

      debugPrint('📨 Created primary data channel: ${channel.label}');
      _setupDataChannelListeners(channel, setAsPrimary: true);
    } catch (e) {
      debugPrint('⚠️ Failed to create primary data channel: $e');
    }
  }

  /// Set up listeners for a data channel
  void _setupDataChannelListeners(
    RTCDataChannel channel, {
    bool setAsPrimary = true,
  }) {
    if (setAsPrimary) {
      _dataChannel = channel;
    }

    channel.onMessage = (message) {
      debugPrint('📨 Data channel message received: ${message.text}');
      onDataChannelMessage?.call(message.text);

      // Handle screen share notifications via data channel
      if (message.text.contains('screen-share-started')) {
        debugPrint('🖥️ Remote started screen sharing (via data channel)');
        onScreenShareChanged?.call(true);
      } else if (message.text.contains('screen-share-stopped')) {
        debugPrint('🖥️ Remote stopped screen sharing (via data channel)');
        if (_primaryRemoteStream != null) {
          debugPrint('🖥️ Reverting to primary camera stream');
          _remoteStream = _primaryRemoteStream;
          onRemoteStream?.call(_remoteStream!);
        }
        onScreenShareChanged?.call(false);
      }
    };

    channel.onDataChannelState = (state) {
      debugPrint(
        '📨 Data channel state (${channel.label}${setAsPrimary ? ', primary' : ''}): $state',
      );
    };
  }

  /// Send a message via data channel
  void sendDataChannelMessage(String message) {
    if (_dataChannel != null &&
        _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      _dataChannel!.send(RTCDataChannelMessage(message));
      debugPrint('📨 Data channel message sent: $message');
    } else {
      debugPrint('⚠️ Data channel not available or not open');
      _sendDataChannelFallbackSignal(message);
    }
  }

  void _sendDataChannelFallbackSignal(String message) {
    if (_callRoomId == null || _callRoomId!.isEmpty) {
      return;
    }

    try {
      final decoded = json.decode(message);
      if (decoded is! Map) {
        return;
      }

      final payload = Map<String, dynamic>.from(decoded as Map);
      final type = payload['type']?.toString();
      if (type != 'mic-state' && type != 'cam-state') {
        return;
      }

      _socketService.emit('signal', {'room': _callRoomId, 'signal': payload});
      debugPrint(
        '📡 Sent socket fallback for data channel message type: $type',
      );
    } catch (e) {
      debugPrint(
        '⚠️ Failed to send socket fallback for data channel message: $e',
      );
    }
  }

  /// Handle incoming signal (offer/answer/ICE candidate)
  Future<void> handleSignal(Map<String, dynamic> signalData) async {
    final signal = signalData['signal'] as Map<String, dynamic>?;
    if (signal == null) return;

    final type = signal['type'] as String?;

    // Web client may send ICE candidates without 'type' field
    // Detect by presence of 'candidate' key
    if (type == null && signal.containsKey('candidate')) {
      debugPrint('🧊 ICE candidate signal detected (no type field)');
      await _handleIceCandidate(signal);
      return;
    }

    switch (type) {
      case 'offer':
        await _handleOffer(signal);
        break;
      case 'answer':
        await _handleAnswer(signal);
        break;
      case 'ice-candidate':
        await _handleIceCandidate(signal);
        break;
      case 'call-ended':
      case 'call_ended':
      case 'call-cancelled':
      case 'call_cancelled':
        debugPrint('📴 Received call termination signal: $type');
        handleCallEnded();
        break;
      case 'call-declined':
      case 'call_declined':
      case 'declined':
      case 'decline':
      case 'reject':
      case 'rejected':
        // Web peers decline via a 'call-declined' control signal (not the
        // decline_call socket event), which the backend cross-room forwards
        // to the caller's personal room. Without this case the outgoing call
        // UI stays stuck on "calling" after the remote user declines.
        debugPrint('❌ Received call decline signal: $type');
        handleCallDeclined();
        break;
      case 'call-connected':
      case 'call_connected':
        debugPrint('✅ Received call connected signal: $signal');
        _consumeConnectedTimestamp(signal, source: 'signal:$type');
        break;
      case 'screen-share-started':
        debugPrint('🖥️ Remote user started screen sharing');
        // The video track in the remote stream will automatically update
        // Just notify the UI that screen share has started
        onScreenShareChanged?.call(true);
        break;
      case 'screen-share-stopped':
        debugPrint('🖥️ Remote user stopped screen sharing');
        if (_primaryRemoteStream != null) {
          debugPrint('🖥️ Reverting to primary camera stream');
          _remoteStream = _primaryRemoteStream;
          onRemoteStream?.call(_remoteStream!);
        }
        onScreenShareChanged?.call(false);
        break;
      default:
        debugPrint('⚠️ Unknown signal type: $type');
    }
  }

  /// Handle incoming offer
  Future<void> _handleOffer(Map<String, dynamic> signal) async {
    final callType = signal['callType'] as String?;
    final reason = signal['reason'] as String?;

    debugPrint(
      '📥 Received WebRTC offer (callDirection: $_callDirection, callState: $_callState, remoteDescSet: $_remoteDescriptionSet, callType: $callType, reason: $reason)',
    );

    // RENEGOTIATION DETECTION: If we already have an active peer connection
    // with remote description set (i.e., call is TRULY connected/connecting),
    // this is a renegotiation offer (e.g., screen share). We auto-answer it.
    // NOTE: 'connecting' with no peer connection = we're still setting up the
    // initial call — that is NOT renegotiation.
    final isRenegotiation = signal['renegotiate'] == true;
    final hasActiveConnection =
        _peerConnection != null && _remoteDescriptionSet;
    final isCallActive =
        _callState == CallState.connected ||
        (_callState == CallState.connecting && hasActiveConnection);

    // Process renegotiation more permissively - if it's marked as renegotiation and we have a peer connection, try to handle it
    if (isRenegotiation && _peerConnection != null) {
      debugPrint(
        '🔄 Renegotiation offer detected (renegotiate flag: $isRenegotiation, activePC: $hasActiveConnection, callActive: $isCallActive) - auto-answering',
      );
      await _processRenegotiationOffer(signal);
      return;
    } else if (hasActiveConnection && isCallActive) {
      debugPrint(
        '🔄 Renegotiation offer detected (renegotiate flag: $isRenegotiation, activePC: $hasActiveConnection, callActive: $isCallActive) - auto-answering',
      );
      await _processRenegotiationOffer(signal);
      return;
    }

    // For incoming calls or when direction is not yet set (cross-room calls),
    // store the offer and wait for user to answer.
    // The answer will be created in answerCall() after user provides local stream.
    if (_callDirection == CallDirection.incoming || _callDirection == null) {
      // DUPLICATE OFFER GUARD: the mobile may receive the same offer twice —
      // once via chat room membership and once via backend personal-room relay.
      // Deduplicate by comparing SDP fingerprint so the second delivery is ignored.
      final incomingSdp = signal['sdp'] as String?;
      final existingSdp = _pendingOffer?['sdp'] as String?;
      if (incomingSdp != null &&
          existingSdp != null &&
          incomingSdp == existingSdp) {
        debugPrint('⏭ Duplicate offer received (same SDP) — ignoring');
        return;
      }
      debugPrint(
        '📥 Storing offer for incoming call - waiting for user to answer',
      );
      debugPrint(
        '📥 Current call state when storing offer: $_callState, direction: $_callDirection',
      );
      debugPrint('📥 Offer SDP length: ${incomingSdp?.length ?? 0} characters');
      _pendingOffer = signal;
      // If direction not set, this is likely a cross-room call - set it now
      if (_callDirection == null) {
        debugPrint('📥 Setting call direction to incoming (was null)');
        _callDirection = CallDirection.incoming;
      }
      return;
    }

    // For outgoing calls that receive an offer (shouldn't happen normally)
    await _processOffer(signal);
  }

  /// Process a renegotiation offer during an active call (e.g., screen share started/stopped)
  /// Unlike _processOffer, this reuses the existing peer connection and does NOT re-add local tracks.
  Future<void> _processRenegotiationOffer(Map<String, dynamic> signal) async {
    if (_peerConnection == null) {
      debugPrint('⚠️ Cannot process renegotiation - no peer connection');
      return;
    }

    // Additional check: ensure we're in a valid call state for renegotiation
    if (_callState != CallState.connected &&
        _callState != CallState.connecting) {
      debugPrint(
        '⚠️ Cannot process renegotiation - invalid call state: $_callState',
      );
      return;
    }

    try {
      final sdp = signal['sdp'] as String;
      final callType = signal['callType'] as String?;
      final reason = signal['reason'] as String?;

      debugPrint(
        '🔄 Processing renegotiation offer (callType: $callType, reason: $reason)',
      );

      // Reset remote description flag so ICE candidates are queued during transition
      _remoteDescriptionSet = false;

      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(sdp, 'offer'),
      );

      _remoteDescriptionSet = true;
      debugPrint('🔄 Remote description set (renegotiation offer)');

      // Process any queued ICE candidates
      await _processQueuedCandidates();

      // Create and send answer with enhanced audio SDP
      final rawAnswer = await _peerConnection!.createAnswer();
      final enhancedAnswerSdp = _enhanceAudioInSdp(rawAnswer.sdp ?? '');
      final answer = RTCSessionDescription(enhancedAnswerSdp, 'answer');
      await _peerConnection!.setLocalDescription(answer);

      debugPrint('🔄 Sending renegotiation answer to room: $_callRoomId');

      if (_callRoomId == null || _callRoomId!.isEmpty) {
        debugPrint(
          '❌ ERROR: _callRoomId is null or empty! Cannot send renegotiation answer.',
        );
        return;
      }

      _socketService.emit('signal', {
        'room': _callRoomId,
        'signal': {
          'type': 'answer',
          'sdp': enhancedAnswerSdp,
          'renegotiate': true,
        },
      });

      debugPrint('✅ Renegotiation answer sent successfully');
    } catch (e) {
      debugPrint('❌ Error processing renegotiation offer: $e');
    }
  }

  /// Enhance Opus audio quality in an SDP string.
  ///
  /// Mirrors the web client's `enableStereoInSDP` function:
  /// - maxaveragebitrate = 510000 (high-quality voice)
  /// - stereo = 0 (mono is cleaner for voice calls; reduces echo)
  /// - useinbandfec = 1 (FEC for packet-loss resilience)
  /// - usedtx = 0 (disable DTX to avoid cut-outs in noisy environments)
  /// - cbr = 0 (variable bitrate adapts to speech dynamics)
  String _enhanceAudioInSdp(String sdp) {
    try {
      // Find Opus payload type
      final rtpmapRegex = RegExp(
        r'a=rtpmap:(\d+) opus/48000',
        caseSensitive: false,
      );
      final rtpmapMatch = rtpmapRegex.firstMatch(sdp);
      if (rtpmapMatch == null) {
        debugPrint('🎵 SDP: Opus rtpmap not found, skipping audio enhancement');
        return sdp;
      }
      final pt = rtpmapMatch.group(1)!;

      const opusParams =
          'minptime=10;useinbandfec=1;stereo=0;maxaveragebitrate=510000;cbr=0;usedtx=0';
      final newFmtp = 'a=fmtp:$pt $opusParams';

      // Replace existing fmtp line or insert one after the rtpmap line
      final fmtpRegex = RegExp('a=fmtp:$pt[^\r\n]*', caseSensitive: false);
      if (fmtpRegex.hasMatch(sdp)) {
        sdp = sdp.replaceAll(fmtpRegex, newFmtp);
      } else {
        final rtpmapLine = 'a=rtpmap:$pt opus/48000/2';
        sdp = sdp.replaceFirst(rtpmapLine, '$rtpmapLine\r\n$newFmtp');
      }

      debugPrint('🎵 SDP: Audio enhanced for Opus pt=$pt');
      return sdp;
    } catch (e) {
      debugPrint('⚠️ SDP audio enhancement error: $e');
      return sdp;
    }
  }

  /// Trigger renegotiation when adding new tracks (e.g., screen share in audio call)
  Future<void> _triggerRenegotiation({String? reason}) async {
    if (_peerConnection == null || _callRoomId == null) {
      debugPrint(
        '❌ Cannot trigger renegotiation - no peer connection or room ID',
      );
      return;
    }

    try {
      debugPrint('🔄 Triggering renegotiation: ${reason ?? "unknown"}');

      // Create new offer with the added video track
      final offer = await _peerConnection!.createOffer();
      await _peerConnection!.setLocalDescription(offer);

      // Send renegotiation offer
      _socketService.emit('signal', {
        'room': _callRoomId,
        'signal': {
          'type': 'offer',
          'sdp': offer.sdp,
          'renegotiate': true, // Mark as renegotiation
          'reason': reason, // Add reason for debugging
          'isScreenShare': _isScreenSharing, // Add screen share state
        },
      });

      debugPrint('✅ Renegotiation offer sent: ${reason ?? "unknown"}');
    } catch (e) {
      debugPrint('❌ Error triggering renegotiation: $e');
    }
  }

  /// Process the offer and create answer (called after user answers incoming call)
  Future<void> _processOffer(Map<String, dynamic> signal) async {
    if (_peerConnection == null) {
      await _createPeerConnection();
    }

    final sdp = signal['sdp'] as String;
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, 'offer'),
    );

    _remoteDescriptionSet = true;
    debugPrint('📥 Remote description set (offer)');

    // Process any queued ICE candidates
    await _processQueuedCandidates();

    // Add local stream if we have one
    if (_localStream != null) {
      for (var track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
      }
    }

    // Create and send answer with enhanced audio SDP
    final rawAnswer = await _peerConnection!.createAnswer();
    final enhancedAnswerSdp = _enhanceAudioInSdp(rawAnswer.sdp ?? '');
    final answer = RTCSessionDescription(enhancedAnswerSdp, 'answer');
    await _peerConnection!.setLocalDescription(answer);

    debugPrint(
      '📤 Sending WebRTC answer to room: $_callRoomId (callId: $_callId, direction: $_callDirection)',
    );

    if (_callRoomId == null || _callRoomId!.isEmpty) {
      debugPrint('❌ ERROR: _callRoomId is null or empty! Cannot send answer.');
      return;
    }

    final signalData = {
      'room': _callRoomId,
      'signal': {'type': 'answer', 'sdp': enhancedAnswerSdp},
    };
    debugPrint('📤 Signal data: $signalData');
    _socketService.emit('signal', signalData);

    _callState = CallState.connecting;
    onCallStateChanged?.call(_callState);
  }

  /// Handle incoming answer
  Future<void> _handleAnswer(Map<String, dynamic> signal) async {
    debugPrint('📥 Received WebRTC answer');

    if (_peerConnection == null) return;

    final sdp = signal['sdp'] as String;
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, 'answer'),
    );

    _remoteDescriptionSet = true;
    debugPrint('📥 Remote description set (answer)');

    // Process any queued ICE candidates
    await _processQueuedCandidates();

    _callState = CallState.connecting;
    onCallStateChanged?.call(_callState);
  }

  /// Handle ICE candidate with queuing support
  Future<void> _handleIceCandidate(Map<String, dynamic> signal) async {
    final candidate = RTCIceCandidate(
      signal['candidate'] as String?,
      signal['sdpMid'] as String?,
      signal['sdpMLineIndex'] as int?,
    );

    // Queue if no peer connection yet
    if (_peerConnection == null) {
      _earlyIceCandidates.add(candidate);
      debugPrint(
        '🧊 Queued early ICE candidate (no PC). Queue size: ${_earlyIceCandidates.length}',
      );
      return;
    }

    // Queue if remote description not set
    if (!_remoteDescriptionSet) {
      _candidateQueue.add(candidate);
      debugPrint(
        '🧊 Queued ICE candidate (no remote desc). Queue size: ${_candidateQueue.length}',
      );
      return;
    }

    // Add immediately if ready
    try {
      debugPrint('🧊 Adding ICE candidate immediately');
      await _peerConnection!.addCandidate(candidate);
    } catch (e) {
      debugPrint('⚠️ Error adding ICE candidate: $e - will queue for retry');
      _candidateQueue.add(candidate);
    }
  }

  /// Process all queued ICE candidates
  Future<void> _processQueuedCandidates() async {
    if (_peerConnection == null || !_remoteDescriptionSet) {
      debugPrint(
        '⚠️ Cannot process queued candidates - PC or remote desc not ready',
      );
      return;
    }

    // First, move early candidates to main queue
    if (_earlyIceCandidates.isNotEmpty) {
      debugPrint(
        '🧊 Flushing ${_earlyIceCandidates.length} early ICE candidates',
      );
      _candidateQueue.addAll(_earlyIceCandidates);
      _earlyIceCandidates.clear();
    }

    final totalCandidates = _candidateQueue.length;
    debugPrint('🧊 Processing $totalCandidates queued ICE candidates');

    int processed = 0;
    int failed = 0;

    while (_candidateQueue.isNotEmpty) {
      final candidate = _candidateQueue.removeAt(0);
      try {
        await _peerConnection!.addCandidate(candidate);
        processed++;
        debugPrint(
          '🧊 Added queued ICE candidate ($processed/$totalCandidates)',
        );
      } catch (e) {
        failed++;
        debugPrint('❌ Error adding queued ICE candidate: $e');
      }
    }

    debugPrint(
      '🧊 Queue processing complete: $processed added, $failed failed',
    );
  }

  /// Answer an incoming call
  Future<void> answerCall({required MediaStream localStream}) async {
    debugPrint(
      '📞 answerCall called - current state: $_callState, direction: $_callDirection',
    );

    if (_callState != CallState.ringing) {
      debugPrint('⚠️ Cannot answer - not ringing (current state: $_callState)');
      return;
    }

    _localStream = localStream;
    onLocalStream?.call(_localStream!);

    // Emit answer_call to backend
    _socketService.emit('answer_call', {'call_id': _callId});

    _callState = CallState.connecting;
    onCallStateChanged?.call(_callState);
    debugPrint('📞 Call state changed to connecting');

    // Process the pending offer now that we have the local stream
    if (_pendingOffer != null) {
      debugPrint('📥 Processing pending offer after user answered');
      await _processOffer(_pendingOffer!);
      _pendingOffer = null;
    } else {
      debugPrint('⚠️ No pending offer to process');

      // FALLBACK: Request pending offer from backend if we don't have one
      // This handles the case where FCM notification was received while app was in background
      // and the original WebRTC offer wasn't properly stored or received
      if (_callRoomId != null) {
        debugPrint(
          '📞 Requesting pending offer as fallback before answering...',
        );
        _socketService.emit('request_pending_offer', {'room': _callRoomId});

        // Wait a moment for the offer to arrive, then check again
        await Future.delayed(const Duration(milliseconds: 1500));

        if (_pendingOffer != null) {
          debugPrint('📥 Processing fallback pending offer after delay');
          await _processOffer(_pendingOffer!);
          _pendingOffer = null;
        } else {
          debugPrint('❌ Still no pending offer after fallback request');
          // The call might still work if the offer arrives later via signal handler
        }
      }
    }
  }

  /// Decline an incoming call
  void declineCall() {
    debugPrint(
      '📴 Declining call - callId: $_callId, callRoomId: $_callRoomId',
    );

    // Emit decline_call for backend-managed calls (initiate_call flow)
    if (_callId != null) {
      _socketService.emit('decline_call', {'call_id': _callId});
    }

    // Also emit signal-based decline for cross-room calls (web client compatibility)
    if (_callRoomId != null) {
      _socketService.emit('signal', {
        'room': _callRoomId,
        'signal': {'type': 'call-ended'},
      });
    }

    _cleanup();
  }

  /// Start emitting the call_keepalive heartbeat for the active call room.
  void _startKeepalive() {
    _keepaliveTimer?.cancel();
    final room = _callRoomId;
    if (room == null || room.isEmpty) return;

    // Beat once immediately so the backend learns this call supports keepalive.
    _socketService.emit('call_keepalive', {'room': room});

    _keepaliveTimer = Timer.periodic(_keepaliveInterval, (_) {
      final activeRoom = _callRoomId;
      if (activeRoom == null || activeRoom.isEmpty) {
        _stopKeepalive();
        return;
      }
      if (_callState != CallState.connected) return;
      _socketService.emit('call_keepalive', {'room': activeRoom});
    });
    debugPrint('💓 Call keepalive started for room: $room');
  }

  /// Stop the call_keepalive heartbeat.
  void _stopKeepalive() {
    if (_keepaliveTimer != null) {
      _keepaliveTimer!.cancel();
      _keepaliveTimer = null;
      debugPrint('💓 Call keepalive stopped');
    }
  }

  /// End the current call
  void endCall() {
    debugPrint('📴 Ending call - callId: $_callId, callRoomId: $_callRoomId');

    // Emit end_call event with call_id
    if (_callId != null) {
      _socketService.emit('end_call', {'call_id': _callId});
    }

    // Also emit to the call room directly for cross-room calls (web client compatibility)
    // Use 'call-ended' with hyphen to match backend signal handler
    if (_callRoomId != null) {
      _socketService.emit('signal', {
        'room': _callRoomId,
        'signal': {'type': 'call-ended'},
      });
    }

    // Use fullCleanup to properly stop camera/mic tracks
    fullCleanup();
  }

  /// Handle call ended event (remote user or timeout)
  void handleCallEnded() {
    debugPrint('📴 Call ended by remote user');
    _callState = CallState.ended;
    onCallStateChanged?.call(_callState);
    fullCleanup();
  }

  /// Handle incoming call event
  void handleIncomingCall(Map<String, dynamic> data) {
    debugPrint('📲 Incoming call: $data');
    debugPrint('📲 Setting _callRoomId to: ${data['call_room_id']}');
    debugPrint(
      '📲 Current call state before: $_callState, direction: $_callDirection',
    );

    _callId = data['id'] as int?;
    _callRoomId = data['call_room_id'] as String?;
    _callType = data['call_type'] as String?;
    _remoteUserId = data['caller']?['id'] as int?;
    _callDirection = CallDirection.incoming;
    _callState = CallState.ringing;

    debugPrint(
      '📲 After setting: _callRoomId=$_callRoomId, _callId=$_callId, _callDirection=$_callDirection, _callState=$_callState',
    );

    onCallStateChanged?.call(_callState);
    onIncomingCall?.call(data);
  }

  /// Handle call initiated confirmation
  void handleCallInitiated(Map<String, dynamic> data) {
    debugPrint('✅ Call initiated: $data');
    _callId = data['id'] as int?;
    _callRoomId = data['call_room_id'] as String?;
  }

  /// Clean up resources - properly close peer connection and stop tracks
  void _cleanup() {
    debugPrint('🧹 Cleaning up call resources');

    _stopKeepalive();

    _socketService.removeListener(
      'screenShareStarted',
      _screenShareListenerKey,
    );
    _socketService.removeListener(
      'screenShareStopped',
      _screenShareListenerKey,
    );
    _socketService.removeListener('callAnswered', 'call_service_call_answered');
    _socketService.removeListener(
      'callSessionState',
      'call_service_call_session_state',
    );

    // Close data channel
    _dataChannel?.close();
    _dataChannel = null;

    // Close peer connection first
    _peerConnection?.close();
    _peerConnection = null;

    // Note: We don't dispose _localStream here since it's managed by the caller
    // The caller should dispose it when appropriate
    _localStream = null;
    _remoteStream = null;
    _primaryRemoteStream = null;

    // Reset screen share tracking
    _cameraStreamId = null;
    _screenShareStreamId = null;
    _remoteIsScreenSharing = false;

    _callState = CallState.idle;
    _callDirection = null;
    _callId = null;
    _remoteUserId = null;
    _callRoomId = null;
    _callType = null;
    _connectedAt = null;
    _connectedAtMs = null;

    // Reset ICE candidate queuing state
    _remoteDescriptionSet = false;
    _earlyIceCandidates.clear();
    _candidateQueue.clear();

    onCallStateChanged?.call(_callState);
  }

  /// Full cleanup including stopping and disposing local stream
  /// Call this when the call UI is being completely closed
  void fullCleanup() {
    debugPrint('🧹 Full cleanup - stopping all tracks and disposing streams');

    _stopKeepalive();

    _socketService.removeListener(
      'screenShareStarted',
      _screenShareListenerKey,
    );
    _socketService.removeListener(
      'screenShareStopped',
      _screenShareListenerKey,
    );
    _socketService.removeListener('callAnswered', 'call_service_call_answered');
    _socketService.removeListener(
      'callSessionState',
      'call_service_call_session_state',
    );

    // DON'T clear onCallStateChanged here - let the UI handle the state change first
    // Only clear other callbacks that aren't needed for cleanup notification
    onLocalStream = null;
    onRemoteStream = null;
    onIncomingCall = null;
    onCallError = null;
    onScreenShareChanged = null;
    onRemoteScreenShare = null;
    onDataChannelMessage = null;

    // Close data channel
    _dataChannel?.close();
    _dataChannel = null;

    // Stop screen sharing if active
    if (_isScreenSharing) {
      if (_screenStream != null) {
        for (var track in _screenStream!.getTracks()) {
          track.stop();
        }
        _screenStream!.dispose();
        _screenStream = null;
      }
      _isScreenSharing = false;
      _originalVideoTrack = null;
    }

    // Stop all local tracks (camera, microphone)
    if (_localStream != null) {
      for (var track in _localStream!.getTracks()) {
        track.stop();
      }
      _localStream!.dispose();
    }

    // Dispose remote stream
    if (_remoteStream != null) {
      _remoteStream!.dispose();
    }

    // Close peer connection
    _peerConnection?.close();
    _peerConnection = null;

    _localStream = null;
    _remoteStream = null;
    _primaryRemoteStream = null;

    // Reset screen share tracking
    _cameraStreamId = null;
    _screenShareStreamId = null;
    _remoteIsScreenSharing = false;

    _callState = CallState.idle;
    _callDirection = null;
    _callId = null;
    _remoteUserId = null;
    _callRoomId = null;
    _callType = null;
    _connectedAt = null;
    _connectedAtMs = null;

    // Reset ICE candidate queuing state
    _remoteDescriptionSet = false;
    _earlyIceCandidates.clear();
    _candidateQueue.clear();

    onCallStateChanged?.call(_callState);
  }

  /// Handle call declined event (remote user declined)
  void handleCallDeclined() {
    debugPrint('❌ Call was declined by remote user');
    _callState = CallState.ended;
    onCallStateChanged?.call(_callState);
    fullCleanup();
  }

  /// Toggle local video
  void toggleVideo(bool enabled) {
    if (_localStream != null) {
      for (var track in _localStream!.getVideoTracks()) {
        track.enabled = enabled;
      }
    }
  }

  /// Toggle local audio (mute/unmute)
  void toggleAudio(bool enabled) {
    if (_localStream != null) {
      for (var track in _localStream!.getAudioTracks()) {
        track.enabled = enabled;
      }
    }
  }

  // ── Noise filter state ──────────────────────────────────────────────────────
  bool _noiseFilterEnabled = false;
  bool get isNoiseFilterEnabled => _noiseFilterEnabled;

  /// Toggle background-noise / echo / AGC processing on the local audio track.
  ///
  /// Uses WebRTC's built-in APM (Audio Processing Module) via [applyConstraints]:
  ///   • noiseSuppression  – spectral subtraction + ML noise gate (best for wind, AC, crowd)
  ///   • echoCancellation  – removes speaker feedback from the microphone
  ///   • autoGainControl   – normalises loudness so quiet voices aren't buried
  ///
  /// All three are toggled together so the button is either "clean audio" or
  /// "raw audio" — simple for the user. The state is persisted in
  /// [_noiseFilterEnabled] so the UI can show the active state.
  Future<bool> toggleNoiseFilter() async {
    _noiseFilterEnabled = !_noiseFilterEnabled;
    final enabled = _noiseFilterEnabled;

    // 1️⃣ Apply to our OWN outgoing audio (cleans what the web user hears from us)
    final audioTracks = _localStream?.getAudioTracks() ?? [];
    for (final track in audioTracks) {
      try {
        await track.applyConstraints({
          'noiseSuppression': enabled,
          'echoCancellation': enabled,
          'autoGainControl': enabled,
        });
        debugPrint(
          '🎙️ Local noise filter ${enabled ? 'ON' : 'OFF'} for track ${track.id}',
        );
      } catch (e) {
        debugPrint('⚠️ applyConstraints failed for track ${track.id}: $e');
      }
    }

    // 2️⃣ Signal the web peer to toggle THEIR RNNoise AI filter on their mic
    //    (this cleans the audio WE HEAR coming from the web user)
    if (_callRoomId != null && _callRoomId!.isNotEmpty) {
      _socketService.emit('signal', {
        'room': _callRoomId,
        'signal': {'type': 'noise-filter-toggle', 'enabled': enabled},
      });
      debugPrint(
        '📡 Sent noise-filter-toggle signal to web peer (enabled=$enabled)',
      );
    }

    return _noiseFilterEnabled;
  }

  /// Switch camera (front/back)
  Future<void> switchCamera() async {
    if (_localStream != null) {
      final videoTrack = _localStream!.getVideoTracks().firstOrNull;
      if (videoTrack != null) {
        await Helper.switchCamera(videoTrack);
      }
    }
  }

  Future<void> _applyScreenTrackConstraints(MediaStreamTrack track) async {
    try {
      await track.applyConstraints({
        'width': {'ideal': 1920, 'max': 1920},
        'height': {'ideal': 1080, 'max': 1080},
        'frameRate': {'ideal': 30, 'max': 30},
      });
      debugPrint('🖥️ Applied screen-share track constraints (1080p/30fps)');
    } catch (e) {
      debugPrint('⚠️ Could not apply screen-share track constraints: $e');
    }
  }

  Future<void> _applyVideoSenderProfile(
    RTCRtpSender sender, {
    required int maxBitrate,
    required int minBitrate,
    required int maxFramerate,
    required RTCDegradationPreference degradationPreference,
  }) async {
    try {
      final parameters = sender.parameters;
      final encodings = parameters.encodings ?? <RTCRtpEncoding>[];
      if (encodings.isEmpty) {
        encodings.add(RTCRtpEncoding());
      }

      for (final encoding in encodings) {
        encoding.maxBitrate = maxBitrate;
        encoding.minBitrate = minBitrate;
        encoding.maxFramerate = maxFramerate;
        encoding.scaleResolutionDownBy = 1.0;
        encoding.priority = RTCPriorityType.high;
        encoding.networkPriority = RTCPriorityType.high;
      }

      parameters.encodings = encodings;
      parameters.degradationPreference = degradationPreference;
      await sender.setParameters(parameters);

      debugPrint(
        '🎚️ Updated video sender params (maxBitrate=$maxBitrate, maxFramerate=$maxFramerate)',
      );
    } catch (e) {
      debugPrint('⚠️ Failed to update video sender params: $e');
    }
  }

  /// Start screen sharing
  Future<bool> startScreenShare() async {
    if (_peerConnection == null) {
      debugPrint('❌ Cannot start screen share: no peer connection');
      return false;
    }

    if (_isScreenSharing) {
      debugPrint('⚠️ Already sharing screen');
      return true;
    }

    try {
      debugPrint('🖥️ Starting screen share...');
      debugPrint('🖥️ Preparing native Android screen share flow');

      // On Android, we need to start the foreground service first
      // This is required for media projection on Android 10+
      try {
        const channel = MethodChannel(
          'com.example.flutter_messenger_v2/screen_share',
        );
        debugPrint('🖥️ Invoking startForegroundService via MethodChannel');
        final result = await channel.invokeMethod('startForegroundService', {
          'notificationTitle': 'Screen Sharing',
          'notificationText': 'You are sharing your screen',
        });
        debugPrint('🖥️ Foreground service started, result: $result');
      } catch (e, stack) {
        debugPrint(
          '⚠️ Could not start foreground service (may not be needed on this platform): $e',
        );
        debugPrint(stack.toString().split('\n').take(5).join('\n'));
      }

      debugPrint(
        '🖥️ Requesting display media (native screen prompt should appear now)',
      );
      try {
        _screenStream = await navigator.mediaDevices.getDisplayMedia({
          'video': {
            'width': {'ideal': 1920, 'max': 1920},
            'height': {'ideal': 1080, 'max': 1080},
            'frameRate': {'ideal': 30, 'max': 30},
          },
          // Keep the existing microphone track for call audio.
          // Capturing system audio on Android is less reliable and can hurt FPS.
          'audio': false,
        });
      } catch (e, stack) {
        debugPrint('❌ getDisplayMedia failed: $e');
        debugPrint(stack.toString().split('\n').take(10).join('\n'));
        rethrow;
      }

      if (_screenStream == null) {
        debugPrint('❌ Failed to get screen stream');
        return false;
      }
      debugPrint(
        '🖥️ Display media stream obtained: ${_screenStream!.id}, tracks: ${_screenStream!.getTracks().map((t) => '${t.kind}:${t.id}').join(', ')}',
      );

      // Get the screen video track
      final screenTrack = _screenStream!.getVideoTracks().firstOrNull;
      if (screenTrack == null) {
        debugPrint('❌ No video track in screen stream');
        await _screenStream!.dispose();
        _screenStream = null;
        return false;
      }
      debugPrint(
        '🖥️ Screen track obtained: ${screenTrack.id}, kind=${screenTrack.kind}',
      );

      await _applyScreenTrackConstraints(screenTrack);

      // Store original video track for later restoration
      if (_localStream != null) {
        _originalVideoTrack = _localStream!.getVideoTracks().firstOrNull;
      }

      // Disable original camera track so we don't send both camera and screen
      if (_originalVideoTrack != null) {
        try {
          _originalVideoTrack!.enabled = false;
          debugPrint('🖥️ Disabled original camera track before screen share');
        } catch (e) {
          debugPrint('⚠️ Could not disable original camera track: $e');
        }
      }

      // Replace the video track in the peer connection
      final senders = await _peerConnection!.getSenders();
      RTCRtpSender? videoSender;

      // Find existing video sender
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          videoSender = sender;
          break;
        }
      }

      if (videoSender != null) {
        // Replace existing video track (video calls)
        try {
          await videoSender.replaceTrack(screenTrack);
          await _applyVideoSenderProfile(
            videoSender,
            maxBitrate: 3000000,
            minBitrate: 800000,
            maxFramerate: 30,
            degradationPreference: RTCDegradationPreference.MAINTAIN_RESOLUTION,
          );
          debugPrint('🖥️ Replaced existing video track with screen share');

          // Set screen sharing flag BEFORE renegotiation so it's included in signal
          _isScreenSharing = true;

          // CRITICAL FIX: Trigger renegotiation even for video calls
          // This ensures web clients receive updated SDP with new track
          await _triggerRenegotiation(reason: 'screen-share-started');
        } catch (e) {
          debugPrint('❌ Failed to replace video track with screen share: $e');
          // Fallback: add the screen track as a new sender if replace fails
          final screenSender = await _peerConnection!.addTrack(
            screenTrack,
            _screenStream!,
          );
          await _applyVideoSenderProfile(
            screenSender,
            maxBitrate: 3000000,
            minBitrate: 800000,
            maxFramerate: 30,
            degradationPreference: RTCDegradationPreference.MAINTAIN_RESOLUTION,
          );
          debugPrint('🖥️ Fallback: added screen track as new sender');

          // Set screen sharing flag BEFORE renegotiation
          _isScreenSharing = true;

          await _triggerRenegotiation(reason: 'screen-share-started-fallback');
        }
      } else {
        // Add new video track (audio calls that want to share screen)
        final screenSender = await _peerConnection!.addTrack(
          screenTrack,
          _screenStream!,
        );
        await _applyVideoSenderProfile(
          screenSender,
          maxBitrate: 3000000,
          minBitrate: 800000,
          maxFramerate: 30,
          degradationPreference: RTCDegradationPreference.MAINTAIN_RESOLUTION,
        );
        debugPrint('🖥️ Added new video track for screen share (audio call)');

        // Set screen sharing flag BEFORE renegotiation
        _isScreenSharing = true;

        // Trigger renegotiation for audio calls
        await _triggerRenegotiation(reason: 'screen-share-started-audio');
      }

      // Listen for when user stops sharing via system UI
      screenTrack.onEnded = () {
        debugPrint('🖥️ Screen share ended by user');
        stopScreenShare();
      };

      // Notify UI about screen share state change
      onScreenShareChanged?.call(true);

      // Notify remote user about screen share via signal
      _socketService.emit('signal', {
        'room': _callRoomId,
        'signal': {'type': 'screen-share-started'},
      });

      // Compatibility event for web clients that listen to dedicated events.
      _socketService.emit('screen_share_started', {
        'room': _callRoomId,
        'call_room_id': _callRoomId,
        'call_id': _callId,
      });

      // Also send the normal signal path above for backward compatibility.
      debugPrint('✅ Screen sharing started');
      return true;
    } catch (e, stack) {
      debugPrint('❌ Error starting screen share: $e');
      debugPrint(stack.toString().split('\n').take(10).join('\n'));
      return false;
    }
  }

  /// Stop screen sharing and restore camera
  Future<void> stopScreenShare() async {
    if (!_isScreenSharing) {
      return;
    }

    try {
      debugPrint('🖥️ Stopping screen share...');

      // Handle video track restoration/removal
      if (_originalVideoTrack != null && _peerConnection != null) {
        // Video call - re-enable and restore original camera track
        try {
          _originalVideoTrack!.enabled = true;
          debugPrint('🖥️ Re-enabled original camera track before restore');
        } catch (e) {
          debugPrint('⚠️ Could not re-enable original camera track: $e');
        }

        final senders = await _peerConnection!.getSenders();
        for (final sender in senders) {
          if (sender.track?.kind == 'video') {
            try {
              await sender.replaceTrack(_originalVideoTrack);
              await _applyVideoSenderProfile(
                sender,
                maxBitrate: 1800000,
                minBitrate: 400000,
                maxFramerate: 30,
                degradationPreference: RTCDegradationPreference.BALANCED,
              );
              debugPrint('🖥️ Restored original video track');

              // CRITICAL FIX: Trigger renegotiation when restoring camera
              // This ensures web clients receive updated SDP with restored track
              await _triggerRenegotiation(reason: 'screen-share-stopped');
            } catch (e) {
              debugPrint('❌ Failed to restore original video track: $e');
            }
            break;
          }
        }
      } else if (_peerConnection != null) {
        // Audio call - remove the video sender we added for screen share
        final senders = await _peerConnection!.getSenders();
        for (final sender in senders) {
          if (sender.track?.kind == 'video') {
            await _peerConnection!.removeTrack(sender);
            debugPrint(
              '🖥️ Removed video track (audio call screen share ended)',
            );

            // Trigger renegotiation to notify remote peer
            await _triggerRenegotiation(reason: 'screen-share-stopped-audio');
            break;
          }
        }
      }

      // Stop and dispose screen stream
      if (_screenStream != null) {
        for (var track in _screenStream!.getTracks()) {
          track.stop();
        }
        await _screenStream!.dispose();
        _screenStream = null;
      }

      _isScreenSharing = false;
      _originalVideoTrack = null;
      onScreenShareChanged?.call(false);

      // Notify remote user about screen share stop via signal
      _socketService.emit('signal', {
        'room': _callRoomId,
        'signal': {'type': 'screen-share-stopped'},
      });

      // Compatibility event for web clients that listen to dedicated events.
      _socketService.emit('screen_share_stopped', {
        'room': _callRoomId,
        'call_room_id': _callRoomId,
        'call_id': _callId,
      });

      // Also send the normal signal path above for backward compatibility.

      // Stop the foreground service on Android
      try {
        const channel = MethodChannel(
          'com.example.flutter_messenger_v2/screen_share',
        );
        await channel.invokeMethod('stopForegroundService');
        debugPrint('🖥️ Foreground service stopped');
      } catch (e) {
        debugPrint('⚠️ Could not stop foreground service: $e');
      }

      debugPrint('✅ Screen sharing stopped');
    } catch (e) {
      debugPrint('❌ Error stopping screen share: $e');
    }
  }

  /// Toggle screen sharing
  Future<bool> toggleScreenShare() async {
    if (_isScreenSharing) {
      await stopScreenShare();
      return false;
    } else {
      return await startScreenShare();
    }
  }
}
