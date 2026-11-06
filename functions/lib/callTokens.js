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
exports.getZegoToken = void 0;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const crypto = __importStar(require("crypto"));
function db() {
    return admin.firestore();
}
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