import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Gold [Verified Customer] badge rendered on incoming ride cards when the
/// request carries `isVerifiedCustomer: true` (hub-approved customer
/// identity verification).
class VerifiedCustomerBadge extends StatelessWidget {
  const VerifiedCustomerBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('verified_customer_badge'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.seseGold,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified, size: 12, color: Colors.black),
          SizedBox(width: 4),
          Text(
            'Verified Customer',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
        ],
      ),
    );
  }
}
