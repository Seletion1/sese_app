import assert from "node:assert";
import { test, describe } from "node:test";
import { assertHubStaffOrAdmin } from "../verification";
import { submitCancellationFeedback } from "../trips";

describe("Hub Security & RBAC Guards", () => {
  describe("assertHubStaffOrAdmin security verification", () => {
    test("rejects unauthenticated requests with permission-denied", async () => {
      await assert.rejects(
        async () => {
          await assertHubStaffOrAdmin(null);
        },
        (err: any) => {
          return err.code === "permission-denied";
        }
      );

      await assert.rejects(
        async () => {
          await assertHubStaffOrAdmin(undefined);
        },
        (err: any) => {
          return err.code === "permission-denied";
        }
      );
    });

    test("rejects standard customer and driver accounts without admin claims", async () => {
      const customerAuth = {
        uid: "user_cust_123",
        token: { email: "customer@example.com", role: "CUSTOMER" },
      };

      await assert.rejects(
        async () => {
          await assertHubStaffOrAdmin(customerAuth);
        },
        (err: any) => {
          return err.code === "permission-denied";
        }
      );

      const driverAuth = {
        uid: "driver_456",
        token: { email: "driver@example.com", role: "DRIVER" },
      };

      await assert.rejects(
        async () => {
          await assertHubStaffOrAdmin(driverAuth);
        },
        (err: any) => {
          return err.code === "permission-denied";
        }
      );
    });

    test("allows platform owner and admin accounts", async () => {
      const adminAuth = {
        uid: "admin_789",
        token: { email: "admin@example.com", admin: true, role: "SUPER_ADMIN" },
      };

      await assert.doesNotReject(async () => {
        await assertHubStaffOrAdmin(adminAuth);
      });
    });
  });

  describe("submitCancellationFeedback authentication and user attribution", () => {
    test("rejects unauthenticated feedback submission with unauthenticated error", async () => {
      const unauthRequest = {
        data: {
          tripId: "trip_test_99",
          userId: "spoofed_user",
          role: "customer",
          reason: "driver_taking_too_long",
        },
      } as any;

      await assert.rejects(
        async () => {
          await submitCancellationFeedback.run(unauthRequest);
        },
        (err: any) => {
          return err.code === "unauthenticated";
        }
      );
    });
  });
});
