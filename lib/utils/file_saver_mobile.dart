import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_filex/open_filex.dart';

class FileSaver {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  static bool _notificationsInitialized = false;

  static Future<void> _initNotifications() async {
    if (_notificationsInitialized) return;
    const initSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettingsIOS = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: initSettingsAndroid,
      iOS: initSettingsIOS,
    );
    await _notificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) async {
        final path = response.payload;
        if (path != null && path.isNotEmpty) {
          try {
            await OpenFilex.open(path);
          } catch (_) {}
        }
      },
    );
    _notificationsInitialized = true;
  }

  static Future<String?> saveFile({
    required String filename,
    required String content,
  }) async {
    // Request storage permission
    try {
      await Permission.storage.request();
    } catch (_) {}

    Directory? dir;
    if (Platform.isAndroid) {
      // Direct Download folder on Android
      final publicDownload = Directory('/storage/emulated/0/Download');
      if (await publicDownload.exists()) {
        dir = publicDownload;
      }
    }
    
    if (dir == null) {
      try {
        dir = await getDownloadsDirectory();
      } catch (_) {}
    }
    if (dir == null) {
      try {
        dir = await getExternalStorageDirectory();
      } catch (_) {}
    }
    dir ??= await getApplicationDocumentsDirectory();

    final file = File('${dir.path}/$filename');
    String finalPath;
    
    try {
      await file.writeAsString(content);
      finalPath = file.path;
    } catch (e) {
      // Fallback to application documents directory
      final fallbackDir = await getApplicationDocumentsDirectory();
      final fallbackFile = File('${fallbackDir.path}/$filename');
      await fallbackFile.writeAsString(content);
      finalPath = fallbackFile.path;
    }

    // Trigger Android/iOS system notification
    try {
      await _initNotifications();
      const androidDetails = AndroidNotificationDetails(
        'chat_export',
        'Chat Exports',
        channelDescription: 'Notifications for exported chats',
        importance: Importance.high,
        priority: Priority.high,
        ongoing: false,
        autoCancel: true,
        icon: '@mipmap/ic_launcher',
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );
      
      await _notificationsPlugin.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'Chat Exported Successfully',
        'Saved as $filename (Tap to open)',
        const NotificationDetails(android: androidDetails, iOS: iosDetails),
        payload: finalPath,
      );
    } catch (_) {
      // Silently catch notification errors
    }

    return finalPath;
  }
}
