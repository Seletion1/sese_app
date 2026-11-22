import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../../referral/referral_hub_screen.dart';
import '../../trips/models/trip_models.dart';
import '../../../widgets/verified_badge.dart';
import '../services/driver_profile_service.dart';
import '../services/driver_streak_service.dart';
import '../../agent_onboarding/widgets/agent_floating_button.dart';
import '../../agent_onboarding/presentation/agent_application_sheet.dart';
import '../../agent_onboarding/presentation/agent_status_card_sheet.dart';

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
  bool _savingExpiry = false;

  Future<void> _saveExpiry({
    DateTime? license,
    DateTime? inspection,
    DateTime? insurance,
  }) async {
    if (_savingExpiry) return;
    setState(() => _savingExpiry = true);
    try {
      await _profiles.saveDocumentExpiry(
        widget.user.uid,
        licenseExpiry: license,
        inspectionExpiry: inspection,
        insuranceExpiry: insurance,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Document expiry date updated.')),
      );
    } on DriverProfileException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
    } finally {
      if (mounted) setState(() => _savingExpiry = false);
    }
  }

  Future<void> _captureAvatar() async {
    if (_uploadingAvatar) return;

    // Surface camera permission issues before starting the spinner — the
    // service returns null silently when permission is denied, so we pre-check
    // here and show actionable feedback to the driver.
    if (!kIsWeb) {
      final permission =
          await MediaPermissionService.ensureFor(ImageSource.camera);
      if (!mounted) return;
      if (permission == MediaPermissionOutcome.permanentlyDenied) {
        await MediaPermissionService.promptIfPermanentlyDenied(context);
        return;
      }
      if (permission == MediaPermissionOutcome.denied) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Camera permission required to update photo.')),
        );
        return;
      }
    }

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
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Could not update photo. Please try again.')),
      );
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

  /// Opens a bottom-sheet text editor to correct a rejected text field,
  /// immediately saving the new value to Firestore.
  Future<void> _editField({
    required DriverProfile profile,
    required String fieldId,
    required String label,
    required String initialValue,
  }) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _TextFieldEditorSheet(
        label: label,
        initialValue: initialValue,
        onSave: (newValue) => _profiles.updateRejectedField(
          profile.uid,
          fieldId,
          newValue,
        ),
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label updated.')),
      );
    }
  }

  /// Opens a dropdown sheet to correct the vehicle type when rejected.
  Future<void> _editVehicleType({
    required DriverProfile profile,
  }) async {
    final vehicleTypes = ['Motorcycle', 'Car', 'Van', 'Truck', 'Bicycle'];
    final picked = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Select Vehicle Type',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            ...vehicleTypes.map((type) => ListTile(
                  title: Text(type),
                  trailing: profile.initialVehicleType == type
                      ? const Icon(Icons.check, color: Colors.green)
                      : null,
                  onTap: () => Navigator.of(ctx).pop(type),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null && mounted) {
      try {
        await _profiles.updateRejectedField(
          profile.uid,
          'initialVehicleType',
          picked,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Vehicle type updated.')),
          );
        }
      } on DriverProfileException catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(e.userMessage)));
        }
      }
    }
  }

  /// Sets verificationStatus back to `pending` for hub re-review after the
  /// driver has corrected all rejected fields.
  Future<void> _resubmitProfile(DriverProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Resubmit for review?'),
        content: const Text(
            'Your profile will be sent back to the verification team. '
            'Please ensure all rejected fields have been corrected.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Resubmit'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _profiles.resubmitProfile(profile.uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Profile resubmitted! Our team will review it shortly.'),
          backgroundColor: Colors.green,
        ),
      );
    } on DriverProfileException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.userMessage)));
    }
  }

  void _openAgentWorkflow({String address = ''}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StreamBuilder<AdminApplication?>(
        stream: AdminApplicationService().applicationStream(widget.user.uid),
        builder: (context, snap) {
          final app = snap.data;
          if (app == null) {
            return AgentApplicationSheet(
              user: widget.user,
              initialAddress: address,
            );
          }
          return AgentStatusCardSheet(
            application: app,
            onResubmit: () {
              showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => AgentApplicationSheet(
                  user: widget.user,
                  initialAddress: address,
                ),
              );
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SeseAppBar(title: 'Driver Profile'),
      body: StreamBuilder<DriverProfile?>(
        stream: _profiles.profileStream(widget.user.uid),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const SeseProfileSkeleton();
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

          final isVerifiedDriver = profile?.isProfileVerified == true;

          return StreamBuilder<ActiveTrip?>(
            stream: _streaks.activeTripStream(widget.user.uid),
            builder: (context, tripSnap) {
              final hasActiveTrip = tripSnap.data != null;
              return Stack(
                children: [
                  ListView(
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
                              size: 20, color: AppColors.seseGold),
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
                  _VerificationField(
                    icon: Icons.home_outlined,
                    label: 'Home / Residential Address',
                    value: address,
                    fieldStatus: profile?.fieldReviewStatus['homeAddress'],
                    onEdit: profile?.verificationStatus ==
                            DriverVerification.rejected
                        ? () => _editField(
                            profile: profile!,
                            fieldId: 'homeAddress',
                            label: 'Home / Residential Address',
                            initialValue: profile.homeAddress,
                          )
                        : null,
                  ),                  _PhoneField(
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
                  // Show a rejection callout when overall status is rejected
                  if (profile?.verificationStatus ==
                      DriverVerification.rejected) ...[
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.error_outline,
                                  color: Colors.red.shade700, size: 18),
                              const SizedBox(width: 6),
                              Text(
                                'Profile Rejected',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.red.shade700,
                                    fontSize: 13),
                              ),
                            ],
                          ),
                          if (profile?.profileRejectionReason.isNotEmpty ==
                              true) ...[
                            const SizedBox(height: 4),
                            Text(
                              profile!.profileRejectionReason,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.red.shade800),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Text(
                            'Correct the highlighted fields below, then tap Resubmit Profile.',
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.red.shade700),
                          ),
                        ],
                      ),
                    ),
                  ],
                  // Verification Status — always locked (system field)
                  _ReadOnlyField(
                    icon: Icons.verified_outlined,
                    label: 'Verification Status',
                    value: (profile?.verificationStatus.isNotEmpty == true)
                        ? profile!.verificationStatus
                        : 'PENDING',
                  ),
                  // Driver's License No — editable when rejected/not provided
                  _VerificationField(
                    icon: Icons.badge_outlined,
                    label: "Driver's License No",
                    value: (profile?.licenseNo.isNotEmpty == true)
                        ? profile!.licenseNo
                        : '—',
                    fieldStatus: profile?.fieldReviewStatus['licenseNo'],
                    onEdit: profile?.verificationStatus ==
                            DriverVerification.rejected
                        ? () => _editField(
                            profile: profile!,
                            fieldId: 'licenseNo',
                            label: "Driver's License No",
                            initialValue: profile.licenseNo,
                          )
                        : null,
                  ),
                  // Registered Vehicle Type — editable when rejected/not provided
                  _VerificationField(
                    icon: Icons.directions_car_outlined,
                    label: 'Registered Vehicle Type',
                    value:
                        (profile?.initialVehicleType.isNotEmpty == true)
                            ? profile!.initialVehicleType
                            : '—',
                    fieldStatus:
                        profile?.fieldReviewStatus['initialVehicleType'],
                    onEdit: profile?.verificationStatus ==
                            DriverVerification.rejected
                        ? () => _editVehicleType(
                            profile: profile!,
                          )
                        : null,
                  ),
                  // Resubmit button — only shown when status is rejected
                  if (profile?.verificationStatus ==
                      DriverVerification.rejected) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const Key('resubmit_profile_button'),
                        icon: const Icon(Icons.send_outlined),
                        label: const Text('Resubmit Profile'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.seseGold,
                          foregroundColor: Colors.black,
                        ),
                        onPressed: () => _resubmitProfile(profile!),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
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
                    icon: Icons.tag,
                    label: 'Driver ID',
                    // Strict role isolation: the driver ID lives ONLY on the
                    // driver profile. The signed-in AppUser is a customer
                    // profile doc, so its SC id must never be displayed here
                    // as a driver ID.
                    value: profile?.sequentialId.isNotEmpty == true
                        ? profile!.sequentialId
                        : '—',
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Document Expiry Dates',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Keep your license, inspection, and insurance dates current. '
                    'Expired documents will prevent you from going online.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 8),
                  _ExpiryDateField(
                    key: const Key('license_expiry_field'),
                    label: "Driver's License Expiry",
                    icon: Icons.badge_outlined,
                    value: profile?.licenseExpiry,
                    saving: _savingExpiry,
                    onPicked: (d) => _saveExpiry(license: d),
                  ),
                  _ExpiryDateField(
                    key: const Key('inspection_expiry_field'),
                    label: 'Vehicle Inspection Expiry',
                    icon: Icons.car_repair,
                    value: profile?.inspectionExpiry,
                    saving: _savingExpiry,
                    onPicked: (d) => _saveExpiry(inspection: d),
                  ),
                  _ExpiryDateField(
                    key: const Key('insurance_expiry_field'),
                    label: 'Vehicle Insurance Expiry',
                    icon: Icons.security_outlined,
                    value: profile?.insuranceExpiry,
                    saving: _savingExpiry,
                    onPicked: (d) => _saveExpiry(insurance: d),
                  ),
                  const SizedBox(height: 16),
                  SettingsTile(
                    tileKey: const Key('driver_referral_tile'),
                    leading: const Icon(Icons.card_giftcard_outlined,
                        color: AppColors.seseGold),
                    title: 'Refer & Earn',
                    infoDescription:
                        'Invite friends & drivers to earn lifetime bonus coins.',
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ReferralHubScreen(user: widget.user),
                    )),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Legal & Compliance',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SettingsTile(
                    tileKey: const Key('driver_profile_terms_tile'),
                    leading: const Icon(Icons.description_outlined),
                    title: 'Terms of Use',
                    infoDescription:
                        'Review terms governing driver partner operations on SESE.',
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => LegalDocumentViewer.showTerms(context),
                  ),
                  SettingsTile(
                    tileKey: const Key('driver_profile_privacy_tile'),
                    leading: const Icon(Icons.privacy_tip_outlined),
                    title: 'Privacy Policy',
                    infoDescription:
                        'Learn how SESE handles driver location, identity, and personal data.',
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => LegalDocumentViewer.showPrivacy(context),
                  ),
                ],
              ),
              if (isVerifiedDriver)
                Positioned(
                  bottom: 20,
                  right: 16,
                  child: StreamBuilder<AdminApplication?>(
                    stream: AdminApplicationService()
                        .applicationStream(widget.user.uid),
                    builder: (context, snap) {
                      final app = snap.data;
                      return AgentFloatingButton(
                        isPending: app?.isPending == true,
                        onTap: () => _openAgentWorkflow(address: address),
                      );
                    },
                  ),
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

/// Verification-aware field row for driver profile Registration Details.
///
/// Renders a lock icon when approved or system-locked, an edit icon when
/// rejected or unsubmitted (and [onEdit] is provided), plus a coloured badge
/// showing the field's review status.
///
/// When [fieldStatus] is `rejected`, the rejection reason is shown in an amber
/// container below the value so the driver knows what to fix.
class _VerificationField extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  /// Null = always locked (system read-only, e.g. Driver ID, Member Since).
  final FieldReviewStatus? fieldStatus;

  /// Called when the driver taps the edit icon/button.
  /// If null the field is always locked regardless of status.
  final VoidCallback? onEdit;

  const _VerificationField({
    required this.icon,
    required this.label,
    required this.value,
    this.fieldStatus,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isRejected = fieldStatus?.isRejected == true;
    final isApproved = fieldStatus?.isApproved == true;
    final isPending = fieldStatus?.isPending == true;
    final canEdit = onEdit != null && !isApproved;

    Widget trailing;
    if (isApproved) {
      trailing = const Icon(Icons.check_circle, size: 20, color: Colors.green);
    } else if (isRejected && canEdit) {
      trailing = IconButton(
        key: Key('edit_${label.replaceAll(' ', '_').toLowerCase()}'),
        icon: const Icon(Icons.edit_outlined, size: 20),
        color: Colors.orange.shade700,
        tooltip: 'Tap to fix',
        onPressed: onEdit,
      );
    } else if (isPending) {
      trailing = Icon(Icons.hourglass_top_outlined,
          size: 18, color: Colors.orange.shade700);
    } else if (canEdit) {
      // Not submitted / empty — show edit button
      trailing = IconButton(
        key: Key('edit_${label.replaceAll(' ', '_').toLowerCase()}'),
        icon: const Icon(Icons.edit_outlined, size: 20),
        color: scheme.primary,
        tooltip: 'Add $label',
        onPressed: onEdit,
      );
    } else {
      trailing =
          Icon(Icons.lock_outline, size: 18, color: scheme.onSurfaceVariant);
    }

    Widget? statusChip;
    if (isApproved) {
      statusChip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.green.shade200),
        ),
        child: Text('Approved',
            style: TextStyle(
                fontSize: 10,
                color: Colors.green.shade700,
                fontWeight: FontWeight.w600)),
      );
    } else if (isRejected) {
      statusChip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red.shade200),
        ),
        child: Text('Rejected',
            style: TextStyle(
                fontSize: 10,
                color: Colors.red.shade700,
                fontWeight: FontWeight.w600)),
      );
    } else if (isPending) {
      statusChip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.shade200),
        ),
        child: Text('Pending',
            style: TextStyle(
                fontSize: 10,
                color: Colors.orange.shade700,
                fontWeight: FontWeight.w600)),
      );
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: scheme.primary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            label,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                          if (statusChip != null) ...[
                            const SizedBox(width: 6),
                            statusChip,
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        value.isEmpty ? '—' : value,
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge
                            ?.copyWith(color: scheme.onSurface),
                      ),
                    ],
                  ),
                ),
                trailing,
              ],
            ),
            if (isRejected && (fieldStatus?.reason?.isNotEmpty == true)) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Text(
                  'Reason: ${fieldStatus!.reason}',
                  style: TextStyle(
                      fontSize: 12, color: Colors.orange.shade800),
                ),
              ),
            ],
          ],
        ),
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
    // 16px gutters so the phone field + save bar span edge-to-edge.
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
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
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Expiry date picker row
// ---------------------------------------------------------------------------

