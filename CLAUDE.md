# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Environment setup (required before running)

- The backend is a Flask API. Its URL and all endpoint paths are defined in `lib/config/api_config.dart` (`ApiConfig`); the base URL is injected from `.env.json` at build time, defaulting to `https://web.flask-call-app.site/`.
- Copy `.env.json.example` to `.env.json` (gitignored) and set `BASE_URL`.
- **Every `flutter run` / `flutter build` must pass `--dart-define-from-file=.env.json`** — without it `BASE_URL` falls back to the default and won't match your environment. This flag also feeds `BuildConfig.BASE_URL` to native Android code.
- **Every Android `flutter run` must also pass `--device-user=0`.** A plain `flutter run` installs into Samsung's hidden `DUAL_APP` user as well as the owner profile, producing a duplicate ChatX icon that is not removable from the Dual Messenger settings UI.
- Release Android builds require `android/key.properties` (gitignored: storeFile, storePassword, keyAlias, keyPassword). Without it, release signing falls back to debug.
- `lib/firebase_options.dart` is a placeholder — run `flutterfire configure` to populate it before relying on Firebase/FCM.

## Commands

```bash
flutter run --device-user=0 --dart-define-from-file=.env.json  # Android owner profile only
flutter run --release --device-user=0 --dart-define-from-file=.env.json
flutter build apk --dart-define-from-file=.env.json    # release APK
flutter analyze                                         # static analysis / lint (run after edits)
flutter test                                            # unit/widget tests (sparse coverage)
flutter test test/foo_test.dart -p 'test name'         # single test
./build_and_install.sh                                  # release build + adb install (--skip-install, --start-logcat)
```

## Verifying changes

Run `flutter analyze` and `flutter test` after changes. Many flows (Socket.IO realtime, WebRTC calls, notifications) can only be confirmed by a manual `flutter run` on a real device.

## Architecture

Service-based, no heavy state-management framework — mostly `StatefulWidget` + `setState`, with `provider` used only by the custom asset picker. Logic lives in singleton services under `lib/services/` (35+ services); screens in `lib/screens/`, reusable UI in `lib/widgets/`, data classes in `lib/models/`, all backend endpoints in `lib/config/api_config.dart`.

Key cross-cutting pieces:
- **`socket_service.dart`** — Socket.IO singleton using a multi-listener broadcast pattern (multiple screens subscribe to the same event via listener maps). When adding a realtime feature, register/unregister listeners here rather than opening new connections.
- **Offline-first** — Hive (`chat_cache_service.dart`) caches messages; `media_preload_service.dart` pre-downloads media; failed sends/uploads retry via the `*_retry_service.dart` / `message_queue_service.dart` services.
- **`main.dart`** — ordered async init (storage → cache → upload retry → share/shortcut intents → alarms → auth/home resolution); preserve ordering when adding bootstrap steps.
- Notifications/alarms sync backend state to device-local scheduling (`alarm_notification_service.dart`, `firebase_messaging_service.dart`); Android quick-reply and notification routing go through MethodChannels named `com.example.flutter_messenger_v2/*`.

- **Excalidraw whiteboards** — two different things share one modal and one header badge. *Pinned links* are chat messages someone highlighted (`/api/mobile/messages/excalidraw/...`). *Boards* are whiteboards hosted by the Flask backend itself (`excalidraw_rooms_service.dart` → `/api/excalidraw/rooms-list`, outside `/api/mobile`, same Bearer token). Boards are scoped to one conversation by a key that must be **the sorted participant pair** (`dm:<lo>-<hi>`) or `group:<id>` — derive it any other way and the two sides of a chat file boards in different places and see none of each other's. Changes arrive over the `excalidraw_room_created/updated/deleted` socket events. Opening a board launches the browser; the room key stays in the URL fragment and never reaches the server.

Feature specs worth reading when relevant: @POMODORO_RULES.md and @BUILD_AND_TEST.md (WebRTC screen-share testing).

## Conventions

- Commit messages: match existing history — `fixed:` / `added:` / `changed:` prefix, then a description, then a `(mobile)` platform suffix. Example: `fixed: image uploads now resume after reconnect (mobile)`.
- Lint config is stock `flutter_lints` (`analysis_options.yaml`) — follow standard Dart/Flutter style; no custom rule overrides.
- Never commit `.env.json` or `android/key.properties` (both gitignored).
