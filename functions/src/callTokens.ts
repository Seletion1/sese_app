import * as admin from "firebase-admin";
import { HttpsError } from "firebase-functions/v2/https";
import { onDocumentCreated, onDocumentUpdated } from "firebase-functions/v2/firestore";
import { RtcTokenBuilder, RtcRole } from "agora-token";
import { enforceAppCheck, guardedOnCall } from "./accountGuard";

function db(): admin.firestore.Firestore {
  return admin.firestore();
}

/**
 * Gets the current UTC month string in `YYYY-MM` format.
 */
function getUtcMonthKey(): string {
  const now = new Date();
  const year = now.getUTCFullYear();
  const month = String(now.getUTCMonth() + 1).padStart(2, "0");
  return `${year}-${month}`;
}

/**
 * Generates a short-lived Agora RTC Access Token server-side.
 *
 * Security:
 * - Credentials (`agoraAppCertificate`) are read exclusively from `/system_config/call_secrets`
 *   and are NEVER returned to or hardcoded inside client mobile apps.
 * - Enforces Firebase App Check and user authentication.
 * - Evaluates automatic failover: if monthly Agora minutes reach the threshold (default: 9,900/10,000 mins),
 *   signals the client to failover to native WebRTC.
 */
export const getAgoraToken = guardedOnCall(async (request) => {
  enforceAppCheck(request);

  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated to request Agora token.");
  }

  const userId = request.auth.uid;
  const channelName = (request.data?.channelName as string) || (request.data?.roomId as string) || `channel_${userId}`;
  const rawDuration = Number(request.data?.effectiveDurationSeconds || 3600);
  const effectiveDurationSeconds = Math.min(Math.max(isNaN(rawDuration) ? 3600 : rawDuration, 300), 86400);

  const monthKey = getUtcMonthKey();

  // Fetch appId from system_settings/calling, Primary Certificate from system_config/call_secrets, and usage metrics
  const [callingSnap, secretsSnap, usageSnap] = await Promise.all([
    db().collection("system_settings").doc("calling").get(),
    db().collection("system_config").doc("call_secrets").get(),
    db().collection("system_config").doc("call_usage").get(),
  ]);

  const callingData = callingSnap.data() || {};
  const secretsData = secretsSnap.data() || {};
  const usageData = usageSnap.data() || {};

  const agoraAppId = callingData.agoraAppId || callingData.appId || secretsData.agoraAppId;
  const agoraAppCertificate = secretsData.agoraPrimaryCertificate || secretsData.agoraAppCertificate || secretsData.appCertificate;

  const routingMode = (callingData.routingMode || "smartFallback").toString().toLowerCase();
  const agoraAutoFailoverThresholdMinutes = Number(callingData.agoraAutoFailoverThresholdMinutes || 9900);
  const agoraMonthlyFreeMinutesCap = Number(callingData.agoraMonthlyFreeMinutesCap || 10000);

  // Read current month's usage
  const lastMonthKey = usageData.lastMonthKey || monthKey;
  const agoraMinutesThisMonth = lastMonthKey === monthKey ? Number(usageData.agoraMinutesThisMonth || 0) : 0;

  const isAutoMode = routingMode === "smartfallback" || routingMode === "auto" || routingMode === "smart_fallback";

  // Check 1: Automatic minute-usage threshold failover
  if (isAutoMode && agoraMinutesThisMonth >= agoraAutoFailoverThresholdMinutes) {
    return {
      failover: true,
      provider: "webrtc",
      reason: `Agora free monthly limit reached (${agoraMinutesThisMonth}/${agoraMonthlyFreeMinutesCap} mins). Automatic failover to WebRTC engaged.`,
      agoraMinutesThisMonth,
      agoraAutoFailoverThresholdMinutes,
      agoraMonthlyFreeMinutesCap,
    };
  }

  // Check 2: Credential check
  if (!agoraAppId || typeof agoraAppId !== "string" || agoraAppId.trim().length === 0 ||
      !agoraAppCertificate || typeof agoraAppCertificate !== "string" || agoraAppCertificate.trim().length < 16) {
    if (isAutoMode) {
      return {
        failover: true,
        provider: "webrtc",
        reason: "Agora credentials are not fully configured on the server. Automatic fallback to WebRTC engaged.",
        agoraMinutesThisMonth,
        agoraAutoFailoverThresholdMinutes,
        agoraMonthlyFreeMinutesCap,
      };
    }
    throw new HttpsError(
      "failed-precondition",
      "Agora credentials (App ID & Primary Certificate) are not configured on the server."
    );
  }

  const now = Math.floor(Date.now() / 1000);
  const privilegeExpiredTs = now + effectiveDurationSeconds;

  // Build Agora RTC token v007 using user account string (UID)
  const token = RtcTokenBuilder.buildTokenWithUserAccount(
    agoraAppId.trim(),
    agoraAppCertificate.trim(),
    channelName.trim(),
    userId,
    RtcRole.PUBLISHER,
    privilegeExpiredTs,
    privilegeExpiredTs
  );

  return {
    failover: false,
    provider: "agora",
    appId: agoraAppId.trim(),
    channelName: channelName.trim(),
    userId,
    token,
    expiresAt: privilegeExpiredTs,
    agoraMinutesThisMonth,
    agoraAutoFailoverThresholdMinutes,
    agoraMonthlyFreeMinutesCap,
  };
});

