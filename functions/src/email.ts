import * as admin from "firebase-admin";
import * as crypto from "crypto";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { Resend } from "resend";

const db = () => admin.firestore();

/** Sender address strictly set to Seletion Tech domain */
const SENDER_EMAIL = "Seletion Tech <noreply@sesetech.com>";

/** 5 wrong OTP tries lock the OTP verification for 15 minutes. */
const OTP_MAX_FAILS = 5;
const OTP_LOCK_MS = 15 * 60 * 1000;
const OTP_TTL_MS = 10 * 60 * 1000; // 10 minutes

function sha256Hex(data: string): string {
  return crypto.createHash("sha256").update(data, "utf8").digest("hex");
}

function randomSaltHex(): string {
  return crypto.randomBytes(16).toString("hex");
}

function hashOtp(otp: string, salt: string): string {
  return sha256Hex(`${salt}:${otp}`);
}

/**
 * Dynamically fetches the Resend API key from Firestore (`/system_config/remote_keys`).
 * Falls back to environment variables (`process.env.RESEND_API_KEY`) if unconfigured in Firestore.
 */
export async function getResendApiKey(): Promise<string> {
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
          const raw = data.resendApiKey ?? data.resend_api_key ?? data.resendKey;
          if (typeof raw === "string" && raw.trim()) {
            return raw.trim();
          }
        }
      }
    } catch (e) {
      console.error(`getResendApiKey: Error reading ${path}:`, e);
    }
  }

  throw new HttpsError(
    "failed-precondition",
    "RESEND_NOT_CONFIGURED: No Resend API key found in System Config or environment."
  );
}

export interface SendEmailOptions {
  to: string | string[];
  subject: string;
  html?: string;
  text?: string;
}

/**
 * Core reusable email dispatch helper using official Resend SDK / API.
 */
export async function sendEmailViaResend(options: SendEmailOptions) {
  const apiKey = await getResendApiKey();
  const resend = new Resend(apiKey);

  const recipients = Array.isArray(options.to)
    ? options.to.map((e) => e.trim()).filter(Boolean)
    : [options.to.trim()];

  if (recipients.length === 0) {
    throw new HttpsError("invalid-argument", "At least one recipient email ('to') is required.");
  }

  const payload = {
    from: SENDER_EMAIL,
    to: recipients,
    subject: options.subject,
    html: options.html ?? (options.text ? `<p>${options.text}</p>` : "<p></p>"),
    text: options.text,
  };

  const { data, error } = await resend.emails.send(payload);

  if (error) {
    console.error("sendEmailViaResend Error:", error);
    throw new HttpsError("internal", `Resend email dispatch failed: ${error.message}`);
  }

  return data;
}

interface TransactionalEmailData {
  to?: string | string[];
  subject?: string;
  html?: string;
  text?: string;
}

/**
 * Callable: Send general transactional emails from authenticated client or staff apps.
 */
export const sendTransactionalEmail = onCall<TransactionalEmailData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required to send emails.");
  }

  const { to, subject, html, text } = request.data ?? {};
  if (!to || !subject) {
    throw new HttpsError("invalid-argument", "'to' and 'subject' fields are required.");
  }

  const result = await sendEmailViaResend({
    to,
    subject,
    html,
    text,
  });

  return { ok: true, id: result?.id };
});

interface SendEmailOtpData {
  email?: string;
  purpose?: string;
}

/**
 * Callable: Mints a 6-digit OTP code, saves a salted SHA-256 hash in Firestore,
 * and delivers the code via Resend to the user's email address.
 */
export const sendEmailOtp = onCall<SendEmailOtpData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required to request OTP.");
  }
  const uid = request.auth.uid;
  const email = (request.data?.email ?? request.auth.token.email ?? "").trim().toLowerCase();

  if (!email || !email.includes("@")) {
    throw new HttpsError("invalid-argument", "Valid email address is required.");
  }

  const purpose = request.data?.purpose ?? "verification";

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

interface VerifyEmailOtpData {
  email?: string;
  otp?: string;
}

/**
 * Callable: Verifies a 6-digit email OTP against the stored salted hash with lockout.
 */
export const verifyEmailOtp = onCall<VerifyEmailOtpData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }
  const uid = request.auth.uid;
  const email = (request.data?.email ?? request.auth.token.email ?? "").trim().toLowerCase();
  const otp = String(request.data?.otp ?? "").trim();

  if (!/^\d{6}$/.test(otp)) {
    throw new HttpsError("invalid-argument", "OTP must be exactly 6 digits.");
  }

  const otpRef = db().collection("users").doc(uid).collection("private").doc("email_otp");
  const snap = await otpRef.get();

  if (!snap.exists) {
    throw new HttpsError("not-found", "No OTP request found. Please request a new code.");
  }

  const data = snap.data() ?? {};
  const now = Date.now();

  if (data.lockedUntilMs && data.lockedUntilMs > now) {
    throw new HttpsError("resource-exhausted", "Too many wrong attempts. Please wait 15 minutes.");
  }

  if (data.expiresAtMs && data.expiresAtMs < now) {
    throw new HttpsError("deadline-exceeded", "OTP has expired. Please request a new code.");
  }

  const candidate = hashOtp(otp, data.otpSalt ?? "");
  const expected = String(data.otpHash ?? "");

  const ok =
    candidate.length === expected.length &&
    crypto.timingSafeEqual(Buffer.from(candidate, "utf8"), Buffer.from(expected, "utf8"));

  if (!ok) {
    const fails = (data.failCount ?? 0) + 1;
    const lockedUntilMs = fails >= OTP_MAX_FAILS ? now + OTP_LOCK_MS : 0;
    await otpRef.set({ failCount: fails, lockedUntilMs }, { merge: true });
    throw new HttpsError("unauthenticated", "Incorrect OTP code. Please check and try again.");
  }

  // Clear OTP record after successful verification
  await otpRef.delete();
  if (email) {
    try {
      await db().collection("email_otps").doc(email).delete();
    } catch (_) {}
  }

  return { ok: true, verified: true };
});
