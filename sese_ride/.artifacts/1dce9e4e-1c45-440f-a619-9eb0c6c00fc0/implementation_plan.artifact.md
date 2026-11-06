# Implement Role Gating and Prevent Self-Verification for KYC Functions

Prevent unauthorized users and self-approvals from reviewing customer/driver KYC verification in Firebase Cloud Functions (`reviewCustomerVerification` and `reviewDriverVerification`).

## User Review Required

> [!IMPORTANT]
> - Users without admin custom claims (`admin: true`, `adminAuth: true`, or `SUPER_ADMIN`/`ADMIN` role) or an active record in the `hub_staff` Firestore collection will now be rejected with a `permission-denied` error when attempting to call `reviewCustomerVerification` or `reviewDriverVerification`.
> - Any caller attempting to verify their own account (`userId === callerUid` or `driverId === callerUid`) will be blocked with a `permission-denied` error regardless of their admin/staff status.

## Open Questions

None.

## Proposed Changes

### Cloud Functions (`functions/src`)

---

#### [MODIFY] [verification.ts](file:///Users/micheal/sese_app/functions/src/verification.ts)

- Add a helper function `assertHubStaffOrAdmin(callerUid: string, callerEmail: string, token: Record<string, unknown>)` to enforce authorization via admin custom claims or active `hub_staff/{email}` document lookup.
- Update `reviewCustomerVerification`:
  - Call `assertHubStaffOrAdmin` immediately after authentication check.
  - Check `userId === callerUid` and throw `HttpsError("permission-denied")` if a user attempts to review their own verification status.
- Update `reviewDriverVerification`:
  - Call `assertHubStaffOrAdmin` immediately after authentication check.
  - Check `driverId === callerUid` and throw `HttpsError("permission-denied")` if a user/driver attempts to review their own verification status.

## Verification Plan

### Automated Tests
- Run `npm run build` in `functions/` to ensure TypeScript compilation succeeds without errors.
- Run `npm test` in `functions/` to run existing backend matrix and unit tests.

### Manual Verification
- Verify that calling `reviewCustomerVerification` or `reviewDriverVerification` with non-admin auth throws `permission-denied`.
- Verify that calling `reviewCustomerVerification` or `reviewDriverVerification` targeting the caller's own `uid` throws `permission-denied`.
