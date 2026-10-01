import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../../trips/models/trip_models.dart';
import '../../../widgets/verified_badge.dart';
import '../services/driver_profile_service.dart';
import '../services/driver_streak_service.dart';

/// Dedicated driver profile detail screen.
///
/// - Read-only (lock icon): full name, email, home address, registration
///   details. Drivers cannot edit these directly.
/// - Editable: phone number via an Edit button + bottom sheet, guarded by
///   the active-trip check.
/// - Avatar: tap the circular placeholder to capture a photo with the
///   device camera ONLY (no gallery). Shows a spinner while uploading.
class DriverProfileScreen extends StatefulWidget {
  final AppUser user;

  /// Test seams (fakes in widget tests, production defaults otherwise).
  final DriverProfileService? profileService;
  final DriverStreakService? streakService;

  const DriverProfileScreen({
    super.key,
    required this.user,
    this.profileService,
    this.streakService,
  });

  @override
  State<DriverProfileScreen> createState() => _DriverProfileScreenState();
}

class _DriverProfileScreenState extends State<DriverProfileScreen> {
  late final DriverProfileService _profiles =
      widget.profileService ?? DriverProfileService();
  late final DriverStreakService _streaks =
      widget.streakService ?? DriverStreakService();

  bool _uploadingAvatar = false;

