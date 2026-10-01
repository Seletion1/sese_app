"use strict";
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
exports.onSupportMessageCreated = exports.onAgentReplied = void 0;
exports.messageNeedsHumanHeuristic = messageNeedsHumanHeuristic;
exports.parseGeminiReply = parseGeminiReply;
const admin = __importStar(require("firebase-admin"));
const firestore_1 = require("firebase-functions/v2/firestore");
const supportBrain_1 = require("./supportBrain");
/**
 * SeSe Support Chat — AI Level-1 triage and live-agent escalation.
 *
 * Trigger: a `senderType == 'user'` write to
 * `support_chats/{chatId}/messages/{messageId}` while the chat
 * `status` is `'ai_active'`.
 *
 * Flow:
 *  - `supportBrain.respondTo` (deterministic, NO external API) classifies the
 *    message and either answers from the curated knowledge base / live
 *    Firestore state, or returns "escalate" with a reason.
 *  - Answer → AI message (`senderType: 'ai'`, `senderId: 'ai_assistant'`,
 *    plus a `topic` so the hub can see what the bot thought it was about).
 *  - Escalate → chat flips to `pending_agent`, a handover message posts
 *    (safety issues get safety-specific wording), an in-app notification is
 *    written for the user, and a high-priority FCM push fires to the
 *    `admin_support_alerts` topic so sese_hub agents are dispatched.
 *
 * An LLM is OPTIONAL and OFF by default. Set `SUPPORT_BOT_USE_LLM=true` and
 * provision `GEMINI_API_KEY` to consult a model for messages the engine
 * declines. With no key the assistant is fully functional — that is the point
 * of `supportBrain`.
 */
const db = () => admin.firestore();
const GEMINI_MODEL = "gemini-1.5-flash";
const GEMINI_URL = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;
/**
 * Legacy keyword escalation list.
 *
 * The engine in `supportBrain.ts` supersedes this and is always consulted
 * first; this remains as a cheap pre-filter so obvious escalations skip the
 * Firestore read the engine would otherwise do.
 */
const ESCALATION_KEYWORDS = [
    "accident", "crash", "injur", "hospital", "police", "stole", "stolen",
    "theft", "fraud", "scam", "blocked", "suspend", "banned", "talk to human",
    "speak to support", "human agent", "real person", "admin", "support agent",
    "money missing", "didn't receive", "not received", "payout", "lawyer",
    "court", "connect to agent", "representative",
];
function messageNeedsHumanHeuristic(text) {
    const lower = text.toLowerCase();
    return ESCALATION_KEYWORDS.some((k) => lower.includes(k));
}
function parseGeminiReply(raw) {
    try {
        const cleaned = raw
            .replace(/```json\s*/gi, "")
            .replace(/```/g, "")
            .trim();
        const start = cleaned.indexOf("{");
        const end = cleaned.lastIndexOf("}");
        if (start < 0 || end <= start)
            return null;
        const parsed = JSON.parse(cleaned.slice(start, end + 1));
        if (typeof parsed.reply !== "string" || !parsed.reply.trim())
            return null;
        return { needsHuman: parsed.needsHuman === true, reply: parsed.reply.trim() };
    }
    catch (_a) {
        return null;
    }
}
/**
 * Optional LLM fallback persona. Only used when `SUPPORT_BOT_USE_LLM=true` AND
 * `GEMINI_API_KEY` is provisioned — both off by default.
 *
 * The live knowledge the assistant is expected to know lives in
 * `supportBrain.ts` (product facts) and the ARTICLES table (KB). This prompt
 * is a thin persona wrapper so a model, if ever enabled, is told to defer to
 * those facts rather than invent its own.
 */
