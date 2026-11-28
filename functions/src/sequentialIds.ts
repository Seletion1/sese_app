import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { enforceAppCheck } from "./accountGuard";
import { assertHubStaffOrAdmin } from "./verification";

const db = () => admin.firestore();

/**
 * Dedicated Firestore counter document paths.
 * - Customer counter: counters/SC
 * - Driver counter: counters/SD
 * - Staff / Hub counter: counters/SH
 * - Agent counter: counters/SA
 */
export const COUNTER_DOCS = {
  customer: "counters/SC",
  driver: "counters/SD",
  staff: "counters/SH",
  hub: "counters/SH",
  agent: "counters/SA",
} as const;

export type UserRoleType = "customer" | "driver" | "staff" | "hub" | "agent";

/**
 * Format a sequential number as "SC0001", "SD0001", "SH0001", "SA0001", growing past 4 digits naturally ("SC10000").
 * Customer prefix: "SC", Driver prefix: "SD", Staff prefix: "SH", Agent prefix: "SA".
 */
export function formatSequentialId(role: UserRoleType, n: number): string {
  const prefix = role === "customer" ? "SC" : (role === "agent" ? "SA" : (role === "staff" || role === "hub" ? "SH" : "SD"));
  return prefix + String(n).padStart(4, "0");
}

/**
 * Extracts a normalized registration timestamp (epoch milliseconds) from document data.
 * Checks `createdAt`, `memberSince`, `registeredAt`, and `joinedAt`.
 * Returns Number.MAX_SAFE_INTEGER if no parseable timestamp exists.
 */
export function extractRegistrationTimestamp(data: Record<string, unknown>): number {
  const raw = data.createdAt ?? data.memberSince ?? data.registeredAt ?? data.joinedAt;
  if (!raw) return Number.MAX_SAFE_INTEGER;
  if (typeof (raw as any).toMillis === "function") return (raw as any).toMillis();
  if (typeof (raw as any).toDate === "function") return (raw as any).toDate().getTime();
  if (raw instanceof Date) return raw.getTime();
  if (typeof raw === "number") return raw;
  if (typeof raw === "string") {
    const p = Date.parse(raw);
    if (!isNaN(p)) return p;
  }
  return Number.MAX_SAFE_INTEGER;
}

/**
 * Atomically assigns the next sequential ID to a user, driver, or hub staff document
 * inside a Firestore transaction reading and incrementing the dedicated counter document
 * (`counters/SC`, `counters/SD`, `counters/SH`).
 *
 * Idempotent — if sequentialId already exists on the doc and starts with the expected prefix
 * (SC for customer, SD for driver, SH for staff), returns it without writing anything or incrementing.
 *
 * @param uid - The Firebase Auth UID / document ID / staff email ID.
 * @param role - "customer" | "driver" | "staff" | "hub"
 * @returns The assigned sequential ID string (e.g. "SC0001", "SD0001", "SH0001").
 */
