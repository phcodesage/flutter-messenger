import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'socket_service.dart';
import 'storage_service.dart';
import '../config/api_config.dart';

/// One participant's WebRTC state
class GroupCallParticipant {
  final String peerId;
  final RTCPeerConnection pc;
  RTCVideoRenderer renderer;
  bool remoteDescriptionSet = false;
  final List<RTCIceCandidate> pendingCandidates = [];

  GroupCallParticipant({required this.peerId, required this.pc, required this.renderer});
}

/// Manages a full-mesh WebRTC group call.
///
/// Signaling uses the mesh_* socket events on the shared SocketService.
/// ICE servers are fetched once on initialize().
///
/// Offer/answer strategy (no Perfect Negotiation needed):
///   Lower peerId string → sends offer; higher peerId → waits for offer.
///   Since peerIds are user id strings ('123', '456'), lower int = offerer.
class GroupCallService {
  static final GroupCallService _instance = GroupCallService._internal();
  factory GroupCallService() => _instance;
  GroupCallService._internal();

  final SocketService _socket = SocketService();

  String? _roomId;
  String? _myPeerId;
  String? _callType;
  MediaStream? _localStream;
  List<Map<String, dynamic>> _iceServers = [];

  final Map<String, GroupCallParticipant> _peers = {};

  // Callbacks
  Function(MediaStream stream)? onLocalStream;
  Function(String peerId, RTCVideoRenderer renderer)? onParticipantJoined;
  Function(String peerId)? onParticipantLeft;
  Function()? onCallEnded;

  bool get isActive => _roomId != null;
  MediaStream? get localStream => _localStream;
  String? get roomId => _roomId;
  Map<String, GroupCallParticipant> get peers => Map.unmodifiable(_peers);

  Future<void> initialize({
    required String roomId,
    required String myPeerId,
    required String callType,
  }) async {
    _roomId = roomId;
    _myPeerId = myPeerId;
    _callType = callType;

    await _fetchIceServers();
    await _initLocalStream();
    _setupSocketListeners();
    _socket.meshJoin(roomId, myPeerId);
  }

