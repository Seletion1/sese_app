import * as admin from "firebase-admin";
import * as crypto from "crypto";
import { onCall, HttpsError } from "firebase-functions/v2/https";

/**
 * Transaction Security PIN authority (zero-trust).
 *
 * HISTORY: the 4-digit wallet PIN used to live as PLAINTEXT in
 * `users/{uid}.securityPin`, compared with a client-side string equality
 * check. Any hostile client could skip the prompt entirely and call the
 * money endpoints directly — the "PIN" was theater, not a boundary.
 *
 * NOW: the PIN is SHA-256(salt + pin) hashed server-side and stored in
 * `users/{uid}/private/auth` (owner-read, server-write only — see
 * firestore.rules). Every money-moving callable (`transferWalletFunds`,
 * `processWalletWithdrawal`, `settleSplitPayment`) takes a `transactionPin`
 * and verifies it HERE, before any balance is read. No PIN, no money.
 *
 * The account password (Firebase Auth credential) and this PIN never share
 * storage, never share verification, and never overwrite each other: the
 * password lives in Firebase Auth, the PIN hash lives in Firestore.
 */

const db = () => admin.firestore();

/** PIN shape: exactly 4 digits. */
const PIN_RE = /^\d{4}$/;

/** 5 wrong tries lock the PIN for 15 minutes. */
const PIN_MAX_FAILS = 5;
const PIN_LOCK_MS = 15 * 60 * 1000;

function sha256Hex(data: string): string {
  return crypto.createHash("sha256").update(data, "utf8").digest("hex");
}

function randomSaltHex(): string {
  return crypto.randomBytes(16).toString("hex");
}

function hashPin(pin: string, salt: string): string {
  return sha256Hex(`${salt}:${pin}`);
}

function assertPinShape(pin: unknown): string {
  const p = String(pin ?? "").trim();
  if (!PIN_RE.test(p)) {
    throw new HttpsError(
      "invalid-argument",
      "Transaction PIN must be exactly 4 digits."
    );
  }
  return p;
}

interface PinRecord {
  hash: string;
  salt: string;
}

/**
 * Reads the server-side PIN record. Returns null when no PIN exists yet
 * (first-time JIT setup path).
 */
async function readPinRecord(uid: string): Promise<PinRecord | null> {
  const snap = await db()
    .collection("users")
    .doc(uid)
    .collection("private")
    .doc("auth")
    .get();
  if (!snap.exists) return null;
  const d = snap.data() ?? {};
  const hash = String(d.pinHash ?? "");
  const salt = String(d.pinSalt ?? "");
  if (!hash || !salt) return null;
  return { hash, salt };
}

/**
 * One-time silent migration: the legacy plaintext `users/{uid}.securityPin`
 * is hashed into the private record and the plaintext field DELETED. Runs
 * inside PIN verification so no user action is needed — the server already
 * holds the plaintext, so hashing it server-side loses nothing. Returns
 * true when a migration happened.
 */
