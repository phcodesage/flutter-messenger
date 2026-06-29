import 'package:flutter/material.dart';

import '../../models/group.dart';
import '../../models/lobby_user.dart';
import '../../widgets/cached_image.dart';

class ChatHeader extends StatelessWidget implements PreferredSizeWidget {
  const ChatHeader({
    super.key,
    this.otherUser,
    required this.headerColor,
    this.isSelfChat = false,
    this.callInProgressOnOtherDevice = false,
    this.partnerStatus = 'offline',
    this.partnerLastSeen,
    this.taskCount = 0,
    this.excalidrawCount = 0,
    required this.scale,
    this.onBack,
    this.onUserProfile,
    this.onShowTasks,
    this.onShowExcalidraw,
    this.onCallAudio,
    this.onCallVideo,
    // Group mode: when [groupName] is non-null the header renders a group
    // title (avatar + member count) and group actions (call/doorbell/menu)
    // instead of the 1:1 user title. 1:1 chat passes none of these, so its
    // layout is unchanged.
    this.groupId,
    this.groupName,
    this.groupAvatarUrl,
    this.memberCount,
    this.onRingDoorbell,
    this.onShowMembers,
    this.onShowSettings,
  });

  final LobbyUser? otherUser;
  final Color headerColor;
  final bool isSelfChat;
  final bool callInProgressOnOtherDevice;

  /// Effective status: 'online' | 'away' | 'offline'
  final String partnerStatus;
  final String? partnerLastSeen;
  final int taskCount;
  final int excalidrawCount;
  final double scale;
  final VoidCallback? onBack;
  final VoidCallback? onUserProfile;
  final VoidCallback? onShowTasks;
  final VoidCallback? onShowExcalidraw;
  final VoidCallback? onCallAudio;
  final VoidCallback? onCallVideo;

  // --- Group mode ---
  final int? groupId;
  final String? groupName;
  final String? groupAvatarUrl;
  final int? memberCount;
  final VoidCallback? onRingDoorbell;
  final VoidCallback? onShowMembers;
  final VoidCallback? onShowSettings;

  bool get _isGroup => groupName != null;

  // Same palette used in the contacts/lobby list so the chat header avatar
  // matches the contact tile exactly.
  static const List<Color> _avatarColors = [
    Color(0xFF1F77B4),
    Color(0xFFFF7F0E),
    Color(0xFF2CA02C),
    Color(0xFFD62728),
    Color(0xFF9467BD),
    Color(0xFF8C564B),
    Color(0xFFE377C2),
    Color(0xFF7F7F7F),
    Color(0xFFBCBD22),
    Color(0xFF17BECF),
  ];

  // Compact header height — trimmed from the default kToolbarHeight (56) to
  // claw back vertical space for the message list.
  static const double _compactToolbarHeight = 48;

  @override
  Size get preferredSize => Size.fromHeight(_compactToolbarHeight * scale);

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    // Under 390 logical pixels wide is considered compact (high DPI / small screens)
    final bool isCompact = screenWidth < 390;
    // We adjust scale slightly on compact screens to make titles/icons fit better
    final double s = isCompact ? scale * 0.88 : scale;

