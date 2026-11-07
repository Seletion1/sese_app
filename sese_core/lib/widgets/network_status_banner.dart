import 'package:flutter/material.dart';
import '../services/network_status_service.dart';

/// Clean, non-blocking top warning banner displayed when network connectivity
/// becomes unstable or disconnected.
///
/// Complies with:
/// - "Network unstable. Please check your connection" message.
/// - Subtle, responsive Refresh action with feedback.
/// - Non-blocking pointer events (only the Refresh button captures taps).
/// - Smooth slide-in and slide-out transitions.
class NetworkStatusBanner extends StatelessWidget {
  const NetworkStatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final status = NetworkStatusService.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: status.isOnline,
      builder: (context, isOnline, _) {
        return AnimatedSlide(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          offset: isOnline ? const Offset(0, -1.2) : Offset.zero,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 250),
            opacity: isOnline ? 0.0 : 1.0,
            child: isOnline
                ? const SizedBox.shrink()
                : SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Material(
                        elevation: 6,
                        borderRadius: BorderRadius.circular(12),
                        color: const Color(0xFF1E1E24), // Sleek dark slate
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(0xFFF59E0B).withValues(alpha: 0.8), // Amber warning
                              width: 1.2,
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.wifi_off_rounded,
                                size: 18,
                                color: Color(0xFFF59E0B),
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  'Network unstable. Please check your connection',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              ValueListenableBuilder<bool>(
                                valueListenable: status.isChecking,
                                builder: (context, isChecking, _) {
                                  return InkWell(
                                    key: const Key('network_banner_refresh_button'),
                                    onTap: isChecking ? null : () => status.refresh(),
                                    borderRadius: BorderRadius.circular(8),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: const Color(0xFFF59E0B).withValues(alpha: 0.5),
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (isChecking) ...[
                                            const SizedBox(
                                              width: 12,
                                              height: 12,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFF59E0B)),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                          ],
                                          Text(
                                            isChecking ? 'Checking…' : 'Refresh',
                                            style: const TextStyle(
                                              color: Color(0xFFFBBF24),
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}

/// A global wrapper that overlays [NetworkStatusBanner] at the top of [child].
/// Safe for [MaterialApp.builder].
class NetworkStatusBannerWrapper extends StatelessWidget {
  final Widget child;

  const NetworkStatusBannerWrapper({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: NetworkStatusBanner(),
        ),
      ],
    );
  }
}
