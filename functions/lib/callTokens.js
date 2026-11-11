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
exports.getZegoToken = exports.recordCallDuration = exports.getAgoraToken = void 0;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const crypto = __importStar(require("crypto"));
const agora_token_1 = require("agora-token");
const accountGuard_1 = require("./accountGuard");
function db() {
    return admin.firestore();
}
/**
 * Gets the current UTC month string in `YYYY-MM` format.
 */
function getUtcMonthKey() {
    const now = new Date();
    const year = now.getUTCFullYear();
    const month = String(now.getUTCMonth() + 1).padStart(2, "0");
    return `${year}-${month}`;
}
/**
 * Generates a short-lived Agora RTC Access Token server-side.
 *
 * Security:
 * - Credentials (`agoraAppCertificate`) are read exclusively from `/system_config/call_secrets`
 *   and are NEVER returned to or hardcoded inside client mobile apps.
 * - Enforces Firebase App Check and user authentication.
 * - Evaluates automatic failover: if monthly Agora minutes reach the threshold (default: 9,900/10,000 mins),
 *   signals the client to failover to native WebRTC.
 */
exports.getAgoraToken = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c;
    (0, accountGuard_1.enforceAppCheck)(request);
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "User must be authenticated to request Agora token.");
    }
    const userId = request.auth.uid;
    const channelName = ((_a = request.data) === null || _a === void 0 ? void 0 : _a.channelName) || ((_b = request.data) === null || _b === void 0 ? void 0 : _b.roomId) || `channel_${userId}`;
    const rawDuration = Number(((_c = request.data) === null || _c === void 0 ? void 0 : _c.effectiveDurationSeconds) || 3600);
    const effectiveDurationSeconds = Math.min(Math.max(isNaN(rawDuration) ? 3600 : rawDuration, 300), 86400);
    const monthKey = getUtcMonthKey();
    // Fetch appId from system_settings/calling, Primary Certificate from system_config/call_secrets, and usage metrics
    const [callingSnap, secretsSnap, usageSnap] = await Promise.all([
        db().collection("system_settings").doc("calling").get(),
        db().collection("system_config").doc("call_secrets").get(),
        db().collection("system_config").doc("call_usage").get(),
    ]);
    const callingData = callingSnap.data() || {};
    const secretsData = secretsSnap.data() || {};
    const usageData = usageSnap.data() || {};
    const agoraAppId = callingData.agoraAppId || callingData.appId || secretsData.agoraAppId;
    const agoraAppCertificate = secretsData.agoraPrimaryCertificate || secretsData.agoraAppCertificate || secretsData.appCertificate;
    const routingMode = (callingData.routingMode || "smartFallback").toString().toLowerCase();
    const agoraAutoFailoverThresholdMinutes = Number(callingData.agoraAutoFailoverThresholdMinutes || 9900);
    const agoraMonthlyFreeMinutesCap = Number(callingData.agoraMonthlyFreeMinutesCap || 10000);
    // Read current month's usage
    const lastMonthKey = usageData.lastMonthKey || monthKey;
    const agoraMinutesThisMonth = lastMonthKey === monthKey ? Number(usageData.agoraMinutesThisMonth || 0) : 0;
    const isAutoMode = routingMode === "smartfallback" || routingMode === "auto" || routingMode === "smart_fallback";
    // Check 1: Automatic minute-usage threshold failover
    if (isAutoMode && agoraMinutesThisMonth >= agoraAutoFailoverThresholdMinutes) {
        return {
            failover: true,
            provider: "webrtc",
            reason: `Agora free monthly limit reached (${agoraMinutesThisMonth}/${agoraMonthlyFreeMinutesCap} mins). Automatic failover to WebRTC engaged.`,
            agoraMinutesThisMonth,
            agoraAutoFailoverThresholdMinutes,
            agoraMonthlyFreeMinutesCap,
        };
    }
    // Check 2: Credential check
    if (!agoraAppId || typeof agoraAppId !== "string" || agoraAppId.trim().length === 0 ||
        !agoraAppCertificate || typeof agoraAppCertificate !== "string" || agoraAppCertificate.trim().length < 16) {
        if (isAutoMode) {
            return {
                failover: true,
                provider: "webrtc",
                reason: "Agora credentials are not fully configured on the server. Automatic fallback to WebRTC engaged.",
                agoraMinutesThisMonth,
                agoraAutoFailoverThresholdMinutes,
                agoraMonthlyFreeMinutesCap,
            };
        }
        throw new https_1.HttpsError("failed-precondition", "Agora credentials (App ID & Primary Certificate) are not configured on the server.");
    }
    const now = Math.floor(Date.now() / 1000);
    const privilegeExpiredTs = now + effectiveDurationSeconds;
    // Build Agora RTC token v007 using user account string (UID)
    const token = agora_token_1.RtcTokenBuilder.buildTokenWithUserAccount(agoraAppId.trim(), agoraAppCertificate.trim(), channelName.trim(), userId, agora_token_1.RtcRole.PUBLISHER, privilegeExpiredTs, privilegeExpiredTs);
    return {
        failover: false,
        provider: "agora",
        appId: agoraAppId.trim(),
        channelName: channelName.trim(),
        userId,
        token,
        expiresAt: privilegeExpiredTs,
        agoraMinutesThisMonth,
        agoraAutoFailoverThresholdMinutes,
        agoraMonthlyFreeMinutesCap,
    };
});
/**
 * Records completed call minutes and updates global usage counters for the current month.
 */
