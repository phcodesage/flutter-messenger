import 'package:flutter/material.dart';

/// Persistent mic / camera status pills for a 1:1 call.
///
/// The mobile equivalent of call-media-status.js on web, with the same
/// reasoning: device changes used to be a transient toast, so seconds later
/// there was no way to tell whether the person you cannot hear is muted or just
/// quiet. These hold the state on screen for as long as it lasts, on both the
/// local preview and the remote view.
///
/// Colours match the web badges so the two clients look like one product:
/// solid yellow-green when on, Material error red when off, white throughout.
class CallStatusBadges extends StatelessWidget {
  const CallStatusBadges({
    super.key,
    required this.micOn,
    required this.isSelf,
    this.cameraOn,
    this.compact = false,
  });

  final bool micOn;

  /// Null in an audio call — there is no camera in play, and a permanent
  /// "video hidden" pill would be noise rather than information.
  final bool? cameraOn;

  /// Whose state this is; only affects the accessibility label.
  final bool isSelf;

  /// Smaller pills for the local preview thumbnail, which is a fraction of the
  /// size of the remote view.
  final bool compact;

  static const Color _onColor = Color(0xFF558B2F); // yellow-green
  static const Color _offColor = Color(0xFFD93025); // Material error red

  @override
  Widget build(BuildContext context) {
    final cam = cameraOn;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _pill(
          icon: micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
          label: micOn ? null : 'Muted',
          on: micOn,
          semantics: micOn
              ? (isSelf ? 'Your microphone is on' : "Peer's microphone is on")
              : (isSelf ? 'You are muted' : 'Peer is muted'),
        ),
        if (cam != null) ...[
          const SizedBox(width: 6),
          _pill(
            icon: cam ? Icons.videocam_rounded : Icons.videocam_off_rounded,
            // Wording follows the control that causes it ("Hide my video"),
            // not "No camera", which reads as a hardware fault.
            label: cam ? null : 'Video hidden',
            on: cam,
            semantics: cam
                ? (isSelf ? 'Your video is showing' : "Peer's video is showing")
                : (isSelf ? 'Your video is hidden' : "Peer's video is hidden"),
          ),
        ],
      ],
    );
  }

  Widget _pill({
    required IconData icon,
    required String? label,
    required bool on,
    required String semantics,
  }) {
    final iconSize = compact ? 13.0 : 16.0;
    final hPad = label == null ? (compact ? 6.0 : 8.0) : (compact ? 8.0 : 12.0);
    return Semantics(
      label: semantics,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: hPad, vertical: compact ? 4 : 6),
        decoration: BoxDecoration(
          color: on ? _onColor : _offColor,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 6, offset: Offset(0, 2)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: iconSize, color: Colors.white),
            // Only the "off" states carry a word — that is what has to be
            // readable at a glance; "on" stays icon-only to keep the video clear.
            if (label != null) ...[
              SizedBox(width: compact ? 4 : 6),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: compact ? 10 : 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.02,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
