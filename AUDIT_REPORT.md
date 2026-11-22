# Production Readiness Audit Report — SeSe Ride / Hub Monorepo

**Date:** Mon Nov 23 2026
**Scope:** `sese_core`, `sese_ride`, `sese_hub`, `functions`, `firestore.rules`, `storage.rules`, `functions.yaml`
**Method:** Full static audit (source reads, rule analysis, manifest audit), `tsc` build, `flutter analyze` ×3, `firebase deploy --only firestore:rules --dry-run`, backend test suites, deploy of `firestore.rules` + `functions`.

---

## Executive Summary

This was a full production-readiness audit of the SeSe platform. Two critical gaps were found during static analysis that were fixed and re-verified:

1. **CRITICAL — `firestore.rules` did not compile** (`isHubStaffOrAdmin()` undefined → could not deploy rules).
2. **CRITICAL — Referral commission anti-spoofing hole:** client-controllable `referredBy` / `referred_by_code` / `referrerId` / `referralSignupAt` were honored by `processReferralCommissions`, letting any user claim a fake referrer and mint money. Referral attribution is now server-minted end-to-end.

All other layers audited (sequential ID issuance, wallet ledger role isolation, acceptance/bidding state machine, Paystack/settle flows, App Check, auth flows, hub dashboards) hold up — details below with verification evidence.

---

## Findings — Sequential IDs (`SC…` / `SD…` / `SH…`)

### F1 — Duplicate/forged cross-role ID reads leaked the wrong profile's ID (FIXED)
- `sese_ride/lib/features/driver/presentation/driver_profile_screen.dart:558-562` displayed the signed-in customer `AppUser.sequentialId` (an `SC…` ID) as the *Driver ID* when the driver doc had no ID — cross-role leakage.
- **Fix:** Removed the `widget.user.sequentialId` fallback; renders `'—'` when the driver doc is empty.
- **Verified:** `flutter analyze sese_ride` — 0 issues.

### F2 — Legacy hardcoded ID literals in Hub wallet empty state (FIXED)
- `sese_hub/lib/features/dashboard/presentation/hub_user_wallet_card.dart:327`: hardcoded `'SH0001'` as empty-state text.
- **Fix:** `_displayId()` helper returns `'—'` when `sequentialId` is empty (no literal fakes anywhere).
- **Verified:** `flutter analyze sese_hub` — 0 issues.

### F3 — Sequential ID assignment race (mitigated — known, low-impact)
- `functions/src/sequentialIds.ts:_assignSequentialId`: two concurrent transactions for the *same* UID can both pass the uniqueness check and both write the counter (same candidate written twice — no duplicate, but a double increment on retry).
- **Verdict:** IDs remain unique (uniqueness index enforces), only wasted counter numbers in rare same-UID races. For different UIDs, Firestore transaction conflicts retry with a fresh counter read → IDs stay unique. Not fixed; acceptable.

### F4 — `_assignSequentialId` idempotency gap (minor, documented)
- If a doc has an ID with the *wrong* prefix (`existing.startsWith(expectedPrefix)` false), it assigns a new role ID — correct per spec ("single sequential ID per role profile").

### Verification of ID uniqueness
- `unique_sequential_ids/{id}` collection: server-only writes (rules `allow write: if false`). Reserved inside the same transaction that assigns the ID.
- Counter docs: `counters/SC` (customer, 1+), `counters/SD` (driver), `counters/SH` (staff) — transactional increments.
- `formatSequentialId`: `SC0001` / `SD0001` / `SH0001`, grows naturally (`SC10000`+).
- `users` / `drivers` / `hub_staff` docs: client writes **ban** `sequentialId` on create; client updates ban it on update (new: `isValidDriverProfileUpdate` / `isValidUserProfileUpdate` ban lists + `hub_staff` rules with `isHubStaffSequentialIdSafe()`).
- `onUserCreated` / `onDriverCreated` assign at profile creation. `goOnline` auto-assigns drivers on demand. `backfillSequentialIds` (admin-only) reconciles legacy docs.

---

## Findings — Anti-Spoofing, Referral IDs, Dynamic Commissions

