/// Unified Member ID & Referral Code validation for the SeSe platform.
///
/// Separate referral code generators have been removed. A user's official
/// verified Member ID (`SC0001` for customers, `SD0001` for drivers,
/// `SH0001` for hub staff, `SA0001` for agents) serves as their sole referral code.
library;

/// Normalises user-entered Member ID / referral codes (trim + uppercase).
String normalizeReferralCode(String input) => input.trim().toUpperCase();

/// True when [code] matches an official verified Member ID shape:
/// `SC`, `SD`, `SH`, or `SA` prefix followed by 4 or more digits
/// (e.g. `SC0001`, `SD0001`, `SH0001`, `SA0001`, `SC10000`).
bool isPlausibleReferralCode(String code) {
  return RegExp(r'^(SC|SD|SH|SA)\d{4,}$')
      .hasMatch(normalizeReferralCode(code));
}
