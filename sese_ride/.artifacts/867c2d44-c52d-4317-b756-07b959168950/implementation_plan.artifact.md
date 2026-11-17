# Secrets Hygiene Overhaul, Key Rotation & Security Policy Enforcement

Establish zero-plaintext credential hygiene, rotate cryptographic secrets, document third-party provider key rotation instructions, and define a formal 90-day secrets rotation policy in `AGENTS.md` and `SECURITY.md`.

## User Review Required

> [!IMPORTANT]
> - **Third-Party Dashboard Key Rotation**:
>   - **Paystack (`PAYSTACK_API_KEY`)**: Log into Paystack Dashboard $\rightarrow$ Settings $\rightarrow$ API Keys & Webhooks $\rightarrow$ Revoke compromised `sk_test_...` key, generate fresh production secret key, and update `functions/.env`.
>   - **Google Maps (`GOOGLE_MAPS_API_KEY`)**: Log into Google Cloud Console $\rightarrow$ APIs & Services $\rightarrow$ Credentials $\rightarrow$ Rotate server key, restrict by API scope (Places, Directions, Geocoding), and update `functions/.env`.
>   - **Resend Email (`RESEND_API_KEY`)**: Log into Resend Dashboard $\rightarrow$ API Keys $\rightarrow$ Revoke old key, generate fresh key, and update `functions/.env`.
> - **Cryptographic Fare Secret Rotation**:
>   - Generate a fresh 256-bit cryptographically secure random hex secret for `FARE_SIGNING_SECRET` in `functions/.env`.
> - **GCP Secret Manager & 90-Day Rotation Policy**:
>   - Document mandatory 90-day secret rotation cadence in `AGENTS.md` and `SECURITY.md`.
>   - Document CLI instructions for binding `functions/.env` variables to Google Cloud Secret Manager (`firebase functions:secrets:set`).

## Proposed Changes

### Configuration & Documentation Files

#### [MODIFY] [functions/.env](file:///Users/micheal/sese_app/functions/.env)
- Rotate `FARE_SIGNING_SECRET` to a fresh 256-bit secure random hex string.
- Provide placeholder entries and instructions for refreshed Paystack, Google Maps, and Resend production API keys.

#### [NEW] [SECURITY.md](file:///Users/micheal/sese_app/SECURITY.md)
- Create formal security policy documenting secret management guidelines, GCP Secret Manager integration, 90-day rotation schedule, and incident response procedures.

#### [MODIFY] [AGENTS.md](file:///Users/micheal/sese_app/AGENTS.md)
- Append 2026-11-17 Decision Log entry for secrets hygiene, key rotation procedures, and GCP Secret Manager integration.

---

## Verification Plan

### Automated Build & Test Execution
- Run `npm run build` in `functions/` to compile TypeScript and generate `functions.yaml` manifest.
- Run `npm test` in `functions/` to verify all 142 unit tests pass cleanly with rotated secrets.

### Mandatory Pipeline Execution
- Run `flutter analyze` in `sese_ride`.
- Deploy backend via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `security: enforce secrets hygiene, rotate fare signing secret, and establish 90-day rotation policy`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
