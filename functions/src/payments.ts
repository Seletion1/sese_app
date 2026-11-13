import * as admin from "firebase-admin";
import { createHmac, timingSafeEqual } from "node:crypto";
import { onCall, HttpsError, onRequest } from "firebase-functions/v2/https";

import { settleTransfer } from "./payouts";
import { requireValidPin } from "./transactionPin";
import { enforceAppCheck, requireAccountActive } from "./accountGuard";

/**
 * Paystack Collections (inline card, bank transfer, USSD, mobile money).
 *
 * Money flow (zero-trust — the client NEVER touches amounts):
 *   1. `initializePayment` (callable): validates the caller + amount, mints a
 *      `payment_intents/{reference}` doc (PENDING), and initializes the
 *      transaction with Paystack. Returns the hosted `authorizationUrl` the
 *      app opens for the user to pay.
 *   2. User pays on Paystack's hosted checkout (test mode accepts test cards).
 *   3. `verifyPayment` (callable): verifies the reference server-side with
 *      Paystack, checks the amount/currency match the intent, then credits
 *      `wallets/{uid}` EXACTLY ONCE (idempotent) and writes the wallet
 *      transaction record.
 *   4. `paystackWebhook` (HTTPS): same settlement driven by Paystack's
 *      `charge.success` event (signature-verified). Either path settles;
 *      the second one no-ops via the idempotency guard.
 *
 * Secrets: the Paystack SECRET key lives ONLY here, read from
 * `process.env.PAYSTACK_API_KEY` (plain `.env` var, git-ignored) with a
 * fallback to `process.env.PAYSTACK_SECRET_KEY` (stale Secret Manager
 * binding from the defineSecret era — see payouts.ts).
 * The public key (`pk_test_...`) is safe to embed in the client.
 */

const db = () => admin.firestore();

const PAYSTACK_BASE =
  process.env.PAYSTACK_BASE_URL ?? "https://api.paystack.co";

/** Floor/ceiling per payment in kobo (₦100 – ₦500,000). */
const MIN_AMOUNT_KOBO = 10_000;
const MAX_AMOUNT_KOBO = 50_000_000;

type PaymentPurpose = "wallet_topup" | "trip_payment";

async function paystackSecret(): Promise<string> {
  const envSecret =
    process.env.PAYSTACK_API_KEY ?? process.env.PAYSTACK_SECRET_KEY;
  if (envSecret && envSecret.trim()) {
    return envSecret.trim();
  }

  // Paystack secret key must NOT be read from client-accessible Firestore documents.
  // It is strictly populated via environment variables or Secret Manager.
  throw new HttpsError("failed-precondition", "PAYSTACK_NOT_CONFIGURED");
}

function newReference(uid: string): string {
  const rand = Math.random().toString(36).slice(2, 10);
  return `sese_${uid.slice(0, 8)}_${Date.now().toString(36)}${rand}`;
}

