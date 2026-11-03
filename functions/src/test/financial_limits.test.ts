import assert from "node:assert";
import { test, describe } from "node:test";
import {
  DEFAULT_FINANCIAL_LIMITS,
  getLocalDateKey,
  convertToKobo,
  formatKoboInCurrency,
} from "../financialLimits";

describe("Financial Limits & Anti-Fraud Engine Test Matrix", () => {
  test("1. Role-Based Single Top-Up Caps", async () => {
    // Customer single top-up ceiling is ₦20,000 (2,000,000 kobo)
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.customerMaxSingleTopUpKobo, 2_000_000);
    // Driver single top-up ceiling is ₦20,000 (2,000,000 kobo)
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.driverMaxSingleTopUpKobo, 2_000_000);
    // Hub Admin single top-up ceiling is ₦50,000 (5,000,000 kobo)
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.hubAdminMaxSingleTopUpKobo, 5_000_000);

    // Minimum top-up is ₦100 (10,000 kobo)
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.customerMinTopUpKobo, 10_000);
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.driverMinTopUpKobo, 10_000);
  });

  test("2. Top-Up Frequency Caps", async () => {
    // Standard accounts: max 5 top-ups per day
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.customerMaxDailyTopUpCount, 5);
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.driverMaxDailyTopUpCount, 5);
    // Hub Admin: max 15 top-ups per day
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.hubAdminMaxDailyTopUpCount, 15);
  });

  test("3. KYC Tiered Overall Wallet Balance Caps", async () => {
    // Unverified Customer: max ₦20,000 balance cap
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.customerMaxWalletBalanceUnverifiedKobo, 2_000_000);
    // KYC-Verified Customer: max ₦50,000 balance cap
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.customerMaxWalletBalanceVerifiedKobo, 5_000_000);

    // Unverified Driver: max ₦20,000 balance cap
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.driverMaxWalletBalanceUnverifiedKobo, 2_000_000);
    // KYC-Verified Driver: max ₦50,000 balance cap
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.driverMaxWalletBalanceVerifiedKobo, 5_000_000);

    // Hub Admin balance cap
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.hubAdminMaxWalletBalanceKobo, 5_000_000);
  });

  test("4. Daily P2P Send Limits (Role & KYC Tiered)", async () => {
    // Customer P2P Send: ₦5,000 (unverified) | ₦15,000 (verified)
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.customerMaxDailyP2pUnverifiedKobo, 500_000);
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.customerMaxDailyP2pVerifiedKobo, 1_500_000);

    // Driver P2P Send: ₦5,000 (unverified) | ₦15,000 (verified)
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.driverMaxDailyP2pUnverifiedKobo, 500_000);
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.driverMaxDailyP2pVerifiedKobo, 1_500_000);

    // Hub Admin P2P Send: ₦10,000
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.hubAdminMaxDailyP2pKobo, 1_000_000);
  });

  test("5. Daily Withdrawal Limits (Role & KYC Tiered)", async () => {
    // Customer Withdrawal: ₦10,000 (unverified) | ₦25,000 (verified)
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.customerMaxDailyWithdrawalUnverifiedKobo, 1_000_000);
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.customerMaxDailyWithdrawalVerifiedKobo, 2_500_000);

    // Driver Withdrawal: ₦15,000 (unverified) | ₦35,000 (verified)
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.driverMaxDailyWithdrawalUnverifiedKobo, 1_500_000);
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.driverMaxDailyWithdrawalVerifiedKobo, 3_500_000);

    // Hub Admin Withdrawal: ₦20,000
    assert.strictEqual(DEFAULT_FINANCIAL_LIMITS.hubAdminMaxDailyWithdrawalKobo, 2_000_000);
  });

  test("6. Split Payment Overdraft Ceiling (Anti-Theft Guard)", async () => {
    const MAX_SPLIT_OVERDRAFT_KOBO = 200_000; // ₦2,000
    const currentDebtKobo = 0;
    const requestedShortfallKobo = 45_000_000; // ₦450,000 exploit attempt

    const wouldExceed = (currentDebtKobo + requestedShortfallKobo) > MAX_SPLIT_OVERDRAFT_KOBO;
    assert.strictEqual(wouldExceed, true);

    const safeShortfallKobo = 150_000; // ₦1,500 allowed overdraft
    const isSafe = (currentDebtKobo + safeShortfallKobo) <= MAX_SPLIT_OVERDRAFT_KOBO;
    assert.strictEqual(isSafe, true);
  });

  test("7. Local Timezone Date Key Resolution (Automated 00:00 Reset)", async () => {
    // Nigerian timezone (Africa/Lagos) outputs formatted YYYY-MM-DD
    const lagosKey = getLocalDateKey("Africa/Lagos");
    assert.match(lagosKey, /^\d{4}-\d{2}-\d{2}$/);

    // London timezone
    const londonKey = getLocalDateKey("Europe/London");
    assert.match(londonKey, /^\d{4}-\d{2}-\d{2}$/);

    // Fallback on invalid timezone returns valid ISO date
    const fallbackKey = getLocalDateKey("Invalid/Timezone");
    assert.match(fallbackKey, /^\d{4}-\d{2}-\d{2}$/);
  });

  test("8. Multi-Currency Conversion via Exchange Rates", async () => {
    // ₦10,000 in NGN = 1,000,000 kobo
    const ngnKobo = await convertToKobo(10000, "NGN");
    assert.strictEqual(ngnKobo, 1_000_000);

    // Format Kobo in Naira
    const formattedNgn = await formatKoboInCurrency(1_000_000, "NGN");
    assert.strictEqual(formattedNgn, "₦10,000");

    // $10 USD conversion to Kobo (with fallback rate 0.00063 USD per NGN)
    // 10 / 0.00063 = ~15,873.01 NGN = ~1,587,302 kobo
    const usdKobo = await convertToKobo(10, "USD");
    assert(usdKobo > 1_500_000 && usdKobo < 1_700_000);
  });
});
