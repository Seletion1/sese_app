# Implementation Task Checklist - End-to-End Fixed-Fare Bidding Lockdown

- [/] Add guard and hide bidding controls in `order_card.dart` when `allowBidding == false`
- [/] Add guard and hide counter-offer pills in `order_pool_sheet.dart` when `allowBidding == false`
- [/] Conditionally render `_BidCarousel` in `live_trip_screen.dart` when `allowBidding == true`
- [/] Enforce fixed-fare bid rejection in `submitBid` and `acceptBid` in `functions/src/trips.ts`
- [/] Add unit tests in `functions/src/test/stacked_dispatch.test.ts`
- [ ] Run backend unit test suite (`npm test`)
- [ ] Run static code analysis (`flutter analyze`) across packages
- [ ] Run `flutter test` in `sese_core` and `sese_ride`
- [ ] Execute mandatory build, test & Firebase deployment pipeline
- [ ] Create `walkthrough.artifact.md`