/**
 * Records completed call minutes and updates global usage counters for the current month.
 */
export const recordCallDuration = guardedOnCall(async (request) => {
  enforceAppCheck(request);

  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated to record call duration.");
  }

  const durationSeconds = Math.max(0, Number(request.data?.durationSeconds || 0));
  const provider = (request.data?.provider || "agora").toString().toLowerCase();
  const callId = (request.data?.callId as string) || "unknown";

  if (durationSeconds <= 0) {
    return { ok: true, durationMinutes: 0 };
  }

  const durationMinutes = Math.ceil(durationSeconds / 60);
  const monthKey = getUtcMonthKey();
  const usageRef = db().collection("system_config").doc("call_usage");

  await db().runTransaction(async (tx) => {
    const snap = await tx.get(usageRef);
    const data = snap.data() || {};
    const lastMonth = data.lastMonthKey || "";

    let currentAgoraMins = lastMonth === monthKey ? Number(data.agoraMinutesThisMonth || 0) : 0;
    let currentTotalMins = lastMonth === monthKey ? Number(data.totalMinutesThisMonth || 0) : 0;
    let currentTotalCalls = lastMonth === monthKey ? Number(data.totalCallsThisMonth || 0) : 0;

    if (provider === "agora") {
      currentAgoraMins += durationMinutes;
    }
    currentTotalMins += durationMinutes;
    currentTotalCalls += 1;

    tx.set(
      usageRef,
      {
        lastMonthKey: monthKey,
        agoraMinutesThisMonth: currentAgoraMins,
        totalMinutesThisMonth: currentTotalMins,
        totalCallsThisMonth: currentTotalCalls,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        lastCallId: callId,
      },
      { merge: true }
    );
  });

  return {
    ok: true,
    durationMinutes,
    monthKey,
  };
});

/**
 * Callable function to explicitly terminate a call session with guaranteed server authority.
 * Atomically transitions the Firestore call document to a terminal state (ended/rejected/failed/missed)
 * and prevents any client or server retry loop.
 */
