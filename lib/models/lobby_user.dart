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
    };
  }

  /// Get initials for avatar (first letter of first and last name)
  String get initials {
    final first = firstName.isNotEmpty ? firstName[0].toUpperCase() : '';
    final last = lastName.isNotEmpty ? lastName[0].toUpperCase() : '';
    return first + last;
  }

  /// Get a color for the avatar based on username
  int get avatarColorIndex {
    return username.hashCode.abs() % 10;
  }
}
