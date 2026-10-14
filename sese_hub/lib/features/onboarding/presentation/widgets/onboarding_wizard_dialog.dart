import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sese_core/sese_core.dart';
import '../../services/hub_onboarding_service.dart';

/// Multi-Step Registration & Provisioning Wizard Dialog for Sese Hub admins.
class OnboardingWizardDialog extends StatefulWidget {
  final String? initialIdentifier;
  final OnboardingLookupResult? lookupResult;

  const OnboardingWizardDialog({
    super.key,
    this.initialIdentifier,
    this.lookupResult,
  });

  static Future<bool?> show(
    BuildContext context, {
    String? initialIdentifier,
    OnboardingLookupResult? lookupResult,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680, maxHeight: 820),
          child: OnboardingWizardDialog(
            initialIdentifier: initialIdentifier,
            lookupResult: lookupResult,
          ),
        ),
      ),
    );
  }

  @override
  State<OnboardingWizardDialog> createState() => _OnboardingWizardDialogState();
}

class _OnboardingWizardDialogState extends State<OnboardingWizardDialog> {
  final _service = HubOnboardingService();
  final _picker = ImagePicker();

  int _currentStep = 0;
  bool _isLoading = false;
  String? _errorMessage;

  // Step 1 Controllers & State
  late final TextEditingController _identifierCtrl;
  final _otpCtrl = TextEditingController();
  bool _otpSent = false;
  bool _otpVerified = false;
  String? _devOtpHint;
  OnboardingLookupResult? _lookupResult;

  // Step 2 Role & Profile
  String _selectedRole = 'driver'; // 'customer' | 'driver'
  final _fullNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _ninCtrl = TextEditingController();
  final _licenseNumCtrl = TextEditingController();
  final _licenseExpiryCtrl = TextEditingController();

  // Step 3 Vehicle Setup
  VehicleCategory _selectedCategory = VehicleCategory.car;
  final _vMakeCtrl = TextEditingController();
  final _vModelCtrl = TextEditingController();
  final _vYearCtrl = TextEditingController(text: DateTime.now().year.toString());
  final _vPlateCtrl = TextEditingController();
  final _vColorCtrl = TextEditingController();
  RideTier? _selectedTier;

  // Step 4 Documents & Live Photo
  final _driverLicenseUrlCtrl = TextEditingController();
  final _inspectionUrlCtrl = TextEditingController();
  final _insuranceUrlCtrl = TextEditingController();
  final _roadworthinessUrlCtrl = TextEditingController();
  
  Uint8List? _capturedPhotoBytes;
  String? _uploadedPhotoUrl;

  @override
  void initState() {
    super.initState();
    _identifierCtrl = TextEditingController(text: widget.initialIdentifier ?? '');
    _lookupResult = widget.lookupResult;

    if (_lookupResult != null && _lookupResult!.exists) {
      final u = _lookupResult!.userData;
      if (u != null) {
        _fullNameCtrl.text = u['fullName']?.toString() ?? '';
        _phoneCtrl.text = u['phoneNumber']?.toString() ?? '';
        _emailCtrl.text = u['email']?.toString() ?? '';
        _selectedRole = u['role']?.toString() ?? 'driver';
      }
    }
  }

  @override
  void dispose() {
    _identifierCtrl.dispose();
    _otpCtrl.dispose();
    _fullNameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    _ninCtrl.dispose();
    _licenseNumCtrl.dispose();
    _licenseExpiryCtrl.dispose();
    _vMakeCtrl.dispose();
    _vModelCtrl.dispose();
    _vYearCtrl.dispose();
    _vPlateCtrl.dispose();
    _vColorCtrl.dispose();
    _driverLicenseUrlCtrl.dispose();
    _inspectionUrlCtrl.dispose();
    _insuranceUrlCtrl.dispose();
    _roadworthinessUrlCtrl.dispose();
    super.dispose();
  }

  // ── Step 1 Handlers ──────────────────────────────────────────────────────

