# Implementation Task Checklist - Per-Trip Bidding Toggle & Fixed-Fare Enforcement

- [/] Add `allowBidding` field to `TripDraft`, `TripData`, and `TripModel` in `trip_models.dart`
- [/] Enforce `allow_bidding` in Cloud Functions `createTrip` and `submitBid` (`functions/src/trips.ts`)
- [/] Add unit test for fixed-fare bidding rejection in `functions/src/test/stacked_dispatch.test.ts`
- [/] Add "Allow Driver Bidding / Counter-Offers" switch on checkout sheet in `customer_dispatch_screen.dart`
- [/] Update driver cards (`order_card.dart`, `order_pool_sheet.dart`) for fixed-fare mode
- [/] Update customer live trip screen & bid overlay for fixed-fare searching status
- [ ] Run backend unit test suite (`npm test`)
- [ ] Run static code analysis (`flutter analyze`) across packages
- [ ] Execute mandatory build, test & Firebase deployment pipeline
- [ ] Create `walkthrough.artifact.md`
