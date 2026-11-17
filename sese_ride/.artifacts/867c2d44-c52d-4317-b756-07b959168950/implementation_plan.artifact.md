# Restrict Read Access on `driver_status` Collection in `firestore.rules`

Restrict read access on `driver_status/{driverId}` to eliminate stalking and competitive intelligence location exposure.

## User Review Required

> [!IMPORTANT]
> - **Read Access Restriction**: Previously, `match /driver_status/{driverId}` allowed unconstrained read access for any authenticated user (`allow read: if isAuthenticated();`).
> - With this change, read access is restricted strictly to:
>   1. **The driver themselves**: `request.auth.uid == driverId` or `resource.data.driverId == request.auth.uid`.
>   2. **Hub Staff / Admins**: Authorized hub staff, operations admins, and support agents (`isHubStaff()`, `isAgent()`, `isAdminAuthClaim()`, `isOperationsAdmin()`, `isSuperAdmin()`).
>   3. **Assigned Active Trip Customer**: Rules-side lookup verifying that `resource.data.activeTripId` points to an active trip document where `customerId == request.auth.uid`.

## Proposed Changes

### Firestore Security Rules (`firestore.rules`)

#### [MODIFY] [firestore.rules](file:///Users/micheal/sese_app/firestore.rules#L1590-L1610)
- Update `match /driver_status/{driverId}` read rule to require caller authorization (self-driver, staff/admin, or active trip customer).
- Maintain `allow write: if false;` (server-managed online status written exclusively by Cloud Functions via Admin SDK).

---

## Verification Plan

### Automated Dry-Run Validation
- Run `firebase deploy --only firestore:rules --dry-run` from `/Users/micheal/sese_app` to verify security rules syntax compilation.

### Full Pipeline Execution
- Execute backend unit test suite (`npm test`).
- Execute mandatory build, test, deploy, and git synchronization pipeline.
