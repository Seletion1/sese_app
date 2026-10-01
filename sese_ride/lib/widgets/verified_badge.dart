import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Verified identity badge shown next to user names across sese_ride.
///
/// [variant] controls the label and icon:
/// - [VerifiedBadgeVariant.customer] → "Verified Customer" (gold, used on
///   driver incoming-request cards and bidding lists).
/// - [VerifiedBadgeVariant.driver] → "Verified Driver" (blue, used on customer
///   live-trip screen and order detail cards).
/// - [VerifiedBadgeVariant.icon] → compact checkmark icon only (used inline
///   beside names in profile headers and trip history rows).
///
/// Hides itself completely when [show] is false so callers can bind it
/// directly to `isVerifiedCustomer` / `isProfileVerified` without extra
/// `if` guards.
class VerifiedBadge extends StatelessWidget {
  final VerifiedBadgeVariant variant;
  final bool show;

  const VerifiedBadge({
    super.key,
    this.variant = VerifiedBadgeVariant.customer,
    this.show = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!show) return const SizedBox.shrink();

    if (variant == VerifiedBadgeVariant.icon) {
      return const Tooltip(
        message: 'Verified',
        child: Icon(Icons.verified, size: 16, color: AppColors.seseGold),
      );
    }

    final isCustomer = variant == VerifiedBadgeVariant.customer;
    final bgColor = isCustomer ? AppColors.seseGold : Colors.blue.shade700;
    final fgColor = isCustomer ? Colors.black : Colors.white;
    final label = isCustomer ? 'Verified Customer' : 'Verified Driver';

    return Container(
      key: Key('verified_badge_${variant.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified, size: 12, color: fgColor),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: fgColor,
            ),
          ),
        ],
      ),
    );
  }
}

enum VerifiedBadgeVariant { customer, driver, icon }
