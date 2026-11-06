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
const accountGuard_1 = require("../accountGuard");
(0, node_test_1.describe)("accountGuard — App Check & Account Suspension Gates", () => {
    const originalEnv = process.env.DISABLE_APP_CHECK;
    (0, node_test_1.afterEach)(() => {
        if (originalEnv !== undefined) {
            process.env.DISABLE_APP_CHECK = originalEnv;
        }
        else {
            delete process.env.DISABLE_APP_CHECK;
        }
    });
    (0, node_test_1.describe)("enforceAppCheck", () => {
        (0, node_test_1.test)("blocks request when App Check token is missing by default", () => {
            delete process.env.DISABLE_APP_CHECK;
            const fakeReq = {};
            node_assert_1.default.throws(() => (0, accountGuard_1.enforceAppCheck)(fakeReq), (err) => {
                node_assert_1.default.ok(err instanceof https_1.HttpsError);
                node_assert_1.default.strictEqual(err.code, "unauthenticated");
                node_assert_1.default.match(err.message, /missing a valid App Check token/);
                return true;
            });
        });
        (0, node_test_1.test)("allows request when valid App Check token is present", () => {
            delete process.env.DISABLE_APP_CHECK;
            const fakeReq = {
                app: {
                    appId: "com.sese.ride",
                    alreadyConsumed: false,
                },
            };
            node_assert_1.default.doesNotThrow(() => (0, accountGuard_1.enforceAppCheck)(fakeReq));
        });
        (0, node_test_1.test)("bypasses enforcement when DISABLE_APP_CHECK=true", () => {
            process.env.DISABLE_APP_CHECK = "true";
            const fakeReq = {};
            node_assert_1.default.doesNotThrow(() => (0, accountGuard_1.enforceAppCheck)(fakeReq));
        });
    });
    (0, node_test_1.describe)("requireAccountActive", () => {
        let docMap = new Map();
        const originalDescriptor = Object.getOwnPropertyDescriptor(admin, "firestore");
        (0, node_test_1.beforeEach)(() => {
            docMap = new Map();
            const mockFirestore = () => {
                return {
                    collection: (collName) => ({
                        doc: (docId) => ({
                            get: async () => {
                                const key = `${collName}/${docId}`;
                                if (docMap.has(key)) {
                                    const val = docMap.get(key);
                                    if (val === null) {
                                        throw new Error("Simulated Firestore network timeout");
                                    }
                                    return {
                                        exists: true,
                                        data: () => val,
                                    };
                                }
                                return {
                                    exists: false,
                                    data: () => undefined,
                                };
                            },
                        }),
                    }),
                };
            };
            Object.defineProperty(admin, "firestore", {
                get: () => mockFirestore,
                configurable: true,
            });
        });
        (0, node_test_1.afterEach)(() => {
            if (originalDescriptor) {
                Object.defineProperty(admin, "firestore", originalDescriptor);
            }
        });
        (0, node_test_1.test)("allows active users with clean documents", async () => {
            docMap.set("users/user_active_123", {
                accountStatus: "active",
                isSuspended: false,
            });
            await node_assert_1.default.doesNotReject(() => (0, accountGuard_1.requireAccountActive)("user_active_123", "customer"));
        });
        (0, node_test_1.test)("fails closed when user document has isSuspended: true", async () => {
            docMap.set("users/user_suspended_123", {
                isSuspended: true,
            });
            await node_assert_1.default.rejects(() => (0, accountGuard_1.requireAccountActive)("user_suspended_123", "customer"), (err) => {
                node_assert_1.default.ok(err instanceof https_1.HttpsError);
                node_assert_1.default.strictEqual(err.code, "permission-denied");
                node_assert_1.default.match(err.message, /currently suspended/);
                return true;
            });
        });
        (0, node_test_1.test)("fails closed when user document has isBanned: true", async () => {
            docMap.set("users/user_banned_123", {
                isBanned: true,
            });
            await node_assert_1.default.rejects(() => (0, accountGuard_1.requireAccountActive)("user_banned_123", "customer"), (err) => {
                node_assert_1.default.ok(err instanceof https_1.HttpsError);
                node_assert_1.default.strictEqual(err.code, "permission-denied");
                node_assert_1.default.match(err.message, /permanently banned/);
                return true;
            });
        });
        (0, node_test_1.test)("fails closed when driver document is suspended and role === 'driver'", async () => {
            docMap.set("users/driver_456", { accountStatus: "active" });
            docMap.set("drivers/driver_456", { accountStatus: "suspended" });
            await node_assert_1.default.rejects(() => (0, accountGuard_1.requireAccountActive)("driver_456", "driver"), (err) => {
                node_assert_1.default.ok(err instanceof https_1.HttpsError);
                node_assert_1.default.strictEqual(err.code, "permission-denied");
                node_assert_1.default.match(err.message, /driver account is suspended/);
                return true;
            });
        });
        (0, node_test_1.test)("fails open on genuine Firestore infra / network error", async () => {
            docMap.set("users/infra_err_789", null); // triggers Firestore read error throw
            await node_assert_1.default.doesNotReject(() => (0, accountGuard_1.requireAccountActive)("infra_err_789", "customer"));
        });
    });
});
//# sourceMappingURL=accountGuard.test.js.map