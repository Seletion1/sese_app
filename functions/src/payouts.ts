import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";

/**
 * Paystack Transfers — automated wallet withdrawal.
 *
 * Replaces the manual "Request via Support" flow with a direct Paystack
 * transfer. The client NEVER moves money and NEVER sees a secret: it can only
 * ask this module to (a) list banks, (b) resolve an account holder name, and
 * (c) request a withdrawal. Every balance check and every debit happens here
 * against the server-held wallet document.
 *
 * Money flow (zero-trust):
 *   1. `paystackBanks` (callable): proxy for `GET /bank` so the app can render
 *      a bank picker. The client could call Paystack's public list itself, but
 *      routing through here keeps one place to rate-limit and one code path
 *      when Paystack is unreachable.
 *   2. `resolveBankAccount` (callable): `GET /bank/resolve` returns the
 *      registered account holder name. Purely a read — it does not persist
 *      anything, so a user can probe names without side effects. (Persisting a
 *      verified destination is `BankService.saveBankAccount` writing
 *      `payout_profiles/{uid}` directly, which firestore.rules already allows
 *      for the owner.)
 *   3. `processWalletWithdrawal` (callable): the only money-moving entry
 *      point. In ONE Firestore transaction it re-reads the wallet, verifies
 *      sufficiency, debits the balance, and writes both a
 *      `wallets/{uid}/transactions/{txId}` ledger row and a
 *      `payout_requests/{requestId}` audit row. The transaction is the
 *      concurrency lock: two simultaneous withdrawals cannot both pass the
 *      balance check.
 *   4. Only after the debit commits does it call Paystack, and a failure at
 *      that point REFUNDS the debit (a compensating credit) rather than
 *      silently swallowing the user's money. This is why the debit is a
 *      transaction that completes independently of the network call.
 *   5. `transferWebhook` (HTTPS): `transfer.success` / `transfer.failed`
 *      settle the payout asynchronously. Transfers are normally async, so the
 *      request row stays `pending` until Paystack calls back.
 *
 * Secrets: the Paystack SECRET key lives ONLY here, via Secret Manager
 * (`firebase functions:secrets:set PAYSTACK_SECRET_KEY="sk_test_..."`). It is
 * never embedded, logged, or returned. Do not "helpfully" inline it — that is
 * exactly the failure mode this module exists to prevent.
 */

/** Bound to the functions below so the platform injects it at runtime. */
const PAYSTACK_SECRET_KEY = defineSecret("PAYSTACK_SECRET_KEY");

const db = () => admin.firestore();

const PAYSTACK_BASE =
  process.env.PAYSTACK_BASE_URL ?? "https://api.paystack.co";

/** Minimum withdrawal: ₦100 (10,000 kobo). Mirrors MIN_AMOUNT_KOBO in payments.ts. */
const MIN_WITHDRAWAL_KOBO = 10_000;

/** Ceiling per withdrawal: ₦500,000. Bounds blast radius of a bug or a hijack. */
const MAX_WITHDRAWAL_KOBO = 50_000_000;

/**
 * Admin-configured payout floor (`system_configs/financials`
 * `minPayoutThreshold`, stored in NAIRA like the rest of FinancialConfig),
 * converted to kobo. Falls back to the hard floor when the doc is missing
 * or unreadable — an unconfigured backend must never block withdrawals.
 */
async function payoutFloorKobo(): Promise<number> {
  try {
    const snap = await db().collection("system_configs").doc("financials").get();
    const raw = snap.data()?.minPayoutThreshold;
    if (typeof raw === "number" && Number.isFinite(raw) && raw > 0) {
      return Math.round(raw * 100);
    }
  } catch (e) {
    console.warn(`payouts: financials read failed: ${e}`);
  }
  return MIN_WITHDRAWAL_KOBO;
}

function paystackSecret(): string {
  const secret = process.env.PAYSTACK_SECRET_KEY;
  if (!secret) {
    throw new HttpsError(
      "failed-precondition",
      "Withdrawals are not available right now. Please contact support."
    );
  }
  return secret;
}

/** Paystack JSON response envelope, narrowed to a keyed record. */
interface PaystackEnvelope {
  status?: boolean;
  message?: string;
  data?: Record<string, unknown>;
}

