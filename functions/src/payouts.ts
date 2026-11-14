import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { requireValidPin } from "./transactionPin";
import { enforceAppCheck, requireAccountActive } from "./accountGuard";
import { assertHubStaffOrAdmin } from "./verification";

const db = () => admin.firestore();

const PAYSTACK_BASE =
  process.env.PAYSTACK_BASE_URL ?? "https://api.paystack.co";

/** Flat ad-hoc instant withdrawal fee: ₦100 (10,000 kobo). */
export const INSTANT_WITHDRAWAL_FEE_KOBO = 10_000;

/** Restricted set of 11 approved financial institutions. */
export const APPROVED_BANK_CODES = new Set([
  "044",   // Access Bank
  "011",   // First Bank of Nigeria
  "058",   // Guaranty Trust Bank (GTB)
  "50211", // Kuda Bank
  "50515", // Moniepoint MFB
  "999992",// OPay
  "999991",// PalmPay
  "221",   // Stanbic IBTC Bank
  "033",   // United Bank for Africa (UBA)
  "035",   // Wema Bank
  "057",   // Zenith Bank
]);

async function paystackSecret(): Promise<string> {
  const secret =
    process.env.PAYSTACK_API_KEY ?? process.env.PAYSTACK_SECRET_KEY;
  if (secret && secret.trim()) {
    return secret.trim();
  }

  try {
    const secDoc = await db().collection("system_config").doc("paystack_secrets").get();
    if (secDoc.exists && secDoc.data()?.secretKey) {
      return String(secDoc.data()!.secretKey).trim();
    }
  } catch (_) {}

  throw new HttpsError(
    "failed-precondition",
    "Withdrawals are not available right now. Please contact support."
  );
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

function normalizeName(raw: string): string {
  return raw
    .toUpperCase()
    .replace(/['’`]/g, "")
    .replace(/[^A-Z]+/g, " ")
    .trim()
    .replace(/\s+/g, " ");
}

export function accountNameMatches(
  profileName: string,
  accountName: string
): boolean {
  const profileTokens: string[] = dedupeTokens(profileName);
  const accountTokens: string[] = dedupeTokens(accountName);

  if (profileTokens.length < 2 || accountTokens.length < 2) return false;

  const [shorter, longer] =
    profileTokens.length <= accountTokens.length
      ? [profileTokens, accountTokens]
      : [accountTokens, profileTokens];
  return shorter.every((t) => longer.includes(t));
}

function dedupeTokens(raw: string): string[] {
  return Array.from(
    new Set(normalizeName(raw).split(" ").filter((t) => t.length > 0))
  );
}

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
      // Ignore
    }
  }
  return "";
}

// ─── Callables ──────────────────────────────────────────────────────────────

let bankCache: { at: number; banks: Array<Record<string, unknown>> } | null = null;
const BANK_CACHE_TTL_MS = 10 * 60 * 1000;

export const paystackBanks = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in.");
  }
  const now = Date.now();
  if (bankCache && now - bankCache.at < BANK_CACHE_TTL_MS) {
    return { banks: bankCache.banks };
  }
  const secret = await paystackSecret();
  const data = await paystackGet("/bank", secret);
  const rawBanks = Array.isArray(data) ? (data as Array<Record<string, unknown>>) : [];
  // Restrict returned banks strictly to approved 11 banks
  const banks = rawBanks.filter((b) => APPROVED_BANK_CODES.has(String(b["code"] ?? "")));
  bankCache = { at: now, banks };
  return { banks };
});

interface ResolveBankAccountData {
  bankCode?: string;
  accountNumber?: string;
}

export interface ResolveBankAccountResult {
  account_name: string;
  accountName: string;
  bankName: string;
  accountNumber: string;
}