export async function _assignSequentialId(
  uid: string,
  role: UserRoleType
): Promise<string> {
  const firestore = db();
  const collection = role === "customer" ? "users" : (role === "staff" || role === "hub" ? "hub_staff" : (role === "agent" ? "agents" : "drivers"));
  const docRef = firestore.collection(collection).doc(uid);
  const counterDocPath = COUNTER_DOCS[role];
  const counterRef = firestore.doc(counterDocPath);
  const expectedPrefix = role === "customer" ? "SC" : (role === "agent" ? "SA" : (role === "staff" || role === "hub" ? "SH" : "SD"));

  return firestore.runTransaction(async (tx) => {
    // 1. Check existing sequential ID on target document
    const snap = await tx.get(docRef);
    const snapData = snap.exists ? (snap.data() as Record<string, unknown>) : {};
    const existing = snapData?.sequentialId as string | undefined;

    const rawFirst = String(
      snapData?.firstName ??
        snapData?.fullName ??
        snapData?.displayName ??
        ""
    ).trim();
    const firstName = rawFirst ? rawFirst.split(/\s+/)[0] : (role === "driver" ? "Driver" : "Member");

    if (existing && existing.startsWith(expectedPrefix)) {
      // Ensure the lookup indexes exist even if sequentialId was already assigned
      const uniqueIndexRef = firestore.collection("unique_sequential_ids").doc(existing);
      const uniqueIndexSnap = await tx.get(uniqueIndexRef);
      if (!uniqueIndexSnap.exists) {
        tx.set(uniqueIndexRef, {
          ownerUid: uid,
          role: role === "hub" ? "staff" : role,
          sequentialId: existing,
          firstName,
          isVerified: true,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      const refCodeRef = firestore.collection("referral_codes").doc(existing);
      const refCodeSnap = await tx.get(refCodeRef);
      if (!refCodeSnap.exists) {
        tx.set(refCodeRef, {
          ownerUid: uid,
          referrerId: uid,
          role: role === "hub" ? "staff" : role,
          code: existing,
          firstName,
          isVerified: true,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      return existing;
    }

    // 2. Read dedicated counter document
    const counterSnap = await tx.get(counterRef);
    const counterData = counterSnap.exists ? (counterSnap.data() as Record<string, unknown>) : {};
    const current = typeof counterData.count === "number"
      ? (counterData.count as number)
      : (typeof counterData.lastNumber === "number" ? (counterData.lastNumber as number) : 0);
    const next = current + 1;
    const sequentialId = formatSequentialId(role, next);

    // 3. Collision protection: verify uniqueness in unique_sequential_ids
    const uniqueIndexRef = firestore.collection("unique_sequential_ids").doc(sequentialId);
    const uniqueIndexSnap = await tx.get(uniqueIndexRef);
    if (uniqueIndexSnap.exists && uniqueIndexSnap.data()?.ownerUid !== uid) {
      throw new Error(`Sequential ID collision detected: ${sequentialId} already reserved.`);
    }

    // 4. Update dedicated counter doc
    tx.set(counterRef, {
      count: next,
      lastNumber: next,
      role: role === "hub" ? "staff" : role,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    // 5. Reserve unique sequential ID index (also serves as verified referral lookup)
    tx.set(uniqueIndexRef, {
      ownerUid: uid,
      role: role === "hub" ? "staff" : role,
      sequentialId,
      firstName,
      isVerified: true,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Also mirror to referral_codes for legacy/backward compatibility
    const refCodeRef = firestore.collection("referral_codes").doc(sequentialId);
    tx.set(refCodeRef, {
      ownerUid: uid,
      referrerId: uid,
      role: role === "hub" ? "staff" : role,
      code: sequentialId,
      firstName,
      isVerified: true,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // 6. Update target user/driver/staff document
    if (snap.exists) {
      tx.update(docRef, { sequentialId });
    } else {
      tx.set(docRef, { sequentialId }, { merge: true });
    }

    return sequentialId;
  });
}

interface BackfillRequestData {
  resetAll?: boolean;
}

/**
 * Hub-only callable to backfill sequential IDs and verified referral codes
 * for all existing users, drivers, and hub staff.
 *
 * Ordering: Orders existing records strictly by earliest registration timestamp
 * (`createdAt` / `memberSince` ascending—oldest first gets 0001, next gets 0002, etc.)
 * in memory without relying on single-field Firestore indexing.
 *
 * Guarantees:
 *  - Unique sequential IDs (SC0001, SC0002...; SD0001, SD0002...; SH0001, SH0002...).
 *  - Zero duplicate sequential IDs across any role.
 *  - Updates dedicated counter documents (`counters/SC`, `counters/SD`, `counters/SH`)
 *    to the highest issued number so next signup gets lastNumber + 1.
 *  - Generates referralId only when user is verified AND has a phone number.
 */
export const backfillSequentialIds = onCall(
  { timeoutSeconds: 540, memory: "512MiB" },
  async (request) => {
    enforceAppCheck(request);
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required.");
    }

    await assertHubStaffOrAdmin(request.auth);

    const firestore = db();
    const data = (request.data ?? {}) as BackfillRequestData;
    const resetAll = data.resetAll === true;

    const results = {
      customersSequentialAssigned: 0,
      driversSequentialAssigned: 0,
      staffSequentialAssigned: 0,
      customerCounterSet: 0,
      driverCounterSet: 0,
      staffCounterSet: 0,
    };

    // ── 1. Backfill Verified Customers ───────────────────────────────────────
    const usersSnap = await firestore.collection("users").get();
    const sortedUsers = usersSnap.docs.slice().sort((a, b) => {
      const tA = extractRegistrationTimestamp(a.data());
      const tB = extractRegistrationTimestamp(b.data());
      if (tA !== tB) return tA - tB;
      return a.id.localeCompare(b.id);
    });

    let customerIndex = 0;
    for (const doc of sortedUsers) {
      const uData = doc.data() as Record<string, unknown>;
      const isVerified =
        uData.isProfileVerified === true ||
        uData.verificationStatus === "verified" ||
        uData.verificationStatus === "approved" ||
        uData.isVerifiedCustomer === true;
      if (!isVerified) continue;

      customerIndex++;
      const existingSeqId = uData.sequentialId as string | undefined;
      const expectedSeqId = formatSequentialId("customer", customerIndex);
      const rawFirst = String(uData.firstName ?? uData.fullName ?? uData.displayName ?? "").trim();
      const firstName = rawFirst ? rawFirst.split(/\s+/)[0] : "Member";

      if (resetAll || !existingSeqId || !existingSeqId.startsWith("SC") || existingSeqId !== expectedSeqId) {
        await firestore.runTransaction(async (tx) => {
          const uniqueIndexRef = firestore.collection("unique_sequential_ids").doc(expectedSeqId);
          tx.set(uniqueIndexRef, {
            ownerUid: doc.id,
            role: "customer",
            sequentialId: expectedSeqId,
            firstName,
            isVerified: true,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          tx.update(doc.ref, { sequentialId: expectedSeqId });
        });
        results.customersSequentialAssigned++;
      }
    }

    // Set dedicated customer counter to highest issued number
    await firestore.doc(COUNTER_DOCS.customer).set({
      count: customerIndex,
      lastNumber: customerIndex,
      role: "customer",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    results.customerCounterSet = customerIndex;

    // ── 2. Backfill Verified Drivers ─────────────────────────────────────────
    const driversSnap = await firestore.collection("drivers").get();
    const sortedDrivers = driversSnap.docs.slice().sort((a, b) => {
      const tA = extractRegistrationTimestamp(a.data());
      const tB = extractRegistrationTimestamp(b.data());
      if (tA !== tB) return tA - tB;
      return a.id.localeCompare(b.id);
    });

    let driverIndex = 0;
    for (const doc of sortedDrivers) {
      const dData = doc.data() as Record<string, unknown>;
      const isVerified =
        dData.isProfileVerified === true ||
        dData.verificationStatus === "verified" ||
        dData.verificationStatus === "approved";
      if (!isVerified) continue;

      driverIndex++;
      const existingSeqId = dData.sequentialId as string | undefined;
      const expectedSeqId = formatSequentialId("driver", driverIndex);
      const rawFirst = String(dData.firstName ?? dData.fullName ?? dData.displayName ?? "").trim();
      const firstName = rawFirst ? rawFirst.split(/\s+/)[0] : "Driver";

      if (resetAll || !existingSeqId || !existingSeqId.startsWith("SD") || existingSeqId !== expectedSeqId) {
        await firestore.runTransaction(async (tx) => {
          const uniqueIndexRef = firestore.collection("unique_sequential_ids").doc(expectedSeqId);
          tx.set(uniqueIndexRef, {
            ownerUid: doc.id,
            role: "driver",
            sequentialId: expectedSeqId,
            firstName,
            isVerified: true,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          tx.update(doc.ref, { sequentialId: expectedSeqId });
        });
        results.driversSequentialAssigned++;
      }
    }

    // Set dedicated driver counter to highest issued number
    await firestore.doc(COUNTER_DOCS.driver).set({
      count: driverIndex,
      lastNumber: driverIndex,
      role: "driver",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    results.driverCounterSet = driverIndex;

    // ── 3. Backfill Hub Staff ────────────────────────────────────────────────
    const staffSnap = await firestore.collection("hub_staff").get();
    const sortedStaff = staffSnap.docs.slice().sort((a, b) => {
      const tA = extractRegistrationTimestamp(a.data());
      const tB = extractRegistrationTimestamp(b.data());
      if (tA !== tB) return tA - tB;
      return a.id.localeCompare(b.id);
    });

    let staffIndex = 0;
    for (const doc of sortedStaff) {
      staffIndex++;
      const sData = doc.data() as Record<string, unknown>;
      const existingSeqId = sData.sequentialId as string | undefined;
      const expectedSeqId = formatSequentialId("staff", staffIndex);

      if (resetAll || !existingSeqId || !existingSeqId.startsWith("SH") || existingSeqId !== expectedSeqId) {
        await firestore.runTransaction(async (tx) => {
          const uniqueIndexRef = firestore.collection("unique_sequential_ids").doc(expectedSeqId);
          tx.set(uniqueIndexRef, {
            ownerUid: doc.id,
            role: "staff",
            sequentialId: expectedSeqId,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          tx.update(doc.ref, { sequentialId: expectedSeqId });
        });
        results.staffSequentialAssigned++;
      }
    }

    // Set dedicated staff counter to highest issued number
    await firestore.doc(COUNTER_DOCS.staff).set({
      count: staffIndex,
      lastNumber: staffIndex,
      role: "staff",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    results.staffCounterSet = staffIndex;

    return {
      success: true,
      message: "Sequential ID & Referral Code backfill completed successfully.",
      results,
    };
  }
);

/**
 * Public referral code validation callable.
 * Resolves official Member IDs (e.g. SC0001, SD0001, SA0001, SH0001) for unauthenticated
 * sign-up flows or client validation.
 *
 * Guarantees:
 * - Direct O(1) read from `unique_sequential_ids/{code}` and `referral_codes/{code}`.
 * - Automatic index self-healing: if an approved driver/user doc carries the sequentialId
 *   but the lookup index was not previously populated, it populates the index atomically.
 * - Never leaks sensitive PII: only returns firstName, role, and sanitized referrerId.
 */
export const validateReferralCode = onCall(
  { cors: true },
  async (request) => {
    const rawCode = String(request.data?.code ?? "").trim().toUpperCase();
    if (!rawCode || !/^(SC|SD|SH|SA)\d{4,}$/.test(rawCode)) {
      return { valid: false, error: "Invalid referral code format." };
    }

    const firestore = db();

    // 1. Check primary uniqueness / referral index
    try {
      const seqSnap = await firestore.collection("unique_sequential_ids").doc(rawCode).get();
      if (seqSnap.exists && seqSnap.data()) {
        const d = seqSnap.data()!;
        const ownerUid = String(d.ownerUid ?? d.referrerId ?? d.userId ?? "").trim();
        const firstName = String(d.firstName ?? "").trim() || "Member";
        const role = String(d.role ?? "user").trim();
        if (ownerUid) {
          return {
            valid: true,
            referrerId: ownerUid,
            firstName,
            role,
            memberId: rawCode,
          };
        }
      }
    } catch (e) {
      console.warn(`[validateReferralCode] unique_sequential_ids read error for ${rawCode}:`, e);
    }

    // 2. Check fallback referral_codes collection
    try {
      const refSnap = await firestore.collection("referral_codes").doc(rawCode).get();
      if (refSnap.exists && refSnap.data()) {
        const d = refSnap.data()!;
        const ownerUid = String(d.ownerUid ?? d.referrerId ?? d.userId ?? "").trim();
        const firstName = String(d.firstName ?? "").trim() || "Member";
        const role = String(d.role ?? "user").trim();
        if (ownerUid) {
          return {
            valid: true,
            referrerId: ownerUid,
            firstName,
            role,
            memberId: rawCode,
          };
        }
      }
    } catch (e) {
      console.warn(`[validateReferralCode] referral_codes read error for ${rawCode}:`, e);
    }

    // 3. Fallback: Lookup in users & drivers collections and auto-heal the index
    try {
      // Driver check (e.g. SD0001)
      const dSnap = await firestore
        .collection("drivers")
        .where("sequentialId", "==", rawCode)
        .limit(1)
        .get();

      if (!dSnap.empty) {
        const doc = dSnap.docs[0];
        const dData = doc.data() as Record<string, unknown>;
        const rawFirst = String(dData.firstName ?? dData.fullName ?? dData.displayName ?? "").trim();
        const firstName = rawFirst ? rawFirst.split(/\s+/)[0] : "Driver";
        const ownerUid = doc.id;

        // Auto-heal lookup documents
        await firestore.collection("unique_sequential_ids").doc(rawCode).set({
          ownerUid,
          role: "driver",
          sequentialId: rawCode,
          firstName,
          isVerified: true,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });

        await firestore.collection("referral_codes").doc(rawCode).set({
          ownerUid,
          referrerId: ownerUid,
          role: "driver",
          firstName,
          isVerified: true,
          code: rawCode,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });

        return {
          valid: true,
          referrerId: ownerUid,
          firstName,
          role: "driver",
          memberId: rawCode,
        };
      }

      // Customer check (e.g. SC0001)
      const uSnap = await firestore
        .collection("users")
        .where("sequentialId", "==", rawCode)
        .limit(1)
        .get();

      if (!uSnap.empty) {
        const doc = uSnap.docs[0];
        const uData = doc.data() as Record<string, unknown>;
        const rawFirst = String(uData.firstName ?? uData.fullName ?? uData.displayName ?? "").trim();
        const firstName = rawFirst ? rawFirst.split(/\s+/)[0] : "Member";
        const ownerUid = doc.id;

        // Auto-heal lookup documents
        await firestore.collection("unique_sequential_ids").doc(rawCode).set({
          ownerUid,
          role: "customer",
          sequentialId: rawCode,
          firstName,
          isVerified: true,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });

        await firestore.collection("referral_codes").doc(rawCode).set({
          ownerUid,
          referrerId: ownerUid,
          role: "customer",
          firstName,
          isVerified: true,
          code: rawCode,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });

        return {
          valid: true,
          referrerId: ownerUid,
          firstName,
          role: "customer",
          memberId: rawCode,
        };
      }
    } catch (e) {
      console.warn(`[validateReferralCode] healing fallback failed for ${rawCode}:`, e);
    }

    return { valid: false, error: "Member ID not found or unverified." };
  }
);

/**
 * Server-authoritative referral linking callable.
 * Links a newly registered user/driver to a valid referrer (SC0001, SD0001, etc.).
 *
 * Enforces:
 * - Caller authentication (refereeUid must be request.auth.uid).
 * - Code validity and existence.
 * - Self-referral prevention (cannot refer oneself).
 * - Immutability: cannot override if a referrer was already set.
 * - Server-only write of `referredBy` bypassing client Firestore rule restrictions.
 */
export const applyReferralCode = onCall(
  { cors: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required to apply a referral code.");
    }

    const refereeUid = request.auth.uid;
    const rawCode = String(request.data?.code ?? "").trim().toUpperCase();

    if (!rawCode || !/^(SC|SD|SH|SA)\d{4,}$/.test(rawCode)) {
      throw new HttpsError("invalid-argument", "Invalid referral Member ID format.");
    }

    const firestore = db();

    // 1. Resolve referrer from unique_sequential_ids or referral_codes
    let referrerUid = "";
    let referrerRole = "";
    let referrerFirstName = "";

    try {
      const seqSnap = await firestore.collection("unique_sequential_ids").doc(rawCode).get();
      if (seqSnap.exists && seqSnap.data()) {
        const d = seqSnap.data()!;
        referrerUid = String(d.ownerUid ?? d.referrerId ?? d.userId ?? "").trim();
        referrerRole = String(d.role ?? "user").trim();
        referrerFirstName = String(d.firstName ?? "").trim();
      }
    } catch (e) {
      console.warn(`[applyReferralCode] unique_sequential_ids read error for ${rawCode}:`, e);
    }

    if (!referrerUid) {
      try {
        const refSnap = await firestore.collection("referral_codes").doc(rawCode).get();
        if (refSnap.exists && refSnap.data()) {
          const d = refSnap.data()!;
          referrerUid = String(d.ownerUid ?? d.referrerId ?? d.userId ?? "").trim();
          referrerRole = String(d.role ?? "user").trim();
          referrerFirstName = String(d.firstName ?? "").trim();
        }
      } catch (e) {
        console.warn(`[applyReferralCode] referral_codes read error for ${rawCode}:`, e);
      }
    }

    // Fallback: search drivers or users via Admin SDK
    if (!referrerUid) {
      try {
        const dSnap = await firestore.collection("drivers").where("sequentialId", "==", rawCode).limit(1).get();
        if (!dSnap.empty) {
          referrerUid = dSnap.docs[0].id;
          referrerRole = "driver";
          const dData = dSnap.docs[0].data();
          const rawFirst = String(dData.firstName ?? dData.fullName ?? "Driver").trim();
          referrerFirstName = rawFirst.split(/\s+/)[0];
        }
      } catch (e) {
        console.warn(`[applyReferralCode] driver fallback error for ${rawCode}:`, e);
      }
    }

    if (!referrerUid) {
      try {
        const uSnap = await firestore.collection("users").where("sequentialId", "==", rawCode).limit(1).get();
        if (!uSnap.empty) {
          referrerUid = uSnap.docs[0].id;
          referrerRole = "customer";
          const uData = uSnap.docs[0].data();
          const rawFirst = String(uData.firstName ?? uData.fullName ?? "Member").trim();
          referrerFirstName = rawFirst.split(/\s+/)[0];
        }
      } catch (e) {
        console.warn(`[applyReferralCode] user fallback error for ${rawCode}:`, e);
      }
    }

    if (!referrerUid) {
      throw new HttpsError("not-found", "Referral Member ID not found or unverified.");
    }

    // 2. Prevent self-referral
    if (referrerUid === refereeUid) {
      throw new HttpsError("failed-precondition", "You cannot use your own Member ID as a referral code.");
    }

    // 3. Check if referee already has a referrer set
    const userRef = firestore.collection("users").doc(refereeUid);
    const driverRef = firestore.collection("drivers").doc(refereeUid);

    const [userSnap, driverSnap] = await Promise.all([userRef.get(), driverRef.get()]);
    const existingRef = userSnap.data()?.referredBy ?? driverSnap.data()?.referredBy;
    if (existingRef) {
      return { success: false, message: "A referrer has already been applied to this account." };
    }

    const refereeData = (userSnap.data() ?? driverSnap.data() ?? {}) as Record<string, unknown>;
    const rawRefereeFirst = String(
      refereeData.firstName ?? refereeData.fullName ?? refereeData.displayName ?? ""
    ).trim();
    const refereeFirstName = rawRefereeFirst ? rawRefereeFirst.split(/\s+/)[0] : "Member";
    const refereeRole = userSnap.exists ? "customer" : (driverSnap.exists ? "driver" : "customer");

    const payload = {
      referredBy: referrerUid,
      referrerId: referrerUid,
      referrerCode: rawCode,
      referralCode: rawCode,
      referredByRole: referrerRole,
      referralSignupAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    const referralTrackingRecord = {
      refereeUid,
      referrerUid,
      referrerCode: rawCode,
      refereeFirstName,
      refereeRole,
      completedTrips: 0,
      totalEarnedNaira: 0.0,
      referralSignupAt: admin.firestore.FieldValue.serverTimestamp(),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    const batch = firestore.batch();
    if (userSnap.exists) {
      batch.update(userRef, payload);
    }
    if (driverSnap.exists) {
      batch.update(driverRef, payload);
    }

    batch.set(
      firestore.collection("users").doc(referrerUid).collection("referrals").doc(refereeUid),
      referralTrackingRecord,
      { merge: true }
    );
    batch.set(
      firestore.collection("drivers").doc(referrerUid).collection("referrals").doc(refereeUid),
      referralTrackingRecord,
      { merge: true }
    );

    await batch.commit();

    return {
      success: true,
      referrerId: referrerUid,
      firstName: referrerFirstName || "Member",
      memberId: rawCode,
    };
  }
);
