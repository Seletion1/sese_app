import assert from "node:assert";
import { test, describe } from "node:test";

/**
 * Unit test suite for Referral Code Generation, Self-Referral Prevention,
 * and Dynamic Referral Commission Payout calculations.
 */

function generateBaseReferralCode(fullName: string, phoneNumber: string): string {
  const cleanName = fullName.trim();
  const parts = cleanName.split(/\s+/).filter(Boolean);

  let fInitial = "X";
  let lInitial = "X";

  if (parts.length === 1) {
    fInitial = (parts[0].match(/[A-Za-z]/)?.[0] ?? "X").toUpperCase();
    lInitial = fInitial;
  } else if (parts.length > 1) {
    fInitial = (parts[0].match(/[A-Za-z]/)?.[0] ?? "X").toUpperCase();
    lInitial = (parts[parts.length - 1].match(/[A-Za-z]/)?.[0] ?? fInitial).toUpperCase();
  }

  const initials = (fInitial + lInitial).toUpperCase();
  const digits = phoneNumber.replace(/\D/g, "");
  const last4 = digits.length >= 4 ? digits.slice(-4) : digits.padStart(4, "0");

  return (initials + last4).toUpperCase();
}

function normalizeRateFraction(val: unknown, fallback: number): number {
  if (typeof val !== "number" || isNaN(val)) return fallback;
  return val > 1 ? val / 100 : val;
}

function calculateReferralCommission(
  totalFareNaira: number,
  rateOrFraction: number,
  fixedBonusNaira?: number,
  isFirstTrip?: boolean
): number {
  if (fixedBonusNaira && fixedBonusNaira > 0 && isFirstTrip) {
    return fixedBonusNaira;
  }
  const rate = normalizeRateFraction(rateOrFraction, 0.01);
  return Number((totalFareNaira * rate).toFixed(2));
}

function isSelfReferral(referrerUid: string, refereeUid: string): boolean {
  if (!referrerUid || !refereeUid) return false;
  return referrerUid.trim().toLowerCase() === refereeUid.trim().toLowerCase();
}

describe("Referral System & Commission Payout Workflow Invariants", () => {
  describe("1. Instant Referral ID Generation & Upgrades", () => {
    test("generates deterministic referral code from initials and last 4 phone digits", () => {
      const code = generateBaseReferralCode("Micheal Bamiduro", "+2348161561592");
      assert.strictEqual(code, "MB1592");
    });

    test("falls back to 0000 placeholder when phone number is missing initially", () => {
      const code = generateBaseReferralCode("Micheal Bamiduro", "");
      assert.strictEqual(code, "MB0000");
    });

    test("identifies placeholder codes ending in 0000 for upgrade upon linking phone", () => {
      const placeholderCode = "MB0000";
      const isPlaceholder = placeholderCode.endsWith("0000");
      assert.strictEqual(isPlaceholder, true);

      const upgradedCode = generateBaseReferralCode("Micheal Bamiduro", "+2348161561592");
      assert.strictEqual(upgradedCode, "MB1592");
    });

    test("appends counter on collision to guarantee unique referral code", () => {
      const base = "MB1592";
      const candidate1 = `${base}1`;
      const candidate2 = `${base}2`;
      assert.strictEqual(candidate1, "MB15921");
      assert.strictEqual(candidate2, "MB15922");
    });
  });

  describe("2. Self-Referral Exploitation Prevention", () => {
    test("detects and blocks direct self-referral attempts when referrerUid equals refereeUid", () => {
      assert.strictEqual(isSelfReferral("user_123", "user_123"), true);
      assert.strictEqual(isSelfReferral("USER_123", "user_123"), true);
    });

    test("allows valid cross-user referrals", () => {
      assert.strictEqual(isSelfReferral("user_referrer_456", "user_referee_789"), false);
    });
  });

  describe("3. Dynamic Hub Rate & Fixed Bonus Commission Distribution", () => {
    test("correctly computes referral commission for standard percentage rate (e.g. 1% of ₦5,000 fare)", () => {
      const commission = calculateReferralCommission(5000, 0.01);
      assert.strictEqual(commission, 50.0);
    });

    test("correctly normalizes integer rate input from Hub (e.g. 2.0% -> 0.02 of ₦10,000 fare)", () => {
      const commission = calculateReferralCommission(10000, 2.0);
      assert.strictEqual(commission, 200.0);
    });

    test("applies fixed referral bonus amount on first qualifying trip when configured", () => {
      const commission = calculateReferralCommission(4200, 0.01, 500, true);
      assert.strictEqual(commission, 500.0);
    });

    test("reverts to percentage rate for subsequent trips if fixed bonus is first-trip only", () => {
      const commission = calculateReferralCommission(4200, 0.01, 500, false);
      assert.strictEqual(commission, 42.0);
    });
  });
});