  Future<void> _onSendOtp() async {
    final identifier = _identifierCtrl.text.trim();
    if (identifier.isEmpty) {
      setState(() => _errorMessage = 'Please enter an email or phone number.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final lookup = await _service.lookupAccount(identifier);
      final otpRes = await _service.sendOtp(identifier);

      setState(() {
        _lookupResult = lookup;
        _otpSent = true;
        _devOtpHint = otpRes.devOtpHint;

        if (lookup.exists && lookup.userData != null) {
          final u = lookup.userData!;
          if (_fullNameCtrl.text.isEmpty) _fullNameCtrl.text = u['fullName']?.toString() ?? '';
          if (_phoneCtrl.text.isEmpty) _phoneCtrl.text = u['phoneNumber']?.toString() ?? '';
          if (_emailCtrl.text.isEmpty) _emailCtrl.text = u['email']?.toString() ?? '';
          _selectedRole = u['role']?.toString() ?? _selectedRole;
        } else {
          if (identifier.contains('@')) {
            _emailCtrl.text = identifier;
          } else {
            _phoneCtrl.text = identifier;
          }
        }
      });
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _onVerifyOtp() async {
    final identifier = _identifierCtrl.text.trim();
    final otp = _otpCtrl.text.trim();

    if (otp.length < 6) {
      setState(() => _errorMessage = 'Please enter a valid 6-digit OTP.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final verified = await _service.verifyOtp(identifier, otp);
      if (verified) {
        setState(() {
          _otpVerified = true;
          _currentStep = 1;
        });
      } else {
        setState(() => _errorMessage = 'OTP verification failed.');
      }
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ── Step 4 Live Photo Capture ─────────────────────────────────────────────

  Future<void> _captureAdminLivePhoto() async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (photo == null) return;
      final bytes = await photo.readAsBytes();

      setState(() {
        _capturedPhotoBytes = bytes;
        _uploadedPhotoUrl = null;
        _errorMessage = null;
      });

      // Upload directly
      final path = 'drivers/admin_capture_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final url = await _service.uploadVerificationPhoto(path: path, bytes: bytes);

      setState(() {
        _uploadedPhotoUrl = url;
      });
    } catch (e) {
      setState(() => _errorMessage = 'Photo capture failed: $e');
    }
  }

  // ── Final Submission ──────────────────────────────────────────────────────

  Future<void> _submitRegistration() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final payload = AdminRegistrationPayload(
        role: _selectedRole,
        fullName: _fullNameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        email: _emailCtrl.text.trim().isNotEmpty ? _emailCtrl.text.trim() : null,
        address: _addressCtrl.text.trim().isNotEmpty ? _addressCtrl.text.trim() : null,
        ninNumber: _ninCtrl.text.trim().isNotEmpty ? _ninCtrl.text.trim() : null,
        driverDetails: _selectedRole == 'driver'
            ? {
                if (_licenseNumCtrl.text.isNotEmpty) 'licenseNumber': _licenseNumCtrl.text.trim(),
                if (_licenseExpiryCtrl.text.isNotEmpty) 'licenseExpiry': _licenseExpiryCtrl.text.trim(),
              }
            : null,
        vehicleDetails: _selectedRole == 'driver' && _vPlateCtrl.text.isNotEmpty
            ? {
                'category': _selectedCategory.name,
                'make': _vMakeCtrl.text.trim(),
                'model': _vModelCtrl.text.trim(),
                'year': int.tryParse(_vYearCtrl.text.trim()) ?? DateTime.now().year,
                'licensePlate': _vPlateCtrl.text.trim().toUpperCase(),
                'color': _vColorCtrl.text.trim(),
                if (_selectedTier != null) 'tier': _selectedTier!.name,
              }
            : null,
        documents: _selectedRole == 'driver'
            ? {
                if (_driverLicenseUrlCtrl.text.isNotEmpty) 'driverLicenseUrl': _driverLicenseUrlCtrl.text.trim(),
                if (_inspectionUrlCtrl.text.isNotEmpty) 'vehicleInspectionUrl': _inspectionUrlCtrl.text.trim(),
                if (_insuranceUrlCtrl.text.isNotEmpty) 'vehicleInsuranceUrl': _insuranceUrlCtrl.text.trim(),
                if (_roadworthinessUrlCtrl.text.isNotEmpty) 'roadworthinessUrl': _roadworthinessUrlCtrl.text.trim(),
              }
            : null,
        livePhotoUrl: _uploadedPhotoUrl,
      );

      final res = await _service.registerUser(payload);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(res['message']?.toString() ?? 'User registered successfully!'),
            backgroundColor: Colors.green.shade700,
          ),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── UI Render ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Onboarding & Registration'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: Column(
        children: [
          // Step Progress Bar
          LinearProgressIndicator(
            value: (_currentStep + 1) / 5,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              children: [
                Expanded(child: _stepHeader(0, '1. Lookup & OTP')),
                Expanded(child: _stepHeader(1, '2. Profile')),
                Expanded(child: _stepHeader(2, '3. Vehicle')),
                Expanded(child: _stepHeader(3, '4. Live Photo')),
                Expanded(child: _stepHeader(4, '5. Review')),
              ],
            ),
          ),
          const Divider(height: 1),

          if (_errorMessage != null)
            Container(
              width: double.infinity,
              color: Colors.red.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(color: Colors.red.shade900, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: _buildCurrentStepView(),
            ),
          ),

          // Bottom Action Bar
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (_currentStep > 0)
                  OutlinedButton.icon(
                    onPressed: _isLoading ? null : () => setState(() => _currentStep--),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Back'),
                  )
                else
                  const SizedBox.shrink(),
                _buildNextOrSubmitButton(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepHeader(int step, String title) {
    final active = _currentStep == step;
    final done = _currentStep > step;
    return Column(
      children: [
        CircleAvatar(
          radius: 12,
          backgroundColor: done
              ? Colors.green
              : active
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade400,
          child: done
              ? const Icon(Icons.check, size: 14, color: Colors.white)
              : Text(
                  '${step + 1}',
                  style: const TextStyle(fontSize: 11, color: Colors.white),
                ),
        ),
        const SizedBox(height: 4),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            color: active ? Theme.of(context).colorScheme.primary : Colors.grey.shade700,
          ),
        ),
      ],
    );
  }

  Widget _buildCurrentStepView() {
    switch (_currentStep) {
      case 0:
        return _buildStep1LookupAndOtp();
      case 1:
        return _buildStep2ProfileDetails();
      case 2:
        return _buildStep3VehicleSetup();
      case 3:
        return _buildStep4DocumentsAndPhoto();
      case 4:
        return _buildStep5ReviewAndSubmit();
      default:
        return const SizedBox.shrink();
    }
  }

  // ── Step 1 UI ─────────────────────────────────────────────────────────────

  Widget _buildStep1LookupAndOtp() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Step 1: Lookup & OTP Verification',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Search for an existing user account or start a new registration by entering their phone number or email address.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _identifierCtrl,
          decoration: InputDecoration(
            labelText: 'Email Address or Phone Number',
            hintText: 'e.g., driver@sese.app or +2348012345678',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.search),
              onPressed: _isLoading ? null : _onSendOtp,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _isLoading ? null : _onSendOtp,
            icon: const Icon(Icons.send),
            label: Text(_otpSent ? 'Resend OTP Code' : 'Lookup Account & Send OTP'),
          ),
        ),

