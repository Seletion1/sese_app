import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";

/** Primary platform owners with inherent super admin bootstrap authority. */
export const PRIMARY_OWNER_EMAILS = [
  "bamiduromichael2@gmail.com",
  "bamiduromichael1@gmail.com",
];

const envOwner = (process.env.OWNER_EMAIL ?? "").trim().toLowerCase();
if (envOwner && !PRIMARY_OWNER_EMAILS.includes(envOwner)) {
  PRIMARY_OWNER_EMAILS.push(envOwner);
}

/** Check if an email is a recognized primary owner email. */
export function isPlatformOwnerEmail(email?: string | null): boolean {
  if (!email) return false;
  const clean = email.trim().toLowerCase();
  return PRIMARY_OWNER_EMAILS.includes(clean);
}

/**
 * Callable function: Bootstraps the primary owner's account.
 * - Mints `SUPER_ADMIN` custom claims on Firebase Auth
 * - Persists or updates the owner's `hub_staff/{email}` record with all permissions
 * Restricted strictly to the primary owner email.
 */
export const bootstrapHubOwner = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }

  const email = (request.auth.token.email ?? "").trim().toLowerCase();
  if (!isPlatformOwnerEmail(email)) {
    throw new HttpsError(
      "permission-denied",
      "Only the primary platform owner can trigger owner bootstrap."
    );
  }

  const uid = request.auth.uid;
  const db = admin.firestore();

  // 1. Set custom claims on Firebase Auth token
  try {
    const userRecord = await admin.auth().getUser(uid);
    await admin.auth().setCustomUserClaims(uid, {
      ...(userRecord.customClaims || {}),
      role: "SUPER_ADMIN",
      admin: true,
      adminAuth: true,
      broadcast: true,
      isVerified: true,
    });
  } catch (e) {
    console.warn(`bootstrapHubOwner: setCustomUserClaims failed for ${uid}: ${e}`);
  }

  // 2. Ensure hub_staff document exists with full permissions
  const allPermissions = [
    "active_rides",
    "fleet_verify",
    "user_onboarding",
    "dynamic_config",
    "support_chat",
    "process_payouts",
    "broadcast_notifications",
    "staff_manage",
    "edit_fares",
    "suspend_users",
    "p2p_limits",
    "document_review",
  ];

  await db.collection("hub_staff").doc(email).set(
    {
      email,
      role: "Super",
      assignedPermissions: allPermissions,
      countryScope: "global",
      assignedBy: email,
      active: true,
      status: "active",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  return {
    success: true,
    email,
    role: "Super",
    message: `Account ${email} successfully bootstrapped as Platform Super Owner.`,
  };
});
