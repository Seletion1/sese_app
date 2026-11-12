import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import {
  assertAndReserveIdentifiersTx,
  normalizeIdentifier,
  IdentifierEntry,
} from "./uniqueIdentifiers";
import { isPlatformOwnerEmail } from "./hubBootstrap";

function db() {
  return admin.firestore();
}

/**
 * Asserts that the caller is authenticated as a staff member or administrator
 * with authority to manage users (or holding Super/Admin status or user_onboarding scope).
 */
async function assertStaffWithManageUsersScope(
  auth: { uid: string; token: Record<string, unknown> } | undefined
): Promise<void> {
  if (!auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }

  const token = auth.token ?? {};
  const email = String(token.email ?? "").trim().toLowerCase();

  // Fast path 1: Primary owner email
  if (isPlatformOwnerEmail(email)) return;

  // Fast path 2: Custom claims indicating Super Admin / Admin
  const claimRole = String(token.role ?? token.adminRole ?? "").toUpperCase();
  const isSuperOrAdminClaim =
    token.admin === true ||
    token.adminAuth === true ||
    claimRole === "SUPER_ADMIN" ||
    claimRole === "ROLE_SUPER_ADMIN" ||
    claimRole === "SUPER" ||
    claimRole === "ADMIN";

  if (isSuperOrAdminClaim) return;

  // Database lookup in hub_staff/{email}
  if (email) {
    try {
      const snap = await db().collection("hub_staff").doc(email).get();
      if (snap.exists) {
        const data = snap.data();
        if (data?.active !== false) {
          const staffRole = String(data?.role ?? "").toUpperCase();
          if (staffRole === "SUPER" || staffRole === "ADMIN" || staffRole === "SUPER_ADMIN") {
            return;
          }
          const perms: unknown = data?.assignedPermissions;
          const grants = Array.isArray(perms)
            ? perms.map((p) => String(p).toLowerCase())
            : [];
          if (
            grants.includes("manageusers") ||
            grants.includes("manage_users") ||
            grants.includes("user_onboarding") ||
            grants.includes("staff_manage")
          ) {
            return;
          }
        }
      }
    } catch (e) {
      console.error(`assertStaffWithManageUsersScope: hub_staff lookup failed for ${email}:`, e);
    }
  }

  throw new HttpsError(
    "permission-denied",
    "Only Hub staff members or administrators with user management scope can perform onboarding actions."
  );
}

// ── 1. lookupAccountForOnboarding ──────────────────────────────────────────

interface LookupData {
  identifier?: string; // Phone or Email
}

