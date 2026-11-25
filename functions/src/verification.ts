import * as admin from "firebase-admin";
import { HttpsError } from "firebase-functions/v2/https";
import { onDocumentCreated, onDocumentUpdated } from "firebase-functions/v2/firestore";
import { guardedOnCall } from "./accountGuard";
import { _assignSequentialId } from "./sequentialIds";

const db = () => admin.firestore();

function _isDocVerified(data: Record<string, unknown> | undefined): boolean {
  if (!data) return false;
  return (
    data.isProfileVerified === true ||
    data.isVerifiedCustomer === true ||
    data.verificationStatus === "approved" ||
    data.verificationStatus === "verified" ||
    data.customerVerificationStatus === "verified" ||
    data.customerVerificationStatus === "approved"
  );
}

/**
 * Trigger: onUserCreated
 *
 * Runs upon user registration document creation in users/{userId}.
 * Unverified signups do NOT receive a sequential Member ID (`SC...`).
 * The Member ID is assigned strictly when the account transitions to `verified`.
 */
export const onUserCreated = onDocumentCreated(
  "users/{userId}",
  async (event) => {
    const userId = event.params.userId;
    const data = event.data?.data();
    if (_isDocVerified(data)) {
      try {
        await _assignSequentialId(userId, "customer");
      } catch (err) {
        console.warn(`onUserCreated sequential ID assignment failed for ${userId}:`, err);
      }
    }
  }
);

/**
 * Trigger: onDriverCreated
 *
 * Runs upon driver registration document creation in drivers/{driverId}.
 * Unverified signups do NOT receive a sequential Member ID (`SD...`).
 * The Member ID is assigned strictly when the account transitions to `verified`.
 */
export const onDriverCreated = onDocumentCreated(
  "drivers/{driverId}",
  async (event) => {
    const driverId = event.params.driverId;
    const data = event.data?.data();
    if (_isDocVerified(data)) {
      try {
        await _assignSequentialId(driverId, "driver");
      } catch (err) {
        console.warn(`onDriverCreated sequential ID assignment failed for ${driverId}:`, err);
      }
    }
  }
);

/**
 * Trigger: onUserUpdated
 *
 * Runs on updates to users/{userId}. Assigns the official sequential Member ID
 * (`SC...`) once the account becomes verified if not already assigned.
 */
export const onUserUpdated = onDocumentUpdated(
  "users/{userId}",
  async (event) => {
    const after = event.data?.after.data();
    if (!after || !_isDocVerified(after)) return;

    const existingSeq = String(after.sequentialId ?? "").trim();
    if (existingSeq.startsWith("SC")) return;

    const userId = event.params.userId;
    try {
      await _assignSequentialId(userId, "customer");
    } catch (err) {
      console.warn(`onUserUpdated sequential ID assignment failed for ${userId}:`, err);
    }
  }
);

/**
 * Trigger: onDriverUpdated
 *
 * Runs on updates to drivers/{driverId}. Assigns the official sequential Member ID
 * (`SD...`) once the account becomes verified if not already assigned.
 */
export const onDriverUpdated = onDocumentUpdated(
  "drivers/{driverId}",
  async (event) => {
    const after = event.data?.after.data();
    if (!after || !_isDocVerified(after)) return;

    const existingSeq = String(after.sequentialId ?? "").trim();
    if (existingSeq.startsWith("SD")) return;

    const driverId = event.params.driverId;
    try {
      await _assignSequentialId(driverId, "driver");
    } catch (err) {
      console.warn(`onDriverUpdated sequential ID assignment failed for ${driverId}:`, err);
    }
  }
);

interface ReviewCustomerData {
  userId: string;
  approved: boolean;
  rejectionReason?: string;
}

interface ReviewDriverData {
  driverId: string;
  approved: boolean;
  rejectionReason?: string;
}

import { isPlatformOwnerEmail } from "./hubBootstrap";

