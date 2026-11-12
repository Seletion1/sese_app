"use strict";
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
exports.hubSetDriverOnlineStatus = exports.goOffline = exports.goOnline = void 0;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const hubBootstrap_1 = require("./hubBootstrap");
const db = () => admin.firestore();
const LIVE_STATUSES = [
    "SEARCHING_DRIVER",
    "WAITING_FOR_ACCEPTANCE",
    "DRIVER_ACCEPTED",
    "DRIVER_ARRIVING",
    "IN_PROGRESS",
];
exports.goOnline = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in to go online.");
    }
    const uid = request.auth.uid;
    const data = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    const driverId = String((_b = data.driverId) !== null && _b !== void 0 ? _b : uid);
    // Enforce that a driver cannot go online for another driver
    if (driverId !== uid) {
        throw new https_1.HttpsError("permission-denied", "You can only go online for your own account.");
    }
    const fix = data.fix;
    if (!fix || typeof fix.latitude !== "number" || typeof fix.longitude !== "number") {
        throw new https_1.HttpsError("invalid-argument", "Valid GPS fix {latitude, longitude} is required.");
    }
    if (fix.isMocked === true) {
        throw new https_1.HttpsError("failed-precondition", "Mock location detected. Disable mock locations to go online.");
    }
    if (typeof fix.accuracy === "number" && fix.accuracy > 100) {
        throw new https_1.HttpsError("failed-precondition", "GPS accuracy too low. Move to open sky and try again.");
    }
    if (fix.latitude < -90 || fix.latitude > 90 || fix.longitude < -180 || fix.longitude > 180) {
        throw new https_1.HttpsError("invalid-argument", "GPS coordinates are outside valid bounds.");
    }
    // Suspension gate
    try {
        const userDoc = await db().collection("users").doc(uid).get();
        if (userDoc.exists && ((_c = userDoc.data()) === null || _c === void 0 ? void 0 : _c.isSuspended) === true) {
            throw new https_1.HttpsError("permission-denied", "Your account is suspended.");
        }
    }
    catch (e) {
        if (e instanceof https_1.HttpsError)
            throw e;
        // Non-fatal — continue
    }
    // Hub profile verification gate: drivers CANNOT go online until BOTH
    // `isProfileVerified == true` AND `isVehicleVerified == true`
    // (sese_hub admin toggles both flags after manual document audit).
    // Flags are absent on legacy documents — only an explicit `false`
    // denies here; the fleet guard below remains the vehicle source of truth.
    try {
        const driverDoc = await db().collection("drivers").doc(uid).get();
        const profile = (_d = driverDoc.data()) !== null && _d !== void 0 ? _d : {};
        if (profile.isProfileVerified === false) {
            throw new https_1.HttpsError("failed-precondition", "Account pending verification. Our team is reviewing your submission.");
        }
        if (profile.isVehicleVerified === false) {
            throw new https_1.HttpsError("failed-precondition", "No verified vehicle found. Register a vehicle and wait for admin approval before going online.");
        }
    }
    catch (e) {
        if (e instanceof https_1.HttpsError)
            throw e;
        // Non-fatal — fall through to the fleet guard below
    }
    // Fleet verification guard: strictly enforce single active approved vehicle.
    let activeVehicleId = null;
    let activeVehicleCategory = null;
    let activePlateNumber = null;
    try {
        const fleetSnap = await db()
            .collection("drivers")
            .doc(uid)
            .collection("vehicles")
            .limit(20)
            .get();
        const isApprovedDoc = (doc) => {
            var _a, _b, _c;
            const vData = (_a = doc.data()) !== null && _a !== void 0 ? _a : {};
            const canonical = String((_c = (_b = vData.verificationStatus) !== null && _b !== void 0 ? _b : vData.status) !== null && _c !== void 0 ? _c : "").toUpperCase();
            return canonical === "APPROVED" || canonical === "VERIFIED" || vData.isVerified === true;
        };
        const targetVehicleId = data.vehicleId ? String(data.vehicleId).trim() : null;
        let activeDoc;
        if (targetVehicleId) {
            // Driver explicitly requested a specific vehicle session ID
            activeDoc = fleetSnap.docs.find((d) => d.id === targetVehicleId);
            if (!activeDoc) {
                throw new https_1.HttpsError("not-found", "Requested vehicle not found in your fleet.");
            }
            if (!isApprovedDoc(activeDoc)) {
                throw new https_1.HttpsError("failed-precondition", "The selected vehicle is pending admin approval and cannot be used to go online.");
            }
        }
        else {
            // Look for a vehicle marked isActiveSelected === true
            activeDoc = fleetSnap.docs.find((d) => { var _a; return ((_a = d.data()) === null || _a === void 0 ? void 0 : _a.isActiveSelected) === true; });
            if (activeDoc) {
                if (!isApprovedDoc(activeDoc)) {
                    throw new https_1.HttpsError("failed-precondition", "The selected active vehicle is pending admin approval and cannot be used to go online.");
                }
            }
            else {
                // Fallback: if only 1 vehicle exists and it is approved, use it.
                const approvedDocs = fleetSnap.docs.filter(isApprovedDoc);
                if (approvedDocs.length === 1) {
                    activeDoc = approvedDocs[0];
                }
                else if (approvedDocs.length === 0) {
                    throw new https_1.HttpsError("failed-precondition", "No verified vehicle found. Register a vehicle and wait for admin approval before going online.");
                }
                else {
                    throw new https_1.HttpsError("failed-precondition", "Multiple approved vehicles found. Please select a specific verified vehicle before going online.");
                }
            }
        }
        if (activeDoc) {
            const vData = (_e = activeDoc.data()) !== null && _e !== void 0 ? _e : {};
            activeVehicleId = activeDoc.id;
            activeVehicleCategory = String((_f = vData.category) !== null && _f !== void 0 ? _f : "car").toLowerCase();
            activePlateNumber = String((_h = (_g = vData.licensePlate) !== null && _g !== void 0 ? _g : vData.plateNumber) !== null && _h !== void 0 ? _h : "");
            // Ensure isActiveSelected is atomically updated across fleet
            const batch = db().batch();
            for (const d of fleetSnap.docs) {
                batch.update(d.ref, {
                    isActiveSelected: d.id === activeVehicleId,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                });
            }
            await batch.commit();
        }
        else {
            throw new https_1.HttpsError("failed-precondition", "No verified vehicle found. Register a vehicle and wait for admin approval before going online.");
        }
    }
    catch (e) {
        if (e instanceof https_1.HttpsError)
            throw e;
        console.error(`goOnline[${uid}]: fleet guard read failed`, e);
        throw new https_1.HttpsError("failed-precondition", "Fleet verification check failed. Ensure a vehicle is approved.");
    }
    // Refuse if already in a live trip as assigned driver
    try {
        const activeTrips = await db()
            .collection("trips")
            .where("driver.driverId", "==", uid)
            .limit(5)
            .get();
        for (const doc of activeTrips.docs) {
            const status = String((_j = doc.data().status) !== null && _j !== void 0 ? _j : "");
            if (LIVE_STATUSES.includes(status)) {
                throw new https_1.HttpsError("failed-precondition", "You have an active trip. Complete it before changing status.");
            }
        }
    }
    catch (e) {
        if (e instanceof https_1.HttpsError)
            throw e;
    }
    const now = admin.firestore.FieldValue.serverTimestamp();
    const newSessionId = String((_k = data.sessionId) !== null && _k !== void 0 ? _k : db().collection("_").doc().id);
    const newFcmToken = data.fcmToken ? String(data.fcmToken) : null;
    // Single-device online session lock:
    // If the driver is already online on Device A and now goes online on Device B,
    // notify Device A via silent FCM and supersede its session.
    try {
        const prevStatusDoc = await db().collection("driver_status").doc(uid).get();
        if (prevStatusDoc.exists) {
            const prevData = (_l = prevStatusDoc.data()) !== null && _l !== void 0 ? _l : {};
            const prevIsOnline = prevData.isOnline === true;
            const prevSessionId = prevData.activeSessionId ? String(prevData.activeSessionId) : null;
            const prevFcmToken = prevData.activeFcmToken ? String(prevData.activeFcmToken) : null;
            if (prevIsOnline && prevSessionId && prevSessionId !== newSessionId) {
                console.log(`[goOnline] Driver ${uid} superseding session ${prevSessionId} with ${newSessionId}`);
                let targetToken = prevFcmToken;
                if (!targetToken) {
                    const userDoc = await db().collection("users").doc(uid).get();
                    targetToken = (_m = userDoc.data()) === null || _m === void 0 ? void 0 : _m.fcmToken;
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
                    }
                    catch (fcmErr) {
                        console.warn(`[goOnline] Failed to send termination FCM for driver ${uid}:`, fcmErr);
                    }
                }
            }
        }
    }
    catch (e) {
        console.warn(`[goOnline] Session lock check error for driver ${uid}:`, e);
    }
    // Write authoritative online mirror (admin SDK bypasses firestore.rules which denies client writes)
    await db().collection("driver_status").doc(uid).set({
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
    }, { merge: true });
    await db().collection("drivers").doc(uid).set({
        isOnline: true,
        activeSessionId: newSessionId,
        lastSeen: now,
        lastLocation: { lat: fix.latitude, lng: fix.longitude, updatedAt: Date.now() },
        activeVehicleId,
        activeVehicleCategory,
        activePlateNumber,
    }, { merge: true });
    return {
        granted: true,
        confirmed: true,
        status: "active",
        sessionId: newSessionId,
        message: "You are now ONLINE.",
    };
});
exports.goOffline = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in to go offline.");
    }
    const uid = request.auth.uid;
    const data = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    const driverId = String((_b = data.driverId) !== null && _b !== void 0 ? _b : uid);
    if (driverId !== uid) {
        throw new https_1.HttpsError("permission-denied", "You can only go offline for your own account.");
    }
    // Refuse while in a live trip
    try {
        const activeTrips = await db()
            .collection("trips")
            .where("driver.driverId", "==", uid)
            .limit(5)
            .get();
        for (const doc of activeTrips.docs) {
            const status = String((_c = doc.data().status) !== null && _c !== void 0 ? _c : "");
            if (LIVE_STATUSES.includes(status)) {
                throw new https_1.HttpsError("failed-precondition", "You have an active trip. Complete it before going offline.");
            }
        }
    }
    catch (e) {
        if (e instanceof https_1.HttpsError)
            throw e;
    }
    const now = admin.firestore.FieldValue.serverTimestamp();
    await db().collection("driver_status").doc(uid).set({
        driverId: uid,
        isOnline: false,
        status: "offline",
        activeSessionId: null,
        updatedAt: now,
    }, { merge: true });
    await db().collection("drivers").doc(uid).set({
        isOnline: false,
        activeSessionId: null,
        lastSeen: now,
    }, { merge: true });
    return { granted: true, confirmed: true, status: "offline", message: "You are now OFFLINE." };
});
/**
 * Hub Admin control callable to manually switch a driver between Online and Offline.
 * Synchronizes both `drivers/{driverId}` and `driver_status/{driverId}` mirrors and
 * notifies the driver via high-priority FCM.
 */
