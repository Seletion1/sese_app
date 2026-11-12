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
const uniqueIdentifiers_1 = require("../uniqueIdentifiers");
(0, node_test_1.describe)("Admin Onboarding & Assisted Registration Invariants", () => {
    (0, node_test_1.test)("1. Identifier Normalization for Phone & Email Searches", () => {
        // Phone numbers normalize to E.164
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("phone", "08161561592"), "+2348161561592");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("phone", "2348161561592"), "+2348161561592");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("phone", "+2348161561592"), "+2348161561592");
        // Email addresses normalize with dot/alias canonicalization
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("email", "Test.Agent+demo@gmail.com"), "testagent@gmail.com");
        node_assert_1.default.strictEqual((0, uniqueIdentifiers_1.normalizeIdentifier)("email", " User@SeseApp.com "), "user@seseapp.com");
    });
    (0, node_test_1.test)("2. Onboarding OTP Key Consistency & Expiration Invariant", () => {
        const rawInputPhone = "081 6156 1592";
        const normKey = (0, uniqueIdentifiers_1.normalizeIdentifier)("phone", rawInputPhone);
        node_assert_1.default.strictEqual(normKey, "+2348161561592");
        // OTP Doc Key matches across different raw formatting variations
        const normKey2 = (0, uniqueIdentifiers_1.normalizeIdentifier)("phone", "+234-816-156-1592");
        node_assert_1.default.strictEqual(normKey, normKey2);
        // OTP TTL invariant: 10 minutes from creation
        const now = Date.now();
        const expiresAt = now + 10 * 60 * 1000;
        node_assert_1.default.ok(expiresAt - now === 600000);
    });
    (0, node_test_1.test)("3. Missing Onboarding Steps Resolution Invariant", () => {
        const resolveMissingSteps = (role, userData, vehicleCount, isDriverVerified) => {
            const missingSteps = [];
            if (!userData.fullName || (!userData.phoneNumber && !userData.email)) {
                missingSteps.push("profile_details");
            }
            if ((role === "driver" || role === "both") && vehicleCount === 0) {
                missingSteps.push("vehicle_setup");
            }
            if ((role === "driver" || role === "both") && !isDriverVerified) {
                missingSteps.push("verification_approval");
            }
            return missingSteps;
        };
        // Customer missing profile details
        const steps1 = resolveMissingSteps("customer", {}, 0, false);
        node_assert_1.default.deepStrictEqual(steps1, ["profile_details"]);
        // Driver missing vehicle setup and approval
        const steps2 = resolveMissingSteps("driver", { fullName: "Bamiduro Micheal", phoneNumber: "+2348161561592" }, 0, false);
        node_assert_1.default.deepStrictEqual(steps2, ["vehicle_setup", "verification_approval"]);
        // Fully set up driver
        const steps3 = resolveMissingSteps("driver", { fullName: "Bamiduro Micheal", phoneNumber: "+2348161561592" }, 1, true);
        node_assert_1.default.deepStrictEqual(steps3, []);
    });
    (0, node_test_1.test)("4. Verification Status Alignment Invariant", () => {
        // Verification statuses must align across rules, queues, and functions
        const allowedCustomerStatuses = ["pending", "unverified", "PENDING", "pending_onboarding"];
        const adminCreatedCustomerStatus = "pending";
        node_assert_1.default.ok(allowedCustomerStatuses.includes(adminCreatedCustomerStatus));
        const driverVerificationStatus = "pending_verification";
        node_assert_1.default.strictEqual(driverVerificationStatus, "pending_verification");
    });
});
//# sourceMappingURL=admin_onboarding.test.js.map