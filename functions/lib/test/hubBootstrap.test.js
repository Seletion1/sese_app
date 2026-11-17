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
const hubBootstrap_1 = require("../hubBootstrap");
(0, node_test_1.describe)("bootstrapHubOwner — Platform Owner Bootstrapping & Security Guards", () => {
    let store = new Map();
    let userClaimsMap = new Map();
    const originalDescriptor = Object.getOwnPropertyDescriptor(admin, "firestore");
    const originalAuthDescriptor = Object.getOwnPropertyDescriptor(admin, "auth");
    (0, node_test_1.beforeEach)(() => {
        process.env.DISABLE_APP_CHECK = "true";
        delete process.env.ALLOW_REBOOTSTRAP;
        delete process.env.BOOTSTRAP_SECRET;
        store = new Map();
        userClaimsMap = new Map();
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
        const mockAuth = () => ({
            getUser: async (uid) => ({
                uid,
                customClaims: userClaimsMap.get(uid) || {},
            }),
            setCustomUserClaims: async (uid, claims) => {
                userClaimsMap.set(uid, claims);
            },
        });
        Object.defineProperty(admin, "auth", {
            get: () => mockAuth,
            configurable: true,
        });
    });
    (0, node_test_1.afterEach)(() => {
        if (originalDescriptor) {
            Object.defineProperty(admin, "firestore", originalDescriptor);
        }
        if (originalAuthDescriptor) {
            Object.defineProperty(admin, "auth", originalAuthDescriptor);
        }
    });
    (0, node_test_1.test)("rejects unauthenticated request", async () => {
        await node_assert_1.default.rejects(async () => await hubBootstrap_1.bootstrapHubOwner.run({}), (err) => {
            node_assert_1.default.ok(err instanceof https_1.HttpsError);
            node_assert_1.default.strictEqual(err.code, "unauthenticated");
            return true;
        });
    });
    (0, node_test_1.test)("rejects non-platform owner email", async () => {
        const req = {
            auth: { uid: "user_unauthorized", token: { email: "unauthorized@example.com" } },
        };
        await node_assert_1.default.rejects(async () => await hubBootstrap_1.bootstrapHubOwner.run(req), (err) => {
            node_assert_1.default.ok(err instanceof https_1.HttpsError);
            node_assert_1.default.strictEqual(err.code, "permission-denied");
            node_assert_1.default.match(err.message, /Only the primary platform owner/);
            return true;
        });
    });
    (0, node_test_1.test)("successfully bootstraps primary platform owner", async () => {
        const req = {
            auth: { uid: "owner_uid_1", token: { email: "bamiduromichael2@gmail.com" } },
        };
        const res = await hubBootstrap_1.bootstrapHubOwner.run(req);
        node_assert_1.default.strictEqual(res.success, true);
        node_assert_1.default.strictEqual(res.role, "Super");
        // Verify Auth claims created
        const claims = userClaimsMap.get("owner_uid_1");
        node_assert_1.default.strictEqual(claims === null || claims === void 0 ? void 0 : claims.role, "SUPER_ADMIN");
        node_assert_1.default.strictEqual(claims === null || claims === void 0 ? void 0 : claims.admin, true);
        // Verify hub_staff document created
        const staffDoc = store.get("hub_staff/bamiduromichael2@gmail.com");
        node_assert_1.default.ok(staffDoc);
        node_assert_1.default.strictEqual(staffDoc.role, "Super");
        node_assert_1.default.strictEqual(staffDoc.active, true);
    });
    (0, node_test_1.test)("locks re-triggering when already bootstrapped", async () => {
        const ownerEmail = "bamiduromichael1@gmail.com";
        store.set(`hub_staff/${ownerEmail}`, {
            email: ownerEmail,
            role: "Super",
            active: true,
        });
        userClaimsMap.set("owner_uid_2", { role: "SUPER_ADMIN", admin: true });
        const req = {
            auth: { uid: "owner_uid_2", token: { email: ownerEmail } },
        };
        await node_assert_1.default.rejects(async () => await hubBootstrap_1.bootstrapHubOwner.run(req), (err) => {
            node_assert_1.default.ok(err instanceof https_1.HttpsError);
            node_assert_1.default.strictEqual(err.code, "already-exists");
            node_assert_1.default.match(err.message, /already bootstrapped and active/);
            return true;
        });
    });
});
//# sourceMappingURL=hubBootstrap.test.js.map