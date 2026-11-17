# Firestore Security Rules Hardening (`firestore.rules`)

Update `firestore.rules` to eliminate data manipulation vulnerabilities across `calls`, `card_verifications`, `quick_orders`, `orders`, and `drivers/{driverId}/telemetry`.

## User Review Required

> [!IMPORTANT]
> - **Calls Field Whitelist**: Restrict updates on `calls/{callId}` to permitted signaling fields (`status`, `answer`, `offer`, timestamps) and ensure `callerId` remains immutable.
> - **Card Verification Control**: Remove client-side permission to self-set `card_verifications` status to `VERIFIED`. Status flips must be processed exclusively via backend Cloud Functions (`processCardVerificationCallback`).
> - **Quick Orders Field Whitelist**: Bound client updates on `quick_orders/{orderId}` to safe mutable fields (`status`, `assignedDriverId`, timestamps, cancellation fields, notes) while locking `driverId` (creator).
> - **Orders Completion Integrity**: Remove `COMPLETED` from the allowed status list in driver client updates on `orders/{orderId}`, forcing order completion through Cloud Functions.
> - **Suspension-Gated Telemetry**: Require `isNotSuspended()` on write rules for `drivers/{driverId}/telemetry/{telemetryId}`.

## Proposed Changes

### Firestore Security Rules (`firestore.rules`)

#### [MODIFY] [firestore.rules](file:///Users/micheal/sese_app/firestore.rules)

1. **`calls/{callId}`**:
   - Define `isValidCallUpdate()` helper checking affected keys (`['status', 'answer', 'offer', 'updatedAt', 'endedAt', 'connectedAt', 'rejectedAt', 'durationSeconds']`), valid status values, and immutable `callerId`.
   - Update `allow update:` to require `isCallParticipant()` and `isValidCallUpdate()`.

2. **`card_verifications/{verificationId}`**:
   - Update `allow update:` to restrict client updates, preventing card owners from self-setting status to `VERIFIED` or `FAILED` (reserved for Operations Admin or Cloud Functions Admin SDK).

3. **`quick_orders/{orderId}`**:
   - Define `isValidQuickOrderUpdate()` helper checking affected keys (`['status', 'assignedDriverId', 'acceptedAt', 'updatedAt', 'completedAt', 'cancelledAt', 'cancellationReason', 'notes']`), immutable `driverId`, and valid status values.
   - Update `allow update:` to enforce `isValidQuickOrderUpdate()`.

4. **`orders/{orderId}`**:
   - Update driver update rule to allow status transitions in `['ARRIVED', 'PICKED_UP', 'IN_TRANSIT']`, explicitly excluding `COMPLETED` from client writes.

5. **`drivers/{driverId}/telemetry/{telemetryId}`**:
   - Update write rule from `allow read, write: if isOwner(driverId);` to `allow read: if isOwner(driverId); allow write: if isOwner(driverId) && isNotSuspended();`.

---

## Verification Plan

### Automated Dry-Run Validation
- Run `firebase deploy --only firestore:rules --dry-run` from `/Users/micheal/sese_app` to verify security rules syntax compilation.

### Full Pipeline Execution
- Execute mandatory build, test, deploy, and git synchronization pipeline.
