/**
 * Standalone Backfill & Migration Script for Sequential User IDs and Verified Referral Codes.
 *
 * Usage:
 *   node scripts/backfill-sequential-and-referral-ids.js [--dry-run] [--reset-all]
 *
 * Rules:
 *   1. Orders existing records strictly by earliest registration date
 *      (`createdAt` / `memberSince` asc) from oldest to newest.
 *   2. Customers: "SC0001", "SC0002", ..., growing past 4 digits ("SC10000").
 *   3. Drivers: "SD0001", "SD0002", ..., growing past 4 digits ("SD10000").
 *   4. Hub Staff: "SH0001", "SH0002", ..., growing past 4 digits ("SH10000").
 *   5. Writes to dedicated counter documents: `counters/SC`, `counters/SD`, `counters/SH`.
 *   6. Backfills referralId for verified users/drivers with a valid phone number.
 *   7. Enforces immutability: never alters an existing non-placeholder referral code.
 */

const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp({
    projectId: "sese-ride",
  });
}

const db = admin.firestore();
const isDryRun = process.argv.includes("--dry-run");
const isResetAll = process.argv.includes("--reset-all");

const COUNTER_DOCS = {
  customer: "counters/SC",
  driver: "counters/SD",
  staff: "counters/SH",
  hub: "counters/SH",
};

function formatSequentialId(role, n) {
  const prefix = role === "customer" ? "SC" : (role === "staff" || role === "hub" ? "SH" : "SD");
  return prefix + String(n).padStart(4, "0");
}

