import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/storage_service.dart';
import '../services/version_service.dart';
import '../utils/notification_handler.dart';

class SettingsModal extends StatefulWidget {
  const SettingsModal({super.key});

  @override
  State<SettingsModal> createState() => _SettingsModalState();
}

class _SettingsModalState extends State<SettingsModal> {
  static const _bg = Color(0xFF1E293B);
  static const _card = Color(0xFF252542);
  static const _innerBox = Color(0xFF111827);
  static const _border = Color(0xFF374151);
  static const _accent = Color(0xFF6366F1);
  static const _accentSoft = Color(0xFFA78BFA);

  bool _useMilitaryTime = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _useMilitaryTime = StorageService.useMilitaryTime;
  }

  void _handleSave() async {
    await StorageService.saveUseMilitaryTime(_useMilitaryTime);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Settings saved successfully'),
        backgroundColor: Color(0xFF22C55E),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );

    Navigator.pop(context, true);
  }

  Future<void> _handleCheckNow() async {
    if (_checking) return;
    setState(() => _checking = true);

    await VersionService().checkAndPromptUpdate(
      NotificationHandler.navigatorKey.currentContext,
      force: true,
    );

    if (!mounted) return;
    setState(() => _checking = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Checked for updates. New versions download automatically.',
        ),
        backgroundColor: Color(0xFF22C55E),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 400,
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.settings, color: _accentSoft, size: 22),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Settings',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close, color: Colors.white70),
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: _border),
            // Scrollable content
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildTimestampCard(),
                    const SizedBox(height: 16),
                    _buildUpdatesCard(),
                    const SizedBox(height: 16),
                    _buildVersionRow(),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: _border),
            // Footer
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                    ),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _handleSave,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: const Text(
                      'Save',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _border),
      ),
      child: child,
    );
  }

  Widget _buildTimestampCard() {
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Timestamp Format',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Choose how message timestamps are displayed.',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _buildOptionBox(
                title: 'AM/PM (default)',
                isSelected: !_useMilitaryTime,
                onTap: () => setState(() => _useMilitaryTime = false),
              ),
              _buildOptionBox(
                title: 'Military (24‑hour)',
                isSelected: _useMilitaryTime,
                onTap: () => setState(() => _useMilitaryTime = true),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUpdatesCard() {
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'App Updates',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'New versions download automatically in the background. When one is '
            'ready you\'ll see a badge and a notification — just tap to install.',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _checking ? null : _handleCheckNow,
              style: OutlinedButton.styleFrom(
                foregroundColor: _accentSoft,
                side: const BorderSide(color: _accent),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: _checking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _accentSoft,
                      ),
                    )
                  : const Icon(Icons.system_update_alt_rounded, size: 18),
              label: Text(_checking ? 'Checking…' : 'Check for updates now'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVersionRow() {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final label = snapshot.hasData
            ? 'App version ${snapshot.data!.version} (build ${snapshot.data!.buildNumber})'
            : 'App version …';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        );
      },
    );
  }

  Widget _buildOptionBox({
    required String title,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 140, maxWidth: 220),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: _innerBox,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isSelected ? _accent : _border, width: 1),
        ),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: isSelected ? _accentSoft : Colors.white70,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                softWrap: true,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
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
}
