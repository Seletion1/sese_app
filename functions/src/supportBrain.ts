import * as admin from "firebase-admin";

/**
 * SeSe Support Brain — Deterministic & Real-Time Level-1 Support Engine.
 *
 * Implements persistent dialogue state awareness, dynamic intent classification,
 * policy kernel rules, dynamic backend tool execution (instant refunds, verification audit,
 * wallet history), and human escalation protocols.
 */

const db = () => admin.firestore();

// ---------------------------------------------------------------------------
// Product Facts & Policy Kernel
// Sourced strictly from backend configuration (pricing.ts, payouts.ts, payments.ts, driverStreak.ts).
// ---------------------------------------------------------------------------

/** Per-vehicle pricing rates. */
const PRICING: Record<string, { base: number; perKm: number; perMin: number }> = {
  bicycle: { base: 300, perKm: 80, perMin: 10 },
  motorcycle: { base: 400, perKm: 120, perMin: 15 },
  tricycle: { base: 450, perKm: 130, perMin: 18 },
  car: { base: 600, perKm: 180, perMin: 25 },
  van: { base: 1200, perKm: 300, perMin: 40 },
  truck: { base: 1500, perKm: 400, perMin: 50 },
};

/** Top-up bounds. Minimum top-up is strictly ₦1,300.00 (130,000 kobo). */
export const MIN_TOPUP_KOBO = 130_000; // ₦1,300.00
export const MAX_TOPUP_KOBO = 50_000_000; // ₦500,000.00

/** External bank payout threshold via weekly desk. Minimum ₦20,000.00 (2,000,000 kobo). */
export const MIN_WITHDRAWAL_KOBO = 2_000_000; // ₦20,000.00
export const MAX_WITHDRAWAL_KOBO = 50_000_000; // ₦500,000.00

/** Driver online minimum balance rule: Drivers can toggle ONLINE at any balance.
 * If mainWalletBalance < ₦1.00, a warning is shown and backend holds trip dispatches. */
export const MIN_WALLET_TO_ONLINE = 1.0; // ₦1.00

/** SeSe Coin Bonus thresholds. */
export const SE_SE_COIN_CONVERT_MIN = 5000.0; // ₦5,000.00
export const SE_SE_COIN_AUTO_SWEEP = 10000.0; // ₦10,000.00

/** Streak step-down ladder. */
const L1_RATES = [15, 12.5, 10, 7.5, 5, 2.5, 0];

