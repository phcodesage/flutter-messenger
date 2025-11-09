/// API Configuration
/// Change the baseUrl here to point to your backend server
class ApiConfig {
  // Base URL for the API - change this to switch backends
  static const String baseUrl = 'https://dev.flask-meet.site';
  
  // API endpoints
  static const String authPrefix = '/api/auth';
  static const String mobilePrefix = '/api/mobile';
  
  // Auth endpoints
  static String get registerUrl => '$baseUrl$authPrefix/register';
  static String get loginUrl => '$baseUrl$authPrefix/login';
  static String get logoutUrl => '$baseUrl$authPrefix/logout';
  static String get meUrl => '$baseUrl$authPrefix/me';
  static String get forgotPasswordUrl => '$baseUrl$authPrefix/forgot-password';
  static String get resetPasswordUrl => '$baseUrl$authPrefix/reset-password';
  
  // Mobile endpoints
  static String get lobbyUrl => '$baseUrl$mobilePrefix/lobby';
  static String get usersUrl => '$baseUrl$mobilePrefix/users';
  static String get contactsUrl => '$baseUrl$mobilePrefix/contacts';
  static String get conversationsUrl => '$baseUrl$mobilePrefix/messages/conversations';
  static String get sendMessageUrl => '$baseUrl$mobilePrefix/messages/send';
  static String get presenceStatusUrl => '$baseUrl$mobilePrefix/presence/status';
  static String get heartbeatUrl => '$baseUrl$mobilePrefix/presence/heartbeat';
  
  // Timeouts
  static const Duration connectionTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 30);
}
