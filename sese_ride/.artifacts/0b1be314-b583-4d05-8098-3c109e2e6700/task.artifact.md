# Delivery PIN Security Fix Tasks

- `[/]` Task 1: Clean plaintext `deliveryPin` strings from Cloud Functions `createTrip` in `functions/src/trips.ts`
- `[ ]` Task 2: Verify Firestore Security Rules for `delivery_pins/{tripId}`
- `[ ]` Task 3: Update `ActiveTrip` model and `LiveTripScreen` in `sese_ride` to stream PIN from `delivery_pins/{tripId}`
- `[ ]` Task 4: Update `sese_hub` admin console screens to read PIN securely from `delivery_pins/{tripId}`
- `[ ]` Task 5: Execute static analysis and run unit/widget test suites
- `[ ]` Task 6: Deploy updated functions & rules to Firebase and document results in `walkthrough.artifact.md`
