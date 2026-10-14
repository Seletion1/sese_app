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
  sessionId?: string;
  fcmToken?: string;
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
  let activeVehicleId: string | null = null;
  let activeVehicleCategory: string | null = null;
  let activePlateNumber: string | null = null;

  try {
    const fleetSnap = await db()
      .collection("drivers")
      .doc(uid)
      .collection("vehicles")
      .limit(20)
      .get();
    
    let activeDoc = fleetSnap.docs.find((d) => {
      const data = d.data() ?? {};
      const canonical = String(data.verificationStatus ?? "").toUpperCase();
      const isAppr = canonical === "APPROVED" || canonical === "VERIFIED" || data.isVerified === true;
      return data.isActiveSelected === true && isAppr;
    });

    if (!activeDoc) {
      activeDoc = fleetSnap.docs.find((d) => {
        const data = d.data() ?? {};
        const canonical = String(data.verificationStatus ?? "").toUpperCase();
        return canonical === "APPROVED" || canonical === "VERIFIED" || data.isVerified === true;
      });
    }

    if (activeDoc) {
      const vData = activeDoc.data();
      activeVehicleId = activeDoc.id;
      activeVehicleCategory = String(vData.category ?? "car").toLowerCase();
      activePlateNumber = String(vData.licensePlate ?? vData.plateNumber ?? "");
    } else {
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
  const newSessionId = String(data.sessionId ?? db().collection("_").doc().id);
  const newFcmToken = data.fcmToken ? String(data.fcmToken) : null;

  // Single-device online session lock:
  // If the driver is already online on Device A and now goes online on Device B,
  // notify Device A via silent FCM and supersede its session.
  try {
    const prevStatusDoc = await db().collection("driver_status").doc(uid).get();
    if (prevStatusDoc.exists) {
      const prevData = prevStatusDoc.data() ?? {};
      const prevIsOnline = prevData.isOnline === true;
      const prevSessionId = prevData.activeSessionId ? String(prevData.activeSessionId) : null;
      const prevFcmToken = prevData.activeFcmToken ? String(prevData.activeFcmToken) : null;

      if (prevIsOnline && prevSessionId && prevSessionId !== newSessionId) {
        console.log(`[goOnline] Driver ${uid} superseding session ${prevSessionId} with ${newSessionId}`);
        let targetToken = prevFcmToken;
        if (!targetToken) {
          const userDoc = await db().collection("users").doc(uid).get();
          targetToken = userDoc.data()?.fcmToken;
        }
        if (targetToken && typeof targetToken === "string") {
          try {
            await admin.messaging().send({
              token: targetToken,
              data: {
                type: "DRIVER_SESSION_TERMINATED",
                reason: "MULTI_DEVICE_ONLINE",
                message: "You went online on another device. This session is now offline.",
                terminatedSessionId: prevSessionId,
                activeSessionId: newSessionId,
              },
              android: { priority: "high" },
              apns: {
                payload: {
                  aps: { "content-available": 1 },
                },
              },
            });
            console.log(`[goOnline] Silent FCM session termination sent for driver ${uid}`);
          } catch (fcmErr) {
            console.warn(`[goOnline] Failed to send termination FCM for driver ${uid}:`, fcmErr);
          }
        }
      }
    }
  } catch (e) {
    console.warn(`[goOnline] Session lock check error for driver ${uid}:`, e);
  }

  // Write authoritative online mirror (admin SDK bypasses firestore.rules which denies client writes)
  await db().collection("driver_status").doc(uid).set(
    {
      driverId: uid,
      isOnline: true,
      status: "active",
      activeSessionId: newSessionId,
      activeFcmToken: newFcmToken,
      lastFix: fix,
      activeVehicleId,
      activeVehicleCategory,
      activePlateNumber,
      updatedAt: now,
      onlineAt: now,
    },
    { merge: true }
  );

  await db().collection("drivers").doc(uid).set(
    {
      isOnline: true,
      activeSessionId: newSessionId,
      lastSeen: now,
      lastLocation: { lat: fix.latitude, lng: fix.longitude, updatedAt: Date.now() },
      activeVehicleId,
      activeVehicleCategory,
      activePlateNumber,
    },
    { merge: true }
  );

  return {
    granted: true,
    confirmed: true,
    status: "active",
    sessionId: newSessionId,
    message: "You are now ONLINE.",
  };
});

interface GoOfflineData {
  driverId?: string;
  sessionId?: string;
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
      activeSessionId: null,
      updatedAt: now,
    },
    { merge: true }
  );

  await db().collection("drivers").doc(uid).set(
    {
      isOnline: false,
      activeSessionId: null,
      lastSeen: now,
    },
    { merge: true }
  );

  return { granted: true, confirmed: true, status: "offline", message: "You are now OFFLINE." };
});

