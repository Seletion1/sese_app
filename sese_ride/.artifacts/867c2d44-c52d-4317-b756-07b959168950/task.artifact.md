# Implementation Task Checklist - Purge `SYSTEM_ALERT_WINDOW` Overlay & Transition to FCM `fullScreenIntent`

- [x] Delete overlay files (`driver_overlay_entry.dart`, `driver_overlay_service.dart`, `driver_overlay_disclosure_dialog.dart`, overlay tests)
- [x] Remove `flutter_overlay_window` dependency from `sese_ride/pubspec.yaml`
- [x] Remove `SYSTEM_ALERT_WINDOW` permission & `OverlayService` from `AndroidManifest.xml`
- [x] Update `sese_ride/lib/background_handler.dart` & `sese_ride/lib/main.dart`
- [x] Clean up `driver_dashboard_screen.dart` and `driver_home_shell.dart`
- [x] Remove `driver_overlay_disclosure_dialog.dart` export from `sese_core.dart`
- [x] Run `flutter pub get` in `sese_ride`
- [x] Run static code analysis (`flutter analyze`) across packages
- [x] Run `flutter test` in `sese_core` and `sese_ride`
- [x] Run backend unit test suite (`npm test`)
- [x] Execute mandatory build, test & Firebase deployment pipeline
- [x] Create `walkthrough.artifact.md`
