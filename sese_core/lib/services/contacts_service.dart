import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/contacts_disclosure_dialog.dart';

/// Selection result from the native contact picker.
class SelectedContactResult {
  final String displayName;
  final String phoneNumber;

  const SelectedContactResult({
    required this.displayName,
    required this.phoneNumber,
  });
}

/// Central Contacts permission handshake & picker service matching Google Play Data Safety rules.
abstract final class ContactsService {
  static const String _consentKey = 'has_accepted_contacts_disclosure';

  /// Picks a contact from the native device phonebook.
  ///
  /// Flow:
  /// 1. Prominent Disclosure Dialog (if consent flag not set in [SharedPreferences]).
  /// 2. OS Permission Request (`Permission.contacts`).
  /// 3. Native contact picker via [FlutterContacts].
  /// 4. Graceful denial fallback (shows toast: "Permission denied. You can still type the phone number manually.").
  static Future<SelectedContactResult?> pickContact(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasAccepted = prefs.getBool(_consentKey) ?? false;

      if (!hasAccepted) {
        if (!context.mounted) return null;
        final agreed = await ContactsDisclosureDialog.show(context);
        if (!agreed) {
          if (context.mounted) _showDeniedToast(context);
          return null;
        }
        await prefs.setBool(_consentKey, true);
      }

      var status = await Permission.contacts.status;
      if (!status.isGranted) {
        status = await Permission.contacts.request();
      }

      if (!status.isGranted) {
        if (context.mounted) {
          _showDeniedToast(context);
        }
        return null;
      }

      final contact = await FlutterContacts.openExternalPick();
      if (contact == null || contact.phones.isEmpty) {
        return null;
      }

      final rawNumber = contact.phones.first.number;
      final sanitizedNumber = _sanitizePhone(rawNumber);

      return SelectedContactResult(
        displayName: contact.displayName,
        phoneNumber: sanitizedNumber,
      );
    } catch (e) {
      debugPrint('ContactsService.pickContact error: $e');
      if (context.mounted) {
        _showDeniedToast(context);
      }
      return null;
    }
  }

  static void _showDeniedToast(BuildContext context) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Permission denied. You can still type the phone number manually.'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 4),
      ),
    );
  }

  static String _sanitizePhone(String phone) {
    final clean = phone.replaceAll(RegExp(r'[^\d+]'), '');
    return clean;
  }
}
