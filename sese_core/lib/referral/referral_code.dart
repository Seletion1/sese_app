/// Deterministic referral code generation for the SeSe platform.
///
/// Algorithm (spec):
///   First letter of First Name (uppercase) +
///   First letter of Surname/Second Name (uppercase) +
///   Last 4 digits of registered phone number.
///
/// Example: "Micheal Bamiduro", "08161561592" -> "MB1592".
///
/// Collision handling: [withCounterUniqueness] appends an incremental counter
/// (`MB15921`, `MB15922`, `MB15923`, etc.) until a unique referral ID is secured.
library;

/// Generates a deterministic referral code from first name, last name, and phone number.
///
/// Algorithm:
/// - Extracts the first character of [firstName] and [lastName] (converted to uppercase).
/// - Extracts the last 4 numeric digits of [phoneNumber].
/// - Concatenates them into a single string (e.g. "MB1592").
String generateReferralCodeFromNames(
  String firstName,
  String lastName,
  String phoneNumber,
) {
  final f = _initialOf(firstName);
  final l = _initialOf(lastName.isEmpty ? firstName : lastName);

  final digits = phoneNumber.replaceAll(RegExp(r'[^0-9]'), '');
  String last4;
  if (digits.length >= 4) {
    last4 = digits.substring(digits.length - 4);
  } else if (digits.isEmpty) {
    last4 = '0000';
  } else {
    last4 = digits.padLeft(4, '0');
  }

  return '$f$l$last4'.toUpperCase();
}

/// Generates a deterministic referral code from display name + phone.
///
/// - [fullName]: e.g. "Micheal Bamiduro". Single-word names reuse the first
///   letter twice (e.g. "Micheal" -> "MM").
/// - [phoneNumber]: e.g. "08161561592"; non-digits are stripped and the last 4 digits
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

/// Incrementally appends a counter when a collision occurs.
///
/// - Counter 0: `MB1592`
/// - Counter 1: `MB15921`
/// - Counter 2: `MB15922`
/// - Counter 3: `MB15923`
String withCounterUniqueness(String baseCode, int counter) {
  if (counter <= 0) return baseCode.toUpperCase();
  return '${baseCode.toUpperCase()}$counter';
}

/// Appends a numeric suffix when the deterministic code is already taken (legacy format).
///
/// e.g. `MB1592` -> `MB1592-2`, `MB1592-3`, ...
String withUniquenessSuffix(String baseCode, int attempt) {
  if (attempt <= 1) return baseCode.toUpperCase();
  return '${baseCode.toUpperCase()}-$attempt';
}

/// Normalises user-entered referral codes (trim + uppercase).
String normalizeReferralCode(String input) => input.trim().toUpperCase();

/// True when [code] matches the referral code shape: 2 letters + 4 or more digits
/// (e.g. `MB1592`, `MB15921`, `MB15922`), or legacy `-N` suffix.
bool isPlausibleReferralCode(String code) {
  return RegExp(r'^[A-Z]{2}\d{4,10}(-\d+)?$')
      .hasMatch(normalizeReferralCode(code));
}

extension _FirstChar on String {
  Iterable<String> get characters sync* {
    if (isEmpty) return;
    yield this[0];
  }
}