async function migrateLegacyPin(uid: string): Promise<boolean> {
  const userRef = db().collection("users").doc(uid);
  const snap = await userRef.get();
  const legacy = snap.data()?.securityPin;
  if (typeof legacy !== "string" || !PIN_RE.test(legacy.trim())) return false;
  const salt = randomSaltHex();
  await db()
    .collection("users")
    .doc(uid)
    .collection("private")
    .doc("auth")
    .set(
      {
        pinHash: hashPin(legacy.trim(), salt),
        pinSalt: salt,
        migratedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  await userRef.update({
    securityPin: admin.firestore.FieldValue.delete(),
  });
  return true;
}

interface PinLock {
  failCount: number;
  lockedUntilMs: number;
}

async function readPinLock(uid: string): Promise<PinLock> {
  try {
    const snap = await db().collection("users").doc(uid).get();
    const raw = (snap.data()?.pinLock ?? {}) as Record<string, unknown>;
    return {
      failCount:
        typeof raw.failCount === "number" && Number.isFinite(raw.failCount)
          ? Math.max(0, Math.floor(raw.failCount))
          : 0,
      lockedUntilMs:
        typeof raw.lockedUntilMs === "number" && Number.isFinite(raw.lockedUntilMs)
          ? raw.lockedUntilMs
          : 0,
    };
  } catch {
    return { failCount: 0, lockedUntilMs: 0 };
  }
}

async function writePinLock(uid: string, lock: PinLock): Promise<void> {
  try {
    await db().collection("users").doc(uid).set(
      {
        pinLock: {
          failCount: lock.failCount,
          lockedUntilMs: lock.lockedUntilMs,
        },
      },
      { merge: true }
    );
  } catch (e) {
    console.warn(`transactionPin: pinLock write failed for ${uid}: ${e}`);
  }
}

/**
 * Core gate used by every money-moving callable. Throws user-safe
 * `HttpsError`s (`wrong-pin`, `locked`, `pin-not-set`); returns void on
 * success and resets the failure counter.
 *
 * Order: migrate legacy → lockout check → shape → compare. The failure
 * counter resets on success, so an attacker gets 5 guesses per 15 minutes
 * per account — brute-forcing a 4-digit space through the callable is
 * uneconomical, and each guess is attributable to the caller's uid.
 */
export async function requireValidPin(
  uid: string,
  pin: unknown
): Promise<void> {
  await migrateLegacyPin(uid);
  const record = await readPinRecord(uid);
  if (record == null) {
    throw new HttpsError(
      "failed-precondition",
      "No transaction PIN is set. Please create one first."
    );
  }
  const lock = await readPinLock(uid);
  if (lock.lockedUntilMs > Date.now()) {
    throw new HttpsError(
      "resource-exhausted",
      "Too many wrong PIN attempts. Please wait a few minutes and try again."
    );
  }
  const p = assertPinShape(pin);
  const candidate = hashPin(p, record.salt);
  // Timing-safe comparison: equal-length hex digests, no early exit.
  const ok =
    candidate.length === record.hash.length &&
    crypto.timingSafeEqual(
      Buffer.from(candidate, "utf8"),
      Buffer.from(record.hash, "utf8")
    );
  if (!ok) {
    const fails = lock.failCount + 1;
    await writePinLock(
      uid,
      fails >= PIN_MAX_FAILS
        ? { failCount: 0, lockedUntilMs: Date.now() + PIN_LOCK_MS }
        : { failCount: fails, lockedUntilMs: 0 }
    );
    throw new HttpsError("unauthenticated", "Incorrect transaction PIN.");
  }
  if (lock.failCount > 0) {
    await writePinLock(uid, { failCount: 0, lockedUntilMs: 0 });
  }
}

/** True when the account already has a server-side PIN (drives setup-vs-verify UI). */
export async function hasPinSet(uid: string): Promise<boolean> {
  await migrateLegacyPin(uid);
  return (await readPinRecord(uid)) != null;
}

interface SetPinData {
  pin?: string;
  currentPin?: string;
}

/**
 * Callable: create or change the transaction PIN.
 *
 * - No PIN on record (or legacy plaintext migrated away): `pin` alone sets
 *   it (JIT setup — the caller is already Firebase-authenticated).
 * - PIN exists: `currentPin` must verify first (knowledge-of-old), then
 *   `pin` replaces it. A changed PIN also clears any lockout.
 * - Setting a new PIN never touches the Firebase Auth password (or vice
 *   versa) — the two credentials are fully independent by construction:
 *   different storage (Firestore vs Auth), different verifiers.
 */
export const setTransactionPin = onCall<SetPinData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in.");
  }
  const uid = request.auth.uid;
  const pin = assertPinShape(request.data?.pin);

  await migrateLegacyPin(uid);
  const existing = await readPinRecord(uid);
  if (existing != null) {
    // Knowledge-of-old gate: verify the CURRENT pin before replacing it.
    // Reuses the same lockout + timing-safe path as money authorization.
    await requireValidPin(uid, request.data?.currentPin);
  }

  const salt = randomSaltHex();
  await db()
    .collection("users")
    .doc(uid)
    .collection("private")
    .doc("auth")
    .set(
      {
        pinHash: hashPin(pin, salt),
        pinSalt: salt,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  // A successful change clears any lockout from earlier guesses.
  await writePinLock(uid, { failCount: 0, lockedUntilMs: 0 });
  return { ok: true };
});

interface VerifyPinData {
  pin?: string;
}

/**
 * Callable: explicit PIN check without moving money (used by the Security
 * PIN management screen and JIT sheets to give immediate wrong-PIN feedback
 * before the money callable runs — which re-verifies independently).
 */
export const verifyTransactionPin = onCall<VerifyPinData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in.");
  }
  await requireValidPin(request.auth.uid, request.data?.pin);
  return { ok: true };
});
