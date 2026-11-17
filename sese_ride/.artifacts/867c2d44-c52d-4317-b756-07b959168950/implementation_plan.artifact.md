# Refactor Error Handling, Observability & Fail-Safe Logic in `accountGuard.ts` & `driverStatus.ts`

Refactor the error handling, logging severity, and fail-safe behavior in `accountGuard.ts` and `driverStatus.ts` to ensure structured Cloud Logging observability during infrastructure outages and enforce fail-closed status transitions for driver operations.

## User Review Required

> [!IMPORTANT]
> - **`accountGuard.ts` Observability**: Maintain the fail-open availability policy on `requireAccountActive` when Firestore reads fail, but format `CRITICAL INFRA ERROR` logs as structured JSON carrying `severity: "CRITICAL"` for Cloud Logging alerting.
> - **`driverStatus.ts` (`goOffline`) Fail-Closed Policy**: Refactor `goOffline` so that any Firestore read failure during active trip verification re-throws an `HttpsError('unavailable')` rather than silently swallowing the error and dropping the driver offline.
> - **`driverStatus.ts` (`goOnline`) Error Wrapping**: Refactor `goOnline` try/catch blocks (suspension check, profile/vehicle verification, active trip verification) so non-`HttpsError` read failures are logged and wrapped into `HttpsError('unavailable')` rather than silently swallowed.

## Proposed Changes

### Firebase Cloud Functions (`functions/src`)

#### [MODIFY] [accountGuard.ts](file:///Users/micheal/sese_app/functions/src/accountGuard.ts)
- In `requireAccountActive`: Format Firestore read failure error logs as JSON payloads with `severity: "CRITICAL"` for Cloud Logging metric filters.

#### [MODIFY] [driverStatus.ts](file:///Users/micheal/sese_app/functions/src/driverStatus.ts)
- In `goOffline`: Refactor `activeTrips` verification catch block to fail closed (`throw new HttpsError("unavailable", ...)`) on read failure.
- In `goOnline`: Refactor `try/catch` blocks for suspension check, profile/vehicle verification check, and active trip verification to catch non-`HttpsError` failures, log them, and throw `HttpsError("unavailable", ...)`.

---

## Verification Plan

### Automated Test Execution
- Run `npm test` inside `/Users/micheal/sese_app/functions` to compile TypeScript and run unit test suites.

### Deployment & Synchronization
- Run `npm run build` to regenerate `functions.yaml` and validate manifest.
- Deploy backend via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Execute full git add, commit, and push pipeline.
