# Export & Secure `bootstrapHubOwner` Production Setup Function

Export `bootstrapHubOwner` in `functions/src/index.ts` and wrap it with strict, one-time security guards in `functions/src/hubBootstrap.ts` to prevent unauthorized re-triggering or privilege escalation after initial setup.

## User Review Required

> [!IMPORTANT]
> - **Option B Implementation**: `bootstrapHubOwner` is intended for production platform owner setup (`bamiduromichael2@gmail.com` or `bamiduromichael1@gmail.com` or `process.env.OWNER_EMAIL`).
> - **Security Guards Added**:
>   1. **Primary Owner Authorization**: Requires caller's email to match primary platform owner list (`isPlatformOwnerEmail`).
>   2. **One-Time / Secret Lock**: If the owner's `hub_staff` record already exists and is active with `role === "Super"` AND Firebase Auth claims already have `admin === true` and `role === "SUPER_ADMIN"`, re-triggering is blocked unless `process.env.ALLOW_REBOOTSTRAP === "true"` or a valid `bootstrapSecret` parameter is provided matching `process.env.BOOTSTRAP_SECRET`.
>   3. **Export Registration**: Export `bootstrapHubOwner` in `functions/src/index.ts` so it is registered in `functions.yaml` and deployed as an active Cloud Function endpoint.

## Proposed Changes

### Firebase Cloud Functions (`functions/src`)

#### [MODIFY] [hubBootstrap.ts](file:///Users/micheal/sese_app/functions/src/hubBootstrap.ts#L25-L65)
- Enhance `bootstrapHubOwner` with one-time setup protection and optional secret token validation (`BOOTSTRAP_SECRET` / `ALLOW_REBOOTSTRAP`).

#### [MODIFY] [index.ts](file:///Users/micheal/sese_app/functions/src/index.ts)
- Export `bootstrapHubOwner` from `./hubBootstrap`.

---

## Verification Plan

### Automated Build & Test Execution
- Run `npm run build` in `functions/` to compile TypeScript and generate `functions.yaml` with 77 endpoints.
- Run `npm test` inside `/Users/micheal/sese_app/functions` to verify unit test suite.

### Mandatory Deployment Pipeline
- Run `flutter analyze` in `sese_ride`.
- Deploy backend via `firebase deploy --only functions,firestore:rules,storage.rules`.
- Stage, commit with message `feat: export bootstrapHubOwner with one-time security guard`, and push to `https://github.com/Seletion1/sese_app.git` on branch `main`.
