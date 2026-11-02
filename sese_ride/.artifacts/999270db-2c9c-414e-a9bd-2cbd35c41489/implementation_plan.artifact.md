# Implementation Plan: Fix Fare-Boosting & Real-Time Driver Broadcast

Fix the false "Session Expired" error on the customer's Boost Offer Fare dialog and implement real-time fare updates across all driver order views (Order Feed, Pool Detail Sheet, and Incoming Offer Sheet).

## User Review Required

> [!IMPORTANT]
> - **Auth Token Validation Fix**: The custom `_ensureFreshAuthToken()` helper in `FirestoreTripRepository` was aggressively invoking `user.getIdToken()` and converting any transient network or platform error into a false `TripException('unauthenticated', 'Your session has expired. Please sign in again.')`. We will sanitize `_ensureFreshAuthToken()` to verify logged-in user state (`user != null`) and allow `FirebaseFunctions` SDK (`httpsCallable`) to manage JWT token refreshing natively, while catching true 401 unauthenticated errors returned from Cloud Functions.
> - **Real-Time Fare Synchronization**: Driver order views (`_PoolOrderDetailSheet`, `IncomingOfferSheet`, `OrderCard`) and `marketplaceStream()` will stream live trip updates via Firestore `tripStream()` so that whenever a customer boosts an active trip fare, all connected drivers instantly see the updated amount, percentage badges, and counter-offer targets in real time without stale prices or desyncs.

## Open Questions

- None. The root causes and solution architecture are fully identified.

---

## Proposed Changes

### Core Trip Service (`lib/features/trips/services/trip_service.dart`)

#### [MODIFY] [trip_service.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/services/trip_service.dart)
- Update `_ensureFreshAuthToken()`:
  - Check if `FirebaseAuth.instance.currentUser == null` (throwing `unauthenticated` only when no user session exists).
  - Perform a safe, non-blocking token check for active users without throwing false `unauthenticated` errors on transient errors.
  - Rely on `FirebaseFunctions.instance.httpsCallable()` native JWT handling and server-returned 401 status mapping.

---

### Driver Streak Service (`lib/features/driver/services/driver_streak_service.dart`)

#### [MODIFY] [driver_streak_service.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/driver/services/driver_streak_service.dart)
- Expand `marketplaceStream()` status filter to include all searching trip statuses:
  - Add `'SEARCHING_DRIVER'`, `'searching_driver'`, and `'WAITING_FOR_ACCEPTANCE'` to `whereIn` array so all active searching/broadcasting orders emit in real time to nearby drivers.

---

### Driver Order Views (`lib/features/driver/presentation/widgets/`)

#### [MODIFY] [order_pool_sheet.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/driver/presentation/widgets/order_pool_sheet.dart)
- Wrap `_PoolOrderDetailSheet` with `StreamBuilder<ActiveTrip?>` using `tripStream(trip.tripId)`.
- Dynamically update the main fare header, per-km rate, counter-offer suggestion chips (+5%, +10%), and primary accept CTA button ("Accept (₦X)") in real time as fare boosts land from Firestore.

#### [MODIFY] [incoming_offer_sheet.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/driver/presentation/widgets/incoming_offer_sheet.dart)
- Stream live updates for the active ping via `tripStream(trip.tripId)`.
- Update offer fare labels, rate per km, breakdown banner, and CTA button in real-time when a customer increases the fare during the ping window.

---

### Tests (`test/`)

#### [MODIFY] [boost_fare_test.dart](file:///Users/micheal/sese_app/sese_ride/test/boost_fare_test.dart)
- Add unit and widget test cases for:
  - Confirming fare boosts complete without false "session expired" errors.
  - Verifying real-time stream propagation of updated trip fares to driver order sheets.

---

## Verification Plan

### Automated Tests
- Run `flutter test test/boost_fare_test.dart` to verify fare boosting dialog and repo execution.
- Run `flutter test test/order_pool_bidding_test.dart` and `flutter test test/order_feed_test.dart` to verify driver order pool real-time updates.
- Run full test suite: `flutter test`

### Manual Verification
- Launch customer app, initiate a trip request, open "Boost Offer Fare" dialog, increase fare, and verify dialog succeeds cleanly without any false "Your session has expired" error.
- Verify driver app immediately reflects the updated fare on the Order Feed card, Order Pool sheet, and expanded Order Detail sheet in real-time.
