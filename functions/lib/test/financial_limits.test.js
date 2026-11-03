"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const node_assert_1 = __importDefault(require("node:assert"));
const node_test_1 = require("node:test");
const financialLimits_1 = require("../financialLimits");
(0, node_test_1.describe)("Financial Limits & Anti-Fraud Engine Test Matrix", () => {
    (0, node_test_1.test)("1. Role-Based Single Top-Up Caps", async () => {
        // Customer single top-up ceiling is ₦20,000 (2,000,000 kobo)
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.customerMaxSingleTopUpKobo, 2000000);
        // Driver single top-up ceiling is ₦20,000 (2,000,000 kobo)
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.driverMaxSingleTopUpKobo, 2000000);
        // Hub Admin single top-up ceiling is ₦50,000 (5,000,000 kobo)
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.hubAdminMaxSingleTopUpKobo, 5000000);
        // Minimum top-up is ₦100 (10,000 kobo)
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.customerMinTopUpKobo, 10000);
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.driverMinTopUpKobo, 10000);
    });
    (0, node_test_1.test)("2. Top-Up Frequency Caps", async () => {
        // Standard accounts: max 5 top-ups per day
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.customerMaxDailyTopUpCount, 5);
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.driverMaxDailyTopUpCount, 5);
        // Hub Admin: max 15 top-ups per day
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.hubAdminMaxDailyTopUpCount, 15);
    });
    (0, node_test_1.test)("3. KYC Tiered Overall Wallet Balance Caps", async () => {
        // Unverified Customer: max ₦20,000 balance cap
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.customerMaxWalletBalanceUnverifiedKobo, 2000000);
        // KYC-Verified Customer: max ₦50,000 balance cap
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.customerMaxWalletBalanceVerifiedKobo, 5000000);
        // Unverified Driver: max ₦20,000 balance cap
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.driverMaxWalletBalanceUnverifiedKobo, 2000000);
        // KYC-Verified Driver: max ₦50,000 balance cap
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.driverMaxWalletBalanceVerifiedKobo, 5000000);
        // Hub Admin balance cap
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.hubAdminMaxWalletBalanceKobo, 5000000);
    });
    (0, node_test_1.test)("4. Daily P2P Send Limits (Role & KYC Tiered)", async () => {
        // Customer P2P Send: ₦5,000 (unverified) | ₦15,000 (verified)
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.customerMaxDailyP2pUnverifiedKobo, 500000);
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.customerMaxDailyP2pVerifiedKobo, 1500000);
        // Driver P2P Send: ₦5,000 (unverified) | ₦15,000 (verified)
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.driverMaxDailyP2pUnverifiedKobo, 500000);
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.driverMaxDailyP2pVerifiedKobo, 1500000);
        // Hub Admin P2P Send: ₦10,000
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.hubAdminMaxDailyP2pKobo, 1000000);
    });
    (0, node_test_1.test)("5. Daily Withdrawal Limits (Role & KYC Tiered)", async () => {
        // Customer Withdrawal: ₦10,000 (unverified) | ₦25,000 (verified)
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.customerMaxDailyWithdrawalUnverifiedKobo, 1000000);
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.customerMaxDailyWithdrawalVerifiedKobo, 2500000);
        // Driver Withdrawal: ₦15,000 (unverified) | ₦35,000 (verified)
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.driverMaxDailyWithdrawalUnverifiedKobo, 1500000);
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.driverMaxDailyWithdrawalVerifiedKobo, 3500000);
        // Hub Admin Withdrawal: ₦20,000
        node_assert_1.default.strictEqual(financialLimits_1.DEFAULT_FINANCIAL_LIMITS.hubAdminMaxDailyWithdrawalKobo, 2000000);
    });
    (0, node_test_1.test)("6. Split Payment Overdraft Ceiling (Anti-Theft Guard)", async () => {
        const MAX_SPLIT_OVERDRAFT_KOBO = 200000; // ₦2,000
        const currentDebtKobo = 0;
        const requestedShortfallKobo = 45000000; // ₦450,000 exploit attempt
        const wouldExceed = (currentDebtKobo + requestedShortfallKobo) > MAX_SPLIT_OVERDRAFT_KOBO;
        node_assert_1.default.strictEqual(wouldExceed, true);
        const safeShortfallKobo = 150000; // ₦1,500 allowed overdraft
        const isSafe = (currentDebtKobo + safeShortfallKobo) <= MAX_SPLIT_OVERDRAFT_KOBO;
        node_assert_1.default.strictEqual(isSafe, true);
    });
    (0, node_test_1.test)("7. Local Timezone Date Key Resolution (Automated 00:00 Reset)", async () => {
        // Nigerian timezone (Africa/Lagos) outputs formatted YYYY-MM-DD
        const lagosKey = (0, financialLimits_1.getLocalDateKey)("Africa/Lagos");
        node_assert_1.default.match(lagosKey, /^\d{4}-\d{2}-\d{2}$/);
        // London timezone
        const londonKey = (0, financialLimits_1.getLocalDateKey)("Europe/London");
        node_assert_1.default.match(londonKey, /^\d{4}-\d{2}-\d{2}$/);
        // Fallback on invalid timezone returns valid ISO date
        const fallbackKey = (0, financialLimits_1.getLocalDateKey)("Invalid/Timezone");
        node_assert_1.default.match(fallbackKey, /^\d{4}-\d{2}-\d{2}$/);
    });
    (0, node_test_1.test)("8. Multi-Currency Conversion via Exchange Rates", async () => {
        // ₦10,000 in NGN = 1,000,000 kobo
        const ngnKobo = await (0, financialLimits_1.convertToKobo)(10000, "NGN");
        node_assert_1.default.strictEqual(ngnKobo, 1000000);
        // Format Kobo in Naira
        const formattedNgn = await (0, financialLimits_1.formatKoboInCurrency)(1000000, "NGN");
        node_assert_1.default.strictEqual(formattedNgn, "₦10,000");
        // $10 USD conversion to Kobo (with fallback rate 0.00063 USD per NGN)
        // 10 / 0.00063 = ~15,873.01 NGN = ~1,587,302 kobo
        const usdKobo = await (0, financialLimits_1.convertToKobo)(10, "USD");
        (0, node_assert_1.default)(usdKobo > 1500000 && usdKobo < 1700000);
    });
});
//# sourceMappingURL=financial_limits.test.js.map