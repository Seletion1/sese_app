import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import {
  onDocumentCreated,
  FirestoreEvent,
  QueryDocumentSnapshot,
} from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { verifyFareToken } from "./fareToken";
import {
  breakDriverStreak,
  handleTripCompletion,
  handleTripCancellationSettlement,
  nairaToKobo,
  logFinancialMutation,
  logTripTransition,
  persistFinancialAuditLogInTx,
  persistTripChangeLogInTx,
} from "./driverStreak";
import { roundToNearest100 } from "./pricing";
import { enforceAppCheck, requireAccountActive } from "./accountGuard";
import { chargePaystackCardAuthorization } from "./payments";

/**
 * Live dispatch state machine (server-authoritative).
 *
 * Client flow: `createTrip` callable mints `trips/{tripId}` in
 * SEARCHING_DRIVER. From there the backend owns every transition —
 * matchmaking, ping timeouts, re-broadcasts — so the customer may close
 * the app and restore live tracking later from Trips.
 *
 *   SEARCHING_DRIVER ──ping──> WAITING_FOR_ACCEPTANCE ──accept──> DRIVER_ACCEPTED
 *          ^                           │ decline / timeout
 *          └───────────────────────────┘ (declineCount + 1)
 *
 * Driver app drives the rest via acceptTrip / declineTrip /
 * updateDriverLocation / advanceTripStatus; customers via cancelTrip.
 */

// NOTE: ping/reping/tier timeouts, radii, and recycle bounds live in
// getDispatchTuning() below (system_settings/dispatch, console-tunable).
// There are intentionally no module-level timing constants here.

// ── Streamlined Sequential Dispatch Engine (1 -> 2 -> 3 -> Public Pool) ──────
// Step 1: 1st nearest online driver within Hub-configured radius (0-3 km default).
// Step 2: 2nd nearest online driver within Hub-configured radius on timeout/rejection.
// Step 3: 3rd nearest online driver within Hub-configured radius on timeout/rejection.
// Step 4: Drop into Public Order Pool (MARKETPLACE_OPEN) up to extended pool radius (15 km default).
//
// All numeric tunables below are DEFAULTS. The Super Admin Dispatch Console
// (sese_hub → Dynamic Config → Dispatch) overrides them at runtime via
// `system_settings/dispatch`; see getDispatchTuning(). Clamp bounds keep
// the console from bricking live dispatch.
export const MAX_SEQUENTIAL_DISPATCH_DRIVERS = 3;
const DEFAULT_PING_TIMEOUT_MS = 15 * 1000;
const DEFAULT_REPING_INTERVAL_MS = 30 * 1000;
const DEFAULT_TIER1_TIMEOUT_MS = 15 * 1000;
const DEFAULT_DISPATCH_RADIUS_KM = 15;
const DEFAULT_TIER1_RADIUS_KM = 3;
const DEFAULT_TIER3_RADIUS_KM = 15;
const DEFAULT_DISPATCH_CANDIDATE_LIMIT = 25;
const DEFAULT_PUBLIC_POOL_DURATION_MIN = 60;

interface DispatchTuning {
  dispatchRadiusKm: number;
  tier1RadiusKm: number;
  tier3RadiusKm: number;
  tier1TimeoutMs: number;
  pingTimeoutMs: number;
  repingIntervalMs: number;
  candidateLimit: number;
  publicPoolDurationMin: number;
  publicPoolDurationMs: number;
  maxOfferBoostPct: number;
  bidCountdownMs: number;
  bidCountdownSec: number;
}

const DEFAULT_TUNING: DispatchTuning = {
  dispatchRadiusKm: DEFAULT_DISPATCH_RADIUS_KM,
  tier1RadiusKm: DEFAULT_TIER1_RADIUS_KM,
  tier3RadiusKm: DEFAULT_TIER3_RADIUS_KM,
  tier1TimeoutMs: DEFAULT_TIER1_TIMEOUT_MS,
  pingTimeoutMs: DEFAULT_PING_TIMEOUT_MS,
  repingIntervalMs: DEFAULT_REPING_INTERVAL_MS,
  candidateLimit: DEFAULT_DISPATCH_CANDIDATE_LIMIT,
  publicPoolDurationMin: DEFAULT_PUBLIC_POOL_DURATION_MIN,
  publicPoolDurationMs: DEFAULT_PUBLIC_POOL_DURATION_MIN * 60 * 1000,
  maxOfferBoostPct: 100,
  bidCountdownMs: 10 * 1000,
  bidCountdownSec: 10,
};

let tuningCache: { at: number; value: DispatchTuning } | null = null;

/**
 * Live dispatch tunables from `system_settings/dispatch` (60s cache).
 * Every value is clamped into a safe band; missing doc / read failure
 * falls back to the compiled defaults, so dispatch never stalls.
 */
async function getDispatchTuning(): Promise<DispatchTuning> {
  try {
    if (tuningCache && Date.now() - tuningCache.at < 60 * 1000) {
      return tuningCache.value;
    }
    const snap = await db()
      .collection("system_settings")
      .doc("dispatch")
      .get();
    const d = snap.exists ? snap.data()! : {};
    const num = (v: unknown, fb: number, min: number, max: number) =>
      typeof v === "number" && Number.isFinite(v)
        ? Math.min(max, Math.max(min, v))
        : fb;
    const tier3Radius = num(
      d.tier3RadiusKm ?? d.dispatchRadiusKm,
      DEFAULT_DISPATCH_RADIUS_KM,
      1,
      50
    );
    const bidCountdownSec = Math.round(
      num(d.bidCountdownSec ?? d.bidCountdownSeconds, 10, 5, 60)
    );
    const tier1Radius = Math.min(
      num(d.tier1RadiusKm ?? d.searchRadiusKm, DEFAULT_TIER1_RADIUS_KM, 0.5, 50),
      tier3Radius
    );
    const tier1TimeoutSec = num(
      d.tier1TimeoutSec ?? d.sequentialTimeoutSec,
      15,
      5,
      120
    );
    const publicPoolDurationMin = Math.round(
      num(d.publicPoolDurationMin ?? d.poolDurationMin ?? d.publicPoolDurationMinutes, 60, 5, 1440)
    );
    const value: DispatchTuning = {
      dispatchRadiusKm: tier3Radius,
      tier1RadiusKm: tier1Radius,
      tier3RadiusKm: tier3Radius,
      tier1TimeoutMs: tier1TimeoutSec * 1000,
      pingTimeoutMs: tier1TimeoutSec * 1000,
      repingIntervalMs: num(d.repingIntervalSec, 30, 10, 600) * 1000,
      candidateLimit: Math.round(num(d.candidateLimit, 25, 5, 100)),
      publicPoolDurationMin,
      publicPoolDurationMs: publicPoolDurationMin * 60 * 1000,
      maxOfferBoostPct: num(d.maxOfferBoostPct, 100, 10, 500),
      bidCountdownMs: bidCountdownSec * 1000,
      bidCountdownSec: bidCountdownSec,
    };
    tuningCache = { at: Date.now(), value };
    return value;
  } catch {
    return tuningCache?.value ?? DEFAULT_TUNING;
  }
}

type TripStatusWire =
  | "SEARCHING_DRIVER"
  | "WAITING_FOR_ACCEPTANCE"
  | "MARKETPLACE_OPEN"
  | "MARKETPLACE_LIST"
  | "DRIVER_ACCEPTED"
  | "DRIVER_ARRIVING"
  | "DRIVER_ARRIVED"
  | "IN_PROGRESS"
  | "COMPLETED"
  | "CANCELLED"
  | "returned_to_customer"
  | "expired"
  | "needs_customer_action";

const LIVE_STATUSES: TripStatusWire[] = [
  "SEARCHING_DRIVER",
  "WAITING_FOR_ACCEPTANCE",
  "MARKETPLACE_OPEN",
  "MARKETPLACE_LIST",
  "DRIVER_ACCEPTED",
  "DRIVER_ARRIVING",
  "DRIVER_ARRIVED",
  "IN_PROGRESS",
];

/**
 * INBOX ALLOW-LIST — only these notification types are written to the
 * persistent `users/{uid}/notifications` inbox.  All other types fire an
 * FCM push only (phone buzz / banner) and are intentionally excluded from
 * the inbox so transient trip-status noise (e.g. "Driver arrived") does not
 * clutter the bell icon for both customers AND drivers.
 *
 * Allowed types (sensitive / official communications only):
 *   - delivery_pin_issued        — 4-digit PIN the customer must share
 *   - cash_settlement_requested  — financial action required from driver
 *   - trip_needs_customer_action — all drivers busy, customer must decide
 *   - driver_counter_bid         — driver offered a custom fare in marketplace
 *   - trip_chat_message          — in-trip chat message (peer or support)
 *   - broadcast                  — Hub-wide or targeted broadcast from admin
 *   - support_escalated          — live support agent joined the chat
 *   - support_reply              — agent replied to support ticket
 */
const INBOX_TYPES = new Set([
  "delivery_pin_issued",
  "cash_settlement_requested",
  "trip_needs_customer_action",
  "driver_counter_bid",
  "trip_chat_message",
  "broadcast",
  "split_payment_request",
  "support_escalated",
  "support_reply",
  "dropoff_approval_request",
  "dropoff_approved",
  "dropoff_rejected",
]);

/**
 * Best-effort user alert: optionally writes an in-app
 * `users/{uid}/notifications` inbox row (only for [INBOX_TYPES]) PLUS
 * always fires a rich high-priority FCM push on the user's topic.
 *
 * Separating inbox-write from FCM-push means transient status events
 * (e.g. "Driver arrived") can still buzz the phone without permanently
 * cluttering the notification bell for customers or drivers.
 *
 * Push shape: Android high priority + `sese_alert_chime` custom sound
 * (res/raw in both apps) so alerts are audible; iOS default sound (the
 * custom wav is not in the iOS bundle).
 */
