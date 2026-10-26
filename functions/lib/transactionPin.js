"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.verifyTransactionPin = exports.setTransactionPin = void 0;
exports.requireValidPin = requireValidPin;
exports.hasPinSet = hasPinSet;
const admin = __importStar(require("firebase-admin"));
const crypto = __importStar(require("crypto"));
const https_1 = require("firebase-functions/v2/https");
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
function sha256Hex(data) {
    return crypto.createHash("sha256").update(data, "utf8").digest("hex");
}
function randomSaltHex() {
    return crypto.randomBytes(16).toString("hex");
}
function hashPin(pin, salt) {
    return sha256Hex(`${salt}:${pin}`);
}
function assertPinShape(pin) {
    const p = String(pin !== null && pin !== void 0 ? pin : "").trim();
    if (!PIN_RE.test(p)) {
        throw new https_1.HttpsError("invalid-argument", "Transaction PIN must be exactly 4 digits.");
    }
    return p;
}
/**
 * Reads the server-side PIN record. Returns null when no PIN exists yet
 * (first-time JIT setup path).
 */
async function readPinRecord(uid) {
    var _a, _b, _c;
    for (const col of ["users", "drivers"]) {
        try {
            const snap = await db()
                .collection(col)
                .doc(uid)
                .collection("private")
                .doc("auth")
                .get();
            if (snap.exists) {
                const d = (_a = snap.data()) !== null && _a !== void 0 ? _a : {};
                const hash = String((_b = d.pinHash) !== null && _b !== void 0 ? _b : "");
                const salt = String((_c = d.pinSalt) !== null && _c !== void 0 ? _c : "");
                if (hash && salt)
                    return { hash, salt };
            }
        }
        catch (_) { }
    }
    return null;
}
/**
 * One-time silent migration: the legacy plaintext `securityPin` field
 * is hashed into the private record and the plaintext field DELETED. Runs
 * inside PIN verification so no user action is needed. Returns true when
 * a migration happened.
 */
