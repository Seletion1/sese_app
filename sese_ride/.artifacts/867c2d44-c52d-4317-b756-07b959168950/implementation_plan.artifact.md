# Architectural Security Regression Checks & Coding Standards

Establish permanent architectural regression checks, linting rules, and security coding standards in `AGENTS.md` and `SECURITY.md` to preserve verified secure baselines across the repository.

## User Review Required

> [!IMPORTANT]
> - **1. Android Manifest Security Linters (`allowBackup="false"`, `exported="false"`)**:
>   - Add automated regression check rules to prevent `allowBackup` from being flipped to `true` and ensure sensitive services (`OverlayService`) maintain `exported="false"`.
> - **2. Webhook Cryptographic Verification Standard**:
>   - Mandate that all incoming HTTP webhooks (Paystack, etc.) require HMAC signature validation with `crypto.timingSafeEqual` comparison to prevent timing attacks.
> - **3. Build-Time Secret Injection Policy**:
>   - Enforce zero-hardcoding policy for API keys, Maps tokens, or service credentials in client Dart files or Android/iOS manifests. Credentials must ship via server proxies or build-time injection.
> - **4. Sound Security Boundaries**:
>   - Document strict preservation rules for Firestore security boundaries (`trips`, `users`, `wallets`, `delivery_pins`, `hub_staff`, `system_config/*`) and Cloud Functions auth gates (`guardedOnCall`, `requireAccountActive`, `assertHubStaffOrAdmin`).

## Proposed Changes

### Repository Guidelines & Security Standards

#### [MODIFY] [SECURITY.md](file:///Users/micheal/sese_app/SECURITY.md)
- Add Section 5: "Architectural Security Regression Checks & Coding Standards" specifying manifest security rules, webhook HMAC timing-safe validation, secret injection standards, and security boundary preservation.

#### [MODIFY] [AGENTS.md](file:///Users/micheal/sese_app/AGENTS.md)
- Append 2026-11-18 Decision Log entry documenting the establishment of permanent architectural security regression checks and coding standards.

---

## Verification Plan

### Automated Verification
- Run `flutter analyze` across `sese_ride`, `sese_hub`, and `sese_core` to confirm zero lint or analysis warnings.
- Run `npm test` in `functions/` to verify all 142 backend unit tests pass.

### Deployment Pipeline
- Execute mandatory build, test, and Firebase deployment pipeline.
