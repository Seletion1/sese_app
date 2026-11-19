# Walkthrough - Purge `SYSTEM_ALERT_WINDOW` Overlay & Transition to FCM `fullScreenIntent`

## Summary of Implementation

Completely purged custom overlay window code, floating bubble services, and the `SYSTEM_ALERT_WINDOW` permission from `sese_ride` and `sese_core`. Replaced with native Firebase Cloud Messaging (FCM) high-priority `fullScreenIntent` notifications that wake the screen and route directly to active order acceptance screens over the lockscreen.

### 1. Deleted Overlay Files & Package Purge
- **Deleted Files**:
  - `sese_ride/lib/driver_overlay_entry.dart`
  - `sese_ride/lib/features/driver/services/driver_overlay_service.dart`
  - `sese_ride/test/driver_overlay_card_widget_test.dart`
  - `sese_ride/test/driver_overlay_service_test.dart`
  - `sese_core/lib/widgets/driver_overlay_disclosure_dialog.dart`
- **Package Purge**: Removed `flutter_overlay_window` from `sese_ride/pubspec.yaml` and purged `driver_overlay_disclosure_dialog.dart` export from `sese_core.dart`.

### 2. Android Native Configuration (`AndroidManifest.xml`)
**[AndroidManifest.xml](file:///Users/micheal/sese_app/sese_ride/android/app/src/main/AndroidManifest.xml)**
- Removed `<uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />` to eliminate Google Play Store policy liabilities and rejection risks.
- Removed `<service android:name="flutter.overlay.window.flutter_overlay_window.OverlayService" ... />` definition.
- Preserved `MainActivity` flags `android:showWhenLocked="true"` and `android:turnScreenOn="true"` for lockscreen full-screen intents.

### 3. Native `fullScreenIntent` High-Priority Notification Channel
**[push_notification_service.dart](file:///Users/micheal/sese_app/sese_core/lib/services/push_notification_service.dart#L460-L510)** & **[background_handler.dart](file:///Users/micheal/sese_app/sese_ride/lib/background_handler.dart#L25-L65)**
- High-priority order notifications trigger `PushNotificationService.showFromMessage` with `fullScreenIntent: true`, `importance: Importance.max`, `priority: Priority.high`, `category: AndroidNotificationCategory.call`, and `visibility: NotificationVisibility.public`.
- When an order arrives while the screen is locked or the app is in the background, Android wakes up the screen and displays the high-importance notification banner or full-screen intent.

### 4. Background-to-Foreground Dispatch Handoff
**[background_handler.dart](file:///Users/micheal/sese_app/sese_ride/lib/background_handler.dart#L60-L80)** & **[main.dart](file:///Users/micheal/sese_app/sese_ride/lib/main.dart#L200-L215)**
- `driverBackgroundHandler` persists the offer payload to `SharedPreferences` and brings `MainActivity` to the foreground via `AppLauncher().bringToForeground(extras: {'tripId': tripId, 'type': type})`.
- `PushNotificationService.incomingOfferNotifier` and `onMessageDataStream` consume the payload, opening the full-screen order sheet (`IncomingOfferSheet` / `OrderPoolSheet`) directly on top of the dashboard with clear Accept and Decline buttons.

---

## Verification Results

### Automated Tests & Pipeline Execution
- **Flutter Code Analysis (`flutter analyze`)**: Passed cleanly across `sese_core`, `sese_hub`, and `sese_ride` with 0 issues.
- **Flutter Unit Tests (`flutter test`)**: All 153 unit tests in `sese_core` and 40 unit tests in `sese_ride` passed with 0 failures.
- **Backend Unit Tests (`npm test`)**: All 147 backend unit tests passed across 48 test suites with 0 failures.
- **Firebase Deployment**: All 77 Cloud Functions and Firestore security rules deployed successfully live on `sese-ride`.
- **Git Sync**: Staged, committed, and pushed commit `1c68c8d` to `https://github.com/Seletion1/sese_app.git` on branch `main`.