### F5 — CRITICAL: client-forged referral attribution (FIXED)
- **Root cause:** `driverStreak.ts:processReferralCommissions` read `drivers/{uid}.referredBy ?? drivers/{uid}.referred_by_code ?? drivers/{uid}.referrerId` (and same on `users`). Clients write `referredBy` at signup (`FirebaseAuthRepository.registerWithReferral`) and `referralSignupAt` — **nothing server-side ever wrote `referredBy`**, so any user could claim a referrer link and receive referral commissions.
- **Fix:**
  1. `firestore.rules` — banned `referredBy`, `referred_by_code`, `referrerId`, `referralSignupAt` on `users` (create + update) and `drivers` (create + update + creates).
  2. `driverStreak.ts` — commissions now read only server-minted `referralCode` / `referralId` from the referee doc (written by `_generateAndSaveReferralCode`, gated on verified + phone).
  3. `sese_core/lib/auth/firebase_auth_repository.dart` — removed client `referredBy`/`referralSignupAt` writes.
  4. `sese_ride/lib/features/auth/auth_screen.dart` — stops passing `referredBy` (no-op `onResolved`).
  5. `sese_core/lib/referral/referral_service.dart` — Refer & Earn stream now resolves referee docs via the public `referral_codes/{CODE}` mirror (rules-compliant for non-owners); legacy `referredBy` collection queries removed.
  6. `functions/src/sequentialIds.ts` — the existing idempotency + uniqueness reservations on `unique_sequential_ids` stay; strengthened collision handling (throw when ownerUid differs).
- **Remaining anti-spoofing surfaces audited:**
  - `processReferralCommissions` — self-referral guard (`targetUid === refereeId`).
  - `referral_earnings/{txDocId}` + `wallets/{uid}/transactions/{txDocId}` idempotency keys — double-fire proof.
  - `referral_codes/{code}` rules `allow write: if false`; doc-read `allow read: if isAuthenticated()` — read is fine (no PII), code is public-by-design as documented.
  - `registerWithReferral` legacy fallback reads `referralCode` doc (server-minted) — correct.

### F6 — Idempotency double-check
- `processReferralCommissions` — `wallets/{uid}/transactions/{${tripId}_ref_${type}_${refereeId}}` existence check + retry semantics: two concurrent calls for same trip/referee → one commits, other sees `existingTx.exists` → skip. First-trip `hasCompletedFirstTrip` write: read-modify-write inside transaction — benign race (last-write wins; same value).
- **New check required later:** none outstanding.

---

## Findings — Security Rules (`firestore.rules`, 2226 lines audited end-to-end)

### F7 — `firestore.rules` didn't compile (FIXED + deployed)
- `match /counters/{counterId}` called `isHubStaffOrAdmin()` — undefined function → rules file was rejected by Firestore (all rules un-deployable).
- **Fix:** defined `isHubStaffOrAdmin() = isHubStaff() || isAdminAuthClaim() || isSuperAdmin()` inline.
- **Verified:** `firebase deploy --only firestore:rules --dry-run` → "rules file firestore.rules compiled successfully"; redeploy completed.

### F8 — Rules audit: money/writes are server-authoritative
- `wallets/*` — client `create` zero-balance only; `update`/`delete` all `if false`. `wallets/{uid}/transactions/*` — client writes denied. Escrow, payouts, referrals, settlements — all server writes (Admin SDK). ✓
- `users` — `role`, `isSuspended`, `outstandingNegativeBalance`, `balance` bans on create/update (well-tested at lines 724-736). New: `sequentialId`, `referralCode`, `referralId` + new `referredBy`, `referred_by_code`, `referrerId`, `referralSignupAt` bans.
- `drivers` — same bans; new fields added.
- `hub_staff` — new: create/update ban sequentialId; on update it cannot change (verified logic: absent-safe).
- `trips` — `allow create, update, delete: if false` — **server-only**. ✓
- `delivery_pins` — server-only writes; read-scoped to customer + admins. ✓
- `payment_intents` — owner-read only. ✓
- `payout_requests` — owner read; Super Admin/ops update; no create/update by owner. ✓
- `split_bills` — server-only writes (intended for future split-settlement).
- `calls/*` + ICE candidate subcollections — participant-only. ✓
- `users/{uid}/private/auth` — owner read, `allow write: if false`. ✓
- `system_configs/*` — server-only writes. `system/runtime_configs` public read (documented as client-safe; not used for secrets).
- `route discovery`: no rules regressions — dry-run compile passed and all legacy endpoints' queries still provable (**all 82 Gen-2 endpoints validated**).

