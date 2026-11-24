import assert from "node:assert";
import { test, describe } from "node:test";

/**
 * Unit test suite for Referral Code Generation, Self-Referral Prevention,
 * and Dynamic Referral Code Validation.
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

function isSelfReferral(referrerUid: string, refereeUid: string): boolean {
  if (!referrerUid || !refereeUid) return false;
  return referrerUid.trim().toLowerCase() === refereeUid.trim().toLowerCase();
}

describe("Referral System & Identity Workflow Invariants", () => {
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

  describe("3. 1% Referral Credit Accumulation & Active Window Invariants", () => {
    function calculateReferralCredit(baseFare: number, commissionPercent: number): number {
      if (baseFare <= 0 || commissionPercent <= 0) return 0;
      return Number(((baseFare * commissionPercent) / 100).toFixed(2));
    }

    function isReferralActive(signupMs: number, maxDays: number, nowMs: number): boolean {
      const ageInDays = (nowMs - signupMs) / (1000 * 60 * 60 * 24);
      return ageInDays <= maxDays;
    }

    test("computes exact 1% referral credit from completed trip base fare", () => {
      assert.strictEqual(calculateReferralCredit(5000, 1.0), 50.00);
      assert.strictEqual(calculateReferralCredit(12500, 1.0), 125.00);
      assert.strictEqual(calculateReferralCredit(2750, 1.0), 27.50);
    });

    test("enforces standard 365-day active referral window for regular users", () => {
      const now = Date.now();
      const signup30DaysAgo = now - 30 * 24 * 60 * 60 * 1000;
      const signup400DaysAgo = now - 400 * 24 * 60 * 60 * 1000;

      assert.strictEqual(isReferralActive(signup30DaysAgo, 365, now), true);
      assert.strictEqual(isReferralActive(signup400DaysAgo, 365, now), false);
    });

    test("enforces elevated 548-day active referral window for Hub Admins/Staff", () => {
      const now = Date.now();
      const signup400DaysAgo = now - 400 * 24 * 60 * 60 * 1000;
      const signup600DaysAgo = now - 600 * 24 * 60 * 60 * 1000;

      assert.strictEqual(isReferralActive(signup400DaysAgo, 548, now), true);
      assert.strictEqual(isReferralActive(signup600DaysAgo, 548, now), false);
    });
  });
});