exports.recordCallDuration = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c;
    (0, accountGuard_1.enforceAppCheck)(request);
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "User must be authenticated to record call duration.");
    }
    const durationSeconds = Math.max(0, Number(((_a = request.data) === null || _a === void 0 ? void 0 : _a.durationSeconds) || 0));
    const provider = (((_b = request.data) === null || _b === void 0 ? void 0 : _b.provider) || "agora").toString().toLowerCase();
    const callId = ((_c = request.data) === null || _c === void 0 ? void 0 : _c.callId) || "unknown";
    if (durationSeconds <= 0) {
        return { ok: true, durationMinutes: 0 };
    }
    const durationMinutes = Math.ceil(durationSeconds / 60);
    const monthKey = getUtcMonthKey();
    const usageRef = db().collection("system_config").doc("call_usage");
    await db().runTransaction(async (tx) => {
        const snap = await tx.get(usageRef);
        const data = snap.data() || {};
        const lastMonth = data.lastMonthKey || "";
        let currentAgoraMins = lastMonth === monthKey ? Number(data.agoraMinutesThisMonth || 0) : 0;
        let currentTotalMins = lastMonth === monthKey ? Number(data.totalMinutesThisMonth || 0) : 0;
        let currentTotalCalls = lastMonth === monthKey ? Number(data.totalCallsThisMonth || 0) : 0;
        if (provider === "agora") {
            currentAgoraMins += durationMinutes;
        }
        currentTotalMins += durationMinutes;
        currentTotalCalls += 1;
        tx.set(usageRef, {
            lastMonthKey: monthKey,
            agoraMinutesThisMonth: currentAgoraMins,
            totalMinutesThisMonth: currentTotalMins,
            totalCallsThisMonth: currentTotalCalls,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            lastCallId: callId,
        }, { merge: true });
    });
    return {
        ok: true,
        durationMinutes,
        monthKey,
    };
});
/**
 * Generates a short-lived ZegoCloud authentication token server-side.
 * Uses the secret AppSign stored securely in `/system_config/call_secrets`.
 */
exports.getZegoToken = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "User must be authenticated to request Zego token.");
    }
    const userId = request.auth.uid;
    const roomId = ((_a = request.data) === null || _a === void 0 ? void 0 : _a.roomId) || `room_${userId}`;
    const rawDuration = Number(((_b = request.data) === null || _b === void 0 ? void 0 : _b.effectiveDurationSeconds) || 3600);
    const effectiveDurationSeconds = Math.min(Math.max(isNaN(rawDuration) ? 3600 : rawDuration, 300), 86400);
    // Fetch appId from system_settings/calling and AppSign from system_config/call_secrets
    const [callingSnap, secretsSnap] = await Promise.all([
        db().collection("system_settings").doc("calling").get(),
        db().collection("system_config").doc("call_secrets").get(),
    ]);
    const appId = (_c = callingSnap.data()) === null || _c === void 0 ? void 0 : _c.zegoAppId;
    const zegoAppSign = (_d = secretsSnap.data()) === null || _d === void 0 ? void 0 : _d.zegoAppSign;
    if (!appId || !zegoAppSign || typeof zegoAppSign !== "string" || zegoAppSign.length < 32) {
        throw new https_1.HttpsError("failed-precondition", "ZegoCloud credentials are not fully configured on the server.");
    }
    const now = Math.floor(Date.now() / 1000);
    const expiresAt = now + effectiveDurationSeconds;
    // Generate Zego V2 token payload using HMAC SHA-256
    const nonce = crypto.randomBytes(8).readBigInt64BE(0).toString();
    const payload = {
        app_id: appId,
        user_id: userId,
        room_id: roomId,
        nonce: nonce,
        ctime: now,
        expire: expiresAt,
    };
    const payloadString = JSON.stringify(payload);
    const hmac = crypto.createHmac("sha256", zegoAppSign);
    hmac.update(payloadString);
    const signature = hmac.digest("hex");
    const token = Buffer.from(JSON.stringify({
        payload: payloadString,
        signature: signature,
    })).toString("base64");
    return {
        appId,
        userId,
        roomId,
        token,
        expiresAt,
    };
});
//# sourceMappingURL=callTokens.js.map