exports.hubSetDriverOnlineStatus = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Staff must sign in to manage driver status.");
    }
    const callerUid = request.auth.uid;
    const callerEmail = ((_a = request.auth.token.email) !== null && _a !== void 0 ? _a : "").trim().toLowerCase();
    const token = (_b = request.auth.token) !== null && _b !== void 0 ? _b : {};
    const isSuperOrAdmin = token.admin === true ||
        token.adminAuth === true ||
        token.role === "SUPER_ADMIN" ||
        (0, hubBootstrap_1.isPlatformOwnerEmail)(callerEmail) ||
        (process.env.OWNER_EMAIL && callerEmail === process.env.OWNER_EMAIL.trim().toLowerCase());
    if (!isSuperOrAdmin) {
        let isStaff = false;
        if (callerEmail) {
            const snap = await db().collection("hub_staff").doc(callerEmail).get();
            if (snap.exists && ((_c = snap.data()) === null || _c === void 0 ? void 0 : _c.active) !== false) {
                isStaff = true;
            }
        }
        if (!isStaff) {
            throw new https_1.HttpsError("permission-denied", "Only Hub staff or administrators can change driver status.");
        }
    }
    const { driverId, isOnline, reason } = (_d = request.data) !== null && _d !== void 0 ? _d : {};
    if (!driverId || typeof isOnline !== "boolean") {
        throw new https_1.HttpsError("invalid-argument", "driverId and boolean isOnline status are required.");
    }
    const now = admin.firestore.FieldValue.serverTimestamp();
    if (isOnline) {
        const driverSnap = await db().collection("drivers").doc(driverId).get();
        if (!driverSnap.exists) {
            throw new https_1.HttpsError("not-found", "Driver profile not found.");
        }
        const driverData = (_e = driverSnap.data()) !== null && _e !== void 0 ? _e : {};
        const lastLoc = (_f = driverData.lastLocation) !== null && _f !== void 0 ? _f : { lat: 6.5244, lng: 3.3792 };
        const newSessionId = "hub_admin_" + db().collection("_").doc().id;
        await db().collection("driver_status").doc(driverId).set({
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
        }, { merge: true });
        await db().collection("drivers").doc(driverId).set({
            isOnline: true,
            activeSessionId: newSessionId,
            lastSeen: now,
            manuallySetByAdmin: callerEmail || callerUid,
        }, { merge: true });
        // Notify driver device
        const userDoc = await db().collection("users").doc(driverId).get();
        const fcm = (_g = userDoc.data()) === null || _g === void 0 ? void 0 : _g.fcmToken;
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
            }
            catch (err) {
                console.warn(`[hubSetDriverOnlineStatus] Failed to notify driver ${driverId}:`, err);
            }
        }
        return { success: true, isOnline: true, message: `Driver status switched to ONLINE.` };
    }
    else {
        // Going offline
        await db().collection("driver_status").doc(driverId).set({
            driverId,
            isOnline: false,
            status: "offline",
            activeSessionId: null,
            updatedAt: now,
            manuallySetByAdmin: callerEmail || callerUid,
            offlineReason: reason || "Switched offline by Hub Operations Desk",
        }, { merge: true });
        await db().collection("drivers").doc(driverId).set({
            isOnline: false,
            activeSessionId: null,
            lastSeen: now,
            manuallySetByAdmin: callerEmail || callerUid,
        }, { merge: true });
        // Notify driver device
        const userDoc = await db().collection("users").doc(driverId).get();
        const fcm = (_h = userDoc.data()) === null || _h === void 0 ? void 0 : _h.fcmToken;
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
            }
            catch (err) {
                console.warn(`[hubSetDriverOnlineStatus] Failed to notify driver ${driverId}:`, err);
            }
        }
        return { success: true, isOnline: false, message: `Driver status switched to OFFLINE.` };
    }
});
//# sourceMappingURL=driverStatus.js.map