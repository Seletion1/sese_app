# Walkthrough - KYC Self-Approval Fix

Added role gating (`assertHubStaffOrAdmin`) and self-verification locks to prevent regular users from reviewing or self-approving their own customer/driver KYC verification.

## Changes Made

### Cloud Functions

#### [verification.ts](file:///Users/micheal/sese_app/functions/src/verification.ts)

- **Added `assertHubStaffOrAdmin` helper**:
  - Checks if caller has custom claim `admin: true`, `adminAuth: true`, or `role` matching `SUPER_ADMIN`, `ROLE_SUPER_ADMIN`, `SUPER`, or `ADMIN`.
  - Checks if caller's email exists as an active record in `hub_staff/{email}` collection.
  - Throws `HttpsError("permission-denied")` if neither condition is satisfied.
- **Updated `reviewCustomerVerification`**:
  - Requires callers to pass `assertHubStaffOrAdmin`.
  - Throws `HttpsError("permission-denied")` when `userId === callerUid`.
- **Updated `reviewDriverVerification`**:
  - Requires callers to pass `assertHubStaffOrAdmin`.
  - Throws `HttpsError("permission-denied")` when `driverId === callerUid`.

```diff
+ async function assertHubStaffOrAdmin(
+   callerUid: string,
+   callerEmail: string,
+   token: Record<string, unknown>
+ ): Promise<void> { ... }

  export const reviewCustomerVerification = onCall<ReviewCustomerData>(
    async (request) => {
      if (!request.auth) {
        throw new HttpsError("unauthenticated", "Authentication required.");
      }

+     const callerUid = request.auth.uid;
+     const callerEmail = (request.auth.token?.email ?? "").trim().toLowerCase();
+     const token = request.auth.token ?? {};
+     await assertHubStaffOrAdmin(callerUid, callerEmail, token);

      const { userId, approved, rejectionReason } = request.data ?? {};
+     if (userId === callerUid) {
+       throw new HttpsError("permission-denied", "Self-Verification Lock: ...");
+     }
```

## Verification Results

### Automated Tests

- **TypeScript Compilation**: Executed `npm run build` in `functions/` — succeeded with 0 errors.
- **Backend Test Suite**: Executed `npm test` in `functions/` — 50 tests passed across 16 test suites with 0 failures.
