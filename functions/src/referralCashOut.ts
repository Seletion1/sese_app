import * as admin from "firebase-admin";
import { HttpsError } from "firebase-functions/v2/https";
import { guardedOnCall } from "./accountGuard";

const db = () => admin.firestore();

export interface ReferralCashOutRequestData {
  amountNaira: number;
  bankCode?: string;
  bankName: string;
  accountNumber: string;
  accountName: string;
  idempotencyKey?: string;
}

/**
 * Server-authoritative, zero-client-trust referral Sese Credits Cash Out.
 *
 * Enforces:
 * - Authenticated session (`request.auth.uid`).
 * - Server-side validation of minimum thresholds (`₦1,000.00`), account inputs.
 * - Single atomic Firestore transaction re-reading server-side available balance.
 * - Idempotency lock preventing duplicate payouts or race conditions.
 * - Atomic balance deduction and transaction ledger entry (`type: 'referral_cashout'`).
 */
export const requestReferralCashOut = guardedOnCall<ReferralCashOutRequestData>(
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required to request a cash-out.");
    }
    const uid = request.auth.uid;

    const { amountNaira, bankCode, bankName, accountNumber, accountName, idempotencyKey } =
      request.data ?? {};

    if (typeof amountNaira !== "number" || !Number.isFinite(amountNaira) || amountNaira < 1000) {
      throw new HttpsError(
        "invalid-argument",
        "Minimum referral cash-out amount is ₦1,000.00."
      );
    }

    const sanitizedBankCode = String(bankCode ?? "").trim();
    const sanitizedBankName = String(bankName ?? "").trim();
    const sanitizedAccountNumber = String(accountNumber ?? "").trim().replace(/\D/g, "");
    const sanitizedAccountName = String(accountName ?? "").trim();

    if (!sanitizedBankName || !sanitizedAccountNumber || sanitizedAccountNumber.length < 10 || !sanitizedAccountName) {
      throw new HttpsError(
        "invalid-argument",
        "Valid bank name, 10-digit account number, and account name are required."
      );
    }

    const rawKey = String(idempotencyKey ?? "").trim() || `${uid}_${Date.now()}`;
    const payoutId = `payout_${rawKey.replace(/[^a-zA-Z0-9_-]/g, "")}`;

    const walletRef = db().collection("wallets").doc(uid);
    const payoutRef = db().collection("payout_requests").doc(payoutId);
    const txRef = walletRef.collection("transactions").doc(payoutId);
    const auditRef = db().collection("financial_audit_logs").doc(`${payoutId}_cashout`);

    const amountKobo = Math.round(amountNaira * 100);

    return await db().runTransaction(async (tx) => {
      // 1. ALL READS FIRST
      const [walletSnap, payoutSnap] = await Promise.all([
        tx.get(walletRef),
        tx.get(payoutRef),
      ]);

      if (payoutSnap.exists) {
        const existingData = payoutSnap.data()!;
        return {
          success: true,
          payoutId,
          amountNaira: existingData["amountNaira"] ?? amountNaira,
          status: existingData["status"] ?? "pending",
          message: "Cash-out request already submitted.",
        };
      }

      const walletData = walletSnap.exists ? (walletSnap.data() as Record<string, unknown>) : {};
      const currentSeseCredits = Number(
        walletData["seseCredits"] ??
          walletData["mainWalletBalance"] ??
          (Number(walletData["balance"] ?? 0) / 100)
      );

      if (amountNaira > currentSeseCredits) {
        throw new HttpsError(
          "failed-precondition",
          `INSUFFICIENT_FUNDS: Your available referral Sese Credits balance is ₦${currentSeseCredits.toFixed(
            2
          )}, which is less than the requested ₦${amountNaira.toFixed(2)}.`
        );
      }

      // 2. ATOMIC WRITES
      tx.set(
        walletRef,
        {
          seseCredits: admin.firestore.FieldValue.increment(-amountNaira),
          mainWalletBalance: admin.firestore.FieldValue.increment(-amountNaira),
          balance: admin.firestore.FieldValue.increment(-amountKobo),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      tx.set(payoutRef, {
        payoutId,
        uid,
        amountNaira,
        amountKobo,
        bankCode: sanitizedBankCode,
        bankName: sanitizedBankName,
        accountNumber: sanitizedAccountNumber,
        accountName: sanitizedAccountName,
        status: "pending",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(txRef, {
        type: "referral_cashout",
        amountNaira: -amountNaira,
        amountKobo: -amountKobo,
        amount: -amountKobo,
        status: "pending",
        currency: "NGN",
        payoutId,
        note: `Referral cash out to ${sanitizedBankName} (${sanitizedAccountNumber})`,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(auditRef, {
        type: "referral_cashout",
        accountId: uid,
        amountNaira: -amountNaira,
        amountKobo: -amountKobo,
        currency: "NGN",
        status: "pending",
        timestamp: Date.now(),
        stage: "request",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return {
        success: true,
        payoutId,
        amountNaira,
        remainingSeseCredits: currentSeseCredits - amountNaira,
        status: "pending",
        message: "Referral cash-out request submitted successfully.",
      };
    });
  }
);