interface HubSetDriverOnlineStatusData {
  driverId: string;
  isOnline: boolean;
  reason?: string;
}

/**
 * Hub Admin control callable to manually switch a driver between Online and Offline.
 * Synchronizes both `drivers/{driverId}` and `driver_status/{driverId}` mirrors and
 * notifies the driver via high-priority FCM.
 */
export const hubSetDriverOnlineStatus = onCall<HubSetDriverOnlineStatusData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Staff must sign in to manage driver status.");
  }

  const callerUid = request.auth.uid;
  const callerEmail = (request.auth.token.email ?? "").trim().toLowerCase();
  const token = request.auth.token ?? {};
  const isSuperOrAdmin =
    token.admin === true ||
    token.adminAuth === true ||
    callerEmail === "bamiduromichael2@gmail.com";

  if (!isSuperOrAdmin) {
    let isStaff = false;
    if (callerEmail) {
      const snap = await db().collection("hub_staff").doc(callerEmail).get();
      if (snap.exists && snap.data()?.active !== false) {
        isStaff = true;
      }
    }
    if (!isStaff) {
      throw new HttpsError("permission-denied", "Only Hub staff or administrators can change driver status.");
    }
  }

  const { driverId, isOnline, reason } = request.data ?? {};
  if (!driverId || typeof isOnline !== "boolean") {
    throw new HttpsError("invalid-argument", "driverId and boolean isOnline status are required.");
  }

  const now = admin.firestore.FieldValue.serverTimestamp();

  if (isOnline) {
    const driverSnap = await db().collection("drivers").doc(driverId).get();
    if (!driverSnap.exists) {
      throw new HttpsError("not-found", "Driver profile not found.");
    }
    const driverData = driverSnap.data() ?? {};
    const lastLoc = driverData.lastLocation ?? { lat: 6.5244, lng: 3.3792 };
    const newSessionId = "hub_admin_" + db().collection("_").doc().id;

    await db().collection("driver_status").doc(driverId).set(
      {
        driverId,
        isOnline: true,
        status: "active",
        activeSessionId: newSessionId,
        lastFix: {
          latitude: lastLoc.lat,
          longitude: lastLoc.lng,
          accuracy: 10,
          timestamp: new Date().toISOString(),
        },
        updatedAt: now,
        onlineAt: now,
        manuallySetByAdmin: callerEmail || callerUid,
      },
      { merge: true }
    );

    await db().collection("drivers").doc(driverId).set(
      {
        isOnline: true,
        activeSessionId: newSessionId,
        lastSeen: now,
        manuallySetByAdmin: callerEmail || callerUid,
      },
      { merge: true }
    );

    // Notify driver device
    const userDoc = await db().collection("users").doc(driverId).get();
    const fcm = userDoc.data()?.fcmToken;
    if (fcm) {
      try {
        await admin.messaging().send({
          token: fcm,
          notification: {
            title: "Status Updated by Operations Desk",
            body: "Your driver account status was switched to ONLINE by an administrator.",
          },
          data: {
            type: "ADMIN_STATUS_TOGGLE",
            isOnline: "true",
          },
        });
      } catch (err) {
        console.warn(`[hubSetDriverOnlineStatus] Failed to notify driver ${driverId}:`, err);
      }
    }

    return { success: true, isOnline: true, message: `Driver status switched to ONLINE.` };
  } else {
    // Going offline
    await db().collection("driver_status").doc(driverId).set(
      {
        driverId,
        isOnline: false,
        status: "offline",
        activeSessionId: null,
        updatedAt: now,
        manuallySetByAdmin: callerEmail || callerUid,
        offlineReason: reason || "Switched offline by Hub Operations Desk",
      },
      { merge: true }
    );

    await db().collection("drivers").doc(driverId).set(
      {
        isOnline: false,
        activeSessionId: null,
        lastSeen: now,
        manuallySetByAdmin: callerEmail || callerUid,
      },
      { merge: true }
    );

    // Notify driver device
    const userDoc = await db().collection("users").doc(driverId).get();
    const fcm = userDoc.data()?.fcmToken;
    if (fcm) {
      try {
        await admin.messaging().send({
          token: fcm,
          notification: {
            title: "Status Updated by Operations Desk",
            body: reason || "Your driver account was switched to OFFLINE by an administrator.",
          },
          data: {
            type: "ADMIN_STATUS_TOGGLE",
            isOnline: "false",
          },
        });
      } catch (err) {
        console.warn(`[hubSetDriverOnlineStatus] Failed to notify driver ${driverId}:`, err);
      }
    }

    return { success: true, isOnline: false, message: `Driver status switched to OFFLINE.` };
  }
});