  Future<void> _captureAvatar() async {
    if (_uploadingAvatar) return;
    setState(() => _uploadingAvatar = true);
    try {
      final url =
          await _profiles.captureAndPublishAvatar(widget.user.uid);
      if (!mounted) return;
      if (url != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile photo updated.')),
        );
      }
    } on DriverProfileException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _editPhone(String current) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _PhoneEditorSheet(
        initial: current,
        onSave: (raw) =>
            _profiles.savePhoneNumber(widget.user.uid, raw),
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Phone number updated.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Driver Profile')),
      body: StreamBuilder<DriverProfile?>(
        stream: _profiles.profileStream(widget.user.uid),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final profile = snap.data;
          // Fall back to the signed-in account when the driver doc is
          // missing so the screen still renders something useful.
          final name = (profile?.fullName.isNotEmpty == true)
              ? profile!.fullName
              : widget.user.fullName;
          final email = (profile?.email.isNotEmpty == true)
              ? profile!.email
              : widget.user.email;
          final photo = profile?.photoUrl ?? widget.user.photoUrl;
          final phone = profile?.phoneNumber ?? widget.user.phoneNumber;
          final address = (profile?.homeAddress.isNotEmpty == true)
              ? profile!.homeAddress
              : 'Not provided';

          return StreamBuilder<ActiveTrip?>(
            stream: _streaks.activeTripStream(widget.user.uid),
            builder: (context, tripSnap) {
              final hasActiveTrip = tripSnap.data != null;
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _AvatarCapture(
                          photoUrl: photo,
                          displayName: name,
                          uploading: _uploadingAvatar,
                          onTap: _captureAvatar,
                        ),
                        if (profile?.isProfileVerified == true) ...[
                          const SizedBox(height: 6),
                          const VerifiedBadge(
                              variant: VerifiedBadgeVariant.driver),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            name.isEmpty ? 'Driver' : name,
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (profile?.isProfileVerified == true) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.verified,
                              size: 20, color: Colors.blue),
                        ],
                      ],
                    ),
                  ),
                  Center(
                    child: Text(
                      email,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(height: 20),
                  _ReadOnlyField(
                    icon: Icons.person_outline,
                    label: 'Full Name',
                    value: name.isEmpty ? '—' : name,
                  ),
                  _ReadOnlyField(
                    icon: Icons.email_outlined,
                    label: 'Email',
                    value: email.isEmpty ? '—' : email,
                  ),
                  _ReadOnlyField(
                    icon: Icons.home_outlined,
                    label: 'Home / Residential Address',
                    value: address,
                  ),
                  _PhoneField(
                    phone: phone.isEmpty ? '—' : phone,
                    tripBlocked: hasActiveTrip,
                    onEdit: () => _editPhone(
                        profile?.phoneNumber ?? ''),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Registration Details',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  _ReadOnlyField(
                    icon: Icons.verified_outlined,
                    label: 'Verification Status',
                    value: (profile?.verificationStatus.isNotEmpty ==
                            true)
                        ? profile!.verificationStatus
                        : 'PENDING',
                  ),
                  _ReadOnlyField(
                    icon: Icons.badge_outlined,
                    label: "Driver's License No",
                    value: (profile?.licenseNo.isNotEmpty == true)
                        ? profile!.licenseNo
                        : '—',
                  ),
                  _ReadOnlyField(
                    icon: Icons.directions_car_outlined,
                    label: 'Registered Vehicle Type',
                    value:
                        (profile?.initialVehicleType.isNotEmpty ==
                                true)
                            ? profile!.initialVehicleType
                            : '—',
                  ),
                  _ReadOnlyField(
                    icon: Icons.calendar_month_outlined,
                    label: 'Member Since',
                    value: profile?.createdAt != null
                        ? profile!.createdAt!
                            .toLocal()
                            .toString()
                            .split(' ')
                            .first
                        : '—',
                  ),
                  _ReadOnlyField(
                    icon: Icons.fingerprint_outlined,
                    label: 'Driver ID',
                    value: widget.user.uid.length > 12
                        ? '${widget.user.uid.substring(0, 12)}…'
                        : widget.user.uid,
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Circular avatar placeholder; tap captures with the device camera.
/// Shows a spinner overlay while uploading.
class _AvatarCapture extends StatelessWidget {
  final String photoUrl;
  final String displayName;
  final bool uploading;
  final VoidCallback onTap;

  const _AvatarCapture({
    required this.photoUrl,
    required this.displayName,
    required this.uploading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('profile_avatar_capture'),
      onTap: uploading ? null : onTap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (photoUrl.isNotEmpty)
            CircleAvatar(
              radius: 52,
              backgroundImage: NetworkImage(photoUrl),
              onBackgroundImageError: (exception, stackTrace) {},
              child: uploading
                  ? const CircularProgressIndicator()
                  : null,
            )
          else
            UserAvatar(displayName: displayName, radius: 52),
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.primary,
              ),
              child: uploading
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color:
                            Theme.of(context).colorScheme.onPrimary,
                      ),
                    )
                  : Icon(
                      Icons.camera_alt,
                      size: 18,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Locked read-only field.
class _ReadOnlyField extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _ReadOnlyField({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: scheme.primary),
        title: Text(label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant)),
        subtitle: Text(
          value,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(color: scheme.onSurface),
        ),
        trailing: Icon(Icons.lock_outline,
            size: 18, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// Phone row with a guarded Edit button.
class _PhoneField extends StatelessWidget {
  final String phone;
  final bool tripBlocked;
  final VoidCallback onEdit;

  const _PhoneField({
    required this.phone,
    required this.tripBlocked,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(Icons.phone_outlined, color: scheme.primary),
        title: Text('Phone Number',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              phone,
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: scheme.onSurface),
            ),
            if (tripBlocked)
              const Text(
                'Phone number cannot be updated during an active trip.',
                style: TextStyle(fontSize: 11, color: Colors.redAccent),
              ),
          ],
        ),
        trailing: TextButton.icon(
          key: const Key('phone_edit_button'),
          icon: const Icon(Icons.edit, size: 16),
          label: const Text('Edit'),
          onPressed: tripBlocked ? null : onEdit,
        ),
      ),
    );
  }
}

/// Bottom-sheet phone editor.
class _PhoneEditorSheet extends StatefulWidget {
  final String initial;
  final Future<void> Function(String raw) onSave;

  const _PhoneEditorSheet({required this.initial, required this.onSave});

  @override
  State<_PhoneEditorSheet> createState() => _PhoneEditorSheetState();
}

class _PhoneEditorSheetState extends State<_PhoneEditorSheet> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_ctrl.text);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on DriverProfileException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.userMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Update Phone Number',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            SesePhoneInputField(
              controller: _ctrl,
              initialValue: widget.initial,
              labelText: 'Phone number',
              enabled: !_saving,
              onChanged: (e164) {
                if (e164.isNotEmpty && _ctrl.text != e164) {
                  _ctrl.text = e164;
                }
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style:
                      TextStyle(color: Colors.red.shade800, fontSize: 12)),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}