async function paystackPost(path: string, body: unknown, secret: string) {
  const res = await fetch(`${PAYSTACK_BASE}${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${secret}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const json = (await res.json()) as {
    status?: boolean;
    message?: string;
    data?: Record<string, unknown>;
  };
  if (!res.ok || json.status !== true) {
    throw new HttpsError(
      "internal",
      `Paystack error: ${json.message ?? `HTTP ${res.status}`}`
    );
  }
  return json.data ?? {};
}

async function paystackGet(path: string, secret: string) {
  const res = await fetch(`${PAYSTACK_BASE}${path}`, {
    method: "GET",
    headers: { Authorization: `Bearer ${secret}` },
  });
  const json = (await res.json()) as {
    status?: boolean;
    message?: string;
    data?: Record<string, unknown>;
  };
  if (!res.ok || json.status !== true) {
    throw new HttpsError(
      "internal",
      `Paystack error: ${json.message ?? `HTTP ${res.status}`}`
    );
  }
  return json.data ?? {};
}

interface InitializePaymentData {
  amountKobo?: number;
  purpose?: string;
  tripId?: string;
  email?: string;
  transactionPin?: string;
}

/**
 * Callable: starts a Paystack collection for the caller.
 * Returns `{ authorizationUrl, accessCode, reference }`.
 */
export const initializePayment = onCall<InitializePaymentData>(
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must sign in to pay.");
    }
    const uid = request.auth.uid;

    // ── Security gates (must run before any business logic) ───────────────
    // App Check: rejects calls from non-genuine app builds / scripts.
    enforceAppCheck(request);
    // Suspension gate: banned/suspended users cannot initiate payments even
    // when Firestore rules have not yet propagated to all SDK caches.
    await requireAccountActive(uid, "customer");

    // Transaction-PIN gate: verified server-side before initializing Paystack payment intent.
    await requireValidPin(uid, request.data?.transactionPin);

    const secret = await paystackSecret();

    const d = request.data ?? {};
    const amountKobo =
      typeof d.amountKobo === "number" ? Math.round(d.amountKobo) : NaN;
    if (!Number.isFinite(amountKobo) || amountKobo < MIN_AMOUNT_KOBO) {
      throw new HttpsError(
        "invalid-argument",
        "Min payment ₦100"
      );
    }
    if (amountKobo > MAX_AMOUNT_KOBO) {
      throw new HttpsError(
        "invalid-argument",
        "Max payment ₦500,000"
      );
    }

    const purpose: PaymentPurpose =
      d.purpose === "trip_payment" ? "trip_payment" : "wallet_topup";

    // ── Financial Rules & Business Limits Gate ─────────────────────────
    if (purpose === "wallet_topup") {
      let maxAccountBalance = 50000;
      let maxSingleTopUp = 20000;
      let dailyTopUpFrequency = 5;
      try {
        const finDoc = await db().collection("system_configs").doc("financials").get();
        if (finDoc.exists) {
          const finData = finDoc.data() ?? {};
          if (typeof finData["maxAccountBalance"] === "number") {
            maxAccountBalance = finData["maxAccountBalance"];
          }
          if (typeof finData["maxSingleTopUp"] === "number") {
            maxSingleTopUp = finData["maxSingleTopUp"];
          }
          if (typeof finData["dailyTopUpFrequency"] === "number") {
            dailyTopUpFrequency = finData["dailyTopUpFrequency"];
          }
        }
      } catch (e) {
        console.warn(`[initializePayment] financials config read fallback: ${e}`);
      }

      // 1. Max Single Top-Up
      const maxSingleKobo = Math.round(maxSingleTopUp * 100);
      if (amountKobo > maxSingleKobo) {
        throw new HttpsError(
          "invalid-argument",
          `Max top-up ₦${maxSingleTopUp.toLocaleString("en-NG")}`
        );
      }

      // 2. Max Account Balance Cap
      try {
        const walletDoc = await db().collection("wallets").doc(uid).get();
        if (walletDoc.exists) {
          const wData = walletDoc.data() ?? {};
          const currentBalKobo = typeof wData["mainWalletBalance"] === "number"
            ? Math.round(wData["mainWalletBalance"] * 100)
            : (typeof wData["balance"] === "number" ? Math.round(wData["balance"]) : 0);
          const maxBalanceKobo = Math.round(maxAccountBalance * 100);
          if (currentBalKobo + amountKobo > maxBalanceKobo) {
            throw new HttpsError(
              "failed-precondition",
              `Max balance ₦${maxAccountBalance.toLocaleString("en-NG")}`
            );
          }
        }
      } catch (e) {
        if (e instanceof HttpsError) throw e;
        console.warn(`[initializePayment] wallet balance check warning: ${e}`);
      }

      // 3. Daily Top-Up Frequency (Max times per 24 hours)
      try {
        const oneDayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000);
        const dailyTopUpsSnap = await db()
          .collection("payment_intents")
          .where("userId", "==", uid)
          .where("purpose", "==", "wallet_topup")
          .where("createdAt", ">=", oneDayAgo)
          .get();

        if (dailyTopUpsSnap.size >= dailyTopUpFrequency) {
          throw new HttpsError(
            "resource-exhausted",
            "Daily limit reached"
          );
        }
      } catch (e) {
        if (e instanceof HttpsError) throw e;
        console.warn(`[initializePayment] daily frequency check warning: ${e}`);
      }
    }
    const tripId = typeof d.tripId === "string" ? d.tripId.trim() : "";
    if (purpose === "trip_payment" && !tripId) {
      throw new HttpsError(
        "invalid-argument",
        "tripId is required for trip payments."
      );
    }

    const email =
      request.auth.token.email ??
      (typeof d.email === "string" ? d.email.trim() : "");
    if (!email || !email.includes("@")) {
      throw new HttpsError(
        "invalid-argument",
        "A valid email is required for the receipt."
      );
    }

    const reference = newReference(uid);
    const intentRef = db().collection("payment_intents").doc(reference);
    await intentRef.set({
      reference,
      userId: uid,
      email,
      amountKobo,
      currency: "NGN",
      purpose,
      tripId: tripId || null,
      status: "INITIALIZED",
      paystackAccessCode: null,
      paystackReference: null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    let accessCode = "";
    let authorizationUrl = "";
    try {
      const data = await paystackPost(
        "/transaction/initialize",
        {
          email,
          amount: amountKobo,
          currency: "NGN",
          reference,
          metadata: {
            userId: uid,
            amount: amountKobo,
            transactionType: "wallet_topup",
            purpose,
          },
        },
        secret
      );
      accessCode = String(data["access_code"] ?? "");
      authorizationUrl = String(data["authorization_url"] ?? "");
      if (!authorizationUrl) {
        throw new HttpsError("internal", "Paystack returned no checkout URL.");
      }
      await intentRef.update({
        status: "PENDING",
        paystackAccessCode: accessCode,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (e) {
      await intentRef.update({
        status: "FAILED",
        failureReason: e instanceof Error ? e.message : String(e),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      throw e;
    }

    return { authorizationUrl, accessCode, reference };
  }
);

/** Alias export for initializePayment */
export const initializePaystackTopUp = initializePayment;

/**
 * Settles a PENDING intent after a successful Paystack verification.
 * Idempotent: concurrent callers (verify callable + webhook) settle once —
 * the Firestore transaction bails when the intent is already SUCCEEDED.
 * Returns `{ settled: boolean, creditedKobo: number }`.
 */
async function settleIntent(
  reference: string,
  verifiedAmountKobo: number
): Promise<{ settled: boolean; creditedKobo: number }> {
  const intentRef = db().collection("payment_intents").doc(reference);
  const ledgerRef = db().collection("wallet_ledger").doc(reference);

  return db().runTransaction(async (tx) => {
    // ── Idempotency Check (wallet_ledger) ──────────────────────────────
    const ledgerSnap = await tx.get(ledgerRef);
    if (ledgerSnap.exists) {
      console.log(`[payments] Duplicate webhook / settlement processing blocked for ledger: ${reference}`);
      return { settled: false, creditedKobo: 0 };
    }

    const snap = await tx.get(intentRef);
    if (!snap.exists) {
      throw new HttpsError("not-found", "Payment reference not found.");
    }
    const intent = snap.data()!;
    if (intent["status"] === "SUCCEEDED") {
      return { settled: false, creditedKobo: 0 };
    }
    if (intent["status"] !== "PENDING" && intent["status"] !== "INITIALIZED") {
      throw new HttpsError(
        "failed-precondition",
        "This payment is no longer payable."
      );
    }

    const expected = Number(intent["amountKobo"] ?? 0);
    if (verifiedAmountKobo !== expected) {
      throw new HttpsError(
        "data-loss",
        "Paid amount does not match the payment request."
      );
    }

    const uid = String(intent["userId"] ?? "");
    if (!uid) {
      throw new HttpsError("data-loss", "Payment intent has no owner.");
    }

    const walletRef = db().collection("wallets").doc(uid);

    // ── Automatic split-debt recovery ──────────────────────────────────
    // Trusted split partners may settle into a negative balance (see
    // `settleSplitPayment`, tracked as `users/{uid}.splitStats.splitDebtKobo`).
    // The next self-funding repays it first: up to the outstanding debt is
    // diverted from this credit before it lands. Same-transaction reads, so
    // a racing spend cannot dodge the diversion.
    let creditKobo = verifiedAmountKobo;
    let recoveredKobo = 0;
    try {
      const userSnap = await tx.get(db().collection("users").doc(uid));
      const statsRaw = ((userSnap.data()?.splitStats ?? {}) as Record<string, unknown>);
      const debt = typeof statsRaw.splitDebtKobo === "number" && Number.isFinite(statsRaw.splitDebtKobo)
        ? Math.max(0, Math.floor(statsRaw.splitDebtKobo))
        : 0;
      if (debt > 0) {
        recoveredKobo = Math.min(debt, verifiedAmountKobo);
        creditKobo = verifiedAmountKobo - recoveredKobo;
        tx.set(
          db().collection("users").doc(uid),
          {
            splitStats: {
              splitDebtKobo: admin.firestore.FieldValue.increment(-recoveredKobo),
            },
          },
          { merge: true }
        );
      }
    } catch (e) {
      // Fail open toward the user: a stats-read failure must never block a
      // paid-for top-up. The debt simply waits for the next funding.
      console.warn(`verifyPayment: debt-recovery skipped for ${uid}: ${e}`);
      creditKobo = verifiedAmountKobo;
      recoveredKobo = 0;
    }

    tx.set(
      walletRef,
      {
        userId: uid,
        balance: admin.firestore.FieldValue.increment(creditKobo),
        mainWalletBalance: admin.firestore.FieldValue.increment(creditKobo / 100),
        currency: "NGN",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    const txRef = walletRef.collection("transactions").doc();
    tx.set(txRef, {
      type: intent["purpose"] === "trip_payment" ? "trip_payment" : "wallet_topup",
      amountKobo: verifiedAmountKobo,
      amount: verifiedAmountKobo / 100,
      status: "success",
      currency: "NGN",
      paymentReference: reference,
      tripId: intent["tripId"] ?? null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    if (recoveredKobo > 0) {
      tx.set(walletRef.collection("transactions").doc(), {
        type: "SPLIT_DEBT_RECOVERY",
        amountKobo: -recoveredKobo,
        amount: -recoveredKobo / 100,
        status: "success",
        currency: "NGN",
        note: `Recovered ₦${(recoveredKobo / 100).toLocaleString("en-NG")} of split debt from this top-up.`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    tx.update(intentRef, {
      status: "SUCCEEDED",
      settledAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    tx.set(ledgerRef, {
      status: "success",
      reference,
      userId: uid,
      amountKobo: verifiedAmountKobo,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { settled: true, creditedKobo: verifiedAmountKobo };
  });
}

interface VerifyPaymentData {
  reference?: string;
}

/**
 * Callable: verifies the caller's payment with Paystack and credits the
 * wallet on success. Safe to call repeatedly (second call reports
 * `{ settled: false }`).
 */
export const verifyPayment = onCall<VerifyPaymentData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in.");
  }
  // ── Security gates ────────────────────────────────────────────────────────
  enforceAppCheck(request);
  await requireAccountActive(request.auth.uid, "customer");
  const reference = String(request.data?.reference ?? "").trim();
  if (!reference) {
    throw new HttpsError("invalid-argument", "reference is required.");
  }

  const intentSnap = await db()
    .collection("payment_intents")
    .doc(reference)
    .get();
  if (!intentSnap.exists) {
    throw new HttpsError("not-found", "Payment reference not found.");
  }
  if (intentSnap.data()!["userId"] !== request.auth.uid) {
    throw new HttpsError("permission-denied", "Not your payment.");
  }

  const secret = await paystackSecret();
  const data = await paystackGet(
    `/transaction/verify/${encodeURIComponent(reference)}`,
    secret
  );

  if (data["status"] !== "success") {
    await intentSnap.ref.update({
      status: "FAILED",
      failureReason: `Paystack status: ${String(data["status"] ?? "unknown")}`,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    throw new HttpsError(
      "failed-precondition",
      "Payment was not successful. No money was taken from your wallet flow."
    );
  }
  if (String(data["currency"] ?? "NGN") !== "NGN") {
    throw new HttpsError("data-loss", "Unexpected payment currency.");
  }

  const paidKobo = Number(data["amount"] ?? 0);
  return settleIntent(reference, paidKobo);
});

/**
 * HTTPS webhook: `charge.success` settlement + `transfer.success` /
 * `transfer.failed` payout settlement, all driven by Paystack.
 * Verifies the `x-paystack-signature` HMAC before trusting the payload.
 * Configure the URL in the Paystack dashboard (Settings → Webhooks).
 *
 * Transfer events settle `payout_requests` rows written by
 * `processWalletWithdrawal`, via the shared idempotent `settleTransfer`.
 * This is the single HMAC-verified ingress for all Paystack events; the old
 * token-guarded `transferWebhook` callable is deleted.
 */
export const paystackWebhook = onRequest(async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).send("Method not allowed");
    return;
  }
  let secret = "";
  try {
    secret = await paystackSecret();
  } catch (e) {
    console.error("paystackWebhook secret error:", e);
    res.status(500).send("Payments not configured");
    return;
  }

  const signature = String(req.headers["x-paystack-signature"] ?? "");
  const rawBody: Buffer =
    (req as unknown as { rawBody?: Buffer }).rawBody ??
    Buffer.from(JSON.stringify(req.body ?? {}));
  const expected = createHmac("sha512", secret).update(rawBody).digest("hex");

  const sigBuf = Buffer.from(signature, "hex");
  const expBuf = Buffer.from(expected, "hex");
  if (
    !signature ||
    sigBuf.length === 0 ||
    sigBuf.length !== expBuf.length ||
    !timingSafeEqual(sigBuf, expBuf)
  ) {
    res.status(401).send("Invalid signature");
    return;
  }

  const event = (req.body ?? {}) as { event?: string; data?: Record<string, unknown> };
  try {
    if (event.event === "charge.success" && event.data) {
      const reference = String(event.data["reference"] ?? "");
      const amountKobo = Number(event.data["amount"] ?? 0);
      if (reference && amountKobo > 0) {
        await settleIntent(reference, amountKobo);
      }
    } else if (event.event === "transfer.success" && event.data) {
      // `reference` is the payout requestId we set on the transfer.
      const reference = String(event.data["reference"] ?? "");
      if (reference) {
        await settleTransfer(reference, "success", "");
      }
    } else if (event.event === "transfer.failed" && event.data) {
      const reference = String(event.data["reference"] ?? "");
      const reason = String(
        (event.data["gateway_response"] as string | undefined) ??
          (event.data["reason"] as string | undefined) ??
          "Transfer failed at the bank."
      );
      if (reference) {
        await settleTransfer(reference, "failed", reason);
      }
    }
    res.status(200).send("ok");
  } catch (e) {
    console.error(`paystackWebhook settlement failed: ${e}`);
    res.status(500).send("Internal settlement error");
  }
});

export interface CardChargeRequest {
  uid: string;
  tripId: string;
  amountNaira: number;
}

export interface CardChargeResponse {
  success: boolean;
  reference?: string;
  failureReason?: string;
}

/**
 * Triggers an automated Paystack charge using a stored reusable card authorization code.
 * Used when a trip with card payment method transitions to IN_PROGRESS.
 */
export async function chargePaystackCardAuthorization(
  req: CardChargeRequest
): Promise<CardChargeResponse> {
  const { uid, tripId, amountNaira } = req;
  if (!uid || amountNaira <= 0) {
    return { success: false, failureReason: "INVALID_CHARGE_PARAMETERS" };
  }

  try {
    const userSnap = await db().collection("users").doc(uid).get();
    const walletSnap = await db().collection("wallets").doc(uid).get();

    const uData = userSnap.exists ? userSnap.data()! : {};
    const wData = walletSnap.exists ? walletSnap.data()! : {};

    const authCode = String(
      uData["paystackAuthorizationCode"] ??
        wData["paystackAuthorizationCode"] ??
        uData["paystackAuthCode"] ??
        ""
    ).trim();
    const email = String(
      uData["email"] ?? uData["emailAddress"] ?? `${uid}@sese.app`
    ).trim();

    if (!authCode) {
      return { success: false, failureReason: "NO_STORED_CARD" };
    }

    const secret = await paystackSecret();
    const reference = newReference(uid);
    const amountKobo = Math.round(amountNaira * 100);

    const data = await paystackPost(
      "/transaction/charge_authorization",
      {
        authorization_code: authCode,
        email,
        amount: amountKobo,
        reference,
        currency: "NGN",
        metadata: { tripId, purpose: "automated_trip_card_charge" },
      },
      secret
    );

    const status = String(data["status"] ?? "");
    if (status === "success") {
      return { success: true, reference };
    }
    return {
      success: false,
      failureReason: String(data["gateway_response"] ?? "CARD_CHARGE_FAILED"),
    };
  } catch (e: any) {
    console.warn(`chargePaystackCardAuthorization error for trip ${tripId}: ${e}`);
    return {
      success: false,
      failureReason: e?.message ?? String(e),
    };
  }
}
