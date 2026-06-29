abstract class FileSaver {
  static Future<String?> saveFile({
    required String filename,
    required String content,
  }) {
    throw UnimplementedError('Platform not supported');
  }
}
