import 'package:flutter/material.dart';

import '../models/lobby_user.dart';
import '../services/lobby_service.dart';
import '../services/forward_service.dart';
import '../services/chat_cache_service.dart';
import '../services/storage_service.dart';

/// Bottom sheet picker for selecting DM contacts to forward a message to.
class ForwardRecipientPicker extends StatefulWidget {
  final int currentUserId;
  final void Function(List<int> selectedUserIds) onConfirm;

  const ForwardRecipientPicker({
    super.key,
    required this.currentUserId,
    required this.onConfirm,
  });

  /// Shows the picker as a modal bottom sheet and returns selected user IDs.
  static Future<void> show(
    BuildContext context, {
    required int currentUserId,
    required void Function(List<int> selectedUserIds) onConfirm,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ForwardRecipientPicker(
        currentUserId: currentUserId,
        onConfirm: onConfirm,
      ),
    );
  }

  @override
  State<ForwardRecipientPicker> createState() => _ForwardRecipientPickerState();
}

class _ForwardRecipientPickerState extends State<ForwardRecipientPicker> {
  final Set<int> _selectedIds = {};
  String _searchQuery = '';
  List<LobbyUser>? _users;
  bool _isLoading = true;
  String? _error;

  Set<int> _starredUserIds = {};
  Map<int, int> _forwardFrequencies = {};

  @override
  void initState() {
    super.initState();
    _loadFromCacheInstantly();
    _refreshFromNetworkInBackground();
  }

  /// Step 1: Render immediately from local disk cache + in-memory prefs cache.
  /// No network call — this is synchronous-fast and shows the picker with no spinner.
  Future<void> _loadFromCacheInstantly() async {
    final cachedUsers =
        await ChatCacheService.loadLobbyUsers(widget.currentUserId);
    final cachedPrefs = ForwardService.cachedPreferences;

    // Fall back to SharedPreferences if in-memory prefs not available yet
    Set<int> starred;
    Map<int, int> freq;
    if (cachedPrefs != null) {
      starred = cachedPrefs['starred'] as Set<int>? ?? <int>{};
      freq = cachedPrefs['frequencies'] as Map<int, int>? ?? <int, int>{};
    } else {
      final userId = widget.currentUserId;
      starred = await StorageService.getStarredUserIds(userId);
      freq = await StorageService.getForwardFrequencies(userId);
    }

    if (!mounted) return;
    if (cachedUsers.isNotEmpty) {
      setState(() {
        _starredUserIds = starred;
        _forwardFrequencies = freq;
        _users = cachedUsers
            .where((u) => u.id != widget.currentUserId)
            .toList();
        _sortUsers();
        _isLoading = false; // show instantly without spinner
      });
    }
  }

