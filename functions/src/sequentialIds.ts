import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { assertHubStaffOrAdmin, _generateAndSaveReferralCode } from "./verification";

const db = () => admin.firestore();
const COUNTERS_DOC = "system_config/user_counters";

/**
 * Format a sequential number as "SC0001", "SD0001", "SH0001", growing past 4 digits naturally.
 * Customer prefix: "SC", Driver prefix: "SD", Staff prefix: "SH".
 */
export function formatSequentialId(role: "customer" | "driver" | "staff" | "hub", n: number): string {
  const prefix = role === "customer" ? "SC" : (role === "staff" || role === "hub" ? "SH" : "SD");
  return prefix + String(n).padStart(4, "0");
}

/**
 * Atomically assigns the next sequential ID to a user, driver, or hub staff document.
 * Idempotent — if sequentialId already exists on the doc and starts with SC/SD/SH,
 * returns it without writing anything or incrementing the counter.
 *
 * @param uid - The Firebase Auth UID / document ID / staff email ID.
 * @param role - "customer" | "driver" | "staff" | "hub"
 * @returns The assigned sequential ID string (e.g. "SC0001", "SD0001", "SH0001").
 */
export async function _assignSequentialId(
  uid: string,
  role: "customer" | "driver" | "staff" | "hub"
): Promise<string> {
  const firestore = db();
  const collection = role === "customer" ? "users" : (role === "staff" || role === "hub" ? "hub_staff" : "drivers");
  const docRef = firestore.collection(collection).doc(uid);
  const countersRef = firestore.doc(COUNTERS_DOC);
  const countField = role === "customer" ? "customerCount" : (role === "staff" || role === "hub" ? "staffCount" : "driverCount");

  return firestore.runTransaction(async (tx) => {
    const snap = await tx.get(docRef);
    if (snap.exists) {
      const existing = (snap.data() as Record<string, unknown>)?.sequentialId as string | undefined;
      if (existing && (existing.startsWith("SC") || existing.startsWith("SD") || existing.startsWith("SH"))) {
        return existing;
      }
    }

    const counterSnap = await tx.get(countersRef);
    const counterData = counterSnap.exists ? (counterSnap.data() as Record<string, number>) : {};
    const current = typeof counterData[countField] === "number" ? counterData[countField] : 0;
    const next = current + 1;
    const sequentialId = formatSequentialId(role, next);

    // Security assertion: Prevent 2 users from ever claiming or receiving the same sequential ID
    const uniqueIndexRef = firestore.collection("unique_sequential_ids").doc(sequentialId);
    const uniqueIndexSnap = await tx.get(uniqueIndexRef);
    if (uniqueIndexSnap.exists && uniqueIndexSnap.data()?.ownerUid !== uid) {
      throw new Error(`Sequential ID collision detected: ${sequentialId} already reserved.`);
    }

    tx.set(countersRef, { [countField]: next }, { merge: true });
    tx.set(uniqueIndexRef, {
      ownerUid: uid,
      role,
      sequentialId,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    if (snap.exists) {
      tx.update(docRef, { sequentialId });
    } else {
      tx.set(docRef, { sequentialId }, { merge: true });
    }

    return sequentialId;
  });
}

/**
 * Hub-only callable to backfill sequential IDs and verified referral codes
 * for all existing users, drivers, and hub staff.
 *
 * Ordering: Orders existing records by registration date (`createdAt` ascending)
 * so earlier registrants receive lower numbers.
 *
 * Safe to run multiple times:
 *  - Skips sequentialId if doc already has a valid "SC..." / "SD..." / "SH..." ID.
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
    const countersRef = firestore.doc(COUNTERS_DOC);

    const results = {
      customersSequentialAssigned: 0,
      customersReferralGenerated: 0,
      driversSequentialAssigned: 0,
      driversReferralGenerated: 0,
      staffSequentialAssigned: 0,
    };

    // ── 1. Backfill Customers ────────────────────────────────────────────────
    const usersSnap = await firestore.collection("users").orderBy("createdAt", "asc").get();

    for (const doc of usersSnap.docs) {
      const data = doc.data() as Record<string, unknown>;
      const existingSeqId = data.sequentialId as string | undefined;

      // Assign sequential ID if missing or invalid
      if (!existingSeqId || !existingSeqId.startsWith("SC")) {
        await firestore.runTransaction(async (tx) => {
          const counterSnap = await tx.get(countersRef);
          const counterData = counterSnap.exists ? (counterSnap.data() as Record<string, number>) : {};
          const current = typeof counterData["customerCount"] === "number" ? counterData["customerCount"] : 0;
          const next = current + 1;
          const sequentialId = formatSequentialId("customer", next);

          const uniqueIndexRef = firestore.collection("unique_sequential_ids").doc(sequentialId);
          tx.set(countersRef, { customerCount: next }, { merge: true });
          tx.set(uniqueIndexRef, {
            ownerUid: doc.id,
            role: "customer",
            sequentialId,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          tx.update(doc.ref, { sequentialId });
        });
        results.customersSequentialAssigned++;
      }

      // Check if eligible for referral code backfill (verified + phone + no code)
      const isVerified =
        data.isProfileVerified === true ||
        data.verificationStatus === "verified" ||
        data.verificationStatus === "approved" ||
        data.isVerifiedCustomer === true;
      const rawPhone = String(data.phoneNumberE164 ?? data.phoneNumber ?? data.phone ?? "").trim();
      const existingRefCode = String(data.referralCode ?? data.referralId ?? "").trim();

      if (isVerified && rawPhone.length > 0 && (!existingRefCode || existingRefCode.endsWith("0000"))) {
        try {
          const code = await _generateAndSaveReferralCode(doc.id, "users");
          if (code) results.customersReferralGenerated++;
        } catch (err) {
          console.warn(`Customer ${doc.id} referral code backfill failed:`, err);
        }
      }
    }

    // ── 2. Backfill Drivers ──────────────────────────────────────────────────
    const driversSnap = await firestore.collection("drivers").orderBy("createdAt", "asc").get();

    for (const doc of driversSnap.docs) {
      const data = doc.data() as Record<string, unknown>;
      const existingSeqId = data.sequentialId as string | undefined;

      // Assign sequential ID if missing or invalid
      if (!existingSeqId || !existingSeqId.startsWith("SD")) {
        await firestore.runTransaction(async (tx) => {
          const counterSnap = await tx.get(countersRef);
          const counterData = counterSnap.exists ? (counterSnap.data() as Record<string, number>) : {};
          const current = typeof counterData["driverCount"] === "number" ? counterData["driverCount"] : 0;
          const next = current + 1;
          const sequentialId = formatSequentialId("driver", next);

          const uniqueIndexRef = firestore.collection("unique_sequential_ids").doc(sequentialId);
          tx.set(countersRef, { driverCount: next }, { merge: true });
          tx.set(uniqueIndexRef, {
            ownerUid: doc.id,
            role: "driver",
            sequentialId,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          tx.update(doc.ref, { sequentialId });
        });
        results.driversSequentialAssigned++;
      }

      // Check if eligible for referral code backfill (verified + phone + no code)
      const isVerified =
        data.isProfileVerified === true ||
        data.verificationStatus === "verified" ||
        data.verificationStatus === "approved";
      const rawPhone = String(data.phone ?? data.phoneNumberE164 ?? data.phoneNumber ?? "").trim();
      const existingRefCode = String(data.referralCode ?? data.referralId ?? "").trim();

      if (isVerified && rawPhone.length > 0 && (!existingRefCode || existingRefCode.endsWith("0000"))) {
        try {
          const code = await _generateAndSaveReferralCode(doc.id, "drivers");
          if (code) results.driversReferralGenerated++;
        } catch (err) {
          console.warn(`Driver ${doc.id} referral code backfill failed:`, err);
        }
      }
    }

    // ── 3. Backfill Hub Staff ────────────────────────────────────────────────
    const staffSnap = await firestore.collection("hub_staff").get();

    for (const doc of staffSnap.docs) {
      const data = doc.data() as Record<string, unknown>;
      const existingSeqId = data.sequentialId as string | undefined;

      if (!existingSeqId || !existingSeqId.startsWith("SH")) {
        await firestore.runTransaction(async (tx) => {
          const counterSnap = await tx.get(countersRef);
          const counterData = counterSnap.exists ? (counterSnap.data() as Record<string, number>) : {};
          const current = typeof counterData["staffCount"] === "number" ? counterData["staffCount"] : 0;
          const next = current + 1;
          const sequentialId = formatSequentialId("staff", next);

          const uniqueIndexRef = firestore.collection("unique_sequential_ids").doc(sequentialId);
          tx.set(countersRef, { staffCount: next }, { merge: true });
          tx.set(uniqueIndexRef, {
            ownerUid: doc.id,
            role: "staff",
            sequentialId,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          tx.update(doc.ref, { sequentialId });
        });
        results.staffSequentialAssigned++;
      }
    }

    return {
      success: true,
      message: "Backfill completed successfully.",
      results,
    };
  }
);
