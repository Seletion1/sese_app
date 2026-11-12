"use strict";
/**
 * uniqueIdentifiers.ts — Strict Uniqueness Enforcement & Duplicate-Prevention Engine.
 *
 * Implements a server-side uniqueness index / lookup collection in Firestore
 * (`unique_identifiers/{identifierHash}`) to instantly verify uniqueness across
 * collections without performing costly, slow full-table scans.
 *
 * Supported sensitive identifier types:
 *   - phone: Customer, driver, and staff contact phone numbers
 *   - email: Gmail / Googlemail and standard email addresses (with dot & alias canonicalization)
 *   - nin: Nigerian National Identity Number (11 digits)
 *   - bvn: Nigerian Bank Verification Number (11 digits)
 *   - passport: International Passport numbers
 *   - plate_number: Vehicle and motorcycle license plate numbers
 *   - drivers_license: Official driver's license numbers
 *
 * Architecture:
 *   1. O(1) Key Lookup: Document ID is a deterministic SHA-256 hash of `type:normalized_value`.
 *      This guarantees privacy for sensitive PII (NIN/BVN never appear in cleartext keys/URLs).
 *   2. Zero-Trust Transactional Guarantees: All checks and reservation writes happen
 *      inside Firestore atomic transactions (`runTransaction`), strictly adhering to
 *      "all reads before all writes" ordering.
 *   3. Duplicate Rejection: Any attempt to register an already-bound identifier under a
 *      different user UID or vehicle immediately throws HttpsError('already-exists')
 *      with a human-friendly message.
 */
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
exports.registerVehicle = exports.updateProfile = exports.registerUser = exports.checkIdentifierAvailability = void 0;
exports.normalizeIdentifier = normalizeIdentifier;
exports.hashIdentifier = hashIdentifier;
exports.maskIdentifier = maskIdentifier;
exports.getConflictErrorMessage = getConflictErrorMessage;
exports.prepareIdentifiers = prepareIdentifiers;
exports.assertAndReserveIdentifiersTx = assertAndReserveIdentifiersTx;
const crypto = __importStar(require("crypto"));
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const accountGuard_1 = require("./accountGuard");
const verification_1 = require("./verification");
const db = () => admin.firestore();
// ── 1. Normalization & Hashing ───────────────────────────────────────────────
/**
 * Normalizes sensitive credentials into canonical comparable strings.
 *
 * - phone: E.164 international format without spaces/dashes (e.g., `080...` -> `+23480...`).
 * - email: Lowercase, trimmed. Gmail addresses have dots removed and `+alias` suffixes stripped.
 * - nin / bvn: Pure numeric digits.
 * - passport / plate_number / drivers_license: Uppercase alphanumeric with all symbols/spaces stripped.
 */
function normalizeIdentifier(type, raw) {
    if (!raw)
        return "";
    const trimmed = raw.trim();
    switch (type) {
        case "phone": {
            let cleaned = trimmed.replace(/[^\d+]/g, "");
            if (cleaned.startsWith("0") && cleaned.length >= 10) {
                cleaned = "+234" + cleaned.substring(1);
            }
            else if (cleaned.startsWith("234")) {
                cleaned = "+" + cleaned;
            }
            else if (!cleaned.startsWith("+") && cleaned.length > 0) {
                cleaned = "+" + cleaned;
            }
            return cleaned;
        }
        case "email": {
            const lower = trimmed.toLowerCase();
            const atIdx = lower.indexOf("@");
            if (atIdx === -1)
                return lower;
            const user = lower.substring(0, atIdx);
            const domain = lower.substring(atIdx + 1);
            if (domain === "gmail.com" || domain === "googlemail.com") {
                // Strip dots and remove +aliases before @ (e.g. m.bamiduro+ride -> mbamiduro)
                const cleanUser = user.replace(/\./g, "").split("+")[0];
                return `${cleanUser}@gmail.com`;
            }
            return `${user}@${domain}`;
        }
        case "nin":
        case "bvn":
            return trimmed.replace(/\D/g, "");
        case "passport":
        case "plate_number":
        case "drivers_license":
            return trimmed.toUpperCase().replace(/[^A-Z0-9]/g, "");
        default:
            return trimmed;
    }
}
/**
 * Computes deterministic SHA-256 hash for Firestore doc ID.
 */