export const verifyBankAccount = onCall<ResolveBankAccountData>(
  async (request): Promise<ResolveBankAccountResult> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must sign in.");
    }
    const bankCode = String(request.data?.bankCode ?? "").trim();
    const accountNumber = String(request.data?.accountNumber ?? "").trim();

    if (!APPROVED_BANK_CODES.has(bankCode)) {
      throw new HttpsError("invalid-argument", "Select an approved bank.");
    }
    if (!/^\d{10}$/.test(accountNumber)) {
      throw new HttpsError(
        "invalid-argument",
        "Account number must be exactly 10 digits."
      );
    }

    const secret = await paystackSecret();
    const data = await paystackGet(
      `/bank/resolve?account_number=${encodeURIComponent(accountNumber)}&bank_code=${encodeURIComponent(bankCode)}`,
      secret
    );

    const accountName = String(data["account_name"] ?? "");
    const bankName = String(data["bank_name"] ?? "");

    return {
      account_name: accountName,
      accountName,
      bankName,
      accountNumber,
    };
  }
);

export const resolveBankAccount = verifyBankAccount;

interface ProcessWithdrawalData {
  amountKobo?: number;
  amount?: number;
  bankCode?: string;
  accountNumber?: string;
  accountName?: string;
  transactionPin?: string;
}

export interface ProcessWithdrawalResult {
  requestId: string;
  amountKobo: number;
  feeKobo: number;
  netAmountKobo: number;
  status: string;
  transferReference: string;
  accountName: string;
}

/**
 * Callable: Instant Ad-Hoc Self-Service Withdrawal
 * Automatically deducts flat ₦100 fee (10,000 kobo).
 */
