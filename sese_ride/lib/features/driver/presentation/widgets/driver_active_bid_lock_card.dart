import 'dart:async';
import 'package:flutter/material.dart';
import '../../../trips/models/bid_models.dart';

/// Active bid lockout banner shown on the driver dashboard / order card
/// while waiting for a customer decision.
class DriverActiveBidLockCard extends StatefulWidget {
  final BidModel activeBid;
  final VoidCallback? onExpired;

  const DriverActiveBidLockCard({
    super.key,
    required this.activeBid,
    this.onExpired,
  });

  @override
  State<DriverActiveBidLockCard> createState() => _DriverActiveBidLockCardState();
}

class _DriverActiveBidLockCardState extends State<DriverActiveBidLockCard> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(covariant DriverActiveBidLockCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeBid.bidId != widget.activeBid.bidId ||
        oldWidget.activeBid.expiresAt != widget.activeBid.expiresAt) {
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (widget.activeBid.isExpired) {
        timer.cancel();
        widget.onExpired?.call();
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final remainingSec = widget.activeBid.remainingSeconds;
    final totalSec = widget.activeBid.bidCountdownSeconds > 0
        ? widget.activeBid.bidCountdownSeconds
        : 10;
    final progress = (remainingSec / totalSec).clamp(0.0, 1.0);

    final fareStr = widget.activeBid.fareFormatted.isNotEmpty
        ? widget.activeBid.fareFormatted
        : '₦${widget.activeBid.offeredFare.toStringAsFixed(0)}';

    return Container(
      key: const Key('driver_active_bid_lock_card'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF78350F).withValues(alpha: 0.35)
            : const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFF59E0B),
          width: 1.5,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 3.5,
                  backgroundColor: isDark
                      ? const Color(0xFF451A03)
                      : const Color(0xFFFDE68A),
                  color: remainingSec <= 3
                      ? Colors.red
                      : const Color(0xFFD97706),
                ),
              ),
              Text(
                '${remainingSec}s',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: remainingSec <= 3
                      ? Colors.red
                      : (isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E)),
                ),
              ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.hourglass_top_rounded,
                      size: 16,
                      color: Color(0xFFD97706),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Waiting for Customer Decision',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isDark ? const Color(0xFFFDE68A) : const Color(0xFF92400E),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  'Offer of $fareStr submitted. Other bids locked until decision.',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: isDark ? Colors.grey.shade300 : const Color(0xFF78350F),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
