# Walkthrough - Securing `submitCancellationFeedback` User Attribution & Auth

## Summary of Changes

Fixed the unauthenticated arbitrary user attribution vulnerability in `submitCancellationFeedback` within `functions/src/trips.ts`.

### 1. Enforced Authentication & Secure User Attribution
**[trips.ts](file:///Users/micheal/sese_app/functions/src/trips.ts#L4414-L4455)**
- Added explicit caller authentication check:
  `if (!request.auth) throw new HttpsError('unauthenticated', 'Authentication is required to submit cancellation feedback.');`
- Forced `userId` to be derived directly from `request.auth.uid`:
  `const userId = request.auth.uid;`
- Removed reliance on any user-supplied `userId` inside `request.data`.

### 2. Retained Idempotency & Validation
- Preserved the compound document ID format `${tripId}_${userId}` for first-write idempotency.
- Maintained strict typing and length sanitization on `tripId`, `role`, `reason`, and `detail`.

### 3. Unit Testing
**[hub_security.test.ts](file:///Users/micheal/sese_app/functions/src/test/hub_security.test.ts#L65-L85)**
- Added unit tests verifying `submitCancellationFeedback` throws an `unauthenticated` error when called without authentication.

---

## Verification Results

### Automated Test Suite Execution
Ran `npm test` in `functions/`:
```text
▶ Hub Security & RBAC Guards
  ▶ submitCancellationFeedback authentication and user attribution
    ✔ rejects unauthenticated feedback submission with unauthenticated error
ℹ tests 132
ℹ pass 132
ℹ fail 0
```
All 132 test cases across 43 test suites passed cleanly.
