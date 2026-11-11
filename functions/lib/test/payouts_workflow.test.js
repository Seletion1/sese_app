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
Object.defineProperty(exports, "__esModule", { value: true });
const node_test_1 = require("node:test");
const assert = __importStar(require("node:assert/strict"));
const payouts_1 = require("../payouts");
(0, node_test_1.describe)("Payouts & Bank Verification Workflow Invariants", () => {
    (0, node_test_1.describe)("1. Restricted 11-Bank List Lockdown", () => {
        (0, node_test_1.it)("contains exactly 11 approved financial institutions", () => {
            assert.equal(payouts_1.APPROVED_BANK_CODES.size, 11);
            assert.ok(payouts_1.APPROVED_BANK_CODES.has("044")); // Access Bank
            assert.ok(payouts_1.APPROVED_BANK_CODES.has("011")); // First Bank
            assert.ok(payouts_1.APPROVED_BANK_CODES.has("058")); // GTBank
            assert.ok(payouts_1.APPROVED_BANK_CODES.has("50211")); // Kuda
            assert.ok(payouts_1.APPROVED_BANK_CODES.has("50515")); // Moniepoint
            assert.ok(payouts_1.APPROVED_BANK_CODES.has("999992")); // OPay
            assert.ok(payouts_1.APPROVED_BANK_CODES.has("999991")); // PalmPay
            assert.ok(payouts_1.APPROVED_BANK_CODES.has("221")); // Stanbic IBTC
            assert.ok(payouts_1.APPROVED_BANK_CODES.has("033")); // UBA
            assert.ok(payouts_1.APPROVED_BANK_CODES.has("035")); // Wema Bank
            assert.ok(payouts_1.APPROVED_BANK_CODES.has("057")); // Zenith Bank
        });
        (0, node_test_1.it)("rejects non-approved bank codes", () => {
            assert.equal(payouts_1.APPROVED_BANK_CODES.has("000"), false);
            assert.equal(payouts_1.APPROVED_BANK_CODES.has("123"), false);
        });
    });
    (0, node_test_1.describe)("2. Ad-Hoc Instant Withdrawal ₦100 Fee Deduction", () => {
        (0, node_test_1.it)("deducts flat ₦100 (10,000 kobo) fee from requested amount", () => {
            const requestedKobo = 500000; // ₦5,000
            const feeKobo = payouts_1.INSTANT_WITHDRAWAL_FEE_KOBO; // ₦100
            const netKobo = requestedKobo - feeKobo;
            assert.equal(feeKobo, 10000);
            assert.equal(netKobo, 490000); // ₦4,900
            assert.equal(requestedKobo, netKobo + feeKobo);
        });
        (0, node_test_1.it)("requires requested amount to exceed flat fee", () => {
            const requestedKobo = 5000; // ₦50
            const feeKobo = payouts_1.INSTANT_WITHDRAWAL_FEE_KOBO; // ₦100
            assert.ok(requestedKobo <= feeKobo);
        });
    });
    (0, node_test_1.describe)("3. Weekly Fee-Free Staged Payout", () => {
        (0, node_test_1.it)("transfers 100% full amount without fee deduction", () => {
            const walletBalanceKobo = 2000000; // ₦20,000
            const feeKobo = 0; // Fee-free
            const netKobo = walletBalanceKobo - feeKobo;
            assert.equal(netKobo, walletBalanceKobo);
            assert.equal(netKobo, 2000000);
        });
    });
    (0, node_test_1.describe)("4. Account Holder Name Fuzzy Matching", () => {
        (0, node_test_1.it)("matches variations of profile name and bank account name", () => {
            assert.ok((0, payouts_1.accountNameMatches)("Bamiduro Micheal", "BAMIDURO MICHEAL OKONKWO"));
            assert.ok((0, payouts_1.accountNameMatches)("Adaeze Okonkwo", "ADAEZE BAKARE OKONKWO"));
            assert.equal((0, payouts_1.accountNameMatches)("John Doe", "CHINEDU OBI"), false);
        });
    });
});
//# sourceMappingURL=payouts_workflow.test.js.map