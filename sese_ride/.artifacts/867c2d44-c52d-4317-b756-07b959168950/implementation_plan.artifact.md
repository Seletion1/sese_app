# Dynamic Sequential Dispatch & 15s Timeout Tunables

Configure sequential single-driver dispatch to route to **1 driver by default** (`maxSequentialDrivers = 1`). If the driver rejects/skips or times out, escalate the order immediately to the Public Order Pool (`MARKETPLACE_OPEN`). Update incoming order response timeout and bidding request countdown to **15 seconds** by default, with dynamic Hub administration in `sese_hub`.

## User Review Required

> [!IMPORTANT]
> - **1. Route to 1 Driver at a Time Default (`maxSequentialDrivers = 1`)**:
>   - In `functions/src/trips.ts` and `sese_core`: Update sequential dispatch threshold default to `1`.
>   - After 1 driver rejects, skips, or times out, `advanceSequentialDispatch` immediately drops the order into the Public Order Pool (`MARKETPLACE_OPEN` / `dispatchStep = 4`) for all nearby drivers to claim.
>   - Expose `maxSequentialDrivers` in Hub Dispatch Console (`global_config_screen.dart`) so admins can adjust sequential driver attempts (1–10) dynamically without redeploying.
> - **2. Incoming Order Response Timeout (15 seconds)**:
>   - Set default incoming order response timeout (`tier1TimeoutSec` / `sequentialTimeoutSec`) to **15 seconds** (was 15s in client models; now enforced consistently as 15s across backend defaults, `sese_core`, and Hub controllers).
> - **3. Bidding Request Countdown Timeout (15 seconds)**:
>   - Set default bidding request countdown (`bidCountdownSec`) to **15 seconds** (updated from 10s in backend defaults to 15s across backend, `sese_core`, and Hub controllers).

## Proposed Changes

### Shared Core Package (`sese_core`)

#### [MODIFY] [dispatch_tuning.dart](file:///Users/micheal/sese_app/sese_core/lib/models/dispatch_tuning.dart)
- Update `maxSequentialDrivers` default to `1`, `tier1TimeoutSec` default to `15`, and `bidCountdownSec` default to `15` with `fromMap` / `toMap` serialization.

### Cloud Functions Backend (`functions/src`)

#### [MODIFY] [trips.ts](file:///Users/micheal/sese_app/functions/src/trips.ts)
- Add `maxSequentialDrivers` to `DispatchTuning` interface and `DEFAULT_TUNING` (default `1`).
- Update `getDispatchTuning()` to parse `maxSequentialDrivers` (default `1`), `tier1TimeoutSec` (default `15`), and `bidCountdownSec` (default `15`).
- Update `advanceSequentialDispatch` to check `currentStep >= tuning.maxSequentialDrivers || attempted.length >= tuning.maxSequentialDrivers`.

#### [MODIFY] [stacked_dispatch.test.ts](file:///Users/micheal/sese_app/functions/src/test/stacked_dispatch.test.ts)
- Update backend unit tests for 1-driver sequential dispatch escalation to Public Pool.

### Hub Portal (`sese_hub`)

#### [MODIFY] [global_config_screen.dart](file:///Users/micheal/sese_app/sese_hub/lib/features/config/presentation/global_config_screen.dart)
- Add `_maxSequentialDriversCtrl` (default `'1'`) input field in Section 7 - Sequential Dispatch Console allowing admins to dynamically adjust sequential driver attempts before Public Pool escalation.

---

## Verification Plan

### Automated Test & Analysis Execution
- Run `npm test` in `functions/` to verify backend unit tests pass.
- Run `flutter analyze` across `sese_core`, `sese_hub`, `sese_ride`.
- Run `flutter test` unit tests in `sese_core` and `sese_hub`.

### Deployment Pipeline
- Deploy backend functions and security rules via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `feat: update sequential dispatch to 1 driver default and 15s response/bidding timeouts with Hub controls`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
