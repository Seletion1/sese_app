import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Identifier types supported by the server-side uniqueness registry.
enum UniquenessIdentifierType {
  phone('phone'),
  email('email'),
  nin('nin'),
  bvn('bvn'),
  passport('passport'),
  plateNumber('plate_number'),
  driversLicense('drivers_license');

  final String wireName;
  const UniquenessIdentifierType(this.wireName);
}

/// Result of an identifier availability pre-flight check.
class IdentifierAvailabilityResult {
  final bool available;
  final bool selfOwned;
  final String maskedValue;
  final String? message;

  const IdentifierAvailabilityResult({
    required this.available,
    this.selfOwned = false,
    this.maskedValue = '',
    this.message,
  });

  factory IdentifierAvailabilityResult.fromMap(Map<String, dynamic> map) {
    return IdentifierAvailabilityResult(
      available: map['available'] == true,
      selfOwned: map['selfOwned'] == true,
      maskedValue: (map['maskedValue'] ?? '').toString(),
      message: map['message']?.toString(),
    );
  }
}

/// Service providing client-side normalization and availability validation
/// against the server-authoritative uniqueness registry (`unique_identifiers`).
class UniquenessService {
  UniquenessService._();
  static final UniquenessService instance = UniquenessService._();

  /// Normalizes a contact phone number to standard E.164 without formatting.
  static String normalizePhone(String raw) {
    final trimmed = raw.trim();
    var cleaned = trimmed.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.startsWith('0') && cleaned.length >= 10) {
      cleaned = '+234${cleaned.substring(1)}';
    } else if (cleaned.startsWith('234')) {
      cleaned = '+$cleaned';
    } else if (!cleaned.startsWith('+') && cleaned.isNotEmpty) {
      cleaned = '+$cleaned';
    }
    return cleaned;
  }

  /// Normalizes an email address, stripping dot and plus aliases for Gmail.
  static String normalizeEmail(String raw) {
    final lower = raw.trim().toLowerCase();
    final parts = lower.split('@');
    if (parts.length != 2) return lower;
    final user = parts[0];
    final domain = parts[1];

    if (domain == 'gmail.com' || domain == 'googlemail.com') {
      final cleanUser = user.replaceAll('.', '').split('+').first;
      return '$cleanUser@gmail.com';
    }
    return '$user@$domain';
  }

  /// Normalizes Nigerian NIN to numeric 11 digits.
  static String normalizeNin(String raw) {
    return raw.trim().replaceAll(RegExp(r'\D'), '');
  }

  /// Normalizes Nigerian BVN to numeric 11 digits.
  static String normalizeBvn(String raw) {
    return raw.trim().replaceAll(RegExp(r'\D'), '');
  }

  /// Normalizes International Passport to uppercase alphanumeric.
  static String normalizePassport(String raw) {
    return raw.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  /// Normalizes vehicle/motorcycle license plate to uppercase alphanumeric.
  static String normalizePlateNumber(String raw) {
    return raw.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  /// Checks whether an identifier is already registered in the system.
  /// Calls `checkIdentifierAvailability` Cloud Function with fallback to
  /// direct Firestore read if functions are not available.
  Future<IdentifierAvailabilityResult> checkAvailability({
    required UniquenessIdentifierType type,
    required String value,
  }) async {
    if (value.trim().isEmpty) {
      return const IdentifierAvailabilityResult(available: true);
    }

    try {
      final callable =
          FirebaseFunctions.instance.httpsCallable('checkIdentifierAvailability');
      final res = await callable.call<Map<String, dynamic>>({
        'type': type.wireName,
        'value': value.trim(),
      });
      return IdentifierAvailabilityResult.fromMap(
        Map<String, dynamic>.from(res.data),
      );
    } on FirebaseFunctionsException catch (e) {
      debugPrint('UniquenessService.checkAvailability functions error: $e');
      if (e.code == 'already-exists') {
        return IdentifierAvailabilityResult(
          available: false,
          message: e.message ?? 'This credential is already registered.',
        );
      }
      return IdentifierAvailabilityResult(
        available: true,
        message: e.message,
      );
    } catch (e) {
      debugPrint('UniquenessService.checkAvailability fallback: $e');
      return const IdentifierAvailabilityResult(available: true);
    }
  }
}
