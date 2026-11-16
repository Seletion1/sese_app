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
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const node_assert_1 = __importDefault(require("node:assert"));
const node_test_1 = require("node:test");
const admin = __importStar(require("firebase-admin"));
if (admin.apps.length === 0) {
    try {
        admin.initializeApp({ projectId: "sese-ride" });
    }
    catch (_) { }
}
const email_1 = require("../email");
(0, node_test_1.describe)("Email OTP Security & Open Relay Prevention", () => {
    (0, node_test_1.describe)("sendEmailOtp email pinning & authentication", () => {
        (0, node_test_1.test)("rejects unauthenticated OTP requests", async () => {
            const unauthReq = {
                data: { email: "attacker@example.com" },
            };
            await node_assert_1.default.rejects(async () => {
                await email_1.sendEmailOtp.run(unauthReq);
            }, (err) => err.code === "unauthenticated");
        });
        (0, node_test_1.test)("rejects request if caller-supplied email mismatches authenticated email token", async () => {
            const mismatchedReq = {
                app: {
                    appId: "com.sese.ride",
                    alreadyConsumed: false,
                },
                auth: {
                    uid: "user_victim_123",
                    token: { email: "victim@example.com" },
                },
                data: {
                    email: "attacker@example.com",
                },
            };
            await node_assert_1.default.rejects(async () => {
                await email_1.sendEmailOtp.run(mismatchedReq);
            }, (err) => err.code === "invalid-argument" &&
                err.message.includes("Email address must match your authenticated profile"));
        });
    });
    (0, node_test_1.describe)("checkEmailOtpRateLimit rate limiting", () => {
        (0, node_test_1.test)("enforces sliding window rate limit per UID for OTP requests", () => {
            const testUid = `otp_rate_limit_user_${Date.now()}`;
            // Max 3 requests allowed per minute
            for (let i = 0; i < 3; i++) {
                node_assert_1.default.doesNotThrow(() => (0, email_1.checkEmailOtpRateLimit)(testUid));
            }
            // 4th request throws resource-exhausted
            node_assert_1.default.throws(() => (0, email_1.checkEmailOtpRateLimit)(testUid), (err) => err.code === "resource-exhausted");
        });
    });
});
//# sourceMappingURL=email_otp_security.test.js.map