/**
 * Helper to enforce that the caller is authorized as a Hub Staff member or Administrator.
 * Checks custom claims (`admin`, `adminAuth`, `role` in SUPER_ADMIN/ADMIN)
 * or an active record in `hub_staff/{email}` collection.
 *
 * Accepts either:
 *  - `auth` object (`request.auth`)
 *  - `(callerUid, callerEmail, token)` tuple
 */
export async function assertHubStaffOrAdmin(
  callerUidOrAuth: string | { uid: string; token?: Record<string, any> } | undefined | null,
  callerEmail?: string,
  token?: Record<string, unknown>
): Promise<void> {
  if (!callerUidOrAuth) {
    throw new HttpsError(
      "permission-denied",
      "Only Hub staff or administrators can perform this action."
    );
  }

  let uid = "";
  let email = "";
  let tok: Record<string, unknown> = {};

  if (typeof callerUidOrAuth === "object") {
    uid = callerUidOrAuth.uid ?? "";
    email = String(callerUidOrAuth.token?.email ?? "").trim().toLowerCase();
    tok = (callerUidOrAuth.token ?? {}) as Record<string, unknown>;
  } else {
    uid = callerUidOrAuth;
    email = String(callerEmail ?? "").trim().toLowerCase();
    tok = token ?? {};
  }

  if (!uid) {
    throw new HttpsError(
      "permission-denied",
      "Only Hub staff or administrators can perform this action."
    );
  }

  if (isPlatformOwnerEmail(email) || (process.env.OWNER_EMAIL && email === process.env.OWNER_EMAIL.trim().toLowerCase())) {
    return;
  }
  const role = String(tok.role ?? tok.adminRole ?? "").toUpperCase();
  const isSuperOrAdmin =
    tok.admin === true ||
    tok.adminAuth === true ||
    role === "SUPER_ADMIN" ||
    role === "ROLE_SUPER_ADMIN" ||
    role === "SUPER" ||
    role === "ADMIN";

  if (isSuperOrAdmin) {
    return;
  }

  if (email) {
    try {
      const snap = await db().collection("hub_staff").doc(email).get();
      if (snap.exists && snap.data()?.active !== false) {
        return;
      }
    } catch (e) {
      console.error(`assertHubStaffOrAdmin: hub_staff lookup failed for ${email}:`, e);
    }
  }

  throw new HttpsError(
    "permission-denied",
    "Only Hub staff or administrators can perform this action."
  );
}

/**
 * Callable: reviewCustomerVerification
 *
 * Hub admins call this to approve or reject customer KYC verification.
 * Approving sets verificationStatus = 'verified' and custom claim isVerified = true.
 * Rejecting stores a structured rejection reason and sends an FCM push notification.
 */
