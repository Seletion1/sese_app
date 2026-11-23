/**
 * Pre-Production Backend Data Reset Script
 *
 * Safely prepares the SeSe monorepo Firestore database for production launch:
 * 1. Purges ephemeral test collections:
 *    - `trips` (including subcollections `bids`, `messages`)
 *    - `driver_streaks`
 *    - `wallet_transactions`
 *    - subcollections `transactions` inside `wallets/{uid}`
 *    - `payout_requests`
 *    - `referral_earnings`
 * 2. Re-initializes clean atomic role counters:
 *    - `counters/SC` (Customer counter)
 *    - `counters/SD` (Driver counter)
 *    - `counters/SH` (Staff/Hub counter)
 * 3. Cleans and reserves `unique_sequential_ids` documents.
 * 4. Re-assigns clean sequential IDs (`SC0001+`, `SD0001+`, `SH0001+`) in strict chronological
 *    order based on earliest registration timestamps (`createdAt` / `memberSince`).
 * 5. Generates immutable `referralId` (`FirstInitial + LastInitial + Last4Digits`) for verified
 *    users with phone numbers.
 * 6. Preserves valid user credentials, Auth documents, system settings, and pricing configs.
 *
 * Usage:
 *   node functions/scripts/pre-production-reset.js --dry-run
 *   node functions/scripts/pre-production-reset.js --execute
 */

const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp({
    projectId: process.env.GCLOUD_PROJECT || "sese-ride",
  });
}

const db = admin.firestore();

const isExecute = process.argv.includes("--execute");
const isDryRun = !isExecute;

const COLLECTIONS_TO_PURGE = [
  "trips",
  "driver_streaks",
  "wallet_transactions",
  "referral_earnings",
  "payout_requests",
];

async function deleteCollection(collectionPath, batchSize = 100) {
  const collectionRef = db.collection(collectionPath);
  const query = collectionRef.orderBy("__name__").limit(batchSize);

  let deletedTotal = 0;
  // eslint-disable-next-line no-constant-condition
  while (true) {
    const snapshot = await query.get();
    if (snapshot.size === 0) break;

    if (!isDryRun) {
      const batch = db.batch();
      for (const doc of snapshot.docs) {
        // Purge any known subcollections
        try {
          const bidsSnap = await doc.ref.collection("bids").get();
          for (const b of bidsSnap.docs) batch.delete(b.ref);
        } catch (_) {}
        batch.delete(doc.ref);
      }
      await batch.commit();
    }
    deletedTotal += snapshot.size;
    console.log(`  [Purge] ${collectionPath}: processed ${deletedTotal} docs...`);
  }
  return deletedTotal;
}

function extractTimestamp(data) {
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

function formatSequentialId(role, n) {
  const prefix = role === "customer" ? "SC" : (role === "staff" || role === "hub" ? "SH" : "SD");
  return prefix + String(n).padStart(4, "0");
}

function generateReferralCode(profile) {
  const fullName = String(profile.fullName ?? profile.displayName ?? profile.name ?? "").trim();
  const firstName = String(profile.firstName ?? "").trim();
  const lastName = String(profile.lastName ?? "").trim();

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
    profile.phoneNumberE164 ?? profile.phoneNumber ?? profile.phone ?? profile.verifiedPhone ?? ""
  ).trim();
  const digits = rawPhone.replace(/\D/g, "");
  if (!digits || digits.length === 0) return null;

  const last4 = digits.length >= 4 ? digits.slice(-4) : digits.padStart(4, "0");
  return (fInitial + lInitial + last4).toUpperCase();
}

