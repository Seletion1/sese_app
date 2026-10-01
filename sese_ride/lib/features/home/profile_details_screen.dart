import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:sese_core/sese_core.dart';

import '../support/support_chat_screen.dart';
import '../../../widgets/verified_badge.dart';

/// Shows the customer's personal details with strict post-approval field locks.
///
/// Before verification (`customerVerificationStatus != 'verified'`):
///   All editable fields can be changed freely.
///
/// After verification (`customerVerificationStatus == 'verified'`):
///   - First Name, Last Name, DOB, Residential Address, Org Name, ID details
///     are read-only (dimmed + 🔒 icon).
///   - A footer banner explains the lock and links to Support.
///   - Primary / Secondary Phone remain editable (triggers OTP flow, stubbed).
class ProfileDetailsScreen extends StatefulWidget {
  final AppUser user;

  /// If provided, the screen reads live Firestore data from this stream.
  /// Otherwise it initialises fields from [user] only.
  final Stream<DocumentSnapshot<Map<String, dynamic>>>? userStream;

  const ProfileDetailsScreen({
    super.key,
    required this.user,
    this.userStream,
  });

  @override
  State<ProfileDetailsScreen> createState() => _ProfileDetailsScreenState();
}

class _ProfileDetailsScreenState extends State<ProfileDetailsScreen> {
  // ── Controllers ──────────────────────────────────────────────────────────
  late final TextEditingController _firstName;
  late final TextEditingController _lastName;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  late final TextEditingController _secondaryPhone;
  late final TextEditingController _dob;
  late final TextEditingController _address;
  late final TextEditingController _orgName;

  // ── State ────────────────────────────────────────────────────────────────
  String _kycStatus = '';
  bool _saving = false;

  bool get _isVerified => CustomerVerification.isVerified(_kycStatus);
  bool get _locksActive => _isVerified;

  @override
  void initState() {
    super.initState();
    final parts = widget.user.fullName.trim().split(RegExp(r'\s+'));
    _firstName = TextEditingController(
        text: parts.isEmpty ? '' : parts.first);
    _lastName = TextEditingController(
        text: parts.length < 2 ? '' : parts.sublist(1).join(' '));
    _email = TextEditingController(text: widget.user.email);
    _phone = TextEditingController(text: widget.user.phoneNumber);
    _secondaryPhone = TextEditingController();
    _dob = TextEditingController();
    _address = TextEditingController();
    _orgName = TextEditingController();
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _email.dispose();
    _phone.dispose();
    _secondaryPhone.dispose();
    _dob.dispose();
    _address.dispose();
    _orgName.dispose();
    super.dispose();
  }

  void _applyFirestoreData(Map<String, dynamic> data) {
    final kyc = data[CustomerVerification.fieldKycData];
    final kycMap = kyc is Map ? Map<String, dynamic>.from(kyc) : <String, dynamic>{};

    _kycStatus =
        (data[CustomerVerification.fieldStatus] ?? '').toString();

    if (kycMap.isNotEmpty) {
      _firstName.text = (kycMap['firstName'] ?? _firstName.text).toString();
      _lastName.text = (kycMap['lastName'] ?? _lastName.text).toString();
      _dob.text = (kycMap['dateOfBirth'] ?? '').toString();
      _address.text = (kycMap['residentialAddress'] ?? '').toString();
      _orgName.text = (kycMap['orgName'] ?? '').toString();
    }
    _phone.text = (data['phoneNumber'] ?? _phone.text).toString();
    _secondaryPhone.text =
        (data['secondaryPhone'] ?? '').toString();
  }

  Future<void> _saveChanges() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final updates = <String, dynamic>{
        'phoneNumber': _phone.text.trim(),
        'secondaryPhone': _secondaryPhone.text.trim(),
      };

