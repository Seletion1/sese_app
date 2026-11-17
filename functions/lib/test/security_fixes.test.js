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
const googleMaps_1 = require("../googleMaps");
(0, node_test_1.describe)("Security Fixes: Rate Limiting & Bank Code Validation", () => {
    let store = new Map();
    const originalDescriptor = Object.getOwnPropertyDescriptor(admin, "firestore");
    (0, node_test_1.beforeEach)(() => {
        store = new Map();
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
                    };
                },
            }),
            runTransaction: async (updateFunction) => {
                const tx = {
                    get: async (ref) => ref.get(),
                    set: async (ref, data, opts) => ref.set(data, opts),
                    update: async (ref, data) => ref.set(data, { merge: true }),
                };
                return await updateFunction(tx);
            },
        });
        Object.defineProperty(mockDb, "FieldValue", {
            value: {
                serverTimestamp: () => new Date().toISOString(),
            },
            writable: true,
        });
        Object.defineProperty(admin, "firestore", {
            get: () => mockDb,
            configurable: true,
        });
    });
    (0, node_test_1.afterEach)(() => {
        if (originalDescriptor) {
            Object.defineProperty(admin, "firestore", originalDescriptor);
        }
    });
    (0, node_test_1.describe)("Google Maps Proxy Rate Limiting", () => {
        (0, node_test_1.test)("allows up to 60 requests per minute and throttles subsequent requests", async () => {
            const testUid = `rate_limit_test_user_${Date.now()}`;
            // First 60 requests should succeed
            for (let i = 0; i < 60; i++) {
                await node_assert_1.default.doesNotReject(() => (0, googleMaps_1.checkProxyRateLimit)(testUid));
            }
            // 61st request should be throttled
            await node_assert_1.default.rejects(async () => await (0, googleMaps_1.checkProxyRateLimit)(testUid), (err) => {
                var _a;
                return err.code === "resource-exhausted" || ((_a = err.message) === null || _a === void 0 ? void 0 : _a.includes("Too many location searches"));
            });
        });
    });
    (0, node_test_1.describe)("Bank Code Regex Validation (Fintech & Digital Banks)", () => {
        const bankCodeRegex = /^[a-zA-Z0-9]{3,6}$/;
        (0, node_test_1.test)("accepts traditional 3-digit bank codes", () => {
            node_assert_1.default.strictEqual(bankCodeRegex.test("058"), true); // GTBank
            node_assert_1.default.strictEqual(bankCodeRegex.test("044"), true); // Access Bank
            node_assert_1.default.strictEqual(bankCodeRegex.test("011"), true); // First Bank
            node_assert_1.default.strictEqual(bankCodeRegex.test("214"), true); // FCMB
        });
        (0, node_test_1.test)("accepts 5 and 6 digit fintech / MFB bank codes", () => {
            node_assert_1.default.strictEqual(bankCodeRegex.test("50515"), true); // Moniepoint
            node_assert_1.default.strictEqual(bankCodeRegex.test("50211"), true); // Kuda Bank
            node_assert_1.default.strictEqual(bankCodeRegex.test("999991"), true); // PalmPay
            node_assert_1.default.strictEqual(bankCodeRegex.test("999992"), true); // OPay
            node_assert_1.default.strictEqual(bankCodeRegex.test("090110"), true); // VFD MFB
        });
        (0, node_test_1.test)("rejects invalid bank codes", () => {
            node_assert_1.default.strictEqual(bankCodeRegex.test(""), false);
            node_assert_1.default.strictEqual(bankCodeRegex.test("1"), false);
            node_assert_1.default.strictEqual(bankCodeRegex.test("12"), false);
            node_assert_1.default.strictEqual(bankCodeRegex.test("1234567"), false); // too long (>6)
            node_assert_1.default.strictEqual(bankCodeRegex.test("058-A"), false); // special character
            node_assert_1.default.strictEqual(bankCodeRegex.test("05 8"), false); // whitespace
        });
    });
});
//# sourceMappingURL=security_fixes.test.js.map