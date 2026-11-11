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
const https_1 = require("firebase-functions/v2/https");
const admin = __importStar(require("firebase-admin"));
const callTokens_1 = require("../callTokens");
(0, node_test_1.describe)("callTokens — Agora Token Generation, Isolation & Automatic Failover", () => {
    let store = new Map();
    const originalDescriptor = Object.getOwnPropertyDescriptor(admin, "firestore");
    (0, node_test_1.beforeEach)(() => {
        store = new Map();
        process.env.DISABLE_APP_CHECK = "true";
        const mockDb = () => ({
            collection: (collName) => ({
                doc: (docId) => {
                    const docPath = `${collName}/${docId}`;
                    return {
                        get: async () => {
                            const data = store.get(docPath);
                            return {
                                exists: data !== undefined,
                                data: () => data,
                            };
                        },
                        set: async (val, opts) => {
                            const existing = store.get(docPath) || {};
                            store.set(docPath, (opts === null || opts === void 0 ? void 0 : opts.merge) ? Object.assign(Object.assign({}, existing), val) : Object.assign({}, val));
                        },
                        update: async (val) => {
                            const existing = store.get(docPath) || {};
                            store.set(docPath, Object.assign(Object.assign({}, existing), val));
                        },
                    };
                },
            }),
            runTransaction: async (cb) => {
                const mockTx = {
                    get: async (ref) => {
                        const path = ref.docPath;
                        const data = path ? store.get(path) : undefined;
                        return {
                            exists: data !== undefined,
                            data: () => data,
                        };
                    },
                    set: (ref, val, opts) => {
                        const path = ref.docPath;
                        if (path) {
                            const existing = store.get(path) || {};
                            store.set(path, (opts === null || opts === void 0 ? void 0 : opts.merge) ? Object.assign(Object.assign({}, existing), val) : Object.assign({}, val));
                        }
                    },
                };
                return cb(mockTx);
            },
        });
        Object.defineProperty(admin, "firestore", {
            value: Object.assign(mockDb, {
                FieldValue: {
                    serverTimestamp: () => new Date(),
                },
            }),
            configurable: true,
            writable: true,
        });
    });
    (0, node_test_1.afterEach)(() => {
        delete process.env.DISABLE_APP_CHECK;
        if (originalDescriptor) {
            Object.defineProperty(admin, "firestore", originalDescriptor);
        }
    });
    function makeReq(uid, data = {}) {
        return {
            auth: uid ? { uid, token: { uid } } : undefined,
            data,
            rawRequest: {},
        };
    }
    (0, node_test_1.test)("rejects unauthenticated caller", async () => {
        await node_assert_1.default.rejects(async () => {
            await callTokens_1.getAgoraToken.run(makeReq(null, { channelName: "channel_1" }));
        }, (err) => err instanceof https_1.HttpsError && err.code === "unauthenticated");
    });
    (0, node_test_1.test)("returns failover signal when Agora credentials unconfigured in auto mode", async () => {
        // system_settings/calling has auto mode, system_config/call_secrets is empty
        store.set("system_settings/calling", { routingMode: "smartFallback" });
        const result = (await callTokens_1.getAgoraToken.run(makeReq("user_101", { channelName: "trip_call_101" })));
        node_assert_1.default.strictEqual(result.failover, true);
        node_assert_1.default.strictEqual(result.provider, "webrtc");
        node_assert_1.default.ok(result.reason.includes("credentials are not fully configured"));
    });
    (0, node_test_1.test)("throws failed-precondition when credentials missing in forceAgora mode", async () => {
        store.set("system_settings/calling", { routingMode: "thirdPartyOnly" });
        await node_assert_1.default.rejects(async () => {
            await callTokens_1.getAgoraToken.run(makeReq("user_101", { channelName: "trip_call_101" }));
        }, (err) => err instanceof https_1.HttpsError && err.code === "failed-precondition");
    });
    (0, node_test_1.test)("generates valid Agora RTC token when credentials exist", async () => {
        store.set("system_settings/calling", {
            agoraAppId: "cd70ed7adfca42f7bcadc14259a939c4",
            routingMode: "smartFallback",
        });
        store.set("system_config/call_secrets", {
            agoraPrimaryCertificate: "5e0b3b9e939f4338be3e531e0933831f",
        });
        const result = (await callTokens_1.getAgoraToken.run(makeReq("user_101", { channelName: "trip_call_101" })));
        node_assert_1.default.strictEqual(result.failover, false);
        node_assert_1.default.strictEqual(result.provider, "agora");
        node_assert_1.default.strictEqual(result.appId, "cd70ed7adfca42f7bcadc14259a939c4");
        node_assert_1.default.strictEqual(result.channelName, "trip_call_101");
        node_assert_1.default.strictEqual(result.userId, "user_101");
        node_assert_1.default.ok(typeof result.token === "string" && result.token.length > 20);
        node_assert_1.default.ok(result.expiresAt > Math.floor(Date.now() / 1000));
    });
    (0, node_test_1.test)("automatically triggers failover to WebRTC when monthly minute threshold reached", async () => {
        store.set("system_settings/calling", {
            agoraAppId: "cd70ed7adfca42f7bcadc14259a939c4",
            routingMode: "smartFallback",
            agoraAutoFailoverThresholdMinutes: 9900,
            agoraMonthlyFreeMinutesCap: 10000,
        });
        store.set("system_config/call_secrets", {
            agoraPrimaryCertificate: "5e0b3b9e939f4338be3e531e0933831f",
        });
        const now = new Date();
        const monthKey = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
        // Seed usage at 9950 minutes (above 9900 threshold)
        store.set("system_config/call_usage", {
            lastMonthKey: monthKey,
            agoraMinutesThisMonth: 9950,
            totalMinutesThisMonth: 9950,
        });
        const result = (await callTokens_1.getAgoraToken.run(makeReq("user_101", { channelName: "trip_call_101" })));
        node_assert_1.default.strictEqual(result.failover, true);
        node_assert_1.default.strictEqual(result.provider, "webrtc");
        node_assert_1.default.ok(result.reason.includes("free monthly limit reached"));
    });
    (0, node_test_1.test)("recordCallDuration increments call usage minutes atomically", async () => {
        const result = (await callTokens_1.recordCallDuration.run(makeReq("user_101", {
            durationSeconds: 125, // 3 minutes rounded up
            provider: "agora",
            callId: "call_999",
        })));
        node_assert_1.default.strictEqual(result.ok, true);
        node_assert_1.default.strictEqual(result.durationMinutes, 3);
    });
});
//# sourceMappingURL=callTokens.test.js.map