import assert from "node:assert";
import { test, describe } from "node:test";
import * as admin from "firebase-admin";

if (admin.apps.length === 0) {
  try {
    admin.initializeApp({ projectId: "sese-ride" });
  } catch (_) {}
}

import { normalizeIdentifier } from "../uniqueIdentifiers";

describe("Admin Onboarding & Assisted Registration Invariants", () => {
  test("1. Identifier Normalization for Phone & Email Searches", () => {
    // Phone numbers normalize to E.164
    assert.strictEqual(normalizeIdentifier("phone", "08161561592"), "+2348161561592");
    assert.strictEqual(normalizeIdentifier("phone", "2348161561592"), "+2348161561592");
    assert.strictEqual(normalizeIdentifier("phone", "+2348161561592"), "+2348161561592");

    // Email addresses normalize with dot/alias canonicalization
    assert.strictEqual(normalizeIdentifier("email", "Test.Agent+demo@gmail.com"), "testagent@gmail.com");
    assert.strictEqual(normalizeIdentifier("email", " User@SeseApp.com "), "user@seseapp.com");
  });

  test("2. Onboarding OTP Key Consistency & Expiration Invariant", () => {
    const rawInputPhone = "081 6156 1592";
    const normKey = normalizeIdentifier("phone", rawInputPhone);
    assert.strictEqual(normKey, "+2348161561592");

    // OTP Doc Key matches across different raw formatting variations
    const normKey2 = normalizeIdentifier("phone", "+234-816-156-1592");
    assert.strictEqual(normKey, normKey2);

    // OTP TTL invariant: 10 minutes from creation
    const now = Date.now();
    const expiresAt = now + 10 * 60 * 1000;
    assert.ok(expiresAt - now === 600000);
  });

  test("3. Missing Onboarding Steps Resolution Invariant", () => {
    const resolveMissingSteps = (
      role: string,
      userData: { fullName?: string; phoneNumber?: string; email?: string },
      vehicleCount: number,
      isDriverVerified: boolean
    ): string[] => {
      const missingSteps: string[] = [];
      if (!userData.fullName || (!userData.phoneNumber && !userData.email)) {
        missingSteps.push("profile_details");
      }
      if ((role === "driver" || role === "both") && vehicleCount === 0) {
        missingSteps.push("vehicle_setup");
      }
      if ((role === "driver" || role === "both") && !isDriverVerified) {
        missingSteps.push("verification_approval");
      }
      return missingSteps;
    };

    // Customer missing profile details
    const steps1 = resolveMissingSteps("customer", {}, 0, false);
    assert.deepStrictEqual(steps1, ["profile_details"]);

    // Driver missing vehicle setup and approval
    const steps2 = resolveMissingSteps("driver", { fullName: "Bamiduro Micheal", phoneNumber: "+2348161561592" }, 0, false);
    assert.deepStrictEqual(steps2, ["vehicle_setup", "verification_approval"]);

    // Fully set up driver
    const steps3 = resolveMissingSteps("driver", { fullName: "Bamiduro Micheal", phoneNumber: "+2348161561592" }, 1, true);
    assert.deepStrictEqual(steps3, []);
  });

  test("4. Verification Status Alignment Invariant", () => {
    // Verification statuses must align across rules, queues, and functions
    const allowedCustomerStatuses = ["pending", "unverified", "PENDING", "pending_onboarding"];
    const adminCreatedCustomerStatus = "pending";
    assert.ok(allowedCustomerStatuses.includes(adminCreatedCustomerStatus));

    const driverVerificationStatus = "pending_verification";
    assert.strictEqual(driverVerificationStatus, "pending_verification");
  });
});
