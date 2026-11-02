# Walkthrough: Real-Time Auth Retry & Error Sanitization for Fare Boosting

Fixed the `UNAUTHENTICATED` error string display and implemented automatic token refresh with single-shot retry for Cloud Functions calls.

## Root Cause & Solution

### 1. Raw API Error String Display Fixed
- **Root Cause**: `_mapError` previously returned `e.message` directly when present. For Cloud Functions HTTP 401 errors, `e.message` is raw `"UNAUTHENTICATED"`, which printed directly as red text under the input field.
- **Fix**: Re-sanitized `_mapError` for `unauthenticated` to always return user-friendly, grammatically complete sentences (`'Your session has expired. Please sign in again.'`).

### 2. Automatic Auth Retry Pattern (`_callWithAuthRetry`)
- **[trip_service.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/services/trip_service.dart)**:
  - Replaced manual pre-call token checks with `_callWithAuthRetry<T>()`.
  - Executes the Cloud Function call (`increaseTripFare`, `submitBid`, `acceptBid`, `keepSearchingTrip`).
  - If Cloud Functions returns an `unauthenticated` error (due to an expired 60-minute ID token), `_callWithAuthRetry` catches the error, calls `await user.getIdToken(true)` to exchange the refresh token with Google Auth servers, and automatically retries the callable once.
  - Transparently recovers from token expiration without failing or showing an error to the user!

---

## Verification Results

### Automated Tests
```bash
flutter test test/boost_fare_test.dart
```
**Result:**
```
01:03 +2: All tests passed!
```
