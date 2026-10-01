import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../../driver/presentation/driver_fleet_screen.dart';
import '../../driver/services/driver_fleet_service.dart';
import '../delete_account_dialog.dart';

/// Dedicated Settings screen: fleet, preferences, privacy, account.
///
/// Reached from the Menu tab (item #6, both roles). Sections are role-gated:
/// fleet + order-alert sound are driver-only; theme, privacy, and account
/// actions apply to everyone.
class SettingsScreen extends StatelessWidget {
  final AppUser user;
  final AuthRepository auth;

  /// Driver mode shows Vehicles & Fleet + Order Alert Sound. Customer mode
  /// shows Preferences (theme), Privacy, and Account only.
  final bool isDriver;

  const SettingsScreen({
    super.key,
    required this.user,
    required this.auth,
    required this.isDriver,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (isDriver) ...[
            const _SectionHeader('Vehicles & Fleet'),
            Card(
              child: ListTile(
                key: const Key('settings_fleet_tile'),
                leading: const Icon(Icons.directions_car_filled,
                    color: AppColors.seseGold),
                title: const Text('Manage Fleet & Documents'),
                subtitle: const Text(
                  'View registered vehicles and add a new one',
                  style: TextStyle(fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right,
                    color: AppColors.seseGold),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DriverFleetScreen(
                      fleetService: DriverFleetService(),
                      driverId: user.uid,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const _SectionHeader('Preferences & Sound'),
            const AlertSoundSection(),
            const SizedBox(height: 8),
          ] else ...[
            const _SectionHeader('Preferences'),
          ],
          _ThemeTile(),
          const SizedBox(height: 20),
          const _SectionHeader('Privacy'),
          PrivacySection(uid: user.uid),
          const SizedBox(height: 20),
          const _SectionHeader('Account Actions'),
          Card(
            child: ListTile(
              key: const Key('settings_sign_out_tile'),
              leading: const Icon(Icons.logout),
              title: const Text('Sign Out'),
              onTap: () => _confirmSignOut(context),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              key: const Key('settings_delete_account_tile'),
              leading: Icon(Icons.delete_forever_outlined,
                  color: Colors.red.shade700),
              title: Text(
                'Delete Account',
                style: TextStyle(
                  color: Colors.red.shade700,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: const Text(
                'Permanent account erasure and 30-day archival',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              onTap: () => DeleteAccountDialog.show(
                context,
                user: user,
                auth: auth,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Sign-out requires explicit confirmation — a destructive-session action
  /// must never fire from an accidental tap.
  Future<void> _confirmSignOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text(
          'You will stop receiving trip offers and updates on this device '
          'until you sign back in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await auth.signOut();
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _ThemeTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance,
      builder: (context, themeMode, _) {
        return Card(
          child: ListTile(
            key: const Key('settings_theme_tile'),
            leading: const Icon(Icons.brightness_6_outlined,
                color: AppColors.seseGold),
            title: const Text('Theme / Appearance'),
            subtitle: Text(themeMode.label),
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.seseGold),
            onTap: () =>
                showThemePickerSheet(context, ThemeController.instance),
          ),
        );
      },
    );
  }
}

/// Order alert tone selector with preview.
///
/// Moved here from DriverProfileScreen: the profile shows identity, settings
/// owns preferences. The driver picks one of the bundled high-priority
/// `sese_alert_*` tones; the choice persists via [AppSoundService] and drives
/// the looping incoming-order chime. The preview button plays the tone once.
class AlertSoundSection extends StatefulWidget {
  const AlertSoundSection({super.key});

  @override
  State<AlertSoundSection> createState() => _AlertSoundSectionState();
}

class _AlertSoundSectionState extends State<AlertSoundSection> {
  AlertTone? _tone;
  bool _previewing = false;

  @override
  void initState() {
    super.initState();
    AppSoundService.instance.loadSelectedTone().then((t) {
      if (mounted) setState(() => _tone = t);
    });
  }

  Future<void> _select(AlertTone? tone) async {
    if (tone == null) return;
    setState(() => _tone = tone);
    await AppSoundService.instance.setSelectedTone(tone);
  }

  Future<void> _preview() async {
    final tone = _tone;
    if (tone == null || _previewing) return;
    setState(() => _previewing = true);
    try {
      await AppSoundService.instance.previewAlertTone(tone);
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Icon(Icons.notifications_active_outlined,
                color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Alert Tone',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  DropdownButton<AlertTone>(
                    key: const Key('alert_tone_selector'),
                    value: _tone,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    items: AlertTone.values
                        .map((t) => DropdownMenuItem(
                              value: t,
                              child: Text(t.displayName),
                            ))
                        .toList(),
                    onChanged: _select,
                  ),
                ],
              ),
            ),
            IconButton(
              key: const Key('alert_tone_preview'),
              tooltip: 'Preview tone',
              icon: _previewing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              onPressed: _tone == null ? null : _preview,
            ),
          ],
        ),
      ),
    );
  }
}

/// "Hide Phone Number" privacy toggle.
///
/// Moved here from DriverProfileScreen for the same identity/preferences
/// split. Writes `users/{uid}.settings.hidePhoneNumber` (source of truth,
/// enforced server-side at trip mint/assignment) plus the local cache.
/// When the server write fails (offline), the toggle still applies locally
/// and warns that masking follows once the device is back online.
class PrivacySection extends StatefulWidget {
  final String uid;

  const PrivacySection({super.key, required this.uid});

  @override
  State<PrivacySection> createState() => _PrivacySectionState();
}

class _PrivacySectionState extends State<PrivacySection> {
  bool? _hide;

  @override
  void initState() {
    super.initState();
    PrivacyMasking.hidePhonesEnabled(widget.uid).then((v) {
      if (mounted) setState(() => _hide = v);
    });
  }

  Future<void> _set(bool v) async {
    setState(() => _hide = v);
    final remoteOk = await PrivacyMasking.setHidePhones(v, widget.uid);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(v
            ? (remoteOk
                ? 'Phone numbers hidden. Trip chat stays available.'
                : 'Phone numbers hidden on this device. Server masking '
                    'applies once you are back online.')
            : 'Phone numbers visible.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: SwitchListTile(
        key: const Key('hide_phone_toggle'),
        secondary:
            Icon(Icons.visibility_off_outlined, color: scheme.primary),
        title: const Text('Hide Phone Number'),
        subtitle: const Text(
          'Mask numbers in trips and use in-app chat instead of calls.',
          style: TextStyle(fontSize: 12),
        ),
        value: _hide ?? false,
        onChanged: _hide == null ? null : _set,
      ),
    );
  }
}
