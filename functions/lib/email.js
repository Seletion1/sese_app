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
exports.verifyEmailOtp = exports.sendEmailOtp = exports.sendTransactionalEmail = void 0;
exports.getResendApiKey = getResendApiKey;
exports.sendEmailViaResend = sendEmailViaResend;
const admin = __importStar(require("firebase-admin"));
const crypto = __importStar(require("crypto"));
const https_1 = require("firebase-functions/v2/https");
const resend_1 = require("resend");
const db = () => admin.firestore();
/** Sender address strictly set to Seletion Tech domain */
const SENDER_EMAIL = "Seletion Tech <noreply@sesetech.com>";
/** 5 wrong OTP tries lock the OTP verification for 15 minutes. */
const OTP_MAX_FAILS = 5;
const OTP_LOCK_MS = 15 * 60 * 1000;
const OTP_TTL_MS = 10 * 60 * 1000; // 10 minutes
function sha256Hex(data) {
    return crypto.createHash("sha256").update(data, "utf8").digest("hex");
}
function randomSaltHex() {
    return crypto.randomBytes(16).toString("hex");
}
function hashOtp(otp, salt) {
    return sha256Hex(`${salt}:${otp}`);
}
/**
 * Dynamically fetches the Resend API key from Firestore (`/system_config/remote_keys`).
 * Falls back to environment variables (`process.env.RESEND_API_KEY`) if unconfigured in Firestore.
 */
async function getResendApiKey() {
    var _a, _b;
    const envKey = process.env.RESEND_API_KEY;
    if (envKey && envKey.trim()) {
        return envKey.trim();
    }
    const docPaths = [
        "system_config/remote_keys",
        "system_config/email",
        "system_config/global_default",
        "system_configs/global_default",
    ];
    for (const path of docPaths) {
        try {
            const snap = await db().doc(path).get();
            if (snap.exists) {
                const data = snap.data();
                if (data) {
                    const raw = (_b = (_a = data.resendApiKey) !== null && _a !== void 0 ? _a : data.resend_api_key) !== null && _b !== void 0 ? _b : data.resendKey;
                    if (typeof raw === "string" && raw.trim()) {
                        return raw.trim();
                    }
                }
            }
        }
        catch (e) {
            console.error(`getResendApiKey: Error reading ${path}:`, e);
        }
    }
    throw new https_1.HttpsError("failed-precondition", "RESEND_NOT_CONFIGURED: No Resend API key found in System Config or environment.");
}
/**
 * Core reusable email dispatch helper using official Resend SDK / API.
 */
async function sendEmailViaResend(options) {
    var _a;
    const apiKey = await getResendApiKey();
    const resend = new resend_1.Resend(apiKey);
    const recipients = Array.isArray(options.to)
        ? options.to.map((e) => e.trim()).filter(Boolean)
        : [options.to.trim()];
    if (recipients.length === 0) {
        throw new https_1.HttpsError("invalid-argument", "At least one recipient email ('to') is required.");
    }
    const payload = {
        from: SENDER_EMAIL,
        to: recipients,
        subject: options.subject,
        html: (_a = options.html) !== null && _a !== void 0 ? _a : (options.text ? `<p>${options.text}</p>` : "<p></p>"),
        text: options.text,
    };
    const { data, error } = await resend.emails.send(payload);
    if (error) {
        console.error("sendEmailViaResend Error:", error);
        throw new https_1.HttpsError("internal", `Resend email dispatch failed: ${error.message}`);
    }
    return data;
}
/**
 * Callable: Send general transactional emails from authenticated client or staff apps.
 */
exports.sendTransactionalEmail = (0, https_1.onCall)(async (request) => {
    var _a;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required to send emails.");
    }
    const { to, subject, html, text } = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    if (!to || !subject) {
        throw new https_1.HttpsError("invalid-argument", "'to' and 'subject' fields are required.");
    }
    const result = await sendEmailViaResend({
        to,
        subject,
        html,
        text,
    });
    return { ok: true, id: result === null || result === void 0 ? void 0 : result.id };
});
/**
 * Callable: Mints a 6-digit OTP code, saves a salted SHA-256 hash in Firestore,
 * and delivers the code via Resend to the user's email address.
 */