        if (_lookupResult != null) ...[
          const SizedBox(height: 20),
          Card(
            color: _lookupResult!.exists ? Colors.blue.shade50 : Colors.green.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    _lookupResult!.exists ? Icons.person_search : Icons.person_add,
                    color: _lookupResult!.exists ? Colors.blue : Colors.green,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _lookupResult!.exists ? 'Existing Account Found' : 'New Account',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          _lookupResult!.message ?? '',
                          style: const TextStyle(fontSize: 12),
                        ),
                        if (_lookupResult!.missingSteps.isNotEmpty)
                          Text(
                            'Missing Steps: ${_lookupResult!.missingSteps.join(", ")}',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.orange),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        if (_otpSent) ...[
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),
          const Text(
            'Enter Received 6-Digit OTP Code',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _otpCtrl,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: InputDecoration(
              labelText: '6-Digit OTP Code',
              hintText: '123456',
              border: const OutlineInputBorder(),
              helperText: _devOtpHint != null ? 'Dev Mode OTP Hint: $_devOtpHint' : null,
              helperStyle: const TextStyle(color: Colors.purple, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _isLoading ? null : _onVerifyOtp,
              icon: const Icon(Icons.verified),
              label: const Text('Verify OTP & Proceed'),
            ),
          ),
        ],
      ],
    );
  }

  // ── Step 2 UI ─────────────────────────────────────────────────────────────

  Widget _buildStep2ProfileDetails() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Step 2: Role & Personal Profile Details',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        const Text('Select Account Role:', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'customer', label: Text('Customer'), icon: Icon(Icons.person)),
            ButtonSegment(value: 'driver', label: Text('Driver'), icon: Icon(Icons.directions_car)),
          ],
          selected: {_selectedRole},
          onSelectionChanged: (val) => setState(() => _selectedRole = val.first),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _fullNameCtrl,
          decoration: const InputDecoration(labelText: 'Full Name *', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: SesePhoneInputField(
                controller: _phoneCtrl,
                labelText: 'Phone Number *',
                autoValidateMode: AutovalidateMode.onUserInteraction,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _emailCtrl,
                decoration: const InputDecoration(labelText: 'Email Address', border: OutlineInputBorder()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _addressCtrl,
          decoration: const InputDecoration(labelText: 'Residential Address', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ninCtrl,
          decoration: const InputDecoration(labelText: 'NIN (National Identity Number)', border: OutlineInputBorder()),
        ),
        if (_selectedRole == 'driver') ...[
          const SizedBox(height: 20),
          const Text('Driver License Information', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _licenseNumCtrl,
                  decoration: const InputDecoration(labelText: 'Driver License Number', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _licenseExpiryCtrl,
                  decoration: const InputDecoration(labelText: 'License Expiry (YYYY-MM-DD)', border: OutlineInputBorder()),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ── Step 3 UI ─────────────────────────────────────────────────────────────

  Widget _buildStep3VehicleSetup() {
    if (_selectedRole == 'customer') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Step 3: Vehicle Setup (Skipped)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.grey.shade100,
            child: const Text('Customer accounts do not require vehicle registration. Tap Next to continue.'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Step 3: Vehicle & Fleet Setup',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<VehicleCategory>(
          initialValue: _selectedCategory,
          decoration: const InputDecoration(labelText: 'Vehicle Category *', border: OutlineInputBorder()),
          items: VehicleCategory.values.map((cat) {
            return DropdownMenuItem(
              value: cat,
              child: Text('${cat.name.toUpperCase()} (${cat.displayName})'),
            );
          }).toList(),
          onChanged: (cat) => setState(() => _selectedCategory = cat ?? VehicleCategory.car),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _vMakeCtrl,
                decoration: const InputDecoration(labelText: 'Vehicle Make (e.g. Toyota)', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _vModelCtrl,
                decoration: const InputDecoration(labelText: 'Vehicle Model (e.g. Corolla)', border: OutlineInputBorder()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _vYearCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Year', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _vPlateCtrl,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'License Plate Number *', border: OutlineInputBorder()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _vColorCtrl,
                decoration: const InputDecoration(labelText: 'Vehicle Color', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<RideTier?>(
                initialValue: _selectedTier,
                decoration: const InputDecoration(labelText: 'Service Tier (Optional)', border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Standard / Auto-Assigned')),
                  ...RideTier.values.map((t) => DropdownMenuItem(value: t, child: Text(t.name.toUpperCase()))),
                ],
                onChanged: (t) => setState(() => _selectedTier = t),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Step 4 UI ─────────────────────────────────────────────────────────────

  Widget _buildStep4DocumentsAndPhoto() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Step 4: Compliance Documents & Admin Live Photo',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        if (_selectedRole == 'driver') ...[
          const Text('Compliance Document Storage URLs / Paths:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _driverLicenseUrlCtrl,
            decoration: const InputDecoration(labelText: 'Driver License Image/Doc URL', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _inspectionUrlCtrl,
            decoration: const InputDecoration(labelText: 'Vehicle Inspection Certificate URL', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _insuranceUrlCtrl,
            decoration: const InputDecoration(labelText: 'Vehicle Insurance Certificate URL', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _roadworthinessUrlCtrl,
            decoration: const InputDecoration(labelText: 'Roadworthiness Certificate URL', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
        ],

        const Text('Admin Live Verification Photo Capture', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text(
          'Use the admin device camera to capture a live verification photo of the user/driver on site.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 12),

        Center(
          child: Column(
            children: [
              if (_capturedPhotoBytes != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(_capturedPhotoBytes!, height: 180, width: 180, fit: BoxFit.cover),
                )
              else
                Container(
                  height: 160,
                  width: 160,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade400),
                  ),
                  child: const Icon(Icons.camera_alt, size: 48, color: Colors.grey),
                ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _isLoading ? null : _captureAdminLivePhoto,
                icon: const Icon(Icons.camera),
                label: Text(_capturedPhotoBytes != null ? 'Retake Live Photo' : 'Capture Live Photo'),
              ),
              if (_uploadedPhotoUrl != null)
                const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle, color: Colors.green, size: 18),
                      SizedBox(width: 6),
                      Text('Photo Uploaded to Storage', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 12)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Step 5 UI ─────────────────────────────────────────────────────────────

  Widget _buildStep5ReviewAndSubmit() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Step 5: Review & Submission',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Summary of Account Provisioning:', style: TextStyle(fontWeight: FontWeight.bold)),
                const Divider(),
                Text('Role: ${_selectedRole.toUpperCase()}'),
                Text('Full Name: ${_fullNameCtrl.text}'),
                Text('Phone: ${_phoneCtrl.text}'),
                if (_emailCtrl.text.isNotEmpty) Text('Email: ${_emailCtrl.text}'),
                if (_selectedRole == 'driver' && _vPlateCtrl.text.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Vehicle Category: ${_selectedCategory.displayName}'),
                  Text('Plate Number: ${_vPlateCtrl.text.toUpperCase()}'),
                  Text('Make/Model: ${_vMakeCtrl.text} ${_vModelCtrl.text}'),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),

        // Self-Verification Lock Notice Box
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.amber.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.amber.shade700, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lock, color: Colors.amber.shade900),
                  const SizedBox(width: 8),
                  Text(
                    'Self-Verification Lock Enforced',
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber.shade900, fontSize: 15),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Zero-Trust Security Rule: Because you are provisioning this account as Admin, backend rules prohibit your admin account from self-approving its verification status. The profile will be submitted in "Pending Verification" state until reviewed by an independent admin account.',
                style: TextStyle(color: Colors.amber.shade900, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNextOrSubmitButton() {
    if (_currentStep == 0) {
      return FilledButton.icon(
        onPressed: _otpVerified ? () => setState(() => _currentStep = 1) : null,
        icon: const Icon(Icons.arrow_forward),
        label: const Text('Next'),
      );
    }

    if (_currentStep < 4) {
      return FilledButton.icon(
        onPressed: () => setState(() => _currentStep++),
        icon: const Icon(Icons.arrow_forward),
        label: const Text('Next'),
      );
    }

    return FilledButton.icon(
      onPressed: _isLoading ? null : _submitRegistration,
      style: FilledButton.styleFrom(backgroundColor: Colors.green.shade700),
      icon: const Icon(Icons.check_circle),
      label: const Text('Submit & Provision Account'),
    );
  }
}
