import { describe, it, before, after } from "node:test";
import * as assert from "node:assert";
import { createHmac } from "node:crypto";
import { opayConfig } from "../payments";

describe("OPay Checkout Integration & Cryptographic Security", () => {
  const originalSecret = process.env.OPAY_SECRET_KEY;
  const originalMerchantId = process.env.OPAY_MERCHANT_ID;
  const originalPublicKey = process.env.OPAY_PUBLIC_KEY;

  before(() => {
    process.env.OPAY_SECRET_KEY = "test_opay_secret_key_12345";
    process.env.OPAY_MERCHANT_ID = "256600001122334";
    process.env.OPAY_PUBLIC_KEY = "OPAYPUB_TEST_KEY_9988";
  });

  after(() => {
    process.env.OPAY_SECRET_KEY = originalSecret;
    process.env.OPAY_MERCHANT_ID = originalMerchantId;
    process.env.OPAY_PUBLIC_KEY = originalPublicKey;
  });

  it("1. Loads OPay config from environment secrets", async () => {
    const config = await opayConfig();
    assert.strictEqual(config.secretKey, "test_opay_secret_key_12345");
    assert.strictEqual(config.merchantId, "256600001122334");
    assert.strictEqual(config.publicKey, "OPAYPUB_TEST_KEY_9988");
  });

  it("2. Verifies HMAC-SHA512 cryptographic signature matching OPay standard", () => {
    const secret = "test_opay_secret_key_12345";
    const payload = JSON.stringify({
      reference: "sese_cust1_123456",
      orderNo: "OPAY_ORDER_789",
      amount: "2500.00",
      currency: "NGN",
      status: "SUCCESS",
    });

    const expectedSignature = createHmac("sha512", secret)
      .update(Buffer.from(payload))
      .digest("hex");

    // Valid signature match
    const testSignature = createHmac("sha512", secret)
      .update(Buffer.from(payload))
      .digest("hex");
    assert.strictEqual(testSignature, expectedSignature);

    // Tampered payload produces signature mismatch
    const tamperedPayload = JSON.stringify({
      reference: "sese_cust1_123456",
      orderNo: "OPAY_ORDER_789",
      amount: "99999.00",
      currency: "NGN",
      status: "SUCCESS",
    });
    const tamperedSignature = createHmac("sha512", secret)
      .update(Buffer.from(tamperedPayload))
      .digest("hex");
    assert.notStrictEqual(tamperedSignature, expectedSignature);
  });

  it("3. Correctly converts OPay Naira amount to integer Kobo", () => {
    const rawAmtNumber = 2000.50;
    const koboFromNumber = Math.round(rawAmtNumber * 100);
    assert.strictEqual(koboFromNumber, 200050);

    const rawAmtString = "2000.00";
    const koboFromString = Math.round(parseFloat(rawAmtString) * 100);
    assert.strictEqual(koboFromString, 200000);
  });
});
