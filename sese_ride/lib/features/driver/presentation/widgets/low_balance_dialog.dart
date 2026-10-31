import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../../../payments/payment_service.dart';
import '../../../payments/top_up_sheet.dart';

/// Shows a clean, concise notification toast and modal dialog stating:
/// "Your balance is low. Please top up to accept trips."
///
/// Gives the driver an immediate one-tap route to top up their wallet balance
/// so they can unblock accepting orders.
Future<void> showLowBalanceAcceptancePrompt(
  BuildContext context, {
  required String driverId,
  AppUser? user,
}) async {
  if (!context.mounted) return;

  // 1. Toast notification
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Your balance is low. Please top up to accept trips.'),
      duration: Duration(seconds: 4),
    ),
  );

  // 2. Clean, concise dialog with direct top-up action
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(
            Icons.account_balance_wallet_outlined,
            color: AppColors.seseGold,
          ),
          SizedBox(width: 8),
          Text(
            'Low Balance',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      content: const Text(
        'Your balance is low. Please top up to accept trips.',
        style: TextStyle(fontSize: 15),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.seseGold,
            foregroundColor: Colors.black87,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: () {
            Navigator.of(ctx).pop();
            final effectiveUser = user ??
                AppUser(
                  uid: driverId,
                  fullName: 'Driver',
                  email: '',
                  phoneNumber: '',
                  createdAt: DateTime.now(),
                  role: UserRole.driver,
                );
            showTopUpSheet(context, PaymentService(), effectiveUser);
          },
          child: const Text(
            'Top Up Now',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    ),
  );
}
