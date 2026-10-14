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
exports.onDriverVehicleVerified = exports.onDriverVerificationUpdated = exports.onUserVerificationUpdated = exports.reviewDriverVerification = exports.reviewCustomerVerification = void 0;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const firestore_1 = require("firebase-functions/v2/firestore");
const db = () => admin.firestore();
// ─── Referral Code Generation ────────────────────────────────────────────────
/**
 * Deterministically generates a unique referral code for a newly-verified
 * user or driver and persists it atomically to both the profile document and
 * the `referral_codes/{CODE}` lookup index.
 *
 * Algorithm:
 *   Base = FirstInitial + LastInitial + last-4-digits-of-phone (uppercase).
 *   If a collision is found (another user already owns that code), progressively
 *   prepend the next-preceding digit from the phone number until the code is
 *   unique (e.g. MB1592 → MB61592 → MB561592 …).
 *   Fallback when name/phone data is insufficient: "SE" + last-4-chars-of-uid.
 *
 * The function is idempotent: if the profile already has a `referralCode` it
 * returns immediately without writing anything.
 *
 * @param userId  - Firestore document ID (uid)
 * @param collection - "users" | "drivers"
 */
async function _generateAndSaveReferralCode(userId, collection) {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k;
    const firestore = db();
    const profileRef = firestore.collection(collection).doc(userId);
    // ── Idempotency check ──────────────────────────────────────────────────────
    const profileSnap = await profileRef.get();
    if (!profileSnap.exists) {
        console.warn(`_generateAndSaveReferralCode: ${collection}/${userId} not found, skipping.`);
        return;
    }
    const profileData = (_a = profileSnap.data()) !== null && _a !== void 0 ? _a : {};
    if (profileData.referralCode) {
        // Code already exists — nothing to do.
        return;
    }
    // ── Build the base candidate code ─────────────────────────────────────────
    const firstName = String((_c = (_b = profileData.firstName) !== null && _b !== void 0 ? _b : profileData.fullName) !== null && _c !== void 0 ? _c : "").trim();
    const lastName = String((_d = profileData.lastName) !== null && _d !== void 0 ? _d : "").trim();
    // For fullName-only profiles split on whitespace and take the last word as surname.
    const nameParts = firstName.split(/\s+/).filter(Boolean);
    const first = (_e = nameParts[0]) !== null && _e !== void 0 ? _e : "";
    const last = lastName.length > 0
        ? lastName
        : nameParts.length > 1
            ? nameParts[nameParts.length - 1]
            : first; // single-word name: repeat the initial
    const firstInitial = ((_g = (_f = first.match(/[A-Za-z]/)) === null || _f === void 0 ? void 0 : _f[0]) !== null && _g !== void 0 ? _g : "").toUpperCase();
    const lastInitial = ((_j = (_h = last.match(/[A-Za-z]/)) === null || _h === void 0 ? void 0 : _h[0]) !== null && _j !== void 0 ? _j : "").toUpperCase();
    const initials = firstInitial + lastInitial; // 2-char initials, or fewer if name is malformed
    const rawPhone = String((_k = profileData.phoneNumber) !== null && _k !== void 0 ? _k : "");
    const digits = rawPhone.replace(/\D/g, ""); // strip non-numeric chars
    // ── Attempt codes from shortest (4-digit suffix) to longest ───────────────
    // Minimum: initials (2 chars) + 4 trailing phone digits.
    // Fallback: "SE" + last 4 chars of uid when name/phone is insufficient.
    const useFallback = initials.length < 2 || digits.length < 4;
    let resolved = false;
    if (!useFallback) {
        // Progressive digit-prepend: start with last 4 digits, grow leftward.
        for (let suffixLen = 4; suffixLen <= digits.length && suffixLen <= 12; suffixLen++) {
            const numericSuffix = digits.slice(-suffixLen);
            const candidate = (initials + numericSuffix).toUpperCase();
            try {
                resolved = await firestore.runTransaction(async (tx) => {
                    var _a;
                    const codeRef = firestore.collection("referral_codes").doc(candidate);
                    const codeSnap = await tx.get(codeRef);
                    if (!codeSnap.exists) {
                        // Slot is free — claim it atomically.
                        tx.set(codeRef, {
                            referrerId: userId,
                            collection,
                            createdAt: admin.firestore.FieldValue.serverTimestamp(),
                        });
                        tx.update(profileRef, { referralCode: candidate });
                        return true; // success signal
                    }
                    if (((_a = codeSnap.data()) === null || _a === void 0 ? void 0 : _a.referrerId) === userId) {
                        // This user already owns this code (race/idempotence). Just
                        // ensure the profile field is written.
                        tx.update(profileRef, { referralCode: candidate });
                        return true;
                    }
                    // Real collision — abort this transaction without error and try
                    // a longer suffix in the next loop iteration.
                    return false;
                });
            }
            catch (err) {
                console.warn(`_generateAndSaveReferralCode: transaction error for ${candidate}:`, err);
                // Don't rethrow — try next suffix.
            }
            if (resolved)
                break;
        }
    }
    // ── Fallback: "SE" + last 4 chars of uid ──────────────────────────────────
    if (!resolved) {
        const fallbackBase = ("SE" + userId.slice(-4)).toUpperCase();
        // Try base, then base + more uid chars if even that collides.
        for (let extra = 0; extra <= 4; extra++) {
            const candidate = extra === 0
                ? fallbackBase
                : ("SE" + userId.slice(-(4 + extra))).toUpperCase();
            try {
                resolved = await firestore.runTransaction(async (tx) => {
                    var _a;
                    const codeRef = firestore.collection("referral_codes").doc(candidate);
                    const codeSnap = await tx.get(codeRef);
                    if (!codeSnap.exists || ((_a = codeSnap.data()) === null || _a === void 0 ? void 0 : _a.referrerId) === userId) {
                        tx.set(codeRef, {
                            referrerId: userId,
                            collection,
                            createdAt: admin.firestore.FieldValue.serverTimestamp(),
                        }, { merge: true });
                        tx.update(profileRef, { referralCode: candidate });
                        return true;
                    }
                    return false;
                });
            }
            catch (err) {
                console.warn(`_generateAndSaveReferralCode fallback error for ${candidate}:`, err);
            }
            if (resolved)
                break;
        }
    }
    if (!resolved) {
        console.error(`_generateAndSaveReferralCode: exhausted all candidates for ${collection}/${userId}. No code written.`);
    }
}
/**
 * Callable: reviewCustomerVerification
 *
 * Hub admins call this to approve or reject customer KYC verification.
 * Approving sets verificationStatus = 'verified' and custom claim isVerified = true.
 * Rejecting stores a structured rejection reason and sends an FCM push notification.
 */
