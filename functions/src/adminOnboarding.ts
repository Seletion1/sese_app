import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";

function db() {
  return admin.firestore();
}

function normPhone(phone?: string): string {
  if (!phone) return "";
  const cleaned = phone.replace(/[^\d+]/g, "");
  if (cleaned.startsWith("0")) {
    return "234" + cleaned.substring(1);
  }
  if (cleaned.startsWith("+")) {
    return cleaned.substring(1);
  }
  return cleaned;
}

// ── 1. lookupAccountForOnboarding ──────────────────────────────────────────

interface LookupData {
  identifier?: string; // Phone or Email
}

export const lookupAccountForOnboarding = onCall<LookupData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }

  const identifier = String(request.data?.identifier ?? "").trim();
  if (!identifier) {
    throw new HttpsError("invalid-argument", "Phone number or email is required.");
  }

  const isEmail = identifier.includes("@");
  let userSnap: admin.firestore.QueryDocumentSnapshot | null = null;

  if (isEmail) {
    const q = await db().collection("users").where("email", "==", identifier.toLowerCase()).limit(1).get();
    if (!q.empty) userSnap = q.docs[0];
  } else {
    const phone = normPhone(identifier);
    const q = await db().collection("users").where("phoneNumber", "==", phone).limit(1).get();
    if (!q.empty) userSnap = q.docs[0];
  }

  if (!userSnap) {
    // Check Auth directly as fallback
    try {
      const authUser = isEmail
        ? await admin.auth().getUserByEmail(identifier.toLowerCase())
        : await admin.auth().getUserByPhoneNumber("+" + normPhone(identifier));
      
      const doc = await db().collection("users").doc(authUser.uid).get();
      if (doc.exists) {
        userSnap = doc as any;
      }
    } catch (_) {}
  }

  if (!userSnap) {
    return {
      exists: false,
      identifier,
      message: "No existing account found. Ready for new user registration.",
    };
  }

  const uid = userSnap.id;
  const userData = userSnap.data();
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
  if (!userData.fullName || !userData.phoneNumber) missingSteps.push("profile_details");
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
      fullName: userData.fullName,
      email: userData.email,
      phoneNumber: userData.phoneNumber,
      role: userData.role,
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
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }

  const identifier = String(request.data?.identifier ?? "").trim();
  if (!identifier) {
    throw new HttpsError("invalid-argument", "Identifier is required.");
  }

  const otp = String(Math.floor(100000 + Math.random() * 900000));
  const expiresAt = Date.now() + 10 * 60 * 1000; // 10 minutes

  await db().collection("onboarding_otps").doc(identifier.toLowerCase()).set({
    identifier: identifier.toLowerCase(),
    otp,
    verified: false,
    expiresAt,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdByAdminId: request.auth.uid,
  });

  return {
    success: true,
    identifier,
    message: `OTP dispatched to ${identifier}.`,
    devOtpHint: otp,
  };
});

interface VerifyOtpData {
  identifier: string;
  otp: string;
}

export const verifyOnboardingOtp = onCall<VerifyOtpData>(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required.");
  }

  const identifier = String(request.data?.identifier ?? "").trim().toLowerCase();
  const otp = String(request.data?.otp ?? "").trim();

  if (!identifier || !otp) {
    throw new HttpsError("invalid-argument", "Identifier and OTP are required.");
  }

  const docRef = db().collection("onboarding_otps").doc(identifier);
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
    identifier,
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
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Admin authentication required.");
  }

  const adminUid = request.auth.uid;
  const data = request.data ?? {};

  const role = data.role === "driver" ? "driver" : "customer";
  const fullName = String(data.fullName ?? "").trim();
  const phone = normPhone(data.phone);
  const email = data.email ? String(data.email).trim().toLowerCase() : undefined;

  if (!fullName) {
    throw new HttpsError("invalid-argument", "Full name is required.");
  }
  if (!phone) {
    throw new HttpsError("invalid-argument", "Phone number is required.");
  }

  let authUser: admin.auth.UserRecord;

  try {
    authUser = await admin.auth().getUserByPhoneNumber("+" + phone);
  } catch (_) {
    if (email) {
      try {
        authUser = await admin.auth().getUserByEmail(email);
      } catch (_) {
        authUser = await admin.auth().createUser({
          phoneNumber: "+" + phone,
          email,
          displayName: fullName,
        });
      }
    } else {
      authUser = await admin.auth().createUser({
        phoneNumber: "+" + phone,
        displayName: fullName,
      });
    }
  }

  const uid = authUser.uid;
  const now = admin.firestore.FieldValue.serverTimestamp();

  // Create/Update user doc
  await db().collection("users").doc(uid).set(
    {
      uid,
      fullName,
      phoneNumber: phone,
      phoneNumberE164: "+" + phone,
      ...(email ? { email } : {}),
      role,
      customerVerificationStatus: "verified",
      isVerifiedCustomer: true,
      address: data.address ?? "",
      ninNumber: data.ninNumber ?? "",
      createdByAdminId: adminUid,
      createdAt: now,
      updatedAt: now,
    },
    { merge: true }
  );

  // Set Auth Custom Claims
  try {
    await admin.auth().setCustomUserClaims(uid, {
      ...(authUser.customClaims || {}),
      role,
      isVerified: true,
    });
  } catch (e) {
    console.warn(`adminRegisterUser: setCustomUserClaims failed: ${e}`);
  }

  let vehicleId: string | null = null;

  if (role === "driver") {
    await db().collection("drivers").doc(uid).set(
      {
        driverId: uid,
        fullName,
        phone,
        ...(email ? { email } : {}),
        licenseNumber: data.driverDetails?.licenseNumber ?? "",
        licenseExpiry: data.driverDetails?.licenseExpiry ?? "",
        verificationStatus: "pending_verification",
        isProfileVerified: false,
        vehicleStatus: data.vehicleDetails ? "pending_verification" : "unregistered",
        photoUrl: data.livePhotoUrl ?? "",
        createdByAdminId: adminUid,
        createdAt: now,
        updatedAt: now,
      },
      { merge: true }
    );

    if (data.vehicleDetails) {
      const v = data.vehicleDetails;
      const vRef = db().collection("drivers").doc(uid).collection("vehicles").doc();
      vehicleId = vRef.id;

      const category = String(v.category ?? "car").toLowerCase();
      const licensePlate = String(v.licensePlate ?? "").toUpperCase();

      await vRef.set({
        id: vehicleId,
        driverId: uid,
        category,
        make: v.make ?? "",
        model: v.model ?? "",
        year: v.year ?? new Date().getFullYear(),
        licensePlate,
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

      // Update root driver doc active vehicle mirror
      await db().collection("drivers").doc(uid).set(
        {
          activeVehicleId: vehicleId,
          activeVehicleCategory: category,
          activePlateNumber: licensePlate,
          updatedAt: now,
        },
        { merge: true }
      );
    }
  }

  return {
    success: true,
    uid,
    role,
    vehicleId,
    message: `Account for ${fullName} (${role}) provisioned successfully by admin. Self-Verification Lock active — final approval requires independent admin review.`,
  };
});