function hashIdentifier(type, normalized) {
    return crypto
        .createHash("sha256")
        .update(`${type.toLowerCase()}:${normalized}`)
        .digest("hex");
}
/**
 * Produces safe masked representations for user-friendly error messages and audit logs.
 */
function maskIdentifier(type, value) {
    const norm = normalizeIdentifier(type, value);
    if (!norm)
        return "••••";
    switch (type) {
        case "phone": {
            if (norm.length > 6) {
                return norm.slice(0, 4) + "••••••" + norm.slice(-2);
            }
            return norm.slice(0, 2) + "••••";
        }
        case "email": {
            const atIdx = norm.indexOf("@");
            if (atIdx === -1)
                return "••••";
            const u = norm.substring(0, atIdx);
            const d = norm.substring(atIdx + 1);
            const maskedUser = u.length > 1 ? u[0] + "••••" : "••••";
            return `${maskedUser}@${d}`;
        }
        case "nin":
        case "bvn": {
            if (norm.length >= 4) {
                return "•••••••" + norm.slice(-4);
            }
            return "••••";
        }
        case "plate_number": {
            if (norm.length > 4) {
                return norm.slice(0, 3) + "•••" + norm.slice(-2);
            }
            return norm.slice(0, 2) + "•••";
        }
        case "passport":
        case "drivers_license": {
            if (norm.length > 4) {
                return norm.slice(0, 2) + "••••" + norm.slice(-2);
            }
            return norm.slice(0, 2) + "••••";
        }
        default:
            return "••••";
    }
}
/**
 * Formats a clean, descriptive HttpsError message for uniqueness conflicts.
 */
function getConflictErrorMessage(type, masked) {
    switch (type) {
        case "phone":
            return `The phone number (${masked}) is already registered to another account.`;
        case "email":
            return `The email address (${masked}) is already associated with an existing account.`;
        case "nin":
            return `The National Identity Number (NIN: ${masked}) is already registered under another account.`;
        case "bvn":
            return `The Bank Verification Number (BVN: ${masked}) is already registered under another account.`;
        case "passport":
            return `The International Passport number (${masked}) is already registered under another account.`;
        case "plate_number":
            return `The vehicle/motorcycle plate number (${masked}) is already registered to another vehicle in the system.`;
        case "drivers_license":
            return `The Driver's License number (${masked}) is already registered under another account.`;
        default:
            return `The credential (${masked}) is already registered to another account.`;
    }
}
/**
 * Prepares and deduplicates entries before checking against Firestore.
 */
function prepareIdentifiers(entries) {
    const result = [];
    const seenHashes = new Set();
    for (const entry of entries) {
        if (!entry.value || !entry.value.trim())
            continue;
        const normalized = normalizeIdentifier(entry.type, entry.value);
        if (!normalized)
            continue;
        const hash = hashIdentifier(entry.type, normalized);
        if (seenHashes.has(hash))
            continue;
        seenHashes.add(hash);
        result.push({
            type: entry.type,
            normalized,
            hash,
            masked: maskIdentifier(entry.type, normalized),
            ref: db().collection("unique_identifiers").doc(hash),
            entityId: entry.entityId,
        });
    }
    return result;
}
/**
 * Atomic Transaction Guard:
 * 1. Executes all reads for uniqueness lookup documents.
 * 2. Validates that no identifier is owned by a different user/entity.
 * 3. Queues transaction writes to register new unique mappings and clean up old ones.
 */
