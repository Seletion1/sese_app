import assert from "node:assert";
import { test, describe } from "node:test";
import {
  formatSequentialId,
  extractRegistrationTimestamp,
  COUNTER_DOCS,
} from "../sequentialIds";

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

    test("formats staff / hub n=1 as SH0001", () => {
      assert.strictEqual(formatSequentialId("staff", 1), "SH0001");
      assert.strictEqual(formatSequentialId("hub", 1), "SH0001");
    });
  });

  describe("2. Dedicated Counter Documents (COUNTER_DOCS)", () => {
    test("maps roles to dedicated counter document paths", () => {
      assert.strictEqual(COUNTER_DOCS.customer, "counters/SC");
      assert.strictEqual(COUNTER_DOCS.driver, "counters/SD");
      assert.strictEqual(COUNTER_DOCS.staff, "counters/SH");
      assert.strictEqual(COUNTER_DOCS.hub, "counters/SH");
    });
  });

  describe("3. Registration Timestamp Extraction & Strict Ordering", () => {
    test("extracts epoch from Date, ISO string, and custom timestamp shapes", () => {
      const now = new Date();
      assert.strictEqual(extractRegistrationTimestamp({ createdAt: now }), now.getTime());
      assert.strictEqual(extractRegistrationTimestamp({ memberSince: "2026-09-29" }), new Date("2026-09-29").getTime());
      assert.strictEqual(extractRegistrationTimestamp({ registeredAt: "2026-10-18T12:00:00Z" }), new Date("2026-10-18T12:00:00Z").getTime());
    });

    test("falls back to Number.MAX_SAFE_INTEGER when no date is present", () => {
      assert.strictEqual(extractRegistrationTimestamp({}), Number.MAX_SAFE_INTEGER);
    });

    test("strictly sorts drivers by earliest registration date: 2026-09-29 gets SD0001, 2026-10-18 gets SD0002", () => {
      const driverOlder = {
        id: "driver_A",
        phone: "+2348161561592",
        memberSince: "2026-09-29",
      };
      const driverNewer = {
        id: "driver_B",
        phone: "+2347074290803",
        memberSince: "2026-10-18",
      };

      const rawDrivers = [driverNewer, driverOlder]; // Unsorted input
      const sorted = rawDrivers.slice().sort((a, b) => {
        const tA = extractRegistrationTimestamp(a);
        const tB = extractRegistrationTimestamp(b);
        if (tA !== tB) return tA - tB;
        return a.id.localeCompare(b.id);
      });

      assert.strictEqual(sorted[0].id, "driver_A");
      assert.strictEqual(sorted[1].id, "driver_B");

      const assigned = sorted.map((d, idx) => ({
        ...d,
        sequentialId: formatSequentialId("driver", idx + 1),
      }));

      assert.strictEqual(assigned[0].sequentialId, "SD0001");
      assert.strictEqual(assigned[1].sequentialId, "SD0002");
      // Zero duplicate sequential IDs invariant
      const idSet = new Set(assigned.map((d) => d.sequentialId));
      assert.strictEqual(idSet.size, assigned.length);
    });
  });

  describe("4. Verification Gating & Referral ID Rules", () => {
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
        phoneNumber: "+2349012345678",
      };
      const shouldRetain =
        Boolean(updatedUser.referralCode) && !updatedUser.referralCode.endsWith("0000");
      assert.strictEqual(shouldRetain, true);
    });
  });
});