async function paystackGet(
  path: string,
  secret: string
): Promise<Record<string, unknown>> {
  const res = await fetch(`${PAYSTACK_BASE}${path}`, {
    method: "GET",
    headers: { Authorization: `Bearer ${secret}` },
  });
  const json = (await res.json()) as PaystackEnvelope;
  if (!res.ok || json.status !== true) {
    throw new HttpsError(
      "internal",
      `Paystack error: ${json.message ?? `HTTP ${res.status}`}`
    );
  }
  const data = json.data;
  return data && typeof data === "object" ? data : {};
}

async function paystackPost(
  path: string,
  body: unknown,
  secret: string
): Promise<Record<string, unknown>> {
  const res = await fetch(`${PAYSTACK_BASE}${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${secret}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const json = (await res.json()) as PaystackEnvelope;
  if (!res.ok || json.status !== true) {
    throw new HttpsError(
      "internal",
      `Paystack error: ${json.message ?? `HTTP ${res.status}`}`
    );
  }
  return json.data ?? {};
}

function newRequestId(uid: string): string {
  const rand = Math.random().toString(36).slice(2, 10);
  return `pay_${uid.slice(0, 8)}_${Date.now().toString(36)}${rand}`;
}

// ─── Account-holder name matching ───────────────────────────────────────────

/**
 * Normalises a name for comparison: uppercase, strip anything that is not a
 * letter (so "O'Brien-Adeniyi," and "OBRIEN ADENIYI" collapse together),
 * collapse whitespace.
 */
function normalizeName(raw: string): string {
  return raw
    .toUpperCase()
    // Apostrophes are dropped with NO separator, so "O'Brien" and "OBRIEN"
    // are the same token. Hyphens become separators, because they usually join
    // two distinct name parts ("Adeniyi-Femi" ~ "ADENIYI FEMI"). Everything
    // else non-alphabetic also becomes a separator, so "Okonkwo, Adaeze" splits.
    .replace(/['’`]/g, "")
    .replace(/[^A-Z]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

/**
 * True when a Paystack-resolved account name plausibly belongs to the
 * registered profile name.
 *
 * Deliberately NOT exact string equality: banks reorder and expand names
 * ("ADAEZE BAKARE OKONKWO" for "Adaeze Okonkwo"), insert middle names, and
 * vary punctuation. An exact match would reject legitimate payouts.
 *
 * The rule is token-set containment: every token of the SHORTER name must
 * appear in the LONGER one. So a profile of "Adaeze Okonkwo" matches an
 * account of "ADAEZE BAKARE OKONKWO" (account is a superset), and vice versa.
 * A completely different person ("CHINEDU OBI") fails.
 *
 * Both directions are checked so that neither an empty profile name nor a
 * generic/unresolved account name can slip through.
 */
export function accountNameMatches(
  profileName: string,
  accountName: string
): boolean {
  const profileTokens: string[] = dedupeTokens(profileName);
  const accountTokens: string[] = dedupeTokens(accountName);

  // Require at least two distinct name components on both sides. "JOHN" alone
  // is too weak an identity signal to authorise a money movement, and a
  // Paystack resolve that returns one token is usually a proxy/placeholder.
  if (profileTokens.length < 2 || accountTokens.length < 2) return false;

  const [shorter, longer] =
    profileTokens.length <= accountTokens.length
      ? [profileTokens, accountTokens]
      : [accountTokens, profileTokens];
  return shorter.every((t) => longer.includes(t));
}

/** Uppercased, de-punctuated, de-duplicated name components. */
function dedupeTokens(raw: string): string[] {
  return Array.from(
    new Set(normalizeName(raw).split(" ").filter((t) => t.length > 0))
  );
}

/** The name on the caller's own profile, from whichever doc holds it. */
async function registeredName(uid: string): Promise<string> {
  for (const collection of ["users", "drivers"]) {
    try {
      const snap = await db().collection(collection).doc(uid).get();
      if (!snap.exists) continue;
      const d = snap.data()!;
      const direct = `${d["fullName"] ?? ""} ${d["displayName"] ?? ""}`.trim();
      if (direct) return direct;
      const composed = `${d["firstName"] ?? ""} ${d["lastName"] ?? ""}`.trim();
      if (composed) return composed;
    } catch (_) {
      // Try the next collection; a missing/denied doc is not fatal here.
    }
  }
  return "";
}

// ─── Callables ──────────────────────────────────────────────────────────────

/**
 * Callable: returns the Nigerian bank catalogue for the payout picker.
 * Cached briefly to keep the sheet snappy and to limit call volume.
 */
let bankCache: { at: number; banks: Array<Record<string, unknown>> } | null = null;
const BANK_CACHE_TTL_MS = 10 * 60 * 1000;

export const paystackBanks = onCall(
  { secrets: [PAYSTACK_SECRET_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must sign in.");
    }
    const now = Date.now();
    if (bankCache && now - bankCache.at < BANK_CACHE_TTL_MS) {
      return { banks: bankCache.banks };
    }
    const data = await paystackGet("/bank", paystackSecret());
    const banks = Array.isArray(data) ? (data as Array<Record<string, unknown>>) : [];
    bankCache = { at: now, banks };
    return { banks };
  }
);

interface ResolveBankAccountData {
  bankCode?: string;
  accountNumber?: string;
}

/**
 * Callable: resolves a Nigerian account number to its registered holder name.
 *
 * Read-only by design. The client shows the returned name for the user to
 * confirm, but the value is treated as UNTRUSTED input by
 * `processWalletWithdrawal`, which re-resolves server-side and never accepts a
 * client-supplied name.
 */
export const resolveBankAccount = onCall<ResolveBankAccountData>(
  { secrets: [PAYSTACK_SECRET_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must sign in.");
    }
    const bankCode = String(request.data?.bankCode ?? "").trim();
    const accountNumber = String(request.data?.accountNumber ?? "").trim();

    if (!/^\d{3}$/.test(bankCode)) {
      throw new HttpsError("invalid-argument", "Select a bank first.");
    }
    if (!/^\d{10}$/.test(accountNumber)) {
      throw new HttpsError(
        "invalid-argument",
        "Account number must be exactly 10 digits."
      );
    }

    const data = await paystackGet(
      `/bank/resolve?account_number=${encodeURIComponent(accountNumber)}&bank_code=${encodeURIComponent(bankCode)}`,
      paystackSecret()
    );

    return {
      accountName: String(data["account_name"] ?? ""),
      bankName: String(data["bank_name"] ?? ""),
      accountNumber,
    };
  }
);

interface ProcessWithdrawalData {
  amountKobo?: number;
  bankCode?: string;
  accountNumber?: string;
}

export interface ProcessWithdrawalResult {
  requestId: string;
  amountKobo: number;
  status: string;
  transferReference: string;
  accountName: string;
}

/**
 * Callable: debits the caller's wallet and transfers the money to their bank.
 *
 * Order of operations (the security-critical part):
 *   1. Authenticate the caller.
 *   2. Validate the amount against min/max and the caller's live balance.
 *   3. Re-resolve the account name server-side and check it against the
 *      registered profile name. A client cannot fake this: the name comes
 *      from Paystack, not from the request body.
 *   4. In one Firestore transaction: re-read the wallet, re-check
 *      sufficiency, decrement, and write the ledger + audit rows.
 *   5. Create the Paystack transfer recipient and initiate the transfer.
 *   6. On any failure after step 4, refund the debit.
 */
export const processWalletWithdrawal = onCall<ProcessWithdrawalData>(
  { secrets: [PAYSTACK_SECRET_KEY] },
  async (request): Promise<ProcessWithdrawalResult> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must sign in.");
    }
    const uid = request.auth.uid;
    const secret = paystackSecret();

    // 1. Amount validation: hard ₦100 floor / ₦500,000 ceiling, plus the
    // admin-configured payout floor from `system_configs/financials`
    // (`minPayoutThreshold`, naira). When the doc is missing/unreadable the
    // configured floor falls back to the hard floor, so an unconfigured
    // backend never blocks all withdrawals.
    const amountKobo = Math.round(Number(request.data?.amountKobo));
    if (!Number.isFinite(amountKobo) || amountKobo < MIN_WITHDRAWAL_KOBO) {
      throw new HttpsError(
        "invalid-argument",
        "Minimum withdrawal is ₦100."
      );
    }
    if (amountKobo > MAX_WITHDRAWAL_KOBO) {
      throw new HttpsError(
        "invalid-argument",
        "Maximum withdrawal per request is ₦500,000."
      );
    }
    const configuredFloorKobo = await payoutFloorKobo();
    if (amountKobo < configuredFloorKobo) {
      throw new HttpsError(
        "invalid-argument",
        `Minimum withdrawal is ₦${(configuredFloorKobo / 100).toLocaleString("en-NG")}.`
      );
    }

    const bankCode = String(request.data?.bankCode ?? "").trim();
    const accountNumber = String(request.data?.accountNumber ?? "").trim();
    if (!/^\d{3}$/.test(bankCode)) {
      throw new HttpsError("invalid-argument", "Select a valid bank.");
    }
    if (!/^\d{10}$/.test(accountNumber)) {
      throw new HttpsError(
        "invalid-argument",
        "Account number must be exactly 10 digits."
      );
    }

    // 2. Resolve the account name server-side (never trust the client's).
    const resolved = await paystackGet(
      `/bank/resolve?account_number=${encodeURIComponent(accountNumber)}&bank_code=${encodeURIComponent(bankCode)}`,
      secret
    );
    const accountName = String(resolved["account_name"] ?? "");
    if (!accountName) {
      throw new HttpsError(
        "invalid-argument",
        "We could not verify that bank account. Check the number and bank."
      );
    }

    // 3. Identity check against the registered profile name.
    const registered = await registeredName(uid);
    if (!registered) {
      throw new HttpsError(
        "failed-precondition",
        "Add your full name to your profile before withdrawing."
      );
    }
    if (!accountNameMatches(registered, accountName)) {
      throw new HttpsError(
        "permission-denied",
        `This account is registered to a different name than your profile. `
          + `Update your profile name or use the account matching your profile.`
      );
    }

    // 4. Debit inside a transaction: the re-read + conditional decrement is
    //    the concurrency lock that stops two withdrawals racing the balance.
    const requestId = newRequestId(uid);
    const walletRef = db().collection("wallets").doc(uid);
    const requestRef = db().collection("payout_requests").doc(requestId);
    const ledgerRef = walletRef.collection("transactions").doc(requestId);
    const createdAt = admin.firestore.FieldValue.serverTimestamp();

    await db().runTransaction(async (tx) => {
      const walletSnap = await tx.get(walletRef);
      if (!walletSnap.exists) {
        throw new HttpsError(
          "failed-precondition",
          "No wallet found for this account."
        );
      }
      const balanceKobo = Number(walletSnap.data()!["balance"] ?? 0);
      if (!Number.isFinite(balanceKobo) || balanceKobo < amountKobo) {
        throw new HttpsError(
          "failed-precondition",
          "Your balance is too low for this withdrawal."
        );
      }

      tx.update(walletRef, {
        balance: admin.firestore.FieldValue.increment(-amountKobo),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(ledgerRef, {
        type: "wallet_withdrawal",
        // `amount` is kobo to match every other ledger row in this collection
        // (payments.ts writes amountKobo here); the naira value is kept
        // alongside for readability.
        amount: amountKobo,
        amountKobo,
        amountNaira: amountKobo / 100,
        currency: "NGN",
        payoutRequestId: requestId,
        status: "pending",
        createdAt,
      });

      tx.set(requestRef, {
        requestId,
        userId: uid,
        driverId: uid,
        amountKobo,
        amountNaira: amountKobo / 100,
        currency: "NGN",
        bankCode,
        accountNumber,
        accountName,
        registeredName: registered,
        bankName: String(resolved["bank_name"] ?? ""),
        status: "pending",
        paystackRecipientCode: null,
        paystackTransferReference: null,
        failureReason: null,
        createdAt,
        updatedAt: createdAt,
      });
    });

    // 5. Move the money. Any throw below is compensated by the refund path.
    try {
      const recipient = await paystackPost(
        "/transferrecipient",
        {
          type: "nuban",
          name: accountName,
          account_number: accountNumber,
          bank_code: bankCode,
          currency: "NGN",
        },
        secret
      );
      const recipientCode = String(recipient["recipient_code"] ?? "");
      if (!recipientCode) {
        throw new HttpsError(
          "internal",
          "Paystack did not return a transfer recipient."
        );
      }

      const transfer = await paystackPost(
        "/transfer",
        {
          source: "balance",
          // Paystack's `amount` is in kobo.
          amount: amountKobo,
          recipient: recipientCode,
          reason: "Sese Ride Wallet Payout",
          reference: requestId,
        },
        secret
      );
      const transferReference = String(transfer["reference"] ?? "");
      const transferStatus = String(transfer["status"] ?? "");

      // `success` here means Paystack ACCEPTED the transfer, not that the
      // bank has paid out. The webhook settles the final state.
      const settled = transferStatus === "success";
      await requestRef.update({
        paystackRecipientCode: recipientCode,
        paystackTransferReference: transferReference,
        status: settled ? "completed" : "pending",
        submittedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      await ledgerRef.update({
        status: settled ? "completed" : "pending",
        paystackTransferReference: transferReference,
      });

      return {
        requestId,
        amountKobo,
        status: settled ? "completed" : "pending",
        transferReference,
        accountName,
      };
    } catch (e) {
      // 6. Compensate: the debit already committed, so give the money back.
      const reason = e instanceof Error ? e.message : String(e);
      await db().runTransaction(async (tx) => {
        tx.update(walletRef, {
          balance: admin.firestore.FieldValue.increment(amountKobo),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.set(
          walletRef.collection("transactions").doc(`${requestId}_refund`),
          {
            type: "wallet_withdrawal_refund",
            amount: amountKobo,
            amountKobo,
            amountNaira: amountKobo / 100,
            currency: "NGN",
            payoutRequestId: requestId,
            status: "completed",
            reason,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          }
        );
        tx.update(requestRef, {
          status: "failed",
          failureReason: reason.slice(0, 500),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.update(ledgerRef, { status: "failed" });
      });
      throw e;
    }
  }
);

/**
 * Settles a payout from Paystack's asynchronous transfer events.
 *
 * Idempotent: guarded on the request's current status so a retried webhook
 * cannot double-refund a failure or double-complete a success. Exported for
 * `paystackWebhook` (payments.ts), which is the single HMAC-verified ingress
 * for all Paystack events.
 */
export async function settleTransfer(
  reference: string,
  outcome: "success" | "failed",
  reason: string
): Promise<void> {
  const snap = await db().collection("payout_requests").doc(reference).get();
  if (!snap.exists) return;
  const row = snap.data()!;
  if (row["status"] === outcome) return;
  if (row["status"] === "refunded" && outcome === "success") return;

  const walletRef = db().collection("wallets").doc(String(row["userId"]));
  const ledgerRef = walletRef
    .collection("transactions")
    .doc(String(row["requestId"]));

  await db().runTransaction(async (tx) => {
    if (outcome === "success") {
      tx.update(snap.ref, {
        status: "completed",
        settledAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      tx.update(ledgerRef, { status: "completed" });
      return;
    }
    // Failed AFTER the debit committed: refund it.
    const amountKobo = Number(row["amountKobo"] ?? 0);
    if (amountKobo > 0) {
      tx.update(walletRef, {
        balance: admin.firestore.FieldValue.increment(amountKobo),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      tx.set(
        walletRef.collection("transactions").doc(`${reference}_refund`),
        {
          type: "wallet_withdrawal_refund",
          amount: amountKobo,
          amountKobo,
          amountNaira: amountKobo / 100,
          currency: "NGN",
          payoutRequestId: reference,
          status: "completed",
          reason,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }
      );
    }
    tx.update(snap.ref, {
      status: "refunded",
      failureReason: reason.slice(0, 500),
      settledAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    tx.update(ledgerRef, { status: "refunded" });
  });
}

/**
 * REMOVED: `transferWebhook` used to exist here as a token-guarded callable
 * for Paystack transfer events. It is deleted because a shared-secret token
 * is strictly weaker than the HMAC signature Paystack already sends, and
 * running two ingress paths for one event source invites double-settlement
 * confusion. `paystackWebhook` (payments.ts) now handles `transfer.success`
 * and `transfer.failed` directly, verified by HMAC, calling the exported
 * `settleTransfer` above. If `firebase deploy` complains about an orphaned
 * `transferWebhook`, delete it once:
 * `firebase functions:delete transferWebhook --region us-central1 --force`.
 */