async function assertAndReserveIdentifiersTx(params) {
    var _a, _b, _c, _d, _e, _f, _g, _h;
    const { tx, ownerUid, ownerCollection, identifiers, oldIdentifiers = [] } = params;
    const prepared = prepareIdentifiers(identifiers);
    const oldPrepared = prepareIdentifiers(oldIdentifiers);
    // ── STEP 1: ALL READS FIRST ────────────────────────────────────────────────
    const snapshots = await Promise.all(prepared.map((p) => tx.get(p.ref)));
    // ── STEP 2: VERIFICATION & CONFLICT DETECTION ──────────────────────────────
    for (let i = 0; i < prepared.length; i++) {
        const p = prepared[i];
        const snap = snapshots[i];
        if (snap.exists) {
            const data = snap.data();
            const existingOwnerUid = String((_a = data.ownerUid) !== null && _a !== void 0 ? _a : "");
            const existingEntityId = String((_b = data.entityId) !== null && _b !== void 0 ? _b : "");
            if (existingOwnerUid && existingOwnerUid !== ownerUid) {
                throw new https_1.HttpsError("already-exists", getConflictErrorMessage(p.type, p.masked));
            }
            // Plate numbers must be unique across all vehicles even within the same driver fleet
            if (p.type === "plate_number") {
                const targetEntity = (_d = (_c = p.entityId) !== null && _c !== void 0 ? _c : params.entityId) !== null && _d !== void 0 ? _d : ownerUid;
                if (existingEntityId && existingEntityId !== targetEntity) {
                    throw new https_1.HttpsError("already-exists", getConflictErrorMessage(p.type, p.masked));
                }
            }
        }
    }
    // ── STEP 3: ALL WRITES AFTER READS ────────────────────────────────────────
    const now = admin.firestore.FieldValue.serverTimestamp();
    const newHashes = new Set(prepared.map((p) => p.hash));
    // Write new / updated entries
    for (let i = 0; i < prepared.length; i++) {
        const p = prepared[i];
        const snap = snapshots[i];
        const targetEntityId = (_f = (_e = p.entityId) !== null && _e !== void 0 ? _e : params.entityId) !== null && _f !== void 0 ? _f : ownerUid;
        tx.set(p.ref, {
            identifierHash: p.hash,
            identifierType: p.type,
            maskedValue: p.masked,
            ownerUid,
            ownerCollection,
            entityId: targetEntityId,
            updatedAt: now,
            createdAt: snap.exists ? ((_h = (_g = snap.data()) === null || _g === void 0 ? void 0 : _g.createdAt) !== null && _h !== void 0 ? _h : now) : now,
        }, { merge: true });
    }
    // Delete retired identifiers that are no longer present in the updated profile/vehicle
    for (const oldP of oldPrepared) {
        if (!newHashes.has(oldP.hash)) {
            tx.delete(oldP.ref);
        }
    }
}
/**
 * Callable: checkIdentifierAvailability
 * Fast O(1) pre-flight check for mobile and hub registration/editing forms.
 */
exports.checkIdentifierAvailability = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d;
    const { type, value } = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    if (!type || !value) {
        throw new https_1.HttpsError("invalid-argument", "type and value are required.");
    }
    const normalized = normalizeIdentifier(type, value);
    if (!normalized) {
        return { available: true, maskedValue: "••••" };
    }
    const hash = hashIdentifier(type, normalized);
    const snap = await db().collection("unique_identifiers").doc(hash).get();
    const masked = maskIdentifier(type, normalized);
    if (!snap.exists) {
        return { available: true, maskedValue: masked };
    }
    const data = (_b = snap.data()) !== null && _b !== void 0 ? _b : {};
    const ownerUid = String((_c = data.ownerUid) !== null && _c !== void 0 ? _c : "");
    const callerUid = (_d = request.auth) === null || _d === void 0 ? void 0 : _d.uid;
    if (callerUid && ownerUid === callerUid) {
        return { available: true, selfOwned: true, maskedValue: masked };
    }
    return {
        available: false,
        selfOwned: false,
        maskedValue: masked,
        message: getConflictErrorMessage(type, masked),
    };
});
/**
 * Callable: registerUser
 * Atomically verifies and reserves user credentials in `unique_identifiers` while creating `users/{uid}`.
 */
