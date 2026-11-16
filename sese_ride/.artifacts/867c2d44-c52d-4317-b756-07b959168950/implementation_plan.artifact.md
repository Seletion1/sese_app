# Fix Open Mail Relay & OTP Takeover Vulnerability in sendEmailOtp

Fix the open mail relay and OTP takeover vulnerability in `sendEmailOtp` located in `functions/src/email.ts`.

## User Review Required

> [!IMPORTANT]
> - **Recipient Email Pinning**: Previously, `sendEmailOtp` allowed callers to supply arbitrary email addresses in `request.data.email`, allowing open mail relay and OTP overwriting.
> - With this change:
>   - Recipient email is strictly pinned to `request.auth.token.email`.
>   - If `request.data.email` is provided and does not match `request.auth.token.email`, an immediate `HttpsError('invalid-argument', 'Email address must match your authenticated profile.')` is thrown.
> - **UID-Namespaced Storage**: OTP documents in `email_otps` will be stored under `email_otps/{uid}` rather than raw email (`email_otps/{email}`), preventing cross-account OTP overwriting.
> - **App Check & Throttling**: App Check (`enforceAppCheck(request)`) and per-UID rate limiting (`checkEmailOtpRateLimit(uid)`, max 3 requests/min) will be enforced.

## Proposed Changes

### Firebase Cloud Functions (`functions/src`)

#### [MODIFY] [email.ts](file:///Users/micheal/sese_app/functions/src/email.ts)
- Implement `checkEmailOtpRateLimit(uid: string)` sliding window rate limiter.
- Update `sendEmailOtp`:
  - Enforce App Check (`enforceAppCheck(request)`) and active account check (`requireAccountActive(uid, "any")`).
  - Pin recipient email to `request.auth.token.email` and validate any `request.data.email` input against it.
  - Store OTP document in `email_otps/{uid}` instead of `email_otps/{email}`.
- Update `verifyEmailOtp`:
  - Delete `email_otps/{uid}` upon successful verification.

#### [NEW] [email_otp_security.test.ts](file:///Users/micheal/sese_app/functions/src/test/email_otp_security.test.ts)
- Add unit tests verifying:
  - Rejection when `request.data.email` mismatches `request.auth.token.email`.
  - Rate limiting enforcement after repeated OTP requests.
  - Verification and deletion of UID-namespaced `email_otps/{uid}` documents.

---

## Verification Plan

### Automated Tests
- Run `npm test` inside `/Users/micheal/sese_app/functions` to compile TypeScript and run unit test suites.

### Manual Verification
- Verify TypeScript compilation using `npm run build` in `/Users/micheal/sese_app/functions`.
