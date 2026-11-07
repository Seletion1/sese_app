"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const node_assert_1 = __importDefault(require("node:assert"));
const node_test_1 = require("node:test");
const googleMaps_1 = require("../googleMaps");
(0, node_test_1.describe)("Security Fixes: Rate Limiting & Bank Code Validation", () => {
    (0, node_test_1.describe)("Google Maps Proxy Rate Limiting", () => {
        (0, node_test_1.test)("allows up to 60 requests per minute and throttles subsequent requests", () => {
            const testUid = `rate_limit_test_user_${Date.now()}`;
            // First 60 requests should succeed
            for (let i = 0; i < 60; i++) {
                node_assert_1.default.doesNotThrow(() => (0, googleMaps_1.checkProxyRateLimit)(testUid));
            }
            // 61st request should be throttled
            node_assert_1.default.throws(() => (0, googleMaps_1.checkProxyRateLimit)(testUid), (err) => {
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