exports.registerUser = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required to register user profile.");
    }
    (0, accountGuard_1.enforceAppCheck)(request);
    const uid = request.auth.uid;
    const data = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    const fullName = String((_b = data.fullName) !== null && _b !== void 0 ? _b : "").trim();
    const rawPhone = String((_c = data.phoneNumber) !== null && _c !== void 0 ? _c : "").trim();
    const rawEmail = data.email ? String(data.email).trim() : "";
    const role = data.role === "driver" || data.role === "both" ? data.role : "customer";
    if (!fullName) {
        throw new https_1.HttpsError("invalid-argument", "Full name is required.");
    }
    if (!rawPhone) {
        throw new https_1.HttpsError("invalid-argument", "Phone number is required.");
    }
    const normPhone = normalizeIdentifier("phone", rawPhone);
    const normEmail = rawEmail ? normalizeIdentifier("email", rawEmail) : "";
    // Build list of unique identifiers to check and reserve
    const identifiers = [
        { type: "phone", value: normPhone },
    ];
    if (normEmail) {
        identifiers.push({ type: "email", value: normEmail });
    }
    if (data.ninNumber) {
        identifiers.push({ type: "nin", value: data.ninNumber });
    }
    if (data.bvn) {
        identifiers.push({ type: "bvn", value: data.bvn });
    }
    if (data.passportNumber) {
        identifiers.push({ type: "passport", value: data.passportNumber });
    }
    // Generic government ID from KYC form
    if (data.idNumber && data.idType) {
        const idTypeLower = data.idType.toLowerCase();
        if (idTypeLower.includes("nin")) {
            identifiers.push({ type: "nin", value: data.idNumber });
        }
        else if (idTypeLower.includes("passport")) {
            identifiers.push({ type: "passport", value: data.idNumber });
        }
        else if (idTypeLower.includes("license")) {
            identifiers.push({ type: "drivers_license", value: data.idNumber });
        }
    }
    await db().runTransaction(async (tx) => {
        var _a, _b;
        const userRef = db().collection("users").doc(uid);
        const userSnap = await tx.get(userRef);
        // Extract previous identifiers if user doc already existed
        const oldIdentifiers = [];
        if (userSnap.exists) {
            const old = (_a = userSnap.data()) !== null && _a !== void 0 ? _a : {};
            if (old.phoneNumber)
                oldIdentifiers.push({ type: "phone", value: old.phoneNumber });
            if (old.email)
                oldIdentifiers.push({ type: "email", value: old.email });
            if (old.ninNumber)
                oldIdentifiers.push({ type: "nin", value: old.ninNumber });
            if (old.bvn)
                oldIdentifiers.push({ type: "bvn", value: old.bvn });
            if (old.passportNumber)
                oldIdentifiers.push({ type: "passport", value: old.passportNumber });
        }
        // Uniqueness reservation (reads uniqueness records, verifies, queues writes)
        await assertAndReserveIdentifiersTx({
            tx,
            ownerUid: uid,
            ownerCollection: "users",
            identifiers,
            oldIdentifiers,
        });
        const now = admin.firestore.FieldValue.serverTimestamp();
        const isNew = !userSnap.exists;
        tx.set(userRef, Object.assign(Object.assign(Object.assign(Object.assign(Object.assign(Object.assign(Object.assign(Object.assign(Object.assign(Object.assign(Object.assign({ uid,
            fullName, phoneNumber: normPhone, phoneNumberE164: normPhone }, (normEmail ? { email: normEmail } : {})), { role, address: (_b = data.address) !== null && _b !== void 0 ? _b : "" }), (data.ninNumber ? { ninNumber: normalizeIdentifier("nin", data.ninNumber) } : {})), (data.bvn ? { bvn: normalizeIdentifier("bvn", data.bvn) } : {})), (data.passportNumber ? { passportNumber: normalizeIdentifier("passport", data.passportNumber) } : {})), (data.dateOfBirth ? { dateOfBirth: data.dateOfBirth } : {})), (data.gender ? { gender: data.gender } : {})), (data.occupation ? { occupation: data.occupation } : {})), (data.orgName ? { orgName: data.orgName } : {})), { updatedAt: now }), (isNew ? { createdAt: now } : {})), { merge: true });
        if (role === "driver" || role === "both") {
            const driverRef = db().collection("drivers").doc(uid);
            tx.set(driverRef, Object.assign(Object.assign(Object.assign({ driverId: uid, fullName, phone: normPhone }, (normEmail ? { email: normEmail } : {})), { updatedAt: now }), (isNew ? { createdAt: now, verificationStatus: "pending_verification", isProfileVerified: false } : {})), { merge: true });
        }
    });
    try {
        await (0, verification_1._generateAndSaveReferralCode)(uid, "users");
    }
    catch (err) {
        console.warn(`registerUser: referral code generation failed for ${uid}:`, err);
    }
    return {
        success: true,
        uid,
        message: "User profile registered successfully with verified unique credentials.",
    };
});
/**
 * Callable: updateProfile
 * Atomically validates any changed sensitive credentials, releases retired identifiers,
 * and updates user/driver profile records.
 */
