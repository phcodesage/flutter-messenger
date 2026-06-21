import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var fileOpsChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)

    configureFileOpsChannelIfNeeded()

    // Bring the app and its window to the foreground and give it keyboard focus
    // on launch. Without this the window can open behind other apps (flutter run
    // logs "Failed to foreground app"); the focus change when the user then
    // clicks the window desyncs Flutter's HardwareKeyboard state, which triggers
    // the "physical key is already pressed" assertion loop and blocks all text
    // input on macOS.
    NSApp.activate(ignoringOtherApps: true)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)

    // Some app launches initialize the window/controller one runloop later.
    DispatchQueue.main.async { [weak self] in
      self?.configureFileOpsChannelIfNeeded()
      NSApp.activate(ignoringOtherApps: true)
      self?.mainFlutterWindow?.makeKeyAndOrderFront(nil)
    }
  }

  private func configureFileOpsChannelIfNeeded() {
    if fileOpsChannel != nil {
      return
    }

    let flutterViewController =
      (mainFlutterWindow?.contentViewController as? FlutterViewController) ??
      NSApplication.shared.windows
        .compactMap { $0.contentViewController as? FlutterViewController }
        .first

    guard let flutterViewController else {
      return
    }

    let channel = FlutterMethodChannel(
      name: "com.example.flutter_messenger_v2/file_ops",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleFileOpsMethodCall(call, result: result)
    }
    fileOpsChannel = channel
  }

  private func handleFileOpsMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getClipboardImagePngBytes":
      guard let pngData = clipboardImagePngData() else {
        result(nil)
        return
      }
      result(FlutterStandardTypedData(bytes: pngData))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func clipboardImagePngData() -> Data? {
    let pasteboard = NSPasteboard.general

    if let png = pasteboard.data(forType: .png), !png.isEmpty {
      return png
    }

    if let tiff = pasteboard.data(forType: .tiff),
       let image = NSImage(data: tiff),
       let png = image.fm_pngData() {
      return png
    }

    return nil
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

private extension NSImage {
  func fm_pngData() -> Data? {
    guard let tiffData = tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData) else {
      return nil
    }
    return bitmap.representation(using: .png, properties: [:])
  }
}
