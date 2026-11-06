# Walkthrough — Ratings Forgery Fixes (Hole A & Hole B)

Fixed two independent rating forgery vulnerabilities across Firestore Security Rules and Cloud Functions.

## Changes Made

### Firestore Security Rules

#### [firestore.rules](file:///Users/micheal/sese_app/firestore.rules#L743-L748)
- Removed redundant `|| request.auth.uid != null` clause under `match /ratings/{ratingId}` `allow create`.
- Strictly enforced `request.resource.data.raterId == request.auth.uid`.

```diff
 match /ratings/{ratingId} {
   allow read: if isAuthenticated();
   allow create: if isAuthenticated() && isNotSuspended() &&
-    (request.resource.data.raterId == request.auth.uid || request.auth.uid != null);
+    request.resource.data.raterId == request.auth.uid;
   allow update, delete: if isSuperAdmin();
 }
```

---

### Cloud Functions Backend

#### [trips.ts](file:///Users/micheal/sese_app/functions/src/trips.ts#L3320-L3365)
- Updated `submitTripRating` callable:
  1. Added `!request.auth` rejection throwing `HttpsError("unauthenticated", "User must be authenticated.")`.
  2. Overrode `raterId` with `request.auth.uid` (ignoring any client payload in `request.data.raterId`).
  3. Added Firestore lookup for `trips/{tripId}` to verify caller participation (`raterId === customerId` or `raterId === driverId`).
  4. Verified `ratedUserId` matches the opposite participant in the trip.
  5. Derived `isRatedUserDriver` strictly on the server (`isCallerCustomer`).

#### [trips.test.ts](file:///Users/micheal/sese_app/functions/src/test/trips.test.ts#L285-L350)
- Added new test suite `Trip Rating Security Invariants` testing:
  - Unauthenticated rejection
  - `raterId` forced to `auth.uid`
  - Non-participant rejection
  - Mismatched target user rejection
  - Valid customer-to-driver and driver-to-customer rating permissions

---

## Verification Results

### Automated Tests Passed

1. **Backend TypeScript Tests**:
   - Command: `npm test` inside `functions/`
   - Outcome: All 50 tests passed cleanly (including 6 new rating invariant tests).

2. **Flutter App Unit Tests**:
   - Command: `flutter test test/trip_rating_test.dart` inside `sese_ride/`
   - Outcome: All 3 tests passed.
