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
var _a;
Object.defineProperty(exports, "__esModule", { value: true });
exports.bootstrapHubOwner = exports.PRIMARY_OWNER_EMAILS = void 0;
exports.isPlatformOwnerEmail = isPlatformOwnerEmail;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
/** Primary platform owners with inherent super admin bootstrap authority. */
exports.PRIMARY_OWNER_EMAILS = [
    "bamiduromichael2@gmail.com",
    "bamiduromichael1@gmail.com",
];
const envOwner = ((_a = process.env.OWNER_EMAIL) !== null && _a !== void 0 ? _a : "").trim().toLowerCase();
if (envOwner && !exports.PRIMARY_OWNER_EMAILS.includes(envOwner)) {
    exports.PRIMARY_OWNER_EMAILS.push(envOwner);
}
/** Check if an email is a recognized primary owner email. */
function isPlatformOwnerEmail(email) {
    if (!email)
        return false;
    const clean = email.trim().toLowerCase();
    return exports.PRIMARY_OWNER_EMAILS.includes(clean);
}
/**
 * Callable function: Bootstraps the primary owner's account.
 * - Mints `SUPER_ADMIN` custom claims on Firebase Auth
 * - Persists or updates the owner's `hub_staff/{email}` record with all permissions
 * Restricted strictly to the primary owner email.
 */
exports.bootstrapHubOwner = (0, https_1.onCall)(async (request) => {
    var _a;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
    const email = ((_a = request.auth.token.email) !== null && _a !== void 0 ? _a : "").trim().toLowerCase();
    if (!isPlatformOwnerEmail(email)) {
        throw new https_1.HttpsError("permission-denied", "Only the primary platform owner can trigger owner bootstrap.");
    }
    const uid = request.auth.uid;
    const db = admin.firestore();
    // 1. Set custom claims on Firebase Auth token
    try {
        const userRecord = await admin.auth().getUser(uid);
        await admin.auth().setCustomUserClaims(uid, Object.assign(Object.assign({}, (userRecord.customClaims || {})), { role: "SUPER_ADMIN", admin: true, adminAuth: true, broadcast: true, isVerified: true }));
    }
    catch (e) {
        console.warn(`bootstrapHubOwner: setCustomUserClaims failed for ${uid}: ${e}`);
    }
    // 2. Ensure hub_staff document exists with full permissions
    const allPermissions = [
        "active_rides",
        "fleet_verify",
        "user_onboarding",
        "dynamic_config",
        "support_chat",
        "process_payouts",
        "broadcast_notifications",
        "staff_manage",
        "edit_fares",
        "suspend_users",
        "p2p_limits",
        "document_review",
    ];
    await db.collection("hub_staff").doc(email).set({
        email,
        role: "Super",
        assignedPermissions: allPermissions,
        countryScope: "global",
        assignedBy: email,
        active: true,
        status: "active",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    return {
        success: true,
        email,
        role: "Super",
        message: `Account ${email} successfully bootstrapped as Platform Super Owner.`,
    };
});
//# sourceMappingURL=hubBootstrap.js.map