export const lookupAccountForOnboarding = onCall<LookupData>(async (request) => {
  await assertStaffWithManageUsersScope(request.auth as any);

  const identifier = String(request.data?.identifier ?? "").trim();
  if (!identifier) {
    throw new HttpsError("invalid-argument", "Phone number or email is required.");
  }

  const isEmail = identifier.includes("@");
  let userSnap: admin.firestore.QueryDocumentSnapshot | null = null;
  let authUser: admin.auth.UserRecord | null = null;

  if (isEmail) {
    const normEmail = normalizeIdentifier("email", identifier);
    const q = await db().collection("users").where("email", "==", normEmail).limit(1).get();
    if (!q.empty) {
      userSnap = q.docs[0];
    } else {
      // Fallback search with raw identifier
      const qRaw = await db().collection("users").where("email", "==", identifier.toLowerCase()).limit(1).get();
      if (!qRaw.empty) userSnap = qRaw.docs[0];
    }
  } else {
    const normPhoneStr = normalizeIdentifier("phone", identifier);
    const barePhone = normPhoneStr.replace("+", "");

    // Query across E.164, raw, and alternate phone fields
    const q1 = await db().collection("users").where("phoneNumber", "==", normPhoneStr).limit(1).get();
    if (!q1.empty) {
      userSnap = q1.docs[0];
    } else {
      const q2 = await db().collection("users").where("phoneNumberE164", "==", normPhoneStr).limit(1).get();
      if (!q2.empty) {
        userSnap = q2.docs[0];
      } else {
        const q3 = await db().collection("users").where("phone", "==", normPhoneStr).limit(1).get();
        if (!q3.empty) {
          userSnap = q3.docs[0];
        } else {
          const q4 = await db().collection("users").where("phoneNumber", "==", barePhone).limit(1).get();
          if (!q4.empty) userSnap = q4.docs[0];
        }
      }
    }
  }

  if (!userSnap) {
    // Check Auth directly as fallback for incomplete registrations
    try {
      if (isEmail) {
        const normEmail = normalizeIdentifier("email", identifier);
        authUser = await admin.auth().getUserByEmail(normEmail);
      } else {
        const normPhoneStr = normalizeIdentifier("phone", identifier);
        authUser = await admin.auth().getUserByPhoneNumber(normPhoneStr);
      }

      if (authUser) {
        const doc = await db().collection("users").doc(authUser.uid).get();
        if (doc.exists) {
          userSnap = doc as any;
        }
      }
    } catch (_) {}
  }

  if (!userSnap && !authUser) {
    return {
      exists: false,
      identifier,
      message: "No existing account found. Ready for new user registration.",
    };
  }

  const uid = userSnap ? userSnap.id : authUser!.uid;
  const userData = userSnap
    ? userSnap.data()
    : {
        uid: authUser!.uid,
        fullName: authUser!.displayName || "",
        email: authUser!.email || "",
        phoneNumber: authUser!.phoneNumber || "",
        role: (authUser!.customClaims?.role as string) || "customer",
        customerVerificationStatus: "pending",
      };

  const role = String(userData.role ?? "customer");

  let driverData: Record<string, unknown> | null = null;
  let vehicleCount = 0;

  if (role === "driver" || role === "both") {
    const dSnap = await db().collection("drivers").doc(uid).get();
    if (dSnap.exists) {
      driverData = dSnap.data()!;
    }
    const vSnap = await db().collection("drivers").doc(uid).collection("vehicles").get();
    vehicleCount = vSnap.size;
  }

  const missingSteps: string[] = [];
  if (!userData.fullName || (!userData.phoneNumber && !userData.email)) missingSteps.push("profile_details");
  if ((role === "driver" || role === "both") && vehicleCount === 0) missingSteps.push("vehicle_setup");
  if ((role === "driver" || role === "both") && !driverData?.isProfileVerified) missingSteps.push("verification_approval");

  return {
    exists: true,
    uid,
    role,
    customerVerificationStatus: String(userData.customerVerificationStatus ?? "pending"),
    driverVerificationStatus: driverData ? String(driverData.verificationStatus ?? "pending") : null,
    vehicleCount,
    missingSteps,
    userData: {
      uid,
      fullName: userData.fullName || authUser?.displayName || "",
      email: userData.email || authUser?.email || "",
      phoneNumber: userData.phoneNumber || authUser?.phoneNumber || "",
      role: userData.role || (authUser?.customClaims?.role as string) || "customer",
      createdByAdminId: userData.createdByAdminId ?? null,
    },
    driverData,
  };
});

// ── 2. sendOnboardingOtp & verifyOnboardingOtp ──────────────────────────────

interface SendOtpData {
  identifier: string;
}

export const sendOnboardingOtp = onCall<SendOtpData>(async (request) => {
  await assertStaffWithManageUsersScope(request.auth as any);

  const rawIdentifier = String(request.data?.identifier ?? "").trim();
  if (!rawIdentifier) {
    throw new HttpsError("invalid-argument", "Identifier is required.");
  }

  const isEmail = rawIdentifier.includes("@");
  const normalizedIdentifier = isEmail
    ? normalizeIdentifier("email", rawIdentifier)
    : normalizeIdentifier("phone", rawIdentifier);

  const otp = String(Math.floor(100000 + Math.random() * 900000));
  const expiresAt = Date.now() + 10 * 60 * 1000; // 10 minutes

  await db().collection("onboarding_otps").doc(normalizedIdentifier).set({
    identifier: normalizedIdentifier,
    rawIdentifier,
    otp,
    verified: false,
    expiresAt,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdByAdminId: request.auth!.uid,
  });

  console.log(`[sendOnboardingOtp] OTP generated for ${normalizedIdentifier}: ${otp}`);

  const isDev =
    process.env.FUNCTIONS_EMULATOR === "true" ||
    process.env.NODE_ENV !== "production";

  return {
    success: true,
    identifier: normalizedIdentifier,
    devOtpHint: isDev ? otp : undefined,
    message: `OTP dispatched to ${rawIdentifier}.`,
  };
});

interface VerifyOtpData {
  identifier: string;
  otp: string;
}