exports.updateProfile = (0, https_1.onCall)(async (request) => {
    var _a;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required to update profile.");
    }
    (0, accountGuard_1.enforceAppCheck)(request);
    const uid = request.auth.uid;
    await (0, accountGuard_1.requireAccountActive)(uid);
    const data = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    await db().runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e, _f, _g;
        const userRef = db().collection("users").doc(uid);
        const userSnap = await tx.get(userRef);
        if (!userSnap.exists) {
            throw new https_1.HttpsError("not-found", "User profile not found.");
        }
        const current = (_a = userSnap.data()) !== null && _a !== void 0 ? _a : {};
        const targetPhone = data.phoneNumber ? normalizeIdentifier("phone", data.phoneNumber) : ((_b = current.phoneNumber) !== null && _b !== void 0 ? _b : "");
        const targetEmail = data.email !== undefined ? normalizeIdentifier("email", data.email) : ((_c = current.email) !== null && _c !== void 0 ? _c : "");
        const targetNin = data.ninNumber !== undefined ? normalizeIdentifier("nin", data.ninNumber) : ((_d = current.ninNumber) !== null && _d !== void 0 ? _d : "");
        const targetBvn = data.bvn !== undefined ? normalizeIdentifier("bvn", data.bvn) : ((_e = current.bvn) !== null && _e !== void 0 ? _e : "");
        const targetPassport = data.passportNumber !== undefined ? normalizeIdentifier("passport", data.passportNumber) : ((_f = current.passportNumber) !== null && _f !== void 0 ? _f : "");
        const newIdentifiers = [];
        const oldIdentifiers = [];
        // Track old vs new
        if (targetPhone)
            newIdentifiers.push({ type: "phone", value: targetPhone });
        if (current.phoneNumber)
            oldIdentifiers.push({ type: "phone", value: current.phoneNumber });
        if (targetEmail)
            newIdentifiers.push({ type: "email", value: targetEmail });
        if (current.email)
            oldIdentifiers.push({ type: "email", value: current.email });
        if (targetNin)
            newIdentifiers.push({ type: "nin", value: targetNin });
        if (current.ninNumber)
            oldIdentifiers.push({ type: "nin", value: current.ninNumber });
        if (targetBvn)
            newIdentifiers.push({ type: "bvn", value: targetBvn });
        if (current.bvn)
            oldIdentifiers.push({ type: "bvn", value: current.bvn });
        if (targetPassport)
            newIdentifiers.push({ type: "passport", value: targetPassport });
        if (current.passportNumber)
            oldIdentifiers.push({ type: "passport", value: current.passportNumber });
        // Handle KYC doc number update if present
        if (data.idNumber && data.idType) {
            const typeLower = data.idType.toLowerCase();
            if (typeLower.includes("nin")) {
                newIdentifiers.push({ type: "nin", value: data.idNumber });
            }
            else if (typeLower.includes("passport")) {
                newIdentifiers.push({ type: "passport", value: data.idNumber });
            }
            else if (typeLower.includes("license")) {
                newIdentifiers.push({ type: "drivers_license", value: data.idNumber });
            }
        }
        // Perform atomic verification & reservation
        await assertAndReserveIdentifiersTx({
            tx,
            ownerUid: uid,
            ownerCollection: "users",
            identifiers: newIdentifiers,
            oldIdentifiers,
        });
        const now = admin.firestore.FieldValue.serverTimestamp();
        const updates = {
            updatedAt: now,
        };
        if (data.fullName)
            updates.fullName = data.fullName.trim();
        if (data.phoneNumber) {
            updates.phoneNumber = targetPhone;
            updates.phoneNumberE164 = targetPhone;
        }
        if (data.email !== undefined)
            updates.email = targetEmail;
        if (data.address !== undefined)
            updates.address = data.address.trim();
        if (data.ninNumber !== undefined)
            updates.ninNumber = targetNin;
        if (data.bvn !== undefined)
            updates.bvn = targetBvn;
        if (data.passportNumber !== undefined)
            updates.passportNumber = targetPassport;
        if (data.dateOfBirth !== undefined)
            updates.dateOfBirth = data.dateOfBirth;
        if (data.gender !== undefined)
            updates.gender = data.gender;
        if (data.occupation !== undefined)
            updates.occupation = data.occupation;
        if (data.orgName !== undefined)
            updates.orgName = data.orgName;
        if (data.kycData)
            updates.kycData = data.kycData;
        tx.update(userRef, updates);
        // Sync contact info to driver doc if applicable
        const role = String((_g = current.role) !== null && _g !== void 0 ? _g : "");
        if (role === "driver" || role === "both") {
            const driverRef = db().collection("drivers").doc(uid);
            const driverUpdates = { updatedAt: now };
            if (data.fullName)
                driverUpdates.fullName = data.fullName.trim();
            if (data.phoneNumber)
                driverUpdates.phone = targetPhone;
            if (data.email !== undefined)
                driverUpdates.email = targetEmail;
            tx.set(driverRef, driverUpdates, { merge: true });
        }
    });
    try {
        await (0, verification_1._generateAndSaveReferralCode)(uid, "users");
    }
    catch (err) {
        console.warn(`updateProfile: referral code generation failed for ${uid}:`, err);
    }
    return {
        success: true,
        uid,
        message: "Profile updated successfully with verified credentials.",
    };
});
/**
 * Callable: registerVehicle
 * Atomically verifies license plate uniqueness and registers a new vehicle in PENDING status.
 */