  /// Step 2: Fetch fresh data from the network silently and update state.
  /// If the cache was empty, this also clears the loading spinner.
  Future<void> _refreshFromNetworkInBackground() async {
    try {
      final prefsData = await ForwardService.getForwardPreferences();
      final starred = prefsData['starred'] as Set<int>? ?? <int>{};
      final freq = prefsData['frequencies'] as Map<int, int>? ?? <int, int>{};

      List<LobbyUser> users;
      try {
        users = await LobbyService.getLobbyUsers();
        await ChatCacheService.saveLobbyUsers(widget.currentUserId, users);
      } catch (e) {
        debugPrint('[ForwardRecipientPicker] Network error, keeping cache: $e');
        // Already rendered from cache — nothing more to do
        if (_users != null && mounted) {
          setState(() => _isLoading = false);
        }
        return;
      }

      if (mounted) {
        setState(() {
          _starredUserIds = starred;
          _forwardFrequencies = freq;
          _users = users
              .where((u) => u.id != widget.currentUserId)
              .toList();
          _sortUsers();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted && _users == null) {
        setState(() {
          _error = 'Failed to load contacts';
          _isLoading = false;
        });
      }
    }
  }

  DateTime _parseUtcTimestamp(String timestamp) {
    final hasTimezone = RegExp(r'[zZ]|[+-]\d{2}:?\d{2}$').hasMatch(timestamp);
    final parsed = DateTime.parse(hasTimezone ? timestamp : '${timestamp}Z');
    return parsed.toLocal();
  }

  DateTime _parseMessageTime(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    try {
      return _parseUtcTimestamp(timestamp);
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  void _sortUsers() {
    if (_users == null) return;
    _users!.sort((a, b) {
      final aStarred = _starredUserIds.contains(a.id);
      final bStarred = _starredUserIds.contains(b.id);
      if (aStarred != bStarred) {
        return aStarred ? -1 : 1;
      }

      final aTime = _parseMessageTime(a.lastMessageTime);
      final bTime = _parseMessageTime(b.lastMessageTime);
      final timeCompare = bTime.compareTo(aTime);
      if (timeCompare != 0) return timeCompare;

      final aFreq = _forwardFrequencies[a.id] ?? 0;
      final bFreq = _forwardFrequencies[b.id] ?? 0;
      if (aFreq != bFreq) {
        return bFreq.compareTo(aFreq);
      }

      if (a.isOnline != b.isOnline) {
        return a.isOnline ? -1 : 1;
      }

      return a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase());
    });
  }

  Future<void> _toggleStar(int userId) async {
    final isStarredNow = await ForwardService.toggleStarredUserId(userId);
    if (mounted) {
      setState(() {
        if (isStarredNow) {
          _starredUserIds.add(userId);
        } else {
          _starredUserIds.remove(userId);
        }
        _sortUsers();
      });
    }
  }

  List<LobbyUser> get _filteredUsers {
    if (_users == null) return [];
    if (_searchQuery.isEmpty) return _users!;
    final q = _searchQuery.toLowerCase();
    return _users!
        .where((u) =>
            u.fullName.toLowerCase().contains(q) ||
            u.username.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: Color(0xFF1a1a2e),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                const Text(
                  'Forward to...',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (_selectedIds.isNotEmpty)
                  Text(
                    '${_selectedIds.length} selected',
                    style: const TextStyle(
                      color: Color(0xFFa78bfa),
                      fontSize: 13,
                    ),
                  ),
              ],
            ),
          ),
          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              onChanged: (v) => setState(() => _searchQuery = v),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search contacts...',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF16213e),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          // Contact list
          Expanded(
            child: _buildContent(),
          ),
          // Confirm button
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: _selectedIds.isEmpty
                      ? null
                      : () {
                           Navigator.pop(context);
                           widget.onConfirm(_selectedIds.toList());
                         },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF7c3aed),
                    disabledBackgroundColor:
                        const Color(0xFF7c3aed).withValues(alpha: 0.3),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _selectedIds.isEmpty
                        ? 'Select recipients'
                        : 'Forward to ${_selectedIds.length} recipient${_selectedIds.length > 1 ? "s" : ""}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF7c3aed)),
      );
    }

    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: const TextStyle(color: Colors.white54),
        ),
      );
    }

    final users = _filteredUsers;
    if (users.isEmpty) {
      return const Center(
        child: Text(
          'No contacts found',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    return ListView.builder(
      itemCount: users.length,
      itemBuilder: (context, index) {
        final user = users[index];
        final isSelected = _selectedIds.contains(user.id);
        final isStarred = _starredUserIds.contains(user.id);
        final freq = _forwardFrequencies[user.id] ?? 0;

        String subtitleText = '@${user.username}';
        Color subtitleColor = Colors.white54;
        if (isStarred) {
          subtitleText = 'Starred';
          subtitleColor = const Color(0xFFfbbf24);
        } else if (freq > 0) {
          subtitleText = 'Forwarded $freq×';
          subtitleColor = const Color(0xFFa78bfa);
        }

        return ListTile(
          leading: CircleAvatar(
            backgroundColor: const Color(0xFF7c3aed),
            backgroundImage: user.avatarUrl != null
                ? NetworkImage(user.avatarUrl!)
                : null,
            child: user.avatarUrl == null
                ? Text(
                    user.initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : null,
          ),
          title: Text(
            user.fullName,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
          subtitle: Text(
            subtitleText,
            style: TextStyle(color: subtitleColor, fontSize: 12),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  isStarred ? Icons.star : Icons.star_border,
                  color: isStarred ? const Color(0xFFfbbf24) : Colors.white38,
                ),
                onPressed: () => _toggleStar(user.id),
              ),
              Checkbox(
                value: isSelected,
                onChanged: (_) => _toggleUser(user.id),
                activeColor: const Color(0xFF7c3aed),
                checkColor: Colors.white,
              ),
            ],
          ),
          onTap: () => _toggleUser(user.id),
        );
      },
    );
  }

  void _toggleUser(int userId) {
    setState(() {
      if (_selectedIds.contains(userId)) {
        _selectedIds.remove(userId);
      } else {
        _selectedIds.add(userId);
      }
    });
  }
}