const SYSTEM_INSTRUCTION = `You are the SeSe Virtual Support Assistant for a ride-hailing and delivery platform (Nigeria). Be concise, polite, and helpful. Reply in plain language, matching the user's language.

Authoritative product facts are in the conversation's earlier AI messages. Never invent a fare, fee, threshold, or policy — if it is not stated there, say you will connect the user to a support agent.

ESCALATE (needsHuman: true) when the user asks for a human, or the issue involves accidents, injury, crime, theft, money disputes, refunds, blocked/suspended accounts, or anything you cannot answer from the stated facts.

REPLY FORMAT: strict JSON only, no markdown fences:
{"needsHuman": <true|false>, "reply": "<1-3 sentence user-facing reply>"}`;
async function askGemini(userText, history) {
    var _a, _b, _c, _d;
    const apiKey = process.env.GEMINI_API_KEY;
    if (!apiKey)
        return null;
    const contents = [
        ...history.slice(-8).map((text, i) => ({
            role: i % 2 === 0 ? "user" : "model",
            parts: [{ text }],
        })),
        { role: "user", parts: [{ text: userText }] },
    ];
    const res = await fetch(`${GEMINI_URL}?key=${encodeURIComponent(apiKey)}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            system_instruction: { parts: [{ text: SYSTEM_INSTRUCTION }] },
            contents,
            generationConfig: { temperature: 0.4, maxOutputTokens: 300 },
        }),
    });
    if (!res.ok) {
        console.warn(`supportBot: Gemini HTTP ${res.status}`);
        return null;
    }
    const json = (await res.json());
    const text = (_d = (_c = (_b = (_a = json.candidates) === null || _a === void 0 ? void 0 : _a[0]) === null || _b === void 0 ? void 0 : _b.content) === null || _c === void 0 ? void 0 : _c.parts) === null || _d === void 0 ? void 0 : _d.map((p) => { var _a; return (_a = p.text) !== null && _a !== void 0 ? _a : ""; }).join("").trim();
    if (!text)
        return null;
    return parseGeminiReply(text);
}
async function postAiMessage(chatId, text, topic) {
    const chatRef = db().collection("support_chats").doc(chatId);
    const batch = db().batch();
    const msgRef = chatRef.collection("messages").doc();
    batch.set(msgRef, Object.assign(Object.assign({ senderId: "ai_assistant", senderType: "ai", text, 
        // Absent for plain text; the rules allow type in ['text','image'] and
        // never allow an audio type.
        type: "text" }, (topic ? { topic } : {})), { timestamp: admin.firestore.FieldValue.serverTimestamp() }));
    batch.update(chatRef, {
        lastMessage: text,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await batch.commit();
}
async function escalateChat(chatId, reason, reasonDetail) {
    var _a, _b;
    const chatRef = db().collection("support_chats").doc(chatId);
    const batch = db().batch();
    const msgRef = chatRef.collection("messages").doc();
    // A safety escalation gets its own wording: the user is told to contact
    // emergency services first, not merely that an agent is coming.
    const text = reason === "safety" ? supportBrain_1.SAFETY_REPLY : supportBrain_1.HANDOVER_TEXT;
    batch.set(msgRef, {
        senderId: "ai_assistant",
        senderType: "ai",
        text,
        type: "text",
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
    });
    batch.update(chatRef, {
        status: "pending_agent",
        escalateReason: reason,
        escalateDetail: reasonDetail !== null && reasonDetail !== void 0 ? reasonDetail : null,
        escalatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        lastMessage: text,
    });
    await batch.commit();
    // Notify the user in-app as well, so the escalation is visible even if the
    // app is backgrounded when the bot hands over.
    let userId = "";
    try {
        const snap = await db().collection("support_chats").doc(chatId).get();
        userId = String((_b = (_a = snap.data()) === null || _a === void 0 ? void 0 : _a.userId) !== null && _b !== void 0 ? _b : "");
    }
    catch (_c) {
        // Non-fatal: the FCM broadcast below still fires.
    }
    if (userId) {
        try {
            await db()
                .collection("users")
                .doc(userId)
                .collection("notifications")
                .add({
                title: reason === "safety"
                    ? "Connecting you to support now"
                    : "Support agent requested",
                body: reasonDetail !== null && reasonDetail !== void 0 ? reasonDetail : "A support agent is joining your chat. Please stay in the chat.",
                chatId,
                type: "support_escalated",
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        }
        catch (e) {
            console.warn(`supportBot: escalation in-app write failed: ${e}`);
        }
    }
    try {
        await admin.messaging().send({
            topic: "admin_support_alerts",
            notification: {
                title: reason === "safety" ? "URGENT: Safety escalation" : "Support Escalation",
                body: `Chat session ${chatId} needs a human agent (${reason}).`,
            },
            // High priority so the agent alert breaks through Doze.
            android: {
                priority: "high",
                notification: { sound: "sese_alert_siren", channelId: "support_alerts" },
            },
            apns: {
                payload: { aps: { sound: "default", "interruption-level": "time-sensitive" } },
            },
            data: { chatId, reason },
        });
    }
    catch (e) {
        console.warn(`supportBot: FCM escalation push failed: ${e}`);
    }
}
/**
 * Trigger: a hub AGENT replies in `support_chats/{chatId}/messages` →
 * notify the ticket owner (in-app + FCM) so they are not left waiting.
 *
 * Replaces `onSupportTicketReply`, which watched `support_tickets/{ticketId}` —
 * a legacy collection with no writers left, so it never fired and was dead
 * code rather than a working notification.
 *
 * Skips `ai_active` sessions: an agent does not hold those, and this must not
 * double-fire with the AI path.
 */
exports.onAgentReplied = (0, firestore_1.onDocumentCreated)("support_chats/{chatId}/messages/{messageId}", async (event) => {
    var _a, _b, _c, _d, _e, _f;
    const msg = (_a = event.data) === null || _a === void 0 ? void 0 : _a.data();
    if (!msg)
        return;
    if (String((_c = (_b = msg.senderType) !== null && _b !== void 0 ? _b : msg.sender) !== null && _c !== void 0 ? _c : "") !== "agent")
        return;
    const chatId = event.params.chatId;
    let chat;
    try {
        chat = (await db().collection("support_chats").doc(chatId).get()).data();
    }
    catch (_g) {
        return;
    }
    if (!chat)
        return;
    // The AI owns ai_active sessions; agents only join after escalation.
    if (chat["status"] === "ai_active")
        return;
    const userId = String((_d = chat["userId"]) !== null && _d !== void 0 ? _d : "");
    if (!userId)
        return;
    const text = String((_e = msg["text"]) !== null && _e !== void 0 ? _e : "").trim();
    const preview = text.length > 90 ? `${text.slice(0, 90)}…` : text;
    const body = preview ||
        (String((_f = msg["type"]) !== null && _f !== void 0 ? _f : "") === "image"
            ? "A support agent sent you a photo."
            : "A support agent replied to your ticket.");
    try {
        await db()
            .collection("users")
            .doc(userId)
            .collection("notifications")
            .add({
            title: "Support replied",
            body,
            chatId,
            type: "support_reply",
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    catch (e) {
        console.warn(`onAgentReplied: in-app write failed: ${e}`);
    }
    try {
        await admin.messaging().send({
            topic: `user_${userId}`,
            notification: { title: "Support replied", body },
            android: {
                priority: "high",
                notification: { sound: "sese_alert_chime" },
            },
            apns: { payload: { aps: { sound: "default" } } },
            data: { type: "support_reply", chatId },
        });
    }
    catch (e) {
        console.warn(`onAgentReplied: FCM send failed: ${e}`);
    }
});
/**
 * Primary trigger: answers user messages in `support_chats/{chatId}/messages/{messageId}`
 * while session status is `ai_active`.
 */
exports.onSupportMessageCreated = (0, firestore_1.onDocumentCreated)("support_chats/{chatId}/messages/{messageId}", async (event) => {
    var _a, _b, _c, _d, _e;
    const msg = (_a = event.data) === null || _a === void 0 ? void 0 : _a.data();
    if (!msg)
        return;
    // Check senderType (new) or sender (legacy)
    const senderType = (_b = msg["senderType"]) !== null && _b !== void 0 ? _b : msg["sender"];
    if (senderType !== "user")
        return;
    const chatId = event.params.chatId;
    const chatSnap = await db()
        .collection("support_chats")
        .doc(chatId)
        .get();
    if (!chatSnap.exists)
        return;
    const chatData = chatSnap.data();
    if (chatData["status"] !== "ai_active")
        return;
    // Image-only messages (a photo of a damaged parcel, a payment receipt)
    // carry no text to reason about, so acknowledge and invite detail rather
    // than escalating immediately — the user is mid-escalation, not in danger.
    const msgType = String((_c = msg["type"]) !== null && _c !== void 0 ? _c : "text");
    const userText = String((_d = msg["text"]) !== null && _d !== void 0 ? _d : "").trim();
    const hasImage = typeof msg["imageUrl"] === "string" && msg["imageUrl"].length > 0;
    if (!userText) {
        if (hasImage) {
            await postAiMessage(chatId, "Thanks — I can see the image you've sent. An agent will take a closer look at it. " +
                "In the meantime, could you tell me briefly what the photo shows?", "image_only");
            return;
        }
        return;
    }
    // Recent thread context for the model / follow-up resolution.
    let history = [];
    try {
        const recent = await db()
            .collection("support_chats")
            .doc(chatId)
            .collection("messages")
            .orderBy("timestamp", "desc")
            .limit(9)
            .get();
        history = recent.docs
            .map((d) => { var _a; return String((_a = d.data()["text"]) !== null && _a !== void 0 ? _a : ""); })
            .filter((t) => t.length > 0)
            .reverse();
    }
    catch (e) {
        console.warn(`supportBot: history read failed: ${e}`);
    }
    // ── Primary path: the deterministic engine. No API required. ──────────
    const userId = String((_e = chatData["userId"]) !== null && _e !== void 0 ? _e : "");
    const userRole = chatData["userRole"] === "driver" ? "driver" : "customer";
    let brainVerdict = null;
    try {
        brainVerdict = await (0, supportBrain_1.respondTo)(userText, {
            userId,
            userRole,
            history,
        });
    }
    catch (e) {
        console.warn(`supportBot: brain failed, will escalate: ${e}`);
    }
    if (brainVerdict) {
        if (brainVerdict.kind === "escalate") {
            await escalateChat(chatId, brainVerdict.reason, msgType);
            return;
        }
        await postAiMessage(chatId, brainVerdict.reply, brainVerdict.topic);
        return;
    }
    // ── Optional path: an LLM, only if explicitly enabled AND configured. ──
    // Off by default. When it is off (or the key is missing) the engine above
    // has already answered, so this block is unreachable in the default setup.
    if (process.env.SUPPORT_BOT_USE_LLM === "true" && process.env.GEMINI_API_KEY) {
        // Explicit escalation keywords skip the model call.
        if (messageNeedsHumanHeuristic(userText)) {
            await escalateChat(chatId, "keyword");
            return;
        }
        let verdict = null;
        try {
            verdict = await askGemini(userText, history);
        }
        catch (e) {
            console.warn(`supportBot: Gemini call failed: ${e}`);
        }
        if (verdict) {
            if (verdict.needsHuman || messageNeedsHumanHeuristic(verdict.reply)) {
                await escalateChat(chatId, "model");
                return;
            }
            await postAiMessage(chatId, verdict.reply, "llm");
            return;
        }
    }
    // The engine could not answer and no LLM is configured. Hand over
    // honestly rather than leaving the user staring at silence.
    await escalateChat(chatId, "no-match", "I wasn't able to answer that automatically, so I'm bringing in a support agent.");
});
//# sourceMappingURL=supportBot.js.map