    return AppBar(
      backgroundColor: headerColor,
      toolbarHeight: _compactToolbarHeight * s,
      elevation: 0,
      automaticallyImplyLeading: false,
      leading: onBack == null
          ? null
          : IconButton(
              icon: Icon(Icons.arrow_back, color: Colors.white, size: 24 * s),
              onPressed: onBack,
            ),
      titleSpacing: onBack == null ? 12 : 0,
      title: _isGroup ? _buildGroupTitle(s) : _buildUserTitle(s),
      actions: _isGroup ? _buildGroupActions(context, isCompact, s) : _buildUserActions(context, isCompact, s),
    );
  }

  // === 1:1 title / actions ===

  Widget _buildUserTitle(double s) {
    return GestureDetector(
      onTap: onUserProfile,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildAvatarWithStatus(s),
          SizedBox(width: 10 * s),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isSelfChat
                      ? '${otherUser!.fullName} (You)'
                      : otherUser!.fullName.split(' ').first,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15 * s,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (!isSelfChat) _buildHeaderStatusPill(s),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildUserActions(BuildContext context, bool isCompact, double s) {
    final List<Widget> actions = [];

    if (!isSelfChat && callInProgressOnOtherDevice) {
      actions.add(
        Padding(
          padding: EdgeInsets.only(right: 6 * s),
          child: Center(
            child: Container(
              constraints: BoxConstraints(maxWidth: 140 * s),
              padding: EdgeInsets.symmetric(
                horizontal: 8 * s,
                vertical: 4 * s,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.45),
                ),
              ),
              child: Text(
                'Call on other device',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: const Color(0xFFF59E0B),
                  fontSize: 10 * s,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    } else if (!isSelfChat) {
      actions.addAll([
        IconButton(
          icon: Icon(Icons.videocam, color: Colors.white, size: 22 * s),
          onPressed: onCallVideo,
          tooltip: 'Video Call',
        ),
        IconButton(
          icon: Icon(Icons.call, color: Colors.white, size: 22 * s),
          onPressed: onCallAudio,
          tooltip: 'Audio Call',
        ),
      ]);
    }

    if (isCompact) {
      // Collapse Tasks and Excalidraw into a PopupMenu
      actions.add(
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: Colors.white, size: 22 * s),
          color: const Color(0xFF1E1E2E),
          onSelected: (value) {
            if (value == 'tasks') {
              onShowTasks?.call();
            } else if (value == 'excalidraw') {
              onShowExcalidraw?.call();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'tasks',
              child: _buildPopupMenuItemChild(
                icon: Icons.task_alt,
                label: 'Tasks',
                color: const Color(0xFF14B8A6),
                count: taskCount,
                scale: s,
              ),
            ),
            PopupMenuItem(
              value: 'excalidraw',
              child: _buildPopupMenuItemChild(
                icon: Icons.draw_outlined,
                label: 'Excalidraw',
                color: const Color(0xFFF97316),
                count: excalidrawCount,
                scale: s,
              ),
            ),
          ],
        ),
      );
    } else {
      actions.addAll([
        _buildBadgeIcon(
          context,
          icon: Icons.task_alt,
          count: taskCount,
          color: const Color(0xFF14B8A6),
          onPressed: onShowTasks ?? () {},
          tooltip: 'Tasks',
          scale: s,
        ),
        _buildBadgeIcon(
          context,
          icon: Icons.draw_outlined,
          count: excalidrawCount,
          color: const Color(0xFFF97316),
          onPressed: onShowExcalidraw ?? () {},
          tooltip: 'Excalidraw',
          scale: s,
        ),
      ]);
    }

    return actions;
  }

  // === Group title / actions ===

  Widget _buildGroupTitle(double s) {
    return GestureDetector(
      onTap: onShowMembers,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildGroupAvatar(s),
          SizedBox(width: 10 * s),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  groupName ?? 'Group',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15 * s,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (memberCount != null)
                  Padding(
                    padding: EdgeInsets.only(top: 1 * s),
                    child: Text(
                      '$memberCount members',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 11.5 * s,
                        fontWeight: FontWeight.w500,
                        height: 1.12,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupAvatar(double s) {
    final double radius = 17 * s;
    final double imgDiameter = radius * 2;
    final colors = Group.getGradientColors(groupId ?? 0);
    final fallback = Icon(Icons.people, color: Colors.white, size: 20 * s);
    final url = groupAvatarUrl;
    return Container(
      width: imgDiameter,
      height: imgDiameter,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        shape: BoxShape.circle,
      ),
      child: (url != null && url.isNotEmpty)
          ? ClipOval(
              child: CachedImage(
                url: url,
                width: imgDiameter,
                height: imgDiameter,
                fit: BoxFit.cover,
                placeholderColor: colors.first,
                errorWidget: fallback,
              ),
            )
          : fallback,
    );
  }

  List<Widget> _buildGroupActions(BuildContext context, bool isCompact, double s) {
    final List<Widget> actions = [];

    if (isCompact) {
      if (onCallVideo != null) {
        actions.add(
          IconButton(
            icon: Icon(Icons.videocam, color: Colors.white, size: 22 * s),
            onPressed: onCallVideo,
            tooltip: 'Video Call',
          ),
        );
      }
      if (onCallAudio != null) {
        actions.add(
          IconButton(
            icon: Icon(Icons.call, color: Colors.white, size: 22 * s),
            onPressed: onCallAudio,
            tooltip: 'Audio Call',
          ),
        );
      }

      actions.add(
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: Colors.white, size: 22 * s),
          color: const Color(0xFF1E1E2E),
          onSelected: (value) {
            if (value == 'tasks') {
              onShowTasks?.call();
            } else if (value == 'excalidraw') {
              onShowExcalidraw?.call();
            } else if (value == 'doorbell') {
              onRingDoorbell?.call();
            } else if (value == 'members') {
              onShowMembers?.call();
            } else if (value == 'settings') {
              onShowSettings?.call();
            }
          },
          itemBuilder: (context) => [
            if (onShowTasks != null)
              PopupMenuItem(
                value: 'tasks',
                child: _buildPopupMenuItemChild(
                  icon: Icons.task_alt,
                  label: 'Tasks',
                  color: const Color(0xFF14B8A6),
                  count: taskCount,
                  scale: s,
                ),
              ),
            if (onShowExcalidraw != null)
              PopupMenuItem(
                value: 'excalidraw',
                child: _buildPopupMenuItemChild(
                  icon: Icons.draw_outlined,
                  label: 'Excalidraw',
                  color: const Color(0xFFF97316),
                  count: excalidrawCount,
                  scale: s,
                ),
              ),
            if (onRingDoorbell != null)
              PopupMenuItem(
                value: 'doorbell',
                child: _buildPopupMenuItemChild(
                  icon: Icons.notifications,
                  label: 'Ring Doorbell',
                  color: Colors.white,
                  count: 0,
                  scale: s,
                ),
              ),
            if (onShowMembers != null)
              PopupMenuItem(
                value: 'members',
                child: _buildPopupMenuItemChild(
                  icon: Icons.people,
                  label: 'Members',
                  color: Colors.white,
                  count: 0,
                  scale: s,
                ),
              ),
            if (onShowSettings != null)
              PopupMenuItem(
                value: 'settings',
                child: _buildPopupMenuItemChild(
                  icon: Icons.settings,
                  label: 'Group Settings',
                  color: Colors.white,
                  count: 0,
                  scale: s,
                ),
              ),
          ],
        ),
      );
    } else {
      if (onShowTasks != null) {
        actions.add(
          _buildBadgeIcon(
            context,
            icon: Icons.task_alt,
            count: taskCount,
            color: const Color(0xFF14B8A6),
            onPressed: onShowTasks!,
            tooltip: 'Tasks',
            scale: s,
          ),
        );
      }
      if (onShowExcalidraw != null) {
        actions.add(
          _buildBadgeIcon(
            context,
            icon: Icons.draw_outlined,
            count: excalidrawCount,
            color: const Color(0xFFF97316),
            onPressed: onShowExcalidraw!,
            tooltip: 'Excalidraw',
            scale: s,
          ),
        );
      }
      if (onCallVideo != null) {
        actions.add(
          IconButton(
            icon: Icon(Icons.videocam, color: Colors.white, size: 24 * s),
            onPressed: onCallVideo,
            tooltip: 'Video Call',
          ),
        );
      }
      if (onCallAudio != null) {
        actions.add(
          IconButton(
            icon: Icon(Icons.call, color: Colors.white, size: 24 * s),
            onPressed: onCallAudio,
            tooltip: 'Audio Call',
          ),
        );
      }
      if (onRingDoorbell != null) {
        actions.add(
          IconButton(
            icon: Icon(Icons.notifications, color: Colors.white, size: 24 * s),
            onPressed: onRingDoorbell,
            tooltip: 'Ring Doorbell',
          ),
        );
      }
      if (onShowMembers != null || onShowSettings != null) {
        actions.add(
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: Colors.white, size: 24 * s),
            color: const Color(0xFF1E1E2E),
            onSelected: (value) {
              if (value == 'members') {
                onShowMembers?.call();
              } else if (value == 'settings') {
                onShowSettings?.call();
              }
            },
            itemBuilder: (context) => [
              if (onShowMembers != null)
                const PopupMenuItem(
                  value: 'members',
                  child: Row(
                    children: [
                      Icon(Icons.people, color: Colors.white, size: 20),
                      SizedBox(width: 12),
                      Text('Members', style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              if (onShowSettings != null)
                const PopupMenuItem(
                  value: 'settings',
                  child: Row(
                    children: [
                      Icon(Icons.settings, color: Colors.white, size: 20),
                      SizedBox(width: 12),
                      Text(
                        'Group Settings',
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      }
    }

    return actions;
  }

  /// Avatar styled like the contacts list: colored background from the user's
  /// palette index, network image when present (fallback to initials on
  /// error), with a status dot overlay (green/yellow/grey).
  Widget _buildAvatarWithStatus(double s) {
    final double radius = 17 * s;
    final double dotSize = 11 * s;
    final double initialsSize = 12 * s;
    final double imgDiameter = radius * 2;
    final avatarColor = _avatarColorForUser();

    final Widget initials = Text(
      otherUser!.initials,
      style: TextStyle(
        color: Colors.white,
        fontSize: initialsSize,
        fontWeight: FontWeight.bold,
      ),
    );

    final avatarUrl = otherUser!.avatarUrl;
    final Widget avatarChild = (avatarUrl != null && avatarUrl.isNotEmpty)
        ? ClipOval(
            child: CachedImage(
              url: avatarUrl,
              width: imgDiameter,
              height: imgDiameter,
              fit: BoxFit.cover,
              placeholderColor: avatarColor,
              errorWidget: initials,
            ),
          )
        : initials;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: avatarColor,
          child: avatarChild,
        ),
        if (!isSelfChat)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(
                color: callInProgressOnOtherDevice
                    ? const Color(0xFFF59E0B)
                    : _statusDotColor(partnerStatus),
                shape: BoxShape.circle,
                border: Border.all(color: headerColor, width: 2),
              ),
            ),
          ),
      ],
    );
  }

  Color _avatarColorForUser() {
    return _avatarColors[otherUser!.avatarColorIndex % _avatarColors.length];
  }

  Color _statusDotColor(String status) {
    switch (status) {
      case 'online':
        return const Color(0xFF00E676); // neon green
      case 'away':
        return const Color(0xFFFFC107); // amber
      default:
        return Colors.grey.shade500; // offline
    }
  }

  Widget _buildHeaderStatusPill(double s) {
    final status = partnerStatus;
    final statusFontSize = (11.5 * s).clamp(11.0, 13.0).toDouble();
    final Color color;
    final String label;
    switch (status) {
      case 'online':
        color = const Color(0xFF00E676);
        label = 'Online';
        break;
      case 'away':
        color = const Color(0xFFFFC107);
        label = partnerLastSeen != null ? 'Away · $partnerLastSeen' : 'Away';
        break;
      default:
        color = Colors.grey.shade400;
        label = partnerLastSeen != null
            ? 'Last seen: $partnerLastSeen'
            : 'Offline';
    }

    return Padding(
      padding: EdgeInsets.only(top: 1 * s),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: statusFontSize,
          fontWeight: FontWeight.w500,
          height: 1.12,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildPopupMenuItemChild({
    required IconData icon,
    required String label,
    required Color color,
    required int count,
    required double scale,
  }) {
    return Row(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(icon, color: color, size: 20 * scale),
            if (count > 0)
              Positioned(
                right: -4,
                top: -4,
                child: Container(
                  padding: EdgeInsets.all(1.5 * scale),
                  constraints: BoxConstraints(
                    minWidth: 12 * scale,
                    minHeight: 12 * scale,
                  ),
                  decoration: const BoxDecoration(
                    color: Color(0xFFDC2626),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 8 * scale,
                      fontWeight: FontWeight.w800,
                      height: 1.0,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: Colors.white)),
      ],
    );
  }

  Widget _buildBadgeIcon(
    BuildContext context, {
    required IconData icon,
    required int count,
    required Color color,
    required VoidCallback onPressed,
    required String tooltip,
    required double scale,
  }) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          // Tint the glyph with its accent color so Tasks (teal) / Excalidraw
          // (orange) match the web header buttons.
          icon: Icon(icon, color: color, size: 24 * scale),
          onPressed: onPressed,
          tooltip: tooltip,
        ),
        if (count > 0)
          Positioned(
            right: 4,
            top: 4,
            child: Container(
              padding: EdgeInsets.all(2 * scale),
              constraints: BoxConstraints(
                minWidth: 16 * scale,
                minHeight: 16 * scale,
              ),
              decoration: BoxDecoration(
                // Red count badge to match the web header badges.
                color: const Color(0xFFDC2626),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.black.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 9 * scale,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }
}
