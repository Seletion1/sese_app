import 'package:flutter/material.dart';

/// Prominent Contacts Disclosure Dialog required by Google Play Developer Policy.
///
/// MUST be presented BEFORE triggering the system `Permission.contacts.request()` prompt.
class ContactsDisclosureDialog extends StatelessWidget {
  final VoidCallback onAgree;
  final VoidCallback? onDecline;

  const ContactsDisclosureDialog({
    super.key,
    required this.onAgree,
    this.onDecline,
  });

  /// Presents the non-dismissible prominent disclosure dialog.
  /// Returns `true` if the user agrees, `false` otherwise.
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ContactsDisclosureDialog(
        onAgree: () => Navigator.of(ctx).pop(true),
        onDecline: () => Navigator.of(ctx).pop(false),
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.contacts_rounded, color: theme.primaryColor, size: 28),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Contacts Access Required',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ),
        ],
      ),
      content: const SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SeSe needs access to your contacts so you can easily select a recipient or rider without typing their number manually. We only read the contact you select.',
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            SizedBox(height: 12),
            Text(
              '• Only the selected contact is processed\n'
              '• We NEVER upload or store your full address book\n'
              '• Used strictly for ride & delivery coordination',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      actions: [
        TextButton(
          key: const Key('contacts_disclosure_decline_btn'),
          onPressed: () {
            if (onDecline != null) {
              onDecline!();
            } else {
              Navigator.of(context).pop(false);
            }
          },
          child: const Text(
            'Not Now',
            style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600),
          ),
        ),
        ElevatedButton(
          key: const Key('contacts_disclosure_agree_btn'),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.primaryColor,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: onAgree,
          child: const Text(
            'Agree & Continue',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
