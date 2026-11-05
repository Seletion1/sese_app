# Fix Delivery PIN Leakage & Enforce Zero-Trust OTP Security

## Overview
A critical security vulnerability was identified where the 4-digit delivery security PIN (`deliveryPin: pinCode`) was written directly onto the `trips/{tripId}` Firestore document in `functions/src/trips.ts`. Because drivers browsing the marketplace pool (`status == 'MARKETPLACE_OPEN'`) and assigned drivers have read permissions on `trips/{tripId}`, the proof-of-delivery OTP was fully visible to the driver who was supposed to be verified by it.

This fix moves the Delivery PIN code strictly to `delivery_pins/{tripId}`, strips all `deliveryPin` plaintext strings from `trips/{tripId}` payloads, and updates client and hub surfaces to read the PIN exclusively from `delivery_pins/{tripId}` (restricted to customer and authorized admin staff).

---

## User Review Required

> [!IMPORTANT]
> **Zero-Trust Security Guarantee**:
> 1. `trips/{tripId}` will contain ONLY boolean flags (`deliveryPinRequired`, `deliveryPinVerified`). Plaintext OTP strings (`deliveryPin`, `order.deliveryPin`) will be completely deleted from the trip document schema.
> 2. The assigned driver or marketplace pool drivers reading `trips/{tripId}` will NEVER be able to inspect the PIN string on the trip document.
> 3. The customer accesses their PIN via `delivery_pins/{tripId}`, where security rules permit read access strictly to the customer who owns the trip (`customerId == request.auth.uid`).
> 4. `verifyDeliveryPin` and `skipDeliveryPin` Cloud Functions continue to run server-side via Firebase Admin SDK with full zero-trust validation.

---

## Proposed Changes

### 1. Cloud Functions (`functions/src/trips.ts`)

#### [MODIFY] [trips.ts](file:///Users/micheal/sese_app/functions/src/trips.ts)
- Strip `deliveryPin: pinCode` from `tripDocPayload`.
- Strip `deliveryPin: pinCode` from `order` map in `tripDocPayload`.
- Ensure `deliveryPinRequired: isPinRequired` and `deliveryPinVerified: !isPinRequired` remain on `tripDocPayload` as booleans.
- Retain atomic document creation in `delivery_pins/{tripId}` (`{ tripId, customerId, pin: pinCode, verified: false, createdAt: ... }`).
- Retain customer FCM push/in-app notification (`notifyCustomer`) containing the OTP code.

---

### 2. Firestore Security Rules (`firestore.rules`)

#### [MODIFY] [firestore.rules](file:///Users/micheal/sese_app/firestore.rules)
- Verify `match /delivery_pins/{tripId}` enforces:
  - Read: allowed ONLY for Super Admin, Operations Admin, Hub Staff, or the authenticated customer (`customerId == request.auth.uid`).
  - Create/Update/Delete: strictly `false` (server-only write via Admin SDK).

---

### 3. Shared Models & Customer App (`sese_ride`)

#### [MODIFY] [trip_models.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/models/trip_models.dart)
- Remove `deliveryPin` string parsing from `ActiveTrip.fromMap` (or return null).
- Preserve `deliveryPinRequired` and `deliveryPinVerified` boolean getters/properties.

#### [MODIFY] [live_trip_screen.dart](file:///Users/micheal/sese_app/sese_ride/lib/features/trips/presentation/live_trip_screen.dart)
- Update `_AcceptedDriverSheet` / `_DeliveryPinBanner` trigger:
  - When `widget.trip.deliveryPinRequired && !widget.trip.deliveryPinVerified`, subscribe to `delivery_pins/{tripId}` document via `StreamBuilder<DocumentSnapshot>`.
  - Extract `doc.data()?['pin']` from `delivery_pins/{tripId}` and pass it to `_DeliveryPinBanner(pin: pin)`.

---

### 4. Admin Portal (`sese_hub`)

#### [MODIFY] [active_rides_console_screen.dart](file:///Users/micheal/sese_app/sese_hub/lib/features/trips/presentation/active_rides_console_screen.dart)
- Update the inspector modal to query `delivery_pins/{tripId}` when `requirePin` is true, displaying the security PIN from `delivery_pins/{tripId}` securely to authorized Hub staff.

#### [MODIFY] [customer_management_screen.dart](file:///Users/micheal/sese_app/sese_hub/lib/features/customers/presentation/customer_management_screen.dart)
- Remove reading `t['deliveryPin']` from `trips/{tripId}` map. Display status chip (`PIN REQ` / `VERIFIED`).

---

## Verification Plan

### Automated Tests
1. **Backend Compilation**: `cd functions && npm run build` (`tsc` clean compilation).
2. **Flutter Static Analysis**: `flutter analyze` across `sese_core`, `sese_ride`, and `sese_hub`.
3. **Flutter Unit & Widget Tests**:
   - `cd sese_ride && flutter test test/driver_active_trip_card_test.dart`
   - `cd sese_ride && flutter test test/live_trip_screen_test.dart` (or relevant test suites).

### Manual Verification
1. Verify `createTrip` payload written to Firestore `trips` collection contains NO `deliveryPin` or `order.deliveryPin` fields.
2. Verify `delivery_pins/{tripId}` contains the 4-digit code and is accessible ONLY to the trip customer and admin staff.
3. Verify driver app displays OTP prompt at drop-off requiring input, with ZERO access to the PIN on the trip payload.
