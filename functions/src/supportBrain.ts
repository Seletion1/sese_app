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
// Sourced strictly from backend configuration (pricing.ts, payments.ts, tripSettlement.ts).
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

/** Driver online minimum balance rule: Drivers can toggle ONLINE at any balance.
 * If mainWalletBalance < ₦1.00, a warning is shown and backend holds trip dispatches. */
export const MIN_WALLET_TO_ONLINE = 1.0; // ₦1.00

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
      "credit",
      "fund",
      "recharge",
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
  "connect me to agent", "connect to agent", "human representative",
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
// Dynamic Backend Tool Calling & Automated Resolutions
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
          `The payment authorization for ${naira(fareKobo > 0 ? fareKobo : (data["estimatedFareKobo"] ?? 0))} was released back to your card/account.`
        );
      }

      if (canceledBy === "driver" || paymentMethod === "card" || paymentMethod === "paystack" || data["prePaid"] === true) {
        const refundKobo = fareKobo > 0 ? fareKobo : Math.round((data["estimatedFareKobo"] ?? 0) as number);
        if (refundKobo > 0) {
          await doc.ref.update({
            refunded: true,
            refundedAt: admin.firestore.FieldValue.serverTimestamp(),
          });

          return (
            `✅ Automated Refund / Release Executed!\n\n` +
            `Your trip #${doc.id.slice(0, 8)} was canceled. Any online payment authorization of ` +
            `${naira(refundKobo)} has been released back to your payment card.`
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
 */
export async function checkWalletHistory(userId: string): Promise<string | null> {
  if (!userId) return null;
  try {
    const wSnap = await db().collection("wallets").doc(userId).get();
    const wData = wSnap.data() ?? {};
    const creditBalance = (wData["driverBalance"] as number) ?? (wData["mainWalletBalance"] as number) ?? (((wData["balance"] as number) ?? 0) / 100.0);

    const txSnap = await db()
      .collection("wallets")
      .doc(userId)
      .collection("transactions")
      .orderBy("createdAt", "desc")
      .limit(5)
      .get();

    let text = `💳 Driver Sese Credits Summary:\n\n`;
    text += `• Available Sese Credits: ${nairaFloat(creditBalance)}\n`;
    text += `• Note: Sese Credits are non-withdrawable platform service credits used strictly to settle dispatch commissions.\n\n`;

    if (txSnap.empty) {
      text += `Recent History: No recent credit movements recorded.`;
    } else {
      text += `Recent Credit History:\n`;
      for (const doc of txSnap.docs) {
        const d = doc.data();
        const label = String(d["label"] ?? d["paymentReference"] ?? d["type"] ?? "Credit transaction");
        let amt = 0.0;
        if (typeof d["amountKobo"] === "number") amt = d["amountKobo"] / 100.0;
        else if (typeof d["amount"] === "number") amt = d["amount"];
        text += `• ${label}: ${amt >= 0 ? "+" : ""}${nairaFloat(amt)}\n`;
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
    topic: "topup",
    triggers: [
      "top up", "topup", "credit account", "credit my account", "fund account",
      "fund wallet", "add credits", "credits topup", "sese credits topup",
      "minimum topup", "how do i credit", "how to credit", "how do i fund",
      "how to fund", "recharge wallet", "paystack topup", "opay topup", "buy credits",
    ],
    answer:
      `To top up your Driver Sese Credits:\n\n` +
      `1. Open Sese Credits from the driver menu and tap "Top Up Sese Credits".\n` +
      `2. Select your gateway (Paystack or OPay Checkout).\n` +
      `3. Enter the amount (Minimum top-up is ${naira(MIN_TOPUP_KOBO)}, maximum is ${naira(MAX_TOPUP_KOBO)}).\n` +
      `4. Pay securely via Paystack or OPay.\n\n` +
      `Your dispatch credits balance is updated immediately upon payment confirmation.\n\n` +
      `Note: Driver Sese Credits are strictly non-withdrawable platform service credits used to settle dispatch commissions.`,
  },
  {
    topic: "customer_payment_rules",
    triggers: [
      "customer payment", "how customer pays", "card payment", "pay for trip",
      "pay for delivery", "customer wallet", "customer deposit", "do customers have wallet",
      "paystack card", "opay card", "how does customer pay",
    ],
    answer:
      `Customer Trip Payment Rules:\n\n` +
      `• Direct Trip Payments: Customer trips are paid directly per booking via Cash or Paystack/OPay online card payment at checkout.\n` +
      `• No Customer Stored Wallet: SESE does not operate a stored-value customer wallet or customer deposit system.\n` +
      `• PCI-DSS Gateway Security: Online card payments are processed directly through licensed PCI-DSS Level 1 payment gateways (Paystack/OPay). SESE never stores raw card details.`,
  },
  {
    topic: "cancellation_policy",
    triggers: [
      "cancellation fee", "cancel policy", "cancellation policy", "canceled trip",
      "cancel fee", "why was i charged cancel", "cancellation penalty", "cancel ride",
    ],
    answer:
      `Our Cancellation & Fare Refund Policy:\n\n` +
      `• Customer Cancellations: Free of charge before a driver accepts your booking or within 3 minutes of driver acceptance.\n` +
      `• Late Cancellations: If you cancel after the driver has arrived and waited beyond 5 minutes, a standard cancellation fee applies to compensate the driver's time.\n` +
      `• Driver-Initiated Cancellations: If a driver cancels an active trip, your request is re-queued automatically and any online card charge is released.`,
  },
  {
    topic: "driver_online_rules",
    triggers: [
      "online balance", "minimum balance driver", "driver online rule", "online threshold",
      "hold dispatch", "dispatch hold", "why am i not getting trips", "driver balance requirement",
      "commission rate", "platform commission",
    ],
    answer:
      `Driver Online Status & Sese Credits Rules:\n\n` +
      `• Toggle Status: You can toggle your status to ONLINE at any credit balance.\n` +
      `• Minimum Dispatch Credits: If your Sese Credits fall below ₦1.00, a warning is displayed and trip dispatches are held.\n` +
      `• Commission Rate: Standard platform commission is 20% on completed trips, settled via Sese Credits.\n` +
      `• Top Up: To receive new trip offers immediately, top up your Sese Credits.`,
  },
  {
    topic: "sese_coin_rules",
    triggers: [
      "sese coin", "sese coins", "bonus balance", "promo balance", "referral earnings",
      "convert coin", "convert bonus", "auto sweep", "autosweep", "convert to main",
    ],
    answer:
      `Direct Trip Payments & Driver Sese Credits:\n\n` +
      `• Direct Trip Payments: Customer trips are paid directly per order via Cash or Paystack card checkout. SESE does not operate a stored-value customer wallet or withdrawal system.\n` +
      `• Non-Withdrawable Dispatch Credits: Driver Sese Credits are strictly non-withdrawable platform service credits used to settle trip commissions.\n` +
      `• Paystack/OPay Top-Up: Drivers can top up their Sese Credits balance via Paystack or OPay whenever required to cover commissions.\n` +
      `• Zero Cash-Out: Sese Credits carry zero cash value and cannot be withdrawn, transferred, or cashed out.`,
  },
  {
    topic: "terms_of_service",
    triggers: [
      "terms of service", "terms of use", "terms and conditions", "platform rules",
      "rules of use", "legal terms", "prohibited goods", "contractor status", "our rules",
    ],
    answer:
      `SESE Technology LTD — Terms of Service Highlights:\n\n` +
      `• Intermediary Technology Platform: SESE connects passengers and senders with independent third-party driver partners.\n` +
      `• Single Unified Account: Every user or driver is permitted exactly one account tied to a verified identity (NIN/BVN) across both customer and driver modes.\n` +
      `• Prohibited Goods: Deliveries must contain no illegal drugs, weapons, toxic materials, stolen items, or counterfeit property.\n` +
      `• Independent Contractors: Driver partners are independent contractors solely responsible for local taxes and vehicle maintenance.\n` +
      `• Full Terms of Service: https://sesetech.com/terms`,
  },
  {
    topic: "privacy_policy",
    triggers: [
      "privacy policy", "privacy", "data protection", "phone number masking",
      "location tracking", "is my data safe", "sell my data", "privacy rules",
    ],
    answer:
      `SESE Technology LTD — Privacy & Data Protection Policy:\n\n` +
      `• Data Security: SESE never sells your personal information or raw location data to third parties.\n` +
      `• Phone Number Masking: Phone numbers can be masked into placeholders (e.g. 080****5678) to keep your personal contact private during trips.\n` +
      `• Location Privacy: GPS location tracking is active only when you are online or during an active trip.\n` +
      `• Full Privacy Policy: https://sesetech.com/PrivacyPolicy`,
  },
  {
    topic: "account_deletion",
    triggers: [
      "delete account", "how to delete account", "remove my account", "close account",
      "erase data", "account deletion",
    ],
    answer:
      `Account & Data Deletion Policy:\n\n` +
      `• In-App Deletion: Open Settings → Legal & Compliance → Delete Account.\n` +
      `• Web Portal: https://sesetech.com/delete\n` +
      `• Requirements: No active trips or pending deliveries in progress.\n` +
      `• 30-Day Archival: Deleted accounts enter a 30-day soft archive for regulatory compliance before permanent PII erasure.`,
  },
  {
    topic: "verification_requirements",
    triggers: [
      "verification requirement", "how to get verified", "kyc document",
      "driver document", "vehicle document", "selfie requirement", "nin requirement",
      "how to verify", "account verification",
    ],
    answer:
      `Account Verification & Driver KYC Requirements:\n\n` +
      `• Customer Verification: National Identification Number (NIN) or Government ID, ID Front & Back photos, and a Live Selfie capture.\n` +
      `• Driver Verification: Valid Driver's License, Vehicle Licence, Proof of Insurance, Vehicle Inspection Certificate, and Live Selfie.\n` +
      `• Unified Member ID: Sequential ID (e.g. SC0001 for customers, SD0001 for drivers) is assigned automatically once verification is complete.`,
  },
  {
    topic: "referral_rules",
    triggers: [
      "referral code", "referral reward", "referral bonus", "invite friend",
      "how referral works", "1% referral", "residual revenue",
    ],
    answer:
      `SESE Referral Program Rules:\n\n` +
      `• Unified Code: You share a single referral code (e.g. MB4321) across customer and driver modes.\n` +
      `• Residual Revenue: Referrers earn 1% residual revenue from completed base fares.\n` +
      `• Active Windows: Standard users enjoy a 365-day active referral window (548 days for elevated staff).`,
  },
  {
    topic: "calling_and_chat",
    triggers: [
      "in app call", "voice call", "call driver", "call customer", "chat rule", "voice note",
    ],
    answer:
      `In-App Audio Calling & Chat Standards:\n\n` +
      `• In-App VoIP Calling: Calls are powered by encrypted WebRTC / Agora RTC without revealing raw cellular phone numbers.\n` +
      `• Trip Chat: Restricted to text messages and photos (no audio notes on trip chat).\n` +
      `• Support Chat: Supports text, photos, and voice notes up to 5MB.`,
  },
  {
    topic: "safety_emergency",
    triggers: ["sos", "panic button", "safety tools", "emergency number", "safety features"],
    answer:
      `Safety & Emergency Procedures:\n\n` +
      `• In-App SOS Panic Button: Tap the SOS icon during any active trip to alert SeSe Safety coordinators with live GPS location.\n` +
      `• Emergency Services: In immediate life-safety emergencies, please contact local emergency services (112/199) directly.`,
  },
  {
    topic: "single_account_architecture",
    triggers: [
      "single account", "customer and driver", "switch role", "unified code",
      "referral code driver", "same account",
    ],
    answer:
      `Single Unified Account Architecture:\n\n` +
      `• A user operating as both a Customer and a Driver uses a single unified account ID (users/{userId}).\n` +
      `• You share a unified referral code (e.g. MB4321) across both roles.\n` +
      `• Verification completed as a customer carries over when registering a vehicle to drive!`,
  },
  {
    topic: "payments_and_credits",
    triggers: [
      "withdraw", "withdrawal", "cash out", "cashout", "payout", "payout desk",
      "external bank payout", "bank transfer payout", "sese credits",
    ],
    answer:
      `Payment & Sese Credits Policy:\n\n` +
      `• Direct Trip Payments: Customer trips are paid directly per order via Cash or Paystack/OPay card/online payment. SESE does not operate a stored-value customer wallet or bank withdrawal system.\n` +
      `• Sese Credits: Driver service credits are non-withdrawable platform credits strictly used to settle dispatch commissions. Drivers can top up their Sese Credits balance via Paystack or OPay whenever needed.\n` +
      `• Zero Cash-Out: Sese Credits cannot be withdrawn, transferred, or cashed out.`,
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
    topic: "greeting",
    triggers: ["hello", "hey there", "good morning", "good evening", "good afternoon", "hiya"],
    standalone: true,
    answer:
      "Hi! I am the SeSe Virtual Assistant. I can help you with trip bookings, wallet top-ups, fares, verification status, Terms of Service, and Privacy Policies. How can I assist you today?",
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
  return bestScore >= 1 ? best : null;
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

    if (
      has(previousText, "sese coin", "convert", "bonus balance") &&
      has(norm, "how", "can i", "withdraw", "process")
    ) {
      return {
        kind: "reply",
        topic: "sese_coin_followup",
        intent: "financials_wallet",
        reply:
          `Sese Credits Policy:\n\n` +
          `Driver dispatch credits are non-withdrawable service units strictly used for trip commission settlement. Customer trips are paid per-order via cash or Paystack card payment.`,
      };
    }
  }

  // 5. Policy Knowledge Base Match
  const article = bestArticle(norm);
  if (article) {
    const reply = article.dynamicAnswer ? await article.dynamicAnswer() : article.answer;
    return { kind: "reply", topic: article.topic, intent, reply };
  }

  // 6. Interactive AI Guidance Response — Active AI Retention
  return {
    kind: "reply",
    topic: "general_help_guidance",
    intent,
    reply:
      "I am the SeSe Virtual Assistant and I can help you with:\n" +
      "1. Wallet Top-Up & Sese Credits (Paystack/OPay)\n" +
      "2. Trip Fares, Booking & Delivery PINs\n" +
      "3. Account Verification & Document Uploads\n" +
      "4. Terms of Service, Privacy Policy & Platform Rules\n\n" +
      "Could you please rephrase or specify your question? If you prefer to speak directly with a human support agent, just reply 'Agent'.",
  };
}
