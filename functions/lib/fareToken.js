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
exports.generateFareToken = generateFareToken;
exports.verifyFareToken = verifyFareToken;
const crypto = __importStar(require("crypto"));
const FARE_SIGNING_SECRET = (_a = process.env.FARE_SIGNING_SECRET) !== null && _a !== void 0 ? _a : "sese-default-insecure-fare-token-secret-change-me";
/**
 * Creates a signed base64 HMAC-SHA256 token encoding the authoritative fare calculation.
 * The client cannot forge or alter the fares without invalidating the token.
 */
function generateFareToken(payload) {
    const json = JSON.stringify(payload);
    const hmac = crypto.createHmac("sha256", FARE_SIGNING_SECRET);
    hmac.update(json);
    const signature = hmac.digest("hex");
    const encodedData = Buffer.from(json, "utf-8").toString("base64url");
    return `${encodedData}.${signature}`;
}
/**
 * Verifies a fareToken and returns the verified payload, or null if invalid or tampered.
 */
function verifyFareToken(token, maxAgeMs = 30 * 60 * 1000) {
    try {
        const [encodedData, signature] = token.split(".");
        if (!encodedData || !signature)
            return null;
        const json = Buffer.from(encodedData, "base64url").toString("utf-8");
        const hmac = crypto.createHmac("sha256", FARE_SIGNING_SECRET);
        hmac.update(json);
        const expectedSig = hmac.digest("hex");
        if (!crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expectedSig))) {
            return null;
        }
        const payload = JSON.parse(json);
        const now = Date.now();
        if (now - payload.timestamp > maxAgeMs) {
            // Expired token
            return null;
        }
        return payload;
    }
    catch (_a) {
        return null;
    }
}
//# sourceMappingURL=fareToken.js.map