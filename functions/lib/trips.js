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
exports.skipDeliveryPin = exports.submitCancellationFeedback = exports.hubManualPinBypass = exports.hubCancelRefundTrip = exports.confirmCashCancellation = exports.hubForceCompleteTrip = exports.verifyDeliveryPin = exports.keepSearchingTrip = exports.increaseTripFare = exports.acceptBid = exports.rejectBid = exports.submitBid = exports.cancelTrip = exports.advanceTripStatus = exports.updateDriverLocation = exports.declineTrip = exports.acceptTrip = exports.recycleDueOrders = exports.sweepTripPings = exports.onTripCreated = exports.createTrip = exports.normPhone = exports.onTripChatMessage = void 0;
exports.haversineKm = haversineKm;
exports.normalizePhone = normalizePhone;
exports.releaseTripEscrow = releaseTripEscrow;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const firestore_1 = require("firebase-functions/v2/firestore");
const scheduler_1 = require("firebase-functions/v2/scheduler");
const fareToken_1 = require("./fareToken");
const driverStreak_1 = require("./driverStreak");
const pricing_1 = require("./pricing");
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
const DEFAULT_DISPATCH_RADIUS_KM = 15;
const DEFAULT_TIER1_RADIUS_KM = 3;
const DEFAULT_TIER3_RADIUS_KM = 15;
const DEFAULT_DISPATCH_CANDIDATE_LIMIT = 25;
const DEFAULT_RECYCLE_WINDOW_MS = 25 * 60 * 1000;
const DEFAULT_MAX_RECYCLES = 5;
const DEFAULT_TUNING = {
    dispatchRadiusKm: DEFAULT_DISPATCH_RADIUS_KM,
    tier1RadiusKm: DEFAULT_TIER1_RADIUS_KM,
    tier3RadiusKm: DEFAULT_TIER3_RADIUS_KM,
    tier1TimeoutMs: DEFAULT_TIER1_TIMEOUT_MS,
    pingTimeoutMs: DEFAULT_PING_TIMEOUT_MS,
    repingIntervalMs: DEFAULT_REPING_INTERVAL_MS,
    candidateLimit: DEFAULT_DISPATCH_CANDIDATE_LIMIT,
    recycleWindowMs: DEFAULT_RECYCLE_WINDOW_MS,
    maxRecycles: DEFAULT_MAX_RECYCLES,
};
let tuningCache = null;
/**
 * Live dispatch tunables from `system_settings/dispatch` (60s cache).
 * Every value is clamped into a safe band; missing doc / read failure
 * falls back to the compiled defaults, so dispatch never stalls.
 */
async function getDispatchTuning() {
    var _a, _b;
    try {
        if (tuningCache && Date.now() - tuningCache.at < 60 * 1000) {
            return tuningCache.value;
        }
        const snap = await db()
            .collection("system_settings")
            .doc("dispatch")
            .get();
        const d = snap.exists ? snap.data() : {};
        const num = (v, fb, min, max) => typeof v === "number" && Number.isFinite(v)
            ? Math.min(max, Math.max(min, v))
            : fb;
        const tier3Radius = num((_a = d.tier3RadiusKm) !== null && _a !== void 0 ? _a : d.dispatchRadiusKm, DEFAULT_DISPATCH_RADIUS_KM, 1, 50);
        const value = {
            dispatchRadiusKm: tier3Radius,
            tier1RadiusKm: Math.min(num(d.tier1RadiusKm, DEFAULT_TIER1_RADIUS_KM, 1, 50), tier3Radius),
            tier3RadiusKm: tier3Radius,
            tier1TimeoutMs: num(d.tier1TimeoutSec, 15, 5, 120) * 1000,
            pingTimeoutMs: num(d.pingTimeoutSec, 60, 10, 600) * 1000,
            repingIntervalMs: num(d.repingIntervalSec, 30, 10, 600) * 1000,
            candidateLimit: Math.round(num(d.candidateLimit, 25, 5, 100)),
            recycleWindowMs: num(d.recycleWindowMin, 25, 5, 120) * 60 * 1000,
            maxRecycles: Math.round(num(d.maxRecycles, 5, 1, 20)),
        };
        tuningCache = { at: Date.now(), value };
        return value;
    }
    catch (_c) {
        return (_b = tuningCache === null || tuningCache === void 0 ? void 0 : tuningCache.value) !== null && _b !== void 0 ? _b : DEFAULT_TUNING;
    }
}
const LIVE_STATUSES = [
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
 *   - P2P_TRANSFER_RECEIVED      — wallet transfer confirmation
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
    "P2P_TRANSFER_RECEIVED",
    "split_payment_request",
    "support_escalated",
    "support_reply",
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
async function notifyCustomer(customerId, tripId, title, body, type, extra = {}, topicOverride) {
    if (!customerId)
        return;
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
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        }
        catch (e) {
            console.warn(`notifyCustomer: in-app write failed for ${customerId}: ${e}`);
        }
    }
    try {
        await admin.messaging().send({
            topic: topicOverride !== null && topicOverride !== void 0 ? topicOverride : `user_${customerId}`,
            notification: { title, body },
            android: {
                priority: "high",
                notification: { sound: "sese_alert_chime" },
            },
            apns: { payload: { aps: { sound: "default" } } },
            data: Object.assign({ type, tripId }, extra),
        });
    }
    catch (e) {
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
exports.onTripChatMessage = (0, firestore_1.onDocumentCreated)("trips/{tripId}/messages/{messageId}", async (event) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k;
    const msg = (_a = event.data) === null || _a === void 0 ? void 0 : _a.data();
    if (!msg)
        return;
    const tripId = event.params.tripId;
    const senderId = String((_b = msg.senderId) !== null && _b !== void 0 ? _b : "");
    if (!senderId)
        return;
    let trip;
    try {
        trip = (await db().collection("trips").doc(tripId).get()).data();
    }
    catch (_l) {
        return;
    }
    if (!trip)
        return;
    const driverId = String((_d = (_c = trip.driver) === null || _c === void 0 ? void 0 : _c.driverId) !== null && _d !== void 0 ? _d : "");
    const customerId = String((_e = trip.customerId) !== null && _e !== void 0 ? _e : "");
    const senderIsDriver = senderId === driverId;
    const targetUid = senderIsDriver ? customerId : driverId;
    if (!targetUid)
        return;
    const text = String((_f = msg.text) !== null && _f !== void 0 ? _f : "").trim();
    const isPhoto = String((_g = msg.type) !== null && _g !== void 0 ? _g : "") === "image";
    const preview = text.length > 90 ? `${text.slice(0, 90)}…` : text;
    const senderName = senderIsDriver
        ? String((_j = (_h = trip.driver) === null || _h === void 0 ? void 0 : _h.fullName) !== null && _j !== void 0 ? _j : "Your driver")
        : "Your customer";
    await notifyCustomer(targetUid, tripId, `New trip message from ${senderName}`, isPhoto ? "📷 Sent a photo" : preview || "Sent a message", "trip_chat_message", { senderId, senderRole: String((_k = msg.senderRole) !== null && _k !== void 0 ? _k : "") }, senderIsDriver ? undefined : `driver_${targetUid}`);
});
/** Great-circle distance in km between two coordinates. */
function haversineKm(lat1, lng1, lat2, lng2) {
    const toRad = (d) => (d * Math.PI) / 180;
    const dLat = toRad(lat2 - lat1);
    const dLng = toRad(lng2 - lng1);
    const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
        Math.cos(toRad(lat1)) *
            Math.cos(toRad(lat2)) *
            Math.sin(dLng / 2) *
            Math.sin(dLng / 2);
    return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
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
    "27", // South Africa
    "20", // Egypt
    "44", // UK
    "33", // France
    "49", // Germany
    "91", // India
    "86", // China
    "971", // UAE
    "966", // Saudi Arabia
    "1", // US / Canada
];
/**
 * Normalizes any raw phone number into canonical E.164 format.
 * - Strips all formatting characters (spaces, dashes, parentheses, dots).
 * - Removes duplicate dial codes (e.g. +234+234... or +234234...).
 * - Strips leading zero after country code (e.g. +2340816... -> +234816...).
 * - Strips leading zero on local numbers and prepends active dial code (e.g. 0816... -> +234816...).
 * - Supports Benin (+229), Ghana (+233), Kenya (+254), US/CA (+1), UK (+44), etc.
 */
