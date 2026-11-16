# Secure Cancellation Feedback User Attribution & Authentication

Fix the unauthenticated arbitrary user attribution vulnerability in `submitCancellationFeedback` located in `functions/src/trips.ts`.

## User Review Required

> [!IMPORTANT]
> - Previously, `submitCancellationFeedback` did not check `request.auth` and trusted `request.data.userId`. Any unauthenticated caller could submit feedback under arbitrary user IDs.
> - With this change:
>   - Requests without valid `request.auth` will throw `HttpsError('unauthenticated')`.
>   - `userId` will be derived directly from `request.auth.uid`. Any client-supplied `userId` parameter in `request.data` is ignored.

## Proposed Changes

### Firebase Cloud Functions (`functions/src`)

#### [MODIFY] [trips.ts](file:///Users/micheal/sese_app/functions/src/trips.ts#L4415-L4455)
- Add explicit authentication guard: `if (!request.auth) throw new HttpsError('unauthenticated', 'Authentication is required to submit cancellation feedback.');`.
- Derive `userId` strictly from `request.auth.uid`.
- Retain input sanitization and length validation on `tripId`, `role`, `reason`, and `detail`.
- Maintain compound document ID `${tripId}_${userId}` for idempotent first-write submission.

#### [MODIFY] [hub_security.test.ts](file:///Users/micheal/sese_app/functions/src/test/hub_security.test.ts)
- Add unit test cases for `submitCancellationFeedback`:
  - Rejecting unauthenticated calls.
  - Forcing `userId` to be caller's `auth.uid` even if a spoofed `userId` is supplied in `request.data`.

---

## Verification Plan

### Automated Tests
- Run `npm test` inside `/Users/micheal/sese_app/functions` to compile TypeScript and run unit tests.

### Manual Verification
- Verify TypeScript compilation using `npm run build` in `/Users/micheal/sese_app/functions`.
