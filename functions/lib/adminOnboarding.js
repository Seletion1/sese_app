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
exports.adminRegisterUser = exports.verifyOnboardingOtp = exports.sendOnboardingOtp = exports.lookupAccountForOnboarding = void 0;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const uniqueIdentifiers_1 = require("./uniqueIdentifiers");
const hubBootstrap_1 = require("./hubBootstrap");
function db() {
    return admin.firestore();
}
/**
 * Asserts that the caller is authenticated as a staff member or administrator
 * with authority to manage users (or holding Super/Admin status or user_onboarding scope).
 */
async function assertStaffWithManageUsersScope(auth) {
    var _a, _b, _c, _d, _e;
    if (!auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
    const token = (_a = auth.token) !== null && _a !== void 0 ? _a : {};
    const email = String((_b = token.email) !== null && _b !== void 0 ? _b : "").trim().toLowerCase();
    // Fast path 1: Primary owner email
    if ((0, hubBootstrap_1.isPlatformOwnerEmail)(email))
        return;
    // Fast path 2: Custom claims indicating Super Admin / Admin
    const claimRole = String((_d = (_c = token.role) !== null && _c !== void 0 ? _c : token.adminRole) !== null && _d !== void 0 ? _d : "").toUpperCase();
    const isSuperOrAdminClaim = token.admin === true ||
        token.adminAuth === true ||
        claimRole === "SUPER_ADMIN" ||
        claimRole === "ROLE_SUPER_ADMIN" ||
        claimRole === "SUPER" ||
        claimRole === "ADMIN";
    if (isSuperOrAdminClaim)
        return;
    // Database lookup in hub_staff/{email}
    if (email) {
        try {
            const snap = await db().collection("hub_staff").doc(email).get();
            if (snap.exists) {
                const data = snap.data();
                if ((data === null || data === void 0 ? void 0 : data.active) !== false) {
                    const staffRole = String((_e = data === null || data === void 0 ? void 0 : data.role) !== null && _e !== void 0 ? _e : "").toUpperCase();
                    if (staffRole === "SUPER" || staffRole === "ADMIN" || staffRole === "SUPER_ADMIN") {
                        return;
                    }
                    const perms = data === null || data === void 0 ? void 0 : data.assignedPermissions;
                    const grants = Array.isArray(perms)
                        ? perms.map((p) => String(p).toLowerCase())
                        : [];
                    if (grants.includes("manageusers") ||
                        grants.includes("manage_users") ||
                        grants.includes("user_onboarding") ||
                        grants.includes("staff_manage")) {
                        return;
                    }
                }
            }
        }
        catch (e) {
            console.error(`assertStaffWithManageUsersScope: hub_staff lookup failed for ${email}:`, e);
        }
    }
    throw new https_1.HttpsError("permission-denied", "Only Hub staff members or administrators with user management scope can perform onboarding actions.");
}
exports.lookupAccountForOnboarding = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h;
    await assertStaffWithManageUsersScope(request.auth);
    const identifier = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.identifier) !== null && _b !== void 0 ? _b : "").trim();
    if (!identifier) {
        throw new https_1.HttpsError("invalid-argument", "Phone number or email is required.");
    }
    const isEmail = identifier.includes("@");
    let userSnap = null;
    let authUser = null;
    if (isEmail) {
        const normEmail = (0, uniqueIdentifiers_1.normalizeIdentifier)("email", identifier);
        const q = await db().collection("users").where("email", "==", normEmail).limit(1).get();
        if (!q.empty) {
            userSnap = q.docs[0];
        }
        else {
            // Fallback search with raw identifier
            const qRaw = await db().collection("users").where("email", "==", identifier.toLowerCase()).limit(1).get();
            if (!qRaw.empty)
                userSnap = qRaw.docs[0];
        }
    }
    else {
        const normPhoneStr = (0, uniqueIdentifiers_1.normalizeIdentifier)("phone", identifier);
        const barePhone = normPhoneStr.replace("+", "");
        // Query across E.164, raw, and alternate phone fields
        const q1 = await db().collection("users").where("phoneNumber", "==", normPhoneStr).limit(1).get();
        if (!q1.empty) {
            userSnap = q1.docs[0];
        }
        else {
            const q2 = await db().collection("users").where("phoneNumberE164", "==", normPhoneStr).limit(1).get();
            if (!q2.empty) {
                userSnap = q2.docs[0];
            }
            else {
                const q3 = await db().collection("users").where("phone", "==", normPhoneStr).limit(1).get();
                if (!q3.empty) {
                    userSnap = q3.docs[0];
                }
                else {
                    const q4 = await db().collection("users").where("phoneNumber", "==", barePhone).limit(1).get();
                    if (!q4.empty)
                        userSnap = q4.docs[0];
                }
            }
        }
    }
    if (!userSnap) {
        // Check Auth directly as fallback for incomplete registrations
        try {
            if (isEmail) {
                const normEmail = (0, uniqueIdentifiers_1.normalizeIdentifier)("email", identifier);
                authUser = await admin.auth().getUserByEmail(normEmail);
            }
            else {
                const normPhoneStr = (0, uniqueIdentifiers_1.normalizeIdentifier)("phone", identifier);
                authUser = await admin.auth().getUserByPhoneNumber(normPhoneStr);
            }
            if (authUser) {
                const doc = await db().collection("users").doc(authUser.uid).get();
                if (doc.exists) {
                    userSnap = doc;
                }
            }
        }
        catch (_) { }
    }
    if (!userSnap && !authUser) {
        return {
            exists: false,
            identifier,
            message: "No existing account found. Ready for new user registration.",
        };
    }
    const uid = userSnap ? userSnap.id : authUser.uid;
    const userData = userSnap
        ? userSnap.data()
        : {
            uid: authUser.uid,
            fullName: authUser.displayName || "",
            email: authUser.email || "",
            phoneNumber: authUser.phoneNumber || "",
            role: ((_c = authUser.customClaims) === null || _c === void 0 ? void 0 : _c.role) || "customer",
            customerVerificationStatus: "pending",
        };
    const role = String((_d = userData.role) !== null && _d !== void 0 ? _d : "customer");
    let driverData = null;
    let vehicleCount = 0;
    if (role === "driver" || role === "both") {
        const dSnap = await db().collection("drivers").doc(uid).get();
        if (dSnap.exists) {
            driverData = dSnap.data();
        }
        const vSnap = await db().collection("drivers").doc(uid).collection("vehicles").get();
        vehicleCount = vSnap.size;
    }
    const missingSteps = [];
    if (!userData.fullName || (!userData.phoneNumber && !userData.email))
        missingSteps.push("profile_details");
    if ((role === "driver" || role === "both") && vehicleCount === 0)
        missingSteps.push("vehicle_setup");
    if ((role === "driver" || role === "both") && !(driverData === null || driverData === void 0 ? void 0 : driverData.isProfileVerified))
        missingSteps.push("verification_approval");
    return {
        exists: true,
        uid,
        role,
        customerVerificationStatus: String((_e = userData.customerVerificationStatus) !== null && _e !== void 0 ? _e : "pending"),
        driverVerificationStatus: driverData ? String((_f = driverData.verificationStatus) !== null && _f !== void 0 ? _f : "pending") : null,
        vehicleCount,
        missingSteps,
        userData: {
            uid,
            fullName: userData.fullName || (authUser === null || authUser === void 0 ? void 0 : authUser.displayName) || "",
            email: userData.email || (authUser === null || authUser === void 0 ? void 0 : authUser.email) || "",
            phoneNumber: userData.phoneNumber || (authUser === null || authUser === void 0 ? void 0 : authUser.phoneNumber) || "",
            role: userData.role || ((_g = authUser === null || authUser === void 0 ? void 0 : authUser.customClaims) === null || _g === void 0 ? void 0 : _g.role) || "customer",
            createdByAdminId: (_h = userData.createdByAdminId) !== null && _h !== void 0 ? _h : null,
        },
        driverData,
    };
});
exports.sendOnboardingOtp = (0, https_1.onCall)(async (request) => {
    var _a, _b;
    await assertStaffWithManageUsersScope(request.auth);
    const rawIdentifier = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.identifier) !== null && _b !== void 0 ? _b : "").trim();
    if (!rawIdentifier) {
        throw new https_1.HttpsError("invalid-argument", "Identifier is required.");
    }
    const isEmail = rawIdentifier.includes("@");
    const normalizedIdentifier = isEmail
        ? (0, uniqueIdentifiers_1.normalizeIdentifier)("email", rawIdentifier)
        : (0, uniqueIdentifiers_1.normalizeIdentifier)("phone", rawIdentifier);
    const otp = String(Math.floor(100000 + Math.random() * 900000));
    const expiresAt = Date.now() + 10 * 60 * 1000; // 10 minutes
    await db().collection("onboarding_otps").doc(normalizedIdentifier).set({
        identifier: normalizedIdentifier,
        rawIdentifier,
        otp,
        verified: false,
        expiresAt,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdByAdminId: request.auth.uid,
    });
    console.log(`[sendOnboardingOtp] OTP generated for ${normalizedIdentifier}: ${otp}`);
    const isDev = process.env.FUNCTIONS_EMULATOR === "true" ||
        process.env.NODE_ENV !== "production";
    return {
        success: true,
        identifier: normalizedIdentifier,
        devOtpHint: isDev ? otp : undefined,
        message: `OTP dispatched to ${rawIdentifier}.`,
    };
});
exports.verifyOnboardingOtp = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d;
    await assertStaffWithManageUsersScope(request.auth);
    const rawIdentifier = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.identifier) !== null && _b !== void 0 ? _b : "").trim();
    const otp = String((_d = (_c = request.data) === null || _c === void 0 ? void 0 : _c.otp) !== null && _d !== void 0 ? _d : "").trim();
    if (!rawIdentifier || !otp) {
        throw new https_1.HttpsError("invalid-argument", "Identifier and OTP are required.");
    }
    const isEmail = rawIdentifier.includes("@");
    const normalizedIdentifier = isEmail
        ? (0, uniqueIdentifiers_1.normalizeIdentifier)("email", rawIdentifier)
        : (0, uniqueIdentifiers_1.normalizeIdentifier)("phone", rawIdentifier);
    const docRef = db().collection("onboarding_otps").doc(normalizedIdentifier);
    const snap = await docRef.get();
    if (!snap.exists) {
        throw new https_1.HttpsError("not-found", "No OTP record found. Please request a new code.");
    }
    const data = snap.data();
    if (data.expiresAt < Date.now()) {
        throw new https_1.HttpsError("deadline-exceeded", "OTP has expired. Please request a new code.");
    }
    if (String(data.otp) !== otp) {
        throw new https_1.HttpsError("invalid-argument", "Incorrect OTP code.");
    }
    await docRef.update({
        verified: true,
        verifiedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return {
        success: true,
        verified: true,
        identifier: normalizedIdentifier,
        message: "OTP verified successfully.",
    };
});
exports.adminRegisterUser = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f;
    await assertStaffWithManageUsersScope(request.auth);
    const adminUid = request.auth.uid;
    const data = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    const role = data.role === "driver" ? "driver" : "customer";
    const fullName = String((_b = data.fullName) !== null && _b !== void 0 ? _b : "").trim();
    const rawPhone = String((_c = data.phone) !== null && _c !== void 0 ? _c : "").trim();
    const rawEmail = data.email ? String(data.email).trim().toLowerCase() : undefined;
    if (!fullName) {
        throw new https_1.HttpsError("invalid-argument", "Full name is required.");
    }
    if (!rawPhone) {
        throw new https_1.HttpsError("invalid-argument", "Phone number is required.");
    }
    const normPhoneStr = (0, uniqueIdentifiers_1.normalizeIdentifier)("phone", rawPhone);
    const normEmailStr = rawEmail ? (0, uniqueIdentifiers_1.normalizeIdentifier)("email", rawEmail) : "";
    const normNinStr = data.ninNumber ? (0, uniqueIdentifiers_1.normalizeIdentifier)("nin", data.ninNumber) : "";
    const normPlateStr = ((_d = data.vehicleDetails) === null || _d === void 0 ? void 0 : _d.licensePlate)
        ? (0, uniqueIdentifiers_1.normalizeIdentifier)("plate_number", data.vehicleDetails.licensePlate)
        : "";
    // Verify OTP verification status unless in dev/emulator mode
    const isDev = process.env.FUNCTIONS_EMULATOR === "true" ||
        process.env.NODE_ENV !== "production";
    if (!isDev) {
        const phoneOtpSnap = await db().collection("onboarding_otps").doc(normPhoneStr).get();
        const emailOtpSnap = normEmailStr
            ? await db().collection("onboarding_otps").doc(normEmailStr).get()
            : null;
        const phoneVerified = phoneOtpSnap.exists && ((_e = phoneOtpSnap.data()) === null || _e === void 0 ? void 0 : _e.verified) === true;
        const emailVerified = emailOtpSnap && emailOtpSnap.exists && ((_f = emailOtpSnap.data()) === null || _f === void 0 ? void 0 : _f.verified) === true;
        if (!phoneVerified && !emailVerified) {
            throw new https_1.HttpsError("failed-precondition", "Phone or email must be verified via OTP before registration can be finalized.");
        }
    }
    let authUser;
    try {
        authUser = await admin.auth().getUserByPhoneNumber(normPhoneStr);
    }
    catch (_) {
        if (normEmailStr) {
            try {
                authUser = await admin.auth().getUserByEmail(normEmailStr);
            }
            catch (_) {
                authUser = await admin.auth().createUser({
                    phoneNumber: normPhoneStr,
                    email: normEmailStr,
                    displayName: fullName,
                });
            }
        }
        else {
            authUser = await admin.auth().createUser({
                phoneNumber: normPhoneStr,
                displayName: fullName,
            });
        }
    }
    const uid = authUser.uid;
    let vehicleId = null;
    if (role === "driver" && data.vehicleDetails) {
        vehicleId = db().collection("drivers").doc(uid).collection("vehicles").doc().id;
    }
    await db().runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t;
        // 1. ALL READS: read user doc and uniqueness docs
        const userRef = db().collection("users").doc(uid);
        const userSnap = await tx.get(userRef);
        const oldIdentifiers = [];
        if (userSnap.exists) {
            const old = (_a = userSnap.data()) !== null && _a !== void 0 ? _a : {};
            if (old.phoneNumber)
                oldIdentifiers.push({ type: "phone", value: old.phoneNumber });
            if (old.email)
                oldIdentifiers.push({ type: "email", value: old.email });
            if (old.ninNumber)
                oldIdentifiers.push({ type: "nin", value: old.ninNumber });
        }
        const identifiers = [
            { type: "phone", value: normPhoneStr },
        ];
        if (normEmailStr) {
            identifiers.push({ type: "email", value: normEmailStr });
        }
        if (normNinStr) {
            identifiers.push({ type: "nin", value: normNinStr });
        }
        if (normPlateStr && vehicleId) {
            identifiers.push({ type: "plate_number", value: normPlateStr, entityId: vehicleId });
        }
        // Atomic uniqueness verification & reservation
        await (0, uniqueIdentifiers_1.assertAndReserveIdentifiersTx)({
            tx,
            ownerUid: uid,
            ownerCollection: "users",
            identifiers,
            oldIdentifiers,
        });
        const now = admin.firestore.FieldValue.serverTimestamp();
        // 2. ALL WRITES: user doc, driver doc, vehicle doc
        tx.set(userRef, Object.assign(Object.assign(Object.assign(Object.assign({ uid,
            fullName, phoneNumber: normPhoneStr, phoneNumberE164: normPhoneStr }, (normEmailStr ? { email: normEmailStr } : {})), { role, customerVerificationStatus: "pending", isVerifiedCustomer: false, address: (_b = data.address) !== null && _b !== void 0 ? _b : "" }), (normNinStr ? { ninNumber: normNinStr } : {})), { createdByAdminId: adminUid, createdAt: userSnap.exists ? ((_d = (_c = userSnap.data()) === null || _c === void 0 ? void 0 : _c.createdAt) !== null && _d !== void 0 ? _d : now) : now, updatedAt: now }), { merge: true });
        if (role === "driver") {
            const driverRef = db().collection("drivers").doc(uid);
            const dSnap = await tx.get(driverRef);
            tx.set(driverRef, Object.assign(Object.assign({ driverId: uid, fullName, phone: normPhoneStr }, (normEmailStr ? { email: normEmailStr } : {})), { licenseNumber: (_f = (_e = data.driverDetails) === null || _e === void 0 ? void 0 : _e.licenseNumber) !== null && _f !== void 0 ? _f : "", licenseExpiry: (_h = (_g = data.driverDetails) === null || _g === void 0 ? void 0 : _g.licenseExpiry) !== null && _h !== void 0 ? _h : "", verificationStatus: "pending_verification", isProfileVerified: false, vehicleStatus: data.vehicleDetails ? "pending_verification" : "unregistered", photoUrl: (_j = data.livePhotoUrl) !== null && _j !== void 0 ? _j : "", createdByAdminId: adminUid, createdAt: dSnap.exists ? ((_l = (_k = dSnap.data()) === null || _k === void 0 ? void 0 : _k.createdAt) !== null && _l !== void 0 ? _l : now) : now, updatedAt: now }), { merge: true });
            if (data.vehicleDetails && vehicleId) {
                const v = data.vehicleDetails;
                const vRef = db().collection("drivers").doc(uid).collection("vehicles").doc(vehicleId);
                const category = String((_m = v.category) !== null && _m !== void 0 ? _m : "car").toLowerCase();
                tx.set(vRef, {
                    id: vehicleId,
                    driverId: uid,
                    category,
                    make: (_o = v.make) !== null && _o !== void 0 ? _o : "",
                    model: (_p = v.model) !== null && _p !== void 0 ? _p : "",
                    year: (_q = v.year) !== null && _q !== void 0 ? _q : new Date().getFullYear(),
                    licensePlate: normPlateStr,
                    color: (_r = v.color) !== null && _r !== void 0 ? _r : "",
                    tier: (_s = v.tier) !== null && _s !== void 0 ? _s : null,
                    verificationStatus: "PENDING",
                    lifecycleStatus: "ACTIVE",
                    isActiveSelected: true,
                    documents: (_t = data.documents) !== null && _t !== void 0 ? _t : {},
                    createdByAdminId: adminUid,
                    createdAt: now,
                    updatedAt: now,
                });
                tx.set(driverRef, {
                    activeVehicleId: vehicleId,
                    activeVehicleCategory: category,
                    activePlateNumber: normPlateStr,
                    updatedAt: now,
                }, { merge: true });
            }
        }
    });
    // Set Auth Custom Claims
    try {
        await admin.auth().setCustomUserClaims(uid, Object.assign(Object.assign({}, (authUser.customClaims || {})), { role, isVerified: false }));
    }
    catch (e) {
        console.warn(`adminRegisterUser: setCustomUserClaims failed: ${e}`);
    }
    return {
        success: true,
        uid,
        role,
        vehicleId,
        message: `Account for ${fullName} (${role}) provisioned successfully by admin. Self-Verification Lock active — final approval requires independent admin review.`,
    };
});
//# sourceMappingURL=adminOnboarding.js.map