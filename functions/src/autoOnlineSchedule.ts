/**
 * autoOnlineSchedule.ts
 *
 * Server-authoritative Auto Online Schedule for drivers.
 *
 * Rules:
 * - All time logic runs against Africa/Lagos (WAT, UTC+1) server time only.
 * - Each transition (online / offline) fires ONCE per calendar day (WAT).
 * - lastAutoOnlineDate / lastAutoOfflineDate guard idempotency and ensure
 *   manual driver overrides are never stomped within the same day.
 * - Drivers with autoScheduleEnabled === false are skipped entirely.
 *
 * Scheduled job: runs every minute ("* * * * *").  Minute-granularity is
 * sufficient because "once per day" idempotency means extra ticks cost only
 * a cheap Firestore read on already-processed drivers.
 */

import * as admin from "firebase-admin";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onCall, HttpsError } from "firebase-functions/v2/https";

const db = () => admin.firestore();

// ─── WAT helpers ────────────────────────────────────────────────────────────

const WAT_TZ = "Africa/Lagos";

/**
 * Returns the current time formatted as "HH:MM" (24-hour) in WAT.
 * Uses the Node.js Intl engine – no external package required.
 */
export function watHHMM(date: Date): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: WAT_TZ,
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const h = parts.find((p) => p.type === "hour")?.value ?? "00";
  const m = parts.find((p) => p.type === "minute")?.value ?? "00";
  return `${h}:${m}`;
}

/**
 * Returns the current calendar date as "YYYY-MM-DD" in WAT.
 */
export function watDateString(date: Date): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: WAT_TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const y = parts.find((p) => p.type === "year")?.value ?? "2000";
  const mo = parts.find((p) => p.type === "month")?.value ?? "01";
  const d = parts.find((p) => p.type === "day")?.value ?? "01";
  return `${y}-${mo}-${d}`;
}

/**
 * Returns true when the current WAT time (HH:MM) has reached or passed the
 * configured schedule time (HH:MM). Both strings are "HH:MM" 24-hour format.
 */
export function hasReachedOrPassed(currentHHMM: string, scheduleHHMM: string): boolean {
  return currentHHMM >= scheduleHHMM;
}

// ─── Scheduled sweep ─────────────────────────────────────────────────────────

/**
 * Runs every minute. Fetches all drivers with autoScheduleEnabled === true
 * and applies the once-per-day online/offline transitions.
 *
 * Data model (on `drivers/{uid}`):
 *   autoScheduleEnabled  boolean   - true = feature active (default true)
 *   autoOnlineTime       string    - "HH:MM" WAT (default "06:00")
 *   autoOfflineTime      string    - "HH:MM" WAT (default "22:00")
 *   lastAutoOnlineDate   string    - "YYYY-MM-DD" WAT – last day auto-online fired
 *   lastAutoOfflineDate  string    - "YYYY-MM-DD" WAT – last day auto-offline fired
 */
export const sweepAutoOnlineSchedule = onSchedule(
  {
    schedule: "* * * * *", // every minute
    timeZone: WAT_TZ,
    timeoutSeconds: 540,
    memory: "256MiB",
  },
  async () => {
    const now = new Date();
    const todayWAT = watDateString(now);
    const currentWAT = watHHMM(now);

    console.log(`[autoOnlineSchedule] sweep at WAT ${todayWAT} ${currentWAT}`);

    // Fetch only drivers who opted in to the schedule.
    // Drivers without the field (new field, legacy accounts) default to enabled.
    // We also fetch drivers where autoScheduleEnabled is simply absent (null check
    // is not supported in Firestore queries; we filter in memory below).
    let snap: admin.firestore.QuerySnapshot;
    try {
      snap = await db()
        .collection("drivers")
        .where("autoScheduleEnabled", "!=", false)
        .get();
    } catch (err) {
      // Fallback: if the index isn't ready yet, fetch all and filter
      console.warn("[autoOnlineSchedule] falling back to full scan:", err);
      snap = await db().collection("drivers").get();
    }

    const promises: Promise<void>[] = [];

    for (const doc of snap.docs) {
      const data = doc.data() ?? {};
      const uid = doc.id;

      // Skip drivers who explicitly disabled the schedule
      if (data.autoScheduleEnabled === false) continue;

      const autoOnlineTime: string = String(data.autoOnlineTime ?? "06:00");
      const autoOfflineTime: string = String(data.autoOfflineTime ?? "22:00");
      const lastAutoOnlineDate: string = String(data.lastAutoOnlineDate ?? "");
      const lastAutoOfflineDate: string = String(data.lastAutoOfflineDate ?? "");

      const shouldGoOnline =
        hasReachedOrPassed(currentWAT, autoOnlineTime) &&
        lastAutoOnlineDate !== todayWAT;

      const shouldGoOffline =
        hasReachedOrPassed(currentWAT, autoOfflineTime) &&
        lastAutoOfflineDate !== todayWAT;

      if (!shouldGoOnline && !shouldGoOffline) continue;

      promises.push(
        applyScheduledTransition(uid, {
          shouldGoOnline,
          shouldGoOffline,
          autoOnlineTime,
          autoOfflineTime,
          todayWAT,
          currentWAT,
        })
      );
    }

    // Run all transitions in parallel (each is its own Firestore transaction)
    await Promise.allSettled(promises);

    console.log(
      `[autoOnlineSchedule] sweep complete. ${promises.length} driver(s) processed.`
    );
  }
);

