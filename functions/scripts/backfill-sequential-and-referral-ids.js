/**
 * Standalone Backfill & Migration Script for Sequential User IDs and Verified Referral Codes.
 *
 * Usage:
 *   node scripts/backfill-sequential-and-referral-ids.js [--dry-run]
 *
 * Rules:
 *   1. Orders existing records by registration date (`createdAt` asc) from oldest to newest.
 *   2. Customers: "SC0001", "SC0002", ..., growing past 4 digits ("SC10000").
 *   3. Drivers: "SD0001", "SD0002", ..., growing past 4 digits ("SD10000").
 *   4. Skips records that already have a valid sequentialId.
 *   5. Backfills referralId for verified users/drivers with a valid phone number.
 *   6. Enforces immutability: never alters an existing non-placeholder referral code.
 */

const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();
const COUNTERS_DOC = "system_config/user_counters";
const isDryRun = process.argv.includes("--dry-run");

function formatSequentialId(role, n) {
  const prefix = role === "customer" ? "SC" : "SD";
  return prefix + String(n).padStart(4, "0");
}

function generateReferralCodeCandidate(profileData) {
  const fullName = String(profileData.fullName ?? profileData.displayName ?? "").trim();
  const firstName = String(profileData.firstName ?? "").trim();
  const lastName = String(profileData.lastName ?? "").trim();

  let fInitial = "X";
  let lInitial = "X";

  if (firstName.length > 0) {
    fInitial = (firstName.match(/[A-Za-z]/)?.[0] ?? "X").toUpperCase();
    lInitial = lastName.length > 0 ? (lastName.match(/[A-Za-z]/)?.[0] ?? fInitial).toUpperCase() : fInitial;
  } else if (fullName.length > 0) {
    const parts = fullName.split(/\s+/).filter(Boolean);
    if (parts.length === 1) {
      fInitial = (parts[0].match(/[A-Za-z]/)?.[0] ?? "X").toUpperCase();
      lInitial = fInitial;
    } else if (parts.length > 1) {
      fInitial = (parts[0].match(/[A-Za-z]/)?.[0] ?? "X").toUpperCase();
      lInitial = (parts[parts.length - 1].match(/[A-Za-z]/)?.[0] ?? fInitial).toUpperCase();
    }
  }

  const rawPhone = String(
    profileData.phoneNumberE164 ?? profileData.phoneNumber ?? profileData.phone ?? ""
  ).trim();
  const digits = rawPhone.replace(/\D/g, "");
  if (digits.length === 0) return null;

  const initials = (fInitial + lInitial).toUpperCase();
  const last4 = digits.length >= 4 ? digits.slice(-4) : digits.padStart(4, "0");
  return (initials + last4).toUpperCase();
}

