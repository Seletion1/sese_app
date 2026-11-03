"use strict";
/**
 * driverTripHistory.ts — Server-authoritative per-driver trip history index.
 *
 * Why this exists
 * ───────────────
 * Firestore list queries can only be proven from rule predicates; our trips
 * read rule is a broad disjunction (customer, nested/flat driver ids,
 * attemptedDriverIds, marketplace …), so a query such as
 * `where('attemptedDriverIds','array-contains',uid)` is REJECTED for the
 * whole result set even though any single document read would pass
 * (verified on the Firestore emulator: `list` → permission-denied while the
 * same predicate on `get` succeeds).
 *
 * Fix: mirror every trip document into `drivers/{uid}/trip_history/{tripId}`
 * for each driver the trip involved (assigned + every driver that was
 * pinged/rejected/skipped). The owning driver (and authorized staff) can
 * read their own index; nobody else can. All writes are server-only.
 *
 * Design notes
 * ─────────────
 * - Triggered on EVERY trip write, so inserts, status transitions,
 *   reassignments, and cancellations all keep the mirror fresh.
 * - Mirror stores the full trip payload (minus nothing) plus
 *   `mirroredAt` (serverTimestamp) and `isAssignedMirror` so clients can
 *   distinguish "assigned to me" from "I only attempted it" if they want.
 * - Trip deletes clean up the mirrors too.
 * - `backfillDriverTripHistory` is a SUPER_ADMIN-only callable that pages
 *   over the whole trips collection and rebuilds the index in one go.
 *   Used by ops after enabling the mirror on an existing database.
 */
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
exports.backfillDriverTripHistory = exports.onTripWrittenForDriverHistory = void 0;
const admin = __importStar(require("firebase-admin"));
const https_1 = require("firebase-functions/v2/https");
const firestore_1 = require("firebase-functions/v2/firestore");
const https_2 = require("firebase-functions/v2/https");
const db = () => admin.firestore();
/** All driver ids the given trip document involved (assigned ∪ attempted). */
function collectDriverIds(data) {
    var _a;
    if (!data)
        return [];
    const ids = new Set();
    const nested = (_a = data.driver) === null || _a === void 0 ? void 0 : _a.driverId;
    if (typeof nested === "string" && nested.trim())
        ids.add(nested.trim());
    if (typeof data.driverId === "string" && data.driverId.trim())
        ids.add(data.driverId.trim());
    const attempted = data.attemptedDriverIds;
    if (Array.isArray(attempted)) {
        for (const d of attempted) {
            const v = String(d !== null && d !== void 0 ? d : "").trim();
            if (v)
                ids.add(v);
        }
    }
    return [...ids];
}
/** assigned (nested/flat) driver ids for this revision of the trip. */
function collectAssignedDriverIds(data) {
    var _a;
    const assigned = new Set();
    if (!data)
        return assigned;
    const nested = (_a = data.driver) === null || _a === void 0 ? void 0 : _a.driverId;
    if (typeof nested === "string" && nested.trim())
        assigned.add(nested.trim());
    if (typeof data.driverId === "string" && data.driverId.trim())
        assigned.add(data.driverId.trim());
    return assigned;
}
const HISTORY_COLLECTION = "trip_history";
exports.onTripWrittenForDriverHistory = (0, firestore_1.onDocumentWritten)("trips/{tripId}", async (event) => {
    var _a, _b, _c, _d;
    const tripId = event.params.tripId;
    const before = (_b = (_a = event.data) === null || _a === void 0 ? void 0 : _a.before) === null || _b === void 0 ? void 0 : _b.data();
    const after = (_d = (_c = event.data) === null || _c === void 0 ? void 0 : _c.after) === null || _d === void 0 ? void 0 : _d.data();
    // Trip deletion: strip any mirrors that referenced it.
    if (!after) {
        const ids = collectDriverIds(before);
        if (ids.length === 0)
            return;
        const batch = db().batch();
        for (const uid of ids) {
            batch.delete(db().collection("drivers").doc(uid).collection(HISTORY_COLLECTION).doc(tripId));
        }
        await batch.commit();
        return;
    }
    const ids = collectDriverIds(after);
    if (ids.length === 0)
        return;
    const assigned = collectAssignedDriverIds(after);
    const batch = db().batch();
    for (const uid of ids) {
        const ref = db().collection("drivers").doc(uid).collection(HISTORY_COLLECTION).doc(tripId);
        batch.set(ref, Object.assign(Object.assign({}, after), { mirroredAt: admin.firestore.FieldValue.serverTimestamp(), isAssignedMirror: assigned.has(uid) }), { merge: true });
    }
    await batch.commit();
});
/** SUPER_ADMIN-only one-shot backfill: mirrors the trips collection page by page. */
exports.backfillDriverTripHistory = (0, https_2.onCall)(async (request) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o;
    const uid = (_b = (_a = request.auth) === null || _a === void 0 ? void 0 : _a.uid) !== null && _b !== void 0 ? _b : "";
    if (!uid)
        throw new https_1.HttpsError("unauthenticated", "You must sign in.");
    const role = String((_e = (_d = (_c = request.auth) === null || _c === void 0 ? void 0 : _c.token) === null || _d === void 0 ? void 0 : _d.role) !== null && _e !== void 0 ? _e : "").toUpperCase();
    const isSuper = ((_g = (_f = request.auth) === null || _f === void 0 ? void 0 : _f.token) === null || _g === void 0 ? void 0 : _g.adminAuth) === true ||
        ((_j = (_h = request.auth) === null || _h === void 0 ? void 0 : _h.token) === null || _j === void 0 ? void 0 : _j.admin) === true ||
        role === "SUPER_ADMIN" ||
        role === "ROLE_SUPER_ADMIN" ||
        role === "ADMIN" ||
        role === "SUPER";
    if (!isSuper) {
        throw new https_1.HttpsError("permission-denied", "Super admin required.");
    }
    const limit = Math.min(Math.max(Number((_l = (_k = request.data) === null || _k === void 0 ? void 0 : _k.limit) !== null && _l !== void 0 ? _l : 200), 1), 500);
    const startAfter = String((_o = (_m = request.data) === null || _m === void 0 ? void 0 : _m.cursor) !== null && _o !== void 0 ? _o : "").trim();
    let q = db().collection("trips").orderBy(admin.firestore.FieldPath.documentId()).limit(limit);
    if (startAfter) {
        const snap = await db().collection("trips").doc(startAfter).get();
        if (snap.exists)
            q = q.startAfter(snap);
    }
    const snap = await q.get();
    const batch = db().batch();
    let mirrored = 0;
    for (const d of snap.docs) {
        const data = d.data();
        const ids = collectDriverIds(data);
        if (ids.length === 0)
            continue;
        const assigned = collectAssignedDriverIds(data);
        for (const driverUid of ids) {
            const ref = db().collection("drivers").doc(driverUid).collection(HISTORY_COLLECTION).doc(d.id);
            batch.set(ref, Object.assign(Object.assign({}, data), { mirroredAt: admin.firestore.FieldValue.serverTimestamp(), isAssignedMirror: assigned.has(driverUid) }), { merge: true });
            mirrored += 1;
        }
    }
    await batch.commit();
    return {
        processed: snap.docs.length,
        mirrored,
        cursor: snap.docs.length ? snap.docs[snap.docs.length - 1].id : null,
        done: snap.docs.length < limit,
    };
});
//# sourceMappingURL=driverTripHistory.js.map