exports.registerVehicle = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required to register vehicle.");
    }
    (0, accountGuard_1.enforceAppCheck)(request);
    const callerUid = request.auth.uid;
    const data = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    const driverId = String((_b = data.driverId) !== null && _b !== void 0 ? _b : "").trim() || callerUid;
    // Authorization: Driver registering their own vehicle, or Hub Admin staff
    if (driverId !== callerUid) {
        const staffDoc = await db().collection("hub_staff").doc(request.auth.token.email || callerUid).get();
        if (!staffDoc.exists) {
            throw new https_1.HttpsError("permission-denied", "You can only register vehicles under your own driver account.");
        }
    }
    await (0, accountGuard_1.requireAccountActive)(driverId, "driver");
    const category = String((_c = data.category) !== null && _c !== void 0 ? _c : "car").toLowerCase();
    const rawPlate = String((_d = data.licensePlate) !== null && _d !== void 0 ? _d : "").trim();
    const normPlate = normalizeIdentifier("plate_number", rawPlate);
    // Bicycles don't carry license plates in Nigeria; all motorized vehicles require one
    if (category !== "bicycle" && !normPlate) {
        throw new https_1.HttpsError("invalid-argument", "License plate number is required for motorized vehicles.");
    }
    const vCol = db().collection("drivers").doc(driverId).collection("vehicles");
    const vehicleId = vCol.doc().id;
    await db().runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e, _f;
        const driverRef = db().collection("drivers").doc(driverId);
        const driverSnap = await tx.get(driverRef);
        if (!driverSnap.exists) {
            throw new https_1.HttpsError("not-found", "Driver profile not found.");
        }
        if (normPlate) {
            // Uniqueness check: ensure plate is not registered to another vehicle in the entire fleet
            await assertAndReserveIdentifiersTx({
                tx,
                ownerUid: driverId,
                ownerCollection: "vehicles",
                entityId: vehicleId,
                identifiers: [{ type: "plate_number", value: normPlate, entityId: vehicleId }],
            });
        }
        const now = admin.firestore.FieldValue.serverTimestamp();
        const vRef = vCol.doc(vehicleId);
        // Single source of truth: vehicles/{vehicleId}
        tx.set(vRef, {
            id: vehicleId,
            driverId,
            category,
            make: (_a = data.make) !== null && _a !== void 0 ? _a : "",
            model: (_b = data.model) !== null && _b !== void 0 ? _b : "",
            year: (_c = data.year) !== null && _c !== void 0 ? _c : new Date().getFullYear(),
            licensePlate: normPlate,
            color: (_d = data.color) !== null && _d !== void 0 ? _d : "",
            tier: (_e = data.tier) !== null && _e !== void 0 ? _e : null,
            verificationStatus: "PENDING",
            isVerified: false,
            status: "pending",
            lifecycleStatus: "ACTIVE",
            isActiveSelected: false,
            documents: (_f = data.documents) !== null && _f !== void 0 ? _f : {},
            createdAt: now,
            updatedAt: now,
        });
        // Update root driver doc status
        tx.set(driverRef, {
            vehicleStatus: "pending_verification",
            isPendingReview: true,
            updatedAt: now,
        }, { merge: true });
    });
    return {
        success: true,
        driverId,
        vehicleId,
        licensePlate: normPlate,
        message: "Vehicle registered successfully and submitted for hub verification.",
    };
});
//# sourceMappingURL=uniqueIdentifiers.js.map