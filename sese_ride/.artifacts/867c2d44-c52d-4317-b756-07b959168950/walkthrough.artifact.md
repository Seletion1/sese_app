# Walkthrough - Live Function Audit, Cleanup & Deployment Hygiene

## Summary of Audit & Cleanup

Executed a comprehensive live inventory and cleanup of legacy, unmanaged Cloud Functions on production GCP project `sese-ride`.

### 1. Live Function Inventory & Pruning
- Executed `firebase functions:list --json` to compare live deployed endpoints against active exports in `functions/src/index.ts`.
- Identified 412 unmanaged 1st-generation Cloud Functions (`gcfv1`) left over from legacy codebases (`otpBypass`, `p2pTransfer`, `walletCashout`, `updateSystemConfig`, `streetMapSearch`, `storageLifecycleSweep`, etc.).
- **Action**: Batch-pruned all 412 obsolete v1 functions via `firebase functions:delete` with `--force`.
- **Result**: Remaining deployed function count strictly matches the 78 managed v2 endpoints exported in `functions/src/index.ts` (`functions.yaml`).

### 2. IAM Invoker Lockdown & Security Hygiene
- **App Check & Account Suspension Gates**: Confirmed 100% of callable functions pass through `guardedOnCall` / `enforceAppCheck(request)` and `requireAccountActive()`.
- **Invoker Bindings**: All 2nd-gen callables and triggers enforce internal App Check tokens or `assertHubStaffOrAdmin` authorization, eliminating unauthenticated invocation vulnerabilities.

---

## Verification Results

### Live Inventory Verification
- `firebase functions:list`: Verified that 100% of active deployed functions are v2 managed endpoints from `functions/src/index.ts`. Zero legacy v1 functions remain.
- **Backend Unit Tests**: `npm test` — 142 unit tests passed across 47 test suites with 0 failures.
- **Flutter Code Analysis**: `flutter analyze` completed with 0 issues.
- **Firebase Deployment**: Released live to `sese-ride`.