export const terminateCall = guardedOnCall(async (request) => {
  enforceAppCheck(request);
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated.");
  }

  const callId = String(request.data?.callId || "").trim();
  const reason = String(request.data?.reason || "normal").trim();
  const rawStatus = String(request.data?.status || "ended").toLowerCase().trim();
  const status = ["rejected", "ended", "failed", "missed", "declined", "cancelled"].includes(rawStatus)
    ? rawStatus
    : "ended";

  if (!callId) {
    throw new HttpsError("invalid-argument", "Missing callId.");
  }

  const callRef = db().collection("calls").doc(callId);
  const snap = await callRef.get();
  if (!snap.exists) {
    return { ok: true, found: false };
  }

  const data = snap.data() || {};
  const callerId = data.callerId;
  const receiverId = data.receiverId || data.targetUserId;
  const uid = request.auth.uid;

  if (callerId !== uid && receiverId !== uid) {
    throw new HttpsError("permission-denied", "Only call participants can terminate the call.");
  }

  await callRef.update({
    status,
    endedAt: admin.firestore.FieldValue.serverTimestamp(),
    endReason: reason,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { ok: true, status };
});

/**
 * Callable function to clean up and terminate all open calls for a given trip.
 */
export const cleanupTripCalls = guardedOnCall(async (request) => {
  enforceAppCheck(request);
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated.");
  }

  const tripId = String(request.data?.tripId || "").trim();
  if (!tripId) {
    throw new HttpsError("invalid-argument", "Missing tripId.");
  }

  const firestore = db();
  const [metaSnap, directSnap] = await Promise.all([
    firestore
      .collection("calls")
      .where("metadata.tripId", "==", tripId)
      .where("status", "in", ["ringing", "connecting", "connected", "idle"])
      .get(),
    firestore
      .collection("calls")
      .where("tripId", "==", tripId)
      .where("status", "in", ["ringing", "connecting", "connected", "idle"])
      .get(),
  ]);

  const batch = firestore.batch();
  const seen = new Set<string>();

  for (const doc of [...metaSnap.docs, ...directSnap.docs]) {
    if (seen.has(doc.id)) continue;
    seen.add(doc.id);
    batch.update(doc.ref, {
      status: "ended",
      endedAt: admin.firestore.FieldValue.serverTimestamp(),
      endReason: "trip_cleanup_requested",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  if (seen.size > 0) {
    await batch.commit();
  }

  return { ok: true, terminatedCount: seen.size };
});

const DEFAULT_STUN_SERVERS = [
  "stun:stun.l.google.com:19302",
  "stun:stun1.l.google.com:19302",
  "stun:stun2.l.google.com:19302",
  "stun:stun3.l.google.com:19302",
  "stun:stun4.l.google.com:19302",
];

/**
 * Returns WebRTC ICE servers (STUN + TURN) for cross-network calls.
 *
 * Reads TURN credentials securely from `/system_config/call_secrets` (static
 * `turnServers` / `turnUrl`+`turnUsername`+`turnCredential`, or Metered REST API
 * via `meteredDomain` + `meteredApiKey`) and falls back to `/system_settings/calling`.
 */
export const getIceServers = guardedOnCall(async (request) => {
  enforceAppCheck(request);
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated to fetch ICE servers.");
  }

  const [callingSnap, secretsSnap] = await Promise.all([
    db().collection("system_settings").doc("calling").get(),
    db().collection("system_config").doc("call_secrets").get(),
  ]);

  const callingData = callingSnap.data() || {};
  const secretsData = secretsSnap.data() || {};

  const iceServers: Array<Record<string, unknown>> = [];

  // 1. STUN servers
  const rawStuns = Array.isArray(callingData.stunServers) && callingData.stunServers.length > 0
    ? callingData.stunServers
    : DEFAULT_STUN_SERVERS;
  for (const stun of rawStuns) {
    const s = String(stun || "").trim();
    if (s) iceServers.push({ urls: s });
  }

  // 2. TURN servers from secrets (array or single-entry fields) or calling settings
  let hasTurn = false;
  const addTurnEntry = (entry: Record<string, unknown>) => {
    const urls = entry.urls ?? entry.url;
    if (!urls) return;
    const username = entry.username ? String(entry.username).trim() : "";
    const credential = entry.credential ? String(entry.credential).trim() : "";
    iceServers.push({
      urls,
      ...(username ? { username } : {}),
      ...(credential ? { credential } : {}),
    });
    hasTurn = true;
  };

  if (Array.isArray(secretsData.turnServers)) {
    for (const item of secretsData.turnServers) {
      if (item && typeof item === "object") addTurnEntry(item as Record<string, unknown>);
    }
  }

  if (!hasTurn && secretsData.turnUrl) {
    addTurnEntry({
      urls: secretsData.turnUrl,
      username: secretsData.turnUsername,
      credential: secretsData.turnCredential,
    });
  }

  if (!hasTurn && Array.isArray(callingData.turnServers)) {
    for (const item of callingData.turnServers) {
      if (item && typeof item === "object") addTurnEntry(item as Record<string, unknown>);
    }
  }

  // 3. Optional Metered TURN API dynamic credentials
  const meteredDomain = String(secretsData.meteredDomain || "").trim();
  const meteredApiKey = String(secretsData.meteredApiKey || "").trim();
  if (!hasTurn && meteredDomain && meteredApiKey) {
    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 4000);
      const resp = await fetch(
        `https://${meteredDomain}/api/v1/turn/credentials?apiKey=${encodeURIComponent(meteredApiKey)}`,
        { signal: controller.signal }
      );
      clearTimeout(timeout);
      if (resp.ok) {
        const list = (await resp.json()) as unknown;
        if (Array.isArray(list)) {
          for (const item of list) {
            if (item && typeof item === "object") {
              addTurnEntry(item as Record<string, unknown>);
            }
          }
        }
      }
    } catch (err) {
      console.warn("getIceServers: Metered TURN fetch failed:", err);
    }
  }

  return {
    iceServers,
    hasTurn,
  };
});

