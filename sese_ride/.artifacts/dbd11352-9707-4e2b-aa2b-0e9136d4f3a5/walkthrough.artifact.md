# Walkthrough - Secure Admin Onboarding & OTP Exposure Fix

The four callables in `functions/src/adminOnboarding.ts` have been secured with Role-Based Access Control (RBAC), OTP leakage via response payload has been eliminated, and account creation has been updated to treat `createdByAdminId` purely as audit data.

## Changes Made

### Firebase Functions

#### [adminOnboarding.ts](file:///Users/micheal/sese_app/functions/src/adminOnboarding.ts)

1. **Authorization Guard (`assertStaffWithManageUsersScope`)**:
   - Added helper enforcing that caller holds active Hub Staff status (`hub_staff/{email}` with `manageUsers`, `manage_users`, `user_onboarding`, or `staff_manage` scope, or `Super`/`Admin` role), custom claim Super/Admin, or primary owner email (`bamiduromichael2@gmail.com`).
   - Throws `HttpsError("permission-denied", ...)` if caller lacks authorization.
   - Applied to `lookupAccountForOnboarding`, `sendOnboardingOtp`, `verifyOnboardingOtp`, and `adminRegisterUser`.

2. **OTP Exposure Removal (`sendOnboardingOtp`)**:
   - Removed `devOtpHint` from the returned response object.
   - Dispatched OTP is logged server-side (`console.log`) without leaking to the client response body.

3. **Self-Verification Lock Alignment (`adminRegisterUser`)**:
   - Provisioned accounts set `customerVerificationStatus: "pending_verification"` and `isVerifiedCustomer: false` (and custom claim `isVerified: false`).
   - `createdByAdminId` is recorded on `users`, `drivers`, and `vehicles` documents purely as audit data.
   - Final approval requires independent admin review in `verification.ts` (where Self-Verification Lock prevents the creator from approving their own registered user).

## Verification Results

### Automated Tests
- Executed `npm run build` in `/Users/micheal/sese_app/functions` — TypeScript compilation succeeded with zero errors.
- Executed `npm test` in `/Users/micheal/sese_app/functions` — All 50 test suites passed cleanly.