function naira(kobo: number): string {
  return `₦${(kobo / 100).toLocaleString("en-NG", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
}

function nairaFloat(amount: number): string {
  return `₦${amount.toLocaleString("en-NG", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
}

// ---------------------------------------------------------------------------
// Intent Classification Types & Categories
// ---------------------------------------------------------------------------

export type IntentCategory =
  | "ride_delivery_ops"
  | "financials_wallet"
  | "account_verification"
  | "platform_policies";

export function classifyIntent(text: string): IntentCategory {
  const norm = normalize(text);
  if (
    has(
      norm,
      "trip",
      "ride",
      "deliver",
      "delivery",
      "driver",
      "cancel",
      "wait",
      "late",
      "lost",
      "item",
      "parcel",
      "pin",
      "code",
      "pickup",
      "dropoff"
    )
  ) {
    return "ride_delivery_ops";
  }
  if (
    has(
      norm,
      "top up",
      "topup",
      "wallet",
      "balance",
      "money",
      "coin",
      "sese coin",
      "convert",
      "payout",
      "withdraw",
      "referral",
      "commission",
      "refund",
      "charge"
    )
  ) {
    return "financials_wallet";
  }
  if (
    has(
      norm,
      "verify",
      "verification",
      "document",
      "nin",
      "license",
      "id",
      "selfie",
      "vehicle",
      "approval",
      "pending",
      "account",
      "bank"
    )
  ) {
    return "account_verification";
  }
  return "platform_policies";
}

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

export function normalize(text: string): string {
  return text
    .toLowerCase()
    .replace(/[’']/g, "")
    .replace(/[^a-z0-9₦\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function has(text: string, ...phrases: string[]): boolean {
  return phrases.some((p) => text.includes(normalize(p)));
}

// ---------------------------------------------------------------------------
// Result Type
// ---------------------------------------------------------------------------

export type BrainResult =
  | { kind: "reply"; reply: string; topic: string; intent: IntentCategory }
  | { kind: "escalate"; reason: string; intent?: IntentCategory };

// ---------------------------------------------------------------------------
// Safety & Escalation Checks
// ---------------------------------------------------------------------------

const SAFETY_PHRASES = [
  "accident", "crash", "crashed", "injur", "hospital", "ambulance", "police",
  "stolen", "theft", "stole", "robbery", "assault", "attack", "kidnap",
  "blood", "unconscious", "emergency", "danger", "threat", "crime",
  "harass", "unsafe", "scared",
];

export function isSafetyIssue(raw: string): boolean {
  return has(raw, ...SAFETY_PHRASES);
}

export const SAFETY_REPLY =
  "I'm very sorry this happened. Your safety comes first — if anyone is hurt " +
  "or you are in danger, please contact local emergency services now. " +
  "I am transferring your conversation and full details to a live SeSe Support Agent. An agent will join this chat shortly.";

export const HANDOVER_TEXT =
  "I am transferring your conversation and full details to a live SeSe Support Agent. An agent will join this chat shortly.";

const HUMAN_PHRASES = [
  "human", "agent", "real person", "customer service", "support agent",
  "speak to human", "speak to someone", "talk to human", "talk to someone",
  "representative", "manager", "escalate", "complaint", "supervisor", "customer care",
];

export function explicitlyWantsHuman(raw: string): boolean {
  return has(raw, ...HUMAN_PHRASES);
}

const HARD_ESCALATION_PHRASES = [
  "chargeback", "legal dispute", "fraudulent charge", "lawyer",
  "court", "police report", "stolen vehicle", "assault complaint",
];

export function needsHuman(raw: string): boolean {
  return has(raw, ...HARD_ESCALATION_PHRASES);
}

// ---------------------------------------------------------------------------
// 3. Dynamic Backend Tool Calling & Automated Resolutions
// ---------------------------------------------------------------------------

export interface HistoryTurn {
  senderType: string;
  text: string;
}

export interface BrainContext {
  userId: string;
  userRole: "driver" | "customer";
  history?: HistoryTurn[];
}

/**
 * Tool 1: check_trip_refund_status
 * Queries recent canceled trips for the user. If a fare was pre-deducted on a driver-initiated
 * cancellation (or eligible canceled trip), executes an atomic Firestore wallet credit refund.
 */
export async function checkTripRefundStatus(userId: string): Promise<string | null> {
  if (!userId) return null;
  try {
    const snap = await db()
      .collection("trips")
      .where("customerId", "==", userId)
      .where("status", "==", "canceled")
      .orderBy("updatedAt", "desc")
      .limit(5)
      .get();

    if (snap.empty) {
      return null;
    }

    for (const doc of snap.docs) {
      const data = doc.data();
      const canceledBy = String(data["canceledBy"] ?? "");
      const isAlreadyRefunded = data["refunded"] === true;
      const fareKobo = typeof data["fareKobo"] === "number" ? data["fareKobo"] : 0;
      const paymentMethod = String(data["paymentMethod"] ?? "wallet");

      if (isAlreadyRefunded) {
        return (
          `Your canceled trip (ID: ${doc.id.slice(0, 8)}) has already been fully refunded. ` +
          `The credit of ${naira(fareKobo > 0 ? fareKobo : (data["estimatedFareKobo"] ?? 0))} was returned to your wallet.`
        );
      }

      // If pre-deducted wallet fare on driver-initiated cancellation or unfulfilled dispatch:
      if (canceledBy === "driver" || paymentMethod === "wallet" || data["prePaid"] === true) {
        const refundKobo = fareKobo > 0 ? fareKobo : Math.round((data["estimatedFareKobo"] ?? 0) as number);
        if (refundKobo > 0) {
          // Execute atomic refund transaction
          await db().runTransaction(async (tx) => {
            const walletRef = db().collection("wallets").doc(userId);
            const wSnap = await tx.get(walletRef);
            const wData = wSnap.data() || {};
            const currentMain = typeof wData["mainWalletBalance"] === "number" ? wData["mainWalletBalance"] : 0.0;
            const currentLegacy = typeof wData["balance"] === "number" ? wData["balance"] : 0;

            const refundNaira = refundKobo / 100.0;
            tx.set(
              walletRef,
              {
                mainWalletBalance: currentMain + refundNaira,
                balance: currentLegacy + refundKobo,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              },
              { merge: true }
            );

            const txRef = walletRef.collection("transactions").doc();
            tx.set(txRef, {
              type: "trip_refund",
              amountKobo: refundKobo,
              amount: refundNaira,
              label: `Instant Refund for Canceled Trip #${doc.id.slice(0, 8)}`,
              tripId: doc.id,
              paymentReference: `REFUND-${doc.id.slice(0, 8)}`,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });

            tx.update(doc.ref, {
              refunded: true,
              refundedAt: admin.firestore.FieldValue.serverTimestamp(),
              refundTxId: txRef.id,
            });
          });

          return (
            `✅ Automated Refund Executed!\n\n` +
            `Your trip #${doc.id.slice(0, 8)} was canceled by the driver. We have processed an instant refund of ` +
            `${naira(refundKobo)} directly into your main wallet balance (` +
            `mainWalletBalance).\n\nYou will see this item in your Wallet transaction history.`
          );
        }
      }
    }
    return null;
  } catch (e) {
    console.warn(`checkTripRefundStatus failed for ${userId}: ${e}`);
    return null;
  }
}

/**
 * Tool 2: check_verification_status
 * Queries user/driver profile verification status, returning exact pending or missing documents.
 */
export async function checkVerificationStatus(userId: string): Promise<string | null> {
  if (!userId) return null;
  try {
    const userDoc = await db().collection("users").doc(userId).get();
    const userData = userDoc.data() ?? {};
    const driverDoc = await db().collection("drivers").doc(userId).get();
    const driverData = driverDoc.data() ?? {};

    const customerStatus = String(userData["customerVerificationStatus"] ?? "unverified");
    const isVerifiedCustomer = userData["isVerifiedCustomer"] === true;
    const profileStatus = String(driverData["profileStatus"] ?? driverData["verificationStatus"] ?? "none");
    const isProfileVerified = driverData["isProfileVerified"] === true;
    const isVehicleVerified = driverData["isVehicleVerified"] === true;

    const pendingDocs: string[] = [];
    const missingDocs: string[] = [];

    if (!userData["idNumber"] && !userData["nin"]) missingDocs.push("Government ID / NIN");
    if (!userData["idFrontUrl"]) missingDocs.push("ID Front Photo");
    if (!userData["idBackUrl"]) missingDocs.push("ID Back Photo");
    if (!userData["liveSelfieUrl"] && !userData["photoUrl"]) missingDocs.push("Live Selfie Capture");

    if (driverDoc.exists) {
      if (!driverData["vehicleInspectionUrl"]) missingDocs.push("Vehicle Inspection Certificate");
      if (!driverData["vehicleLicenceUrl"]) missingDocs.push("Vehicle Licence");
      if (!driverData["insuranceUrl"]) missingDocs.push("Proof of Insurance");
    }

    if (profileStatus === "pending" || profileStatus === "pending_verification") {
      pendingDocs.push("Driver Profile Audit");
    }
    if (driverData["isVehicleVerified"] === false && driverData["vehicleCount"] > 0) {
      pendingDocs.push("Vehicle Inspection & Approval");
    }

    let summary = `📋 Your Verification Status Overview:\n\n`;
    summary += `• Account Status: ${isVerifiedCustomer ? "Verified Customer ✅" : `Customer Verification: ${customerStatus}`}\n`;
    if (driverDoc.exists) {
      summary += `• Driver Profile: ${isProfileVerified ? "Approved ✅" : `Status: ${profileStatus}`}\n`;
      summary += `• Vehicle Status: ${isVehicleVerified ? "Approved ✅" : "Pending Inspection/Review"}\n`;
    }

    if (missingDocs.length > 0) {
      summary += `\n⚠️ Missing Documents: ${missingDocs.join(", ")}. Please upload these in your Profile.`;
    } else if (pendingDocs.length > 0) {
      summary += `\n⏳ Currently under manual review by our audit team: ${pendingDocs.join(", ")}. Approvals are processed promptly.`;
    } else {
      summary += `\n🎉 All required documents are submitted and verified!`;
    }

    return summary;
  } catch (e) {
    console.warn(`checkVerificationStatus failed for ${userId}: ${e}`);
    return null;
  }
}

/**
 * Tool 3: check_wallet_history
 * Queries transaction history for the user, returning live summary of top-ups, referral credits, payouts.
 */
export async function checkWalletHistory(userId: string): Promise<string | null> {
  if (!userId) return null;
  try {
    const wSnap = await db().collection("wallets").doc(userId).get();
    const wData = wSnap.data() ?? {};
    const mainBalance = (wData["mainWalletBalance"] as number) ?? (((wData["balance"] as number) ?? 0) / 100.0);
    const coinBalance = (wData["seseCoinBalance"] as number) ?? 0.0;

    const txSnap = await db()
      .collection("wallets")
      .doc(userId)
      .collection("transactions")
      .orderBy("createdAt", "desc")
      .limit(5)
      .get();

    let text = `💳 Wallet Summary for Account:\n\n`;
    text += `• Primary Cash Wallet: ${nairaFloat(mainBalance)}\n`;
    text += `• SeSe Coin Bonus Balance: 🪙 ${nairaFloat(coinBalance)}\n`;
    text += `• Total Combined Balance: ${nairaFloat(mainBalance + coinBalance)}\n\n`;

    if (txSnap.empty) {
      text += `Recent Transactions: No recorded transactions yet.`;
    } else {
      text += `Recent Transactions:\n`;
      for (const doc of txSnap.docs) {
        const d = doc.data();
        const label = String(d["label"] ?? d["paymentReference"] ?? d["type"] ?? "Transaction");
        let amt = 0.0;
        if (typeof d["amountKobo"] === "number") amt = d["amountKobo"] / 100.0;
        else if (typeof d["amount"] === "number") amt = d["amount"];
        text += `• ${label}: ${nairaFloat(amt)}\n`;
      }
    }
    return text;
  } catch (e) {
    console.warn(`checkWalletHistory failed for ${userId}: ${e}`);
    return null;
  }
}

// ---------------------------------------------------------------------------
// 4. Policy Kernel & Knowledge Articles
// ---------------------------------------------------------------------------

interface Article {
  topic: string;
  triggers: string[];
  answer: string;
  standalone?: boolean;
  dynamicAnswer?: () => Promise<string>;
}

const ARTICLES: Article[] = [
  {
    topic: "cancellation_policy",
    triggers: [
      "cancellation fee", "cancel policy", "cancellation policy", "canceled trip",
      "cancel fee", "why was i charged cancel", "cancellation penalty",
    ],
    answer:
      `Our Cancellation & Fare Refund Policy:\n\n` +
      `• Customer Cancellations: Free of charge before a driver accepts your booking or within 3 minutes of driver acceptance.\n` +
      `• Late Cancellations: If you cancel after the driver has arrived and waited beyond 5 minutes, a standard cancellation fee applies to compensate the driver's time.\n` +
      `• Driver-Initiated Cancellations: If a driver cancels an active trip, we re-queue your request automatically and refund any pre-deducted wallet fare back to your main wallet balance immediately.`,
  },
  {
    topic: "driver_online_rules",
    triggers: [
      "online balance", "minimum balance driver", "driver online rule", "online threshold",
      "hold dispatch", "dispatch hold", "why am i not getting trips", "driver balance requirement",
    ],
    answer:
      `Driver Online Balance & Dispatch Rules:\n\n` +
      `• You can toggle your status to ONLINE at any wallet balance.\n` +
      `• Minimum Dispatch Balance: If your primary cash wallet (mainWalletBalance) falls below ₦1.00, a warning banner is displayed and trip dispatches are held.\n` +
      `• To receive new trip offers immediately, top up your wallet to at least ₦1.300.00.`,
  },
  {
    topic: "sese_coin_rules",
    triggers: [
      "sese coin", "sese coins", "bonus balance", "promo balance", "referral earnings",
      "convert coin", "convert bonus", "auto sweep", "autosweep", "convert to main",
    ],
    answer:
      `SeSe Coin Bonus & Conversion Mechanics:\n\n` +
      `• Bonus Credits: Referral commissions (1% standard for 365 days, 2% agent/staff for 547 days), streak awards, and promotional bonuses credit exclusively into your SeSe Coin balance (seseCoinBalance).\n` +
      `• Manual Conversion: Once your seseCoinBalance reaches ₦5,000.00, you can tap "Convert to Main Balance" to move your coins into your primary cash wallet.\n` +
      `• Auto-Sweep: When your seseCoinBalance reaches ₦10,000.00, the full bonus automatically sweeps into your main cash wallet in real time.\n` +
      `• Note: SeSe Coins cannot be withdrawn directly to an external bank account without converting to main balance first.`,
  },
  {
    topic: "single_account_architecture",
    triggers: [
      "single account", "customer and driver", "switch role", "unified code",
      "referral code driver", "shared wallet", "same account",
    ],
    answer:
      `Single Unified Account Architecture:\n\n` +
      `• A user operating as both a Customer and a Driver uses a single unified account ID (users/{userId}).\n` +
      `• You share a unified referral code (e.g. MB4321) and a single shared referral wallet pool across both roles.\n` +
      `• Verification completed as a customer carries over when registering a vehicle to drive!`,
  },
  {
    topic: "topup",
    triggers: ["top up", "topup", "add money", "deposit", "fund my wallet", "load wallet", "minimum topup"],
    answer:
      `To top up your SeSe wallet:\n\n` +
      `1. Open Wallet & Earnings and tap "+ Top Up".\n` +
      `2. Enter the amount (Minimum top-up is ${naira(MIN_TOPUP_KOBO)}, maximum is ${naira(MAX_TOPUP_KOBO)}).\n` +
      `3. Pay securely via card, bank transfer, USSD, or mobile money on Paystack.\n\n` +
      `Your balance is credited immediately upon payment confirmation.`,
  },
  {
    topic: "withdraw",
    triggers: [
      "withdraw", "withdrawal", "cash out", "cashout", "payout", "payout desk",
      "external bank payout", "bank transfer payout",
    ],
    answer:
      `External Bank Payout & Withdrawal Rules:\n\n` +
      `1. Open Wallet & Earnings and select "Withdraw / Payout".\n` +
      `2. Enter your withdrawal amount, select your bank, and enter your 10-digit account number.\n` +
      `3. Minimum payout threshold via the weekly payout desk is ${naira(MIN_WITHDRAWAL_KOBO)} (₦20,000.00).\n` +
      `4. Payouts are sent to a bank account matching your registered profile name.`,
  },
  {
    topic: "fare",
    triggers: ["how much", "fare", "price", "pricing", "cost of", "charges", "calculate fare"],
    answer:
      `Fares are calculated automatically before you confirm:\n\n` +
      `Trip Fare = Base Fee + (Distance × per-km rate) + (Time × per-minute rate).\n` +
      `Base fees range from ${naira(PRICING.bicycle.base)} (Bicycle) up to ${naira(PRICING.truck.base)} (Truck). ` +
      `For a Car, the base fare is ${naira(PRICING.car.base)} plus ₦${PRICING.car.perKm}/km and ₦${PRICING.car.perMin}/min.`,
  },
  {
    topic: "streak",
    triggers: ["streak", "cash back", "cashback", "driver bonus", "daily streak", "commission ladder"],
    answer:
      `Driver Streak Rewards & Commission Ladder:\n\n` +
      `• Level 1: Commission steps down from ${L1_RATES[0]}% to ${L1_RATES[L1_RATES.length - 1]}% as you complete daily trips.\n` +
      `• Level 2: 0% commission + previous Level 1 commission is refunded step-by-step.\n` +
      `• Level 3: 0% commission + growing cash bonus ending in a grand award.\n\n` +
      `All streak rewards credit automatically to your wallet. Daily streaks reset at 00:00 midnight local time.`,
  },
  {
    topic: "greeting",
    triggers: ["hello", "hey there", "good morning", "good evening", "good afternoon", "hiya"],
    standalone: true,
    answer:
      "Hi! I am the SeSe Assistant. I can help you with trip bookings, driver status, cancellation refunds, wallet top-ups, SeSe Coin bonus conversions, and account verification. How can I assist you today?",
  },
  {
    topic: "thanks",
    triggers: ["thanks", "thank you", "cheers", "appreciate it"],
    answer: "You're very welcome! Let me know if you need anything else.",
  },
];

function hasWord(text: string, word: string): boolean {
  return new RegExp(`(^|\\s)${normalize(word).replace(/\s+/g, "\\s+")}($|\\s)`).test(text);
}

function bestArticle(text: string): Article | null {
  let best: Article | null = null;
  let bestScore = 0;

  if (hasWord(text, "hi") || hasWord(text, "hey")) {
    return ARTICLES.find((a) => a.topic === "greeting") ?? null;
  }

  for (const article of ARTICLES) {
    let score = 0;
    for (const trigger of article.triggers) {
      const t = normalize(trigger);
      if (text.includes(t)) {
        score += t.includes(" ") ? 3 : 1;
      }
    }
    if (article.standalone && score > 0) {
      return article;
    }
    if (score > bestScore) {
      bestScore = score;
      best = article;
    }
  }
  return bestScore >= 2 ? best : null;
}

// ---------------------------------------------------------------------------
// Main Dialogue Entry Point
// ---------------------------------------------------------------------------

export async function respondTo(
  userText: string,
  ctx: BrainContext
): Promise<BrainResult> {
  const norm = normalize(userText);
  const intent = classifyIntent(userText);

  if (!norm) {
    return {
      kind: "reply",
      topic: "empty",
      intent,
      reply: "I didn't catch that — could you please rephrase your question?",
    };
  }

  // 1. Safety Concerns & Physical Disputes — Highest Priority Escalation
  if (isSafetyIssue(userText)) {
    return { kind: "escalate", reason: "safety", intent: "ride_delivery_ops" };
  }

  // 2. Explicit Human Request or Hard Legal/Fraud Escalations
  if (explicitlyWantsHuman(userText)) {
    return { kind: "escalate", reason: "user-requested", intent };
  }
  if (needsHuman(userText)) {
    return { kind: "escalate", reason: "policy", intent };
  }

  // 3. Automated Backend Tool Resolutions
  // Tool 1: Refund Check for canceled trips
  if (
    has(
      userText,
      "refund",
      "canceled trip",
      "driver canceled",
      "driver cancelled",
      "missing fare",
      "charged for canceled",
      "prepaid fare",
      "deducted fare"
    )
  ) {
    const refundResult = await checkTripRefundStatus(ctx.userId);
    if (refundResult) {
      return {
        kind: "reply",
        topic: "trip_refund_auto_resolved",
        intent: "financials_wallet",
        reply: refundResult,
      };
    }
  }

  // Tool 2: Account & Verification Status Lookup
  if (
    has(
      userText,
      "verification status",
      "am i verified",
      "my account approval",
      "my vehicle approval",
      "missing document",
      "pending review",
      "kyc status"
    )
  ) {
    const verifyResult = await checkVerificationStatus(ctx.userId);
    if (verifyResult) {
      return {
        kind: "reply",
        topic: "verification_status_lookup",
        intent: "account_verification",
        reply: verifyResult,
      };
    }
  }

  // Tool 3: Wallet History & Ledger Lookup
  if (
    has(
      userText,
      "check my balance",
      "my wallet balance",
      "my transaction history",
      "my topup history",
      "my wallet history",
      "how much do i have"
    )
  ) {
    const walletResult = await checkWalletHistory(ctx.userId);
    if (walletResult) {
      return {
        kind: "reply",
        topic: "wallet_history_lookup",
        intent: "financials_wallet",
        reply: walletResult,
      };
    }
  }

  // 4. Contextual & Multi-turn Dialogue Awareness
  if (ctx.history && ctx.history.length > 0) {
    const lastTurn = ctx.history[ctx.history.length - 1];
    const previousText = normalize(lastTurn?.text ?? "");

    // If previous message discussed conversion and user asks "how?" or "can I withdraw?"
    if (
      has(previousText, "sese coin", "convert", "bonus balance") &&
      has(norm, "how", "can i", "withdraw", "process")
    ) {
      return {
        kind: "reply",
        topic: "sese_coin_followup",
        intent: "financials_wallet",
        reply:
          `To convert your SeSe Coins into main withdrawable balance:\n\n` +
          `1. Open Wallet & Earnings in the app.\n` +
          `2. Check your SeSe Coin bonus card. Once balance reaches ₦5,000.00, tap "Convert to Main Balance".\n` +
          `3. If your balance reaches ₦10,000.00, it automatically converts into your main cash wallet!\n\n` +
          `After converting, you can withdraw your main balance to your bank account via the weekly payout desk.`,
      };
    }
  }

  // 5. Policy Knowledge Base Match
  const article = bestArticle(norm);
  if (article) {
    const reply = article.dynamicAnswer ? await article.dynamicAnswer() : article.answer;
    return { kind: "reply", topic: article.topic, intent, reply };
  }

  // 6. Default Fallback — Honest Handover to Live Support Agent
  return {
    kind: "escalate",
    reason: "no-match",
    intent,
  };
}
