/// API Configuration
/// Change the baseUrl in .env.json (root of project) and build with:
///   flutter run --dart-define-from-file=.env.json
///   flutter build apk --dart-define-from-file=.env.json
class ApiConfig {
  // Base URL is injected at build time via --dart-define-from-file=.env.json.
  // The default keeps plain `flutter run` (without --dart-define-from-file) working.
  static const String baseUrl = String.fromEnvironment(
    'BASE_URL',
    //defaultValue: 'https://web.flask-call-app.site/',
    defaultValue: 'https://check.flask-meet.site/',
  );

  // API endpoints
  static const String authPrefix = '/api/auth';
  static const String mobilePrefix = '/api/mobile';

  // Auth endpoints
  static const String registerUrl = '$baseUrl$authPrefix/register';
  static const String loginUrl = '$baseUrl$authPrefix/login';
  static const String logoutUrl = '$baseUrl$authPrefix/logout';
  static const String meUrl = '$baseUrl$authPrefix/me';
  static const String forgotPasswordUrl = '$baseUrl$authPrefix/forgot-password';
  static const String resetPasswordUrl = '$baseUrl$authPrefix/reset-password';

  // Mobile endpoints
  static const String lobbyUrl = '$baseUrl$mobilePrefix/lobby';
  static const String usersUrl = '$baseUrl$mobilePrefix/users';
  static const String contactsUrl = '$baseUrl$mobilePrefix/contacts';
  static const String conversationsUrl =
      '$baseUrl$mobilePrefix/messages/conversations';
  static const String sendMessageUrl = '$baseUrl$mobilePrefix/messages/send';
  static const String sendManyMessagesUrl =
      '$baseUrl$mobilePrefix/messages/send-many';
  static const String markReadUrl = '$baseUrl$mobilePrefix/messages/mark-read';
  static const String presenceStatusUrl =
      '$baseUrl$mobilePrefix/presence/status';
  static const String heartbeatUrl = '$baseUrl$mobilePrefix/presence/heartbeat';

  // Timeouts
  static const Duration connectionTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 30);
  static const Duration forgotPasswordTimeout = Duration(seconds: 60);

  // App update endpoints
  static const String appVersionUrl = '$baseUrl$mobilePrefix/app-version';
  static const String appDownloadUrl = '$baseUrl$mobilePrefix/app-download';

  // Task endpoints
  static const String tasksUrl = '$baseUrl$mobilePrefix/tasks';
  static const String chatTasksUrl = '$baseUrl$mobilePrefix/tasks/chat';
  static String getChatTasksForUserUrl(int otherUserId) =>
      '$baseUrl$mobilePrefix/tasks/chat?other_user_id=$otherUserId';
  static String getTaskUrl(int taskId) => '$baseUrl$mobilePrefix/tasks/$taskId';
  static String getTaskCompleteUrl(int taskId) =>
      '$baseUrl$mobilePrefix/tasks/$taskId/complete';

  // Excalidraw endpoints
  static String getExcalidrawConversationUrl(int userId) =>
      '$baseUrl$mobilePrefix/messages/excalidraw/conversation/$userId';
  static String getExcalidrawPinUrl(int messageId) =>
      '$baseUrl$mobilePrefix/messages/excalidraw/pin/$messageId';
  static String getExcalidrawUnpinUrl(int messageId) =>
      '$baseUrl$mobilePrefix/messages/excalidraw/unpin/$messageId';

  // Legacy Excalidraw board endpoints (kept for backward compatibility)
  static const String excalidrawBoardsUrl =
      '$baseUrl$mobilePrefix/excalidraw/boards';
  static String getExcalidrawBoardUrl(String boardId) =>
      '$baseUrl$mobilePrefix/excalidraw/boards/$boardId';

  // Group endpoints
  static const String groupsUrl = '$baseUrl$mobilePrefix/groups';
  static String getGroupUrl(int groupId) =>
      '$baseUrl$mobilePrefix/groups/$groupId';
  static String getGroupMembersUrl(int groupId) =>
      '$baseUrl$mobilePrefix/groups/$groupId/members';
  static String getGroupMemberUrl(int groupId, int userId) =>
      '$baseUrl$mobilePrefix/groups/$groupId/members/$userId';
  static String getGroupLeaveUrl(int groupId) =>
      '$baseUrl$mobilePrefix/groups/$groupId/leave';
  static String getGroupMessagesUrl(int groupId) =>
      '$baseUrl$mobilePrefix/groups/$groupId/messages';
  static String getGroupMessageUrl(int groupId, int messageId) =>
      '$baseUrl$mobilePrefix/groups/$groupId/messages/$messageId';
  static String getGroupUploadUrl(int groupId) =>
      '$baseUrl$mobilePrefix/groups/$groupId/messages/upload';
  static String getGroupMessageDeliveredUrl(int groupId, int messageId) =>
      '$baseUrl$mobilePrefix/groups/$groupId/messages/$messageId/delivered';
  static String getGroupMessagesViewedUrl(int groupId) =>
      '$baseUrl$mobilePrefix/groups/$groupId/messages/viewed';
  static String getGroupMessageReactionsUrl(int groupId, int messageId) =>
      '$baseUrl$mobilePrefix/groups/$groupId/messages/$messageId/reactions';
  static String getGroupDoorbellUrl(int groupId) =>
      '$baseUrl$mobilePrefix/groups/$groupId/doorbell';

  // Translation endpoints
  static const String translateMessageUrl =
      '$baseUrl$mobilePrefix/translate_message';

  // Link preview endpoints
  static String get linkPreviewUrl {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return '$base/api/link_preview';
  }

  // AI endpoints
  static String get aiGeneratePhraseUrl {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return '$base/api/ai/generate_phrase';
  }

  // Pomodoro & Alarm endpoints
  static const String pomodoroPrefix = '/api/pomodoro';
  static const String pomodoroStateUrl = '$baseUrl$pomodoroPrefix/state';
  static const String pomodoroLogsUrl = '$baseUrl$pomodoroPrefix/logs';
  static String getPomodoroLogUrl(int logId) => '$baseUrl$pomodoroPrefix/logs/$logId';

  static const String alarmsPrefix = '/api/alarms';
  static const String alarmsUrl = '$baseUrl$alarmsPrefix';
  static String getAlarmUrl(int alarmId) => '$baseUrl$alarmsPrefix/$alarmId';
  static String getAlarmToggleUrl(int alarmId) =>
      '$baseUrl$alarmsPrefix/$alarmId/toggle';
}
