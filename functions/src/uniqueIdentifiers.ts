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

import * as crypto from "crypto";
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { enforceAppCheck, requireAccountActive } from "./accountGuard";
import { _generateAndSaveReferralCode } from "./verification";

const db = () => admin.firestore();

export type IdentifierType =
  | "phone"
  | "email"
  | "nin"
  | "bvn"
  | "passport"
  | "plate_number"
  | "drivers_license";

export interface UniqueIdentifierDoc {
  identifierHash: string;
  identifierType: IdentifierType;
  maskedValue: string;
  ownerUid: string;
  ownerCollection: "users" | "drivers" | "hub_staff" | "vehicles";
  entityId: string;
  createdAt: admin.firestore.FieldValue;
  updatedAt: admin.firestore.FieldValue;
}

export interface IdentifierEntry {
  type: IdentifierType;
  value: string;
  entityId?: string;
}

export interface PreparedIdentifier {
  type: IdentifierType;
  normalized: string;
  hash: string;
  masked: string;
  ref: admin.firestore.DocumentReference;
  entityId?: string;
}

// ── 1. Normalization & Hashing ───────────────────────────────────────────────

/**
 * Normalizes sensitive credentials into canonical comparable strings.
 *
 * - phone: E.164 international format without spaces/dashes (e.g., `080...` -> `+23480...`).
 * - email: Lowercase, trimmed. Gmail addresses have dots removed and `+alias` suffixes stripped.
 * - nin / bvn: Pure numeric digits.
 * - passport / plate_number / drivers_license: Uppercase alphanumeric with all symbols/spaces stripped.
 */