exports.reviewCustomerVerification = (0, https_1.onCall)(async (request) => {
    var _a, _b;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
    const { userId, approved, rejectionReason } = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    if (!userId) {
        throw new https_1.HttpsError("invalid-argument", "userId is required.");
    }
    const userRef = db().collection("users").doc(userId);
    const userSnap = await userRef.get();
    if (!userSnap.exists) {
        throw new https_1.HttpsError("not-found", "User document not found.");
    }
    const userData = (_b = userSnap.data()) !== null && _b !== void 0 ? _b : {};
    if (approved && userData.createdByAdminId && userData.createdByAdminId === request.auth.uid) {
        throw new https_1.HttpsError("failed-precondition", "Self-Verification Lock: Admin who created this account cannot self-approve verification.");
    }
    if (approved) {
        await userRef.set({
            customerVerificationStatus: "verified",
            verificationStatus: "verified",
            isVerifiedCustomer: true,
            kycRejectionReason: "",
            verificationReviewedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        // Set custom claim isVerified = true
        try {
            const userRecord = await admin.auth().getUser(userId);
            await admin.auth().setCustomUserClaims(userId, Object.assign(Object.assign({}, (userRecord.customClaims || {})), { isVerified: true }));
        }
        catch (err) {
            console.warn(`Failed to set isVerified custom claim on ${userId}:`, err);
        }
        // Send FCM Push Notification
        try {
            await admin.messaging().send({
                topic: `user_${userId}`,
                notification: {
                    title: "Account Verified ✅",
                    body: "Your account verification has been approved.",
                },
                data: {
                    type: "kyc_approved",
                    userId,
                },
            });
        }
        catch (err) {
            console.warn(`FCM send failed for ${userId}:`, err);
        }
        // Generate referral code now that the user is verified.
        // Wrapped in try/catch — a code generation failure must never
        // roll back a successfully-completed verification approval.
        try {
            await _generateAndSaveReferralCode(userId, "users");
        }
        catch (err) {
            console.warn(`Referral code generation failed for user ${userId}:`, err);
        }
        return { success: true, status: "verified" };
    }
    else {
        const reason = (rejectionReason === null || rejectionReason === void 0 ? void 0 : rejectionReason.trim()) || "Documents could not be verified";
        await userRef.set({
            customerVerificationStatus: "rejected",
            verificationStatus: "rejected",
            isVerifiedCustomer: false,
            kycRejectionReason: reason,
            verificationReviewedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        // Set custom claim isVerified = false
        try {
            const userRecord = await admin.auth().getUser(userId);
            await admin.auth().setCustomUserClaims(userId, Object.assign(Object.assign({}, (userRecord.customClaims || {})), { isVerified: false }));
        }
        catch (err) {
            console.warn(`Failed to update custom claims on ${userId}:`, err);
        }
        // Send FCM Push Notification with rejection reason (body is generic,
        // reason is available in-app via kycRejectionReason field)
        try {
            await admin.messaging().send({
                topic: `user_${userId}`,
                notification: {
                    title: "Verification Update ⚠️",
                    body: "Verification update required. Please check your profile for details.",
                },
                data: {
                    type: "kyc_rejected",
                    userId,
                    reason,
                },
            });
        }
        catch (err) {
            console.warn(`FCM send failed for ${userId}:`, err);
        }
        return { success: true, status: "rejected", reason };
    }
});
/**
 * Callable: reviewDriverVerification
 *
 * Hub admins call this to approve or reject driver profile onboarding documents.
 */
exports.reviewDriverVerification = (0, https_1.onCall)(async (request) => {
    var _a, _b;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
    const { driverId, approved, rejectionReason } = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    if (!driverId) {
        throw new https_1.HttpsError("invalid-argument", "driverId is required.");
    }
    const driverRef = db().collection("drivers").doc(driverId);
    const driverSnap = await driverRef.get();
    if (!driverSnap.exists) {
        throw new https_1.HttpsError("not-found", "Driver document not found.");
    }
    const driverData = (_b = driverSnap.data()) !== null && _b !== void 0 ? _b : {};
    if (approved && driverData.createdByAdminId && driverData.createdByAdminId === request.auth.uid) {
        throw new https_1.HttpsError("failed-precondition", "Self-Verification Lock: Admin who created this driver account cannot self-approve verification.");
    }
    if (approved) {
        await driverRef.set({
            verificationStatus: "approved",
            isProfileVerified: true,
            isActive: true,
            profileRejectionReason: "",
            profileApprovedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        // Also set custom claim isVerified = true on the Auth user
        try {
            const userRecord = await admin.auth().getUser(driverId);
            await admin.auth().setCustomUserClaims(driverId, Object.assign(Object.assign({}, (userRecord.customClaims || {})), { isVerified: true }));
        }
        catch (err) {
            console.warn(`Failed to set isVerified custom claim on driver ${driverId}:`, err);
        }
        // Send FCM notification
        try {
            await admin.messaging().send({
                topic: `driver_${driverId}`,
                notification: {
                    title: "Account Verified ✅",
                    body: "Your account verification has been approved.",
                },
                data: {
                    type: "driver_approved",
                    driverId,
                },
            });
        }
        catch (err) {
            console.warn(`FCM send failed for driver ${driverId}:`, err);
        }
        // Generate referral code now that the driver is verified.
        try {
            await _generateAndSaveReferralCode(driverId, "drivers");
        }
        catch (err) {
            console.warn(`Referral code generation failed for driver ${driverId}:`, err);
        }
        return { success: true, status: "approved" };
    }
    else {
        const reason = (rejectionReason === null || rejectionReason === void 0 ? void 0 : rejectionReason.trim()) || "Driver documents could not be verified";
        await driverRef.set({
            verificationStatus: "rejected",
            isProfileVerified: false,
            isActive: false,
            profileRejectionReason: reason,
            rejectedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        try {
            const userRecord = await admin.auth().getUser(driverId);
            await admin.auth().setCustomUserClaims(driverId, Object.assign(Object.assign({}, (userRecord.customClaims || {})), { isVerified: false }));
        }
        catch (err) {
            console.warn(`Failed to update custom claims on driver ${driverId}:`, err);
        }
        // Send FCM notification (body is generic; reason stored in profileRejectionReason)
        try {
            await admin.messaging().send({
                topic: `driver_${driverId}`,
                notification: {
                    title: "Verification Update ⚠️",
                    body: "Verification update required. Please check your profile for details.",
                },
                data: {
                    type: "driver_rejected",
                    driverId,
                    reason,
                },
            });
        }
        catch (err) {
            console.warn(`FCM send failed for driver ${driverId}:`, err);
        }
        return { success: true, status: "rejected", reason };
    }
});
/**
 * Trigger: onUserVerificationUpdated
 *
 * Catches direct Firestore updates from sese_hub or console on users/{userId}.
 * Synchronizes custom claims and sends FCM push notification if status changed.
 */
exports.onUserVerificationUpdated = (0, firestore_1.onDocumentUpdated)("users/{userId}", async (event) => {
    var _a, _b, _c;
    const before = (_a = event.data) === null || _a === void 0 ? void 0 : _a.before.data();
    const after = (_b = event.data) === null || _b === void 0 ? void 0 : _b.after.data();
    if (!before || !after)
        return;
    const beforeStatus = before.customerVerificationStatus || before.verificationStatus;
    const afterStatus = after.customerVerificationStatus || after.verificationStatus;
    if (beforeStatus === afterStatus)
        return;
    const userId = event.params.userId;
    if (afterStatus === "verified") {
        try {
            const userRecord = await admin.auth().getUser(userId);
            if (!((_c = userRecord.customClaims) === null || _c === void 0 ? void 0 : _c.isVerified)) {
                await admin.auth().setCustomUserClaims(userId, Object.assign(Object.assign({}, (userRecord.customClaims || {})), { isVerified: true }));
            }
        }
        catch (err) {
            console.warn(`Trigger failed setting claim on ${userId}:`, err);
        }
        // Approval announcement: account verification completed.
        try {
            await admin.messaging().send({
                topic: `user_${userId}`,
                notification: {
                    title: "Account Verified ✅",
                    body: "Your account verification has been approved.",
                },
                android: {
                    priority: "high",
                    notification: { sound: "sese_alert_chime" },
                },
                apns: { payload: { aps: { sound: "default" } } },
                data: {
                    type: "kyc_approved",
                    userId,
                },
            });
        }
        catch (err) {
            console.warn(`Trigger FCM failed for ${userId}:`, err);
        }
        // Idempotent referral code generation — handles admin console edits
        // that bypass the reviewCustomerVerification callable.
        try {
            await _generateAndSaveReferralCode(userId, "users");
        }
        catch (err) {
            console.warn(`Trigger referral code generation failed for ${userId}:`, err);
        }
    }
    else if (afterStatus === "rejected") {
        const reason = after.kycRejectionReason || "Verification not approved";
        try {
            await admin.messaging().send({
                topic: `user_${userId}`,
                notification: {
                    title: "Verification Update ⚠️",
                    body: "Verification update required. Please check your profile for details.",
                },
                data: {
                    type: "kyc_rejected",
                    userId,
                    reason,
                },
            });
        }
        catch (err) {
            console.warn(`Trigger FCM failed for ${userId}:`, err);
        }
    }
});
/**
 * Trigger: onDriverVerificationUpdated
 *
 * Catches direct Firestore updates on drivers/{driverId}.
 */
exports.onDriverVerificationUpdated = (0, firestore_1.onDocumentUpdated)("drivers/{driverId}", async (event) => {
    var _a, _b, _c;
    const before = (_a = event.data) === null || _a === void 0 ? void 0 : _a.before.data();
    const after = (_b = event.data) === null || _b === void 0 ? void 0 : _b.after.data();
    if (!before || !after)
        return;
    const beforeStatus = before.verificationStatus;
    const afterStatus = after.verificationStatus;
    if (beforeStatus === afterStatus)
        return;
    const driverId = event.params.driverId;
    if (afterStatus === "approved" || afterStatus === "verified") {
        try {
            const userRecord = await admin.auth().getUser(driverId);
            if (!((_c = userRecord.customClaims) === null || _c === void 0 ? void 0 : _c.isVerified)) {
                await admin.auth().setCustomUserClaims(driverId, Object.assign(Object.assign({}, (userRecord.customClaims || {})), { isVerified: true }));
            }
        }
        catch (err) {
            console.warn(`Trigger failed setting claim on driver ${driverId}:`, err);
        }
        // Approval announcement: driver account verification completed.
        try {
            await admin.messaging().send({
                topic: `driver_${driverId}`,
                notification: {
                    title: "Account Verified ✅",
                    body: "Your driver verification has been approved.",
                },
                android: {
                    priority: "high",
                    notification: { sound: "sese_alert_chime" },
                },
                apns: { payload: { aps: { sound: "default" } } },
                data: {
                    type: "driver_approved",
                    driverId,
                },
            });
        }
        catch (err) {
            console.warn(`Trigger FCM failed for driver ${driverId}:`, err);
        }
        // Idempotent referral code generation — handles admin console edits
        // that bypass the reviewDriverVerification callable.
        try {
            await _generateAndSaveReferralCode(driverId, "drivers");
        }
        catch (err) {
            console.warn(`Trigger referral code generation failed for driver ${driverId}:`, err);
        }
    }
    else if (afterStatus === "rejected") {
        const reason = after.profileRejectionReason || "Profile not approved";
        try {
            await admin.messaging().send({
                topic: `driver_${driverId}`,
                notification: {
                    title: "Verification Update ⚠️",
                    body: "Verification update required. Please check your profile for details.",
                },
                data: {
                    type: "driver_rejected",
                    driverId,
                    reason,
                },
            });
        }
        catch (err) {
            console.warn(`Trigger FCM failed for driver ${driverId}:`, err);
        }
    }
});
/**
 * Trigger: onDriverVehicleVerified
 *
 * Catches hub fleet-desk transitions on
 * `drivers/{driverId}/vehicles/{vehicleId}` and announces the outcome to
 * the driver (high-priority audible push). Approval unblocks online
 * dispatch for that vehicle.
 */
exports.onDriverVehicleVerified = (0, firestore_1.onDocumentUpdated)("drivers/{driverId}/vehicles/{vehicleId}", async (event) => {
    var _a, _b, _c, _d, _e, _f;
    const before = (_a = event.data) === null || _a === void 0 ? void 0 : _a.before.data();
    const after = (_b = event.data) === null || _b === void 0 ? void 0 : _b.after.data();
    if (!before || !after)
        return;
    const beforeStatus = String((_d = (_c = before.verificationStatus) !== null && _c !== void 0 ? _c : before.status) !== null && _d !== void 0 ? _d : "").toUpperCase();
    const afterStatus = String((_f = (_e = after.verificationStatus) !== null && _e !== void 0 ? _e : after.status) !== null && _f !== void 0 ? _f : "").toUpperCase();
    if (beforeStatus === afterStatus)
        return;
    const driverId = event.params.driverId;
    const vehicleId = event.params.vehicleId;
    const label = [after.make, after.model, after.year]
        .filter(Boolean)
        .join(" ")
        .trim();
    const title = afterStatus === "APPROVED" || afterStatus === "VERIFIED"
        ? "Vehicle Verified ✅"
        : afterStatus === "REJECTED"
            ? "Vehicle Update ⚠️"
            : "Vehicle Update";
    const body = afterStatus === "APPROVED" || afterStatus === "VERIFIED"
        ? `${label || "Your vehicle"} is verified — you can go online with it.`
        : afterStatus === "REJECTED"
            ? `${label || "Your vehicle"} needs attention: ${after.rejectionReason || "check documents and resubmit."}`
            : `Vehicle status changed to ${afterStatus}.`;
    try {
        await admin.messaging().send({
            topic: `driver_${driverId}`,
            notification: { title, body },
            android: {
                priority: "high",
                notification: { sound: "sese_alert_chime" },
            },
            apns: { payload: { aps: { sound: "default" } } },
            data: {
                type: "vehicle_verification",
                driverId,
                vehicleId,
                status: afterStatus,
            },
        });
    }
    catch (err) {
        console.warn(`Vehicle FCM failed for driver ${driverId}:`, err);
    }
});
//# sourceMappingURL=verification.js.map