interface TransitionOptions {
  shouldGoOnline: boolean;
  shouldGoOffline: boolean;
  autoOnlineTime: string;
  autoOfflineTime: string;
  todayWAT: string;
  currentWAT: string;
}

/**
 * Applies the scheduled status transition for a single driver.
 * Uses a Firestore transaction so the idempotency check is atomic.
 *
 * IMPORTANT – Manual-toggle protection:
 * lastAutoOnlineDate / lastAutoOfflineDate are set to todayWAT when the
 * transition fires. If the driver manually toggled offline (or online) later
 * in the same day, those date fields are already today, so no second
 * auto-transition will fire for the rest of that day.
 *
 * The manual goOffline / goOnline callables do NOT modify these date fields,
 * which is intentional: a manual toggle naturally breaks the auto-loop for
 * that day's already-processed window (because the date guard is already set).
 */
async function applyScheduledTransition(uid: string, opts: TransitionOptions): Promise<void> {
  const {
    shouldGoOnline,
    shouldGoOffline,
    autoOnlineTime,
    autoOfflineTime,
    todayWAT,
    currentWAT,
  } = opts;

  let appliedStatus: "online" | "offline" | null = null;

  try {
    await db().runTransaction(async (tx) => {
      // ── All reads first (Firestore transaction invariant) ──────────────────
      const driverRef = db().collection("drivers").doc(uid);
      const statusRef = db().collection("driver_status").doc(uid);
      const driverSnap = await tx.get(driverRef);
      const statusSnap = await tx.get(statusRef);

      const driverData = driverSnap.data() ?? {};
      const statusData = statusSnap.data() ?? {};

      // Re-check inside the transaction to prevent TOCTOU
      const lastOnlineDate = String(driverData.lastAutoOnlineDate ?? "");
      const lastOfflineDate = String(driverData.lastAutoOfflineDate ?? "");

      const reallyGoOnline = shouldGoOnline && lastOnlineDate !== todayWAT;
      const reallyGoOffline = shouldGoOffline && lastOfflineDate !== todayWAT;

      if (!reallyGoOnline && !reallyGoOffline) return; // already handled

      const now = admin.firestore.FieldValue.serverTimestamp();

      // ── Determine which transition wins when both fire simultaneously ──────
      // If both windows have passed today (e.g. sweep runs at 22:30 for a driver
      // not yet stamped today), whichever scheduled time is later in the day wins,
      // and BOTH dates are stamped so the superseded transition doesn't fire 1m later.
      const offlineWins =
        reallyGoOffline && (!reallyGoOnline || autoOfflineTime >= autoOnlineTime);

      if (offlineWins) {
        // — Go OFFLINE ————————————————————————————————————————————————————————
        console.log(`[autoOnlineSchedule] AUTO-OFFLINE uid=${uid} WAT=${todayWAT} ${currentWAT}`);
        const driverUpdate: Record<string, unknown> = {
          lastAutoOfflineDate: todayWAT,
        };
        if (reallyGoOnline) {
          driverUpdate.lastAutoOnlineDate = todayWAT;
        }

        if (driverData.isOnline !== false || statusData.isOnline !== false) {
          tx.set(
            statusRef,
            {
              driverId: uid,
              isOnline: false,
              status: "offline",
              activeSessionId: null,
              updatedAt: now,
              autoScheduledOfflineAt: now,
            },
            { merge: true }
          );
          driverUpdate.isOnline = false;
          driverUpdate.activeSessionId = null;
          driverUpdate.lastSeen = now;
          appliedStatus = "offline";
        }

        tx.set(driverRef, driverUpdate, { merge: true });
      } else if (reallyGoOnline) {
        // — Go ONLINE ─────────────────────────────────────────────────────────
        const driverUpdate: Record<string, unknown> = {
          lastAutoOnlineDate: todayWAT,
        };
        if (reallyGoOffline) {
          driverUpdate.lastAutoOfflineDate = todayWAT;
        }

        // Guard: never force online a driver who is suspended or unverified.
        if (driverData.isProfileVerified === false || driverData.isVehicleVerified === false) {
          console.log(
            `[autoOnlineSchedule] Skipping auto-online for unverified driver uid=${uid}`
          );
          tx.set(driverRef, driverUpdate, { merge: true });
          return;
        }

        // If driver is already online, stamp date(s) without clobbering activeSessionId.
        if (driverData.isOnline === true && statusData.isOnline === true) {
          tx.set(driverRef, driverUpdate, { merge: true });
          return;
        }

        // Reuse the existing GPS fix and vehicle from the last known status.
        const prevFix = statusData.lastFix ?? {
          latitude: (driverData.lastLocation?.lat ?? 6.5244),
          longitude: (driverData.lastLocation?.lng ?? 3.3792),
          accuracy: 10,
          timestamp: new Date().toISOString(),
        };

        const sessionId = "auto_schedule_" + db().collection("_").doc().id;
        const prevVehicleId = statusData.activeVehicleId ?? driverData.activeVehicleId ?? null;
        const prevVehicleCategory = statusData.activeVehicleCategory ?? driverData.activeVehicleCategory ?? "car";
        const prevPlateNumber = statusData.activePlateNumber ?? driverData.activePlateNumber ?? "";

        console.log(`[autoOnlineSchedule] AUTO-ONLINE uid=${uid} WAT=${todayWAT} ${currentWAT}`);

        tx.set(
          statusRef,
          {
            driverId: uid,
            isOnline: true,
            status: "active",
            activeSessionId: sessionId,
            lastFix: prevFix,
            activeVehicleId: prevVehicleId,
            activeVehicleCategory: prevVehicleCategory,
            activePlateNumber: prevPlateNumber,
            updatedAt: now,
            onlineAt: now,
            autoScheduledOnlineAt: now,
          },
          { merge: true }
        );

        driverUpdate.isOnline = true;
        driverUpdate.activeSessionId = sessionId;
        driverUpdate.lastSeen = now;
        driverUpdate.activeVehicleId = prevVehicleId;
        driverUpdate.activeVehicleCategory = prevVehicleCategory;
        driverUpdate.activePlateNumber = prevPlateNumber;

        tx.set(driverRef, driverUpdate, { merge: true });
        appliedStatus = "online";
      }
    });

    // Best-effort FCM notification (outside the transaction; non-critical)
    if (appliedStatus !== null) {
      await _notifyDriver(uid, appliedStatus);
    }
  } catch (err) {
    console.error(`[autoOnlineSchedule] Error processing uid=${uid}:`, err);
  }
}