exports.sendEmailOtp = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required to request OTP.");
    }
    const uid = request.auth.uid;
    const email = ((_c = (_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.email) !== null && _b !== void 0 ? _b : request.auth.token.email) !== null && _c !== void 0 ? _c : "").trim().toLowerCase();
    if (!email || !email.includes("@")) {
        throw new https_1.HttpsError("invalid-argument", "Valid email address is required.");
    }
    const purpose = (_e = (_d = request.data) === null || _d === void 0 ? void 0 : _d.purpose) !== null && _e !== void 0 ? _e : "verification";
    // Generate crypto-secure 6-digit OTP
    const otpCode = Math.floor(100000 + crypto.randomInt(900000)).toString();
    const salt = randomSaltHex();
    const hash = hashOtp(otpCode, salt);
    const now = Date.now();
    const expiresAtMs = now + OTP_TTL_MS;
    // Store salted OTP record under `users/{uid}/private/auth` and `email_otps/{email}`
    const otpDoc = {
        email,
        purpose,
        otpHash: hash,
        otpSalt: salt,
        failCount: 0,
        lockedUntilMs: 0,
        expiresAtMs,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    await Promise.all([
        db().collection("users").doc(uid).collection("private").doc("email_otp").set(otpDoc, { merge: true }),
        db().collection("email_otps").doc(email).set(otpDoc, { merge: true }),
    ]);
    // Render responsive HTML email template
    const htmlBody = `
    <div style="font-family: Arial, sans-serif; max-width: 500px; margin: 0 auto; padding: 24px; border: 1px solid #e0e0e0; border-radius: 12px; background-color: #ffffff;">
      <div style="text-align: center; margin-bottom: 20px;">
        <h2 style="color: #FFB800; margin: 0;">Seletion Tech</h2>
        <p style="color: #666666; font-size: 14px; margin-top: 4px;">Security Verification Code</p>
      </div>
      <p style="font-size: 15px; color: #333333;">Your verification code for <strong>${purpose}</strong> is:</p>
      <div style="text-align: center; margin: 24px 0;">
        <span style="font-size: 32px; font-weight: bold; letter-spacing: 6px; color: #111111; background: #f8f9fa; padding: 12px 24px; border-radius: 8px; border: 1px dashed #FFB800; display: inline-block;">${otpCode}</span>
      </div>
      <p style="font-size: 13px; color: #777777;">This code is valid for <strong>10 minutes</strong>. Do not share this code with anyone.</p>
      <hr style="border: none; border-top: 1px solid #eeeeee; margin: 20px 0;" />
      <p style="font-size: 11px; color: #aaaaaa; text-align: center;">Sent by Seletion Tech &bull; noreply@sesetech.com</p>
    </div>
  `;
    await sendEmailViaResend({
        to: email,
        subject: `${otpCode} is your Seletion Tech verification code`,
        html: htmlBody,
        text: `Your Seletion Tech verification code is: ${otpCode}. Valid for 10 minutes.`,
    });
    return { ok: true, expiresAtMs };
});
/**
 * Callable: Verifies a 6-digit email OTP against the stored salted hash with lockout.
 */
exports.verifyEmailOtp = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
    const uid = request.auth.uid;
    const email = ((_c = (_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.email) !== null && _b !== void 0 ? _b : request.auth.token.email) !== null && _c !== void 0 ? _c : "").trim().toLowerCase();
    const otp = String((_e = (_d = request.data) === null || _d === void 0 ? void 0 : _d.otp) !== null && _e !== void 0 ? _e : "").trim();
    if (!/^\d{6}$/.test(otp)) {
        throw new https_1.HttpsError("invalid-argument", "OTP must be exactly 6 digits.");
    }
    const otpRef = db().collection("users").doc(uid).collection("private").doc("email_otp");
    const snap = await otpRef.get();
    if (!snap.exists) {
        throw new https_1.HttpsError("not-found", "No OTP request found. Please request a new code.");
    }
    const data = (_f = snap.data()) !== null && _f !== void 0 ? _f : {};
    const now = Date.now();
    if (data.lockedUntilMs && data.lockedUntilMs > now) {
        throw new https_1.HttpsError("resource-exhausted", "Too many wrong attempts. Please wait 15 minutes.");
    }
    if (data.expiresAtMs && data.expiresAtMs < now) {
        throw new https_1.HttpsError("deadline-exceeded", "OTP has expired. Please request a new code.");
    }
    const candidate = hashOtp(otp, (_g = data.otpSalt) !== null && _g !== void 0 ? _g : "");
    const expected = String((_h = data.otpHash) !== null && _h !== void 0 ? _h : "");
    const ok = candidate.length === expected.length &&
        crypto.timingSafeEqual(Buffer.from(candidate, "utf8"), Buffer.from(expected, "utf8"));
    if (!ok) {
        const fails = ((_j = data.failCount) !== null && _j !== void 0 ? _j : 0) + 1;
        const lockedUntilMs = fails >= OTP_MAX_FAILS ? now + OTP_LOCK_MS : 0;
        await otpRef.set({ failCount: fails, lockedUntilMs }, { merge: true });
        throw new https_1.HttpsError("unauthenticated", "Incorrect OTP code. Please check and try again.");
    }
    // Clear OTP record after successful verification
    await otpRef.delete();
    if (email) {
        try {
            await db().collection("email_otps").doc(email).delete();
        }
        catch (_) { }
    }
    return { ok: true, verified: true };
});
//# sourceMappingURL=email.js.map