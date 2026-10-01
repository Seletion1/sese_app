"use strict";
/**
 * SeSe Support Brain — deterministic, API-free Level-1 support engine.
 *
 * Replaces the external LLM call in `supportBot.ts` with a rules + retrieval
 * engine that runs entirely inside Cloud Functions. No API key, no network
 * call, no cost, no rate limit, and no dependency on a third-party model being
 * available.
 *
 * WHY THIS IS BETTER THAN AN LLM FOR SUPPORT
 * ------------------------------------------
 * Support answers are overwhelmingly *factual about this product*, and the
 * facts are already in this repo as configuration. A model can invent a fee; an
 * engine that reads `PRICING` and `FINANCIAL` cannot. Where the engine does not
 * know something it escalates rather than guessing, which is the correct
 * failure mode when money or safety is involved.
 *
 * The trade-off, stated plainly: this is not a language model. It will not
 * reason about novel phrasing the way a model would. It handles the configured
 * surface superbly and defers everything else to a human. That is a deliberate
 * trade: predictable and honest over fluent and occasionally wrong.
 *
 * ORDER OF PRECEDENCE (first match wins)
 *   1. Safety / emergency      — never answered by a bot, always escalated.
 *   2. Account-specific lookup — answers from live Firestore state.
 *   3. Knowledge article       — answered from the curated KB below.
 *   4. Escalation heuristic    — out-of-scope topics go to a human.
 */
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.SAFETY_REPLY = exports.HANDOVER_TEXT = void 0;
exports.normalize = normalize;
exports.isSafetyIssue = isSafetyIssue;
exports.needsHuman = needsHuman;
exports.explicitlyWantsHuman = explicitlyWantsHuman;
exports.respondTo = respondTo;
const admin = __importStar(require("firebase-admin"));
// ---------------------------------------------------------------------------
// Product facts. Sourced from the live config, not invented.
// Keep in sync with: functions/src/pricing.ts, sese_core financial_config,
// sese_core car_tier_thresholds.dart.
// ---------------------------------------------------------------------------
/** Per-vehicle pricing, mirrored from `functions/src/pricing.ts` DEFAULT_RATES. */
const PRICING = {
    bicycle: { base: 300, perKm: 80, perMin: 10 },
    motorcycle: { base: 400, perKm: 120, perMin: 15 },
    tricycle: { base: 450, perKm: 130, perMin: 18 },
    car: { base: 600, perKm: 180, perMin: 25 },
    van: { base: 1200, perKm: 300, perMin: 40 },
    truck: { base: 1500, perKm: 400, perMin: 50 },
};
/** Human-readable vehicle names, used in fare explanations. */
function vehicleLabel(key) {
    switch (key) {
        case "bicycle": return "Bicycle";
        case "motorcycle": return "Motorcycle (Okada)";
        case "tricycle": return "Tricycle (Keke)";
        case "car": return "Car";
        case "van": return "Van";
        case "truck": return "Truck";
        default: return key;
    }
}
/** Cheapest and most expensive base fees, quoted in the fare article. */
function fareRange() {
    const entries = Object.entries(PRICING);
    const cheapest = entries.reduce((a, b) => (a[1].base <= b[1].base ? a : b));
    const dearest = entries.reduce((a, b) => (a[1].base >= b[1].base ? a : b));
    return (`Base fees start from ${naira(cheapest[1].base)} (${vehicleLabel(cheapest[0])}) ` +
        `and go up to ${naira(dearest[1].base)} (${vehicleLabel(dearest[0])}).`);
}
/** Withdrawal bounds, mirrored from `functions/src/payouts.ts`. */
const MIN_WITHDRAWAL_KOBO = 10000;
const MAX_WITHDRAWAL_KOBO = 50000000;
/** Top-up bounds, mirrored from `functions/src/payments.ts`. */
const MIN_TOPUP_KOBO = 10000;
const MAX_TOPUP_KOBO = 50000000;
/** Minimum driver wallet balance to go online, from FinancialConfig. */
const MIN_WALLET_TO_ONLINE = 1.0;
/** Streak step-down ladder, mirrored from `functions/src/driverStreak.ts`. */
const L1_RATES = [15, 12.5, 10, 7.5, 5, 2.5, 0];
function naira(kobo) {
    return `₦${(kobo / 100).toLocaleString("en-NG", {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
    })}`;
}
// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------
function normalize(text) {
    return text
        .toLowerCase()
        .replace(/[’']/g, "")
        .replace(/[^a-z0-9₦\s]/g, " ")
        .replace(/\s+/g, " ")
        .trim();
}
/** True when ANY of the phrases occurs in the normalized text. */
function has(text, ...phrases) {
    return phrases.some((p) => text.includes(normalize(p)));
}
/**
 * Small stop-word filter used for topic scoring so "how do I get my money
 * back" is not dominated by "how do i".
 */
const STOPWORDS = new Set([
    "a", "an", "the", "is", "are", "was", "i", "my", "me", "you", "your", "to",
    "of", "in", "on", "for", "and", "or", "do", "does", "did", "can", "could",
    "how", "what", "why", "when", "where", "it", "that", "this", "with", "be",
    "have", "has", "am", "get", "got", "please", "help", "hi", "hello", "hey",
    "so", "if", "at", "from", "but", "not", "no", "yes", "im", "ive", "id",
]);
function tokens(text) {
    return normalize(text)
        .split(" ")
        .filter((t) => t.length > 1 && !STOPWORDS.has(t));
}
// ---------------------------------------------------------------------------
// 1. Safety — always first, never answered by a bot.
// ---------------------------------------------------------------------------
const SAFETY_PHRASES = [
    "accident", "crash", "crashed", "injur", "hospital", "ambulance", "police",
    "stolen", "theft", "stole", "robbery", "assault", "attack", "kidnap",
    "blood", "unconscious", "emergency", "danger", "threat", "crime",
    "harass", "unsafe", "scared",
];
function isSafetyIssue(raw) {
    return has(raw, ...SAFETY_PHRASES);
}
const SAFETY_REPLY = "I'm very sorry this happened. Your safety comes first — if anyone is hurt " +
    "or you are in danger, please contact local emergency services now. " +
    "I'm connecting you to a human support agent right away, and you should " +
    "stay on the line with them.";
exports.SAFETY_REPLY = SAFETY_REPLY;
// ---------------------------------------------------------------------------
// 2. Hard escalation — money disputes, bans, anything needing authority.
// ---------------------------------------------------------------------------
const HARD_ESCALATION_PHRASES = [
    "refund", "chargeback", "dispute", "fraud", "scam", "stolen money",
    "missing money", "money missing", "didnt receive", "did not receive",
    "not received", "wrong amount", "overcharged", "double charged",
    "appeal", "unban", "ban", "banned", "blocked", "suspended", "suspension",
    "deactivated", "close my account", "delete my account", "lawyer",
    "court", "police", "regulator",
];
function needsHuman(raw) {
    return has(raw, ...HARD_ESCALATION_PHRASES);
}
const HUMAN_PHRASES = [
    "human", "agent", "real person", "customer service", "support agent",
    "speak to someone", "talk to someone", "representative", "manager",
    "escalate", "complaint", "supervisor",
];
function explicitlyWantsHuman(raw) {
    return has(raw, ...HUMAN_PHRASES);
}
// ---------------------------------------------------------------------------
// 3. Account-specific answers, read live from Firestore.
// ---------------------------------------------------------------------------
const db = () => admin.firestore();
/** Reads a real number so the bot never quotes a stale or invented figure. */
async function readNumber(uid, collection, field) {
    var _a;
    try {
        const snap = await db().collection(collection).doc(uid).get();
        if (!snap.exists)
            return null;
        const raw = (_a = snap.data()) === null || _a === void 0 ? void 0 : _a[field];
        return typeof raw === "number" ? raw : null;
    }
    catch (_b) {
        return null;
    }
}
/** Admin-configured payout floor, same source as `payouts.payoutFloorKobo`. */
async function livePayoutFloorKobo() {
    var _a;
    try {
        const snap = await db().collection("system_configs").doc("financials").get();
        const raw = (_a = snap.data()) === null || _a === void 0 ? void 0 : _a.minPayoutThreshold;
        if (typeof raw === "number" && Number.isFinite(raw) && raw > 0) {
            return Math.round(raw * 100);
        }
    }
    catch (_b) {
        // Fall through to the hard floor.
    }
    return MIN_WITHDRAWAL_KOBO;
}
const ARTICLES = [
    {
        topic: "withdraw",
        triggers: [
            "withdraw", "withdrawal", "cash out", "cashout", "payout", "take my money",
            "get paid out", "transfer to bank", "money out",
        ],
        answer: "",
        dynamicAnswer: async () => {
            const floor = await livePayoutFloorKobo();
            return (`Here's how to withdraw your SeSe wallet balance:\n\n` +
                `1. Open Wallet & Earnings and tap "Withdraw / Payout".\n` +
                `2. Enter the amount, choose your bank, and enter your 10-digit account number.\n` +
                `3. We confirm the account name matches your profile name, then send the money.\n\n` +
                `Per withdrawal: minimum ${naira(floor)}, maximum ${naira(MAX_WITHDRAWAL_KOBO)}.\n` +
                `Your balance drops as soon as you request, and is refunded automatically if the transfer fails.\n` +
                `Payouts can only go to a bank account in your own name — the name on the account must match your SeSe profile name.`);
        },
    },
    {
        topic: "topup",
        triggers: ["top up", "topup", "add money", "deposit", "fund my wallet", "load wallet"],
        answer: `To top up your SeSe wallet:\n\n` +
            `1. Open Wallet & Earnings and tap "+ Top Up".\n` +
            `2. Enter the amount (${naira(MIN_TOPUP_KOBO)} to ${naira(MAX_TOPUP_KOBO)}).\n` +
            `3. Pay by card, bank transfer, USSD or mobile money on Paystack's secure checkout.\n\n` +
            `Your balance is credited the moment payment is confirmed, and you'll see it in your transaction history.`,
    },
    {
        topic: "go_online",
        triggers: ["go online", "going online", "cannot go online", "cant go online", "why cant i go online", "start driving", "start taking trips"],
        answer: `You can go online once all of these are in place:\n\n` +
            `• Your profile is approved by our verification team.\n` +
            `• You have at least one vehicle registered AND approved.\n` +
            `• Your wallet holds at least ₦${MIN_WALLET_TO_ONLINE.toFixed(2)} so you can receive trip earnings.\n` +
            `• Your GPS fix is accurate (within 100m) when you tap the button.\n\n` +
            `If any of these is missing, the app will tell you exactly what's blocking you. You also can't go online while you're mid-trip.`,
    },
    {
        topic: "fare",
        triggers: ["how much", "fare", "price", "pricing", "cost of", "charges", "how do you calculate"],
        answer: `Fares are calculated automatically and shown to you before you confirm — drivers cannot set or change them.\n\n` +
            `Every trip is: a base fee + (distance × per-km rate) + (time × per-minute rate), ` +
            `then any applicable multiplier.\n\n${fareRange()} ` +
            `For a Car, that's ${naira(PRICING.car.base)} plus ₦${PRICING.car.perKm} per km ` +
            `and ₦${PRICING.car.perMin} per minute.`,
    },
    {
        topic: "surge",
        triggers: ["surge", "price increase", "why is it expensive", "higher fare", "dynamic pricing"],
        answer: `Fares can rise above the standard rate when demand is high in your area. The exact price is always shown to you ` +
            `before you confirm the booking, and you'll see a breakdown of the base fare and the increase.\n\n` +
            `Surge is applied automatically by the system based on local demand — drivers have no control over it. ` +
            `You are never charged more than the figure shown at confirmation.`,
    },
    {
        topic: "tier",
        triggers: ["comfort", "premium", "luxe", "tier", "vehicle class", "car class", "car tier"],
        answer: `Car rides are grouped into three classes based on the vehicle's year:\n\n` +
            `• Standard / Comfort — built before 2010.\n` +
            `• Executive / Premium — built 2010 to 2019.\n` +
            `• Luxe / Super — built 2020 or newer.\n\n` +
            `Each class has its own fare multiplier, so a newer car costs a little more per trip. ` +
            `You choose the class you want when booking, and you'll see the fare for each option before you confirm.`,
    },
    {
        topic: "vehicle_verify",
        triggers: ["vehicle verification", "verify my vehicle", "vehicle approval", "vehicle pending", "car pending", "bike pending"],
        answer: `Every vehicle needs our verification team to approve it before you can go online. You register it in Fleet & Vehicles with:\n\n` +
            `• Make, model, year, colour and licence plate\n` +
            `• Your vehicle licence and insurance certificate\n` +
            `• Photos of the vehicle (front, rear, both sides and interior)\n\n` +
            `New vehicles start as PENDING VERIFICATION and you can't receive orders until approved. Approval usually takes a short while during working hours.`,
    },
    {
        topic: "streak",
        triggers: ["streak", "cash back", "cashback", "bonus", "daily streak", "commission"],
        answer: `Drivers earn streak rewards for completing trips in a day:\n\n` +
            `• Level 1: commission steps down from ${L1_RATES[0]}% to 0% as you complete trips.\n` +
            `• Level 2: zero commission, and the Level 1 commission you already paid is refunded to you step by step.\n` +
            `• Level 3: zero commission, with a growing cash bonus each step, ending in a grand award.\n\n` +
            `Rewards credit to your wallet automatically on the trip that triggers them. Your streak resets at the start of each day in your own timezone.`,
    },
    {
        topic: "cancel",
        triggers: ["cancel", "cancellation", "cancel my trip", "cancel order", "refund my fare"],
        answer: `You can cancel a booking any time before the driver arrives, at no cost from you.\n\n` +
            `• If you cancel before the driver accepts, the order closes immediately.\n` +
            `• If the driver has already arrived and waited, cancelling protects their streak — and a support agent can review the case if you think that's unfair.\n\n` +
            `If you were charged and want the fare back, tell me what happened and I'll connect you to an agent who can review the payment.`,
    },
    {
        topic: "arrival",
        triggers: ["driver not coming", "no show", "driver is late", "waiting too long", "driver cancelled", "where is my driver"],
        answer: `You can follow your driver's live location from the trip screen once a driver accepts.\n\n` +
            `If the driver isn't moving, the app normally re-broadcasts your request to other drivers automatically. ` +
            `You can also cancel and re-book at any time before they arrive.\n\n` +
            `If you've been waiting a long time with no update, tell me and I'll connect you to an agent.`,
    },
    {
        topic: "delivery",
        triggers: ["deliver", "delivery", "send item", "package", "parcel", "pickup"],
        answer: `To send an item:\n\n` +
            `1. Choose "Send Item" on the home screen and enter pickup and drop-off.\n` +
            `2. Pick a vehicle type that suits the item — options run from Bicycle through Motorcycle, Tricycle, Car, Van and Truck.\n` +
            `3. Confirm the fare, then the driver is matched to your pickup location.\n\n` +
            `Fares are based on distance and vehicle size, and are confirmed before you book.`,
    },
    {
        topic: "damage",
        triggers: ["item damaged", "damaged", "broken", "package broken", "item lost", "lost my item"],
        answer: "I'm sorry about that. Item damage or loss needs a human to review — photos and details of the incident, and they'll take it from there. Connecting you to a support agent now.",
    },
    {
        topic: "payment_method",
        triggers: ["payment method", "pay with", "cash", "how do i pay", "card", "paystack", "usd"],
        answer: `You can pay by card, bank transfer, USSD, or mobile money — all through Paystack's secure checkout. ` +
            `Some orders can also be paid with cash on delivery where the driver confirms cash collection.\n\n` +
            `Wallet balance can be topped up in advance and used for trips. Never send cash to a driver's personal number or transfer money outside the app.`,
    },
    {
        topic: "account_verify",
        triggers: ["verify my account", "account verification", "kyc", "nin", "documents", "verification pending"],
        answer: `To verify your SeSe account, open Profile → "Verify Account" and complete the one-time form:\n\n` +
            `• Your name, date of birth, gender and residential address\n` +
            `• Your government ID type and number\n` +
            `• A photo of the front and back of your ID\n` +
            `• A live selfie taken with the camera\n\n` +
            `Our verification team reviews submissions. You'll see the status on your profile once it's reviewed. ` +
            `If you're rejected, the app shows the reason and you can edit and resubmit.`,
    },
    {
        topic: "switch_mode",
        triggers: ["switch to driver", "become a driver", "drive as well", "switch role", "both driver and customer"],
        answer: `You can switch between Customer and Driver mode at any time from your profile.\n\n` +
            `Once your personal account is verified you do NOT need to re-enter those details to drive — the same verification covers both. ` +
            `To start taking trips you just need at least one approved vehicle added in Fleet & Vehicles.`,
    },
    {
        topic: "payout_schedule",
        triggers: [
            "when will i be paid", "when do i get paid", "when do i get my money",
            "payout schedule", "how long does payout take", "how long until payout",
            "settlement time", "when is my money available", "money available",
        ],
        answer: "",
        dynamicAnswer: async () => {
            const floor = await livePayoutFloorKobo();
            return (`Trip earnings land in your SeSe wallet as soon as the trip is completed — there is no waiting period for your money to become available.\n\n` +
                `Withdrawing it to your bank is a separate step you trigger yourself from Wallet & Earnings, any time your balance is at least ${naira(floor)}. ` +
                `Transfers normally reach your bank the same working day.`);
        },
    },
    {
        topic: "referral",
        triggers: [
            "referral", "referral code", "refer a friend", "refer someone",
            "invite a friend", "invite", "bonus for referring", "referral bonus",
            "referral commission", "how do referrals work", "how does referral work",
        ],
        answer: `Share your referral code from the Referral Hub. Your friend signs up with it, and you earn a commission on the orders they complete.\n\n` +
            `Standard referrals earn 1% and are eligible for 365 days. Agent and staff referrals earn 2% and are eligible for 547 days.`,
    },
    {
        topic: "safety_tools",
        triggers: ["share trip", "safety", "emergency contact", "sos", "share my ride"],
        answer: `While a trip is active you can share your trip details with a trusted person from the trip screen, and you always have ` +
            `one-tap access to the local emergency number.\n\n` +
            `If you feel unsafe in any situation, contact local emergency services first, then escalate here — an agent will pick up immediately.`,
    },
    {
        topic: "delivery_pin",
        triggers: [
            "delivery pin", "delivery code", "verification pin", "verification code",
            "4-digit", "4 digit", "drop-off code", "dropoff code", "confirm delivery",
            "complete my delivery", "recipient code", "package code",
        ],
        answer: `Deliveries are confirmed with a 4-digit verification PIN:\n\n` +
            `• When a delivery is booked, the app generates a random 4-digit code.\n` +
            `• You (the sender) receive the code and share it with your recipient.\n` +
            `• At drop-off, the recipient gives the code to the driver, who enters ` +
            `it to complete the delivery and release the payout.\n\n` +
            `Passenger rides do not use a PIN. If your code does not work, check ` +
            `that you are reading the code for the right delivery — each one has ` +
            `its own.`,
    },
    {
        topic: "p2p_transfer",
        triggers: [
            "send money to", "transfer to", "p2p", "wallet to wallet",
            "pay a friend", "send to a friend", "transfer funds",
        ],
        answer: `You can send wallet money instantly to another SeSe user:\n\n` +
            `1. Open Wallet & Earnings and choose the wallet-to-wallet transfer option.\n` +
            `2. Enter the recipient's registered phone number and the amount ` +
            `(${naira(MIN_WITHDRAWAL_KOBO)} minimum per transfer).\n` +
            `3. Confirm — the money leaves your wallet and lands in theirs ` +
            `immediately, and you both get a transaction record.\n\n` +
            `Transfers only work to registered SeSe phone numbers, never to ` +
            `yourself, and never exceed your available balance.`,
    },
    {
        topic: "split_payment",
        triggers: [
            "split payment", "split the fare", "split fare", "share the fare",
            "share fare", "split bill", "share cost", "co-pay", "copay",
        ],
        answer: `You can split a trip fare with up to 5 friends:\n\n` +
            `1. After booking, choose "Split Payment" and enter each friend's ` +
            `registered phone number.\n` +
            `2. The fare is divided equally — you absorb any leftover kobo so the ` +
            `parts always add up exactly.\n` +
            `3. Each friend gets an in-app prompt to accept their share. The split ` +
            `is ready once everyone accepts; one decline cancels the whole split.\n\n` +
            `Everyone invited must be a registered SeSe user. Your own share is ` +
            `reserved the moment you create the split.`,
    },
    {
        topic: "greeting",
        // NOTE: "hi" is deliberately absent. As a substring it matches inside
        // "pending", "this", "while" and more, which stole real topics. Greetings
        // are matched on word boundaries in `bestArticle` instead.
        triggers: [
            "hello", "hey there", "good morning", "good evening", "good afternoon",
            "good day", "how are you", "hiya", "hiya there",
        ],
        standalone: true,
        answer: "Hi! I'm the SeSe Assistant. I can help with fares, trips, deliveries, your wallet, " +
            "withdrawals, vehicle verification, and account verification. " +
            "What can I help you with?",
    },
    {
        topic: "thanks",
        triggers: ["thanks", "thank you", "cheers", "appreciate it"],
        answer: "Happy to help! Anything else I can look into for you?",
    },
];
/** True when the whole word `word` appears in the text. */
function hasWord(text, word) {
    return new RegExp(`(^|\\s)${normalize(word).replace(/\s+/g, "\\s+")}($|\\s)`).test(text);
}
/** Best-scoring article for the message, or null. */
function bestArticle(text) {
    var _a;
    let best = null;
    let bestScore = 0;
    const words = tokens(text);
    // A bare "hi" / "hey" greeting, matched on word boundaries so it cannot
    // match inside "pending" or "this".
    if (hasWord(text, "hi") || hasWord(text, "hey")) {
        return (_a = ARTICLES.find((a) => a.topic === "greeting")) !== null && _a !== void 0 ? _a : null;
    }
    for (const article of ARTICLES) {
        let score = 0;
        // A multi-word trigger phrase is strong evidence; a single generic word is
        // weak, so single-word triggers need a second corroborating word.
        for (const trigger of article.triggers) {
            const t = normalize(trigger);
            if (text.includes(t)) {
                score += t.includes(" ") ? 3 : 1;
            }
        }
        for (const w of words) {
            if (article.triggers.some((tr) => normalize(tr).includes(w) && w.length > 3)) {
                score += 1;
            }
        }
        if (article.standalone && score > 0) {
            // A bare greeting is unambiguous, so 1 point is enough.
            return article;
        }
        if (score > bestScore) {
            bestScore = score;
            best = article;
        }
    }
    // Require at least 2 points, so a single weak word cannot pull a wrong
    // article out of the KB.
    return bestScore >= 2 ? best : null;
}
/**
 * Answers one user message, or asks for a human.
 *
 * `topic` is recorded on the message row so the hub can see what the bot
 * thought the user was asking about — useful when an agent takes over.
 */
async function respondTo(userText, ctx) {
    const text = normalize(userText);
    if (!text) {
        return {
            kind: "reply",
            topic: "empty",
            reply: "I didn't catch that — could you rephrase your question?",
        };
    }
    // 1. Safety always wins, before anything else.
    if (isSafetyIssue(userText)) {
        return { kind: "escalate", reason: "safety" };
    }
    // 2. Explicit request for a human, or a topic needing authority.
    if (explicitlyWantsHuman(userText)) {
        return { kind: "escalate", reason: "user-requested" };
    }
    if (needsHuman(userText)) {
        return { kind: "escalate", reason: "policy" };
    }
    // 3. Account-specific, from live state.
    if (has(userText, "my balance", "how much do i have", "what is my balance", "check my balance", "available balance")) {
        const balanceKobo = await readNumber(ctx.userId, "wallets", "balance");
        if (balanceKobo !== null) {
            const floor = await livePayoutFloorKobo();
            return {
                kind: "reply",
                topic: "my_balance",
                reply: `Your available SeSe wallet balance is ${naira(balanceKobo)}.\n\n` +
                    `You can withdraw any amount from ${naira(floor)} up to your balance. ` +
                    `Tap "Withdraw / Payout" on the Wallet & Earnings screen to send it to your bank.`,
            };
        }
    }
    if (has(userText, "how many vehicles", "my vehicles", "my fleet")) {
        return {
            kind: "reply",
            topic: "my_vehicles",
            reply: "You can see every vehicle you've registered, and its approval status, under " +
                "Fleet & Vehicles. At least one APPROVED vehicle is required before you can go online. " +
                "If a vehicle is still showing Pending Verification, our team is still reviewing it.",
        };
    }
    if (has(userText, "am i verified", "my verification status", "is my account verified", "kyc status")) {
        return {
            kind: "reply",
            topic: "my_verification",
            reply: "Your verification status is shown on your profile. Open Profile and look at the " +
                "verification banner: Pending means our team is still reviewing it, Verified means " +
                "you're all set, and Rejected comes with a reason you can act on and resubmit.",
        };
    }
    // 4. Knowledge articles.
    const article = bestArticle(text);
    if (article) {
        const reply = article.dynamicAnswer
            ? await article.dynamicAnswer()
            : article.answer;
        return { kind: "reply", topic: article.topic, reply };
    }
    // 5. Nothing matched. Be honest and hand over rather than bluff.
    return {
        kind: "escalate",
        reason: "no-match",
    };
}
/** The handover line posted when escalating. */
exports.HANDOVER_TEXT = "Hold on — I'm connecting you to a human support agent now. " +
    "Please stay in this chat and they'll be with you shortly.";
//# sourceMappingURL=supportBrain.js.map