export const verifyOnboardingOtp = onCall<VerifyOtpData>(async (request) => {
  await assertStaffWithManageUsersScope(request.auth as any);

  const rawIdentifier = String(request.data?.identifier ?? "").trim();
  const otp = String(request.data?.otp ?? "").trim();

  if (!rawIdentifier || !otp) {
    throw new HttpsError("invalid-argument", "Identifier and OTP are required.");
  }

  const isEmail = rawIdentifier.includes("@");
  const normalizedIdentifier = isEmail
    ? normalizeIdentifier("email", rawIdentifier)
    : normalizeIdentifier("phone", rawIdentifier);

  const docRef = db().collection("onboarding_otps").doc(normalizedIdentifier);
  const snap = await docRef.get();

  if (!snap.exists) {
    throw new HttpsError("not-found", "No OTP record found. Please request a new code.");
  }

  const data = snap.data()!;
  if (data.expiresAt < Date.now()) {
    throw new HttpsError("deadline-exceeded", "OTP has expired. Please request a new code.");
  }

  if (String(data.otp) !== otp) {
    throw new HttpsError("invalid-argument", "Incorrect OTP code.");
  }

  await docRef.update({
    verified: true,
    verifiedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return {
    success: true,
    verified: true,
    identifier: normalizedIdentifier,
    message: "OTP verified successfully.",
  };
});

// ── 3. adminRegisterUser ───────────────────────────────────────────────────

interface AdminRegisterUserData {
  role: "customer" | "driver";
  fullName: string;
  email?: string;
  phone: string;
  address?: string;
  ninNumber?: string;
  driverDetails?: {
    licenseNumber?: string;
    licenseExpiry?: string;
  };
  vehicleDetails?: {
    category: string;
    make: string;
    model: string;
    year: number;
    licensePlate: string;
    color: string;
    tier?: string;
  };
  documents?: {
    driverLicenseUrl?: string;
    vehicleInspectionUrl?: string;
    vehicleInsuranceUrl?: string;
    roadworthinessUrl?: string;
  };
  livePhotoUrl?: string;
}

export const adminRegisterUser = onCall<AdminRegisterUserData>(async (request) => {
  await assertStaffWithManageUsersScope(request.auth as any);

  const adminUid = request.auth!.uid;
  const data = request.data ?? {};

  const role = data.role === "driver" ? "driver" : "customer";
  const fullName = String(data.fullName ?? "").trim();
  const rawPhone = String(data.phone ?? "").trim();
  const rawEmail = data.email ? String(data.email).trim().toLowerCase() : undefined;

  if (!fullName) {
    throw new HttpsError("invalid-argument", "Full name is required.");
  }
  if (!rawPhone) {
    throw new HttpsError("invalid-argument", "Phone number is required.");
  }

  const normPhoneStr = normalizeIdentifier("phone", rawPhone);
  const normEmailStr = rawEmail ? normalizeIdentifier("email", rawEmail) : "";
  const normNinStr = data.ninNumber ? normalizeIdentifier("nin", data.ninNumber) : "";
  const normPlateStr = data.vehicleDetails?.licensePlate
    ? normalizeIdentifier("plate_number", data.vehicleDetails.licensePlate)
    : "";

  // Verify OTP verification status unless in dev/emulator mode
  const isDev =
    process.env.FUNCTIONS_EMULATOR === "true" ||
    process.env.NODE_ENV !== "production";

  if (!isDev) {
    const phoneOtpSnap = await db().collection("onboarding_otps").doc(normPhoneStr).get();
    const emailOtpSnap = normEmailStr
      ? await db().collection("onboarding_otps").doc(normEmailStr).get()
      : null;

    const phoneVerified = phoneOtpSnap.exists && phoneOtpSnap.data()?.verified === true;
    const emailVerified =
      emailOtpSnap && emailOtpSnap.exists && emailOtpSnap.data()?.verified === true;

    if (!phoneVerified && !emailVerified) {
      throw new HttpsError(
        "failed-precondition",
        "Phone or email must be verified via OTP before registration can be finalized."
      );
    }
  }

  let authUser: admin.auth.UserRecord;

  try {
    authUser = await admin.auth().getUserByPhoneNumber(normPhoneStr);
  } catch (_) {
    if (normEmailStr) {
      try {
        authUser = await admin.auth().getUserByEmail(normEmailStr);
      } catch (_) {
        authUser = await admin.auth().createUser({
          phoneNumber: normPhoneStr,
          email: normEmailStr,
          displayName: fullName,
        });
      }
    } else {
      authUser = await admin.auth().createUser({
        phoneNumber: normPhoneStr,
        displayName: fullName,
      });
    }
  }

  const uid = authUser.uid;
  let vehicleId: string | null = null;
  if (role === "driver" && data.vehicleDetails) {
    vehicleId = db().collection("drivers").doc(uid).collection("vehicles").doc().id;
  }

  await db().runTransaction(async (tx) => {
    // 1. ALL READS: read user doc and uniqueness docs
    const userRef = db().collection("users").doc(uid);
    const userSnap = await tx.get(userRef);

    const oldIdentifiers: IdentifierEntry[] = [];
    if (userSnap.exists) {
      const old = userSnap.data() ?? {};
      if (old.phoneNumber) oldIdentifiers.push({ type: "phone", value: old.phoneNumber });
      if (old.email) oldIdentifiers.push({ type: "email", value: old.email });
      if (old.ninNumber) oldIdentifiers.push({ type: "nin", value: old.ninNumber });
    }

    const identifiers: IdentifierEntry[] = [
      { type: "phone", value: normPhoneStr },
    ];
    if (normEmailStr) {
      identifiers.push({ type: "email", value: normEmailStr });
    }
    if (normNinStr) {
      identifiers.push({ type: "nin", value: normNinStr });
    }
    if (normPlateStr && vehicleId) {
      identifiers.push({ type: "plate_number", value: normPlateStr, entityId: vehicleId });
    }

    // Atomic uniqueness verification & reservation
    await assertAndReserveIdentifiersTx({
      tx,
      ownerUid: uid,
      ownerCollection: "users",
      identifiers,
      oldIdentifiers,
    });

    const now = admin.firestore.FieldValue.serverTimestamp();

    // 2. ALL WRITES: user doc, driver doc, vehicle doc
    tx.set(
      userRef,
      {
        uid,
        fullName,
        phoneNumber: normPhoneStr,
        phoneNumberE164: normPhoneStr,
        ...(normEmailStr ? { email: normEmailStr } : {}),
        role,
        customerVerificationStatus: "pending",
        isVerifiedCustomer: false,
        address: data.address ?? "",
        ...(normNinStr ? { ninNumber: normNinStr } : {}),
        createdByAdminId: adminUid,
        createdAt: userSnap.exists ? (userSnap.data()?.createdAt ?? now) : now,
        updatedAt: now,
      },
      { merge: true }
    );

    if (role === "driver") {
      const driverRef = db().collection("drivers").doc(uid);
      const dSnap = await tx.get(driverRef);

      tx.set(
        driverRef,
        {
          driverId: uid,
          fullName,
          phone: normPhoneStr,
          ...(normEmailStr ? { email: normEmailStr } : {}),
          licenseNumber: data.driverDetails?.licenseNumber ?? "",
          licenseExpiry: data.driverDetails?.licenseExpiry ?? "",
          verificationStatus: "pending_verification",
          isProfileVerified: false,
          vehicleStatus: data.vehicleDetails ? "pending_verification" : "unregistered",
          photoUrl: data.livePhotoUrl ?? "",
          createdByAdminId: adminUid,
          createdAt: dSnap.exists ? (dSnap.data()?.createdAt ?? now) : now,
          updatedAt: now,
        },
        { merge: true }
      );

      if (data.vehicleDetails && vehicleId) {
        const v = data.vehicleDetails;
        const vRef = db().collection("drivers").doc(uid).collection("vehicles").doc(vehicleId);
        const category = String(v.category ?? "car").toLowerCase();

        tx.set(vRef, {
          id: vehicleId,
          driverId: uid,
          category,
          make: v.make ?? "",
          model: v.model ?? "",
          year: v.year ?? new Date().getFullYear(),
          licensePlate: normPlateStr,
          color: v.color ?? "",
          tier: v.tier ?? null,
          verificationStatus: "PENDING",
          lifecycleStatus: "ACTIVE",
          isActiveSelected: true,
          documents: data.documents ?? {},
          createdByAdminId: adminUid,
          createdAt: now,
          updatedAt: now,
        });

        tx.set(
          driverRef,
          {
            activeVehicleId: vehicleId,
            activeVehicleCategory: category,
            activePlateNumber: normPlateStr,
            updatedAt: now,
          },
          { merge: true }
        );
      }
    }
  });

  // Set Auth Custom Claims
  try {
    await admin.auth().setCustomUserClaims(uid, {
      ...(authUser.customClaims || {}),
      role,
      isVerified: false,
    });
  } catch (e) {
    console.warn(`adminRegisterUser: setCustomUserClaims failed: ${e}`);
  }

  return {
    success: true,
    uid,
    role,
    vehicleId,
    message: `Account for ${fullName} (${role}) provisioned successfully by admin. Self-Verification Lock active — final approval requires independent admin review.`,
  };
});
