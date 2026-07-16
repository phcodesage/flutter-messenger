import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../services/storage_service.dart';
import '../services/version_service.dart';
import '../utils/notification_handler.dart';
import 'avatar_crop_screen.dart';

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

  // Profile editing state
  final TextEditingController _usernameCtrl = TextEditingController();
  final TextEditingController _firstNameCtrl = TextEditingController();
  final TextEditingController _lastNameCtrl = TextEditingController();
  String? _avatarUrl;
  bool _avatarBusy = false;
  bool _profileBusy = false;
  String? _profileMsg;
  bool _profileMsgIsError = false;

  @override
  void initState() {
    super.initState();
    _useMilitaryTime = StorageService.useMilitaryTime;
    _loadProfile();
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    // Instant placeholder from local cache while the server fetch runs.
    final username = await StorageService.getUsername();
    if (!mounted) return;
    setState(() {
      _usernameCtrl.text = username ?? '';
    });
    final sp = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _avatarUrl = sp.getString('my_avatar_url'));

    // Authoritative copy from the server — picks up changes made on web or
    // another device (the local pref only knows about uploads from this one).
    try {
      final token = await StorageService.getToken();
      final res = await http.get(
        Uri.parse(ApiConfig.profileUrl),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] != true) return;
      final serverUsername = body['username'] as String?;
      final serverAvatar = body['avatar_url'] as String?;
      if (serverUsername != null && serverUsername.isNotEmpty) {
        await StorageService.saveUsername(serverUsername);
      }
      if (serverAvatar != null && serverAvatar.isNotEmpty) {
        await sp.setString('my_avatar_url', serverAvatar);
      } else {
        await sp.remove('my_avatar_url');
      }
      if (!mounted) return;
      setState(() {
        if (serverUsername != null && serverUsername.isNotEmpty) {
          _usernameCtrl.text = serverUsername;
        }
        _firstNameCtrl.text = body['first_name'] as String? ?? '';
        _lastNameCtrl.text = body['last_name'] as String? ?? '';
        _avatarUrl = serverAvatar;
      });
    } catch (_) {
      // Offline — cached values stay.
    }
  }

  Future<void> _saveProfile() async {
    final username = _usernameCtrl.text.trim();
    if (username.isEmpty || _profileBusy) return;
    setState(() {
      _profileBusy = true;
      _profileMsg = null;
    });
    try {
      final token = await StorageService.getToken();
      final res = await http.post(
        Uri.parse(ApiConfig.profileUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'username': username,
          'first_name': _firstNameCtrl.text.trim(),
          'last_name': _lastNameCtrl.text.trim(),
        }),
      );
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (!mounted) return;
      if (res.statusCode == 200 && body['success'] == true) {
        await StorageService.saveUsername(body['username'] as String? ?? username);
        setState(() {
          _profileMsg = 'Profile saved ✓';
          _profileMsgIsError = false;
        });
      } else {
        setState(() {
          _profileMsg = body['error'] as String? ?? 'Could not save profile';
          _profileMsgIsError = true;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _profileMsg = 'Request failed — check connection';
        _profileMsgIsError = true;
      });
    } finally {
      if (mounted) setState(() => _profileBusy = false);
    }
  }

  Future<void> _pickAndUploadAvatar() async {
    if (_avatarBusy) return;
    // Pick at high-ish resolution so there is room to crop, then let the
    // user frame it. GIFs skip the crop (canvas would kill the animation).
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 92,
    );
    if (picked == null || !mounted) return;

    http.MultipartFile uploadFile;
    if (picked.path.toLowerCase().endsWith('.gif')) {
      uploadFile = await http.MultipartFile.fromPath('avatar', picked.path);
    } else {
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      final cropped = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          builder: (_) => AvatarCropScreen(imageBytes: bytes),
          fullscreenDialog: true,
        ),
      );
      if (cropped == null || !mounted) return; // cancelled
      uploadFile = http.MultipartFile.fromBytes(
        'avatar',
        cropped,
        filename: 'avatar.png',
      );
    }

    setState(() => _avatarBusy = true);
    try {
      final token = await StorageService.getToken();
      final req = http.MultipartRequest('POST', Uri.parse(ApiConfig.profileAvatarUrl))
        ..headers['Authorization'] = 'Bearer $token'
        ..files.add(uploadFile);
      final streamed = await req.send();
      final res = await http.Response.fromStream(streamed);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (!mounted) return;
      if (res.statusCode == 200 && body['success'] == true) {
        final url = body['avatar_url'] as String?;
        setState(() => _avatarUrl = url);
        if (url != null) {
          final sp = await SharedPreferences.getInstance();
          await sp.setString('my_avatar_url', url);
        }
      } else {
        _showError(body['error'] as String? ?? 'Avatar upload failed');
      }
    } catch (e) {
      if (mounted) _showError('Avatar upload failed');
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  Future<void> _removeAvatar() async {
    if (_avatarBusy) return;
    setState(() => _avatarBusy = true);
    try {
      final token = await StorageService.getToken();
      final res = await http.delete(
        Uri.parse(ApiConfig.profileAvatarUrl),
        headers: {'Authorization': 'Bearer $token'},
      );
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (!mounted) return;
      if (res.statusCode == 200 && body['success'] == true) {
        setState(() => _avatarUrl = body['avatar_url'] as String?);
        final sp = await SharedPreferences.getInstance();
        await sp.remove('my_avatar_url');
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFFDC2626),
        behavior: SnackBarBehavior.floating,
      ),
    );
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
                    _buildProfileCard(),
                    const SizedBox(height: 16),
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

  InputDecoration _profileFieldDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54),
      counterText: '',
      filled: true,
      fillColor: _innerBox,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _accent),
      ),
    );
  }

  Widget _buildProfileCard() {
    return _sectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Profile',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Your photo and name, visible to everyone.',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 16),
          Center(
            child: Column(
              children: [
                GestureDetector(
                  onTap: _avatarBusy ? null : _pickAndUploadAvatar,
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 44,
                        backgroundColor: _innerBox,
                        backgroundImage:
                            (_avatarUrl != null && _avatarUrl!.isNotEmpty)
                                ? NetworkImage(_avatarUrl!)
                                : null,
                        child: (_avatarUrl == null || _avatarUrl!.isEmpty)
                            ? const Icon(Icons.person,
                                color: Colors.white38, size: 44)
                            : null,
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F766E),
                            shape: BoxShape.circle,
                            border: Border.all(color: _card, width: 2),
                          ),
                          child: _avatarBusy
                              ? const Padding(
                                  padding: EdgeInsets.all(6),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.photo_camera,
                                  color: Colors.white, size: 14),
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _avatarBusy ? null : _removeAvatar,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white54,
                  ),
                  child: const Text('Remove photo', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _firstNameCtrl,
                  maxLength: 50,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  decoration: _profileFieldDecoration('First name'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _lastNameCtrl,
                  maxLength: 50,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  decoration: _profileFieldDecoration('Last name'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _usernameCtrl,
            maxLength: 32,
            style: const TextStyle(color: Colors.white, fontSize: 15),
            decoration: _profileFieldDecoration('Username (login & mentions)'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _profileMsg == null
                    ? const SizedBox.shrink()
                    : Text(
                        _profileMsg!,
                        style: TextStyle(
                          color: _profileMsgIsError
                              ? const Color(0xFFF87171)
                              : const Color(0xFF22C55E),
                          fontSize: 12,
                        ),
                      ),
              ),
              ElevatedButton(
                onPressed: _profileBusy ? null : _saveProfile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                ),
                child: Text(_profileBusy ? 'Saving…' : 'Save profile'),
              ),
            ],
          ),
        ],
      ),
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
