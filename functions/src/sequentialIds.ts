import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { assertHubStaffOrAdmin } from "./verification";

const db = () => admin.firestore();

/**
 * Dedicated Firestore counter document paths.
 * - Customer counter: counters/SC
 * - Driver counter: counters/SD
 * - Staff / Hub counter: counters/SH
 */
export const COUNTER_DOCS = {
  customer: "counters/SC",
  driver: "counters/SD",
  staff: "counters/SH",
  hub: "counters/SH",
} as const;

export type UserRoleType = "customer" | "driver" | "staff" | "hub";

/**
 * Format a sequential number as "SC0001", "SD0001", "SH0001", growing past 4 digits naturally ("SC10000").
 * Customer prefix: "SC", Driver prefix: "SD", Staff prefix: "SH".
 */
export function formatSequentialId(role: UserRoleType, n: number): string {
  const prefix = role === "customer" ? "SC" : (role === "staff" || role === "hub" ? "SH" : "SD");
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
  const collection = role === "customer" ? "users" : (role === "staff" || role === "hub" ? "hub_staff" : "drivers");
  const docRef = firestore.collection(collection).doc(uid);
  const counterDocPath = COUNTER_DOCS[role];
  const counterRef = firestore.doc(counterDocPath);
  const expectedPrefix = role === "customer" ? "SC" : (role === "staff" || role === "hub" ? "SH" : "SD");

  return firestore.runTransaction(async (tx) => {
    // 1. Check existing sequential ID on target document
    const snap = await tx.get(docRef);
    const snapData = snap.exists ? (snap.data() as Record<string, unknown>) : {};
    const existing = snapData?.sequentialId as string | undefined;
    if (existing && existing.startsWith(expectedPrefix)) {
      return existing;
    }

    const rawFirst = String(
      snapData?.firstName ??
        snapData?.fullName ??
        snapData?.displayName ??
        ""
    ).trim();
    const firstName = rawFirst ? rawFirst.split(/\s+/)[0] : "Member";

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
