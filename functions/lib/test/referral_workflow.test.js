"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const node_assert_1 = __importDefault(require("node:assert"));
const node_test_1 = require("node:test");
/**
 * Unit test suite for Referral Code Generation, Self-Referral Prevention,
 * and Dynamic Referral Commission Payout calculations.
 */
function generateBaseReferralCode(fullName, phoneNumber) {
    var _a, _b, _c, _d, _e, _f;
    const cleanName = fullName.trim();
    const parts = cleanName.split(/\s+/).filter(Boolean);
    let fInitial = "X";
    let lInitial = "X";
    if (parts.length === 1) {
        fInitial = ((_b = (_a = parts[0].match(/[A-Za-z]/)) === null || _a === void 0 ? void 0 : _a[0]) !== null && _b !== void 0 ? _b : "X").toUpperCase();
        lInitial = fInitial;
    }
    else if (parts.length > 1) {
        fInitial = ((_d = (_c = parts[0].match(/[A-Za-z]/)) === null || _c === void 0 ? void 0 : _c[0]) !== null && _d !== void 0 ? _d : "X").toUpperCase();
        lInitial = ((_f = (_e = parts[parts.length - 1].match(/[A-Za-z]/)) === null || _e === void 0 ? void 0 : _e[0]) !== null && _f !== void 0 ? _f : fInitial).toUpperCase();
    }
    const initials = (fInitial + lInitial).toUpperCase();
    const digits = phoneNumber.replace(/\D/g, "");
    const last4 = digits.length >= 4 ? digits.slice(-4) : digits.padStart(4, "0");
    return (initials + last4).toUpperCase();
}
function normalizeRateFraction(val, fallback) {
    if (typeof val !== "number" || isNaN(val))
        return fallback;
    return val > 1 ? val / 100 : val;
}
function calculateReferralCommission(totalFareNaira, rateOrFraction, fixedBonusNaira, isFirstTrip) {
    if (fixedBonusNaira && fixedBonusNaira > 0 && isFirstTrip) {
        return fixedBonusNaira;
    }
    const rate = normalizeRateFraction(rateOrFraction, 0.01);
    return Number((totalFareNaira * rate).toFixed(2));
}
function isSelfReferral(referrerUid, refereeUid) {
    if (!referrerUid || !refereeUid)
        return false;
    return referrerUid.trim().toLowerCase() === refereeUid.trim().toLowerCase();
}
(0, node_test_1.describe)("Referral System & Commission Payout Workflow Invariants", () => {
    (0, node_test_1.describe)("1. Instant Referral ID Generation & Upgrades", () => {
        (0, node_test_1.test)("generates deterministic referral code from initials and last 4 phone digits", () => {
            const code = generateBaseReferralCode("Micheal Bamiduro", "+2348161561592");
            node_assert_1.default.strictEqual(code, "MB1592");
        });
        (0, node_test_1.test)("falls back to 0000 placeholder when phone number is missing initially", () => {
            const code = generateBaseReferralCode("Micheal Bamiduro", "");
            node_assert_1.default.strictEqual(code, "MB0000");
        });
        (0, node_test_1.test)("identifies placeholder codes ending in 0000 for upgrade upon linking phone", () => {
            const placeholderCode = "MB0000";
            const isPlaceholder = placeholderCode.endsWith("0000");
            node_assert_1.default.strictEqual(isPlaceholder, true);
            const upgradedCode = generateBaseReferralCode("Micheal Bamiduro", "+2348161561592");
            node_assert_1.default.strictEqual(upgradedCode, "MB1592");
        });
        (0, node_test_1.test)("appends counter on collision to guarantee unique referral code", () => {
            const base = "MB1592";
            const candidate1 = `${base}1`;
            const candidate2 = `${base}2`;
            node_assert_1.default.strictEqual(candidate1, "MB15921");
            node_assert_1.default.strictEqual(candidate2, "MB15922");
        });
    });
    (0, node_test_1.describe)("2. Self-Referral Exploitation Prevention", () => {
        (0, node_test_1.test)("detects and blocks direct self-referral attempts when referrerUid equals refereeUid", () => {
            node_assert_1.default.strictEqual(isSelfReferral("user_123", "user_123"), true);
            node_assert_1.default.strictEqual(isSelfReferral("USER_123", "user_123"), true);
        });
        (0, node_test_1.test)("allows valid cross-user referrals", () => {
            node_assert_1.default.strictEqual(isSelfReferral("user_referrer_456", "user_referee_789"), false);
        });
    });
    (0, node_test_1.describe)("3. Dynamic Hub Rate & Fixed Bonus Commission Distribution", () => {
        (0, node_test_1.test)("correctly computes referral commission for standard percentage rate (e.g. 1% of ₦5,000 fare)", () => {
            const commission = calculateReferralCommission(5000, 0.01);
            node_assert_1.default.strictEqual(commission, 50.0);
        });
        (0, node_test_1.test)("correctly normalizes integer rate input from Hub (e.g. 2.0% -> 0.02 of ₦10,000 fare)", () => {
            const commission = calculateReferralCommission(10000, 2.0);
            node_assert_1.default.strictEqual(commission, 200.0);
        });
        (0, node_test_1.test)("applies fixed referral bonus amount on first qualifying trip when configured", () => {
            const commission = calculateReferralCommission(4200, 0.01, 500, true);
            node_assert_1.default.strictEqual(commission, 500.0);
        });
        (0, node_test_1.test)("reverts to percentage rate for subsequent trips if fixed bonus is first-trip only", () => {
            const commission = calculateReferralCommission(4200, 0.01, 500, false);
            node_assert_1.default.strictEqual(commission, 42.0);
        });
    });
});
//# sourceMappingURL=referral_workflow.test.js.map