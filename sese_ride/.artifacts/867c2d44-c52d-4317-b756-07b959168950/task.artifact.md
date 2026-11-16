# Implementation Task Checklist - Email OTP Security Fix

- [/] Add email pinning to `request.auth.token.email`, App Check, UID rate limiting, and UID-namespaced OTP storage in `sendEmailOtp` (`functions/src/email.ts`)
- [ ] Add unit tests in `functions/src/test/email_otp_security.test.ts`
- [ ] Run `npm test` in `functions/`
- [ ] Run mandatory build, test & Firebase deployment pipeline
- [ ] Create `walkthrough.artifact.md`
