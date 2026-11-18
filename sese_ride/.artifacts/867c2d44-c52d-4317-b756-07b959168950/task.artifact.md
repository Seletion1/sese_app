# Implementation Task Checklist - Purge `SYSTEM_ALERT_WINDOW` Overlay & Transition to FCM `fullScreenIntent`

- [/] Delete overlay files (`driver_overlay_entry.dart`, `driver_overlay_service.dart`, `driver_overlay_disclosure_dialog.dart`, overlay tests)
- [/] Remove `flutter_overlay_window` dependency from `sese_ride/pubspec.yaml`
- [/] Remove `SYSTEM_ALERT_WINDOW` permission & `OverlayService` from `AndroidManifest.xml`
- [/] Update `sese_ride/lib/background_handler.dart` & `sese_ride/lib/main.dart`
- [/] Clean up `driver_dashboard_screen.dart` and `driver_home_shell.dart`
- [/] Remove `driver_overlay_disclosure_dialog.dart` export from `sese_core.dart`
- [ ] Run `flutter pub get` in `sese_ride`
- [ ] Run static code analysis (`flutter analyze`) across packages
- [ ] Run `flutter test` in `sese_core` and `sese_ride`
- [ ] Run backend unit test suite (`npm test`)
- [ ] Execute mandatory build, test & Firebase deployment pipeline
- [ ] Create `walkthrough.artifact.md`
