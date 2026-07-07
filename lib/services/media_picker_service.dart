import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

import '../widgets/custom_asset_picker_builder_delegate.dart';

/// Service wrapping `wechat_assets_picker` for WhatsApp-style multi-select
/// media picking, camera capture, and permission handling.
class MediaPickerService {
  static final ImagePicker _imagePicker = ImagePicker();

  /// Opens the asset picker with WhatsApp-style configuration.
  /// Returns null if cancelled or permission denied.
  ///
  /// [selectedAssets] allows pre-selecting items (e.g. when returning from preview).
  /// [maxAssets] defaults to 20 per the design spec.
  static Future<List<AssetEntity>?> pickAssets(
    BuildContext context, {
    List<AssetEntity>? selectedAssets,
    int maxAssets = 20,
  }) async {
    if (!context.mounted) return null;

    // Request photo/video access up front and get the REAL permission state.
    //
    // The delegate below is built with an explicit `initialPermission`, which
    // bypasses wechat_assets_picker's own built-in permission request. If we
    // hardcode `authorized` (as before), the very first open — when the OS
    // grant hasn't landed yet — builds the grid assuming access, queries the
    // media store with no permission, and shows an empty grid. It only worked
    // on the 2nd try because by then the grant had been recorded. Requesting
    // here and passing the resolved state makes the first open load correctly.
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.hasAccess) {
      debugPrint('pickAssets: photo access not granted ($permission)');
      if (permission == PermissionState.denied) {
        // Permanently denied — surface settings so the user can recover.
        PhotoManager.openSetting();
      }
      return null;
    }

    if (!context.mounted) return null;

    final theme = _buildDarkPickerTheme();

    // Create the provider for the picker
    final provider = DefaultAssetPickerProvider(
      maxAssets: maxAssets,
      selectedAssets: selectedAssets,
      requestType: RequestType.common,
      pageSize: 80,
    );

    // Use our custom builder delegate with the custom viewer.
    // SpecialPickerType.noPreview makes tapping a thumbnail toggle selection
    // instead of opening the picker's built-in viewer.
    final delegate = CustomAssetPickerBuilderDelegate(
      provider: provider,
      initialPermission: permission,
      pickerTheme: theme,
      gridCount: 4,
      textDelegate: const EnglishAssetPickerTextDelegate(),
      specialPickerType: SpecialPickerType.noPreview,
    );

