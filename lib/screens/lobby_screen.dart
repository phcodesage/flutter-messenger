import 'package:flutter/material.dart';
import '../models/lobby_user.dart';
import '../services/lobby_service.dart';
import '../services/auth_service.dart';
import '../services/socket_service.dart';
import 'sign_in_page.dart';
import 'chat_screen.dart';

/// Lobby/Chat list screen
class LobbyScreen extends StatefulWidget {
  static const route = '/lobby';
  const LobbyScreen({super.key});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  List<LobbyUser> _lobbyUsers = [];
  List<LobbyUser> _filteredUsers = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();
  final SocketService _socketService = SocketService();

  // Avatar colors palette
  static const List<Color> avatarColors = [
    Color(0xFFE91E63), // Pink
    Color(0xFF9C27B0), // Purple
    Color(0xFF673AB7), // Deep Purple
    Color(0xFF3F51B5), // Indigo
    Color(0xFF2196F3), // Blue
    Color(0xFF00BCD4), // Cyan
    Color(0xFF009688), // Teal
    Color(0xFF4CAF50), // Green
    Color(0xFFFF9800), // Orange
    Color(0xFFFF5722), // Deep Orange
  ];

  @override
  void initState() {
    super.initState();
    _loadLobby();
    _searchController.addListener(_filterUsers);
    _setupRealtimeListeners();
  }

  void _setupRealtimeListeners() {
    // Listen for doorbell rings
    _socketService.onDoorbellRing = (data) {
      _handleDoorbellRing(data);
    };

    // Listen for new messages
    _socketService.onMessageReceived = (data) {
      _handleNewMessage(data);
    };

    // Listen for presence updates
    _socketService.onPresenceUpdate = (data) {
      _updateUserPresence(data);
    };
  }

