import assert from "node:assert";
import { test, describe, beforeEach, afterEach } from "node:test";
import * as admin from "firebase-admin";
import { checkProxyRateLimit } from "../googleMaps";

describe("Security Fixes: Rate Limiting & Bank Code Validation", () => {
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
          };
        },
      }),
      runTransaction: async (updateFunction: (tx: any) => Promise<any>) => {
        const tx = {
          get: async (ref: any) => ref.get(),
          set: async (ref: any, data: any, opts?: any) => ref.set(data, opts),
          update: async (ref: any, data: any) => ref.set(data, { merge: true }),
        };
        return await updateFunction(tx);
      },
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
  });

  afterEach(() => {
    if (originalDescriptor) {
      Object.defineProperty(admin, "firestore", originalDescriptor);
    }
  });
  describe("Google Maps Proxy Rate Limiting", () => {
    test("allows up to 60 requests per minute and throttles subsequent requests", async () => {
      const testUid = `rate_limit_test_user_${Date.now()}`;
      
      // First 60 requests should succeed
      for (let i = 0; i < 60; i++) {
        await assert.doesNotReject(() => checkProxyRateLimit(testUid));
      }

      // 61st request should be throttled
      await assert.rejects(
        async () => await checkProxyRateLimit(testUid),
        (err: any) => {
          return err.code === "resource-exhausted" || err.message?.includes("Too many location searches");
        }
      );
    });
  });

  describe("Bank Code Regex Validation (Fintech & Digital Banks)", () => {
    const bankCodeRegex = /^[a-zA-Z0-9]{3,6}$/;

    test("accepts traditional 3-digit bank codes", () => {
      assert.strictEqual(bankCodeRegex.test("058"), true); // GTBank
      assert.strictEqual(bankCodeRegex.test("044"), true); // Access Bank
      assert.strictEqual(bankCodeRegex.test("011"), true); // First Bank
      assert.strictEqual(bankCodeRegex.test("214"), true); // FCMB
    });

    test("accepts 5 and 6 digit fintech / MFB bank codes", () => {
      assert.strictEqual(bankCodeRegex.test("50515"), true);  // Moniepoint
      assert.strictEqual(bankCodeRegex.test("50211"), true);  // Kuda Bank
      assert.strictEqual(bankCodeRegex.test("999991"), true); // PalmPay
      assert.strictEqual(bankCodeRegex.test("999992"), true); // OPay
      assert.strictEqual(bankCodeRegex.test("090110"), true); // VFD MFB
    });

    test("rejects invalid bank codes", () => {
      assert.strictEqual(bankCodeRegex.test(""), false);
      assert.strictEqual(bankCodeRegex.test("1"), false);
      assert.strictEqual(bankCodeRegex.test("12"), false);
      assert.strictEqual(bankCodeRegex.test("1234567"), false); // too long (>6)
      assert.strictEqual(bankCodeRegex.test("058-A"), false); // special character
      assert.strictEqual(bankCodeRegex.test("05 8"), false);  // whitespace
    });
  });
});
