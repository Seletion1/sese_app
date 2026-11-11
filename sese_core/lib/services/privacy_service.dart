import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phone-number privacy masking ("Hide Phone Number").
///
/// Two layers, deliberately separated:
///
/// - **Source of truth: `users/{uid}.settings.hidePhoneNumber`** (Firestore).
///   Owner-writable per rules; syncs across the user's devices; auditable;
///   and — critically — readable server-side, so `createTrip`/`acceptTrip`
///   mask numbers at write time when the owner's flag is set. That is the
///   real enforcement boundary: a hostile client cannot unmask what was
///   never written.
/// - **Local cache: SharedPreferences** (`hide_phone_numbers`). Instant,
///   offline-capable, and the fallback when Firestore is unreachable
///   (widget tests, offline starts).
///
/// `hidePhonesEnabled` prefers Firestore and falls back to the cache;
/// `setHidePhones` writes both. The viewer-side application (masking in trip
/// surfaces) is unchanged — only where the preference lives changed.
class PrivacyMasking {
  PrivacyMasking._();

  /// SharedPreferences key for the viewer's masking toggle.
  static const String hidePhonesPrefsKey = 'hide_phone_numbers';

  /// `08012345678` → `080****5678`. Short/empty input returns a fixed
  /// placeholder so layouts never shift on masked values.
  static String maskPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 7) return '••••••';
    final head = digits.substring(0, 3);
    final tail = digits.substring(digits.length - 4);
    return '$head****$tail';
  }

  /// Render [phone] masked when [hide] is true, raw otherwise.
  static String display(String phone, {required bool hide}) =>
      hide ? maskPhone(phone) : phone;

  /// Reads the viewer's toggle (defaults to visible).
  ///
  /// When [uid] is provided, Firestore (`users/{uid}.settings`) is the
  /// primary source and SharedPreferences the fallback. Without a uid
  /// (tests, signed-out surfaces) only the local cache is consulted.
  /// Never throws — failures resolve to visible, never to a crash.
  static Future<bool> hidePhonesEnabled([String? uid]) async {
    if (uid != null && uid.isNotEmpty) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .get(const GetOptions(source: Source.serverAndCache));
        final settings = snap.data()?['settings'];
        if (settings is Map && settings['hidePhoneNumber'] is bool) {
          final remote = settings['hidePhoneNumber'] as bool;
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool(hidePhonesPrefsKey, remote);
          } catch (_) {}
          return remote;
        }

        // Fallback: check drivers collection for driver accounts
        final driverSnap = await FirebaseFirestore.instance
            .collection('drivers')
            .doc(uid)
            .get(const GetOptions(source: Source.serverAndCache));
        final driverSettings = driverSnap.data()?['settings'];
        if (driverSettings is Map && driverSettings['hidePhoneNumber'] is bool) {
          final remote = driverSettings['hidePhoneNumber'] as bool;
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool(hidePhonesPrefsKey, remote);
          } catch (_) {}
          return remote;
        }
      } catch (e) {
        debugPrint('PrivacyMasking remote read failed: $e');
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(hidePhonesPrefsKey) ?? false;
    } catch (e) {
      debugPrint('PrivacyMasking read failed: $e');
      return false;
    }
  }

  /// Persists the viewer's toggle.
  ///
  /// Writes Firestore first (source of truth, dotted merge so sibling
  /// `settings.*` keys survive), updating both `users/{uid}` and `drivers/{uid}`
  /// documents, then the local cache. A Firestore failure still persists
  /// locally so the toggle never appears broken offline.
  static Future<bool> setHidePhones(bool hide, [String? uid]) async {
    var remoteOk = uid == null || uid.isEmpty;
    if (uid != null && uid.isNotEmpty) {
      try {
        final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
        final driverRef = FirebaseFirestore.instance.collection('drivers').doc(uid);
        
        await userRef.set(
          {'settings.hidePhoneNumber': hide},
          SetOptions(merge: true),
        );

        // Also sync settings to drivers collection if the driver document exists
        final driverSnap = await driverRef.get(const GetOptions(source: Source.cache));
        if (driverSnap.exists) {
          await driverRef.set(
            {'settings.hidePhoneNumber': hide},
            SetOptions(merge: true),
          );
        }

        remoteOk = true;
      } catch (e) {
        debugPrint('PrivacyMasking remote write failed: $e');
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(hidePhonesPrefsKey, hide);
    } catch (_) {}
    return remoteOk;
  }
}
