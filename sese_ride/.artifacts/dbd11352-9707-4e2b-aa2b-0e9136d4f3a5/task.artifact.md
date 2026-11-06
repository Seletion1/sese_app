# Tasks - Secure Admin Onboarding & OTP Exposure Fix

- `[x]` Implement RBAC gating and fix OTP exposure in `functions/src/adminOnboarding.ts`
  - `[x]` Add `assertStaffWithManageUsersScope` authorization helper
  - `[x]` Gate `lookupAccountForOnboarding`, `sendOnboardingOtp`, `verifyOnboardingOtp`, and `adminRegisterUser`
  - `[x]` Remove `devOtpHint` from `sendOnboardingOtp` response
  - `[x]` Ensure `adminRegisterUser` sets pending status and treats `createdByAdminId` purely as data
- `[x]` Build and test `functions`
- `[x]` Create walkthrough artifact
