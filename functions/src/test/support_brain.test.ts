import { describe, it } from "node:test";
import * as assert from "node:assert";
import { respondTo, isSafetyIssue } from "../supportBrain";

describe("SeSe Support Brain — Active AI Assistant & Knowledge Base Tests", () => {
  it("1. Responds directly to wallet top-up & crediting questions without escalating", async () => {
    const res = await respondTo("how do I credit my account", {
      userId: "test_user_123",
      userRole: "driver",
    });

    assert.strictEqual(res.kind, "reply");
    if (res.kind === "reply") {
      assert.strictEqual(res.topic, "topup");
      assert.ok(res.reply.includes("To top up your Driver Sese Credits"));
      assert.ok(res.reply.includes("Paystack or OPay"));
    }
  });

  it("2. Responds directly to Terms of Service & platform rules queries", async () => {
    const res = await respondTo("what are your rules and terms of service", {
      userId: "test_user_123",
      userRole: "customer",
    });

    assert.strictEqual(res.kind, "reply");
    if (res.kind === "reply") {
      assert.strictEqual(res.topic, "terms_of_service");
      assert.ok(res.reply.includes("Terms of Service Highlights"));
      assert.ok(res.reply.includes("https://sesetech.com/terms"));
    }
  });

  it("3. Responds directly to Privacy Policy & data protection queries", async () => {
    const res = await respondTo("what is your privacy policy and how is my data protected", {
      userId: "test_user_123",
      userRole: "customer",
    });

    assert.strictEqual(res.kind, "reply");
    if (res.kind === "reply") {
      assert.strictEqual(res.topic, "privacy_policy");
      assert.ok(res.reply.includes("Privacy & Data Protection Policy"));
      assert.ok(res.reply.includes("https://sesetech.com/PrivacyPolicy"));
    }
  });

  it("4. Responds directly to fare calculation and pricing queries", async () => {
    const res = await respondTo("how much is car fare and base price", {
      userId: "test_user_123",
      userRole: "customer",
    });

    assert.strictEqual(res.kind, "reply");
    if (res.kind === "reply") {
      assert.strictEqual(res.topic, "fare");
      assert.ok(res.reply.includes("Fares are calculated automatically"));
      assert.ok(res.reply.includes("Car, the base fare is"));
    }
  });

  it("5. Only escalates on explicit human requests", async () => {
    const res = await respondTo("I want to speak to a human support agent", {
      userId: "test_user_123",
      userRole: "customer",
    });

    assert.strictEqual(res.kind, "escalate");
    if (res.kind === "escalate") {
      assert.strictEqual(res.reason, "user-requested");
    }
  });

  it("6. Only escalates on safety & emergency issues", async () => {
    const isSafety = isSafetyIssue("there was an accident during the trip");
    assert.strictEqual(isSafety, true);

    const res = await respondTo("there was an accident during the trip", {
      userId: "test_user_123",
      userRole: "customer",
    });

    assert.strictEqual(res.kind, "escalate");
    if (res.kind === "escalate") {
      assert.strictEqual(res.reason, "safety");
    }
  });
});
