import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/presentation/global_config_screen.dart';
import '../config/services/system_config_service.dart';
import '../dashboard/presentation/hub_dashboard_screen.dart'
    show showHubThemePickerSheet;
import '../dashboard/services/hub_route_persistence.dart';
import 'calling_config_screen.dart';

/// Dedicated Settings screen for `sese_hub` staff.
///
/// Sections:
///   1. **Notifications** — FCM topic opt-in for support escalation alerts.
///      Managed via [PushNotificationService] subscribe/unsubscribe which
///      are no-ops when Firebase is unavailable (test/widget-test safe).
///   2. **Appearance** — opens [showHubThemePickerSheet], shared with the
///      More menu and Profile page.
///   3. **Security** — PIN/biometric lock placeholder. `local_auth` is not
///      yet in the hub's pubspec; the tile shows "Coming soon" until it is.
///   4. **Quick System Config** — launches [GlobalConfigScreen] directly,
///      so super-admins can tweak live pricing without navigating to the tab.
///
/// This screen is stateful because the Notifications toggle must reflect the
/// live SharedPreferences value and optimistically update on tap.
class HubSettingsScreen extends StatefulWidget {
  /// Required so the Quick Config shortcut can construct [GlobalConfigScreen].
  final SystemConfigService configService;

  const HubSettingsScreen({super.key, required this.configService});

  @override
  State<HubSettingsScreen> createState() => _HubSettingsScreenState();
}

class _HubSettingsScreenState extends State<HubSettingsScreen> {
  /// Whether the user has opted in to `admin_support_alerts` FCM topic.
  ///
  /// Stored in [SharedPreferences] under [_kAlertsPrefKey] so the toggle
  /// survives app restarts without a Firestore round-trip.
  bool _supportAlertsEnabled = true;
  bool _loadingAlerts = true;

  static const _kAlertsPrefKey = 'hub_setting_support_alerts_enabled';

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _supportAlertsEnabled =
            prefs.getBool(_kAlertsPrefKey) ?? true; // default: subscribed
        _loadingAlerts = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingAlerts = false);
    }
  }

  Future<void> _toggleSupportAlerts(bool value) async {
    setState(() => _supportAlertsEnabled = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAlertsPrefKey, value);
      if (value) {
        // ignore: discarded_futures
        PushNotificationService.subscribe('admin_support_alerts');
      } else {
        // ignore: discarded_futures
        PushNotificationService.unsubscribe('admin_support_alerts');
      }
    } catch (e) {
      debugPrint('HubSettingsScreen: failed to persist alert pref: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // ── 1. Notifications ─────────────────────────────────────────────
          _SectionHeader('Notifications'),
          Card(
            child: Column(
              children: [
                SettingsSwitchTile(
                  tileKey: const Key('hub_settings_support_alerts_tile'),
                  switchKey: const Key('hub_settings_support_alerts_toggle'),
                  leading: const Icon(Icons.support_agent_outlined),
                  title: 'Support Escalation Alerts',
                  infoDescription:
                      'Receive a push notification whenever a customer support ticket is escalated to staff.',
                  value: _supportAlertsEnabled,
                  activeThumbColor: AppColors.seseGold,
                  onChanged:
                      _loadingAlerts ? null : _toggleSupportAlerts,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // ── 2. Appearance ─────────────────────────────────────────────────
          _SectionHeader('Appearance'),
          Card(
            child: ValueListenableBuilder<ThemeMode>(
              valueListenable: ThemeController.instance,
              builder: (context, mode, _) {
                return SettingsTile(
                  tileKey: const Key('hub_settings_theme_tile'),
                  leading: const Icon(Icons.brightness_6_outlined),
                  title: 'Theme / Appearance',
                  infoDescription:
                      'Toggle the Hub administrative interface between Light, Dark, or System theme.',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        mode.label,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () =>
                      showHubThemePickerSheet(context, ThemeController.instance),
                );
              },
            ),
          ),
          const SizedBox(height: 20),

          // ── 3. Security ───────────────────────────────────────────────────
          _SectionHeader('Security'),
          Card(
            child: SettingsTile(
              tileKey: const Key('hub_settings_biometrics_tile'),
              leading: Icon(
                Icons.fingerprint,
                color: scheme.onSurfaceVariant,
              ),
              title: 'Biometrics / PIN Lock',
              infoDescription:
                  'Require fingerprint, face recognition, or PIN to open the Hub administration portal.',
              trailing: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Coming soon',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              // Intentionally non-interactive — placeholder until local_auth
              // is added to sese_hub/pubspec.yaml.
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Biometric lock is coming in a future update.',
                    ),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 20),

          // ── 4. Quick System Config ─────────────────────────────────────────
          _SectionHeader('Quick Config'),
          Card(
            child: SettingsTile(
              tileKey: const Key('hub_settings_quick_config_tile'),
              leading: const Icon(Icons.tune_outlined),
              title: 'System Configuration',
              infoDescription:
                  'Configure real-time pricing models, driver commissions, and regional dispatch rules.',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GlobalConfigScreen(
                    configService: widget.configService,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── 5. In-App Calling & VoIP ────────────────────────────────────────
          _SectionHeader('In-App Calling & VoIP'),
          Card(
            child: SettingsTile(
              tileKey: const Key('hub_settings_calling_config_tile'),
              leading: const Icon(Icons.phone_in_talk_rounded),
              title: 'Calling Providers & Credentials',
              infoDescription:
                  'Switch between self-hosted WebRTC (Firebase signaling) and ZegoCloud SDK, configure credentials, or test the audio pipeline.',
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                HubRoutePersistence.saveSubRoute('calling_config');
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const CallingConfigScreen(),
                  ),
                ).then((_) {
                  HubRoutePersistence.saveSubRoute('settings');
                });
              },
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── Private helpers ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
      ),
    );
  }
}
