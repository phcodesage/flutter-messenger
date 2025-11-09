/// User model matching the backend API response
class User {
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

  User({
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
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
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
    };
  }
}
