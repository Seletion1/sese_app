import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sese_core/sese_core.dart';

/// Full KYC verification screen for customers.
///
/// Collects:
///   1. Personal info — legal name, DOB, gender, address + proof-of-address.
///   2. Employment / org info — occupation, company name & address.
///   3. Government ID — type, number, front & back photos.
///   4. Biometric — live liveness selfie (camera-only).
///
/// Lifecycle:
///   `unverified` → (submit) → `pending_review` → (hub approves) → `verified`
///                                              → (hub rejects)  → `rejected`
///
/// When status is `pending_review` or `verified`, the form is read-only
/// and a contextual banner is shown.
class CustomerVerificationScreen extends StatefulWidget {
  final AppUser user;

  /// KYC status sourced from Firestore (passed in from profile stream so
  /// we avoid an extra round-trip on open).
  final String? currentStatus;

  /// The hub admin's rejection reason, if status == rejected.
  final String? rejectionReason;

  final CustomerKycService? kycService;
  final ImagePicker? imagePicker;

  const CustomerVerificationScreen({
    super.key,
    required this.user,
    this.currentStatus,
    this.rejectionReason,
    this.kycService,
    this.imagePicker,
  });

  @override
  State<CustomerVerificationScreen> createState() =>
      _CustomerVerificationScreenState();
}