function normalizePhone(raw, defaultDialCode = "+234") {
    const str = String(raw !== null && raw !== void 0 ? raw : "").trim();
    if (!str)
        return "";
    let cleaned = str.replace(/[\s\(\)\-\.]/g, "");
    if (!cleaned)
        return "";
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
                }
                else if (code !== "229") {
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
            }
            else if (code !== "229") {
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
exports.normPhone = normalizePhone;
/**
 * Validates that a normalized phone number is either empty (optional)
 * or conforms to ITU-T E.164 international standard (+ followed by 8 to 15 digits).
 */
const phoneOk = (p) => {
    if (p === "")
        return true;
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
const isCoord = (lat, lng) => typeof lat === "number" &&
    typeof lng === "number" &&
    Number.isFinite(lat) &&
    Number.isFinite(lng) &&
    lat >= -90 && lat <= 90 &&
    lng >= -180 && lng <= 180;
const db = () => admin.firestore();
const nowMs = () => Date.now();
/** Server-resolved customer verification: `users/{uid}` holds
 * `customerVerificationStatus: 'verified'` after sese_hub approval. */
async function isVerifiedCustomer(customerId) {
    var _a;
    try {
        const doc = await db().collection("users").doc(customerId).get();
        const data = (_a = doc.data()) !== null && _a !== void 0 ? _a : {};
        return (data.customerVerificationStatus === "verified" ||
            data.isVerifiedCustomer === true);
    }
    catch (_b) {
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
async function hidePhonesEnabled(uid) {
    var _a;
    try {
        const doc = await db().collection("users").doc(uid).get();
        const settings = (_a = doc.data()) === null || _a === void 0 ? void 0 : _a.settings;
        return (typeof settings === "object" &&
            settings !== null &&
            settings.hidePhoneNumber === true);
    }
    catch (_b) {
        // Fail closed to visible: a read error must not silently strip numbers
        // the parties need for coordination.
        return false;
    }
}
/** `08012345678` → `080****5678`. Short/empty input → fixed placeholder. */
function maskPhone(raw) {
    const digits = raw.replace(/\D/g, "");
    if (digits.length < 7)
        return "••••••";
    return `${digits.slice(0, 3)}****${digits.slice(-4)}`;
}
/**
 * Phone fields for a minted trip, masked when the customer opted into
 * number privacy. Returns the pickup/dropoff maps plus the top-level
 * coordination numbers — every copy the doc carries, so no raw value
 * survives anywhere on the document.
 */
async function maskedPhones(customerId, pickupPhone, dropoffPhone, d) {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k;
    const pickupName = String((_c = (_b = (_a = d.pickup) === null || _a === void 0 ? void 0 : _a.name) !== null && _b !== void 0 ? _b : d.pickupName) !== null && _c !== void 0 ? _c : "").trim();
    const dropoffName = String((_f = (_e = (_d = d.dropoff) === null || _d === void 0 ? void 0 : _d.name) !== null && _e !== void 0 ? _e : d.dropoffName) !== null && _f !== void 0 ? _f : "").trim();
    if (!(await hidePhonesEnabled(customerId))) {
        return Object.assign(Object.assign({ pickup: Object.assign(Object.assign({ lat: d.pickup.lat, lng: d.pickup.lng, address: String((_g = d.pickup.address) !== null && _g !== void 0 ? _g : "") }, (pickupName ? { name: pickupName } : {})), { phone: pickupPhone }), dropoff: Object.assign(Object.assign({ lat: d.dropoff.lat, lng: d.dropoff.lng, address: String((_h = d.dropoff.address) !== null && _h !== void 0 ? _h : "") }, (dropoffName ? { name: dropoffName } : {})), { phone: dropoffPhone }), pickupPhone,
            dropoffPhone }, (pickupName ? { pickupName } : {})), (dropoffName ? { dropoffName } : {}));
    }
    // Empty stays empty: masking an absent number into a placeholder would
    // fabricate a contact that was never given.
    const maskedPickup = pickupPhone === "" ? "" : maskPhone(pickupPhone);
    const maskedDropoff = dropoffPhone === "" ? "" : maskPhone(dropoffPhone);
    return Object.assign(Object.assign({ phoneMasked: true, pickup: Object.assign(Object.assign({ lat: d.pickup.lat, lng: d.pickup.lng, address: String((_j = d.pickup.address) !== null && _j !== void 0 ? _j : "") }, (pickupName ? { name: pickupName } : {})), { phone: maskedPickup }), dropoff: Object.assign(Object.assign({ lat: d.dropoff.lat, lng: d.dropoff.lng, address: String((_k = d.dropoff.address) !== null && _k !== void 0 ? _k : "") }, (dropoffName ? { name: dropoffName } : {})), { phone: maskedDropoff }), pickupPhone: maskedPickup, dropoffPhone: maskedDropoff }, (pickupName ? { pickupName } : {})), (dropoffName ? { dropoffName } : {}));
}
/**
 * Callable: validates the booking, verifies the signed fareToken, and mints
 * the live trip document. Returns `{ tripId }`.
 */
exports.createTrip = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t, _u, _v, _w, _x, _y, _z, _0, _1;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in to book.");
    }
    const customerId = request.auth.uid;
    const d = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    const pickupPhone = normalizePhone((_b = d.pickupPhone) !== null && _b !== void 0 ? _b : (_c = d.pickup) === null || _c === void 0 ? void 0 : _c.phone);
    const dropoffPhone = normalizePhone((_d = d.dropoffPhone) !== null && _d !== void 0 ? _d : (_e = d.dropoff) === null || _e === void 0 ? void 0 : _e.phone);
    // Secondary contact numbers are OPTIONAL: empty means the customer offers
    // no extra contact ("call me when you get there"). Only a malformed
    // non-empty entry is rejected. The booker's own account number is minted
    // onto the trip below and stays reachable regardless.
    if (!phoneOk(pickupPhone) || !phoneOk(dropoffPhone)) {
        throw new https_1.HttpsError("invalid-argument", "Phone numbers are optional, but when provided they must be valid.");
    }
    if (!d.pickup || !d.dropoff || !isCoord(d.pickup.lat, d.pickup.lng) ||
        !isCoord(d.dropoff.lat, d.dropoff.lng)) {
        throw new https_1.HttpsError("invalid-argument", "Both pickup and dropoff coordinates ({lat, lng}) are required.");
    }
    const serviceType = d.serviceType === "ride" ? "ride" : "send_item";
    if (!Array.isArray(d.selectedTiers) || d.selectedTiers.length === 0 ||
        d.selectedTiers.some((t) => typeof t !== "string" || !t.trim())) {
        throw new https_1.HttpsError("invalid-argument", "At least one vehicle tier must be selected.");
    }
    // Heavy-duty mutual exclusion, enforced server-side so a hostile client
    // cannot page small-vehicle riders on a heavy-cargo broadcast by crafting
    // the payload directly. (Spec names this function `createRideDispatch`;
    // the real entry point is `createTrip` — enforced here.)
    if (serviceType !== "ride") {
        const rawTiers = d.selectedTiers;
        const tiers = Array.isArray(rawTiers) ? rawTiers.map(String) : [];
        const hasHeavy = tiers.some((t) => t === "van" || t === "truck");
        const hasSmall = tiers.some((t) => t === "bicycle" || t === "tricycle" || t === "motorcycle");
        if (hasHeavy && hasSmall) {
            throw new https_1.HttpsError("invalid-argument", "Van/Truck cannot be combined with Bicycle, Tricycle, or Motorcycle " +
                "in one request. Split heavy cargo into its own booking.");
        }
    }
    // Zero-trust: the fare must come from calculateFare untampered.
    const verified = (0, fareToken_1.verifyFareToken)(String((_f = d.fareToken) !== null && _f !== void 0 ? _f : ""));
    if (!verified || verified.uid !== customerId) {
        throw new https_1.HttpsError("invalid-argument", "Fare verification failed. Please re-check the fare and try again.");
    }
    // Primary selected tier and its baseline fare
    const primaryTier = Array.isArray(d.selectedTiers) && d.selectedTiers.length > 0
        ? String(d.selectedTiers[0])
        : "";
    const primaryTierObj = verified.tiers.find((t) => t.tierId === primaryTier);
    const primaryBaselineFare = (_j = (_g = primaryTierObj === null || primaryTierObj === void 0 ? void 0 : primaryTierObj.fareAmount) !== null && _g !== void 0 ? _g : (_h = verified.tiers[0]) === null || _h === void 0 ? void 0 : _h.fareAmount) !== null && _j !== void 0 ? _j : 0;
    const baselineFare = primaryBaselineFare;
    const customTierFares = d.customTierFares && typeof d.customTierFares === "object"
        ? d.customTierFares
        : {};
    // Resolve custom fare for the primary tier if provided
    const customPrimaryFare = primaryTier && typeof customTierFares[primaryTier] === "number"
        ? Number(customTierFares[primaryTier])
        : 0;
    const rawProposedFare = typeof d.proposedFare === "number" ? Number(d.proposedFare) : 0;
    const proposedFare = Math.max(rawProposedFare, customPrimaryFare, primaryBaselineFare);
    // Update tier entries in fareTiers to reflect custom/proposed fares
    const updatedFareTiers = verified.tiers.map((t) => {
        const customForTier = typeof customTierFares[t.tierId] === "number" ? Number(customTierFares[t.tierId]) : 0;
        let tierFare = t.fareAmount;
        if (customForTier > tierFare) {
            tierFare = customForTier;
        }
        if (t.tierId === primaryTier && proposedFare > tierFare) {
            tierFare = proposedFare;
        }
        return Object.assign(Object.assign({}, t), { fareAmount: tierFare });
    });
    // Payment rail & Payment Mode resolution
    const rawPaymentMode = String((_k = d.paymentMode) !== null && _k !== void 0 ? _k : "sender_pays").toLowerCase();
    const paymentMode = ["sender_pays", "receiver_pays", "split"].includes(rawPaymentMode)
        ? rawPaymentMode
        : "sender_pays";
    const rawPayment = String((_l = d.paymentMethod) !== null && _l !== void 0 ? _l : "auto").toLowerCase();
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
        if (remoteKeysSnap.exists && ((_m = remoteKeysSnap.data()) === null || _m === void 0 ? void 0 : _m.forceDeliveryPinSystemWide) === true) {
            forceDeliveryPinSystemWide = true;
        }
    }
    catch (_) { }
    // Rides never take a drop-off PIN: there is no recipient handoff, and
    // the driver completion path never asks for one on rides. Deliveries
    // require PIN only if system-wide forced or customer explicitly toggled on.
    const isPinRequired = serviceType !== "ride" &&
        (forceDeliveryPinSystemWide || d.requireDeliveryPin === true);
    const pinCode = isPinRequired ? String(Math.floor(1000 + Math.random() * 9000)) : null;
    // Split payment validation if split selected
    let splitPaymentData = null;
    if (paymentMethod === "split" || d.paymentMode === "split") {
        const recPhone = (0, exports.normPhone)((_o = d.receiverPhone) !== null && _o !== void 0 ? _o : dropoffPhone);
        if (recPhone === "") {
            throw new https_1.HttpsError("invalid-argument", "Split payment needs the receiver's phone number so their share " +
                "can be settled. Add it, or use Sender/Receiver Pays.");
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
            throw new https_1.HttpsError("invalid-argument", "Split payment requires both parties to be registered users. Ask the receiver to sign up, or select 'Sender Pays' / 'Receiver Pays'.");
        }
        const senderShare = Number((_p = d.senderShareAmount) !== null && _p !== void 0 ? _p : baselineFare / 2);
        const receiverShare = Number((_q = d.receiverShareAmount) !== null && _q !== void 0 ? _q : baselineFare / 2);
        splitPaymentData = {
            status: "pending_receiver_consent",
            senderShare,
            receiverShare,
            senderPaymentMethod: String((_r = d.senderPaymentMethod) !== null && _r !== void 0 ? _r : "cash"),
            receiverPaymentMethod: String((_s = d.receiverPaymentMethod) !== null && _s !== void 0 ? _s : "cash"),
            senderPhone: pickupPhone,
            receiverPhone: recPhone,
            receiverUid: recSnap.id,
            receiverConsentStatus: "pending",
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        };
    }
    let customerName = "Customer";
    let customerPhone = "";
    let outstandingNegativeBalance = 0;
    try {
        const custSnap = await db().collection("users").doc(customerId).get();
        if (custSnap.exists) {
            const cData = custSnap.data();
            customerName = String((_u = (_t = cData.fullName) !== null && _t !== void 0 ? _t : cData.name) !== null && _u !== void 0 ? _u : "Customer");
            customerPhone = (0, exports.normPhone)((_w = (_v = cData.phoneNumberE164) !== null && _v !== void 0 ? _v : cData.phoneNumber) !== null && _w !== void 0 ? _w : "");
            outstandingNegativeBalance = Math.max(0, Number((_x = cData.outstandingNegativeBalance) !== null && _x !== void 0 ? _x : 0));
        }
    }
    catch (_) { }
    const adjustedProposedFare = proposedFare + outstandingNegativeBalance;
    const adjustedBaselineFare = baselineFare + outstandingNegativeBalance;
    // Clear outstanding negative balance from user account since it is rolled into the new trip fare
    if (outstandingNegativeBalance > 0) {
        try {
            await db().collection("users").doc(customerId).set({ outstandingNegativeBalance: 0 }, { merge: true });
        }
        catch (_) { }
    }
    // ── Wallet Escrow & Cash Collection Breakdown Engine ───────────────────
    let availableWalletBalance = 0;
    const custWalletRef = db().collection("wallets").doc(customerId);
    try {
        const custWalletSnap = await custWalletRef.get();
        if (custWalletSnap.exists) {
            const wData = custWalletSnap.data();
            const mainBal = typeof wData.mainWalletBalance === "number"
                ? wData.mainWalletBalance
                : (typeof wData.balance === "number" ? wData.balance / 100 : 0);
            const escrowBal = typeof wData.escrowBalance === "number" ? wData.escrowBalance : 0;
            availableWalletBalance = Math.max(0, mainBal - escrowBal);
        }
    }
    catch (e) {
        console.warn(`createTrip: wallet lookup warning: ${e}`);
    }
    let walletCoverageAmount = 0;
    let cashToCollect = adjustedProposedFare;
    let collectAt = "pickup";
    let payerRole = "sender";
    let escrowLocked = false;
    let senderCashToCollect = 0;
    let receiverCashToCollect = 0;
    if (paymentMode === "receiver_pays") {
        // Receiver Pays: Cash Only, driver collects full fare from receiver at drop-off
        walletCoverageAmount = 0;
        cashToCollect = adjustedProposedFare;
        receiverCashToCollect = adjustedProposedFare;
        collectAt = "dropoff";
        payerRole = "receiver";
        escrowLocked = false;
    }
    else if (paymentMode === "split") {
        payerRole = "split";
        const senderShare = Number((_y = d.senderShareAmount) !== null && _y !== void 0 ? _y : adjustedProposedFare / 2);
        const receiverShare = Number((_z = d.receiverShareAmount) !== null && _z !== void 0 ? _z : (adjustedProposedFare - senderShare));
        receiverCashToCollect = receiverShare;
        if (paymentMethod === "cash") {
            walletCoverageAmount = 0;
            senderCashToCollect = senderShare;
            escrowLocked = false;
        }
        else {
            // Auto (smart default) or Wallet / Card
            walletCoverageAmount = (0, pricing_1.roundToNearest100)(Math.min(senderShare, availableWalletBalance));
            if (walletCoverageAmount > senderShare) {
                walletCoverageAmount = senderShare;
            }
            senderCashToCollect = Math.max(0, senderShare - walletCoverageAmount);
            escrowLocked = walletCoverageAmount > 0;
        }
        cashToCollect = senderCashToCollect + receiverCashToCollect;
        collectAt = senderCashToCollect > 0 ? "both" : "dropoff";
    }
    else {
        // "sender_pays"
        payerRole = "sender";
        collectAt = "pickup";
        if (paymentMethod === "cash") {
            walletCoverageAmount = 0;
            cashToCollect = adjustedProposedFare;
            senderCashToCollect = adjustedProposedFare;
            escrowLocked = false;
        }
        else {
            // Auto (smart default) or Wallet / Card
            walletCoverageAmount = (0, pricing_1.roundToNearest100)(Math.min(adjustedProposedFare, availableWalletBalance));
            if (walletCoverageAmount > adjustedProposedFare) {
                walletCoverageAmount = adjustedProposedFare;
            }
            cashToCollect = Math.max(0, adjustedProposedFare - walletCoverageAmount);
            senderCashToCollect = cashToCollect;
            escrowLocked = walletCoverageAmount > 0;
        }
    }
    // Lock available wallet balance into active escrow hold
    if (escrowLocked && walletCoverageAmount > 0) {
        try {
            const coverageKobo = (0, driverStreak_1.nairaToKobo)(walletCoverageAmount);
            await custWalletRef.set({
                escrowBalance: admin.firestore.FieldValue.increment(walletCoverageAmount),
            }, { merge: true });
            await custWalletRef.collection("transactions").add({
                type: "trip_escrow_hold",
                amountNaira: -walletCoverageAmount,
                amountKobo: -coverageKobo,
                amount: -coverageKobo,
                currency: "NGN",
                note: "Locked in escrow for active trip",
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        }
        catch (e) {
            console.warn(`createTrip: escrow lock warning: ${e}`);
        }
    }
    const ref = await db().collection("trips").add(Object.assign(Object.assign(Object.assign(Object.assign({ customerId,
        customerName,
        customerPhone, 
        // Permanent trip booker profile snapshot (retained even if contacts change)
        tripBooker: {
            uid: customerId,
            customerId,
            name: customerName,
            fullName: customerName,
            phone: customerPhone,
            phoneNumber: customerPhone,
        }, createdBy: {
            uid: customerId,
            name: customerName,
            fullName: customerName,
            phone: customerPhone,
        }, serviceType, status: "SEARCHING_DRIVER", 
        // Server-resolved (never trust the client flag): verified customers
        // broadcast `isVerifiedCustomer: true` so drivers see a
        // [Verified Customer] badge on the incoming request.
        isVerifiedCustomer: await isVerifiedCustomer(customerId) }, (await maskedPhones(customerId, pickupPhone, dropoffPhone, d))), { deliveryPinRequired: isPinRequired, deliveryPinVerified: !isPinRequired, deliveryPin: pinCode, order: {
            deliveryPin: pinCode,
            requireDeliveryPin: isPinRequired,
        } }), (splitPaymentData ? { splitPaymentStatus: "pending_receiver_consent", splitPayment: splitPaymentData } : {})), { selectedTiers: d.selectedTiers, vehicleCategory: String((_1 = (_0 = d.vehicleCategory) !== null && _0 !== void 0 ? _0 : d.category) !== null && _1 !== void 0 ? _1 : (Array.isArray(d.selectedTiers) && d.selectedTiers.length > 0 ? d.selectedTiers[0] : "car")).toLowerCase(), fareToken: d.fareToken, fareTiers: updatedFareTiers, baselineFare: adjustedBaselineFare, proposedFare: adjustedProposedFare, fareAmount: adjustedProposedFare, fareFormatted: `₦${adjustedProposedFare.toLocaleString()}`, outstandingBalanceIncluded: outstandingNegativeBalance, fareBoosted: false, boostPercent: 0, paymentMethod,
        paymentMode,
        walletCoverageAmount,
        cashToCollect,
        collectAt,
        payerRole,
        escrowLocked,
        senderCashToCollect,
        receiverCashToCollect, paymentBreakdown: {
            totalFare: adjustedProposedFare,
            walletCoverageAmount,
            cashToCollect,
            senderCashToCollect,
            receiverCashToCollect,
            collectAt,
            payerRole,
            escrowLocked,
        }, senderShareAmount: d.senderShareAmount != null
            ? Number(d.senderShareAmount)
            : (splitPaymentData ? Number(splitPaymentData.senderShare) : null), receiverShareAmount: d.receiverShareAmount != null
            ? Number(d.receiverShareAmount)
            : (splitPaymentData ? Number(splitPaymentData.receiverShare) : null), customTierFares, distanceKm: verified.distanceKm, durationMins: verified.durationMins, declineCount: 0, reassignmentCount: 0, reassignmentHistory: [], idlePromptSent: false, attemptedDriverIds: [], pingDriverId: null, pingExpiresAt: null, driver: null, driverLocation: null, createdAt: admin.firestore.FieldValue.serverTimestamp(), updatedAt: admin.firestore.FieldValue.serverTimestamp() }));
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
            await notifyCustomer(customerId, ref.id, "Delivery PIN", `Your delivery verification code is ${pinCode}. Share it with your recipient — the driver will ask for it at drop-off.`, "delivery_pin_issued");
        }
        catch (e) {
            console.warn(`createTrip: PIN issue failed: ${e}`);
        }
    }
    return { tripId: ref.id };
});
function pickupOf(data) {
    const pickup = data.pickup;
    if (pickup &&
        typeof pickup.lat === "number" &&
        typeof pickup.lng === "number") {
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
async function getMinWalletBalanceToOnline() {
    var _a;
    try {
        const snap = await db().collection("system_configs").doc("financials").get();
        const raw = (_a = snap.data()) === null || _a === void 0 ? void 0 : _a.minWalletBalanceToOnline;
        if (typeof raw === "number" && Number.isFinite(raw))
            return raw;
    }
    catch (_) { }
    return 1.00;
}
async function findNearestDrivers(attempted, serviceType, pickup, count, tuning, radiusKm, vehicleCategory, customerId) {
    var _a, _b;
    const snap = await db()
        .collection("drivers")
        .where("isOnline", "==", true)
        .orderBy("lastSeen", "desc")
        .limit(tuning.candidateLimit)
        .get();
    const ranked = [];
    for (const doc of snap.docs) {
        if (attempted.includes(doc.id))
            continue;
        // Self-dispatch protection: never ping or match the customer as the driver
        if (customerId && doc.id === customerId)
            continue;
        const data = doc.data();
        // Strict Vehicle Category Matching Guard:
        // When order specifies a category (e.g. bicycle, motorcycle, tricycle, car, van, truck),
        // skip drivers whose active vehicle category does not match.
        if (vehicleCategory) {
            const activeCat = String((_b = (_a = data.activeVehicleCategory) !== null && _a !== void 0 ? _a : data.vehicleCategory) !== null && _b !== void 0 ? _b : "").toLowerCase();
            if (activeCat && activeCat !== vehicleCategory.toLowerCase()) {
                continue;
            }
        }
        const tiers = Array.isArray(data.serviceTiers)
            ? data.serviceTiers.map(String)
            : [];
        // No tier allow-list on the driver doc = eligible for everything.
        if (tiers.length > 0 && serviceType === "ride" && !tiers.includes("ride")) {
            continue;
        }
        const loc = data.lastLocation;
        const distanceKm = loc && typeof loc.lat === "number" && typeof loc.lng === "number"
            ? haversineKm(pickup.lat, pickup.lng, loc.lat, loc.lng)
            : Number.POSITIVE_INFINITY;
        // Stage radius defaults to the outer cap when the caller passes none.
        const capKm = radiusKm !== null && radiusKm !== void 0 ? radiusKm : tuning.dispatchRadiusKm;
        if (distanceKm <= capKm) {
            ranked.push({ id: doc.id, distanceKm });
        }
    }
    ranked.sort((a, b) => a.distanceKm - b.distanceKm);
    return ranked.slice(0, count);
}
function attemptedIdsOf(data) {
    return Array.isArray(data.attemptedDriverIds)
        ? data.attemptedDriverIds.map(String)
        : [];
}
/** Tier 1: exclusive offer to the single nearest online driver (1-3km). */
async function startTier1(tripRef, data, tuning) {
    var _a, _b, _c, _d;
    const pickup = pickupOf(data);
    const attempted = attemptedIdsOf(data);
    const serviceType = String((_a = data.serviceType) !== null && _a !== void 0 ? _a : "ride");
    const vehicleCategory = String((_b = data.vehicleCategory) !== null && _b !== void 0 ? _b : (Array.isArray(data.selectedTiers) && data.selectedTiers.length > 0 ? data.selectedTiers[0] : "")).toLowerCase();
    const customerId = String((_d = (_c = data.customerId) !== null && _c !== void 0 ? _c : data.userId) !== null && _d !== void 0 ? _d : "");
    const nearest = pickup == null
        ? []
        : await findNearestDrivers(attempted, serviceType, pickup, 1, tuning, tuning.tier1RadiusKm, vehicleCategory, customerId);
    if (nearest.length === 0)
        return false; // Nobody online in Stage 1 radius.
    await tripRef.update({
        status: "WAITING_FOR_ACCEPTANCE",
        dispatchTier: 1,
        tier1DriverId: nearest[0].id,
        pingDriverId: nearest[0].id,
        pingDriverIds: [nearest[0].id],
        pingExpiresAt: nowMs() + tuning.pingTimeoutMs,
        tierExpiresAt: nowMs() + tuning.tier1TimeoutMs,
        attemptedDriverIds: admin.firestore.FieldValue.arrayUnion(nearest[0].id),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
}
/** Stage 3 Fallback: direct drop into global Order Pool (marketplace feed). */
async function startTier3(tripRef) {
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
/** Streamlined 2-Stage Dispatch: Stage 1 (Sequential 1-on-1) -> Direct Order Pool Fallback. */
exports.onTripCreated = (0, firestore_1.onDocumentCreated)("trips/{tripId}", async (event) => {
    const snap = event.data;
    if (!snap)
        return;
    const data = snap.data();
    if (data.status !== "SEARCHING_DRIVER")
        return;
    const tuning = await getDispatchTuning();
    const started = await startTier1(snap.ref, data, tuning);
    if (!started) {
        // Direct Fallback to Order Pool
        await startTier3(snap.ref);
    }
});
async function breakStreakQuiet(driverId, reason) {
    try {
        await (0, driverStreak_1.breakDriverStreak)(driverId, reason);
    }
    catch (e) {
        console.warn(`sweepTripPings: streak break failed for ${driverId}: ${e}`);
    }
}
/**
 * Scheduled sweep (every minute): promotes waiting offers through Stage 1
 * sequential pings to Stage 3 Order Pool, expires ignored pings
 * ("skipped_by_driver"), and restarts dispatch for long-waiting searches.
 */
exports.sweepTripPings = (0, scheduler_1.onSchedule)("* * * * *", async () => {
    var _a, _b, _c, _d, _e, _f;
    const cutoff = nowMs();
    const tuning = await getDispatchTuning();
    // 1. Promote Stage 1 offers whose deadline passed.
    const tier1Due = await db()
        .collection("trips")
        .where("status", "==", "WAITING_FOR_ACCEPTANCE")
        .where("dispatchTier", "==", 1)
        .where("tierExpiresAt", "<", cutoff)
        .limit(25)
        .get();
    for (const doc of tier1Due.docs) {
        const data = doc.data();
        const ignored = data.pingDriverId;
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
        if (!fresh || fresh["status"] !== "WAITING_FOR_ACCEPTANCE")
            continue;
        const restarted1 = await startTier1(doc.ref, fresh, tuning);
        if (!restarted1) {
            await startTier3(doc.ref);
        }
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
        if (typeof data.dispatchTier === "number")
            continue; // handled above
        const ignoredDriverId = data.pingDriverId;
        await doc.ref.update({
            status: "SEARCHING_DRIVER",
            pingDriverId: null,
            pingExpiresAt: null,
            cancellationSource: "ping_expired",
            declineCount: admin.firestore.FieldValue.increment(1),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        if (ignoredDriverId)
            await breakStreakQuiet(ignoredDriverId, "ping_expired");
    }
    // 4. Re-dispatch long-waiting searches (nobody online at creation).
    const searching = await db()
        .collection("trips")
        .where("status", "==", "SEARCHING_DRIVER")
        .limit(25)
        .get();
    for (const doc of searching.docs) {
        const data = doc.data();
        const updated = (_c = (_b = (_a = data.updatedAt) === null || _a === void 0 ? void 0 : _a.toMillis) === null || _b === void 0 ? void 0 : _b.call(_a)) !== null && _c !== void 0 ? _c : 0;
        if (cutoff - updated < tuning.repingIntervalMs)
            continue;
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
        const createdMs = (_f = (_e = (_d = data.createdAt) === null || _d === void 0 ? void 0 : _d.toMillis) === null || _e === void 0 ? void 0 : _e.call(_d)) !== null && _f !== void 0 ? _f : 0;
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
            }
            catch (_g) {
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
exports.recycleDueOrders = (0, scheduler_1.onSchedule)("*/25 * * * *", async () => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l;
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
        const updated = (_c = (_b = (_a = data.updatedAt) === null || _a === void 0 ? void 0 : _a.toMillis) === null || _b === void 0 ? void 0 : _b.call(_a)) !== null && _c !== void 0 ? _c : 0;
        if (cutoff - updated < recycleWindowMs)
            continue;
        if (Number((_d = data.recycleCount) !== null && _d !== void 0 ? _d : 0) >= MAX_RECYCLES)
            continue;
        await doc.ref.update({
            recycleCount: admin.firestore.FieldValue.increment(1),
            recycledAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        const fresh = (await doc.ref.get()).data();
        if (!fresh || fresh.status !== "SEARCHING_DRIVER")
            continue;
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
        const updated = (_k = (_g = (_f = (_e = data.updatedAt) === null || _e === void 0 ? void 0 : _e.toMillis) === null || _f === void 0 ? void 0 : _f.call(_e)) !== null && _g !== void 0 ? _g : (_j = (_h = data.createdAt) === null || _h === void 0 ? void 0 : _h.toMillis) === null || _j === void 0 ? void 0 : _j.call(_h)) !== null && _k !== void 0 ? _k : 0;
        if (cutoff - updated < recycleWindowMs)
            continue;
        if (Number((_l = data.recycleCount) !== null && _l !== void 0 ? _l : 0) >= MAX_RECYCLES)
            continue;
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
function isPingTarget(data, driverId) {
    if (data.status !== "WAITING_FOR_ACCEPTANCE")
        return false;
    if (data.pingDriverId === driverId)
        return true;
    const group = data.pingDriverIds;
    return Array.isArray(group) && group.map(String).includes(driverId);
}
async function requirePingedDriver(tripId, driverId) {
    const ref = db().collection("trips").doc(tripId);
    const snap = await ref.get();
    if (!snap.exists) {
        throw new https_1.HttpsError("not-found", "Trip not found.");
    }
    const data = snap.data();
    if (!isPingTarget(data, driverId)) {
        throw new https_1.HttpsError("failed-precondition", "This trip is no longer waiting on you.");
    }
    if (typeof data.pingExpiresAt === "number" && data.pingExpiresAt < nowMs()) {
        throw new https_1.HttpsError("deadline-exceeded", "Your ping expired.");
    }
    return snap;
}
async function driverSnapshot(driverId) {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k;
    try {
        const doc = await db().collection("drivers").doc(driverId).get();
        const d = doc.exists ? doc.data() : {};
        let vehicle = {};
        try {
            const v = await db()
                .collection("drivers").doc(driverId)
                .collection("vehicles").limit(1).get();
            if (!v.empty)
                vehicle = v.docs[0].data();
        }
        catch ( /* vehicle optional */_l) { /* vehicle optional */ }
        // Driver lifeline: during an active assigned trip, the customer must be able
        // to call the driver. The driver's actual dialable phone is minted onto the
        // trip's driver snapshot — matching customerPhone which is also kept dialable.
        const rawPhone = String((_c = (_b = (_a = d.phoneNumberE164) !== null && _a !== void 0 ? _a : d.phoneNumber) !== null && _b !== void 0 ? _b : d.phone) !== null && _c !== void 0 ? _c : "");
        const phone = rawPhone;
        return {
            driverId,
            fullName: String((_e = (_d = d.fullName) !== null && _d !== void 0 ? _d : d.name) !== null && _e !== void 0 ? _e : "Driver"),
            photoUrl: String((_f = d.photoUrl) !== null && _f !== void 0 ? _f : ""),
            rating: Number((_g = d.rating) !== null && _g !== void 0 ? _g : 0),
            phone,
            plateNumber: String((_j = (_h = vehicle.licensePlate) !== null && _h !== void 0 ? _h : vehicle.plateNumber) !== null && _j !== void 0 ? _j : ""),
            vehicleModel: String([vehicle.make, vehicle.model].filter(Boolean).join(" ") || vehicle.model || ""),
            vehicleColor: String((_k = vehicle.color) !== null && _k !== void 0 ? _k : ""),
        };
    }
    catch (_m) {
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
exports.acceptTrip = (0, https_1.onCall)(async (request) => {
    var _a, _b;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in.");
    }
    const driverId = request.auth.uid;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "");
    if (!tripId)
        throw new https_1.HttpsError("invalid-argument", "tripId is required.");
    const snapshot = await driverSnapshot(driverId);
    await db().runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o;
        const ref = db().collection("trips").doc(tripId);
        const snap = await tx.get(ref);
        if (!snap.exists) {
            throw new https_1.HttpsError("not-found", "Trip not found.");
        }
        // Multi-device session guard: ensure driver is currently online and
        // that this device session has not been superseded by another device.
        const statusDoc = await tx.get(db().collection("driver_status").doc(driverId));
        if (statusDoc.exists) {
            const sData = (_a = statusDoc.data()) !== null && _a !== void 0 ? _a : {};
            if (sData.isOnline !== true) {
                throw new https_1.HttpsError("failed-precondition", "You are currently offline. Go online to accept trips.");
            }
            const clientSessionId = ((_b = request.data) === null || _b === void 0 ? void 0 : _b.sessionId) ? String(request.data.sessionId) : null;
            if (clientSessionId && sData.activeSessionId && sData.activeSessionId !== clientSessionId) {
                throw new https_1.HttpsError("failed-precondition", "This session is no longer active. You went online on another device.");
            }
        }
        // Low balance guard: Drivers with balance below minWalletBalanceToOnline (< 1.00) cannot accept trips.
        const walletDoc = await tx.get(db().collection("wallets").doc(driverId));
        const wData = walletDoc.exists ? ((_c = walletDoc.data()) !== null && _c !== void 0 ? _c : {}) : {};
        const mainBal = typeof wData.mainWalletBalance === "number"
            ? wData.mainWalletBalance
            : ((typeof wData.balance === "number" ? wData.balance : 0) / 100);
        const minBalance = await getMinWalletBalanceToOnline();
        if (mainBal < minBalance) {
            throw new https_1.HttpsError("failed-precondition", "Your balance is low. Please top up to accept trips.");
        }
        const data = snap.data();
        const status = String((_d = data.status) !== null && _d !== void 0 ? _d : "");
        // Self-assignment guard: drivers cannot accept orders they created as customer
        const orderCustomerId = String((_f = (_e = data.customerId) !== null && _e !== void 0 ? _e : data.userId) !== null && _f !== void 0 ? _f : "");
        if (orderCustomerId && orderCustomerId === driverId) {
            throw new https_1.HttpsError("failed-precondition", "You cannot accept an order you created as a customer.");
        }
        if (status === "WAITING_FOR_ACCEPTANCE") {
            if (!isPingTarget(data, driverId)) {
                throw new https_1.HttpsError("failed-precondition", "This trip is no longer waiting on you.");
            }
            if (typeof data.pingExpiresAt === "number" && data.pingExpiresAt < nowMs()) {
                throw new https_1.HttpsError("deadline-exceeded", "Your ping expired.");
            }
        }
        else if (status === "MARKETPLACE_OPEN" || status === "MARKETPLACE_LIST") {
            const driverDoc = await tx.get(db().collection("drivers").doc(driverId));
            if (!driverDoc.exists || ((_g = driverDoc.data()) === null || _g === void 0 ? void 0 : _g.isOnline) !== true) {
                throw new https_1.HttpsError("failed-precondition", "Go online to claim marketplace requests.");
            }
            // Zero-trust claim gate (mirrors submitBid): online alone is not
            // enough. Verification or the fleet may have been revoked mid-session
            // after goOnline granted, so re-check inside the transaction.
            const claimer = driverDoc.data();
            const claimerStatus = String((_j = (_h = claimer.verificationStatus) !== null && _h !== void 0 ? _h : claimer.status) !== null && _j !== void 0 ? _j : "").toLowerCase();
            const claimerVerified = claimerStatus === "verified" ||
                claimerStatus === "approved" ||
                claimerStatus === "active_verified" ||
                claimer.isVerified === true ||
                claimer.isProfileVerified === true;
            if (!claimerVerified) {
                throw new https_1.HttpsError("permission-denied", "Only active verified drivers can claim marketplace requests.");
            }
            const fleetSnap = await tx.get(db()
                .collection("drivers")
                .doc(driverId)
                .collection("vehicles")
                .limit(20));
            const hasApprovedVehicle = fleetSnap.docs.some((vDoc) => {
                var _a, _b, _c;
                const vData = (_a = vDoc.data()) !== null && _a !== void 0 ? _a : {};
                const vStatus = String((_c = (_b = vData.verificationStatus) !== null && _b !== void 0 ? _b : vData.status) !== null && _c !== void 0 ? _c : "").toUpperCase();
                return (vStatus === "APPROVED" ||
                    vStatus === "VERIFIED" ||
                    vData.isVerified === true);
            });
            if (!hasApprovedVehicle) {
                throw new https_1.HttpsError("failed-precondition", "An approved vehicle is required to claim marketplace requests.");
            }
        }
        else {
            throw new https_1.HttpsError("failed-precondition", "This trip is no longer available.");
        }
        if ((_k = data.driver) === null || _k === void 0 ? void 0 : _k.driverId) {
            throw new https_1.HttpsError("failed-precondition", "Another driver claimed this trip first.");
        }
        // Verify pending bids before assignment: accept the claimer's own
        // pending bid (keeps bid history consistent) and reject everyone
        // else's so no stale pending bid outlives the claim.
        const pendingBids = await tx.get(ref.collection("bids").where("status", "==", "pending"));
        for (const b of pendingBids.docs) {
            if (b.id === driverId) {
                tx.update(b.ref, {
                    status: "accepted",
                    acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                });
            }
            else {
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
            driverId: driverId,
            dispatchTier: (_l = data.dispatchTier) !== null && _l !== void 0 ? _l : null,
            pingDriverId: null,
            pingDriverIds: [],
            pingExpiresAt: null,
            tierExpiresAt: null,
            hasActiveBids: false,
            biddingCompleted: pendingBids.size > 0 ? true : ((_m = data.biddingCompleted) !== null && _m !== void 0 ? _m : false),
            acceptedBidDriverId: pendingBids.docs.some((b) => b.id === driverId)
                ? driverId
                : ((_o = data.acceptedBidDriverId) !== null && _o !== void 0 ? _o : null),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    });
    return { ok: true };
});
/**
 * Driver declines a Stage 1 ping → streak breaks, then dispatch continues
 * sequentially to the next nearest Stage 1 driver or falls back directly
 * to the global Order Pool (Stage 3).
 */
exports.declineTrip = (0, https_1.onCall)(async (request) => {
    var _a, _b;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in.");
    }
    const driverId = request.auth.uid;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "");
    if (!tripId)
        throw new https_1.HttpsError("invalid-argument", "tripId is required.");
    const snap = await requirePingedDriver(tripId, driverId);
    // Rejecting an incoming request breaks the streak.
    try {
        await (0, driverStreak_1.breakDriverStreak)(driverId, "driver_declined");
    }
    catch (e) {
        console.warn(`declineTrip: streak break failed for ${driverId}: ${e}`);
    }
    const tuning = await getDispatchTuning();
    const rejectionEntry = {
        driverId,
        action: "rejected",
        timestamp: nowMs(),
    };
    await snap.ref.update({
        status: "SEARCHING_DRIVER",
        pingDriverId: null,
        pingDriverIds: [],
        pingExpiresAt: null,
        tierExpiresAt: null,
        cancellationSource: "rejected_by_driver",
        declineCount: admin.firestore.FieldValue.increment(1),
        attemptedDriverIds: admin.firestore.FieldValue.arrayUnion(driverId),
        rejections: admin.firestore.FieldValue.arrayUnion(rejectionEntry),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    // Try remaining Stage 1 drivers sequentially before escalating to Order Pool (Stage 3).
    const fresh = await snap.ref.get();
    if (fresh.exists && fresh.data().status === "SEARCHING_DRIVER") {
        const restarted1 = await startTier1(snap.ref, fresh.data(), tuning);
        if (!restarted1) {
            await startTier3(snap.ref);
        }
    }
    return { ok: true };
});
/** Driver GPS heartbeat → powers the customer's live OSM driver marker.
 *
 * Mock Location Guard: heartbeats flagged `isMocked` (GPS spoofing) are
 * rejected so a spoofed fix can never move the live marker, feed
 * proximity triggers, or poison nearest-driver ranking. */
exports.updateDriverLocation = (0, https_1.onCall)(async (request) => {
    var _a, _b;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in.");
    }
    const { tripId, lat, lng, isMocked } = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    if (!tripId || !isCoord(lat, lng)) {
        throw new https_1.HttpsError("invalid-argument", "tripId + valid {lat, lng} required.");
    }
    if (isMocked === true) {
        throw new https_1.HttpsError("failed-precondition", "Mock location detected. Disable mock locations to continue this trip.");
    }
    const ref = db().collection("trips").doc(String(tripId));
    const snap = await ref.get();
    if (!snap.exists)
        throw new https_1.HttpsError("not-found", "Trip not found.");
    const data = snap.data();
    const assigned = (_b = data.driver) === null || _b === void 0 ? void 0 : _b.driverId;
    if (assigned !== request.auth.uid) {
        throw new https_1.HttpsError("permission-denied", "Not your trip.");
    }
    if (!LIVE_STATUSES.includes(data.status)) {
        throw new https_1.HttpsError("failed-precondition", "Trip is no longer live.");
    }
    await ref.update({
        driverLocation: { lat, lng, updatedAt: nowMs() },
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    // Mirror the fix onto the driver doc so Tier 1/2 nearest-driver ranking
    // uses a fresh position (best-effort; trip tracking stays authoritative).
    try {
        await db().collection("drivers").doc(request.auth.uid).set({
            lastLocation: { lat, lng, updatedAt: nowMs() },
            lastSeen: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
    }
    catch (_c) {
        // Non-fatal — ranking falls back to the last goOnline fix.
    }
    return { ok: true };
});
const DRIVER_TRANSITIONS = {
    DRIVER_ACCEPTED: ["DRIVER_ARRIVING", "DRIVER_ARRIVED"],
    DRIVER_ARRIVING: ["DRIVER_ARRIVED"],
    DRIVER_ARRIVED: ["IN_PROGRESS"],
    IN_PROGRESS: ["COMPLETED"],
};
/** Driver advances arrival/progress/completion along the allowed chain. */
exports.advanceTripStatus = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in.");
    }
    const { tripId, status } = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    if (!tripId || typeof status !== "string") {
        throw new https_1.HttpsError("invalid-argument", "tripId + status required.");
    }
    const ref = db().collection("trips").doc(String(tripId));
    const snap = await ref.get();
    if (!snap.exists)
        throw new https_1.HttpsError("not-found", "Trip not found.");
    const data = snap.data();
    if (((_b = data.driver) === null || _b === void 0 ? void 0 : _b.driverId) !== request.auth.uid) {
        throw new https_1.HttpsError("permission-denied", "Not your trip.");
    }
    const allowed = (_c = DRIVER_TRANSITIONS[String(data.status)]) !== null && _c !== void 0 ? _c : [];
    if (!allowed.includes(String(status))) {
        throw new https_1.HttpsError("failed-precondition", `Cannot move from ${data.status} to ${status}.`);
    }
    const update = {
        status,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    // Record the timestamp when driver taps "Arrived" for no-show timer tracking
    if (status === "DRIVER_ARRIVED") {
        update["arrivedAt"] = admin.firestore.FieldValue.serverTimestamp();
    }
    else if (status === "COMPLETED") {
        update["completedAt"] = admin.firestore.FieldValue.serverTimestamp();
    }
    await ref.update(update);
    // Synchronous trip completion settlement: immediately post commission debit,
    // update wallet balance and trip settlement metadata with zero delay.
    if (status === "COMPLETED") {
        try {
            const snapAfter = await ref.get();
            if (snapAfter.exists) {
                await (0, driverStreak_1.handleTripCompletion)(String(tripId), snapAfter.data());
            }
        }
        catch (e) {
            console.warn(`advanceTripStatus[${tripId}]: synchronous settlement warning: ${e}`);
        }
    }
    // Arrival alert: in-app notification + rich FCM push to the customer
    // (also fired for proximity auto-arrivals — same server path).
    if (status === "DRIVER_ARRIVED") {
        const customerId = String((_d = data.customerId) !== null && _d !== void 0 ? _d : "");
        const driverName = String((_f = (_e = data.driver) === null || _e === void 0 ? void 0 : _e.fullName) !== null && _f !== void 0 ? _f : "Your driver");
        await notifyCustomer(customerId, String(tripId), "Driver arrived", `${driverName} has arrived at the pickup point.`, "driver_arrived");
    }
    return { ok: true };
});
// ── Customer actions ───────────────────────────────────────────────────────
/** Release active trip wallet escrow hold back to customer's available balance upon cancellation */
async function releaseTripEscrow(tripId, tripData) {
    var _a, _b, _c, _d;
    const walletCoverage = Number((_c = (_a = tripData["walletCoverageAmount"]) !== null && _a !== void 0 ? _a : (_b = tripData["paymentBreakdown"]) === null || _b === void 0 ? void 0 : _b["walletCoverageAmount"]) !== null && _c !== void 0 ? _c : 0);
    if (walletCoverage > 0 && tripData["escrowLocked"] === true && !tripData["escrowRefundedAt"]) {
        const customerId = String((_d = tripData["customerId"]) !== null && _d !== void 0 ? _d : "");
        if (customerId) {
            try {
                const custWalletRef = db().collection("wallets").doc(customerId);
                const coverageKobo = (0, driverStreak_1.nairaToKobo)(walletCoverage);
                await custWalletRef.set({
                    escrowBalance: admin.firestore.FieldValue.increment(-walletCoverage),
                }, { merge: true });
                await custWalletRef.collection("transactions").add({
                    type: "trip_escrow_refund",
                    amountNaira: walletCoverage,
                    amountKobo: coverageKobo,
                    amount: coverageKobo,
                    tripId,
                    currency: "NGN",
                    note: `Escrow hold released for cancelled trip ${tripId}`,
                    createdAt: admin.firestore.FieldValue.serverTimestamp(),
                });
            }
            catch (e) {
                console.warn(`releaseTripEscrow[${tripId}] warning: ${e}`);
            }
        }
        try {
            await db().collection("trips").doc(tripId).update({
                escrowLocked: false,
                escrowRefundedAt: admin.firestore.FieldValue.serverTimestamp(),
                "paymentBreakdown.escrowLocked": false,
                "paymentBreakdown.escrowRefunded": true,
            });
        }
        catch (_) { }
    }
}
/** Customer or driver cancels a live trip — sets cancellationSource for streak logic. */
exports.cancelTrip = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t, _u, _v, _w, _x, _y, _z, _0, _1;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "");
    if (!tripId)
        throw new https_1.HttpsError("invalid-argument", "tripId is required.");
    const ref = db().collection("trips").doc(tripId);
    const snap = await ref.get();
    if (!snap.exists)
        throw new https_1.HttpsError("not-found", "Trip not found.");
    const data = snap.data();
    const callerId = request.auth.uid;
    const isCustomer = data.customerId === callerId;
    const isDriver = ((_c = data.driver) === null || _c === void 0 ? void 0 : _c.driverId) === callerId;
    if (!isCustomer && !isDriver) {
        throw new https_1.HttpsError("permission-denied", "Not your trip.");
    }
    if (!LIVE_STATUSES.includes(data.status)) {
        throw new https_1.HttpsError("failed-precondition", "Trip is already closed.");
    }
    // ── Cancellation reason (audited, allow-listed) ──────────────────────
    // Unknown/absent codes land as `other` — the audit stays complete while
    // a hostile client can never inject a free-form value into the trail.
    const rawReason = String((_e = (_d = request.data) === null || _d === void 0 ? void 0 : _d.reason) !== null && _e !== void 0 ? _e : "other").trim();
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
        var _a, _b;
        const userSnap = await tx.get(userRef);
        const stats = ((_b = (_a = userSnap.data()) === null || _a === void 0 ? void 0 : _a.cancelStats) !== null && _b !== void 0 ? _b : {});
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
            throw new https_1.HttpsError("resource-exhausted", "Too many cancellations in the last hour. Please wait before cancelling again.");
        }
        tx.set(userRef, { cancelStats: { count: count + 1, windowStartMs: windowStart } }, { merge: true });
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
            statusAtCancel: String((_f = data.status) !== null && _f !== void 0 ? _f : ""),
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    catch (e) {
        console.warn(`cancelTrip: audit write failed for ${tripId}: ${e}`);
    }
    // Customer cancellation with paid waiting fee & trusted customer / cash settlement logic
    if (isCustomer) {
        const customerId = String((_g = data.customerId) !== null && _g !== void 0 ? _g : callerId);
        let paidWaitingFee = 0;
        const isArrivedOrProgress = data.status === "DRIVER_ARRIVED" || data.status === "IN_PROGRESS";
        const arrivedAtMs = (_k = (_j = (_h = data.arrivedAt) === null || _h === void 0 ? void 0 : _h.toMillis) === null || _j === void 0 ? void 0 : _j.call(_h)) !== null && _k !== void 0 ? _k : 0;
        const enableWaitingBilling = data.enableWaitingTimeBilling !== false;
        if (isArrivedOrProgress && arrivedAtMs > 0 && enableWaitingBilling) {
            const elapsedMs = nowMs() - arrivedAtMs;
            const freeWaitMs = 10 * 60 * 1000; // 10 minutes free countdown
            if (elapsedMs > freeWaitMs) {
                const paidWaitMins = Math.ceil((elapsedMs - freeWaitMs) / (60 * 1000));
                const timeRatePerMin = Number((_l = data.timeRatePerMinute) !== null && _l !== void 0 ? _l : 20);
                paidWaitingFee = Math.max(0, paidWaitMins * timeRatePerMin);
            }
        }
        const useCashSettlement = ((_m = request.data) === null || _m === void 0 ? void 0 : _m.useCashSettlement) === true;
        if (paidWaitingFee > 0 && useCashSettlement) {
            await ref.update({
                status: "CANCELLED_WAITING_CASH_SETTLEMENT",
                cancellationSource: "customer",
                cancellationReason: reason,
                paidWaitingFee,
                pendingCashFee: paidWaitingFee,
                pingDriverId: null,
                pingExpiresAt: null,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            const assignedDriverId = String((_q = (_p = (_o = data.driver) === null || _o === void 0 ? void 0 : _o.driverId) !== null && _p !== void 0 ? _p : data.driverId) !== null && _q !== void 0 ? _q : "");
            if (assignedDriverId) {
                await notifyCustomer(assignedDriverId, tripId, "Cash Settlement Requested", `Customer cancelled during paid waiting. Collect ₦${paidWaitingFee} cash from customer and tap "Accept Cash & Cancel".`, "cash_settlement_requested", {}, `driver_${assignedDriverId}`);
            }
            return { ok: true, cancelledBy: "customer", cashSettlement: true, fee: paidWaitingFee };
        }
        if (paidWaitingFee > 0) {
            // Wallet settlement
            const custUserSnap = await db().collection("users").doc(customerId).get();
            const custUserData = (_r = custUserSnap.data()) !== null && _r !== void 0 ? _r : {};
            const completedTripCount = Number((_s = custUserData.completedTripCount) !== null && _s !== void 0 ? _s : 0);
            const isTrustedCustomer = completedTripCount >= 5;
            const walletRef = db().collection("wallets").doc(customerId);
            const walletSnap = await walletRef.get();
            const walletData = (_t = walletSnap.data()) !== null && _t !== void 0 ? _t : {};
            const currentBalance = typeof walletData.mainWalletBalance === "number"
                ? walletData.mainWalletBalance
                : (typeof walletData.balance === "number" ? walletData.balance / 100 : 0);
            if (currentBalance < paidWaitingFee && !isTrustedCustomer) {
                throw new https_1.HttpsError("failed-precondition", `INSUFFICIENT_FUNDS: Your wallet balance (₦${currentBalance}) is insufficient for the ₦${paidWaitingFee} paid waiting fee. Please top up your wallet or select Cash Settlement.`, { currentBalance, paidWaitingFee, isTrustedCustomer });
            }
            // Deduct wallet / record negative balance for trusted customers
            if (currentBalance >= paidWaitingFee) {
                // Direct wallet deduction
                await db().runTransaction(async (wTx) => {
                    var _a, _b, _c;
                    wTx.set(walletRef, {
                        mainWalletBalance: admin.firestore.FieldValue.increment(-paidWaitingFee),
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    }, { merge: true });
                    const assignedDriverId = String((_c = (_b = (_a = data.driver) === null || _a === void 0 ? void 0 : _a.driverId) !== null && _b !== void 0 ? _b : data.driverId) !== null && _c !== void 0 ? _c : "");
                    if (assignedDriverId) {
                        const driverWalletRef = db().collection("wallets").doc(assignedDriverId);
                        wTx.set(driverWalletRef, {
                            mainWalletBalance: admin.firestore.FieldValue.increment(paidWaitingFee),
                            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                        }, { merge: true });
                    }
                });
            }
            else {
                // Trusted Customer Exception: record outstanding negative balance
                const shortage = paidWaitingFee - Math.max(0, currentBalance);
                await db().collection("users").doc(customerId).set({
                    outstandingNegativeBalance: admin.firestore.FieldValue.increment(shortage),
                }, { merge: true });
                if (currentBalance > 0) {
                    await walletRef.set({
                        mainWalletBalance: 0,
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    }, { merge: true });
                }
                const assignedDriverId = String((_w = (_v = (_u = data.driver) === null || _u === void 0 ? void 0 : _u.driverId) !== null && _v !== void 0 ? _v : data.driverId) !== null && _w !== void 0 ? _w : "");
                if (assignedDriverId) {
                    await db().collection("wallets").doc(assignedDriverId).set({
                        mainWalletBalance: admin.firestore.FieldValue.increment(paidWaitingFee),
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    }, { merge: true });
                }
            }
        }
        await releaseTripEscrow(tripId, data);
        await ref.update({
            status: "CANCELLED",
            cancellationSource: "customer",
            cancellationReason: reason,
            paidWaitingFee,
            pingDriverId: null,
            pingExpiresAt: null,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return { ok: true, cancelledBy: "customer", paidWaitingFee };
    }
    // Driver cancellation logic
    let cancellationSource = "unknown";
    if (data.status === "DRIVER_ARRIVED") {
        const arrivedAt = (_z = (_y = (_x = data.arrivedAt) === null || _x === void 0 ? void 0 : _x.toMillis) === null || _y === void 0 ? void 0 : _y.call(_x)) !== null && _z !== void 0 ? _z : 0;
        const waitedMs = nowMs() - arrivedAt;
        const noShowWaitMs = ((_0 = data["noShowWaitMinutes"]) !== null && _0 !== void 0 ? _0 : 10) * 60 * 1000;
        cancellationSource =
            waitedMs >= noShowWaitMs ? "driver_no_show" : "driver_before_arrival";
    }
    else {
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
        const currentCount = Number((_1 = data.reassignmentCount) !== null && _1 !== void 0 ? _1 : 0);
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
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            // Chain next nearest dispatch
            const freshSnap = await ref.get();
            if (freshSnap.exists) {
                const restarted = await startTier1(ref, freshSnap.data(), await getDispatchTuning());
                if (!restarted) {
                    await startTier3(ref);
                }
            }
            return { ok: true, reassigned: true, attempt: nextCount };
        }
        else {
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
                statusMessage: "All drivers are busy right now. Keep searching or wait?",
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
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
            }
            catch (_2) {
                /* best-effort */
            }
            return { ok: true, needsCustomerAction: true };
        }
    }
    // Fallback cancellation (e.g. driver no-show after waiting)
    await releaseTripEscrow(tripId, data);
    await ref.update({
        status: "CANCELLED",
        cancellationSource,
        cancellationReason: reason,
        pingDriverId: null,
        pingExpiresAt: null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { ok: true };
});
// ── Multi-Driver Bidding System & Customer Actions ─────────────────────────
/** Driver submits a custom fare bid on an open trip document */
exports.submitBid = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in to bid.");
    }
    const driverId = request.auth.uid;
    const { tripId, offeredFare, etaMinutes } = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    if (!tripId || typeof offeredFare !== "number" || offeredFare <= 0) {
        throw new https_1.HttpsError("invalid-argument", "tripId and valid offeredFare (number > 0) are required.");
    }
    // 1. Verify driver is active, online, and verified
    const driverDoc = await db().collection("drivers").doc(driverId).get();
    if (!driverDoc.exists) {
        throw new https_1.HttpsError("permission-denied", "Driver profile not found.");
    }
    const driverData = driverDoc.data();
    if (driverData.isOnline !== true) {
        throw new https_1.HttpsError("failed-precondition", "You must be online to submit bids.");
    }
    const driverStatus = String((_c = (_b = driverData.verificationStatus) !== null && _b !== void 0 ? _b : driverData.status) !== null && _c !== void 0 ? _c : "").toLowerCase();
    const isVerified = driverStatus === "verified" ||
        driverStatus === "approved" ||
        driverStatus === "active_verified" ||
        driverData.isVerified === true ||
        driverData.isProfileVerified === true;
    if (!isVerified) {
        throw new https_1.HttpsError("permission-denied", "Only active verified drivers can submit bids.");
    }
    const tripRef = db().collection("trips").doc(String(tripId));
    const tripSnap = await tripRef.get();
    if (!tripSnap.exists) {
        throw new https_1.HttpsError("not-found", "Trip not found.");
    }
    const tripData = tripSnap.data();
    // Self-assignment guard: drivers cannot bid on orders they created as customer
    const orderCustomerId = String((_e = (_d = tripData.customerId) !== null && _d !== void 0 ? _d : tripData.userId) !== null && _e !== void 0 ? _e : "");
    if (orderCustomerId && orderCustomerId === driverId) {
        throw new https_1.HttpsError("failed-precondition", "You cannot bid on an order you created as a customer.");
    }
    // 2. Validate offered fare against baseline, rounded to nearest 100
    const baseline = Number((_g = (_f = tripData.baselineFare) !== null && _f !== void 0 ? _f : tripData.fareAmount) !== null && _g !== void 0 ? _g : 0);
    const roundedOfferedFare = (0, pricing_1.roundToNearest100)(offeredFare, baseline);
    if (baseline > 0 && roundedOfferedFare < baseline) {
        throw new https_1.HttpsError("invalid-argument", `Offered fare (₦${roundedOfferedFare}) cannot be lower than the baseline fare (₦${baseline}).`);
    }
    if ((_h = tripData.driver) === null || _h === void 0 ? void 0 : _h.driverId) {
        throw new https_1.HttpsError("failed-precondition", "This trip has already been claimed by another driver.");
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
        throw new https_1.HttpsError("failed-precondition", "This trip is no longer open for bidding.");
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
        offeredFare: roundedOfferedFare,
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
    const vehicleDetails = [snapshot.vehicleColor, snapshot.vehicleModel]
        .filter(Boolean)
        .join(" ");
    const vehicleStr = snapshot.plateNumber
        ? `${vehicleDetails} (${snapshot.plateNumber})`.trim()
        : vehicleDetails;
    // Rich counter-bid alert: in-app notification + FCM push to the customer
    // with complete driver details, ETA, vehicle info, offered fare, and Accept/Reject payload
    await notifyCustomer(String((_j = tripData.customerId) !== null && _j !== void 0 ? _j : ""), String(tripId), "New Driver Offer", `${snapshot.fullName} offered ₦${Number(roundedOfferedFare).toLocaleString()} (~${etaMinutes !== null && etaMinutes !== void 0 ? etaMinutes : 5} mins away)`, "driver_counter_bid", {
        driverId,
        driverName: String(snapshot.fullName),
        driverPhoto: String((_k = snapshot.photoUrl) !== null && _k !== void 0 ? _k : ""),
        driverRating: String((_l = snapshot.rating) !== null && _l !== void 0 ? _l : 0),
        offeredFare: String(roundedOfferedFare),
        offeredFareFormatted: `₦${Number(roundedOfferedFare).toLocaleString()}`,
        etaMinutes: String(etaMinutes !== null && etaMinutes !== void 0 ? etaMinutes : 5),
        vehicleModel: String((_m = snapshot.vehicleModel) !== null && _m !== void 0 ? _m : ""),
        vehicleColor: String((_o = snapshot.vehicleColor) !== null && _o !== void 0 ? _o : ""),
        plateNumber: String((_p = snapshot.plateNumber) !== null && _p !== void 0 ? _p : ""),
        vehicleDetails: vehicleStr,
    });
    return { ok: true, bidId: driverId };
});
/** Customer rejects a driver's bid (driver may re-bid later) */
exports.rejectBid = (0, https_1.onCall)(async (request) => {
    var _a;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const customerId = request.auth.uid;
    const { tripId, driverId } = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    if (!tripId || !driverId) {
        throw new https_1.HttpsError("invalid-argument", "tripId and driverId are required.");
    }
    const tripRef = db().collection("trips").doc(String(tripId));
    const tripSnap = await tripRef.get();
    if (!tripSnap.exists) {
        throw new https_1.HttpsError("not-found", "Trip not found.");
    }
    if (tripSnap.data().customerId !== customerId) {
        throw new https_1.HttpsError("permission-denied", "Only the requesting customer can reject bids.");
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
exports.acceptBid = (0, https_1.onCall)(async (request) => {
    var _a;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const customerId = request.auth.uid;
    const { tripId, driverId } = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    if (!tripId || !driverId) {
        throw new https_1.HttpsError("invalid-argument", "tripId and driverId are required.");
    }
    const tripRef = db().collection("trips").doc(String(tripId));
    const bidRef = tripRef.collection("bids").doc(String(driverId));
    await db().runTransaction(async (tx) => {
        var _a;
        const tripSnap = await tx.get(tripRef);
        if (!tripSnap.exists) {
            throw new https_1.HttpsError("not-found", "Trip not found.");
        }
        const tripData = tripSnap.data();
        if (tripData.customerId !== customerId) {
            throw new https_1.HttpsError("permission-denied", "Only the requesting customer can accept bids.");
        }
        if ((_a = tripData.driver) === null || _a === void 0 ? void 0 : _a.driverId) {
            throw new https_1.HttpsError("failed-precondition", "A driver has already been assigned to this trip.");
        }
        const bidSnap = await tx.get(bidRef);
        if (!bidSnap.exists) {
            throw new https_1.HttpsError("not-found", "Bid not found.");
        }
        const bidData = bidSnap.data();
        if (bidData.status !== "pending") {
            throw new https_1.HttpsError("failed-precondition", "This bid is no longer pending.");
        }
        const driverSnap = await tx.get(db().collection("drivers").doc(driverId));
        const d = driverSnap.exists ? driverSnap.data() : {};
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
exports.increaseTripFare = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    const customerId = request.auth.uid;
    const { tripId, newFare } = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    if (!tripId || typeof newFare !== "number" || newFare <= 0) {
        throw new https_1.HttpsError("invalid-argument", "tripId and valid newFare are required.");
    }
    const tripRef = db().collection("trips").doc(String(tripId));
    const tripSnap = await tripRef.get();
    if (!tripSnap.exists) {
        throw new https_1.HttpsError("not-found", "Trip not found.");
    }
    const tripData = tripSnap.data();
    if (tripData.customerId !== customerId) {
        throw new https_1.HttpsError("permission-denied", "Not your trip.");
    }
    const currentFare = Number((_c = (_b = tripData.fareAmount) !== null && _b !== void 0 ? _b : tripData.baselineFare) !== null && _c !== void 0 ? _c : 0);
    const roundedNewFare = (0, pricing_1.roundToNearest100)(newFare);
    if (roundedNewFare <= currentFare) {
        throw new https_1.HttpsError("invalid-argument", "New fare must be higher than current fare.");
    }
    const wasNeedsAction = tripData.status === "needs_customer_action";
    const boostPct = currentFare > 0
        ? Math.round(((roundedNewFare - currentFare) / currentFare) * 100)
        : 0;
    const rawFareTiers = Array.isArray(tripData.fareTiers) ? tripData.fareTiers : [];
    const selectedTiers = Array.isArray(tripData.selectedTiers) ? tripData.selectedTiers : [];
    const updatedFareTiers = rawFareTiers.map((t) => {
        if (t && typeof t === "object" && (selectedTiers.length === 0 || selectedTiers.includes(t.tierId))) {
            return Object.assign(Object.assign({}, t), { fareAmount: roundedNewFare });
        }
        return t;
    });
    const updatePayload = {
        fareAmount: roundedNewFare,
        proposedFare: roundedNewFare,
        fareFormatted: `₦${roundedNewFare.toLocaleString()}`,
        fareBoosted: true,
        boostPercent: boostPct,
        boostedAt: admin.firestore.FieldValue.serverTimestamp(),
        status: wasNeedsAction ? "SEARCHING_DRIVER" : tripData.status,
        reassignmentCount: wasNeedsAction ? 0 : ((_d = tripData.reassignmentCount) !== null && _d !== void 0 ? _d : 0),
        statusMessage: "Price increased! Searching for nearby drivers...",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (updatedFareTiers.length > 0) {
        updatePayload.fareTiers = updatedFareTiers;
    }
    await tripRef.update(updatePayload);
    if (wasNeedsAction) {
        const fresh = (await tripRef.get()).data();
        const restarted = await startTier1(tripRef, fresh, await getDispatchTuning());
        if (!restarted) {
            await startTier3(tripRef);
        }
    }
    return { ok: true, newFare };
});
/**
 * Customer chooses to keep searching after 3-strike driver cancellations or when drivers are busy.
 * Resets reassignmentCount and restarts matchmaking without dropping the order or escrow.
 */
exports.keepSearchingTrip = (0, https_1.onCall)(async (request) => {
    var _a, _b;
    const customerId = (_a = request.auth) === null || _a === void 0 ? void 0 : _a.uid;
    if (!customerId) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in.");
    }
    const { tripId } = ((_b = request.data) !== null && _b !== void 0 ? _b : {});
    if (!tripId) {
        throw new https_1.HttpsError("invalid-argument", "tripId is required.");
    }
    const tripRef = db().collection("trips").doc(tripId);
    const tripSnap = await tripRef.get();
    if (!tripSnap.exists) {
        throw new https_1.HttpsError("not-found", "Trip not found.");
    }
    const tripData = tripSnap.data();
    if (tripData.customerId !== customerId) {
        throw new https_1.HttpsError("permission-denied", "Not your trip.");
    }
    await tripRef.update({
        status: "SEARCHING_DRIVER",
        reassignmentCount: 0,
        statusMessage: "Searching for available drivers nearby...",
        cancellationSource: null,
        cancellationReason: null,
        driver: null,
        driverLocation: null,
        driverId: null,
        arrivedAt: null,
        pingDriverId: null,
        pingDriverIds: [],
        pingExpiresAt: null,
        tierExpiresAt: null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    const fresh = (await tripRef.get()).data();
    const restarted = await startTier1(tripRef, fresh, await getDispatchTuning());
    if (!restarted) {
        await startTier3(tripRef);
    }
    return { ok: true, status: "SEARCHING_DRIVER" };
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
exports.verifyDeliveryPin = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in.");
    }
    const driverId = request.auth.uid;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "");
    const pin = String((_d = (_c = request.data) === null || _c === void 0 ? void 0 : _c.pin) !== null && _d !== void 0 ? _d : "").trim();
    if (!tripId || !/^\d{4}$/.test(pin)) {
        throw new https_1.HttpsError("invalid-argument", "A 4-digit delivery PIN is required.");
    }
    const ref = db().collection("trips").doc(tripId);
    const snap = await ref.get();
    if (!snap.exists)
        throw new https_1.HttpsError("not-found", "Trip not found.");
    const data = snap.data();
    if (((_e = data.driver) === null || _e === void 0 ? void 0 : _e.driverId) !== driverId) {
        throw new https_1.HttpsError("permission-denied", "Not your trip.");
    }
    const serviceType = String((_f = data.serviceType) !== null && _f !== void 0 ? _f : "ride");
    if (serviceType === "ride") {
        throw new https_1.HttpsError("failed-precondition", "Passenger trips do not use a delivery PIN.");
    }
    if (data.deliveryPinVerified === true) {
        return { ok: true, alreadyVerified: true };
    }
    const pinSnap = await db().collection("delivery_pins").doc(tripId).get();
    if (String((_h = (_g = pinSnap.data()) === null || _g === void 0 ? void 0 : _g.pin) !== null && _h !== void 0 ? _h : "") !== pin) {
        throw new https_1.HttpsError("invalid-argument", "That code does not match. Ask the recipient for the 4-digit PIN.");
    }
    if (!LIVE_STATUSES.includes(String((_j = data.status) !== null && _j !== void 0 ? _j : ""))) {
        throw new https_1.HttpsError("failed-precondition", "This delivery is no longer active.");
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
    try {
        const snapAfter = await ref.get();
        if (snapAfter.exists) {
            await (0, driverStreak_1.handleTripCompletion)(tripId, snapAfter.data());
        }
    }
    catch (e) {
        console.warn(`verifyDeliveryPin[${tripId}]: synchronous settlement warning: ${e}`);
    }
    return { ok: true };
});
// ── Hub Admin Dispute Actions ──────────────────────────────────────────────
/** Hub Admin: Force Complete a trip during live support/dispute resolution */
exports.hubForceCompleteTrip = (0, https_1.onCall)(async (request) => {
    var _a, _b;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Hub authentication required.");
    }
    const adminUid = request.auth.uid;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "").trim();
    if (!tripId)
        throw new https_1.HttpsError("invalid-argument", "tripId required.");
    const ref = db().collection("trips").doc(tripId);
    const snap = await ref.get();
    if (!snap.exists)
        throw new https_1.HttpsError("not-found", "Trip not found.");
    await ref.update({
        status: "COMPLETED",
        deliveryPinVerified: true,
        forceCompletedBy: adminUid,
        forceCompletedAt: admin.firestore.FieldValue.serverTimestamp(),
        completedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    try {
        const snapAfter = await ref.get();
        if (snapAfter.exists) {
            await (0, driverStreak_1.handleTripCompletion)(tripId, snapAfter.data());
        }
    }
    catch (e) {
        console.warn(`hubForceCompleteTrip[${tripId}]: synchronous settlement warning: ${e}`);
    }
    return { ok: true, tripId };
});
/** Driver confirms cash collected from customer for waiting time cancellation */
exports.confirmCashCancellation = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in.");
    }
    const driverId = request.auth.uid;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "");
    if (!tripId)
        throw new https_1.HttpsError("invalid-argument", "tripId is required.");
    const ref = db().collection("trips").doc(tripId);
    const snap = await ref.get();
    if (!snap.exists)
        throw new https_1.HttpsError("not-found", "Trip not found.");
    const data = snap.data();
    const assignedDriverId = String((_e = (_d = (_c = data.driver) === null || _c === void 0 ? void 0 : _c.driverId) !== null && _d !== void 0 ? _d : data.driverId) !== null && _e !== void 0 ? _e : "");
    if (assignedDriverId !== driverId) {
        throw new https_1.HttpsError("permission-denied", "Not your trip.");
    }
    await ref.update({
        status: "CANCELLED",
        cashSettlementConfirmed: true,
        cashSettlementConfirmedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { ok: true };
});
/** Hub Admin: Cancel trip & refund any held escrow */
exports.hubCancelRefundTrip = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Hub authentication required.");
    }
    const adminUid = request.auth.uid;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "").trim();
    const reason = String((_d = (_c = request.data) === null || _c === void 0 ? void 0 : _c.reason) !== null && _d !== void 0 ? _d : "Cancelled by Hub admin");
    if (!tripId)
        throw new https_1.HttpsError("invalid-argument", "tripId required.");
    const ref = db().collection("trips").doc(tripId);
    const snap = await ref.get();
    if (!snap.exists)
        throw new https_1.HttpsError("not-found", "Trip not found.");
    await releaseTripEscrow(tripId, snap.data());
    await ref.update({
        status: "CANCELLED",
        cancellationSource: "admin_hub",
        cancellationReason: reason,
        cancelledByAdmin: adminUid,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { ok: true, tripId };
});
/** Hub Admin: Manual PIN Bypass during call verification */
exports.hubManualPinBypass = (0, https_1.onCall)(async (request) => {
    var _a, _b;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Hub authentication required.");
    }
    const adminUid = request.auth.uid;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "").trim();
    if (!tripId)
        throw new https_1.HttpsError("invalid-argument", "tripId required.");
    const ref = db().collection("trips").doc(tripId);
    const snap = await ref.get();
    if (!snap.exists)
        throw new https_1.HttpsError("not-found", "Trip not found.");
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
exports.submitCancellationFeedback = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "").trim();
    const userId = String((_d = (_c = request.data) === null || _c === void 0 ? void 0 : _c.userId) !== null && _d !== void 0 ? _d : "").trim();
    const role = String((_f = (_e = request.data) === null || _e === void 0 ? void 0 : _e.role) !== null && _f !== void 0 ? _f : "").trim();
    const reason = String((_h = (_g = request.data) === null || _g === void 0 ? void 0 : _g.reason) !== null && _h !== void 0 ? _h : "").trim();
    const detail = String((_k = (_j = request.data) === null || _j === void 0 ? void 0 : _j.detail) !== null && _k !== void 0 ? _k : "").trim();
    if (!tripId)
        throw new https_1.HttpsError("invalid-argument", "tripId is required.");
    if (!userId)
        throw new https_1.HttpsError("invalid-argument", "userId is required.");
    if (role !== "customer" && role !== "driver") {
        throw new https_1.HttpsError("invalid-argument", "role must be 'customer' or 'driver'.");
    }
    if (!reason)
        throw new https_1.HttpsError("invalid-argument", "reason is required.");
    if (reason.length > 100) {
        throw new https_1.HttpsError("invalid-argument", "reason must be at most 100 characters.");
    }
    if (detail.length > 300) {
        throw new https_1.HttpsError("invalid-argument", "detail must be at most 300 characters.");
    }
    const docId = `${tripId}_${userId}`;
    const ref = db().collection("cancellation_feedback").doc(docId);
    try {
        await ref.set({
            tripId,
            userId,
            role,
            reason,
            detail: detail !== null && detail !== void 0 ? detail : "",
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: false });
    }
    catch (e) {
        console.error(`submitCancellationFeedback[${docId}]: ${e}`);
        throw new https_1.HttpsError("internal", "Unable to save feedback.");
    }
    return { ok: true };
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
exports.skipDeliveryPin = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in.");
    }
    const driverId = request.auth.uid;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "").trim();
    if (!tripId) {
        throw new https_1.HttpsError("invalid-argument", "tripId is required.");
    }
    const ref = db().collection("trips").doc(tripId);
    const snap = await ref.get();
    if (!snap.exists)
        throw new https_1.HttpsError("not-found", "Trip not found.");
    const data = snap.data();
    // Gate 1: caller must be the assigned driver.
    if (((_c = data.driver) === null || _c === void 0 ? void 0 : _c.driverId) !== driverId) {
        throw new https_1.HttpsError("permission-denied", "Not your trip.");
    }
    // Gate 2: delivery trips only.
    const serviceType = String((_d = data.serviceType) !== null && _d !== void 0 ? _d : "ride");
    if (serviceType === "ride") {
        throw new https_1.HttpsError("failed-precondition", "Passenger trips do not use a delivery PIN.");
    }
    // Gate 3: PIN must be required and not already handled.
    if (!data.deliveryPinRequired) {
        throw new https_1.HttpsError("failed-precondition", "Delivery PIN is not required for this trip.");
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
    const startedAtMs = (_k = (_g = (_f = (_e = data.startedAt) === null || _e === void 0 ? void 0 : _e.toMillis) === null || _f === void 0 ? void 0 : _f.call(_e)) !== null && _g !== void 0 ? _g : (_j = (_h = data.updatedAt) === null || _h === void 0 ? void 0 : _h.toMillis) === null || _j === void 0 ? void 0 : _j.call(_h)) !== null && _k !== void 0 ? _k : Date.now();
    const elapsedMs = nowMs() - startedAtMs;
    if (elapsedMs < skipWaitMs) {
        const remainingSec = Math.ceil((skipWaitMs - elapsedMs) / 1000);
        throw new https_1.HttpsError("failed-precondition", `You can only skip the PIN after waiting 10 minutes. ${remainingSec}s remaining.`);
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
    }
    catch (e) {
        console.warn(`skipDeliveryPin: audit write failed for ${tripId}: ${e}`);
    }
    return { ok: true };
});
//# sourceMappingURL=trips.js.map