# Fix Incoming Order `fullScreenIntent` Notification Channel Routing

Fix notification channel resolution in `PushNotificationService._channelFor()` so that incoming driver order pings (`trip_offer`, `direct_ping`, `tier_ping`, `marketplace_broadcast`) correctly resolve to `PushChannels.orders` (`sese_orders`) instead of being trapped in the chat channel. This enables native `fullScreenIntent: true` with `Importance.max` and `category: AndroidNotificationCategory.call`, allowing incoming orders to wake the screen and pop up over external apps and lockscreen automatically.

## User Review Required

> [!IMPORTANT]
> - **Channel Priority & Ordering Fix**:
>   - In `sese_core/lib/services/push_notification_service.dart`:
>   - Previously, `type.startsWith('trip_')` was evaluated before `type == 'trip_offer'`, routing `trip_offer` pings into `PushChannels.chat` (`sese_chat`) without `fullScreenIntent` or `Importance.max`.
>   - Update `_channelFor()` to evaluate order/dispatch types (`trip_offer`, `direct_ping`, `tier_ping`, `marketplace_broadcast`) BEFORE prefix checks, ensuring `PushChannels.orders` (`sese_orders`) is returned.
> - **Native Screen-Waking Behavior**:
>   - With `PushChannels.orders` matched, `showFromMessage` applies `fullScreenIntent: true`, `importance: Importance.max`, `priority: Priority.max`, and `category: AndroidNotificationCategory.call`.
>   - In combination with `MainActivity`'s `android:showWhenLocked="true"` and `android:turnScreenOn="true"`, incoming orders immediately wake the device screen and pop up the order sheet (`IncomingOfferSheet`) over background apps and lockscreen.

## Proposed Changes

### Shared Core Package (`sese_core`)

#### [MODIFY] [push_notification_service.dart](file:///Users/micheal/sese_app/sese_core/lib/services/push_notification_service.dart#L430-L460)
- Re-order channel resolution logic in `_channelFor()` so order offer types (`trip_offer`, `direct_ping`, `tier_ping`, `marketplace_broadcast`) take precedence over `type.startsWith('trip_')`.

---

## Verification Plan

### Automated Test & Analysis Execution
- Run `flutter analyze` across `sese_core`, `sese_hub`, `sese_ride`.
- Run `flutter test` unit tests in `sese_core` and `sese_ride`.
- Run `npm test` in `functions/`.

### Deployment Pipeline
- Deploy backend functions and security rules via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `fix: resolve order notification channel routing to enable fullScreenIntent screen wake`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