class _CustomerVerificationScreenState
    extends State<CustomerVerificationScreen> {
  final _formKey = GlobalKey<FormState>();

  // ── 1. Personal information ───────────────────────────────────────────────
  late final TextEditingController _firstName;
  late final TextEditingController _lastName;
  late final TextEditingController _dob; // YYYY-MM-DD
  String _gender = 'Male';
  static const _genders = ['Male', 'Female', 'Prefer not to say'];

  late final TextEditingController _address;
  XFile? _proofOfAddress;

  // ── 2. Employment / org info ──────────────────────────────────────────────
  late final TextEditingController _occupation;
  late final TextEditingController _orgName;
  late final TextEditingController _orgAddress;

  // ── 3. Government ID ─────────────────────────────────────────────────────
  String _idType = 'NIN';
  static const _idTypes = [
    'NIN',
    "Voter's Card",
    'International Passport',
    "Driver's License",
    'Government Issued ID',
  ];
  late final TextEditingController _idNumber;
  XFile? _idFront;
  XFile? _idBack;

  // ── 4. Biometric ─────────────────────────────────────────────────────────
  XFile? _selfie;

  // ── UI state ──────────────────────────────────────────────────────────────
  bool _submitting = false;
  bool _editingRejected = false;

  late final CustomerKycService _service;

  String get _status =>
      widget.currentStatus ?? CustomerVerification.unverified;

  bool get _isLocked =>
      _isVerified || _isPending || (_isRejected && !_editingRejected);
  bool get _isVerified => CustomerVerification.isVerified(_status);
  bool get _isPending => CustomerVerification.isPending(_status);
  bool get _isRejected => _status == CustomerVerification.rejected;

  @override
  void initState() {
    super.initState();
    final parts = widget.user.fullName.trim().split(RegExp(r'\s+'));
    _firstName = TextEditingController(
        text: parts.isEmpty ? '' : parts.first);
    _lastName = TextEditingController(
        text: parts.length < 2 ? '' : parts.sublist(1).join(' '));
    _dob = TextEditingController();
    _address = TextEditingController();
    _occupation = TextEditingController();
    _orgName = TextEditingController();
    _orgAddress = TextEditingController();
    _idNumber = TextEditingController();
    _service = widget.kycService ?? CustomerKycService();
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _dob.dispose();
    _address.dispose();
    _occupation.dispose();
    _orgName.dispose();
    _orgAddress.dispose();
    _idNumber.dispose();
    super.dispose();
  }

  // ── Pickers ───────────────────────────────────────────────────────────────

  Future<void> _pickFile({
    required bool allowGallery,
    required ValueChanged<XFile> onPicked,
    String dialogTitle = 'Choose source',
  }) async {
    ImageSource? source;
    if (allowGallery) {
      source = await showDialog<ImageSource>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(dialogTitle),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, ImageSource.camera),
              child: const Row(children: [
                Icon(Icons.photo_camera_outlined),
                SizedBox(width: 12),
                Text('Take photo'),
              ]),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, ImageSource.gallery),
              child: const Row(children: [
                Icon(Icons.photo_library_outlined),
                SizedBox(width: 12),
                Text('Choose from gallery'),
              ]),
            ),
          ],
        ),
      );
    } else {
      source = ImageSource.camera;
    }
    if (source == null) return;
    // Runtime permission handshake BEFORE the native picker.
    final permission = await MediaPermissionService.ensureFor(source);
    if (!mounted) return;
    if (permission != MediaPermissionOutcome.granted) {
      await MediaPermissionService.promptIfPermanentlyDenied(context);
      return;
    }
    final file = await ImageCompressionService.pickAndCompressImage(
        source: source);
    if (file == null) return;
    onPicked(file);
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 20),
      firstDate: DateTime(1920),
      lastDate: DateTime(now.year - 16),
      helpText: 'Date of Birth',
    );
    if (picked == null) return;
    setState(() =>
        _dob.text =
            '${picked.year.toString().padLeft(4, '0')}-'
            '${picked.month.toString().padLeft(2, '0')}-'
            '${picked.day.toString().padLeft(2, '0')}');
  }

  // ── Submission ────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (_isLocked) return;
    if (!_formKey.currentState!.validate()) return;
    if (_selfie == null) {
      _snack('A live selfie is required for identity verification.',
          isError: true);
      return;
    }
    setState(() => _submitting = true);
    try {
      await _service.submitKyc(
        userId: widget.user.uid,
        firstName: _firstName.text.trim(),
        lastName: _lastName.text.trim(),
        dateOfBirth: _dob.text.trim(),
        gender: _gender,
        address: _address.text.trim(),
        proofOfAddress: _proofOfAddress,
        occupation: _occupation.text.trim(),
        orgName: _orgName.text.trim(),
        orgAddress: _orgAddress.text.trim(),
        idType: _idType,
        idNumber: _idNumber.text.trim(),
        idFront: _idFront,
        idBack: _idBack,
        selfie: _selfie!,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Documents submitted! Our team will review and notify you within 24 h.',
          ),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).pop();
    } on CustomerKycException catch (e) {
      _snack(e.userMessage, isError: true);
    } on FirebaseException catch (e) {
      final message = e.code == 'permission-denied'
          ? 'Unable to save profile details. Please try again or contact support.'
          : 'Submission failed. Please check your network connection.';
      _snack(message, isError: true);
    } catch (_) {
      _snack('Submission failed. Please try again.', isError: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red.shade700 : null,
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify Account')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Status banner
              if (_isVerified) _statusBanner(
                icon: Icons.verified,
                color: Colors.green.shade700,
                text: 'Your identity has been verified. 🎉',
              ),
              if (_isPending) _statusBanner(
                icon: Icons.hourglass_top_outlined,
                color: Colors.orange.shade700,
                text: 'Your verification request is currently under review.',
              ),
              if (_isRejected) _statusBanner(
                icon: Icons.cancel_outlined,
                color: Colors.red.shade700,
                text: 'Rejected: ${widget.rejectionReason ?? 'Your documents were not approved.'}',
                trailing: TextButton(
                  onPressed: () => setState(() => _editingRejected = true),
                  child: const Text('Edit & Re-submit',
                      style: TextStyle(color: Colors.white)),
                ),
              ),
              if (!_isLocked) ...[
                const Text(
                  'Submit your personal details, government ID, and a live '
                  'selfie. Verified customers get instant driver matches.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),
              ],

              // ── 1. Personal Information ────────────────────────────────
              _sectionHeader('1 · Personal Information', Icons.person_outlined),
              _row([
                _field(controller: _firstName, label: 'First Name',
                    enabled: !_isLocked),
                _field(controller: _lastName, label: 'Last Name',
                    enabled: !_isLocked),
              ]),
              const SizedBox(height: 12),
              TextFormField(
                controller: _dob,
                readOnly: true,
                enabled: !_isLocked,
                decoration: const InputDecoration(
                  labelText: 'Date of Birth',
                  suffixIcon: Icon(Icons.calendar_today_outlined),
                ),
                onTap: _isLocked ? null : _pickDob,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _gender,
                decoration: const InputDecoration(
                  labelText: 'Gender',
                ),
                items: _genders
                    .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                    .toList(),
                onChanged: _isLocked
                    ? null
                    : (v) => setState(() => _gender = v ?? _gender),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _address,
                enabled: !_isLocked,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Full Residential Address',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              DocumentUploadCard(
                label: 'Proof of Address',
                file: _proofOfAddress,
                placeholderIcon: Icons.home_outlined,
                helpText: 'Utility bill, tenancy agreement, or bank statement',
                disabled: _isLocked || _submitting,
                onPick: () => _pickFile(
                  allowGallery: true,
                  dialogTitle: 'Proof of Address',
                  onPicked: (f) => setState(() => _proofOfAddress = f),
                ),
                onRetake: () => _pickFile(
                  allowGallery: true,
                  dialogTitle: 'Proof of Address',
                  onPicked: (f) => setState(() => _proofOfAddress = f),
                ),
              ),

              // ── 2. Employment / Organisation ──────────────────────────
              _sectionHeader('2 · Employment / Organisation',
                  Icons.business_outlined),
              _field(
                  controller: _occupation,
                  label: 'Occupation / Student Status',
                  enabled: !_isLocked),
              const SizedBox(height: 12),
              _field(
                  controller: _orgName,
                  label: 'Organisation or Company Name (optional)',
                  required: false,
                  enabled: !_isLocked),
              const SizedBox(height: 12),
              _field(
                  controller: _orgAddress,
                  label: 'Official Work Address (optional)',
                  required: false,
                  enabled: !_isLocked),

              // ── 3. Government ID ──────────────────────────────────────
              _sectionHeader('3 · Government ID', Icons.badge_outlined),
              DropdownButtonFormField<String>(
                initialValue: _idType,
                decoration: const InputDecoration(
                  labelText: 'ID Document Type',
                ),
                items: _idTypes
                    .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                    .toList(),
                onChanged: _isLocked
                    ? null
                    : (v) => setState(() => _idType = v ?? _idType),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _idNumber,
                enabled: !_isLocked,
                decoration: InputDecoration(
                  labelText: '$_idType Number',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              Column(
                children: [
                  DocumentUploadCard(
                    label: 'ID Front',
                    file: _idFront,
                    placeholderIcon: Icons.badge_outlined,
                    disabled: _isLocked || _submitting,
                    onPick: () => _pickFile(
                      allowGallery: true,
                      dialogTitle: 'ID Front',
                      onPicked: (f) => setState(() => _idFront = f),
                    ),
                    onRetake: () => _pickFile(
                      allowGallery: true,
                      dialogTitle: 'ID Front',
                      onPicked: (f) => setState(() => _idFront = f),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DocumentUploadCard(
                    label: 'ID Back',
                    file: _idBack,
                    placeholderIcon: Icons.badge_outlined,
                    disabled: _isLocked || _submitting,
                    onPick: () => _pickFile(
                      allowGallery: true,
                      dialogTitle: 'ID Back',
                      onPicked: (f) => setState(() => _idBack = f),
                    ),
                    onRetake: () => _pickFile(
                      allowGallery: true,
                      dialogTitle: 'ID Back',
                      onPicked: (f) => setState(() => _idBack = f),
                    ),
                  ),
                ],
              ),

              // ── 4. Live Selfie ────────────────────────────────────────
              _sectionHeader('4 · Live Biometric Selfie',
                  Icons.camera_alt_outlined),
              DocumentUploadCard(
                label: 'Live Selfie',
                file: _selfie,
                placeholderIcon: Icons.camera_alt_outlined,
                isCameraOnly: true,
                helpText: 'Camera only — gallery uploads are not accepted.',
                disabled: _isLocked || _submitting,
                onPick: () => _pickFile(
                  allowGallery: false,
                  onPicked: (f) => setState(() => _selfie = f),
                ),
                onRetake: () => _pickFile(
                  allowGallery: false,
                  onPicked: (f) => setState(() => _selfie = f),
                ),
              ),

              // ── Submit ────────────────────────────────────────────────
              const SizedBox(height: 24),
              if (!_isLocked)
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text(
                          'Submit for Verification',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Widget _sectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 18,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
        ],
      ),
    );
  }

  Widget _row(List<Widget> children) {
    return Row(
      children: children
          .expand((w) => [Expanded(child: w), const SizedBox(width: 12)])
          .toList()
        ..removeLast(),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    bool enabled = true,
    bool required = true,
    int maxLines = 1,
  }) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: !enabled
            ? const Icon(Icons.lock_outline, size: 16)
            : null,
      ),
      validator: required
          ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null
          : null,
    );
  }

  Widget _statusBanner({
    required IconData icon,
    required Color color,
    required String text,
    Widget? trailing,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: color, fontSize: 13)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

// ── Exception ─────────────────────────────────────────────────────────────────

class CustomerKycException implements Exception {
  final String code;
  final String userMessage;

  const CustomerKycException(this.code, this.userMessage);

  @override
  String toString() => 'CustomerKycException($code): $userMessage';
}

// ── Service ───────────────────────────────────────────────────────────────────

/// Uploads KYC documents to Firebase Storage under
/// `verification_documents/{userId}/` and writes the payload to
/// `users/{userId}` with `customerVerificationStatus: 'pending_review'`.
class CustomerKycService {
  final FirebaseFirestore? firestore;
  final FirebaseStorage? storage;

  /// Test seam — bypasses real upload and returns the supplied URL.
  final Future<String> Function(XFile, String)? uploadOverride;

  CustomerKycService({
    this.firestore,
    this.storage,
    this.uploadOverride,
  });

  FirebaseFirestore get _db =>
      firestore ?? FirebaseFirestore.instance;

  Future<String> _upload(XFile file, String path) async {
    if (uploadOverride != null) return uploadOverride!(file, path);
    try {
      final st = storage ?? FirebaseStorage.instance;
      final rawData = await file.readAsBytes();
      final data = await ImageCompressionService.compressBytes(rawData);
      final ref = st.ref().child(path);
      await ref.putData(data,
          SettableMetadata(contentType: 'image/jpeg'));
      return await ref.getDownloadURL();
    } catch (_) {
      throw const CustomerKycException(
        'upload-failed',
        'Unable to upload document. Please check your network connection and try again.',
      );
    }
  }

  Future<void> submitKyc({
    required String userId,
    required String firstName,
    required String lastName,
    required String dateOfBirth,
    required String gender,
    required String address,
    XFile? proofOfAddress,
    required String occupation,
    required String orgName,
    required String orgAddress,
    required String idType,
    required String idNumber,
    XFile? idFront,
    XFile? idBack,
    required XFile selfie,
    DateTime? now,
  }) async {
    if (userId.isEmpty) {
      throw const CustomerKycException(
          'invalid-user', 'Missing user account reference.');
    }

    final stamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final base = 'verification_documents/$userId';

    String proofUrl = '';
    String idFrontUrl = '';
    String idBackUrl = '';

    if (proofOfAddress != null) {
      proofUrl =
          await _upload(proofOfAddress, '$base/proof_of_address_$stamp.jpg');
    }
    if (idFront != null) {
      idFrontUrl = await _upload(idFront, '$base/id_front_$stamp.jpg');
    }
    if (idBack != null) {
      idBackUrl = await _upload(idBack, '$base/id_back_$stamp.jpg');
    }
    final selfieUrl = await _upload(selfie, '$base/selfie_$stamp.jpg');

    await _db.collection('users').doc(userId).set(
      {
        'verificationStatus': CustomerVerification.pendingReview,
        CustomerVerification.fieldStatus: CustomerVerification.pendingReview,
        CustomerVerification.fieldIsVerified: false,
        CustomerVerification.fieldRejectionReason: '',
        CustomerVerification.fieldKycData: {
          'firstName': firstName,
          'lastName': lastName,
          'fullName': '$firstName $lastName'.trim(),
          'dateOfBirth': dateOfBirth,
          'gender': gender,
          'residentialAddress': address,
          'proofOfAddressUrl': proofUrl,
          'occupation': occupation,
          'orgName': orgName,
          'orgAddress': orgAddress,
          'idType': idType,
          'idNumber': idNumber,
          'idFrontUrl': idFrontUrl,
          'idBackUrl': idBackUrl,
          'selfieUrl': selfieUrl,
        },
        'submittedAt': FieldValue.serverTimestamp(),
        'kycSubmittedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }
}
