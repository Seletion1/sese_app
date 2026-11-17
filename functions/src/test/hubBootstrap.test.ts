import assert from "node:assert";
import { test, describe, beforeEach, afterEach } from "node:test";
import { CallableRequest, HttpsError } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import { bootstrapHubOwner } from "../hubBootstrap";

describe("bootstrapHubOwner — Platform Owner Bootstrapping & Security Guards", () => {
  let store: Map<string, Record<string, unknown>> = new Map();
  let userClaimsMap: Map<string, Record<string, unknown>> = new Map();
  const originalDescriptor = Object.getOwnPropertyDescriptor(admin, "firestore");
  const originalAuthDescriptor = Object.getOwnPropertyDescriptor(admin, "auth");

  beforeEach(() => {
    process.env.DISABLE_APP_CHECK = "true";
    delete process.env.ALLOW_REBOOTSTRAP;
    delete process.env.BOOTSTRAP_SECRET;
    store = new Map();
    userClaimsMap = new Map();

    const mockDb = () => ({
      collection: (collName: string) => ({
        doc: (docId: string) => {
          const docPath = `${collName}/${docId}`;
          return {
            get: async () => {
              const data = store.get(docPath);
              return {
                exists: data !== undefined,
                data: () => data,
              };
            },
            set: async (val: Record<string, unknown>, opts?: { merge?: boolean }) => {
              const existing = store.get(docPath) || {};
              store.set(
                docPath,
                opts?.merge ? { ...existing, ...val } : { ...val }
              );
            },
          };
        },
      }),
    });

    Object.defineProperty(mockDb, "FieldValue", {
      value: {
        serverTimestamp: () => new Date().toISOString(),
      },
      writable: true,
    });

    Object.defineProperty(admin, "firestore", {
      get: () => mockDb,
      configurable: true,
    });

    const mockAuth = () => ({
      getUser: async (uid: string) => ({
        uid,
        customClaims: userClaimsMap.get(uid) || {},
      }),
      setCustomUserClaims: async (uid: string, claims: Record<string, unknown>) => {
        userClaimsMap.set(uid, claims);
      },
    });

    Object.defineProperty(admin, "auth", {
      get: () => mockAuth,
      configurable: true,
    });
  });

  afterEach(() => {
    if (originalDescriptor) {
      Object.defineProperty(admin, "firestore", originalDescriptor);
    }
    if (originalAuthDescriptor) {
      Object.defineProperty(admin, "auth", originalAuthDescriptor);
    }
  });

  test("rejects unauthenticated request", async () => {
    await assert.rejects(
      async () => await bootstrapHubOwner.run({} as any),
      (err: unknown) => {
        assert.ok(err instanceof HttpsError);
        assert.strictEqual(err.code, "unauthenticated");
        return true;
      }
    );
  });

  test("rejects non-platform owner email", async () => {
    const req = {
      auth: { uid: "user_unauthorized", token: { email: "unauthorized@example.com" } },
    } as unknown as CallableRequest;

    await assert.rejects(
      async () => await bootstrapHubOwner.run(req),
      (err: unknown) => {
        assert.ok(err instanceof HttpsError);
        assert.strictEqual(err.code, "permission-denied");
        assert.match(err.message, /Only the primary platform owner/);
        return true;
      }
    );
  });

  test("successfully bootstraps primary platform owner", async () => {
    const req = {
      auth: { uid: "owner_uid_1", token: { email: "bamiduromichael2@gmail.com" } },
    } as unknown as CallableRequest;

    const res = await bootstrapHubOwner.run(req);
    assert.strictEqual(res.success, true);
    assert.strictEqual(res.role, "Super");

    // Verify Auth claims created
    const claims = userClaimsMap.get("owner_uid_1");
    assert.strictEqual(claims?.role, "SUPER_ADMIN");
    assert.strictEqual(claims?.admin, true);

    // Verify hub_staff document created
    const staffDoc = store.get("hub_staff/bamiduromichael2@gmail.com");
    assert.ok(staffDoc);
    assert.strictEqual(staffDoc.role, "Super");
    assert.strictEqual(staffDoc.active, true);
  });

  test("locks re-triggering when already bootstrapped", async () => {
    const ownerEmail = "bamiduromichael1@gmail.com";
    store.set(`hub_staff/${ownerEmail}`, {
      email: ownerEmail,
      role: "Super",
      active: true,
    });
    userClaimsMap.set("owner_uid_2", { role: "SUPER_ADMIN", admin: true });

    const req = {
      auth: { uid: "owner_uid_2", token: { email: ownerEmail } },
    } as unknown as CallableRequest;

    await assert.rejects(
      async () => await bootstrapHubOwner.run(req),
      (err: unknown) => {
        assert.ok(err instanceof HttpsError);
        assert.strictEqual(err.code, "already-exists");
        assert.match(err.message, /already bootstrapped and active/);
        return true;
      }
    );
  });
});
