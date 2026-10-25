import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

/// Interactive daily streak banner for the driver map view.
///
/// Shows current Level (1–3), step progress dots, next-milestone reward,
/// and — when [arrivedAt] is set (driver tapped "Arrived") — a live
/// no-show wait timer counting toward [waitThresholdMinutes}.
class StreakProgressBanner extends StatefulWidget {
  final DriverStreakState streak;
  final double fareAmount;
  final String currencySymbol;

  /// Minutes the driver must wait after "Arrived" for no-show protection.
  final int waitThresholdMinutes;

  /// Server timestamp of the "Arrived" tap, if the driver has arrived.
  final DateTime? arrivedAt;

  /// When true, renders as a compact floating round badge showing the level
  /// number. Tapping expands to the full banner and auto-collapses after 3 seconds.
  final bool collapsible;

  const StreakProgressBanner({
    super.key,
    required this.streak,
    this.fareAmount = 0,
    this.currencySymbol = '₦',
    this.waitThresholdMinutes = 10,
    this.arrivedAt,
    this.collapsible = false,
  });

  @override
  State<StreakProgressBanner> createState() => _StreakProgressBannerState();
}

class _StreakProgressBannerState extends State<StreakProgressBanner> {
  Timer? _ticker;
  Timer? _collapseTimer;
  Duration _elapsed = Duration.zero;
  bool _expanded = false;

  bool get _waiting => widget.arrivedAt != null;
  bool get _isExpanded => !widget.collapsible || _expanded || _waiting;

  @override
  void initState() {
    super.initState();
    _syncElapsed();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(_syncElapsed);
    });
  }

  @override
  void didUpdateWidget(covariant StreakProgressBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.arrivedAt != widget.arrivedAt) _syncElapsed();
  }

  void _syncElapsed() {
    final arrived = widget.arrivedAt;
    _elapsed = arrived == null
        ? Duration.zero
        : DateTime.now().difference(arrived);
    if (_elapsed.isNegative) _elapsed = Duration.zero;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _collapseTimer?.cancel();
    super.dispose();
  }

  void _onBadgeTap() {
    if (widget.collapsible) {
      _showStreakDetailsSheet(context);
    } else {
      setState(() {
        _expanded = !_expanded;
      });
      _resetCollapseTimer();
    }
  }

  void _showStreakDetailsSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        final s = widget.streak;
        return Container(
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'LEVEL ${s.currentLevel.number}',
                      style: TextStyle(
                        color: scheme.onPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _nextMilestone,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: scheme.onSurface,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Step ${s.currentStep} of 7 · ${s.streakActive ? "Streak Active" : "Streak Inactive"}',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _resetCollapseTimer() {
    _collapseTimer?.cancel();
    if (_expanded && widget.collapsible && !_waiting) {
      _collapseTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _expanded = false;
          });
        }
      });
    }
  }

  String get _nextMilestone {
    final s = widget.streak;
    if (!s.streakActive) return 'Go online — streak restarts at 15% fee';
    if (s.dailyStreakCompleted) return 'Streak complete — see you tomorrow';
    switch (s.currentLevel) {
      case StreakLevel.level1:
        if (s.currentStep >= 6) return 'Next: enter Level 2 cash-back';
        final next = _l1Rate(s.currentStep + 1);
        return 'Next trip: ${(next * 100).toStringAsFixed(1)}% fee';
      case StreakLevel.level2:
        if (s.currentStep >= 5) return 'Next: enter Level 3 cash bonuses';
        return 'Next: 0% fee + cash refund';
      case StreakLevel.level3:
        if (s.currentStep >= 6) return 'Next: grand cash award';
        final bonus = _l3Rate(s.currentStep + 1);
        return 'Next: 0% fee + ${(bonus * 100).toStringAsFixed(1)}% bonus';
    }
  }

  static double _l1Rate(int step) {
    const rates = [0.15, 0.125, 0.10, 0.075, 0.05, 0.025, 0.0];
    if (step < 0 || step >= rates.length) return 0.0;
    return rates[step];
  }

  static double _l3Rate(int step) {
    const rates = [0.025, 0.05, 0.075, 0.10, 0.125, 0.15, 0.20];
    if (step < 0 || step >= rates.length) return 0.0;
    return rates[step];
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final s = widget.streak;
    final scheme = Theme.of(context).colorScheme;

    if (!_isExpanded) {
      return GestureDetector(
        key: const Key('streak_compact_badge'),
        onTap: _onBadgeTap,
        child: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.primary,
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'LVL',
                style: TextStyle(
                  color: scheme.onPrimary.withValues(alpha: 0.8),
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
              Text(
                '${s.currentLevel.number}',
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final threshold =
        Duration(minutes: widget.waitThresholdMinutes <= 0 ? 10 : widget.waitThresholdMinutes);
    final protected = _waiting && _elapsed >= threshold;
    final remaining = threshold - _elapsed;

    return Container(
      key: const Key('streak_progress_banner'),
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'LEVEL ${s.currentLevel.number}',
                  style: TextStyle(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.streakLabel(
                      fareAmount: widget.fareAmount,
                      symbol: widget.currencySymbol),
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.collapsible && !_waiting) ...[
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () {
                    _collapseTimer?.cancel();
                    setState(() => _expanded = false);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          // Step segments: active = Warm Gold, inactive = muted grey.
          Row(
            children: [
              for (var i = 0; i < s.totalStepsInLevel; i++)
                Expanded(
                  child: Container(
                    height: 6,
                    margin: EdgeInsets.only(
                        right: i == s.totalStepsInLevel - 1 ? 0 : 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      color: i <= s.currentStep
                          ? AppColors.seseGold
                          : Colors.grey.withValues(alpha: 0.3),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Step ${s.currentStep + 1} of ${s.totalStepsInLevel} · $_nextMilestone',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (_waiting) ...[
            const SizedBox(height: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: protected
                    ? scheme.tertiaryContainer
                    : scheme.onSurface.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    protected ? Icons.shield_outlined : Icons.timer_outlined,
                    size: 16,
                    color: protected
                        ? scheme.onTertiaryContainer
                        : scheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      protected
                          ? 'Waited ${_two(_elapsed.inMinutes)}:${_two(_elapsed.inSeconds % 60)} — no-show cancel is streak-protected'
                          : 'Arrived wait: ${_two(_elapsed.inMinutes)}:${_two(_elapsed.inSeconds % 60)} / ${_two(remaining.inMinutes)}:${_two(remaining.inSeconds % 60)} to protection',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(
                            color: protected
                                ? scheme.onTertiaryContainer
                                : scheme.onSurface,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
