import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import '../settings/role_controller.dart';

/// Floating countdown timer banner displayed in Customer View when a Driver
/// switches modes while having an active ongoing order (`accepted`, `arrived`, `in_transit`).
///
/// Shows a live 10-Minute countdown (`09:59...`) and auto-switches back to Driver Mode
/// on expiry or upon manual tap of "Return to Driver Mode".
class ActiveTripCountdownBanner extends StatelessWidget {
  final VoidCallback onReturnToDriver;

  const ActiveTripCountdownBanner({
    super.key,
    required this.onReturnToDriver,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: RoleController.instance,
      builder: (context, _) {
        if (!RoleController.instance.hasActiveTripProtection) {
          return const SizedBox.shrink();
        }

        return Container(
          key: const Key('active_trip_countdown_banner'),
          width: double.infinity,
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.seseGold.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.timer_outlined,
                  color: AppColors.seseGold,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Active Driver Trip in Progress',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      softWrap: true,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Auto-switch in: ${RoleController.instance.countdownDisplay}',
                      style: const TextStyle(
                        color: AppColors.seseGold,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                      softWrap: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: FilledButton(
                  key: const Key('return_to_driver_button'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.seseGold,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: const Size(0, 36),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    RoleController.instance.cancelActiveTripCountdown();
                    onReturnToDriver();
                  },
                  child: const Text(
                    'Driver Mode',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    softWrap: false,
                    overflow: TextOverflow.visible,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