export function normalizeIdentifier(type: IdentifierType, raw: string): string {
  if (!raw) return "";
  const trimmed = raw.trim();

  switch (type) {
    case "phone": {
      let cleaned = trimmed.replace(/[^\d+]/g, "");
      if (cleaned.startsWith("0") && cleaned.length >= 10) {
        cleaned = "+234" + cleaned.substring(1);
      } else if (cleaned.startsWith("234")) {
        cleaned = "+" + cleaned;
      } else if (!cleaned.startsWith("+") && cleaned.length > 0) {
        cleaned = "+" + cleaned;
      }
      return cleaned;
    }

    case "email": {
      const lower = trimmed.toLowerCase();
      const atIdx = lower.indexOf("@");
      if (atIdx === -1) return lower;
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
export function hashIdentifier(type: IdentifierType, normalized: string): string {
  return crypto
    .createHash("sha256")
    .update(`${type.toLowerCase()}:${normalized}`)
    .digest("hex");
}

/**
 * Produces safe masked representations for user-friendly error messages and audit logs.
 */
export function maskIdentifier(type: IdentifierType, value: string): string {
  const norm = normalizeIdentifier(type, value);
  if (!norm) return "••••";

  switch (type) {
    case "phone": {
      if (norm.length > 6) {
        return norm.slice(0, 4) + "••••••" + norm.slice(-2);
      }
      return norm.slice(0, 2) + "••••";
    }

    case "email": {
      const atIdx = norm.indexOf("@");
      if (atIdx === -1) return "••••";
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
 * Formats a secure, generic feedback message for uniqueness conflicts without leaking rules or PII.
 */
export function getConflictErrorMessage(
  _type?: IdentifierType,
  _masked?: string
): string {
  return "Please check your details and try again.";
}

/**
 * Prepares and deduplicates entries before checking against Firestore.
 */
export function prepareIdentifiers(
  entries: IdentifierEntry[]
): PreparedIdentifier[] {
  const result: PreparedIdentifier[] = [];
  const seenHashes = new Set<string>();

  for (const entry of entries) {
    if (!entry.value || !entry.value.trim()) continue;
    const normalized = normalizeIdentifier(entry.type, entry.value);
    if (!normalized) continue;
    const hash = hashIdentifier(entry.type, normalized);
    if (seenHashes.has(hash)) continue;
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

// ── 2. Atomic Transaction Execution ──────────────────────────────────────────

export interface AssertAndReserveParams {
  tx: admin.firestore.Transaction;
  ownerUid: string;
  ownerCollection: "users" | "drivers" | "hub_staff" | "vehicles";
  entityId?: string;
  identifiers: IdentifierEntry[];
  oldIdentifiers?: IdentifierEntry[];
}

/**
 * Atomic Transaction Guard:
 * 1. Executes all reads for uniqueness lookup documents.
 * 2. Validates that no identifier is owned by a different user/entity.
 * 3. Queues transaction writes to register new unique mappings and clean up old ones.
 */
export async function assertAndReserveIdentifiersTx(
  params: AssertAndReserveParams
): Promise<void> {
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
      const data = snap.data() as Partial<UniqueIdentifierDoc>;
      const existingOwnerUid = String(data.ownerUid ?? "");
      const existingEntityId = String(data.entityId ?? "");

      if (existingOwnerUid && existingOwnerUid !== ownerUid) {
        throw new HttpsError("already-exists", getConflictErrorMessage(p.type, p.masked));
      }

      // Plate numbers must be unique across all vehicles even within the same driver fleet
      if (p.type === "plate_number") {
        const targetEntity = p.entityId ?? params.entityId ?? ownerUid;
        if (existingEntityId && existingEntityId !== targetEntity) {
          throw new HttpsError("already-exists", getConflictErrorMessage(p.type, p.masked));
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
    const targetEntityId = p.entityId ?? params.entityId ?? ownerUid;

    tx.set(
      p.ref,
      {
        identifierHash: p.hash,
        identifierType: p.type,
        maskedValue: p.masked,
        ownerUid,
        ownerCollection,
        entityId: targetEntityId,
        updatedAt: now,
        createdAt: snap.exists ? (snap.data()?.createdAt ?? now) : now,
      },
      { merge: true }
    );
  }

  // Delete retired identifiers that are no longer present in the updated profile/vehicle
  for (const oldP of oldPrepared) {
    if (!newHashes.has(oldP.hash)) {
      tx.delete(oldP.ref);
    }
  }
}

// ── 3. Callable: checkIdentifierAvailability ─────────────────────────────────

interface CheckAvailabilityData {
  type: IdentifierType;
  value: string;
}

/**
 * Callable: checkIdentifierAvailability
 * Fast O(1) pre-flight check for mobile and hub registration/editing forms.
 */
export const checkIdentifierAvailability = onCall<CheckAvailabilityData>(
  async (request) => {
    const { type, value } = request.data ?? {};
    if (!type || !value) {
      throw new HttpsError("invalid-argument", "type and value are required.");
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

    const data = snap.data() ?? {};
    const ownerUid = String(data.ownerUid ?? "");
    const callerUid = request.auth?.uid;

    if (callerUid && ownerUid === callerUid) {
      return { available: true, selfOwned: true, maskedValue: masked };
    }

    return {
      available: false,
      selfOwned: false,
      maskedValue: masked,
      message: getConflictErrorMessage(type, masked),
    };
  }
);

// ── 4. Callable: registerUser ────────────────────────────────────────────────

export interface RegisterUserData {
  fullName: string;
  phoneNumber: string;
  email?: string;
  role?: "customer" | "driver" | "both";
  address?: string;
  ninNumber?: string;
  bvn?: string;
  passportNumber?: string;
  idType?: string;
  idNumber?: string;
  dateOfBirth?: string;
  gender?: string;
  occupation?: string;
  orgName?: string;
}

/**
 * Callable: registerUser
 * Atomically verifies and reserves user credentials in `unique_identifiers` while creating `users/{uid}`.
 */
export const registerUser = onCall<RegisterUserData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required to register user profile.");
  }
  enforceAppCheck(request);

  const uid = request.auth.uid;
  const data = request.data ?? {};
  const fullName = String(data.fullName ?? "").trim();
  const rawPhone = String(data.phoneNumber ?? "").trim();
  const rawEmail = data.email ? String(data.email).trim() : "";
  const role = data.role === "driver" || data.role === "both" ? data.role : "customer";

  if (!fullName) {
    throw new HttpsError("invalid-argument", "Full name is required.");
  }
  if (!rawPhone) {
    throw new HttpsError("invalid-argument", "Phone number is required.");
  }

  const normPhone = normalizeIdentifier("phone", rawPhone);
  const normEmail = rawEmail ? normalizeIdentifier("email", rawEmail) : "";

  // Build list of unique identifiers to check and reserve
  const identifiers: IdentifierEntry[] = [
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
    } else if (idTypeLower.includes("passport")) {
      identifiers.push({ type: "passport", value: data.idNumber });
    } else if (idTypeLower.includes("license")) {
      identifiers.push({ type: "drivers_license", value: data.idNumber });
    }
  }

  await db().runTransaction(async (tx) => {
    const userRef = db().collection("users").doc(uid);
    const userSnap = await tx.get(userRef);

    // Extract previous identifiers if user doc already existed
    const oldIdentifiers: IdentifierEntry[] = [];
    if (userSnap.exists) {
      const old = userSnap.data() ?? {};
      if (old.phoneNumber) oldIdentifiers.push({ type: "phone", value: old.phoneNumber });
      if (old.email) oldIdentifiers.push({ type: "email", value: old.email });
      if (old.ninNumber) oldIdentifiers.push({ type: "nin", value: old.ninNumber });
      if (old.bvn) oldIdentifiers.push({ type: "bvn", value: old.bvn });
      if (old.passportNumber) oldIdentifiers.push({ type: "passport", value: old.passportNumber });
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

    tx.set(
      userRef,
      {
        uid,
        fullName,
        phoneNumber: normPhone,
        phoneNumberE164: normPhone,
        ...(normEmail ? { email: normEmail } : {}),
        role,
        address: data.address ?? "",
        ...(data.ninNumber ? { ninNumber: normalizeIdentifier("nin", data.ninNumber) } : {}),
        ...(data.bvn ? { bvn: normalizeIdentifier("bvn", data.bvn) } : {}),
        ...(data.passportNumber ? { passportNumber: normalizeIdentifier("passport", data.passportNumber) } : {}),
        ...(data.dateOfBirth ? { dateOfBirth: data.dateOfBirth } : {}),
        ...(data.gender ? { gender: data.gender } : {}),
        ...(data.occupation ? { occupation: data.occupation } : {}),
        ...(data.orgName ? { orgName: data.orgName } : {}),
        updatedAt: now,
        ...(isNew ? { createdAt: now } : {}),
      },
      { merge: true }
    );

    if (role === "driver" || role === "both") {
      const driverRef = db().collection("drivers").doc(uid);
      tx.set(
        driverRef,
        {
          driverId: uid,
          fullName,
          phone: normPhone,
          ...(normEmail ? { email: normEmail } : {}),
          updatedAt: now,
          ...(isNew ? { createdAt: now, verificationStatus: "pending_verification", isProfileVerified: false } : {}),
        },
        { merge: true }
      );
    }
  });

  try {
    await _generateAndSaveReferralCode(uid, "users");
  } catch (err) {
    console.warn(`registerUser: referral code generation failed for ${uid}:`, err);
  }

  return {
    success: true,
    uid,
    message: "User profile registered successfully with verified unique credentials.",
  };
});

// ── 5. Callable: updateProfile ───────────────────────────────────────────────

export interface UpdateProfileData {
  fullName?: string;
  phoneNumber?: string;
  email?: string;
  address?: string;
  ninNumber?: string;
  bvn?: string;
  passportNumber?: string;
  idType?: string;
  idNumber?: string;
  dateOfBirth?: string;
  gender?: string;
  occupation?: string;
  orgName?: string;
  kycData?: Record<string, any>;
}

/**
 * Callable: updateProfile
 * Atomically validates any changed sensitive credentials, releases retired identifiers,
 * and updates user/driver profile records.
 */
export const updateProfile = onCall<UpdateProfileData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required to update profile.");
  }
  enforceAppCheck(request);
  const uid = request.auth.uid;
  await requireAccountActive(uid);

  const data = request.data ?? {};

  await db().runTransaction(async (tx) => {
    const userRef = db().collection("users").doc(uid);
    const userSnap = await tx.get(userRef);
    if (!userSnap.exists) {
      throw new HttpsError("not-found", "User profile not found.");
    }
    const current = userSnap.data() ?? {};

    const targetPhone = data.phoneNumber ? normalizeIdentifier("phone", data.phoneNumber) : (current.phoneNumber ?? "");
    const targetEmail = data.email !== undefined ? normalizeIdentifier("email", data.email) : (current.email ?? "");
    const targetNin = data.ninNumber !== undefined ? normalizeIdentifier("nin", data.ninNumber) : (current.ninNumber ?? "");
    const targetBvn = data.bvn !== undefined ? normalizeIdentifier("bvn", data.bvn) : (current.bvn ?? "");
    const targetPassport = data.passportNumber !== undefined ? normalizeIdentifier("passport", data.passportNumber) : (current.passportNumber ?? "");

    const newIdentifiers: IdentifierEntry[] = [];
    const oldIdentifiers: IdentifierEntry[] = [];

    // Track old vs new
    if (targetPhone) newIdentifiers.push({ type: "phone", value: targetPhone });
    if (current.phoneNumber) oldIdentifiers.push({ type: "phone", value: current.phoneNumber });

    if (targetEmail) newIdentifiers.push({ type: "email", value: targetEmail });
    if (current.email) oldIdentifiers.push({ type: "email", value: current.email });

    if (targetNin) newIdentifiers.push({ type: "nin", value: targetNin });
    if (current.ninNumber) oldIdentifiers.push({ type: "nin", value: current.ninNumber });

    if (targetBvn) newIdentifiers.push({ type: "bvn", value: targetBvn });
    if (current.bvn) oldIdentifiers.push({ type: "bvn", value: current.bvn });

    if (targetPassport) newIdentifiers.push({ type: "passport", value: targetPassport });
    if (current.passportNumber) oldIdentifiers.push({ type: "passport", value: current.passportNumber });

    // Handle KYC doc number update if present
    if (data.idNumber && data.idType) {
      const typeLower = data.idType.toLowerCase();
      if (typeLower.includes("nin")) {
        newIdentifiers.push({ type: "nin", value: data.idNumber });
      } else if (typeLower.includes("passport")) {
        newIdentifiers.push({ type: "passport", value: data.idNumber });
      } else if (typeLower.includes("license")) {
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
    const updates: Record<string, any> = {
      updatedAt: now,
    };

    if (data.fullName) updates.fullName = data.fullName.trim();
    if (data.phoneNumber) {
      updates.phoneNumber = targetPhone;
      updates.phoneNumberE164 = targetPhone;
    }
    if (data.email !== undefined) updates.email = targetEmail;
    if (data.address !== undefined) updates.address = data.address.trim();
    if (data.ninNumber !== undefined) updates.ninNumber = targetNin;
    if (data.bvn !== undefined) updates.bvn = targetBvn;
    if (data.passportNumber !== undefined) updates.passportNumber = targetPassport;
    if (data.dateOfBirth !== undefined) updates.dateOfBirth = data.dateOfBirth;
    if (data.gender !== undefined) updates.gender = data.gender;
    if (data.occupation !== undefined) updates.occupation = data.occupation;
    if (data.orgName !== undefined) updates.orgName = data.orgName;
    if (data.kycData) updates.kycData = data.kycData;

    tx.update(userRef, updates);

    // Sync contact info to driver doc if applicable
    const role = String(current.role ?? "");
    if (role === "driver" || role === "both") {
      const driverRef = db().collection("drivers").doc(uid);
      const driverUpdates: Record<string, any> = { updatedAt: now };
      if (data.fullName) driverUpdates.fullName = data.fullName.trim();
      if (data.phoneNumber) driverUpdates.phone = targetPhone;
      if (data.email !== undefined) driverUpdates.email = targetEmail;
      tx.set(driverRef, driverUpdates, { merge: true });
    }
  });

  try {
    await _generateAndSaveReferralCode(uid, "users");
  } catch (err) {
    console.warn(`updateProfile: referral code generation failed for ${uid}:`, err);
  }

  return {
    success: true,
    uid,
    message: "Profile updated successfully with verified credentials.",
  };
});

// ── 6. Callable: registerVehicle ─────────────────────────────────────────────

export interface RegisterVehicleData {
  driverId: string;
  category: string;
  make: string;
  model: string;
  year: number;
  licensePlate: string;
  color: string;
  documents?: Record<string, string>;
  tier?: string;
}

/**
 * Callable: registerVehicle
 * Atomically verifies license plate uniqueness and registers a new vehicle in PENDING status.
 */
export const registerVehicle = onCall<RegisterVehicleData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required to register vehicle.");
  }
  enforceAppCheck(request);

  const callerUid = request.auth.uid;
  const data = request.data ?? {};
  const driverId = String(data.driverId ?? "").trim() || callerUid;

  // Authorization: Driver registering their own vehicle, or Hub Admin staff
  if (driverId !== callerUid) {
    const staffDoc = await db().collection("hub_staff").doc(request.auth.token.email || callerUid).get();
    if (!staffDoc.exists) {
      throw new HttpsError("permission-denied", "You can only register vehicles under your own driver account.");
    }
  }

  await requireAccountActive(driverId, "driver");

  const category = String(data.category ?? "car").toLowerCase();
  const rawPlate = String(data.licensePlate ?? "").trim();
  const normPlate = normalizeIdentifier("plate_number", rawPlate);

  // Bicycles don't carry license plates in Nigeria; all motorized vehicles require one
  if (category !== "bicycle" && !normPlate) {
    throw new HttpsError("invalid-argument", "License plate number is required for motorized vehicles.");
  }

  const vCol = db().collection("drivers").doc(driverId).collection("vehicles");
  const vehicleId = vCol.doc().id;

  await db().runTransaction(async (tx) => {
    const driverRef = db().collection("drivers").doc(driverId);
    const driverSnap = await tx.get(driverRef);
    if (!driverSnap.exists) {
      throw new HttpsError("not-found", "Driver profile not found.");
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
      make: data.make ?? "",
      model: data.model ?? "",
      year: data.year ?? new Date().getFullYear(),
      licensePlate: normPlate,
      color: data.color ?? "",
      tier: data.tier ?? null,
      verificationStatus: "PENDING",
      isVerified: false,
      status: "pending",
      lifecycleStatus: "ACTIVE",
      isActiveSelected: false,
      documents: data.documents ?? {},
      createdAt: now,
      updatedAt: now,
    });

    // Update root driver doc status
    tx.set(
      driverRef,
      {
        vehicleStatus: "pending_verification",
        isPendingReview: true,
        updatedAt: now,
      },
      { merge: true }
    );
  });

  return {
    success: true,
    driverId,
    vehicleId,
    licensePlate: normPlate,
    message: "Vehicle registered successfully and submitted for hub verification.",
  };
});
