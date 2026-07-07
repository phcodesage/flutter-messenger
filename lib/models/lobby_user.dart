/// Lobby user model for the contact/chat list
class LobbyUser {
  final int id;
  final String username;
  final String email;
  final String firstName;
  final String lastName;
  final String fullName;
  final String? avatarUrl;
  final String? bio;
  final String status;
  final String? statusMessage;
  final String? lastSeen;
  final bool isOnline;
  final bool isAdmin;
  final String timezone;
  final int unreadCount;
  final bool isContact;
  final bool isAdminUser;
  final String? lastMessage;
  final String? lastMessageTime;
  final bool? lastMessageIsFromMe;
  /// Delivery status of the last message when it's from me: sent/delivered/seen.
  final String? lastMessageStatus;

  LobbyUser({
    required this.id,
    required this.username,
    required this.email,
    required this.firstName,
    required this.lastName,
    required this.fullName,
    this.avatarUrl,
    this.bio,
    required this.status,
    this.statusMessage,
    this.lastSeen,
    required this.isOnline,
    required this.isAdmin,
    required this.timezone,
    this.unreadCount = 0,
    this.isContact = false,
    this.isAdminUser = false,
    this.lastMessage,
    this.lastMessageTime,
    this.lastMessageIsFromMe,
    this.lastMessageStatus,
  });

  factory LobbyUser.fromJson(Map<String, dynamic> json) {
    return LobbyUser(
      id: json['id'] as int,
      username: json['username'] as String,
      email: json['email'] as String,
      firstName: json['first_name'] as String,
      lastName: json['last_name'] as String? ?? '',
      fullName: json['full_name'] as String,
      avatarUrl: json['avatar_url'] as String?,
      bio: json['bio'] as String?,
      status: json['status'] as String,
      statusMessage: json['status_message'] as String?,
      lastSeen: json['last_seen'] as String?,
      isOnline: json['is_online'] as bool,
      isAdmin: json['is_admin'] as bool,
      timezone: json['timezone'] as String,
      unreadCount: json['unread_count'] as int? ?? 0,
      isContact: json['is_contact'] as bool? ?? false,
      isAdminUser: json['is_admin_user'] as bool? ?? false,
      lastMessage: json['last_message'] as String?,
      lastMessageTime: json['last_message_time'] as String?,
      lastMessageIsFromMe: json['last_message_is_from_me'] as bool?,
      lastMessageStatus: json['last_message_status'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'email': email,
      'first_name': firstName,
      'last_name': lastName,
      'full_name': fullName,
      'avatar_url': avatarUrl,
      'bio': bio,
      'status': status,
      'status_message': statusMessage,
      'last_seen': lastSeen,
      'is_online': isOnline,
      'is_admin': isAdmin,
      'timezone': timezone,
      'unread_count': unreadCount,
      'is_contact': isContact,
      'is_admin_user': isAdminUser,
      'last_message': lastMessage,
      'last_message_time': lastMessageTime,
      'last_message_is_from_me': lastMessageIsFromMe,
      'last_message_status': lastMessageStatus,
    };
  }

  /// Returns a copy with the given fields replaced. Used by the lobby to update
  /// a contact's preview / unread / presence without rebuilding every field.
  LobbyUser copyWith({
    int? id,
    String? username,
    String? email,
    String? firstName,
    String? lastName,
    String? fullName,
    String? avatarUrl,
    String? bio,
    String? status,
    String? statusMessage,
    String? lastSeen,
    bool? isOnline,
    bool? isAdmin,
    String? timezone,
    int? unreadCount,
    bool? isContact,
    bool? isAdminUser,
    String? lastMessage,
    String? lastMessageTime,
    bool? lastMessageIsFromMe,
    String? lastMessageStatus,
  }) {
    return LobbyUser(
      id: id ?? this.id,
      username: username ?? this.username,
      email: email ?? this.email,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      fullName: fullName ?? this.fullName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      bio: bio ?? this.bio,
      status: status ?? this.status,
      statusMessage: statusMessage ?? this.statusMessage,
      lastSeen: lastSeen ?? this.lastSeen,
      isOnline: isOnline ?? this.isOnline,
      isAdmin: isAdmin ?? this.isAdmin,
      timezone: timezone ?? this.timezone,
      unreadCount: unreadCount ?? this.unreadCount,
      isContact: isContact ?? this.isContact,
      isAdminUser: isAdminUser ?? this.isAdminUser,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      lastMessageIsFromMe: lastMessageIsFromMe ?? this.lastMessageIsFromMe,
      lastMessageStatus: lastMessageStatus ?? this.lastMessageStatus,
    );
  }

  /// Get initials for avatar (first letter of first and last name)
  String get initials {
    final first = firstName.isNotEmpty ? firstName[0].toUpperCase() : '';
    final last = lastName.isNotEmpty ? lastName[0].toUpperCase() : '';
    return first + last;
  }

  /// Get a color for the avatar based on user id.
  /// Matches the web app (generate_avatar_url: colors[user.id % len]) so the
  /// same person gets the same avatar background color on both platforms.
  int get avatarColorIndex {
    return id % 10;
  }
}
