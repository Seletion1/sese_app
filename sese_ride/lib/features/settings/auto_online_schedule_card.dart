import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../driver/services/auto_schedule_service.dart';

/// "Auto Online Schedule" card shown inside Driver Settings.
///
/// Reads the driver's existing schedule preferences from Firestore in real
/// time, displays an ON/OFF toggle and two 24-hour time pickers, and writes
/// any change back to the server via [AutoScheduleService.savePrefs].
///
/// **No phone clock is used** — all schedule enforcement happens server-side
/// using Africa/Lagos (WAT) time.  This card only manages *preferences*.
class AutoOnlineScheduleCard extends StatefulWidget {
  final String driverId;

  /// Optionally inject a custom service (facilitates widget testing).
  final AutoScheduleService? service;

  const AutoOnlineScheduleCard({
    super.key,
    required this.driverId,
    this.service,
  });

  @override
  State<AutoOnlineScheduleCard> createState() => _AutoOnlineScheduleCardState();
}

class _AutoOnlineScheduleCardState extends State<AutoOnlineScheduleCard> {
  late final AutoScheduleService _svc;

  /// Current in-memory prefs (reflects last successful save or stream value).
  AutoSchedulePrefs _prefs = const AutoSchedulePrefs();

  /// True while a save request is in flight.
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _svc = widget.service ?? AutoScheduleService();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Parses "HH:MM" into a [TimeOfDay].
  static TimeOfDay _parse(String hhmm) {
    final parts = hhmm.split(':');
    return TimeOfDay(
      hour: int.tryParse(parts.first) ?? 6,
      minute: int.tryParse(parts.last) ?? 0,
    );
  }

  /// Formats a [TimeOfDay] back to "HH:MM" (zero-padded, 24-hour).
  static String _format(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Formats "HH:MM" to a human-friendly label, e.g. "06:00 → 6:00 AM".
  static String _label(String hhmm) {
    final t = _parse(hhmm);
    final amPm = t.hour < 12 ? 'AM' : 'PM';
    final h = t.hour == 0
        ? 12
        : t.hour > 12
            ? t.hour - 12
            : t.hour;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m $amPm';
  }

  Future<void> _save(AutoSchedulePrefs updated) async {
    setState(() => _saving = true);
    try {
      await _svc.savePrefs(widget.driverId, updated);
      if (mounted) {
        setState(() => _prefs = updated);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Auto Online Schedule saved.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } on AutoScheduleException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickTime({
    required String current,
    required String label,
    required void Function(String newHHMM) onPicked,
  }) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _parse(current),
      helpText: label,
      builder: (ctx, child) => MediaQuery(
        // Force 24-hour clock regardless of device locale
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      onPicked(_format(picked));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AutoSchedulePrefs>(
      stream: _svc.prefsStream(widget.driverId),
      initialData: _prefs,
      builder: (context, snap) {
        // Merge stream value into local state so the UI always reflects
        // the latest server value while not discarding in-flight edits.
        final serverPrefs = snap.data ?? const AutoSchedulePrefs();
        if (!_saving) {
          // Only sync from stream when no save is in-flight to avoid flicker
          _prefs = serverPrefs;
        }
        return _buildCard(context);
      },
    );
  }

  Widget _buildCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isEnabled = _prefs.enabled;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row: icon + title + toggle ──────────────────────────
            Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  color: isEnabled ? AppColors.seseGold : scheme.onSurfaceVariant,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Auto Online Schedule',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Server sets your status automatically using WAT (Nigeria) time.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _saving
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Switch(
                        key: const Key('auto_schedule_toggle'),
                        value: isEnabled,
                        activeColor: AppColors.seseGold,
                        onChanged: (v) => _save(_prefs.copyWith(enabled: v)),
                      ),
              ],
            ),

            // ── Time pickers (shown regardless; dimmed when disabled) ──────
            const SizedBox(height: 14),
            AnimatedOpacity(
              opacity: isEnabled ? 1.0 : 0.4,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !isEnabled || _saving,
                child: Column(
                  children: [
                    _TimeTile(
                      key: const Key('auto_online_time_tile'),
                      icon: Icons.wb_sunny_outlined,
                      label: 'Go Online At',
                      timeLabel: _label(_prefs.autoOnlineTime),
                      onTap: () => _pickTime(
                        current: _prefs.autoOnlineTime,
                        label: 'Auto Go Online Time (WAT)',
                        onPicked: (t) => _save(_prefs.copyWith(autoOnlineTime: t)),
                      ),
                    ),
                    const Divider(height: 1),
                    _TimeTile(
                      key: const Key('auto_offline_time_tile'),
                      icon: Icons.nights_stay_outlined,
                      label: 'Go Offline At',
                      timeLabel: _label(_prefs.autoOfflineTime),
                      onTap: () => _pickTime(
                        current: _prefs.autoOfflineTime,
                        label: 'Auto Go Offline Time (WAT)',
                        onPicked: (t) => _save(_prefs.copyWith(autoOfflineTime: t)),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Informational footer ───────────────────────────────────────
            if (isEnabled) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 14, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'If you manually go Offline after the auto-online time, '
                        'the system will not force you back Online that day.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontSize: 11,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A single tappable row showing an icon, label, and the selected time.
class _TimeTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String timeLabel;
  final VoidCallback onTap;

  const _TimeTile({
    super.key,
    required this.icon,
    required this.label,
    required this.timeLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        child: Row(
          children: [
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Text(
              timeLabel,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.seseGold,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.edit_outlined, size: 14, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
