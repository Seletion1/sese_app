import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onDocumentCreated, onDocumentUpdated } from "firebase-functions/v2/firestore";

const db = () => admin.firestore();

// ─── Referral Code Generation ────────────────────────────────────────────────

/**
 * Deterministically generates a unique referral code for a newly-verified
 * user or driver and persists it atomically to both the profile document and
 * the `referral_codes/{CODE}` lookup index.
 *
 * Format Rule: FirstInitial + LastInitial + last-4-digits-of-phone (uppercase).
 * Collision Handling: Incrementally appends counter (MB1592, MB15921, MB15922, ...)
 * until a unique referral ID is secured.
 *
 * The function is idempotent: if the profile already has a `referralCode` it
 * returns immediately without writing anything.
 *
 * @param userId  - Firestore document ID (uid)
 * @param collection - "users" | "drivers"
 */
async function _generateAndSaveReferralCode(
  userId: string,
  collection: "users" | "drivers"
): Promise<void> {
  const firestore = db();
  const profileRef = firestore.collection(collection).doc(userId);

  // ── Idempotency check ──────────────────────────────────────────────────────
  const profileSnap = await profileRef.get();
  if (!profileSnap.exists) {
    console.warn(
      `_generateAndSaveReferralCode: ${collection}/${userId} not found, skipping.`
    );
    return;
  }
  const profileData = profileSnap.data() ?? {};
  if (profileData.referralCode) {
    // Code already exists — nothing to do.
    return;
  }

  // ── Format Rule: First Initial + Last Initial + Last 4 phone digits ────────
  const fullName = String(profileData.fullName ?? profileData.displayName ?? "").trim();
  const firstName = String(profileData.firstName ?? "").trim();
  const lastName = String(profileData.lastName ?? "").trim();

  let fInitial = "X";
  let lInitial = "X";

  if (firstName.length > 0) {
    fInitial = (firstName.match(/[A-Za-z]/)?.[0] ?? "X").toUpperCase();
    lInitial = lastName.length > 0 ? (lastName.match(/[A-Za-z]/)?.[0] ?? fInitial).toUpperCase() : fInitial;
  } else if (fullName.length > 0) {
    const parts = fullName.split(/\s+/).filter(Boolean);
    if (parts.length === 1) {
      fInitial = (parts[0].match(/[A-Za-z]/)?.[0] ?? "X").toUpperCase();
      lInitial = fInitial;
    } else if (parts.length > 1) {
      fInitial = (parts[0].match(/[A-Za-z]/)?.[0] ?? "X").toUpperCase();
      lInitial = (parts[parts.length - 1].match(/[A-Za-z]/)?.[0] ?? fInitial).toUpperCase();
    }
  }

  const initials = (fInitial + lInitial).toUpperCase();

  const rawPhone = String(profileData.phoneNumber ?? "");
  const digits = rawPhone.replace(/\D/g, ""); // strip non-numeric chars
  const last4 = digits.length >= 4 ? digits.slice(-4) : digits.padStart(4, "0");

  const baseCode = (initials + last4).toUpperCase();

  let resolved = false;

  // ── Collision Handling: Incrementally append counter 0, 1, 2, 3... ────────
  for (let counter = 0; counter < 50; counter++) {
    const candidate = counter === 0 ? baseCode : `${baseCode}${counter}`;

    try {
      resolved = await firestore.runTransaction(async (tx) => {
        const codeRef = firestore.collection("referral_codes").doc(candidate);
        const codeSnap = await tx.get(codeRef);

        if (!codeSnap.exists) {
          tx.set(codeRef, {
            referrerId: userId,
            collection,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
          tx.update(profileRef, { referralCode: candidate });
          return true;
        }

        if (codeSnap.data()?.referrerId === userId) {
          tx.update(profileRef, { referralCode: candidate });
          return true;
        }

        return false;
      });
    } catch (err) {
      console.warn(
        `_generateAndSaveReferralCode: transaction error for ${candidate}:`,
        err
      );
    }

    if (resolved) break;
  }

  if (!resolved) {
    console.error(
      `_generateAndSaveReferralCode: exhausted candidate attempts for ${collection}/${userId}.`
    );
  }
}

/**
 * Trigger: onUserCreated
 *
 * Runs upon user registration document creation in users/{userId}.
 */
export const onUserCreated = onDocumentCreated(
  "users/{userId}",
  async (event) => {
    const userId = event.params.userId;
    try {
      await _generateAndSaveReferralCode(userId, "users");
    } catch (err) {
      console.warn(`onUserCreated referral code generation failed for ${userId}:`, err);
    }
  }
);

/**
 * Trigger: onDriverCreated
 *
 * Runs upon driver registration document creation in drivers/{driverId}.
 */
export const onDriverCreated = onDocumentCreated(
  "drivers/{driverId}",
  async (event) => {
    const driverId = event.params.driverId;
    try {
      await _generateAndSaveReferralCode(driverId, "drivers");
    } catch (err) {
      console.warn(`onDriverCreated referral code generation failed for ${driverId}:`, err);
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

/**
 * Callable: reviewCustomerVerification
 *
 * Hub admins call this to approve or reject customer KYC verification.
 * Approving sets verificationStatus = 'verified' and custom claim isVerified = true.
 * Rejecting stores a structured rejection reason and sends an FCM push notification.
 */
export const reviewCustomerVerification = onCall<ReviewCustomerData>(
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required.");
    }

    const { userId, approved, rejectionReason } = request.data ?? {};
    if (!userId) {
      throw new HttpsError("invalid-argument", "userId is required.");
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

      // Generate referral code now that the user is verified.
      // Wrapped in try/catch — a code generation failure must never
      // roll back a successfully-completed verification approval.
      try {
        await _generateAndSaveReferralCode(userId, "users");
      } catch (err) {
        console.warn(`Referral code generation failed for user ${userId}:`, err);
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
export const reviewDriverVerification = onCall<ReviewDriverData>(
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required.");
    }

    const { driverId, approved, rejectionReason } = request.data ?? {};
    if (!driverId) {
      throw new HttpsError("invalid-argument", "driverId is required.");
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

      // Generate referral code now that the driver is verified.
      try {
        await _generateAndSaveReferralCode(driverId, "drivers");
      } catch (err) {
        console.warn(`Referral code generation failed for driver ${driverId}:`, err);
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
      // Idempotent referral code generation — handles admin console edits
      // that bypass the reviewCustomerVerification callable.
      try {
        await _generateAndSaveReferralCode(userId, "users");
      } catch (err) {
        console.warn(`Trigger referral code generation failed for ${userId}:`, err);
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
      // Idempotent referral code generation — handles admin console edits
      // that bypass the reviewDriverVerification callable.
      try {
        await _generateAndSaveReferralCode(driverId, "drivers");
      } catch (err) {
        console.warn(`Trigger referral code generation failed for driver ${driverId}:`, err);
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