/** Sends a silent FCM data-only message to inform the driver app of the auto-transition. */
async function _notifyDriver(uid: string, newStatus: "online" | "offline"): Promise<void> {
  try {
    const userDoc = await db().collection("users").doc(uid).get();
    const fcmToken = userDoc.data()?.fcmToken;
    if (!fcmToken || typeof fcmToken !== "string") return;

    await admin.messaging().send({
      token: fcmToken,
      data: {
        type: "AUTO_SCHEDULE_STATUS_CHANGE",
        isOnline: newStatus === "online" ? "true" : "false",
        reason: newStatus === "online" ? "AUTO_ONLINE_SCHEDULE" : "AUTO_OFFLINE_SCHEDULE",
        message:
          newStatus === "online"
            ? "Your scheduled online time has started. You are now Online."
            : "Your scheduled offline time has arrived. You are now Offline.",
      },
      android: { priority: "high" },
      apns: { payload: { aps: { "content-available": 1 } } },
    });
  } catch (err) {
    console.warn(`[autoOnlineSchedule] FCM notify failed for uid=${uid}:`, err);
  }
}

// ─── Callable: save driver auto-schedule settings ────────────────────────────

interface SaveAutoScheduleData {
  autoScheduleEnabled: boolean;
  autoOnlineTime: string;  // "HH:MM" 24-hour
  autoOfflineTime: string; // "HH:MM" 24-hour
}

/**
 * Saves auto-schedule preferences for the calling driver.
 * Validates the time strings and writes them to `drivers/{uid}`.
 */
export const saveAutoScheduleSettings = onCall<SaveAutoScheduleData>(
  { enforceAppCheck: false },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in to save schedule settings.");
    }
    const uid = request.auth.uid;
    const { autoScheduleEnabled, autoOnlineTime, autoOfflineTime } = request.data ?? {};

    if (typeof autoScheduleEnabled !== "boolean") {
      throw new HttpsError("invalid-argument", "autoScheduleEnabled must be a boolean.");
    }

    const timeRe = /^([01]\d|2[0-3]):([0-5]\d)$/;
    if (!timeRe.test(autoOnlineTime ?? "")) {
      throw new HttpsError("invalid-argument", "autoOnlineTime must be HH:MM (24-hour).");
    }
    if (!timeRe.test(autoOfflineTime ?? "")) {
      throw new HttpsError("invalid-argument", "autoOfflineTime must be HH:MM (24-hour).");
    }

    await db().collection("drivers").doc(uid).set(
      {
        autoScheduleEnabled,
        autoOnlineTime,
        autoOfflineTime,
        autoScheduleUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    return { success: true, message: "Auto Online Schedule saved." };
  }
);
