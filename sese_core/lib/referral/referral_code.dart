/// Deterministic referral code generation for the SeSe platform.
///
/// Algorithm (spec):
///   First letter of First Name (uppercase) +
///   First letter of Surname/Second Name (uppercase) +
///   Last 4 digits of registered phone number.
///
/// Example: "Micheal Bamiduro", "+2348012344321" -> "MB4321".
///
/// Collision handling: [generateReferralCode] is deterministic; callers that
/// need global uniqueness should use [withUniquenessSuffix] or rely on the
/// `referral_codes/{code}` lookup collection (first-writer-wins via the
/// `ensureReferralCode` Cloud Function backfill).
library;

/// Generates a deterministic referral code from display name + phone.
///
/// - [fullName]: e.g. "Micheal Bamiduro". Single-word names reuse the first
///   letter twice (e.g. "Ada" -> "AA").
/// - [phoneNumber]: any format; non-digits are stripped and the last 4 digits
///   are used. When fewer than 4 digits exist, the digits are left-padded
///   with `0` (e.g. "12" -> "0012"); with no digits at all, "0000" is used.
String generateReferralCode({
  required String fullName,
  required String phoneNumber,
}) {
  final parts =
      fullName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();

  String firstInitial = 'X';
  String secondInitial = 'X';
  if (parts.isEmpty) {
    firstInitial = 'X';
    secondInitial = 'X';
  } else if (parts.length == 1) {
    firstInitial = _initialOf(parts.first);
    secondInitial = firstInitial;
  } else {
    firstInitial = _initialOf(parts.first);
    secondInitial = _initialOf(parts.last);
  }

  final digits = phoneNumber.replaceAll(RegExp(r'[^0-9]'), '');
  String last4;
  if (digits.length >= 4) {
    last4 = digits.substring(digits.length - 4);
  } else if (digits.isEmpty) {
    last4 = '0000';
  } else {
    last4 = digits.padLeft(4, '0');
  }

  return '$firstInitial$secondInitial$last4'.toUpperCase();
}

String _initialOf(String word) {
  for (final rune in word.runes) {
    final ch = String.fromCharCode(rune);
    if (RegExp(r'[A-Za-z]').hasMatch(ch)) return ch.toUpperCase();
  }
  // Fall back to the first character (supports non-latin names).
  return word.isEmpty ? 'X' : word.characters.first.toUpperCase();
}

/// Appends a numeric suffix when the deterministic code is already taken.
///
/// e.g. `MB4321` -> `MB4321-2`, `MB4321-3`, ...
String withUniquenessSuffix(String baseCode, int attempt) {
  if (attempt <= 1) return baseCode.toUpperCase();
  return '${baseCode.toUpperCase()}-$attempt';
}

/// Normalises user-entered referral codes (trim + uppercase).
String normalizeReferralCode(String input) => input.trim().toUpperCase();

/// True when [code] matches the deterministic shape: 2 letters + 4 digits,
/// with an optional `-N` uniqueness suffix.
bool isPlausibleReferralCode(String code) {
  return RegExp(r'^[A-Z]{2}\d{4}(-\d+)?$')
      .hasMatch(normalizeReferralCode(code));
}

extension _FirstChar on String {
  Iterable<String> get characters sync* {
    if (isEmpty) return;
    yield this[0];
  }
}
