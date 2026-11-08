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

import * as admin from "firebase-admin";
import { HttpsError } from "firebase-functions/v2/https";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { onCall } from "firebase-functions/v2/https";

const db = () => admin.firestore();

/** All driver ids the given trip document involved (assigned ∪ attempted). */
function collectDriverIds(data: Record<string, unknown> | undefined): string[] {
  if (!data) return [];
  const ids = new Set<string>();

  const nested = (data.driver as Record<string, unknown> | undefined)?.driverId;
  if (typeof nested === "string" && nested.trim()) ids.add(nested.trim());
  if (typeof data.driverId === "string" && data.driverId.trim()) ids.add(data.driverId.trim());

  const attempted = data.attemptedDriverIds;
  if (Array.isArray(attempted)) {
    for (const d of attempted) {
      const v = String(d ?? "").trim();
      if (v) ids.add(v);
    }
  }
  return [...ids];
}

/** assigned (nested/flat) driver ids for this revision of the trip. */
function collectAssignedDriverIds(data: Record<string, unknown> | undefined): Set<string> {
  const assigned = new Set<string>();
  if (!data) return assigned;
  const nested = (data.driver as Record<string, unknown> | undefined)?.driverId;
  if (typeof nested === "string" && nested.trim()) assigned.add(nested.trim());
  if (typeof data.driverId === "string" && data.driverId.trim()) assigned.add(data.driverId.trim());
  return assigned;
}

const HISTORY_COLLECTION = "trip_history";

export const onTripWrittenForDriverHistory = onDocumentWritten(
  "trips/{tripId}",
  async (event) => {
    const tripId = event.params.tripId as string;
    const before = event.data?.before?.data() as Record<string, unknown> | undefined;
    const after = event.data?.after?.data() as Record<string, unknown> | undefined;

    // Trip deletion: strip any mirrors that referenced it.
    if (!after) {
      const ids = collectDriverIds(before);
      if (ids.length === 0) return;
      const batch = db().batch();
      for (const uid of ids) {
        batch.delete(db().collection("drivers").doc(uid).collection(HISTORY_COLLECTION).doc(tripId));
      }
      await batch.commit();
      return;
    }

    const ids = collectDriverIds(after);
    if (ids.length === 0) return;
    const assigned = collectAssignedDriverIds(after);
    const isTripCompleted = String(after.status ?? "").toUpperCase() === "COMPLETED";

    const batch = db().batch();
    for (const uid of ids) {
      const isAssigned = assigned.has(uid);
      const ref = db().collection("drivers").doc(uid).collection(HISTORY_COLLECTION).doc(tripId);

      const mirrorData: Record<string, unknown> = {
        ...after,
        mirroredAt: admin.firestore.FieldValue.serverTimestamp(),
        isAssignedMirror: isAssigned,
      };

      // If the trip completed and this driver fulfilled it, or if this driver is actively assigned,
      // clear any preliminary skip or cancellation flags.
      if (isAssigned || isTripCompleted) {
        if (
          isTripCompleted ||
          after.status === "DRIVER_ACCEPTED" ||
          after.status === "DRIVER_ARRIVING" ||
          after.status === "DRIVER_ARRIVED" ||
          after.status === "IN_PROGRESS"
        ) {
          mirrorData.cancellationSource = after.cancellationSource ?? null;
          mirrorData.cancellationReason = after.cancellationReason ?? null;
        }
      }

      // If this driver is the assigned driver, any previous rejection/skip
      // by this driver is strictly superseded by their acceptance/completion.
      if (isAssigned && Array.isArray(mirrorData.rejections)) {
        mirrorData.rejections = (mirrorData.rejections as any[]).map((r) =>
          r && r.driverId === uid ? { ...r, superseded: true } : r
        );
      }

      batch.set(ref, mirrorData);
    }
    await batch.commit();
  }
);

/** SUPER_ADMIN-only one-shot backfill: mirrors the trips collection page by page. */
export const backfillDriverTripHistory = onCall(async (request) => {
  const uid = request.auth?.uid ?? "";
  if (!uid) throw new HttpsError("unauthenticated", "You must sign in.");
  const role = String(request.auth?.token?.role ?? "").toUpperCase();
  const isSuper =
    request.auth?.token?.adminAuth === true ||
    request.auth?.token?.admin === true ||
    role === "SUPER_ADMIN" ||
    role === "ROLE_SUPER_ADMIN" ||
    role === "ADMIN" ||
    role === "SUPER";
  if (!isSuper) {
    throw new HttpsError("permission-denied", "Super admin required.");
  }

  const limit = Math.min(Math.max(Number(request.data?.limit ?? 200), 1), 500);
  const startAfter = String(request.data?.cursor ?? "").trim();

  let q = db().collection("trips").orderBy(admin.firestore.FieldPath.documentId()).limit(limit);
  if (startAfter) {
    const snap = await db().collection("trips").doc(startAfter).get();
    if (snap.exists) q = q.startAfter(snap);
  }

  const snap = await q.get();
  const batch = db().batch();
  let mirrored = 0;
  for (const d of snap.docs) {
    const data = d.data() as Record<string, unknown>;
    const ids = collectDriverIds(data);
    if (ids.length === 0) continue;
    const assigned = collectAssignedDriverIds(data);
    const isTripCompleted = String(data.status ?? "").toUpperCase() === "COMPLETED";

    for (const driverUid of ids) {
      const isAssigned = assigned.has(driverUid);
      const ref = db().collection("drivers").doc(driverUid).collection(HISTORY_COLLECTION).doc(d.id);

      const mirrorData: Record<string, unknown> = {
        ...data,
        mirroredAt: admin.firestore.FieldValue.serverTimestamp(),
        isAssignedMirror: isAssigned,
      };

      if (isAssigned || isTripCompleted) {
        if (
          isTripCompleted ||
          data.status === "DRIVER_ACCEPTED" ||
          data.status === "DRIVER_ARRIVING" ||
          data.status === "DRIVER_ARRIVED" ||
          data.status === "IN_PROGRESS"
        ) {
          mirrorData.cancellationSource = data.cancellationSource ?? null;
          mirrorData.cancellationReason = data.cancellationReason ?? null;
        }
      }

      if (isAssigned && Array.isArray(mirrorData.rejections)) {
        mirrorData.rejections = (mirrorData.rejections as any[]).map((r) =>
          r && r.driverId === driverUid ? { ...r, superseded: true } : r
        );
      }

      batch.set(ref, mirrorData);
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
