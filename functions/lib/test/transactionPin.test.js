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
const transactionPin_1 = require("../transactionPin");
(0, node_test_1.describe)("transactionPin — Authority, Validation & Recovery", () => {
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
                        update: async (val) => {
                            const existing = store.get(docPath) || {};
                            store.set(docPath, Object.assign(Object.assign({}, existing), val));
                        },
                        collection: (subCollName) => ({
                            doc: (subDocId) => {
                                const subPath = `${docPath}/${subCollName}/${subDocId}`;
                                return {
                                    get: async () => {
                                        const data = store.get(subPath);
                                        return {
                                            exists: data !== undefined,
                                            data: () => data,
                                        };
                                    },
                                    set: async (val, opts) => {
                                        const existing = store.get(subPath) || {};
                                        store.set(subPath, (opts === null || opts === void 0 ? void 0 : opts.merge) ? Object.assign(Object.assign({}, existing), val) : Object.assign({}, val));
                                    },
                                };
                            },
                        }),
                    };
                },
            }),
        });
        Object.defineProperty(mockDb, "FieldValue", {
            value: {
                serverTimestamp: () => new Date().toISOString(),
                delete: () => undefined,
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
    (0, node_test_1.test)("hasPinSet returns false when no PIN doc exists", async () => {
        const hasPin = await (0, transactionPin_1.hasPinSet)("user_no_pin");
        node_assert_1.default.strictEqual(hasPin, false);
    });
    (0, node_test_1.test)("setTransactionPin creates new PIN for user without PIN", async () => {
        store.set("users/user_1", { uid: "user_1" });
        const req = {
            auth: { uid: "user_1" },
            data: { pin: "1234" },
        };
        const res = await transactionPin_1.setTransactionPin.run(req);
        node_assert_1.default.deepStrictEqual(res, { ok: true });
        const hasPin = await (0, transactionPin_1.hasPinSet)("user_1");
        node_assert_1.default.strictEqual(hasPin, true);
    });
    (0, node_test_1.test)("setTransactionPin rejects invalid PIN shapes", async () => {
        const req = {
            auth: { uid: "user_1" },
            data: { pin: "123" }, // 3 digits
        };
        await node_assert_1.default.rejects(async () => await transactionPin_1.setTransactionPin.run(req), (err) => {
            node_assert_1.default.ok(err instanceof https_1.HttpsError);
            node_assert_1.default.strictEqual(err.code, "invalid-argument");
            node_assert_1.default.match(err.message, /exactly 4 digits/);
            return true;
        });
    });
    (0, node_test_1.test)("setTransactionPin requires correct currentPin when changing existing PIN", async () => {
        store.set("users/user_2", { uid: "user_2" });
        // Set initial PIN
        await transactionPin_1.setTransactionPin.run({
            auth: { uid: "user_2" },
            data: { pin: "1234" },
        });
        // Fail change with wrong current PIN
        await node_assert_1.default.rejects(async () => await transactionPin_1.setTransactionPin.run({
            auth: { uid: "user_2" },
            data: { pin: "5678", currentPin: "9999" },
        }), (err) => {
            node_assert_1.default.ok(err instanceof https_1.HttpsError);
            node_assert_1.default.strictEqual(err.code, "unauthenticated");
            return true;
        });
        // Succeed change with correct current PIN
        const res = await transactionPin_1.setTransactionPin.run({
            auth: { uid: "user_2" },
            data: { pin: "5678", currentPin: "1234" },
        });
        node_assert_1.default.deepStrictEqual(res, { ok: true });
        // Verify new PIN works
        await node_assert_1.default.doesNotReject(() => (0, transactionPin_1.requireValidPin)("user_2", "5678"));
    });
    (0, node_test_1.test)("verifyTransactionPin succeeds with correct PIN and fails with wrong PIN", async () => {
        store.set("users/user_3", { uid: "user_3" });
        await transactionPin_1.setTransactionPin.run({
            auth: { uid: "user_3" },
            data: { pin: "4321" },
        });
        const validReq = {
            auth: { uid: "user_3" },
            data: { pin: "4321" },
        };
        const res = await transactionPin_1.verifyTransactionPin.run(validReq);
        node_assert_1.default.deepStrictEqual(res, { ok: true });
        const invalidReq = {
            auth: { uid: "user_3" },
            data: { pin: "9999" },
        };
        await node_assert_1.default.rejects(async () => await transactionPin_1.verifyTransactionPin.run(invalidReq), (err) => {
            node_assert_1.default.ok(err instanceof https_1.HttpsError);
            node_assert_1.default.strictEqual(err.code, "unauthenticated");
            return true;
        });
    });
    (0, node_test_1.test)("resetTransactionPin updates PIN and clears active lock", async () => {
        store.set("users/user_4", { uid: "user_4" });
        await transactionPin_1.setTransactionPin.run({
            auth: { uid: "user_4" },
            data: { pin: "1111" },
        });
        // Reset PIN to 9999
        const resetReq = {
            auth: { uid: "user_4" },
            data: { pin: "9999" },
        };
        const res = await transactionPin_1.resetTransactionPin.run(resetReq);
        node_assert_1.default.deepStrictEqual(res, { ok: true });
        // Verify new PIN 9999 works
        await node_assert_1.default.doesNotReject(() => (0, transactionPin_1.requireValidPin)("user_4", "9999"));
    });
});
//# sourceMappingURL=transactionPin.test.js.map