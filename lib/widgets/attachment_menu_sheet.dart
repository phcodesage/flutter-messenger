import 'package:flutter/material.dart';

/// WhatsApp-style bottom sheet attachment menu for the chat composer.
/// Presents Camera, Gallery, and Document options in a fixed order
/// with dark theme styling.
class AttachmentMenuSheet extends StatelessWidget {
  final VoidCallback onCameraTap;
  final VoidCallback onGalleryTap;
  final VoidCallback onDocumentTap;

  const AttachmentMenuSheet({
    super.key,
    required this.onCameraTap,
    required this.onGalleryTap,
    required this.onDocumentTap,
  });

  /// Shows the attachment menu as a modal bottom sheet.
  /// Dismisses on outside tap or swipe down.
  static Future<void> show(
    BuildContext context, {
    required VoidCallback onCameraTap,
    required VoidCallback onGalleryTap,
    required VoidCallback onDocumentTap,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      transitionAnimationController: AnimationController(
        vsync: Navigator.of(context),
        // Instant open/close — no slide-up animation.
        duration: Duration.zero,
      ),
      builder: (context) => AttachmentMenuSheet(
        onCameraTap: () {
          Navigator.of(context).pop();
          onCameraTap();
        },
        onGalleryTap: () {
          Navigator.of(context).pop();
          onGalleryTap();
        },
        onDocumentTap: () {
          Navigator.of(context).pop();
          onDocumentTap();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Menu options
            _AttachmentOption(
              icon: Icons.camera_alt,
              label: 'Camera',
              onTap: onCameraTap,
            ),
            _AttachmentOption(
              icon: Icons.photo_library,
              label: 'Gallery',
              onTap: onGalleryTap,
            ),
            _AttachmentOption(
              icon: Icons.insert_drive_file,
              label: 'Document',
              onTap: onDocumentTap,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// A single option row in the attachment menu.
class _AttachmentOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _AttachmentOption({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(width: 16),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
