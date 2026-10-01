/// Shared verification constants for the driver onboarding pipeline and
/// customer profile verification, used by sese_ride and sese_hub.
///
/// Driver lifecycle on `drivers/{driverId}`:
/// - `pending_onboarding` — account created, Step 2 personal-info form not
///   yet submitted. AuthGate routes these drivers to the onboarding screen.
/// - `pending` — Step 2 submitted, awaiting sese_hub manual document audit.
///   Drivers land on Driver Home with a persistent pending banner and may
///   still register vehicles (non-blocking).
/// - `approved` — hub approved the profile (`isProfileVerified == true`).
///
/// A driver may only switch Online when BOTH `isProfileVerified == true`
/// AND `isVehicleVerified == true` (hub toggles both after document audit).
abstract final class DriverVerification {
  static const String pendingOnboarding = 'pending_onboarding';
  static const String pending = 'pending';
  static const String approved = 'approved';
  static const String rejected = 'rejected';

  static const String fieldStatus = 'verificationStatus';
  static const String fieldProfileVerified = 'isProfileVerified';
  static const String fieldVehicleVerified = 'isVehicleVerified';
  static const String fieldCanGoOnline = 'canGoOnline';
}

/// Customer profile verification lifecycle on `users/{uid}`.
///
/// Lifecycle:
/// - `unverified` (default) — the KYC banner invites submission.
/// - `pending_review` — full KYC form submitted; awaiting sese_hub approval.
///   Submission button is disabled. A "Pending" banner is shown in-app.
/// - `verified` — hub approved; ride requests carry `isVerifiedCustomer: true`
///   and drivers see the gold [Verified Customer] badge. Sensitive fields are
///   locked (read-only) in the Profile Details screen.
/// - `rejected` — hub rejected the submission; the rejection reason stored in
///   `kycRejectionReason` is shown in-app with an "Edit & Re-submit" option.
abstract final class CustomerVerification {
  static const String unverified = 'unverified';

  /// @deprecated Use [pendingReview]. Kept for backward compat.
  static const String pending = 'pending';

  static const String pendingReview = 'pending_review';
  static const String verified = 'verified';
  static const String rejected = 'rejected';

  static const String fieldStatus = 'customerVerificationStatus';
  static const String fieldIsVerified = 'isVerifiedCustomer';

  /// Firestore field holding the hub admin's rejection reason string.
  static const String fieldRejectionReason = 'kycRejectionReason';

  /// Firestore field holding the nested KYC payload map.
  static const String fieldKycData = 'kycData';

  /// Returns true when the status indicates an active pending state
  /// (including the legacy `pending` value for backwards compatibility).
  static bool isPending(String status) =>
      status == pendingReview || status == pending;

  /// Returns true when the user's profile is fully verified and fields
  /// should be locked against editing.
  static bool isVerified(String status) => status == verified;

  /// Returns true when submission should be prevented (pending or verified).
  static bool isSubmitBlocked(String status) =>
      isPending(status) || isVerified(status);
}