      // Only allow free-form edits on unlocked fields
      if (!_locksActive) {
        updates['kycData.firstName'] = _firstName.text.trim();
        updates['kycData.lastName'] = _lastName.text.trim();
        updates['kycData.fullName'] =
            '${_firstName.text.trim()} ${_lastName.text.trim()}'.trim();
        updates['fullName'] =
            '${_firstName.text.trim()} ${_lastName.text.trim()}'.trim();
        updates['kycData.dateOfBirth'] = _dob.text.trim();
        updates['kycData.residentialAddress'] = _address.text.trim();
        updates['kycData.orgName'] = _orgName.text.trim();
      }

      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.user.uid)
          .set(updates, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Profile updated.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to save. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _onLockedFieldTap() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: const Text('Field Locked'),
        content: const Text(
          'This field is locked because your profile has been verified. '
          'To request a change, please contact Customer Support.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SupportChatScreen(
                  user: widget.user,
                  userRole: 'customer',
                ),
              ));
            },
            child: const Text('Contact Support'),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.userStream == null) {
      return Scaffold(
        appBar: _appBar(),
        body: _buildBody(),
      );
    }

    return Scaffold(
      appBar: _appBar(),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: widget.userStream,
        builder: (context, snap) {
          if (snap.hasData) {
            final d = snap.data!.data();
            if (d != null) _applyFirestoreData(d);
          }
          return _buildBody();
        },
      ),
    );
  }

  AppBar _appBar() => AppBar(
        title: Row(
          children: [
            const Text('Profile Details'),
            const SizedBox(width: 8),
            VerifiedBadge(
              variant: VerifiedBadgeVariant.icon,
              show: _isVerified,
            ),
          ],
        ),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            IconButton(
              icon: const Icon(Icons.save_outlined),
              tooltip: 'Save',
              onPressed: _saveChanges,
            ),
        ],
      );

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Locked-field notice ──────────────────────────────────────────
        if (_locksActive)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .secondaryContainer
                  .withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.lock_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSecondaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Your profile details are verified and locked for security. '
                    'To update locked information, please contact Customer Support.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context)
                          .colorScheme
                          .onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // ── Personal Info ────────────────────────────────────────────────
        _sectionHeader('Personal Information'),
        _lockedField(
          label: 'First Name',
          controller: _firstName,
          locked: _locksActive,
        ),
        const SizedBox(height: 12),
        _lockedField(
          label: 'Last Name',
          controller: _lastName,
          locked: _locksActive,
        ),
        const SizedBox(height: 12),
        _lockedField(
          label: 'Date of Birth',
          controller: _dob,
          locked: _locksActive,
        ),
        const SizedBox(height: 12),
        _lockedField(
          label: 'Residential Address',
          controller: _address,
          locked: _locksActive,
          maxLines: 2,
        ),
        const SizedBox(height: 12),
        _lockedField(
          label: 'Organisation / Company Name',
          controller: _orgName,
          locked: _locksActive,
        ),

        // ── Contact ──────────────────────────────────────────────────────
        _sectionHeader('Contact Details'),
        TextFormField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            labelText: 'Primary Phone',
            helperText: 'Changing phone requires OTP verification',
            filled: true,
            fillColor: Colors.grey.shade100,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _secondaryPhone,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            labelText: 'Secondary Phone (optional)',
            filled: true,
            fillColor: Colors.grey.shade100,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Email — always read-only (Firebase Auth source-of-truth)
        TextFormField(
          controller: _email,
          enabled: false,
          decoration: InputDecoration(
            labelText: 'Email Address',
            suffixIcon: const Icon(Icons.lock_outline, size: 16),
            filled: true,
            fillColor: Colors.grey.shade100,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),

        // ── Footer ───────────────────────────────────────────────────────
        if (_locksActive) ...[
          const SizedBox(height: 24),
          OutlinedButton.icon(
            icon: const Icon(Icons.headset_mic_outlined),
            label: const Text('Contact Support to Request Profile Update'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) =>
                  SupportChatScreen(user: widget.user, userRole: 'customer'),
            )),
          ),
        ],
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }

  /// A form field that becomes read-only with a lock icon when [locked].
  /// Tapping a locked field triggers the "contact support" modal.
  Widget _lockedField({
    required String label,
    required TextEditingController controller,
    required bool locked,
    int maxLines = 1,
  }) {
    return GestureDetector(
      onTap: locked ? _onLockedFieldTap : null,
      child: AbsorbPointer(
        absorbing: locked,
        child: TextField(
          controller: controller,
          enabled: !locked,
          maxLines: maxLines,
          style: locked
              ? TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.45),
                )
              : null,
          decoration: InputDecoration(
            labelText: label,
            filled: locked,
            fillColor: locked
                ? Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.5)
                : null,
            suffixIcon: locked
                ? const Icon(Icons.lock_outline, size: 16)
                : null,
          ),
        ),
      ),
    );
  }
}
