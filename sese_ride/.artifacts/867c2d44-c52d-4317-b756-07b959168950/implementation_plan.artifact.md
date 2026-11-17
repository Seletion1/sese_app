# Fix 7 Unit & Widget Test Failures in `sese_ride`

Resolve test harness failures across `places_autocomplete_test.dart`, `review_contact_phones_test.dart`, `live_trip_screen_test.dart`, and `widget_test.dart` to achieve 100% green test suite status.

## User Review Required

> [!IMPORTANT]
> - **`places_autocomplete_test.dart`**: Fix button finder in `places_autocomplete_test.dart` from `FilledButton` to `ElevatedButton` (or generic button finder) to avoid `Bad state: No element`.
> - **`review_contact_phones_test.dart`**:
>   - Multi-select broadcast: Replace `Checkbox` widget finder with `_VehicleTierTile` / tier key finders.
>   - Phone validation: Restore proper phone format validation in `customer_dispatch_screen.dart` (`_phonesValid` returning `isOptionalNigerianPhoneNumber(...)`) so malformed phone numbers correctly disable the Confirm button.
> - **`live_trip_screen_test.dart`**: Set `NetworkStatusService.instance.reachabilityChecker = () async => true;` in test setup to prevent `InternetAddress.lookup` from spawning uncompleted 2.5s timers.
> - **`widget_test.dart`**: Update `_pumpLogin` to use explicit `pump()` durations rather than `pumpAndSettle()`, preventing infinite animation / periodic timer timeouts.

## Proposed Changes

### `sese_ride/test` & `sese_ride/lib`

#### [MODIFY] [places_autocomplete_test.dart](file:///Users/micheal/sese_app/sese_ride/test/places_autocomplete_test.dart)
- Update Next button finder to match `ElevatedButton` or use generic text matching.

#### [MODIFY] [customer_dispatch_screen.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/customer/presentation/customer_dispatch_screen.dart)
- Restore `_phonesValid` calculation: `isOptionalNigerianPhoneNumber(p) && isOptionalNigerianPhoneNumber(d)`.

#### [MODIFY] [review_contact_phones_test.dart](file:///Users/micheal/sese_app/sese_ride/test/review_contact_phones_test.dart)
- Update tier tile selection finder from `find.byType(Checkbox)` to `_VehicleTierTile` / tile keys.

#### [MODIFY] [live_trip_screen_test.dart](file:///Users/micheal/sese_app/sese_ride/test/live_trip_screen_test.dart)
- Set `NetworkStatusService.instance.reachabilityChecker` in test setup.

#### [MODIFY] [widget_test.dart](file:///Users/micheal/sese_app/sese_ride/test/widget_test.dart)
- Update `_pumpLogin` to pump with bounded duration.

---

## Verification Plan

### Automated Test Execution
- Run `/Users/micheal/flutter/bin/flutter test` inside `sese_ride/` to verify all test suites pass with 0 failures.

### Mandatory Synchronization Pipeline
- Run `flutter analyze` in `sese_ride`.
- Run `npm run build` & `npm test` in `functions/`.
- Deploy backend via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `test: fix 7 widget and unit test failures in sese_ride`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
