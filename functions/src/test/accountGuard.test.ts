import assert from "node:assert";
import { test, describe, beforeEach, afterEach } from "node:test";
import { CallableRequest, HttpsError } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import { enforceAppCheck, requireAccountActive } from "../accountGuard";

describe("accountGuard — App Check & Account Suspension Gates", () => {
  const originalEnv = process.env.DISABLE_APP_CHECK;

  afterEach(() => {
    if (originalEnv !== undefined) {
      process.env.DISABLE_APP_CHECK = originalEnv;
    } else {
      delete process.env.DISABLE_APP_CHECK;
    }
  });

  describe("enforceAppCheck", () => {
    test("blocks request when App Check token is missing by default", () => {
      delete process.env.DISABLE_APP_CHECK;
      const fakeReq = {} as CallableRequest;

      assert.throws(
        () => enforceAppCheck(fakeReq),
        (err: unknown) => {
          assert.ok(err instanceof HttpsError);
          assert.strictEqual(err.code, "unauthenticated");
          assert.match(err.message, /missing a valid App Check token/);
          return true;
        }
      );
    });

    test("allows request when valid App Check token is present", () => {
      delete process.env.DISABLE_APP_CHECK;
      const fakeReq = {
        app: {
          appId: "com.sese.ride",
          alreadyConsumed: false,
        },
      } as CallableRequest;

      assert.doesNotThrow(() => enforceAppCheck(fakeReq));
    });

    test("bypasses enforcement when DISABLE_APP_CHECK=true", () => {
      process.env.DISABLE_APP_CHECK = "true";
      const fakeReq = {} as CallableRequest;

      assert.doesNotThrow(() => enforceAppCheck(fakeReq));
    });
  });

  describe("requireAccountActive", () => {
    let docMap: Map<string, Record<string, unknown> | null> = new Map();
    const originalDescriptor = Object.getOwnPropertyDescriptor(admin, "firestore");

    beforeEach(() => {
      docMap = new Map();

      const mockFirestore = () => {
        return {
          collection: (collName: string) => ({
            doc: (docId: string) => ({
              get: async () => {
                const key = `${collName}/${docId}`;
                if (docMap.has(key)) {
                  const val = docMap.get(key);
                  if (val === null) {
                    throw new Error("Simulated Firestore network timeout");
                  }
                  return {
                    exists: true,
                    data: () => val,
                  };
                }
                return {
                  exists: false,
                  data: () => undefined,
                };
              },
            }),
          }),
        };
      };

      Object.defineProperty(admin, "firestore", {
        get: () => mockFirestore,
        configurable: true,
      });
    });

    afterEach(() => {
      if (originalDescriptor) {
        Object.defineProperty(admin, "firestore", originalDescriptor);
      }
    });

    test("allows active users with clean documents", async () => {
      docMap.set("users/user_active_123", {
        accountStatus: "active",
        isSuspended: false,
      });

      await assert.doesNotReject(() =>
        requireAccountActive("user_active_123", "customer")
      );
    });

    test("fails closed when user document has isSuspended: true", async () => {
      docMap.set("users/user_suspended_123", {
        isSuspended: true,
      });

      await assert.rejects(
        () => requireAccountActive("user_suspended_123", "customer"),
        (err: unknown) => {
          assert.ok(err instanceof HttpsError);
          assert.strictEqual(err.code, "permission-denied");
          assert.match(err.message, /currently suspended/);
          return true;
        }
      );
    });

    test("fails closed when user document has isBanned: true", async () => {
      docMap.set("users/user_banned_123", {
        isBanned: true,
      });

      await assert.rejects(
        () => requireAccountActive("user_banned_123", "customer"),
        (err: unknown) => {
          assert.ok(err instanceof HttpsError);
          assert.strictEqual(err.code, "permission-denied");
          assert.match(err.message, /permanently banned/);
          return true;
        }
      );
    });

    test("fails closed when driver document is suspended and role === 'driver'", async () => {
      docMap.set("users/driver_456", { accountStatus: "active" });
      docMap.set("drivers/driver_456", { accountStatus: "suspended" });

      await assert.rejects(
        () => requireAccountActive("driver_456", "driver"),
        (err: unknown) => {
          assert.ok(err instanceof HttpsError);
          assert.strictEqual(err.code, "permission-denied");
          assert.match(err.message, /driver account is suspended/);
          return true;
        }
      );
    });

    test("fails open on genuine Firestore infra / network error", async () => {
      docMap.set("users/infra_err_789", null); // triggers Firestore read error throw

      await assert.doesNotReject(() =>
        requireAccountActive("infra_err_789", "customer")
      );
    });
  });
});
