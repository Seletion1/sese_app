import 'package:flutter/foundation.dart';
import 'package:sese_core/sese_core.dart';
import 'package:url_launcher/url_launcher.dart';

/// Centralized telephony and calling service for `sese_ride`.
///
/// Encapsulates E.164 phone number sanitization, dialer launching with Android 11+
/// query compatibility, and fallback strategies to guarantee customer and driver
/// calls and SMS connect reliably without failing on `canLaunchUrl`.
class AppCallService {
  AppCallService._();

  /// Formats and sanitizes a [raw] phone number for telephony schemes (`tel:`, `sms:`).
  ///
  /// Strips formatting artifacts (parentheses, spaces, hyphens, dots).
  /// If [raw] is masked with asterisks or bullets (`*`, `•`), returns an empty string
  /// indicating it is non-dialable.
  static String formatDialablePhone(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return '';
    if (v.contains('*') || v.contains('•')) return '';

    // Strip whitespace, hyphens, parentheses, and dots.
    final clean = v.replaceAll(RegExp(r'[\s\-().]'), '');
    if (clean.isEmpty) return '';

    // Attempt standard E.164 normalization via SesePhoneSanitizer.
    try {
      final parsed = SesePhoneSanitizer.parse(clean);
      if (parsed.e164.isNotEmpty) {
        return parsed.e164;
      }
    } catch (_) {}

    // Fallback: preserve leading + and extract digits.
    final hasPlus = clean.startsWith('+');
    final digits = clean.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';
    return hasPlus ? '+$digits' : digits;
  }

  /// Determines whether [raw] contains dialable phone digits (non-empty, unmasked).
  static bool isDialable(String raw) {
    return formatDialablePhone(raw).isNotEmpty;
  }

  /// Launches the native phone dialer with [rawPhoneNumber].
  ///
  /// Tries [LaunchMode.externalApplication] first to hand off cleanly to the native
  /// dialer app, falling back to [LaunchMode.platformDefault].
  /// Returns `true` if launched successfully, `false` otherwise.
  static Future<bool> makeCall(String rawPhoneNumber) async {
    final dialable = formatDialablePhone(rawPhoneNumber);
    if (dialable.isEmpty) {
      if (kDebugMode) {
        debugPrint('[AppCallService] Cannot place call: "$rawPhoneNumber" is empty or masked.');
      }
      return false;
    }

    final uri = Uri.parse('tel:$dialable');
    if (kDebugMode) {
      debugPrint('[AppCallService] Launching phone call to: $uri');
    }

    // Attempt 1: externalApplication with canLaunchUrl check.
    try {
      if (await canLaunchUrl(uri)) {
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (ok) return true;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AppCallService] canLaunchUrl check error: $e');
      }
    }

    // Attempt 2: direct externalApplication without canLaunchUrl (Android 11+ OEM fallback).
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok) return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AppCallService] externalApplication launch error: $e');
      }
    }

    // Attempt 3: platformDefault fallback.
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.platformDefault);
      if (ok) return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AppCallService] platformDefault launch error: $e');
      }
    }

    return false;
  }

  /// Opens the device messaging app pre-filled with [rawPhoneNumber] and optional [body].
  static Future<bool> sendSms(String rawPhoneNumber, {String? body}) async {
    final dialable = formatDialablePhone(rawPhoneNumber);
    if (dialable.isEmpty) return false;

    final uri = Uri(
      scheme: 'sms',
      path: dialable,
      queryParameters: (body != null && body.isNotEmpty) ? {'body': body} : null,
    );

    try {
      if (await canLaunchUrl(uri)) {
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (ok) return true;
      }
    } catch (_) {}

    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok) return true;
    } catch (_) {}

    try {
      final ok = await launchUrl(uri, mode: LaunchMode.platformDefault);
      if (ok) return true;
    } catch (_) {}

    return false;
  }
}