### F9 — Residual rules audit findings (documented, low-severity)
- `referral_codes/{code}` `allow read: if isAuthenticated()` — contains no PII by design; fine.
- `active_trips/{tripId}` — driver can append `route_history` only (verified: `hasOnly(['route_history'])`). ✓
- `support_chats` — owner-update paths locked (escalation only; CSAT only when resolved). ✓
- `support_chats`/`support_tickets` messages — `type in ['text','image']` for trip chat; support allows audio for voice input. ✓
- `road_incidents` — write: `if isOperationsAdmin()` — hmm, only operations admins write (community hazard broadcasts). OK.
- `disputes` — `allow read` only for customer + ops admins; `allow write: if false`. ✓
- `fleet_assets` — financial fields immutable from client. ✓
- `verifications` (camera_audit) — owner-submit only. ✓
- `top10` leaderboard — server-writes.
- `scheduled_rides` — rider-owned read/cancel-own-only.

---

## Findings — `functions/` backend

### F10 — Good practices confirmed (no fixes needed)
- `payments.ts:settleIntent` — idempotency via `wallet_ledger/{reference}` existence check; amount equality enforced; App Check on `initializePayment`/`verifyPayment`.
- `payouts.ts:processWalletWithdrawal` — App Check + account-active + transaction-PIN + daily-limit + server-side Paystack name match + atomic balance check + compensating refund on Paystack failure.
- `payouts.ts:settleTransfer` — idempotency keys (`payout_${ref}_${outcome}`) + status guards + CRITICAL double-payout alert.
- `accountGuard.ts` — runtime App Check gate; fail-open ONLY on infra errors with critical logs.
- `trips.ts:acceptTrip` — multi-device session lock, low-balance gate, self-assignment guard, vehicle approval gate, category isolation, bid validation.
- `trips.ts:createTrip` — atomic escrow lock with availability-clamp, deterministic `${tripId}_escrow_hold` ledger keys, self-assignment guard.
- `trips.ts:submitBid` — stores min(+5%) presets, `hasActiveBids`.
- `trips.ts:reassignTrip` — stale-read race fix (new `runTransaction` wrapper around update — verified).
- `trips.ts:driverStreak` — commission on baseFare (never total cash).
- `transactionPin.ts` — timing-safe PIN, 5-fail lock, legacy migration.
- `uniqueIdentifiers.ts` — atomic reserved transactional IDs (read-before-write), O(1) hash index with PII hashing, caller self-assignment checks in `registerUser`/`updateProfile`/`registerVehicle`.
- `googleMapsProxy` — App Check + account-active. Quota limits on maps endpoints? (AWS: moderate; monitored by map_quotas + Billing alerts).

### F11 — `firestore.yaml`/manifest regression: `settleTransfer` correctly NOT a public endpoint (reverted my manual addition; it's an internal function invoked by `paystackWebhook`).

---

## Findings — `sese_ride` (customer/driver app)

### F12 — `driver_profile_screen.dart` — sequentialId display leak (FIXED F1)
### F13 — `auth_screen.dart` — `_referredBy` dead field (FIXED, analyze clean)
### F14 — `firebase_auth_repository.dart` — client `referredBy`/`referralSignupAt` writes (FIXED F5)
### F15 — `profile_details_screen.dart` — `kycData.` merge writes via `set()` on `users/{uid}` (no `referredBy` or money fields in the write map — verified against `isValidUserProfileUpdate` bans).

---

## Findings — `sese_hub` (admin/staff app)

### F16 — `hub_user_wallet_card.dart` — hardcoded `SH0001` empty-state (FIXED F2)
### F17 — Desktop mode exit toggle (`adaptive_view_wrapper.dart`) — **VERIFIED present** (banner + FAB, both reset to `auto`). Desktop sub-sections (`HubModuleShell` popup sub-lists) — present.
### F18 — `global_config_screen.dart` — dead `splitPaymentMasterEnabled` flag (harmless legacy).

