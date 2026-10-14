import 'dart:io' show Platform;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Data model representing remote Legal Terms configuration.
class LegalTermsConfig {
  final String termsVersion;
  final String termsUrl;
  final String privacyUrl;
  final bool forceReaccept;

  const LegalTermsConfig({
    required this.termsVersion,
    required this.termsUrl,
    required this.privacyUrl,
    required this.forceReaccept,
  });

  factory LegalTermsConfig.defaultConfig() => const LegalTermsConfig(
        termsVersion: '2026.10.04',
        termsUrl: 'https://sesetech.com/terms-of-service',
        privacyUrl: 'https://sesetech.com/privacy-policy',
        forceReaccept: false,
      );

  factory LegalTermsConfig.fromMap(Map<String, dynamic>? data) {
    if (data == null) return LegalTermsConfig.defaultConfig();
    return LegalTermsConfig(
      termsVersion: (data['terms_version'] ?? '2026.10.04').toString(),
      termsUrl:
          (data['terms_url'] ?? 'https://sesetech.com/terms-of-service').toString(),
      privacyUrl:
          (data['privacy_url'] ?? 'https://sesetech.com/privacy-policy').toString(),
      forceReaccept: data['force_reaccept'] == true,
    );
  }

  Map<String, dynamic> toMap() => {
        'terms_version': termsVersion,
        'terms_url': termsUrl,
        'privacy_url': privacyUrl,
        'force_reaccept': forceReaccept,
      };
}

/// Dynamic Remote Legal Sync, Consent Verification & Audit Logger Service.
class LegalConsentService {
  static const String localVersionPrefsKey = 'accepted_terms_version';

  const LegalConsentService();

  /// Reads `/app_config/legal_terms` from Firestore.
  /// Gracefully falls back to default configuration when offline or missing.
  Future<LegalTermsConfig> fetchRemoteLegalTerms() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('legal_terms')
          .get(const GetOptions(source: Source.serverAndCache));
      if (snap.exists && snap.data() != null) {
        return LegalTermsConfig.fromMap(snap.data());
      }
    } catch (e) {
      debugPrint('LegalConsentService: Firestore remote fetch failed ($e). Using default.');
    }
    return LegalTermsConfig.defaultConfig();
  }

  /// Gets the user's locally cached accepted terms version.
  Future<String?> getLocalAcceptedVersion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(localVersionPrefsKey);
    } catch (_) {
      return null;
    }
  }

  /// Returns true if the user must re-accept updated Terms before continuing.
  Future<bool> needsReacceptance({
    required String userId,
    required LegalTermsConfig remoteConfig,
  }) async {
    if (!remoteConfig.forceReaccept) return false;
    final localVersion = await getLocalAcceptedVersion();
    return localVersion != remoteConfig.termsVersion;
  }

  /// Records user acceptance locally and writes an audit log entry in Firestore.
  Future<void> recordAcceptance({
    required String userId,
    required String role,
    required String termsVersion,
  }) async {
    // 1. Cache locally first
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(localVersionPrefsKey, termsVersion);
    } catch (e) {
      debugPrint('LegalConsentService local cache write failed: $e');
    }

    // 2. Write audit log entry in Firestore
    if (userId.isEmpty) return;
    try {
      final isDriver = role.toLowerCase() == 'driver';
      final collection = isDriver ? 'drivers' : 'users';

      final deviceInfo = kIsWeb
          ? 'Web Browser'
          : '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

      await FirebaseFirestore.instance
          .collection(collection)
          .doc(userId)
          .collection('legal_agreements')
          .doc(termsVersion)
          .set({
        'accepted_at': FieldValue.serverTimestamp(),
        'version': termsVersion,
        'device_info': deviceInfo,
        'role': role,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('LegalConsentService Firestore audit log write failed: $e');
    }
  }
}
