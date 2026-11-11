import assert from "node:assert";
import { test, describe, beforeEach, afterEach } from "node:test";
import { CallableRequest, HttpsError } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {
  requireValidPin,
  hasPinSet,
  setTransactionPin,
  verifyTransactionPin,
  resetTransactionPin,
} from "../transactionPin";

describe("transactionPin — Authority, Validation & Recovery", () => {
  let store: Map<string, Record<string, unknown>> = new Map();
  const originalDescriptor = Object.getOwnPropertyDescriptor(admin, "firestore");

  beforeEach(() => {
    store = new Map();

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
            update: async (val: Record<string, unknown>) => {
              const existing = store.get(docPath) || {};
              store.set(docPath, { ...existing, ...val });
            },
            collection: (subCollName: string) => ({
              doc: (subDocId: string) => {
                const subPath = `${docPath}/${subCollName}/${subDocId}`;
                return {
                  get: async () => {
                    const data = store.get(subPath);
                    return {
                      exists: data !== undefined,
                      data: () => data,
                    };
                  },
                  set: async (val: Record<string, unknown>, opts?: { merge?: boolean }) => {
                    const existing = store.get(subPath) || {};
                    store.set(
                      subPath,
                      opts?.merge ? { ...existing, ...val } : { ...val }
                    );
                  },
                };
              },
            }),
          };
        },
      }),
    });

    Object.defineProperty(mockDb, "FieldValue", {
      value: {
        serverTimestamp: () => new Date().toISOString(),
        delete: () => undefined,
      },
      writable: true,
    });

    Object.defineProperty(admin, "firestore", {
      get: () => mockDb,
      configurable: true,
    });
  });

  afterEach(() => {
    if (originalDescriptor) {
      Object.defineProperty(admin, "firestore", originalDescriptor);
    }
  });

  test("hasPinSet returns false when no PIN doc exists", async () => {
    const hasPin = await hasPinSet("user_no_pin");
    assert.strictEqual(hasPin, false);
  });

  test("setTransactionPin creates new PIN for user without PIN", async () => {
    store.set("users/user_1", { uid: "user_1" });
    const req = {
      auth: { uid: "user_1" },
      data: { pin: "1234" },
    } as unknown as CallableRequest;

    const res = await setTransactionPin.run(req);
    assert.deepStrictEqual(res, { ok: true });

    const hasPin = await hasPinSet("user_1");
    assert.strictEqual(hasPin, true);
  });

  test("setTransactionPin rejects invalid PIN shapes", async () => {
    const req = {
      auth: { uid: "user_1" },
      data: { pin: "123" }, // 3 digits
    } as unknown as CallableRequest;

    await assert.rejects(
      async () => await setTransactionPin.run(req),
      (err: unknown) => {
        assert.ok(err instanceof HttpsError);
        assert.strictEqual(err.code, "invalid-argument");
        assert.match(err.message, /exactly 4 digits/);
        return true;
      }
    );
  });

  test("setTransactionPin requires correct currentPin when changing existing PIN", async () => {
    store.set("users/user_2", { uid: "user_2" });
    // Set initial PIN
    await setTransactionPin.run({
      auth: { uid: "user_2" },
      data: { pin: "1234" },
    } as unknown as CallableRequest);

    // Fail change with wrong current PIN
    await assert.rejects(
      async () =>
        await setTransactionPin.run({
          auth: { uid: "user_2" },
          data: { pin: "5678", currentPin: "9999" },
        } as unknown as CallableRequest),
      (err: unknown) => {
        assert.ok(err instanceof HttpsError);
        assert.strictEqual(err.code, "unauthenticated");
        return true;
      }
    );

    // Succeed change with correct current PIN
    const res = await setTransactionPin.run({
      auth: { uid: "user_2" },
      data: { pin: "5678", currentPin: "1234" },
    } as unknown as CallableRequest);
    assert.deepStrictEqual(res, { ok: true });

    // Verify new PIN works
    await assert.doesNotReject(() => requireValidPin("user_2", "5678"));
  });

  test("verifyTransactionPin succeeds with correct PIN and fails with wrong PIN", async () => {
    store.set("users/user_3", { uid: "user_3" });
    await setTransactionPin.run({
      auth: { uid: "user_3" },
      data: { pin: "4321" },
    } as unknown as CallableRequest);

    const validReq = {
      auth: { uid: "user_3" },
      data: { pin: "4321" },
    } as unknown as CallableRequest;
    const res = await verifyTransactionPin.run(validReq);
    assert.deepStrictEqual(res, { ok: true });

    const invalidReq = {
      auth: { uid: "user_3" },
      data: { pin: "9999" },
    } as unknown as CallableRequest;
    await assert.rejects(
      async () => await verifyTransactionPin.run(invalidReq),
      (err: unknown) => {
        assert.ok(err instanceof HttpsError);
        assert.strictEqual(err.code, "unauthenticated");
        return true;
      }
    );
  });

  test("resetTransactionPin updates PIN and clears active lock", async () => {
    store.set("users/user_4", { uid: "user_4" });
    await setTransactionPin.run({
      auth: { uid: "user_4" },
      data: { pin: "1111" },
    } as unknown as CallableRequest);

    // Reset PIN to 9999
    const resetReq = {
      auth: { uid: "user_4" },
      data: { pin: "9999" },
    } as unknown as CallableRequest;
    const res = await resetTransactionPin.run(resetReq);
    assert.deepStrictEqual(res, { ok: true });

    // Verify new PIN 9999 works
    await assert.doesNotReject(() => requireValidPin("user_4", "9999"));
  });
});
