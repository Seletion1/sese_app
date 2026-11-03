import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Discreet, professional agent floating button styled using established
/// app brand color tokens (black circle container with warm gold border & SeSe branding).
///
/// Displayed at the bottom-right corner of Customer and Driver Profile screens
/// strictly when [isVerified] is true.
class AgentFloatingButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool isPending;

  const AgentFloatingButton({
    super.key,
    required this.onTap,
    this.isPending = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: isPending
          ? 'Agent Profile Under Verification'
          : 'Become an Admin / Work With Us',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        elevation: 6,
        shadowColor: AppColors.seseGold.withValues(alpha: 0.4),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black,
              border: Border.all(
                color: isPending ? Colors.orange : AppColors.seseGold,
                width: 2.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.seseGold.withValues(alpha: 0.25),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'SeSe',
                      style: TextStyle(
                        color: AppColors.seseGold,
                        fontWeight: FontWeight.w900,
                        fontSize: 11,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const Icon(
                      Icons.badge_outlined,
                      size: 14,
                      color: AppColors.seseGold,
                    ),
                  ],
                ),
                if (isPending)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: const BoxDecoration(
                        color: Colors.orange,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
