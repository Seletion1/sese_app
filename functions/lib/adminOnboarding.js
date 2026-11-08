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
function normPhone(phone) {
    if (!phone)
        return "";
    const cleaned = phone.replace(/[^\d+]/g, "");
    if (cleaned.startsWith("0")) {
        return "234" + cleaned.substring(1);
    }
    if (cleaned.startsWith("+")) {
        return cleaned.substring(1);
    }
    return cleaned;
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
    var _a, _b, _c, _d, _e, _f;
    await assertStaffWithManageUsersScope(request.auth);
    const identifier = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.identifier) !== null && _b !== void 0 ? _b : "").trim();
    if (!identifier) {
        throw new https_1.HttpsError("invalid-argument", "Phone number or email is required.");
    }
    const isEmail = identifier.includes("@");
    let userSnap = null;
    if (isEmail) {
        const q = await db().collection("users").where("email", "==", identifier.toLowerCase()).limit(1).get();
        if (!q.empty)
            userSnap = q.docs[0];
    }
    else {
        const phone = normPhone(identifier);
        const q = await db().collection("users").where("phoneNumber", "==", phone).limit(1).get();
        if (!q.empty)
            userSnap = q.docs[0];
    }
    if (!userSnap) {
        // Check Auth directly as fallback
        try {
            const authUser = isEmail
                ? await admin.auth().getUserByEmail(identifier.toLowerCase())
                : await admin.auth().getUserByPhoneNumber("+" + normPhone(identifier));
            const doc = await db().collection("users").doc(authUser.uid).get();
            if (doc.exists) {
                userSnap = doc;
            }
        }
        catch (_) { }
    }
    if (!userSnap) {
        return {
            exists: false,
            identifier,
            message: "No existing account found. Ready for new user registration.",
        };
    }
    const uid = userSnap.id;
    const userData = userSnap.data();
    const role = String((_c = userData.role) !== null && _c !== void 0 ? _c : "customer");
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
    if (!userData.fullName || !userData.phoneNumber)
        missingSteps.push("profile_details");
    if ((role === "driver" || role === "both") && vehicleCount === 0)
        missingSteps.push("vehicle_setup");
    if ((role === "driver" || role === "both") && !(driverData === null || driverData === void 0 ? void 0 : driverData.isProfileVerified))
        missingSteps.push("verification_approval");
    return {
        exists: true,
        uid,
        role,
        customerVerificationStatus: String((_d = userData.customerVerificationStatus) !== null && _d !== void 0 ? _d : "pending"),
        driverVerificationStatus: driverData ? String((_e = driverData.verificationStatus) !== null && _e !== void 0 ? _e : "pending") : null,
        vehicleCount,
        missingSteps,
        userData: {
            uid,
            fullName: userData.fullName,
            email: userData.email,
            phoneNumber: userData.phoneNumber,
            role: userData.role,
            createdByAdminId: (_f = userData.createdByAdminId) !== null && _f !== void 0 ? _f : null,
        },
        driverData,
    };
});
exports.sendOnboardingOtp = (0, https_1.onCall)(async (request) => {
    var _a, _b;
    await assertStaffWithManageUsersScope(request.auth);
    const identifier = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.identifier) !== null && _b !== void 0 ? _b : "").trim();
    if (!identifier) {
        throw new https_1.HttpsError("invalid-argument", "Identifier is required.");
    }
    const otp = String(Math.floor(100000 + Math.random() * 900000));
    const expiresAt = Date.now() + 10 * 60 * 1000; // 10 minutes
    await db().collection("onboarding_otps").doc(identifier.toLowerCase()).set({
        identifier: identifier.toLowerCase(),
        otp,
        verified: false,
        expiresAt,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdByAdminId: request.auth.uid,
    });
    console.log(`[sendOnboardingOtp] OTP generated for ${identifier}: ${otp}`);
    return {
        success: true,
        identifier,
        message: `OTP dispatched to ${identifier}.`,
    };
});
exports.verifyOnboardingOtp = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d;
    await assertStaffWithManageUsersScope(request.auth);
    const identifier = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.identifier) !== null && _b !== void 0 ? _b : "").trim().toLowerCase();
    const otp = String((_d = (_c = request.data) === null || _c === void 0 ? void 0 : _c.otp) !== null && _d !== void 0 ? _d : "").trim();
    if (!identifier || !otp) {
        throw new https_1.HttpsError("invalid-argument", "Identifier and OTP are required.");
    }
    const docRef = db().collection("onboarding_otps").doc(identifier);
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
        identifier,
        message: "OTP verified successfully.",
    };
});
exports.adminRegisterUser = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c;
    await assertStaffWithManageUsersScope(request.auth);
    const adminUid = request.auth.uid;
    const data = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    const role = data.role === "driver" ? "driver" : "customer";
    const fullName = String((_b = data.fullName) !== null && _b !== void 0 ? _b : "").trim();
    const phone = normPhone(data.phone);
    const email = data.email ? String(data.email).trim().toLowerCase() : undefined;
    if (!fullName) {
        throw new https_1.HttpsError("invalid-argument", "Full name is required.");
    }
    if (!phone) {
        throw new https_1.HttpsError("invalid-argument", "Phone number is required.");
    }
    const normPhoneStr = (0, uniqueIdentifiers_1.normalizeIdentifier)("phone", phone);
    const normEmailStr = email ? (0, uniqueIdentifiers_1.normalizeIdentifier)("email", email) : "";
    const normNinStr = data.ninNumber ? (0, uniqueIdentifiers_1.normalizeIdentifier)("nin", data.ninNumber) : "";
    const normPlateStr = ((_c = data.vehicleDetails) === null || _c === void 0 ? void 0 : _c.licensePlate)
        ? (0, uniqueIdentifiers_1.normalizeIdentifier)("plate_number", data.vehicleDetails.licensePlate)
        : "";
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
        var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p;
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
            fullName, phoneNumber: normPhoneStr, phoneNumberE164: normPhoneStr }, (normEmailStr ? { email: normEmailStr } : {})), { role, customerVerificationStatus: "pending_verification", isVerifiedCustomer: false, address: (_b = data.address) !== null && _b !== void 0 ? _b : "" }), (normNinStr ? { ninNumber: normNinStr } : {})), { createdByAdminId: adminUid, createdAt: now, updatedAt: now }), { merge: true });
        if (role === "driver") {
            const driverRef = db().collection("drivers").doc(uid);
            tx.set(driverRef, Object.assign(Object.assign({ driverId: uid, fullName, phone: normPhoneStr }, (normEmailStr ? { email: normEmailStr } : {})), { licenseNumber: (_d = (_c = data.driverDetails) === null || _c === void 0 ? void 0 : _c.licenseNumber) !== null && _d !== void 0 ? _d : "", licenseExpiry: (_f = (_e = data.driverDetails) === null || _e === void 0 ? void 0 : _e.licenseExpiry) !== null && _f !== void 0 ? _f : "", verificationStatus: "pending_verification", isProfileVerified: false, vehicleStatus: data.vehicleDetails ? "pending_verification" : "unregistered", photoUrl: (_g = data.livePhotoUrl) !== null && _g !== void 0 ? _g : "", createdByAdminId: adminUid, createdAt: now, updatedAt: now }), { merge: true });
            if (data.vehicleDetails && vehicleId) {
                const v = data.vehicleDetails;
                const vRef = db().collection("drivers").doc(uid).collection("vehicles").doc(vehicleId);
                const category = String((_h = v.category) !== null && _h !== void 0 ? _h : "car").toLowerCase();
                tx.set(vRef, {
                    id: vehicleId,
                    driverId: uid,
                    category,
                    make: (_j = v.make) !== null && _j !== void 0 ? _j : "",
                    model: (_k = v.model) !== null && _k !== void 0 ? _k : "",
                    year: (_l = v.year) !== null && _l !== void 0 ? _l : new Date().getFullYear(),
                    licensePlate: normPlateStr,
                    color: (_m = v.color) !== null && _m !== void 0 ? _m : "",
                    tier: (_o = v.tier) !== null && _o !== void 0 ? _o : null,
                    verificationStatus: "PENDING",
                    lifecycleStatus: "ACTIVE",
                    isActiveSelected: true,
                    documents: (_p = data.documents) !== null && _p !== void 0 ? _p : {},
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