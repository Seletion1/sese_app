import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sese_core/sese_core.dart';

/// In-app non-navigating bottom sheet modal for candidate agent submission
/// ("Become an Admin / Work With Us").
class AgentApplicationSheet extends StatefulWidget {
  final AppUser user;
  final String initialDob;
  final String initialAddress;
  final VoidCallback? onSubmitted;

  const AgentApplicationSheet({
    super.key,
    required this.user,
    this.initialDob = '',
    this.initialAddress = '',
    this.onSubmitted,
  });

  @override
  State<AgentApplicationSheet> createState() => _AgentApplicationSheetState();
}

class _AgentApplicationSheetState extends State<AgentApplicationSheet> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _firstNameCtrl;
  late final TextEditingController _middleNameCtrl;
  late final TextEditingController _lastNameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _dobCtrl;

  String _idType = 'NIN';
  dynamic _idFile; // XFile or File
  dynamic _proofOfAddressFile; // XFile or File
  dynamic _liveSelfieFile; // XFile or File

  bool _submitting = false;
  final _picker = ImagePicker();
  final _service = AdminApplicationService();

  static const List<String> _idTypeOptions = [
    'NIN',
    'International Passport',
    "Driver's License",
    "Voter's Card",
  ];

  @override
  void initState() {
    super.initState();
    final parts = widget.user.fullName.trim().split(RegExp(r'\s+'));
    final first = parts.isNotEmpty ? parts.first : '';
    final last = parts.length > 1 ? parts.last : '';
    final middle = parts.length > 2 ? parts.sublist(1, parts.length - 1).join(' ') : '';

    _firstNameCtrl = TextEditingController(text: first);
    _middleNameCtrl = TextEditingController(text: middle);
    _lastNameCtrl = TextEditingController(text: last);
    _phoneCtrl = TextEditingController(text: widget.user.phoneNumber);
    _emailCtrl = TextEditingController(text: widget.user.email);
    _dobCtrl = TextEditingController(text: widget.initialDob);
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _middleNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _dobCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage({
    required ImageSource source,
    required Function(XFile file) onPicked,
  }) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 1200,
        maxHeight: 1200,
      );
      if (picked != null) {
        setState(() => onPicked(picked));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not select photo: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<Map<String, dynamic>> _gatherDeviceMetadata() async {
    final meta = <String, dynamic>{
      'platform': defaultTargetPlatform.name,
      'isWeb': kIsWeb,
      'submittedAtIso': DateTime.now().toIso8601String(),
    };
    try {
      if (!kIsWeb) {
        meta['os'] = Platform.operatingSystem;
        meta['osVersion'] = Platform.operatingSystemVersion;
        meta['localHostname'] = Platform.localHostname;
      }
    } catch (_) {}
    return meta;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    if (_idFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please upload a Government-Issued ID.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (_proofOfAddressFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please upload a Proof of Address document.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (_liveSelfieFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please capture a Live Camera Selfie for verification.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _submitting = true);

    try {
      final metadata = await _gatherDeviceMetadata();

      dynamic prepareFileData(dynamic src) {
        if (src is XFile) {
          if (kIsWeb) {
            return src.readAsBytes();
          } else {
            return File(src.path);
          }
        }
        return src;
      }

      final idData = await prepareFileData(_idFile);
      final proofData = await prepareFileData(_proofOfAddressFile);
      final selfieData = await prepareFileData(_liveSelfieFile);

      await _service.submitApplication(
        uid: widget.user.uid,
        firstName: _firstNameCtrl.text.trim(),
        middleName: _middleNameCtrl.text.trim(),
        lastName: _lastNameCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        phoneNumber: _phoneCtrl.text.trim(),
        dob: _dobCtrl.text.trim(),
        idType: _idType,
        idFile: idData,
        proofOfAddressFile: proofData,
        selfieFile: selfieData,
        deviceMetadata: metadata,
      );

      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onSubmitted?.call();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Agent application submitted! Your documents are now under review.',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to submit application: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (ctx, scrollController) => Container(
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Form(
          key: _formKey,
          child: ListView(
            controller: scrollController,
            children: [
              // ── Top Handle & Title ──────────────────────────────────────
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.seseGold.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.badge_outlined,
                      color: AppColors.seseGold,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Work With Us / Become an Agent',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Submit your credentials to join Sese Hub staff',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const Divider(height: 24),

              // ── Verified Identity Section (Auto-populated & Locked) ───────
              _sectionHeader('1. Verified Identity Information'),
              const SizedBox(height: 8),

              TextFormField(
                controller: _firstNameCtrl,
                enabled: false,
                decoration: _lockedDecoration('First Name'),
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _middleNameCtrl,
                decoration: InputDecoration(
                  labelText: 'Middle Name (Optional)',
                  filled: true,
                  fillColor: cs.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _lastNameCtrl,
                enabled: false,
                decoration: _lockedDecoration('Last Name'),
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _phoneCtrl,
                enabled: false,
                decoration: _lockedDecoration('Phone Number'),
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _emailCtrl,
                enabled: false,
                decoration: _lockedDecoration('Email Address'),
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _dobCtrl,
                readOnly: true,
                decoration: InputDecoration(
                  labelText: 'Date of Birth (DOB)',
                  suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
                  filled: true,
                  fillColor: cs.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onTap: () async {
                  final initial = DateTime.tryParse(_dobCtrl.text) ??
                      DateTime(2000, 1, 1);
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: initial,
                    firstDate: DateTime(1940),
                    lastDate: DateTime.now().subtract(const Duration(days: 365 * 18)),
                  );
                  if (picked != null) {
                    setState(() {
                      _dobCtrl.text =
                          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                    });
                  }
                },
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),

              const SizedBox(height: 20),

              // ── Document & Biometric Upload Section ───────────────────────
              _sectionHeader('2. Compliance & Verification Documents'),
              const SizedBox(height: 8),

              DropdownButtonFormField<String>(
                value: _idType,
                decoration: InputDecoration(
                  labelText: 'Government ID Type',
                  filled: true,
                  fillColor: cs.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                items: _idTypeOptions
                    .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                    .toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _idType = val);
                },
              ),
              const SizedBox(height: 12),

              _uploadCard(
                title: 'Government-Issued ID Document',
                subtitle: 'Upload a clear photo of your $_idType card/page',
                icon: Icons.badge_outlined,
                file: _idFile,
                onTap: () => _pickImage(
                  source: ImageSource.gallery,
                  onPicked: (f) => _idFile = f,
                ),
                onCameraTap: () => _pickImage(
                  source: ImageSource.camera,
                  onPicked: (f) => _idFile = f,
                ),
              ),

              const SizedBox(height: 12),

              _uploadCard(
                title: 'Proof of Residential Address',
                subtitle: 'Upload a recent utility bill or residence document',
                icon: Icons.home_work_outlined,
                file: _proofOfAddressFile,
                onTap: () => _pickImage(
                  source: ImageSource.gallery,
                  onPicked: (f) => _proofOfAddressFile = f,
                ),
                onCameraTap: () => _pickImage(
                  source: ImageSource.camera,
                  onPicked: (f) => _proofOfAddressFile = f,
                ),
              ),

              const SizedBox(height: 12),

              // Camera-only biometric selfie
              _uploadCard(
                title: 'Live Camera Selfie (Biometric Match)',
                subtitle: 'Take a direct camera photo facing the camera',
                icon: Icons.camera_front_outlined,
                file: _liveSelfieFile,
                isCameraOnly: true,
                onTap: () => _pickImage(
                  source: ImageSource.camera,
                  onPicked: (f) => _liveSelfieFile = f,
                ),
                onCameraTap: () => _pickImage(
                  source: ImageSource.camera,
                  onPicked: (f) => _liveSelfieFile = f,
                ),
              ),

              const SizedBox(height: 24),

              // ── Submit Action ───────────────────────────────────────────
              FilledButton.icon(
                onPressed: _submitting ? null : _submit,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: AppColors.seseGold,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Icon(Icons.send_outlined),
                label: Text(
                  _submitting ? 'Submitting Application…' : 'Submit Agent Profile',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
    );
  }

  InputDecoration _lockedDecoration(String label) {
    final cs = Theme.of(context).colorScheme;
    return InputDecoration(
      labelText: label,
      suffixIcon: const Icon(Icons.lock_outline, size: 16),
      filled: true,
      fillColor: cs.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _uploadCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required dynamic file,
    required VoidCallback onTap,
    required VoidCallback onCameraTap,
    bool isCameraOnly = false,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasFile = file != null;

    return Card(
      elevation: 0,
      color: cs.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: hasFile ? Colors.green : cs.outline.withValues(alpha: 0.3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  hasFile ? Icons.check_circle : icon,
                  color: hasFile ? Colors.green : AppColors.seseGold,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (!isCameraOnly)
                  OutlinedButton.icon(
                    onPressed: onTap,
                    icon: const Icon(Icons.image_outlined, size: 16),
                    label: Text(hasFile ? 'Change File' : 'Pick File'),
                  ),
                if (!isCameraOnly) const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: onCameraTap,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.seseGold.withValues(alpha: 0.2),
                    foregroundColor: theme.textTheme.bodyMedium?.color,
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.camera_alt_outlined, size: 16),
                  label: Text(isCameraOnly
                      ? (hasFile ? 'Retake Photo' : 'Capture Live Photo')
                      : 'Camera'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