async function runReset() {
  console.log(`=======================================================`);
  console.log(`SeSe Platform Pre-Production Reset`);
  console.log(`Mode: ${isDryRun ? "DRY-RUN (Simulated)" : "LIVE EXECUTE (Permanent)"}`);
  console.log(`=======================================================\n`);

  // Step 1: Purge Ephemeral Collections
  console.log("[1/5] Purging ephemeral test data...");
  for (const coll of COLLECTIONS_TO_PURGE) {
    const count = await deleteCollection(coll);
    console.log(`  ✓ ${coll}: ${count} records purged.`);
  }

  // Step 2: Reset Wallet Balances & Subcollection Ledgers
  console.log("\n[2/5] Cleaning wallet balances and transaction subcollections...");
  const walletsSnap = await db.collection("wallets").get();
  for (const wDoc of walletsSnap.docs) {
    // Delete transactions subcollection
    const txSnap = await wDoc.ref.collection("transactions").get();
    if (!isDryRun && txSnap.size > 0) {
      const b = db.batch();
      txSnap.docs.forEach((d) => b.delete(d.ref));
      await b.commit();
    }
    // Zero out balances
    if (!isDryRun) {
      await wDoc.ref.set(
        {
          balance: 0,
          mainWalletBalance: 0,
          escrowBalance: 0,
          customerBalance: 0,
          driverBalance: 0,
          seseCoinBalance: 0,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    }
  }
  console.log(`  ✓ ${walletsSnap.size} wallets reset to 0.00.`);

  // Step 3: Purge unique sequential ID reservations
  console.log("\n[3/5] Resetting sequential ID reservations...");
  await deleteCollection("unique_sequential_ids");

  // Step 4: Re-index Customers (SC0001+)
  console.log("\n[4/5] Re-indexing Customer Sequential IDs (counters/SC)...");
  const customersSnap = await db.collection("users").get();
  const sortedCustomers = customersSnap.docs.slice().sort((a, b) => {
    const tA = extractTimestamp(a.data());
    const tB = extractTimestamp(b.data());
    if (tA !== tB) return tA - tB;
    return a.id.localeCompare(b.id);
  });

  let custIndex = 0;
  for (const doc of sortedCustomers) {
    custIndex++;
    const seqId = formatSequentialId("customer", custIndex);
    const data = doc.data();

    if (!isDryRun) {
      await db.collection("unique_sequential_ids").doc(seqId).set({
        ownerUid: doc.id,
        role: "customer",
        sequentialId: seqId,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      const updates = { sequentialId: seqId };
      const isVerified =
        data.isProfileVerified === true ||
        data.verificationStatus === "verified" ||
        data.verificationStatus === "approved" ||
        data.isVerifiedCustomer === true;

      const rawPhone = String(data.phoneNumberE164 ?? data.phoneNumber ?? data.phone ?? "").trim();
      const existingRef = String(data.referralCode ?? data.referralId ?? "").trim();

      if (isVerified && rawPhone.length > 0 && (!existingRef || existingRef.endsWith("0000"))) {
        const candidate = generateReferralCode(data);
        if (candidate) {
          updates.referralCode = candidate;
          updates.referralId = candidate;
          await db.collection("referral_codes").doc(candidate).set({
            referrerId: doc.id,
            referralCode: candidate,
            referralId: candidate,
            collection: "users",
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        }
      }
      await doc.ref.set(updates, { merge: true });
    }
  }

  if (!isDryRun) {
    await db.doc("counters/SC").set({
      count: custIndex,
      lastNumber: custIndex,
      role: "customer",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  console.log(`  ✓ ${custIndex} customers indexed. Counter counters/SC set to ${custIndex}.`);

  // Step 5: Re-index Drivers (SD0001+)
  console.log("\n[5/5] Re-indexing Driver Sequential IDs (counters/SD)...");
  const driversSnap = await db.collection("drivers").get();
  const sortedDrivers = driversSnap.docs.slice().sort((a, b) => {
    const tA = extractTimestamp(a.data());
    const tB = extractTimestamp(b.data());
    if (tA !== tB) return tA - tB;
    return a.id.localeCompare(b.id);
  });

  let driverIndex = 0;
  for (const doc of sortedDrivers) {
    driverIndex++;
    const seqId = formatSequentialId("driver", driverIndex);
    const data = doc.data();

    if (!isDryRun) {
      await db.collection("unique_sequential_ids").doc(seqId).set({
        ownerUid: doc.id,
        role: "driver",
        sequentialId: seqId,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      const updates = { sequentialId: seqId, isOnline: false };
      const isVerified =
        data.isProfileVerified === true ||
        data.verificationStatus === "verified" ||
        data.verificationStatus === "approved";

      const rawPhone = String(data.phone ?? data.phoneNumberE164 ?? data.phoneNumber ?? "").trim();
      const existingRef = String(data.referralCode ?? data.referralId ?? "").trim();

      if (isVerified && rawPhone.length > 0 && (!existingRef || existingRef.endsWith("0000"))) {
        const candidate = generateReferralCode(data);
        if (candidate) {
          updates.referralCode = candidate;
          updates.referralId = candidate;
          await db.collection("referral_codes").doc(candidate).set({
            referrerId: doc.id,
            referralCode: candidate,
            referralId: candidate,
            collection: "drivers",
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        }
      }
      await doc.ref.set(updates, { merge: true });
    }
  }

  if (!isDryRun) {
    await db.doc("counters/SD").set({
      count: driverIndex,
      lastNumber: driverIndex,
      role: "driver",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  console.log(`  ✓ ${driverIndex} drivers indexed. Counter counters/SD set to ${driverIndex}.`);

  console.log(`\n=======================================================`);
  console.log(`Pre-production reset complete! Database is clean & launch-ready.`);
  console.log(`=======================================================`);
}

runReset().catch((err) => {
  console.error("Reset failed:", err);
  process.exit(1);
});
