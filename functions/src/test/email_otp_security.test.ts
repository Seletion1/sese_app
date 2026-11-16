import assert from "node:assert";
import { test, describe } from "node:test";
import * as admin from "firebase-admin";

if (admin.apps.length === 0) {
  try {
    admin.initializeApp({ projectId: "sese-ride" });
  } catch (_) {}
}

import { sendEmailOtp, checkEmailOtpRateLimit } from "../email";

describe("Email OTP Security & Open Relay Prevention", () => {
  describe("sendEmailOtp email pinning & authentication", () => {
    test("rejects unauthenticated OTP requests", async () => {
      const unauthReq = {
        data: { email: "attacker@example.com" },
      } as any;

      await assert.rejects(
        async () => {
          await sendEmailOtp.run(unauthReq);
        },
        (err: any) => err.code === "unauthenticated"
      );
    });

    test("rejects request if caller-supplied email mismatches authenticated email token", async () => {
      const mismatchedReq = {
        app: {
          appId: "com.sese.ride",
          alreadyConsumed: false,
        },
        auth: {
          uid: "user_victim_123",
          token: { email: "victim@example.com" },
        },
        data: {
          email: "attacker@example.com",
        },
      } as any;

      await assert.rejects(
        async () => {
          await sendEmailOtp.run(mismatchedReq);
        },
        (err: any) =>
          err.code === "invalid-argument" &&
          err.message.includes("Email address must match your authenticated profile")
      );
    });
  });

  describe("checkEmailOtpRateLimit rate limiting", () => {
    test("enforces sliding window rate limit per UID for OTP requests", () => {
      const testUid = `otp_rate_limit_user_${Date.now()}`;

      // Max 3 requests allowed per minute
      for (let i = 0; i < 3; i++) {
        assert.doesNotThrow(() => checkEmailOtpRateLimit(testUid));
      }

      // 4th request throws resource-exhausted
      assert.throws(
        () => checkEmailOtpRateLimit(testUid),
        (err: any) => err.code === "resource-exhausted"
      );
    });
  });
});
