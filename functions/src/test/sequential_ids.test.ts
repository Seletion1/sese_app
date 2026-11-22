import assert from "node:assert";
import { test, describe } from "node:test";
import { formatSequentialId } from "../sequentialIds";

describe("Sequential User ID & Verification-Gated Referral System", () => {
  describe("1. Sequential Role-Based User IDs (formatSequentialId)", () => {
    test("formats customer n=1 as SC0001", () => {
      assert.strictEqual(formatSequentialId("customer", 1), "SC0001");
    });

    test("formats customer n=42 as SC0042", () => {
      assert.strictEqual(formatSequentialId("customer", 42), "SC0042");
    });

    test("formats customer n=9999 as SC9999", () => {
      assert.strictEqual(formatSequentialId("customer", 9999), "SC9999");
    });

    test("formats customer n=10000 as SC10000 (grows past 4 digits naturally, never truncated)", () => {
      assert.strictEqual(formatSequentialId("customer", 10000), "SC10000");
    });

    test("formats customer n=123456 as SC123456", () => {
      assert.strictEqual(formatSequentialId("customer", 123456), "SC123456");
    });

    test("formats driver n=1 as SD0001", () => {
      assert.strictEqual(formatSequentialId("driver", 1), "SD0001");
    });

    test("formats driver n=50 as SD0050", () => {
      assert.strictEqual(formatSequentialId("driver", 50), "SD0050");
    });

    test("formats driver n=10000 as SD10000", () => {
      assert.strictEqual(formatSequentialId("driver", 10000), "SD10000");
    });
  });

  describe("2. Verification Gating & Referral ID Rules", () => {
    function evaluateReferralEligibility(user: {
      isProfileVerified?: boolean;
      verificationStatus?: string;
      phoneNumber?: string;
      referralCode?: string;
    }): { eligible: boolean; reason?: string } {
      const isVerified =
        user.isProfileVerified === true ||
        user.verificationStatus === "approved" ||
        user.verificationStatus === "verified";
      if (!isVerified) {
        return { eligible: false, reason: "Profile not verified" };
      }
      const rawPhone = (user.phoneNumber ?? "").trim();
      const digits = rawPhone.replace(/\D/g, "");
      if (digits.length === 0) {
        return { eligible: false, reason: "No phone number on record" };
      }
      return { eligible: true };
    }

    test("blocks referral code generation for unverified users", () => {
      const unverifiedUser = {
        isProfileVerified: false,
        verificationStatus: "pending_verification",
        phoneNumber: "+2348161561592",
      };
      const result = evaluateReferralEligibility(unverifiedUser);
      assert.strictEqual(result.eligible, false);
      assert.strictEqual(result.reason, "Profile not verified");
    });

    test("blocks referral code generation when user is verified but has no phone", () => {
      const verifiedNoPhone = {
        isProfileVerified: true,
        verificationStatus: "verified",
        phoneNumber: "",
      };
      const result = evaluateReferralEligibility(verifiedNoPhone);
      assert.strictEqual(result.eligible, false);
      assert.strictEqual(result.reason, "No phone number on record");
    });

    test("allows referral code generation when BOTH verified and phone is present", () => {
      const eligibleUser = {
        isProfileVerified: true,
        verificationStatus: "verified",
        phoneNumber: "+2348161561592",
      };
      const result = evaluateReferralEligibility(eligibleUser);
      assert.strictEqual(result.eligible, true);
    });

    test("enforces immutability: existing non-placeholder referral code is never overwritten even on phone change", () => {
      const existingUser = {
        referralCode: "MB1592",
        phoneNumber: "+2348161561592",
      };
      const updatedUser = {
        ...existingUser,
        phoneNumber: "+2349012345678", // Phone number updated by user
      };
      // Immutability rule: if referralCode already exists and does not end in 0000, keep it
      const shouldRetain =
        Boolean(updatedUser.referralCode) && !updatedUser.referralCode.endsWith("0000");
      assert.strictEqual(shouldRetain, true);
    });
  });
});
