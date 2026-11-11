import assert from "node:assert";
import { test, describe, beforeEach, afterEach } from "node:test";
import { CallableRequest, HttpsError } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import { getAgoraToken, recordCallDuration } from "../callTokens";

describe("callTokens — Agora Token Generation, Isolation & Automatic Failover", () => {
  let store: Map<string, Record<string, unknown>> = new Map();
  const originalDescriptor = Object.getOwnPropertyDescriptor(admin, "firestore");

  beforeEach(() => {
    store = new Map();
    process.env.DISABLE_APP_CHECK = "true";

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
          };
        },
      }),
      runTransaction: async (cb: (tx: unknown) => Promise<unknown>) => {
        const mockTx = {
          get: async (ref: { docPath?: string }) => {
            const path = ref.docPath;
            const data = path ? store.get(path) : undefined;
            return {
              exists: data !== undefined,
              data: () => data,
            };
          },
          set: (ref: { docPath?: string }, val: Record<string, unknown>, opts?: { merge?: boolean }) => {
            const path = ref.docPath;
            if (path) {
              const existing = store.get(path) || {};
              store.set(path, opts?.merge ? { ...existing, ...val } : { ...val });
            }
          },
        };
        return cb(mockTx);
      },
    });

    Object.defineProperty(admin, "firestore", {
      value: Object.assign(mockDb, {
        FieldValue: {
          serverTimestamp: () => new Date(),
        },
      }),
      configurable: true,
      writable: true,
    });
  });

  afterEach(() => {
    delete process.env.DISABLE_APP_CHECK;
    if (originalDescriptor) {
      Object.defineProperty(admin, "firestore", originalDescriptor);
    }
  });

  function makeReq(uid: string | null, data: Record<string, unknown> = {}): CallableRequest {
    return {
      auth: uid ? { uid, token: { uid } } : undefined,
      data,
      rawRequest: {} as any,
    } as unknown as CallableRequest;
  }

  test("rejects unauthenticated caller", async () => {
    await assert.rejects(
      async () => {
        await getAgoraToken.run(makeReq(null, { channelName: "channel_1" }));
      },
      (err: any) => err instanceof HttpsError && err.code === "unauthenticated"
    );
  });

  test("returns failover signal when Agora credentials unconfigured in auto mode", async () => {
    // system_settings/calling has auto mode, system_config/call_secrets is empty
    store.set("system_settings/calling", { routingMode: "smartFallback" });

    const result = (await getAgoraToken.run(makeReq("user_101", { channelName: "trip_call_101" }))) as any;
    assert.strictEqual(result.failover, true);
    assert.strictEqual(result.provider, "webrtc");
    assert.ok(result.reason.includes("credentials are not fully configured"));
  });

  test("throws failed-precondition when credentials missing in forceAgora mode", async () => {
    store.set("system_settings/calling", { routingMode: "thirdPartyOnly" });

    await assert.rejects(
      async () => {
        await getAgoraToken.run(makeReq("user_101", { channelName: "trip_call_101" }));
      },
      (err: any) => err instanceof HttpsError && err.code === "failed-precondition"
    );
  });

  test("generates valid Agora RTC token when credentials exist", async () => {
    store.set("system_settings/calling", {
      agoraAppId: "cd70ed7adfca42f7bcadc14259a939c4",
      routingMode: "smartFallback",
    });
    store.set("system_config/call_secrets", {
      agoraPrimaryCertificate: "5e0b3b9e939f4338be3e531e0933831f",
    });

    const result = (await getAgoraToken.run(makeReq("user_101", { channelName: "trip_call_101" }))) as any;
    assert.strictEqual(result.failover, false);
    assert.strictEqual(result.provider, "agora");
    assert.strictEqual(result.appId, "cd70ed7adfca42f7bcadc14259a939c4");
    assert.strictEqual(result.channelName, "trip_call_101");
    assert.strictEqual(result.userId, "user_101");
    assert.ok(typeof result.token === "string" && result.token.length > 20);
    assert.ok(result.expiresAt > Math.floor(Date.now() / 1000));
  });

  test("automatically triggers failover to WebRTC when monthly minute threshold reached", async () => {
    store.set("system_settings/calling", {
      agoraAppId: "cd70ed7adfca42f7bcadc14259a939c4",
      routingMode: "smartFallback",
      agoraAutoFailoverThresholdMinutes: 9900,
      agoraMonthlyFreeMinutesCap: 10000,
    });
    store.set("system_config/call_secrets", {
      agoraPrimaryCertificate: "5e0b3b9e939f4338be3e531e0933831f",
    });

    const now = new Date();
    const monthKey = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, "0")}`;

    // Seed usage at 9950 minutes (above 9900 threshold)
    store.set("system_config/call_usage", {
      lastMonthKey: monthKey,
      agoraMinutesThisMonth: 9950,
      totalMinutesThisMonth: 9950,
    });

    const result = (await getAgoraToken.run(makeReq("user_101", { channelName: "trip_call_101" }))) as any;
    assert.strictEqual(result.failover, true);
    assert.strictEqual(result.provider, "webrtc");
    assert.ok(result.reason.includes("free monthly limit reached"));
  });

  test("recordCallDuration increments call usage minutes atomically", async () => {
    const result = (await recordCallDuration.run(
      makeReq("user_101", {
        durationSeconds: 125, // 3 minutes rounded up
        provider: "agora",
        callId: "call_999",
      })
    )) as any;

    assert.strictEqual(result.ok, true);
    assert.strictEqual(result.durationMinutes, 3);
  });
});
