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
exports.sendTargetedBroadcast = void 0;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
/**
 * Granular targeted push broadcast engine.
 *
 * `sendTargetedBroadcast` (callable): an authorized admin submits title +
 * body + audience filters; the function resolves matching users, writes one
 * inbox record per user under `users/{uid}/notifications`, and fans out a
 * high-priority FCM multicast (Doze-bypassing, default sound, tap opens the
 * app; the client renders it on `sese_high_priority_alerts`).
 *
 * Auth: primary owner email, or an active `hub_staff` record with role
 * `Super` / `Admin` holding the `broadcast_notifications` grant. (Owner
 * always qualifies; Agents need the explicit grant like every module.)
 *
 * Audience resolution (bounded — MAX_TARGETS per broadcast):
 * - mode `userIds`: explicit uid list (deduped, capped).
 * - mode `global`: every doc with an `fcmToken` in `users` + `drivers`.
 * - mode `segment`: role slice (`users` by `role`, and/or `drivers`),
 *   then `country` / `state` equality on stored fields, then — drivers
 *   only — an approved vehicle of `vehicleCategory` in
 *   `drivers/{uid}/vehicles`.
 *
 * Tokens come from `fcmToken` fields written by the apps at startup
 * (`PushNotificationService.registerToken`). Docs without a token still
 * get the inbox record (pull) but no push.
 */