  void _handleDoorbellRing(Map<String, dynamic> data) {
    final senderId = data['sender_id'] as int;
    final senderName = data['sender_name'] as String;
    
    // Only show dialog if we're still on the lobby screen (not in a chat)
    if (!mounted) return;
    
    // Find the user in the lobby
    final user = _lobbyUsers.firstWhere(
      (u) => u.id == senderId,
      orElse: () => _lobbyUsers.first, // fallback
    );

    // Show doorbell notification only in lobby
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2D2D2D),
        title: Row(
          children: [
            const Icon(Icons.notifications_active, color: Color(0xFFFFA726)),
            const SizedBox(width: 8),
            const Text('Doorbell Ring', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Text(
          '$senderName is calling you!',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Dismiss'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              // Clear doorbell listener before navigating to chat
              _socketService.onDoorbellRing = null;
              // Navigate to chat with this user
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ChatScreen(otherUser: user),
                ),
              ).then((_) {
                // Reload lobby and restore doorbell listener
                _loadLobby();
                _setupRealtimeListeners();
              });
            },
            child: const Text('Answer'),
          ),
        ],
      ),
    );
  }

  void _handleNewMessage(Map<String, dynamic> data) {
    final senderId = data['sender_id'] as int;
    
    // Update unread count for sender
    setState(() {
      final userIndex = _lobbyUsers.indexWhere((u) => u.id == senderId);
      if (userIndex != -1) {
        // Create updated user with incremented unread count
        final user = _lobbyUsers[userIndex];
        final updatedUser = LobbyUser(
          id: user.id,
          username: user.username,
          email: user.email,
          firstName: user.firstName,
          lastName: user.lastName,
          fullName: user.fullName,
          avatarUrl: user.avatarUrl,
          bio: user.bio,
          status: user.status,
          statusMessage: user.statusMessage,
          lastSeen: user.lastSeen,
          isOnline: user.isOnline,
          isAdmin: user.isAdmin,
          timezone: user.timezone,
          unreadCount: user.unreadCount + 1,
          isContact: user.isContact,
          isAdminUser: user.isAdminUser,
        );
        
        _lobbyUsers[userIndex] = updatedUser;
        
        // Move to top of list
        _lobbyUsers.removeAt(userIndex);
        _lobbyUsers.insert(0, updatedUser);
        
        // Update filtered list
        _filterUsers();
      }
    });
  }

  void _updateUserPresence(Map<String, dynamic> data) {
    final userId = data['user_id'] as int;
    final status = data['status'] as String;
    final isOnline = data['is_online'] as bool;
    
    setState(() {
      final userIndex = _lobbyUsers.indexWhere((u) => u.id == userId);
      if (userIndex != -1) {
        final user = _lobbyUsers[userIndex];
        final updatedUser = LobbyUser(
          id: user.id,
          username: user.username,
          email: user.email,
          firstName: user.firstName,
          lastName: user.lastName,
          fullName: user.fullName,
          avatarUrl: user.avatarUrl,
          bio: user.bio,
          status: status,
          statusMessage: user.statusMessage,
          lastSeen: user.lastSeen,
          isOnline: isOnline,
          isAdmin: user.isAdmin,
          timezone: user.timezone,
          unreadCount: user.unreadCount,
          isContact: user.isContact,
          isAdminUser: user.isAdminUser,
        );
        
        _lobbyUsers[userIndex] = updatedUser;
        _filterUsers();
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    // Clear socket callbacks to prevent memory leaks
    _socketService.onDoorbellRing = null;
    _socketService.onMessageReceived = null;
    _socketService.onPresenceUpdate = null;
    super.dispose();
  }

  Future<void> _loadLobby() async {
    setState(() => _isLoading = true);
    try {
      final users = await LobbyService.getLobbyUsers();
      setState(() {
        _lobbyUsers = users;
        _filteredUsers = users;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading lobby: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _filterUsers() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredUsers = _lobbyUsers;
      } else {
        _filteredUsers = _lobbyUsers.where((user) {
          return user.fullName.toLowerCase().contains(query) ||
              user.username.toLowerCase().contains(query);
        }).toList();
      }
    });
  }

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2D2D2D),
        title: const Text('Logout', style: TextStyle(color: Colors.white)),
        content: const Text('Are you sure you want to logout?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Logout', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      await AuthService.logout();
      if (mounted) {
        Navigator.pushReplacementNamed(context, SignInPage.route);
      }
    }
  }

  Color _getAvatarColor(int index) {
    return avatarColors[index % avatarColors.length];
  }

  String _formatTime(String? lastSeen) {
    if (lastSeen == null) return '';
    try {
      final dateTime = DateTime.parse(lastSeen);
      final now = DateTime.now();
      final difference = now.difference(dateTime);

      if (difference.inMinutes < 1) return 'Just now';
      if (difference.inHours < 1) return '${difference.inMinutes}m ago';
      if (difference.inDays < 1) {
        final hour = dateTime.hour;
        final minute = dateTime.minute.toString().padLeft(2, '0');
        final period = hour >= 12 ? 'PM' : 'AM';
        final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
        return '$displayHour:$minute $period';
      }
      if (difference.inDays < 7) return '${difference.inDays}d ago';
      return '${dateTime.month}/${dateTime.day}';
    } catch (e) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        title: const Text(
          'Chats',
          style: TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _loadLobby,
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white),
            onPressed: _handleLogout,
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search conversations...',
                hintStyle: TextStyle(color: Colors.grey[600]),
                prefixIcon: Icon(Icons.search, color: Colors.grey[600]),
                filled: true,
                fillColor: const Color(0xFF2D2D2D),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),
          // User list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredUsers.isEmpty
                    ? Center(
                        child: Text(
                          _searchController.text.isEmpty
                              ? 'No conversations yet'
                              : 'No results found',
                          style: TextStyle(color: Colors.grey[600], fontSize: 16),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _filteredUsers.length,
                        itemBuilder: (context, index) {
                          final user = _filteredUsers[index];
                          return _buildUserTile(user);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserTile(LobbyUser user) {
    final avatarColor = _getAvatarColor(user.avatarColorIndex);
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF2D2D2D),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Stack(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: avatarColor,
              child: user.avatarUrl != null
                  ? ClipOval(
                      child: Image.network(
                        user.avatarUrl!,
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return Text(
                            user.initials,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          );
                        },
                      ),
                    )
                  : Text(
                      user.initials,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
            // Online indicator
            if (user.isOnline)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF2D2D2D),
                      width: 2,
                    ),
                  ),
                ),
              ),
            // Offline/away indicator
            if (!user.isOnline && user.status == 'away')
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFA726),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF2D2D2D),
                      width: 2,
                    ),
                  ),
                ),
              ),
          ],
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                user.fullName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (user.isAdminUser)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF2196F3),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'ADMIN',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            user.statusMessage ?? (user.isOnline ? 'Online' : 'Offline'),
            style: TextStyle(
              color: user.isOnline ? const Color(0xFF4CAF50) : Colors.grey[600],
              fontSize: 14,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (user.lastSeen != null)
              Text(
                _formatTime(user.lastSeen),
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
              ),
            if (user.unreadCount > 0)
              Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: Color(0xFFE91E63),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  user.unreadCount > 99 ? '99+' : '${user.unreadCount}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        onTap: () {
          // Navigate to chat screen
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ChatScreen(otherUser: user),
            ),
          ).then((_) {
            // Reload lobby when returning from chat to update unread counts
            _loadLobby();
          });
        },
      ),
    );
  }
}
