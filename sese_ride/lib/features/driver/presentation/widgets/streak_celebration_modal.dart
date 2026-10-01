import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Celebratory modal shown when the driver completes Level 3 Step 6 and
/// the admin-configured grand award lands in their wallet.
Future<void> showStreakCelebration(
  BuildContext context, {
  required double awardAmount,
  String currencySymbol = '₦',
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.seseGoldLight,
            ),
            child: const Text('🏆', style: TextStyle(fontSize: 48)),
          ),
          const SizedBox(height: 16),
          const Text(
            'Streak Complete!',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'You conquered all 3 levels today — 0% fees, full cash-back, and max bonuses.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.seseGoldLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '+$currencySymbol${awardAmount.toStringAsFixed(0)} Grand Award',
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Credited to your wallet. Streak resets at midnight — come back tomorrow!',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.seseGold,
            foregroundColor: Colors.black,
          ),
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Keep Earning'),
        ),
      ],
    ),
  );
}
