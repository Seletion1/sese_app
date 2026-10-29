import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../../auth/login_page.dart';
import '../../driver/presentation/driver_fleet_screen.dart';
import '../../driver/services/driver_fleet_service.dart';
import '../../driver/services/driver_overlay_service.dart';
import '../../home/security_pin_screen.dart';
import '../delete_account_dialog.dart';
import '../mode_switcher.dart';
import '../role_controller.dart';

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
      appBar: const SeseAppBar(title: 'Settings'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (isDriver) ...[
            const _SectionHeader('Vehicles & Fleet'),
            Card(
              child: SettingsTile(
                tileKey: const Key('settings_fleet_tile'),
                leading: const Icon(Icons.directions_car_filled,
                    color: AppColors.seseGold),
                title: 'Manage Fleet & Documents',
                infoDescription:
                    'View registered vehicles, track verification status, and add new vehicles to your fleet.',
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
          const _SectionHeader('Security & Credentials'),
          Card(
            child: Column(
              children: [
                SettingsTile(
                  tileKey: const Key('settings_security_pin_tile'),
                  leading: const Icon(Icons.pin_outlined,
                      color: AppColors.seseGold),
                  title: 'Transaction Security PIN',
                  infoDescription:
                      'Manage your 4-digit PIN for wallet transfers, payouts, and withdrawal requests.',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SecurityPinScreen(uid: user.uid),
                    ),
                  ),
                ),
                const Divider(height: 1),
                SettingsTile(
                  tileKey: const Key('settings_account_password_tile'),
                  leading: const Icon(Icons.password_outlined,
                      color: AppColors.seseGold),
                  title: 'Account Password',
                  infoDescription:
                      'Change your password or link credentials for email sign-in across platforms.',
                  onTap: () => _manageAccountPassword(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _SectionHeader('Legal & Compliance'),
          Card(
            child: Column(
              children: [
                SettingsTile(
                  tileKey: const Key('settings_terms_tile'),
                  leading: const Icon(Icons.description_outlined,
                      color: AppColors.seseGold),
                  title: 'Terms of Use',
                  infoDescription:
                      'Read the platform terms, user conditions, and operational policies for SESE.',
                  onTap: () => LegalDocumentViewer.showTerms(context),
                ),
                const Divider(height: 1),
                SettingsTile(
                  tileKey: const Key('settings_privacy_policy_tile'),
                  leading: const Icon(Icons.privacy_tip_outlined,
                      color: AppColors.seseGold),
                  title: 'Privacy Policy',
                  infoDescription:
                      'Review how SESE handles, encrypts, and protects your personal and location data.',
                  onTap: () => LegalDocumentViewer.showPrivacy(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _SectionHeader('App Mode'),
          Card(
            child: SettingsTile(
              tileKey: const Key('settings_switch_mode_tile'),
              leading: const Icon(Icons.swap_horiz,
                  color: AppColors.seseGold),
              title: isDriver ? 'Switch to Customer Mode' : 'Switch to Driver Mode',
              titleStyle: const TextStyle(fontWeight: FontWeight.bold),
              infoDescription: isDriver
                  ? 'Book rides and deliveries as a customer.'
                  : 'Earn on your schedule with verified driver dispatch.',
              trailing: const Icon(Icons.chevron_right,
                  color: AppColors.seseGold),
              onTap: () => isDriver
                  ? ModeSwitcher.switchToCustomer(context,
                      user: user, auth: auth)
                  : ModeSwitcher.switchToDriver(context,
                      user: user, auth: auth),
            ),
          ),
          const SizedBox(height: 20),
          const _SectionHeader('Account Actions'),
          Card(
            child: SettingsTile(
              tileKey: const Key('settings_sign_out_tile'),
              leading: const Icon(Icons.logout),
              title: 'Sign Out',
              infoDescription:
                  'End your active session on this device. You will stop receiving offers until you sign back in.',
              trailing: const SizedBox.shrink(),
              onTap: () => _confirmSignOut(context),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: SettingsTile(
              tileKey: const Key('settings_delete_account_tile'),
              leading: Icon(Icons.delete_forever_outlined,
                  color: Colors.red.shade700),
              title: 'Delete Account',
              titleStyle: TextStyle(
                color: Colors.red.shade700,
                fontWeight: FontWeight.bold,
              ),
              infoDescription:
                  'Permanently erases your account, identity records, and trip history subject to 30-day archival compliance.',
              trailing: const SizedBox.shrink(),
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
  ///
  /// Teardown order:
  ///   1. Dismiss any floating SeSe overlay bubble.
  ///   2. Cancel the "You are ONLINE" foreground notification.
  ///   3. Sign out of Firebase Auth — the root _AuthGate StreamBuilder
  ///      observes the resulting null user and replaces the route tree
  ///      with the LoginPage, preventing back-nav into authenticated views.
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
      // 1. Tear down overlay + notification before auth state change.
      // Both calls are no-ops when offline or on non-Android.
      // ignore: discarded_futures
      DriverOverlayService.instance.hide();
      // ignore: discarded_futures
      PushNotificationService.cancelOnlineAlert();

      // 2. Clear role controller active trip protection timer.
      RoleController.instance.cancelActiveTripCountdown();

      // 3. Clear local session tokens and cached preferences.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('driver_active_vehicle');
        await prefs.remove('driver_online_session');
        await prefs.remove('active_trip_id');
      } catch (_) {}

      try {
        // 4. Time-boxed Firebase Auth & Google Sign-In sign-out.
        await auth.signOut().timeout(const Duration(seconds: 15));
      } catch (e) {
        debugPrint('FirebaseAuth signOut error: $e');
      }

      // 5. Clean, authoritative navigation back to LoginPage.
      // pushAndRemoveUntil flushes all routes (CustomerHomeShell, DriverHomeShell,
      // SettingsScreen) preventing any loop back into the authenticated dashboard.
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => LoginPage(auth: auth),
          ),
          (route) => false,
        );
      }
    }
  }

  /// Opens the account password management modal.
  ///
  /// Distinguishes between email/password users who can change their existing
  /// password and Google Sign-In users who can create or link an account
  /// password for cross-platform access.
  void _manageAccountPassword(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _AccountPasswordSheet(user: user, auth: auth),
    );
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
          child: SettingsTile(
            tileKey: const Key('settings_theme_tile'),
            leading: const Icon(Icons.brightness_6_outlined,
                color: AppColors.seseGold),
            title: 'Theme / Appearance',
            infoDescription:
                'Toggle between light mode, dark mode, or system theme appearance across the app.',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  themeMode.label,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, color: AppColors.seseGold),
              ],
            ),
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
            const SettingsInfoButton(
              title: 'Order Alert Sound',
              description:
                  'Select the high-priority alert chime that plays when a new trip offer or dispatch request is received.',
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
      child: SettingsSwitchTile(
        tileKey: const Key('hide_phone_tile'),
        switchKey: const Key('hide_phone_toggle'),
        leading:
            Icon(Icons.visibility_off_outlined, color: scheme.primary),
        title: 'Hide Phone Number',
        infoDescription:
            'Mask your phone number during active trips and route all passenger communications through in-app chat.',
        value: _hide ?? false,
        onChanged: _hide == null ? null : _set,
      ),
    );
  }
}

/// Modal sheet for managing account passwords and credentials.
///
/// Supports:
/// - Updating an existing password (requires entering current password).
/// - Creating or linking a password for users who authenticated via Google
///   or phone, allowing them to also sign in via email/password.
class _AccountPasswordSheet extends StatefulWidget {
  final AppUser user;
  final AuthRepository auth;

  const _AccountPasswordSheet({
    required this.user,
    required this.auth,
  });

  @override
  State<_AccountPasswordSheet> createState() => _AccountPasswordSheetState();
}

class _AccountPasswordSheetState extends State<_AccountPasswordSheet> {
  final _currentPasswordCtrl = TextEditingController();
  final _newPasswordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();

  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;

  bool _submitting = false;
  String? _error;
  String? _success;

  @override
  void dispose() {
    _currentPasswordCtrl.dispose();
    _newPasswordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    super.dispose();
  }

  /// Validates password strength:
  /// - Minimum 8 characters
  /// - Contains at least one uppercase letter
  /// - Contains at least one lowercase letter
  /// - Contains at least one number
  static String? _validatePasswordStrength(String password) {
    if (password.length < 8) {
      return 'Password must be at least 8 characters long.';
    }
    if (!password.contains(RegExp(r'[A-Z]'))) {
      return 'Password must include at least one uppercase letter (A-Z).';
    }
    if (!password.contains(RegExp(r'[a-z]'))) {
      return 'Password must include at least one lowercase letter (a-z).';
    }
    if (!password.contains(RegExp(r'[0-9]'))) {
      return 'Password must include at least one digit (0-9).';
    }
    return null;
  }

  /// Submits the password create/update through the shared repository
  /// helper ([AuthRepository.setAccountPassword]) — one implementation for
  /// customer/driver surfaces, so OAuth↔password synchronization cannot
  /// drift between screens. Passwords are used verbatim (never trimmed);
  /// only the email identifier normalizes.
  Future<void> _handleSubmit({
    required bool hasPasswordProvider,
  }) async {
    // NOTE: no `.trim()` on any password field — the repository compares
    // and stores verbatim on every path (settings, registration, sign-in),
    // so stray whitespace can never mint a set-then-mismatch failure.
    final currentPassword = _currentPasswordCtrl.text;
    final newPassword = _newPasswordCtrl.text;
    final confirmPassword = _confirmPasswordCtrl.text;

    if (hasPasswordProvider && currentPassword.isEmpty) {
      setState(() => _error = 'Please enter your current account password.');
      return;
    }

    final strengthError = _validatePasswordStrength(newPassword);
    if (strengthError != null) {
      setState(() => _error = strengthError);
      return;
    }

    if (newPassword != confirmPassword) {
      setState(() => _error = 'New passwords do not match.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
      _success = null;
    });

    try {
      await widget.auth.setAccountPassword(
        currentPassword:
            hasPasswordProvider ? currentPassword : null,
        newPassword: newPassword,
        role: widget.user.role,
      );
      if (mounted) {
        setState(() {
          _success = hasPasswordProvider
              ? 'Password successfully updated! Email and Google sign-in both keep working.'
              : 'Account password linked successfully! You can now sign in with email & password or Google.';
          _currentPasswordCtrl.clear();
          _newPasswordCtrl.clear();
          _confirmPasswordCtrl.clear();
        });
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        String msg = 'Unable to update password. Please try again.';
        if (e.code == 'wrong-password' ||
            e.code == 'invalid-credential' ||
            e.code == 'reauth-required') {
          msg = 'Incorrect current password. Please try again.';
        } else if (e.code == 'requires-recent-login') {
          msg = 'For security, please sign out and sign back in before changing your password.';
        } else if (e.code == 'weak-password') {
          msg = 'The chosen password is too weak. Please use a stronger password.';
        } else if (e.code == 'email-already-in-use' ||
            e.code == 'credential-already-in-use') {
          msg = 'This email is already linked to another sign-in method. Sign in with it first, then retry.';
        } else if (e.code == 'network-request-failed') {
          msg = 'Connection unstable. Please check your network and try again.';
        }
        setState(() => _error = msg);
      }
    } catch (e) {
      debugPrint('SettingsScreen updatePassword error: $e');
      if (mounted) {
        setState(() => _error =
            'Unable to update password right now. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Provider state comes from the repository (fresh reload best-effort),
    // not a raw FirebaseAuth singleton read — one source of truth shared
    // with the submit path above.
    return FutureBuilder<List<String>>(
      future: widget.auth.authProviders(),
      builder: (context, snap) {
        final providers = snap.data ?? const <String>[];
        // While resolving, assume the safer branch (ask for current
        // password only when we KNOW it exists — never block link mode).
        final hasPasswordProvider = providers.contains('password');
        final isGoogleUser = providers.contains('google.com');
        return _buildSheet(context,
            hasPasswordProvider: hasPasswordProvider,
            isGoogleUser: isGoogleUser);
      },
    );
  }

  Widget _buildSheet(BuildContext context,
      {required bool hasPasswordProvider, required bool isGoogleUser}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        20,
        24,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Icon(Icons.password_outlined, color: AppColors.seseGold, size: 40),
            const SizedBox(height: 12),
            Text(
              hasPasswordProvider
                  ? 'Change Account Password'
                  : 'Set Account Password',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              hasPasswordProvider
                  ? 'Update your account password for signing in with email.'
                  : (isGoogleUser
                      ? 'You are signed in with Google. Link a password so you can also sign in using email & password.'
                      : 'Set an account password for secure email sign-in.'),
              style: const TextStyle(fontSize: 13, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            if (hasPasswordProvider) ...[
              TextField(
                key: const Key('account_current_password_field'),
                controller: _currentPasswordCtrl,
                obscureText: _obscureCurrent,
                decoration: InputDecoration(
                  labelText: 'Current Password',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.lock_open_outlined),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureCurrent
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () =>
                        setState(() => _obscureCurrent = !_obscureCurrent),
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],
            TextField(
              key: const Key('account_new_password_field'),
              controller: _newPasswordCtrl,
              obscureText: _obscureNew,
              decoration: InputDecoration(
                labelText: hasPasswordProvider ? 'New Password' : 'Create Password',
                helperText: 'Min 8 characters, uppercase, lowercase & digits',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureNew
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () =>
                      setState(() => _obscureNew = !_obscureNew),
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('account_confirm_password_field'),
              controller: _confirmPasswordCtrl,
              obscureText: _obscureConfirm,
              decoration: InputDecoration(
                labelText: hasPasswordProvider ? 'Confirm New Password' : 'Confirm Password',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureConfirm
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (_success != null) ...[
              const SizedBox(height: 12),
              Text(
                _success!,
                style: const TextStyle(
                  color: Colors.green,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('account_password_submit_button'),
              onPressed: _submitting
                  ? null
                  : () => _handleSubmit(
                        hasPasswordProvider: hasPasswordProvider,
                      ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.seseGold,
                foregroundColor: Colors.black,
                minimumSize: const Size(double.infinity, 50),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : Text(
                      hasPasswordProvider
                          ? 'Update Account Password'
                          : 'Link Account Password',
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

