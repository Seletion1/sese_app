import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import {
  onDocumentCreated,
  FirestoreEvent,
  QueryDocumentSnapshot,
} from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { verifyFareToken } from "./fareToken";
import { breakDriverStreak } from "./driverStreak";

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

// ── Cascading tiered dispatch ──────────────────────────────────────────────
// Tier 1: exclusive offer to the single nearest online driver.
// Tier 2: simultaneous offer to the next N nearest drivers.
// Tier 3: broadcast (MARKETPLACE_OPEN) to all nearby online drivers.
// Tier deadlines are stored as `tierExpiresAt` and promoted by the
// `sweepTripPings` cron (1-minute cadence — promotions run on the first
// sweep at/after each deadline).
//
// All numeric tunables below are DEFAULTS. The Super Admin Dispatch Console
// (sese_hub → Dynamic Config → Dispatch) overrides them at runtime via
// `system_settings/dispatch`; see getDispatchTuning(). Clamp bounds keep
// the console from bricking live dispatch.
const DEFAULT_PING_TIMEOUT_MS = 60 * 1000;
const DEFAULT_REPING_INTERVAL_MS = 30 * 1000;
const DEFAULT_TIER1_TIMEOUT_MS = 15 * 1000;
const DEFAULT_TIER2_TIMEOUT_MS = 15 * 1000;
const DEFAULT_TIER2_COUNT = 2;
const DEFAULT_DISPATCH_RADIUS_KM = 15;
const DEFAULT_TIER1_RADIUS_KM = 3;
const DEFAULT_TIER2_RADIUS_KM = 5;
const DEFAULT_DISPATCH_CANDIDATE_LIMIT = 25;
const DEFAULT_RECYCLE_WINDOW_MS = 25 * 60 * 1000;
const DEFAULT_MAX_RECYCLES = 5;

interface DispatchTuning {
  dispatchRadiusKm: number;
  tier1RadiusKm: number;
  tier2RadiusKm: number;
  tier1TimeoutMs: number;
  tier2TimeoutMs: number;
  pingTimeoutMs: number;
  repingIntervalMs: number;
  tier2Count: number;
  candidateLimit: number;
  recycleWindowMs: number;
  maxRecycles: number;
}

