# Walkthrough - Architectural Security Regression Checks & Coding Standards

## Summary of Implementation

Established permanent architectural security regression checks and coding standards across `SECURITY.md` and `AGENTS.md` to preserve verified secure baselines for Android manifests, webhooks, build-time secret injection, and Firestore security boundaries.

### 1. Section 5 in `SECURITY.md`
**[SECURITY.md](file:///Users/micheal/sese_app/SECURITY.md#L45-L80)**
- Added Section 5 detailing **Architectural Security Regression Checks & Coding Standards**:
  - **Android Manifest Security**: `android:allowBackup="false"` required on `<application>` in all manifests (`sese_ride` & `sese_hub`); `android:exported="false"` required on background services (`OverlayService`).
  - **Webhook Cryptographic Integrity**: All incoming HTTP webhook handlers (e.g. `paystackWebhook` in `payments.ts`) MUST require HMAC verification using `crypto.timingSafeEqual` and record idempotency ledgers (`wallet_ledger/{reference}`).
  - **Build-Time Secret Injection**: Prohibits plaintext hardcoding in client Dart code or native manifests; forces web-services keys through server proxies (`googleMapsProxy`).
  - **Security Boundaries**: Mandates preservation of strict Firestore security rules (`trips`, `users`, `wallets`, `delivery_pins`, `hub_staff`, `system_config/*`) and Cloud Functions auth gates (`guardedOnCall`, `requireAccountActive`, `assertHubStaffOrAdmin`).

### 2. Decision Log Entry in `AGENTS.md`
**[AGENTS.md](file:///Users/micheal/sese_app/AGENTS.md#L70-L85)**
- Appended a 2026-11-18 Decision Log entry documenting the establishment of permanent architectural security regression checks and coding standards.

---

## Verification Results

### Pipeline & Test Execution
- **Flutter Code Analysis (`flutter analyze`)**: Passed in `sese_ride` with 0 issues.
- **Backend Unit Tests (`npm test`)**: All 142 backend unit tests passed across 47 test suites with 0 failures.
- **Firebase Deployment**: All 78 Gen-2 Cloud Functions, Firestore rules, and Storage rules updated successfully live on `sese-ride`.
- **Git Sync**: Staged, committed, and pushed commit `950fb46` to `https://github.com/Seletion1/sese_app.git` on branch `main`.
