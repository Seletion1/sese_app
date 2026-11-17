# Full-Screen Intent & Drop-Off Confirmation Request Implementation

Implement high-priority Full-Screen Intent notifications, dedicated high-importance notification channels, FCM data payload enhancements, and immediate UI redirection for customer drop-off approval and trip-completion requests in `sese_ride` and backend `functions/src/trips.ts`.

## User Review Required

> [!IMPORTANT]
> - **1. Android Manifest & Lock-Screen Permissions**:
>   - Confirm `USE_FULL_SCREEN_INTENT`, `WAKE_LOCK`, `POST_NOTIFICATIONS` in `sese_ride/android/app/src/main/AndroidManifest.xml`.
>   - Ensure `MainActivity` retains `showWhenLocked="true"`, `turnScreenOn="true"`, and `singleTop` launch mode to wake the device screen and launch over the keyguard.
> - **2. Dedicated High-Importance Notification Channel**:
>   - Ensure `PushChannels.orders` ("Order alerts" / `sese_orders`) in `push_notification_service.dart` configures `Importance.max`, `Priority.high`, `fullScreenIntent: true`, `category: AndroidNotificationCategory.call`, `visibility: NotificationVisibility.public`, and vibration.
>   - Add explicit support for `dropoff_approval_request`, `drop_off_confirmation`, and `dropoff_approval` notification types in `_channelFor` so drop-off confirmation requests route through `PushChannels.orders` with full-screen intent.
> - **3. Backend FCM Payload & High-Priority Dispatch (`trips.ts`)**:
>   - Enhance `requestDropoffApproval` and `notifyCustomer` in `functions/src/trips.ts` to include high-priority flags (`priority: "high"`, `content_available: true`, `click_action: "FLUTTER_NOTIFICATION_CLICK"`, `fullScreen: "true"`).
>   - Ensure `type: "drop_off_confirmation"` (or `dropoff_approval_request`) is included in the FCM data payload.
> - **4. Customer App UI & State Redirection (`main.dart` & `live_trip_screen.dart`)**:
>   - Ensure `_handlePushTap` and foreground push handlers immediately push `LiveTripScreen` with the target `tripId`.
>   - Verify `_CustomerDropoffApprovalCard` presents the interactive confirmation sheet with "Confirm Drop-off" (`dropoff_approval_approve_button`) and "Decline" (`dropoff_approval_reject_button`) right on top of the active screen.

## Proposed Changes

### Cloud Functions Backend (`functions/src`)

#### [MODIFY] [trips.ts](file:///Users/micheal/sese_app/functions/src/trips.ts#L230-L315)
- Update `notifyCustomer` to route `dropoff_approval_request` / `drop_off_confirmation` as pure high-priority data payloads with `fullScreen: "true"`, `priority: "high"`, and `contentAvailable: true` on Android and iOS.

### Shared Flutter Core (`sese_core`)

#### [MODIFY] [push_notification_service.dart](file:///Users/micheal/sese_app/sese_core/lib/services/push_notification_service.dart#L440-L480)
- Update `_channelFor` and `showFromMessage` to classify `dropoff_approval_request`, `drop_off_confirmation`, `dropoff_approval`, and `dropoff_approval_response` under `PushChannels.orders` with `fullScreenIntent: true`, `Importance.max`, `Priority.high`, and `NotificationVisibility.public`.

### Customer App (`sese_ride`)

#### [MODIFY] [main.dart](file:///Users/micheal/sese_app/sese_ride/lib/main.dart#L205-L245)
- Enhance `_handlePushTap` to handle `drop_off_confirmation` / `dropoff_approval_request` payloads and immediately open `LiveTripScreen`.

---

## Verification Plan

### Automated Test Execution
- Run `flutter analyze` across `sese_ride` and `sese_core`.
- Run `npm test` in `functions/`.
- Run `flutter test test/dropoff_geofence_test.dart` and `test/live_trip_screen_test.dart`.

### Deployment Pipeline
- Build TS and validate manifest via `npm run build` in `functions/`.
- Deploy backend via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `feat: implement full-screen intent for customer drop-off confirmation requests`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
