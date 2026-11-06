# Secure Admin Onboarding Callables & OTP Exposure Fix

Fix security vulnerabilities in `functions/src/adminOnboarding.ts` by:
1. Gating all 4 callables (`lookupAccountForOnboarding`, `sendOnboardingOtp`, `verifyOnboardingOtp`, `adminRegisterUser`) on staff role + user management scope (`manageUsers` / `user_onboarding`).
2. Removing the exposed OTP (`devOtpHint`) from `sendOnboardingOtp` response.
3. Ensuring `createdByAdminId` is recorded purely as auditing data rather than an auto-approval flag.

## User Review Required

> [!IMPORTANT]
> - All four `adminOnboarding` functions will now require the caller to be an active staff member (`hub_staff/{email}`) with a Super/Admin role or holding an user management scope grant (`manageUsers`, `user_onboarding`, `manage_users`, `staff_manage`), or holding an Admin/SuperAdmin custom claim / owner email.
> - `sendOnboardingOtp` will no longer return `devOtpHint` in the HTTPS response. OTP codes will be logged on the server.
> - Accounts provisioned via `adminRegisterUser` will be created in `pending_verification` status rather than auto-verified, leaving `createdByAdminId` as auditing data so an independent admin must approve verification via `verification.ts` (enforcing Self-Verification Lock).

## Proposed Changes

### Firebase Functions

#### [MODIFY] [adminOnboarding.ts](file:///Users/micheal/sese_app/functions/src/adminOnboarding.ts)

- Add helper `assertStaffWithManageUsersScope(auth)` to verify that the caller is authenticated and holds staff role + user management permissions (`manageUsers`, `user_onboarding`, etc.).
- Update `lookupAccountForOnboarding`: replace simple `if (!request.auth)` check with `await assertStaffWithManageUsersScope(request.auth)`.
- Update `sendOnboardingOtp`:
  - Call `await assertStaffWithManageUsersScope(request.auth)`.
  - Remove `devOtpHint: otp` from the response body returned to the caller. Log dispatch on server instead.
- Update `verifyOnboardingOtp`:
  - Call `await assertStaffWithManageUsersScope(request.auth)`.
- Update `adminRegisterUser`:
  - Call `await assertStaffWithManageUsersScope(request.auth)`.
  - Provision user with `customerVerificationStatus: "pending_verification"` and `isVerifiedCustomer: false` (and do not grant `isVerified: true` claim at registration time).
  - Store `createdByAdminId` as audit data only.

## Verification Plan

### Automated Tests
- Build and compile TypeScript functions using `npm run build` in `/Users/micheal/sese_app/functions`.
- Run backend unit tests (`npm test`) in `/Users/micheal/sese_app/functions`.

### Manual Verification
- Verify that standard customer accounts calling `lookupAccountForOnboarding`, `sendOnboardingOtp`, `verifyOnboardingOtp`, or `adminRegisterUser` are rejected with `permission-denied`.
- Verify that staff accounts with user management scope pass the authorization checks.
- Verify that `sendOnboardingOtp` response does not contain `devOtpHint` or any raw OTP string.