async function migrateLegacyPin(uid) {
    var _a;
    for (const col of ["users", "drivers"]) {
        try {
            const ref = db().collection(col).doc(uid);
            const snap = await ref.get();
            const legacy = (_a = snap.data()) === null || _a === void 0 ? void 0 : _a.securityPin;
            if (typeof legacy === "string" && PIN_RE.test(legacy.trim())) {
                const salt = randomSaltHex();
                await ref
                    .collection("private")
                    .doc("auth")
                    .set({
                    pinHash: hashPin(legacy.trim(), salt),
                    pinSalt: salt,
                    migratedAt: admin.firestore.FieldValue.serverTimestamp(),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                }, { merge: true });
                await ref.update({
                    securityPin: admin.firestore.FieldValue.delete(),
                });
                return true;
            }
        }
        catch (_) { }
    }
    return false;
}
async function readPinLock(uid) {
    var _a, _b;
    for (const col of ["users", "drivers"]) {
        try {
            const snap = await db().collection(col).doc(uid).get();
            if (!snap.exists)
                continue;
            const raw = ((_b = (_a = snap.data()) === null || _a === void 0 ? void 0 : _a.pinLock) !== null && _b !== void 0 ? _b : {});
            return {
                failCount: typeof raw.failCount === "number" && Number.isFinite(raw.failCount)
                    ? Math.max(0, Math.floor(raw.failCount))
                    : 0,
                lockedUntilMs: typeof raw.lockedUntilMs === "number" && Number.isFinite(raw.lockedUntilMs)
                    ? raw.lockedUntilMs
                    : 0,
            };
        }
        catch (_) { }
    }
    return { failCount: 0, lockedUntilMs: 0 };
}
async function writePinLock(uid, lock) {
    for (const col of ["users", "drivers"]) {
        try {
            const ref = db().collection(col).doc(uid);
            const snap = await ref.get();
            if (snap.exists) {
                await ref.set({
                    pinLock: {
                        failCount: lock.failCount,
                        lockedUntilMs: lock.lockedUntilMs,
                    },
                }, { merge: true });
                return;
            }
        }
        catch (e) {
            console.warn(`transactionPin: pinLock write failed for ${col}/${uid}: ${e}`);
        }
    }
    try {
        await db().collection("users").doc(uid).set({
            pinLock: {
                failCount: lock.failCount,
                lockedUntilMs: lock.lockedUntilMs,
            },
        }, { merge: true });
    }
    catch (_) { }
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
async function requireValidPin(uid, pin) {
    await migrateLegacyPin(uid);
    const record = await readPinRecord(uid);
    if (record == null) {
        throw new https_1.HttpsError("failed-precondition", "No transaction PIN is set. Please create one first.");
    }
    const lock = await readPinLock(uid);
    if (lock.lockedUntilMs > Date.now()) {
        throw new https_1.HttpsError("resource-exhausted", "Too many wrong PIN attempts. Please wait a few minutes and try again.");
    }
    const p = assertPinShape(pin);
    const candidate = hashPin(p, record.salt);
    // Timing-safe comparison: equal-length hex digests, no early exit.
    const ok = candidate.length === record.hash.length &&
        crypto.timingSafeEqual(Buffer.from(candidate, "utf8"), Buffer.from(record.hash, "utf8"));
    if (!ok) {
        const fails = lock.failCount + 1;
        await writePinLock(uid, fails >= PIN_MAX_FAILS
            ? { failCount: 0, lockedUntilMs: Date.now() + PIN_LOCK_MS }
            : { failCount: fails, lockedUntilMs: 0 });
        throw new https_1.HttpsError("unauthenticated", "Incorrect transaction PIN.");
    }
    if (lock.failCount > 0) {
        await writePinLock(uid, { failCount: 0, lockedUntilMs: 0 });
    }
}
/** True when the account already has a server-side PIN (drives setup-vs-verify UI). */
async function hasPinSet(uid) {
    await migrateLegacyPin(uid);
    return (await readPinRecord(uid)) != null;
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
exports.setTransactionPin = (0, https_1.onCall)(async (request) => {
    var _a, _b;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const uid = request.auth.uid;
    const pin = assertPinShape((_a = request.data) === null || _a === void 0 ? void 0 : _a.pin);
    await migrateLegacyPin(uid);
    const existing = await readPinRecord(uid);
    if (existing != null) {
        // Knowledge-of-old gate: verify the CURRENT pin before replacing it.
        // Reuses the same lockout + timing-safe path as money authorization.
        await requireValidPin(uid, (_b = request.data) === null || _b === void 0 ? void 0 : _b.currentPin);
    }
    const salt = randomSaltHex();
    const pinData = {
        pinHash: hashPin(pin, salt),
        pinSalt: salt,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    let written = false;
    for (const col of ["users", "drivers"]) {
        const docRef = db().collection(col).doc(uid);
        const snap = await docRef.get();
        if (snap.exists) {
            await docRef.collection("private").doc("auth").set(pinData, { merge: true });
            written = true;
        }
    }
    if (!written) {
        await db()
            .collection("users")
            .doc(uid)
            .collection("private")
            .doc("auth")
            .set(pinData, { merge: true });
    }
    // A successful change clears any lockout from earlier guesses.
    await writePinLock(uid, { failCount: 0, lockedUntilMs: 0 });
    return { ok: true };
});
/**
 * Callable: explicit PIN check without moving money (used by the Security
 * PIN management screen and JIT sheets to give immediate wrong-PIN feedback
 * before the money callable runs — which re-verifies independently).
 */
exports.verifyTransactionPin = (0, https_1.onCall)(async (request) => {
    var _a;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    await requireValidPin(request.auth.uid, (_a = request.data) === null || _a === void 0 ? void 0 : _a.pin);
    return { ok: true };
});
//# sourceMappingURL=transactionPin.js.map