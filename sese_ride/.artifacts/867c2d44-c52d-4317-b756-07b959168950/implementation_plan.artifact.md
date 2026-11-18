# Purge / Lock Down `bypassAppCheckOnCall` (`H-4`)

Purge/restrict `bypassAppCheckOnCall` in `functions/src/accountGuard.ts` with a hard production gate and strict environment check to eliminate potential App Check bypass vulnerabilities.

## User Review Required

> [!IMPORTANT]
> - **Production Guard & Purge**:
>   - In `functions/src/accountGuard.ts`: Hard-gate `bypassAppCheckOnCall` so that it throws an immediate `Error('App Check bypass is strictly disabled in production.')` in production environments (`NODE_ENV === 'production'`), ensuring 100% of callable functions enforce App Check via `guardedOnCall`.

## Proposed Changes

### Cloud Functions Security Core (`functions/src`)

#### [MODIFY] [accountGuard.ts](file:///Users/micheal/sese_app/functions/src/accountGuard.ts#L60-L75)
- Add hard production check in `bypassAppCheckOnCall` throwing an error when executed in production.

---

## Verification Plan

### Automated Test Execution
- Run `npm run build` in `functions/` to compile TypeScript and generate `functions.yaml` manifest.
- Run `npm test` in `functions/` to verify all 146 backend unit tests pass.

### Deployment Pipeline
- Run `flutter analyze` across `sese_ride`.
- Deploy backend via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `security: lock down bypassAppCheckOnCall with hard production block (H-4)`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
