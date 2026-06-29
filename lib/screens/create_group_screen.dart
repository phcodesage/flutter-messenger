import 'package:flutter/material.dart';
import '../models/lobby_user.dart';
import '../services/lobby_service.dart';
import '../services/group_service.dart';
import '../services/storage_service.dart';
import '../services/socket_service.dart';
import '../widgets/cached_image.dart';

/// Create group screen - select members and create group
class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  List<LobbyUser> _allUsers = [];
  List<LobbyUser> _filteredUsers = [];
  final Set<int> _selectedUserIds = {};
  bool _isLoading = true;
  bool _isCreating = false;

  final SocketService _socketService = SocketService();
  final String _socketListenerKey = 'create_group_screen_${DateTime.now().millisecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    _checkAdminAccess();
    _loadUsers();
    _searchController.addListener(_filterUsers);
    
    // Subscribe to real-time presence updates
    _socketService.addListener('presenceUpdate', _socketListenerKey, (data) {
      _handlePresenceUpdate(data);
    });
  }

  Future<void> _checkAdminAccess() async {
    final isAdmin = await StorageService.getIsAdmin();
    if (!isAdmin) {
      // Non-admin users shouldn't be able to access this screen
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Only admin users can create groups'),
            backgroundColor: Colors.red,
          ),
        );
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);

    try {
      final users = await LobbyService.getLobbyUsers();

      if (mounted) {
        setState(() {
          _allUsers = users;
          _filteredUsers = users;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading users: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load users: $e')));
      }
    }
  }

  void _filterUsers() {
    final query = _searchController.text.toLowerCase();

    setState(() {
      if (query.isEmpty) {
        _filteredUsers = _allUsers;
      } else {
        _filteredUsers = _allUsers.where((user) {
          return user.username.toLowerCase().contains(query) ||
              user.fullName.toLowerCase().contains(query);
        }).toList();
      }
    });
  }

  Future<void> _createGroup() async {
    // Double-check admin access before creating
    final isAdmin = await StorageService.getIsAdmin();
    if (!mounted) return;
    if (!isAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only admin users can create groups'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final groupName = _groupNameController.text.trim();

    if (groupName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a group name')),
      );
      return;
    }

    if (_selectedUserIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one member')),
      );
      return;
    }

    setState(() => _isCreating = true);

    try {
      await GroupService.createGroup(
        name: groupName,
        description: _descriptionController.text.trim(),
        memberIds: _selectedUserIds.toList(),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group created successfully')),
      );
      Navigator.pop(context, true);
    } catch (e) {
      debugPrint('Error creating group: $e');
      if (!mounted) return;
      setState(() => _isCreating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create group: $e')),
      );
    }
  }

  @override
  void dispose() {
    _socketService.removeListener('presenceUpdate', _socketListenerKey);
    _groupNameController.dispose();
    _descriptionController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  DateTime _parseUtcTimestamp(String timestamp) {
    final hasTimezone = RegExp(r'[zZ]|[+-]\d{2}:?\d{2}$').hasMatch(timestamp);
    final parsed = DateTime.parse(hasTimezone ? timestamp : '${timestamp}Z');
    return parsed.toLocal();
  }

  String _formatRelativeTime(String? lastSeen) {
    if (lastSeen == null || lastSeen.isEmpty) return 'offline';
    try {
      final dateTime = _parseUtcTimestamp(lastSeen);
      final now = DateTime.now();
      final difference = now.difference(dateTime);

      if (difference.inMinutes < 1) return 'last seen just now';
      if (difference.inMinutes < 60) {
        final mins = difference.inMinutes;
        return 'last seen ${mins}m ago';
      }
      if (difference.inHours < 24) {
        final hours = difference.inHours;
        return 'last seen ${hours}h ago';
      }
      if (difference.inDays == 1) return 'last seen yesterday';
      if (difference.inDays < 7) return 'last seen ${difference.inDays}d ago';
      return 'last seen ${dateTime.month}/${dateTime.day}';
    } catch (e) {
      return 'offline';
    }
  }

  void _handlePresenceUpdate(Map<String, dynamic> data) {
    final userId = data['user_id'] as int?;
    final status = data['status'] as String?;
    if (userId == null || status == null) return;
    
    final isOnline = data['is_online'] as bool? ?? (status == 'online');
    final timestamp = data['timestamp'] as String?;

    if (!mounted) return;
    setState(() {
      final allIndex = _allUsers.indexWhere((u) => u.id == userId);
      if (allIndex != -1) {
        _allUsers[allIndex] = _allUsers[allIndex].copyWith(
          status: status,
          isOnline: isOnline,
          lastSeen: timestamp,
        );
      }
      
      final filteredIndex = _filteredUsers.indexWhere((u) => u.id == userId);
      if (filteredIndex != -1) {
        _filteredUsers[filteredIndex] = _filteredUsers[filteredIndex].copyWith(
          status: status,
          isOnline: isOnline,
          lastSeen: timestamp,
        );
      }
    });
  }

  static const List<Color> _avatarColors = [
    Color(0xFF1F77B4), // Blue
    Color(0xFFFF7F0E), // Orange
    Color(0xFF2CA02C), // Green
    Color(0xFFD62728), // Red
    Color(0xFF9467BD), // Purple
    Color(0xFF8C564B), // Brown
    Color(0xFFE377C2), // Pink
    Color(0xFF7F7F7F), // Gray
    Color(0xFFBCBD22), // Olive
    Color(0xFF17BECF), // Cyan
  ];

  Color _getAvatarColor(int index) {
    return _avatarColors[index % _avatarColors.length];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Create Group',
          style: TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          // Group info section
          Container(
            padding: const EdgeInsets.all(16),
            color: const Color(0xFF1E293B),
            child: Column(
              children: [
                TextField(
                  controller: _groupNameController,
                  cursorColor: Colors.white,
                  showCursor: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Group name',
                    hintStyle: TextStyle(color: Colors.grey[400]),
                    filled: true,
                    fillColor: const Color(0xFF334155),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _descriptionController,
                  cursorColor: Colors.white,
                  showCursor: true,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 2,
                  decoration: InputDecoration(
                    hintText: 'Description (optional)',
                    hintStyle: TextStyle(color: Colors.grey[400]),
                    filled: true,
                    fillColor: const Color(0xFF334155),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Selected members count
          if (_selectedUserIds.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFF1E293B),
              child: Row(
                children: [
                  Text(
                    '${_selectedUserIds.length} member${_selectedUserIds.length == 1 ? '' : 's'} selected',
                    style: TextStyle(color: Colors.grey[400], fontSize: 14),
                  ),
                ],
              ),
            ),

          // Search bar
          Container(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              cursorColor: Colors.white,
              showCursor: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search users...',
                hintStyle: TextStyle(color: Colors.grey[400]),
                prefixIcon: Icon(Icons.search, color: Colors.grey[400]),
                filled: true,
                fillColor: const Color(0xFF1E293B),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
            ),
          ),

          // Users list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredUsers.isEmpty
                ? Center(
                    child: Text(
                      'No users found',
                      style: TextStyle(color: Colors.grey[400]),
                    ),
                  )
                : ListView.builder(
                    itemCount: _filteredUsers.length,
                    itemBuilder: (context, index) {
                      final user = _filteredUsers[index];
                      final isSelected = _selectedUserIds.contains(user.id);

                      return CheckboxListTile(
                        value: isSelected,
                        onChanged: (value) {
                          setState(() {
                            if (value == true) {
                              _selectedUserIds.add(user.id);
                            } else {
                              _selectedUserIds.remove(user.id);
                            }
                          });
                        },
                        title: Text(
                          user.fullName,
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: Row(
                          children: [
                            Text(
                              '@${user.username}',
                              style: TextStyle(color: Colors.grey[400]),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '•',
                              style: TextStyle(color: Colors.grey[500]),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                user.isOnline 
                                    ? 'online' 
                                    : _formatRelativeTime(user.lastSeen),
                                style: TextStyle(
                                  color: user.isOnline ? const Color(0xFF00E676) : Colors.grey[400],
                                  fontSize: 12,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        secondary: SizedBox(
                          width: 44,
                          height: 44,
                          child: Stack(
                            children: [
                              CircleAvatar(
                                backgroundColor: _getAvatarColor(user.avatarColorIndex),
                                radius: 20,
                                child: user.avatarUrl != null && user.avatarUrl!.isNotEmpty
                                    ? ClipOval(
                                        child: CachedImage(
                                          url: user.avatarUrl!,
                                          width: 40,
                                          height: 40,
                                          fit: BoxFit.cover,
                                          placeholderColor: _getAvatarColor(user.avatarColorIndex),
                                          errorWidget: Text(
                                            user.initials,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      )
                                    : Text(
                                        user.initials,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                              ),
                              Positioned(
                                right: 2,
                                bottom: 2,
                                child: Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: user.isOnline
                                        ? const Color(0xFF00E676)
                                        : (user.status == 'away'
                                            ? const Color(0xFFFFC107)
                                            : Colors.grey[600]!),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: const Color(0xFF0F172A),
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        activeColor: const Color(0xFF8B5CF6),
                        checkColor: Colors.white,
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.20),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: SafeArea(
          child: ElevatedButton(
            onPressed: _isCreating ? null : _createGroup,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8B5CF6),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: _isCreating
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Text(
                    'Create Group',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
          ),
        ),
      ),
    );
  }
}
