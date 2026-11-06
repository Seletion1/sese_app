/**
 * accountGuard.ts — Shared zero-trust account gates for Cloud Functions.
 *
 * Provides two guards that MUST be called at the top of every financial or
 * sensitive callable function before any business logic runs:
 *
 *   1. `enforceAppCheck(request)` — blocks calls that lack a valid Firebase
 *      App Check token. Prevents automated scripts, API scrapers, and
 *      side-loaded APKs from hitting callable endpoints directly.
 *
 *   2. `requireAccountActive(uid, role)` — asserts that the authenticated
 *      user's account is not suspended, banned, or deactivated. Users can be
 *      blocked at the Firestore-rules layer *and* here, so neither gate alone
 *      is a single point of failure.
 *
 * Usage pattern (every financial callable):
 * ```ts
 * export const myCallable = onCall(async (request) => {
 *   if (!request.auth) throw new HttpsError('unauthenticated', '...');
 *   enforceAppCheck(request);
 *   await requireAccountActive(request.auth.uid);
 *   // ... business logic
 * });
 * ```
 *
 * IMPORTANT: `enforceAppCheck` is a *synchronous* check on the already-
 * verified token that Firebase Functions attaches to `request.app`; it does
 * not make a network call. `requireAccountActive` does a Firestore read so
 * it must be awaited.
 */

import * as admin from "firebase-admin";
import { CallableRequest, HttpsError } from "firebase-functions/v2/https";

// ── App Check ────────────────────────────────────────────────────────────────

/**
 * Enforces Firebase App Check on the incoming callable request.
 *
 * App Check enforcement is ENABLED BY DEFAULT in all environments. Any
 * request without a verified App Check token is rejected with `unauthenticated`.
 *
 * To disable enforcement during local development or emulator runs, set
 * `DISABLE_APP_CHECK=true` in the environment.
 *
 * @param request - The `CallableRequest` received by the Cloud Function.
 * @throws {HttpsError} `unauthenticated` when App Check token is absent or invalid.
 */
export function enforceAppCheck(request: CallableRequest): void {
  const enforce = process.env.DISABLE_APP_CHECK !== "true";

  if (!enforce) {
    // Explicitly disabled for dev / emulator convenience.
    if (!request.app) {
      console.warn(
        "[accountGuard] App Check enforcement explicitly disabled (DISABLE_APP_CHECK=true). " +
          "App Check token missing for request."
      );
    }
    return;
  }

  // Hard gate by default.
  if (!request.app) {
    throw new HttpsError(
      "unauthenticated",
      "Request is missing a valid App Check token. " +
        "Only genuine SeseRide app builds are allowed to call this endpoint."
    );
  }
  // `request.app` is populated by the Firebase Functions SDK only when the
  // App Check JWT has been cryptographically verified server-side — no
  // additional verification step is needed here.
}

// ── Account suspension gate ───────────────────────────────────────────────────

type AccountRole = "customer" | "driver" | "any";

/**
 * Reads the caller's account record from Firestore and throws if the account
 * is suspended, banned, or deactivated, so that suspended users cannot bypass
 * Firestore security rules by calling Cloud Functions directly.
 *
 * Checks are performed against BOTH the `users/{uid}` document (customers and
 * shared profile) and the `drivers/{uid}` document when `role === 'driver'`.
 *
 * Status field aliases checked (in priority order):
 *   - `accountStatus`   — canonical field set by Hub ops actions
 *   - `status`          — legacy alias
 *   - `isSuspended`     — boolean flag written by admin actions
 *   - `isBanned`        — boolean flag for permanent bans
 *   - `isDeactivated`   — boolean flag for self-deactivation
 *
 * @param uid  - Firebase Auth UID of the caller.
 * @param role - Determines which Firestore collections to check.
 *   - `'customer'` → checks `users/{uid}` only.
 *   - `'driver'`   → checks `users/{uid}` AND `drivers/{uid}`.
 *   - `'any'`      → checks `users/{uid}` only (default).
 * @throws {HttpsError} `permission-denied` when the account is suspended/banned.
 */
export async function requireAccountActive(
  uid: string,
  role: AccountRole = "any"
): Promise<void> {
  const db = admin.firestore();

  // ── 1. Check universal user record ────────────────────────────────────────
  try {
    const userSnap = await db.collection("users").doc(uid).get();
    if (userSnap.exists) {
      _assertNotSuspended(userSnap.data() ?? {}, "account");
    }
  } catch (e) {
    if (e instanceof HttpsError) throw e;
    // Genuine Firestore infrastructure read failure: fail OPEN toward the user
    // (degraded mode) so a transient outage does not block all payments. Log loudly for ops.
    console.error(
      `[accountGuard] CRITICAL INFRA ERROR: users/${uid} read failed — failing open: ${e}`
    );
  }

  // ── 2. Additionally check driver record when role === 'driver' ────────────
  if (role === "driver") {
    try {
      const driverSnap = await db.collection("drivers").doc(uid).get();
      if (driverSnap.exists) {
        _assertNotSuspended(driverSnap.data() ?? {}, "driver account");
      }
    } catch (e) {
      if (e instanceof HttpsError) throw e;
      console.error(
        `[accountGuard] CRITICAL INFRA ERROR: drivers/${uid} read failed — failing open: ${e}`
      );
    }
  }
}

/**
 * Internal helper: inspects a Firestore document's data map for suspension
 * or ban signals and throws when any are present.
 *
 * @param data  - Firestore document data object.
 * @param label - Human-readable label for error messages ("account" / "driver account").
 * @throws {HttpsError} `permission-denied`
 */
function _assertNotSuspended(
  data: Record<string, unknown>,
  label: string
): void {
  // Boolean flag checks — takes priority for fast evaluation.
  if (data.isBanned === true) {
    throw new HttpsError(
      "permission-denied",
      `Your ${label} has been permanently banned. ` +
        "Contact support if you believe this is an error."
    );
  }
  if (data.isSuspended === true) {
    throw new HttpsError(
      "permission-denied",
      `Your ${label} is currently suspended. ` +
        "Contact support to resolve this."
    );
  }
  if (data.isDeactivated === true) {
    throw new HttpsError(
      "permission-denied",
      `Your ${label} has been deactivated. ` +
        "Please contact support to reactivate it."
    );
  }

  // String-status checks — canonical `accountStatus` field wins, then `status`.
  const rawStatus = String(
    data.accountStatus ?? data.status ?? ""
  ).toLowerCase().trim();

  const BLOCKED_STATUSES = new Set([
    "suspended",
    "banned",
    "deactivated",
    "disabled",
    "blocked",
    "inactive",
    "terminated",
  ]);

  if (rawStatus && BLOCKED_STATUSES.has(rawStatus)) {
    throw new HttpsError(
      "permission-denied",
      `Your ${label} is ${rawStatus}. ` +
        "Contact support if you believe this is an error."
    );
  }
}