    try {
      final result = await AssetPicker.pickAssetsWithDelegate(
        context,
        delegate: delegate,
      );
      return result;
    } catch (e) {
      // If permission denied, the picker throws — handle gracefully
      debugPrint('pickAssets error: $e');
      return null;
    }
  }

  /// Opens device camera for photo/video capture.
  /// Returns null if cancelled or permission denied.
  ///
  /// Opens in photo mode by default. User can switch to video
  /// in the native camera UI on most devices.
  /// [maxVideoDuration] defaults to 60 seconds per the design spec.
  static Future<AssetEntity?> captureFromCamera(
    BuildContext context, {
    Duration maxVideoDuration = const Duration(seconds: 60),
    bool preferVideo = false,
  }) async {
    final hasPermission = await requestCameraPermission();
    if (!hasPermission) {
      return null;
    }

    if (!context.mounted) return null;

    try {
      XFile? file;
      if (preferVideo) {
        file = await _imagePicker.pickVideo(
          source: ImageSource.camera,
          maxDuration: maxVideoDuration,
          // Default to the rear (back) camera rather than the selfie camera.
          preferredCameraDevice: CameraDevice.rear,
        );
      } else {
        file = await _imagePicker.pickImage(
          source: ImageSource.camera,
          // Default to the rear (back) camera rather than the selfie camera.
          preferredCameraDevice: CameraDevice.rear,
        );
      }

      if (file == null) return null;

      // Convert XFile to AssetEntity by saving to gallery
      final assetEntity = await _fileToAssetEntity(file);
      return assetEntity;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Camera is unavailable. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return null;
    }
  }

  /// Checks and requests photo/video library permission using the native OS dialog.
  /// On Android 13+, requests READ_MEDIA_IMAGES and READ_MEDIA_VIDEO.
  /// On older Android, requests READ_EXTERNAL_STORAGE.
  /// This triggers the standard "Allow access" prompt like WhatsApp.
  /// Returns true if granted.
  static Future<bool> requestPhotoPermission() async {
    // On Android 13+ (API 33), we need both images and videos permissions
    // On older Android, Permission.storage covers everything
    // On iOS, Permission.photos covers the photo library
    if (Platform.isAndroid) {
      // Request both image and video permissions for full access
      final statuses = await [
        Permission.photos, // READ_MEDIA_IMAGES on Android 13+
        Permission.videos, // READ_MEDIA_VIDEO on Android 13+
      ].request();

      final photosGranted = statuses[Permission.photos]?.isGranted ?? false;
      final videosGranted = statuses[Permission.videos]?.isGranted ?? false;

      if (photosGranted && videosGranted) {
        return true;
      }

      // Check if permanently denied — if so, open settings
      final photosPermanent =
          statuses[Permission.photos]?.isPermanentlyDenied ?? false;
      final videosPermanent =
          statuses[Permission.videos]?.isPermanentlyDenied ?? false;

      if (photosPermanent || videosPermanent) {
        await openAppSettings();
      }

      return false;
    } else {
      // iOS: use Permission.photos
      final status = await Permission.photos.status;
      if (status.isGranted || status.isLimited) {
        return true;
      }

      final result = await Permission.photos.request();
      if (result.isGranted || result.isLimited) {
        return true;
      }

      if (result.isPermanentlyDenied) {
        await openAppSettings();
      }
      return false;
    }
  }

  /// Checks and requests camera permission.
  /// Returns true if granted.
  static Future<bool> requestCameraPermission() async {
    final status = await Permission.camera.status;

    if (status.isGranted) {
      return true;
    }

    // This triggers the native OS permission dialog
    final result = await Permission.camera.request();

    if (result.isGranted) {
      return true;
    }

    // If permanently denied, open app settings so user can grant manually
    if (result.isPermanentlyDenied) {
      await openAppSettings();
    }

    return false;
  }

  /// Converts an XFile (from image_picker) to an AssetEntity
  /// by saving it to the device gallery.
  static Future<AssetEntity?> _fileToAssetEntity(XFile file) async {
    final bytes = await file.readAsBytes();
    final fileName = file.name;

    // Determine if it's a video or image based on mime type
    final mimeType = file.mimeType ?? '';
    final isVideo =
        mimeType.startsWith('video') ||
        fileName.toLowerCase().endsWith('.mp4') ||
        fileName.toLowerCase().endsWith('.mov');

    if (isVideo) {
      final tempFile = File(file.path);
      final asset = await PhotoManager.editor.saveVideo(
        tempFile,
        title: fileName,
      );
      return asset;
    } else {
      final asset = await PhotoManager.editor.saveImage(
        bytes,
        title: fileName,
        filename: fileName,
      );
      return asset;
    }
  }

  /// Builds a dark theme for the asset picker matching the app's violet color scheme.
  static ThemeData _buildDarkPickerTheme() {
    const primaryColor = Color(0xFF7C3AED);

    return ThemeData.dark().copyWith(
      primaryColor: primaryColor,
      colorScheme: const ColorScheme.dark(
        primary: primaryColor,
        secondary: primaryColor,
        surface: Color(0xFF1E1E1E),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF121212),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      scaffoldBackgroundColor: const Color(0xFF121212),
      bottomAppBarTheme: const BottomAppBarThemeData(color: Color(0xFF1E1E1E)),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: primaryColor),
      ),
      iconTheme: const IconThemeData(color: Colors.white),
    );
  }
}