function extractRegistrationTimestamp(data) {
  const raw = data.createdAt ?? data.memberSince ?? data.registeredAt ?? data.joinedAt;
  if (!raw) return Number.MAX_SAFE_INTEGER;
  if (typeof raw.toMillis === "function") return raw.toMillis();
  if (typeof raw.toDate === "function") return raw.toDate().getTime();
  if (raw instanceof Date) return raw.getTime();
  if (typeof raw === "number") return raw;
  if (typeof raw === "string") {
    const p = Date.parse(raw);
    if (!isNaN(p)) return p;
  }
  return Number.MAX_SAFE_INTEGER;
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
  console.log(`[Backfill] Starting sequential ID & referral code backfill (dryRun: ${isDryRun}, resetAll: ${isResetAll})...`);

  // ── 1. Customers ───────────────────────────────────────────────────────────
  console.log("[Backfill] Fetching customers (sorted by earliest timestamp)...");
  const usersSnap = await db.collection("users").get();
  const sortedUsers = usersSnap.docs.slice().sort((a, b) => {
    const tA = extractRegistrationTimestamp(a.data());
    const tB = extractRegistrationTimestamp(b.data());
    if (tA !== tB) return tA - tB;
    return a.id.localeCompare(b.id);
  });
  console.log(`[Backfill] Found ${sortedUsers.length} customer records.`);

  let customerSeqAssigned = 0;
  let customerRefAssigned = 0;
  let customerCount = 0;

  for (const doc of sortedUsers) {
    customerCount++;
    const data = doc.data() || {};
    const existingSeq = data.sequentialId;
    const expectedSeqId = formatSequentialId("customer", customerCount);
    const updates = {};

    if (isResetAll || !existingSeq || !existingSeq.startsWith("SC") || existingSeq !== expectedSeqId) {
      updates.sequentialId = expectedSeqId;
      customerSeqAssigned++;
      if (!isDryRun) {
        await db.collection("unique_sequential_ids").doc(expectedSeqId).set({
          ownerUid: doc.id,
          role: "customer",
          sequentialId: expectedSeqId,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      console.log(`  Assigning ${expectedSeqId} to customer ${doc.id} (${data.fullName || 'Unnamed'})`);
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

  // Update dedicated customer counter doc counters/SC
  if (!isDryRun) {
    await db.doc(COUNTER_DOCS.customer).set({
      count: customerCount,
      lastNumber: customerCount,
      role: "customer",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    console.log(`[Backfill] Customer counter counters/SC set to ${customerCount}`);
  }

  // ── 2. Drivers ─────────────────────────────────────────────────────────────
  console.log("[Backfill] Fetching drivers (sorted by earliest timestamp)...");
  const driversSnap = await db.collection("drivers").get();
  const sortedDrivers = driversSnap.docs.slice().sort((a, b) => {
    const tA = extractRegistrationTimestamp(a.data());
    const tB = extractRegistrationTimestamp(b.data());
    if (tA !== tB) return tA - tB;
    return a.id.localeCompare(b.id);
  });
  console.log(`[Backfill] Found ${sortedDrivers.length} driver records.`);

  let driverSeqAssigned = 0;
  let driverRefAssigned = 0;
  let driverCount = 0;

  for (const doc of sortedDrivers) {
    driverCount++;
    const data = doc.data() || {};
    const existingSeq = data.sequentialId;
    const expectedSeqId = formatSequentialId("driver", driverCount);
    const updates = {};

    if (isResetAll || !existingSeq || !existingSeq.startsWith("SD") || existingSeq !== expectedSeqId) {
      updates.sequentialId = expectedSeqId;
      driverSeqAssigned++;
      if (!isDryRun) {
        await db.collection("unique_sequential_ids").doc(expectedSeqId).set({
          ownerUid: doc.id,
          role: "driver",
          sequentialId: expectedSeqId,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      console.log(`  Assigning ${expectedSeqId} to driver ${doc.id} (${data.fullName || 'Unnamed'}, memberSince: ${data.memberSince})`);
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

  // Update dedicated driver counter doc counters/SD
  if (!isDryRun) {
    await db.doc(COUNTER_DOCS.driver).set({
      count: driverCount,
      lastNumber: driverCount,
      role: "driver",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    console.log(`[Backfill] Driver counter counters/SD set to ${driverCount}`);
  }

  // ── 3. Hub Staff ───────────────────────────────────────────────────────────
  console.log("[Backfill] Fetching hub staff (sorted by earliest timestamp)...");
  const staffSnap = await db.collection("hub_staff").get();
  const sortedStaff = staffSnap.docs.slice().sort((a, b) => {
    const tA = extractRegistrationTimestamp(a.data());
    const tB = extractRegistrationTimestamp(b.data());
    if (tA !== tB) return tA - tB;
    return a.id.localeCompare(b.id);
  });
  console.log(`[Backfill] Found ${sortedStaff.length} hub staff records.`);

  let staffSeqAssigned = 0;
  let staffCount = 0;

  for (const doc of sortedStaff) {
    staffCount++;
    const data = doc.data() || {};
    const existingSeq = data.sequentialId;
    const expectedSeqId = formatSequentialId("staff", staffCount);
    const updates = {};

    if (isResetAll || !existingSeq || !existingSeq.startsWith("SH") || existingSeq !== expectedSeqId) {
      updates.sequentialId = expectedSeqId;
      staffSeqAssigned++;
      if (!isDryRun) {
        await db.collection("unique_sequential_ids").doc(expectedSeqId).set({
          ownerUid: doc.id,
          role: "staff",
          sequentialId: expectedSeqId,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        await doc.ref.update(updates);
      }
      console.log(`  Assigning ${expectedSeqId} to staff ${doc.id} (${data.email || 'Unnamed'})`);
    }
  }

  // Update dedicated staff counter doc counters/SH
  if (!isDryRun) {
    await db.doc(COUNTER_DOCS.staff).set({
      count: staffCount,
      lastNumber: staffCount,
      role: "staff",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    console.log(`[Backfill] Staff counter counters/SH set to ${staffCount}`);
  }

  console.log("[Backfill] Summary:");
  console.log(`  Customers: ${customerSeqAssigned} sequential IDs updated, ${customerRefAssigned} referral codes generated. (Counter: ${customerCount})`);
  console.log(`  Drivers: ${driverSeqAssigned} sequential IDs updated, ${driverRefAssigned} referral codes generated. (Counter: ${driverCount})`);
  console.log(`  Staff: ${staffSeqAssigned} sequential IDs updated. (Counter: ${staffCount})`);
  console.log("[Backfill] Completed.");
}

runBackfill().catch((err) => {
  console.error("[Backfill] Fatal error:", err);
  process.exit(1);
});