/// Generic text field editor sheet for correcting a single rejected field.
class _TextFieldEditorSheet extends StatefulWidget {
  final String label;
  final String initialValue;
  final Future<void> Function(String newValue) onSave;

  const _TextFieldEditorSheet({
    required this.label,
    required this.initialValue,
    required this.onSave,
  });

  @override
  State<_TextFieldEditorSheet> createState() => _TextFieldEditorSheetState();
}

class _TextFieldEditorSheetState extends State<_TextFieldEditorSheet> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initialValue);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final val = _ctrl.text.trim();
    if (val.isEmpty) {
      setState(() => _error = 'Please enter a value.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(val);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on DriverProfileException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.userMessage;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save. Check your connection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Update ${widget.label}',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              enabled: !_saving,
              decoration: InputDecoration(
                labelText: widget.label,
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(
                      color: Colors.red.shade800, fontSize: 12)),
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

/// Tappable Card that shows the current expiry date for one compliance
/// document and opens a [showDatePicker] modal to update it.
///
/// Status chip colour:
/// - Red   → already expired
/// - Amber → expiring within 7 days
/// - Green → valid (>7 days remaining)
/// - Grey  → not yet entered
class _ExpiryDateField extends StatelessWidget {
  final String label;
  final IconData icon;
  final DateTime? value;
  final bool saving;
  final void Function(DateTime picked) onPicked;

  const _ExpiryDateField({
    super.key,
    required this.label,
    required this.icon,
    required this.value,
    required this.saving,
    required this.onPicked,
  });

  Color _chipColor(DateTime? v) {
    if (v == null) return Colors.grey;
    final today = DateTime.now();
    if (v.isBefore(today)) return Colors.red;
    if (v.isBefore(today.add(const Duration(days: 7)))) return Colors.orange;
    return Colors.green;
  }

  String _chipLabel(DateTime? v) {
    if (v == null) return 'Not set';
    final today = DateTime.now();
    if (v.isBefore(today)) return 'EXPIRED';
    final diff = v.difference(today).inDays;
    if (diff < 7) return 'Expires in $diff day${diff == 1 ? '' : 's'}';
    return 'Valid';
  }

  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chipColor = _chipColor(value);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: scheme.primary),
        title: Text(
          label,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        subtitle: Row(
          children: [
            Text(
              value != null ? _formatDate(value!) : 'Tap to set',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(width: 8),
            Chip(
              label: Text(
                _chipLabel(value),
                style: const TextStyle(fontSize: 10, color: Colors.white),
              ),
              backgroundColor: chipColor,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
        trailing: saving
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(Icons.edit_calendar_outlined,
                size: 20, color: scheme.onSurfaceVariant),
        onTap: saving
            ? null
            : () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate:
                      value ?? DateTime.now().add(const Duration(days: 365)),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2035),
                  helpText: 'Select $label date',
                );
                if (picked != null) onPicked(picked);
              },
      ),
    );
  }
}
