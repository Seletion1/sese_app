# Complete Removal of `SYSTEM_ALERT_WINDOW` & Transition to Native FCM `fullScreenIntent`

Completely purge all custom overlay window code, floating heads, and `SYSTEM_ALERT_WINDOW` permissions from `sese_ride` and `sese_core`. Replace with native Firebase Cloud Messaging (FCM) high-priority `fullScreenIntent` notifications that wake the screen and route directly to active order acceptance screens over the lockscreen.

## User Review Required

> [!IMPORTANT]
> - **1. Purge Overlay Code & `SYSTEM_ALERT_WINDOW` Permission**:
>   - Delete `sese_ride/lib/driver_overlay_entry.dart` and `sese_ride/lib/features/driver/services/driver_overlay_service.dart`.
>   - Delete test files `test/driver_overlay_card_widget_test.dart` and `test/driver_overlay_service_test.dart`.
>   - Delete `sese_core/lib/widgets/driver_overlay_disclosure_dialog.dart`.
>   - Remove `flutter_overlay_window: ^0.5.0` from `sese_ride/pubspec.yaml`.
>   - Remove `<uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />` and `<service android:name="flutter.overlay.window.flutter_overlay_window.OverlayService" ... />` from `AndroidManifest.xml` to eliminate Google Play policy liabilities.
> - **2. Native `fullScreenIntent` High-Priority Channel Setup**:
>   - Configure FCM local notification channels (`PushNotificationService.showFromMessage` and `driverBackgroundHandler`) with `IMPORTANCE_MAX`, `Priority.high`, `fullScreenIntent: true`, `category: AndroidNotificationCategory.call`, and `visibility: NotificationVisibility.public`.
>   - Keep `MainActivity` configured with `android:showWhenLocked="true"` and `android:turnScreenOn="true"` so incoming orders wake the screen and display over the lockscreen.
> - **3. Background-to-Foreground Dispatch Handoff**:
>   - When a full-screen intent or notification is tapped/auto-launched, `AppLauncher().bringToForeground` launches `MainActivity` with payload extras (`tripId`, `type`).
>   - `PushNotificationService.incomingOfferNotifier` and `onMessageDataStream` consume the offer payload, opening the full-screen order sheet (`IncomingOfferSheet` / `OrderPoolSheet`) with Accept and Decline buttons.

## Proposed Changes

### Android Native Configuration (`sese_ride`)

#### [MODIFY] [AndroidManifest.xml](file:///Users/micheal/sese_app/sese_ride/android/app/src/main/AndroidManifest.xml)
- Remove `SYSTEM_ALERT_WINDOW` permission and `OverlayService` definition.

### Shared Core Package (`sese_core`)

#### [DELETE] [driver_overlay_disclosure_dialog.dart](file:///Users/micheal/sese_app/sese_core/lib/widgets/driver_overlay_disclosure_dialog.dart)
- Delete `driver_overlay_disclosure_dialog.dart`.

#### [MODIFY] [sese_core.dart](file:///Users/micheal/sese_app/sese_core/lib/sese_core.dart)
- Remove `export 'widgets/driver_overlay_disclosure_dialog.dart';`.

#### [MODIFY] [push_notification_service.dart](file:///Users/micheal/sese_app/sese_core/lib/services/push_notification_service.dart)
- Clean up comments referencing overlay bubble/window service.

### Customer & Driver App (`sese_ride`)

#### [DELETE] [driver_overlay_entry.dart](file:///Users/micheal/sese_app/sese_ride/lib/driver_overlay_entry.dart)
- Delete `driver_overlay_entry.dart`.

#### [DELETE] [driver_overlay_service.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/driver/services/driver_overlay_service.dart)
- Delete `driver_overlay_service.dart`.

#### [DELETE] [driver_overlay_card_widget_test.dart](file:///Users/micheal/sese_app/sese_ride/test/driver_overlay_card_widget_test.dart)
- Delete `driver_overlay_card_widget_test.dart`.

#### [DELETE] [driver_overlay_service_test.dart](file:///Users/micheal/sese_app/sese_ride/test/driver_overlay_service_test.dart)
- Delete `driver_overlay_service_test.dart`.

#### [MODIFY] [pubspec.yaml](file:///Users/micheal/sese_app/sese_ride/pubspec.yaml)
- Remove `flutter_overlay_window` dependency.

#### [MODIFY] [background_handler.dart](file:///Users/micheal/sese_app/sese_ride/lib/background_handler.dart)
- Remove `flutter_overlay_window` imports and calls, relying strictly on `PushNotificationService.showFromMessage` (high-priority `fullScreenIntent`) and `AppLauncher().bringToForeground`.

#### [MODIFY] [main.dart](file:///Users/micheal/sese_app/sese_ride/lib/main.dart)
- Remove `driver_overlay_entry.dart` and `driver_overlay_service.dart` imports/exports. Replace overlay calls in push handler with `AppLauncher().bringToForeground()`.

#### [MODIFY] [driver_dashboard_screen.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/driver/presentation/driver_dashboard_screen.dart)
- Remove `DriverOverlayService` calls.

#### [MODIFY] [driver_home_shell.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/home/driver_home_shell.dart)
- Remove `DriverOverlayService` calls in `_handlePopInvoked`.

---

## Verification Plan

### Automated Test & Analysis Execution
- Run `flutter pub get` in `sese_ride`.
- Run `flutter analyze` across `sese_ride`, `sese_core`, `sese_hub`.
- Run `flutter test` in `sese_core` and `sese_ride`.
- Run `npm test` in `functions/`.

### Deployment Pipeline
- Deploy backend functions and security rules via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `refactor: purge SYSTEM_ALERT_WINDOW overlay code and transition to native FCM fullScreenIntent notifications`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
