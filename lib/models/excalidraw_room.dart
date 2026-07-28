/// A whiteboard in the self-hosted Excalidraw directory.
///
/// Distinct from a pinned Excalidraw *link* (a message someone pinned): these
/// are boards created on our own instance and scoped to one conversation, the
/// same way that conversation's task list is.
class ExcalidrawRoom {
  const ExcalidrawRoom({
    required this.id,
    required this.roomId,
    required this.roomKey,
    required this.title,
    this.conversationKey,
    this.createdByUserId,
    this.createdByUsername,
    this.createdAt,
    this.updatedAt,
    this.clients = 0,
    this.live = false,
  });

  /// Directory row id — what the rename/delete endpoints take.
  final int id;

  /// Collaboration room id (20 hex chars), used in the board URL.
  final String roomId;

  /// AES key for the room, 22 url-safe base64 chars. Only ever placed in the
  /// URL fragment, never sent to the server as a query parameter.
  final String roomKey;

  final String title;
  final String? conversationKey;
  final int? createdByUserId;
  final String? createdByUsername;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// How many clients currently have the board open. Sending a photo or note
  /// into a board only works while somebody has it open, so the UI shows this.
  final int clients;
  final bool live;

  static DateTime? _parseDate(dynamic value) {
    if (value is! String || value.isEmpty) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return null;
    // The server sends naive UTC (`datetime.utcnow`), which DateTime would
    // otherwise read as local time — an hours-wide error when comparing
    // against the "last seen" marker.
    return parsed.isUtc ? parsed : DateTime.utc(
      parsed.year, parsed.month, parsed.day,
      parsed.hour, parsed.minute, parsed.second, parsed.millisecond,
      parsed.microsecond,
    );
  }

  factory ExcalidrawRoom.fromJson(Map<String, dynamic> json) {
    return ExcalidrawRoom(
      id: (json['id'] as num?)?.toInt() ?? 0,
      roomId: json['room_id'] as String? ?? '',
      roomKey: json['room_key'] as String? ?? '',
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? json['title'] as String
          : 'Untitled board',
      conversationKey: json['conversation_key'] as String?,
      createdByUserId: (json['created_by_user_id'] as num?)?.toInt(),
      createdByUsername: json['created_by_username'] as String?,
      createdAt: _parseDate(json['created_at']),
      updatedAt: _parseDate(json['updated_at']),
      clients: (json['clients'] as num?)?.toInt() ?? 0,
      live: json['live'] as bool? ?? false,
    );
  }

  /// Timestamp used for "is this new to me?" comparisons.
  DateTime? get changedAt => updatedAt ?? createdAt;

  ExcalidrawRoom copyWith({String? title}) => ExcalidrawRoom(
    id: id,
    roomId: roomId,
    roomKey: roomKey,
    title: title ?? this.title,
    conversationKey: conversationKey,
    createdByUserId: createdByUserId,
    createdByUsername: createdByUsername,
    createdAt: createdAt,
    updatedAt: updatedAt,
    clients: clients,
    live: live,
  );
}
