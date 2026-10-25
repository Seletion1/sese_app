import 'dart:async';

import 'package:flutter/material.dart';

import '../services/awareness_tooltip_service.dart';
import '../theme/app_theme.dart';

/// Clean modal dialog explaining a settings option or feature.
///
/// Ensures the info popup stays open for at least [autoDismissDuration]
/// (default 4 seconds, never closing prematurely), or until the user
/// explicitly taps outside of it or taps the close action.
class SettingsInfoDialog extends StatefulWidget {
  final String title;
  final String description;
  final IconData icon;

  /// Duration before auto-dismissal if left untouched.
  /// Guaranteed to be at least 3 seconds (default 4s), or null to stay
  /// open indefinitely until user dismissal.
  final Duration? autoDismissDuration;

  const SettingsInfoDialog({
    super.key,
    required this.title,
    required this.description,
    this.icon = Icons.info_outline,
    this.autoDismissDuration = const Duration(seconds: 4),
  });

  /// Opens the settings info dialog.
  ///
  /// Safe against duplicate pops or route teardowns.
  static Future<void> show(
    BuildContext context, {
    required String title,
    required String description,
    IconData icon = Icons.info_outline,
    Duration? autoDismissDuration = const Duration(seconds: 4),
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => SettingsInfoDialog(
        title: title,
        description: description,
        icon: icon,
        autoDismissDuration: autoDismissDuration,
      ),
    );
  }

  @override
  State<SettingsInfoDialog> createState() => _SettingsInfoDialogState();
}

class _SettingsInfoDialogState extends State<SettingsInfoDialog> {
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    final duration = widget.autoDismissDuration;
    if (duration != null) {
      // Ensure the popup stays open for at least 3 seconds.
      final safeDuration = duration < const Duration(seconds: 3)
          ? const Duration(seconds: 3)
          : duration;
      _dismissTimer = Timer(safeDuration, () {
        if (mounted) {
          Navigator.of(context, rootNavigator: true).maybePop();
        }
      });
    }
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      elevation: 6,
      backgroundColor: theme.dialogTheme.backgroundColor,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.seseGold.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    widget.icon,
                    size: 22,
                    color: AppColors.seseGold,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Close',
                  onPressed: () =>
                      Navigator.of(context, rootNavigator: true).maybePop(),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              widget.description,
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.5,
                fontSize: 14,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.seseGold,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                onPressed: () =>
                    Navigator.of(context, rootNavigator: true).maybePop(),
                child: const Text(
                  'Got it',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Standalone info action button for settings controls and list tiles.
///
/// Tapping this button opens [SettingsInfoDialog], isolating the info popup
/// from list tile taps or toggle changes. Automatically tracks user views
/// via [AwarenessTooltipService] and hides after being viewed twice.
class SettingsInfoButton extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final double size;
  final Color? color;
  final Duration? autoDismissDuration;
  final String? tooltipId;
  final String? userId;

  const SettingsInfoButton({
    super.key,
    required this.title,
    required this.description,
    this.icon = Icons.info_outline,
    this.size = 18,
    this.color,
    this.autoDismissDuration = const Duration(seconds: 4),
    this.tooltipId,
    this.userId,
  });

  String get _effectiveKey =>
      tooltipId ??
      title.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AwarenessTooltipService.instance,
      builder: (context, _) {
        final key = _effectiveKey;
        if (!AwarenessTooltipService.instance.shouldShow(key)) {
          return const SizedBox.shrink();
        }

        final dynamicItem = AwarenessTooltipService.instance.getTooltip(
          key,
          fallbackTitle: title,
          fallbackDescription: description,
        );

        final theme = Theme.of(context);
        final iconColor =
            color ?? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55);

        return IconButton(
          icon: Icon(icon, size: size, color: iconColor),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          tooltip: 'Information',
          onPressed: () {
            AwarenessTooltipService.instance.recordView(key, userId: userId);
            SettingsInfoDialog.show(
              context,
              title: dynamicItem.title.isNotEmpty ? dynamicItem.title : title,
              description: dynamicItem.description.isNotEmpty
                  ? dynamicItem.description
                  : description,
              icon: icon,
              autoDismissDuration: autoDismissDuration,
            );
          },
        );
      },
    );
  }
}

/// Unified, clean Settings list item with independent title and optional
/// dedicated info action button next to the trailing control or chevron.
class SettingsTile extends StatelessWidget {
  final Widget? leading;
  final String title;
  final TextStyle? titleStyle;
  final String? infoTitle;
  final String? infoDescription;
  final IconData infoIcon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Key? tileKey;
  final String? tooltipId;
  final String? userId;

  const SettingsTile({
    super.key,
    this.tileKey,
    this.leading,
    required this.title,
    this.titleStyle,
    this.infoTitle,
    this.infoDescription,
    this.infoIcon = Icons.info_outline,
    this.trailing = const Icon(Icons.chevron_right),
    this.onTap,
    this.tooltipId,
    this.userId,
  });

  @override
  Widget build(BuildContext context) {
    Widget? trailingWidget = trailing;
    if (infoDescription != null && infoDescription!.isNotEmpty) {
      trailingWidget = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingsInfoButton(
            title: infoTitle ?? title,
            description: infoDescription!,
            icon: infoIcon,
            tooltipId: tooltipId,
            userId: userId,
          ),
          if (trailing != null) ...[
            const SizedBox(width: 4),
            trailing!,
          ],
        ],
      );
    }

    return ListTile(
      key: tileKey,
      leading: leading,
      title: Text(
        title,
        style: titleStyle,
      ),
      trailing: trailingWidget,
      onTap: onTap,
    );
  }
}

/// Unified Settings switch row with independent title and dedicated info action.
class SettingsSwitchTile extends StatelessWidget {
  final Widget? leading;
  final String title;
  final TextStyle? titleStyle;
  final String? infoTitle;
  final String? infoDescription;
  final IconData infoIcon;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Key? tileKey;
  final Key? switchKey;
  final Color? activeThumbColor;
  final String? tooltipId;
  final String? userId;

  const SettingsSwitchTile({
    super.key,
    this.tileKey,
    this.switchKey,
    this.leading,
    required this.title,
    this.titleStyle,
    this.infoTitle,
    this.infoDescription,
    this.infoIcon = Icons.info_outline,
    required this.value,
    required this.onChanged,
    this.activeThumbColor,
    this.tooltipId,
    this.userId,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: tileKey,
      leading: leading,
      title: Text(
        title,
        style: titleStyle,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (infoDescription != null && infoDescription!.isNotEmpty) ...[
            SettingsInfoButton(
              title: infoTitle ?? title,
              description: infoDescription!,
              icon: infoIcon,
              tooltipId: tooltipId,
              userId: userId,
            ),
            const SizedBox(width: 4),
          ],
          Switch.adaptive(
            key: switchKey,
            value: value,
            activeThumbColor: activeThumbColor ?? AppColors.seseGold,
            activeTrackColor: activeThumbColor ?? AppColors.seseGold,
            onChanged: onChanged,
          ),
        ],
      ),
      onTap: onChanged == null ? null : () => onChanged!(!value),
    );
  }
}
