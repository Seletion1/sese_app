# Reconcile Cloud Functions Manifest (`functions.yaml`) & Automate Manifest Generation

Reconcile `functions/functions.yaml` with all active Cloud Function exports in `functions/src/index.ts`, automate manifest generation, and add CI/CD validation guards.

## User Review Required

> [!IMPORTANT]
> - **Manifest Drift Reconciled**: 10 active Cloud Functions were exported in `functions/src/index.ts` but missing from `functions/functions.yaml`:
>   - `recordDropoffArrival`, `requestDropoffApproval`, `respondDropoffApproval`, `cancelDropoffApprovalRequest`
>   - `getZegoToken`, `getAgoraToken`, `recordCallDuration`
>   - `approveWeeklyPayout`, `approveAllWeeklyPayouts`, `resetTransactionPin`
> - **Automated Generation**: A node script (`scripts/generate-manifest.js`) will mechanically generate `functions.yaml` directly from `lib/index.js` exports during `npm run build`.
> - **CI/CD Guard**: A validation script (`scripts/validate-manifest.js`) will fail the build if any exported function is missing from `functions.yaml`.

## Proposed Changes

### Firebase Cloud Functions (`functions/`)

#### [NEW] [generate-manifest.js](file:///Users/micheal/sese_app/functions/scripts/generate-manifest.js)
- Script that imports `lib/index.js`, extracts all exported endpoints with `__endpoint` properties, and writes a complete, normalized `functions.yaml`.

#### [NEW] [validate-manifest.js](file:///Users/micheal/sese_app/functions/scripts/validate-manifest.js)
- Script that validates `functions.yaml` against `lib/index.js` exports, exiting with code 1 if any endpoint is missing.

#### [MODIFY] [package.json](file:///Users/micheal/sese_app/functions/package.json)
- Update `build` script to: `"tsc && node scripts/generate-manifest.js && node scripts/validate-manifest.js"`.
- Add `"generate-manifest"` and `"validate-manifest"` scripts.

#### [MODIFY] [functions.yaml](file:///Users/micheal/sese_app/functions/functions.yaml)
- Regenerated manifest containing all 76 Cloud Function endpoints.

---

## Verification Plan

### Automated Build & Manifest Generation
- Run `npm run build` inside `/Users/micheal/sese_app/functions` to compile TypeScript, generate `functions.yaml`, and validate all 76 endpoints.

### Deployment & Active Function Listing
- Deploy functions using `firebase deploy --only functions`.
- Execute `firebase functions:list` to confirm all 76 endpoints are active and running on Cloud Functions.
- Run full mandatory build/test/git sync pipeline.
