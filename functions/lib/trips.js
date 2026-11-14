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
exports.cancelDropoffApprovalRequest = exports.respondDropoffApproval = exports.requestDropoffApproval = exports.recordDropoffArrival = exports.skipDeliveryPin = exports.submitTripRating = exports.submitCancellationFeedback = exports.hubManualPinBypass = exports.hubCancelRefundTrip = exports.confirmCashCancellation = exports.hubForceCompleteTrip = exports.verifyDeliveryPin = exports.keepSearchingTrip = exports.retryTripDispatch = exports.reassignTrip = exports.increaseTripFare = exports.acceptBid = exports.rejectBid = exports.submitBid = exports.cancelTrip = exports.advanceTripStatus = exports.updateDriverLocation = exports.declineTrip = exports.acceptTrip = exports.sweepTripPings = exports.onTripCreated = exports.createTrip = exports.normPhone = exports.onTripChatMessage = exports.MAX_SEQUENTIAL_DISPATCH_DRIVERS = void 0;
exports.haversineKm = haversineKm;
exports.getDropoffRadiusMeters = getDropoffRadiusMeters;
exports.normalizePhone = normalizePhone;
exports.requirePingedDriver = requirePingedDriver;
exports.releaseTripEscrow = releaseTripEscrow;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const firestore_1 = require("firebase-functions/v2/firestore");
const scheduler_1 = require("firebase-functions/v2/scheduler");
const fareToken_1 = require("./fareToken");
const driverStreak_1 = require("./driverStreak");
const pricing_1 = require("./pricing");
const accountGuard_1 = require("./accountGuard");
const payments_1 = require("./payments");
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
exports.MAX_SEQUENTIAL_DISPATCH_DRIVERS = 3;
const DEFAULT_PING_TIMEOUT_MS = 15 * 1000;
const DEFAULT_REPING_INTERVAL_MS = 30 * 1000;
const DEFAULT_TIER1_TIMEOUT_MS = 15 * 1000;
const DEFAULT_DISPATCH_RADIUS_KM = 15;
const DEFAULT_TIER1_RADIUS_KM = 3;
const DEFAULT_TIER3_RADIUS_KM = 15;
const DEFAULT_DISPATCH_CANDIDATE_LIMIT = 25;
const DEFAULT_PUBLIC_POOL_DURATION_MIN = 60;
const DEFAULT_TUNING = {
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
let tuningCache = null;
/**
 * Live dispatch tunables from `system_settings/dispatch` (60s cache).
 * Every value is clamped into a safe band; missing doc / read failure
 * falls back to the compiled defaults, so dispatch never stalls.
 */
async function getDispatchTuning() {
    var _a, _b, _c, _d, _e, _f, _g;
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
        const bidCountdownSec = Math.round(num((_b = d.bidCountdownSec) !== null && _b !== void 0 ? _b : d.bidCountdownSeconds, 10, 5, 60));
        const tier1Radius = Math.min(num((_c = d.tier1RadiusKm) !== null && _c !== void 0 ? _c : d.searchRadiusKm, DEFAULT_TIER1_RADIUS_KM, 0.5, 50), tier3Radius);
        const tier1TimeoutSec = num((_d = d.tier1TimeoutSec) !== null && _d !== void 0 ? _d : d.sequentialTimeoutSec, 15, 5, 120);
        const publicPoolDurationMin = Math.round(num((_f = (_e = d.publicPoolDurationMin) !== null && _e !== void 0 ? _e : d.poolDurationMin) !== null && _f !== void 0 ? _f : d.publicPoolDurationMinutes, 60, 5, 1440));
        const value = {
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
    }
    catch (_h) {
        return (_g = tuningCache === null || tuningCache === void 0 ? void 0 : tuningCache.value) !== null && _g !== void 0 ? _g : DEFAULT_TUNING;
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
async function notifyCustomer(customerId, tripId, title, body, type, extra = {}, topicOverride) {
    var _a;
    if (!customerId)
        return;
    // Only persist to the inbox for high-value, non-transient event types.
    if (INBOX_TYPES.has(type)) {
        try {
            await db()
                .collection("users")
                .doc(customerId)
                .collection("notifications")
                .add(Object.assign(Object.assign({ title,
                body,
                tripId,
                type }, extra), { createdAt: admin.firestore.FieldValue.serverTimestamp() }));
        }
        catch (e) {
            console.warn(`notifyCustomer: in-app write failed for ${customerId}: ${e}`);
        }
    }
    try {
        const channelId = type.startsWith("order") ||
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
            topic: topicOverride !== null && topicOverride !== void 0 ? topicOverride : `user_${customerId}`,
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
            data: Object.assign({ type,
                tripId, click_action: "FLUTTER_NOTIFICATION_CLICK", fullScreen: channelId === "sese_orders" ? "true" : ((_a = extra.fullScreen) !== null && _a !== void 0 ? _a : "false") }, extra),
        });
    }
    catch (e) {
        console.warn(`notifyCustomer: FCM send failed for ${customerId}: ${e}`);
    }
}
async function notifyDriver(driverId, tripId, title, body, type, extra = {}) {
    if (!driverId)
        return;
    try {
        await db()
            .collection("drivers")
            .doc(driverId)
            .collection("notifications")
            .add(Object.assign(Object.assign({ title,
            body,
            tripId,
            type }, extra), { createdAt: admin.firestore.FieldValue.serverTimestamp() }));
    }
    catch (_) { }
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
            data: Object.assign({ type,
                tripId, click_action: "FLUTTER_NOTIFICATION_CLICK" }, extra),
        });
    }
    catch (e) {
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
 * Reads Hub-configured maximum drop-off completion radius in meters.
 * Defaults to 500 meters if unconfigured or invalid.
 */
async function getDropoffRadiusMeters() {
    var _a, _b, _c, _d, _e, _f;
    try {
        const snap = await db().collection("system_config").doc("remote_keys").get();
        if (snap.exists) {
            const val = (_b = (_a = snap.data()) === null || _a === void 0 ? void 0 : _a.dropoffCompletionRadiusMeters) !== null && _b !== void 0 ? _b : (_c = snap.data()) === null || _c === void 0 ? void 0 : _c.dropoff_completion_radius_meters;
            if (typeof val === "number" && val > 0)
                return val;
        }
    }
    catch (_) { }
    try {
        const snap = await db().collection("system_configs").doc("global_default").get();
        if (snap.exists) {
            const val = (_e = (_d = snap.data()) === null || _d === void 0 ? void 0 : _d.dropoffCompletionRadiusMeters) !== null && _e !== void 0 ? _e : (_f = snap.data()) === null || _f === void 0 ? void 0 : _f.dropoff_completion_radius_meters;
            if (typeof val === "number" && val > 0)
                return val;
        }
    }
    catch (_) { }
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
    var _a, _b;
    try {
        const doc = await db().collection("users").doc(uid).get();
        const settings = (_a = doc.data()) === null || _a === void 0 ? void 0 : _a.settings;
        if (typeof settings === "object" &&
            settings !== null &&
            settings.hidePhoneNumber === true) {
            return true;
        }
        const driverDoc = await db().collection("drivers").doc(uid).get();
        const dSettings = (_b = driverDoc.data()) === null || _b === void 0 ? void 0 : _b.settings;
        return (typeof dSettings === "object" &&
            dSettings !== null &&
            dSettings.hidePhoneNumber === true);
    }
    catch (_c) {
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
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t, _u, _v, _w, _x, _y, _z, _0, _1, _2;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in to book.");
    }
    const customerId = request.auth.uid;
    // ── Security gates (run before all booking logic) ─────────────────────────
    // App Check: reject calls from scripts / re-signed APKs lacking a valid
    // attestation token so that the callable cannot be used as an open booking API.
    (0, accountGuard_1.enforceAppCheck)(request);
    // Suspension gate: banned customers cannot create trips even when SDK-cached
    // Firestore rules have not yet propagated.
    await (0, accountGuard_1.requireAccountActive)(customerId, "customer");
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
    // Maximum custom fare cap: 10x baseline fare or 500,000 max to prevent absurd/hostile inputs.
    const maxFareCap = Math.max(primaryBaselineFare * 10, 500000);
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
        // Server-authoritative split share validation: ensure senderShare + receiverShare equals proposedFare.
        let senderShare = Number((_p = d.senderShareAmount) !== null && _p !== void 0 ? _p : 0);
        let receiverShare = Number((_q = d.receiverShareAmount) !== null && _q !== void 0 ? _q : 0);
        if (!Number.isFinite(senderShare) ||
            !Number.isFinite(receiverShare) ||
            senderShare <= 0 ||
            receiverShare <= 0 ||
            Math.abs((senderShare + receiverShare) - proposedFare) > 0.01) {
            senderShare = Math.round((proposedFare / 2) * 100) / 100;
            receiverShare = Math.round((proposedFare - senderShare) * 100) / 100;
        }
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
    let userNegativeBalance = 0;
    try {
        const custSnap = await db().collection("users").doc(customerId).get();
        if (custSnap.exists) {
            const cData = custSnap.data();
            customerName = String((_u = (_t = cData.fullName) !== null && _t !== void 0 ? _t : cData.name) !== null && _u !== void 0 ? _u : "Customer");
            customerPhone = (0, exports.normPhone)((_w = (_v = cData.phoneNumberE164) !== null && _v !== void 0 ? _v : cData.phoneNumber) !== null && _w !== void 0 ? _w : "");
            userNegativeBalance = Math.max(0, Number((_x = cData.outstandingNegativeBalance) !== null && _x !== void 0 ? _x : 0));
        }
    }
    catch (_) { }
    // ── Wallet Escrow & Cash Collection Breakdown Engine ───────────────────
    let availableWalletBalance = 0;
    let walletNegativeBalance = 0;
    const custWalletRef = db().collection("wallets").doc(customerId);
    try {
        const custWalletSnap = await custWalletRef.get();
        if (custWalletSnap.exists) {
            const wData = custWalletSnap.data();
            const mainBal = typeof wData.mainWalletBalance === "number"
                ? wData.mainWalletBalance
                : (typeof wData.balance === "number" ? wData.balance / 100 : 0);
            const escrowBal = typeof wData.escrowBalance === "number" ? wData.escrowBalance : 0;
            if (mainBal < 0) {
                walletNegativeBalance = Math.abs(mainBal);
            }
            availableWalletBalance = Math.max(0, mainBal - escrowBal);
        }
    }
    catch (e) {
        console.warn(`createTrip: wallet lookup warning: ${e}`);
    }
    const clientRecoveredDebt = Number((_y = d.recoveredDebt) !== null && _y !== void 0 ? _y : 0);
    const recoveredDebt = Math.max(userNegativeBalance, walletNegativeBalance, clientRecoveredDebt);
    const baseFare = proposedFare;
    const totalFare = baseFare + recoveredDebt;
    // Clear outstanding negative balance from user account since it is rolled into the new trip fare
    if (userNegativeBalance > 0) {
        try {
            await db().collection("users").doc(customerId).set({ outstandingNegativeBalance: 0 }, { merge: true });
        }
        catch (_) { }
    }
    let walletCoverageAmount = 0;
    let cashToCollect = totalFare;
    let collectAt = "pickup";
    let payerRole = "sender";
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
    }
    else if (paymentMode === "split") {
        payerRole = "split";
        const senderShare = Number((_z = d.senderShareAmount) !== null && _z !== void 0 ? _z : totalFare / 2);
        const receiverShare = Number((_0 = d.receiverShareAmount) !== null && _0 !== void 0 ? _0 : (totalFare - senderShare));
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
        if (paymentMethod === "cash" || (paymentMethod === "auto" && availableWalletBalance <= 0)) {
            walletCoverageAmount = 0;
            cashToCollect = totalFare;
            senderCashToCollect = totalFare;
            escrowLocked = false;
        }
        else {
            // Auto (smart default) or Wallet / Card
            walletCoverageAmount = (0, pricing_1.roundToNearest100)(Math.min(totalFare, availableWalletBalance));
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
    const tripDocPayload = Object.assign(Object.assign(Object.assign(Object.assign({ customerId,
        customerName, customerPhone: safeCustomerPhone, statusHistory: initialStatusHistory, tripBooker: {
            uid: customerId,
            customerId,
            name: customerName,
            fullName: customerName,
            phone: safeCustomerPhone,
            phoneNumber: safeCustomerPhone,
        }, createdBy: {
            uid: customerId,
            name: customerName,
            fullName: customerName,
            phone: safeCustomerPhone,
        }, serviceType, status: "SEARCHING_DRIVER", isVerifiedCustomer: isVerifiedCust }, maskedPhoneMap), { deliveryPinRequired: isPinRequired, deliveryPinVerified: !isPinRequired, order: {
            requireDeliveryPin: isPinRequired,
        } }), (splitPaymentData ? { splitPaymentStatus: "pending_receiver_consent", splitPayment: splitPaymentData } : {})), { selectedTiers: d.selectedTiers, vehicleCategory: String((_2 = (_1 = d.vehicleCategory) !== null && _1 !== void 0 ? _1 : d.category) !== null && _2 !== void 0 ? _2 : (Array.isArray(d.selectedTiers) && d.selectedTiers.length > 0 ? d.selectedTiers[0] : "car")).toLowerCase(), fareToken: d.fareToken, fareTiers: updatedFareTiers, base_trip_fare: baseFare, baseTripFare: baseFare, baseFare, outstanding_debt: recoveredDebt, outstandingDebt: recoveredDebt, recoveredDebt, total_collectible_fare: totalFare, totalCollectibleFare: totalFare, totalFare, broadcast_fare: baseFare, broadcastFare: baseFare, baselineFare, proposedFare: baseFare, fareAmount: baseFare, broadcastFareFormatted: `₦${baseFare.toLocaleString()}`, fareFormatted: `₦${baseFare.toLocaleString()}`, totalCollectibleFareFormatted: `₦${totalFare.toLocaleString()}`, outstandingBalanceIncluded: recoveredDebt, driverAcceptedFinancialsReleased: false, fareBoosted: false, boostPercent: 0, paymentMethod,
        paymentMode,
        walletCoverageAmount,
        cashToCollect,
        collectAt,
        payerRole,
        escrowLocked,
        senderCashToCollect,
        receiverCashToCollect, paymentBreakdown: {
            base_trip_fare: baseFare,
            baseTripFare: baseFare,
            baseFare,
            outstanding_debt: recoveredDebt,
            outstandingDebt: recoveredDebt,
            recoveredDebt,
            total_collectible_fare: totalFare,
            totalCollectibleFare: totalFare,
            totalFare,
            broadcast_fare: baseFare,
            broadcastFare: baseFare,
            walletCoverageAmount,
            cashToCollect,
            senderCashToCollect,
            receiverCashToCollect,
            collectAt,
            payerRole,
            escrowLocked,
            driverAcceptedFinancialsReleased: false,
        }, senderShareAmount: d.senderShareAmount != null
            ? Number(d.senderShareAmount)
            : (splitPaymentData ? Number(splitPaymentData.senderShare) : null), receiverShareAmount: d.receiverShareAmount != null
            ? Number(d.receiverShareAmount)
            : (splitPaymentData ? Number(splitPaymentData.receiverShare) : null), customTierFares, distanceKm: verified.distanceKm, durationMins: verified.durationMins, declineCount: 0, reassignmentCount: 0, reassignmentHistory: [], idlePromptSent: false, attemptedDriverIds: [], pingDriverId: null, pingExpiresAt: null, driver: null, driverLocation: null, createdAt: admin.firestore.FieldValue.serverTimestamp(), updatedAt: admin.firestore.FieldValue.serverTimestamp() });
    // Atomic transaction: locks available wallet balance into active escrow hold AND mints the trip doc
    await db().runTransaction(async (tx) => {
        let actualCoverage = 0;
        let actualCoverageKobo = 0;
        if (escrowLocked && walletCoverageAmount > 0) {
            const wSnap = await tx.get(custWalletRef);
            const wData = wSnap.exists ? wSnap.data() : {};
            const mainBal = typeof wData.mainWalletBalance === "number"
                ? wData.mainWalletBalance
                : (typeof wData.balance === "number" ? wData.balance / 100 : 0);
            const currentEscrow = typeof wData.escrowBalance === "number" ? wData.escrowBalance : 0;
            const realAvailable = Math.max(0, mainBal - currentEscrow);
            actualCoverage = Math.min(walletCoverageAmount, realAvailable);
            actualCoverageKobo = (0, driverStreak_1.nairaToKobo)(actualCoverage);
            if (actualCoverage > 0) {
                tx.set(custWalletRef, {
                    escrowBalance: admin.firestore.FieldValue.increment(actualCoverage),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                }, { merge: true });
                tx.set(custWalletRef.collection("transactions").doc(`${tripId}_escrow_hold`), {
                    type: "trip_escrow_hold",
                    role: "customer",
                    amountNaira: -actualCoverage,
                    amountKobo: -actualCoverageKobo,
                    amount: -actualCoverageKobo,
                    tripId,
                    currency: "NGN",
                    note: `Locked in escrow for active trip ${tripId}`,
                    createdAt: admin.firestore.FieldValue.serverTimestamp(),
                });
                (0, driverStreak_1.persistFinancialAuditLogInTx)(tx, {
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
        (0, driverStreak_1.persistTripChangeLogInTx)(tx, {
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
async function findNearestDrivers(attempted, serviceType, pickup, count, tuning, radiusKm, vehicleCategory, customerId, selectedTiers) {
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
        // Strict Vehicle Category & Tier Isolation Guard:
        // Drivers MUST have a valid active vehicle category set when online.
        const activeCat = String((_b = (_a = data.activeVehicleCategory) !== null && _a !== void 0 ? _a : data.vehicleCategory) !== null && _b !== void 0 ? _b : "").toLowerCase();
        if (!activeCat) {
            continue;
        }
        const allowedCats = new Set();
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
/**
 * Step 4 Fallback: drop the order into the Public Order Pool (MARKETPLACE_OPEN).
 * Every online driver within the extended pool radius (up to 15 km or Hub-configured
 * pool radius) will see it available to claim from the pool.
 */
async function dropToPublicPool(tripRef) {
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
async function advanceSequentialDispatch(tripRef, data, tuning) {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t, _u, _v, _w, _x, _y, _z, _0, _1, _2, _3, _4, _5, _6, _7;
    const pickup = pickupOf(data);
    const attempted = attemptedIdsOf(data);
    const currentStep = typeof data.dispatchStep === "number" ? data.dispatchStep : attempted.length;
    // If already at or beyond 3 attempted drivers, automatically drop into Public Order Pool
    if (currentStep >= exports.MAX_SEQUENTIAL_DISPATCH_DRIVERS ||
        attempted.length >= exports.MAX_SEQUENTIAL_DISPATCH_DRIVERS) {
        await dropToPublicPool(tripRef);
        return false;
    }
    const nextStep = currentStep + 1;
    const serviceType = String((_a = data.serviceType) !== null && _a !== void 0 ? _a : "ride");
    const vehicleCategory = String((_b = data.vehicleCategory) !== null && _b !== void 0 ? _b : (Array.isArray(data.selectedTiers) && data.selectedTiers.length > 0
        ? data.selectedTiers[0]
        : "")).toLowerCase();
    const customerId = String((_e = (_d = (_c = data.customerId) !== null && _c !== void 0 ? _c : data.userId) !== null && _d !== void 0 ? _d : (data.customer && typeof data.customer === "object" ? data.customer.uid : "")) !== null && _e !== void 0 ? _e : "");
    const selectedTiers = Array.isArray(data.selectedTiers)
        ? data.selectedTiers.map((t) => String(t).toLowerCase())
        : [];
    const nearest = pickup == null
        ? []
        : await findNearestDrivers(attempted, serviceType, pickup, 1, tuning, tuning.tier1RadiusKm, vehicleCategory, customerId, selectedTiers);
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
            from: String((_f = data.status) !== null && _f !== void 0 ? _f : ""),
            to: "WAITING_FOR_ACCEPTANCE",
            actor: "system_dispatch",
            role: "system",
            reason: `sequential_dispatch_step_${nextStep}`,
            driverId: targetDriver.id,
            distanceKm: targetDriver.distanceKm,
            timestamp: nowMs(),
        }),
    });
    // Pre-acceptance scoping: push targeted notification carrying exclusively broadcast_fare
    const broadcastFareAmount = Number((_m = (_l = (_k = (_j = (_h = (_g = data.broadcast_fare) !== null && _g !== void 0 ? _g : data.broadcastFare) !== null && _h !== void 0 ? _h : data.base_trip_fare) !== null && _j !== void 0 ? _j : data.baseTripFare) !== null && _k !== void 0 ? _k : data.baseFare) !== null && _l !== void 0 ? _l : data.fareAmount) !== null && _m !== void 0 ? _m : 0);
    await notifyCustomer(targetDriver.id, tripRef.id, "New Order Request", "You have an exclusive order request! Tap to review and accept.", "trip_offer", {
        tripId: tripRef.id,
        dispatchStep: String(nextStep),
        pickupAddress: String((_q = (_o = data.pickupAddress) !== null && _o !== void 0 ? _o : (_p = data.pickup) === null || _p === void 0 ? void 0 : _p.address) !== null && _q !== void 0 ? _q : ""),
        dropoffAddress: String((_t = (_r = data.dropoffAddress) !== null && _r !== void 0 ? _r : (_s = data.dropoff) === null || _s === void 0 ? void 0 : _s.address) !== null && _t !== void 0 ? _t : ""),
        broadcast_fare: String(broadcastFareAmount),
        fareFormatted: `₦${broadcastFareAmount.toLocaleString()}`,
        fareAmount: String(broadcastFareAmount),
        distanceKm: String((_v = (_u = data.distanceKm) !== null && _u !== void 0 ? _u : targetDriver.distanceKm) !== null && _v !== void 0 ? _v : 0),
        pickupLat: String((_y = (_w = data.pickupLat) !== null && _w !== void 0 ? _w : (_x = data.pickup) === null || _x === void 0 ? void 0 : _x.lat) !== null && _y !== void 0 ? _y : 0),
        pickupLng: String((_1 = (_z = data.pickupLng) !== null && _z !== void 0 ? _z : (_0 = data.pickup) === null || _0 === void 0 ? void 0 : _0.lng) !== null && _1 !== void 0 ? _1 : 0),
        dropoffLat: String((_4 = (_2 = data.dropoffLat) !== null && _2 !== void 0 ? _2 : (_3 = data.dropoff) === null || _3 === void 0 ? void 0 : _3.lat) !== null && _4 !== void 0 ? _4 : 0),
        dropoffLng: String((_7 = (_5 = data.dropoffLng) !== null && _5 !== void 0 ? _5 : (_6 = data.dropoff) === null || _6 === void 0 ? void 0 : _6.lng) !== null && _7 !== void 0 ? _7 : 0),
    }, `driver_${targetDriver.id}`);
    return true;
}
/** Sequential Dispatch entry point on order creation. */
exports.onTripCreated = (0, firestore_1.onDocumentCreated)("trips/{tripId}", async (event) => {
    const snap = event.data;
    if (!snap)
        return;
    const data = snap.data();
    if (data.status !== "SEARCHING_DRIVER")
        return;
    const tuning = await getDispatchTuning();
    await advanceSequentialDispatch(snap.ref, data, tuning);
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
 * Scheduled sweep (every minute): advances timed-out sequential offers (Step 1 -> 2 -> 3 -> Public Pool),
 * expires ignored pings ("skipped_by_driver"), and restarts dispatch for long-waiting searches.
 */
exports.sweepTripPings = (0, scheduler_1.onSchedule)("* * * * *", async () => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s;
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
        if (typeof data.dispatchTier === "number")
            continue; // handled above
        const ignoredDriverId = data.pingDriverId;
        await doc.ref.update(Object.assign(Object.assign({ status: "SEARCHING_DRIVER", pingDriverId: null, pingExpiresAt: null, cancellationSource: "skipped_by_driver", declineCount: admin.firestore.FieldValue.increment(1) }, (ignoredDriverId
            ? {
                attemptedDriverIds: admin.firestore.FieldValue.arrayUnion(ignoredDriverId),
                rejections: admin.firestore.FieldValue.arrayUnion({
                    driverId: ignoredDriverId,
                    action: "skipped",
                    timestamp: cutoff,
                }),
            }
            : {})), { updatedAt: admin.firestore.FieldValue.serverTimestamp() }));
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
            catch (_t) {
                /* best effort */
            }
        }
    }
    // 6. Public Order Pool Expiration & Order Timeout (Hub-Configured Pool Duration)
    // When an order sits in the public pool (MARKETPLACE_OPEN or MARKETPLACE_LIST) beyond
    // the Hub-configured duration limit (default: 60 min), automatically transition to
    // `returned_to_customer` so it clears out of all driver feeds and notifies customer.
    const poolTimeoutMs = tuning.publicPoolDurationMs;
    for (const poolStatus of ["MARKETPLACE_OPEN", "MARKETPLACE_LIST"]) {
        const poolDue = await db()
            .collection("trips")
            .where("status", "==", poolStatus)
            .limit(25)
            .get();
        for (const doc of poolDue.docs) {
            const data = doc.data();
            const droppedAt = (_q = (_m = (_j = (_h = (_g = data.droppedToPoolAt) === null || _g === void 0 ? void 0 : _g.toMillis) === null || _h === void 0 ? void 0 : _h.call(_g)) !== null && _j !== void 0 ? _j : (_l = (_k = data.updatedAt) === null || _k === void 0 ? void 0 : _k.toMillis) === null || _l === void 0 ? void 0 : _l.call(_k)) !== null && _m !== void 0 ? _m : (_p = (_o = data.createdAt) === null || _o === void 0 ? void 0 : _o.toMillis) === null || _p === void 0 ? void 0 : _p.call(_o)) !== null && _q !== void 0 ? _q : 0;
            const poolExpiresAt = typeof data.poolExpiresAt === "number"
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
                const customerId = String((_s = (_r = data.customerId) !== null && _r !== void 0 ? _r : data.userId) !== null && _s !== void 0 ? _s : "");
                if (customerId) {
                    try {
                        await notifyCustomer(customerId, doc.id, "Order Returned", "Please increase the fare to catch nearby drivers' attention.", "trip_returned_to_customer", { tripId: doc.id, status: "returned_to_customer" });
                    }
                    catch (_u) {
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
function isPingTarget(data, driverId) {
    if (data.status !== "WAITING_FOR_ACCEPTANCE")
        return false;
    return data.pingDriverId === driverId;
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
        const hidePhone = await hidePhonesEnabled(driverId);
        const phone = hidePhone ? (rawPhone ? maskPhone(rawPhone) : "") : rawPhone;
        return {
            driverId,
            fullName: String((_e = (_d = d.fullName) !== null && _d !== void 0 ? _d : d.name) !== null && _e !== void 0 ? _e : "Driver"),
            photoUrl: String((_f = d.photoUrl) !== null && _f !== void 0 ? _f : ""),
            rating: Number((_g = d.rating) !== null && _g !== void 0 ? _g : 0),
            phone,
            phoneMasked: hidePhone,
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
 * - Tier 1: caller must be a current ping target.
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
    // ── Security gates ────────────────────────────────────────────────────────
    (0, accountGuard_1.enforceAppCheck)(request);
    // The driver-record suspension check happens inside the transaction below
    // (verification status), but we also gate on the shared user record here
    // so a banned driver with a still-valid driver doc cannot slip through.
    await (0, accountGuard_1.requireAccountActive)(driverId, "driver");
    const snapshot = await driverSnapshot(driverId);
    await db().runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t, _u, _v, _w, _x, _y, _z, _0, _1, _2, _3, _4, _5, _6, _7, _8, _9, _10, _11;
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
        // Idempotent retry: if this driver has already claimed/accepted this trip,
        // succeed safely rather than failing due to duplicate network requests.
        if (data.driverId === driverId || ((_e = data.driver) === null || _e === void 0 ? void 0 : _e.driverId) === driverId) {
            return;
        }
        // Self-assignment guard: drivers cannot accept orders they created as customer
        const orderCustomerId = String((_h = (_g = (_f = data.customerId) !== null && _f !== void 0 ? _f : data.userId) !== null && _g !== void 0 ? _g : (data.customer && typeof data.customer === "object" ? data.customer.uid : "")) !== null && _h !== void 0 ? _h : "");
        if (orderCustomerId && orderCustomerId === driverId) {
            throw new https_1.HttpsError("failed-precondition", "You cannot accept an order you created as a customer.");
        }
        // Zero-trust Active Vehicle Approval & Category Isolation Gate (runs for all trip acceptances)
        const driverDocSnap = await tx.get(db().collection("drivers").doc(driverId));
        if (!driverDocSnap.exists || ((_j = driverDocSnap.data()) === null || _j === void 0 ? void 0 : _j.isOnline) !== true) {
            throw new https_1.HttpsError("failed-precondition", "You are currently offline. Go online to accept trips.");
        }
        const claimer = driverDocSnap.data();
        const claimerStatus = String((_l = (_k = claimer.verificationStatus) !== null && _k !== void 0 ? _k : claimer.status) !== null && _l !== void 0 ? _l : "").toLowerCase();
        const claimerVerified = claimerStatus === "verified" ||
            claimerStatus === "approved" ||
            claimerStatus === "active_verified" ||
            claimer.isVerified === true ||
            claimer.isProfileVerified === true;
        if (!claimerVerified) {
            throw new https_1.HttpsError("permission-denied", "Only active verified drivers can accept trips.");
        }
        const activeVehicleId = String((_m = claimer.activeVehicleId) !== null && _m !== void 0 ? _m : "");
        const activeVehicleCategory = String((_o = claimer.activeVehicleCategory) !== null && _o !== void 0 ? _o : "").toLowerCase();
        const fleetSnap = await tx.get(db()
            .collection("drivers")
            .doc(driverId)
            .collection("vehicles")
            .limit(20));
        let activeDoc = fleetSnap.docs.find((vDoc) => vDoc.id === activeVehicleId);
        if (!activeDoc) {
            activeDoc = fleetSnap.docs.find((vDoc) => { var _a; return ((_a = vDoc.data()) === null || _a === void 0 ? void 0 : _a.isActiveSelected) === true; });
        }
        if (!activeDoc) {
            throw new https_1.HttpsError("failed-precondition", "No active vehicle selected for this session. Go offline and select a verified vehicle.");
        }
        const activeVData = (_p = activeDoc.data()) !== null && _p !== void 0 ? _p : {};
        const vStatus = String((_r = (_q = activeVData.verificationStatus) !== null && _q !== void 0 ? _q : activeVData.status) !== null && _r !== void 0 ? _r : "").toUpperCase();
        const isVehicleApproved = vStatus === "APPROVED" || vStatus === "VERIFIED" || activeVData.isVerified === true;
        if (!isVehicleApproved) {
            throw new https_1.HttpsError("failed-precondition", "Your active vehicle is pending admin approval and cannot accept orders.");
        }
        // Category & Tier Isolation Check
        const reqCat = String((_s = data.vehicleCategory) !== null && _s !== void 0 ? _s : "").toLowerCase();
        const reqTiers = Array.isArray(data.selectedTiers)
            ? data.selectedTiers.map((t) => String(t).toLowerCase())
            : [];
        const allowedCats = new Set();
        if (reqCat)
            allowedCats.add(reqCat);
        for (const t of reqTiers)
            if (t)
                allowedCats.add(t);
        const effectiveDriverCat = activeVehicleCategory || String((_t = activeVData.category) !== null && _t !== void 0 ? _t : "").toLowerCase();
        if (allowedCats.size > 0 && !allowedCats.has(effectiveDriverCat)) {
            throw new https_1.HttpsError("failed-precondition", `Your active vehicle (${effectiveDriverCat}) cannot accept orders for this trip category.`);
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
            // Vehicle checks handled by the zero-trust gate above
        }
        else {
            throw new https_1.HttpsError("failed-precondition", "This trip is no longer available.");
        }
        if ((_u = data.driver) === null || _u === void 0 ? void 0 : _u.driverId) {
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
        // If this claiming driver previously skipped or rejected this order,
        // supersede that preliminary rejection record so the trip state cleanly resolves.
        const existingRejections = Array.isArray(data.rejections) ? data.rejections : [];
        const updatedRejections = existingRejections.map((r) => r && r.driverId === driverId ? Object.assign(Object.assign({}, r), { superseded: true, supersededAt: nowMs() }) : r);
        const isPoolClaim = status === "MARKETPLACE_OPEN" ||
            status === "MARKETPLACE_LIST" ||
            data.isPoolOrder === true ||
            data.droppedToPoolAt != null ||
            data.dispatchStep === 4;
        const baseTripFare = Number((_0 = (_z = (_y = (_x = (_w = (_v = data.base_trip_fare) !== null && _v !== void 0 ? _v : data.baseTripFare) !== null && _w !== void 0 ? _w : data.broadcast_fare) !== null && _x !== void 0 ? _x : data.broadcastFare) !== null && _y !== void 0 ? _y : data.baseFare) !== null && _z !== void 0 ? _z : data.fareAmount) !== null && _0 !== void 0 ? _0 : 0);
        const outstandingDebt = Number((_4 = (_3 = (_2 = (_1 = data.outstanding_debt) !== null && _1 !== void 0 ? _1 : data.outstandingDebt) !== null && _2 !== void 0 ? _2 : data.recoveredDebt) !== null && _3 !== void 0 ? _3 : data.outstandingBalanceIncluded) !== null && _4 !== void 0 ? _4 : 0);
        const totalCollectibleFare = Number((_7 = (_6 = (_5 = data.total_collectible_fare) !== null && _5 !== void 0 ? _5 : data.totalCollectibleFare) !== null && _6 !== void 0 ? _6 : data.totalFare) !== null && _7 !== void 0 ? _7 : (baseTripFare + outstandingDebt));
        const finalCashToCollect = data.paymentMethod === "cash"
            ? totalCollectibleFare
            : Number((_8 = data.cashToCollect) !== null && _8 !== void 0 ? _8 : totalCollectibleFare);
        tx.update(ref, {
            status: "DRIVER_ACCEPTED",
            driver: snapshot,
            driverId: driverId,
            isPoolOrder: isPoolClaim,
            dispatchTier: (_9 = data.dispatchTier) !== null && _9 !== void 0 ? _9 : null,
            cancellationSource: null,
            cancellationReason: null,
            rejections: updatedRejections,
            pingDriverId: null,
            pingDriverIds: [],
            pingExpiresAt: null,
            tierExpiresAt: null,
            hasActiveBids: false,
            biddingCompleted: pendingBids.size > 0 ? true : ((_10 = data.biddingCompleted) !== null && _10 !== void 0 ? _10 : false),
            acceptedBidDriverId: pendingBids.docs.some((b) => b.id === driverId)
                ? driverId
                : ((_11 = data.acceptedBidDriverId) !== null && _11 !== void 0 ? _11 : null),
            // Secure Post-Acceptance Financial Release to Driver UI
            driverAcceptedFinancialsReleased: true,
            driverAcceptedAt: nowMs(),
            base_trip_fare: baseTripFare,
            baseTripFare: baseTripFare,
            outstanding_debt: outstandingDebt,
            outstandingDebt: outstandingDebt,
            total_collectible_fare: totalCollectibleFare,
            totalCollectibleFare: totalCollectibleFare,
            cashToCollect: finalCashToCollect,
            fareFormatted: `₦${totalCollectibleFare.toLocaleString()}`,
            paymentBreakdown: Object.assign(Object.assign({}, (typeof data.paymentBreakdown === "object" ? data.paymentBreakdown : {})), { base_trip_fare: baseTripFare, baseTripFare: baseTripFare, outstanding_debt: outstandingDebt, outstandingDebt: outstandingDebt, total_collectible_fare: totalCollectibleFare, totalCollectibleFare: totalCollectibleFare, cashToCollect: finalCashToCollect, driverAcceptedFinancialsReleased: true }),
            statusHistory: admin.firestore.FieldValue.arrayUnion({
                from: status,
                to: "DRIVER_ACCEPTED",
                actor: driverId,
                role: "driver",
                timestamp: nowMs(),
            }),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        // Authoritative active session state update for driver in the database
        tx.set(db().collection("driver_status").doc(driverId), {
            activeTripId: tripId,
            activeTripStatus: "DRIVER_ACCEPTED",
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        (0, driverStreak_1.persistTripChangeLogInTx)(tx, {
            tripId,
            from: status,
            to: "DRIVER_ACCEPTED",
            actor: driverId,
            role: "driver",
            timestamp: nowMs(),
        });
    });
    (0, driverStreak_1.logTripTransition)({
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
exports.declineTrip = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in.");
    }
    const driverId = request.auth.uid;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "");
    if (!tripId)
        throw new https_1.HttpsError("invalid-argument", "tripId is required.");
    // ── Security gates ────────────────────────────────────────────────────────
    (0, accountGuard_1.enforceAppCheck)(request);
    await (0, accountGuard_1.requireAccountActive)(driverId, "driver");
    const tripRef = db().collection("trips").doc(tripId);
    const tuning = await getDispatchTuning();
    const rawAction = String((_f = (_d = (_c = request.data) === null || _c === void 0 ? void 0 : _c.action) !== null && _d !== void 0 ? _d : (_e = request.data) === null || _e === void 0 ? void 0 : _e.reason) !== null && _f !== void 0 ? _f : "").toLowerCase();
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
        var _a;
        const snap = await tx.get(tripRef);
        if (!snap.exists) {
            throw new https_1.HttpsError("not-found", "Trip not found.");
        }
        const data = snap.data();
        fromStatus = String((_a = data.status) !== null && _a !== void 0 ? _a : "");
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
        (0, driverStreak_1.persistTripChangeLogInTx)(tx, {
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
        await (0, driverStreak_1.breakDriverStreak)(driverId, "driver_declined");
    }
    catch (e) {
        console.warn(`declineTrip: streak break failed for ${driverId}: ${e}`);
    }
    // Advance to next sequential driver (Step 2 / Step 3) or escalate to Public Order Pool (Step 4).
    if (shouldRedispatch) {
        const fresh = await tripRef.get();
        if (fresh.exists && fresh.data().status === "SEARCHING_DRIVER") {
            await advanceSequentialDispatch(tripRef, fresh.data(), tuning);
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
    // Mirror the fix onto the driver doc so Tier 1 nearest-driver ranking
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
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in.");
    }
    // ── Security gates ────────────────────────────────────────────────────────
    (0, accountGuard_1.enforceAppCheck)(request);
    await (0, accountGuard_1.requireAccountActive)(request.auth.uid, "driver");
    const { tripId, status, expectedStatus } = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    if (!tripId || typeof status !== "string") {
        throw new https_1.HttpsError("invalid-argument", "tripId + status required.");
    }
    const ref = db().collection("trips").doc(String(tripId));
    let alreadyInStatus = false;
    let fromStatus = "";
    let snapAfterData = null;
    const dropoffRadiusMeters = await getDropoffRadiusMeters();
    await db().runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t, _u, _v, _w, _x, _y, _z, _0, _1, _2, _3, _4, _5, _6, _7, _8, _9, _10, _11;
        const snap = await tx.get(ref);
        if (!snap.exists)
            throw new https_1.HttpsError("not-found", "Trip not found.");
        const data = snap.data();
        const driverId = String((_c = (_b = (_a = data.driver) === null || _a === void 0 ? void 0 : _a.driverId) !== null && _b !== void 0 ? _b : data.driverId) !== null && _c !== void 0 ? _c : "");
        if (driverId !== request.auth.uid) {
            throw new https_1.HttpsError("permission-denied", "Not your trip.");
        }
        const currentStatus = String(data.status);
        fromStatus = currentStatus;
        // Stale write rejection: if client passed expectedStatus, verify it matches current
        if (expectedStatus && typeof expectedStatus === "string" && currentStatus !== expectedStatus) {
            throw new https_1.HttpsError("failed-precondition", `STALE_WRITE: Trip status is ${currentStatus}, expected ${expectedStatus}.`);
        }
        // Terminal/settlement guard: cannot advance an already completed or settled trip
        if (((_d = data.settlement) === null || _d === void 0 ? void 0 : _d.settled) === true && status !== "COMPLETED") {
            throw new https_1.HttpsError("failed-precondition", "This trip has already been completed and settled.");
        }
        if (currentStatus === String(status)) {
            alreadyInStatus = true;
            snapAfterData = data;
            return;
        }
        const allowed = (_e = DRIVER_TRANSITIONS[currentStatus]) !== null && _e !== void 0 ? _e : [];
        if (!allowed.includes(String(status))) {
            throw new https_1.HttpsError("failed-precondition", `Cannot move from ${currentStatus} to ${status}.`);
        }
        // ── Drop-off Geofencing Check ───────────────────────────────────────────
        if (status === "COMPLETED" && data.dropoffApprovalStatus !== "APPROVED") {
            const dropoffLat = Number((_k = (_j = (_g = (_f = data.dropoff) === null || _f === void 0 ? void 0 : _f.lat) !== null && _g !== void 0 ? _g : (_h = data.dropoffLocation) === null || _h === void 0 ? void 0 : _h.latitude) !== null && _j !== void 0 ? _j : data.dropoffLat) !== null && _k !== void 0 ? _k : 0);
            const dropoffLng = Number((_q = (_p = (_m = (_l = data.dropoff) === null || _l === void 0 ? void 0 : _l.lng) !== null && _m !== void 0 ? _m : (_o = data.dropoffLocation) === null || _o === void 0 ? void 0 : _o.longitude) !== null && _p !== void 0 ? _p : data.dropoffLng) !== null && _q !== void 0 ? _q : 0);
            if (dropoffLat !== 0 && dropoffLng !== 0) {
                const driverLat = Number((_0 = (_y = (_w = (_u = (_s = (_r = request.data) === null || _r === void 0 ? void 0 : _r.driverLat) !== null && _s !== void 0 ? _s : (_t = request.data) === null || _t === void 0 ? void 0 : _t.lat) !== null && _u !== void 0 ? _u : (_v = request.data) === null || _v === void 0 ? void 0 : _v.latitude) !== null && _w !== void 0 ? _w : (_x = data.driverLocation) === null || _x === void 0 ? void 0 : _x.lat) !== null && _y !== void 0 ? _y : (_z = data.driverLocation) === null || _z === void 0 ? void 0 : _z.latitude) !== null && _0 !== void 0 ? _0 : 0);
                const driverLng = Number((_10 = (_8 = (_6 = (_4 = (_2 = (_1 = request.data) === null || _1 === void 0 ? void 0 : _1.driverLng) !== null && _2 !== void 0 ? _2 : (_3 = request.data) === null || _3 === void 0 ? void 0 : _3.lng) !== null && _4 !== void 0 ? _4 : (_5 = request.data) === null || _5 === void 0 ? void 0 : _5.longitude) !== null && _6 !== void 0 ? _6 : (_7 = data.driverLocation) === null || _7 === void 0 ? void 0 : _7.lng) !== null && _8 !== void 0 ? _8 : (_9 = data.driverLocation) === null || _9 === void 0 ? void 0 : _9.longitude) !== null && _10 !== void 0 ? _10 : 0);
                if (driverLat !== 0 && driverLng !== 0) {
                    const distM = Math.round(haversineKm(driverLat, driverLng, dropoffLat, dropoffLng) * 1000);
                    if (distM > dropoffRadiusMeters) {
                        throw new https_1.HttpsError("failed-precondition", `OUT_OF_RANGE: Driver is outside drop-off location (${distM}m away, max allowed is ${dropoffRadiusMeters}m). Customer confirmation required.`);
                    }
                }
            }
        }
        const update = {
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
        }
        else if (status === "IN_PROGRESS" && !data.startedAt) {
            update["startedAt"] = admin.firestore.FieldValue.serverTimestamp();
        }
        else if (status === "COMPLETED") {
            update["completedAt"] = admin.firestore.FieldValue.serverTimestamp();
            update["cancellationSource"] = null;
            update["cancellationReason"] = null;
            const rejectionsList = Array.isArray(data.rejections) ? data.rejections : [];
            if (rejectionsList.some((r) => (r === null || r === void 0 ? void 0 : r.driverId) === driverId && !(r === null || r === void 0 ? void 0 : r.superseded))) {
                update["rejections"] = rejectionsList.map((r) => r && r.driverId === driverId ? Object.assign(Object.assign({}, r), { superseded: true, supersededAt: nowMs() }) : r);
            }
        }
        if (((_11 = request.data) === null || _11 === void 0 ? void 0 : _11.recordDropoffArrival) === true && !data.dropoffArrivedAt) {
            update["dropoffArrivedAt"] = admin.firestore.FieldValue.serverTimestamp();
        }
        tx.update(ref, update);
        snapAfterData = Object.assign(Object.assign({}, data), update);
        (0, driverStreak_1.persistTripChangeLogInTx)(tx, {
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
    (0, driverStreak_1.logTripTransition)({
        tripId: String(tripId),
        from: fromStatus || "UNKNOWN",
        to: String(status),
        actor: String(request.auth.uid),
        role: "driver",
        timestamp: nowMs(),
    });
    // Synchronous trip completion settlement: immediately post commission debit,
    // update wallet balance and trip settlement metadata with zero delay.
    if (status === "COMPLETED" && snapAfterData) {
        try {
            await (0, driverStreak_1.handleTripCompletion)(String(tripId), snapAfterData);
        }
        catch (e) {
            console.warn(`advanceTripStatus[${tripId}]: synchronous settlement warning: ${e}`);
        }
    }
    else if (status === "DRIVER_ARRIVED" && snapAfterData) {
        const tripObj = snapAfterData;
        const customerId = String((_b = tripObj.customerId) !== null && _b !== void 0 ? _b : "");
        const driverName = String((_d = (_c = tripObj.driver) === null || _c === void 0 ? void 0 : _c.fullName) !== null && _d !== void 0 ? _d : "Your driver");
        await notifyCustomer(customerId, String(tripId), "Driver arrived", `${driverName} has arrived at the pickup point.`, "driver_arrived");
    }
    else if (status === "IN_PROGRESS" && snapAfterData) {
        const liveTrip = snapAfterData;
        const paymentMethod = String((_e = liveTrip["paymentMethod"]) !== null && _e !== void 0 ? _e : "cash").toLowerCase();
        const customerId = String((_f = liveTrip["customerId"]) !== null && _f !== void 0 ? _f : "");
        const driverId = String((_j = (_h = (_g = liveTrip["driver"]) === null || _g === void 0 ? void 0 : _g["driverId"]) !== null && _h !== void 0 ? _h : liveTrip["driverId"]) !== null && _j !== void 0 ? _j : request.auth.uid);
        const cashToCollect = Number((_k = liveTrip["cashToCollect"]) !== null && _k !== void 0 ? _k : 0);
        if ((paymentMethod === "card" || paymentMethod === "paystack" || paymentMethod === "wallet") &&
            cashToCollect > 0 &&
            !liveTrip["paidViaCard"]) {
            try {
                const chargeResult = await (0, payments_1.chargePaystackCardAuthorization)({
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
                    await notifyDriver(driverId, String(tripId), "Card Payment Successful", `Card payment of ₦${cashToCollect.toLocaleString()} was processed successfully. DO NOT collect cash from customer.`, "card_payment_success");
                }
                else {
                    await db().collection("trips").doc(String(tripId)).update({
                        paymentMethod: "cash",
                        paymentStatus: "cash_fallback",
                        cardPaymentFailed: true,
                        cardPaymentFailureReason: (_l = chargeResult.failureReason) !== null && _l !== void 0 ? _l : "Card charge failed",
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    });
                    await notifyDriver(driverId, String(tripId), "Card Payment Failed - Collect Cash", `Card payment failed (${(_m = chargeResult.failureReason) !== null && _m !== void 0 ? _m : "failed"}). Collect full cash amount (₦${cashToCollect.toLocaleString()}) from customer upon trip completion.`, "card_payment_failed");
                }
            }
            catch (e) {
                console.warn(`advanceTripStatus[${tripId}]: automated card charge error: ${e}`);
                await db().collection("trips").doc(String(tripId)).update({
                    paymentMethod: "cash",
                    paymentStatus: "cash_fallback",
                    cardPaymentFailed: true,
                    cardPaymentFailureReason: String(e),
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                });
                await notifyDriver(driverId, String(tripId), "Card Payment Failed - Collect Cash", `Card payment failed. Collect full cash amount (₦${cashToCollect.toLocaleString()}) from customer upon trip completion.`, "card_payment_failed");
            }
        }
    }
    return { ok: true };
});
// ── Customer actions ───────────────────────────────────────────────────────
/** Release active trip wallet escrow hold back to customer's available balance upon cancellation */
async function releaseTripEscrow(tripId, tripData, passedTx) {
    var _a, _b, _c, _d;
    const walletCoverage = Number((_c = (_a = tripData["walletCoverageAmount"]) !== null && _a !== void 0 ? _a : (_b = tripData["paymentBreakdown"]) === null || _b === void 0 ? void 0 : _b["walletCoverageAmount"]) !== null && _c !== void 0 ? _c : 0);
    if (walletCoverage <= 0 || tripData["escrowRefundedAt"] || tripData["escrowLocked"] === false) {
        return;
    }
    const customerId = String((_d = tripData["customerId"]) !== null && _d !== void 0 ? _d : "");
    if (!customerId)
        return;
    const coverageKobo = (0, driverStreak_1.nairaToKobo)(walletCoverage);
    const custWalletRef = db().collection("wallets").doc(customerId);
    const refundTxRef = custWalletRef.collection("transactions").doc(`${tripId}_escrow_refund`);
    const tripRef = db().collection("trips").doc(tripId);
    const applyRefund = (tx, currentEscrow) => {
        const newEscrow = currentEscrow != null ? Math.max(0, currentEscrow - walletCoverage) : undefined;
        tx.set(custWalletRef, Object.assign(Object.assign({}, (newEscrow != null
            ? { escrowBalance: newEscrow }
            : { escrowBalance: admin.firestore.FieldValue.increment(-walletCoverage) })), { updatedAt: admin.firestore.FieldValue.serverTimestamp() }), { merge: true });
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
        (0, driverStreak_1.logFinancialMutation)({
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
    }
    else {
        await db().runTransaction(async (tx) => {
            var _a, _b;
            const snap = await tx.get(tripRef);
            if (!snap.exists)
                return;
            const t = snap.data();
            if (t["escrowRefundedAt"] || t["escrowLocked"] === false)
                return;
            const wSnap = await tx.get(custWalletRef);
            const currentEscrow = wSnap.exists ? Number((_b = (_a = wSnap.data()) === null || _a === void 0 ? void 0 : _a.escrowBalance) !== null && _b !== void 0 ? _b : walletCoverage) : walletCoverage;
            applyRefund(tx, currentEscrow);
        });
    }
}
/** Customer or driver cancels a live trip — sets cancellationSource for streak logic. */
exports.cancelTrip = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t, _u, _v, _w, _x, _y, _z, _0;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    }
    // ── Security gates ────────────────────────────────────────────────────────
    // Cancelation can have financial consequences (waiting-fee settlement),
    // so App Check + suspension gate apply.
    (0, accountGuard_1.enforceAppCheck)(request);
    await (0, accountGuard_1.requireAccountActive)(request.auth.uid);
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
    const isDriver = ((_c = data.driver) === null || _c === void 0 ? void 0 : _c.driverId) === callerId || data.driverId === callerId;
    if (!isCustomer && !isDriver) {
        throw new https_1.HttpsError("permission-denied", "Not your trip.");
    }
    const CANCELLABLE_STATUSES = new Set([
        ...LIVE_STATUSES,
        "returned_to_customer",
        "expired",
        "needs_customer_action",
    ]);
    if (!CANCELLABLE_STATUSES.has(data.status)) {
        if (data.status === "CANCELLED" ||
            data.status === "CANCELLED_BY_CUSTOMER" ||
            data.status === "CANCELLED_BY_DRIVER" ||
            data.status === "CANCELLED_WAITING_CASH_SETTLEMENT") {
            return { ok: true, alreadyCancelled: true };
        }
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
        let paidWaitingFee = 0;
        const isArrivedOrProgress = data.status === "DRIVER_ARRIVED" || data.status === "IN_PROGRESS";
        const arrivedAtMs = (data.status === "IN_PROGRESS" && ((_h = (_g = data.dropoffArrivedAt) === null || _g === void 0 ? void 0 : _g.toMillis) === null || _h === void 0 ? void 0 : _h.call(_g)))
            ? data.dropoffArrivedAt.toMillis()
            : ((_l = (_k = (_j = data.arrivedAt) === null || _j === void 0 ? void 0 : _j.toMillis) === null || _k === void 0 ? void 0 : _k.call(_j)) !== null && _l !== void 0 ? _l : 0);
        const enableWaitingBilling = data.enableWaitingTimeBilling !== false;
        if (isArrivedOrProgress && arrivedAtMs > 0 && enableWaitingBilling) {
            const elapsedMs = nowMs() - arrivedAtMs;
            const freeWaitMs = 10 * 60 * 1000; // 10 minutes free countdown
            if (elapsedMs > freeWaitMs) {
                const paidWaitMins = Math.ceil((elapsedMs - freeWaitMs) / (60 * 1000));
                const timeRatePerMin = Number((_m = data.timeRatePerMinute) !== null && _m !== void 0 ? _m : 20);
                paidWaitingFee = Math.max(0, paidWaitMins * timeRatePerMin);
            }
        }
        const useCashSettlement = ((_o = request.data) === null || _o === void 0 ? void 0 : _o.useCashSettlement) === true;
        const result = await (0, driverStreak_1.handleTripCancellationSettlement)({
            tripId,
            cancelledBy: "customer",
            actorId: callerId,
            role: "customer",
            reason,
            paidWaitingFee,
            useCashSettlement,
        });
        if (result.cashSettlementPending) {
            const assignedDriverId = String((_r = (_q = (_p = data.driver) === null || _p === void 0 ? void 0 : _p.driverId) !== null && _q !== void 0 ? _q : data.driverId) !== null && _r !== void 0 ? _r : "");
            if (assignedDriverId) {
                await notifyCustomer(assignedDriverId, tripId, "Cash Settlement Requested", `Customer cancelled during paid waiting. Collect ₦${paidWaitingFee} cash from customer and tap "Accept Cash & Cancel".`, "cash_settlement_requested", {}, `driver_${assignedDriverId}`);
            }
            return { ok: true, cancelledBy: "customer", cashSettlement: true, fee: paidWaitingFee };
        }
        return { ok: true, cancelledBy: "customer", paidWaitingFee: result.paidWaitingFee };
    }
    // Driver cancellation logic
    let cancellationSource = "unknown";
    if (data.status === "DRIVER_ARRIVED") {
        const arrivedAt = (_u = (_t = (_s = data.arrivedAt) === null || _s === void 0 ? void 0 : _s.toMillis) === null || _t === void 0 ? void 0 : _t.call(_s)) !== null && _u !== void 0 ? _u : 0;
        const waitedMs = nowMs() - arrivedAt;
        const noShowWaitMs = ((_v = data["noShowWaitMinutes"]) !== null && _v !== void 0 ? _v : 10) * 60 * 1000;
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
        const currentCount = Number((_w = data.reassignmentCount) !== null && _w !== void 0 ? _w : 0);
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
                    from: String((_x = data.status) !== null && _x !== void 0 ? _x : ""),
                    to: "SEARCHING_DRIVER",
                    actor: callerId,
                    role: "driver",
                    reason,
                    attempt: nextCount,
                    timestamp: nowMs(),
                }),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            (0, driverStreak_1.logTripTransition)({
                tripId,
                from: String((_y = data.status) !== null && _y !== void 0 ? _y : ""),
                to: "SEARCHING_DRIVER",
                actor: callerId,
                role: "driver",
                reason: `driver_cancelled_reassigning_attempt_${nextCount}`,
                timestamp: nowMs(),
            });
            // Chain next nearest dispatch
            const freshSnap = await ref.get();
            if (freshSnap.exists) {
                await advanceSequentialDispatch(ref, freshSnap.data(), await getDispatchTuning());
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
                statusHistory: admin.firestore.FieldValue.arrayUnion({
                    from: String((_z = data.status) !== null && _z !== void 0 ? _z : ""),
                    to: "needs_customer_action",
                    actor: callerId,
                    role: "driver",
                    reason: "max_reassignments_reached",
                    attempt: nextCount,
                    timestamp: nowMs(),
                }),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            (0, driverStreak_1.logTripTransition)({
                tripId,
                from: String((_0 = data.status) !== null && _0 !== void 0 ? _0 : ""),
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
            }
            catch (_1) {
                /* best-effort */
            }
            return { ok: true, needsCustomerAction: true };
        }
    }
    // Fallback cancellation (e.g. driver no-show after waiting)
    await (0, driverStreak_1.handleTripCancellationSettlement)({
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
exports.submitBid = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t, _u, _v, _w, _x, _y, _z, _0, _1, _2, _3, _4, _5, _6;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in to bid.");
    }
    const driverId = request.auth.uid;
    // ── Security gates ────────────────────────────────────────────────────────
    (0, accountGuard_1.enforceAppCheck)(request);
    await (0, accountGuard_1.requireAccountActive)(driverId, "driver");
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
    // Active Vehicle Approval & Category Isolation Guard
    const activeVehicleId = String((_d = driverData.activeVehicleId) !== null && _d !== void 0 ? _d : "");
    const activeVehicleCategory = String((_e = driverData.activeVehicleCategory) !== null && _e !== void 0 ? _e : "").toLowerCase();
    const fleetSnap = await db()
        .collection("drivers")
        .doc(driverId)
        .collection("vehicles")
        .limit(20)
        .get();
    let activeDoc = fleetSnap.docs.find((vDoc) => vDoc.id === activeVehicleId);
    if (!activeDoc) {
        activeDoc = fleetSnap.docs.find((vDoc) => { var _a; return ((_a = vDoc.data()) === null || _a === void 0 ? void 0 : _a.isActiveSelected) === true; });
    }
    if (!activeDoc) {
        throw new https_1.HttpsError("failed-precondition", "No active vehicle selected for this session. Go offline and select a verified vehicle.");
    }
    const activeVData = (_f = activeDoc.data()) !== null && _f !== void 0 ? _f : {};
    const vStatus = String((_h = (_g = activeVData.verificationStatus) !== null && _g !== void 0 ? _g : activeVData.status) !== null && _h !== void 0 ? _h : "").toUpperCase();
    const isVehicleApproved = vStatus === "APPROVED" || vStatus === "VERIFIED" || activeVData.isVerified === true;
    if (!isVehicleApproved) {
        throw new https_1.HttpsError("failed-precondition", "Your active vehicle is pending admin approval and cannot submit bids.");
    }
    // Low balance guard: Drivers with balance below minWalletBalanceToOnline (< 1.00) cannot submit bids.
    const walletDoc = await db().collection("wallets").doc(driverId).get();
    const wData = walletDoc.exists ? ((_j = walletDoc.data()) !== null && _j !== void 0 ? _j : {}) : {};
    const mainBal = typeof wData.mainWalletBalance === "number"
        ? wData.mainWalletBalance
        : ((typeof wData.balance === "number" ? wData.balance : 0) / 100);
    const minBalance = await getMinWalletBalanceToOnline();
    if (mainBal < minBalance) {
        throw new https_1.HttpsError("failed-precondition", "Your balance is low. Please top up to accept trips.");
    }
    // Category & Tier Isolation Check
    const reqCat = String((_k = tripData.vehicleCategory) !== null && _k !== void 0 ? _k : "").toLowerCase();
    const reqTiers = Array.isArray(tripData.selectedTiers)
        ? tripData.selectedTiers.map((t) => String(t).toLowerCase())
        : [];
    const allowedCats = new Set();
    if (reqCat)
        allowedCats.add(reqCat);
    for (const t of reqTiers)
        if (t)
            allowedCats.add(t);
    const effectiveDriverCat = activeVehicleCategory || String((_l = activeVData.category) !== null && _l !== void 0 ? _l : "").toLowerCase();
    if (allowedCats.size > 0 && !allowedCats.has(effectiveDriverCat)) {
        throw new https_1.HttpsError("failed-precondition", `Your active vehicle (${effectiveDriverCat}) cannot bid on orders for this trip category.`);
    }
    // Self-assignment guard: drivers cannot bid on orders they created as customer
    const orderCustomerId = String((_p = (_o = (_m = tripData.customerId) !== null && _m !== void 0 ? _m : tripData.userId) !== null && _o !== void 0 ? _o : (tripData.customer && typeof tripData.customer === "object" ? tripData.customer.uid : "")) !== null && _p !== void 0 ? _p : "");
    if (orderCustomerId && orderCustomerId === driverId) {
        throw new https_1.HttpsError("failed-precondition", "You cannot bid on an order you created as a customer.");
    }
    // 2. Validate offered fare against baseline, rounded to nearest 100
    const baseline = Number((_r = (_q = tripData.baselineFare) !== null && _q !== void 0 ? _q : tripData.fareAmount) !== null && _r !== void 0 ? _r : 0);
    const roundedOfferedFare = (0, pricing_1.roundToNearest100)(offeredFare, baseline);
    if (baseline > 0 && roundedOfferedFare < baseline) {
        throw new https_1.HttpsError("invalid-argument", `Offered fare (₦${roundedOfferedFare}) cannot be lower than the baseline fare (₦${baseline}).`);
    }
    if ((_s = tripData.driver) === null || _s === void 0 ? void 0 : _s.driverId) {
        throw new https_1.HttpsError("failed-precondition", "This trip has already been claimed by another driver.");
    }
    const currentStatus = String((_t = tripData.status) !== null && _t !== void 0 ? _t : "").trim().toUpperCase();
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
        throw new https_1.HttpsError("failed-precondition", `This trip is no longer open for bidding (status: ${tripData.status}).`);
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
            const expMs = (_w = (_v = (_u = bData.expiresAt) === null || _u === void 0 ? void 0 : _u.toMillis) === null || _v === void 0 ? void 0 : _v.call(_u)) !== null && _w !== void 0 ? _w : 0;
            if (expMs > currentTime) {
                throw new https_1.HttpsError("failed-precondition", "You already have an active bid waiting for a customer decision.");
            }
        }
    }
    catch (err) {
        if (err instanceof https_1.HttpsError)
            throw err;
        console.warn(`[submitBid] collectionGroup bids query failed (${err === null || err === void 0 ? void 0 : err.message}) — falling back to per-trip check.`);
        try {
            const existingTripBid = await tripRef.collection("bids").doc(driverId).get();
            if (existingTripBid.exists) {
                const bData = existingTripBid.data();
                const expMs = (_z = (_y = (_x = bData === null || bData === void 0 ? void 0 : bData.expiresAt) === null || _x === void 0 ? void 0 : _x.toMillis) === null || _y === void 0 ? void 0 : _y.call(_x)) !== null && _z !== void 0 ? _z : 0;
                if ((bData === null || bData === void 0 ? void 0 : bData.status) === "pending" && expMs > currentTime) {
                    throw new https_1.HttpsError("failed-precondition", "You already have an active bid waiting for a customer decision.");
                }
            }
        }
        catch (fbErr) {
            if (fbErr instanceof https_1.HttpsError)
                throw fbErr;
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
        customerId: String((_0 = tripData.customerId) !== null && _0 !== void 0 ? _0 : ""),
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
    const isMarketplace = currentStatus === "MARKETPLACE_OPEN" ||
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
    await notifyCustomer(String((_1 = tripData.customerId) !== null && _1 !== void 0 ? _1 : ""), String(tripId), "New Driver Offer", `${snapshot.fullName} offered ₦${Number(roundedOfferedFare).toLocaleString()} (~${etaMinutes !== null && etaMinutes !== void 0 ? etaMinutes : 5} mins away)`, "driver_counter_bid", {
        driverId,
        driverName: String(snapshot.fullName),
        driverPhoto: String((_2 = snapshot.photoUrl) !== null && _2 !== void 0 ? _2 : ""),
        driverRating: String((_3 = snapshot.rating) !== null && _3 !== void 0 ? _3 : 0),
        offeredFare: String(roundedOfferedFare),
        offeredFareFormatted: `₦${Number(roundedOfferedFare).toLocaleString()}`,
        etaMinutes: String(etaMinutes !== null && etaMinutes !== void 0 ? etaMinutes : 5),
        vehicleModel: String((_4 = snapshot.vehicleModel) !== null && _4 !== void 0 ? _4 : ""),
        vehicleColor: String((_5 = snapshot.vehicleColor) !== null && _5 !== void 0 ? _5 : ""),
        plateNumber: String((_6 = snapshot.plateNumber) !== null && _6 !== void 0 ? _6 : ""),
        vehicleDetails: vehicleStr,
    });
    return { ok: true, bidId: driverId };
});
/** Customer rejects a driver's bid (driver may re-bid later) */
exports.rejectBid = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d;
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
    const tripData = tripSnap.data();
    const orderCustomerId = String((_d = (_c = (_b = tripData.customerId) !== null && _b !== void 0 ? _b : tripData.userId) !== null && _c !== void 0 ? _c : (tripData.customer && typeof tripData.customer === "object"
        ? tripData.customer.uid
        : "")) !== null && _d !== void 0 ? _d : "");
    if (orderCustomerId !== customerId) {
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
        var _a, _b, _c, _d, _e, _f, _g, _h;
        const tripSnap = await tx.get(tripRef);
        if (!tripSnap.exists) {
            throw new https_1.HttpsError("not-found", "Trip not found.");
        }
        const tripData = tripSnap.data();
        const orderCustomerId = String((_c = (_b = (_a = tripData.customerId) !== null && _a !== void 0 ? _a : tripData.userId) !== null && _b !== void 0 ? _b : (tripData.customer && typeof tripData.customer === "object"
            ? tripData.customer.uid
            : "")) !== null && _c !== void 0 ? _c : "");
        if (orderCustomerId !== customerId) {
            throw new https_1.HttpsError("permission-denied", "Only the requesting customer can accept bids.");
        }
        if (String(driverId) === customerId || String(driverId) === orderCustomerId) {
            throw new https_1.HttpsError("failed-precondition", "Customer cannot accept their own driver bid.");
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
            throw new https_1.HttpsError("failed-precondition", `This trip is no longer open for bidding (current status: ${tripData.status}).`);
        }
        if (((_d = tripData.driver) === null || _d === void 0 ? void 0 : _d.driverId) || tripData.driverId) {
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
        // ── Server-side expiry enforcement ───────────────────────────────────────
        // Block any Accept that arrives after the bid timer has elapsed, even by a
        // fraction of a second. The server timestamp is the authoritative clock.
        if (bidData.expiresAt) {
            const expiresAtMs = typeof bidData.expiresAt.toMillis === "function"
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
                throw new https_1.HttpsError("deadline-exceeded", "This offer has expired. The driver will need to re-submit a bid.");
            }
        }
        // Perform all queries/reads BEFORE any writes to satisfy Firestore transaction requirements
        const otherBids = await tx.get(tripRef.collection("bids").where("status", "==", "pending"));
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
        // Calculate cashToCollect based on the newly accepted offered fare and existing wallet escrow hold
        const walletCoverage = Number((_e = tripData.walletCoverageAmount) !== null && _e !== void 0 ? _e : 0);
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
        const updatedBidRejections = existingBidRejections.map((r) => r && r.driverId === driverId ? Object.assign(Object.assign({}, r), { superseded: true, supersededAt: nowMs() }) : r);
        const isPoolBid = tripData.status === "MARKETPLACE_OPEN" ||
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
                ? Math.max(0, Number((_f = tripData.senderShareAmount) !== null && _f !== void 0 ? _f : (updatedOfferedFare / 2)) - walletCoverage)
                : newCashToCollect,
            biddingCompleted: true,
            hasActiveBids: false,
            acceptedBidDriverId: driverId,
            pingDriverId: null,
            pingDriverIds: [],
            pingExpiresAt: null,
            tierExpiresAt: null,
            statusHistory: admin.firestore.FieldValue.arrayUnion({
                from: (_g = tripData.status) !== null && _g !== void 0 ? _g : "MARKETPLACE_OPEN",
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
        (0, driverStreak_1.persistTripChangeLogInTx)(tx, {
            tripId: String(tripId),
            from: String((_h = tripData.status) !== null && _h !== void 0 ? _h : "MARKETPLACE_OPEN"),
            to: "DRIVER_ACCEPTED",
            actor: customerId,
            role: "customer",
            reason: "accepted_driver_bid",
            timestamp: nowMs(),
        });
    });
    (0, driverStreak_1.logTripTransition)({
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
exports.increaseTripFare = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j;
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
    const tuning = await getDispatchTuning();
    const maxOfferBoostPct = Number((_d = tuning.maxOfferBoostPct) !== null && _d !== void 0 ? _d : 100);
    const originalBase = Number(tripData.baselineFare && Number(tripData.baselineFare) > 0
        ? tripData.baselineFare
        : ((_e = tripData.fareAmount) !== null && _e !== void 0 ? _e : 0));
    const maxAllowedFare = Math.round(originalBase * (1 + maxOfferBoostPct / 100));
    if (roundedNewFare > maxAllowedFare) {
        throw new https_1.HttpsError("failed-precondition", `Offer boost cannot exceed ${maxOfferBoostPct}% above original base fare (max ₦${maxAllowedFare.toLocaleString()}).`);
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
    const debt = Number((_h = (_g = (_f = tripData.outstanding_debt) !== null && _f !== void 0 ? _f : tripData.outstandingDebt) !== null && _g !== void 0 ? _g : tripData.recoveredDebt) !== null && _h !== void 0 ? _h : 0);
    const newTotalCollectible = roundedNewFare + debt;
    const updatePayload = {
        fareAmount: roundedNewFare,
        proposedFare: roundedNewFare,
        base_trip_fare: roundedNewFare,
        baseTripFare: roundedNewFare,
        baseFare: roundedNewFare,
        broadcast_fare: roundedNewFare,
        broadcastFare: roundedNewFare,
        broadcastFareFormatted: `₦${roundedNewFare.toLocaleString()}`,
        fareFormatted: `₦${roundedNewFare.toLocaleString()}`,
        total_collectible_fare: newTotalCollectible,
        totalCollectibleFare: newTotalCollectible,
        totalFare: newTotalCollectible,
        totalCollectibleFareFormatted: `₦${newTotalCollectible.toLocaleString()}`,
        outstanding_debt: debt,
        outstandingDebt: debt,
        recoveredDebt: debt,
        fareBoosted: true,
        boostPercent: boostPct,
        boostedAt: admin.firestore.FieldValue.serverTimestamp(),
        status: wasNeedsAction ? "SEARCHING_DRIVER" : tripData.status,
        reassignmentCount: wasNeedsAction ? 0 : ((_j = tripData.reassignmentCount) !== null && _j !== void 0 ? _j : 0),
        statusMessage: "Price increased! Searching for nearby drivers...",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (updatedFareTiers.length > 0) {
        updatePayload.fareTiers = updatedFareTiers;
    }
    await tripRef.update(updatePayload);
    if (wasNeedsAction) {
        const fresh = (await tripRef.get()).data();
        await advanceSequentialDispatch(tripRef, fresh, await getDispatchTuning());
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
async function handleReassignTrip(request) {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l;
    const customerId = (_a = request.auth) === null || _a === void 0 ? void 0 : _a.uid;
    if (!customerId) {
        throw new https_1.HttpsError("unauthenticated", "Must be logged in.");
    }
    const { tripId, newFare } = ((_b = request.data) !== null && _b !== void 0 ? _b : {});
    if (!tripId) {
        throw new https_1.HttpsError("invalid-argument", "tripId is required.");
    }
    const tripRef = db().collection("trips").doc(String(tripId));
    const tripSnap = await tripRef.get();
    if (!tripSnap.exists) {
        throw new https_1.HttpsError("not-found", "Trip not found.");
    }
    const tripData = tripSnap.data();
    const orderCustomerId = String((_f = (_e = (_d = (_c = tripData.customerId) !== null && _c !== void 0 ? _c : tripData.userId) !== null && _d !== void 0 ? _d : (tripData.customer && typeof tripData.customer === "object"
        ? tripData.customer.uid
        : "")) !== null && _e !== void 0 ? _e : (tripData.tripBooker && typeof tripData.tripBooker === "object"
        ? tripData.tripBooker.uid
        : "")) !== null && _f !== void 0 ? _f : "");
    if (orderCustomerId !== customerId) {
        throw new https_1.HttpsError("permission-denied", "Not your trip.");
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
    const fromStatus = String((_g = tripData.status) !== null && _g !== void 0 ? _g : "");
    if (!validStatuses.includes(fromStatus)) {
        throw new https_1.HttpsError("failed-precondition", `Cannot reassign trip with status ${fromStatus}.`);
    }
    const tuning = await getDispatchTuning();
    let fareUpdate = {};
    if (typeof newFare === "number" && Number.isFinite(newFare) && newFare > 0) {
        const currentFare = Number((_j = (_h = tripData.fareAmount) !== null && _h !== void 0 ? _h : tripData.baselineFare) !== null && _j !== void 0 ? _j : 0);
        const roundedNewFare = (0, pricing_1.roundToNearest100)(newFare);
        if (roundedNewFare < currentFare) {
            throw new https_1.HttpsError("invalid-argument", "New fare cannot be lower than current fare.");
        }
        const maxOfferBoostPct = Number((_k = tuning.maxOfferBoostPct) !== null && _k !== void 0 ? _k : 100);
        const originalBase = Number(tripData.baselineFare && Number(tripData.baselineFare) > 0
            ? tripData.baselineFare
            : ((_l = tripData.fareAmount) !== null && _l !== void 0 ? _l : 0));
        const maxAllowedFare = Math.round(originalBase * (1 + maxOfferBoostPct / 100));
        if (roundedNewFare > maxAllowedFare) {
            throw new https_1.HttpsError("failed-precondition", `Offer boost cannot exceed ${maxOfferBoostPct}% above original base fare (max ₦${maxAllowedFare.toLocaleString()}).`);
        }
        const boostPct = currentFare > 0
            ? Math.round(((roundedNewFare - currentFare) / currentFare) * 100)
            : 0;
        const rawFareTiers = Array.isArray(tripData.fareTiers) ? tripData.fareTiers : [];
        const selectedTiers = Array.isArray(tripData.selectedTiers)
            ? tripData.selectedTiers
            : [];
        const updatedFareTiers = rawFareTiers.map((t) => {
            if (t &&
                typeof t === "object" &&
                (selectedTiers.length === 0 || selectedTiers.includes(t.tierId))) {
                return Object.assign(Object.assign({}, t), { fareAmount: roundedNewFare });
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
    const updatePayload = Object.assign(Object.assign({}, fareUpdate), { status: "SEARCHING_DRIVER", isPoolOrder: false, dispatchTier: 1, dispatchStep: 0, attemptedDriverIds: [], reassignmentCount: 0, reassignmentHistory: [], declineCount: 0, pingDriverId: null, pingDriverIds: [], pingExpiresAt: null, tierExpiresAt: null, poolExpiresAt: null, droppedToPoolAt: null, isExpired: false, cancellationSource: null, cancellationReason: null, driver: null, driverLocation: null, driverId: null, arrivedAt: null, statusMessage: fareUpdate.fareAmount
            ? `Fare updated to ₦${fareUpdate.fareAmount.toLocaleString()}! Reassigning drivers...`
            : "Searching for available drivers nearby...", statusHistory: admin.firestore.FieldValue.arrayUnion({
            from: fromStatus,
            to: "SEARCHING_DRIVER",
            actor: customerId,
            role: "customer",
            reason: fareUpdate.fareAmount ? "reassign_with_fare_boost" : "reassign_retry",
            timestamp: nowMs(),
        }), updatedAt: admin.firestore.FieldValue.serverTimestamp() });
    await tripRef.update(updatePayload);
    // Instantly trigger sequential dispatch router from Step 1!
    const fresh = (await tripRef.get()).data();
    await advanceSequentialDispatch(tripRef, fresh, tuning);
    return {
        ok: true,
        status: "SEARCHING_DRIVER",
        fareAmount: fresh.fareAmount,
        reassigned: true,
    };
}
exports.reassignTrip = (0, https_1.onCall)(handleReassignTrip);
exports.retryTripDispatch = exports.reassignTrip;
exports.keepSearchingTrip = exports.reassignTrip;
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
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t, _u, _v, _w, _x, _y, _z, _0, _1, _2, _3, _4, _5, _6, _7, _8, _9, _10, _11, _12, _13, _14, _15, _16;
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
    // ── Drop-off Geofencing Check ───────────────────────────────────────────
    if (data.dropoffApprovalStatus !== "APPROVED") {
        const dropoffLat = Number((_p = (_o = (_l = (_k = data.dropoff) === null || _k === void 0 ? void 0 : _k.lat) !== null && _l !== void 0 ? _l : (_m = data.dropoffLocation) === null || _m === void 0 ? void 0 : _m.latitude) !== null && _o !== void 0 ? _o : data.dropoffLat) !== null && _p !== void 0 ? _p : 0);
        const dropoffLng = Number((_u = (_t = (_r = (_q = data.dropoff) === null || _q === void 0 ? void 0 : _q.lng) !== null && _r !== void 0 ? _r : (_s = data.dropoffLocation) === null || _s === void 0 ? void 0 : _s.longitude) !== null && _t !== void 0 ? _t : data.dropoffLng) !== null && _u !== void 0 ? _u : 0);
        if (dropoffLat !== 0 && dropoffLng !== 0) {
            const driverLat = Number((_4 = (_2 = (_0 = (_y = (_w = (_v = request.data) === null || _v === void 0 ? void 0 : _v.driverLat) !== null && _w !== void 0 ? _w : (_x = request.data) === null || _x === void 0 ? void 0 : _x.lat) !== null && _y !== void 0 ? _y : (_z = request.data) === null || _z === void 0 ? void 0 : _z.latitude) !== null && _0 !== void 0 ? _0 : (_1 = data.driverLocation) === null || _1 === void 0 ? void 0 : _1.lat) !== null && _2 !== void 0 ? _2 : (_3 = data.driverLocation) === null || _3 === void 0 ? void 0 : _3.latitude) !== null && _4 !== void 0 ? _4 : 0);
            const driverLng = Number((_14 = (_12 = (_10 = (_8 = (_6 = (_5 = request.data) === null || _5 === void 0 ? void 0 : _5.driverLng) !== null && _6 !== void 0 ? _6 : (_7 = request.data) === null || _7 === void 0 ? void 0 : _7.lng) !== null && _8 !== void 0 ? _8 : (_9 = request.data) === null || _9 === void 0 ? void 0 : _9.longitude) !== null && _10 !== void 0 ? _10 : (_11 = data.driverLocation) === null || _11 === void 0 ? void 0 : _11.lng) !== null && _12 !== void 0 ? _12 : (_13 = data.driverLocation) === null || _13 === void 0 ? void 0 : _13.longitude) !== null && _14 !== void 0 ? _14 : 0);
            if (driverLat !== 0 && driverLng !== 0) {
                const distM = Math.round(haversineKm(driverLat, driverLng, dropoffLat, dropoffLng) * 1000);
                const radiusM = await getDropoffRadiusMeters();
                if (distM > radiusM) {
                    throw new https_1.HttpsError("failed-precondition", `OUT_OF_RANGE: Driver is outside drop-off location (${distM}m away, max allowed is ${radiusM}m). Customer confirmation required.`);
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
            from: String((_15 = data.status) !== null && _15 !== void 0 ? _15 : ""),
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
    (0, driverStreak_1.logTripTransition)({
        tripId,
        from: String((_16 = data.status) !== null && _16 !== void 0 ? _16 : ""),
        to: "COMPLETED",
        actor: driverId,
        role: "driver",
        reason: "pin_verified",
        timestamp: nowMs(),
    });
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
    let snapAfterData = null;
    await db().runTransaction(async (tx) => {
        var _a, _b, _c, _d;
        const snap = await tx.get(ref);
        if (!snap.exists)
            throw new https_1.HttpsError("not-found", "Trip not found.");
        const data = snap.data();
        const currentStatus = String((_a = data.status) !== null && _a !== void 0 ? _a : "");
        if (currentStatus === "COMPLETED") {
            snapAfterData = data;
            return;
        }
        if (!LIVE_STATUSES.includes(currentStatus)) {
            throw new https_1.HttpsError("failed-precondition", `Cannot force complete trip with closed status ${currentStatus}.`);
        }
        const assignedDriverId = String((_d = (_c = (_b = data.driver) === null || _b === void 0 ? void 0 : _b.driverId) !== null && _c !== void 0 ? _c : data.driverId) !== null && _d !== void 0 ? _d : "");
        const rejectionsList = Array.isArray(data.rejections) ? data.rejections : [];
        const updatedRejections = assignedDriverId
            ? rejectionsList.map((r) => r && r.driverId === assignedDriverId ? Object.assign(Object.assign({}, r), { superseded: true, supersededAt: nowMs() }) : r)
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
        snapAfterData = Object.assign(Object.assign({}, data), updates);
        (0, driverStreak_1.persistTripChangeLogInTx)(tx, {
            tripId,
            from: currentStatus,
            to: "COMPLETED",
            actor: adminUid,
            role: "hub_admin",
            timestamp: nowMs(),
        });
    });
    if ((snapAfterData === null || snapAfterData === void 0 ? void 0 : snapAfterData.status) === "COMPLETED" && snapAfterData.forceCompletedBy !== adminUid) {
        return { ok: true, alreadyCompleted: true, tripId };
    }
    try {
        if (snapAfterData) {
            await (0, driverStreak_1.handleTripCompletion)(tripId, snapAfterData);
        }
    }
    catch (e) {
        console.warn(`hubForceCompleteTrip[${tripId}]: synchronous settlement warning: ${e}`);
    }
    return { ok: true, tripId };
});
/** Driver confirms cash collected from customer for waiting time cancellation */
exports.confirmCashCancellation = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in.");
    }
    const driverId = request.auth.uid;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "");
    const cashCollected = ((_c = request.data) === null || _c === void 0 ? void 0 : _c.cashCollected) !== false;
    if (!tripId)
        throw new https_1.HttpsError("invalid-argument", "tripId is required.");
    const ref = db().collection("trips").doc(tripId);
    await db().runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e, _f, _g, _h, _j;
        // 1. ALL READS FIRST
        const snap = await tx.get(ref);
        if (!snap.exists)
            throw new https_1.HttpsError("not-found", "Trip not found.");
        const data = snap.data();
        const assignedDriverId = String((_c = (_b = (_a = data.driver) === null || _a === void 0 ? void 0 : _a.driverId) !== null && _b !== void 0 ? _b : data.driverId) !== null && _c !== void 0 ? _c : "");
        if (assignedDriverId !== driverId) {
            throw new https_1.HttpsError("permission-denied", "Not your trip.");
        }
        const currentStatus = String((_d = data.status) !== null && _d !== void 0 ? _d : "");
        if (currentStatus === "CANCELLED" && (data.cashSettlementConfirmed === true || ((_e = data.settlement) === null || _e === void 0 ? void 0 : _e.settled) === true)) {
            return;
        }
        if (currentStatus !== "CANCELLED_WAITING_CASH_SETTLEMENT") {
            throw new https_1.HttpsError("failed-precondition", `Cannot confirm cash cancellation for trip in status ${currentStatus}.`);
        }
        const customerId = String((_g = (_f = data.customerId) !== null && _f !== void 0 ? _f : data.userId) !== null && _g !== void 0 ? _g : "");
        const custWalletRef = customerId ? db().collection("wallets").doc(customerId) : null;
        if (custWalletRef)
            await tx.get(custWalletRef);
        const driverWalletRef = driverId ? db().collection("wallets").doc(driverId) : null;
        if (driverWalletRef)
            await tx.get(driverWalletRef);
        const custUserRef = customerId ? db().collection("users").doc(customerId) : null;
        if (custUserRef)
            await tx.get(custUserRef);
        const fee = Math.max(0, Number((_j = (_h = data.pendingCashFee) !== null && _h !== void 0 ? _h : data.paidWaitingFee) !== null && _j !== void 0 ? _j : 0));
        const feeKobo = (0, driverStreak_1.nairaToKobo)(fee);
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
            (0, driverStreak_1.persistTripChangeLogInTx)(tx, {
                tripId,
                from: currentStatus,
                to: "CANCELLED",
                actor: driverId,
                role: "driver",
                reason: "cash_waiting_fee_collected",
                timestamp: nowMs(),
            });
            if (fee > 0) {
                (0, driverStreak_1.persistFinancialAuditLogInTx)(tx, {
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
        }
        else {
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
            (0, driverStreak_1.persistTripChangeLogInTx)(tx, {
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
                    tx.set(custWalletRef, {
                        mainWalletBalance: admin.firestore.FieldValue.increment(-fee),
                        balance: admin.firestore.FieldValue.increment(-feeKobo),
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    }, { merge: true });
                    tx.set(custWalletRef.collection("transactions").doc(`${tripId}_unpaid_waiting_fee_debited`), {
                        type: "waiting_fee_paid",
                        role: "customer",
                        amountNaira: -fee,
                        amountKobo: -feeKobo,
                        amount: -feeKobo,
                        tripId,
                        currency: "NGN",
                        note: `Unpaid cash waiting fee debited for trip ${tripId}`,
                        createdAt: admin.firestore.FieldValue.serverTimestamp(),
                    });
                }
                if (custUserRef) {
                    tx.set(custUserRef, { outstandingNegativeBalance: admin.firestore.FieldValue.increment(fee) }, { merge: true });
                }
                if (driverWalletRef) {
                    tx.set(driverWalletRef, {
                        mainWalletBalance: admin.firestore.FieldValue.increment(fee),
                        balance: admin.firestore.FieldValue.increment(feeKobo),
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    }, { merge: true });
                    tx.set(driverWalletRef.collection("transactions").doc(`${tripId}_unpaid_waiting_fee_credited`), {
                        type: "waiting_fee_credited",
                        role: "driver",
                        amountNaira: fee,
                        amountKobo: feeKobo,
                        amount: feeKobo,
                        tripId,
                        currency: "NGN",
                        note: `Unpaid cash waiting fee credited for trip ${tripId}`,
                        createdAt: admin.firestore.FieldValue.serverTimestamp(),
                    });
                }
                if (customerId) {
                    (0, driverStreak_1.persistFinancialAuditLogInTx)(tx, {
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
                (0, driverStreak_1.persistFinancialAuditLogInTx)(tx, {
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
    const result = await (0, driverStreak_1.handleTripCancellationSettlement)({
        tripId,
        cancelledBy: "hub_admin",
        actorId: adminUid,
        role: "hub_admin",
        reason,
    });
    return { ok: true, tripId, alreadyCancelled: result.alreadyCancelled };
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
 * Submit post-trip star rating and update rated user's cumulative profile metrics.
 *
 * Atomically writes to `ratings/{tripId}_{raterId}` and updates:
 * - `users/{ratedUserId}`: totalRatingSum, totalRatingCount, averageRating
 * - `drivers/{ratedUserId}`: (if isRatedUserDriver) totalRatingSum, totalRatingCount, averageRating, rating
 */
exports.submitTripRating = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "User must be authenticated.");
    }
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "").trim();
    const raterId = request.auth.uid;
    const ratedUserId = String((_d = (_c = request.data) === null || _c === void 0 ? void 0 : _c.ratedUserId) !== null && _d !== void 0 ? _d : "").trim();
    const rating = Number((_e = request.data) === null || _e === void 0 ? void 0 : _e.rating);
    const comment = String((_g = (_f = request.data) === null || _f === void 0 ? void 0 : _f.comment) !== null && _g !== void 0 ? _g : "").trim();
    const lowRatingReasons = Array.isArray((_h = request.data) === null || _h === void 0 ? void 0 : _h.lowRatingReasons)
        ? request.data.lowRatingReasons.map((r) => String(r).trim()).filter(Boolean)
        : [];
    if (!tripId)
        throw new https_1.HttpsError("invalid-argument", "tripId is required.");
    if (!ratedUserId)
        throw new https_1.HttpsError("invalid-argument", "ratedUserId is required.");
    if (raterId === ratedUserId) {
        throw new https_1.HttpsError("invalid-argument", "Cannot rate yourself.");
    }
    if (!Number.isInteger(rating) || rating < 1 || rating > 5) {
        throw new https_1.HttpsError("invalid-argument", "rating must be an integer between 1 and 5.");
    }
    if (comment.length > 500) {
        throw new https_1.HttpsError("invalid-argument", "comment must be at most 500 characters.");
    }
    // Fetch trip to verify caller participation and target user validity
    const tripSnap = await db().collection("trips").doc(tripId).get();
    if (!tripSnap.exists) {
        throw new https_1.HttpsError("not-found", "Trip not found.");
    }
    const tripData = tripSnap.data() || {};
    const customerId = String((_j = tripData.customerId) !== null && _j !== void 0 ? _j : "").trim();
    const driverId = String((_m = (_l = (_k = tripData.driver) === null || _k === void 0 ? void 0 : _k.driverId) !== null && _l !== void 0 ? _l : tripData.driverId) !== null && _m !== void 0 ? _m : "").trim();
    const isCallerCustomer = raterId === customerId;
    const isCallerDriver = raterId === driverId;
    if (!isCallerCustomer && !isCallerDriver) {
        throw new https_1.HttpsError("permission-denied", "You are not a participant in this trip.");
    }
    const expectedRatedUserId = isCallerCustomer ? driverId : customerId;
    if (ratedUserId !== expectedRatedUserId) {
        throw new https_1.HttpsError("permission-denied", "Rated user was not a participant in this trip.");
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
            tx.set(userRef, {
                totalRatingSum: admin.firestore.FieldValue.increment(rating),
                totalRatingCount: admin.firestore.FieldValue.increment(1),
                averageRating: newAverage,
            }, { merge: true });
            // Mirror to drivers/{ratedUserId} if rated party is a driver
            if (driverRef) {
                tx.set(driverRef, {
                    totalRatingSum: admin.firestore.FieldValue.increment(rating),
                    totalRatingCount: admin.firestore.FieldValue.increment(1),
                    averageRating: newAverage,
                    rating: newAverage,
                }, { merge: true });
            }
        });
        return { ok: true, ratingDocId };
    }
    catch (err) {
        console.error(`submitTripRating[${ratingDocId}] error:`, err);
        throw new https_1.HttpsError("internal", "Failed to submit rating.");
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
exports.skipDeliveryPin = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in.");
    }
    (0, accountGuard_1.enforceAppCheck)(request);
    await (0, accountGuard_1.requireAccountActive)(request.auth.uid, "driver");
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
    // Gate 1: caller must be the assigned driver (supports both nested driver.driverId and flat driverId schemas).
    const assignedDriverId = (_d = (_c = data.driver) === null || _c === void 0 ? void 0 : _c.driverId) !== null && _d !== void 0 ? _d : data.driverId;
    if (assignedDriverId !== driverId) {
        throw new https_1.HttpsError("permission-denied", "Not your trip.");
    }
    // Gate 2: delivery trips only.
    const serviceType = String((_e = data.serviceType) !== null && _e !== void 0 ? _e : "ride");
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
    const startedAtMs = (_l = (_h = (_g = (_f = data.startedAt) === null || _f === void 0 ? void 0 : _f.toMillis) === null || _g === void 0 ? void 0 : _g.call(_f)) !== null && _h !== void 0 ? _h : (_k = (_j = data.updatedAt) === null || _j === void 0 ? void 0 : _j.toMillis) === null || _k === void 0 ? void 0 : _k.call(_j)) !== null && _l !== void 0 ? _l : Date.now();
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
/** Records driver arrival timestamp at drop-off for waiting & billing tracking. */
exports.recordDropoffArrival = (0, https_1.onCall)(async (request) => {
    var _a;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in.");
    }
    (0, accountGuard_1.enforceAppCheck)(request);
    const { tripId } = (_a = request.data) !== null && _a !== void 0 ? _a : {};
    if (!tripId || typeof tripId !== "string") {
        throw new https_1.HttpsError("invalid-argument", "tripId required.");
    }
    const ref = db().collection("trips").doc(String(tripId));
    await db().runTransaction(async (tx) => {
        var _a, _b, _c;
        const snap = await tx.get(ref);
        if (!snap.exists)
            throw new https_1.HttpsError("not-found", "Trip not found.");
        const data = snap.data();
        const driverId = String((_c = (_b = (_a = data.driver) === null || _a === void 0 ? void 0 : _a.driverId) !== null && _b !== void 0 ? _b : data.driverId) !== null && _c !== void 0 ? _c : "");
        if (driverId !== request.auth.uid) {
            throw new https_1.HttpsError("permission-denied", "Not your trip.");
        }
        if (data.status !== "IN_PROGRESS")
            return;
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
exports.requestDropoffApproval = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q, _r, _s, _t, _u, _v, _w, _x, _y, _z, _0, _1, _2, _3, _4, _5, _6;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in.");
    }
    (0, accountGuard_1.enforceAppCheck)(request);
    await (0, accountGuard_1.requireAccountActive)(request.auth.uid, "driver");
    const driverId = request.auth.uid;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "").trim();
    const driverLat = Number((_h = (_f = (_d = (_c = request.data) === null || _c === void 0 ? void 0 : _c.driverLat) !== null && _d !== void 0 ? _d : (_e = request.data) === null || _e === void 0 ? void 0 : _e.lat) !== null && _f !== void 0 ? _f : (_g = request.data) === null || _g === void 0 ? void 0 : _g.latitude) !== null && _h !== void 0 ? _h : 0);
    const driverLng = Number((_p = (_m = (_k = (_j = request.data) === null || _j === void 0 ? void 0 : _j.driverLng) !== null && _k !== void 0 ? _k : (_l = request.data) === null || _l === void 0 ? void 0 : _l.lng) !== null && _m !== void 0 ? _m : (_o = request.data) === null || _o === void 0 ? void 0 : _o.longitude) !== null && _p !== void 0 ? _p : 0);
    const reason = String((_r = (_q = request.data) === null || _q === void 0 ? void 0 : _q.reason) !== null && _r !== void 0 ? _r : "Driver dropped off at customer's new location").trim();
    if (!tripId) {
        throw new https_1.HttpsError("invalid-argument", "tripId is required.");
    }
    if (!driverLat || !driverLng) {
        throw new https_1.HttpsError("invalid-argument", "Valid driver GPS location is required.");
    }
    const ref = db().collection("trips").doc(tripId);
    const snap = await ref.get();
    if (!snap.exists)
        throw new https_1.HttpsError("not-found", "Trip not found.");
    const data = snap.data();
    const assignedDriverId = String((_u = (_t = (_s = data.driver) === null || _s === void 0 ? void 0 : _s.driverId) !== null && _t !== void 0 ? _t : data.driverId) !== null && _u !== void 0 ? _u : "");
    if (assignedDriverId !== driverId) {
        throw new https_1.HttpsError("permission-denied", "Not your trip.");
    }
    if (data.status !== "IN_PROGRESS") {
        throw new https_1.HttpsError("failed-precondition", `Trip must be IN_PROGRESS (currently ${data.status}).`);
    }
    const dropoffLat = Number((_z = (_y = (_w = (_v = data.dropoff) === null || _v === void 0 ? void 0 : _v.lat) !== null && _w !== void 0 ? _w : (_x = data.dropoffLocation) === null || _x === void 0 ? void 0 : _x.latitude) !== null && _y !== void 0 ? _y : data.dropoffLat) !== null && _z !== void 0 ? _z : 0);
    const dropoffLng = Number((_4 = (_3 = (_1 = (_0 = data.dropoff) === null || _0 === void 0 ? void 0 : _0.lng) !== null && _1 !== void 0 ? _1 : (_2 = data.dropoffLocation) === null || _2 === void 0 ? void 0 : _2.longitude) !== null && _3 !== void 0 ? _3 : data.dropoffLng) !== null && _4 !== void 0 ? _4 : 0);
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
    const customerId = String((_6 = (_5 = data.customerId) !== null && _5 !== void 0 ? _5 : data.userId) !== null && _6 !== void 0 ? _6 : "");
    if (customerId) {
        const distStr = distanceM >= 1000 ? `${(distanceM / 1000).toFixed(1)}km` : `${distanceM}m`;
        await notifyCustomer(customerId, tripId, "Drop-off Confirmation Required", "Confirm driver has dropped off your item at your new location?", "dropoff_approval_request", {
            tripId,
            type: "dropoff_approval_request",
            distanceMeters: String(distanceM),
            distanceText: distStr,
            click_action: "FLUTTER_NOTIFICATION_CLICK",
        });
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
exports.respondDropoffApproval = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Authentication required.");
    }
    (0, accountGuard_1.enforceAppCheck)(request);
    await (0, accountGuard_1.requireAccountActive)(request.auth.uid);
    const customerId = request.auth.uid;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "").trim();
    const approved = ((_c = request.data) === null || _c === void 0 ? void 0 : _c.approved) === true;
    if (!tripId) {
        throw new https_1.HttpsError("invalid-argument", "tripId is required.");
    }
    const ref = db().collection("trips").doc(tripId);
    let snapAfterData = null;
    let driverId = "";
    await db().runTransaction(async (tx) => {
        var _a, _b, _c, _d, _e;
        const snap = await tx.get(ref);
        if (!snap.exists)
            throw new https_1.HttpsError("not-found", "Trip not found.");
        const data = snap.data();
        const tripCustomerId = String((_b = (_a = data.customerId) !== null && _a !== void 0 ? _a : data.userId) !== null && _b !== void 0 ? _b : "");
        if (tripCustomerId !== customerId) {
            throw new https_1.HttpsError("permission-denied", "Only the customer who ordered this trip can respond to drop-off approval.");
        }
        if (data.dropoffApprovalStatus !== "PENDING") {
            if (data.status === "COMPLETED") {
                return; // Idempotent
            }
            throw new https_1.HttpsError("failed-precondition", "No pending drop-off approval request.");
        }
        driverId = String((_e = (_d = (_c = data.driver) === null || _c === void 0 ? void 0 : _c.driverId) !== null && _d !== void 0 ? _d : data.driverId) !== null && _e !== void 0 ? _e : "");
        if (approved) {
            const currentStatus = String(data.status);
            const update = {
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
            snapAfterData = Object.assign(Object.assign({}, data), update);
            (0, driverStreak_1.persistTripChangeLogInTx)(tx, {
                tripId,
                from: currentStatus,
                to: "COMPLETED",
                actor: customerId,
                role: "customer",
                reason: "remote_customer_dropoff_approved",
                timestamp: nowMs(),
            });
        }
        else {
            const update = {
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
            snapAfterData = Object.assign(Object.assign({}, data), update);
        }
    });
    if (approved && snapAfterData) {
        (0, driverStreak_1.logTripTransition)({
            tripId,
            from: "IN_PROGRESS",
            to: "COMPLETED",
            actor: customerId,
            role: "customer",
            reason: "remote_customer_dropoff_approved",
            timestamp: nowMs(),
        });
        try {
            await (0, driverStreak_1.handleTripCompletion)(tripId, snapAfterData);
        }
        catch (e) {
            console.warn(`respondDropoffApproval[${tripId}]: synchronous settlement warning: ${e}`);
        }
        if (driverId) {
            await notifyCustomer(driverId, tripId, "Drop-off Approved", "Customer has confirmed drop-off. Trip completed successfully!", "dropoff_approved", { tripId, type: "dropoff_approved" }, `driver_${driverId}`);
        }
        return { ok: true, approved: true, completed: true };
    }
    else {
        if (driverId) {
            await notifyCustomer(driverId, tripId, "Drop-off Confirmation Rejected", "Customer declined out-of-range drop-off. Please reach the scheduled drop-off location or contact support.", "dropoff_rejected", { tripId, type: "dropoff_rejected" }, `driver_${driverId}`);
        }
        return { ok: true, approved: false, completed: false };
    }
});
/** Driver cancels an active pending out-of-range drop-off confirmation request. */
exports.cancelDropoffApprovalRequest = (0, https_1.onCall)(async (request) => {
    var _a, _b, _c, _d, _e;
    if (!request.auth) {
        throw new https_1.HttpsError("unauthenticated", "Drivers must sign in.");
    }
    (0, accountGuard_1.enforceAppCheck)(request);
    const driverId = request.auth.uid;
    const tripId = String((_b = (_a = request.data) === null || _a === void 0 ? void 0 : _a.tripId) !== null && _b !== void 0 ? _b : "").trim();
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
    if (data.dropoffApprovalStatus === "PENDING") {
        await ref.update({
            dropoffApprovalStatus: null,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }
    return { ok: true };
});
//# sourceMappingURL=trips.js.map