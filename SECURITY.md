# Security & Secrets Management Policy

This document establishes the security guidelines, secret rotation schedule, and incident response protocols for the **SeseRide** and **SeseHub** platforms.

---

## 1. Zero-Plaintext Credential Storage Guidelines

- **No Plaintext Secrets in Source Code**: Production API keys, private signing secrets, database credentials, and service account tokens must **NEVER** be committed to version control (`git`).
- **`.env` Exclusion**: Local environment files (`.env`, `functions/.env`, `key.properties`, `local.properties`, `*.jks`, `*.keystore`) are strictly git-ignored.
- **Client Key Isolation**: Mobile client binaries (`sese_ride`, `sese_hub`) carry ONLY app-restricted SDK render keys (such as Android Maps API keys restricted by package name and SHA-1 fingerprint). All web-services API keys (Directions, Geocoding, Places, Paystack, Resend) are restricted strictly to server-side Cloud Functions.

---

## 2. Mandatory 90-Day Secret Rotation Schedule

All production credentials and API keys must be rotated **every 90 days** or **immediately following any team/developer access changes**:

| Secret / Credential | Provider | Rotation Target / Location |
| --- | --- | --- |
| `PAYSTACK_API_KEY` | Paystack Dashboard | `functions/.env` / GCP Secret Manager |
| `GOOGLE_MAPS_API_KEY` | Google Cloud Console | `functions/.env` / GCP Secret Manager |
| `RESEND_API_KEY` | Resend Dashboard | `functions/.env` / GCP Secret Manager |
| `FARE_SIGNING_SECRET` | Node.js `crypto.randomBytes(32)` | `functions/.env` / GCP Secret Manager |
| Android Release Keystore | Local Offline Vault | `android/key.properties` |

---

## 3. Google Cloud Secret Manager Integration

Production secrets can be bound directly to Cloud Functions via Google Cloud Secret Manager, bypassing `.env` files entirely:

```bash
# Provision or update a secret in GCP Secret Manager
firebase functions:secrets:set PAYSTACK_API_KEY
firebase functions:secrets:set GOOGLE_MAPS_API_KEY
firebase functions:secrets:set FARE_SIGNING_SECRET

# Deploy functions using Secret Manager bindings
firebase deploy --only functions
```

---

## 4. Incident Response & Key Revocation Protocol

In the event of a suspected or confirmed credential leak:

1. **Immediate Revocation**: Log into the respective provider dashboard (Paystack, Google Cloud, Resend) and revoke the compromised API key.
2. **Key Generation**: Generate a fresh production key pair with strict scope restrictions.
3. **Environment & Function Update**: Update `functions/.env` or Secret Manager and deploy backend functions immediately (`firebase deploy --only functions`).
4. **Git Scrubbing**: If a secret was accidentally committed to git history, use `git-filter-repo` to scrub the historical commit or force-push a sanitized history.

---

## 5. Architectural Security Regression Checks & Coding Standards

To preserve verified secure baselines across refactoring and future feature development:

### A. Android Manifest Security Standards
- **`allowBackup="false"`**: Must remain explicitly set on `<application>` in `sese_ride/android/app/src/main/AndroidManifest.xml` and `sese_hub/android/app/src/main/AndroidManifest.xml` to prevent unauthorized ADB data extraction.
- **Service Export Lock (`exported="false"`)**: Sensitive background services (e.g., `OverlayService`) must maintain `android:exported="false"` so external malicious apps cannot invoke internal components.

### B. Webhook Cryptographic Verification Standard
- **Constant-Time HMAC Comparison**: All incoming HTTP webhook handlers (e.g. `paystackWebhook` in `payments.ts`) must require and verify cryptographic HMAC signatures using `crypto.timingSafeEqual` to prevent signature spoofing and timing side-channel attacks.

### C. Build-Time Secret Injection Standards
- **Zero Hardcoding**: Server-side API keys, web-services Maps credentials, Resend tokens, and fare signing secrets must NEVER be written into Dart code or native Android/iOS manifests as string literals.
- **Proxy Architecture**: All third-party web-service requests must route through authorized Cloud Functions (`googleMapsProxy`, `sendTransactionalEmail`, etc.), preserving client key isolation.

### D. Security Boundaries Preservation
- **Firestore Security Rules**: Core rules (`trips`, `users`, `wallets`, `delivery_pins`, `hub_staff`, `system_config/*`) must enforce strict owner/staff/participant authorization and prevent direct client-side balance, debt, or verification status mutations.
- **Cloud Functions Middleware**: All money-moving or sensitive callable functions must execute `guardedOnCall` (`enforceAppCheck`), `requireAccountActive()`, and `assertHubStaffOrAdmin()` at the top of the function.
