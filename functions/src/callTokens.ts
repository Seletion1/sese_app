import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import * as crypto from "crypto";

function db(): admin.firestore.Firestore {
  return admin.firestore();
}

/**
 * Generates a short-lived ZegoCloud authentication token server-side.
 * Uses the secret AppSign stored securely in `/system_config/call_secrets`.
 */
export const getZegoToken = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated to request Zego token.");
  }

  const userId = request.auth.uid;
  const roomId = (request.data?.roomId as string) || `room_${userId}`;
  const rawDuration = Number(request.data?.effectiveDurationSeconds || 3600);
  const effectiveDurationSeconds = Math.min(Math.max(isNaN(rawDuration) ? 3600 : rawDuration, 300), 86400);

  // Fetch appId from system_settings/calling and AppSign from system_config/call_secrets
  const [callingSnap, secretsSnap] = await Promise.all([
    db().collection("system_settings").doc("calling").get(),
    db().collection("system_config").doc("call_secrets").get(),
  ]);

  const appId = callingSnap.data()?.zegoAppId;
  const zegoAppSign = secretsSnap.data()?.zegoAppSign;

  if (!appId || !zegoAppSign || typeof zegoAppSign !== "string" || zegoAppSign.length < 32) {
    throw new HttpsError(
      "failed-precondition",
      "ZegoCloud credentials are not fully configured on the server."
    );
  }

  const now = Math.floor(Date.now() / 1000);
  const expiresAt = now + effectiveDurationSeconds;

  // Generate Zego V2 token payload using HMAC SHA-256
  const nonce = crypto.randomBytes(8).readBigInt64BE(0).toString();
  const payload = {
    app_id: appId,
    user_id: userId,
    room_id: roomId,
    nonce: nonce,
    ctime: now,
    expire: expiresAt,
  };

  const payloadString = JSON.stringify(payload);
  const hmac = crypto.createHmac("sha256", zegoAppSign);
  hmac.update(payloadString);
  const signature = hmac.digest("hex");

  const token = Buffer.from(
    JSON.stringify({
      payload: payloadString,
      signature: signature,
    })
  ).toString("base64");

  return {
    appId,
    userId,
    roomId,
    token,
    expiresAt,
  };
});
