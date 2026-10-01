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
exports.goOffline = exports.goOnline = void 0;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const db = () => admin.firestore();
const LIVE_STATUSES = [
    "SEARCHING_DRIVER",
    "WAITING_FOR_ACCEPTANCE",
    "DRIVER_ACCEPTED",
    "DRIVER_ARRIVING",
    "IN_PROGRESS",
];
exports.goOnline = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e;
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
            var _a, _b, _c;
            const data = (_a = d.data()) !== null && _a !== void 0 ? _a : {};
            const canonical = String((_b = data.verificationStatus) !== null && _b !== void 0 ? _b : "").toUpperCase();
            const legacyStatus = String((_c = data.status) !== null && _c !== void 0 ? _c : "").toUpperCase();
            if (canonical === "APPROVED" || canonical === "VERIFIED")
                return true;
            if (data.isVerified === true)
                return true;
            if (legacyStatus === "ACTIVE" || legacyStatus === "APPROVED")
                return true;
            return false;
        });
        if (!hasApproved) {
            console.warn(`goOnline[${uid}]: no approved vehicle ` +
                `(${fleetSnap.size} vehicle docs scanned)`);
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
            const status = String((_e = doc.data().status) !== null && _e !== void 0 ? _e : "");
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
    // Write authoritative online mirror (admin SDK bypasses firestore.rules which denies client writes)
    await db().collection("driver_status").doc(uid).set({
        driverId: uid,
        isOnline: true,
        status: "active",
        lastFix: fix,
        updatedAt: now,
    }, { merge: true });
    await db().collection("drivers").doc(uid).set({
        isOnline: true,
        lastSeen: now,
        lastLocation: { lat: fix.latitude, lng: fix.longitude, updatedAt: Date.now() },
    }, { merge: true });
    return { granted: true, confirmed: true, status: "active", message: "You are now ONLINE." };
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
        updatedAt: now,
    }, { merge: true });
    await db().collection("drivers").doc(uid).set({
        isOnline: false,
        lastSeen: now,
    }, { merge: true });
    return { granted: true, confirmed: true, status: "offline", message: "You are now OFFLINE." };
});
//# sourceMappingURL=driverStatus.js.map