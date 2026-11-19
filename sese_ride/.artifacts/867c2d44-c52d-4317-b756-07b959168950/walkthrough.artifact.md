# Walkthrough - 1 Driver Dispatch & 15s Timeout Tunables

## Summary of Implementation

Updated sequential single-driver dispatch to route to **1 driver by default** (`maxSequentialDrivers = 1`). If the driver rejects/skips or times out, the system escalates the order immediately to the Public Order Pool (`MARKETPLACE_OPEN` / `dispatchStep = 4`). Updated the default response timeout and bidding countdown to **15 seconds** across backend and client models, and exposed dynamic Hub controls in `sese_hub`.

### 1. 1-Driver Sequential Dispatch & Escalation to Pool (`functions/src/trips.ts`)
**[trips.ts](file:///Users/micheal/sese_app/functions/src/trips.ts#L60-L165)**
- Added `maxSequentialDrivers` to `DispatchTuning` interface and `DEFAULT_TUNING` (default `1`).
- Updated `getDispatchTuning()` to parse `maxSequentialDrivers` (default `1`, clamped 1–10).
- Updated `advanceSequentialDispatch`:
```ts
  const maxSeqLimit = tuning.maxSequentialDrivers ?? 1;
  if (currentStep >= maxSeqLimit || attempted.length >= maxSeqLimit) {
    await dropToPublicPool(tripRef);
    return false;
  }
```
- When a customer places an order, the system pings 1 nearest driver. If that driver declines, skips, or times out (after 15s), the order is sent straight to the Public Order Pool (`MARKETPLACE_OPEN`) for all drivers to see.

### 2. 15-Second Response & Bidding Countdown Timeouts
- **Incoming Order Response Timeout**: Set `tier1TimeoutSec` / `pingTimeoutMs` default to **15 seconds** (15,000 ms) in `DEFAULT_TUNING` and `getDispatchTuning()`.
- **Bidding Countdown Timeout**: Set `bidCountdownSec` / `bidCountdownMs` default to **15 seconds** (15,000 ms) in `DEFAULT_TUNING` and `getDispatchTuning()`.

### 3. Dynamic Hub Administration (`sese_hub`)
**[global_config_screen.dart](file:///Users/micheal/sese_app/sese_hub/lib/features/config/presentation/global_config_screen.dart#L2950-L2965)**
- Added `_maxSequentialDriversCtrl` input field under Section 7 - Sequential Dispatch Console:
  > **Sequential driver attempts**: Default 1 driver. Number of sequential driver pings before sending order to Public Pool.
- Admins can dynamically adjust sequential attempts (1–10), incoming order response timeout (5–120s), and bidding countdown (5–60s) directly from the Hub console without redeploying Cloud Functions.

### 4. Shared Core Models (`sese_core`)
**[dispatch_tuning.dart](file:///Users/micheal/sese_app/sese_core/lib/models/dispatch_tuning.dart#L10-L150)**
- Added `maxSequentialDrivers` (default `1`) to `DispatchTuning` with `fromMap` / `toMap` serialization.

---

## Verification Results

### Automated Tests & Pipeline Execution
- **Backend Unit Tests (`npm test`)**: All 147 backend unit tests passed across 48 test suites with 0 failures.
- **Flutter Code Analysis (`flutter analyze`)**: Passed cleanly across `sese_core`, `sese_hub`, and `sese_ride` with 0 issues (`No issues found!`).
- **Flutter Unit Tests (`flutter test`)**: All 153 tests in `sese_core` and 71 tests in `sese_hub` passed with 0 failures.
- **Firebase Deployment**: All 77 Cloud Functions and Firestore security rules deployed successfully live on `sese-ride`.
- **Git Sync**: Staged, committed, and pushed commit `b00660c` to `https://github.com/Seletion1/sese_app.git` on branch `main`.