async function resolveUserFcmToken(uid: string): Promise<string> {
  if (!uid) return "";
  try {
    const userSnap = await db().collection("users").doc(uid).get();
    const userToken = String(userSnap.data()?.fcmToken || "").trim();
    if (userToken) return userToken;
    const driverSnap = await db().collection("drivers").doc(uid).get();
    return String(driverSnap.data()?.fcmToken || "").trim();
  } catch {
    return "";
  }
}

/**
 * Sends a high-priority data-only FCM push when a new ringing call is created
 * in `calls/{callId}` so recipients outside the app or with a killed process
 * immediately receive the Accept / Reject call notification banner.
 */
export const onCallCreated = onDocumentCreated("calls/{callId}", async (event) => {
  const data = event.data?.data();
  if (!data) return;

  const status = String(data.status || "").trim();
  const receiverId = String(data.receiverId || "").trim();
  if (status !== "ringing" || !receiverId) return;

  const token = await resolveUserFcmToken(receiverId);
  if (!token) return;

  const callId = event.params.callId;
  const callerId = String(data.callerId || "").trim();
  const callerName = String(data.callerName || "SeSe User").trim() || "SeSe User";
  const callerAvatar = String(data.callerAvatar || "").trim();
  const tripId = String(data.tripId || "").trim();

  try {
    await admin.messaging().send({
      token,
      data: {
        type: "incoming_call",
        callId,
        callerId,
        callerName,
        callerAvatar,
        receiverId,
        tripId,
        sentAtMs: String(Date.now()),
        click_action: "FLUTTER_NOTIFICATION_CLICK",
      },
      android: {
        priority: "high",
      },
      apns: {
        headers: {
          "apns-priority": "10",
        },
        payload: {
          aps: {
            alert: {
              title: callerName,
              body: "Incoming audio call...",
            },
            sound: "sese_alert_chime.caf",
            contentAvailable: true,
          },
        },
      },
    });
  } catch (err) {
    console.warn(`onCallCreated: FCM send failed for ${receiverId}:`, err);
  }
});

/**
 * Dismisses the receiver's incoming-call notification immediately when a ringing
 * call transitions to ended/cancelled/rejected/missed/connected.
 */
export const onCallUpdated = onDocumentUpdated("calls/{callId}", async (event) => {
  const before = event.data?.before.data();
  const after = event.data?.after.data();
  if (!before || !after) return;

  const prevStatus = String(before.status || "").trim();
  const nextStatus = String(after.status || "").trim();
  if (prevStatus !== "ringing" || nextStatus === "ringing") return;

  const receiverId = String(after.receiverId || "").trim();
  if (!receiverId) return;

  const token = await resolveUserFcmToken(receiverId);
  if (!token) return;

  const callId = event.params.callId;
  try {
    await admin.messaging().send({
      token,
      data: {
        type: "call_ended",
        callId,
        status: nextStatus,
        sentAtMs: String(Date.now()),
      },
      android: {
        priority: "high",
      },
    });
  } catch (err) {
    console.warn(`onCallUpdated: FCM dismiss failed for ${receiverId}:`, err);
  }
});