  Future<void> _fetchIceServers() async {
    try {
      final token = await StorageService.getToken();
      final response = await http.get(
        Uri.parse('${ApiConfig.baseUrl}/get-ice-servers'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final servers = data['iceServers'] ?? data['ice_servers'];
        if (servers is List) {
          _iceServers = List<Map<String, dynamic>>.from(servers);
        }
      }
    } catch (e) {
      debugPrint('[GroupCall] ICE server fetch error: $e');
    }
    if (_iceServers.isEmpty) {
      _iceServers = [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ];
    }
  }

  Future<void> _initLocalStream() async {
    try {
      final constraints = <String, dynamic>{
        'audio': true,
        'video': _callType == 'video'
            ? {'facingMode': 'user', 'width': 640, 'height': 480}
            : false,
      };
      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      onLocalStream?.call(_localStream!);
    } catch (e) {
      debugPrint('[GroupCall] Local stream error: $e');
    }
  }

  void _setupSocketListeners() {
    const k = 'group_call_service';
    _socket.addRawListener('mesh_joined', k, _onMeshJoined);
    _socket.addRawListener('mesh_peer_joined', k, _onMeshPeerJoined);
    _socket.addRawListener('mesh_peer_left', k, _onMeshPeerLeft);
    _socket.addRawListener('mesh_offer', k, _onMeshOffer);
    _socket.addRawListener('mesh_answer', k, _onMeshAnswer);
    _socket.addRawListener('mesh_ice', k, _onMeshIce);
    _socket.addRawListener('group_call_ended', k, _onGroupCallEnded);
    _socket.addRawListener('group_call_cancelled', k, _onGroupCallEnded);
  }

  void _removeSocketListeners() {
    const k = 'group_call_service';
    for (final event in ['mesh_joined', 'mesh_peer_joined', 'mesh_peer_left',
        'mesh_offer', 'mesh_answer', 'mesh_ice', 'group_call_ended', 'group_call_cancelled']) {
      _socket.removeRawListener(event, k);
    }
  }

  void _onMeshJoined(dynamic data) async {
    final d = data as Map<String, dynamic>;
    final peers = (d['peers'] as List? ?? []).cast<String>();
    for (final peerId in peers) {
      // Lower peerId string → sends offer
      if (_myPeerId!.compareTo(peerId) < 0) {
        await _createPeerAndOffer(peerId);
      } else {
        // Higher ID waits for the other side's offer — pre-create the PC
        await _getOrCreatePeer(peerId);
      }
    }
  }

  void _onMeshPeerJoined(dynamic data) async {
    final d = data as Map<String, dynamic>;
    final peerId = d['peerId'] as String;
    if (peerId == _myPeerId) return;
    // Lower peerId sends offer to the newcomer
    if (_myPeerId!.compareTo(peerId) < 0) {
      await _createPeerAndOffer(peerId);
    } else {
      await _getOrCreatePeer(peerId);
    }
  }

  void _onMeshPeerLeft(dynamic data) async {
    final d = data as Map<String, dynamic>;
    final peerId = d['peerId'] as String;
    await _removePeer(peerId);
    onParticipantLeft?.call(peerId);
  }

  void _onMeshOffer(dynamic data) async {
    final d = data as Map<String, dynamic>;
    final from = d['from'] as String;
    final sdpMap = d['sdp'] as Map<String, dynamic>;
    final pc = await _getOrCreatePeer(from);
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdpMap['sdp'] as String, sdpMap['type'] as String));
      final participant = _peers[from];
      if (participant != null) participant.remoteDescriptionSet = true;
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      _socket.meshAnswer(_roomId!, _myPeerId!, from, {'type': answer.type, 'sdp': answer.sdp});
      // Drain pending ICE
      if (participant != null) {
        for (final c in participant.pendingCandidates) {
          await pc.addCandidate(c);
        }
        participant.pendingCandidates.clear();
      }
    } catch (e) {
      debugPrint('[GroupCall] Error handling offer from $from: $e');
    }
  }

  void _onMeshAnswer(dynamic data) async {
    final d = data as Map<String, dynamic>;
    final from = d['from'] as String;
    final sdpMap = d['sdp'] as Map<String, dynamic>;
    final participant = _peers[from];
    if (participant == null) return;
    try {
      await participant.pc.setRemoteDescription(RTCSessionDescription(sdpMap['sdp'] as String, sdpMap['type'] as String));
      participant.remoteDescriptionSet = true;
      for (final c in participant.pendingCandidates) {
        await participant.pc.addCandidate(c);
      }
      participant.pendingCandidates.clear();
    } catch (e) {
      debugPrint('[GroupCall] Error handling answer from $from: $e');
    }
  }

  void _onMeshIce(dynamic data) async {
    final d = data as Map<String, dynamic>;
    final from = d['from'] as String;
    final candidateMap = d['candidate'] as Map<String, dynamic>;
    final candidate = RTCIceCandidate(
      candidateMap['candidate'] as String,
      candidateMap['sdpMid'] as String?,
      candidateMap['sdpMLineIndex'] as int?,
    );
    final participant = _peers[from];
    if (participant == null) return;
    try {
      if (!participant.remoteDescriptionSet) {
        participant.pendingCandidates.add(candidate);
      } else {
        await participant.pc.addCandidate(candidate);
      }
    } catch (e) {
      debugPrint('[GroupCall] ICE error from $from: $e');
    }
  }

  void _onGroupCallEnded(dynamic data) {
    onCallEnded?.call();
  }

  Future<RTCPeerConnection> _getOrCreatePeer(String peerId) async {
    if (_peers.containsKey(peerId)) return _peers[peerId]!.pc;

    final config = <String, dynamic>{
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
    };
    final pc = await createPeerConnection(config);
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    final participant = GroupCallParticipant(peerId: peerId, pc: pc, renderer: renderer);
    _peers[peerId] = participant;

    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await pc.addTrack(track, _localStream!);
      }
    }

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate != null && _roomId != null) {
        _socket.meshIce(_roomId!, _myPeerId!, peerId, {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      }
    };

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        renderer.srcObject = event.streams.first;
        onParticipantJoined?.call(peerId, renderer);
      }
    };

    return pc;
  }

  Future<void> _createPeerAndOffer(String peerId) async {
    final pc = await _getOrCreatePeer(peerId);
    try {
      final offer = await pc.createOffer({'offerToReceiveAudio': 1, 'offerToReceiveVideo': _callType == 'video' ? 1 : 0});
      await pc.setLocalDescription(offer);
      _socket.meshOffer(_roomId!, _myPeerId!, peerId, {'type': offer.type, 'sdp': offer.sdp});
    } catch (e) {
      debugPrint('[GroupCall] Error creating offer for $peerId: $e');
    }
  }

  Future<void> _removePeer(String peerId) async {
    final participant = _peers.remove(peerId);
    if (participant == null) return;
    try {
      participant.pc.close();
      participant.renderer.dispose();
    } catch (_) {}
  }

  void toggleMute() {
    _localStream?.getAudioTracks().forEach((t) {
      t.enabled = !t.enabled;
    });
  }

  bool get isMuted {
    final tracks = _localStream?.getAudioTracks() ?? [];
    return tracks.isEmpty || !tracks.first.enabled;
  }

  void toggleCamera() {
    _localStream?.getVideoTracks().forEach((t) {
      t.enabled = !t.enabled;
    });
  }

  bool get isCameraOff {
    final tracks = _localStream?.getVideoTracks() ?? [];
    return tracks.isEmpty || !tracks.first.enabled;
  }

  Future<void> dispose() async {
    _removeSocketListeners();
    if (_roomId != null && _myPeerId != null) {
      _socket.meshLeave(_roomId!, _myPeerId!);
      _socket.leaveGroupCall(_roomId!, _myPeerId!);
    }
    for (final p in _peers.values) {
      try {
        p.pc.close();
        p.renderer.dispose();
      } catch (_) {}
    }
    _peers.clear();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    _roomId = null;
    _myPeerId = null;
    _callType = null;
    onLocalStream = null;
    onParticipantJoined = null;
    onParticipantLeft = null;
    onCallEnded = null;
  }
}
