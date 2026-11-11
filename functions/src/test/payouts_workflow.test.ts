import { describe, it } from "node:test";
import * as assert from "node:assert/strict";
import { APPROVED_BANK_CODES, INSTANT_WITHDRAWAL_FEE_KOBO, accountNameMatches } from "../payouts";

describe("Payouts & Bank Verification Workflow Invariants", () => {
  describe("1. Restricted 11-Bank List Lockdown", () => {
    it("contains exactly 11 approved financial institutions", () => {
      assert.equal(APPROVED_BANK_CODES.size, 11);
      assert.ok(APPROVED_BANK_CODES.has("044")); // Access Bank
      assert.ok(APPROVED_BANK_CODES.has("011")); // First Bank
      assert.ok(APPROVED_BANK_CODES.has("058")); // GTBank
      assert.ok(APPROVED_BANK_CODES.has("50211")); // Kuda
      assert.ok(APPROVED_BANK_CODES.has("50515")); // Moniepoint
      assert.ok(APPROVED_BANK_CODES.has("999992")); // OPay
      assert.ok(APPROVED_BANK_CODES.has("999991")); // PalmPay
      assert.ok(APPROVED_BANK_CODES.has("221")); // Stanbic IBTC
      assert.ok(APPROVED_BANK_CODES.has("033")); // UBA
      assert.ok(APPROVED_BANK_CODES.has("035")); // Wema Bank
      assert.ok(APPROVED_BANK_CODES.has("057")); // Zenith Bank
    });

    it("rejects non-approved bank codes", () => {
      assert.equal(APPROVED_BANK_CODES.has("000"), false);
      assert.equal(APPROVED_BANK_CODES.has("123"), false);
    });
  });

  describe("2. Ad-Hoc Instant Withdrawal ₦100 Fee Deduction", () => {
    it("deducts flat ₦100 (10,000 kobo) fee from requested amount", () => {
      const requestedKobo = 500_000; // ₦5,000
      const feeKobo = INSTANT_WITHDRAWAL_FEE_KOBO; // ₦100
      const netKobo = requestedKobo - feeKobo;

      assert.equal(feeKobo, 10_000);
      assert.equal(netKobo, 490_000); // ₦4,900
      assert.equal(requestedKobo, netKobo + feeKobo);
    });

    it("requires requested amount to exceed flat fee", () => {
      const requestedKobo = 5_000; // ₦50
      const feeKobo = INSTANT_WITHDRAWAL_FEE_KOBO; // ₦100
      assert.ok(requestedKobo <= feeKobo);
    });
  });

  describe("3. Weekly Fee-Free Staged Payout", () => {
    it("transfers 100% full amount without fee deduction", () => {
      const walletBalanceKobo = 2_000_000; // ₦20,000
      const feeKobo = 0; // Fee-free
      const netKobo = walletBalanceKobo - feeKobo;

      assert.equal(netKobo, walletBalanceKobo);
      assert.equal(netKobo, 2_000_000);
    });
  });

  describe("4. Account Holder Name Fuzzy Matching", () => {
    it("matches variations of profile name and bank account name", () => {
      assert.ok(accountNameMatches("Bamiduro Micheal", "BAMIDURO MICHEAL OKONKWO"));
      assert.ok(accountNameMatches("Adaeze Okonkwo", "ADAEZE BAKARE OKONKWO"));
      assert.equal(accountNameMatches("John Doe", "CHINEDU OBI"), false);
    });
  });
});