const DEFAULT_TUNING: DispatchTuning = {
  dispatchRadiusKm: DEFAULT_DISPATCH_RADIUS_KM,
  tier1RadiusKm: DEFAULT_TIER1_RADIUS_KM,
  tier2RadiusKm: DEFAULT_TIER2_RADIUS_KM,
  tier1TimeoutMs: DEFAULT_TIER1_TIMEOUT_MS,
  tier2TimeoutMs: DEFAULT_TIER2_TIMEOUT_MS,
  pingTimeoutMs: DEFAULT_PING_TIMEOUT_MS,
  repingIntervalMs: DEFAULT_REPING_INTERVAL_MS,
  tier2Count: DEFAULT_TIER2_COUNT,
  candidateLimit: DEFAULT_DISPATCH_CANDIDATE_LIMIT,
  recycleWindowMs: DEFAULT_RECYCLE_WINDOW_MS,
  maxRecycles: DEFAULT_MAX_RECYCLES,
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
    const value: DispatchTuning = {
      dispatchRadiusKm: num(d.dispatchRadiusKm, 15, 1, 50),
      // Per-stage radii: Tier 1 offers the single nearest driver (1-3km),
      // Tier 2 the next group (up to 5km). Both clamp inside the outer
      // dispatchRadiusKm cap so a misconfigured stage can never out-broadcast
      // the pool. Applied within ~60s via the tuning cache.
      tier1RadiusKm: Math.min(
        num(d.tier1RadiusKm, DEFAULT_TIER1_RADIUS_KM, 1, 50),
        num(d.dispatchRadiusKm, 15, 1, 50)
      ),
      tier2RadiusKm: Math.min(
        num(d.tier2RadiusKm, DEFAULT_TIER2_RADIUS_KM, 1, 50),
        num(d.dispatchRadiusKm, 15, 1, 50)
      ),
      tier1TimeoutMs: num(d.tier1TimeoutSec, 15, 5, 120) * 1000,
      tier2TimeoutMs: num(d.tier2TimeoutSec, 15, 5, 120) * 1000,
      pingTimeoutMs: num(d.pingTimeoutSec, 60, 10, 600) * 1000,
      repingIntervalMs: num(d.repingIntervalSec, 30, 10, 600) * 1000,
      tier2Count: Math.round(num(d.tier2Count, 2, 1, 5)),
      candidateLimit: Math.round(num(d.candidateLimit, 25, 5, 100)),
      recycleWindowMs: num(d.recycleWindowMin, 25, 5, 120) * 60 * 1000,
      maxRecycles: Math.round(num(d.maxRecycles, 5, 1, 20)),
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
  | "CANCELLED";

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
 * Best-effort customer alert: in-app `users/{uid}/notifications` row plus
 * rich high-priority FCM push on the customer's topic. Never throws —
 * dispatch must not fail because a notification failed.
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
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
  } catch (e) {
    console.warn(`notifyCustomer: in-app write failed for ${customerId}: ${e}`);
  }
  try {
    await admin.messaging().send({
      topic: topicOverride ?? `user_${customerId}`,
      notification: { title, body },
      android: {
        priority: "high",
        notification: { sound: "sese_alert_chime" },
      },
      apns: { payload: { aps: { sound: "default" } } },
      data: { type, tripId, ...extra },
    });
  } catch (e) {
    console.warn(`notifyCustomer: FCM send failed for ${customerId}: ${e}`);
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

const NG_PHONE = /^(\+?234|0)(70|71|80|81|90|91)\d{8}$/;
const normPhone = (v: unknown) =>
  String(v ?? "").replace(/[\s\-()]/g, "");

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
    return (
      typeof settings === "object" &&
      settings !== null &&
      (settings as Record<string, unknown>).hidePhoneNumber === true
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
  if (!(await hidePhonesEnabled(customerId))) {
    return {
      pickup: {
        lat: d.pickup.lat,
        lng: d.pickup.lng,
        address: String(d.pickup.address ?? ""),
        phone: pickupPhone,
      },
      dropoff: {
        lat: d.dropoff.lat,
        lng: d.dropoff.lng,
        address: String(d.dropoff.address ?? ""),
        phone: dropoffPhone,
      },
      pickupPhone,
      dropoffPhone,
    };
  }
  const maskedPickup = maskPhone(pickupPhone);
  const maskedDropoff = maskPhone(dropoffPhone);
  return {
    phoneMasked: true,
    pickup: {
      lat: d.pickup.lat,
      lng: d.pickup.lng,
      address: String(d.pickup.address ?? ""),
      phone: maskedPickup,
    },
    dropoff: {
      lat: d.dropoff.lat,
      lng: d.dropoff.lng,
      address: String(d.dropoff.address ?? ""),
      phone: maskedDropoff,
    },
    pickupPhone: maskedPickup,
    dropoffPhone: maskedDropoff,
  };
}

// ── createTrip ─────────────────────────────────────────────────────────────

interface CreateTripData {
  pickup: { lat: number; lng: number; address?: string; phone?: string };
  dropoff: { lat: number; lng: number; address?: string; phone?: string };
  pickupPhone?: string;
  dropoffPhone?: string;
  serviceType?: string;
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
  const d = request.data ?? {};

  const pickupPhone = normPhone(d.pickupPhone ?? d.pickup?.phone);
  const dropoffPhone = normPhone(d.dropoffPhone ?? d.dropoff?.phone);
  if (!NG_PHONE.test(pickupPhone) || !NG_PHONE.test(dropoffPhone)) {
    throw new HttpsError(
      "invalid-argument",
      "Valid pickup and drop-off phone numbers are required."
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

  // Baseline fare from verified token for the primary tier
  const baselineFare = verified.tiers[0]?.fareAmount ?? 0;
  const proposedFare =
    typeof (d as any).proposedFare === "number" && (d as any).proposedFare >= baselineFare
      ? (d as any).proposedFare
      : baselineFare;
  const customTierFares =
    (d as any).customTierFares && typeof (d as any).customTierFares === "object"
      ? (d as any).customTierFares
      : {};
  // Payment rail for departure protection. Allow-listed values only;
  // anything else falls back to 'cash' (never auto-starts).
  const rawPayment = String((d as any).paymentMethod ?? "cash").toLowerCase();
  const paymentMethod = [
    "cash", "split", "prepaid", "wallet", "card", "paystack", "online",
  ].includes(rawPayment)
    ? rawPayment
    : "cash";

  const ref = await db().collection("trips").add({
    customerId,
    serviceType,
    status: "SEARCHING_DRIVER",
    // Server-resolved (never trust the client flag): verified customers
    // broadcast `isVerifiedCustomer: true` so drivers see a
    // [Verified Customer] badge on the incoming request.
    isVerifiedCustomer: await isVerifiedCustomer(customerId),
    // Owner-side privacy enforcement, applied ONCE here so every reader
    // sees the same values: when the CUSTOMER enabled
    // `settings.hidePhoneNumber`, all coordination numbers on the minted
    // trip are masked placeholders. The assigned driver (and any client)
    // never receives the raw values — there is nothing to leak, regardless
    // of what a hostile client renders. Parties coordinate through the
    // in-app trip chat for masked trips. The customer viewing their own
    // trip sees the masked values too; their own number remains in their
    // profile. Validation above already ran on the RAW numbers, so masking
    // here cannot smuggle an invalid number past the NG_PHONE gate.
    ...(await maskedPhones(customerId, pickupPhone, dropoffPhone, d)),
    // Delivery verification PIN (send_item / receive_item only): a random
    // 4-digit code the recipient must give the driver at drop-off. The code
    // itself lives in `delivery_pins/{tripId}` — readable ONLY by the
    // customer and admins — because the assigned driver reads the whole trip
    // document, and a PIN the driver can read is theater, not verification.
    // Only the `deliveryPinVerified` flag lives on the trip. Verified by
    // `verifyDeliveryPin` (Admin SDK), which is the only completion path
    // for deliveries. Rides never carry one.
    ...(serviceType === "ride" ? {} : { deliveryPinVerified: false }),
    selectedTiers: d.selectedTiers,
    fareToken: d.fareToken,
    fareTiers: verified.tiers,
    baselineFare,
    proposedFare,
    fareAmount: proposedFare,
    fareBoosted: false,
    boostPercent: 0,
    paymentMethod,
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
  });

  // Delivery PIN notice: the customer (sender) receives the code and shares
  // it with the recipient out-of-band. The recipient is identified only by a
  // phone number — not necessarily a SeSe user — so there is no uid to push
  // to; the sender is the distribution channel. The code is also readable on
  // `delivery_pins/{tripId}` by the customer.
  if (serviceType !== "ride") {
    try {
      const pin = String(Math.floor(1000 + Math.random() * 9000));
      await db().collection("delivery_pins").doc(ref.id).set({
        tripId: ref.id,
        customerId,
        pin,
        verified: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      await notifyCustomer(
        customerId,
        ref.id,
        "Delivery PIN",
        `Your delivery verification code is ${pin}. Share it with your recipient — the driver will ask for it at drop-off.`,
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
async function findNearestDrivers(
  attempted: string[],
  serviceType: string,
  pickup: { lat: number; lng: number },
  count: number,
  tuning: DispatchTuning,
  radiusKm?: number
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
    const data = doc.data();
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

/** Tier 1: exclusive offer to the single nearest online driver (1-3km). */
async function startTier1(
  tripRef: admin.firestore.DocumentReference,
  data: admin.firestore.DocumentData,
  tuning: DispatchTuning
): Promise<boolean> {
  const pickup = pickupOf(data);
  const attempted = attemptedIdsOf(data);
  const serviceType = String(data.serviceType ?? "ride");
  const nearest =
    pickup == null
      ? []
      : await findNearestDrivers(
          attempted,
          serviceType,
          pickup,
          1,
          tuning,
          tuning.tier1RadiusKm
        );
  if (nearest.length === 0) return false; // Nobody online — sweep retries.

  await tripRef.update({
    status: "WAITING_FOR_ACCEPTANCE",
    dispatchTier: 1,
    tier1DriverId: nearest[0].id,
    tier2DriverIds: [],
    pingDriverId: nearest[0].id,
    pingDriverIds: [],
    pingExpiresAt: nowMs() + tuning.pingTimeoutMs,
    tierExpiresAt: nowMs() + tuning.tier1TimeoutMs,
    attemptedDriverIds: admin.firestore.FieldValue.arrayUnion(nearest[0].id),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  return true;
}

/** Tier 2: simultaneous offer to the next N nearest online drivers (≤5km). */
async function startTier2(
  tripRef: admin.firestore.DocumentReference,
  data: admin.firestore.DocumentData,
  tuning: DispatchTuning
): Promise<boolean> {
  const pickup = pickupOf(data);
  const attempted = attemptedIdsOf(data);
  const serviceType = String(data.serviceType ?? "ride");
  const nearest =
    pickup == null
      ? []
      : await findNearestDrivers(
          attempted,
          serviceType,
          pickup,
          tuning.tier2Count,
          tuning,
          tuning.tier2RadiusKm
        );
  if (nearest.length === 0) {
    await startTier3(tripRef);
    return true;
  }
  const ids = nearest.map((n) => n.id);
  await tripRef.update({
    status: "WAITING_FOR_ACCEPTANCE",
    dispatchTier: 2,
    tier2DriverIds: ids,
    pingDriverId: null,
    pingDriverIds: ids,
    pingExpiresAt: nowMs() + tuning.pingTimeoutMs,
    tierExpiresAt: nowMs() + tuning.tier2TimeoutMs,
    attemptedDriverIds: admin.firestore.FieldValue.arrayUnion(...ids),
    declineCount: admin.firestore.FieldValue.increment(1),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  return true;
}

/** Tier 3: broadcast to every nearby online driver (marketplace feed). */
async function startTier3(
  tripRef: admin.firestore.DocumentReference
): Promise<void> {
  await tripRef.update({
    status: "MARKETPLACE_OPEN",
    dispatchTier: 3,
    pingDriverId: null,
    pingDriverIds: [],
    pingExpiresAt: null,
    tierExpiresAt: null,
    declineCount: admin.firestore.FieldValue.increment(1),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
}

/** First dispatch fires the moment the trip document lands (Tier 1). */
export const onTripCreated = onDocumentCreated(
  "trips/{tripId}",
  async (
    event: FirestoreEvent<QueryDocumentSnapshot | undefined, { tripId: string }>
  ) => {
    const snap = event.data;
    if (!snap) return;
    const data = snap.data();
    if (data.status !== "SEARCHING_DRIVER") return;
    await startTier1(snap.ref, data, await getDispatchTuning());
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
 * Scheduled sweep (every minute): promotes waiting offers through the
 * tiers when their deadlines pass (Tier 1 → Tier 2 → marketplace
 * broadcast), expires ignored pings (streak-breaking, like a decline),
 * and restarts dispatch for long-waiting searches. This keeps dispatch
 * alive while the customer's app is closed.
 */
export const sweepTripPings = onSchedule("* * * * *", async () => {
  const cutoff = nowMs();
  const tuning = await getDispatchTuning();

  // 1. Promote Tier 1 offers whose deadline passed.
  const tier1Due = await db()
    .collection("trips")
    .where("status", "==", "WAITING_FOR_ACCEPTANCE")
    .where("dispatchTier", "==", 1)
    .where("tierExpiresAt", "<", cutoff)
    .limit(25)
    .get();
  for (const doc of tier1Due.docs) {
    const data = doc.data();
    // Ignoring a Tier 1 ping until expiry breaks the streak (same as decline).
    const ignored: string | undefined = data.pingDriverId;
    if (ignored) await breakStreakQuiet(ignored, "ping_expired");
    const fresh = (await doc.ref.get()).data();
    if (!fresh || fresh["status"] !== "WAITING_FOR_ACCEPTANCE") continue;
    await startTier2(doc.ref, fresh, tuning);
  }

  // 2. Promote Tier 2 offers whose deadline passed → marketplace broadcast.
  const tier2Due = await db()
    .collection("trips")
    .where("status", "==", "WAITING_FOR_ACCEPTANCE")
    .where("dispatchTier", "==", 2)
    .where("tierExpiresAt", "<", cutoff)
    .limit(25)
    .get();
  for (const doc of tier2Due.docs) {
    const data = doc.data();
    const ignored: string[] = Array.isArray(data.pingDriverIds)
      ? data.pingDriverIds.map(String)
      : [];
    for (const id of ignored) await breakStreakQuiet(id, "ping_expired");
    const fresh = (await doc.ref.get()).data();
    if (!fresh || fresh["status"] !== "WAITING_FOR_ACCEPTANCE") continue;
    await startTier3(doc.ref);
  }

  // 3. Legacy pings without tier fields (pre-cascade docs): expire them.
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
      cancellationSource: "ping_expired",
      declineCount: admin.firestore.FieldValue.increment(1),
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
    await startTier1(doc.ref, data, tuning);
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
});

/**
 * recycleDueOrders — bounded auto-recycling dispatcher (every 25 minutes).
 *
 * Restarts dispatch cycles for trips stuck beyond the 1-minute sweep's
 * reach, so ignored / rejected / timed-out orders keep flowing instead of
 * dying silently:
 * 1. Stale SEARCHING_DRIVER trips (>25 min since update) → fresh Tier 1
 *    cascade (falls back to the Tier 3 broadcast when nobody is online).
 * 2. Stale MARKETPLACE_OPEN broadcasts (>25 min) → re-listed into the
 *    MARKETPLACE_LIST outer-radius (3–5km) pool with a refreshed timestamp
 *    so the driver pool stream re-renders them as live cards.
 *
 * Bounded execution: batches of 20, at most 5 recycles per trip
 * (`recycleCount`), so a permanently unmatchable trip cannot loop forever.
 */
export const recycleDueOrders = onSchedule("*/25 * * * *", async () => {
  const cutoff = nowMs();
  // Console-tunable window/bounds (system_settings/dispatch); the cron
  // cadence itself stays 25 min, the staleness window is configurable.
  const tuning = await getDispatchTuning();
  const recycleWindowMs = tuning.recycleWindowMs;
  const BATCH = 20;
  const MAX_RECYCLES = tuning.maxRecycles;

  // 1. Stale unassigned searches → restart the Tier 1 cascade.
  const staleSearch = await db()
    .collection("trips")
    .where("status", "==", "SEARCHING_DRIVER")
    .limit(BATCH)
    .get();
  for (const doc of staleSearch.docs) {
    const data = doc.data();
    const updated = data.updatedAt?.toMillis?.() ?? 0;
    if (cutoff - updated < recycleWindowMs) continue;
    if (Number(data.recycleCount ?? 0) >= MAX_RECYCLES) continue;
    await doc.ref.update({
      recycleCount: admin.firestore.FieldValue.increment(1),
      recycledAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    const fresh = (await doc.ref.get()).data();
    if (!fresh || fresh.status !== "SEARCHING_DRIVER") continue;
    const restarted = await startTier1(doc.ref, fresh, tuning);
    if (!restarted) {
      await startTier3(doc.ref);
    }
  }

  // 2. Stale marketplace broadcasts → MARKETPLACE_LIST outer-radius pool.
  const staleMarket = await db()
    .collection("trips")
    .where("status", "==", "MARKETPLACE_OPEN")
    .limit(BATCH)
    .get();
  for (const doc of staleMarket.docs) {
    const data = doc.data();
    const updated =
      data.updatedAt?.toMillis?.() ?? data.createdAt?.toMillis?.() ?? 0;
    if (cutoff - updated < recycleWindowMs) continue;
    if (Number(data.recycleCount ?? 0) >= MAX_RECYCLES) continue;
    await doc.ref.update({
      status: "MARKETPLACE_LIST",
      dispatchTier: 3,
      pingDriverId: null,
      pingDriverIds: [],
      pingExpiresAt: null,
      tierExpiresAt: null,
      recycleCount: admin.firestore.FieldValue.increment(1),
      recycledAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
});

// ── Driver actions ─────────────────────────────────────────────────────────

/**
 * Eligibility check shared by accept/decline (read outside transactions).
 * Tier 1: caller is the exclusive ping target. Tier 2: caller is one of
 * the simultaneous ping targets. Tier 3 is claimable inside the accept
 * transaction only (first tap wins atomically).
 */
function isPingTarget(
  data: admin.firestore.DocumentData,
  driverId: string
): boolean {
  if (data.status !== "WAITING_FOR_ACCEPTANCE") return false;
  if (data.pingDriverId === driverId) return true;
  const group: unknown = data.pingDriverIds;
  return Array.isArray(group) && group.map(String).includes(driverId);
}

async function requirePingedDriver(
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
    // Owner-side privacy, driver direction: when the DRIVER enabled
    // `settings.hidePhoneNumber`, the customer never receives the raw
    // number — the trip's driver map carries the masked placeholder, and
    // parties coordinate through in-app trip chat. Same guarantee as the
    // customer direction in createTrip: enforced at write time, not trusted
    // to the reader.
    const rawPhone = String(d.phoneNumber ?? d.phone ?? "");
    const phone = (await hidePhonesEnabled(driverId))
      ? maskPhone(rawPhone)
      : rawPhone;
    return {
      driverId,
      fullName: String(d.fullName ?? d.name ?? "Driver"),
      photoUrl: String(d.photoUrl ?? ""),
      rating: Number(d.rating ?? 0),
      phone,
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
 * - Tier 1/2: caller must be a current ping target.
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

  const snapshot = await driverSnapshot(driverId);
  await db().runTransaction(async (tx) => {
    const ref = db().collection("trips").doc(tripId);
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new HttpsError("not-found", "Trip not found.");
    }
    const data = snap.data()!;
    const status = String(data.status ?? "");

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
      const driverDoc = await tx.get(db().collection("drivers").doc(driverId));
      if (!driverDoc.exists || driverDoc.data()?.isOnline !== true) {
        throw new HttpsError(
          "failed-precondition",
          "Go online to claim marketplace requests."
        );
      }
      // Zero-trust claim gate (mirrors submitBid): online alone is not
      // enough. Verification or the fleet may have been revoked mid-session
      // after goOnline granted, so re-check inside the transaction.
      const claimer = driverDoc.data()!;
      const claimerVerified =
        claimer.verificationStatus === "verified" ||
        claimer.verificationStatus === "active_verified" ||
        claimer.status === "active_verified" ||
        claimer.isVerified === true;
      if (!claimerVerified) {
        throw new HttpsError(
          "permission-denied",
          "Only active verified drivers can claim marketplace requests."
        );
      }
      const fleetSnap = await tx.get(
        db()
          .collection("drivers")
          .doc(driverId)
          .collection("vehicles")
          .where("verificationStatus", "==", "APPROVED")
          .limit(1)
      );
      if (fleetSnap.empty) {
        throw new HttpsError(
          "failed-precondition",
          "An approved vehicle is required to claim marketplace requests."
        );
      }
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

    tx.update(ref, {
      status: "DRIVER_ACCEPTED",
      driver: snapshot,
      dispatchTier: data.dispatchTier ?? null,
      pingDriverId: null,
      pingDriverIds: [],
      pingExpiresAt: null,
      tierExpiresAt: null,
      hasActiveBids: false,
      biddingCompleted: pendingBids.size > 0 ? true : (data.biddingCompleted ?? false),
      acceptedBidDriverId: pendingBids.docs.some((b) => b.id === driverId)
        ? driverId
        : (data.acceptedBidDriverId ?? null),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });
  return { ok: true };
});

/**
 * Driver declines a Tier 1/2 ping → streak breaks, then dispatch continues
 * immediately instead of waiting for the sweep:
 * - Tier 1 decline → jump straight to Tier 2.
 * - Tier 2 decline → drop the decliner from the ping group; when nobody is
 *   left, jump straight to the Tier 3 broadcast.
 */
export const declineTrip = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Drivers must sign in.");
  }
  const driverId = request.auth.uid;
  const tripId = String(request.data?.tripId ?? "");
  if (!tripId) throw new HttpsError("invalid-argument", "tripId is required.");
  const snap = await requirePingedDriver(tripId, driverId);
  const data = snap.data()!;
  const tier = typeof data.dispatchTier === "number" ? data.dispatchTier : 1;

  // Rejecting an incoming request breaks the streak.
  try {
    await breakDriverStreak(driverId, "driver_declined");
  } catch (e) {
    console.warn(`declineTrip: streak break failed for ${driverId}: ${e}`);
  }

  if (tier === 2) {
    const remaining: string[] = (Array.isArray(data.pingDriverIds)
      ? data.pingDriverIds.map(String)
      : []
    ).filter((id) => id !== driverId);
    if (remaining.length > 0) {
      await snap.ref.update({
        pingDriverIds: remaining,
        tier2DriverIds: remaining,
        attemptedDriverIds: admin.firestore.FieldValue.arrayUnion(driverId),
        cancellationSource: "driver_declined",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return { ok: true };
    }
    await startTier3(snap.ref);
    return { ok: true };
  }

  await snap.ref.update({
    status: "SEARCHING_DRIVER",
    pingDriverId: null,
    pingExpiresAt: null,
    cancellationSource: "driver_declined",
    declineCount: admin.firestore.FieldValue.increment(1),
    attemptedDriverIds: admin.firestore.FieldValue.arrayUnion(driverId),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  // Chain Tier 2 immediately instead of waiting for the sweep.
  const fresh = await snap.ref.get();
  if (fresh.exists && fresh.data()!.status === "SEARCHING_DRIVER") {
    await startTier2(snap.ref, fresh.data()!, await getDispatchTuning());
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
  // Mirror the fix onto the driver doc so Tier 1/2 nearest-driver ranking
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
  DRIVER_ACCEPTED: ["DRIVER_ARRIVING"],
  DRIVER_ARRIVING: ["DRIVER_ARRIVED"],
  DRIVER_ARRIVED: ["IN_PROGRESS"],
  IN_PROGRESS: ["COMPLETED"],
};

/** Driver advances arrival/progress/completion along the allowed chain. */
export const advanceTripStatus = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Drivers must sign in.");
  }
  const { tripId, status } = request.data ?? {};
  if (!tripId || typeof status !== "string") {
    throw new HttpsError("invalid-argument", "tripId + status required.");
  }
  const ref = db().collection("trips").doc(String(tripId));
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
  const data = snap.data()!;
  if (data.driver?.driverId !== request.auth.uid) {
    throw new HttpsError("permission-denied", "Not your trip.");
  }
  const allowed = DRIVER_TRANSITIONS[String(data.status)] ?? [];
  if (!allowed.includes(String(status))) {
    throw new HttpsError(
      "failed-precondition",
      `Cannot move from ${data.status} to ${status}.`
    );
  }
  const update: Record<string, unknown> = {
    status,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
  // Record the timestamp when driver taps "Arrived" for no-show timer tracking
  if (status === "DRIVER_ARRIVED") {
    update["arrivedAt"] = admin.firestore.FieldValue.serverTimestamp();
  }
  await ref.update(update);
  // Arrival alert: in-app notification + rich FCM push to the customer
  // (also fired for proximity auto-arrivals — same server path).
  if (status === "DRIVER_ARRIVED") {
    const customerId = String(data.customerId ?? "");
    const driverName = String(data.driver?.fullName ?? "Your driver");
    await notifyCustomer(
      customerId,
      String(tripId),
      "Driver arrived",
      `${driverName} has arrived at the pickup point.`,
      "driver_arrived"
    );
  }
  return { ok: true };
});

// ── Customer actions ───────────────────────────────────────────────────────

/** Customer or driver cancels a live trip — sets cancellationSource for streak logic. */
export const cancelTrip = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must sign in.");
  }
  const tripId = String(request.data?.tripId ?? "");
  if (!tripId) throw new HttpsError("invalid-argument", "tripId is required.");
  const ref = db().collection("trips").doc(tripId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
  const data = snap.data()!;

  const callerId = request.auth.uid;
  const isCustomer = data.customerId === callerId;
  const isDriver = data.driver?.driverId === callerId;

  if (!isCustomer && !isDriver) {
    throw new HttpsError("permission-denied", "Not your trip.");
  }
  if (!LIVE_STATUSES.includes(data.status)) {
    throw new HttpsError("failed-precondition", "Trip is already closed.");
  }

  // Customer cancellation
  if (isCustomer) {
    await ref.update({
      status: "CANCELLED",
      cancellationSource: "customer",
      pingDriverId: null,
      pingExpiresAt: null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { ok: true, cancelledBy: "customer" };
  }

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
  if (data.status === "DRIVER_ACCEPTED" || data.status === "DRIVER_ARRIVING") {
    const currentCount = Number(data.reassignmentCount ?? 0);
    const nextCount = currentCount + 1;
    const history = Array.isArray(data.reassignmentHistory)
      ? [...data.reassignmentHistory, { driverId: callerId, cancelledAt: nowMs() }]
      : [{ driverId: callerId, cancelledAt: nowMs() }];

    if (nextCount <= 3) {
      // Auto-reassign to next nearest driver
      await ref.update({
        driver: null,
        driverLocation: null,
        reassignmentCount: nextCount,
        reassignmentHistory: history,
        attemptedDriverIds: admin.firestore.FieldValue.arrayUnion(callerId),
        status: "SEARCHING_DRIVER",
        cancellationSource: "driver_cancelled_reassigning",
        statusMessage: `Driver cancelled. Reassigning to next available driver (Attempt ${nextCount} of 3)...`,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      // Chain next nearest dispatch
      const freshSnap = await ref.get();
      if (freshSnap.exists) {
        const restarted = await startTier1(
          ref,
          freshSnap.data()!,
          await getDispatchTuning()
        );
        if (!restarted) {
          await startTier3(ref);
        }
      }
      return { ok: true, reassigned: true, attempt: nextCount };
    } else {
      // Reached 3 cancellations: revert to needs_customer_action
      await ref.update({
        status: "needs_customer_action",
        reassignmentCount: nextCount,
        reassignmentHistory: history,
        attemptedDriverIds: admin.firestore.FieldValue.arrayUnion(callerId),
        driver: null,
        driverLocation: null,
        pingDriverId: null,
        pingDriverIds: [],
        pingExpiresAt: null,
        tierExpiresAt: null,
        cancellationSource: "driver_cancelled_max_reached",
        statusMessage:
          "Multiple drivers had to cancel. Please raise your fare/bid to attract nearby drivers.",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      // Notify customer
      try {
        await db()
          .collection("users")
          .doc(data.customerId)
          .collection("notifications")
          .add({
            title: "Trip needs your attention",
            body: "Drivers were unavailable. Please increase your fare to get a driver faster.",
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
  await ref.update({
    status: "CANCELLED",
    cancellationSource,
    pingDriverId: null,
    pingExpiresAt: null,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  return { ok: true };
});

// ── Multi-Driver Bidding System & Customer Actions ─────────────────────────

/** Driver submits a custom fare bid on an open trip document */
export const submitBid = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Drivers must sign in to bid.");
  }
  const driverId = request.auth.uid;
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
  const isVerified =
    driverData.verificationStatus === "verified" ||
    driverData.verificationStatus === "active_verified" ||
    driverData.status === "active_verified" ||
    driverData.isVerified === true;
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

  // 2. Validate offered fare against baseline
  const baseline = Number(tripData.baselineFare ?? tripData.fareAmount ?? 0);
  if (baseline > 0 && offeredFare < baseline) {
    throw new HttpsError(
      "invalid-argument",
      `Offered fare (₦${offeredFare}) cannot be lower than the baseline fare (₦${baseline}).`
    );
  }

  if (tripData.driver?.driverId) {
    throw new HttpsError(
      "failed-precondition",
      "This trip has already been claimed by another driver."
    );
  }

  const allowedStatuses = [
    "SEARCHING_DRIVER",
    "WAITING_FOR_ACCEPTANCE",
    "MARKETPLACE_OPEN",
    "MARKETPLACE_LIST",
    "needs_customer_action",
    "bidding",
  ];
  if (!allowedStatuses.includes(String(tripData.status))) {
    throw new HttpsError(
      "failed-precondition",
      "This trip is no longer open for bidding."
    );
  }

  const snapshot = await driverSnapshot(driverId);
  const bidRef = tripRef.collection("bids").doc(driverId);

  await bidRef.set({
    bidId: driverId,
    tripId,
    driverId,
    driverName: snapshot.fullName,
    photoUrl: snapshot.photoUrl,
    rating: snapshot.rating,
    phone: snapshot.phone,
    vehicleModel: snapshot.vehicleModel,
    vehicleColor: snapshot.vehicleColor,
    plateNumber: snapshot.plateNumber,
    offeredFare,
    etaMinutes: typeof etaMinutes === "number" ? etaMinutes : 5,
    status: "pending",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  await tripRef.update({
    hasActiveBids: true,
    lastBidAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  // Rich counter-bid alert: in-app notification + FCM push to the customer
  // with the driver's name and offered fare (best-effort, never fails bid).
  await notifyCustomer(
    String(tripData.customerId ?? ""),
    String(tripId),
    "New driver offer",
    `${snapshot.fullName} offered ₦${Number(offeredFare).toLocaleString()} for your trip.`,
    "driver_counter_bid",
    { driverId, offeredFare: String(offeredFare) }
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
  if (tripSnap.data()!.customerId !== customerId) {
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
    if (tripData.customerId !== customerId) {
      throw new HttpsError(
        "permission-denied",
        "Only the requesting customer can accept bids."
      );
    }

    if (tripData.driver?.driverId) {
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

    tx.update(bidRef, {
      status: "accepted",
      acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    tx.update(tripRef, {
      status: "DRIVER_ACCEPTED",
      driver: driverPayload,
      fareAmount: bidData.offeredFare,
      fareFormatted: `₦${Number(bidData.offeredFare).toLocaleString()}`,
      biddingCompleted: true,
      acceptedBidDriverId: driverId,
      pingDriverId: null,
      pingDriverIds: [],
      pingExpiresAt: null,
      tierExpiresAt: null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const otherBids = await tripRef
      .collection("bids")
      .where("status", "==", "pending")
      .get();
    for (const b of otherBids.docs) {
      if (b.id !== driverId) {
        tx.update(b.ref, {
          status: "rejected",
          rejectedReason: "another_bid_accepted",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }
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
  if (newFare <= currentFare) {
    throw new HttpsError(
      "invalid-argument",
      "New fare must be higher than current fare."
    );
  }

  const wasNeedsAction = tripData.status === "needs_customer_action";
  const boostPct =
    currentFare > 0
      ? Math.round(((newFare - currentFare) / currentFare) * 100)
      : 0;
  await tripRef.update({
    fareAmount: newFare,
    proposedFare: newFare,
    fareFormatted: `₦${newFare.toLocaleString()}`,
    fareBoosted: true,
    boostPercent: boostPct,
    boostedAt: admin.firestore.FieldValue.serverTimestamp(),
    status: wasNeedsAction ? "SEARCHING_DRIVER" : tripData.status,
    reassignmentCount: wasNeedsAction ? 0 : (tripData.reassignmentCount ?? 0),
    statusMessage: "Price increased! Searching for nearby drivers...",
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  if (wasNeedsAction) {
    const fresh = (await tripRef.get()).data()!;
    const restarted = await startTier1(
      tripRef,
      fresh,
      await getDispatchTuning()
    );
    if (!restarted) {
      await startTier3(tripRef);
    }
  }

  return { ok: true, newFare };
});

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

  const batch = db().batch();
  batch.update(ref, {
    deliveryPinVerified: true,
    deliveryPinVerifiedAt: admin.firestore.FieldValue.serverTimestamp(),
    status: "COMPLETED",
    completedAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  batch.update(pinSnap.ref, {
    verified: true,
    verifiedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  await batch.commit();
  return { ok: true };
});
