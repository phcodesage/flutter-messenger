import 'package:flutter/material.dart';
import 'dart:async';
import 'package:shimmer/shimmer.dart';
import '../models/group.dart';
import '../services/group_service.dart';
import '../services/socket_service.dart';
import '../services/storage_service.dart';
import 'group_chat_screen.dart';
import 'create_group_screen.dart';

/// Groups list screen - WhatsApp-like group chat list
class GroupsListScreen extends StatefulWidget {
  const GroupsListScreen({super.key});

  @override
  State<GroupsListScreen> createState() => _GroupsListScreenState();
}

class _GroupsListScreenState extends State<GroupsListScreen> {
  final SocketService _socketService = SocketService();
  final TextEditingController _searchController = TextEditingController();

  List<Group> _groups = [];
  List<Group> _filteredGroups = [];
  bool _isLoading = true;
  bool _isCurrentUserAdmin = false;
  int? _currentUserId;

  @override
  void initState() {
    super.initState();
    _initialize();
    _searchController.addListener(_filterGroups);
  }

  Future<void> _initialize() async {
    _currentUserId = await StorageService.getUserId();
    _isCurrentUserAdmin = await StorageService.getIsAdmin();
    await _loadGroups();
    _setupRealtimeListeners();
  }

  void _setupRealtimeListeners() {
    const key = 'groups_list';

    // New message in any group
    _socketService.addListener('groupNewMessage', key, (data) {
      _updateGroupLastMessage(data);
    });

    // Group created - add new group to list
    _socketService.addListener('groupCreated', key, (data) {
      debugPrint('🎉 New group created: $data');
      if (data is Map<String, dynamic>) {
        try {
          final newGroup = Group.fromJson(data);
          if (mounted) {
            setState(() {
              _groups.insert(0, newGroup);
              _filterGroups();
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('New group: ${newGroup.name}'),
                backgroundColor: Colors.green,
              ),
            );
          }
        } catch (e) {
          debugPrint('❌ Error parsing group_created: $e');
        }
      }
    });

    // Group member added - add group if current user was added
    _socketService.addListener('groupMemberAdded', key, (data) {
      debugPrint('👥 Member added to group: $data');
      if (data is Map<String, dynamic>) {
        final groupData = data['group'] as Map<String, dynamic>?;
        final addedUserIds = List<int>.from(data['added_user_ids'] ?? []);

        if (groupData != null && mounted) {
          // Check if current user was added
          if (addedUserIds.contains(_currentUserId)) {
            try {
              final newGroup = Group.fromJson(groupData);
              setState(() {
                // Check if group already exists
                final existingIndex = _groups.indexWhere(
                  (g) => g.id == newGroup.id,
                );
                if (existingIndex == -1) {
                  _groups.insert(0, newGroup);
                } else {
                  _groups[existingIndex] = newGroup;
                }
                _filterGroups();
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Added to group: ${newGroup.name}'),
                  backgroundColor: Colors.green,
                ),
              );
            } catch (e) {
              debugPrint('❌ Error parsing group_member_added: $e');
            }
          } else {
            // Update existing group member count
            try {
              final updatedGroup = Group.fromJson(groupData);
              final index = _groups.indexWhere((g) => g.id == updatedGroup.id);
              if (index != -1) {
                setState(() {
                  _groups[index] = updatedGroup;
                  _filterGroups();
                });
              }
            } catch (e) {
              debugPrint('❌ Error updating group after member added: $e');
            }
          }
        }
      }
    });

    // Group deleted - remove from list
    _socketService.addListener('groupDeleted', key, (data) {
      debugPrint('🗑️ Group deleted: $data');
      if (data is Map<String, dynamic>) {
        final groupId = data['group_id'] as int?;
        if (groupId != null && mounted) {
          setState(() {
            _groups.removeWhere((g) => g.id == groupId);
            _filterGroups();
          });
        }
      }
    });

    // Member left group
    _socketService.addListener('groupMemberLeft', key, (data) {
      debugPrint('👋 [GROUPS LIST] Group member left event received: $data');

      int? groupId;
      bool currentUserRemoved = false;

      // Handle different event data structures
      if (data.containsKey('group_id') && data.containsKey('user_id')) {
        // Structure: {group_id: 6, user_id: 16} - from group_member_left
        groupId = data['group_id'] as int?;
        final userId = data['user_id'] as int?;
        currentUserRemoved = (userId == _currentUserId);
        debugPrint('👋 [GROUPS LIST] Using group_member_left structure');
      } else if (data.containsKey('group')) {
        // Structure: {group: {...}} - from group_member_removed
        final groupData = data['group'] as Map<String, dynamic>?;
        if (groupData != null) {
          groupId = groupData['id'] as int?;
          // Check if current user is still in the members list
          final members = groupData['members'] as List?;
          if (members != null) {
            final isCurrentUserInGroup = members.any((member) {
              final memberData = member as Map<String, dynamic>;
              final memberUserId = memberData['user_id'] as int?;
              return memberUserId == _currentUserId;
            });
            currentUserRemoved = !isCurrentUserInGroup;
          }
        }
        debugPrint('👋 [GROUPS LIST] Using group_member_removed structure');
      }

      debugPrint(
        '👋 [GROUPS LIST] Parsed groupId: $groupId, currentUserRemoved: $currentUserRemoved',
      );

      if (groupId != null && currentUserRemoved) {
        debugPrint(
          '👋 [GROUPS LIST] Current user was removed from group $groupId',
        );
        // Current user was removed or left - remove from list
        final voluntaryLeave =
            data.containsKey('user_id') && !data.containsKey('group');
        setState(() {
          final initialCount = _groups.length;
          _groups.removeWhere((g) => g.id == groupId);
          final finalCount = _groups.length;
          debugPrint(
            '👋 [GROUPS LIST] Groups count: $initialCount → $finalCount',
          );
          _filterGroups();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              voluntaryLeave
                  ? 'You left the group'
                  : 'You were removed from a group',
            ),
            backgroundColor: voluntaryLeave ? Colors.green : Colors.orange,
          ),
        );
      } else if (groupId != null) {
        debugPrint('👋 [GROUPS LIST] Another member left, reloading groups');
        // Another member left, update member count
        _loadGroups(); // Reload to get updated member count
      }
    });
  }

  Future<void> _loadGroups() async {
    setState(() => _isLoading = true);

    try {
      final groups = await GroupService.getGroups();

      if (mounted) {
        setState(() {
          _groups = groups;
          _filteredGroups = groups;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading groups: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load groups: $e')));
      }
    }
  }

  void _updateGroupLastMessage(Map<String, dynamic> data) {
    final groupId = data['group_id'] as int?;
    if (groupId == null) return;

    setState(() {
      final index = _groups.indexWhere((g) => g.id == groupId);
      if (index != -1) {
        // Update last message
        final message = GroupMessage.fromJson(data);
        _groups[index] = Group(
          id: _groups[index].id,
          name: _groups[index].name,
          description: _groups[index].description,
          createdBy: _groups[index].createdBy,
          avatarUrl: _groups[index].avatarUrl,
          memberCount: _groups[index].memberCount,
          isActive: _groups[index].isActive,
          createdAt: _groups[index].createdAt,
          myRole: _groups[index].myRole,
          isMuted: _groups[index].isMuted,
          lastMessage: message,
        );

        // Move to top
        final group = _groups.removeAt(index);
        _groups.insert(0, group);
        _filterGroups();
      }
    });
  }

  void _filterGroups() {
    final query = _searchController.text.toLowerCase();

    setState(() {
      if (query.isEmpty) {
        _filteredGroups = _groups;
      } else {
        _filteredGroups = _groups.where((group) {
          return group.name.toLowerCase().contains(query) ||
              (group.description?.toLowerCase().contains(query) ?? false);
        }).toList();
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _socketService.removeListener('groupNewMessage', 'groups_list');
    _socketService.removeListener('groupMemberLeft', 'groups_list');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Groups', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadGroups,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Container(
            padding: const EdgeInsets.all(16),
            color: const Color(0xFF1E293B),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search groups...',
                hintStyle: TextStyle(color: Colors.grey[400]),
                prefixIcon: Icon(Icons.search, color: Colors.grey[400]),
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
          ),

          // Groups list
          Expanded(
            child: _isLoading
                ? _buildLoadingShimmer()
                : _filteredGroups.isEmpty
                ? _buildEmptyState()
                : _buildGroupsList(),
          ),
        ],
      ),
      floatingActionButton: _isCurrentUserAdmin
          ? FloatingActionButton(
              onPressed: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const CreateGroupScreen(),
                  ),
                );

                if (result == true) {
                  _loadGroups();
                }
              },
              backgroundColor: const Color(0xFF8B5CF6),
              child: const Icon(Icons.add, color: Colors.white),
            )
          : null,
    );
  }

  Widget _buildLoadingShimmer() {
    return ListView.builder(
      itemCount: 8,
      itemBuilder: (context, index) {
        return Shimmer.fromColors(
          baseColor: const Color(0xFF1E293B),
          highlightColor: const Color(0xFF334155),
          child: ListTile(
            leading: const CircleAvatar(radius: 28),
            title: Container(
              height: 16,
              width: double.infinity,
              color: Colors.white,
            ),
            subtitle: Container(
              height: 12,
              width: double.infinity,
              color: Colors.white,
              margin: const EdgeInsets.only(top: 8),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.group_outlined, size: 80, color: Colors.grey[600]),
          const SizedBox(height: 16),
          Text(
            _searchController.text.isEmpty
                ? 'No groups yet'
                : 'No groups found',
            style: TextStyle(color: Colors.grey[400], fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            _searchController.text.isEmpty
                ? 'Create a group to get started'
                : 'Try a different search',
            style: TextStyle(color: Colors.grey[600], fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupsList() {
    return ListView.builder(
      itemCount: _filteredGroups.length,
      itemBuilder: (context, index) {
        final group = _filteredGroups[index];
        return _buildGroupTile(group);
      },
    );
  }

  Widget _buildGroupTile(Group group) {
    final lastMessage = group.lastMessage;
    final hasUnread = false; // TODO: Implement unread count

    return ListTile(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => GroupChatScreen(group: group),
          ),
        );
        // Refresh to update last message
        _loadGroups();
      },
      leading: CircleAvatar(
        radius: 28,
        backgroundColor: const Color(0xFF8B5CF6),
        backgroundImage: group.avatarUrl != null
            ? NetworkImage(group.avatarUrl!)
            : null,
        child: group.avatarUrl == null
            ? Text(
                _getGroupInitials(group.name),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              )
            : null,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              group.name,
              style: TextStyle(
                color: Colors.white,
                fontWeight: hasUnread ? FontWeight.bold : FontWeight.normal,
                fontSize: 16,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (lastMessage != null)
            Text(
              lastMessage.formattedTime,
              style: TextStyle(
                color: hasUnread ? const Color(0xFF8B5CF6) : Colors.grey[500],
                fontSize: 12,
              ),
            ),
        ],
      ),
      subtitle: Row(
        children: [
          if (group.isMuted)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.volume_off, size: 14, color: Colors.grey[500]),
            ),
          Expanded(
            child: Text(
              _getLastMessagePreview(lastMessage, group),
              style: TextStyle(
                color: hasUnread ? Colors.white : Colors.grey[400],
                fontWeight: hasUnread ? FontWeight.w500 : FontWeight.normal,
                fontSize: 14,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (hasUnread)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF8B5CF6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                '1', // TODO: Show actual unread count
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    );
  }

  String _getGroupInitials(String name) {
    final words = name.trim().split(' ');
    if (words.length >= 2) {
      return '${words[0][0]}${words[1][0]}'.toUpperCase();
    } else if (words.isNotEmpty && words[0].isNotEmpty) {
      return words[0][0].toUpperCase();
    }
    return 'G';
  }

  String _getLastMessagePreview(GroupMessage? message, Group group) {
    if (message == null) {
      return 'No messages yet';
    }

    if (message.isDeleted) {
      return 'Message deleted';
    }

    if (message.messageType == 'system') {
      String content = message.content;
      final isSentByMe = message.senderId == _currentUserId || group.createdBy == _currentUserId;
      if (isSentByMe && (content.contains('created the group') || content.contains('created this group') || content == 'You created this group')) {
        return 'You created this group';
      }
      return content;
    }

    final senderName = message.sender?.firstName ?? 'Someone';
    final isSentByMe = message.senderId == _currentUserId;
    final prefix = isSentByMe ? 'You: ' : '$senderName: ';

    switch (message.messageType) {
      case 'image':
        return '$prefix📷 Photo';
      case 'video':
        return '$prefix🎥 Video';
      case 'voice':
        return '$prefix🎤 Voice message';
      case 'file':
        return '$prefix📎 ${message.fileName ?? 'File'}';
      case 'doorbell':
        return '$prefix🔔 Notification';
      default:
        return '$prefix${message.content}';
    }
  }
}
