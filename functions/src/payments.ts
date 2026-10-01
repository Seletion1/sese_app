import * as admin from "firebase-admin";
import { createHmac } from "node:crypto";
import { onCall, HttpsError, onRequest } from "firebase-functions/v2/https";

import { settleTransfer } from "./payouts";

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
 * `process.env.PAYSTACK_SECRET_KEY`
 * (`firebase functions:secrets:set PAYSTACK_SECRET_KEY="sk_test_..."`).
 * The public key (`pk_test_...`) is safe to embed in the client.
 */

const db = () => admin.firestore();

const PAYSTACK_BASE =
  process.env.PAYSTACK_BASE_URL ?? "https://api.paystack.co";

/** Floor/ceiling per payment in kobo (₦100 – ₦500,000). */
const MIN_AMOUNT_KOBO = 10_000;
const MAX_AMOUNT_KOBO = 50_000_000;

type PaymentPurpose = "wallet_topup" | "trip_payment";

function paystackSecret(): string {
  const secret = process.env.PAYSTACK_SECRET_KEY;
  if (!secret) {
    throw new HttpsError(
      "failed-precondition",
      "Paystack is not configured yet. Ask support to enable payments."
    );
  }
  return secret;
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
    const secret = paystackSecret();

    const d = request.data ?? {};
    const amountKobo =
      typeof d.amountKobo === "number" ? Math.round(d.amountKobo) : NaN;
    if (!Number.isFinite(amountKobo) || amountKobo < MIN_AMOUNT_KOBO) {
      throw new HttpsError(
        "invalid-argument",
        "Minimum payment is ₦100. Enter a valid amount."
      );
    }
    if (amountKobo > MAX_AMOUNT_KOBO) {
      throw new HttpsError(
        "invalid-argument",
        "Maximum payment per transaction is ₦500,000."
      );
    }

    const purpose: PaymentPurpose =
      d.purpose === "trip_payment" ? "trip_payment" : "wallet_topup";
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
        { email, amount: amountKobo, currency: "NGN", reference },
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

  return db().runTransaction(async (tx) => {
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
    tx.set(
      walletRef,
      {
        userId: uid,
        balance: admin.firestore.FieldValue.increment(verifiedAmountKobo),
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
      currency: "NGN",
      paymentReference: reference,
      tripId: intent["tripId"] ?? null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    tx.update(intentRef, {
      status: "SUCCEEDED",
      settledAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
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

  const secret = paystackSecret();
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
  const secret = process.env.PAYSTACK_SECRET_KEY;
  if (!secret) {
    res.status(500).send("Payments not configured");
    return;
  }

  const signature = String(req.headers["x-paystack-signature"] ?? "");
  const rawBody: Buffer =
    (req as unknown as { rawBody?: Buffer }).rawBody ??
    Buffer.from(JSON.stringify(req.body ?? {}));
  const expected = createHmac("sha512", secret).update(rawBody).digest("hex");
  if (!signature || signature !== expected) {
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
    // Return 200 anyway for unknown references so Paystack stops retrying
    // poison events; real mismatches are already logged above.
    res.status(200).send("ok");
  }
});
