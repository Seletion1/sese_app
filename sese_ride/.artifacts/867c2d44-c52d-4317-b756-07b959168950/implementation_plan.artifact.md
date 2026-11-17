# Deployment Manifest (`functions.yaml`) Specification & Regeneration

Update `functions/scripts/generate-manifest.js` and regenerate `functions/functions.yaml` to ensure 100% Gen-2 deployment spec alignment and manifest validation across all 78 endpoints.

## User Review Required

> [!IMPORTANT]
> - **Gen-2 Manifest Generator Alignment**: Ensure `functions/scripts/generate-manifest.js` structures `functions.yaml` with the canonical `specVersion: "v1alpha1"` required by Firebase CLI v15.30+ for Gen-2 (`gcfv2`) Cloud Functions.
> - **Manifest Regeneration & Validation**: Run `npm run build` to execute `tsc`, `generate-manifest.js`, and `validate-manifest.js`, confirming all 78 exported Cloud Functions endpoints are present with Gen-2 metadata.

## Proposed Changes

### Firebase Cloud Functions Build Scripts

#### [MODIFY] [generate-manifest.js](file:///Users/micheal/sese_app/functions/scripts/generate-manifest.js)
- Ensure manifest generator formats `specVersion` and `endpoints` metadata matching Firebase CLI Gen-2 deployment standards.

---

## Verification Plan

### Automated Manifest Validation
- Run `npm run build` in `functions/` to generate and validate `functions.yaml`.
- Run `npm test` in `functions/` to verify backend unit test suite.

### Mandatory Pipeline Execution
- Run `flutter analyze` in `sese_ride`.
- Deploy backend via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `build: align functions.yaml manifest generator with Gen-2 deployment standards`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