export const processWalletWithdrawal = onCall<ProcessWithdrawalData>(
  async (request): Promise<ProcessWithdrawalResult> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must sign in.");
    }
    const uid = request.auth.uid;

    enforceAppCheck(request);
    await requireAccountActive(uid, "customer");
    const secret = await paystackSecret();

    await requireValidPin(uid, request.data?.transactionPin);

    const rawKobo = request.data?.amountKobo !== undefined
      ? Number(request.data.amountKobo)
      : request.data?.amount !== undefined
        ? Number(request.data.amount) * 100
        : NaN;
    const requestedAmountKobo = Math.round(rawKobo);

    const feeKobo = INSTANT_WITHDRAWAL_FEE_KOBO; // ₦100 flat fee
    if (!Number.isFinite(requestedAmountKobo) || requestedAmountKobo <= feeKobo) {
      throw new HttpsError(
        "invalid-argument",
        "Withdrawal amount must be greater than the ₦100 withdrawal fee."
      );
    }

    const netAmountKobo = requestedAmountKobo - feeKobo;

    // Daily Limit Cap (₦20,000)
    let maxDailyWithdrawal = 20000;
    try {
      const finDoc = await db().collection("system_configs").doc("financials").get();
      if (finDoc.exists) {
        const finData = finDoc.data() ?? {};
        if (typeof finData["maxDailyWithdrawal"] === "number") {
          maxDailyWithdrawal = finData["maxDailyWithdrawal"];
        }
      }
    } catch (e) {
      console.warn(`[processWalletWithdrawal] financials config read fallback: ${e}`);
    }

    const maxDailyKobo = Math.round(maxDailyWithdrawal * 100);
    if (requestedAmountKobo > maxDailyKobo) {
      throw new HttpsError(
        "invalid-argument",
        `Max withdrawal ₦${maxDailyWithdrawal.toLocaleString("en-NG")}`
      );
    }

    try {
      const oneDayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000);
      const recentPayoutsSnap = await db()
        .collection("payout_requests")
        .where("userId", "==", uid)
        .where("createdAt", ">=", oneDayAgo)
        .get();

      let dailyTotalKobo = 0;
      for (const pDoc of recentPayoutsSnap.docs) {
        const pData = pDoc.data();
        if (pData["status"] !== "failed" && pData["status"] !== "refunded") {
          dailyTotalKobo += Number(pData["requestedAmountKobo"] ?? pData["amountKobo"] ?? 0);
        }
      }

      if (dailyTotalKobo + requestedAmountKobo > maxDailyKobo) {
        throw new HttpsError(
          "failed-precondition",
          "Daily limit reached"
        );
      }
    } catch (e) {
      if (e instanceof HttpsError) throw e;
      console.warn(`[processWalletWithdrawal] daily withdrawal sum warning: ${e}`);
    }

    const bankCode = String(request.data?.bankCode ?? "").trim();
    const accountNumber = String(request.data?.accountNumber ?? "").trim();
    if (!APPROVED_BANK_CODES.has(bankCode)) {
      throw new HttpsError("invalid-argument", "Select an approved bank.");
    }
    if (!/^\d{10}$/.test(accountNumber)) {
      throw new HttpsError(
        "invalid-argument",
        "10-digit account required"
      );
    }

    const resolved = await paystackGet(
      `/bank/resolve?account_number=${encodeURIComponent(accountNumber)}&bank_code=${encodeURIComponent(bankCode)}`,
      secret
    );
    const accountName = String(resolved["account_name"] ?? "");
    if (!accountName) {
      throw new HttpsError(
        "invalid-argument",
        "Account not found"
      );
    }

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
        `Name mismatch: account must match ${registered}`
      );
    }

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
      if (!Number.isFinite(balanceKobo) || balanceKobo < requestedAmountKobo) {
        throw new HttpsError(
          "failed-precondition",
          "Insufficient balance"
        );
      }

      tx.update(walletRef, {
        balance: admin.firestore.FieldValue.increment(-requestedAmountKobo),
        mainWalletBalance: admin.firestore.FieldValue.increment(-requestedAmountKobo / 100),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(ledgerRef, {
        type: "wallet_withdrawal",
        role: "driver",
        amount: requestedAmountKobo,
        requestedAmountKobo,
        feeKobo,
        netAmountKobo,
        amountKobo: requestedAmountKobo,
        amountNaira: requestedAmountKobo / 100,
        currency: "NGN",
        payoutRequestId: requestId,
        status: "pending",
        createdAt,
      });

      tx.set(requestRef, {
        requestId,
        userId: uid,
        driverId: uid,
        payoutType: "instant_adhoc",
        requestedAmountKobo,
        feeKobo,
        netAmountKobo,
        amountKobo: netAmountKobo,
        amountNaira: netAmountKobo / 100,
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
          amount: netAmountKobo, // Transfer net amount after ₦100 fee
          recipient: recipientCode,
          reason: "Sese Ride Wallet Payout",
          reference: requestId,
        },
        secret
      );
      const transferReference = String(transfer["reference"] ?? "");
      const transferStatus = String(transfer["status"] ?? "");

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
        amountKobo: requestedAmountKobo,
        feeKobo,
        netAmountKobo,
        status: settled ? "completed" : "pending",
        transferReference,
        accountName,
      };
    } catch (e) {
      const reason = e instanceof Error ? e.message : String(e);
      const isNetworkTimeout =
        reason.toLowerCase().includes("timeout") ||
        reason.includes("ETIMEDOUT") ||
        reason.includes("ECONNRESET") ||
        reason.includes("504") ||
        reason.includes("ENOTFOUND");

      if (isNetworkTimeout) {
        console.warn(`[payouts] Network timeout for requestId ${requestId}. Holding debit for reconciliation.`);
        await requestRef.update({
          status: "pending_verification",
          failureReason: `Network timeout connecting to Paystack: ${reason.slice(0, 400)}`,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        await db().collection("failed_payouts_dlq").doc(requestId).set({
          requestId,
          userId: uid,
          amountKobo: requestedAmountKobo,
          reason,
          status: "NEEDS_RECONCILIATION",
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        throw new HttpsError(
          "unavailable",
          "Transfer request timed out with our payment provider. Your balance is safely held while we verify delivery status."
        );
      }

      await db().runTransaction(async (tx) => {
        tx.update(walletRef, {
          balance: admin.firestore.FieldValue.increment(requestedAmountKobo),
          mainWalletBalance: admin.firestore.FieldValue.increment(requestedAmountKobo / 100),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.set(
          walletRef.collection("transactions").doc(`${requestId}_refund`),
          {
            type: "wallet_withdrawal_refund",
            amount: requestedAmountKobo,
            amountKobo: requestedAmountKobo,
            amountNaira: requestedAmountKobo / 100,
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

interface ApproveWeeklyPayoutData {
  userId?: string;
}

/**
 * Callable: Hub Admin Weekly Fee-Free Payout Approval
 * Debits full remaining user balance and transfers 100% full amount to bank (0 fee).
 */
export const approveWeeklyPayout = onCall<ApproveWeeklyPayoutData>(
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must sign in.");
    }
    const token = (request.auth.token ?? {}) as Record<string, unknown>;
    const callerEmail = String(request.auth.token?.email ?? "").trim();
    await assertHubStaffOrAdmin(request.auth.uid, callerEmail, token);

    const targetUid = String(request.data?.userId ?? "").trim();
    if (!targetUid) {
      throw new HttpsError("invalid-argument", "Target userId is required.");
    }

    const secret = await paystackSecret();

    // 1. Resolve user payout bank profile
    const profileSnap = await db().collection("payout_profiles").doc(targetUid).get();
    if (!profileSnap.exists) {
      throw new HttpsError("failed-precondition", "User has not configured bank details.");
    }
    const profile = profileSnap.data()!;
    const bankCode = String(profile["bankCode"] ?? "").trim();
    const accountNumber = String(profile["accountNumber"] ?? "").trim();
    const accountName = String(profile["accountName"] ?? "").trim();
    const bankName = String(profile["bankName"] ?? "").trim();

    if (!APPROVED_BANK_CODES.has(bankCode)) {
      throw new HttpsError("invalid-argument", "User bank is not in approved list.");
    }
    if (!/^\d{10}$/.test(accountNumber) || !accountName) {
      throw new HttpsError("invalid-argument", "Invalid or unverified bank account details.");
    }

    // 2. Resolve wallet balance
    const walletRef = db().collection("wallets").doc(targetUid);
    const walletSnap = await walletRef.get();
    if (!walletSnap.exists) {
      throw new HttpsError("failed-precondition", "No wallet found for this account.");
    }
    const balanceKobo = Number(walletSnap.data()!["balance"] ?? 0);
    if (!Number.isFinite(balanceKobo) || balanceKobo <= 0) {
      throw new HttpsError("failed-precondition", "Wallet balance must be greater than 0.");
    }

    const requestId = newRequestId(targetUid);
    const requestRef = db().collection("payout_requests").doc(requestId);
    const ledgerRef = walletRef.collection("transactions").doc(requestId);
    const createdAt = admin.firestore.FieldValue.serverTimestamp();

    const adminUid = request.auth.uid;
    const feeKobo = 0;
    const netAmountKobo = balanceKobo;

    await db().runTransaction(async (tx) => {
      const freshWallet = await tx.get(walletRef);
      const walletData = freshWallet.data() || {};
      const freshBal = Number(walletData["balance"] ?? 0);
      if (!Number.isFinite(freshBal) || freshBal < balanceKobo) {
        throw new HttpsError("failed-precondition", "Wallet balance changed during processing.");
      }

      tx.update(walletRef, {
        balance: admin.firestore.FieldValue.increment(-balanceKobo),
        mainWalletBalance: admin.firestore.FieldValue.increment(-balanceKobo / 100),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(ledgerRef, {
        type: "weekly_payout",
        role: "driver",
        amount: balanceKobo,
        amountKobo: balanceKobo,
        amountNaira: balanceKobo / 100,
        feeKobo,
        currency: "NGN",
        payoutRequestId: requestId,
        status: "pending",
        createdAt,
      });

      tx.set(requestRef, {
        requestId,
        userId: targetUid,
        driverId: targetUid,
        payoutType: "weekly_payout",
        requestedAmountKobo: balanceKobo,
        feeKobo,
        netAmountKobo,
        amountKobo: balanceKobo,
        amountNaira: balanceKobo / 100,
        currency: "NGN",
        bankCode,
        accountNumber,
        accountName,
        bankName,
        status: "pending",
        approvedByAdmin: adminUid,
        paystackRecipientCode: null,
        paystackTransferReference: null,
        failureReason: null,
        createdAt,
        updatedAt: createdAt,
      });
    });

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
        throw new HttpsError("internal", "Paystack returned no recipient code.");
      }

      const transfer = await paystackPost(
        "/transfer",
        {
          source: "balance",
          amount: netAmountKobo,
          recipient: recipientCode,
          reason: "Sese Weekly Payout",
          reference: requestId,
        },
        secret
      );
      const transferReference = String(transfer["reference"] ?? "");
      const transferStatus = String(transfer["status"] ?? "");
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
        amountKobo: balanceKobo,
        status: settled ? "completed" : "pending",
        transferReference,
        accountName,
      };
    } catch (e) {
      const reason = e instanceof Error ? e.message : String(e);
      await db().runTransaction(async (tx) => {
        tx.update(walletRef, {
          balance: admin.firestore.FieldValue.increment(balanceKobo),
          mainWalletBalance: admin.firestore.FieldValue.increment(balanceKobo / 100),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.set(walletRef.collection("transactions").doc(`${requestId}_refund`), {
          type: "weekly_payout_refund",
          amount: balanceKobo,
          amountKobo: balanceKobo,
          amountNaira: balanceKobo / 100,
          currency: "NGN",
          payoutRequestId: requestId,
          status: "completed",
          reason,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
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
 * Callable: Bulk Weekly Payout Approval for all eligible users in queue.
 */
export const approveAllWeeklyPayouts = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in.");
  }
  const token = (request.auth.token ?? {}) as Record<string, unknown>;
  const callerEmail = String(request.auth.token?.email ?? "").trim();
  await assertHubStaffOrAdmin(request.auth.uid, callerEmail, token);

  // Fetch financial config for minPayoutThreshold
  let minPayoutThreshold = 20000;
  try {
    const finDoc = await db().collection("system_configs").doc("financials").get();
    const finData = finDoc.data() || {};
    if (finDoc.exists && typeof finData["minPayoutThreshold"] === "number") {
      minPayoutThreshold = finData["minPayoutThreshold"];
    }
  } catch (_) {}

  const minKobo = Math.round(minPayoutThreshold * 100);

  // Query eligible wallets
  const walletsSnap = await db()
    .collection("wallets")
    .where("balance", ">=", minKobo)
    .get();

  const results: Array<{ userId: string; success: boolean; error?: string }> = [];

  for (const wDoc of walletsSnap.docs) {
    const targetUid = wDoc.id;
    try {
      const profileSnap = await db().collection("payout_profiles").doc(targetUid).get();
      if (!profileSnap.exists) {
        results.push({ userId: targetUid, success: false, error: "No bank details" });
        continue;
      }
      const profile = profileSnap.data()!;
      const bankCode = String(profile["bankCode"] ?? "").trim();
      if (!APPROVED_BANK_CODES.has(bankCode)) {
        results.push({ userId: targetUid, success: false, error: "Bank not approved" });
        continue;
      }

      // Invoke approveWeeklyPayout logic internally
      const secret = await paystackSecret();
      const balanceKobo = Number(wDoc.data()["balance"] ?? 0);
      const accountNumber = String(profile["accountNumber"] ?? "").trim();
      const accountName = String(profile["accountName"] ?? "").trim();
      const bankName = String(profile["bankName"] ?? "").trim();

      const requestId = newRequestId(targetUid);
      const requestRef = db().collection("payout_requests").doc(requestId);
      const walletRef = db().collection("wallets").doc(targetUid);
      const ledgerRef = walletRef.collection("transactions").doc(requestId);
      const createdAt = admin.firestore.FieldValue.serverTimestamp();

      const adminUid = request.auth.uid;
      await db().runTransaction(async (tx) => {
        tx.update(walletRef, {
          balance: admin.firestore.FieldValue.increment(-balanceKobo),
          mainWalletBalance: admin.firestore.FieldValue.increment(-balanceKobo / 100),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.set(ledgerRef, {
          type: "weekly_payout",
          amount: balanceKobo,
          amountKobo: balanceKobo,
          amountNaira: balanceKobo / 100,
          feeKobo: 0,
          currency: "NGN",
          payoutRequestId: requestId,
          status: "pending",
          createdAt,
        });
        tx.set(requestRef, {
          requestId,
          userId: targetUid,
          driverId: targetUid,
          payoutType: "weekly_payout",
          requestedAmountKobo: balanceKobo,
          feeKobo: 0,
          netAmountKobo: balanceKobo,
          amountKobo: balanceKobo,
          amountNaira: balanceKobo / 100,
          currency: "NGN",
          bankCode,
          accountNumber,
          accountName,
          bankName,
          status: "pending",
          approvedByAdmin: adminUid,
          paystackRecipientCode: null,
          paystackTransferReference: null,
          failureReason: null,
          createdAt,
          updatedAt: createdAt,
        });
      });

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
      const transfer = await paystackPost(
        "/transfer",
        {
          source: "balance",
          amount: balanceKobo,
          recipient: recipientCode,
          reason: "Sese Weekly Payout Batch",
          reference: requestId,
        },
        secret
      );
      const transferReference = String(transfer["reference"] ?? "");
      const settled = String(transfer["status"] ?? "") === "success";

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

      results.push({ userId: targetUid, success: true });
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      results.push({ userId: targetUid, success: false, error: errMsg });
    }
  }

  return { processed: results.length, details: results };
});

export async function settleTransfer(
  reference: string,
  outcome: "success" | "failed",
  reason: string
): Promise<void> {
  const payoutRef = db().collection("payout_requests").doc(reference);
  const payoutLedgerRef = db().collection("wallet_ledger").doc(`payout_${reference}_${outcome}`);

  await db().runTransaction(async (tx) => {
    const ledgerSnap = await tx.get(payoutLedgerRef);
    if (ledgerSnap.exists) {
      console.log(`[payouts] Duplicate webhook processing blocked for payout ledger: payout_${reference}_${outcome}`);
      return;
    }

    const snap = await tx.get(payoutRef);
    if (!snap.exists) return;
    const row = snap.data()!;
    const currentStatus = String(row["status"] ?? "");

    if (currentStatus === outcome || currentStatus === "completed") return;
    if (currentStatus === "refunded" && outcome === "success") {
      console.error(`[payouts] CRITICAL: Payout ${reference} succeeded on Paystack but had already been marked refunded!`);
      const alertRef = db().collection("failed_payouts_dlq").doc(`${reference}_double_payout_alert`);
      tx.set(alertRef, {
        type: "DOUBLE_PAYOUT_DETECTED",
        severity: "CRITICAL",
        reference,
        userId: row["userId"],
        amountKobo: row["amountKobo"],
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return;
    }

    const userId = String(row["userId"] ?? "");
    const requestId = String(row["requestId"] ?? "");
    const walletRef = db().collection("wallets").doc(userId);
    const ledgerRef = walletRef.collection("transactions").doc(requestId);

    await tx.get(walletRef);

    if (outcome === "success") {
      tx.update(payoutRef, {
        status: "completed",
        settledAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      tx.update(ledgerRef, { status: "completed" });
      tx.set(payoutLedgerRef, {
        status: "completed",
        reference,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
      });
      return;
    }

    // Failed AFTER the debit committed: refund it.
    const amountKobo = Number(row["requestedAmountKobo"] ?? row["amountKobo"] ?? 0);
    if (amountKobo > 0) {
      tx.update(walletRef, {
        balance: admin.firestore.FieldValue.increment(amountKobo),
        mainWalletBalance: admin.firestore.FieldValue.increment(amountKobo / 100),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      tx.set(
        walletRef.collection("transactions").doc(`${reference}_refund`),
        {
          type: "wallet_withdrawal_refund",
          role: "driver",
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
    tx.update(payoutRef, {
      status: "refunded",
      failureReason: reason.slice(0, 500),
      settledAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    tx.update(ledgerRef, { status: "refunded" });
    tx.set(payoutLedgerRef, {
      status: "refunded",
      reference,
      reason: reason.slice(0, 500),
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
}
