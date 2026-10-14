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
exports.lookupAccountForOnboarding = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
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
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
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
    return {
        success: true,
        identifier,
        message: `OTP dispatched to ${identifier}.`,
        devOtpHint: otp,
    };
});
exports.verifyOnboardingOtp = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
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
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Admin authentication required.");
    }
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
    let authUser;
    try {
        authUser = await admin.auth().getUserByPhoneNumber("+" + phone);
    }
    catch (_) {
        if (email) {
            try {
                authUser = await admin.auth().getUserByEmail(email);
            }
            catch (_) {
                authUser = await admin.auth().createUser({
                    phoneNumber: "+" + phone,
                    email,
                    displayName: fullName,
                });
            }
        }
        else {
            authUser = await admin.auth().createUser({
                phoneNumber: "+" + phone,
                displayName: fullName,
            });
        }
    }
    const uid = authUser.uid;
    const now = admin.firestore.FieldValue.serverTimestamp();
    // Create/Update user doc
    await db().collection("users").doc(uid).set(Object.assign(Object.assign({ uid,
        fullName, phoneNumber: phone, phoneNumberE164: "+" + phone }, (email ? { email } : {})), { role, customerVerificationStatus: "verified", isVerifiedCustomer: true, address: (_c = data.address) !== null && _c !== void 0 ? _c : "", ninNumber: (_d = data.ninNumber) !== null && _d !== void 0 ? _d : "", createdByAdminId: adminUid, createdAt: now, updatedAt: now }), { merge: true });
    // Set Auth Custom Claims
    try {
        await admin.auth().setCustomUserClaims(uid, Object.assign(Object.assign({}, (authUser.customClaims || {})), { role, isVerified: true }));
    }
    catch (e) {
        console.warn(`adminRegisterUser: setCustomUserClaims failed: ${e}`);
    }
    let vehicleId = null;
    if (role === "driver") {
        await db().collection("drivers").doc(uid).set(Object.assign(Object.assign({ driverId: uid, fullName,
            phone }, (email ? { email } : {})), { licenseNumber: (_f = (_e = data.driverDetails) === null || _e === void 0 ? void 0 : _e.licenseNumber) !== null && _f !== void 0 ? _f : "", licenseExpiry: (_h = (_g = data.driverDetails) === null || _g === void 0 ? void 0 : _g.licenseExpiry) !== null && _h !== void 0 ? _h : "", verificationStatus: "pending_verification", isProfileVerified: false, vehicleStatus: data.vehicleDetails ? "pending_verification" : "unregistered", photoUrl: (_j = data.livePhotoUrl) !== null && _j !== void 0 ? _j : "", createdByAdminId: adminUid, createdAt: now, updatedAt: now }), { merge: true });
        if (data.vehicleDetails) {
            const v = data.vehicleDetails;
            const vRef = db().collection("drivers").doc(uid).collection("vehicles").doc();
            vehicleId = vRef.id;
            const category = String((_k = v.category) !== null && _k !== void 0 ? _k : "car").toLowerCase();
            const licensePlate = String((_l = v.licensePlate) !== null && _l !== void 0 ? _l : "").toUpperCase();
            await vRef.set({
                id: vehicleId,
                driverId: uid,
                category,
                make: (_m = v.make) !== null && _m !== void 0 ? _m : "",
                model: (_o = v.model) !== null && _o !== void 0 ? _o : "",
                year: (_p = v.year) !== null && _p !== void 0 ? _p : new Date().getFullYear(),
                licensePlate,
                color: (_q = v.color) !== null && _q !== void 0 ? _q : "",
                tier: (_r = v.tier) !== null && _r !== void 0 ? _r : null,
                verificationStatus: "PENDING",
                lifecycleStatus: "ACTIVE",
                isActiveSelected: true,
                documents: (_s = data.documents) !== null && _s !== void 0 ? _s : {},
                createdByAdminId: adminUid,
                createdAt: now,
                updatedAt: now,
            });
            // Update root driver doc active vehicle mirror
            await db().collection("drivers").doc(uid).set({
                activeVehicleId: vehicleId,
                activeVehicleCategory: category,
                activePlateNumber: licensePlate,
                updatedAt: now,
            }, { merge: true });
        }
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