async function runBackfill() {
  console.log(`[Backfill] Starting sequential ID & referral code backfill (dryRun: ${isDryRun})...`);

  const countersRef = db.doc(COUNTERS_DOC);
  let customerCount = 0;
  let driverCount = 0;

  const counterSnap = await countersRef.get();
  if (counterSnap.exists) {
    const data = counterSnap.data() || {};
    customerCount = typeof data.customerCount === "number" ? data.customerCount : 0;
    driverCount = typeof data.driverCount === "number" ? data.driverCount : 0;
  }

  console.log(`[Backfill] Current counters: customerCount=${customerCount}, driverCount=${driverCount}`);

  // ── 1. Customers ───────────────────────────────────────────────────────────
  console.log("[Backfill] Fetching customers ordered by createdAt asc...");
  const usersSnap = await db.collection("users").orderBy("createdAt", "asc").get();
  console.log(`[Backfill] Found ${usersSnap.docs.length} customer records.`);

  let customerSeqAssigned = 0;
  let customerRefAssigned = 0;

  for (const doc of usersSnap.docs) {
    const data = doc.data() || {};
    const existingSeq = data.sequentialId;
    const updates = {};

    if (!existingSeq || !existingSeq.startsWith("SC")) {
      customerCount++;
      const newSeqId = formatSequentialId("customer", customerCount);
      updates.sequentialId = newSeqId;
      customerSeqAssigned++;
      if (!isDryRun) {
        await db.collection("unique_sequential_ids").doc(newSeqId).set({
          ownerUid: doc.id,
          role: "customer",
          sequentialId: newSeqId,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      console.log(`  Assigning ${newSeqId} to user ${doc.id} (${data.fullName || 'Unnamed'})`);
    }

    // Referral code check
    const isVerified =
      data.isProfileVerified === true ||
      data.verificationStatus === "verified" ||
      data.verificationStatus === "approved" ||
      data.isVerifiedCustomer === true;
    const rawPhone = String(data.phoneNumberE164 ?? data.phoneNumber ?? data.phone ?? "").trim();
    const existingRef = String(data.referralCode ?? data.referralId ?? "").trim();

    if (isVerified && rawPhone.length > 0 && (!existingRef || existingRef.endsWith("0000"))) {
      const baseCode = generateReferralCodeCandidate(data);
      if (baseCode) {
        // Find unique candidate
        for (let counter = 0; counter < 50; counter++) {
          const candidate = counter === 0 ? baseCode : `${baseCode}${counter}`;
          const codeRef = db.collection("referral_codes").doc(candidate);
          const codeSnap = await codeRef.get();
          if (!codeSnap.exists || codeSnap.data()?.referrerId === doc.id) {
            updates.referralCode = candidate;
            updates.referralId = candidate;
            if (!isDryRun) {
              await codeRef.set({
                referrerId: doc.id,
                referralCode: candidate,
                referralId: candidate,
                collection: "users",
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
              });
            }
            customerRefAssigned++;
            console.log(`  Assigned referral ID ${candidate} to verified user ${doc.id}`);
            break;
          }
        }
      }
    }

    if (Object.keys(updates).length > 0 && !isDryRun) {
      await doc.ref.update(updates);
    }
  }

  // Update customer counter doc
  if (!isDryRun && customerSeqAssigned > 0) {
    await countersRef.set({ customerCount }, { merge: true });
  }

  // ── 2. Drivers ─────────────────────────────────────────────────────────────
  console.log("[Backfill] Fetching drivers ordered by createdAt asc...");
  const driversSnap = await db.collection("drivers").orderBy("createdAt", "asc").get();
  console.log(`[Backfill] Found ${driversSnap.docs.length} driver records.`);

  let driverSeqAssigned = 0;
  let driverRefAssigned = 0;

  for (const doc of driversSnap.docs) {
    const data = doc.data() || {};
    const existingSeq = data.sequentialId;
    const updates = {};

    if (!existingSeq || !existingSeq.startsWith("SD")) {
      driverCount++;
      const newSeqId = formatSequentialId("driver", driverCount);
      updates.sequentialId = newSeqId;
      driverSeqAssigned++;
      if (!isDryRun) {
        await db.collection("unique_sequential_ids").doc(newSeqId).set({
          ownerUid: doc.id,
          role: "driver",
          sequentialId: newSeqId,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      console.log(`  Assigning ${newSeqId} to driver ${doc.id} (${data.fullName || 'Unnamed'})`);
    }

    // Referral code check
    const isVerified =
      data.isProfileVerified === true ||
      data.verificationStatus === "verified" ||
      data.verificationStatus === "approved";
    const rawPhone = String(data.phone ?? data.phoneNumberE164 ?? data.phoneNumber ?? "").trim();
    const existingRef = String(data.referralCode ?? data.referralId ?? "").trim();

    if (isVerified && rawPhone.length > 0 && (!existingRef || existingRef.endsWith("0000"))) {
      const baseCode = generateReferralCodeCandidate(data);
      if (baseCode) {
        for (let counter = 0; counter < 50; counter++) {
          const candidate = counter === 0 ? baseCode : `${baseCode}${counter}`;
          const codeRef = db.collection("referral_codes").doc(candidate);
          const codeSnap = await codeRef.get();
          if (!codeSnap.exists || codeSnap.data()?.referrerId === doc.id) {
            updates.referralCode = candidate;
            updates.referralId = candidate;
            if (!isDryRun) {
              await codeRef.set({
                referrerId: doc.id,
                referralCode: candidate,
                referralId: candidate,
                collection: "drivers",
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
              });
            }
            driverRefAssigned++;
            console.log(`  Assigned referral ID ${candidate} to verified driver ${doc.id}`);
            break;
          }
        }
      }
    }

    if (Object.keys(updates).length > 0 && !isDryRun) {
      await doc.ref.update(updates);
    }
  }

  // Update driver counter doc
  if (!isDryRun && driverSeqAssigned > 0) {
    await countersRef.set({ driverCount }, { merge: true });
  }

  console.log("\n[Backfill] Summary:");
  console.log(`  Customers: ${customerSeqAssigned} sequential IDs assigned, ${customerRefAssigned} referral IDs generated.`);
  console.log(`  Drivers:   ${driverSeqAssigned} sequential IDs assigned, ${driverRefAssigned} referral IDs generated.`);
  console.log(`  Final counter doc: customerCount=${customerCount}, driverCount=${driverCount}`);
  console.log("[Backfill] Completed successfully.");
}

if (require.main === module) {
  runBackfill()
    .then(() => process.exit(0))
    .catch((err) => {
      console.error("[Backfill] Fatal error:", err);
      process.exit(1);
    });
}

module.exports = { runBackfill };
