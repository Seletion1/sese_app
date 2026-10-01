import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";

const db = () => admin.firestore();

/**
 * Zero-trust driver availability handshake.
 * Server-authoritative online mirror: never trusts client self-assertion.
 * Validates JWT, suspension, fleet verification, GPS spoof sanity, and active-trip state.
 */

interface GoOnlineData {
  driverId?: string;
  fix?: {
    latitude: number;
    longitude: number;
    accuracy: number;
    timestamp: string;
    isMocked?: boolean;
  };
  idToken?: string;
}

const LIVE_STATUSES = [
  "SEARCHING_DRIVER",
  "WAITING_FOR_ACCEPTANCE",
  "DRIVER_ACCEPTED",
  "DRIVER_ARRIVING",
  "IN_PROGRESS",
];

export const goOnline = onCall<GoOnlineData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in to go online.");
  }
  const uid = request.auth.uid;
  const data = request.data ?? {};
  const driverId = String(data.driverId ?? uid);

  // Enforce that a driver cannot go online for another driver
  if (driverId !== uid) {
    throw new HttpsError("permission-denied", "You can only go online for your own account.");
  }

  const fix = data.fix;
  if (!fix || typeof fix.latitude !== "number" || typeof fix.longitude !== "number") {
    throw new HttpsError("invalid-argument", "Valid GPS fix {latitude, longitude} is required.");
  }
  if (fix.isMocked === true) {
    throw new HttpsError("failed-precondition", "Mock location detected. Disable mock locations to go online.");
  }
  if (typeof fix.accuracy === "number" && fix.accuracy > 100) {
    throw new HttpsError("failed-precondition", "GPS accuracy too low. Move to open sky and try again.");
  }
  if (fix.latitude < -90 || fix.latitude > 90 || fix.longitude < -180 || fix.longitude > 180) {
    throw new HttpsError("invalid-argument", "GPS coordinates are outside valid bounds.");
  }

  // Suspension gate
  try {
    const userDoc = await db().collection("users").doc(uid).get();
    if (userDoc.exists && userDoc.data()?.isSuspended === true) {
      throw new HttpsError("permission-denied", "Your account is suspended.");
    }
  } catch (e) {
    if (e instanceof HttpsError) throw e;
    // Non-fatal — continue
  }

  // Hub profile verification gate: drivers CANNOT go online until BOTH
  // `isProfileVerified == true` AND `isVehicleVerified == true`
  // (sese_hub admin toggles both flags after manual document audit).
  // Flags are absent on legacy documents — only an explicit `false`
  // denies here; the fleet guard below remains the vehicle source of truth.
  try {
    const driverDoc = await db().collection("drivers").doc(uid).get();
    const profile = driverDoc.data() ?? {};
    if (profile.isProfileVerified === false) {
      throw new HttpsError(
        "failed-precondition",
        "Account pending verification. Our team is reviewing your submission."
      );
    }
    if (profile.isVehicleVerified === false) {
      throw new HttpsError(
        "failed-precondition",
        "No verified vehicle found. Register a vehicle and wait for admin approval before going online."
      );
    }
  } catch (e) {
    if (e instanceof HttpsError) throw e;
    // Non-fatal — fall through to the fleet guard below
  }

  // Fleet verification guard: at least one APPROVED vehicle.
  // Tolerant across writer generations: hub writes canonical
  // `verificationStatus: "APPROVED"` + `isVerified: true` + `status: "active"`,
  // but legacy docs may carry "VERIFIED", "approved" (any casing), or only
  // the `isVerified` alias. A strict exact-match query would wrongly reject
  // hub-approved drivers, so scan the fleet and match case-insensitively.
  try {
    const fleetSnap = await db()
      .collection("drivers")
      .doc(uid)
      .collection("vehicles")
      .limit(20)
      .get();
    const hasApproved = fleetSnap.docs.some((d) => {
      const data = d.data() ?? {};
      const canonical = String(data.verificationStatus ?? "").toUpperCase();
      const legacyStatus = String(data.status ?? "").toUpperCase();
      if (canonical === "APPROVED" || canonical === "VERIFIED") return true;
      if (data.isVerified === true) return true;
      if (legacyStatus === "ACTIVE" || legacyStatus === "APPROVED") return true;
      return false;
    });
    if (!hasApproved) {
      console.warn(
        `goOnline[${uid}]: no approved vehicle ` +
          `(${fleetSnap.size} vehicle docs scanned)`
      );
      throw new HttpsError(
        "failed-precondition",
        "No verified vehicle found. Register a vehicle and wait for admin approval before going online."
      );
    }
  } catch (e) {
    if (e instanceof HttpsError) throw e;
    console.error(`goOnline[${uid}]: fleet guard read failed`, e);
    throw new HttpsError("failed-precondition", "Fleet verification check failed. Ensure a vehicle is approved.");
  }

  // Refuse if already in a live trip as assigned driver
  try {
    const activeTrips = await db()
      .collection("trips")
      .where("driver.driverId", "==", uid)
      .limit(5)
      .get();
    for (const doc of activeTrips.docs) {
      const status = String(doc.data().status ?? "");
      if (LIVE_STATUSES.includes(status)) {
        throw new HttpsError("failed-precondition", "You have an active trip. Complete it before changing status.");
      }
    }
  } catch (e) {
    if (e instanceof HttpsError) throw e;
  }

  const now = admin.firestore.FieldValue.serverTimestamp();

  // Write authoritative online mirror (admin SDK bypasses firestore.rules which denies client writes)
  await db().collection("driver_status").doc(uid).set(
    {
      driverId: uid,
      isOnline: true,
      status: "active",
      lastFix: fix,
      updatedAt: now,
    },
    { merge: true }
  );

  await db().collection("drivers").doc(uid).set(
    {
      isOnline: true,
      lastSeen: now,
      lastLocation: { lat: fix.latitude, lng: fix.longitude, updatedAt: Date.now() },
    },
    { merge: true }
  );

  return { granted: true, confirmed: true, status: "active", message: "You are now ONLINE." };
});

interface GoOfflineData {
  driverId?: string;
}

export const goOffline = onCall<GoOfflineData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in to go offline.");
  }
  const uid = request.auth.uid;
  const data = request.data ?? {};
  const driverId = String(data.driverId ?? uid);
  if (driverId !== uid) {
    throw new HttpsError("permission-denied", "You can only go offline for your own account.");
  }

  // Refuse while in a live trip
  try {
    const activeTrips = await db()
      .collection("trips")
      .where("driver.driverId", "==", uid)
      .limit(5)
      .get();
    for (const doc of activeTrips.docs) {
      const status = String(doc.data().status ?? "");
      if (LIVE_STATUSES.includes(status)) {
        throw new HttpsError("failed-precondition", "You have an active trip. Complete it before going offline.");
      }
    }
  } catch (e) {
    if (e instanceof HttpsError) throw e;
  }

  const now = admin.firestore.FieldValue.serverTimestamp();

  await db().collection("driver_status").doc(uid).set(
    {
      driverId: uid,
      isOnline: false,
      status: "offline",
      updatedAt: now,
    },
    { merge: true }
  );

  await db().collection("drivers").doc(uid).set(
    {
      isOnline: false,
      lastSeen: now,
    },
    { merge: true }
  );

  return { granted: true, confirmed: true, status: "offline", message: "You are now OFFLINE." };
});