const db = () => admin.firestore();
const OWNER_EMAIL = "bamiduromichael2@gmail.com";
const BROADCAST_PERM = "broadcast_notifications";
/** Hard fan-out ceiling per broadcast (FCM multicast limit is 500). */
const MAX_TARGETS = 500;
/** Firestore batch ceiling is 500; stay well under with overhead. */
const BATCH_SIZE = 400;
/** Cap for the explicit user-ID list. */
const MAX_USER_IDS = 100;
async function assertBroadcastAdmin(uid, email, token) {
    var _a, _b, _c;
    // Custom-claims fast path (defense in depth alongside the hub_staff RBAC
    // lookup below): accounts minted with an admin claim qualify immediately.
    try {
        const claims = token !== null && token !== void 0 ? token : {};
        const role = String((_b = (_a = claims.role) !== null && _a !== void 0 ? _a : claims.adminRole) !== null && _b !== void 0 ? _b : "").toUpperCase();
        if (claims.adminAuth === true ||
            claims.admin === true ||
            claims.broadcast === true ||
            role === "SUPER_ADMIN" ||
            role === "ROLE_SUPER_ADMIN" ||
            role === "SUPER" ||
            role === "ADMIN") {
            return;
        }
    }
    catch (_d) {
        // Fall through to the RBAC lookup.
    }
    const mail = (email !== null && email !== void 0 ? email : "").trim().toLowerCase();
    if (mail === OWNER_EMAIL)
        return;
    if (mail) {
        try {
            const snap = await db().collection("hub_staff").doc(mail).get();
            const data = snap.data();
            if (snap.exists && (data === null || data === void 0 ? void 0 : data.active) !== false) {
                const role = String((_c = data === null || data === void 0 ? void 0 : data.role) !== null && _c !== void 0 ? _c : "");
                const perms = data === null || data === void 0 ? void 0 : data.assignedPermissions;
                const grants = Array.isArray(perms)
                    ? perms.map((p) => String(p))
                    : [];
                if (role === "Super" || grants.includes(BROADCAST_PERM))
                    return;
            }
        }
        catch (e) {
            console.error(`sendTargetedBroadcast admin lookup failed: ${e}`);
        }
    }
    throw new https_1.HttpsError("permission-denied", "Broadcasts require Super Admin or an explicit broadcast grant.");
}
function cleanStr(v, max) {
    return String(v !== null && v !== void 0 ? v : "")
        .trim()
        .slice(0, max);
}
function tokenOf(data) {
    const t = data === null || data === void 0 ? void 0 : data.fcmToken;
    return typeof t === "string" && t.trim() ? t.trim() : null;
}
/** True when a driver has an approved vehicle of [categoryName]. */
async function driverHasVehicleCategory(uid, categoryName) {
    try {
        const snap = await db()
            .collection("drivers")
            .doc(uid)
            .collection("vehicles")
            .where("category", "==", categoryName)
            .limit(5)
            .get();
        return snap.docs.some((d) => {
            const v = d.data();
            return ((v === null || v === void 0 ? void 0 : v.verificationStatus) === "approved" ||
                (v === null || v === void 0 ? void 0 : v.isApproved) === true ||
                (v === null || v === void 0 ? void 0 : v.status) === "approved");
        });
    }
    catch (e) {
        console.error(`sendTargetedBroadcast vehicle check failed for ${uid}: ${e}`);
        return false;
    }
}
exports.sendTargetedBroadcast = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Sign in to send broadcasts.");
    }
    await assertBroadcastAdmin(request.auth.uid, request.auth.token.email, request.auth.token);
    const d = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    const title = cleanStr(d.title, 80);
    const body = cleanStr(d.body, 500);
    if (!title || !body) {
        throw new https_1.HttpsError("invalid-argument", "Title and message body are required.");
    }
    const audience = String((_b = d.audience) !== null && _b !== void 0 ? _b : "all");
    const mode = String((_c = d.mode) !== null && _c !== void 0 ? _c : "segment");
    if (!["all", "customers", "drivers"].includes(audience)) {
        throw new https_1.HttpsError("invalid-argument", "Unknown audience.");
    }
    if (!["segment", "userIds", "global"].includes(mode)) {
        throw new https_1.HttpsError("invalid-argument", "Unknown targeting mode.");
    }
    const country = d.country == null || String(d.country).trim() === ""
        ? null
        : String(d.country).trim().toUpperCase();
    const state = d.state == null || String(d.state).trim() === ""
        ? null
        : String(d.state).trim();
    const vehicleCategory = d.vehicleCategory == null || String(d.vehicleCategory).trim() === ""
        ? null
        : String(d.vehicleCategory).trim().toLowerCase();
    const targets = new Map();
    const consider = (uid, userData, driverData) => {
        var _a, _b;
        if (!uid || targets.size >= MAX_TARGETS)
            return;
        if (targets.has(uid)) {
            const prev = targets.get(uid);
            if (!prev.token) {
                prev.token = (_a = tokenOf(userData)) !== null && _a !== void 0 ? _a : tokenOf(driverData);
            }
            return;
        }
        const docCountry = (typeof (userData === null || userData === void 0 ? void 0 : userData.country) === "string" && userData.country) ||
            (typeof (driverData === null || driverData === void 0 ? void 0 : driverData.country) === "string" && driverData.country) ||
            null;
        if (country && (docCountry !== null && docCountry !== void 0 ? docCountry : "").toUpperCase() !== country)
            return;
        const docState = (typeof (userData === null || userData === void 0 ? void 0 : userData.state) === "string" && userData.state) ||
            (typeof (driverData === null || driverData === void 0 ? void 0 : driverData.state) === "string" && driverData.state) ||
            null;
        if (state && docState !== state)
            return;
        targets.set(uid, {
            uid,
            token: (_b = tokenOf(userData)) !== null && _b !== void 0 ? _b : tokenOf(driverData),
            country: docCountry,
        });
    };
    if (mode === "userIds") {
        const raw = Array.isArray(d.userIds) ? d.userIds : [];
        const ids = [...new Set(raw.map((v) => String(v !== null && v !== void 0 ? v : "").trim()))]
            .filter((v) => v.length > 0)
            .slice(0, MAX_USER_IDS);
        if (!ids.length) {
            throw new https_1.HttpsError("invalid-argument", "Provide at least one user ID.");
        }
        for (const uid of ids) {
            const [u, dr] = await Promise.all([
                db().collection("users").doc(uid).get(),
                db().collection("drivers").doc(uid).get(),
            ]);
            if (!u.exists && !dr.exists)
                continue;
            consider(uid, u.data(), dr.data());
        }
    }
    else {
        const wantUsers = mode === "global" || audience === "all" || audience === "customers";
        const wantDrivers = mode === "global" || audience === "all" || audience === "drivers";
        if (wantUsers) {
            let q = db()
                .collection("users")
                .where("fcmToken", "!=", "")
                .limit(MAX_TARGETS);
            // NOTE: role lives on users docs ('customer'/'driver'); drivers-only
            // segments skip users whose role is explicitly 'driver' to avoid
            // double-targeting alongside the drivers collection sweep below.
            if (mode === "segment" && audience === "customers") {
                q = db()
                    .collection("users")
                    .where("role", "==", "customer")
                    .limit(MAX_TARGETS);
            }
            else if (mode === "segment" && audience === "drivers") {
                q = db()
                    .collection("users")
                    .where("role", "==", "driver")
                    .limit(MAX_TARGETS);
            }
            const snap = await q.get();
            for (const doc of snap.docs)
                consider(doc.id, doc.data());
        }
        if (wantDrivers && targets.size < MAX_TARGETS) {
            const snap = await db()
                .collection("drivers")
                .where("fcmToken", "!=", "")
                .limit(MAX_TARGETS)
                .get();
            for (const doc of snap.docs) {
                if (targets.size >= MAX_TARGETS)
                    break;
                const data = doc.data();
                // Segment/all sweeps also read the users doc for geo fields.
                let userData;
                try {
                    const u = await db().collection("users").doc(doc.id).get();
                    if (u.exists)
                        userData = u.data();
                }
                catch (_e) {
                    // Geo match falls back to the driver doc alone.
                }
                consider(doc.id, userData, data);
            }
        }
    }
    // Vehicle filter (drivers only): keep targets with an approved vehicle
    // of the selected category. Users without a driver profile are dropped
    // when a vehicle filter is active.
    let finalTargets = [...targets.values()];
    if (vehicleCategory) {
        const kept = [];
        for (const t of finalTargets) {
            if (await driverHasVehicleCategory(t.uid, vehicleCategory)) {
                kept.push(t);
            }
            if (kept.length >= MAX_TARGETS)
                break;
        }
        finalTargets = kept;
    }
    const broadcastId = db().collection("broadcasts").doc().id;
    const now = admin.firestore.FieldValue.serverTimestamp();
    // 1. Inbox records (batched; token or not — pull always lands).
    let batches = 0;
    for (let i = 0; i < finalTargets.length; i += BATCH_SIZE) {
        const batch = db().batch();
        for (const t of finalTargets.slice(i, i + BATCH_SIZE)) {
            const ref = db()
                .collection("users")
                .doc(t.uid)
                .collection("notifications")
                .doc(broadcastId);
            batch.set(ref, {
                title,
                body,
                type: "broadcast",
                broadcastId,
                audience,
                isRead: false,
                createdAt: now,
            });
        }
        await batch.commit();
        batches += 1;
    }
    // 2. High-priority push to tokens (Doze-bypassing, default sound).
    const tokens = [...new Set(finalTargets.map((t) => t.token).filter((t) => !!t))];
    let successCount = 0;
    let failureCount = 0;
    for (let i = 0; i < tokens.length; i += MAX_TARGETS) {
        const slice = tokens.slice(i, i + MAX_TARGETS);
        try {
            const res = await admin.messaging().sendEach(slice.map((token) => ({
                token,
                data: {
                    type: "broadcast",
                    title,
                    body,
                    broadcastId,
                    channel: "sese_high_priority_alerts",
                },
                notification: { title, body },
                android: {
                    priority: "high",
                    notification: {
                        sound: "default",
                        channelId: "sese_high_priority_alerts",
                        clickAction: "FLUTTER_NOTIFICATION_CLICK",
                    },
                },
                apns: {
                    headers: { "apns-priority": "10" },
                    payload: {
                        aps: { sound: "default", "content-available": 1 },
                    },
                },
            })), false);
            successCount += res.successCount;
            failureCount += res.failureCount;
        }
        catch (e) {
            console.error(`sendTargetedBroadcast FCM batch failed: ${e}`);
            failureCount += slice.length;
        }
    }
    // 3. Audit record for the hub.
    try {
        await db().collection("broadcasts").doc(broadcastId).set({
            title,
            body,
            audience,
            mode,
            country: country !== null && country !== void 0 ? country : null,
            state: state !== null && state !== void 0 ? state : null,
            vehicleCategory: vehicleCategory !== null && vehicleCategory !== void 0 ? vehicleCategory : null,
            senderUid: request.auth.uid,
            senderEmail: ((_d = request.auth.token.email) !== null && _d !== void 0 ? _d : "").toString(),
            targeted: finalTargets.length,
            notified: successCount,
            failed: failureCount,
            batches,
            createdAt: now,
        });
    }
    catch (e) {
        console.error(`sendTargetedBroadcast audit write failed: ${e}`);
    }
    console.log(`sendTargetedBroadcast ${broadcastId}: targeted=${finalTargets.length} `
        + `notified=${successCount} failed=${failureCount} by=${request.auth.uid}`);
    return {
        broadcastId,
        targeted: finalTargets.length,
        notified: successCount,
        failed: failureCount,
    };
});
//# sourceMappingURL=broadcast.js.map