export const reviewCustomerVerification = guardedOnCall<ReviewCustomerData>(
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required.");
    }

    const callerUid = request.auth.uid;
    const callerEmail = (request.auth.token?.email ?? "").trim().toLowerCase();
    const token = request.auth.token ?? {};

    await assertHubStaffOrAdmin(callerUid, callerEmail, token);

    const { userId, approved, rejectionReason } = request.data ?? {};
    if (!userId) {
      throw new HttpsError("invalid-argument", "userId is required.");
    }

    if (userId === callerUid) {
      throw new HttpsError(
        "permission-denied",
        "Self-Verification Lock: Users cannot review or approve their own verification status."
      );
    }

    const userRef = db().collection("users").doc(userId);
    const userSnap = await userRef.get();
    if (!userSnap.exists) {
      throw new HttpsError("not-found", "User document not found.");
    }

    const userData = userSnap.data() ?? {};
    if (approved && userData.createdByAdminId && userData.createdByAdminId === request.auth.uid) {
      throw new HttpsError(
        "failed-precondition",
        "Self-Verification Lock: Admin who created this account cannot self-approve verification."
      );
    }

    if (approved) {
      await userRef.set(
        {
          customerVerificationStatus: "verified",
          verificationStatus: "verified",
          isVerifiedCustomer: true,
          kycRejectionReason: "",
          verificationReviewedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      // Set custom claim isVerified = true
      try {
        const userRecord = await admin.auth().getUser(userId);
        await admin.auth().setCustomUserClaims(userId, {
          ...(userRecord.customClaims || {}),
          isVerified: true,
        });
      } catch (err) {
        console.warn(`Failed to set isVerified custom claim on ${userId}:`, err);
      }

      // Send FCM Push Notification
      try {
        await admin.messaging().send({
          topic: `user_${userId}`,
          notification: {
            title: "Account Verified ✅",
            body: "Your account verification has been approved.",
          },
          data: {
            type: "kyc_approved",
            userId,
          },
        });
      } catch (err) {
        console.warn(`FCM send failed for ${userId}:`, err);
      }

      // Assign official sequential Member ID (SC...) now that the user is verified.
      // Wrapped in try/catch — an ID assignment failure must never
      // roll back a successfully-completed verification approval.
      try {
        await _assignSequentialId(userId, "customer");
      } catch (err) {
        console.warn(`Sequential ID assignment failed for user ${userId}:`, err);
      }

      return { success: true, status: "verified" };
    } else {
      const reason =
        rejectionReason?.trim() || "Documents could not be verified";
      await userRef.set(
        {
          customerVerificationStatus: "rejected",
          verificationStatus: "rejected",
          isVerifiedCustomer: false,
          kycRejectionReason: reason,
          verificationReviewedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      // Set custom claim isVerified = false
      try {
        const userRecord = await admin.auth().getUser(userId);
        await admin.auth().setCustomUserClaims(userId, {
          ...(userRecord.customClaims || {}),
          isVerified: false,
        });
      } catch (err) {
        console.warn(`Failed to update custom claims on ${userId}:`, err);
      }

      // Send FCM Push Notification with rejection reason (body is generic,
      // reason is available in-app via kycRejectionReason field)
      try {
        await admin.messaging().send({
          topic: `user_${userId}`,
          notification: {
            title: "Verification Update ⚠️",
            body: "Verification update required. Please check your profile for details.",
          },
          data: {
            type: "kyc_rejected",
            userId,
            reason,
          },
        });
      } catch (err) {
        console.warn(`FCM send failed for ${userId}:`, err);
      }

      return { success: true, status: "rejected", reason };
    }
  }
);

/**
 * Callable: reviewDriverVerification
 *
 * Hub admins call this to approve or reject driver profile onboarding documents.
 */
export const reviewDriverVerification = guardedOnCall<ReviewDriverData>(
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required.");
    }

    const callerUid = request.auth.uid;
    const callerEmail = (request.auth.token?.email ?? "").trim().toLowerCase();
    const token = request.auth.token ?? {};

    await assertHubStaffOrAdmin(callerUid, callerEmail, token);

    const { driverId, approved, rejectionReason } = request.data ?? {};
    if (!driverId) {
      throw new HttpsError("invalid-argument", "driverId is required.");
    }

    if (driverId === callerUid) {
      throw new HttpsError(
        "permission-denied",
        "Self-Verification Lock: Drivers cannot review or approve their own verification status."
      );
    }

    const driverRef = db().collection("drivers").doc(driverId);
    const driverSnap = await driverRef.get();
    if (!driverSnap.exists) {
      throw new HttpsError("not-found", "Driver document not found.");
    }

    const driverData = driverSnap.data() ?? {};
    if (approved && driverData.createdByAdminId && driverData.createdByAdminId === request.auth.uid) {
      throw new HttpsError(
        "failed-precondition",
        "Self-Verification Lock: Admin who created this driver account cannot self-approve verification."
      );
    }

    if (approved) {
      await driverRef.set(
        {
          verificationStatus: "approved",
          isProfileVerified: true,
          isActive: true,
          profileRejectionReason: "",
          profileApprovedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      // Also set custom claim isVerified = true on the Auth user
      try {
        const userRecord = await admin.auth().getUser(driverId);
        await admin.auth().setCustomUserClaims(driverId, {
          ...(userRecord.customClaims || {}),
          isVerified: true,
        });
      } catch (err) {
        console.warn(`Failed to set isVerified custom claim on driver ${driverId}:`, err);
      }

      // Send FCM notification
      try {
        await admin.messaging().send({
          topic: `driver_${driverId}`,
          notification: {
            title: "Account Verified ✅",
            body: "Your account verification has been approved.",
          },
          data: {
            type: "driver_approved",
            driverId,
          },
        });
      } catch (err) {
        console.warn(`FCM send failed for driver ${driverId}:`, err);
      }

      // Assign official sequential Driver ID (SD...) now that the driver is verified.
      try {
        await _assignSequentialId(driverId, "driver");
      } catch (err) {
        console.warn(`Sequential ID assignment failed for driver ${driverId}:`, err);
      }

      return { success: true, status: "approved" };
    } else {
      const reason =
        rejectionReason?.trim() || "Driver documents could not be verified";
      await driverRef.set(
        {
          verificationStatus: "rejected",
          isProfileVerified: false,
          isActive: false,
          profileRejectionReason: reason,
          rejectedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      try {
        const userRecord = await admin.auth().getUser(driverId);
        await admin.auth().setCustomUserClaims(driverId, {
          ...(userRecord.customClaims || {}),
          isVerified: false,
        });
      } catch (err) {
        console.warn(`Failed to update custom claims on driver ${driverId}:`, err);
      }

      // Send FCM notification (body is generic; reason stored in profileRejectionReason)
      try {
        await admin.messaging().send({
          topic: `driver_${driverId}`,
          notification: {
            title: "Verification Update ⚠️",
            body: "Verification update required. Please check your profile for details.",
          },
          data: {
            type: "driver_rejected",
            driverId,
            reason,
          },
        });
      } catch (err) {
        console.warn(`FCM send failed for driver ${driverId}:`, err);
      }

      return { success: true, status: "rejected", reason };
    }
  }
);

/**
 * Trigger: onUserVerificationUpdated
 *
 * Catches direct Firestore updates from sese_hub or console on users/{userId}.
 * Synchronizes custom claims and sends FCM push notification if status changed.
 */
export const onUserVerificationUpdated = onDocumentUpdated(
  "users/{userId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    const beforeStatus =
      before.customerVerificationStatus || before.verificationStatus;
    const afterStatus =
      after.customerVerificationStatus || after.verificationStatus;

    if (beforeStatus === afterStatus) return;

    const userId = event.params.userId;

    if (afterStatus === "verified") {
      try {
        const userRecord = await admin.auth().getUser(userId);
        if (!userRecord.customClaims?.isVerified) {
          await admin.auth().setCustomUserClaims(userId, {
            ...(userRecord.customClaims || {}),
            isVerified: true,
          });
        }
      } catch (err) {
        console.warn(`Trigger failed setting claim on ${userId}:`, err);
      }
      // Approval announcement: account verification completed.
      try {
        await admin.messaging().send({
          topic: `user_${userId}`,
          notification: {
            title: "Account Verified ✅",
            body: "Your account verification has been approved.",
          },
          android: {
            priority: "high",
            notification: { sound: "sese_alert_chime" },
          },
          apns: { payload: { aps: { sound: "default" } } },
          data: {
            type: "kyc_approved",
            userId,
          },
        });
      } catch (err) {
        console.warn(`Trigger FCM failed for ${userId}:`, err);
      }
      // Idempotent sequential Member ID assignment — handles admin console edits
      // that bypass the reviewCustomerVerification callable.
      try {
        await _assignSequentialId(userId, "customer");
      } catch (err) {
        console.warn(`Trigger sequential ID assignment failed for ${userId}:`, err);
      }
    } else if (afterStatus === "rejected") {
      const reason = after.kycRejectionReason || "Verification not approved";
      try {
        await admin.messaging().send({
          topic: `user_${userId}`,
          notification: {
            title: "Verification Update ⚠️",
            body: "Verification update required. Please check your profile for details.",
          },
          data: {
            type: "kyc_rejected",
            userId,
            reason,
          },
        });
      } catch (err) {
        console.warn(`Trigger FCM failed for ${userId}:`, err);
      }
    }
  }
);

/**
 * Trigger: onDriverVerificationUpdated
 *
 * Catches direct Firestore updates on drivers/{driverId}.
 */
export const onDriverVerificationUpdated = onDocumentUpdated(
  "drivers/{driverId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    const beforeStatus = before.verificationStatus;
    const afterStatus = after.verificationStatus;

    if (beforeStatus === afterStatus) return;

    const driverId = event.params.driverId;

    if (afterStatus === "approved" || afterStatus === "verified") {
      try {
        const userRecord = await admin.auth().getUser(driverId);
        if (!userRecord.customClaims?.isVerified) {
          await admin.auth().setCustomUserClaims(driverId, {
            ...(userRecord.customClaims || {}),
            isVerified: true,
          });
        }
      } catch (err) {
        console.warn(`Trigger failed setting claim on driver ${driverId}:`, err);
      }
      // Approval announcement: driver account verification completed.
      try {
        await admin.messaging().send({
          topic: `driver_${driverId}`,
          notification: {
            title: "Account Verified ✅",
            body: "Your driver verification has been approved.",
          },
          android: {
            priority: "high",
            notification: { sound: "sese_alert_chime" },
          },
          apns: { payload: { aps: { sound: "default" } } },
          data: {
            type: "driver_approved",
            driverId,
          },
        });
      } catch (err) {
        console.warn(`Trigger FCM failed for driver ${driverId}:`, err);
      }
      // Idempotent sequential Driver ID assignment — handles admin console edits
      // that bypass the reviewDriverVerification callable.
      try {
        await _assignSequentialId(driverId, "driver");
      } catch (err) {
        console.warn(`Trigger sequential ID assignment failed for driver ${driverId}:`, err);
      }
    } else if (afterStatus === "rejected") {
      const reason = after.profileRejectionReason || "Profile not approved";
      try {
        await admin.messaging().send({
          topic: `driver_${driverId}`,
          notification: {
            title: "Verification Update ⚠️",
            body: "Verification update required. Please check your profile for details.",
          },
          data: {
            type: "driver_rejected",
            driverId,
            reason,
          },
        });
      } catch (err) {
        console.warn(`Trigger FCM failed for driver ${driverId}:`, err);
      }
    }
  }
);

/**
 * Trigger: onDriverVehicleVerified
 *
 * Catches hub fleet-desk transitions on
 * `drivers/{driverId}/vehicles/{vehicleId}` and announces the outcome to
 * the driver (high-priority audible push). Approval unblocks online
 * dispatch for that vehicle.
 */
export const onDriverVehicleVerified = onDocumentUpdated(
  "drivers/{driverId}/vehicles/{vehicleId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;
    const beforeStatus = String(
      before.verificationStatus ?? before.status ?? ""
    ).toUpperCase();
    const afterStatus = String(
      after.verificationStatus ?? after.status ?? ""
    ).toUpperCase();
    if (beforeStatus === afterStatus) return;

    const driverId = event.params.driverId;
    const vehicleId = event.params.vehicleId;
    const label = [after.make, after.model, after.year]
      .filter(Boolean)
      .join(" ")
      .trim();
    const title =
      afterStatus === "APPROVED" || afterStatus === "VERIFIED"
        ? "Vehicle Verified ✅"
        : afterStatus === "REJECTED"
          ? "Vehicle Update ⚠️"
          : "Vehicle Update";
    const body =
      afterStatus === "APPROVED" || afterStatus === "VERIFIED"
        ? `${label || "Your vehicle"} is verified — you can go online with it.`
        : afterStatus === "REJECTED"
          ? `${label || "Your vehicle"} needs attention: ${after.rejectionReason || "check documents and resubmit."}`
          : `Vehicle status changed to ${afterStatus}.`;
    try {
      await admin.messaging().send({
        topic: `driver_${driverId}`,
        notification: { title, body },
        android: {
          priority: "high",
          notification: { sound: "sese_alert_chime" },
        },
        apns: { payload: { aps: { sound: "default" } } },
        data: {
          type: "vehicle_verification",
          driverId,
          vehicleId,
          status: afterStatus,
        },
      });
    } catch (err) {
      console.warn(`Vehicle FCM failed for driver ${driverId}:`, err);
    }
  }
);
