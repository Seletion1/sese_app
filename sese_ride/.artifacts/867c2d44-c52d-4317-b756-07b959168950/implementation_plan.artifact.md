# Per-Trip "Enable Bidding" Toggle & Fixed-Fare Enforcement

Implement a customer-facing "Allow Driver Bidding / Counter-Offers" toggle on the ride checkout screen in `sese_ride` (enabled by default), update the Firestore `trips` schema (`allow_bidding: true/false`), and enforce fixed-price broadcasting across Cloud Functions (`submitBid`, `createTrip`) and driver/customer UI surfaces.

## User Review Required

> [!IMPORTANT]
> - **1. Ride Checkout Screen UI Toggle**:
>   - Add "Allow Driver Bidding / Counter-Offers" toggle switch in `customer_dispatch_screen.dart` (alongside payment method selector and fare summary).
>   - Default switch to **ON** (`allow_bidding: true`) for every order. When toggled OFF, order is created as a fixed-fare trip.
> - **2. Backend & Matching Engine Enforcement (`functions/src/trips.ts`)**:
>   - `createTrip`: Persists `allow_bidding: true/false` to Firestore trip document.
>   - `submitBid`: Verifies `allow_bidding !== false`. If `false`, rejects counter-offer bids with `failed-precondition` error ("This trip is fixed-price only and does not accept driver counter-offers.").
> - **3. Driver & Customer UI Adaptation**:
>   - Driver cards (`order_card.dart`, `order_pool_sheet.dart`): Hide counter-offer bidding buttons when `allowBidding == false`; drivers see a fixed fare and can only accept or pass.
>   - Customer active trip views (`live_trip_screen.dart`, `customer_bid_overlay.dart`): Show bidding counter-offers bar when `allowBidding == true`. Display fixed-fare searching status ("Fixed Fare Order - Searching for driver at ₦X") and suppress bid overlays when `allowBidding == false`.

## Proposed Changes

### Shared Core & Trip Models (`sese_ride`)

#### [MODIFY] [trip_models.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/models/trip_models.dart)
- Add `allowBidding` boolean field (default `true`) to `TripDraft`, `TripData`, and `TripModel` with `fromMap` / `toMap` serialization.

### Customer Ride Checkout & Active Trip UI (`sese_ride`)

#### [MODIFY] [customer_dispatch_screen.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/customer/presentation/customer_dispatch_screen.dart)
- Add `_allowBidding` state variable (default `true`) and "Allow Driver Bidding / Counter-Offers" switch tile under payment selector on checkout sheet.

#### [MODIFY] [live_trip_screen.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/presentation/live_trip_screen.dart)
- Update status messaging and bidding list visibility: display fixed-fare status when `allowBidding == false`.

#### [MODIFY] [customer_bid_overlay.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/presentation/customer_bid_overlay.dart)
- Filter out trips with `allowBidding == false` from active bid overlay stream.

### Driver Order Surface (`sese_ride`)

#### [MODIFY] [order_card.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/driver/presentation/widgets/order_card.dart)
- Hide "Bid Fare" button when `trip.allowBidding == false` and show single "Accept (Fixed Fare)" action button.

#### [MODIFY] [order_pool_sheet.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/driver/presentation/widgets/order_pool_sheet.dart)
- Disable counter-offer slider / bidding controls when `trip.allowBidding == false`.

### Cloud Functions Backend (`functions/src`)

#### [MODIFY] [trips.ts](file:///Users/micheal/sese_app/functions/src/trips.ts)
- Update `createTrip` to save `allow_bidding` and `allowBidding` fields.
- Update `submitBid` to validate `allow_bidding !== false` and reject bids on fixed-price orders.

#### [NEW/MODIFY] [stacked_dispatch.test.ts](file:///Users/micheal/sese_app/functions/src/test/stacked_dispatch.test.ts)
- Add unit test verifying that `submitBid` rejects driver counter-offers when `allow_bidding: false`.

---

## Verification Plan

### Automated Test & Analysis Execution
- Run `npm test` in `functions/` to verify all backend unit tests pass.
- Run `flutter analyze` across `sese_ride`, `sese_core`, `sese_hub`.
- Run `flutter test` in `sese_core` and `sese_ride`.

### Deployment Pipeline
- Deploy backend functions and security rules via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `feat: implement per-trip bidding toggle and fixed-fare backend enforcement`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
