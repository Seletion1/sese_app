import assert from "node:assert";
import { test, describe } from "node:test";
import { checkProxyRateLimit } from "../googleMaps";

describe("Security Fixes: Rate Limiting & Bank Code Validation", () => {
  describe("Google Maps Proxy Rate Limiting", () => {
    test("allows up to 60 requests per minute and throttles subsequent requests", () => {
      const testUid = `rate_limit_test_user_${Date.now()}`;
      
      // First 60 requests should succeed
      for (let i = 0; i < 60; i++) {
        assert.doesNotThrow(() => checkProxyRateLimit(testUid));
      }

      // 61st request should be throttled
      assert.throws(
        () => checkProxyRateLimit(testUid),
        (err: any) => {
          return err.code === "resource-exhausted" || err.message?.includes("Too many location searches");
        }
      );
    });
  });

  describe("Bank Code Regex Validation (Fintech & Digital Banks)", () => {
    const bankCodeRegex = /^[a-zA-Z0-9]{3,6}$/;

    test("accepts traditional 3-digit bank codes", () => {
      assert.strictEqual(bankCodeRegex.test("058"), true); // GTBank
      assert.strictEqual(bankCodeRegex.test("044"), true); // Access Bank
      assert.strictEqual(bankCodeRegex.test("011"), true); // First Bank
      assert.strictEqual(bankCodeRegex.test("214"), true); // FCMB
    });

    test("accepts 5 and 6 digit fintech / MFB bank codes", () => {
      assert.strictEqual(bankCodeRegex.test("50515"), true);  // Moniepoint
      assert.strictEqual(bankCodeRegex.test("50211"), true);  // Kuda Bank
      assert.strictEqual(bankCodeRegex.test("999991"), true); // PalmPay
      assert.strictEqual(bankCodeRegex.test("999992"), true); // OPay
      assert.strictEqual(bankCodeRegex.test("090110"), true); // VFD MFB
    });

    test("rejects invalid bank codes", () => {
      assert.strictEqual(bankCodeRegex.test(""), false);
      assert.strictEqual(bankCodeRegex.test("1"), false);
      assert.strictEqual(bankCodeRegex.test("12"), false);
      assert.strictEqual(bankCodeRegex.test("1234567"), false); // too long (>6)
      assert.strictEqual(bankCodeRegex.test("058-A"), false); // special character
      assert.strictEqual(bankCodeRegex.test("05 8"), false);  // whitespace
    });
  });
});
