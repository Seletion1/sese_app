# Fix End-to-End Fixed-Fare Bidding Lockdown

Ensure orders with bidding turned OFF by the customer (`allowBidding == false`) completely hide all bidding controls from the driver UI and reject any bid submission or bid-based assignment on the backend, ensuring fixed-fare orders are accepted and assigned exclusively at the main price.

## User Review Required

> [!IMPORTANT]
> - **1. Complete Driver UI Bidding Hiding (`allowBidding == false`)**:
>   - In `order_card.dart`: Hide the "Bid Fare" button completely when `widget.trip.allowBidding == false`. Render only the full-width "Accept (Fixed Fare)" button.
>   - In `order_pool_sheet.dart`: Remove counter-offer suggestion chips and custom bid pen controls from the widget tree when `widget.trip.allowBidding == false`. Display only the main fixed price and the "Accept" action button.
> - **2. Backend & Security Rule Enforcement (`functions/src/trips.ts`)**:
>   - In `submitBid`: Validate `allowBidding !== false && allow_bidding !== false`. Reject with `failed-precondition` error if bidding is disabled.
>   - In `acceptBid`: Validate `allowBidding !== false && allow_bidding !== false`. Reject with `failed-precondition` error if bidding is disabled.
> - **3. Customer Checkout & Active Trip UI Consistency**:
>   - `customer_dispatch_screen.dart`: "Allow Driver Bidding / Counter-Offers" switch tile on checkout sheet passes `allowBidding` to `TripDraft`.
>   - `live_trip_screen.dart`: Hides `_BidCarousel` and shows fixed-fare status ("Fixed-fare order: searching for nearby drivers...") when `allowBidding == false`.
>   - `customer_bid_overlay.dart`: Suppresses bid overlay when `allowBidding == false`.

## Proposed Changes

### Trip Models & Shared Core (`sese_ride`)

#### [MODIFY] [trip_models.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/models/trip_models.dart)
- Verify `allowBidding` field in `TripDraft`, `TripData`, and `ActiveTrip` defaults to `true` and is consistently serialized/deserialized as `allowBidding` and `allow_bidding`.

### Driver UI Controls (`sese_ride`)

#### [MODIFY] [order_card.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/driver/presentation/widgets/order_card.dart)
- Completely hide "Bid Fare" button when `trip.allowBidding == false`.
- Add guard in `_showBidDialog` returning immediately if `trip.allowBidding == false`.

#### [MODIFY] [order_pool_sheet.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/driver/presentation/widgets/order_pool_sheet.dart)
- Completely hide counter-offer suggestion pills and edit pen icon when `trip.allowBidding == false`.
- Add guard in `_submitBid` returning immediately if `trip.allowBidding == false`.

### Customer UI Controls (`sese_ride`)

#### [MODIFY] [live_trip_screen.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/presentation/live_trip_screen.dart)
- Conditionally render `_BidCarousel` only when `widget.trip.allowBidding == true`.

### Cloud Functions Backend (`functions/src`)

#### [MODIFY] [trips.ts](file:///Users/micheal/sese_app/functions/src/trips.ts)
- In `submitBid`: throw `failed-precondition` if `tripData.allowBidding === false || tripData.allow_bidding === false`.
- In `acceptBid`: throw `failed-precondition` if `tripData.allowBidding === false || tripData.allow_bidding === false`.

#### [MODIFY] [stacked_dispatch.test.ts](file:///Users/micheal/sese_app/functions/src/test/stacked_dispatch.test.ts)
- Add backend unit tests verifying bid submission and bid acceptance rejection on fixed-fare orders (`allow_bidding: false`).

---

## Verification Plan

### Automated Test Execution
- Run `npm test` in `functions/` to verify all backend unit tests pass.
- Run `flutter analyze` across `sese_ride`, `sese_core`, `sese_hub`.
- Run `flutter test` in `sese_core` and `sese_ride`.

### Deployment Pipeline
- Deploy backend functions and security rules via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `fix: enforce complete UI hiding and backend rejection for fixed-fare non-bidding orders`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
