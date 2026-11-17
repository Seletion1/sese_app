# Refactor Cloud Functions onCall Handlers to Enforce Firebase App Check Globally

Refactor all Cloud Functions `onCall` handlers across `functions/src/` to use a unified `guardedOnCall` security wrapper, bringing App Check and zero-trust enforcement coverage to 100% (75/75 handlers).

## User Review Required

> [!IMPORTANT]
> - **Global Security Wrapper**: `guardedOnCall` will be defined in `accountGuard.ts`. It sets `{ enforceAppCheck: true }` in GCF options and executes `enforceAppCheck(request)` synchronously at runtime before any business logic executes.
> - **Explicit Bypass Rule**: An explicit `bypassAppCheckOnCall` function builder is provided for any function requiring an intentional bypass, making unprotected endpoints immediately visible during code audits.
> - **100% Coverage**: Every `onCall` export across 16 module files will be migrated to `guardedOnCall`.

## Proposed Changes

### Firebase Cloud Functions (`functions/src`)

#### [MODIFY] [accountGuard.ts](file:///Users/micheal/sese_app/functions/src/accountGuard.ts)
- Export `guardedOnCall` wrapper function enforcing `enforceAppCheck: true` and runtime `enforceAppCheck(request)` guard.
- Export `bypassAppCheckOnCall` wrapper for explicit bypass scenarios.

#### [MODIFY] [adminOnboarding.ts](file:///Users/micheal/sese_app/functions/src/adminOnboarding.ts)
- Migrate `lookupAccountForOnboarding`, `sendOnboardingOtp`, `verifyOnboardingOtp`, and `adminRegisterUser` to `guardedOnCall`.

#### [MODIFY] [broadcast.ts](file:///Users/micheal/sese_app/functions/src/broadcast.ts)
- Migrate `sendTargetedBroadcast` to `guardedOnCall`.

#### [MODIFY] [callTokens.ts](file:///Users/micheal/sese_app/functions/src/callTokens.ts)
- Migrate `getAgoraToken`, `recordCallDuration`, and `getZegoToken` to `guardedOnCall`.

#### [MODIFY] [deleteAccount.ts](file:///Users/micheal/sese_app/functions/src/deleteAccount.ts)
- Migrate `deleteAccount` to `guardedOnCall`.

#### [MODIFY] [driverStatus.ts](file:///Users/micheal/sese_app/functions/src/driverStatus.ts)
- Migrate `goOnline`, `goOffline`, and `hubSetDriverOnlineStatus` to `guardedOnCall`.

#### [MODIFY] [driverTripHistory.ts](file:///Users/micheal/sese_app/functions/src/driverTripHistory.ts)
- Migrate `backfillDriverTripHistory` to `guardedOnCall`.

#### [MODIFY] [email.ts](file:///Users/micheal/sese_app/functions/src/email.ts)
- Migrate `sendTransactionalEmail`, `sendEmailOtp`, and `verifyEmailOtp` to `guardedOnCall`.

#### [MODIFY] [googleMaps.ts](file:///Users/micheal/sese_app/functions/src/googleMaps.ts)
- Migrate `googleMapsProxy` to `guardedOnCall`.

#### [MODIFY] [hubBootstrap.ts](file:///Users/micheal/sese_app/functions/src/hubBootstrap.ts)
- Migrate `bootstrapHubOwner` to `guardedOnCall`.

#### [MODIFY] [index.ts](file:///Users/micheal/sese_app/functions/src/index.ts)
- Migrate `calculateFare` to `guardedOnCall`.

#### [MODIFY] [payments.ts](file:///Users/micheal/sese_app/functions/src/payments.ts)
- Migrate `initializePayment` and `verifyPayment` to `guardedOnCall`.

#### [MODIFY] [payouts.ts](file:///Users/micheal/sese_app/functions/src/payouts.ts)
- Migrate `paystackBanks`, `resolveBankAccount`, `verifyBankAccount`, `processWalletWithdrawal`, `approveWeeklyPayout`, and `approveAllWeeklyPayouts` to `guardedOnCall`.

#### [MODIFY] [transactionPin.ts](file:///Users/micheal/sese_app/functions/src/transactionPin.ts)
- Migrate `setTransactionPin`, `verifyTransactionPin`, and `resetTransactionPin` to `guardedOnCall`.

#### [MODIFY] [trips.ts](file:///Users/micheal/sese_app/functions/src/trips.ts)
- Migrate all trip callables (`createTrip`, `acceptTrip`, `declineTrip`, `updateDriverLocation`, `advanceTripStatus`, `cancelTrip`, `confirmCashCancellation`, `submitBid`, `rejectBid`, `acceptBid`, `increaseTripFare`, `reassignTrip`, `verifyDeliveryPin`, `skipDeliveryPin`, `recordDropoffArrival`, `requestDropoffApproval`, `respondDropoffApproval`, `cancelDropoffApprovalRequest`, `hubForceCompleteTrip`, `hubCancelRefundTrip`, `hubManualPinBypass`, `submitTripRating`, `submitCancellationFeedback`) to `guardedOnCall`.

#### [MODIFY] [uniqueIdentifiers.ts](file:///Users/micheal/sese_app/functions/src/uniqueIdentifiers.ts)
- Migrate `checkIdentifierAvailability`, `registerUser`, `updateProfile`, and `registerVehicle` to `guardedOnCall`.

#### [MODIFY] [verification.ts](file:///Users/micheal/sese_app/functions/src/verification.ts)
- Migrate `reviewCustomerVerification` and `reviewDriverVerification` to `guardedOnCall`.

---

## Verification Plan

### Static Analysis & Audit
- Run grep/audit script confirming every `onCall` in `functions/src/` is wrapped with `guardedOnCall` (or `bypassAppCheckOnCall`).

### Automated Test Execution
- Run `npm test` inside `/Users/micheal/sese_app/functions` to ensure all 137 unit tests pass.

### Deployment & Synchronization
- Run `npm run build` to regenerate `functions.yaml` and validate manifest.
- Deploy backend via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Execute full git add, commit, and push pipeline.