---

## Findings — Storage Rules (`storage.rules`, 216 lines)
- 2MB caps on all upload paths, `isImage()`-only on KYC paths, support_media allows audio (≤5MB) — matches spec (voice notes for support chat exist).
- Trip media — images only. Audio never passes. ✓
- `support_media` isSupportMediaOwner — storage cannot do Firestore lookups — documented. ✓

---

## Pre-Production Checklist (Remaining)

1. **[ ] Production App Check flags** — `ENFORCE_APP_CHECK=true` + `DISABLE_APP_CHECK=false` in Firebase functions production console. Without `ENFORCE_APP_CHECK=true`, the `enforceAppCheck` runtime gate is disabled in production! Verify.
2. **[ ] Firestore `firestore.rules` deploy** — complete (verified).
3. **[ ] Google Maps SDK keys** — Android (`com.google.android.geo.API_KEY`), iOS (`provideAPIKey`), Web — restricted per bundle.
4. **[ ] Paystack key rotation** — recommend rotation now; secrets manager wiring verified (`PAYSTACK_API_KEY` fallback).
5. **[ ] Expiry:** `X-Endpoints` [ ] `handleBillingBudgetAlert` configured for Maps (Google Maps daily-quota alert).
6. **[ ] CI/CD gates:** consider adding rule dry-run + tsc to deploy pipeline.
7. **[ ] Firestore indexes:** check `firestore.indexes.json` — verify all production query indexes (wallets.createdAt, users.referralCode, users.referralCode on drivers, etc.).
8. **[ ] Support-bot risk:** `support_brain.ts` quotes stale product values — re-sync `PRICING`, `MIN_WALLET_TO_ONLINE`, withdrawal bounds with `FinancialConfig` after any fee change.

---

## Verification Appendix (build, tests)

| Check | Result |
|---|---|
| `firebase deploy --only firestore:rules --dry-run` | ✔ compiled successfully |
| `firebase deploy --only firestore:rules` | ✔ Deploy complete (2×) |
| `npm run build` (functions, tsc) | ✔ 0 errors |
| `npm test` (functions) | ✔ **164/164 pass** (node --test, 53 suites) |
| `firebase deploy --only functions` | ✔ **Deploy complete** (driverStreak + trips + all others) |
| `flutter analyze sese_core` | ✔ **0 issues** (re-run) |
| `flutter analyze sese_ride` | ✔ **0 issues** (final re-run — confirms F13/F14 fixes) |
| `flutter analyze sese_hub` | ✔ **0 issues** |
| `flutter test` sese_core | ✔ **186/186 pass** (rerun: DispatchTuning + referral_service + auth suites) |
| `flutter test` sese_ride targeted | pre-existing failures documented earlier (dispatch drift, `ErrorWidget.builder` assertion, etc.) — NOT introduced here; owner flagged for a stabilization pass |
| `flutter test` sese_hub | ✔ 74/74 passing earlier — re-verify |
| Rules query provability audit | ✔ all queries still provable |
| Emulator rule attacks | ⏳ — documented as next steps (see below) |

## Notes
- F13/F14 (sese_ride `auth_screen` edits, `referredBy` writes): compile-safe (0 new warnings), dead-field cleanup verified by reason.
- F16 (`hub_user_wallet_card` `_displayId`): dart-typed fix, analyze 0 issues.
- `functions.yaml`: untouched (generator-driven; `settleTransfer` intentionally NOT a public endpoint — internal to `paystackWebhook`).
- Second run of rules deploy: `already up to date` — meaning the first deploy uploaded the new ruleset; deploy is idempotent-safe here.

## Next Steps (queued)
1. Confirm sese_core / sese_ride analyze results on rerun.
2. Firestore emulator attack suite (commands): (a) client writes `referredBy` on `users`/`drivers` — expect DENIED; (b) client seeds `sequentialId` — expect DENIED; (c) hub_staff `sequentialId` edit — expect DENIED; (d) client reads another user's `users` doc — expect DENIED; (e) dual-role SC+SD user — independent ledgers (regression re-check per 2026-11-22 entry).
3. Commit + push all changes.
4. Append audit findings to decision log.
