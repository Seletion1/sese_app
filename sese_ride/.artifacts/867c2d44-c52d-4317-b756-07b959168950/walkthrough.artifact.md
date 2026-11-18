# Walkthrough - Per-Trip Bidding Toggle & Fixed-Fare Enforcement

## Summary of Implementation

Implemented a per-trip "Allow Driver Bidding / Counter-Offers" switch directly on the customer checkout screen in `sese_ride` (enabled by default), updated the Firestore `trips` schema (`allow_bidding: true/false`), and enforced fixed-fare broadcasting across Cloud Functions (`createTrip`, `submitBid`) and driver/customer UI surfaces.

### 1. Checkout Screen UI Switch (`sese_ride`)
**[customer_dispatch_screen.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/customer/presentation/customer_dispatch_screen.dart#L3590-L3625)**
- Added `_allowBidding` state variable initialized to `true`.
- Added an "Allow Driver Bidding / Counter-Offers" switch tile on the trip review / checkout sheet under the payment summary.
- Users can manually toggle it OFF if they want a fixed-fare order.
- Passes `allowBidding: _allowBidding` to `TripDraft` when the customer confirms booking.

### 2. Schema & Models (`sese_ride` & Firestore)
**[trip_models.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/models/trip_models.dart)**
- Extended `TripDraft`, `TripData`, and `TripModel` with `allowBidding` (default: `true`).
- Serializes `allowBidding` and `allow_bidding` to the Firestore `trips` document upon `createTrip`.

### 3. Backend & Matching Engine Enforcement (`functions/src`)
**[trips.ts](file:///Users/micheal/sese_app/functions/src/trips.ts#L1120-L1130)** & **[trips.ts](file:///Users/micheal/sese_app/functions/src/trips.ts#L3235-L3250)**
- **`createTrip`**: Stores `allowBidding` and `allow_bidding` on the created trip document.
- **`submitBid`**: Verifies `tripData.allowBidding !== false && tripData.allow_bidding !== false`. If `false`, throws `failed-precondition` error ("This trip is fixed-price only and does not accept driver counter-offers.").
- **[stacked_dispatch.test.ts](file:///Users/micheal/sese_app/functions/src/test/stacked_dispatch.test.ts#L55-L65)**: Added backend unit test verifying fixed-fare bidding rejection logic.

### 4. UI/UX Refinement across Driver and Customer Views
- **Driver Order Cards ([order_card.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/driver/presentation/widgets/order_card.dart#L730-L745) & [order_pool_sheet.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/driver/presentation/widgets/order_pool_sheet.dart#L950-L960))**:
  - When `trip.allowBidding == false`, hides the "Bid Fare" button and counter-offer slider, showing a single "Accept (Fixed Fare)" action button.
- **Customer Active Trip & Overlay ([live_trip_screen.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/presentation/live_trip_screen.dart#L2100-L2120) & [customer_bid_overlay.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/presentation/customer_bid_overlay.dart#L95-L105))**:
  - When `allowBidding == false`, displays fixed-fare searching status ("Fixed-fare order: searching for nearby drivers...") and suppresses the counter-offer overlay stream.

---

## Verification Results

### Automated Tests & Pipeline Execution
- **Backend Unit Tests (`npm test`)**: All 147 backend unit tests passed across 48 test suites with 0 failures (including the new fixed-fare bidding invariant test).
- **Flutter Code Analysis (`flutter analyze`)**: Passed cleanly across `sese_core`, `sese_hub`, and `sese_ride` with 0 issues.
- **Firebase Deployment**: All 77 Cloud Functions and Firestore security rules deployed successfully live on `sese-ride`.
- **Git Sync**: Staged, committed, and pushed commit `8152e03` to `https://github.com/Seletion1/sese_app.git` on branch `main`.
