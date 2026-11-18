# Strict Smart-Dispatch & Stacked Order Proximity Rule

Implement smart-dispatch candidate filtering in Cloud Functions (`functions/src/trips.ts`) and dynamic Hub configuration (`system_settings/dispatch` & `sese_hub`) to exclude drivers with active trips from receiving new orders prematurely while permitting next-trip/stacked order assignments during the final drop-off approach phase under strict proximity and estimated time thresholds.

## User Review Required

> [!IMPORTANT]
> - **1. Active Trip Candidate Exclusion Rule**:
>   - By default, any online driver with an active trip in statuses `DRIVER_ACCEPTED`, `DRIVER_ARRIVING`, `DRIVER_ARRIVED`, or `pending_customer_approval` is strictly excluded from candidate matching (`findNearestDrivers`).
> - **2. Stacked Order Final Stage Allowance**:
>   - A driver with an active trip may ONLY be matched for a stacked order if:
>     1. `allowStackedOrders` is enabled in `system_settings/dispatch`.
>     2. Active trip status is `IN_PROGRESS` (en route to drop-off).
>     3. Driver's distance to active drop-off destination $\le \text{maxDistanceToDropoffKm}$ (default `2.0` km).
>     4. Driver's estimated remaining time to active drop-off is $\le \text{maxRemainingTimeMinutes}$ (default `10` minutes).
> - **3. Dynamic Hub Configurability**:
>   - Expose `allowStackedOrders` (`bool`, default `true`), `maxDistanceToDropoffKm` (`double`, default `2.0`), and `maxRemainingTimeMinutes` (`int`, default `10`) in `sese_core` `DispatchTuning` model and `sese_hub` `global_config_screen.dart` (Section 7 - Dispatch Console).
> - **4. Stacked Order Metadata & Logging**:
>   - When a stacked order is matched and assigned, attach metadata `isStackedOrder: true` and `priorTripId: <activeTripId>` to the newly assigned trip document for downstream routing and analytics.

## Proposed Changes

### Shared Flutter Core (`sese_core`)

#### [MODIFY] [dispatch_tuning.dart](file:///Users/micheal/sese_app/sese_core/lib/models/dispatch_tuning.dart)
- Add `allowStackedOrders` (bool, default `true`), `maxDistanceToDropoffKm` (double, default `2.0`), and `maxRemainingTimeMinutes` (int, default `10`) fields to `DispatchTuning` model with `fromMap` / `toMap` serialization.

### Cloud Functions Backend (`functions/src`)

#### [MODIFY] [trips.ts](file:///Users/micheal/sese_app/functions/src/trips.ts)
- Update `DispatchTuning` interface and `getDispatchTuning()` to read `allowStackedOrders`, `maxDistanceToDropoffKm`, and `maxRemainingTimeMinutes` from `system_settings/dispatch`.
- Update `findNearestDrivers`: query driver active trips; exclude active drivers by default; evaluate stacked order proximity criteria when status is `IN_PROGRESS`; attach `isStackedOrder` and `priorTripId` to matched candidates.
- Update `advanceSequentialDispatch` and `acceptTrip` to stamp `isStackedOrder: true` and `priorTripId` when assigning a stacked order.

### Hub Portal (`sese_hub`)

#### [MODIFY] [global_config_screen.dart](file:///Users/micheal/sese_app/sese_hub/lib/features/config/presentation/global_config_screen.dart)
- Add UI controls for `allowStackedOrders` toggle, `maxDistanceToDropoffKm`, and `maxRemainingTimeMinutes` input fields under Section 7 - Sequential Dispatch Console.

### Backend Unit Tests (`functions/src/test`)

#### [NEW] [stacked_dispatch.test.ts](file:///Users/micheal/sese_app/functions/src/test/stacked_dispatch.test.ts)
- Add comprehensive backend unit tests verifying active trip blocking, final stage stacked order allowance within 2km / 10min, out-of-range rejection, and stacked order metadata attachment.

---

## Verification Plan

### Automated Test Execution
- Run `npm test` in `functions/` to compile TypeScript and execute backend test suite including new stacked dispatch invariants.
- Run `flutter analyze` in `sese_core`, `sese_hub`, `sese_ride`.

### Deployment Pipeline
- Run `npm run build` in `functions/` to generate `functions.yaml` manifest.
- Deploy backend via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `feat: implement strict smart-dispatch active trip blocking and stacked order proximity rules`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