async function notifyCustomer(
  customerId: string,
  tripId: string,
  title: string,
  body: string,
  type: string,
  extra: Record<string, string> = {},
  topicOverride?: string
): Promise<void> {
  if (!customerId) return;
  // Only persist to the inbox for high-value, non-transient event types.
  if (INBOX_TYPES.has(type)) {
    try {
      await db()
        .collection("users")
        .doc(customerId)
        .collection("notifications")
        .add({
          title,
          body,
          tripId,
          type,
          ...extra,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    } catch (e) {
      console.warn(`notifyCustomer: in-app write failed for ${customerId}: ${e}`);
    }
  }
  try {
    const channelId =
      type.startsWith("order") ||
      type === "trip_offer" ||
      type === "direct_ping" ||
      type === "tier_ping" ||
      type === "marketplace_broadcast"
        ? "sese_orders"
        : type === "broadcast"
        ? "sese_high_priority_alerts"
        : type.includes("chat") || type.includes("reply") || type.includes("escalated")
        ? "sese_chat"
        : "sese_system";

    await admin.messaging().send({
      topic: topicOverride ?? `user_${customerId}`,
      notification: { title, body },
      android: {
        priority: "high",
        notification: {
          sound: "sese_alert_chime",
          channelId,
          clickAction: "FLUTTER_NOTIFICATION_CLICK",
        },
      },
      apns: { payload: { aps: { sound: "default" } } },
      data: {
        type,
        tripId,
        click_action: "FLUTTER_NOTIFICATION_CLICK",
        fullScreen: channelId === "sese_orders" ? "true" : (extra.fullScreen ?? "false"),
        ...extra,
      },
    });
  } catch (e) {
    console.warn(`notifyCustomer: FCM send failed for ${customerId}: ${e}`);
  }
}

async function notifyDriver(
  driverId: string,
  tripId: string,
  title: string,
  body: string,
  type: string,
  extra: Record<string, string> = {}
): Promise<void> {
  if (!driverId) return;
  try {
    await db()
      .collection("drivers")
      .doc(driverId)
      .collection("notifications")
      .add({
        title,
        body,
        tripId,
        type,
        ...extra,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
  } catch (_) {}

  try {
    await admin.messaging().send({
      topic: `driver_${driverId}`,
      notification: { title, body },
      android: {
        priority: "high",
        notification: {
          sound: "sese_alert_chime",
          channelId: "sese_orders",
          clickAction: "FLUTTER_NOTIFICATION_CLICK",
        },
      },
      apns: { payload: { aps: { sound: "default" } } },
      data: {
        type,
        tripId,
        click_action: "FLUTTER_NOTIFICATION_CLICK",
        ...extra,
      },
    });
  } catch (e) {
    console.warn(`notifyDriver: FCM send failed for ${driverId}: ${e}`);
  }
}

/**
 * Trigger: tri-party trip chat message → push the OTHER party.
 *
 * `trips/{tripId}/messages/{messageId}` onCreate: resolves the trip,
 * skips the sender, and fires a high-priority audible FCM + in-app row
 * to the customer (driver sent) or the assigned driver (customer sent).
 * Agent/support reads stay in-app (console streams them live).
 */
export const onTripChatMessage = onDocumentCreated(
  "trips/{tripId}/messages/{messageId}",
  async (event) => {
    const msg = event.data?.data();
    if (!msg) return;
    const tripId = event.params.tripId;
    const senderId = String(msg.senderId ?? "");
    if (!senderId) return;
    let trip: admin.firestore.DocumentData | undefined;
    try {
      trip = (await db().collection("trips").doc(tripId).get()).data();
    } catch {
      return;
    }
    if (!trip) return;
    const driverId = String(trip.driver?.driverId ?? "");
    const customerId = String(trip.customerId ?? "");
    const senderIsDriver = senderId === driverId;
    const targetUid = senderIsDriver ? customerId : driverId;
    if (!targetUid) return;
    const text = String(msg.text ?? "").trim();
    const isPhoto = String(msg.type ?? "") === "image";
    const preview =
      text.length > 90 ? `${text.slice(0, 90)}…` : text;
    const senderName = senderIsDriver
      ? String(trip.driver?.fullName ?? "Your driver")
      : "Your customer";
    await notifyCustomer(
      targetUid,
      tripId,
      `New trip message from ${senderName}`,
      isPhoto ? "📷 Sent a photo" : preview || "Sent a message",
      "trip_chat_message",
      { senderId, senderRole: String(msg.senderRole ?? "") },
      senderIsDriver ? undefined : `driver_${targetUid}`
    );
  }
);

/** Great-circle distance in km between two coordinates. */
export function haversineKm(
  lat1: number, lng1: number, lat2: number, lng2: number
): number {
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRad(lat1)) *
      Math.cos(toRad(lat2)) *
      Math.sin(dLng / 2) *
      Math.sin(dLng / 2);
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/**
 * Reads Hub-configured maximum drop-off completion radius in meters.
 * Defaults to 500 meters if unconfigured or invalid.
 */
export async function getDropoffRadiusMeters(): Promise<number> {
  try {
    const snap = await db().collection("system_config").doc("remote_keys").get();
    if (snap.exists) {
      const val = snap.data()?.dropoffCompletionRadiusMeters ?? snap.data()?.dropoff_completion_radius_meters;
      if (typeof val === "number" && val > 0) return val;
    }
  } catch (_) {}
  try {
    const snap = await db().collection("system_configs").doc("global_default").get();
    if (snap.exists) {
      const val = snap.data()?.dropoffCompletionRadiusMeters ?? snap.data()?.dropoff_completion_radius_meters;
      if (typeof val === "number" && val > 0) return val;
    }
  } catch (_) {}
  return 500;
}

/**
 * Known dial codes mapped to disambiguate country prefixes.
 * Ordered longest to shortest so multi-digit codes match first.
 */
const KNOWN_DIAL_CODES = [
  "234", // Nigeria
  "229", // Benin
  "233", // Ghana
  "254", // Kenya
  "256", // Uganda
  "250", // Rwanda
  "255", // Tanzania
  "237", // Cameroon
  "225", // Côte d'Ivoire
  "221", // Senegal
  "228", // Togo
  "27",  // South Africa
  "20",  // Egypt
  "44",  // UK
  "33",  // France
  "49",  // Germany
  "91",  // India
  "86",  // China
  "971", // UAE
  "966", // Saudi Arabia
  "1",   // US / Canada
];

/**
 * Normalizes any raw phone number into canonical E.164 format.
 * - Strips all formatting characters (spaces, dashes, parentheses, dots).
 * - Removes duplicate dial codes (e.g. +234+234... or +234234...).
 * - Strips leading zero after country code (e.g. +2340816... -> +234816...).
 * - Strips leading zero on local numbers and prepends active dial code (e.g. 0816... -> +234816...).
 * - Supports Benin (+229), Ghana (+233), Kenya (+254), US/CA (+1), UK (+44), etc.
 */
export function normalizePhone(raw: unknown, defaultDialCode = "+234"): string {
  const str = String(raw ?? "").trim();
  if (!str) return "";

  let cleaned = str.replace(/[\s\(\)\-\.]/g, "");
  if (!cleaned) return "";

  const defaultPrefix = defaultDialCode.startsWith("+")
    ? defaultDialCode.slice(1)
    : defaultDialCode;

  // 1. If starts with '+'
  if (cleaned.startsWith("+")) {
    let digits = cleaned.slice(1);
    for (const code of KNOWN_DIAL_CODES) {
      if (digits.startsWith(code)) {
        let rest = digits.slice(code.length);
        while (rest.startsWith(code)) {
          rest = rest.slice(code.length);
        }
        if (code === "234") {
          while (rest.startsWith("0")) {
            rest = rest.slice(1);
          }
        } else if (code !== "229") {
          rest = rest.replace(/^0+/, "");
        }
        return `+${code}${rest}`;
      }
    }
    return `+${digits.replace(/^0+/, "")}`;
  }

  // 2. If starts with dial code digits without '+' (e.g. 2348161561592)
  for (const code of KNOWN_DIAL_CODES) {
    if (cleaned.startsWith(code) && cleaned.length >= code.length + 7) {
      let rest = cleaned.slice(code.length);
      while (rest.startsWith(code)) {
        rest = rest.slice(code.length);
      }
      if (code === "234") {
        while (rest.startsWith("0")) {
          rest = rest.slice(1);
        }
      } else if (code !== "229") {
        rest = rest.replace(/^0+/, "");
      }
      return `+${code}${rest}`;
    }
  }

  // 3. Plain local national number (e.g. 08161561592 or 8161561592)
  let national = cleaned;
  if (national.startsWith("0")) {
    national = national.slice(1);
  }
  return `+${defaultPrefix}${national}`;
}

export const normPhone = normalizePhone;

/**
 * Validates that a normalized phone number is either empty (optional)
 * or conforms to ITU-T E.164 international standard (+ followed by 8 to 15 digits).
 */
const phoneOk = (p: string) => {
  if (p === "") return true;
  return /^\+[1-9]\d{7,14}$/.test(p);
};

/**
 * Allow-listed cancellation reason codes (mirrors `CancelTripDialog` in
 * `sese_ride/lib/features/trips/presentation/cancel_trip_dialog.dart`).
 * Unknown codes collapse to `other` at the gate, so keep this set in step
 * with the client lists when reasons are added or renamed.
 */
const CANCEL_REASONS = new Set([
  "driver_taking_too_long",
  "changed_my_mind",
  "wrong_pickup",
  "wrong_dropoff",
  "fare_too_high",
  "booked_by_mistake",
  "driver_asked_to_cancel",
  "customer_no_show",
  "customer_asked_to_cancel",
  "pickup_too_far",
  "vehicle_issue",
  "emergency",
  "wrong_trip_match",
  "fare_too_low",
  "other",
]);

const isCoord = (lat: unknown, lng: unknown) =>
  typeof lat === "number" &&
  typeof lng === "number" &&
  Number.isFinite(lat) &&
  Number.isFinite(lng) &&
  lat >= -90 && lat <= 90 &&
  lng >= -180 && lng <= 180;

const db = () => admin.firestore();
const nowMs = () => Date.now();

/** Server-resolved customer verification: `users/{uid}` holds
 * `customerVerificationStatus: 'verified'` after sese_hub approval. */
async function isVerifiedCustomer(customerId: string): Promise<boolean> {
  try {
    const doc = await db().collection("users").doc(customerId).get();
    const data = doc.data() ?? {};
    return (
      data.customerVerificationStatus === "verified" ||
      data.isVerifiedCustomer === true
    );
  } catch {
    return false;
  }
}

/**
 * Owner-side phone-privacy flag: `users/{uid}.settings.hidePhoneNumber`.
 *
 * When true, the server withholds that user's raw number from trip documents
 * at write time (masked placeholder instead), so counterparties coordinate
 * through the in-app trip chat. Client-side masking alone was never a real
 * boundary — any client could read the raw field — so the flag is enforced
 * here, where the documents are minted. Mirrors `PrivacyMasking.maskPhone`
 * in sese_core; keep the two in step.
 */
async function hidePhonesEnabled(uid: string): Promise<boolean> {
  try {
    const doc = await db().collection("users").doc(uid).get();
    const settings = doc.data()?.settings;
    if (
      typeof settings === "object" &&
      settings !== null &&
      (settings as Record<string, unknown>).hidePhoneNumber === true
    ) {
      return true;
    }
    const driverDoc = await db().collection("drivers").doc(uid).get();
    const dSettings = driverDoc.data()?.settings;
    return (
      typeof dSettings === "object" &&
      dSettings !== null &&
      (dSettings as Record<string, unknown>).hidePhoneNumber === true
    );
  } catch {
    // Fail closed to visible: a read error must not silently strip numbers
    // the parties need for coordination.
    return false;
  }
}

/** `08012345678` → `080****5678`. Short/empty input → fixed placeholder. */
function maskPhone(raw: string): string {
  const digits = raw.replace(/\D/g, "");
  if (digits.length < 7) return "••••••";
  return `${digits.slice(0, 3)}****${digits.slice(-4)}`;
}

/**
 * Phone fields for a minted trip, masked when the customer opted into
 * number privacy. Returns the pickup/dropoff maps plus the top-level
 * coordination numbers — every copy the doc carries, so no raw value
 * survives anywhere on the document.
 */
async function maskedPhones(
  customerId: string,
  pickupPhone: string,
  dropoffPhone: string,
  d: CreateTripData
): Promise<Record<string, unknown>> {
  const pickupName = String(d.pickup?.name ?? d.pickupName ?? "").trim();
  const dropoffName = String(d.dropoff?.name ?? d.dropoffName ?? "").trim();
  if (!(await hidePhonesEnabled(customerId))) {
    return {
      pickup: {
        lat: d.pickup.lat,
        lng: d.pickup.lng,
        address: String(d.pickup.address ?? ""),
        ...(pickupName ? { name: pickupName } : {}),
        phone: pickupPhone,
      },
      dropoff: {
        lat: d.dropoff.lat,
        lng: d.dropoff.lng,
        address: String(d.dropoff.address ?? ""),
        ...(dropoffName ? { name: dropoffName } : {}),
        phone: dropoffPhone,
      },
      pickupPhone,
      dropoffPhone,
      ...(pickupName ? { pickupName } : {}),
      ...(dropoffName ? { dropoffName } : {}),
    };
  }
  // Empty stays empty: masking an absent number into a placeholder would
  // fabricate a contact that was never given.
  const maskedPickup = pickupPhone === "" ? "" : maskPhone(pickupPhone);
  const maskedDropoff = dropoffPhone === "" ? "" : maskPhone(dropoffPhone);
  return {
    phoneMasked: true,
    pickup: {
      lat: d.pickup.lat,
      lng: d.pickup.lng,
      address: String(d.pickup.address ?? ""),
      ...(pickupName ? { name: pickupName } : {}),
      phone: maskedPickup,
    },
    dropoff: {
      lat: d.dropoff.lat,
      lng: d.dropoff.lng,
      address: String(d.dropoff.address ?? ""),
      ...(dropoffName ? { name: dropoffName } : {}),
      phone: maskedDropoff,
    },
    pickupPhone: maskedPickup,
    dropoffPhone: maskedDropoff,
    ...(pickupName ? { pickupName } : {}),
    ...(dropoffName ? { dropoffName } : {}),
  };
}

// ── createTrip ─────────────────────────────────────────────────────────────

interface CreateTripData {
  pickup: { lat: number; lng: number; address?: string; phone?: string; name?: string };
  dropoff: { lat: number; lng: number; address?: string; phone?: string; name?: string };
  pickupPhone?: string;
  dropoffPhone?: string;
  pickupName?: string;
  dropoffName?: string;
  serviceType?: string;
  vehicleCategory?: string;
  category?: string;
  selectedTiers?: string[];
  fareToken?: string;
  distanceKm?: number;
  durationMins?: number;
}

/**
 * Callable: validates the booking, verifies the signed fareToken, and mints
 * the live trip document. Returns `{ tripId }`.
 */
export const createTrip = onCall<CreateTripData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in to book.");
  }
  const customerId = request.auth.uid;

  // ── Security gates (run before all booking logic) ─────────────────────────
  // App Check: reject calls from scripts / re-signed APKs lacking a valid
  // attestation token so that the callable cannot be used as an open booking API.
  enforceAppCheck(request);
  // Suspension gate: banned customers cannot create trips even when SDK-cached
  // Firestore rules have not yet propagated.
  await requireAccountActive(customerId, "customer");
  const d = request.data ?? {};

  const pickupPhone = normalizePhone(d.pickupPhone ?? d.pickup?.phone);
  const dropoffPhone = normalizePhone(d.dropoffPhone ?? d.dropoff?.phone);
  // Secondary contact numbers are OPTIONAL: empty means the customer offers
  // no extra contact ("call me when you get there"). Only a malformed
  // non-empty entry is rejected. The booker's own account number is minted
  // onto the trip below and stays reachable regardless.
  if (!phoneOk(pickupPhone) || !phoneOk(dropoffPhone)) {
    throw new HttpsError(
      "invalid-argument",
      "Phone numbers are optional, but when provided they must be valid."
    );
  }
  if (!d.pickup || !d.dropoff || !isCoord(d.pickup.lat, d.pickup.lng) ||
      !isCoord(d.dropoff.lat, d.dropoff.lng)) {
    throw new HttpsError(
      "invalid-argument",
      "Both pickup and dropoff coordinates ({lat, lng}) are required."
    );
  }
  const serviceType = d.serviceType === "ride" ? "ride" : "send_item";
  if (!Array.isArray(d.selectedTiers) || d.selectedTiers.length === 0 ||
      d.selectedTiers.some((t) => typeof t !== "string" || !t.trim())) {
    throw new HttpsError(
      "invalid-argument",
      "At least one vehicle tier must be selected."
    );
  }

  // Heavy-duty mutual exclusion, enforced server-side so a hostile client
  // cannot page small-vehicle riders on a heavy-cargo broadcast by crafting
  // the payload directly. (Spec names this function `createRideDispatch`;
  // the real entry point is `createTrip` — enforced here.)
  if (serviceType !== "ride") {
    const rawTiers: unknown = d.selectedTiers;
    const tiers: string[] = Array.isArray(rawTiers) ? rawTiers.map(String) : [];
    const hasHeavy = tiers.some((t) => t === "van" || t === "truck");
    const hasSmall = tiers.some(
      (t) => t === "bicycle" || t === "tricycle" || t === "motorcycle"
    );
    if (hasHeavy && hasSmall) {
      throw new HttpsError(
        "invalid-argument",
        "Van/Truck cannot be combined with Bicycle, Tricycle, or Motorcycle " +
        "in one request. Split heavy cargo into its own booking."
      );
    }
  }

  // Zero-trust: the fare must come from calculateFare untampered.
  const verified = verifyFareToken(String(d.fareToken ?? ""));
  if (!verified || verified.uid !== customerId) {
    throw new HttpsError(
      "invalid-argument",
      "Fare verification failed. Please re-check the fare and try again."
    );
  }

  // Primary selected tier and its baseline fare
  const primaryTier = Array.isArray(d.selectedTiers) && d.selectedTiers.length > 0
    ? String(d.selectedTiers[0])
    : "";
  const primaryTierObj = verified.tiers.find((t) => t.tierId === primaryTier);
  const primaryBaselineFare = primaryTierObj?.fareAmount ?? verified.tiers[0]?.fareAmount ?? 0;
  const baselineFare = primaryBaselineFare;

  const customTierFares =
    (d as any).customTierFares && typeof (d as any).customTierFares === "object"
      ? (d as any).customTierFares
      : {};

  // Resolve custom fare for the primary tier if provided
  const customPrimaryFare = primaryTier && typeof customTierFares[primaryTier] === "number"
    ? Number(customTierFares[primaryTier])
    : 0;

  const rawProposedFare = typeof (d as any).proposedFare === "number" ? Number((d as any).proposedFare) : 0;
  // Maximum custom fare cap: 10x baseline fare or 500,000 max to prevent absurd/hostile inputs.
  const maxFareCap = Math.max(primaryBaselineFare * 10, 500_000);
  const boundedProposedFare = Math.min(Math.max(rawProposedFare, 0), maxFareCap);
  const proposedFare = Math.max(boundedProposedFare, customPrimaryFare, primaryBaselineFare);

  // Update tier entries in fareTiers to reflect custom/proposed fares (never below baseline)
  const updatedFareTiers = verified.tiers.map((t) => {
    const customForTier = typeof customTierFares[t.tierId] === "number" ? Number(customTierFares[t.tierId]) : 0;
    const boundedCustom = Math.min(Math.max(customForTier, 0), maxFareCap);
    let tierFare = t.fareAmount;
    if (boundedCustom > tierFare) {
      tierFare = boundedCustom;
    }
    if (t.tierId === primaryTier && proposedFare > tierFare) {
      tierFare = proposedFare;
    }
    return { ...t, fareAmount: tierFare };
  });

  // Payment rail & Payment Mode resolution
  const rawPaymentMode = String((d as any).paymentMode ?? "sender_pays").toLowerCase();
  const paymentMode = ["sender_pays", "receiver_pays", "split"].includes(rawPaymentMode)
    ? rawPaymentMode
    : "sender_pays";

  const rawPayment = String((d as any).paymentMethod ?? "auto").toLowerCase();
  let paymentMethod = [
    "auto", "cash", "split", "prepaid", "wallet", "card", "paystack", "online",
  ].includes(rawPayment)
    ? rawPayment
    : "auto";

  // Receiver Pays: Automatically enforce Cash Only
  if (paymentMode === "receiver_pays") {
    paymentMethod = "cash";
  }

  // Check system-wide force PIN setting
  let forceDeliveryPinSystemWide = false;
  try {
    const remoteKeysSnap = await db().collection("system_config").doc("remote_keys").get();
    if (remoteKeysSnap.exists && remoteKeysSnap.data()?.forceDeliveryPinSystemWide === true) {
      forceDeliveryPinSystemWide = true;
    }
  } catch (_) {}

  // Rides never take a drop-off PIN: there is no recipient handoff, and
  // the driver completion path never asks for one on rides. Deliveries
  // require PIN only if system-wide forced or customer explicitly toggled on.
  const isPinRequired = serviceType !== "ride" &&
    (forceDeliveryPinSystemWide || (d as any).requireDeliveryPin === true);
  const pinCode = isPinRequired ? String(Math.floor(1000 + Math.random() * 9000)) : null;

  // Split payment validation if split selected
  let splitPaymentData: Record<string, unknown> | null = null;
  if (paymentMethod === "split" || (d as any).paymentMode === "split") {
    const recPhone = normPhone((d as any).receiverPhone ?? dropoffPhone);
    if (recPhone === "") {
      throw new HttpsError(
        "invalid-argument",
        "Split payment needs the receiver's phone number so their share " +
        "can be settled. Add it, or use Sender/Receiver Pays."
      );
    }
    const byE164 = await db()
      .collection("users")
      .where("phoneNumberE164", "==", recPhone.startsWith("234") ? `+${recPhone}` : recPhone)
      .limit(1)
      .get();
    let recSnap = byE164.empty ? null : byE164.docs[0];
    if (!recSnap) {
      const byLocal = await db()
        .collection("users")
        .where("phoneNumber", "==", recPhone)
        .limit(1)
        .get();
      recSnap = byLocal.empty ? null : byLocal.docs[0];
    }
    if (!recSnap) {
      throw new HttpsError(
        "invalid-argument",
        "Split payment requires both parties to be registered users. Ask the receiver to sign up, or select 'Sender Pays' / 'Receiver Pays'."
      );
    }
    // Server-authoritative split share validation: ensure senderShare + receiverShare equals proposedFare.
    let senderShare = Number((d as any).senderShareAmount ?? 0);
    let receiverShare = Number((d as any).receiverShareAmount ?? 0);
    if (
      !Number.isFinite(senderShare) ||
      !Number.isFinite(receiverShare) ||
      senderShare <= 0 ||
      receiverShare <= 0 ||
      Math.abs((senderShare + receiverShare) - proposedFare) > 0.01
    ) {
      senderShare = Math.round((proposedFare / 2) * 100) / 100;
      receiverShare = Math.round((proposedFare - senderShare) * 100) / 100;
    }

    splitPaymentData = {
      status: "pending_receiver_consent",
      senderShare,
      receiverShare,
      senderPaymentMethod: String((d as any).senderPaymentMethod ?? "cash"),
      receiverPaymentMethod: String((d as any).receiverPaymentMethod ?? "cash"),
      senderPhone: pickupPhone,
      receiverPhone: recPhone,
      receiverUid: recSnap.id,
      receiverConsentStatus: "pending",
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    };
  }

  let customerName = "Customer";
  let customerPhone = "";
  let userNegativeBalance = 0;
  try {
    const custSnap = await db().collection("users").doc(customerId).get();
    if (custSnap.exists) {
      const cData = custSnap.data()!;
      customerName = String(cData.fullName ?? cData.name ?? "Customer");
      customerPhone = normPhone(
        cData.phoneNumberE164 ?? cData.phoneNumber ?? ""
      );
      userNegativeBalance = Math.max(0, Number(cData.outstandingNegativeBalance ?? 0));
    }
  } catch (_) {}

  // ── Wallet Escrow & Cash Collection Breakdown Engine ───────────────────
  let availableWalletBalance = 0;
  let walletNegativeBalance = 0;
  const custWalletRef = db().collection("wallets").doc(customerId);
  try {
    const custWalletSnap = await custWalletRef.get();
    if (custWalletSnap.exists) {
      const wData = custWalletSnap.data()!;
      const mainBal = typeof wData.mainWalletBalance === "number"
        ? wData.mainWalletBalance
        : (typeof wData.balance === "number" ? wData.balance / 100 : 0);
      const escrowBal = typeof wData.escrowBalance === "number" ? wData.escrowBalance : 0;
      if (mainBal < 0) {
        walletNegativeBalance = Math.abs(mainBal);
      }
      availableWalletBalance = Math.max(0, mainBal - escrowBal);
    }
  } catch (e) {
    console.warn(`createTrip: wallet lookup warning: ${e}`);
  }

  const clientRecoveredDebt = Number((d as any).recoveredDebt ?? 0);
  const recoveredDebt = Math.max(userNegativeBalance, walletNegativeBalance, clientRecoveredDebt);
  const baseFare = proposedFare;
  const totalFare = baseFare + recoveredDebt;

  // Clear outstanding negative balance from user account since it is rolled into the new trip fare
  if (userNegativeBalance > 0) {
    try {
      await db().collection("users").doc(customerId).set(
        { outstandingNegativeBalance: 0 },
        { merge: true }
      );
    } catch (_) {}
  }

  let walletCoverageAmount = 0;
  let cashToCollect = totalFare;
  let collectAt: "pickup" | "dropoff" | "both" = "pickup";
  let payerRole: "sender" | "receiver" | "split" = "sender";
  let escrowLocked = false;
  let senderCashToCollect = 0;
  let receiverCashToCollect = 0;

  if (paymentMode === "receiver_pays") {
    // Receiver Pays: Cash Only, driver collects full fare from receiver at drop-off
    walletCoverageAmount = 0;
    cashToCollect = totalFare;
    receiverCashToCollect = totalFare;
    collectAt = "dropoff";
    payerRole = "receiver";
    escrowLocked = false;
  } else if (paymentMode === "split") {
    payerRole = "split";
    const senderShare = Number((d as any).senderShareAmount ?? totalFare / 2);
    const receiverShare = Number((d as any).receiverShareAmount ?? (totalFare - senderShare));
    receiverCashToCollect = receiverShare;

    if (paymentMethod === "cash") {
      walletCoverageAmount = 0;
      senderCashToCollect = senderShare;
      escrowLocked = false;
    } else {
      // Auto (smart default) or Wallet / Card
      walletCoverageAmount = roundToNearest100(Math.min(senderShare, availableWalletBalance));
      if (walletCoverageAmount > senderShare) {
        walletCoverageAmount = senderShare;
      }
      senderCashToCollect = Math.max(0, senderShare - walletCoverageAmount);
      escrowLocked = walletCoverageAmount > 0;
    }
    cashToCollect = senderCashToCollect + receiverCashToCollect;
    collectAt = senderCashToCollect > 0 ? "both" : "dropoff";
  } else {
    // "sender_pays"
    payerRole = "sender";
    collectAt = "pickup";
    if (paymentMethod === "cash" || (paymentMethod === "auto" && availableWalletBalance <= 0)) {
      walletCoverageAmount = 0;
      cashToCollect = totalFare;
      senderCashToCollect = totalFare;
      escrowLocked = false;
    } else {
      // Auto (smart default) or Wallet / Card
      walletCoverageAmount = roundToNearest100(Math.min(totalFare, availableWalletBalance));
      if (walletCoverageAmount > totalFare) {
        walletCoverageAmount = totalFare;
      }
      cashToCollect = Math.max(0, totalFare - walletCoverageAmount);
      senderCashToCollect = cashToCollect;
      escrowLocked = walletCoverageAmount > 0;
    }
  }

  const ref = db().collection("trips").doc();
  const tripId = ref.id;

  const initialStatusHistory = [
    {
      from: "none",
      to: "SEARCHING_DRIVER",
      actor: customerId,
      role: "customer",
      timestamp: nowMs(),
    },
  ];

  const isVerifiedCust = await isVerifiedCustomer(customerId);
  const maskedPhoneMap = await maskedPhones(customerId, pickupPhone, dropoffPhone, d);
  const isHideCustomerPhone = maskedPhoneMap.phoneMasked === true;
  const safeCustomerPhone = isHideCustomerPhone && customerPhone ? maskPhone(customerPhone) : customerPhone;

  const tripDocPayload: Record<string, any> = {
    customerId,
    customerName,
    customerPhone: safeCustomerPhone,
    statusHistory: initialStatusHistory,
    tripBooker: {
      uid: customerId,
      customerId,
      name: customerName,
      fullName: customerName,
      phone: safeCustomerPhone,
      phoneNumber: safeCustomerPhone,
    },
    createdBy: {
      uid: customerId,
      name: customerName,
      fullName: customerName,
      phone: safeCustomerPhone,
    },
    serviceType,
    status: "SEARCHING_DRIVER",
    isVerifiedCustomer: isVerifiedCust,
    ...maskedPhoneMap,
    deliveryPinRequired: isPinRequired,
    deliveryPinVerified: !isPinRequired,
    order: {
      requireDeliveryPin: isPinRequired,
    },
    ...(splitPaymentData ? { splitPaymentStatus: "pending_receiver_consent", splitPayment: splitPaymentData } : {}),
    selectedTiers: d.selectedTiers,
    vehicleCategory: String(d.vehicleCategory ?? d.category ?? (Array.isArray(d.selectedTiers) && d.selectedTiers.length > 0 ? d.selectedTiers[0] : "car")).toLowerCase(),
    fareToken: d.fareToken,
    fareTiers: updatedFareTiers,
    baseFare,
    recoveredDebt,
    totalFare,
    baselineFare,
    proposedFare: baseFare,
    fareAmount: baseFare,
    fareFormatted: `₦${totalFare.toLocaleString()}`,
    outstandingBalanceIncluded: recoveredDebt,
    fareBoosted: false,
    boostPercent: 0,
    paymentMethod,
    paymentMode,
    walletCoverageAmount,
    cashToCollect,
    collectAt,
    payerRole,
    escrowLocked,
    senderCashToCollect,
    receiverCashToCollect,
    paymentBreakdown: {
      baseFare,
      recoveredDebt,
      totalFare,
      walletCoverageAmount,
      cashToCollect,
      senderCashToCollect,
      receiverCashToCollect,
      collectAt,
      payerRole,
      escrowLocked,
    },
    senderShareAmount: (d as any).senderShareAmount != null
      ? Number((d as any).senderShareAmount)
      : (splitPaymentData ? Number(splitPaymentData.senderShare) : null),
    receiverShareAmount: (d as any).receiverShareAmount != null
      ? Number((d as any).receiverShareAmount)
      : (splitPaymentData ? Number(splitPaymentData.receiverShare) : null),
    customTierFares,
    distanceKm: verified.distanceKm,
    durationMins: verified.durationMins,
    declineCount: 0,
    reassignmentCount: 0,
    reassignmentHistory: [],
    idlePromptSent: false,
    attemptedDriverIds: [],
    pingDriverId: null,
    pingExpiresAt: null,
    driver: null,
    driverLocation: null,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  // Atomic transaction: locks available wallet balance into active escrow hold AND mints the trip doc
  await db().runTransaction(async (tx) => {
    let actualCoverage = 0;
    let actualCoverageKobo = 0;

    if (escrowLocked && walletCoverageAmount > 0) {
      const wSnap = await tx.get(custWalletRef);
      const wData = wSnap.exists ? wSnap.data()! : {};
      const mainBal = typeof wData.mainWalletBalance === "number"
        ? wData.mainWalletBalance
        : (typeof wData.balance === "number" ? wData.balance / 100 : 0);
      const currentEscrow = typeof wData.escrowBalance === "number" ? wData.escrowBalance : 0;
      const realAvailable = Math.max(0, mainBal - currentEscrow);

      actualCoverage = Math.min(walletCoverageAmount, realAvailable);
      actualCoverageKobo = nairaToKobo(actualCoverage);

      if (actualCoverage > 0) {
        tx.set(
          custWalletRef,
          {
            escrowBalance: admin.firestore.FieldValue.increment(actualCoverage),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true }
        );

        tx.set(
          custWalletRef.collection("transactions").doc(`${tripId}_escrow_hold`),
          {
            type: "trip_escrow_hold",
            role: "customer",
            amountNaira: -actualCoverage,
            amountKobo: -actualCoverageKobo,
            amount: -actualCoverageKobo,
            tripId,
            currency: "NGN",
            note: `Locked in escrow for active trip ${tripId}`,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          }
        );

        persistFinancialAuditLogInTx(tx, {
          tripId,
          type: "escrow_lock",
          accountId: customerId,
          amountNaira: -actualCoverage,
          amountKobo: -actualCoverageKobo,
          currency: "NGN",
          note: `Locked in escrow for active trip ${tripId}`,
          timestamp: Date.now(),
          stage: "creation",
          invariantsChecked: true,
        });
      }
    }

    tx.set(ref, tripDocPayload);

    persistTripChangeLogInTx(tx, {
      tripId,
      from: "none",
      to: "SEARCHING_DRIVER",
      actor: customerId,
      role: "customer",
      timestamp: Date.now(),
    });
  });

  // Save PIN doc for secure driver verification
  if (isPinRequired && pinCode != null) {
    try {
      await db().collection("delivery_pins").doc(ref.id).set({
        tripId: ref.id,
        customerId,
        pin: pinCode,
        verified: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      await notifyCustomer(
        customerId,
        ref.id,
        "Delivery PIN",
        `Your delivery verification code is ${pinCode}. Share it with your recipient — the driver will ask for it at drop-off.`,
        "delivery_pin_issued"
      );
    } catch (e) {
      console.warn(`createTrip: PIN issue failed: ${e}`);
    }
  }

  return { tripId: ref.id };
});

// ── Cascading matchmaking ──────────────────────────────────────────────────

interface NearbyDriver {
  id: string;
  distanceKm: number;
}

function pickupOf(data: admin.firestore.DocumentData): { lat: number; lng: number } | null {
  const pickup = data.pickup as { lat?: unknown; lng?: unknown } | undefined;
  if (
    pickup &&
    typeof pickup.lat === "number" &&
    typeof pickup.lng === "number"
  ) {
    return { lat: pickup.lat, lng: pickup.lng };
  }
  return null;
}

/**
 * Nearest online drivers to the pickup, excluding already-attempted ones.
 * Distances come from each driver doc's `lastLocation` (refreshed on the
 * goOnline handshake and every GPS heartbeat). Drivers without a fix sort
 * last. Results are capped to the coverage radius, nearest first.
 */
async function getMinWalletBalanceToOnline(): Promise<number> {
  try {
    const snap = await db().collection("system_configs").doc("financials").get();
    const raw = snap.data()?.minWalletBalanceToOnline;
    if (typeof raw === "number" && Number.isFinite(raw)) return raw;
  } catch (_) {}
  return 1.00;
}

async function findNearestDrivers(
  attempted: string[],
  serviceType: string,
  pickup: { lat: number; lng: number },
  count: number,
  tuning: DispatchTuning,
  radiusKm?: number,
  vehicleCategory?: string,
  customerId?: string,
  selectedTiers?: string[]
): Promise<NearbyDriver[]> {
  const snap = await db()
    .collection("drivers")
    .where("isOnline", "==", true)
    .orderBy("lastSeen", "desc")
    .limit(tuning.candidateLimit)
    .get();

  const ranked: NearbyDriver[] = [];
  for (const doc of snap.docs) {
    if (attempted.includes(doc.id)) continue;

    // Self-dispatch protection: never ping or match the customer as the driver
    if (customerId && doc.id === customerId) continue;

    const data = doc.data();

    // Strict Vehicle Category & Tier Isolation Guard:
    // Drivers MUST have a valid active vehicle category set when online.
    const activeCat = String(data.activeVehicleCategory ?? data.vehicleCategory ?? "").toLowerCase();
    if (!activeCat) {
      continue;
    }

    const allowedCats = new Set<string>();
    if (vehicleCategory && vehicleCategory.trim()) {
      allowedCats.add(vehicleCategory.trim().toLowerCase());
    }
    if (Array.isArray(selectedTiers)) {
      for (const t of selectedTiers) {
        if (typeof t === "string" && t.trim()) {
          allowedCats.add(t.trim().toLowerCase());
        }
      }
    }

    if (allowedCats.size > 0 && !allowedCats.has(activeCat)) {
      continue;
    }

    const tiers: string[] = Array.isArray(data.serviceTiers)
      ? data.serviceTiers.map(String)
      : [];
    // No tier allow-list on the driver doc = eligible for everything.
    if (tiers.length > 0 && serviceType === "ride" && !tiers.includes("ride")) {
      continue;
    }
    const loc = data.lastLocation as { lat?: unknown; lng?: unknown } | undefined;
    const distanceKm =
      loc && typeof loc.lat === "number" && typeof loc.lng === "number"
        ? haversineKm(pickup.lat, pickup.lng, loc.lat, loc.lng)
        : Number.POSITIVE_INFINITY;
    // Stage radius defaults to the outer cap when the caller passes none.
    const capKm = radiusKm ?? tuning.dispatchRadiusKm;
    if (distanceKm <= capKm) {
      ranked.push({ id: doc.id, distanceKm });
    }
  }
  ranked.sort((a, b) => a.distanceKm - b.distanceKm);
  return ranked.slice(0, count);
}

function attemptedIdsOf(data: admin.firestore.DocumentData): string[] {
  return Array.isArray(data.attemptedDriverIds)
    ? data.attemptedDriverIds.map(String)
    : [];
}

/**
 * Step 4 Fallback: drop the order into the Public Order Pool (MARKETPLACE_OPEN).
 * Every online driver within the extended pool radius (up to 15 km or Hub-configured
 * pool radius) will see it available to claim from the pool.
 */
async function dropToPublicPool(
  tripRef: admin.firestore.DocumentReference
): Promise<void> {
  const tuning = await getDispatchTuning();
  const poolExpiresAt = nowMs() + tuning.publicPoolDurationMs;
  await tripRef.update({
    status: "MARKETPLACE_OPEN",
    isPoolOrder: true,
    dispatchTier: 3,
    dispatchStep: 4,
    pingDriverId: null,
    pingDriverIds: [],
    pingExpiresAt: null,
    tierExpiresAt: null,
    poolExpiresAt,
    declineCount: admin.firestore.FieldValue.increment(1),
    droppedToPoolAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    statusHistory: admin.firestore.FieldValue.arrayUnion({
      from: "WAITING_FOR_ACCEPTANCE",
      to: "MARKETPLACE_OPEN",
      actor: "system_dispatch",
      role: "system",
      reason: "sequential_dispatch_fallback_to_public_pool",
      timestamp: nowMs(),
    }),
  });
}

/**
 * Sequential 1 -> 2 -> 3 -> Public Pool Dispatch Router
 *
 * Implements strict, sequential single-driver matching:
 * - Step 1: 1st nearest online driver within Hub-configured radius (0-3 km default).
 * - Step 2: 2nd nearest online driver within Hub-configured radius on timeout/rejection.
 * - Step 3: 3rd nearest online driver within Hub-configured radius on timeout/rejection.
 * - Step 4: Drop to Public Order Pool (MARKETPLACE_OPEN) if all three reject or time out.
 */
async function advanceSequentialDispatch(
  tripRef: admin.firestore.DocumentReference,
  data: admin.firestore.DocumentData,
  tuning: DispatchTuning
): Promise<boolean> {
  const pickup = pickupOf(data);
  const attempted = attemptedIdsOf(data);
  const currentStep =
    typeof data.dispatchStep === "number" ? data.dispatchStep : attempted.length;

  // If already at or beyond 3 attempted drivers, automatically drop into Public Order Pool
  if (
    currentStep >= MAX_SEQUENTIAL_DISPATCH_DRIVERS ||
    attempted.length >= MAX_SEQUENTIAL_DISPATCH_DRIVERS
  ) {
    await dropToPublicPool(tripRef);
    return false;
  }

  const nextStep = currentStep + 1;
  const serviceType = String(data.serviceType ?? "ride");
  const vehicleCategory = String(
    data.vehicleCategory ??
      (Array.isArray(data.selectedTiers) && data.selectedTiers.length > 0
        ? data.selectedTiers[0]
        : "")
  ).toLowerCase();
  const customerId = String(
    data.customerId ??
      data.userId ??
      (data.customer && typeof data.customer === "object" ? data.customer.uid : "") ??
      ""
  );

  const selectedTiers = Array.isArray(data.selectedTiers)
    ? data.selectedTiers.map((t: unknown) => String(t).toLowerCase())
    : [];

  const nearest =
    pickup == null
      ? []
      : await findNearestDrivers(
          attempted,
          serviceType,
          pickup,
          1,
          tuning,
          tuning.tier1RadiusKm,
          vehicleCategory,
          customerId,
          selectedTiers
        );

  if (nearest.length === 0) {
    // No more eligible drivers within configured radius (0-3 km) -> drop directly to Public Order Pool
    await dropToPublicPool(tripRef);
    return false;
  }

  const targetDriver = nearest[0];
  const stepExpiresAt = nowMs() + tuning.tier1TimeoutMs;

  await tripRef.update({
    status: "WAITING_FOR_ACCEPTANCE",
    dispatchTier: 1,
    dispatchStep: nextStep,
    tier1DriverId: targetDriver.id,
    pingDriverId: targetDriver.id,
    pingDriverIds: [targetDriver.id],
    pingExpiresAt: stepExpiresAt,
    tierExpiresAt: stepExpiresAt,
    attemptedDriverIds: admin.firestore.FieldValue.arrayUnion(targetDriver.id),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    statusHistory: admin.firestore.FieldValue.arrayUnion({
      from: String(data.status ?? ""),
      to: "WAITING_FOR_ACCEPTANCE",
      actor: "system_dispatch",
      role: "system",
      reason: `sequential_dispatch_step_${nextStep}`,
      driverId: targetDriver.id,
      distanceKm: targetDriver.distanceKm,
      timestamp: nowMs(),
    }),
  });

  // Push targeted notification exclusively to this 1 driver
  await notifyCustomer(
    targetDriver.id,
    tripRef.id,
    "New Order Request",
    "You have an exclusive order request! Tap to review and accept.",
    "trip_offer",
    {
      tripId: tripRef.id,
      dispatchStep: String(nextStep),
      pickupAddress: String(data.pickupAddress ?? data.pickup?.address ?? ""),
      dropoffAddress: String(data.dropoffAddress ?? data.dropoff?.address ?? ""),
      fareFormatted: String(data.fareFormatted ?? (data.fareAmount ? `₦${data.fareAmount}` : "")),
      fareAmount: String(data.fareAmount ?? data.baselineFare ?? 0),
      distanceKm: String(data.distanceKm ?? targetDriver.distanceKm ?? 0),
      pickupLat: String(data.pickupLat ?? data.pickup?.lat ?? 0),
      pickupLng: String(data.pickupLng ?? data.pickup?.lng ?? 0),
      dropoffLat: String(data.dropoffLat ?? data.dropoff?.lat ?? 0),
      dropoffLng: String(data.dropoffLng ?? data.dropoff?.lng ?? 0),
    },
    `driver_${targetDriver.id}`
  );

  return true;
}

/** Sequential Dispatch entry point on order creation. */
export const onTripCreated = onDocumentCreated(
  "trips/{tripId}",
  async (
    event: FirestoreEvent<QueryDocumentSnapshot | undefined, { tripId: string }>
  ) => {
    const snap = event.data;
    if (!snap) return;
    const data = snap.data();
    if (data.status !== "SEARCHING_DRIVER") return;
    const tuning = await getDispatchTuning();
    await advanceSequentialDispatch(snap.ref, data, tuning);
  }
);

async function breakStreakQuiet(driverId: string, reason: string) {
  try {
    await breakDriverStreak(driverId, reason);
  } catch (e) {
    console.warn(`sweepTripPings: streak break failed for ${driverId}: ${e}`);
  }
}

/**
 * Scheduled sweep (every minute): advances timed-out sequential offers (Step 1 -> 2 -> 3 -> Public Pool),
 * expires ignored pings ("skipped_by_driver"), and restarts dispatch for long-waiting searches.
 */
export const sweepTripPings = onSchedule("* * * * *", async () => {
  const cutoff = nowMs();
  const tuning = await getDispatchTuning();

  // 1. Advance sequential offers whose deadline passed.
  const tier1Due = await db()
    .collection("trips")
    .where("status", "==", "WAITING_FOR_ACCEPTANCE")
    .where("dispatchTier", "==", 1)
    .where("tierExpiresAt", "<", cutoff)
    .limit(25)
    .get();
  for (const doc of tier1Due.docs) {
    const data = doc.data();
    const ignored: string | undefined = data.pingDriverId;
    if (ignored) {
      await breakStreakQuiet(ignored, "ping_expired");
      await doc.ref.update({
        cancellationSource: "skipped_by_driver",
        rejections: admin.firestore.FieldValue.arrayUnion({
          driverId: ignored,
          action: "skipped",
          timestamp: cutoff,
        }),
      });
    }
    const fresh = (await doc.ref.get()).data();
    if (!fresh || fresh["status"] !== "WAITING_FOR_ACCEPTANCE") continue;
    await advanceSequentialDispatch(doc.ref, fresh, tuning);
  }

  // 2. Legacy pings without tier fields (pre-cascade docs): expire them.
  const stale = await db()
    .collection("trips")
    .where("status", "==", "WAITING_FOR_ACCEPTANCE")
    .where("pingExpiresAt", "<", cutoff)
    .limit(25)
    .get();
  for (const doc of stale.docs) {
    const data = doc.data();
    if (typeof data.dispatchTier === "number") continue; // handled above
    const ignoredDriverId: string | undefined = data.pingDriverId;
    await doc.ref.update({
      status: "SEARCHING_DRIVER",
      pingDriverId: null,
      pingExpiresAt: null,
      cancellationSource: "skipped_by_driver",
      declineCount: admin.firestore.FieldValue.increment(1),
      ...(ignoredDriverId
        ? {
            attemptedDriverIds: admin.firestore.FieldValue.arrayUnion(ignoredDriverId),
            rejections: admin.firestore.FieldValue.arrayUnion({
              driverId: ignoredDriverId,
              action: "skipped",
              timestamp: cutoff,
            }),
          }
        : {}),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    if (ignoredDriverId) await breakStreakQuiet(ignoredDriverId, "ping_expired");
  }

  // 4. Re-dispatch long-waiting searches (nobody online at creation).
  const searching = await db()
    .collection("trips")
    .where("status", "==", "SEARCHING_DRIVER")
    .limit(25)
    .get();
  for (const doc of searching.docs) {
    const data = doc.data();
    const updated = data.updatedAt?.toMillis?.() ?? 0;
    if (cutoff - updated < tuning.repingIntervalMs) continue;
    await advanceSequentialDispatch(doc.ref, data, tuning);
  }

  // 5. 30-Minute Idle Marketplace Price Adjustment Prompt
  const thirtyMinsAgo = cutoff - 30 * 60 * 1000;
  const idleTrips = await db()
    .collection("trips")
    .where("status", "==", "MARKETPLACE_OPEN")
    .where("idlePromptSent", "==", false)
    .limit(25)
    .get();

  for (const doc of idleTrips.docs) {
    const data = doc.data();
    const createdMs = data.createdAt?.toMillis?.() ?? 0;
    if (createdMs > 0 && createdMs < thirtyMinsAgo) {
      await doc.ref.update({
        idlePromptSent: true,
        statusMessage: "Increase price to get a driver faster",
        idlePromptAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      try {
        await db()
          .collection("users")
          .doc(data.customerId)
          .collection("notifications")
          .add({
            title: "Get a driver faster",
            body: "Increase price to get a driver faster",
            tripId: doc.id,
            type: "idle_trip_price_prompt",
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
      } catch {
        /* best effort */
      }
    }
  }

  // 6. Public Order Pool Expiration & Order Timeout (Hub-Configured Pool Duration)
  // When an order sits in the public pool (MARKETPLACE_OPEN or MARKETPLACE_LIST) beyond
  // the Hub-configured duration limit (default: 60 min), automatically transition to
  // `returned_to_customer` so it clears out of all driver feeds and notifies customer.
  const poolTimeoutMs = tuning.publicPoolDurationMs;
  for (const poolStatus of ["MARKETPLACE_OPEN", "MARKETPLACE_LIST"] as const) {
    const poolDue = await db()
      .collection("trips")
      .where("status", "==", poolStatus)
      .limit(25)
      .get();

    for (const doc of poolDue.docs) {
      const data = doc.data();
      const droppedAt =
        data.droppedToPoolAt?.toMillis?.() ??
        data.updatedAt?.toMillis?.() ??
        data.createdAt?.toMillis?.() ??
        0;
      const poolExpiresAt =
        typeof data.poolExpiresAt === "number"
          ? data.poolExpiresAt
          : droppedAt > 0
          ? droppedAt + poolTimeoutMs
          : 0;

      if (poolExpiresAt > 0 && cutoff >= poolExpiresAt) {
        await doc.ref.update({
          status: "returned_to_customer",
          isExpired: true,
          expiredAt: admin.firestore.FieldValue.serverTimestamp(),
          statusMessage: "Please increase the fare to catch nearby drivers' attention.",
          cancellationSource: "pool_timeout_returned_to_customer",
          pingDriverId: null,
          pingDriverIds: [],
          pingExpiresAt: null,
          tierExpiresAt: null,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          statusHistory: admin.firestore.FieldValue.arrayUnion({
            from: data.status,
            to: "returned_to_customer",
            actor: "system_dispatch",
            role: "system",
            reason: "public_pool_timeout_expired",
            timestamp: cutoff,
          }),
        });

        const customerId = String(data.customerId ?? data.userId ?? "");
        if (customerId) {
          try {
            await notifyCustomer(
              customerId,
              doc.id,
              "Order Returned",
              "Please increase the fare to catch nearby drivers' attention.",
              "trip_returned_to_customer",
              { tripId: doc.id, status: "returned_to_customer" }
            );
          } catch {
            /* best effort */
          }
        }
      }
    }
  }
});

// ── Driver actions ─────────────────────────────────────────────────────────

/**
 * Eligibility check shared by accept/decline.
 * Strict single-driver matching: caller must match pingDriverId exclusively.
 */
function isPingTarget(
  data: admin.firestore.DocumentData,
  driverId: string
): boolean {
  if (data.status !== "WAITING_FOR_ACCEPTANCE") return false;
  return data.pingDriverId === driverId;
}

export async function requirePingedDriver(
  tripId: string,
  driverId: string
): Promise<admin.firestore.DocumentSnapshot> {
  const ref = db().collection("trips").doc(tripId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Trip not found.");
  }
  const data = snap.data()!;
  if (!isPingTarget(data, driverId)) {
    throw new HttpsError(
      "failed-precondition",
      "This trip is no longer waiting on you."
    );
  }
  if (typeof data.pingExpiresAt === "number" && data.pingExpiresAt < nowMs()) {
    throw new HttpsError("deadline-exceeded", "Your ping expired.");
  }
  return snap;
}

async function driverSnapshot(driverId: string): Promise<Record<string, unknown>> {
  try {
    const doc = await db().collection("drivers").doc(driverId).get();
    const d = doc.exists ? doc.data()! : {};
    let vehicle: Record<string, unknown> = {};
    try {
      const v = await db()
        .collection("drivers").doc(driverId)
        .collection("vehicles").limit(1).get();
      if (!v.empty) vehicle = v.docs[0].data();
    } catch { /* vehicle optional */ }
    // Driver lifeline: during an active assigned trip, the customer must be able
    // to call the driver. The driver's actual dialable phone is minted onto the
    // trip's driver snapshot — matching customerPhone which is also kept dialable.
    const rawPhone = String(d.phoneNumberE164 ?? d.phoneNumber ?? d.phone ?? "");
    const hidePhone = await hidePhonesEnabled(driverId);
    const phone = hidePhone ? (rawPhone ? maskPhone(rawPhone) : "") : rawPhone;
    return {
      driverId,
      fullName: String(d.fullName ?? d.name ?? "Driver"),
      photoUrl: String(d.photoUrl ?? ""),
      rating: Number(d.rating ?? 0),
      phone,
      phoneMasked: hidePhone,
      plateNumber: String(vehicle.licensePlate ?? vehicle.plateNumber ?? ""),
      vehicleModel: String(
        [vehicle.make, vehicle.model].filter(Boolean).join(" ") || vehicle.model || ""
      ),
      vehicleColor: String(vehicle.color ?? ""),
    };
  } catch {
    return { driverId, fullName: "Driver", phone: "" };
  }
}

/**
 * Driver accepts → trip goes live with the driver sheet payload.
 *
 * Atomic first-wins claim inside a Firestore transaction
 * (claimOrderAtomic semantics):
 * - Tier 1: caller must be a current ping target.
 * - Tier 3 (MARKETPLACE_OPEN / MARKETPLACE_LIST): any online driver may
 *   claim; the transaction aborts for losers once `driver` is set, so
 *   double assignment is impossible even when two drivers tap the same
 *   millisecond.
 * - Pending bids are verified before assignment: the claimer's own pending
 *   bid (if any) is marked accepted and every other pending bid is
 *   rejected, so no stale `pending` bid survives a claim.
 */
export const acceptTrip = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Drivers must sign in.");
  }
  const driverId = request.auth.uid;
  const tripId = String(request.data?.tripId ?? "");
  if (!tripId) throw new HttpsError("invalid-argument", "tripId is required.");

  // ── Security gates ────────────────────────────────────────────────────────
  enforceAppCheck(request);
  // The driver-record suspension check happens inside the transaction below
  // (verification status), but we also gate on the shared user record here
  // so a banned driver with a still-valid driver doc cannot slip through.
  await requireAccountActive(driverId, "driver");

  const snapshot = await driverSnapshot(driverId);
  await db().runTransaction(async (tx) => {
    const ref = db().collection("trips").doc(tripId);
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new HttpsError("not-found", "Trip not found.");
    }

    // Multi-device session guard: ensure driver is currently online and
    // that this device session has not been superseded by another device.
    const statusDoc = await tx.get(db().collection("driver_status").doc(driverId));
    if (statusDoc.exists) {
      const sData = statusDoc.data() ?? {};
      if (sData.isOnline !== true) {
        throw new HttpsError(
          "failed-precondition",
          "You are currently offline. Go online to accept trips."
        );
      }
      const clientSessionId = request.data?.sessionId ? String(request.data.sessionId) : null;
      if (clientSessionId && sData.activeSessionId && sData.activeSessionId !== clientSessionId) {
        throw new HttpsError(
          "failed-precondition",
          "This session is no longer active. You went online on another device."
        );
      }
    }

    // Low balance guard: Drivers with balance below minWalletBalanceToOnline (< 1.00) cannot accept trips.
    const walletDoc = await tx.get(db().collection("wallets").doc(driverId));
    const wData = walletDoc.exists ? (walletDoc.data() ?? {}) : {};
    const mainBal = typeof wData.mainWalletBalance === "number"
      ? wData.mainWalletBalance
      : ((typeof wData.balance === "number" ? wData.balance : 0) / 100);
    const minBalance = await getMinWalletBalanceToOnline();
    if (mainBal < minBalance) {
      throw new HttpsError(
        "failed-precondition",
        "Your balance is low. Please top up to accept trips."
      );
    }

    const data = snap.data()!;
    const status = String(data.status ?? "");

    // Idempotent retry: if this driver has already claimed/accepted this trip,
    // succeed safely rather than failing due to duplicate network requests.
    if (data.driverId === driverId || data.driver?.driverId === driverId) {
      return;
    }

    // Self-assignment guard: drivers cannot accept orders they created as customer
    const orderCustomerId = String(data.customerId ?? data.userId ?? (data.customer && typeof data.customer === "object" ? data.customer.uid : "") ?? "");
    if (orderCustomerId && orderCustomerId === driverId) {
      throw new HttpsError(
        "failed-precondition",
        "You cannot accept an order you created as a customer."
      );
    }

    // Zero-trust Active Vehicle Approval & Category Isolation Gate (runs for all trip acceptances)
    const driverDocSnap = await tx.get(db().collection("drivers").doc(driverId));
    if (!driverDocSnap.exists || driverDocSnap.data()?.isOnline !== true) {
      throw new HttpsError(
        "failed-precondition",
        "You are currently offline. Go online to accept trips."
      );
    }
    const claimer = driverDocSnap.data()!;
    const claimerStatus = String(
      claimer.verificationStatus ?? claimer.status ?? ""
    ).toLowerCase();
    const claimerVerified =
      claimerStatus === "verified" ||
      claimerStatus === "approved" ||
      claimerStatus === "active_verified" ||
      claimer.isVerified === true ||
      claimer.isProfileVerified === true;
    if (!claimerVerified) {
      throw new HttpsError(
        "permission-denied",
        "Only active verified drivers can accept trips."
      );
    }

    const activeVehicleId = String(claimer.activeVehicleId ?? "");
    const activeVehicleCategory = String(claimer.activeVehicleCategory ?? "").toLowerCase();

    const fleetSnap = await tx.get(
      db()
        .collection("drivers")
        .doc(driverId)
        .collection("vehicles")
        .limit(20)
    );

    let activeDoc = fleetSnap.docs.find((vDoc) => vDoc.id === activeVehicleId);
    if (!activeDoc) {
      activeDoc = fleetSnap.docs.find((vDoc) => vDoc.data()?.isActiveSelected === true);
    }

    if (!activeDoc) {
      throw new HttpsError(
        "failed-precondition",
        "No active vehicle selected for this session. Go offline and select a verified vehicle."
      );
    }

    const activeVData = activeDoc.data() ?? {};
    const vStatus = String(activeVData.verificationStatus ?? activeVData.status ?? "").toUpperCase();
    const isVehicleApproved = vStatus === "APPROVED" || vStatus === "VERIFIED" || activeVData.isVerified === true;
    if (!isVehicleApproved) {
      throw new HttpsError(
        "failed-precondition",
        "Your active vehicle is pending admin approval and cannot accept orders."
      );
    }

    // Category & Tier Isolation Check
    const reqCat = String(data.vehicleCategory ?? "").toLowerCase();
    const reqTiers = Array.isArray(data.selectedTiers)
      ? data.selectedTiers.map((t: unknown) => String(t).toLowerCase())
      : [];
    const allowedCats = new Set<string>();
    if (reqCat) allowedCats.add(reqCat);
    for (const t of reqTiers) if (t) allowedCats.add(t);

    const effectiveDriverCat = activeVehicleCategory || String(activeVData.category ?? "").toLowerCase();
    if (allowedCats.size > 0 && !allowedCats.has(effectiveDriverCat)) {
      throw new HttpsError(
        "failed-precondition",
        `Your active vehicle (${effectiveDriverCat}) cannot accept orders for this trip category.`
      );
    }

    if (status === "WAITING_FOR_ACCEPTANCE") {
      if (!isPingTarget(data, driverId)) {
        throw new HttpsError(
          "failed-precondition",
          "This trip is no longer waiting on you."
        );
      }
      if (typeof data.pingExpiresAt === "number" && data.pingExpiresAt < nowMs()) {
        throw new HttpsError("deadline-exceeded", "Your ping expired.");
      }
    } else if (status === "MARKETPLACE_OPEN" || status === "MARKETPLACE_LIST") {
      // Vehicle checks handled by the zero-trust gate above
    } else {
      throw new HttpsError(
        "failed-precondition",
        "This trip is no longer available."
      );
    }

    if (data.driver?.driverId) {
      throw new HttpsError(
        "failed-precondition",
        "Another driver claimed this trip first."
      );
    }

    // Verify pending bids before assignment: accept the claimer's own
    // pending bid (keeps bid history consistent) and reject everyone
    // else's so no stale pending bid outlives the claim.
    const pendingBids = await tx.get(
      ref.collection("bids").where("status", "==", "pending")
    );
    for (const b of pendingBids.docs) {
      if (b.id === driverId) {
        tx.update(b.ref, {
          status: "accepted",
          acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } else {
        tx.update(b.ref, {
          status: "rejected",
          rejectedReason: "trip_claimed_by_driver",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }

    // If this claiming driver previously skipped or rejected this order,
    // supersede that preliminary rejection record so the trip state cleanly resolves.
    const existingRejections = Array.isArray(data.rejections) ? data.rejections : [];
    const updatedRejections = existingRejections.map((r: any) =>
      r && r.driverId === driverId ? { ...r, superseded: true, supersededAt: nowMs() } : r
    );

    const isPoolClaim =
      status === "MARKETPLACE_OPEN" ||
      status === "MARKETPLACE_LIST" ||
      data.isPoolOrder === true ||
      data.droppedToPoolAt != null ||
      data.dispatchStep === 4;

    tx.update(ref, {
      status: "DRIVER_ACCEPTED",
      driver: snapshot,
      driverId: driverId,
      isPoolOrder: isPoolClaim,
      dispatchTier: data.dispatchTier ?? null,
      cancellationSource: null,
      cancellationReason: null,
      rejections: updatedRejections,
      pingDriverId: null,
      pingDriverIds: [],
      pingExpiresAt: null,
      tierExpiresAt: null,
      hasActiveBids: false,
      biddingCompleted: pendingBids.size > 0 ? true : (data.biddingCompleted ?? false),
      acceptedBidDriverId: pendingBids.docs.some((b) => b.id === driverId)
        ? driverId
        : (data.acceptedBidDriverId ?? null),
      statusHistory: admin.firestore.FieldValue.arrayUnion({
        from: status,
        to: "DRIVER_ACCEPTED",
        actor: driverId,
        role: "driver",
        timestamp: nowMs(),
      }),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    persistTripChangeLogInTx(tx, {
      tripId,
      from: status,
      to: "DRIVER_ACCEPTED",
      actor: driverId,
      role: "driver",
      timestamp: nowMs(),
    });
  });

  logTripTransition({
    tripId,
    from: "WAITING_FOR_ACCEPTANCE",
    to: "DRIVER_ACCEPTED",
    actor: driverId,
    role: "driver",
    timestamp: nowMs(),
  });

  return { ok: true };
});

/**
 * Driver declines a Stage 1 ping → streak breaks, then dispatch continues
 * sequentially to the next nearest Stage 1 driver or falls back directly
 * to the global Order Pool (Stage 3).
 */
export const declineTrip = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Drivers must sign in.");
  }
  const driverId = request.auth.uid;
  const tripId = String(request.data?.tripId ?? "");
  if (!tripId) throw new HttpsError("invalid-argument", "tripId is required.");

  // ── Security gates ────────────────────────────────────────────────────────
  enforceAppCheck(request);
  await requireAccountActive(driverId, "driver");

  const tripRef = db().collection("trips").doc(tripId);
  const tuning = await getDispatchTuning();
  const rawAction = String(request.data?.action ?? request.data?.reason ?? "").toLowerCase();
  const isSkip = rawAction.includes("skip");
  const action = isSkip ? "skipped" : "rejected";
  const cancellationSource = isSkip ? "skipped_by_driver" : "rejected_by_driver";

  const rejectionEntry = {
    driverId,
    action,
    timestamp: nowMs(),
  };

  let shouldRedispatch = false;
  let fromStatus = "WAITING_FOR_ACCEPTANCE";

  await db().runTransaction(async (tx) => {
    const snap = await tx.get(tripRef);
    if (!snap.exists) {
      throw new HttpsError("not-found", "Trip not found.");
    }
    const data = snap.data()!;
    fromStatus = String(data.status ?? "");

    // Guard: only WAITING_FOR_ACCEPTANCE trips pinged to this driver can be declined
    if (fromStatus !== "WAITING_FOR_ACCEPTANCE") {
      return;
    }
    if (!isPingTarget(data, driverId)) {
      return;
    }

    shouldRedispatch = true;
    tx.update(tripRef, {
      status: "SEARCHING_DRIVER",
      pingDriverId: null,
      pingDriverIds: [],
      pingExpiresAt: null,
      tierExpiresAt: null,
      cancellationSource,
      declineCount: admin.firestore.FieldValue.increment(1),
      attemptedDriverIds: admin.firestore.FieldValue.arrayUnion(driverId),
      rejections: admin.firestore.FieldValue.arrayUnion(rejectionEntry),
      statusHistory: admin.firestore.FieldValue.arrayUnion({
        from: fromStatus,
        to: "SEARCHING_DRIVER",
        actor: driverId,
        role: "driver",
        reason: action,
        timestamp: nowMs(),
      }),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    persistTripChangeLogInTx(tx, {
      tripId,
      from: fromStatus,
      to: "SEARCHING_DRIVER",
      actor: driverId,
      role: "driver",
      reason: action,
      timestamp: nowMs(),
    });
  });

  // Rejecting an incoming request breaks the streak.
  try {
    await breakDriverStreak(driverId, "driver_declined");
  } catch (e) {
    console.warn(`declineTrip: streak break failed for ${driverId}: ${e}`);
  }

  // Advance to next sequential driver (Step 2 / Step 3) or escalate to Public Order Pool (Step 4).
  if (shouldRedispatch) {
    const fresh = await tripRef.get();
    if (fresh.exists && fresh.data()!.status === "SEARCHING_DRIVER") {
      await advanceSequentialDispatch(tripRef, fresh.data()!, tuning);
    }
  }
  return { ok: true };
});

/** Driver GPS heartbeat → powers the customer's live OSM driver marker.
 *
 * Mock Location Guard: heartbeats flagged `isMocked` (GPS spoofing) are
 * rejected so a spoofed fix can never move the live marker, feed
 * proximity triggers, or poison nearest-driver ranking. */
export const updateDriverLocation = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Drivers must sign in.");
  }
  const { tripId, lat, lng, isMocked } = request.data ?? {};
  if (!tripId || !isCoord(lat, lng)) {
    throw new HttpsError("invalid-argument", "tripId + valid {lat, lng} required.");
  }
  if (isMocked === true) {
    throw new HttpsError(
      "failed-precondition",
      "Mock location detected. Disable mock locations to continue this trip."
    );
  }
  const ref = db().collection("trips").doc(String(tripId));
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
  const data = snap.data()!;
  const assigned: string | undefined = data.driver?.driverId;
  if (assigned !== request.auth.uid) {
    throw new HttpsError("permission-denied", "Not your trip.");
  }
  if (!LIVE_STATUSES.includes(data.status)) {
    throw new HttpsError("failed-precondition", "Trip is no longer live.");
  }
  await ref.update({
    driverLocation: { lat, lng, updatedAt: nowMs() },
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  // Mirror the fix onto the driver doc so Tier 1 nearest-driver ranking
  // uses a fresh position (best-effort; trip tracking stays authoritative).
  try {
    await db().collection("drivers").doc(request.auth.uid).set(
      {
        lastLocation: { lat, lng, updatedAt: nowMs() },
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  } catch {
    // Non-fatal — ranking falls back to the last goOnline fix.
  }
  return { ok: true };
});

const DRIVER_TRANSITIONS: Record<string, string[]> = {
  DRIVER_ACCEPTED: ["DRIVER_ARRIVING", "DRIVER_ARRIVED"],
  DRIVER_ARRIVING: ["DRIVER_ARRIVED"],
  DRIVER_ARRIVED: ["IN_PROGRESS"],
  IN_PROGRESS: ["COMPLETED"],
};

/** Driver advances arrival/progress/completion along the allowed chain. */
export const advanceTripStatus = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Drivers must sign in.");
  }
  // ── Security gates ────────────────────────────────────────────────────────
  enforceAppCheck(request);
  await requireAccountActive(request.auth.uid, "driver");
  const { tripId, status, expectedStatus } = request.data ?? {};
  if (!tripId || typeof status !== "string") {
    throw new HttpsError("invalid-argument", "tripId + status required.");
  }
  const ref = db().collection("trips").doc(String(tripId));
  let alreadyInStatus = false;
  let fromStatus = "";
  let snapAfterData: admin.firestore.DocumentData | null = null;
  const dropoffRadiusMeters = await getDropoffRadiusMeters();

  await db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
    const data = snap.data()!;
    const driverId = String(data.driver?.driverId ?? data.driverId ?? "");
    if (driverId !== request.auth!.uid) {
      throw new HttpsError("permission-denied", "Not your trip.");
    }
    const currentStatus = String(data.status);
    fromStatus = currentStatus;

    // Stale write rejection: if client passed expectedStatus, verify it matches current
    if (expectedStatus && typeof expectedStatus === "string" && currentStatus !== expectedStatus) {
      throw new HttpsError(
        "failed-precondition",
        `STALE_WRITE: Trip status is ${currentStatus}, expected ${expectedStatus}.`
      );
    }

    // Terminal/settlement guard: cannot advance an already completed or settled trip
    if (data.settlement?.settled === true && status !== "COMPLETED") {
      throw new HttpsError(
        "failed-precondition",
        "This trip has already been completed and settled."
      );
    }

    if (currentStatus === String(status)) {
      alreadyInStatus = true;
      snapAfterData = data;
      return;
    }
    const allowed = DRIVER_TRANSITIONS[currentStatus] ?? [];
    if (!allowed.includes(String(status))) {
      throw new HttpsError(
        "failed-precondition",
        `Cannot move from ${currentStatus} to ${status}.`
      );
    }

    // ── Drop-off Geofencing Check ───────────────────────────────────────────
    if (status === "COMPLETED" && data.dropoffApprovalStatus !== "APPROVED") {
      const dropoffLat = Number(data.dropoff?.lat ?? data.dropoffLocation?.latitude ?? data.dropoffLat ?? 0);
      const dropoffLng = Number(data.dropoff?.lng ?? data.dropoffLocation?.longitude ?? data.dropoffLng ?? 0);
      if (dropoffLat !== 0 && dropoffLng !== 0) {
        const driverLat = Number(
          request.data?.driverLat ??
          request.data?.lat ??
          request.data?.latitude ??
          data.driverLocation?.lat ??
          data.driverLocation?.latitude ??
          0
        );
        const driverLng = Number(
          request.data?.driverLng ??
          request.data?.lng ??
          request.data?.longitude ??
          data.driverLocation?.lng ??
          data.driverLocation?.longitude ??
          0
        );
        if (driverLat !== 0 && driverLng !== 0) {
          const distM = Math.round(haversineKm(driverLat, driverLng, dropoffLat, dropoffLng) * 1000);
          if (distM > dropoffRadiusMeters) {
            throw new HttpsError(
              "failed-precondition",
              `OUT_OF_RANGE: Driver is outside drop-off location (${distM}m away, max allowed is ${dropoffRadiusMeters}m). Customer confirmation required.`
            );
          }
        }
      }
    }
    const update: Record<string, unknown> = {
      status,
      statusHistory: admin.firestore.FieldValue.arrayUnion({
        from: currentStatus,
        to: status,
        actor: driverId,
        role: "driver",
        timestamp: nowMs(),
      }),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    // Record the timestamp when driver taps "Arrived" for no-show timer tracking
    if (status === "DRIVER_ARRIVED") {
      update["arrivedAt"] = admin.firestore.FieldValue.serverTimestamp();
    } else if (status === "IN_PROGRESS" && !data.startedAt) {
      update["startedAt"] = admin.firestore.FieldValue.serverTimestamp();
    } else if (status === "COMPLETED") {
      update["completedAt"] = admin.firestore.FieldValue.serverTimestamp();
      update["cancellationSource"] = null;
      update["cancellationReason"] = null;
      const rejectionsList = Array.isArray(data.rejections) ? data.rejections : [];
      if (rejectionsList.some((r: any) => r?.driverId === driverId && !r?.superseded)) {
        update["rejections"] = rejectionsList.map((r: any) =>
          r && r.driverId === driverId ? { ...r, superseded: true, supersededAt: nowMs() } : r
        );
      }
    }
    if (request.data?.recordDropoffArrival === true && !data.dropoffArrivedAt) {
      update["dropoffArrivedAt"] = admin.firestore.FieldValue.serverTimestamp();
    }
    tx.update(ref, update);
    snapAfterData = { ...data, ...update };

    persistTripChangeLogInTx(tx, {
      tripId: String(tripId),
      from: currentStatus,
      to: status,
      actor: driverId,
      role: "driver",
      timestamp: nowMs(),
    });
  });

  if (alreadyInStatus) {
    return { ok: true, alreadyInStatus: true };
  }

  logTripTransition({
    tripId: String(tripId),
    from: fromStatus || "UNKNOWN",
    to: String(status),
    actor: String(request.auth!.uid),
    role: "driver",
    timestamp: nowMs(),
  });

  // Synchronous trip completion settlement: immediately post commission debit,
  // update wallet balance and trip settlement metadata with zero delay.
  if (status === "COMPLETED" && snapAfterData) {
    try {
      await handleTripCompletion(String(tripId), snapAfterData);
    } catch (e) {
      console.warn(`advanceTripStatus[${tripId}]: synchronous settlement warning: ${e}`);
    }
  } else if (status === "DRIVER_ARRIVED" && snapAfterData) {
    const tripObj = snapAfterData as Record<string, any>;
    const customerId = String(tripObj.customerId ?? "");
    const driverName = String(tripObj.driver?.fullName ?? "Your driver");
    await notifyCustomer(
      customerId,
      String(tripId),
      "Driver arrived",
      `${driverName} has arrived at the pickup point.`,
      "driver_arrived"
    );
  } else if (status === "IN_PROGRESS" && snapAfterData) {
    const liveTrip = snapAfterData as Record<string, any>;
    const paymentMethod = String(liveTrip["paymentMethod"] ?? "cash").toLowerCase();
    const customerId = String(liveTrip["customerId"] ?? "");
    const driverId = String(
      liveTrip["driver"]?.["driverId"] ?? liveTrip["driverId"] ?? request.auth!.uid
    );
    const cashToCollect = Number(liveTrip["cashToCollect"] ?? 0);

    if (
      (paymentMethod === "card" || paymentMethod === "paystack" || paymentMethod === "wallet") &&
      cashToCollect > 0 &&
      !liveTrip["paidViaCard"]
    ) {
      try {
        const chargeResult = await chargePaystackCardAuthorization({
          uid: customerId,
          tripId: String(tripId),
          amountNaira: cashToCollect,
        });

        if (chargeResult.success) {
          await db().collection("trips").doc(String(tripId)).update({
            paymentMethod: "online",
            cashToCollect: 0,
            paidViaCard: true,
            paymentStatus: "paid",
            paystackReference: chargeResult.reference,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });

          await notifyDriver(
            driverId,
            String(tripId),
            "Card Payment Successful",
            `Card payment of ₦${cashToCollect.toLocaleString()} was processed successfully. DO NOT collect cash from customer.`,
            "card_payment_success"
          );
        } else {
          await db().collection("trips").doc(String(tripId)).update({
            paymentMethod: "cash",
            paymentStatus: "cash_fallback",
            cardPaymentFailed: true,
            cardPaymentFailureReason: chargeResult.failureReason ?? "Card charge failed",
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });

          await notifyDriver(
            driverId,
            String(tripId),
            "Card Payment Failed - Collect Cash",
            `Card payment failed (${chargeResult.failureReason ?? "failed"}). Collect full cash amount (₦${cashToCollect.toLocaleString()}) from customer upon trip completion.`,
            "card_payment_failed"
          );
        }
      } catch (e) {
        console.warn(`advanceTripStatus[${tripId}]: automated card charge error: ${e}`);
        await db().collection("trips").doc(String(tripId)).update({
          paymentMethod: "cash",
          paymentStatus: "cash_fallback",
          cardPaymentFailed: true,
          cardPaymentFailureReason: String(e),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        await notifyDriver(
          driverId,
          String(tripId),
          "Card Payment Failed - Collect Cash",
          `Card payment failed. Collect full cash amount (₦${cashToCollect.toLocaleString()}) from customer upon trip completion.`,
          "card_payment_failed"
        );
      }
    }
  }
  return { ok: true };
});

// ── Customer actions ───────────────────────────────────────────────────────

/** Release active trip wallet escrow hold back to customer's available balance upon cancellation */
export async function releaseTripEscrow(
  tripId: string,
  tripData: Record<string, any>,
  passedTx?: admin.firestore.Transaction
): Promise<void> {
  const walletCoverage = Number(
    tripData["walletCoverageAmount"] ??
    tripData["paymentBreakdown"]?.["walletCoverageAmount"] ??
    0
  );
  if (walletCoverage <= 0 || tripData["escrowRefundedAt"] || tripData["escrowLocked"] === false) {
    return;
  }

  const customerId = String(tripData["customerId"] ?? "");
  if (!customerId) return;

  const coverageKobo = nairaToKobo(walletCoverage);
  const custWalletRef = db().collection("wallets").doc(customerId);
  const refundTxRef = custWalletRef.collection("transactions").doc(`${tripId}_escrow_refund`);
  const tripRef = db().collection("trips").doc(tripId);

  const applyRefund = (tx: admin.firestore.Transaction, currentEscrow?: number) => {
    const newEscrow = currentEscrow != null ? Math.max(0, currentEscrow - walletCoverage) : undefined;
    tx.set(
      custWalletRef,
      {
        ...(newEscrow != null
          ? { escrowBalance: newEscrow }
          : { escrowBalance: admin.firestore.FieldValue.increment(-walletCoverage) }),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    tx.set(refundTxRef, {
      type: "trip_escrow_refund",
      role: "customer",
      amountNaira: walletCoverage,
      amountKobo: coverageKobo,
      amount: coverageKobo,
      tripId,
      currency: "NGN",
      note: `Escrow hold released for cancelled trip ${tripId}`,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    tx.update(tripRef, {
      escrowLocked: false,
      escrowRefundedAt: admin.firestore.FieldValue.serverTimestamp(),
      "paymentBreakdown.escrowLocked": false,
      "paymentBreakdown.escrowRefunded": true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    logFinancialMutation({
      tripId,
      type: "trip_escrow_refund",
      accountId: customerId,
      amountNaira: walletCoverage,
      amountKobo: coverageKobo,
      currency: "NGN",
      note: `Escrow hold released for cancelled trip ${tripId}`,
      timestamp: Date.now(),
    });
  };

  if (passedTx) {
    applyRefund(passedTx);
  } else {
    await db().runTransaction(async (tx) => {
      const snap = await tx.get(tripRef);
      if (!snap.exists) return;
      const t = snap.data()!;
      if (t["escrowRefundedAt"] || t["escrowLocked"] === false) return;
      const wSnap = await tx.get(custWalletRef);
      const currentEscrow = wSnap.exists ? Number(wSnap.data()?.escrowBalance ?? walletCoverage) : walletCoverage;
      applyRefund(tx, currentEscrow);
    });
  }
}

/** Customer or driver cancels a live trip — sets cancellationSource for streak logic. */
export const cancelTrip = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in.");
  }
  // ── Security gates ────────────────────────────────────────────────────────
  // Cancelation can have financial consequences (waiting-fee settlement),
  // so App Check + suspension gate apply.
  enforceAppCheck(request);
  await requireAccountActive(request.auth.uid);
  const tripId = String(request.data?.tripId ?? "");
  if (!tripId) throw new HttpsError("invalid-argument", "tripId is required.");
  const ref = db().collection("trips").doc(tripId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
  const data = snap.data()!;

  const callerId = request.auth.uid;
  const isCustomer = data.customerId === callerId;
  const isDriver = data.driver?.driverId === callerId || data.driverId === callerId;

  if (!isCustomer && !isDriver) {
    throw new HttpsError("permission-denied", "Not your trip.");
  }
  const CANCELLABLE_STATUSES = new Set<string>([
    ...LIVE_STATUSES,
    "returned_to_customer",
    "expired",
    "needs_customer_action",
  ]);

  if (!CANCELLABLE_STATUSES.has(data.status)) {
    if (
      data.status === "CANCELLED" ||
      data.status === "CANCELLED_BY_CUSTOMER" ||
      data.status === "CANCELLED_BY_DRIVER" ||
      data.status === "CANCELLED_WAITING_CASH_SETTLEMENT"
    ) {
      return { ok: true, alreadyCancelled: true };
    }
    throw new HttpsError("failed-precondition", "Trip is already closed.");
  }

  // ── Cancellation reason (audited, allow-listed) ──────────────────────
  // Unknown/absent codes land as `other` — the audit stays complete while
  // a hostile client can never inject a free-form value into the trail.
  const rawReason = String(request.data?.reason ?? "other").trim();
  const reason = CANCEL_REASONS.has(rawReason) ? rawReason : "other";
  const role = isCustomer ? "customer" : "driver";

  // ── Spam-cancel rate limit (10/hour per account, no index needed) ────
  // A per-user `cancelStats {count, windowStartMs}` counter lives on the
  // user doc and is bumped transactionally, so two racing cancels cannot
  // both slip under the cap. The window is fixed (not sliding): exceeding
  // it rejects with `resource-exhausted` and a user-safe message.
  const CANCEL_WINDOW_MS = 60 * 60 * 1000;
  const CANCEL_MAX_PER_HOUR = 10;
  const userRef = db().collection("users").doc(callerId);
  await db().runTransaction(async (tx) => {
    const userSnap = await tx.get(userRef);
    const stats = (userSnap.data()?.cancelStats ?? {}) as {
      count?: unknown; windowStartMs?: unknown;
    };
    const now = nowMs();
    let count = typeof stats.count === "number" ? stats.count : 0;
    let windowStart = typeof stats.windowStartMs === "number"
      ? stats.windowStartMs
      : 0;
    if (!windowStart || now - windowStart >= CANCEL_WINDOW_MS) {
      count = 0;
      windowStart = now;
    }
    if (count >= CANCEL_MAX_PER_HOUR) {
      throw new HttpsError(
        "resource-exhausted",
        "Too many cancellations in the last hour. Please wait before cancelling again."
      );
    }
    tx.set(
      userRef,
      { cancelStats: { count: count + 1, windowStartMs: windowStart } },
      { merge: true }
    );
  });

  // ── Immutable audit row (server-only writes via rules) ───────────────
  // Timestamp, actor, role, reason, trip id, and the status at cancel time.
  // Best-effort ordering after the rate-limit gate: a failed audit write
  // must never block a legitimate cancellation, so it never throws.
  try {
    await db().collection("cancellation_audits").add({
      tripId,
      userId: callerId,
      role,
      reason,
      statusAtCancel: String(data.status ?? ""),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (e) {
    console.warn(`cancelTrip: audit write failed for ${tripId}: ${e}`);
  }

  // Customer cancellation with paid waiting fee & trusted customer / cash settlement logic
  if (isCustomer) {
    let paidWaitingFee = 0;
    const isArrivedOrProgress = data.status === "DRIVER_ARRIVED" || data.status === "IN_PROGRESS";
    const arrivedAtMs = (data.status === "IN_PROGRESS" && data.dropoffArrivedAt?.toMillis?.())
      ? data.dropoffArrivedAt.toMillis()
      : (data.arrivedAt?.toMillis?.() ?? 0);
    const enableWaitingBilling = data.enableWaitingTimeBilling !== false;

    if (isArrivedOrProgress && arrivedAtMs > 0 && enableWaitingBilling) {
      const elapsedMs = nowMs() - arrivedAtMs;
      const freeWaitMs = 10 * 60 * 1000; // 10 minutes free countdown
      if (elapsedMs > freeWaitMs) {
        const paidWaitMins = Math.ceil((elapsedMs - freeWaitMs) / (60 * 1000));
        const timeRatePerMin = Number(data.timeRatePerMinute ?? 20);
        paidWaitingFee = Math.max(0, paidWaitMins * timeRatePerMin);
      }
    }

    const useCashSettlement = request.data?.useCashSettlement === true;

    const result = await handleTripCancellationSettlement({
      tripId,
      cancelledBy: "customer",
      actorId: callerId,
      role: "customer",
      reason,
      paidWaitingFee,
      useCashSettlement,
    });

    if (result.cashSettlementPending) {
      const assignedDriverId = String(data.driver?.driverId ?? data.driverId ?? "");
      if (assignedDriverId) {
        await notifyCustomer(
          assignedDriverId,
          tripId,
          "Cash Settlement Requested",
          `Customer cancelled during paid waiting. Collect ₦${paidWaitingFee} cash from customer and tap "Accept Cash & Cancel".`,
          "cash_settlement_requested",
          {},
          `driver_${assignedDriverId}`
        );
      }
      return { ok: true, cancelledBy: "customer", cashSettlement: true, fee: paidWaitingFee };
    }

    return { ok: true, cancelledBy: "customer", paidWaitingFee: result.paidWaitingFee };  }

  // Driver cancellation logic
  let cancellationSource = "unknown";
  if (data.status === "DRIVER_ARRIVED") {
    const arrivedAt = data.arrivedAt?.toMillis?.() ?? 0;
    const waitedMs = nowMs() - arrivedAt;
    const noShowWaitMs = (data["noShowWaitMinutes"] ?? 10) * 60 * 1000;
    cancellationSource =
      waitedMs >= noShowWaitMs ? "driver_no_show" : "driver_before_arrival";
  } else {
    cancellationSource = "driver_before_arrival";
  }

  // Driver Reassignment Loop (Up to 3 Times)
  // Per spec: If a driver cancels a ride after accepting (even if arrived or picked up),
  // it must NOT cancel the order for the customer — server holds and re-assigns.
  const isDriverActiveStatus = [
    "DRIVER_ACCEPTED",
    "DRIVER_ARRIVING",
    "DRIVER_ARRIVED",
    "IN_PROGRESS",
  ].includes(String(data.status));

  if (isDriverActiveStatus) {
    const currentCount = Number(data.reassignmentCount ?? 0);
    const nextCount = currentCount + 1;
    const history = Array.isArray(data.reassignmentHistory)
      ? [...data.reassignmentHistory, { driverId: callerId, cancelledAt: nowMs(), reason }]
      : [{ driverId: callerId, cancelledAt: nowMs(), reason }];

    if (nextCount <= 3) {
      // Auto-reassign to next nearest driver — DO NOT cancel for the customer!
      await ref.update({
        driver: null,
        driverLocation: null,
        driverId: null,
        arrivedAt: null,
        reassignmentCount: nextCount,
        reassignmentHistory: history,
        attemptedDriverIds: admin.firestore.FieldValue.arrayUnion(callerId),
        status: "SEARCHING_DRIVER",
        cancellationSource: "driver_cancelled_reassigning",
        cancellationReason: reason,
        statusMessage: `Driver had to cancel. Finding you another nearby driver (Attempt ${nextCount} of 3)...`,
        statusHistory: admin.firestore.FieldValue.arrayUnion({
          from: String(data.status ?? ""),
          to: "SEARCHING_DRIVER",
          actor: callerId,
          role: "driver",
          reason,
          attempt: nextCount,
          timestamp: nowMs(),
        }),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      logTripTransition({
        tripId,
        from: String(data.status ?? ""),
        to: "SEARCHING_DRIVER",
        actor: callerId,
        role: "driver",
        reason: `driver_cancelled_reassigning_attempt_${nextCount}`,
        timestamp: nowMs(),
      });

      // Chain next nearest dispatch
      const freshSnap = await ref.get();
      if (freshSnap.exists) {
        await advanceSequentialDispatch(
          ref,
          freshSnap.data()!,
          await getDispatchTuning()
        );
      }
      return { ok: true, reassigned: true, attempt: nextCount };
    } else {
      // Reached 3 cancellations: revert to needs_customer_action so customer gets prompt modal
      await ref.update({
        status: "needs_customer_action",
        reassignmentCount: nextCount,
        reassignmentHistory: history,
        attemptedDriverIds: admin.firestore.FieldValue.arrayUnion(callerId),
        driver: null,
        driverLocation: null,
        driverId: null,
        arrivedAt: null,
        pingDriverId: null,
        pingDriverIds: [],
        pingExpiresAt: null,
        tierExpiresAt: null,
        cancellationSource: "driver_cancelled_max_reached",
        cancellationReason: reason,
        statusMessage:
          "All drivers are busy right now. Keep searching or wait?",
        statusHistory: admin.firestore.FieldValue.arrayUnion({
          from: String(data.status ?? ""),
          to: "needs_customer_action",
          actor: callerId,
          role: "driver",
          reason: "max_reassignments_reached",
          attempt: nextCount,
          timestamp: nowMs(),
        }),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      logTripTransition({
        tripId,
        from: String(data.status ?? ""),
        to: "needs_customer_action",
        actor: callerId,
        role: "driver",
        reason: "driver_cancelled_max_reached",
        timestamp: nowMs(),
      });

      // Notify customer
      try {
        await db()
          .collection("users")
          .doc(data.customerId)
          .collection("notifications")
          .add({
            title: "All drivers are currently busy",
            body: "Do you still want to order? All drivers are busy right now. Keep searching or wait?",
            tripId,
            type: "trip_needs_customer_action",
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
      } catch {
        /* best-effort */
      }

      return { ok: true, needsCustomerAction: true };
    }
  }

  // Fallback cancellation (e.g. driver no-show after waiting)
  await handleTripCancellationSettlement({
    tripId,
    cancelledBy: "driver",
    actorId: callerId,
    role: "driver",
    reason: cancellationSource,
  });

  return { ok: true, cancelledBy: "driver" };
});

// ── Multi-Driver Bidding System & Customer Actions ─────────────────────────

/** Driver submits a custom fare bid on an open trip document */
export const submitBid = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Drivers must sign in to bid.");
  }
  const driverId = request.auth.uid;

  // ── Security gates ────────────────────────────────────────────────────────
  enforceAppCheck(request);
  await requireAccountActive(driverId, "driver");
  const { tripId, offeredFare, etaMinutes } = request.data ?? {};
  if (!tripId || typeof offeredFare !== "number" || offeredFare <= 0) {
    throw new HttpsError(
      "invalid-argument",
      "tripId and valid offeredFare (number > 0) are required."
    );
  }

  // 1. Verify driver is active, online, and verified
  const driverDoc = await db().collection("drivers").doc(driverId).get();
  if (!driverDoc.exists) {
    throw new HttpsError("permission-denied", "Driver profile not found.");
  }
  const driverData = driverDoc.data()!;
  if (driverData.isOnline !== true) {
    throw new HttpsError(
      "failed-precondition",
      "You must be online to submit bids."
    );
  }
  const driverStatus = String(
    driverData.verificationStatus ?? driverData.status ?? ""
  ).toLowerCase();
  const isVerified =
    driverStatus === "verified" ||
    driverStatus === "approved" ||
    driverStatus === "active_verified" ||
    driverData.isVerified === true ||
    driverData.isProfileVerified === true;
  if (!isVerified) {
    throw new HttpsError(
      "permission-denied",
      "Only active verified drivers can submit bids."
    );
  }

  const tripRef = db().collection("trips").doc(String(tripId));
  const tripSnap = await tripRef.get();
  if (!tripSnap.exists) {
    throw new HttpsError("not-found", "Trip not found.");
  }
  const tripData = tripSnap.data()!;

  // Active Vehicle Approval & Category Isolation Guard
  const activeVehicleId = String(driverData.activeVehicleId ?? "");
  const activeVehicleCategory = String(driverData.activeVehicleCategory ?? "").toLowerCase();

  const fleetSnap = await db()
    .collection("drivers")
    .doc(driverId)
    .collection("vehicles")
    .limit(20)
    .get();

  let activeDoc = fleetSnap.docs.find((vDoc) => vDoc.id === activeVehicleId);
  if (!activeDoc) {
    activeDoc = fleetSnap.docs.find((vDoc) => vDoc.data()?.isActiveSelected === true);
  }

  if (!activeDoc) {
    throw new HttpsError(
      "failed-precondition",
      "No active vehicle selected for this session. Go offline and select a verified vehicle."
    );
  }

  const activeVData = activeDoc.data() ?? {};
  const vStatus = String(activeVData.verificationStatus ?? activeVData.status ?? "").toUpperCase();
  const isVehicleApproved = vStatus === "APPROVED" || vStatus === "VERIFIED" || activeVData.isVerified === true;
  if (!isVehicleApproved) {
    throw new HttpsError(
      "failed-precondition",
      "Your active vehicle is pending admin approval and cannot submit bids."
    );
  }

  // Low balance guard: Drivers with balance below minWalletBalanceToOnline (< 1.00) cannot submit bids.
  const walletDoc = await db().collection("wallets").doc(driverId).get();
  const wData = walletDoc.exists ? (walletDoc.data() ?? {}) : {};
  const mainBal =
    typeof wData.mainWalletBalance === "number"
      ? wData.mainWalletBalance
      : ((typeof wData.balance === "number" ? wData.balance : 0) / 100);
  const minBalance = await getMinWalletBalanceToOnline();
  if (mainBal < minBalance) {
    throw new HttpsError(
      "failed-precondition",
      "Your balance is low. Please top up to accept trips."
    );
  }

  // Category & Tier Isolation Check
  const reqCat = String(tripData.vehicleCategory ?? "").toLowerCase();
  const reqTiers = Array.isArray(tripData.selectedTiers)
    ? tripData.selectedTiers.map((t: unknown) => String(t).toLowerCase())
    : [];
  const allowedCats = new Set<string>();
  if (reqCat) allowedCats.add(reqCat);
  for (const t of reqTiers) if (t) allowedCats.add(t);

  const effectiveDriverCat = activeVehicleCategory || String(activeVData.category ?? "").toLowerCase();
  if (allowedCats.size > 0 && !allowedCats.has(effectiveDriverCat)) {
    throw new HttpsError(
      "failed-precondition",
      `Your active vehicle (${effectiveDriverCat}) cannot bid on orders for this trip category.`
    );
  }

  // Self-assignment guard: drivers cannot bid on orders they created as customer
  const orderCustomerId = String(tripData.customerId ?? tripData.userId ?? (tripData.customer && typeof tripData.customer === "object" ? tripData.customer.uid : "") ?? "");
  if (orderCustomerId && orderCustomerId === driverId) {
    throw new HttpsError(
      "failed-precondition",
      "You cannot bid on an order you created as a customer."
    );
  }

  // 2. Validate offered fare against baseline, rounded to nearest 100
  const baseline = Number(tripData.baselineFare ?? tripData.fareAmount ?? 0);
  const roundedOfferedFare = roundToNearest100(offeredFare, baseline);
  if (baseline > 0 && roundedOfferedFare < baseline) {
    throw new HttpsError(
      "invalid-argument",
      `Offered fare (₦${roundedOfferedFare}) cannot be lower than the baseline fare (₦${baseline}).`
    );
  }

  if (tripData.driver?.driverId) {
    throw new HttpsError(
      "failed-precondition",
      "This trip has already been claimed by another driver."
    );
  }

  const currentStatus = String(tripData.status ?? "").trim().toUpperCase();
  const allowedStatuses = [
    "SEARCHING_DRIVER",
    "SEARCHING",
    "WAITING_FOR_ACCEPTANCE",
    "WAITING_ACCEPTANCE",
    "DRIVER_PINGED",
    "MARKETPLACE_OPEN",
    "MARKETPLACE_LIST",
    "NEEDS_CUSTOMER_ACTION",
    "BIDDING",
  ];
  if (!allowedStatuses.includes(currentStatus)) {
    throw new HttpsError(
      "failed-precondition",
      `This trip is no longer open for bidding (status: ${tripData.status}).`
    );
  }

  // Single Active Bid Guard: check if driver already has an unexpired pending bid
  const currentTime = Date.now();
  try {
    const existingPendingBids = await db()
      .collectionGroup("bids")
      .where("driverId", "==", driverId)
      .where("status", "==", "pending")
      .get();

    for (const bDoc of existingPendingBids.docs) {
      const bData = bDoc.data();
      const expMs = bData.expiresAt?.toMillis?.() ?? 0;
      if (expMs > currentTime) {
        throw new HttpsError(
          "failed-precondition",
          "You already have an active bid waiting for a customer decision."
        );
      }
    }
  } catch (err: any) {
    if (err instanceof HttpsError) throw err;
    console.warn(
      `[submitBid] collectionGroup bids query failed (${err?.message}) — falling back to per-trip check.`
    );
    try {
      const existingTripBid = await tripRef.collection("bids").doc(driverId).get();
      if (existingTripBid.exists) {
        const bData = existingTripBid.data();
        const expMs = bData?.expiresAt?.toMillis?.() ?? 0;
        if (bData?.status === "pending" && expMs > currentTime) {
          throw new HttpsError(
            "failed-precondition",
            "You already have an active bid waiting for a customer decision."
          );
        }
      }
    } catch (fbErr: any) {
      if (fbErr instanceof HttpsError) throw fbErr;
    }
  }

  const tuning = await getDispatchTuning();
  const expiresAtMs = currentTime + tuning.bidCountdownMs;
  const expiresAt = admin.firestore.Timestamp.fromMillis(expiresAtMs);

  const snapshot = await driverSnapshot(driverId);
  const bidRef = tripRef.collection("bids").doc(driverId);

  await bidRef.set({
    bidId: driverId,
    tripId,
    driverId,
    customerId: String(tripData.customerId ?? ""),
    driverName: snapshot.fullName,
    photoUrl: snapshot.photoUrl,
    rating: snapshot.rating,
    phone: snapshot.phone,
    vehicleModel: snapshot.vehicleModel,
    vehicleColor: snapshot.vehicleColor,
    plateNumber: snapshot.plateNumber,
    offeredFare: roundedOfferedFare,
    etaMinutes: typeof etaMinutes === "number" ? etaMinutes : 5,
    status: "pending",
    bidCountdownSeconds: tuning.bidCountdownSec,
    expiresAt,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  const isMarketplace =
    currentStatus === "MARKETPLACE_OPEN" ||
    currentStatus === "MARKETPLACE_LIST";
  await tripRef.update({
    hasActiveBids: true,
    status: isMarketplace ? tripData.status : "bidding",
    lastBidAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  const vehicleDetails = [snapshot.vehicleColor, snapshot.vehicleModel]
    .filter(Boolean)
    .join(" ");
  const vehicleStr = snapshot.plateNumber
    ? `${vehicleDetails} (${snapshot.plateNumber})`.trim()
    : vehicleDetails;

  // Rich counter-bid alert: in-app notification + FCM push to the customer
  // with complete driver details, ETA, vehicle info, offered fare, and Accept/Reject payload
  await notifyCustomer(
    String(tripData.customerId ?? ""),
    String(tripId),
    "New Driver Offer",
    `${snapshot.fullName} offered ₦${Number(roundedOfferedFare).toLocaleString()} (~${etaMinutes ?? 5} mins away)`,
    "driver_counter_bid",
    {
      driverId,
      driverName: String(snapshot.fullName),
      driverPhoto: String(snapshot.photoUrl ?? ""),
      driverRating: String(snapshot.rating ?? 0),
      offeredFare: String(roundedOfferedFare),
      offeredFareFormatted: `₦${Number(roundedOfferedFare).toLocaleString()}`,
      etaMinutes: String(etaMinutes ?? 5),
      vehicleModel: String(snapshot.vehicleModel ?? ""),
      vehicleColor: String(snapshot.vehicleColor ?? ""),
      plateNumber: String(snapshot.plateNumber ?? ""),
      vehicleDetails: vehicleStr,
    }
  );

  return { ok: true, bidId: driverId };
});

/** Customer rejects a driver's bid (driver may re-bid later) */
export const rejectBid = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in.");
  }
  const customerId = request.auth.uid;
  const { tripId, driverId } = request.data ?? {};
  if (!tripId || !driverId) {
    throw new HttpsError(
      "invalid-argument",
      "tripId and driverId are required."
    );
  }

  const tripRef = db().collection("trips").doc(String(tripId));
  const tripSnap = await tripRef.get();
  if (!tripSnap.exists) {
    throw new HttpsError("not-found", "Trip not found.");
  }
  const tripData = tripSnap.data()!;
  const orderCustomerId = String(
    tripData.customerId ??
      tripData.userId ??
      (tripData.customer && typeof tripData.customer === "object"
        ? tripData.customer.uid
        : "") ??
      ""
  );
  if (orderCustomerId !== customerId) {
    throw new HttpsError(
      "permission-denied",
      "Only the requesting customer can reject bids."
    );
  }

  const bidRef = tripRef.collection("bids").doc(String(driverId));
  await bidRef.update({
    status: "rejected",
    rejectedAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { ok: true };
});

/** Customer accepts a driver's bid via an atomic Firestore Transaction */
export const acceptBid = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in.");
  }
  const customerId = request.auth.uid;
  const { tripId, driverId } = request.data ?? {};
  if (!tripId || !driverId) {
    throw new HttpsError(
      "invalid-argument",
      "tripId and driverId are required."
    );
  }

  const tripRef = db().collection("trips").doc(String(tripId));
  const bidRef = tripRef.collection("bids").doc(String(driverId));

  await db().runTransaction(async (tx) => {
    const tripSnap = await tx.get(tripRef);
    if (!tripSnap.exists) {
      throw new HttpsError("not-found", "Trip not found.");
    }
    const tripData = tripSnap.data()!;
    const orderCustomerId = String(
      tripData.customerId ??
        tripData.userId ??
        (tripData.customer && typeof tripData.customer === "object"
          ? tripData.customer.uid
          : "") ??
        ""
    );
    if (orderCustomerId !== customerId) {
      throw new HttpsError(
        "permission-denied",
        "Only the requesting customer can accept bids."
      );
    }
    if (String(driverId) === customerId || String(driverId) === orderCustomerId) {
      throw new HttpsError(
        "failed-precondition",
        "Customer cannot accept their own driver bid."
      );
    }

    const allowedBiddingStatuses = [
      "SEARCHING_DRIVER",
      "WAITING_FOR_ACCEPTANCE",
      "MARKETPLACE_OPEN",
      "MARKETPLACE_LIST",
      "needs_customer_action",
      "bidding",
    ];
    if (!allowedBiddingStatuses.includes(String(tripData.status))) {
      throw new HttpsError(
        "failed-precondition",
        `This trip is no longer open for bidding (current status: ${tripData.status}).`
      );
    }

    if (tripData.driver?.driverId || tripData.driverId) {
      throw new HttpsError(
        "failed-precondition",
        "A driver has already been assigned to this trip."
      );
    }

    const bidSnap = await tx.get(bidRef);
    if (!bidSnap.exists) {
      throw new HttpsError("not-found", "Bid not found.");
    }
    const bidData = bidSnap.data()!;
    if (bidData.status !== "pending") {
      throw new HttpsError(
        "failed-precondition",
        "This bid is no longer pending."
      );
    }

    // ── Server-side expiry enforcement ───────────────────────────────────────
    // Block any Accept that arrives after the bid timer has elapsed, even by a
    // fraction of a second. The server timestamp is the authoritative clock.
    if (bidData.expiresAt) {
      const expiresAtMs: number =
        typeof bidData.expiresAt.toMillis === "function"
          ? bidData.expiresAt.toMillis()
          : Number(bidData.expiresAt);
      const nowMs = Date.now();
      if (nowMs >= expiresAtMs) {
        // Mark the bid as expired atomically so the client stream reflects it
        // immediately, clearing any stale banner without requiring a re-fetch.
        tx.update(bidRef, {
          status: "expired",
          isExpired: true,
          expiredAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        throw new HttpsError(
          "deadline-exceeded",
          "This offer has expired. The driver will need to re-submit a bid."
        );
      }
    }

    // Perform all queries/reads BEFORE any writes to satisfy Firestore transaction requirements
    const otherBids = await tx.get(
      tripRef.collection("bids").where("status", "==", "pending")
    );

    const driverSnap = await tx.get(db().collection("drivers").doc(driverId));
    const d = driverSnap.exists ? driverSnap.data()! : {};
    const driverPayload = {
      driverId,
      fullName: String(bidData.driverName || d.fullName || d.name || "Driver"),
      photoUrl: String(bidData.photoUrl || d.photoUrl || ""),
      rating: Number(bidData.rating || d.rating || 0),
      phone: String(bidData.phone || d.phoneNumber || d.phone || ""),
      plateNumber: String(bidData.plateNumber || ""),
      vehicleModel: String(bidData.vehicleModel || ""),
      vehicleColor: String(bidData.vehicleColor || ""),
    };

    // Calculate cashToCollect based on the newly accepted offered fare and existing wallet escrow hold
    const walletCoverage = Number(tripData.walletCoverageAmount ?? 0);
    const updatedOfferedFare = Number(bidData.offeredFare);
    const newCashToCollect = Math.max(0, updatedOfferedFare - walletCoverage);

    tx.update(bidRef, {
      status: "accepted",
      acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // If this accepted bidder previously skipped or rejected this order,
    // supersede that preliminary rejection record so the trip state cleanly resolves.
    const existingBidRejections = Array.isArray(tripData.rejections) ? tripData.rejections : [];
    const updatedBidRejections = existingBidRejections.map((r: any) =>
      r && r.driverId === driverId ? { ...r, superseded: true, supersededAt: nowMs() } : r
    );

    const isPoolBid =
      tripData.status === "MARKETPLACE_OPEN" ||
      tripData.status === "MARKETPLACE_LIST" ||
      tripData.isPoolOrder === true ||
      tripData.droppedToPoolAt != null ||
      tripData.dispatchStep === 4;

    tx.update(tripRef, {
      status: "DRIVER_ACCEPTED",
      driver: driverPayload,
      driverId,
      isPoolOrder: isPoolBid,
      cancellationSource: null,
      cancellationReason: null,
      rejections: updatedBidRejections,
      fareAmount: updatedOfferedFare,
      fareFormatted: `₦${updatedOfferedFare.toLocaleString()}`,
      cashToCollect: newCashToCollect,
      senderCashToCollect: tripData.paymentMode === "split"
        ? Math.max(0, Number(tripData.senderShareAmount ?? (updatedOfferedFare / 2)) - walletCoverage)
        : newCashToCollect,
      biddingCompleted: true,
      hasActiveBids: false,
      acceptedBidDriverId: driverId,
      pingDriverId: null,
      pingDriverIds: [],
      pingExpiresAt: null,
      tierExpiresAt: null,
      statusHistory: admin.firestore.FieldValue.arrayUnion({
        from: tripData.status ?? "MARKETPLACE_OPEN",
        to: "DRIVER_ACCEPTED",
        actor: customerId,
        role: "customer",
        reason: "accepted_driver_bid",
        timestamp: nowMs(),
      }),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    for (const b of otherBids.docs) {
      if (b.id !== driverId) {
        tx.update(b.ref, {
          status: "rejected",
          rejectedReason: "another_bid_accepted",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }

    persistTripChangeLogInTx(tx, {
      tripId: String(tripId),
      from: String(tripData.status ?? "MARKETPLACE_OPEN"),
      to: "DRIVER_ACCEPTED",
      actor: customerId,
      role: "customer",
      reason: "accepted_driver_bid",
      timestamp: nowMs(),
    });
  });

  logTripTransition({
    tripId: String(tripId),
    from: "MARKETPLACE_OPEN",
    to: "DRIVER_ACCEPTED",
    actor: customerId,
    role: "customer",
    reason: "accepted_driver_bid",
    timestamp: nowMs(),
  });

  return { ok: true };
});

/** Customer raises the offered price / fare to attract drivers faster */
export const increaseTripFare = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in.");
  }
  const customerId = request.auth.uid;
  const { tripId, newFare } = request.data ?? {};
  if (!tripId || typeof newFare !== "number" || newFare <= 0) {
    throw new HttpsError(
      "invalid-argument",
      "tripId and valid newFare are required."
    );
  }

  const tripRef = db().collection("trips").doc(String(tripId));
  const tripSnap = await tripRef.get();
  if (!tripSnap.exists) {
    throw new HttpsError("not-found", "Trip not found.");
  }
  const tripData = tripSnap.data()!;
  if (tripData.customerId !== customerId) {
    throw new HttpsError("permission-denied", "Not your trip.");
  }

  const currentFare = Number(tripData.fareAmount ?? tripData.baselineFare ?? 0);
  const roundedNewFare = roundToNearest100(newFare);
  if (roundedNewFare <= currentFare) {
    throw new HttpsError(
      "invalid-argument",
      "New fare must be higher than current fare."
    );
  }

  const tuning = await getDispatchTuning();
  const maxOfferBoostPct = Number(tuning.maxOfferBoostPct ?? 100);
  const originalBase = Number(
    tripData.baselineFare && Number(tripData.baselineFare) > 0
      ? tripData.baselineFare
      : (tripData.fareAmount ?? 0)
  );
  const maxAllowedFare = Math.round(originalBase * (1 + maxOfferBoostPct / 100));

  if (roundedNewFare > maxAllowedFare) {
    throw new HttpsError(
      "failed-precondition",
      `Offer boost cannot exceed ${maxOfferBoostPct}% above original base fare (max ₦${maxAllowedFare.toLocaleString()}).`
    );
  }

  const wasNeedsAction = tripData.status === "needs_customer_action";
  const boostPct =
    currentFare > 0
      ? Math.round(((roundedNewFare - currentFare) / currentFare) * 100)
      : 0;

  const rawFareTiers = Array.isArray(tripData.fareTiers) ? tripData.fareTiers : [];
  const selectedTiers: string[] = Array.isArray(tripData.selectedTiers) ? tripData.selectedTiers : [];
  const updatedFareTiers = rawFareTiers.map((t: any) => {
    if (t && typeof t === "object" && (selectedTiers.length === 0 || selectedTiers.includes(t.tierId))) {
      return { ...t, fareAmount: roundedNewFare };
    }
    return t;
  });

  const updatePayload: Record<string, any> = {
    fareAmount: roundedNewFare,
    proposedFare: roundedNewFare,
    fareFormatted: `₦${roundedNewFare.toLocaleString()}`,
    fareBoosted: true,
    boostPercent: boostPct,
    boostedAt: admin.firestore.FieldValue.serverTimestamp(),
    status: wasNeedsAction ? "SEARCHING_DRIVER" : tripData.status,
    reassignmentCount: wasNeedsAction ? 0 : (tripData.reassignmentCount ?? 0),
    statusMessage: "Price increased! Searching for nearby drivers...",
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
  if (updatedFareTiers.length > 0) {
    updatePayload.fareTiers = updatedFareTiers;
  }

  await tripRef.update(updatePayload);

  if (wasNeedsAction) {
    const fresh = (await tripRef.get()).data()!;
    await advanceSequentialDispatch(
      tripRef,
      fresh,
      await getDispatchTuning()
    );
  }

  return { ok: true, newFare };
});

/**
 * Reassign / Retry Dispatch Engine callable:
 * Instantly retries the dispatch sequence from the beginning (re-running the
 * 1st -> 2nd -> 3rd nearest driver loop followed by the public order pool).
 *
 * Supports instant one-tap fare boosting when `newFare` is provided, atomically
 * saving the new higher price in Firestore and immediately restarting matchmaking.
 */
async function handleReassignTrip(request: { auth?: { uid: string }; data?: any }) {
  const customerId = request.auth?.uid;
  if (!customerId) {
    throw new HttpsError("unauthenticated", "Must be logged in.");
  }
  const { tripId, newFare } = (request.data ?? {}) as {
    tripId?: string;
    newFare?: number;
  };
  if (!tripId) {
    throw new HttpsError("invalid-argument", "tripId is required.");
  }

  const tripRef = db().collection("trips").doc(String(tripId));
  const tripSnap = await tripRef.get();
  if (!tripSnap.exists) {
    throw new HttpsError("not-found", "Trip not found.");
  }
  const tripData = tripSnap.data()!;
  const orderCustomerId = String(
    tripData.customerId ??
      tripData.userId ??
      (tripData.customer && typeof tripData.customer === "object"
        ? tripData.customer.uid
        : "") ??
      (tripData.tripBooker && typeof tripData.tripBooker === "object"
        ? tripData.tripBooker.uid
        : "") ??
      ""
  );
  if (orderCustomerId !== customerId) {
    throw new HttpsError("permission-denied", "Not your trip.");
  }

  const validStatuses = [
    "returned_to_customer",
    "expired",
    "needs_customer_action",
    "SEARCHING_DRIVER",
    "MARKETPLACE_OPEN",
    "MARKETPLACE_LIST",
    "CANCELLED",
  ];
  const fromStatus = String(tripData.status ?? "");
  if (!validStatuses.includes(fromStatus)) {
    throw new HttpsError(
      "failed-precondition",
      `Cannot reassign trip with status ${fromStatus}.`
    );
  }

  const tuning = await getDispatchTuning();
  let fareUpdate: Record<string, any> = {};

  if (typeof newFare === "number" && Number.isFinite(newFare) && newFare > 0) {
    const currentFare = Number(tripData.fareAmount ?? tripData.baselineFare ?? 0);
    const roundedNewFare = roundToNearest100(newFare);
    if (roundedNewFare < currentFare) {
      throw new HttpsError(
        "invalid-argument",
        "New fare cannot be lower than current fare."
      );
    }
    const maxOfferBoostPct = Number(tuning.maxOfferBoostPct ?? 100);
    const originalBase = Number(
      tripData.baselineFare && Number(tripData.baselineFare) > 0
        ? tripData.baselineFare
        : (tripData.fareAmount ?? 0)
    );
    const maxAllowedFare = Math.round(originalBase * (1 + maxOfferBoostPct / 100));
    if (roundedNewFare > maxAllowedFare) {
      throw new HttpsError(
        "failed-precondition",
        `Offer boost cannot exceed ${maxOfferBoostPct}% above original base fare (max ₦${maxAllowedFare.toLocaleString()}).`
      );
    }
    const boostPct =
      currentFare > 0
        ? Math.round(((roundedNewFare - currentFare) / currentFare) * 100)
        : 0;

    const rawFareTiers = Array.isArray(tripData.fareTiers) ? tripData.fareTiers : [];
    const selectedTiers: string[] = Array.isArray(tripData.selectedTiers)
      ? tripData.selectedTiers
      : [];
    const updatedFareTiers = rawFareTiers.map((t: any) => {
      if (
        t &&
        typeof t === "object" &&
        (selectedTiers.length === 0 || selectedTiers.includes(t.tierId))
      ) {
        return { ...t, fareAmount: roundedNewFare };
      }
      return t;
    });

    fareUpdate = {
      fareAmount: roundedNewFare,
      proposedFare: roundedNewFare,
      fareFormatted: `₦${roundedNewFare.toLocaleString()}`,
      fareBoosted: true,
      boostPercent: boostPct,
      boostedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (updatedFareTiers.length > 0) {
      fareUpdate.fareTiers = updatedFareTiers;
    }
  }

  const updatePayload: Record<string, any> = {
    ...fareUpdate,
    status: "SEARCHING_DRIVER",
    isPoolOrder: false,
    dispatchTier: 1,
    dispatchStep: 0,
    attemptedDriverIds: [],
    reassignmentCount: 0,
    reassignmentHistory: [],
    declineCount: 0,
    pingDriverId: null,
    pingDriverIds: [],
    pingExpiresAt: null,
    tierExpiresAt: null,
    poolExpiresAt: null,
    droppedToPoolAt: null,
    isExpired: false,
    cancellationSource: null,
    cancellationReason: null,
    driver: null,
    driverLocation: null,
    driverId: null,
    arrivedAt: null,
    statusMessage: fareUpdate.fareAmount
      ? `Fare updated to ₦${fareUpdate.fareAmount.toLocaleString()}! Reassigning drivers...`
      : "Searching for available drivers nearby...",
    statusHistory: admin.firestore.FieldValue.arrayUnion({
      from: fromStatus,
      to: "SEARCHING_DRIVER",
      actor: customerId,
      role: "customer",
      reason: fareUpdate.fareAmount ? "reassign_with_fare_boost" : "reassign_retry",
      timestamp: nowMs(),
    }),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  await tripRef.update(updatePayload);

  // Instantly trigger sequential dispatch router from Step 1!
  const fresh = (await tripRef.get()).data()!;
  await advanceSequentialDispatch(tripRef, fresh, tuning);

  return {
    ok: true,
    status: "SEARCHING_DRIVER",
    fareAmount: fresh.fareAmount,
    reassigned: true,
  };
}

export const reassignTrip = onCall(handleReassignTrip);
export const retryTripDispatch = reassignTrip;
export const keepSearchingTrip = reassignTrip;

/**
 * Callable: driver submits the 4-digit delivery PIN at drop-off.
 *
 * The recipient gives the driver the code (issued at mint via
 * `delivery_pin_issued`); a correct code marks the delivery verified and
 * completes the trip through the same settlement path as a normal
 * completion, so streak/settlement logic is untouched.
 *
 * Zero-trust: the code lives in `delivery_pins/{tripId}`, readable only by
 * the customer and admins — never on the trip doc the driver reads. The
 * client never sees it except the customer on their own PIN doc. Wrong codes
 * are rejected without revealing the code, and there is no lockout — a
 * lockout would let anyone deny a delivery by spamming guesses.
 */
export const verifyDeliveryPin = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Drivers must sign in.");
  }
  const driverId = request.auth.uid;
  const tripId = String(request.data?.tripId ?? "");
  const pin = String(request.data?.pin ?? "").trim();
  if (!tripId || !/^\d{4}$/.test(pin)) {
    throw new HttpsError(
      "invalid-argument",
      "A 4-digit delivery PIN is required."
    );
  }

  const ref = db().collection("trips").doc(tripId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
  const data = snap.data()!;

  if (data.driver?.driverId !== driverId) {
    throw new HttpsError("permission-denied", "Not your trip.");
  }
  const serviceType = String(data.serviceType ?? "ride");
  if (serviceType === "ride") {
    throw new HttpsError(
      "failed-precondition",
      "Passenger trips do not use a delivery PIN."
    );
  }
  if (data.deliveryPinVerified === true) {
    return { ok: true, alreadyVerified: true };
  }

  const pinSnap = await db().collection("delivery_pins").doc(tripId).get();
  if (String(pinSnap.data()?.pin ?? "") !== pin) {
    throw new HttpsError(
      "invalid-argument",
      "That code does not match. Ask the recipient for the 4-digit PIN."
    );
  }
  if (!(LIVE_STATUSES as readonly string[]).includes(String(data.status ?? ""))) {
    throw new HttpsError(
      "failed-precondition",
      "This delivery is no longer active."
    );
  }

  // ── Drop-off Geofencing Check ───────────────────────────────────────────
  if (data.dropoffApprovalStatus !== "APPROVED") {
    const dropoffLat = Number(data.dropoff?.lat ?? data.dropoffLocation?.latitude ?? data.dropoffLat ?? 0);
    const dropoffLng = Number(data.dropoff?.lng ?? data.dropoffLocation?.longitude ?? data.dropoffLng ?? 0);
    if (dropoffLat !== 0 && dropoffLng !== 0) {
      const driverLat = Number(
        request.data?.driverLat ??
        request.data?.lat ??
        request.data?.latitude ??
        data.driverLocation?.lat ??
        data.driverLocation?.latitude ??
        0
      );
      const driverLng = Number(
        request.data?.driverLng ??
        request.data?.lng ??
        request.data?.longitude ??
        data.driverLocation?.lng ??
        data.driverLocation?.longitude ??
        0
      );
      if (driverLat !== 0 && driverLng !== 0) {
        const distM = Math.round(haversineKm(driverLat, driverLng, dropoffLat, dropoffLng) * 1000);
        const radiusM = await getDropoffRadiusMeters();
        if (distM > radiusM) {
          throw new HttpsError(
            "failed-precondition",
            `OUT_OF_RANGE: Driver is outside drop-off location (${distM}m away, max allowed is ${radiusM}m). Customer confirmation required.`
          );
        }
      }
    }
  }

  const batch = db().batch();
  batch.update(ref, {
    deliveryPinVerified: true,
    deliveryPinVerifiedAt: admin.firestore.FieldValue.serverTimestamp(),
    status: "COMPLETED",
    completedAt: admin.firestore.FieldValue.serverTimestamp(),
    statusHistory: admin.firestore.FieldValue.arrayUnion({
      from: String(data.status ?? ""),
      to: "COMPLETED",
      actor: driverId,
      role: "driver",
      reason: "pin_verified",
      timestamp: nowMs(),
    }),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  batch.update(pinSnap.ref, {
    verified: true,
    verifiedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  await batch.commit();

  logTripTransition({
    tripId,
    from: String(data.status ?? ""),
    to: "COMPLETED",
    actor: driverId,
    role: "driver",
    reason: "pin_verified",
    timestamp: nowMs(),
  });

  try {
    const snapAfter = await ref.get();
    if (snapAfter.exists) {
      await handleTripCompletion(tripId, snapAfter.data()!);
    }
  } catch (e) {
    console.warn(`verifyDeliveryPin[${tripId}]: synchronous settlement warning: ${e}`);
  }

  return { ok: true };
});

// ── Hub Admin Dispute Actions ──────────────────────────────────────────────

/** Hub Admin: Force Complete a trip during live support/dispute resolution */
export const hubForceCompleteTrip = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Hub authentication required.");
  }
  const adminUid = request.auth.uid;
  const tripId = String(request.data?.tripId ?? "").trim();
  if (!tripId) throw new HttpsError("invalid-argument", "tripId required.");

  const ref = db().collection("trips").doc(tripId);
  let snapAfterData: any = null;
  await db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
    const data = snap.data()!;
    const currentStatus = String(data.status ?? "");

    if (currentStatus === "COMPLETED") {
      snapAfterData = data;
      return;
    }
    if (!(LIVE_STATUSES as readonly string[]).includes(currentStatus)) {
      throw new HttpsError(
        "failed-precondition",
        `Cannot force complete trip with closed status ${currentStatus}.`
      );
    }

    const assignedDriverId = String(data.driver?.driverId ?? data.driverId ?? "");
    const rejectionsList = Array.isArray(data.rejections) ? data.rejections : [];
    const updatedRejections = assignedDriverId
      ? rejectionsList.map((r: any) =>
          r && r.driverId === assignedDriverId ? { ...r, superseded: true, supersededAt: nowMs() } : r
        )
      : rejectionsList;

    const updates = {
      status: "COMPLETED",
      deliveryPinVerified: true,
      forceCompletedBy: adminUid,
      forceCompletedAt: admin.firestore.FieldValue.serverTimestamp(),
      completedAt: admin.firestore.FieldValue.serverTimestamp(),
      cancellationSource: null,
      cancellationReason: null,
      rejections: updatedRejections,
      statusHistory: admin.firestore.FieldValue.arrayUnion({
        from: currentStatus,
        to: "COMPLETED",
        actor: adminUid,
        role: "hub_admin",
        timestamp: nowMs(),
      }),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    tx.update(ref, updates);
    snapAfterData = { ...data, ...updates };

    persistTripChangeLogInTx(tx, {
      tripId,
      from: currentStatus,
      to: "COMPLETED",
      actor: adminUid,
      role: "hub_admin",
      timestamp: nowMs(),
    });
  });

  if (snapAfterData?.status === "COMPLETED" && snapAfterData.forceCompletedBy !== adminUid) {
    return { ok: true, alreadyCompleted: true, tripId };
  }

  try {
    if (snapAfterData) {
      await handleTripCompletion(tripId, snapAfterData);
    }
  } catch (e) {
    console.warn(`hubForceCompleteTrip[${tripId}]: synchronous settlement warning: ${e}`);
  }

  return { ok: true, tripId };
});

/** Driver confirms cash collected from customer for waiting time cancellation */
export const confirmCashCancellation = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Drivers must sign in.");
  }
  const driverId = request.auth.uid;
  const tripId = String(request.data?.tripId ?? "");
  const cashCollected = request.data?.cashCollected !== false;
  if (!tripId) throw new HttpsError("invalid-argument", "tripId is required.");

  const ref = db().collection("trips").doc(tripId);

  await db().runTransaction(async (tx) => {
    // 1. ALL READS FIRST
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
    const data = snap.data()!;

    const assignedDriverId = String(data.driver?.driverId ?? data.driverId ?? "");
    if (assignedDriverId !== driverId) {
      throw new HttpsError("permission-denied", "Not your trip.");
    }

    const currentStatus = String(data.status ?? "");
    if (currentStatus === "CANCELLED" && (data.cashSettlementConfirmed === true || data.settlement?.settled === true)) {
      return;
    }
    if (currentStatus !== "CANCELLED_WAITING_CASH_SETTLEMENT") {
      throw new HttpsError(
        "failed-precondition",
        `Cannot confirm cash cancellation for trip in status ${currentStatus}.`
      );
    }

    const customerId = String(data.customerId ?? data.userId ?? "");
    const custWalletRef = customerId ? db().collection("wallets").doc(customerId) : null;
    if (custWalletRef) await tx.get(custWalletRef);
    const driverWalletRef = driverId ? db().collection("wallets").doc(driverId) : null;
    if (driverWalletRef) await tx.get(driverWalletRef);
    const custUserRef = customerId ? db().collection("users").doc(customerId) : null;
    if (custUserRef) await tx.get(custUserRef);

    const fee = Math.max(0, Number(data.pendingCashFee ?? data.paidWaitingFee ?? 0));
    const feeKobo = nairaToKobo(fee);

    // 2. ATOMIC WRITES
    if (cashCollected) {
      tx.update(ref, {
        status: "CANCELLED",
        cashSettlementConfirmed: true,
        cashCollected: true,
        cashSettlementConfirmedAt: admin.firestore.FieldValue.serverTimestamp(),
        pendingCashFee: 0,
        "settlement.cashSettlementConfirmed": true,
        "settlement.settled": true,
        "settlement.settledAt": admin.firestore.FieldValue.serverTimestamp(),
        pingDriverId: null,
        pingExpiresAt: null,
        statusHistory: admin.firestore.FieldValue.arrayUnion({
          from: currentStatus,
          to: "CANCELLED",
          actor: driverId,
          role: "driver",
          reason: "cash_waiting_fee_collected",
          timestamp: nowMs(),
        }),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      persistTripChangeLogInTx(tx, {
        tripId,
        from: currentStatus,
        to: "CANCELLED",
        actor: driverId,
        role: "driver",
        reason: "cash_waiting_fee_collected",
        timestamp: nowMs(),
      });

      if (fee > 0) {
        persistFinancialAuditLogInTx(tx, {
          tripId,
          type: "waiting_fee_cash_collected",
          accountId: driverId,
          amountNaira: fee,
          amountKobo: feeKobo,
          currency: "NGN",
          actor: driverId,
          role: "driver",
          reason: "cash_waiting_fee_collected",
          timestamp: Date.now(),
          stage: "cancellation",
          invariantsChecked: true,
        });
      }
    } else {
      // Driver reports "Cash Not Collected" -> debit customer wallet (allowing negative balance) and credit driver wallet
      tx.update(ref, {
        status: "CANCELLED",
        cashSettlementConfirmed: false,
        cashCollected: false,
        cashNotCollectedReason: "driver_reported_unpaid",
        cashSettlementConfirmedAt: admin.firestore.FieldValue.serverTimestamp(),
        pendingCashFee: 0,
        "settlement.cashSettlementConfirmed": false,
        "settlement.settled": true,
        "settlement.settledAt": admin.firestore.FieldValue.serverTimestamp(),
        pingDriverId: null,
        pingExpiresAt: null,
        statusHistory: admin.firestore.FieldValue.arrayUnion({
          from: currentStatus,
          to: "CANCELLED",
          actor: driverId,
          role: "driver",
          reason: "cash_waiting_fee_not_collected_debited",
          timestamp: nowMs(),
        }),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      persistTripChangeLogInTx(tx, {
        tripId,
        from: currentStatus,
        to: "CANCELLED",
        actor: driverId,
        role: "driver",
        reason: "cash_waiting_fee_not_collected_debited",
        timestamp: nowMs(),
      });

      if (fee > 0) {
        if (custWalletRef) {
          tx.set(
            custWalletRef,
            {
              mainWalletBalance: admin.firestore.FieldValue.increment(-fee),
              balance: admin.firestore.FieldValue.increment(-feeKobo),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true }
          );

          tx.set(
            custWalletRef.collection("transactions").doc(`${tripId}_unpaid_waiting_fee_debited`),
            {
              type: "waiting_fee_paid",
              role: "customer",
              amountNaira: -fee,
              amountKobo: -feeKobo,
              amount: -feeKobo,
              tripId,
              currency: "NGN",
              note: `Unpaid cash waiting fee debited for trip ${tripId}`,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            }
          );
        }

        if (custUserRef) {
          tx.set(
            custUserRef,
            { outstandingNegativeBalance: admin.firestore.FieldValue.increment(fee) },
            { merge: true }
          );
        }

        if (driverWalletRef) {
          tx.set(
            driverWalletRef,
            {
              mainWalletBalance: admin.firestore.FieldValue.increment(fee),
              balance: admin.firestore.FieldValue.increment(feeKobo),
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            { merge: true }
          );

          tx.set(
            driverWalletRef.collection("transactions").doc(`${tripId}_unpaid_waiting_fee_credited`),
            {
              type: "waiting_fee_credited",
              role: "driver",
              amountNaira: fee,
              amountKobo: feeKobo,
              amount: feeKobo,
              tripId,
              currency: "NGN",
              note: `Unpaid cash waiting fee credited for trip ${tripId}`,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
            }
          );
        }

        if (customerId) {
          persistFinancialAuditLogInTx(tx, {
            tripId,
            type: "waiting_fee_unpaid_debited",
            accountId: customerId,
            amountNaira: -fee,
            amountKobo: -feeKobo,
            currency: "NGN",
            actor: driverId,
            role: "driver",
            reason: "cash_waiting_fee_not_collected",
            timestamp: Date.now(),
            stage: "cancellation",
            invariantsChecked: true,
          });
        }

        persistFinancialAuditLogInTx(tx, {
          tripId,
          type: "waiting_fee_unpaid_credited",
          accountId: driverId,
          amountNaira: fee,
          amountKobo: feeKobo,
          currency: "NGN",
          actor: driverId,
          role: "driver",
          reason: "cash_waiting_fee_not_collected",
          timestamp: Date.now(),
          stage: "cancellation",
          invariantsChecked: true,
        });
      }
    }
  });

  return { ok: true, tripId, cashCollected };
});

/** Hub Admin: Cancel trip & refund any held escrow */
export const hubCancelRefundTrip = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Hub authentication required.");
  }
  const adminUid = request.auth.uid;
  const tripId = String(request.data?.tripId ?? "").trim();
  const reason = String(request.data?.reason ?? "Cancelled by Hub admin");
  if (!tripId) throw new HttpsError("invalid-argument", "tripId required.");

  const result = await handleTripCancellationSettlement({
    tripId,
    cancelledBy: "hub_admin",
    actorId: adminUid,
    role: "hub_admin",
    reason,
  });

  return { ok: true, tripId, alreadyCancelled: result.alreadyCancelled };
});

/** Hub Admin: Manual PIN Bypass during call verification */
export const hubManualPinBypass = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Hub authentication required.");
  }
  const adminUid = request.auth.uid;
  const tripId = String(request.data?.tripId ?? "").trim();
  if (!tripId) throw new HttpsError("invalid-argument", "tripId required.");

  const ref = db().collection("trips").doc(tripId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");

  await ref.update({
    deliveryPinVerified: true,
    manualPinBypassBy: adminUid,
    manualPinBypassAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { ok: true, tripId };
});

/**
 * Submit cancellation feedback for a trip.
 *
 * Accepts a structured reason and optional detail from either the customer or
 * driver after a trip is cancelled. Writes to `cancellation_feedback` with a
 * compound doc ID of `{tripId}_{userId}` so first-write wins — idempotent on
 * duplicate submissions.
 */
export const submitCancellationFeedback = onCall(async (request) => {
  const tripId = String(request.data?.tripId ?? "").trim();
  const userId = String(request.data?.userId ?? "").trim();
  const role = String(request.data?.role ?? "").trim() as "customer" | "driver";
  const reason = String(request.data?.reason ?? "").trim();
  const detail = String(request.data?.detail ?? "").trim();

  if (!tripId) throw new HttpsError("invalid-argument", "tripId is required.");
  if (!userId) throw new HttpsError("invalid-argument", "userId is required.");
  if (role !== "customer" && role !== "driver") {
    throw new HttpsError("invalid-argument", "role must be 'customer' or 'driver'.");
  }
  if (!reason) throw new HttpsError("invalid-argument", "reason is required.");
  if (reason.length > 100) {
    throw new HttpsError("invalid-argument", "reason must be at most 100 characters.");
  }
  if (detail.length > 300) {
    throw new HttpsError("invalid-argument", "detail must be at most 300 characters.");
  }

  const docId = `${tripId}_${userId}`;
  const ref = db().collection("cancellation_feedback").doc(docId);

  try {
    await ref.set(
      {
        tripId,
        userId,
        role,
        reason,
        detail: detail ?? "",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: false }
    );
  } catch (e) {
    console.error(`submitCancellationFeedback[${docId}]: ${e}`);
    throw new HttpsError("internal", "Unable to save feedback.");
  }

  return { ok: true };
});

/**
 * Submit post-trip star rating and update rated user's cumulative profile metrics.
 *
 * Atomically writes to `ratings/{tripId}_{raterId}` and updates:
 * - `users/{ratedUserId}`: totalRatingSum, totalRatingCount, averageRating
 * - `drivers/{ratedUserId}`: (if isRatedUserDriver) totalRatingSum, totalRatingCount, averageRating, rating
 */
export const submitTripRating = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated.");
  }

  const tripId = String(request.data?.tripId ?? "").trim();
  const raterId = request.auth.uid;
  const ratedUserId = String(request.data?.ratedUserId ?? "").trim();
  const rating = Number(request.data?.rating);
  const comment = String(request.data?.comment ?? "").trim();
  const lowRatingReasons = Array.isArray(request.data?.lowRatingReasons)
    ? request.data.lowRatingReasons.map((r: any) => String(r).trim()).filter(Boolean)
    : [];

  if (!tripId) throw new HttpsError("invalid-argument", "tripId is required.");
  if (!ratedUserId) throw new HttpsError("invalid-argument", "ratedUserId is required.");
  if (raterId === ratedUserId) {
    throw new HttpsError("invalid-argument", "Cannot rate yourself.");
  }
  if (!Number.isInteger(rating) || rating < 1 || rating > 5) {
    throw new HttpsError("invalid-argument", "rating must be an integer between 1 and 5.");
  }
  if (comment.length > 500) {
    throw new HttpsError("invalid-argument", "comment must be at most 500 characters.");
  }

  // Fetch trip to verify caller participation and target user validity
  const tripSnap = await db().collection("trips").doc(tripId).get();
  if (!tripSnap.exists) {
    throw new HttpsError("not-found", "Trip not found.");
  }
  const tripData = tripSnap.data() || {};
  const customerId = String(tripData.customerId ?? "").trim();
  const driverId = String(tripData.driver?.driverId ?? tripData.driverId ?? "").trim();

  const isCallerCustomer = raterId === customerId;
  const isCallerDriver = raterId === driverId;

  if (!isCallerCustomer && !isCallerDriver) {
    throw new HttpsError(
      "permission-denied",
      "You are not a participant in this trip."
    );
  }

  const expectedRatedUserId = isCallerCustomer ? driverId : customerId;
  if (ratedUserId !== expectedRatedUserId) {
    throw new HttpsError(
      "permission-denied",
      "Rated user was not a participant in this trip."
    );
  }

  const isRatedUserDriver = isCallerCustomer;

  const ratingDocId = `${tripId}_${raterId}`;
  const ratingRef = db().collection("ratings").doc(ratingDocId);
  const userRef = db().collection("users").doc(ratedUserId);
  const driverRef = isRatedUserDriver ? db().collection("drivers").doc(ratedUserId) : null;

  try {
    await db().runTransaction(async (tx) => {
      // 1. ALL READS MUST PRECEDE ALL WRITES in Firestore transactions
      const existing = await tx.get(ratingRef);
      if (existing.exists) {
        return; // Idempotent — no double-counting
      }

      const userSnap = await tx.get(userRef);
      const userData = userSnap.exists ? (userSnap.data() || {}) : {};

      // 2. Compute updated aggregates
      const currentSum = Number(userData.totalRatingSum || 0);
      const currentCount = Number(userData.totalRatingCount || 0);

      const newSum = currentSum + rating;
      const newCount = currentCount + 1;
      const newAverage = Math.round((newSum / newCount) * 10) / 10;

      // 3. ALL WRITES AFTER ALL READS
      tx.set(ratingRef, {
        ratingId: ratingDocId,
        tripId,
        raterId,
        ratedUserId,
        rating,
        comment,
        lowRatingReasons,
        isLowRating: rating <= 3,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      tx.set(
        userRef,
        {
          totalRatingSum: admin.firestore.FieldValue.increment(rating),
          totalRatingCount: admin.firestore.FieldValue.increment(1),
          averageRating: newAverage,
        },
        { merge: true }
      );

      // Mirror to drivers/{ratedUserId} if rated party is a driver
      if (driverRef) {
        tx.set(
          driverRef,
          {
            totalRatingSum: admin.firestore.FieldValue.increment(rating),
            totalRatingCount: admin.firestore.FieldValue.increment(1),
            averageRating: newAverage,
            rating: newAverage,
          },
          { merge: true }
        );
      }
    });

    return { ok: true, ratingDocId };
  } catch (err: any) {
    console.error(`submitTripRating[${ratingDocId}] error:`, err);
    throw new HttpsError("internal", "Failed to submit rating.");
  }
});

/**
 * Callable: driver skips the 4-digit delivery PIN after the recipient is
 * unreachable for 10 minutes at the drop-off location.
 *
 * This is an escape-hatch designed to prevent drivers from being indefinitely
 * stuck if a recipient cannot be contacted. The driver assumes full liability
 * for the delivery outcome by explicitly confirming the liability warning in
 * the app before this callable is invoked. The trip is marked
 * `deliveryPinSkipped: true` and `deliveryPinVerified: true` so that the
 * normal settlement path can continue — but the audit trail is permanent.
 *
 * Security gates enforced on the server:
 *  1. Caller must be the assigned driver.
 *  2. Trip must be a delivery (serviceType != 'ride').
 *  3. PIN must be required and not yet verified or previously skipped.
 *  4. At least 10 minutes must have elapsed since the trip entered
 *     `IN_PROGRESS` status (using `startedAt` timestamp on the trip doc).
 *
 * Client-side: the driver must confirm a liability warning dialog before
 * calling this function. The server does NOT enforce the dialog — it is a UX
 * gate only. The permanent audit trail is the real safeguard.
 */
export const skipDeliveryPin = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Drivers must sign in.");
  }
  enforceAppCheck(request);
  await requireAccountActive(request.auth.uid, "driver");

  const driverId = request.auth.uid;
  const tripId = String(request.data?.tripId ?? "").trim();
  if (!tripId) {
    throw new HttpsError("invalid-argument", "tripId is required.");
  }

  const ref = db().collection("trips").doc(tripId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
  const data = snap.data()!;

  // Gate 1: caller must be the assigned driver (supports both nested driver.driverId and flat driverId schemas).
  const assignedDriverId = data.driver?.driverId ?? data.driverId;
  if (assignedDriverId !== driverId) {
    throw new HttpsError("permission-denied", "Not your trip.");
  }

  // Gate 2: delivery trips only.
  const serviceType = String(data.serviceType ?? "ride");
  if (serviceType === "ride") {
    throw new HttpsError(
      "failed-precondition",
      "Passenger trips do not use a delivery PIN."
    );
  }

  // Gate 3: PIN must be required and not already handled.
  if (!data.deliveryPinRequired) {
    throw new HttpsError(
      "failed-precondition",
      "Delivery PIN is not required for this trip."
    );
  }
  if (data.deliveryPinVerified === true || data.deliveryPinSkipped === true) {
    // Idempotent — already completed or skipped.
    return { ok: true, alreadyHandled: true };
  }

  // Gate 4: at least 10 minutes must have passed since the trip started
  // (entered IN_PROGRESS). We use `startedAt` written by advanceTripStatus.
  // If `startedAt` is absent we fall back to `updatedAt` as a conservative
  // proxy — the server can never be tricked into skipping prematurely.
  const skipWaitMs = 10 * 60 * 1000; // 10 minutes
  const startedAtMs: number =
    data.startedAt?.toMillis?.() ??
    data.updatedAt?.toMillis?.() ??
    Date.now();
  const elapsedMs = nowMs() - startedAtMs;
  if (elapsedMs < skipWaitMs) {
    const remainingSec = Math.ceil((skipWaitMs - elapsedMs) / 1000);
    throw new HttpsError(
      "failed-precondition",
      `You can only skip the PIN after waiting 10 minutes. ${remainingSec}s remaining.`
    );
  }

  // All gates passed — mark as skipped with full audit trail.
  await ref.update({
    deliveryPinVerified: true,
    deliveryPinSkipped: true,
    deliveryPinSkippedAt: admin.firestore.FieldValue.serverTimestamp(),
    deliveryPinSkippedBy: driverId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  // Best-effort audit log for operations/dispute review.
  try {
    await db().collection("delivery_pin_skips").add({
      tripId,
      driverId,
      skippedAt: admin.firestore.FieldValue.serverTimestamp(),
      elapsedMs,
    });
  } catch (e) {
    console.warn(`skipDeliveryPin: audit write failed for ${tripId}: ${e}`);
  }

  return { ok: true };
});

/** Records driver arrival timestamp at drop-off for waiting & billing tracking. */
export const recordDropoffArrival = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Drivers must sign in.");
  }
  enforceAppCheck(request);
  const { tripId } = request.data ?? {};
  if (!tripId || typeof tripId !== "string") {
    throw new HttpsError("invalid-argument", "tripId required.");
  }
  const ref = db().collection("trips").doc(String(tripId));
  await db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
    const data = snap.data()!;
    const driverId = String(data.driver?.driverId ?? data.driverId ?? "");
    if (driverId !== request.auth!.uid) {
      throw new HttpsError("permission-denied", "Not your trip.");
    }
    if (data.status !== "IN_PROGRESS") return;
    if (!data.dropoffArrivedAt) {
      tx.update(ref, {
        dropoffArrivedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  });
  return { ok: true };
});

/**
 * Driver requests customer approval for completing an out-of-range drop-off.
 *
 * Triggered when the driver taps complete while outside the Hub-configured
 * drop-off completion radius. Puts the order in a non-blocking `PENDING`
 * customer approval state and alerts the customer via push and in-app prompt.
 */
export const requestDropoffApproval = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Drivers must sign in.");
  }
  enforceAppCheck(request);
  await requireAccountActive(request.auth.uid, "driver");

  const driverId = request.auth.uid;
  const tripId = String(request.data?.tripId ?? "").trim();
  const driverLat = Number(
    request.data?.driverLat ?? request.data?.lat ?? request.data?.latitude ?? 0
  );
  const driverLng = Number(
    request.data?.driverLng ?? request.data?.lng ?? request.data?.longitude ?? 0
  );
  const reason = String(
    request.data?.reason ?? "Driver dropped off at customer's new location"
  ).trim();

  if (!tripId) {
    throw new HttpsError("invalid-argument", "tripId is required.");
  }
  if (!driverLat || !driverLng) {
    throw new HttpsError("invalid-argument", "Valid driver GPS location is required.");
  }

  const ref = db().collection("trips").doc(tripId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
  const data = snap.data()!;

  const assignedDriverId = String(data.driver?.driverId ?? data.driverId ?? "");
  if (assignedDriverId !== driverId) {
    throw new HttpsError("permission-denied", "Not your trip.");
  }

  if (data.status !== "IN_PROGRESS") {
    throw new HttpsError(
      "failed-precondition",
      `Trip must be IN_PROGRESS (currently ${data.status}).`
    );
  }

  const dropoffLat = Number(
    data.dropoff?.lat ?? data.dropoffLocation?.latitude ?? data.dropoffLat ?? 0
  );
  const dropoffLng = Number(
    data.dropoff?.lng ?? data.dropoffLocation?.longitude ?? data.dropoffLng ?? 0
  );
  let distanceM = 0;
  if (dropoffLat !== 0 && dropoffLng !== 0) {
    distanceM = Math.round(haversineKm(driverLat, driverLng, dropoffLat, dropoffLng) * 1000);
  }

  const radiusM = await getDropoffRadiusMeters();

  await ref.update({
    dropoffApprovalStatus: "PENDING",
    dropoffApprovalRequestedAt: admin.firestore.FieldValue.serverTimestamp(),
    dropoffApprovalDriverLocation: { lat: driverLat, lng: driverLng },
    dropoffApprovalDistanceMeters: distanceM,
    dropoffApprovalReason: reason,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    statusHistory: admin.firestore.FieldValue.arrayUnion({
      from: String(data.status),
      to: String(data.status),
      actor: driverId,
      role: "driver",
      action: "request_dropoff_approval",
      distanceMeters: distanceM,
      timestamp: nowMs(),
    }),
  });

  const customerId = String(data.customerId ?? data.userId ?? "");
  if (customerId) {
    const distStr = distanceM >= 1000 ? `${(distanceM / 1000).toFixed(1)}km` : `${distanceM}m`;
    await notifyCustomer(
      customerId,
      tripId,
      "Drop-off Confirmation Required",
      "Confirm driver has dropped off your item at your new location?",
      "dropoff_approval_request",
      {
        tripId,
        type: "dropoff_approval_request",
        distanceMeters: String(distanceM),
        distanceText: distStr,
        click_action: "FLUTTER_NOTIFICATION_CLICK",
      }
    );
  }

  return { ok: true, pending: true, distanceMeters: distanceM, radiusMeters: radiusM };
});

/**
 * Customer responds to an out-of-range drop-off confirmation request.
 *
 * If approved: the server immediately and securely finalizes and completes the trip,
 * triggers synchronous commission and wallet settlement, and alerts the driver.
 * If rejected: keeps trip in `IN_PROGRESS` and alerts the driver to proceed to destination.
 */
export const respondDropoffApproval = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }
  enforceAppCheck(request);
  await requireAccountActive(request.auth.uid);

  const customerId = request.auth.uid;
  const tripId = String(request.data?.tripId ?? "").trim();
  const approved = request.data?.approved === true;

  if (!tripId) {
    throw new HttpsError("invalid-argument", "tripId is required.");
  }

  const ref = db().collection("trips").doc(tripId);
  let snapAfterData: admin.firestore.DocumentData | null = null;
  let driverId = "";

  await db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
    const data = snap.data()!;

    const tripCustomerId = String(data.customerId ?? data.userId ?? "");
    if (tripCustomerId !== customerId) {
      throw new HttpsError(
        "permission-denied",
        "Only the customer who ordered this trip can respond to drop-off approval."
      );
    }

    if (data.dropoffApprovalStatus !== "PENDING") {
      if (data.status === "COMPLETED") {
        return; // Idempotent
      }
      throw new HttpsError("failed-precondition", "No pending drop-off approval request.");
    }

    driverId = String(data.driver?.driverId ?? data.driverId ?? "");

    if (approved) {
      const currentStatus = String(data.status);
      const update: Record<string, unknown> = {
        dropoffApprovalStatus: "APPROVED",
        dropoffApprovalRespondedAt: admin.firestore.FieldValue.serverTimestamp(),
        status: "COMPLETED",
        completedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        cancellationSource: null,
        cancellationReason: null,
        statusHistory: admin.firestore.FieldValue.arrayUnion({
          from: currentStatus,
          to: "COMPLETED",
          actor: customerId,
          role: "customer",
          reason: "remote_customer_dropoff_approved",
          timestamp: nowMs(),
        }),
      };
      tx.update(ref, update);
      snapAfterData = { ...data, ...update };
      persistTripChangeLogInTx(tx, {
        tripId,
        from: currentStatus,
        to: "COMPLETED",
        actor: customerId,
        role: "customer",
        reason: "remote_customer_dropoff_approved",
        timestamp: nowMs(),
      });
    } else {
      const update: Record<string, unknown> = {
        dropoffApprovalStatus: "REJECTED",
        dropoffApprovalRespondedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        statusHistory: admin.firestore.FieldValue.arrayUnion({
          from: String(data.status),
          to: String(data.status),
          actor: customerId,
          role: "customer",
          reason: "remote_customer_dropoff_rejected",
          timestamp: nowMs(),
        }),
      };
      tx.update(ref, update);
      snapAfterData = { ...data, ...update };
    }
  });

  if (approved && snapAfterData) {
    logTripTransition({
      tripId,
      from: "IN_PROGRESS",
      to: "COMPLETED",
      actor: customerId,
      role: "customer",
      reason: "remote_customer_dropoff_approved",
      timestamp: nowMs(),
    });

    try {
      await handleTripCompletion(tripId, snapAfterData);
    } catch (e) {
      console.warn(`respondDropoffApproval[${tripId}]: synchronous settlement warning: ${e}`);
    }

    if (driverId) {
      await notifyCustomer(
        driverId,
        tripId,
        "Drop-off Approved",
        "Customer has confirmed drop-off. Trip completed successfully!",
        "dropoff_approved",
        { tripId, type: "dropoff_approved" },
        `driver_${driverId}`
      );
    }
    return { ok: true, approved: true, completed: true };
  } else {
    if (driverId) {
      await notifyCustomer(
        driverId,
        tripId,
        "Drop-off Confirmation Rejected",
        "Customer declined out-of-range drop-off. Please reach the scheduled drop-off location or contact support.",
        "dropoff_rejected",
        { tripId, type: "dropoff_rejected" },
        `driver_${driverId}`
      );
    }
    return { ok: true, approved: false, completed: false };
  }
});

/** Driver cancels an active pending out-of-range drop-off confirmation request. */
export const cancelDropoffApprovalRequest = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Drivers must sign in.");
  }
  enforceAppCheck(request);
  const driverId = request.auth.uid;
  const tripId = String(request.data?.tripId ?? "").trim();
  if (!tripId) throw new HttpsError("invalid-argument", "tripId is required.");

  const ref = db().collection("trips").doc(tripId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
  const data = snap.data()!;

  const assignedDriverId = String(data.driver?.driverId ?? data.driverId ?? "");
  if (assignedDriverId !== driverId) {
    throw new HttpsError("permission-denied", "Not your trip.");
  }

  if (data.dropoffApprovalStatus === "PENDING") {
    await ref.update({
      dropoffApprovalStatus: null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  return { ok: true };
});

