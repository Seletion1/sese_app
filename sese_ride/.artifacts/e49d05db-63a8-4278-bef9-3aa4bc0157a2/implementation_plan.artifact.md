# Fix Ratings Forgery Vulnerabilities (Hole A & Hole B)

Fix two independent security holes allowing arbitrary rating forgery in Firestore security rules and Cloud Functions callables.

## User Review Required

> [!IMPORTANT]
> **Security Impact**:
> 1. **Hole A (`firestore.rules`)**: The condition `request.resource.data.raterId == request.auth.uid || request.auth.uid != null` allowed any authenticated user to forge rating documents as any other user/driver because `request.auth.uid != null` was always true.
> 2. **Hole B (`functions/src/trips.ts`)**: `submitTripRating` lacked an authentication check (`!request.auth`), allowed unauthenticated callers to pass `request.data.raterId`, and did not verify if the caller or target user were actual participants in the specified `tripId`.

## Proposed Changes

### Database Security Rules

#### [MODIFY] [firestore.rules](file:///Users/micheal/sese_app/firestore.rules)
- Update `match /ratings/{ratingId}` `allow create` rule:
  - Remove redundant `|| request.auth.uid != null` clause.
  - Strictly enforce `request.resource.data.raterId == request.auth.uid`.

```diff
     // Root-level post-trip ratings & reviews (driver rates customer, customer rates driver)
     match /ratings/{ratingId} {
       allow read: if isAuthenticated();
       allow create: if isAuthenticated() && isNotSuspended() &&
-        (request.resource.data.raterId == request.auth.uid || request.auth.uid != null);
+        request.resource.data.raterId == request.auth.uid;
       allow update, delete: if isSuperAdmin();
     }
```

---

### Backend Cloud Functions

#### [MODIFY] [trips.ts](file:///Users/micheal/sese_app/functions/src/trips.ts)
- Update `submitTripRating` callable:
  - Add explicit `!request.auth` check (throws `HttpsError("unauthenticated", "User must be authenticated.")`).
  - Derive `raterId` strictly from `request.auth.uid` (ignoring client-supplied `request.data.raterId`).
  - Fetch `trips/{tripId}` document to verify caller participation (`raterId === customerId` or `raterId === driverId`).
  - Verify that `ratedUserId` is the opposite participant in the trip (`customerId` if rater is driver, or `driverId` if rater is customer).
  - Throw `permission-denied` if caller is not a trip participant or if `ratedUserId` is invalid.

---

## Verification Plan

### Automated Tests
- Run existing Flutter unit tests in `sese_ride`:
  ```bash
  flutter test test/trip_rating_test.dart
  ```
- Run Node backend unit tests in `functions`:
  ```bash
  cd /Users/micheal/sese_app/functions && npm test
  ```

### Manual Verification
1. Verify Firestore security rules syntax in `firestore.rules`.
2. Inspect `submitTripRating` in `functions/src/trips.ts` for strict input validation, authentication enforcement, and participant verification.
